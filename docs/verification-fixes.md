# Defects exposed by verification review

## Status and evidence

The operator authorized the deadline correction and fixes for defects exposed by
the audit. This follow-up is on audit parent `swwmtmzo` (`c7b9cf87`). Product
and verification changes are separate from the original portfolio's approvals.

**Accepted at the stated scopes.** The bounded council approved the retained
contracts and exact corrections. Corrected-source affected checks passed 51/51
build steps; the final root aggregate passed 195/195 steps. The separate
current-source Node run passed 36/36 cases with no skips. Raw commands/results
are in `final-affected.log`, `final-checks.log`, and `node-checks.log`; cached
build results may contribute to summaries. Earlier failed runs and the
first-candidate aggregate are preserved separately, not substituted for final
execution.

Evidence is in a maintainer-local `verification-fixes/` directory:
`candidate.diff`, `candidate-hashes.tsv`, the council brief/memo and run
receipts, and the following before/after logs. The original audit failure
remains at `../verification-audit/post-checks.log`; no failed run is rewritten
as a pass.

- `canonical-before.log`: malformed UTF-8 key panics in UTF-16 iteration;
  `canonical-after.log`: direct canonical JSON tests pass after validation.
- `native-before.log`: duplicate working commands were accepted, invalid
  checkpoint retention aborted, post-sync bootstrap allocation failure crashed
  during cleanup, and targeted cancellation failed after notification failure.
  `native-after.log`: the corrected native/controller target passes 75 tests.
- `alias-before.log`: real CLI discovery fails with `InvalidControllerPolicy`.
  `alias-after.log` and `denial-after.log`: canonical discovery, alias
  empty-refresh retirement, and denied-source no-I/O observations pass after the
  correction. The stale-helper path was initially only suspected, not previously
  reproduced.
- `packaging-before.log`: the release command cannot import the absent CLI
  helper. `packaging-after.log` / `packaging-usage.log`: local staging and
  command loading work without that dependency. No signed artifact or
  publication was performed.

## Required contract notices

All names below identify the observed obligation, not a claim about all inputs
or schedules. Supporting helpers/import roots are not additional verification
wins. Both seats support each retained contract. The review used two passes,
with `oracle` on forked,
context-aware GPT-6.1 Sol and `reviewer` on DeepSeek Flash with default-unknown
context. Source review is not an execution pass. See the external `memo.md`,
`runs.json`, `p1-*.json`, `p2-*.json`, and exact retained hashes.

The proposed F4 construction extension was rejected for an incorrect expected
summary. Its executable candidate was deleted; the original replay-only F4 block
remains, supported by both first-pass approvals and the explicit second-pass
fallback. Direct constructor rejection coverage is deferred, not silently fixed.

