# cpi-terminus

The shared [session journal](../agent/docs/session-frames.md) records core
messages and contexts. Terminus parses JSON actions without provider tools.

`cpi-terminus` runs a Terminus-style JSON agent through `agent.Controller`. The
agent controls a persistent Ghostmux terminal and uses child Workers for
summary, questions, and answers during context compaction.

This example is not a complete clone of Harbor Terminus. A real model and a
Terminal-Bench task have not yet been run with this binary.

The [private context format](docs/context-journal.md) preserves implicit ctx
mutations through a Terminus-owned contract at live yield and completion
boundaries. The CLI has one execution path and no separate context journal or
prototype flag.

## Build and test

From the repository root, using the existing cpi2 and Kit checkouts:

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" -j4
anyzig 0.17.1 build test-terminus --fork "$HOME/Kit.zig" -j4
```

The root build installs `zig-out/bin/cpi-terminus`. The root `test` step also
runs the Terminus tests. To build or test this package alone, run
`anyzig 0.17.1 build --fork "$HOME/Kit.zig" -j4` or
`anyzig 0.17.1 build test --fork "$HOME/Kit.zig" -j4` from
`packages/cpi_example_terminus`.

`tests/test_worker.py` exercises context edits, policies, compaction, and PTYs
with a loopback fixture. `tests/test_cli.py` starts the CLI from a separate
workspace. It tests fixture mode and the registered model service against a
loopback Responses server using a synthetic provider configuration. The tests do
not contact a provider. The build supplies the CLI and Ghostmux executables to
the tests. Test runs are written under the package's `.zig-cache`. The parser
test compares against `tests/parser_expected.json`, generated from Harbor's
Terminus parser at commit `5eb713ff9500daced4e143b98765a7c732744a1b`.

The tests create a private socket directory under the package's `.zig-cache`.
They do not reuse `CPI_GHOSTMUX_SOCKET`. Set `CPI_TERMINUS_TEST_SOCKET` to a
socket path in a private directory if the checkout path exceeds the operating
system's Unix socket path limit.

The native application services, CLI, and Worker test driver live in `src`.
Their Luau programs live in `src/guest`. Provider transport comes from the
public `agent.provider` API. Test scripts and fixtures live in `tests`. The
optional `build-boundary-probe` package build step installs
`terminus-boundary-probe`. The `test-boundary` step runs it against real denied
and allowed file writes through one Controller and checks that guest code cannot
mutate controller ctx.

The package's `test-metadata` step runs context authority, read grants, parser
parity, completed replay and binding checks without creating a terminal. It also
checks failure-closed policy, denied model requests with zero loopback HTTP
requests, native authority under a permissive application policy, and
cancellation during a stalled model request. This focused step does not replace
the full CLI and PTY tests.

## Controller and service ownership

Each application principal owns an opaque `agent.Controller` and a
controller-scoped `WorkerId`. Its real `services.Process` instance uses a
principal-specific receipt directory under `processes`. Another principal's
process ID therefore cannot select its jobs, even if application policy permits
a request. ContextStore reads and records core session actions through
serialized host-only Controller calls. It does not own another persistence file.

Application services declare typed arguments, results, bounds and recovery
behavior. Each guest tool calls one fixed descriptor. The guest's `rt.call`
helper only selects those tools. There is no general privileged `runtime.call`
endpoint or native operation dispatcher. Context edits and delegation enforce
native ownership and read grants in addition to Luau policy.

The policy runs with a separate budget in a fresh activation of the
[Controller heap](../agent/README.md#where-luau-runs), not in the Worker's heap.
Native code projects identity, grants and snapshot ownership into controller ctx
through pure controller programs. Model ctx is not policy state. Model
generation prepares application context and budgets in a typed service, then
calls the registered `model.request` operation in a controller program. Terminal
creation similarly composes real `process.spawn` with ownership registration.
Subsequent terminal operations go directly through Controller to
`services.Process`.

Cancellation requests stop and schedules closure in an application-owned task
group. The external owner joins those tasks before releasing principal metadata.
The timer and service callbacks do not synchronously join their own Controller.
Application shutdown releases retained terminals through declared Process
operations in a cleanup Controller. Uncertain application mutations use `never`
recovery. The example does not replay unfinished controller programs or claim
durable receipts for application metadata operations. `broker.jsonl` records
terminal audits with controller scope, principal, request and effect identities,
policy decisions, argument digests, and error codes. It does not record provider
credentials.

The default CLI checks include commands that produce 700 KB and 2 MiB of output.
Both must finish with their completion marker in a later model observation. The
root `test-terminus-large-output` step runs the same CLI checks.

## Run a task

The shell runs with your operating-system permissions. The workspace does not
confine it. Do not use untrusted tasks or models without a separate isolation
boundary.

For a Responses-compatible provider, set `OPENAI_MODEL`, `OPENAI_BASE_URL`, and
`OPENAI_API_KEY` in the process environment. The endpoint must support the
OpenAI Responses request and response format. Remote endpoints require HTTPS;
HTTP is restricted to numeric loopback. No dotenv file is read.

```sh
zig-out/bin/cpi-terminus \
  --task-file /absolute/path/instruction.txt \
  --workspace /absolute/path/workspace \
  --state-dir /absolute/path/new-run-directory \
  --ghostmux /absolute/path/to/ghostmux \
  --socket /absolute/path/to/ghostmux.sock \
  --live
```

`--task TEXT` is an alternative to `--task-file`. The state directory must not
exist, and its parent must exist. The CLI creates the state directory with mode
`0700` and rejects a state directory inside the workspace. The socket can
instead come from `CPI_GHOSTMUX_SOCKET`. The CLI writes a JSON result to stdout
and returns nonzero when the Worker fails or the agent reaches its turn limit.
Ghostmux must be installed separately.

`--max-model-calls` limits the total number of model requests across the main
agent and its children. SIGINT and SIGTERM request cancellation and terminal
cleanup. A run has no overall wall-clock deadline.

`--reasoning-effort medium` sends `reasoning.effort` in model requests,
including compaction calls. Omit the flag to leave the provider's default
unchanged.

For a local Responses fixture, replace `--live` with
`--fixture-url http://127.0.0.1:PORT`. Fixture mode does not use provider
credentials. The CLI embeds the guest programs and policy, so it does not need a
source directory at runtime.

## Limits

The controller keeps provider credentials out of its explicit terminal
environment. This does not protect secrets from a same-user process that has
other operating-system access to the host. Give the agent an isolated
environment when running untrusted code.

The example handles text output and uses a byte-based context estimate. It does
not implement every Responses feature or every Terminus API format. Exact
tokenizer accounting, XML, ATIF, asciinema, automatic recovery of a live Luau
stack, and reliable reconciliation of uncertain external effects remain outside
this implementation. A cancelled principal's PTY is cleaned up at application
shutdown. Recovery from a genuine provider context overflow is also unverified.

The Worker requests a bounded terminal observation, with a 10,000-byte text
budget by default. Ghostmux retains the requested head and tail while
formatting, then returns the omitted-byte count. The Worker adds the omission
notice. No full-history transfer is needed. Complete captures retain text-based
incremental matching. Truncated captures are labeled as retained terminal output
rather than an exact delta.

The Terminal-Bench task demonstration is pending. A scripted fixture is not a
model-run benchmark result.
