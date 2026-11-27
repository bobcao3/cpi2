# Verification portfolio audit

## Status and scope

The audit started from `6612c0be` under `AGENTS.md#verification-quality`. Two
read-only advisor seats independently reviewed six first-party batches, then
received one parent-curated cross-examination. The pass cap was two. The author
did not supply an approval vote. No `council-*` profiles were installed:
fallback `oracle` used GPT-6.1 Sol with forked, context-aware history; fallback
`reviewer` used DeepSeek Flash with runtime-default-unknown context, not claimed
fresh.

This is a contract-by-contract audit, not a correctness certificate or a count
of independent verification achievements. The inventory includes inline Zig
tests, Python and Node drivers, support functions, TLC configuration properties,
Lean claims, assertions, unreachable branches, and compile-time restrictions.
Vendored and generated dependency trees were excluded. Six production
distribution programs were initially misclassified by the extractor and were
preserved, not deleted.

The retrievable per-contract ledger records names, locations, reviewed content
hashes, criteria, scope limits, both advisor judgments, dissent and actions:

- Maintainer-local evidence directory: `verification-audit/`.
- Parent decision: `memo.md`; detailed records: `ledger.json` / `ledger.tsv`.
- Exact reviewed changes: `candidate-edits.json`; advisor run IDs: `runs.json`.
- Reports: `p1-<batch>-<seat>.json` and `p2-<batch>-<seat>.json`.

Review transcripts and working evidence remain outside version control. Approval
applies to the recorded content and contract; material changes need review.
Supporting cases, import roots, fixtures and lemmas belong to their parent
contract, not additional wins. Green commands do not establish approval.

**The audit and authorized follow-up are accepted at their recorded scopes.**
The unchanged root baseline passed; the original post-audit aggregate failed
three MCP cases because the reviewed helper mistook premature `Timeout` results
for true deadline expiry. That failed run remains recorded, not reclassified as
a pass. The operator authorized correction and investigation of exposed defects.
[Verification fixes](verification-fixes.md) records the exact follow-up
contracts, council decisions, reproductions and final passing execution (195/195
aggregate build steps; separate 36/36 Node cases). The original separate Node
run passed 35 cases; it is not evidence for later edits.

## Required change notice

The following are the new or strengthened verification contracts, including
their supporting harness changes. All domains are the stated finite cases or
controlled schedules, not exhaustive implementation correctness. The exact names
identify the observed boundary rather than an implementation detail or an
unobserved claim. Both seats approved the specified source corrections in the
corresponding Pass 2 reports; execution results are separate. The original MCP
helper's source approval did not excuse its runtime failure; its corrected
content needs separate approval.

