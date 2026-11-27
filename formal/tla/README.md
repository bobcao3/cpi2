# Unpublished async startup

> **Verification scope.** These TLA+ specifications support TLC model checking.
> [Lean proof contracts](../lean/README.md) define the separate proof portfolio.
> Neither establishes refinement of the implemented session journal.

For the post-startup agent session contract, read
[Agent session lifecycle contract](session-lifecycle.md). Run its checks with
[Check the session lifecycle](check-session-lifecycle.md). That contract has
separate finite models, a corrected native cancellation regression, and a
historical guard-failure control. The startup model scope below is unchanged.
Proofs now use Lean.

This model supports the shared framework startup optimization for a fully ready
usable UI below 50 ms. It checks ordering, ownership and failure rules. It does
not prove a latency bound.

```mmd
flowchart TD
  reserve[Retain generation and borrows] --> vm[Owned VM prep]
  reserve --> journal[Owned journal prep]
  vm --> join[Consume both joined results]
  journal --> join
  join --> private[Private bootstrap]
  private --> write[Append final snapshot]
  write --> sync[Successful sync]
  sync --> publish[Publish current generation]
  publish --> intent[Persist separate effect intent]
  intent --> dispatch[Dispatch]
  reserve --> close[Close or failure]
  private --> close
  sync --> close
  close --> drain[Join outstanding jobs]
  drain --> release[Release borrowed lifetime]
```

## Files and scope

`Startup.tla` is the unbounded abstract protocol. Its state uses scalar
variables. The read-only `s` record is a view for the finite detail module. `g`
ranges over `Nat`; `MayStart` is always true in the unbounded specification. TLC
explores the explicit bounds in its configurations. The unbounded definition
alone is not a proof.

The proof workflow uses the pinned Lean package in `formal/lean/`. Its initial
kernels prove registry algebra, committed-only publication, stale-owner
exclusion, and joined release in their own transition systems. The former
complete startup proof has not been ported. Do not treat these narrower Lean
claims as an equivalent replacement of the full startup invariant.

`StartupFinite.tla` adds two-entry catalog checks, fixed/preserve modes,
unchanged-entry evaluation avoidance, named rejection outcomes, torn tails and a
crash counter. Its steps either restrict an abstract protocol action or stutter
the abstract state. This correspondence is by inspection, not a separate checked
refinement theorem.

The four configs check the following finite graphs.

| Config                | Generations | Catalog entries |   Crashes | Additional property                                                               |
| --------------------- | ----------: | --------------: | --------: | --------------------------------------------------------------------------------- |
| `StartupSafety.cfg`   |           2 |               2 | at most 1 | `Inv`, `CatalogSafety` and `TailSafety`, with arbitrary enabled faults and close. |
| `StartupSuccess.cfg`  |           1 |               2 |         0 | Eventually ready and a post-ready effect.                                         |
| `StartupTerminal.cfg` |           1 |               2 |         0 | A blocked or closing startup eventually releases its lifetime.                    |
| `StartupRecovery.cfg` |           2 |               2 | at most 1 | Eventually permanently ready after successful work and any allowed crash.         |

These are finite exhaustive TLC checks, not unbounded liveness proofs. No state
constraint, symmetry reduction or depth cutoff removes reachable states. The
generation and crash bounds are explicit action restrictions. TLC uses its
normal state fingerprints; its collision estimates remain in the raw logs. No
unbounded theorem for this complete startup specification is currently claimed.

## Safety and histories

The compound invariant contains typing, preparation ownership, phase relations,
validated initialization facts, generation matching, historical observations and
prefix ordering. Publication history must be a subset of synced, joined,
validated and initialized generations. Dispatch history must have a separate
post-ready intent and publication. Failed or pre-publication canceled
generations never appear in publication history. Release history must have both
preparation results joined. If a runtime actor was started, its joined history
must also precede release. Installation history records both the destination
generation and the result tag.

Each preparation result has one abstract owner slot, `task`, `startup` or
`none`. Only a completed result can transfer, and transfer changes completion to
joined. The mutable candidate is the single protocol state owned by startup,
then by the published actor. This is an ownership protocol specification, not a
proof that native pointers have no aliases.

Both handoffs now take independently supplied tags. `JoinVM(tag)` consumes a VM
receipt and `JoinJournal(tag)` consumes a journal receipt, each requiring a
current-generation match. The native futures structurally prevent stale reuse
through exclusive result ownership; native code need not have numeric tag
fields. The model conservatively admits cached old receipts to test both
generation guards.

`Activate` starts an unpublished actor in `waiting`. It cannot observe or
dispatch provisional work. Publication both attaches the durable runtime and
opens its publication gate. Close changes a waiting or active actor to
`draining`. `JoinRuntime` represents the actor and its callback/operation
shutdown being joined before borrowed resources are released. The abstraction
permits private activation before sync, while the implementation orders it after
sync. Publication still requires sync in every case.

`complete` and `stable` are sets of immutable member identifiers. Their
increasing order represents an append-only sequence, relative to an unchanged
pre-existing baseline prefix. `IsPrefix(stable, complete)` states that no
complete-but-unacknowledged member precedes a stable member. Successful sync
advances `stable`. Unbounded stable-member monotonicity remains a future
complete Lean startup-proof obligation. TLC checks the configured
prefix-consistency properties. Crash may retain any complete-member prefix
containing `stable`. Core `Reopen` is a stutter, not a proof of a parser or byte
repair.

