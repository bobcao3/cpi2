# Commands

Command names are case-sensitive. Whitespace separates a command name from its
arguments. For `/export`, quote paths with spaces. Session paths passed to
`/resume` use the entire argument.

Type `/` at the start of the first composer line to open command completion. It
includes enabled `/skill:NAME` commands. Tab inserts the highlighted command and
a space. Enter from the command list runs it. Escape closes the menu and keeps
the draft.

`/model`, `/thinking`, and `/login` offer built-in argument suggestions. Other
built-in commands and skill commands have no argument-specific suggestions. Luau
command definitions can supply their own choices. Tab or Enter from an argument
menu inserts a value. A subsequent Enter submits the command.

| Command                                 | Contract                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| /help                                   | Discover commands, literal submission, queue recovery, and context-sensitive shortcuts.                                                                                                                                                                                                                                                                                                                 |
| /settings                               | Search preference names, move with the arrow keys, and cycle the selected value with Enter or Space on an empty query. Esc closes the picker. Preferences are saved to `~/.cpi-minimal/settings.json`.                                                                                                                                                                                                  |
| /session                                | Show the session name, journal location, ID, message and tool counts, and recorded token usage.                                                                                                                                                                                                                                                                                                         |
| /export [PATH]                          | Write the selected branch as Markdown. A path ending in `.jsonl` writes a Pi-format session.                                                                                                                                                                                                                                                                                                            |
| /name [NAME]                            | Set the session display name or show the current name. The name appears in the footer and terminal title. Saved sessions keep the name when reopened and display it in the resume picker. Tree filter Ctrl+A shows the title history.                                                                                                                                                                   |
| /quit                                   | Quit and join work; no ignored arguments.                                                                                                                                                                                                                                                                                                                                                               |
| /login [openai\|deepseek\|compatible]   | Always authorize again, never silently activate saved credentials. Picker explains saved status. Use /model to switch saved routes.                                                                                                                                                                                                                                                                     |
| /logout                                 | Select a saved provider to remove its local credentials. A route already loaded in the current process can keep using its credentials.                                                                                                                                                                                                                                                                  |
| /forget KIND                            | Confirm local credential removal; no promise of remote revocation. Preserve unrelated profiles. Do not silently activate another saved account. Active in-process route remains until explicitly changed; explain this limitation.                                                                                                                                                                      |
| /model [PROVIDER/MODEL]                 | Search credentialed choices or select directly. Exact qualified and unambiguous bare IDs can switch providers. Unknown IDs fall back only on configured current-route handling; strict registry rules apply there.                                                                                                                                                                                      |
| /thinking [LEVEL]                       | Supported choices only. Unknown capabilities show exact session-preserving restart guidance, not unusable suggestions.                                                                                                                                                                                                                                                                                  |
| /compact [focus]                        | Idle compaction; preserve summary outcomes and archived history.                                                                                                                                                                                                                                                                                                                                        |
| /new                                    | Start a fresh session and cancel active work in the outgoing session.                                                                                                                                                                                                                                                                                                                                   |
| /resume [PATH]                          | Open the recent-session picker or resume an existing path. Opening or closing the picker leaves active work running. Confirming a different session cancels active work in the outgoing session.                                                                                                                                                                                                        |
| /fork [ID]                              | Bare opens the user-message picker. Confirm a message to open an independent session with the history before it and place the selected text in the composer. An explicit ID creates a scoped conversation through that entry.                                                                                                                                                                           |
| /clone                                  | Open an independent session with the history through the current point and an empty composer.                                                                                                                                                                                                                                                                                                           |
| /tree [CURSOR]                          | Bare opens the session tree with search, filters, labels, folding, and branch selection. Select a point and choose whether to summarize the branch being left. A custom prompt adds focus to the summary. Escape cancels summarization and returns to the picker. Selecting a user message moves to its parent and prefills an empty composer. A numeric cursor opens the journal page for that cursor. |
| /reload                                 | Reload skills and themes.                                                                                                                                                                                                                                                                                                                                                                               |
| /send TEXT                              | Literal model input; bypass slash dispatch and skill expansion.                                                                                                                                                                                                                                                                                                                                         |
| /queue [pause\|continue\|edit\|discard] | Inspect, pause, resume, edit, or discard pending inputs.                                                                                                                                                                                                                                                                                                                                                |
| /draft                                  | Restore the latest displaced editor snapshot when one is available.                                                                                                                                                                                                                                                                                                                                     |
| /outcome [dismiss]                      | Inspect/dismiss the in-process outcome; restart-required outcomes cannot be dismissed.                                                                                                                                                                                                                                                                                                                  |
| /skill:NAME [args]                      | Skill input follows prompt readiness/queue rules; expansion failure preserves input.                                                                                                                                                                                                                                                                                                                    |

TUI mode switches between fullscreen and the terminal's regular scrollback while
the settings picker stays open. `--tui-mode regular` and `--tui-mode fullscreen`
choose a mode for the current launch. Show hardware cursor replaces the
composer's drawn caret. Clear on shrink applies to regular mode. Terminal
progress reports active turns to terminals that support OSC 9;4.

Theme previews each highlighted palette. Select a theme to save it, or choose
automatic and apply separate light and dark themes. Escape discards the preview.
Custom themes use Pi's JSON format and load from `~/.cpi-minimal/themes` or a
file or directory passed with `--theme`. The active custom theme reloads when
its matching `<name>.json` in the config themes directory changes. Missing or
invalid edits leave the last valid palette visible.

Block images replaces images in model requests with a text placeholder,
including images from earlier turns. Show images controls inline rendering in
terminals that support it.

Auto-resize images defaults to on. Tool results use the current preference when
saved. The built-in read tool also applies the preference at startup and on
`/reload` for its initial image preparation. Resizing uses Lanczos3 to fit
within 2000×2000 and the inline size limit, and reports the coordinate scale.
Images already saved in the transcript keep their representation.

Transport defaults to `auto` and cycles through `sse`, `websocket`, and
`websocket-cached`. The change applies to the next Codex request. An explicit
`OPENAI_TRANSPORT` overrides the picker for that launch.

The default tree shows system configuration changes. Ctrl+A includes saved
titles, model selections, thinking levels, and label changes. Selecting a
settings row changes the conversation position. The footer continues to show the
live name, model, and thinking level.

Reopening a session after a bare tree navigation returns to the last appended
entry. A summary, label, title, or subsequent message saves the new branch.

A fork with no copied user or assistant message stays in memory until its first
such message commits.

`/new` and a confirmed `/resume` discard unconsumed input in the outgoing
session. `/select` requires an empty pending queue. Use `/queue edit` or
`/queue discard` to clear it. During work, help, session naming and replacement,
quit, queue inspection and editing, outcome inspection, and draft restoration
remain available. Provider and configuration changes preserve the draft when the
model is busy. Unknown commands retain text and explain `/send TEXT`. Accepted
command drafts clear only after success. Modal fields and snapshots are
separately owned.