| Contract, domain and evidence limit                                                                                                                                 | Exact name and location; naming rationale                                                                                                                                                                                                                                                                                                                                                                        | Leverage and review                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A forged WebSocket upgrade emits no frame bytes; valid loopback upgrade supplies the positive observer. One forged variant, not all transports.                     | `packages/agent/src/responses_transport_tests.zig` — `WebSocket transport rejects a forged upgrade without sending a model request`. Names the actual joined wire observation.                                                                                                                                                                                                                                   | Plausible handshake-admission failure family; both `p2-agent-*`, A136.                                                                                   |
| Accept SHA-256(`hello`) and reject a one-hex-character mismatch with unchanged binary data/schema.                                                                  | `packages/agent/src/session_frame_tests.zig` — `binary message parts validate the decoded content hash`. The name now has a rejecting integrity oracle as well as a valid vector.                                                                                                                                                                                                                                | Digest-comparison failure family; both agent reports, A151.                                                                                              |
| Identical read-to-write rewrite under read-only versus read+write grants; observe absent versus exact real file bytes.                                              | `packages/agent/src/controller_tests.zig` — `a policy rewrite cannot escalate a read grant into a file write`. Names the rewritten grant boundary rather than four nondistinguishing policy examples.                                                                                                                                                                                                            | Ignored rewrite or target-grant enforcement failures, with same-effect control; both agent reports, A066.                                                |
| Explicitly root the existing bounded-copy/deep-JSON cases in the launch target. No unbounded ownership/recursion theorem.                                           | `packages/agent/src/launch_tests.zig` anonymous import block adds `json.zig`; the existing tests remain named in `json.zig`. This is support wiring, not another test.                                                                                                                                                                                                                                           | Execution-wiring support for A090/A091; both agent reports.                                                                                              |
| An in-range partial value survives while a complete field wholly beyond the scan limit is ignored; empty/truncated cases remain.                                    | `packages/cpi_minimal/src/args.zig` — `argument scan stops at its byte limit and never reads past the text`. Names the meaningful byte boundary.                                                                                                                                                                                                                                                                 | Limit-removal/truncated-input failure family; both `p2-minimal-core-*`, M066.                                                                            |
| Benign heading/emphasis words survive while the selected OSC/BEL injection does not; existing expanded-output observations remain.                                  | `packages/cpi_minimal/src/markdown.zig` — `untrusted Markdown cannot inject terminal links and expanded tools retain large output`. Positive text observations prevent an empty-renderer false pass.                                                                                                                                                                                                             | Filtering/content-loss family, not universal terminal security; both Minimal core reports, M075.                                                         |
| Match the 4,220 recorded glob cases, checking their recorded Pi revision and minimatch version. Not full Unicode/minimatch parity.                                  | `packages/cpi_minimal/src/skill_paths.zig` — `minimatch Unicode units and POSIX categories`. Names the corpus behavior; provenance checks support it.                                                                                                                                                                                                                                                            | Independent finite reference-corpus family; both Minimal core reports, M088.                                                                             |
| Reject array nesting above the limit and accept exactly the limit; reject duplicate keys while a distinct-key object preserves expected values.                     | `packages/mcp/src/Json.zig` — `json depth is bounded` and `duplicate object keys are rejected`. Names the two actual parser obligations.                                                                                                                                                                                                                                                                         | Boundary and always-reject-parser failure families; both `p2-backends-*`, B022/B023.                                                                     |
| Observe blocked-source/call entry and fail rather than auto-release on a true fixture deadline; cancellation must still propagate. Selected schedules only.         | `packages/mcp/tests/mcp.zig` — `waitFixture`, supporting the four cold/cache/cancellation/source-independence tests. It is fixture support, not a native liveness proof.                                                                                                                                                                                                                                         | Controlled concurrency failure families; both backend reports, B033–B036. **Original helper failed at runtime; see the separately reviewed correction.** |
| Create/read/delete the exact marker pathname before denied sandbox attempts; preserve the nested infinite-loop budget case. No complete sandbox-security proof.     | `packages/model_registry/tests/registry.zig` — `sandbox excludes effect capabilities and stops an infinite loop even inside pcall`. Names actual missing capabilities and execution limit.                                                                                                                                                                                                                       | Denial-observer and budget failure families; both backend reports, B072.                                                                                 |
| Hold a real process behind a release file until its initial running state is observed, then require its completion event without provider work.                     | `packages/services/tests/test_process.py` — `test_background_completion_events_are_available_without_provider_calls`. Names the real service event boundary.                                                                                                                                                                                                                                                     | Missed/premature/duplicate completion-event family; both backend reports, B099.                                                                          |
| Before status-path/duplicate-UID denial, positively execute the same marker child/touch command through the same observer and clear its marker.                     | Native `packages/ghostmux/src/test_fixture.zig::marker_control` supports `existing status destinations reject launch and preserve caller files` and `symlink status destination never launches or overwrites target`; Node `server-status.test.mjs` status-destination case and `server.integration.test.mjs` concurrent-client case carry equivalent controls. These names identify the actual denied boundary. | Same-effect denial controls; both `p2-boundaries-terminal-*`, T017/T030/T051.02/T052.01.                                                                 |
| After controlled rejection, observe the original symlink type/target and target bytes on the startup/daemon lock paths. Not inode identity or a symlink-race proof. | Native `test_lifecycle.zig` — `regular socket files and symlink startup locks never get replaced`; Node `server-lifecycle.test.mjs` — `unsafe socket directories, regular files, and symlink locks are never replaced`. Names the path-preservation obligation, with the narrower observed scope recorded.                                                                                                       | File/link-replacement failure family; both boundary reports, T019/T047.04.                                                                               |
| Run the individually reviewed Node behavior cases through the package command, with Sharp and a current explicitly selected binary.                                 | `packages/ghostmux/package.json::scripts.test` runs `node --test tests/*.test.mjs`. Names a package test command, not a root Zig gate.                                                                                                                                                                                                                                                                           | Supporting execution wiring for the 35 case-level contracts in `node-cases.json`; both boundary reports, T-C1.                                           |

Other edits narrow names rather than add stronger checks:

- Agent: in-memory committed outcome, source execution beyond 64 KiB,
  conversation field projection, text-preview forwarding, and bounded reconnect
  retries.
- Minimal: one caller-owned prompt buffer/optional sections, unsupported-command
  diagnostic, paste/completion behavior, and line reporting at the file-size
  cap.
- JSON/MCP: selected depth 4096, caller-owned-arena allocation-failure
  propagation, and preconnect header-allocation failures—not unbounded
  iteration, callee arena ownership, internal arena leak freedom, or postconnect
  cleanup.
- Process cancellation:
  `test_cancellation_racing_wait_admission_stops_job_and_joins_caller` observes
  that race and a killed job, not an already-blocked native wait.
- Frontmatter:
  `frontmatter extraction matches the recorded finite reference corpus` covers
  323 expectations; historical Pi/YAML capture provenance lacks a tracked
  regeneration recipe and was not independently re-established.
