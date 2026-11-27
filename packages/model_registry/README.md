# Shared model catalog and provider selection

The catalog describes what each provider offers. A harness still picks the
route, keys, and user interface. Do not guess support from a model name. See
[catalog types](model.zig), [selection](selection.zig), and
[live discovery](discovery.zig) for the shared APIs.

## Version 2

A sandboxed Lua 5.1+ chunk returns this shape:

```lua
return {
  version = 2,
  providers = {{
    id = "example", name = "Example",
    base_url = "https://example.test/v1", api_key_env = "EXAMPLE_API_KEY",
    models = {{
      id = "example-model", name = "Example model",
      transports = {"openai-responses", "openai-chat"},
      context_window = 128 * 1024, max_output_tokens = 8192,
      reasoning_efforts = {"none", "low", "high"},
      pricing = {input = 0.5, output = 0},
    }},
  }},
}
```

| Object       | Required                                                | Optional/default                                                                                                                 |
| ------------ | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Root         | `version = 2`, `providers` array                        | —                                                                                                                                |
| Provider     | `id`, `name`, `base_url`, `api_key_env`, `models` array | `source_url`, `retrieved_at`                                                                                                     |
| Model        | `id`, `name`                                            | `transports = {}`, `reasoning_efforts = {}`, `context_window`, `max_output_tokens`, `source_url`, `pricing = {}`, `image_resize` |
| Pricing      | —                                                       | `input`, `output`, `cache_read`, `cache_write`                                                                                   |
| Image resize | —                                                       | `max_width`, `max_height`, `max_bytes`, `jpeg_quality`                                                                           |

An image resize profile can specify any subset of its fields. Width and height
are positive pixel limits, `max_bytes` is an exclusive limit on the base64
payload length, and `jpeg_quality` is an integer from 1 to 100. Consumers supply
their defaults for omitted fields.

Each model lists its transports. Providers have no transport default. An empty
list means unknown, not OpenAI support. A catalog entry does not give an account
access or add a transport to a harness.

Efforts come from the source. `none` is sent on the wire; `off` means leave the
reasoning field out. Prices use USD per million tokens. Missing means unknown;
zero means free. Tiered rates do not fit these fields.

The [loader](runtime/ConfigBuilder.zig) owns schema checks and warnings. Large
inputs may warn without failing. Bad shapes and cycles still fail.

### Legacy input

Version 1 may set a provider API, with a model override. The loader copies the
effective API to each model. `unknown` becomes an empty list. Version 2 reads no
legacy API fields. All writes use version 2.

## First-party ground truth

[`data/first_party_sources.json`](data/first_party_sources.json) retains:

- OpenAI's complete model documentation index and linked model pages, including
  explicit model IDs, snapshots/aliases, supported endpoint tables, limits,
  effort declarations, and pricing;
- DeepSeek's model-list/Responses/pricing documentation and authenticated
  `/models` metadata;
- a metadata-only capture of the authenticated OpenAI subscription/Codex model
  list. Hidden offers are excluded from picker data.

A paid subscription and a public API offer are separate, even for the same model
ID. Do not fill gaps from the other offer. Direct sources win over aggregators;
OpenRouter data describes OpenRouter offers only.

The saved subscription list shows one account's view. Client version can filter
it. Use the [pinned version](data/codex_client_version.txt), not a placeholder.
A missing entry does not prove lack of access. The
[saved data](data/first_party_sources.json) holds the evidence and exact values.

### Capture and refresh

Replay the retained input without network access:

```sh
python3 -B packages/model_registry/scripts/first_party.py
```

Explicitly acquire public docs, optionally including authenticated model lists:

```sh
python3 -B packages/model_registry/scripts/first_party.py --acquire
python3 -B packages/model_registry/scripts/first_party.py --acquire \
  --auth "$HOME/.pi/agent/auth.json"
```

`--auth` explicitly authorizes GETs to the fixed first-party model-list
endpoints. Only a metadata whitelist is retained: no tokens, refresh tokens,
account IDs, instructions, or other account fields. It makes no inference
requests, follows no authenticated redirects, and does not refresh OAuth tokens.
Absent credentials skip that API; HTTP/authentication failures are reported.
Public documentation redirects must stay on their original HTTPS host.

Then rebuild the complete catalog, using the retained first-party bundle ahead
of the downloaded fallback catalogs:

```sh
python3 -B packages/model_registry/scripts/model_registry.py refresh
```

