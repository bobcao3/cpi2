# Native controller API

Controller owns execution and attachment lifetimes. The
[semantic session journal](journal.md) owns durable state transitions. The Luau
harness maps these execution APIs to core actions and private contracts.

Use `agent.Controller` to embed the agent from Zig. This page covers controller
setup, service and provider routing, policy, programs, and lifecycle. For
model-side tool modules, see [Tools and context](tools-and-context.md). Borrowed
service, provider and sink contexts must outlive joined controller closure. Read
[Shutdown and lifetimes](#shutdown-and-lifetimes) before attaching them.

[Agent documentation](../README.md) · [Project README](../../../README.md)

## Snapshots and model requests for native tasks

With `host_session_access`, use `queryApplication` to read a committed view. The
query runs on the Worker and drops changes to its private context.

Use `requestTaskModel` to ask for one model step under the Worker's grants. The
task owns the attempt ID, progress sink, checkpoint, retry, and result.

## Open a controller and start a Worker

This minimal example registers no external services or provider routes. It
submits a local Lua command to a Worker through Controller.

```zig
const controller = try agent.Controller.open(allocator, io, .{
    .authorize = "return function(event, state) return {allow=true} end",
});
defer controller.close();
const worker = try controller.start(.{
    .session_id = "example",
    .journal_path = "/absolute/path/session.gz",
});
const request = try controller.submit(worker, "increment-1", .{
    .lua = "ctx.count=(ctx.count or 0)+1; return ctx.count",
});
defer request.deinit();
var outcome = try request.wait(io);
defer outcome.deinit();
```

Canceling a wait or releasing its handle does not cancel the command. Submit
`.cancel` instead. Snapshot ownership is described under
[Worker identities and snapshots](#worker-identities-and-snapshots).

Tool definitions in `Config.capabilities` seed new journals only. See
[Seed and recovered tools](tools-and-context.md#seed-and-recovered-capabilities).

## Launch a configured Worker atomically

Use `launch(config, startup)` when a client owns a fixed catalog or needs local
application initialization before exposing a Worker. It returns the ordinary
`WorkerId` only after preparation joins and the complete state is durable.

```zig
const worker = try controller.launch(.{
    .session_id = "configured",
    .journal_path = "/absolute/path/configured.gz",
    .application = .{
        .source = "ctx.label=input.label; agent.checkpoint({configured=true}); return true",
    },
}, .{
    .catalog = .{ .fixed = &.{.{
        .name = "sum",
        .tool = .{
            .source_name = "sum.luau",
            .source = "return {name='sum',version=1,description='sum',parameters={type='object'},capabilities={},recovery='never',execute=function(args) return args.a+args.b end}",
        },
    }} },
    .initialize = .{ .input_json = "{\"label\":\"ready\"}" },
});
```

A fixed set replaces old tools and drops absent names. Names must match the
loaded modules. `.preserve` keeps dynamic tools. A launch checks command policy
for tool changes and setup. It rejects policy rewrites.

Setup may change `ctx` but cannot send a model request or any other effect. One
final commit saves the result and emits `READY`. Queued commands wait for that
point. Failed launches expose no Worker. A fault before append leaves the file
intact. A fault during append can leave a full record or torn tail; see
[journal recovery](journal.md#replay-and-recovery).

Use `initialize_id` for one-time setup. Use a new ID or omit it for each open.
Pass an empty `Startup.failure_diagnostic` slot to get an owned error from a
failed initializer. Free it after use. Launch borrows its inputs until it
returns. It joins VM and journal setup on both success and failure.

## Durable tasks

Register `agent.TaskJournal.contract` in the codec. Attach `agent.TaskScheduler`
to a Worker with host session access. Keep the Worker and host state alive until
scheduler close returns.

Submit a stable task ID. The [task record](../src/TaskJournal.zig) keeps
ownership and phase state. A phase runs outside the Worker. It can save a
checkpoint, wait until a deadline or for other tasks, or finish. A handoff can
add owned children in the same journal commit. That does not make external
effects atomic.

Give effectful phases a recovery handler. Set `replay_safe` only for safe
repeats. A missing definition leaves the task pending. Use `registerDefinition`
and `notify` when the host can run it.

`wait` gives an owned receipt. Canceling the wait does not stop work. Use
`abort` to cancel. Use `close` to join and park work. If a task drives a Worker
command, recover its result with `readCommandReceipt`. Use `joinInvocation`
after stop to join host work and collect late receipts.

### Conversations and task ownership

A conversation is a named task scope. Its context selects messages; its
transcript shows them. The default is `main`. Use `createConversation` for an
unowned scope or `Step.conversations` for one the task owns. A fork shares
messages through a saved cut. Later messages are separate.

The scope, its context with the same ID, and its first tasks commit together. A
context fork alone creates no task owner. Child tasks use the parent's scope. A
handoff can save messages and extension edits with the task phase. See
[`Step` and `ConversationDraft`](../src/TaskJournal.zig) for fields.

Owners wait for ordinary owned work before settling. Abort or failure cancels
that work. A background child can outlive the parent. A conversation survives
the owner's end. Use `abortConversation` to stop and join its work or
`waitConversationIdle` to wait for it.

With scoped delivery, `Delivery.conversation` picks history and checkpoint. The
Worker runs application commands one at a time. A parked task can let another
scope run. `Delivery.application_model` pins the model and route; Controller
checks the same binding on resume. The host resolves keys. The journal stores
route refs, not keys.

### Worker and conversation slots

A task submitted with `exclusive_turn` holds its conversation's turn slot until
terminal settlement, even while waiting for children or a provider retry. The
next exclusive task in that conversation starts in journal admission order.
Other conversations have their own slots; this does not make application
commands on one Worker run in parallel.

The Worker's [run slots](../src/RunState.zig) track execution, not task
admission. The Worker loop can move a user run from `active` to `suspended`, run
a summary in `active`, then resume the user run when `active` is empty. The
continuation selects the suspended run; the resumed run can have a new command
ID. This is a Worker-loop mechanism, not a requirement that every harness
compaction use it.

### Task documents

A [task document](../src/TaskJournal.zig) has a kind and optional family key.
`Invocation.document` returns an owned view with version and revision. Use
`Step.documents` for edits in the handoff or `commitDocuments` for a separate
commit. Both need the active lease. A bad edit or stale version rejects the
whole batch.

The [patch codec](../src/DocumentDelta.zig) defines Chord edits. A document must
have an object root. Documents stay readable through cleanup and retire when
their task ends. The journal keeps past edits.

## Services and provider routes

Attach services in `Controller.open`. Set Worker grants in
`Config.endpoint_grants` and program grants in `program_grants`. Attachment
alone grants no access. Bad grants, inputs, and results fail closed. Size
warnings do not block valid calls. Workers also check each tool's own grants.

Map model endpoints and credential labels in `ControllerOptions.providers`. A
label is not a key. Both the Worker and Controller programs use `model.request`;
neither can fall back to direct HTTP.

A route's [retry settings](../src/provider.zig) count the first attempt. With
one attempt there is no retry. See
[transport recovery](openai-transports.md#native-resume) for which failures
retry, restart, or resume. Stop cancels the wait.

A `provider.DeferredAdapter` needs model progress and a codec with deferred
polls. Its start and poll calls get the admitted input and a stable key. A
pending reply gives a non-secret handle and can set a wait. The Worker saves
both before giving back control. On reopen, poll gets the same handle and route.
A lost job can return a retryable outcome. A temporary fault keeps the handle.
Keep the adapter ID stable for compatible handles. Keep its context alive
through close. Provider idempotency can protect the gap between remote
acceptance and the local commit.

See [services](../../services/README.md) for the file and process contracts.

## Worker identities and snapshots

Live Worker storage has an active limit, not a lifetime-start limit. Stop and
failed startup release that storage. Worker indices increase without reuse and
remain exactly representable in Luau; stale IDs never identify replacements. A
reopened journal gets a new `WorkerId`, not a durable handle. Controller rejects
duplicate live session names.

`readContext(worker, allocator)` and `readConversation(worker, allocator)`
return owned snapshots. Journal location also determines the stable identity
used for effect receipts. The key uses the session ID and canonical journal
path, so moving the journal can change receipt lookup.

Use the command request ID to recover a committed command receipt, and the task
ID to resume tracking a durable task. A model request ID names a provider step;
an effect ID relates its recorded intent and result. They are not Worker
handles. A suspended run is selected by its continuation, not by reusing the old
command ID. See
[command request IDs](foreign-controller.md#commands-and-request-ids),
[model actions](session-frames.md#model-actions), and
[effect actions](session-frames.md#native-effect-actions).

## Admission policy

`ControllerOptions.authorize` is Luau source that returns a function accepting
`event` and a controller-state projection. It returns `{allow=true}` or
`{allow=false}`. Service decisions may also return `operation` and `arguments`.
Unknown fields, invalid results, errors, effects, and exhausted admission
budgets deny the request. Admission uses a copied context and cannot commit its
changes. Original grants, identity, schemas, and the configured model endpoint
constrain transformed requests too.

## Controller programs and event hooks

`Controller.program(id, source, input)` returns a `Request`. Code gets `input`,
`ctx`, and `host.call`. It can queue a Lua command with
`worker.command({worker=id, request_id=id, kind='lua', text=source})`. This
needs the `controller.command` grant, which Workers cannot hold.

See [where Luau runs](../README.md#where-luau-runs) for state and heap
ownership. Program changes to `ctx` take effect at host yields and return, in
memory only. Public IDs keep their dedup records until close. Event-hook runs do
not keep those records or share their effect keys. No program stack survives
restart.

Programs run one at a time, even during a service wait. They hold no VM or
Controller lock during I/O. Admission, Worker calls, and notices can still
advance. The default allocator warns at its shared threshold but still tries to
allocate. An inherited allocator sets its own policy. See
[Controller](../src/Controller.zig) for event hooks and exact limits.

## Notices and previews

The sink gets copied Worker notices and provisional model previews. Use
`request_id`, `worker`, and `scope` to route previews. Controller program
previews have no Worker ID. The old `notify` callback still works.

Text arrives as `delta`. Tool arguments arrive from `tool_start` through
`tool_delta` to `tool_end`. The decoder closes all open calls before it
finishes. Copy preview text if it must outlive the callback. The journal, not
the preview, owns the final tool call. See
[retry behavior](openai-transports.md#native-resume).

A `size_warning` gives the size, threshold, and operation. A missing or failed
sink sends it to the log. See [event types](../src/Controller.zig) for fields.

## Audit delivery

A service attempt gets one terminal audit when storage is available. The audit
names the requested and resolved operation and the policy result. It hashes the
key and arguments, but does not log arguments or keys in plain text.
`execution_attempted` does not tell you whether an effect happened.

Controller reserves space before dispatch. No space can mean no dispatch. A sink
fault can block later work with `NotificationDeliveryFailed`. Stop and close
still work. A lost audit does not undo an effect or make replay safe.

Audits live in memory. On close the owner joins producers, gives the sink time
to drain, then cancels and joins it. A stalled sink can lose records. A sink
that ignores cancel can block close. Supply your own store for durable audits.

## Shutdown and lifetimes

Stop and close cannot be vetoed. `stop(worker)` joins that Worker and retires
its ID. The owner calls `close` to join Workers, programs, and sinks. Stop
outside producers first. Keep borrowed services, routes, and sink state alive
until close returns. Handles and results also need their allocator and I/O.

In a callback, use `requestClose()` to shut the door to new work. It does not
cancel, join, or free anything. Callback `close` also only requests closure. The
outside owner still has to call `close`. Callback `stop` returns
`ControllerCallbackLifecycle`; it cannot join work that needs that callback.

Use an allocator and `std.Io` that can serve concurrent calls. A stop does not
free a Worker while a call still holds it.
