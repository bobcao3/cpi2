# UX coverage and verification ledger

These documents are the **target contract** accepted after the 25-scenario
comparative audit, not an assertion that documentation alone implements or
verifies behavior. Implementation evidence must come from regression tests and
source review. The audit baseline describes the pre-change working tree and
is retained outside the public repository.

## Scenario ownership

| Scenarios | Contract                                                          | Source                                                                                                          |
| --------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 01–02     | Paused queue, distinct pending input, displaced-draft restoration | tui/interactive.zig, Kit Editor                                                                                 |
| 03–04     | Completion invalidation, modal key/paste ownership                | tui/interactive.zig, tui/pickers/Dialogs.zig                                                                    |
| 05–06     | Explicit custom ID, literal send, command arity                   | tui/pickers/Dialogs.zig, tui/interactive.zig, tui/ui_presentation.luau                                          |
| 07–08     | Recognizable existing-only resume and fork selection              | tui/pickers/SessionSelector.zig, session/SessionIndex.zig, tui/pickers/ForkSelector.zig, session/Controller.zig |
| 09–10     | Model onboarding, actionable unknown-effort recovery              | tui/pickers/Dialogs.zig, tui/interactive.zig                                                                    |
| 11–12     | Consistent backward navigation and editing                        | tui/interactive.zig, tui/pickers/Dialogs.zig                                                                    |
| 13–14     | Explicit auth lifecycle and interactive launch                    | providers/Auth.zig, main.zig                                                                                    |
| 15–16     | Read-only running inspection, progress and durable outcomes       | tui/interactive.zig, session/Controller.zig, services/Exec.zig                                                  |
| 17–18     | Back/paste recovery, truthful nonrollback outcomes                | tui/pickers/Dialogs.zig, tui/interactive.zig                                                                    |
| 19–21     | Value-aware help/config scan, trace grammar, negative overrides   | main.zig                                                                                                        |
| 22–25     | Accurate routing/editor/shortcut/OAuth descriptions               | README.md and these contracts                                                                                   |

## Required regression cases

1. Interrupt/failure with steering, two follow-ups and a nonempty draft; no
   automatic continuation while paused; continue/edit/discard explicit.
2. Repeated queue retrieval preserving cursor and large paste payloads;
   displaced draft restore; allocation failure leaves original intact.
3. Tab → paste → Tab, initial/repeated reverse completion, no matches, unknown
   thinking capabilities.
4. All modal cancel keys and paste; no underlying editor mutation or quit
   fallthrough.
5. Search miss cannot activate ID; explicit custom ID works with/without matches
   and discovery pending.
6. Literal /quit and /skill text; extra arguments to no-argument commands
   reject.
7. Missing interactive resume does not create files; searchable session/fork
   rows; cancellation; selected-head and excerpt identity.
8. Fresh login versus saved route, masked keys, Back with secret disposal,
   incidental versus embedded pasted newline, saved OAuth cancel outcome.
9. Forget legacy profile, reopen, unrelated credentials preserved,
   reauthorization clears suppression; active-route limitation explicit.
10. Busy read-only paging with live argument/text/tool events; bounded process
    progress, real cancellation and joined shutdown.
11. Partial failures remain visible after next job; rollback instructions not
    overwritten; no claim of reverted host effects.
12. CLI help/config tokens inside values and after --; broken config still
    allows help; trace preserves prompt; explicit/inherited disable paths;
    interactive launch conflicts.

Run anyzig 0.17.1 build --fork "$HOME/Kit.zig" check test-controller
test-services test-agent -j4 and formal checks described in the lifecycle skill.
These remain bounded checks, not a refinement/ownership proof. Actual commands,
regression coverage, pass/fail/blocked outcomes and remaining limitations are
recorded in the maintainer-local implementation handoff.