- `bench_startup.py` used manual descriptive measurement with a journal observed
  after a frame, not a 50 ms SLO or sync-before-first-frame proof.
- The PTY presentation driver drops only its already-satisfied dismissal check.
  The failing HTTP discovery case names contact/session progress, not an exact
  configured watchdog deadline. VM diagnostics say runtime check, not proof.

These exact names, locations and limits are mapped to both judgments in the
external ledger. No new historical regression story is inferred from them.

## Retired checks and remaining coverage

| Removed artifact or claim                                                                      | Reason; preserved obligation or gap                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `StartupSuccess.cfg`'s `TailSafety` occurrence                                                 | Vacuous under success-only transitions. Crash-enabled checks and the torn-tail negative control remain.                                                                                                                                                                                             |
| `StartupTerminal.cfg`'s repeated `TailSafety` occurrence                                       | Consolidated under `StartupSafety`/`DetailSpec`, which includes these transitions and bounds. **Not vacuous:** `WriteFailure` can set `torn` even with zero crashes.                                                                                                                                |
| Lean `rejection_unchanged`, `authority_preserved`, and unused `State/register` wrapper         | Artificial acceptance/authority projections supplied no substantive native validation or grant evidence.                                                                                                                                                                                            |
| Lean `cancellation_is_not_join`, `terminal_result_is_not_join`, `replacement_discards_pending` | No two supporting retention judgments at the cap. Remove declarations/audits only; retain action constructors, transition semantics and substantive induction. Short proofs are not automatically worthless.                                                                                        |
| `Exec returns before normal descendants finish and eventually reaps them`                      | The proposed barrier repair could hang on the central early-return regression before a bounded observation. That exact normal-reaping/early-return witness is absent.                                                                                                                               |
| `Exec detach transfers descendants after destroying owner and I/O backend`                     | Incorrect shutdown could hang before the proposed bounded PID poll. The post-owner/backend detach witness is absent. Other cancellation, ownership and process tests remain; this is not a claim that all lifecycle coverage vanished.                                                              |
| `test_mcp.py::run_timeout`, its hanging-stdio fixture/call/print                               | Could pass on early discovery failure without observing process/request/deadline. Stdio timeout coverage is absent; other real stdio and HTTP cases remain.                                                                                                                                         |
| Ghostmux `tests/install.test.mjs`                                                              | Could not import absent repository helpers. Installation/signature/version/source-digest rejection is not replaced or claimed passing. Production packaging programs remain. Their missing-helper defect is addressed separately in the follow-up, without restoring installation/signature claims. |
| Ownership parse-only test                                                                      | The same `parse()` checks already execute for every case inside the retained detector/control test.                                                                                                                                                                                                 |
| Six repeated Terminus probe-boolean assertions                                                 | At the cap, independent host-evidence claims remained disputed. Remove those assertions while retaining actual guest service exercise and approved filesystem/network/broker observations. No replacement host proof is claimed.                                                                    |

Substantive Lean contracts and conditional registry update/frame support remain.
There is no complete startup port, kernel composition or checked Zig/Luau
refinement. The `latest` selector's last-wins characterization is not separately
proved. TLC remains finite model checking with its documented bounds/fairness;
the historical notification-guard finding is preserved as a negative control,
while the corrected native test requires targeted cancellation. See the
follow-up notice.

## Production guard classifications

The audit itself kept production guards and behavior unchanged; the separately
authorized follow-up adds recoverable validation for reproduced malformed-input
failures. Two seats withdrew incorrect objections to cancellation-protected
`Group.await`, null-only invocation cleanup, and Input's spare-capacity
invariant after inspecting the actual construction. Compile-time restrictions
remain construction checks; test-fixture assertions are not production
assertions; always-active Luau error checks are recoverable input validation,
not debug assertions that vanish in release.

The audit initially left these source-correspondence questions, without native
reproductions at that point:

- `CanonicalJson.zig` lacked an established UTF-8-key precondition (P002/P003).
  The follow-up now validates keys/strings before encoding and tests the
  reproduced failure; this is not universal canonicalization correctness.
- `logic.commandPtr` had an unresolved private-state consistency precondition
  (P007). The follow-up rejects duplicate/empty working IDs and absent active
  owners. Other private-state invariants remain outside that contract; no direct
  restored-active `commandPtr` crash was demonstrated.
- `Conversation.retained` lacked an established restored-checkpoint `first_kept`
  precondition (Q004). It now returns a recoverable error on invalid retention,
  with real replay rejection/control evidence. Direct constructor rejection
  coverage remains deferred.

The later authorized investigation reproduced malformed UTF-8 sorting and
invalid checkpoint panics, duplicate/missing working-command acceptance, and a
`Session.commitBootstrap` allocation-after-sync crash. The follow-up records the
validation/publication fixes and their limits. It does not claim every private
state invariant, startup path, or native refinement is now proved.
