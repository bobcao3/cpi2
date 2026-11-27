# Foreign controller C ABI

> The C ABI exposes commands, events, and I/O feeds, not the
> [session frame format](session-frames.md).

Use the C ABI when an external host implements the controller side of the
request/feed interface. Native Zig products use
[agent.Controller](native-controller.md) instead of constructing a separate
adapter path. Both interfaces use the same private Worker engine. The public
definitions are in [agent.h](../include/cpi/agent.h).

[Agent documentation](../README.md) · [Project README](../../../README.md)

## Configuration and threading

Initialize every C structure's `struct_size` to `sizeof` that structure and set
the configuration's ABI version to `CPI_AGENT_ABI_VERSION`. ABI v2 requires
exact structure sizes. It is intentionally incompatible with v1. Open performs
native storage recovery and can report storage, writer-lock, or concurrency
errors. The actor owns execution. C calls may wait for admission or a
synchronization barrier but do not invoke user callbacks.

One native actor owns each session's agent loop, transcript, Lua execution,
durable context, and private journal. Producers use a bounded mailbox. HTTP and
execution-service adapters do not own storage or advance the agent loop.

Foreign callers serialize their C API calls, including event release. They may
move between OS threads after a synchronized handoff. C calls must not overlap
or race destruction. The foreign adapter copies commands to the same native
actor used by Zig callers. There is no second worker engine.

## Open a session

1. Optionally create an initial-tools builder with `cpi_agent_registry_create`
   and add module sources with `cpi_agent_registry_add_lua`. Each module returns
   one tool descriptor. Duplicate names, invalid descriptors, and service calls
   during bootstrap registration are errors. Registration runs descriptor
   construction only. Capability names and registry allocation above their
   expected sizes produce warnings.
2. Open a worker with that builder or `NULL`, session identity, workspace,
   journal URI, and options. Open snapshots the builder and configuration, so
   the host may immediately reuse, change, or destroy the builder. Its snapshot
   seeds a new session only. An existing session restores its durable capability
   registrations instead; bootstrap sources do not silently replace session
   tools on reopen.
3. Queue input with `send`, drain events, and supply external I/O responses.
   Open completes locked recovery before returning. `READY` reports that
   recovery succeeded. `run` is a synchronization barrier and status query, not
   the agent scheduler. The actor advances without calls to `run`.

The session can register, replace, and remove tools after open. The optional
builder supplies initial tools. It is not a runtime registry and needs no
finalization. Options select provider and model configuration, tool capability
grants, and resource limits. Capability access defaults to denied. Credentials
belong to the runtime adapter, not `ctx` or journal records.

For an example, see
[register_capabilities.c](../examples/register_capabilities.c).

## Register and remove capabilities

`cpi_agent_register_lua(agent, request_id, source_name, source)` queues a
command to add or replace the tool named by the returned descriptor.
`cpi_agent_unregister_capability(agent, request_id, name)` queues removal of a
registered name. Both operations are available throughout the worker's open
lifetime, including while a model request or tool is running. They copy their
input spans once and return without compiling or executing invocation code.

