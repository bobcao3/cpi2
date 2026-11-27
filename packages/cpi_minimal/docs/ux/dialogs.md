# Dialogs

Focus owns keys and paste. Escape/Ctrl+C/Ctrl+D close only the current modal.
Closing a picker does not stop discovery for configured routes; closing login
cancels unfinished device authorization and removes unsaved discovery routes.
Enter accepts; Up/Down and Tab/Shift+Tab navigate forward/backward. Unsupported
keys and cursor movement do not reset selection. Query edits may reset it. Main
editor draft is retained independently.

## Login

/login selects a provider for **fresh authorization**; /model switches saved
providers. Display saved status and distinguish local format validation from
actual server acceptance. API keys remain masked with fixed-length asterisks and
are never history/tool arguments.

Endpoint → hidden key → model choices. Ctrl+B goes Back (distinct from cancel),
preserving nonsecret values and clearing superseded secret material when
returning to endpoint/provider selection. Trim incidental pasted surrounding
line breaks; reject embedded line breaks. Keep single-line and length
safeguards.

Saved subscription renewal for prompts/queues/long-running tool loops happens
inside the admitted model service, not a modal that asks the user to resubmit.
Its private credential store persists before key publication; the UI reloads by
revision. Device polling retains its code across transient failures, while
explicit denial/expiry remains terminal.

After key entry, Minimal fetches models asynchronously; Ctrl+N can enter a
custom ID without waiting. Model acceptance confirms the configured
provider/model, not that a model request has succeeded.

OpenAI device OAuth persists successful authorization before reporting success,
independently of discovery/selection. Discovery then uses the saved
authorization without activating a route. Cancelling this picker says
authorization was saved and provider/model unchanged. Ordinary pre-success
cancellation must not claim a saved login.

## Model picker

DeepSeek has an explicit provider identity throughout `/login deepseek`, saved
credentials, runtime routing and model selection. Its catalog rows remain
`deepseek/MODEL`; neither switching routes nor using an explicit endpoint
override turns it into a generic compatible provider. Native DeepSeek
credentials/model preferences use `DEEPSEEK_API_KEY`/`DEEPSEEK_MODEL` or its
saved profile, not OpenAI settings.

`/model` consistently lists credentialed routes: environment, saved profiles,
and the current route. An endpoint-bound generic `OPENAI_API_KEY` remains bound
to its original URL/model when switching to a saved route; it does not become a
public OpenAI credential or disappear. Providers without credentials remain
absent. Local credential presence is not a guarantee of remote entitlement.
Ordinary picker cancellation is silent; only newly saved authorization needs
confirmation.

Startup, session and queue resume, turn completion, and model Tab completion
schedule or reuse asynchronous discovery. Requests are coalesced per credential
and endpoint; an open TUI refreshes successful lists after five minutes and
retries failures after 30 seconds. `/model`, `/model <id>`, and Tab use the same
snapshots. While a route has no result, Tab can use reference choices; the
picker waits for the initial listing or fallback without blocking the editor. A
successful empty list stays empty. Selecting a live model applies its reported
metadata to that selection; background updates do not change an in-progress turn
or the reference catalog.

Filter only selects listed rows. Enter with no matches reports “No matching
models”; it never silently treats search text as an ID. Ctrl+N opens an explicit
custom-ID field identifying the destination endpoint/account. This action is
available whether matches exist or not. Custom selection validates on Enter;
Back returns to search. Pending login credentials remain independently owned
until acceptance/cancellation.

## Session/fork pickers

`/resume` opens the current-folder picker with threaded ordering. Tab switches
to All. Ctrl+S cycles Threaded, Recent, and Fuzzy. Ctrl+N filters to explicitly
named sessions. Ctrl+P toggles file paths. Each row shows a title or
first-prompt preview, the message count, and the age of the latest activity.
Search uses case-insensitive fuzzy matching over the session name, ID,
workspace, and user and assistant text, including inactive branches. Words can
match different fields. Double quotes match a phrase. Enter opens the selected
session in its saved workspace. Escape closes the picker.

If the saved workspace is missing, choose whether to continue once in the
current workspace, fork the full history into the current workspace, or cancel.
Continue keeps the original saved workspace so the next resume asks again. Fork
creates a new session ID, preserves inactive branches, and leaves the original
in place. Pending work stays with its original journal. Escape and Ctrl+C
cancel. A locked or replaced session leaves current work running.

Ctrl+R opens a single-line rename field. Enter saves a nonempty title and Escape
or Ctrl+C returns to the list. Ctrl+D, or Ctrl+Backspace with an empty query,
asks to delete the selected inactive session. Enter confirms and Escape or
Ctrl+C cancels. Deletion attempts to move the session file to trash when the
`trash` command is available. If the original file remains and its identity is
unchanged, deletion removes it directly.

`/fork` opens the user-message picker at the latest available message.
Confirming copies the conversation before that message and puts its text in the
composer.

## Forget confirmation

Show target provider and explain local removal versus remote revocation. Removal
preserves unrelated providers and suppresses re-import of the removed legacy
profile. The legacy auth.json itself is not rewritten/deleted; the confirmation
and outcome explicitly disclose that it remains on disk. This is
application-level forgetting, not secure erasure. Existing environment
credentials and the in-process route are not erased; explain that
switching/restarting is separate. Never silently select another account.

## Errors

Validation retains step/input for correction. Async errors remain in the dialog
where possible. Preserve actionable rollback/restart guidance in a persistent
outcome separate from transient error names. Selection success with
preference-save failure reports session-only success explicitly.
