---

name: verify-session-lifecycle description: Check the TLA+ session lifecycle
models and relevant Lean proof obligations after changing admission,
cancellation, replacement, recovery, run slots, effect receipts, notification
delivery, or shutdown in packages/agent, packages/services, or cpi-minimal. Use
before accepting lifecycle changes or changing a formal model.
---

# Verify the agent session lifecycle

Work from the repository root, three directories above this skill. Follow
`AGENTS.md` verification-quality rules and `.agents/skills/council/SKILL.md`
before retaining new or changed tests, model properties, or proof claims.
Passing the commands below does not approve their leverage.

1. Read `formal/tla/session-lifecycle.md`,
   `formal/tla/check-session-lifecycle.md`, `formal/lean/README.md`, and the
   relevant TLA+ modules, TLC configurations, and Lean kernels.
2. Read the covered functions and their diffs. The initial source review used
   base commit `817a502fe3388a6340942a196e49dca12626372b` with pre-existing
   uncommitted changes. This is manual correspondence, not a source-hash gate or
   a checked refinement theorem.
3. Classify changes as irrelevant to the model, correspondence drift, an
   intentional contract change, or a possible bug. Check intermediate states and
   atomicity, not just function names.
4. Update the TLA+ specification or configuration to describe the source. Keep a
   failing property as a finding when the source violates it. Do not weaken
   bounds, invariants, or fairness assumptions merely to get a pass.
5. Run `./formal/check.sh lifecycle`. Select the pinned TLA+ tools jar with
   `TLA2TOOLS` if it is not at the documented default path. The Makefile invokes
   TLC directly. It must not generate specifications or mutate their text.
6. Require the negative configurations in `formal/tla/negative` to fail on their
   named properties. They use TLC definition overrides from the checked-in
   `*Faults.tla` modules. Parser errors, unrelated violations, deadlocks, and
   unexpected success are not substitutes.
7. Read every model result with the pstack `/statechart` skill. Use that skill's
   installed instructions rather than copying its machine-specific command into
   this project.
8. Run
   `anyzig 0.17.1 build --fork "$HOME/Kit.zig" check test-controller test-services test-agent -j4`.
   Use a fresh `--cache-dir` if stale metadata refers to deleted sources. The
   native replay is part of the ordinary controller tests in
   `packages/agent/src/lifecycle_tests.zig`.
9. For startup or proof-contract changes, also run `./formal/check.sh startup`
   and `./formal/check.sh lean`. Use TLA+ only for model checking. Use the
   pinned Lean version for proofs. Require the negative proof controls and
   theorem dependency audit. Report a missing tool as blocked, not as a proof
   pass.
10. Report TLC model checks, Lean kernel theorems, native tests, manual source
    correspondence, and remaining proof gaps separately. Keep raw logs under the
    selected `OUT` directories. Do not claim the Lean kernels prove the full
    startup protocol or native implementation; read the coverage ledger.

## Coverage

`SessionLifecycle.tla` covers the intended post-ready admission, execution,
cancellation, replacement, reporting, health, and joined-shutdown protocol. It
has two request IDs and one representative outstanding operation per request. It
permits an obsolete operation to finish after a replacement starts.

`RunSlots.tla` covers `RunState.suspendRun`, `resumeRun`, `installFresh`, and
`clear`. It has one user run, one auxiliary run, and two suspension tokens. Run
identity is separate from command identity.

`KeyedEffect.tla` covers the durable-intent and receipt protocol in
`services.Exec.dispatch`. It has one fixed key with matching arguments and at
most two crashes. File durability, directory durability, and exclusive creation
are assumptions.

The source mapping in `formal/tla/session-lifecycle.md` covers agent
`Controller`, `Runtime`, `Session`, `RunState`, `logic`, `domain_ops`, `io`, and
`work`, service `Exec`, and Minimal `Controller`.

## Interpret findings

- `SessionSafety` must satisfy `CancelAvailable` after the notification-failure
  fix. The redundant corrected `SessionCurrentCancel` configuration is
  consolidated into that existing check. The native regression must retain
  targeted policy admission: deny a policy-rejected stop without stopping the
  held service, then admit an authorized stop despite
  `NotificationDeliveryFailed`, stop and join the service, keep ordinary
  cancellation available, and still deny new ordinary work. The finite model
  assumes otherwise authorized cancellation.
- `negative/NotificationBlocksCancel.cfg` retains the historical faulty guard
  and must violate `CancelAvailable`. It is a sensitivity control, not the
  current implementation's expected behavior. Keep the native regression and
  both configurations aligned; never preserve an obsolete native error after
  fixing the product.
- Compare each new counterexample with the source. If a step cannot happen,
  correct the model and record the mistaken assumption. Add native tests for
  plausible implementation failures.
- Minimal reporting and recovery have incomplete implementation correspondence.
  Their intended transitions are not already verified Zig behavior.

No Python runner, generated implementation, trace-conformance checker, checked
composition, unbounded lifecycle proof, or Zig refinement proof is part of this
workflow. The Lean proof portfolio and the missing complete startup-proof port
have their scope in `formal/lean/README.md`.
