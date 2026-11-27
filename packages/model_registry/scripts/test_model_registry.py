"""Offline behavioral tests for catalog parsing, public conversion, queries, and updates."""

import copy
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any
import unittest
from unittest.mock import patch

import model_registry as registry


def provider(identifier="seller-a", price=0.7) -> dict[str, Any]:
    return {
        "id": identifier, "name": identifier.title(), "base_url": "https://example.com/v1",
        "api_key_env": "EXAMPLE_API_KEY", "api": "unknown",
        "models": [{"id": "shared/model", "name": "Shared Model", "pricing": {"input": price}}],
    }


def catalog() -> dict[str, Any]:
    return {"version": 1, "providers": [provider("seller-b", 2.1), provider()]}


def models_dev() -> dict[str, Any]:
    return {
        "seller-b": {"id": "seller-b", "name": "Seller B", "api": "https://b.example/v1",
                     "env": ["B_KEY"], "npm": "@ai-sdk/openai-compatible", "models": {
                         "same": {"id": "same", "name": "Shared", "limit": {"context": 8192, "output": 1234},
                                  "cost": {"input": 2.75, "output": 0, "cache_read": 0.25,
                                           "cache_write": 3.5, "input_audio": 80}}}},
        "seller-a": {"id": "seller-a", "name": "Seller A", "models": {
                         "same": {"id": "same", "name": "Shared", "limit": {"context": 0},
                                  "cost": {"input": 0.5}}}},
    }


