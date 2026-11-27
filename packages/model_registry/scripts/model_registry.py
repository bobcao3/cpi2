#!/usr/bin/env python3
"""Load, query, validate, and refresh the version 2 Lua model catalog."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request
import warnings

SOURCES = {
    "models.dev": "https://models.dev/api.json",
    "openrouter": "https://openrouter.ai/api/v1/models",
}
DEFAULT_CONFIG = Path(__file__).resolve().parents[1] / "data" / "models.lua"
DEFAULT_API_OVERLAY = DEFAULT_CONFIG.with_name("api_overrides.json")
MAX_BYTES = 32 * 1024 * 1024
EVALUATOR_TIMEOUT = 15
MAX_STDERR_BYTES = 64 * 1024
MAX_EXACT_INTEGER = 2**53 - 1
PRICE_FIELDS = ("input", "output", "cache_read", "cache_write")
IMAGE_RESIZE_FIELDS = ("max_width", "max_height", "max_bytes", "jpeg_quality")
SERVICE_DEFAULTS = {
    "openai": ("https://api.openai.com/v1", "OPENAI_API_KEY"),
    "anthropic": ("https://api.anthropic.com/v1", "ANTHROPIC_API_KEY"),
    "google": ("https://generativelanguage.googleapis.com/v1beta", "GOOGLE_API_KEY"),
    "openrouter": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY"),
}


class CatalogError(ValueError):
    """The catalog or a public snapshot violates a supported contract."""


def _object(value, path, allowed=None, required=()):
    if not isinstance(value, dict):
        raise CatalogError(f"{path}: expected object")
    if allowed is not None:
        unknown = value.keys() - set(allowed)
        if unknown:
            raise CatalogError(f"{path}: unknown fields {sorted(unknown)}")
    missing = set(required) - value.keys()
    if missing:
        raise CatalogError(f"{path}: missing fields {sorted(missing)}")
    return value


def _string(value, path, nullable=False):
    if value is None and nullable:
        return None
    if not isinstance(value, str):
        raise CatalogError(f"{path}: expected {'string or null' if nullable else 'string'}")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise CatalogError(f"{path}: expected a Unicode scalar string") from error
    return value


def _array(value, path):
    if not isinstance(value, list):
        raise CatalogError(f"{path}: expected array")
    return value


def _token(value, path, maximum):
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as error:
        raise CatalogError(f"{path}: expected valid UTF-8 token") from error
    if not encoded or any(byte <= 0x20 or byte == 0x7f for byte in encoded):
        raise CatalogError(f"{path}: expected nonempty token without ASCII whitespace/control bytes")
    _report_size(f"{path} bytes", len(encoded), maximum)


def _report_size(measurement, actual, expected):
    if actual > expected:
        warnings.warn(f"{measurement} is {actual}, above the expected {expected}", RuntimeWarning, stacklevel=2)


def _limit(value, path, bits):
    if value is None:
        return None
    if bits == 64 and (type(value) is not int or not 0 < value <= MAX_EXACT_INTEGER):
        raise CatalogError(f"{path}: expected positive exact Lua integer at most {MAX_EXACT_INTEGER} or null")
    if type(value) is not int or not 0 < value < 2**bits:
        raise CatalogError(f"{path}: expected positive u{bits} or null")
    return value


def _price(value, path):
    if value is None:
        return None
    if type(value) not in (int, float) or value < 0:
        raise CatalogError(f"{path}: expected nonnegative finite number or null")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise CatalogError(f"{path}: expected nonnegative finite number or null")
    return value


def _image_resize(value, path):
    if value is None:
        return None
    values = _object(value, path, IMAGE_RESIZE_FIELDS)
    resize = {key: _limit(values.get(key), f"{path}.{key}", bits)
              for key, bits in zip(IMAGE_RESIZE_FIELDS, (32, 32, 64, 8))}
    if resize["jpeg_quality"] is not None and resize["jpeg_quality"] > 100:
        raise CatalogError(f"{path}.jpeg_quality: expected integer 1 through 100 or null")
    return resize


def validate(document) -> dict[str, Any]:
    """Return a normalized copy; reject unknown fields, invalid values, and duplicate IDs."""
    _object(document, "catalog", ("version", "providers"), ("version", "providers"))
    if type(document["version"]) is not int or document["version"] not in (1, 2):
        raise CatalogError("catalog.version: expected integer 1 or 2")
    legacy = document["version"] == 1
    providers, provider_ids = [], set()
    for index, raw_provider in enumerate(_array(document["providers"], "catalog.providers")):
        path = f"providers[{index}]"
        required = ("id", "name", "base_url", "api_key_env", "models")
        if legacy:
            required += ("api",)
        _object(raw_provider, path, (*required, "source_url", "retrieved_at"), required)
        provider: dict[str, Any] = {key: _string(raw_provider[key], f"{path}.{key}") for key in required if key not in ("models", "api")}
        _token(provider["id"], f"{path}.id", 128)
        if legacy:
            _token(_string(raw_provider["api"], f"{path}.api"), f"{path}.api", 128)
        if not provider["name"]:
            raise CatalogError(f"{path}.name: expected nonempty string")
        if provider["id"] in provider_ids:
            raise CatalogError(f"{path}: duplicate provider id {provider['id']!r}")
        provider_ids.add(provider["id"])
        for key in ("source_url", "retrieved_at"):
            provider[key] = _string(raw_provider.get(key), f"{path}.{key}", nullable=True)
        models, model_ids = [], set()
        for model_index, raw_model in enumerate(_array(raw_provider["models"], f"{path}.models")):
            model_path = f"{path}.models[{model_index}]"
            _object(raw_model, model_path,
                    ("id", "name", "context_window", "max_output_tokens", "pricing", "source_url", "reasoning_efforts", "image_resize",
                     *(("api",) if legacy else ("transports",))),
                    ("id", "name"))
            model: dict[str, Any] = {key: _string(raw_model[key], f"{model_path}.{key}") for key in ("id", "name")}
            _token(model["id"], f"{model_path}.id", 512)
            if legacy:
                api = _string(raw_model.get("api"), f"{model_path}.api", nullable=True)
                api = raw_provider["api"] if api is None else api
                _token(api, f"{model_path}.api", 128)
                transports = [] if api == "unknown" else [api]
            else:
                transports = raw_model.get("transports", [])
            for key, values in (("transports", transports), ("reasoning_efforts", raw_model.get("reasoning_efforts", []))):
                values = _array(values, f"{model_path}.{key}")
                for value in values:
                    _token(_string(value, f"{model_path}.{key}[]"), f"{model_path}.{key}[]", 128)
                if len(set(values)) != len(values):
                    raise CatalogError(f"{model_path}.{key}: duplicate value")
                model[key] = list(values)
            if not model["name"]:
                raise CatalogError(f"{model_path}.name: expected nonempty string")
            if model["id"] in model_ids:
                raise CatalogError(f"{model_path}: duplicate model id {model['id']!r}")
            model_ids.add(model["id"])
            model["context_window"] = _limit(raw_model.get("context_window"), f"{model_path}.context_window", 64)
            model["max_output_tokens"] = _limit(raw_model.get("max_output_tokens"), f"{model_path}.max_output_tokens", 32)
            resize = _image_resize(raw_model.get("image_resize"), f"{model_path}.image_resize")
            if resize is not None:
                model["image_resize"] = resize
            pricing = _object(raw_model.get("pricing", {}), f"{model_path}.pricing", PRICE_FIELDS)
            model["pricing"] = {key: _price(pricing.get(key), f"{model_path}.pricing.{key}") for key in PRICE_FIELDS}
            model["source_url"] = _string(raw_model.get("source_url"), f"{model_path}.source_url", nullable=True)
            models.append(model)
        provider["models"] = sorted(models, key=lambda model: model["id"])
        providers.append(provider)
    return {"version": 2, "providers": sorted(providers, key=lambda provider: provider["id"])}


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError(f"JSON: duplicate object key {key!r}")
        result[key] = value
    return result


def _constant(value):
    raise CatalogError(f"JSON: invalid constant {value}")


def decode(raw):
    """Decode strict UTF-8 JSON, including duplicate-key and nonfinite-constant checks."""
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise CatalogError(f"invalid JSON: {error}") from error


def read_snapshot(path):
    raw = Path(path).read_bytes()
    _report_size("snapshot bytes", len(raw), MAX_BYTES)
    return decode(raw)


def find_evaluator():
    """Resolve the explicit override, repository build, package build, then PATH."""
    name = "cpi-model-registry"
    override = os.environ.get("CPI_MODEL_REGISTRY_EVALUATOR")
    if override is not None:
        executable = shutil.which(override) if override else None
        if executable is None:
            raise CatalogError("CPI_MODEL_REGISTRY_EVALUATOR does not name an executable")
        return executable
    script = Path(__file__).resolve()
    for directory in (script.parents[3], script.parents[1]):
        candidate = directory / "zig-out" / "bin" / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    executable = shutil.which(name)
    if executable is None:
        raise CatalogError("cpi-model-registry evaluator not found; build/install the native evaluator or set CPI_MODEL_REGISTRY_EVALUATOR")
    return executable


def load(path=DEFAULT_CONFIG):
    """Evaluate sandboxed Lua through the shared native evaluator and normalize JSON output."""
    executable = find_evaluator()
    deadline = time.monotonic() + EVALUATOR_TIMEOUT
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": MAX_BYTES, "stderr": MAX_STDERR_BYTES}
    try:
        with subprocess.Popen([executable, str(Path(path).resolve())], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                assert process.stdout is not None and process.stderr is not None
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
                    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
                    while selector.get_map():
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise CatalogError(f"native evaluator exceeded {EVALUATOR_TIMEOUT} second timeout")
                        for key, _ in selector.select(remaining):
                            name = key.data
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                selector.unregister(key.fileobj)
                                continue
                            buffers[name].extend(chunk)
                    try:
                        process.wait(timeout=max(0, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired as error:
                        raise CatalogError(f"native evaluator exceeded {EVALUATOR_TIMEOUT} second timeout") from error
            except BaseException:
                process.kill()
                process.wait()
                raise
    except OSError as error:
        raise CatalogError(f"cannot execute native evaluator {executable!r}: {error}") from error
    for name, expected in limits.items():
        _report_size(f"native evaluator {name} bytes", len(buffers[name]), expected)
    if process.returncode != 0:
        message = buffers["stderr"].decode("utf-8", errors="replace").strip()
        raise CatalogError(f"native evaluator failed ({process.returncode}): {message}")
    return validate(decode(bytes(buffers["stdout"])))


def iter_models(catalog, *, provider_id=None, text=None):
    """Yield (provider, model) pairs in catalog order, with optional literal filters."""
    needle = text.casefold() if text is not None else None
    for provider in catalog["providers"]:
        if provider_id is not None and provider["id"] != provider_id:
            continue
        for model in provider["models"]:
            if needle is None or any(needle in value.casefold() for value in
                                     (provider["id"], provider["name"], model["id"], model["name"])):
                yield provider, model


def find_model(catalog, provider_id, model_id):
    """Return a model by provider-scoped identity, or raise KeyError."""
    for provider, model in iter_models(catalog, provider_id=provider_id):
        if model["id"] == model_id:
            return model
    raise KeyError((provider_id, model_id))


LUA_RESERVED = frozenset("and break do else elseif end false for function goto if in local nil not or repeat return then true until while".split())


def _lua_string(value):
    parts = ['"']
    for character in value:
        if character in ('"', "\\"):
            parts.append("\\" + character)
        elif ord(character) < 32 or ord(character) == 127:
            parts.append(f"\\{ord(character):03d}")
        else:
            parts.append(character)
    parts.append('"')
    return "".join(parts)


def _lua_value(value, depth=0):
    if isinstance(value, str):
        return _lua_string(value)
    if type(value) in (int, float):
        return repr(value)
    indent = "  " * (depth + 1)
    if isinstance(value, dict):
        entries = []
        for key, item in sorted(value.items()):
            if item is None:
                continue
            field = key if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", key) and key not in LUA_RESERVED else f"[{_lua_string(key)}]"
            entries.append(f"{indent}{field} = {_lua_value(item, depth + 1)},")
    else:
        entries = [f"{indent}{_lua_value(item, depth + 1)}," for item in value]
    if not entries:
        return "{}"
    return "{\n" + "\n".join(entries) + "\n" + "  " * depth + "}"


def dumps(catalog):
    """Serialize portable Lua with stable ordering and absent optional nil fields."""
    return "return " + _lua_value(validate(catalog)) + "\n"


def write_atomic(path, catalog):
    """Replace the target only after validation, serialization, and a complete temporary write."""
    write_text_atomic(path, dumps(catalog))


def write_text_atomic(path, content):
    """Atomic UTF-8 replacement, also used for retained first-party raw inputs."""
    path = Path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                         dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
            temporary = stream.name
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


class _PublicRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        original = urllib.parse.urlsplit(req.full_url)
        target = urllib.parse.urlsplit(newurl)
        if (target.scheme != "https" or target.hostname != original.hostname
                or target.port not in (None, 443) or target.username or target.password):
            raise CatalogError("public source redirected outside its HTTPS origin")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(source, *, timeout=20):
    """Read at most 32 MiB from a fixed unauthenticated HTTPS source."""
    if source not in SOURCES:
        raise CatalogError(f"unsupported source {source!r}")
    if not 0 < timeout <= 60:
        raise CatalogError("timeout must be greater than zero and at most 60 seconds")
    request = urllib.request.Request(SOURCES[source], headers={
        "User-Agent": "model-registry/1.0 (public catalog maintenance)",
        "Accept": "application/json",
        "Accept-Encoding": "identity",
    })
    opener = urllib.request.build_opener(_PublicRedirects())
    with opener.open(request, timeout=timeout) as response:
        raw = response.read()
    _report_size("source bytes", len(raw), MAX_BYTES)
    return decode(raw)


def _source_number(value, path, *, per_token=False):
    if value is None:
        return None
    if type(value) not in (int, float, str):
        raise CatalogError(f"{path}: expected numeric source price")
    try:
        number = Decimal(str(value))
    except InvalidOperation as error:
        raise CatalogError(f"{path}: invalid numeric source price") from error
    if not number.is_finite():
        raise CatalogError(f"{path}: nonfinite source price")
    # OpenRouter uses -1 for routing-dependent prices, not a free rate.
    if per_token and number == -1:
        return None
    if number < 0:
        raise CatalogError(f"{path}: negative source price")
    if number != 0 and not -330 <= number.adjusted() <= 308:
        raise CatalogError(f"{path}: source price exceeds representable range")
    if per_token:
        number *= 1_000_000
    result = float(number)
    if not math.isfinite(result) or (number != 0 and result == 0):
        raise CatalogError(f"{path}: source price exceeds representable range")
    return result


def _source_limit(value, path, bits):
    # Public catalogs sometimes use zero when a limit is unknown.
    if type(value) is int and value == 0:
        return None
    return _limit(value, path, bits)


def _models_dev(snapshot, retrieved_at):
    _object(snapshot, "models.dev")
    providers = []
    for provider_id, raw in snapshot.items():
        _object(raw, f"models.dev.{provider_id}", required=("id", "name", "models"))
        if raw["id"] != provider_id:
            raise CatalogError(f"models.dev: provider key/id mismatch for {provider_id!r}")
        base_default, env_default = SERVICE_DEFAULTS.get(provider_id, ("", ""))
        env = raw.get("env", [])
        _array(env, f"models.dev.{provider_id}.env")
        for entry in env:
            _string(entry, f"models.dev.{provider_id}.env[]")
        provider = {
            "id": provider_id, "name": raw["name"],
            "base_url": raw.get("api", base_default),
            "api_key_env": env[0] if env else env_default,
            # The source's SDK package names do not prove wire-protocol support.
            "source_url": SOURCES["models.dev"],
            "retrieved_at": retrieved_at, "models": [],
        }
        _object(raw["models"], f"models.dev.{provider_id}.models")
        for model_id, model in raw["models"].items():
            path = f"models.dev.{provider_id}.{model_id}"
            _object(model, path, required=("id", "name"))
            if model["id"] != model_id:
                raise CatalogError(f"{path}: model key/id mismatch")
            limits = _object(model.get("limit", {}), f"{path}.limit")
            cost = _object(model.get("cost", {}), f"{path}.cost")
            provider["models"].append({
                "id": model_id, "name": model["name"],
                "context_window": _source_limit(limits.get("context"), f"{path}.limit.context", 64),
                "max_output_tokens": _source_limit(limits.get("output"), f"{path}.limit.output", 32),
                "pricing": {key: _source_number(cost.get(key), f"{path}.cost.{key}") for key in PRICE_FIELDS},
                "source_url": SOURCES["models.dev"],
            })
        providers.append(provider)
    return providers


def _openrouter(snapshot, retrieved_at):
    _object(snapshot, "openrouter", required=("data",))
    provider = {
        "id": "openrouter", "name": "OpenRouter",
        "base_url": SERVICE_DEFAULTS["openrouter"][0],
        "api_key_env": "OPENROUTER_API_KEY",
        "source_url": SOURCES["openrouter"], "retrieved_at": retrieved_at, "models": [],
    }
    keys = {"input": "prompt", "output": "completion",
            "cache_read": "input_cache_read", "cache_write": "input_cache_write"}
    for index, raw in enumerate(_array(snapshot["data"], "openrouter.data")):
        path = f"openrouter.data[{index}]"
        _object(raw, path, required=("id", "name"))
        pricing = _object(raw.get("pricing", {}), f"{path}.pricing")
        top = _object({} if raw.get("top_provider") is None else raw["top_provider"], f"{path}.top_provider")
        endpoints = _array(raw.get("endpoints", []), f"{path}.endpoints")
        for endpoint in endpoints:
            _string(endpoint, f"{path}.endpoints[]")
        transports = [protocol for endpoint, protocol in (
            ("/api/v1/responses", "openai-responses"),
            ("/api/v1/chat/completions", "openai-chat"),
            ("/api/v1/messages", "anthropic-messages"),
        ) if endpoint in endpoints]
        provider["models"].append({
            "id": raw["id"], "name": raw["name"], "transports": transports,
            "context_window": _source_limit(raw.get("context_length"), f"{path}.context_length", 64),
            "max_output_tokens": _source_limit(top.get("max_completion_tokens"), f"{path}.max_completion_tokens", 32),
            "pricing": {key: _source_number(pricing.get(source_key), f"{path}.pricing.{source_key}", per_token=True)
                        for key, source_key in keys.items()},
            "source_url": SOURCES["openrouter"],
        })
    return [provider]


def convert_snapshot(source, snapshot, *, retrieved_at=None, provider_ids=None, model_ids=None):
    """Transform a public snapshot without guessing protocol support or merging providers."""
    if source == "models.dev":
        providers = _models_dev(snapshot, retrieved_at)
    elif source == "openrouter":
        providers = _openrouter(snapshot, retrieved_at)
    else:
        raise CatalogError(f"unsupported source {source!r}")
    catalog = validate({"version": 2, "providers": providers})
    if provider_ids is not None:
        wanted = set(provider_ids)
        missing = wanted - {provider["id"] for provider in catalog["providers"]}
        if missing:
            raise CatalogError(f"source has no providers {sorted(missing)}")
        catalog["providers"] = [provider for provider in catalog["providers"] if provider["id"] in wanted]
    if model_ids is not None:
        wanted = set(model_ids)
        found = {model["id"] for _, model in iter_models(catalog)}
        if wanted - found:
            raise CatalogError(f"selected providers have no models {sorted(wanted - found)}")
        for provider in catalog["providers"]:
            provider["models"] = [model for model in provider["models"] if model["id"] in wanted]
        catalog["providers"] = [provider for provider in catalog["providers"] if provider["models"]]
    return catalog


def apply_api_overlay(catalog, overlay):
    """Apply reviewed exact-ID protocol claims without adding or removing offers."""
    catalog = validate(catalog)
    seen = set()
    for index, entry in enumerate(_array(overlay, "API overlay")):
        path = f"API overlay[{index}]"
        fields = ("provider_id", "model_id", "api", "reference_url", "reviewed_at")
        _object(entry, path, fields, fields)
        for field in fields:
            _string(entry[field], f"{path}.{field}")
            if not entry[field]:
                raise CatalogError(f"{path}.{field}: expected nonempty string")
        _token(entry["provider_id"], f"{path}.provider_id", 128)
        _token(entry["model_id"], f"{path}.model_id", 512)
        _token(entry["api"], f"{path}.api", 128)
        if not entry["reference_url"].startswith("https://"):
            raise CatalogError(f"{path}.reference_url: expected public HTTPS reference")
        identity = (entry["provider_id"], entry["model_id"])
        if identity in seen:
            raise CatalogError(f"{path}: duplicate API override {identity!r}")
        seen.add(identity)
        try:
            model = find_model(catalog, *identity)
        except KeyError:
            print(f"model-registry: warning: stale API override {identity!r}; source has no offer", file=sys.stderr)
            continue
        if model["transports"] and entry["api"] not in model["transports"]:
            raise CatalogError(f"{path}: API override contradicts explicit source endpoint")
        if not model["transports"]:
            model["transports"] = [entry["api"]]
    return catalog


def refresh(*, models_dev_input=None, openrouter_input=None, models_dev_retrieved_at=None,
            openrouter_retrieved_at=None, api_overlay=DEFAULT_API_OVERLAY, first_party_input=None,
            output=DEFAULT_CONFIG, timeout=20):
    """Materialize both complete public sources before replacing the installed snapshot."""
    converted = {}
    for source, path, timestamp in (
        ("models.dev", models_dev_input, models_dev_retrieved_at),
        ("openrouter", openrouter_input, openrouter_retrieved_at),
    ):
        if path is not None:
            if not timestamp:
                raise CatalogError(f"{source}: offline refresh requires an explicit retrieval timestamp")
            snapshot = read_snapshot(path)
        else:
            snapshot = download(source, timeout=timeout)
            timestamp = timestamp or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        converted[source] = convert_snapshot(source, snapshot, retrieved_at=timestamp)
        if not any(iter_models(converted[source])):
            raise CatalogError(f"{source}: refusing an empty public catalog")
    providers = [provider for provider in converted["models.dev"]["providers"] if provider["id"] != "openrouter"]
    providers.extend(converted["openrouter"]["providers"])
    import first_party
    direct = validate(first_party.convert(read_snapshot(first_party_input or first_party.RAW)))
    direct_ids = {provider["id"] for provider in direct["providers"]}
    providers = [provider for provider in providers if provider["id"] not in direct_ids]
    providers.extend(direct["providers"])
    catalog = apply_api_overlay({"version": 2, "providers": providers}, read_snapshot(api_overlay))
    write_atomic(output, catalog)
    return catalog


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "list", "show"):
        sub = commands.add_parser(command)
        sub.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
        if command == "list":
            sub.add_argument("--provider")
            sub.add_argument("--query", help="case-insensitive literal substring")
        elif command == "show":
            sub.add_argument("provider")
            sub.add_argument("model")
    fetch = commands.add_parser("fetch", help="replace a catalog candidate from a public source")
    fetch.add_argument("source", choices=SOURCES)
    fetch.add_argument("--input", type=Path, help="use a local public snapshot instead of the network")
    fetch.add_argument("--output", type=Path, help="atomically replace this file; default: stdout")
    fetch.add_argument("--provider", action="append", help="include an exact provider ID; repeatable")
    fetch.add_argument("--model", action="append", help="include an exact model ID; repeatable")
    fetch.add_argument("--retrieved-at", help="original snapshot retrieval time; offline default: omitted")
    fetch.add_argument("--timeout", type=float, default=20, help="network socket timeout in seconds (0 < n <= 60)")
    update = commands.add_parser("refresh", help="atomically install both complete public catalogs")
    update.add_argument("--models-dev-input", type=Path, help="local raw models.dev JSON instead of downloading")
    update.add_argument("--openrouter-input", type=Path, help="local raw OpenRouter JSON instead of downloading")
    update.add_argument("--models-dev-retrieved-at", help="original models.dev retrieval timestamp; required for local input")
    update.add_argument("--openrouter-retrieved-at", help="original OpenRouter retrieval timestamp; required for local input")
    update.add_argument("--api-overlay", type=Path, default=DEFAULT_API_OVERLAY)
    update.add_argument("--first-party-input", type=Path, help="retained first-party documentation/API bundle; defaults to data/first_party_sources.json")
    update.add_argument("--output", type=Path, default=DEFAULT_CONFIG)
    update.add_argument("--timeout", type=float, default=20, help="network socket timeout in seconds (0 < n <= 60)")
    args = parser.parse_args(argv)
    try:
        if args.command == "refresh":
            catalog = refresh(models_dev_input=args.models_dev_input, openrouter_input=args.openrouter_input,
                              models_dev_retrieved_at=args.models_dev_retrieved_at,
                              openrouter_retrieved_at=args.openrouter_retrieved_at,
                              api_overlay=args.api_overlay, first_party_input=args.first_party_input, output=args.output, timeout=args.timeout)
            print(json.dumps({"providers": len(catalog["providers"]),
                              "models": sum(len(provider["models"]) for provider in catalog["providers"])}))
            return 0
        if args.command == "fetch":
            if args.input is not None:
                snapshot = read_snapshot(args.input)
                retrieved_at = args.retrieved_at
            else:
                snapshot = download(args.source, timeout=args.timeout)
                retrieved_at = args.retrieved_at or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
            catalog = convert_snapshot(args.source, snapshot, retrieved_at=retrieved_at,
                                       provider_ids=args.provider, model_ids=args.model)
            if args.output is not None:
                write_atomic(args.output, catalog)
            else:
                print(dumps(catalog), end="")
            return 0
        catalog = load(args.config)
        if args.command == "validate":
            result = {"version": 2, "providers": len(catalog["providers"]),
                      "models": sum(len(provider["models"]) for provider in catalog["providers"])}
        elif args.command == "list":
            result = [{"provider_id": provider["id"], "model": model}
                      for provider, model in iter_models(catalog, provider_id=args.provider, text=args.query)]
        else:
            result = {"provider_id": args.provider, "model": find_model(catalog, args.provider, args.model)}
        print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
        return 0
    except (CatalogError, OSError, KeyError, urllib.error.URLError, RecursionError, OverflowError) as error:
        print(f"model-registry: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
