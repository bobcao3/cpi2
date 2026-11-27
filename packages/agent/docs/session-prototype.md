# Worker application sessions

> Historical prototype notes. Do not use these examples as the current API or
> CLI reference. See the [native Controller guide](native-controller.md),
> [session frames](session-frames.md), and
> [Terminus guide](../../cpi_example_terminus/README.md).

Minimal and Terminus demonstrated different imperative Luau applications in
separate Workers. At this stage, Terminus selected the prototype with
`--session-controller-prototype`. The current CLI does not have this switch.

## Run the proof

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" -j4 test-session-prototype
```

The target runs Terminus against a local provider. Terminus uses raw JSON
without an `execute_lua` descriptor. Its real terminal output must appear in a
later prompt, and completion requires two confirmations.

Controller tests also deny real file, process, and model operations after inside
mutation. A trusted outside program then enables those operations. Replacement
tests hold the old HTTP response until the corrected invocation has progressed.
They check stale targets, queued delivery, observation-handle release, joined
shutdown, late receipts, explicit helper persistence, and fixed-tool upgrades.

## Native interface

Bind `Config.application` when starting a Worker. An `Application` contains
source, JSON environment options, and a choice of mutable or frozen tool
bindings. Application-specific input stays JSON data. Native code has no
application reducer, context mirror, or model scheduler beside Worker.

```zig
const worker = try controller.start(.{
    .session_id = "coding",
    .journal_path = journal,
    .application = .{ .source = application_source, .environment_json = options_json, .mutable = true },
    .tools = coding_tools,
    .endpoint_grants = grants,
    .model = model,
});
const invocation = try controller.deliver(worker, "turn-1", .{ .input_json = input_json });
defer invocation.deinit();
const corrected = try controller.deliver(worker, "turn-2", .{
    .input_json = correction_json,
    .replace = invocation.id,
});
defer corrected.deinit();
var outcome = try corrected.wait(io);
defer outcome.deinit();
```

Delivery without `replace` queues an invocation. Replacement names an immutable
command identity in that Worker. Reusing an identity with different input fails.
Worker orders target invalidation, operation completion, and replacement in its
mailbox and journal. A stale replacement fails instead of canceling newer work.
Replacing queued work leaves an unrelated active invocation alone.

Set `Delivery.boundary` with `replace` to wait for an application checkpoint
marked as safe. Canceling that queued delivery leaves its target alone. An
admitted correction runs next if its target finishes naturally before reaching a
checkpoint. A target already stale at admission is rejected. Immediate
replacement remains the default when `boundary` is false.

`Controller.cancelInvocation` explicitly cancels an identified invocation.
Waiting on or releasing a `Request` only manages observation. `Request.retain`
creates another observation reference when a UI and its waiter need independent
lifetimes. Each reference needs `deinit`. `Controller.inspect` returns an owned
Worker snapshot. Existing context and conversation readers remain available for
unmigrated consumers.

## Inside execution and outside authority

```mmd
flowchart TD
    UI[Native CLI configuration and delivery] --> Worker[Worker mailbox and journal]
    Worker --> Inside[Inside Luau application, ctx, tools, model helpers]
    Inside --> Jobs[Worker-owned effect jobs]
    Jobs --> Outside[Separate Controller authorization VM]
    Outside --> Grants[Native grants and service schemas]
    Grants --> Services[Files, processes, configured provider transport]
    Services --> Worker