The finite detail ties a torn current write to its generation and exact retained
complete prefix. A synced generation cannot become torn. A newly torn generation
must be excluded from the crash-retained prefix. `TailSafety` checks that all
historical torn generations stay outside both `complete` and `stable`, including
after subsequent startup/sync. `DetailReopen` clears the incomplete suffix only
when the retained complete prefix is unchanged, ordered after `stable`, and
excludes the torn generation. It never promotes a merely read member durable.
This is an abstract member-exclusion and prefix-preservation guarantee, not a
partial-byte model. Native complete-member validation remains assumed. Gzip, CRC
and rejection of corruption followed by later valid members remain native
checks.

Crash destroys the process-local tasks and candidate. It is not an in-process
free that can waive joining. Normal close and failure unwind must join before
recording a release. Historical observations survive crash so an earlier effect
is not invalidated merely because the current phase is no longer ready.

`Close` and `Release` are per-generation Worker/startup-owner lifetime
transitions. `Start` after `dead` means a fresh owner or reopened Controller,
not a launch on the same closed Controller. There is no Controller-lifetime
closing latch in this model. The native one-way latch and launch-after-close
rejection require native review/tests.

Existing core `Fail` is enabled in phase `sync` before and after `Activate`,
whether or not sync has succeeded. The finite fault and terminality relations
include it, so prepublication allocation/spawn/activation failure can abort with
a runtime absent or parked. `Close` also races parked activation and represents
cancellation's publication gate and joined unwind. No redundant
activation-failure action is needed. Post-publication first-tick, sink and
ordinary runtime faults are excluded. Publication safety is not a proof of fully
operational readiness under arbitrary out-of-memory failures.

## Liveness assumptions

The liveness specs use weak fairness of their next-state action. They do not
assume ready. Successful preparation, private application steps and I/O
completion are explicit enabled transitions. Their finite progress graph has no
non-stuttering work cycle. Fairness therefore excludes an infinite refusal to
perform remaining enabled work.

Success excludes faults, close and crashes. Terminality permits either
preparation outcome, admission or initialization rejection, write/sync failure
and close, but excludes crashes. Recovery permits one crash and no other faults
or close. It can restart once and requires successful subsequent work. There is
no unconditional progress claim under repeated crashes, nonterminating
application code, starvation, infinite I/O, or allocator exhaustion.

## Reproduce

Use TLC for these models and Lean for the separate proof portfolio. The Makefile
verifies the TLA+ tools 1.7.4 jar checksum and invokes those tools directly. It
does not install software, copy snapshots, generate models, or mutate
specifications.

```sh
export TLA2TOOLS="$HOME/.cache/cpi-formal/tla2tools-1.7.4.jar"
OUT=/tmp/cpi-startup-check ./formal/check.sh startup
OUT=/tmp/cpi-lean-proof ./formal/check.sh lean
```

Set `TLA2TOOLS` to the existing jar. The Lean checker uses its pinned version
and accepts an explicit `LEAN` executable. Each tool writes logs under its
selected `OUT` directory. The Lean target rejects proof holes and unexpected
axiom dependencies. Negative TLC configurations must produce their intended
named violation with exit status 12. Parser errors and other violations fail the
check. See [Check the session lifecycle](check-session-lifecycle.md) for setup.

`StartupFaults.tla` contains seven deliberate faulty action definitions. The
checked-in configurations under `negative` select them with TLC definition
overrides. They remove the durable publication guard, allow a provisional
external effect, remove each generation-match guard, remove preparation/runtime
join release guards, and allow a torn current generation into the retained
complete prefix. Both stale-handoff configurations disable crashes and replay a
generation-1 receipt during generation 2 after normal close and joined release.
They do not require a live task surviving process death. The torn-prefix
configuration must violate `TailSafety`. Lean has separate negative controls for
false arithmetic, unsafe publication, unjoined release, false source isolation,
incomplete proofs, and a custom axiom. None of the TLC fault definitions changes
the protocol modules.

## Correspondence and limits

The startup source correspondence is manual. Review `Controller.launch`,
`Runtime.bootstrap`, `Session.init`, `Session.commitBootstrap`, and the
publication and joined-shutdown boundaries when they change. The selected
implementation uses `Controller.launch`, two independently owned `Session.init`
preparation jobs, private `Runtime.bootstrap`, one `Session.commitBootstrap`
append and a parked actor startup acknowledgement before the closing recheck and
runtime attachment. Publication opens the actor gate under the Controller mutex.
It has no extra async final writer.

The model assumes atomic domain transitions, exclusive native task ownership,
correct generation reservation, immutable input and correct native validation.
Validation stands for real Controller admission and grants, with metadata and
execution from one evaluation. The model does not interpret Luau or prove that
validation predicate. The finite catalog abstraction records matching/changed
entries and preserve behavior. It does not encode source versions, arbitrary
tool removal, restored command contents or a byte-for-byte rollback theorem.

The model assumes successful sync protects the acknowledged prefix and native
recovery validates complete members, repairs only an incomplete trailing suffix
and rejects corruption followed by a later valid member. It does not verify
gzip, CRC, sequence decoding, filesystem durability, native cancellation APIs,
allocation failure at every instruction, JSON/container aliasing, VM memory
safety, callback delivery exactly once across crashes, or post-ready effect
execution semantics. `Intent` abstracts an already persisted per-effect intent;
startup durability alone is insufficient.

The disjoint results still share the supplied `gpa` and `std.Io` backend. Both
must support concurrent use. The startup design separates mutable Session,
VM-owner and journal-result ownership; it does not claim no allocator or backend
is shared. Minimal uses `std.heap.smp_allocator`, framework tests use
`std.testing.allocator`, and generic Controller already has concurrent
runtime/notification tasks. Supported allocator/backend contracts remain a
native gate, not an allocator proof here.

Native activation failure, notification failure and the concrete joined shutdown
APIs remain correspondence obligations. There is no machine-checked refinement
from Zig to TLA+. Actual performance, fully ready UI timing, native denial
tests, joined-close tests and source review are separate gates.
