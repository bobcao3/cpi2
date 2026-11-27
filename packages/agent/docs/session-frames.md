# Session state machine and action journal

A session is the state obtained by reducing its durable journal. A message is a
recorded document. A semantic context selects an ordered set of messages; it is
not the message store or Lua `ctx`. At a committed position, a harness can
render that state as a transcript or project it as model input. Those views can
differ: a display-only message may appear in the transcript without entering
model input. A native task
[conversation](native-controller.md#conversations-and-task-ownership) is a named
scope, not the transcript it renders.

```text
state_at(position) = reduce(initial_state, journal[1..position])
transcript_at(position) = render(state_at(position))
```

Minimal and Terminus use the [session protocol](../src/session_protocol.zig) and
[journal](../src/SessionJournal.zig). Both capture private state and use core
messages and contexts without legacy readers or dual writes.
[Session journal persistence](journal.md) describes publication, recovery, frame
ownership, and verification limits. [JSONL examples](session-frame-examples.md)
show provider tools and custom actions.

## Framework boundary

The core defines bindings, model settings, provider advertisements, documents,
context selections, model requests and native-effect receipts. It does not
define an execution language, callable registry, shared `ctx`, tool entry point,
compiler, builtin catalog or closure lifetime.

A harness defines tool handlers, custom protocols, private state and their
versioned contracts. Names such as `execute_luau` have no special core meaning.

## Shared types

`T?` is optional. `T | null` is required but nullable. `A & B` combines fields.

```text
Id          = nonempty UTF-8 string
UInt        = integer in 0..9007199254740991
FrameRef    = positive UInt                  // exact earlier frame
Prefix      = UInt                          // end of a complete transaction
Head        = UInt                          // last change in one context/namespace
Hash        = lowercase SHA-256 hex string
JSON        = RFC 8785-compatible JSON value
Object      = map<string, JSON>
Version     = { id: Id, version: string }
Status      = "completed" | "failed" | "cancelled" | "interrupted"
Recovery    = "never" | "retry_safe" | "reconcile"
EndpointRef = { name: Id, binding: FrameRef }

HarnessValue {
  contract: Version
  value: JSON                               // contract-owned representation
}
```

## Frame envelope

Each action below supplies `op` and the pseudotype of `data`.

```text
Frame {
  v: 1
  session_id: Id
  seq: FrameRef
  tx: { id: Id, index: UInt, count: UInt }
  class: "capability" | "control" | "document"
  op: ActionName                            // class must match op prefix
  actor: { kind: "host" | "user" | "agent" | "service", id: Id }
  cause: FrameRef | null                     // causal action, not a runtime pointer
  data: ActionPayload
}
```

## Capability actions

Host-authorized native bindings. Binding is independent of provider
advertisement and does not prescribe a VM or execution mechanism.

```text
capability.bind {
  name: Id
  service: Version
  config: Object                            // public configuration, no secrets
}

capability.unbind {
  name: Id
  binding: FrameRef
}
```

## Model configuration

Initial core state contains empty `main`, no bindings, no provider tools, no
selected model and no extension namespaces. There is no open/close protocol.

```text
control.set_model {
  provider: Id
  model: Id
  route: Id
  credential_ref: Id | null
  adapter: Version
  kwargs: Object
}
```

Runtime versions and resource limits are host concerns, not session lifecycle
frames. Model options require provider/route admission before use.

## Provider-tool actions

The core records the advertisement and captures an opaque handler descriptor. It
does not resolve that descriptor through a shared callable registry.

```text
control.provider_tool.register {
  name: Id                                  // session-local identity
  definition: Object                        // provider adapter owns this schema
  handler: HarnessValue | null               // null for provider-executed tools
}

control.provider_tool.deregister {
  name: Id
  registration: FrameRef
}
```

- `definition` can describe a function tool, hosted search or another provider
  tool type. The core requires no function signature or `parameters` object.
- The contract owns local handler identity, implementation, artifacts and
  validation.
- The core neither interprets nor executes `handler.value`. A provider-executed
  tool has no local handler and needs no fake executable registration.
- The provider receives the rendered definition, not the handler payload.
- Replacement explicitly deregisters/registers in one transaction.
- Pending calls retain the registration from their issuing request's prefix.
- A registered handler grants no native authority. Endpoint calls still require
  current bindings and outside policy approval.
- Non-provider operations require no provider tool or synthetic registration.

## Harness-owned state actions

This action persists harness-specific transitions without defining a shared
execution model or `ctx` representation.

```text
control.extension {
  namespace: Id
  expected_head: Head
  action: Id
  input: HarnessValue
}
```

Contract interface, not another journal action:

```text
contract.initial_state() -> JSON
contract.validate(previous: JSON, action: Id, input: JSON) -> valid | error
contract.reduce(previous: JSON, action: Id, input: JSON) -> JSON
```

- A namespace starts with its contract's initial state at head 0. Its serialized
  state may be a scalar, array, object or contract-defined binary encoding.
- The contract owns its input schema and state shape. The framework supplies no
  shared mutable context or generic object-patch semantics.
- Validate `expected_head` against that namespace at transaction entry.
- Reducers are trusted, versioned, deterministic and effect-free. They may
  change only their namespace. Tool/model/document/binding changes remain
  explicit core actions in the same transaction, not hidden reducer effects.
- A contract must validate the serialized state it consumes. The recorded
  version selects its exact reducer. The framework infers no state
  representation or conversion.
- Missing contracts permit raw frame inspection, not silent skipping during full
  state reconstruction, rendering or live execution.
- Contracts must capture all inputs needed for deterministic reconstruction.
  Mutable paths, pointers or unversioned callback names are not sufficient.
- Harness validation may inspect the candidate transaction and extension state.
  If admission depends on persistent approvals, record those approval actions.
  Replay reconstructs their facts without reauthorizing old work under today's
  host permissions. Current host authority remains an additional live boundary.
- A harness that exposes persistent `ctx` captures assignments, deletions and
  nested mutations at its yield/completion boundaries using its own action
  format. Capture precedes acknowledgement or dependent effect dispatch. The
  core provides no shared `ctx` shape, implicit object patcher or serialization
  policy. Conversation stays in message/context actions, not a private history
  mirror.
- Execution, private command/invocation bookkeeping, helper registration,
  compaction policy and private cancellation use harness actions when durable.
  There are no mandatory framework callable, invocation or command registries.

## Messages

One message type, with standard per-message roles.

```text
ContentPart =
  { type: "text", text: string }
  | { type: "json", value: JSON }
  | { type: "binary", media_type: string, base64: string, sha256: Hash }
  | {
      type: "provider_state"
      provider: Id
      format: string
      base64: string
      sha256: Hash
    }

ToolCall {
  id: Id
  name: Id
  arguments: JSON
}

Message {
  id: Id
  role: "system" | "developer" | "user" | "assistant" | "tool"
  content: ContentPart[]
  tool_calls?: ToolCall[]
  tool_call_id?: Id
}

document.message.append {
  message: Message
  placement: { context: Id, after: Id | null } | null
  display_only?: true
  request?: Id
  source?: FrameRef
  provenance?: { source: string, sha256: Hash }
}
```

- Role is explicit data, not a separate action verb. There is no agent or
  observation role. The harness records the role it chooses for external input.
- Tool calls occur on assistant messages. A tool message requires `tool_call_id`
  and answers that call. Other roles cannot carry tool-call fields.
- Message IDs and tool-call IDs are each session-unique. Content may be empty.
- `request` attributes model output when applicable. It is required for an
  assistant message with tool calls and pins their tool registrations through
  that request's input prefix. It is not required for harness-authored messages.
- `source` and `provenance` are journal metadata, not provider-message roles.
- `placement:null` captures a message without selecting it. `after:null` inserts
  at the beginning. Otherwise, insert immediately after that selected message
  ID.
- A `display_only` append requires a selected system message with no model
  request or tool call. It appears in the transcript and can be inherited at a
  fork cut. Provider projection and tool-pair validation skip it.
- Preserve argument values or raw argument text in `arguments`. Parsing and
  execution validation belong to the harness. No extra call/result message type
  or framework invocation object is required.
- Preserve required provider continuation bytes and original wire call IDs.
  Captured content is authoritative, not a path to a live file.

## Context actions

A context is an ordered selection of message IDs. Mutation changes selection and
preserves historical content. A fork can seed its harness settings in the same
transaction as context creation. Existing effects stay in their original
conversation.

```text
control.context.create {
  id: Id
  base: {
    context: Id
    at: Prefix
    through?: Id
    fork?: { parent: Id, anchor: FrameRef, selected: Id[] }
  } | null
}

control.context.select {
  context: Id
}

ContextEdit =
  { op: "drop", ids: Id[] }
  | { op: "insert", after: Id | null, ids: Id[] }

control.document_mutation {
  context: Id
  expected_head: Head
  edits: ContextEdit[]
}
```

- A legacy base copies membership at `base.at` through the optional anchor. A
  historical fork carries the exact model selection and its structural parent
  separately. The anchor's transaction ends at `base.at`, and every selected
  message already exists at the anchor. An inherited entry can have been written
  by an ancestor of `fork.parent`.
- Select records the default context. A model request names its exact context.
- Check the named context's head at transaction entry. Apply edits in list
  order.
- Resolve relative cuts to exact IDs before admission. Inserted IDs must exist
  and cannot already occur in the selection.
- Replacing content captures a new document and drops/inserts IDs atomically.
- Compaction is harness policy expressed as document/context actions, optionally
  accompanied by extension actions. The core knows no `compact` function,
  summary algorithm, auxiliary-agent protocol or policy for executing proposed
  tools.

## Model actions

A request pins a committed state and a renderer contract, not a Worker snapshot.

```text
control.model.request {
  request_id: Id
  input_at: Prefix
  context: Id
  model_frame: FrameRef
  renderer: Version
  kwargs: Object
  instructions_sha256: Hash
  messages_sha256: Hash
  tools_sha256: Hash
}

control.model.progress {
  request_id: Id
  response_id: Id | ""
  cursor: NonNegativeInteger
  next_poll_ms?: NonNegativeInteger | null
  poll_failures?: NonNegativeInteger | null
  reattach?: "stream"
  deferred?: { adapter: Id, handle: Value }
}

control.model.finish {
  request_id: Id
  status: Status
  usage: Object | null
  diagnostic: Object | null
}
```

- `input_at` precedes the request transaction and pins core and extension state.
- `model_frame` must be the model selection at that prefix. Merge validated
  request kwargs over the selected defaults.
- The harness renderer consumes that state only. All extra variable inputs must
  first be captured in documents, controls or versioned extension actions.
- Dispatch the same owned input after commit. Later actions affect later
  requests.
- An adapter with durable recovery can attach the provider response ID to a
  pending request. Later progress must name the same response ID and advance or
  retain its cursor. The optional polling deadline is a Unix timestamp in
  milliseconds. An absent poll failure count means zero consecutive failures.
  The optional stream mode requests reattachment using the stored cursor.
  Resuming the same provider job retains the request ID.
- A deferred adapter uses an empty `response_id`, no stream reattachment, and a
  non-null JSON handle. Its adapter ID stays fixed for the request. Replacing
  the handle advances the cursor, and each new poll deadline is later than the
  previous one. Poll retries can retain the handle and cursor.
- Commit settled output documents and model finish together. Previews are not
  canonical documents. Each generation retry has a new request ID.

## Native-effect actions

These record operations dispatched through framework-bound native services. They
are not required records for every harness-local function invocation.

```text
control.effect.intent {
  effect_id: Id
  endpoint: EndpointRef
  arguments: JSON
  source_message: Id | null
  key: Id
  recovery: Recovery
}

control.effect.result {
  effect_id: Id
  status: "completed" | "failed" | "cancelled" | "indeterminate"
  result: JSON
}

control.cancel {
  target: FrameRef                           // model.request or effect.intent
  reason: string
}
```

- Durable intent precedes native dispatch. Outside policy authorizes the binding
  and arguments. The service validates recovery classification and idempotency.
- Generic effects do not require a language runtime or framework invocation.
- `indeterminate` records uncertainty. A later confirmed receipt can resolve it.
- Cancel records cancellation requested for the exact pending core operation.
  Harness-private cancellation belongs to its extension contract.
- Cancellation does not roll back effects. A terminal outcome never changes.
  Late receipts retain their effect identity and do not replay earlier work.

## Commit and replay rules

1. One compressed member commits one transaction of JSON Lines frames. Sequence
   starts at 1. Transaction indexes are zero-based and counts must match.
2. Core checks and installed harness admission contracts validate the entire
   candidate transaction before append. Sync before publication or dispatch.
   Duplicate transaction IDs return the existing result only for identical
   input.
3. Reject unknown core verbs/fields, invalid references and complete corrupt
   transactions. Harness-defined verbs live inside `control.extension`
   contracts. Only an incomplete final transaction is repairable.
4. Documents, registrations, model requests and effect intents remain
   identifiable historically. The log is append-only. Checkpoints and indexes
   are caches.
5. Core replay never dispatches handlers, compiles tool programs, attaches
   services or performs I/O. Full reconstruction may run explicitly supplied
   pure extension reducers. Missing required reducer/renderer code is an error,
   not empty state.
6. Provider projection preserves complete, ordered native call/result groups.
   Handler validation and execution are separate harness responsibilities.
7. Process start/stop and attachment/detachment create no lifecycle actions. The
   host owns cancellation, resource lifetime and joined shutdown outside this
   log.
8. Actor fields are audit data, not authority. Host admission controls bindings,
   tools and extension contracts. Credentials never enter frame payloads.
9. IDs are bounded to 256 UTF-8 bytes without control characters. Hash exact
   text, decoded binary bytes or RFC 8785 canonical JSON with SHA-256.
10. Default size thresholds are 8 MiB expanded per frame, 32 MiB per
    transaction, and 1024 frames per transaction. Exceeding a threshold emits a
    warning while the journal continues to validate the transaction.

## Projection

```text
fold(journal through input_at)
  -> bindings, model, provider tools, documents, contexts, core operations,
     harness-owned extension state

harness.render(state_at(input_at))
  -> instructions, messages, provider tools
```

Unchanged provider-visible prefixes remain cache-eligible, not guaranteed hits.
Custom JSON/text protocols can record agent output, harness actions, native
receipts and observation documents with zero provider-tool registrations.

The [lifecycle models](../../../formal/tla/session-lifecycle.md) check separate
contracts. They do not establish refinement of the native session protocol.
