# Minimal context rendering

> Design notes, not a live request-rendering reference. Minimal uses the shared
> [session frames](../../agent/docs/session-frames.md). For its current private
> state, hooks, and recovery, see
> [Minimal private context actions](context-journal.md).

## Boundary

The framework does not define `execute_luau`, a Luau VM, closures, helper
registration or a shared `ctx`. Minimal may implement those through its own
versioned handler and extension contracts. Its
[private context format](context-journal.md) captures implicit assignments and
mutations at yield/completion boundaries. Other harnesses need not implement any
of them.

Minimal's renderer reads one committed prefix. It renders selected documents,
provider-tool definitions and any relevant Minimal extension state. It never
reads unrecorded files, source caches or mutable runtime state while reproducing
an earlier request.

## Instructions and tools

Instruction files and skill text use `document.message.append` with explicit
`system` or `developer` message roles. Replacing a section captures a new
message and atomically drops/inserts exact message IDs. The framework has no
priority sort or hidden prompt-part registry.

A provider-tool registration carries a public provider definition and an opaque
handler descriptor. Minimal's handler contract may contain captured Luau source,
source hashes, entry-point information and permitted endpoint references. Those
fields and their validation belong to Minimal, not the core schema.

Sandbox-only helpers belong to a Minimal extension namespace. They need no
provider advertisement or shared framework callable registry. Minimal's contract
defines how helper definitions and any durable `ctx` state serialize.

## Request boundary

1. Drain completed source work without waiting for unfinished network
   operations.
2. Commit admitted tool, helper, instruction and private-state changes.
3. Select a completed journal prefix and prepare the exact provider request.
4. Record `control.model.request` with that prefix and renderer identity.
5. Dispatch the prepared input after commit.

Concurrent changes affect later requests. Provider-visible tool availability
must agree with what Minimal's executor can actually dispatch. Preserving a
running VM's closures or waiting for a fresh execution scope is Minimal's own
implementation rule. It is not a framework persistence requirement.

The handler payload is not provider-visible. Only its public definition enters
the provider tool schema.

## Compaction policy

Embedding hosts can register `before_compact` callbacks in the Minimal
controller settings. The hook receives the reason, the selected entries and
their effective model messages, the first retained entry, and any instructions.
The first decision can decline compaction or supply the summary. When no hook
decides, the existing summarizer runs. The durable task checkpoints its decision
before it applies the compaction.

Summarizer input includes the complete text of tool results. Tool results above
the expected size emit an advisory.

Minimal may track a compaction job through `control.extension` actions such as
`compact.begin` and `compact.finish`. Its contract defines those names, pending
state, failure handling and any auxiliary model calls. The framework knows no
`compact` function or turn/summary purpose enum.

Minimal forbids execution of proposed summary tools. Failed or incomplete
summaries leave the original document selection unchanged. A successful summary
and its exact cut commit atomically with the private completion action.

The core validates ID references, context heads and provider call/result groups.
Minimal chooses summaries, token budgets, retained suffixes and cancellation
policy. Private reducers cannot hide document or authority mutations.

## Acceptance checks

- Replay reproduces the same input using captured data and the pinned renderer.
- Registration during a request changes only later requests.
- A non-Luau harness can use the same core without Minimal contracts.
- Scalar, list and object extension state work without a shared `ctx` type.
- Handler code and private state do not leak into provider tool definitions.
- A failed summary preserves context and executes no proposed tools.
- Compaction drops selection, not historical documents.
- No replay dispatches model calls, handlers or native effects.

Current lifecycle models do not prove this draft or its extension contracts.
