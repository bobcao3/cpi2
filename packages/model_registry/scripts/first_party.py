"""First-party catalog acquisition. No inference calls or aggregator metadata.

The raw bundle is retained so conversion is reproducible and schema drift can
fail before replacing installed data. API keys are never read by maintenance.
Account-specific /models discovery belongs to the shared runtime discovery API.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import re
import urllib.request
import urllib.parse
import warnings
from pathlib import Path

DATA = Path(__file__).resolve().parents[1] / "data"
RAW = DATA / "first_party_sources.json"
CODEX_CLIENT_VERSION = (DATA / "codex_client_version.txt").read_text().strip()
OPENAI = "https://developers.openai.com/api/docs/models/"
DEEPSEEK = "https://api-docs.deepseek.com/"
MAX_BYTES = 32 * 1024 * 1024


class SameHost(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if (new.scheme != "https" or old.hostname != new.hostname or new.port not in (None, 443)
                or new.username or new.password):
            raise ValueError("first-party redirect left HTTPS source host")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def read_source(response, measurement):
    raw = response.read()
    if len(raw) > MAX_BYTES:
        warnings.warn(f"{measurement} is {len(raw)}, above the expected {MAX_BYTES}", RuntimeWarning, stacklevel=2)
    return raw


def fetch(url):
    if not (url.startswith(OPENAI) or url.startswith(DEEPSEEK)):
        raise ValueError(f"not a first-party documentation URL: {url}")
    with urllib.request.build_opener(SameHost()).open(url, timeout=20) as response:
        raw = read_source(response, "first-party document bytes")
    return raw.decode("utf-8")


def acquire_api(auth_path):
    """Explicit credentialed GETs only; retain a metadata whitelist, never tokens."""
    auth = json.loads(Path(auth_path).read_text())
    endpoints = {"openai": "https://api.openai.com/v1/models",
                 "deepseek": "https://api.deepseek.com/models",
                 "openai-codex": "https://chatgpt.com/backend-api/codex/models?client_version=" + CODEX_CLIENT_VERSION}
    keys = {"id", "slug", "name", "display_name", "context_window", "max_output_tokens",
            "effort", "supported_reasoning_levels", "visibility"}
    result = {}
    for service, url in endpoints.items():
        if service not in auth:
            continue
        credential = auth[service]
        token = credential.get("access") if service == "openai-codex" else credential.get("key")
        if not token:
            raise ValueError(f"{service}: credential has no usable token")
        headers = {"Authorization": "Bearer " + token}
        if service == "openai-codex":
            headers["ChatGPT-Account-Id"] = credential["accountId"]
        # No redirects may forward Authorization to any endpoint.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                raise ValueError("authenticated model discovery redirected")
        with urllib.request.build_opener(NoRedirect()).open(urllib.request.Request(url, headers=headers), timeout=20) as response:
            raw = read_source(response, "first-party model list bytes")
        body = json.loads(raw)
        rows = body["models" if service == "openai-codex" else "data"]
        result[service] = {"source_url": url, "models": [{k: v for k, v in row.items() if k in keys} for row in rows]}
    return result


def acquire():
    index = fetch(OPENAI + "all.md")
    slugs = sorted(set(re.findall(r"/api/docs/models/([a-zA-Z0-9._-]+?)(?:\.md)?[)#]", index)))
    slugs = [slug for slug in slugs if slug not in ("all", "compare")]
    if not slugs:
        raise ValueError("OpenAI model index contains no model pages")
    urls = [OPENAI + slug + ".md" for slug in slugs]
    urls += [DEEPSEEK + "api/list-models.md", DEEPSEEK + "api/create-response.md",
             DEEPSEEK + "quick_start/pricing.md"]
    with ThreadPoolExecutor(max_workers=6) as pool:
        pages = dict(zip(urls, pool.map(fetch, urls)))
    pages[OPENAI + "all.md"] = index
    return {"retrieved_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "pages": pages}


def openai_models(pages):
    models = {}
    routes = {"v1/responses": "openai-responses", "v1/chat/completions": "openai-chat",
              "v1/embeddings": "openai-embeddings", "v1/images/generations": "openai-images",
              "v1/realtime": "openai-realtime", "v1/audio/speech": "openai-audio"}
    for url, page in sorted(pages.items()):
        if not url.startswith(OPENAI) or url.endswith("/all.md"):
            continue
        identity = re.search(r"Model ID:\s*`([^`]+)`", page)
        if not identity:
            raise ValueError(f"OpenAI page has no explicit Model ID: {url}")
        identifier = identity[1]
        transports = [protocol for route, protocol in routes.items()
                      if re.search(r"\|\s*`" + re.escape(route) + r"`\s*\|\s*Supported\s*\|", page)]
        model = {"id": identifier, "name": page.splitlines()[0].lstrip("# "),
                 "transports": transports, "source_url": url, "pricing": {}}
        for label, key in (("context window", "context_window"), ("max output tokens", "max_output_tokens")):
            match = re.search(r"([\d,]+)\s+" + label, page, re.I)
            if match:
                model[key] = int(match[1].replace(",", ""))
        effort = re.search(r"reasoning\.effort(?:\s+supports)?\s*:?\s*([^\n.]*(?:\n(?!\n)[^\n.]*)*)", page.replace("`", ""), re.I)
        if effort:
            model["reasoning_efforts"] = re.findall(r"\b(none|minimal|low|medium|high|xhigh|max)\b", re.sub(r"\([^)]*\)", "", effort[1]))
        elif re.search(r"\bnon-reasoning\b", page, re.I):
            model["reasoning_efforts"] = ["off"]
        for label, key in (("Input", "input"), ("Cached input", "cache_read"), ("Cache writes", "cache_write"), ("Output", "output")):
            match = re.search(r"\|\s*" + label + r"\s*\|\s*\$([\d.]+)\s*\|\s*1M tokens\s*\|", page)
            if match:
                model["pricing"][key] = float(match[1])
        models[identifier] = model
        section = page.split("## Snapshots", 1)
        if len(section) == 2:
            snapshots = section[1].split("\n## ", 1)[0]
            for alias in re.findall(r"^- `([^`]+)`", snapshots, re.M):
                models.setdefault(alias, dict(model, id=alias))
        for alias in re.findall(r"The `([^`]+)` alias routes requests to", page):
            models.setdefault(alias, dict(model, id=alias))
    if not models:
        raise ValueError("empty first-party OpenAI catalog")
    return sorted(models.values(), key=lambda m: m["id"])


def convert(bundle):
    pages = bundle["pages"]
    url = DEEPSEEK + "api/list-models.md"
    examples = re.findall(r"```json\s*\n(.*?)\n```", pages[url], re.S)
    lists = [json.loads(raw) for raw in examples if '"data"' in raw]
    if len(lists) != 1 or not lists[0].get("data"):
        raise ValueError("DeepSeek list-models documentation schema changed")
    response_doc = pages[DEEPSEEK + "api/create-response.md"]
    declared = re.search(r'`enum`: `\[("deepseek[^\n]+?)\]`', response_doc)
    if not declared:
        raise ValueError("DeepSeek Responses model enum missing")
    response_models = json.loads("[" + declared[1] + "]")
    api = bundle.get("api", {})
    deepseek = api.get("deepseek")
    if deepseek:
        url = deepseek["source_url"]
    models = []
    for raw in (deepseek["models"] if deepseek else lists[0]["data"]):
        if raw["id"] not in response_models:
            raise ValueError("DeepSeek model has no first-party Responses declaration")
        efforts = raw.get("effort", {}).get("supported_levels", [])
        models.append({"id": raw["id"], "name": raw.get("name", raw["id"]),
                       "context_window": raw.get("context_window"), "max_output_tokens": raw.get("max_output_tokens"),
                       "reasoning_efforts": ["none", *efforts],
                       "transports": ["openai-responses", "openai-chat", "anthropic-messages"],
                       "pricing": {}, "source_url": url})
    public = {m["id"]: m for m in openai_models(pages)}
    if "openai" in api:
        for m in api["openai"]["models"]:
            public.setdefault(m["id"], {"id": m["id"], "name": m["id"], "transports": [],
                                         "source_url": api["openai"]["source_url"]})
    providers = [
        {"id": "openai", "name": "OpenAI", "base_url": "https://api.openai.com/v1",
         "api_key_env": "OPENAI_API_KEY", "source_url": OPENAI + "all.md",
         "retrieved_at": bundle.get("openai_docs_retrieved_at", bundle["retrieved_at"]), "models": list(public.values())},
        {"id": "deepseek", "name": "DeepSeek", "base_url": "https://api.deepseek.com",
         "api_key_env": "DEEPSEEK_API_KEY", "source_url": url,
         "retrieved_at": bundle["retrieved_at"], "models": models},
    ]
    if "openai-codex" in api:
        source = api["openai-codex"]
        providers.append({"id": "openai-codex", "name": "OpenAI subscription", "base_url": "https://chatgpt.com/backend-api/codex",
                          "api_key_env": "OPENAI_ACCESS_TOKEN", "retrieved_at": source.get("retrieved_at", bundle["retrieved_at"]), "source_url": source["source_url"],
                          "models": [{"id": m["slug"], "name": m.get("display_name", m["slug"]),
                                      "context_window": m.get("context_window"), "max_output_tokens": m.get("max_output_tokens"),
                                      "transports": ["openai-codex-responses"], "source_url": source["source_url"],
                                      "reasoning_efforts": [level["effort"] for level in m.get("supported_reasoning_levels", [])]}
                                     for m in source["models"] if m.get("visibility", "list") == "list"]})
    return {"version": 2, "providers": providers}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--acquire", action="store_true", help="download first-party docs instead of replaying captured inputs")
    parser.add_argument("--input", type=Path, default=RAW)
    parser.add_argument("--auth", type=Path, help="explicitly authorize first-party model-list GETs with a Pi auth file")
    args = parser.parse_args()
    bundle = acquire() if args.acquire else json.loads(args.input.read_text())
    if args.auth:
        bundle["api"] = acquire_api(args.auth)
        bundle["retrieved_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    import model_registry
    catalog = model_registry.validate(convert(bundle))
    if args.acquire or args.auth:
        model_registry.write_text_atomic(args.input, json.dumps(bundle, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(catalog, ensure_ascii=False, indent=2))