| Contract, domain, assumptions and limits                                                                                                                                                                                                                                                                                                                                                                                                                          | Exact name/location and naming rationale                                                                                                                                                                                                                                                                                                  | Qualifying leverage and review                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| One fixed ten-second awake-clock deadline survives premature `Event.waitTimeout` returns, propagates cancellation, and fails stop at real expiry. Supports the existing controlled source/call schedules; not an unconditional native liveness proof.                                                                                                                                                                                                             | `packages/mcp/tests/mcp.zig::waitFixture`, support for the existing cold/cache/cancellation/source-independence tests. The helper name denotes fixture synchronization, not production timeout behavior.                                                                                                                                  | Named audit-helper failure in `post-checks.log`, plus spurious-timeout/deadline-extension/cancellation failure families. APPROVE, F1: both second-pass reports; support only.                                                  |
| Reject five malformed UTF-8 classes as object keys and nested array strings; accept selected valid Unicode. Not exhaustive Unicode or canonicalization correctness.                                                                                                                                                                                                                                                                                               | `packages/agent/src/CanonicalJson.zig` — `canonical JSON rejects malformed UTF-8 keys and nested values`. Names the actual invalid-input boundary.                                                                                                                                                                                        | Reproduced sorting panic and malformed-string failure family; APPROVE, F2: both second-pass reports.                                                                                                                           |
| Reject duplicate/empty working IDs and active IDs absent from the command set before VM/operation creation and without appending. Positive valid active recovery also clears an orphaned suspended record. Not validation of every private replay field.                                                                                                                                                                                                          | `packages/agent/src/replay_validation_tests.zig` — `replay rejects inconsistent working-command identities without appending`. Names the input consistency and journal boundary.                                                                                                                                                          | Ambiguous-lookup/missing-owner family and evidenced prior duplicate acceptance; APPROVE, F3: both second-pass reports, exact retained composition.                                                                             |
| Reject missing/self/empty checkpoint retention targets without panicking or changing journal bytes; an ancestor input target reopens and projects retained text. Not every conversation graph invariant.                                                                                                                                                                                                                                                          | Same file — `replay rejects invalid checkpoint retention instead of panicking`. Names the reproduced crash boundary.                                                                                                                                                                                                                      | Evidenced native panic and invalid-retention family, with a real replay/projection control; APPROVE, original F4: both first-pass reports; explicit second-pass fallback. Rejected constructor extension supplies no coverage. |
| First prove the allocation-denial observer; after real journal sync, require denial armed on the session allocator until bootstrap commit returns, READY, no refused allocation, and the committed sequence after reopen. Allocations outside that allocator are invisible. Tests `Session.commitBootstrap` in the native bootstrap setup, not every startup/VM/allocation schedule.                                                                              | `packages/agent/src/startup_publication_tests.zig` — `bootstrap publishes READY without allocating after successful journal sync`; `AllocationGate` and launch import are support. The name states the exact publication cut.                                                                                                             | Reproduced allocation-after-sync cleanup crash and late-publication-allocation family; APPROVE, F5: both second-pass reports, including observer control.                                                                      |
| With a held real native service and a failing sink, deny new ordinary work and a policy-denied targeted stop, leaving the service active; a policy-authorized targeted stop then stops it. Retain ordinary cancellation and joined closure before releasing borrows. One controlled schedule; waits retry premature Timeout against a fixed five-second deadline.                                                                                                 | `packages/agent/src/lifecycle_tests.zig` — `targeted and ordinary cancellation remain available after notification failure`. The name requires the corrected behavior, not an obsolete expected error.                                                                                                                                    | Evidenced targeted-cancel rejection and cancellation-admission family; APPROVE, F6: both second-pass reports, preserving policy admission.                                                                                     |
| Preserve the historical faulty guard as a two-request `CancelAvailable` counterexample; correct guard remains checked by existing `SessionSafety`. Safety exploration is finite, assumes otherwise valid/authorized cancellation, and asserts no Zig refinement.                                                                                                                                                                                                  | Replaced `SessionCurrentCancel.cfg` with the counterexample now at [formal/tla/negative/NotificationBlocksCancel.cfg](../formal/tla/negative/NotificationBlocksCancel.cfg) and updated the Makefile and lifecycle correspondence. The new name describes the deliberately faulty guard. A redundant corrected configuration is not added. | Named historical counterexample and native replay; consolidation rather than duplicate coverage. APPROVE with F6: both second-pass reports.                                                                                    |
| Real Minimal CLI: hidden/disabled aliases cause no MCP requests, allowed discovery and echo succeed, an underscore alias refresh returns the configured hyphenated source identity with an empty catalog, and its old helper disappears. Exact HTTP initialize/list/call counts, three provider callbacks and consumed final output are required, so the central result assertion cannot be skipped. Selected names/schedule, not all aliases or authority cases. | `packages/cpi_minimal/tests/test_deferred_tools.py::alias_refresh`, CLI case `alias-refresh`. Names the alias/source-replacement interaction; existing provider/MCP fixtures are support.                                                                                                                                                 | Reproduced policy failure plus canonical-source retirement and authorization-normalization families, with actual positive network control; APPROVE, F7: both second-pass reports, including completion observers.              |
| Command loading rejects missing arguments with usage rather than missing-module failure. Real wrapper staging saves its public name and all five supported native aliases at the wrapper version. Does not stage signed binaries, install tarballs, verify tampering, or publish.                                                                                                                                                                                 | `packages/ghostmux/tests/package.test.mjs` — `local packaging loads and stages public wrapper metadata with versioned aliases`. Names the command/staged-metadata boundary, not installation security.                                                                                                                                    | Evidenced absent-helper regression and finite published-name/version mapping family; APPROVE, F8: both second-pass reports.                                                                                                    |

## Product changes and remaining limits

Canonical JSON validates strings and keys before UTF-16 iteration. Replay
validates working-command uniqueness and active membership; invalid checkpoint
retention returns a recoverable error. Checkpoint construction also checks its
target by source inspection; direct constructor rejection coverage is deferred.
Bootstrap prepares READY storage before the journal boundary. Targeted stop
bypasses only notification health, retaining Controller policy admission; new
ordinary work remains denied. The conversation-event insertion failure arm also
frees its not-yet-inserted Event. Both advisors inspected this source ownership
fix; no native leak reproduction or additional allocation-coverage claim
follows.

Minimal's policy uses bounded bytewise hyphen normalization rather than sandbox-
removed `string.gsub`. The host supplies normalized authorized names. Discovery
returns the configured server identity even for empty catalogs; registry source
replacement uses that identity, not the caller's spelling. Gateway discovery and
shutdown ownership are otherwise unchanged. Packaging helpers own their public
names and aliases, removing the missing CLI-framework transformation.

TLC contracts, Lean kernels and manual source correspondence remain distinct. No
new proof claims, legacy readers, migrations, automatic replay, provider-charge
guarantees, remote publication, full startup theorem, kernel composition, or
checked Zig/Luau refinement are introduced. Existing audit retirements and their
coverage gaps remain except for the explicitly named follow-up contracts above.
