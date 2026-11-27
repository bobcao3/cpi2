# Lean proof contract

TLA+ remains the model-checking language. TLC explores configured interleavings,
checks liveness under stated fairness assumptions, and produces counterexamples.
Lean checks unbounded mathematical safety and algebraic claims. Native and CLI
tests remain responsible for the concrete implementation boundaries.

This directory is not a Zig or Luau verification framework. A Lean theorem is a
theorem about the definitions it names. The source correspondence below is
manual until a checked refinement or extraction path exists. The three kernels
are independent; their composition is not proved. In particular, the publication
kernel's owner replacement is not a proof of native crash recovery or joined
worker replacement.

## Run the checks

From the repository root:

```sh
./formal/check.sh lean
```

`./formal/check.sh formal` runs both the TLC and Lean suites. The proof checker
accepts `LEAN=/path/to/lean`. It uses a matching executable on PATH or an
already installed `~/.cache/cpi-formal/lean-4.35.0-linux/bin/lean`. It never
installs tools.

The pinned toolchain is Lean 4.35.0. The official Linux archive is
[lean-4.35.0-linux.tar.zst](https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-linux.tar.zst),
with SHA-256 `7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d`.
Use another official platform build of the same version when needed.

The council-approved substantive contracts are registry batch idempotence,
reachable committed-only publication and preservation of known receipts, and
reachable joined-release ordering. Guard lemmas, conditional update/frame
clauses, induction scaffolding, and the visible-receipt corollary support those
contracts; they are not independent verification wins. The distinct-source
overwrite example limits the source-isolation claim. See the
[portfolio audit](../../docs/verification-audit.md) for decisions and evidence.
Negative controls reject false arithmetic, false source isolation, early
publication, unjoined release, an incomplete proof, and a manufactured axiom.
The dependency audit permits only Lean's standard `propext`, `Classical.choice`,
and `Quot.sound` axioms. Proof holes, additional axioms, native decision or
unsafe proof escapes, and a missing or changed portfolio fail the gate. Logs go
under `.zig-cache/lean` or the explicitly selected `OUT` directory.

## What earns a proof

A property belongs here when an unbounded argument is useful, the domain can be
specified precisely, and a native observable can distinguish its failure. Do not
add proofs that merely restate a Boolean flag or assume the desired invariant.
Prove preservation from initial states through permitted transitions. Record
external assumptions separately from the conclusion.

The first proof package covers three small kernels. It does not port the entire
old startup invariant. Removing the old prover must not turn that missing port
into a claim of equivalent coverage.

| Priority | Obligation                           | Exact boundary                                                                                                                                                                                                                                                                                                                  |
| -------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| First    | Registry batch algebra.              | Reapplying the same batch is idempotent. Subordinate clauses establish assignment, removal, source replacement, and unaffected-key behavior relative to the defined `latest` selector. A separate last-wins characterization of that selector is not proved. Native validation/rejection and authority are outside this kernel. |
| First    | Committed-only publication.          | Every published candidate has its own successful synchronization receipt. A prepared candidate is not sufficient. An uncertain commit poisons the attachment instead of authorizing publication or an ordinary retry.                                                                                                           |
| First    | Stale-owner exclusion.               | Publication rejects a candidate whose owner differs from the current worker identity. Owner replacement resets the modeled phase by definition; its removed projection lemma is not credited as separate coverage. Identities are unbounded naturals, not wrapping machine counters.                                            |
| First    | Joined resource release.             | Closing stops new owned jobs. Reachable release requires an empty modeled owned-job set. Whether native terminal results and canceled waiters preserve unjoined ownership remains a manual correspondence obligation, not an approved standalone proof claim.                                                                   |
| Next     | Semantic replay and historical cuts. | Folding transactions in chunks or in one prefix gives the same state. A historical result depends only on that complete committed prefix. Replay produces data, not effect-dispatch instructions.                                                                                                                               |
| Next     | Transaction retry identity.          | Repeating an identical ID, actor, and payload returns the original commit. Reusing an ID with different content rejects without a new state transition.                                                                                                                                                                         |
| Next     | Extension entry-head discipline.     | All actions in a namespace compare against the transaction-entry head while consuming sequential candidate state. Rejecting any action publishes none of the candidate.                                                                                                                                                         |
| Next     | Projection and registration pinning. | A request retains its selected context, renderer contract, and exact tool-registration references. A later replacement cannot rewrite an earlier request's projection.                                                                                                                                                          |
| Next     | Recovery uncertainty.                | An unfinished effect without a trustworthy receipt remains uncertain. Recovery itself never authorizes that effect's dispatch. This is not an exactly-once theorem for new explicit calls.                                                                                                                                      |
| Later    | Complete startup protocol safety.    | Port the old startup invariant, including validated initialization, both preparation results, monotone acknowledged prefix, actor activation, crash/reopen, and historical ownership. Keep this gap explicit until the Lean statements and correspondence are checked.                                                          |