class CatalogTests(unittest.TestCase):
    def test_normalization_defaults_bounds_and_roundtrip(self):
        raw = catalog()
        raw["providers"][0]["models"][0].update(context_window=2**53 - 1, max_output_tokens=2**32 - 1)
        raw["providers"][0]["name"] = 'Quotes " backslash \\ newline\ncontrols ' + ''.join(chr(i) for i in range(32)) + '\x7f9 café 雪'
        raw["providers"][0]["models"][0]["pricing"]["output"] = 0
        normalized = registry.validate(raw)
        self.assertEqual([p["id"] for p in normalized["providers"]], ["seller-a", "seller-b"])
        model = registry.find_model(normalized, "seller-a", "shared/model")
        self.assertEqual(model["transports"], [])
        self.assertIsNone(model["context_window"])
        self.assertEqual(model["pricing"], {"input": 0.7, "output": None, "cache_read": None, "cache_write": None})
        self.assertIsNone(normalized["providers"][0]["retrieved_at"])
        self.assertNotIn("source_url", raw["providers"][0])
        boundary = {"version": 1, "providers": [provider("é" * 64)]}
        boundary_provider = boundary["providers"][0]
        boundary_provider.update(api="é" * 64, name=" ", base_url="", api_key_env="")
        boundary_provider["models"][0].update(id="é" * 256, name=" ", api="é" * 64)
        accepted = registry.validate(boundary)
        self.assertEqual(registry.find_model(accepted, "é" * 64, "é" * 256)["name"], " ")
        self.assertNotIn("api", accepted["providers"][0])
        self.assertEqual(accepted["providers"][0]["models"][0]["transports"], ["é" * 64])
        self.assertEqual(accepted["providers"][0]["base_url"], "")
        self.assertEqual(accepted["providers"][0]["api_key_env"], "")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "models.lua"
            registry.write_atomic(target, normalized)
            self.assertEqual(registry.load(target), normalized)
            before = target.read_bytes()
            registry.write_atomic(target, raw)
            self.assertEqual(target.read_bytes(), before)
            emitted = target.read_text(encoding="utf-8")
            self.assertIn('\\010', emitted)
            self.assertIn('\\000', emitted)
            self.assertNotIn('\\u', emitted)

    def test_load_evaluates_computed_lua_and_normalizes_nil(self):
        source = '''
local function offer(id, rate)
  return { id = id, name = "Computed", context_window = 2 ^ 13,
           max_output_tokens = 1024 * 3, api = nil,
           pricing = { input = rate / 4, output = 0 } }
end
local seller = { id = "computed", name = "Computed seller", api = "unknown",
                 base_url = "", api_key_env = "", models = {} }
seller.models[1] = offer("first", 3)
seller.models[2] = offer("second", 5)
return { version = 1, providers = { seller } }
'''
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "models.lua"
            target.write_text(source, encoding="utf-8")
            loaded = registry.load(target)
            first = registry.find_model(loaded, "computed", "first")
            second = registry.find_model(loaded, "computed", "second")
            self.assertEqual((first["context_window"], first["max_output_tokens"]), (8192, 3072))
            self.assertEqual(first["pricing"], {"input": 0.75, "output": 0, "cache_read": None, "cache_write": None})
            self.assertEqual(second["pricing"]["input"], 1.25)
            self.assertEqual(first["transports"], [])
            self.assertIsNone(loaded["providers"][0]["retrieved_at"])
            target.write_text(json.dumps(catalog()), encoding="utf-8")
            with self.assertRaises(registry.CatalogError):
                registry.load(target)

    def test_bad_explicit_evaluator_never_falls_back(self):
        for override in ("", "/no/such/cpi-model-registry"):
            with self.subTest(override=override), patch.dict(registry.os.environ, {"CPI_MODEL_REGISTRY_EVALUATOR": override}):
                with self.assertRaisesRegex(registry.CatalogError, "CPI_MODEL_REGISTRY_EVALUATOR"):
                    registry.load()

    def test_writer_rejects_inexact_context_before_replacing_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "models.lua"
            target.write_bytes(b"existing catalog")
            value = catalog()
            for integer in (2**53, 2**53 + 1):
                value["providers"][0]["models"][0]["context_window"] = integer
                with self.subTest(integer=integer), self.assertRaises(registry.CatalogError):
                    registry.write_atomic(target, value)
                self.assertEqual(target.read_bytes(), b"existing catalog")

    def test_evaluator_subprocess_deadline_and_diagnostics(self):
        # The trusted Python fixture exercises subprocess transport, not Lua evaluation.
        cases = (
            ('print(\'{"version":1,"providers":[]}\')', None),
            ('import sys; print("rejected config", file=sys.stderr); sys.exit(7)', "rejected config"),
            ('import time; time.sleep(60)', "timeout"),
        )
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "evaluator_fixture.py"
            with patch.dict(registry.os.environ, {"CPI_MODEL_REGISTRY_EVALUATOR": sys.executable}), \
                    patch.object(registry, "EVALUATOR_TIMEOUT", 1):
                for program, failure in cases:
                    with self.subTest(failure=failure):
                        fixture.write_text(program, encoding="utf-8")
                        if failure is None:
                            self.assertEqual(registry.load(fixture), {"version": 2, "providers": []})
                        else:
                            with self.assertRaisesRegex(registry.CatalogError, failure):
                                registry.load(fixture)

    def test_strict_schema_rejects_unknown_fields_and_malformed_values(self):
        cases = []
        for location in ("root", "provider", "model", "pricing"):
            value = catalog()
            objects = {"root": value, "provider": value["providers"][0],
                       "model": value["providers"][0]["models"][0],
                       "pricing": value["providers"][0]["models"][0]["pricing"]}
            objects[location]["unexpected"] = 1
            cases.append((f"unknown-{location}", value))
        for key, values in {
            "context_window": [0, -1, 2**53, 2**53 + 1, 2**64, True, 3.5, "8192"],
            "max_output_tokens": [0, 2**32, False],
            "pricing": [None, {"input": -0.1}, {"input": float("inf")},
                        {"input": float("nan")}, {"input": True}, {"output": "1.0"}],
            "source_url": [2], "name": [None, "", "\ud800"], "api": [2, False, "\ud800"],
        }.items():
            for invalid in values:
                value = catalog()
                value["providers"][0]["models"][0][key] = invalid
                cases.append((f"model-{key}-{invalid}", value))
        for key, invalid in (("version", True), ("version", 3), ("providers", {})):
            value = catalog()
            value[key] = invalid
            cases.append((f"root-{key}", value))
        for key, invalid in (("api", None), ("retrieved_at", 123), ("models", {})):
            value = catalog()
            value["providers"][0][key] = invalid
            cases.append((f"provider-{key}", value))
        for location, key in (("provider", "id"), ("provider", "api"), ("model", "id"), ("model", "api")):
            for invalid in ("", "has space", "has\t tab", "has\nnewline", "has\x00nul",
                            "has\x1fcontrol", "has\x7fdelete"):
                value = catalog()
                target = value["providers"][0]
                if location == "model":
                    target = target["models"][0]
                target[key] = invalid
                cases.append((f"{location}-{key}-{invalid!r}", value))
        value = catalog()
        value["providers"][0]["name"] = ""
        cases.append(("empty-provider-name", value))
        value = catalog()
        del value["providers"][0]["api_key_env"]
        cases.append(("missing-required", value))
        for name, value in cases:
            with self.subTest(name=name), self.assertRaises(registry.CatalogError):
                registry.validate(value)

    def test_duplicate_identity_scopes_and_provider_pricing(self):
        normalized = registry.validate(catalog())
        self.assertEqual(registry.find_model(normalized, "seller-a", "shared/model")["pricing"]["input"], 0.7)
        self.assertEqual(registry.find_model(normalized, "seller-b", "shared/model")["pricing"]["input"], 2.1)
        with self.assertRaises(KeyError):
            registry.find_model(normalized, "shared", "shared/model")
        for duplicate_provider in (True, False):
            value = catalog()
            if duplicate_provider:
                value["providers"].append(copy.deepcopy(value["providers"][0]))
            else:
                value["providers"][0]["models"].append(copy.deepcopy(value["providers"][0]["models"][0]))
            with self.subTest(provider=duplicate_provider), self.assertRaisesRegex(registry.CatalogError, "duplicate"):
                registry.validate(value)

    def test_json_parser_rejects_duplicates_nonfinite_and_non_utf8(self):
        for raw in (b'{"version":1,"version":1,"providers":[]}', b'{"value":NaN}',
                    b'{"value":Infinity}', b'\xff', b'{"providers":['):
            with self.subTest(raw=raw), self.assertRaises(registry.CatalogError):
                registry.decode(raw)

    def test_models_dev_conversion_keeps_seller_prices_and_unknowns(self):
        converted = registry.convert_snapshot("models.dev", models_dev(), retrieved_at="2026-11-06T00:00:00Z")
        a = registry.find_model(converted, "seller-a", "same")
        b = registry.find_model(converted, "seller-b", "same")
        self.assertEqual(a["pricing"]["input"], 0.5)
        self.assertIsNone(a["pricing"]["output"])
        self.assertIsNone(a["context_window"])
        self.assertEqual(b["pricing"], {"input": 2.75, "output": 0, "cache_read": 0.25, "cache_write": 3.5})
        self.assertEqual((b["context_window"], b["max_output_tokens"]), (8192, 1234))
        self.assertNotIn("api", converted["providers"][1])
        self.assertEqual(converted["providers"][1]["api_key_env"], "B_KEY")
        self.assertEqual(converted["providers"][0]["retrieved_at"], "2026-11-06T00:00:00Z")
        self.assertEqual(a["source_url"], "https://models.dev/api.json")

    def test_openrouter_conversion_units_sentinels_and_optional_fields(self):
        snapshot = {"data": [
            {"id": "publisher/paid", "name": "Paid", "context_length": 98304,
             "top_provider": {"max_completion_tokens": 6789},
             "pricing": {"prompt": "0.0000004", "completion": "0.0000016",
                         "input_cache_read": "0.0000001", "input_cache_write": "0.0000006",
                         "request": "0.5", "image": "9"}},
            {"id": "router", "name": "Variable", "pricing": {"prompt": "-1", "completion": "-1"}},
            {"id": "free", "name": "Free", "pricing": {"prompt": "0", "completion": "0"}},
        ]}
        converted = registry.convert_snapshot("openrouter", snapshot)
        paid = registry.find_model(converted, "openrouter", "publisher/paid")
        self.assertEqual(paid["pricing"], {"input": 0.4, "output": 1.6, "cache_read": 0.1, "cache_write": 0.6})
        self.assertEqual((paid["context_window"], paid["max_output_tokens"]), (98304, 6789))
        self.assertIsNone(registry.find_model(converted, "openrouter", "router")["pricing"]["input"])
        self.assertEqual(registry.find_model(converted, "openrouter", "free")["pricing"]["input"], 0)
        self.assertIsNone(registry.find_model(converted, "openrouter", "free")["pricing"]["cache_read"])
        self.assertIsNone(converted["providers"][0]["retrieved_at"])
        self.assertNotIn("api", converted["providers"][0])

    def test_malformed_sources_fail_instead_of_supplying_fake_values(self):
        cases: list[tuple[str, Any]] = [("openrouter", {"data": {}}), ("models.dev", {"a": {"id": "b", "name": "B", "models": {}}})]
        for value in ("garbage", "NaN", "-0.4", True, "1e999999", "1e-999999"):
            cases.append(("openrouter", {"data": [{"id": "a", "name": "A", "pricing": {"prompt": value}}]}))
        for source, snapshot in cases:
            with self.subTest(source=source, snapshot=snapshot), self.assertRaises(registry.CatalogError):
                registry.convert_snapshot(source, snapshot)
        for kwargs in ({"provider_ids": ["absent"]}, {"model_ids": ["absent"]}):
            with self.subTest(kwargs=kwargs), self.assertRaises(registry.CatalogError):
                registry.convert_snapshot("models.dev", models_dev(), **kwargs)

    def test_cli_offline_fetch_query_and_exact_scoped_show(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "snapshot.json"
            target = Path(directory) / "models.lua"
            source.write_text(json.dumps(models_dev()), encoding="utf-8")
            def run(*args):
                return subprocess.run([sys.executable, str(Path(registry.__file__)), *args], capture_output=True, text=True)
            fetched = run("fetch", "models.dev", "--input", str(source), "--output", str(target),
                          "--provider", "seller-b", "--model", "same")
            self.assertEqual(fetched.returncode, 0, fetched.stderr)
            stdout_candidate = run("fetch", "models.dev", "--input", str(source),
                                   "--provider", "seller-b", "--model", "same")
            self.assertEqual(stdout_candidate.returncode, 0, stdout_candidate.stderr)
            self.assertEqual(stdout_candidate.stdout, target.read_text(encoding="utf-8"))
            self.assertEqual([p["id"] for p in registry.load(target)["providers"]], ["seller-b"])
            listing = run("list", "--config", str(target), "--provider", "seller-b", "--query", "sHaReD")
            self.assertEqual(listing.returncode, 0, listing.stderr)
            self.assertEqual([(row["provider_id"], row["model"]["id"]) for row in json.loads(listing.stdout)], [("seller-b", "same")])
            self.assertEqual(json.loads(run("list", "--config", str(target), "--query", ".*").stdout), [])
            shown = run("show", "--config", str(target), "seller-b", "same")
            self.assertEqual(json.loads(shown.stdout)["model"]["pricing"]["input"], 2.75)
            self.assertNotEqual(run("show", "--config", str(target), "seller-a", "same").returncode, 0)
            checked = run("validate", "--config", str(target))
            self.assertEqual(json.loads(checked.stdout)["models"], 1)

    def test_failed_fetch_preserves_existing_target_for_read_parse_and_conversion_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "snapshot.json"
            target = Path(directory) / "models.lua"
            target.write_bytes(b"previous configuration\n")
            for contents in (None, b"{", b'{"data":[{"id":"x","name":"X","pricing":{"prompt":"oops"}}]}'):
                if contents is not None:
                    source.write_bytes(contents)
                with redirect_stderr(io.StringIO()):
                    status = registry.main(["fetch", "openrouter", "--input", str(source), "--output", str(target)])
                self.assertEqual(status, 1)
                self.assertEqual(target.read_bytes(), b"previous configuration\n")
            self.assertEqual(sorted(path.name for path in Path(directory).iterdir()), ["models.lua", "snapshot.json"])

    def test_atomic_replace_failure_cleans_temporary_and_preserves_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "models.lua"
            target.write_bytes(b"original")
            with patch.object(registry.os, "replace", side_effect=OSError("simulated filesystem refusal")):
                with self.assertRaises(OSError):
                    registry.write_atomic(target, catalog())
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(Path(directory).iterdir()), [target])
            bad = catalog()
            bad["version"] = 9
            with self.assertRaises(registry.CatalogError):
                registry.write_atomic(target, bad)
            self.assertEqual(target.read_bytes(), b"original")

    def test_network_failure_preserves_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "models.lua"
            target.write_bytes(b"original")
            for error in (TimeoutError("socket timed out"), OSError("connection refused")):
                with patch.object(registry.urllib.request.OpenerDirector, "open", side_effect=error), redirect_stderr(io.StringIO()):
                    status = registry.main(["fetch", "openrouter", "--output", str(target)])
                self.assertEqual(status, 1)
                self.assertEqual(target.read_bytes(), b"original")
        for timeout in (0, -1, 61, float("nan")):
            with self.subTest(timeout=timeout), self.assertRaises(registry.CatalogError):
                registry.download("models.dev", timeout=timeout)

    def test_openrouter_protocol_claims_require_explicit_supported_endpoints(self):
        cases = [
            ("anthropic/future-model-2099", ["/api/v1/chat/completions", "/api/v1/responses"], "openai-responses"),
            ("openai/future-model-2099", ["/api/v1/messages"], "anthropic-messages"),
            ("google/novel-model", ["/api/v1/chat/completions"], "openai-chat"),
            ("openai/gpt-4.1-mini", ["/api/v1/embeddings"], None),
            ("openai/gpt-6.1-sol", [], None),
        ]
        raw = {"data": [{"id": identifier, "name": identifier, "endpoints": endpoints}
                        for identifier, endpoints, _ in cases]}
        converted = registry.convert_snapshot("openrouter", raw)
        for identifier, _, expected in cases:
            with self.subTest(identifier=identifier):
                self.assertEqual(registry.find_model(converted, "openrouter", identifier)["transports"],
                                 [p for route, p in (("/api/v1/responses", "openai-responses"), ("/api/v1/chat/completions", "openai-chat"), ("/api/v1/messages", "anthropic-messages")) if route in next(e for i, e, _ in cases if i == identifier)])
        self.assertNotIn("api", converted["providers"][0])
        for endpoints in (None, "responses", [2]):
            with self.subTest(endpoints=endpoints), self.assertRaises(registry.CatalogError):
                registry.convert_snapshot("openrouter", {"data": [{"id": "x", "name": "X", "endpoints": endpoints}]})

    def test_complete_offline_refresh_keeps_novel_ids_and_authoritative_seller_prices(self):
        direct = models_dev()
        direct["seller-a"]["models"].update({
            identifier: {"id": identifier, "name": identifier, "cost": {"input": price}}
            for identifier, price in (("arbitrary-next-2099", 8), ("image-new", 3), ("embedding-new", 0.01))
        })
        direct["openai"] = {"id": "openai", "name": "OpenAI", "npm": "@ai-sdk/openai", "models": {
            "gpt-future-2099": {"id": "gpt-future-2099", "name": "Future"}}}
        direct["brand-new-provider"] = {"id": "brand-new-provider", "name": "New", "models": {
            "brand-new-model": {"id": "brand-new-model", "name": "New"}}}
        direct["empty-provider"] = {"id": "empty-provider", "name": "Empty provider", "models": {}}
        direct["openrouter"] = {"id": "openrouter", "name": "Stale mirror", "models": {
            "same": {"id": "same", "name": "Wrong price", "cost": {"input": 900, "output": 800}},
            "mirror-only": {"id": "mirror-only", "name": "Mirror only"}}}
        routed = {"data": [{"id": "same", "name": "Official offer", "pricing": {"prompt": "0.000003"},
                            "endpoints": ["/api/v1/chat/completions", "/api/v1/responses"]},
                           {"id": "brand-new/arbitrary-2099", "name": "New routed offer"}]}
        overlay = [{"provider_id": "seller-a", "model_id": "same", "api": "openai-chat",
                    "reference_url": "https://example.com/docs/same", "reviewed_at": "2099-01-01"}]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for filename, contents in (("direct.json", direct), ("router.json", routed), ("overlay.json", overlay)):
                (directory / filename).write_text(json.dumps(contents), encoding="utf-8")
            target = directory / "models.lua"
            command = [sys.executable, str(Path(registry.__file__)), "refresh",
                       "--models-dev-input", str(directory / "direct.json"),
                       "--openrouter-input", str(directory / "router.json"),
                       "--models-dev-retrieved-at", "2099-02-03T01:02:03Z",
                       "--openrouter-retrieved-at", "2099-02-04T04:05:06Z",
                       "--api-overlay", str(directory / "overlay.json"), "--output", str(target)]
            completed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            actual = registry.load(target)
            self.assertEqual({p["id"] for p in actual["providers"]}, set(direct) | {"deepseek", "openai-codex"})
            import first_party
            primary = first_party.convert(registry.read_snapshot(first_party.RAW))
            expected_ids = {(pid, mid) for pid, p in direct.items() if pid not in ("openrouter", "openai", "deepseek", "openai-codex") for mid in p["models"]}
            expected_ids.update((p["id"], m["id"]) for p in primary["providers"] for m in p["models"])
            expected_ids.update(("openrouter", m["id"]) for m in routed["data"])
            self.assertEqual({(p["id"], m["id"]) for p, m in registry.iter_models(actual)}, expected_ids)
            self.assertEqual(registry.find_model(actual, "seller-a", "same")["pricing"]["input"], 0.5)
            self.assertEqual(registry.find_model(actual, "seller-b", "same")["pricing"]["input"], 2.75)
            official = registry.find_model(actual, "openrouter", "same")
            self.assertEqual(official["pricing"]["input"], 3)
            self.assertIsNone(official["pricing"]["output"])
            self.assertEqual(official["transports"], ["openai-responses", "openai-chat"])
            for p, m in registry.iter_models(actual):
                self.assertNotIn("api", p)
                if p["id"] == "openrouter":
                    self.assertEqual(p["retrieved_at"], "2099-02-04T04:05:06Z")
                    self.assertEqual(m["source_url"], registry.SOURCES["openrouter"])
                elif p["id"] not in ("openai", "deepseek", "openai-codex"):
                    self.assertEqual(p["retrieved_at"], "2099-02-03T01:02:03Z")
                    self.assertEqual(m["source_url"], registry.SOURCES["models.dev"])
                if (p["id"], m["id"]) == ("seller-a", "same"):
                    self.assertEqual(m["transports"], ["openai-chat"])
                elif p["id"] not in ("openai", "deepseek", "openai-codex") and (p["id"] != "openrouter" or m["id"] != "same"):
                    self.assertEqual(m["transports"], [])
            before = target.read_bytes()
            repeated = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertEqual(target.read_bytes(), before)

    def test_overlay_warns_for_stale_ids_and_rejects_ambiguous_claims(self):
        entry = {"provider_id": "seller-a", "model_id": "shared/model", "api": "openai-responses",
                 "reference_url": "https://example.com/docs", "reviewed_at": "2099-01-01"}
        stale = dict(entry, model_id="removed-model")
        warnings = io.StringIO()
        with redirect_stderr(warnings):
            updated = registry.apply_api_overlay(catalog(), [entry, stale])
        self.assertTrue(warnings.getvalue())
        self.assertEqual({(p["id"], m["id"]) for p, m in registry.iter_models(updated)},
                         {("seller-a", "shared/model"), ("seller-b", "shared/model")})
        self.assertEqual(registry.find_model(updated, "seller-a", "shared/model")["transports"], ["openai-responses"])
        self.assertEqual(registry.find_model(updated, "seller-b", "shared/model")["transports"], [])
        for entries in ([entry, entry], [dict(entry, reference_url="")], [dict(entry, api="has space")]):
            with self.subTest(entries=entries), self.assertRaises(registry.CatalogError):
                registry.apply_api_overlay(catalog(), entries)
        routed = registry.convert_snapshot("openrouter", {"data": [{"id": "shared/model", "name": "Shared",
                                                                  "endpoints": ["/api/v1/messages"]}]})
        with self.assertRaisesRegex(registry.CatalogError, "contradicts"):
            registry.apply_api_overlay(routed, [dict(entry, provider_id="openrouter")])

    def test_refresh_failure_in_either_source_or_overlay_preserves_existing_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            target = directory / "models.lua"
            overlay = directory / "overlay.json"
            overlay.write_text("[]", encoding="utf-8")
            source = directory / "source.json"
            source.write_text(json.dumps(models_dev()), encoding="utf-8")
            target.write_bytes(b"existing catalog")
            command = ["refresh", "--models-dev-input", str(source),
                       "--models-dev-retrieved-at", "2099-01-01T00:00:00Z",
                       "--api-overlay", str(overlay), "--output", str(target)]
            for second in (OSError("source unavailable"), {"data": []}, {"data": [{"id": "x", "name": "X",
                                                                                "pricing": {"prompt": "oops"}}]}):
                with self.subTest(second=second):
                    kwargs: dict[str, Any] = {"side_effect": second} if isinstance(second, Exception) else {"return_value": second}
                    with patch.object(registry, "download", **kwargs), redirect_stderr(io.StringIO()):
                        self.assertEqual(registry.main(command), 1)
                    self.assertEqual(target.read_bytes(), b"existing catalog")
            with patch.object(registry, "download", side_effect=OSError("first source unavailable")), redirect_stderr(io.StringIO()):
                self.assertEqual(registry.main(["refresh", "--output", str(target)]), 1)
            self.assertEqual(target.read_bytes(), b"existing catalog")
            overlay.write_text("{", encoding="utf-8")
            with patch.object(registry, "download", return_value={"data": [{"id": "x", "name": "X"}]}), redirect_stderr(io.StringIO()):
                self.assertEqual(registry.main(command), 1)
            self.assertEqual(target.read_bytes(), b"existing catalog")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(registry.main(["refresh", "--models-dev-input", str(source), "--output", str(target)]), 1)
            self.assertEqual(target.read_bytes(), b"existing catalog")
            self.assertEqual({p.name for p in directory.iterdir()}, {"models.lua", "overlay.json", "source.json"})

    def assert_first_party_projection(self, catalog):
        import first_party
        reference = registry.validate(first_party.convert(registry.read_snapshot(first_party.RAW)))
        for provider in reference["providers"]:
            actual = next(p for p in catalog["providers"] if p["id"] == provider["id"])
            self.assertEqual(actual, provider)

    def test_first_party_projection_rejects_the_real_historical_aggregator_catalog(self):
        import gzip
        import hashlib
        fixture = Path(__file__).resolve().parent / "fixtures" / "aggregator-models.lua.gz"
        historical = gzip.decompress(fixture.read_bytes())
        self.assertEqual(hashlib.sha256(historical).hexdigest(),
                         "ab728360ec14f4e4d659fb304b87eb62111c1edd1c14807a2d2c337811029a20")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "historical.lua"
            path.write_bytes(historical)
            old = registry.load(path)
        with self.assertRaises(AssertionError):
            self.assert_first_party_projection(old)
        self.assert_first_party_projection(registry.load())

    def test_first_party_documents_keep_every_declared_transport_and_current_deepseek_limits(self):
        import first_party
        bundle = registry.read_snapshot(first_party.RAW)
        catalog = registry.validate(first_party.convert(bundle))
        for identifier in ("gpt-5.6", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra"):
            model = registry.find_model(catalog, "openai", identifier)
            self.assertEqual(model["transports"], ["openai-responses", "openai-chat"])
            self.assertEqual(model["context_window"], 1050000)
            self.assertNotIn("models.dev", model["source_url"])
        for identifier in ("deepseek-flash", "deepseek-v4-pro"):
            model = registry.find_model(catalog, "deepseek", identifier)
            self.assertEqual(model["context_window"], 1048576)
            self.assertEqual(model["max_output_tokens"], 393216)
            self.assertEqual(model["reasoning_efforts"], ["none", "low", "high", "max"])
            self.assertIn("api.deepseek.com", model["source_url"])
        self.assertEqual(bundle["api"]["openai-codex"]["source_url"],
                         "https://chatgpt.com/backend-api/codex/models?client_version=" + first_party.CODEX_CLIENT_VERSION)
        for identifier in ("gpt-6.1-sol", "gpt-6.1-terra"):
            self.assertIn("openai-codex-responses", registry.find_model(catalog, "openai-codex", identifier)["transports"])
        subscription = registry.find_model(catalog, "openai-codex", "gpt-5.6-sol")
        self.assertEqual(subscription["transports"], ["openai-codex-responses"])
        self.assertEqual(subscription["context_window"], 272000)
        self.assertIn("ultra", subscription["reasoning_efforts"])
        # A novel exact model page needs no family allowlist or protocol overlay.
        novel = "https://developers.openai.com/api/docs/models/novel-2099.md"
        bundle["pages"][novel] = "# Novel\n\nModel ID: `novel-2099`\n\n| Responses | `v1/responses` | Supported |\n"
        updated = registry.validate(first_party.convert(bundle))
        self.assertEqual(registry.find_model(updated, "openai", "novel-2099")["transports"], ["openai-responses"])
        bundle["pages"][novel] = bundle["pages"][novel].replace("| Supported |", "| Not supported |")
        updated = registry.validate(first_party.convert(bundle))
        self.assertEqual(registry.find_model(updated, "openai", "novel-2099")["transports"], [])
        bundle["api"]["deepseek"]["models"][0]["id"] = "deepseek-new-2099"
        with self.assertRaisesRegex(ValueError, "Responses declaration"):
            first_party.convert(bundle)
        # Unknown model/transport relationships are rejected, never guessed.

    def test_v2_cannot_express_provider_transport_inheritance(self):
        value = {"version": 2, "providers": [{"id": "p", "name": "P", "base_url": "", "api_key_env": "",
                 "models": [{"id": "text", "name": "Text", "transports": ["openai-responses", "openai-chat"]},
                            {"id": "embedding", "name": "Embedding", "transports": ["openai-embeddings"]}]}]}
        normalized = registry.validate(value)
        self.assertNotIn("openai-responses", normalized["providers"][0]["models"][0]["transports"])
        # Stable sorting puts the embedding first, without inheriting text support.
        value["providers"][0]["api"] = "openai-responses"
        with self.assertRaisesRegex(registry.CatalogError, "unknown fields"):
            registry.validate(value)

    def test_bundled_catalog_loads_and_keeps_multiple_sellers(self):
        bundled = registry.load()
        self.assertGreaterEqual(len(bundled["providers"]), 235)
        self.assertGreater(sum(len(p["models"]) for p in bundled["providers"]), 9000)
        for provider in bundled["providers"]:
            self.assertTrue(provider["source_url"].startswith("https://"))
            self.assertIsNotNone(provider["retrieved_at"])
        direct = registry.find_model(bundled, "openai", "gpt-4.1-mini")
        routed = registry.find_model(bundled, "openrouter", "openai/gpt-4.1-mini")
        self.assertIsNot(direct, routed)
        self.assertIsNot(direct["pricing"], routed["pricing"])


if __name__ == "__main__":
    unittest.main()
