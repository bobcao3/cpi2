# Repository boundaries

## Verification quality

This policy covers inline Zig tests, `tests/`, scripts, fixtures, compile-time
checks, TLA+ models and configurations, Lean proofs, and verification harnesses.
Moving a check to another directory does not exempt it.

### Choose the right layer

| Layer                      | What belongs here                                                                                                                                                                          | What it cannot establish                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Types and construction.    | Make invalid local states unrepresentable and encode ownership or valid transitions when the language can enforce them.                                                                    | Correct external data, I/O, or an unverified foreign implementation.                                            |
| Production assertions.     | Internal programmer invariants at the point where violating them is a bug. Prefer a type or constructor when it can enforce the same condition.                                            | Input validation, recoverable errors, durable success, or an end-to-end contract.                               |
| Tests.                     | Observable behavior of the real implementation, algorithms over meaningful input domains, integration boundaries, actual side effects, and named regressions.                              | Exhaustive coverage of an unbounded domain or correctness of every interleaving from a few schedules.           |
| Models and model checking. | Protocol states, concurrent interleavings, admission, ownership transfer, cancellation, crash/recovery, and liveness under stated environment and fairness assumptions. Use TLA+ with TLC. | Native memory safety, real filesystem semantics, or implementation refinement without a checked correspondence. |
| Proofs.                    | Precisely stated unbounded algebraic or inductive properties of explicitly defined semantics. Use Lean. State assumptions, dependencies, and correspondence obligations.                   | Correctness of Zig, Luau, a transport, or an OS merely because a separate mathematical kernel is proved.        |

These layers complement each other. Use several only when each addresses a
distinct failure family or closes a named correspondence gap. Do not duplicate
one claim across all layers to inflate verification counts.

### Council approval and leverage

A retained test requires explicit approval from the council described in
[`.agents/skills/council/SKILL.md`](.agents/skills/council/SKILL.md). Model
properties, model-checking configurations, proof claims, and verification
harnesses require the same leverage review. A successful run is not council
approval.

An artifact has leverage only when the council establishes at least one of
these:

- It catches a family of plausible failures, not just one chosen example.
- It checks a precisely stated full input domain, state space, or quantified
  property. Sampling is not a full-range claim; state its actual coverage.
- It is a regression for a named, evidenced past failure. Link the original
  failure or reproducer. Do not invent a historical failure for a synthetic
  case.

The council must also approve the layer, oracle, scope, assumptions, and
maintenance cost. Count reusable cases or supporting lemmas as part of their
approved contract, not as separate verification wins. No blanket approval for a
file, large matrix, or proof portfolio without inspecting its claims.

Treat unreviewed, rejected, inconclusive, or materially changed artifacts as
unapproved and as having no leverage. Delete tests the council does not approve.
Do not retain unapproved new or changed model/proof claims either. A missing
council or failed advisor run is a blocked review, not permission to
self-approve. Do not relocate rejected checks into assertions or another
harness.

Record the reviewed reference and artifact content, named contract, qualifying
leverage criterion, council verdict, rationale, dissent resolution, and
retrievable review evidence. Material changes invalidate approval. Existing
artifacts are not automatically approved. A portfolio-wide audit is separate
work; this policy is not authority for an unreviewed bulk deletion or a claim
that legacy checks passed council review.

### Tests must distinguish correct from incorrect behavior

Exercise the interface whose contract matters. Use the actual CLI, journal,
filesystem, process, or network boundary when that behavior is the claim. Use
isolated tests for pure behavior when external machinery adds no evidence. Mocks
are useful only when they preserve the boundary the test claims to check. For
denial and no-side-effect claims, observe the real effect and include a positive
control showing that the observer can detect it.

Require an independent oracle. Reject tests that calculate the expected answer
with the implementation under test, inspect constants or prompt wording instead
of behavior, assert only fixture construction, or pass when the relevant
operation never happens. A named external text or ABI contract is different from
incidental wording. Bound waits and control synchronization instead of adding
arbitrary sleeps.

A useful test fails when the promised behavior breaks and survives a
behavior-preserving internal refactor. Prefer properties, meaningful boundaries,
metamorphic relations, complete finite enumeration, or a justified regression
over large piles of single-instance examples. Do not call an arbitrary matrix
complete.

### Assertions are not tests

Use production assertions for internal invariants, not conditions an untrusted
caller, provider, journal, or configuration can violate. Return an error or
model an explicit outcome for those conditions. A check required for
release-mode correctness must not disappear with debug assertions. Test
assertions remain oracles inside tests and are subject to the test-quality gate
above.

### Models and proofs must say something real