## Registry laws need real hypotheses

Different source names do not imply independent updates. The current registry
has global tool names. An explicit assignment can replace another source's
entry, and an explicit removal can remove it. The unaffected-key clause
therefore names all excluded updates. Commutativity needs disjoint explicit
writes and removals, plus source-replacement conditions. Do not prove
unconditional cross-source noninterference against a different policy than the
implementation has.

Source identities must also be canonical. Configured MCP server names and their
accepted aliases are not automatically different sources. Any future theorem
about full-source refresh must use the configured source identity even when the
new catalog is empty. An alias-spelling theorem is an implementation obligation,
not something an abstract source-ID type proves for free.

Registration does not imply successful execution. A checked source factory can
return the wrong kind of value, exhaust its budget, fail, or perform a denied
operation when explicitly invoked. Captured bytes, checked metadata, atomic
publication, validation rejection, and preservation of authority are
implementation obligations requiring real boundary evidence. The planner has no
authority field and proves none of those native outcomes. It does not say that
every lazy helper returns successfully.

## Durability and lifetime assumptions

The publication kernel records a known successful sync receipt. Actual write,
file-sync, and directory-sync semantics remain environmental obligations. An
uncertain result may have appended bytes. The proof must not identify uncertain
commit with unchanged disk. Reopening requires independent journal validation
before another attachment can proceed.

The resource kernel counts owned jobs until an explicit join transition. It does
not assume that cancellation is rollback or that an uncooperative transport
eventually returns. It proves release ordering, not unconditional shutdown
termination. Cached arenas and native pointer aliasing still require ownership
review and allocation-failure tests.

Permissions remain an independent input to dispatch. Registration must preserve
that input, but the removed acceptance/authority wrapper supplied no evidence
for it. Real Controller denial and positive-control tests exercise this
obligation. The retained kernels prove no Luau policy branch, shell restriction,
or remote server implementation.

## Correspondence obligations

| Kernel             | Implementation                                                                                                                                                                                                  | Native evidence                                                                                                                                                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Registry.          | Minimal deferred_tools.luau install and source replacement. Definition payloads are opaque in Lean. Parsing, reserved names, schema checking, compilation, and limits precede acceptance in the implementation. | test_deferred_tools.py covers malformed batches, duplicate definitions, reserved names, replacement, removal, and pinned old helpers.                                                                                              |
| Publication.       | Minimal's prepared namespace and receipt, agent.prepareTools, SessionJournal.append, and WorkerId-targeted Controller delivery.                                                                                 | DeferredTools_tests.zig holds a real effect, submits asynchronous registration, and replaces its worker. CLI tests cover atomic replacement and reopening. Native journal tests cover uncertain sync and no candidate publication. |
| Resource lifetime. | Controller.close joins foreground services. Gateway.deinit closes discovery admission, cancels and joins its group, then frees clients and configuration.                                                       | MCP tests block discovery and calls, cancel waiters, close the gateway, and check transport join without effect replay.                                                                                                            |

The Lean code does not import native code. These rows do not establish
refinement. The next useful bridge is a shared executable case format checked
against both a Lean reference and the real CLI, followed by explicit trace
correspondence for publication and join events. Differential tests add evidence,
not a refinement theorem.

## Deliberate exclusions

- No proof of Zig or C++ memory safety, Luau evaluation, arbitrary helper
  source, garbage collection, JSON parsing, gzip, CRC, hashing, or OS
  durability.
- No exactly-once claim for remote effects or model generation. A disconnected
  provider may still charge for a generation; a new explicit tool call is new
  work.
- No assertion that failed writes leave storage unchanged.
- No unbounded liveness claim under arbitrary I/O, crashes, starvation, or
  memory exhaustion. Keep liveness exploration and assumption controls in TLC.
- No theorem that per-server locks imply a wall-clock startup or latency bound.
- No equivalent replacement of the former complete startup proof yet.

## Proof discipline

Follow the
[repository verification-quality policy](../../AGENTS.md#verification-quality)
and its council gate before retaining proof claims or verification controls.
Kernel acceptance and theorem counts do not establish leverage. Supporting
lemmas belong to their approved substantive contract, not independent coverage
claims.

Use the pinned Lean release in lean-toolchain and the standard library only.
Check proof terms with Lean's kernel. Missing tools fail the proof target; they
never turn into a skipped pass. Reject incomplete proofs and audit theorem axiom
dependencies. Negative controls must fail at the intended false claim, not on an
import, parser, or unrelated tool error. A cross-source overwrite example guards
against accidentally claiming a stronger source-isolation policy.

The build must not download tools, generate model specifications, or modify
proofs to get a pass. Tool setup is a separate operator or environment step.