```

The shared inside `agent` library provides JSON codecs, explicit context
collections, model response data, evaluation, and source-backed helpers.
`agent.evaluate` uses a private bounded compiler. Lua assigns the ordinary
application environment and invokes the compiled closure, so tool effects can
yield. Neither the native table nor the host global environment is available to
evaluated code.

`agent.checkpoint(event, boundary)` commits explicit context before publishing
bounded, invocation-attributed progress, then resumes the same stack. It is not
a host service or an authorization grant. `agent.capture(fn)` preserves the
function's ordinary return value, Lua error, image attachments, and completed
host observations. An interrupted capture leaves recoverable facts in reserved
`ctx.__capture`; applications consume them without repeating uncertain effects.
Nested captures share the outer call's image budget.

`agent.model` requests `model.request` as a normal Worker effect. Native code
supplies the configured route and credential label before admission. Outside
policy receives the real Worker principal, concrete operation, and effective
arguments. Native grants, schema validation, and route ceilings apply again
after any outside rewrite. Completion, refusal, incomplete output, cancellation,
and errors are application data. Only the inside application decides whether a
generation completes its task.

`Limits.max_rounds` also bounds model requests per application invocation,
including requests from evaluated code. Minimal's outside policy fixes the
selected model and reasoning effort and caps output tokens. These constraints
live outside its mutable agent environment.

`Controller.program` remains trusted outside orchestration. Its context and
authorization VM are separate from the inside application. Inside context
changes and tool wrappers cannot change outside policy or native grants. Mutable
tool bindings are a behavior choice, not an authorization boundary.

Outside Controller context is memory-only. The trusted host initializes that
state again when it opens a new Controller.

## Persistence and interruption

Worker commits explicit `ctx` at host yields and normal completion.
`agent.define` saves helper source in that context. An application can call
`agent.restore` when a new invocation starts. Helper factories cannot perform
host effects during definition or reconstruction. The returned functions can
yield when called later. Application-local closures, model-written tool
wrappers, and Lua stacks are not retained between invocations.

Registered tool execute closures and their module-private state remain alive
with that tool version in the Worker heap. They are distinct from
invocation-local wrappers. Replacing the registered version or closing the
Worker releases them once no invocation needs them. Module-private state is not
journal-durable; reopening evaluates the stored source in the new Worker heap.

Recovery marks interrupted invocations failed and does not replay uncertain
effects. A later delivery can continue from explicit application state. Fixed
tool catalogs still upgrade restored definitions through Controller commands.

`Application.adopt_conversation` opts into atomic transfer of a recovered native
tree into `ctx.__adopted_conversation`. The native tree is emptied in the same
journal transaction. The application validates and consumes that slot at its
next commit. A crash therefore retains either the original tree or its staged
adoption. Clients that do not opt in retain native conversation behavior.

Reopening uses the current host-supplied application source and options. Worker
does not check their version compatibility with the previous application.
Applications own compatibility with their persisted context and helper
definitions.

Replacement requests cancellation of old I/O without waiting for remote
acknowledgement. Runtime keeps the old job and buffers until joined. Late
outcomes enter `late_receipts` with their original invocation and operation
identities. They cannot resume the obsolete VM or change replacement context.
Completed effects stay completed. Cancellation is not rollback and does not
guarantee that remote billing stopped.

## Application limits

- Minimal owns its session graph, compaction, image results, and command state
  in its application. Its native Session is a read-only projection. See
  [Minimal's session contract](../../cpi_minimal/README.md#sessions-and-compaction).
- Terminus reuses its existing parser, prompts, command durations, bounded
  terminal observations, and completion confirmation. Its prototype does not
  register native model/context services or create a `ContextStore`. Child
  delegation and automatic compaction are not migrated. Its CLI still creates a
  fresh state directory rather than resuming an old terminal task.
- Worker journal recovery persists explicit state, not a suspended imperative
  stack. Applications must handle interrupted outcomes before beginning new
  work.
- Provider projection currently targets Responses. Configured VM, context,
  journal, source-compilation, and transport limits still apply. This is not an
  unbounded service API.
- `Limits.max_vm_input_bytes` bounds the combined encoded context, input,
  options, application source, and tool sources independently of the heap cap.
  Defaults remain in `src/config.zig`. Controller policy input has its own
  explicit budget. Neither setting raises the separate trusted Controller
  context limit.
- Late receipts retain full outcomes. They count toward the snapshot and journal
  limits, so repeated replacements can exhaust those limits. Worker fails rather
  than silently discarding effect facts.