A model must name its domain states, transitions, properties, bounds,
abstractions, and fairness assumptions. Justify that its bounds can expose the
relevant failure family. Explain the source correspondence and replay plausible
counterexamples against native behavior. A negative control must violate the
intended property, not fail parsing or type checking. Preserve known findings.
Never weaken the contract, remove the relevant race, or assume progress merely
to obtain a pass.

A proof must state a useful contract and prove it from explicit premises through
actual definitions. Reject vacuous premises, assumed conclusions, manufactured
axioms, and stand-alone tautologies presented as coverage. Simple reflexivity or
helper lemmas may support an approved substantive theorem; they are not
independent verification achievements. Audit dependencies and retain sensitive
negative controls. Keep theorem scope, kernel composition, source
correspondence, and implementation refinement distinct. A pure planner proof
does not replace real authorization or durability tests.

### Required notice for additions

When adding a test, model/property/configuration, proof claim, or verification
harness, tell the user in the same change:

1. What it checks, including its input domain, assumptions, and evidence limits.
2. Its exact name and location, and why that name concisely states its contract.
3. Why it has leverage under the criteria above, with the council verdict and
   review evidence.

An added test without that notice has no leverage and must be deleted. Apply the
same retention rule to added model/proof claims. Do not report success or finish
the change while the notice or approval is missing.

## Boundaries and enforcement

| Rule                                                                                                                                                                                                                                                            | Enforcement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Review lifecycle changes with `.pi/skills/verify-session-lifecycle/SKILL.md`. Use TLA+ with TLC for model checking and Lean for proofs. Keep model contracts, Lean theorem scope, manual source correspondence, and known implementation findings distinct.     | `./formal/check.sh tla` checks the startup and lifecycle models in `formal/tla/`. `./formal/check.sh lean` checks the pinned Lean portfolio and its negative controls in `formal/lean/`. Run both with `./formal/check.sh formal`. `test-controller` requires policy-authorized targeted cancellation after notification failure. The historical faulty guard remains a TLC negative control. These checks do not establish Zig refinement.                                                                           |
| Keep root run-slot writes in `packages/agent/src/RunState.zig`. Mutate authoritative container headers or transfer ownership instead of extending a surviving shallow alias. Review collection changes with `.cpi/skills/ownership-review/SKILL.md`.            | `anyzig 0.17.1 build check` runs bounded AST checks and agent semantic compilation, not a complete ownership proof. `test-ownership` checks supported forms, safe controls, and SHA-pinned historical fixtures. `test-agent` exercises growth, suspension, resumption, and recursive no-subtree-copy contracts. The ownership checks also run in root `test`.                                                                                                                                                         |
| Consume Kit through its exported `kit` module and public APIs such as `kit.unicode.generalCategory`. Keep Kit's Unicode inputs, tables, and generation inside Kit. Do not inspect its dependency builder, module import table, or source files from a consumer. | `./formal/check.sh kit-boundary` runs the Kit boundary check.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Keep direct OpenAI, Codex, and DeepSeek reference metadata in the shared `model_registry` framework package, derived from their own APIs/docs before aggregator fallbacks. Harness overrides must remain explicit and provider-scoped.                          | `anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-model-registry` checks first-party projections, SHA-pinned rejection of the historical aggregator catalog, distinct API/subscription limits, and metadata ownership after injection/discovery teardown. Runtime and capture share `data/codex_client_version.txt`; URL/snapshot checks reject placeholder discovery versions. Runtime `Provider` has no transport field; v2 parsing rejects provider transport inheritance. Root `test` includes the package checks. |
| Persist successful authorization before publishing login completion, independently of model selection/discovery. Preserve saved providers across credential-storage migrations; remembering a login must not activate its route.                                | Exercise loopback OAuth through a temporary binary check that reopens credentials before UI or model acceptance when changing this flow.                                                                                                                                                                                                                                                                                                                                                                              |
| Generate skill glob fixtures from the pinned vanilla Pi revision and its required minimatch version.                                                                                                                                                            | Confirm the reference revision and dependency version before writing fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| When changing a fixed tool catalog, upgrade restored tool definitions through Controller. `Config.capabilities` only seeds new journals. Preserve dynamic registries in clients that do not own a fixed catalog.                                                | When changing the fixed catalog, reopen an old journal with the actual CLI, run the affected tools, and verify the append-only journal prefix.                                                                                                                                                                                                                                                                                                                                                                        |
| When changing service contracts, verify denial against real side effects and preserve cancellation and borrowed-context lifetimes.                                                                                                                              | `anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-controller test-services` exercises loopback denial, actual files and processes, reentry, cancellation, and joined shutdown. `./formal/check.sh controller-boundary` runs the gate and checks that it rejects SHA-verified historical Minimal, chat, and effects source files.                                                                                                                                                                                       |
