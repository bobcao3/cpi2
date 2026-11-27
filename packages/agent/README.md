# Agent controller and Worker engine

The agent package provides `agent.Controller`, private Workers, Luau tools and
an OpenAI Responses agent loop. Native embedders use Controller. Foreign hosts
can implement its request/feed boundary through the C ABI.

This README explains ownership and directs each kind of caller to its API. Build
instructions and executable selection start in the
[project README](../../README.md). The
[OpenAI transport reference](docs/openai-transports.md) covers shared codecs,
HTTP and WebSocket transports, and Codex subscription settings.

## Session state

A session is durable; a Worker is a live attachment. Reopen the same journal
with its recorded session ID to recover committed state, not the old `WorkerId`.
See [session frames](docs/session-frames.md) for messages, contexts, and their
projections, or [journal persistence](docs/journal.md) for recovery and storage.
The [JSONL examples](docs/session-frame-examples.md) show complete transactions.

A turn is harness work toward an answer. It is not one command or one frame. A
command asks the Worker to do work, including running Lua without a model. An
invocation is one execution of a program; a model request is one provider step.
A turn can span several commands, invocations, and requests.
[Durable tasks](docs/native-controller.md#durable-tasks) track that work across
phases. See
[Worker and conversation slots](docs/native-controller.md#worker-and-conversation-slots)
for what can run while other work waits.

## Architecture and ownership

`agent.Controller` owns private Workers and one mandatory request and notice
port. Native clients receive scoped `WorkerId` values, request handles and owned
snapshots. The CLI, Minimal and Terminus all use that controller. Independent
native HTTP, RPC and observer adapters are not a supported construction path.

| Component          | Responsibilities                                                                                                |
| ------------------ | --------------------------------------------------------------------------------------------------------------- |
| Controller         | Command admission, Worker identities, snapshots, service dispatch, explicit provider routes and copied notices. |
| Controller Luau    | Effect-free admission policy and effectful controller programs, with state separate from model programs.        |
| Worker             | The model loop, model-side `execute_lua`, tool revisions, durable `ctx` and private journal.                    |
| Execution services | File and process mechanisms behind typed, bounded operation contracts.                                          |
| Foreign host       | Controller-side external I/O through the C request/feed interface, not a second Worker engine.                  |

### Follow a turn

The harness submits work through Controller. The Worker runs the configured
harness application or built-in loop. The harness renderer builds model input
from committed state. The session reducer checks the recorded projection.
Controller separately validates and authorizes the `model.request` operation
against the configured route before dispatch. Previews are provisional. The
settled response is recorded before the Worker acts on its tool calls.

A Worker tool can request a declared native operation through `host.call`. The
Worker records context changes and effect intent before dispatch. Controller
checks grants and policy, the service performs the operation, and the Worker
records its result before resuming Lua. See
[journal persistence](docs/journal.md) for commit and recovery rules. There is
no direct HTTP fallback.

### Where Luau runs

| Code                                                         | Heap and state                                                                                                                                                                                                             | Effects                                                                                        |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Admission policy                                             | Fresh activation in the Controller heap, reading a copy of controller context. Changes are discarded.                                                                                                                      | None.                                                                                          |
| Trusted controller program                                   | Fresh activation in the same Controller heap. It can update controller context, which is not journaled.                                                                                                                    | Declared operations granted to the program.                                                    |
| Harness application, model-written Lua, and registered tools | Each Worker has its own heap, separate from Controller and other Workers. Activations have fresh locals. Tools retain the private closure of their captured revision; committed Worker `ctx` is restored from the journal. | Model-written Lua calls tools. Trusted modules can call declared endpoints through Controller. |

Tool replacement changes future activations, not work already bound to an older
revision. A new Controller starts with fresh controller context. Reopening the
same Worker journal restores committed Worker state and rebuilds tool closures
from their recorded definitions. It does not restore live Lua stacks or closure
state. See
[controller programs](docs/native-controller.md#controller-programs-and-event-hooks)
and
[Worker capabilities and context](docs/tools-and-context.md#model-side-lua-and-checkpoints).

## Thinking effort

`agent.thinking.Level` names portable effort preferences, including `max` and
`ultra`. `Profile` maps each level to `.unsupported`, `.omitted`, or a native
`.effort` string. Its `supports`, `wire`, `cycle`, and `clamp` methods share
that table. `clamp` searches upward before searching downward. `parse` accepts
names without case sensitivity and treats `none` as `off`.

```zig
// Supply capabilities from model_registry or an explicit application override.
const profile = try agent.thinking.fromList("low,medium,high,xhigh,max");
const model = try (agent.Model{ .model = "configured-model" }).withThinking(profile, .max);
```

Callers can construct a `Profile` with native wire strings or use
`thinking.fromList("off,low,high,max")` for a canonical Responses mapping.
`Model.withThinking` rejects unsupported selections before a run starts. Raw
`Model.reasoning_effort` remains an untyped escape hatch. Null omits the
reasoning object in generation and summary requests. Raw `agent.model` bodies
also remain untyped and need application admission policy.

`ControllerOptions.preserve_policy_nulls` keeps explicit JSON null values in
policy input as frozen tables, distinct from absent fields. It defaults to false
for existing policies. cpi-minimal enables it to enforce exact reasoning
omission.

Provider/model-specific capabilities belong to the shared
[model registry](../model_registry/README.md), whose `Model.thinkingProfile`
uses first-party effort declarations. The agent package contains no parallel
model-name catalog. Match an offer by provider/endpoint and model, not model
name alone: a proxy or subscription connection may expose different
capabilities. Supply a custom profile when an alias or server has different
capabilities.

## Choose a guide

The guides separate native embedding, model programming, executable use and the
foreign protocol so their ownership rules do not appear interchangeable.

| Goal                                                                              | Read                                                                                           |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Embed from Zig, register services, define policy or run controller programs       | [Native controller API](docs/native-controller.md).                                            |
| Define model-side capabilities, endpoints and registration, permissions and `ctx` | [Capabilities and context](docs/tools-and-context.md).                                         |
| Run standalone Lua against a persistent session                                   | [Standalone agent executable](docs/cli.md).                                                    |
| Implement an external C controller and manage events, I/O and leases              | [Foreign controller C ABI](docs/foreign-controller.md).                                        |
| Understand storage ordering, interrupted effects and corrupt journals             | [Journal and recovery](docs/journal.md).                                                       |
| Inspect the session action log and context projection                             | [Session frames](docs/session-frames.md) and [JSONL examples](docs/session-frame-examples.md). |

## Examples and related packages

- The [C capability registration example](examples/register_capabilities.c)
  shows the foreign API.
- [cpi-minimal](../cpi_minimal/README.md) composes four coding capabilities in
  Luau and supplies skills, compaction and a coding-oriented TUI.
- [Terminus](../cpi_example_terminus/README.md) connects the same gateway to
  Ghostmux-backed terminal operations.
- The [services package](../services/README.md) owns operation implementations.
  The [Luau package](../../vendor/luau/README.md) owns the VM embedding and
  REPL.

## Limits and lifecycle contracts

Permissions are not an OS sandbox. Recovery restores committed state and known
results, not live Lua stacks or exactly-once OS effects. The
[journal guide](docs/journal.md) defines those guarantees.

Services, provider configuration and sink contexts are borrowed unless an owned
service explicitly provides cleanup. Calling `close` from a controller callback
only requests closure. An external owner must still join and destroy Controller.
The
[native lifecycle contract](docs/native-controller.md#shutdown-and-lifetimes)
and
[foreign destruction contract](docs/foreign-controller.md#cancellation-and-destruction)
define each interface's obligations. Audit delivery is not durable storage.

## Verify the package

Run these commands from the repository root:

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-controller test-services test-provider
./formal/check.sh controller-boundary
```

`test-controller`, `test-services` and `test-provider` exercise controller
policy, service behavior and provider configuration and routing. The shell
command runs the controller boundary gate and its historical controls. Root
`test` includes Terminus's process, policy and cancellation fixtures.

The negative controls contain verbatim Minimal, chat and effects source from
`ca76e6e3847ace2ac1fa482f72078cd07e8a6967`, with checked SHA-256 digests.
Diagnostics name `agent.Controller`. Ordinary tests use local files, real
processes, Ghostmux, journals and loopback providers. Live-provider tests are
opt-in, not part of the offline verification path.