`--first-party-input PATH` selects another retained bundle. For fully offline,
byte-reproducible refresh also supply `--models-dev-input PATH`,
`--models-dev-retrieved-at TIMESTAMP`, `--openrouter-input PATH`, and
`--openrouter-retrieved-at TIMESTAMP`. Preserve original raw source inputs and
timestamps; normalized catalog files are not raw snapshots.

`--output PATH` chooses a destination. Writes use a complete validated temporary
file, flush/fsync, and atomic replacement. Acquisition/conversion failure leaves
the existing destination untouched. Acquisition warns above the source-size
threshold; it does not cap download size. Network socket timeouts are not
whole-operation deadlines. Catalog refresh rejects empty source catalogs.

The optional `data/api_overrides.json` overlay is for exact, separately reviewed
fallback-provider claims, not a first-party model allowlist. Its entries contain
`provider_id`, `model_id`, `api`, `reference_url`, and `reviewed_at`.
Contradictions with source transports and duplicate claims fail; stale IDs warn
without adding offers. An annotation never removes other source-established
transports.

## Shared Zig APIs

```zig
var catalog = try registry.Registry.load(allocator, io, path);
defer catalog.deinit();
const provider = catalog.find("deepseek").?;
const model = provider.find("deepseek-flash").?;
if (model.supports("openai-responses")) {
    const limits = registry.selection.limits(model, .{}, .{});
    _ = limits;
    const thinking = try model.thinkingProfile();
    _ = thinking;
}
```

Use `Registry` for the fixed catalog schema. `parseLuaValue` and `loadLuaValue`
are for open-ended configuration. The [runtime](runtime.zig) implements both
paths.

You can load the built-in catalog or a file. Match on endpoint and model ID, not
name alone. An ambiguous match returns null. Explicit limits win. See
[selection](selection.zig) for defaults and DeepSeek routing.

Insert and merge calls copy input data. After a replacement, look up the
provider again by ID; the old slice is not a live view. Keep live account
listings separate from the reference catalog.

- Use `registry.discovery.discover(arena, io, route, reference, warnings)` for
  one listing through the framework's OpenAI-compatible or Codex HTTP adapter.
  `discovery.list(..., get)` allows a caller-supplied transport for those wire
  formats. Bind each route to an already-authorized endpoint and credential.
- Use `registry.Refresh` for a long-lived interface. Reconcile its immutable
  route targets, call `advance` on events and at the returned monotonic
  deadline, and read `offer(index)` in the reconciled target order. The host
  chooses the refresh policy and wake mechanism and may supply a loader for
  additional provider protocols. Join the cache before releasing callback
  contexts or reference providers.
- In both APIs, a successful response supplies membership, including an empty
  list. The reference fills missing metadata and supplies the fallback list on
  failure. `fallback_reason` distinguishes a fallback from a live result.

The framework does not locate user or workspace configs, discover credentials,
perform login, choose an active account, or write credentials or live results to
disk. An OpenCode-style harness can resolve its own project/user configuration
layers and keychain or secret service, bind multiple accounts for one provider,
and supply its own discovery adapter and UI. Those policies do not require
Minimal's config files, environment, or picker.

## cpi-minimal integration

See [Minimal's registry setup](../cpi_minimal/README.md#shared-model-registry).
A context window guides local compaction; it is not a setting agreed with the
provider.

## CLI and verification

```sh
python3 -B packages/model_registry/scripts/model_registry.py validate
python3 -B packages/model_registry/scripts/model_registry.py list --provider deepseek
python3 -B packages/model_registry/scripts/model_registry.py show openai gpt-5.6-sol
anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-model-registry
```

Python loading uses the native `cpi-model-registry` evaluator, discovered via
`CPI_MODEL_REGISTRY_EVALUATOR`, installed repository binary, or PATH. It never
runs untrusted input with system Lua. Lua evaluation has no filesystem, process,
network, module-loading, or host-I/O capabilities. The
[native evaluator](runtime.zig) and [Lua bridge](runtime/bridge.c) define the
size advisories and execution budget. Native compiler allocations are outside
the VM heap budget. The [Python wrapper](scripts/model_registry.py) enforces a
subprocess deadline and reports stdout and stderr size advisories.

The tests verify the complete first-party projection, source transport tables,
novel IDs, direct DeepSeek defaults, live discovery limits/efforts, injection
ownership across teardown and growth. The same projection check rejects the
[SHA-pinned catalog fixture](scripts/fixtures/aggregator-models.lua.gz) from
historical commit `a381e0c`, which left GPT-5.6 transport-unclassified and used
aggregator metadata for direct providers. Root `test` and `test-model-registry`
run the package checks.
