# Session journal persistence

This guide covers how the journal stores, publishes, and recovers
[session state](session-frames.md). The
[frame examples](session-frame-examples.md) show complete JSON Lines
transactions. Both Minimal and Terminus use this storage path.

## Components

Start with the [session protocol exports](../src/session_protocol.zig) for
frame, transaction, and reducer definitions. Follow the
[writer](../src/SessionJournal.zig), [read-only view](../src/SessionView.zig),
or [Luau adapter](../src/LuauJournal.zig) for the part you need to change.

See the [framework boundary](session-frames.md#framework-boundary) for what the
protocol leaves to a harness.

## Transaction storage

Each compressed member holds one complete JSON Lines transaction. Only its last
sequence is a committed position. Writers append to that prefix. New journals
use Zstandard 1.6.0. Each transaction starts with a checksummed length in a
Zstandard skippable frame, followed by a checksummed data frame. Standard
Zstandard decoders can read the concatenated stream. Existing gzip journals and
new paths explicitly ending in `.gz` use gzip members. See the
[frame format](session-frames.md#frame-envelope),
[Zstandard framing](../src/journal_zstd.zig), and
[gzip framing](../src/journal_gzip.zig).

`PATH.lock` and the journal inode exclude other writers. The writer rejects
symlinks, nonregular files, and hard links. It syncs the parent folder at open.
`memory:` uses the same transaction rules without disk I/O.

## Candidate publication

A successful durable boundary follows this order.

1. Capture the harness's private state and new messages.
2. Validate and encode the complete transaction.
3. Prepare independently owned core and extension candidates.
4. Reserve publication metadata and output storage.
5. Append the complete compressed member and synchronize the file.
6. Publish the prepared state.
7. Acknowledge the boundary or dispatch dependent external work.

A validation or allocation failure before append leaves committed state
unchanged. A failed write or synchronization has an uncertain result. The
journal becomes poisoned and rejects further commits in that attachment. No
successful receipt or candidate state is published for that uncertain commit.

An identical retry of a transaction identity returns its earlier committed
position. A different transaction with that identity rejects.

## Read-only followers

The writer posts the synced prefix in two slots in `PATH.lock`. Each slot binds
the inode, byte cut, final sequence, and session ID. A torn write leaves the old
slot usable. A failed post does not fail the journal commit.

`SessionView` reads only the posted prefix, even after writer exit. It never
starts a Worker or fixes the tail. Old files with no post can be read once the
writer is gone. A slow watcher gets the latest changed view.

## Replay and recovery

Replay validates every complete transaction and reduces actions in sequence. It
does not execute helper source, dispatch effects, or repeat a model request. A
missing extension contract or renderer blocks complete reconstruction.

Opening a large Worker journal can decode and parse ahead in bounded chunks. One
consumer prepares state in transaction order and owns the history cache. The two
queues each hold one chunk. A chunk stops after 16 transactions or about 1 MiB
of expanded data, with room for a single larger transaction. Replay falls back
to sequential processing when concurrency is unavailable.

A complete corrupt member, malformed frame, wrong session identity, sequence
gap, duplicate transaction, or invalid reduction rejects the journal. Rejection
preserves the original bytes, including any incomplete suffix.

An incomplete final member is not a committed transaction. Open remembers the
last valid offset without truncation. A later valid append repairs that suffix
only after its candidate has passed validation. A rejected append does not
repair it.

Reopening a Worker goes beyond pure replay. The Luau runtime restores private
context and rebuilds tool closures from recorded definitions, not live stacks.
An interrupted invocation does not resume its Lua stack. A harness that recorded
provider progress may separately
[resume or retrieve the same model response](openai-transports.md#native-resume).
Unresolved native effects receive an `indeterminate` receipt. Recovery does not
claim the effect failed to happen and does not dispatch it again.

## Messages and private execution state

Messages live in the core log. A context picks the messages for a request.
Compaction changes that pick, not the log. Private `ctx` is separate:
[Minimal](../../cpi_minimal/docs/context-journal.md) saves key edits;
[Terminus](../../cpi_example_terminus/docs/context-journal.md) saves a whole
changed value.

## Ownership

`SessionJournal.frame` copies a frame for its caller. A borrowed cache view can
expire on the next transaction read. Treat borrowed extension values as
read-only. A mutable context must not alias them.

## Verification scope

Native tests cover schema and grouping, atomic reduction, historical
projections, private-state replay, allocation failures, gzip corruption,
incomplete-tail repair, writer exclusion, transaction retries, and uncertain
synchronization.

Real CLI checks cover tool effects, implicit private mutation, restart,
compaction, branching, cancellation, and negative old-format fixtures.

The lifecycle models remain separate contracts. TLC checks those models, not Zig
refinement or filesystem durability. Native and CLI tests do not prove
correctness under every power-loss or filesystem failure.