Wait for registry activation before depending on a new definition. The full
[registration and revision contract](tools-and-context.md#registration-and-capability-revisions)
covers admission, activation, captured revisions and durable source retention.

## Commands and request IDs

Every command has a nonempty session-scoped `request_id`. `send` copies its
bytes and only queues it in memory. `COMMAND_COMMITTED` confirms durable
admission; `COMMAND_FINISHED` reports its terminal result or error. A duplicate
request ID with the same command finds the existing command; different content
returns `REQUEST_CONFLICT`. Pending and durable admissions participate in
deduplication. The worker re-emits an existing admission and terminal result
without executing the command again. Pending admissions emit confirmation once
their commit finishes.

| Kind     | JSON payload                                        | Behavior                                                        |
| -------- | --------------------------------------------------- | --------------------------------------------------------------- |
| `INPUT`  | `{"content":"..."}`                                 | Queue user input for the agent loop.                            |
| `LUA`    | `{"source":"..."}`                                  | Queue a Lua invocation without a model request.                 |
| `STEER`  | `{"content":"...","policy":"interrupt_generation"}` | Persist steering and apply it to the next model request.        |
| `CANCEL` | `{}`                                                | Cancel the active run or standalone invocation, not the worker. |
| `CLOSE`  | `{}`                                                | Stop admission and quiesce I/O, preserving durable queued work. |

`LUA` runs through the same evaluator, permissions, and journal as
model-generated programs. The model calls a single Lua execution tool. Registry
descriptors describe functions in `tools`. Only one invocation mutates `ctx` at
a time.

Steering also accepts `at_boundary`. Both policies prevent unstarted tool calls
from the old plan from dispatching after steering commits.
`interrupt_generation` also cancels an active provider stream. Already-running
tools must settle or be explicitly cancelled; steering cannot undo side effects.
Skipped calls receive recorded results, and late completions cannot advance a
different invocation. An active Lua program stops at a scheduling boundary
rather than executing more of the old plan. Its pending effects settle before
another invocation starts.

## Drive events and external I/O

`run` synchronizes with the actor and returns its disposition. Its clock
argument is ignored. Positive budget arguments are reserved in v2; they do not
configure actor execution. The actor uses bounded Lua interrupt quanta
internally.

Drain `next_event` until `NO_EVENT`, dispatch external requests, and feed
terminal responses. `RUNNABLE` and `WAITING` describe the actor's state, not
instructions for pumping its execution. There is no timed wakeup. `CLOSED` and
`FAILED` are terminal. Retained leases count against bounded foreign event
storage. Exceeding that bound fails the worker rather than silently dropping
committed observations.

Committed observations have nonzero journal sequences. `PROGRESS` is provisional
and has sequence zero. `READY`, `FAULT`, and I/O control messages are not
journal entries; their sequence is zero. Tool and context events only describe
durable state. A tool start means a committed intent, not proof an external
effect ran.

For `IO_REQUEST`, `operation_id` identifies the operation, `method` selects an
adapter, and `json` contains its request. The only methods are `rpc.call` and
`http.request`. Storage never crosses this boundary. There are no journal
read/append requests or external storage acknowledgments.

`io_feed` supplies metadata JSON with `META`, raw streaming bytes with `DATA`,
and exactly one terminal `DONE`, `ERROR`, or `CANCELLED`. `DONE` carries result
JSON; `ERROR` carries `{"code":"...","message":"..."}`. `CANCELLED` has an empty
span. Operation IDs are never reused within a handle. Responses for terminal or
unknown operations return `STALE_OPERATION`. A successful feed copies and queues
the response for the native operation task. The actor processes it
independently.

## I/O message schemas

| Method         | Request JSON                               | Successful `DONE` JSON |
| -------------- | ------------------------------------------ | ---------------------- |
| `rpc.call`     | `endpoint`, `arguments`, `idempotency_key` | Endpoint result        |
| `http.request` | `url`, `credential`, `body`                | `status`, `body`       |

The runtime adapter resolves `credential` locally; the field contains a label,
never a secret. [native provider implementation](../src/provider.zig) implements
the concrete message schemas. `DATA` can carry raw response bytes, but this
version does not parse Responses SSE events. Normal model requests use one
non-streaming HTTP completion.

Journal reads, appends and acknowledgments never cross this interface. See
[Journal and recovery](journal.md) for the private storage contract.

## Buffer and event-lease ownership

Every successful `next_event` transfers one event lease to the driver. All spans
in that event are immutable and remain valid through subsequent API calls until
`cpi_agent_event_release(agent, event.lease_id)`. The host may pass copies of
the small event structure to asynchronous readers without copying payload bytes.
It must retain the lease until every reader has finished, then arrange release
on the driver. Releasing the request event does not complete its I/O operation,
and completing an operation does not release the event automatically.

`next_event` does not copy payloads. It exposes worker-owned immutable storage.
The worker keeps that storage valid until release and never mutates a leased
payload. Lease IDs are nonzero and never reused within a handle. Double release
or an unknown ID returns `STALE_EVENT`; `NO_EVENT` creates no lease. Event
storage limits include both queued events and outstanding leases.

Input spans passed to `send` or `io_feed` are borrowed only for that call.
Success copies each accepted payload once into worker-owned storage. On any
error, the worker accepts none of the input. Host I/O tasks own response buffers
and move buffer ownership through the host mailbox without copying bytes. The
driver passes the buffer to `io_feed`, then frees or reuses it after the call
returns. This avoids cross-allocator frees, release callbacks, and reference
counting in the C API. Encoding, parsing, and journal compression are separate
from this one-copy ownership transfer.

## Cancellation and destruction

The driver signals worker cancellation by sending `CANCEL`. It does not cancel
the native actor task. Admission does not wait for the invocation to stop. The
worker records cancellation and emits `IO_CANCEL` for its pending operations.
Completion of the cancellation command acknowledges that request. The target
command completes separately when the invocation stops.

`IO_CANCEL` requests cancellation but does not assert that an effect was undone.
The adapter must eventually send a terminal response, which may be `DONE` if
completion won the race. Close reaches `CLOSED` only after operations settle.
Destroy joins native work. Stop and settle all adapters before destroying a
handle. The driver must release every outstanding event lease before destroy,
including leases whose events describe a closed or failed worker.

The foreign bridge waits for a terminal feed even after cancellation. This keeps
external resources and leased input alive until their real owner settles them.
Native cancellation owners may join operation tasks, but the actor never does.

## Queue ownership and bounds

The native actor owns a 128-message mailbox and bounded admitted requests.
Pending retries share one request/result owner per ID. Ordinary pending requests
have 128 slots. Eight separate slots are reserved for cancel, steer, and close.
Foreign operation replies and event leases have their own bounded storage. These
are not Bash stdout pipes or queues of shell jobs.

The host should process completions, drain events, and release leases before
accepting more input. Allocation and journal size thresholds produce
`CPI_AGENT_EVENT_PROGRESS` events with JSON kind `size_warning`. The payload
includes the operation, measurement, actual size, and threshold. Backing
allocation errors and journal integrity failures surface as errors. Opening with
an initial-tools builder publishes its allocation and name size high-water
warnings to the worker's event queue.
