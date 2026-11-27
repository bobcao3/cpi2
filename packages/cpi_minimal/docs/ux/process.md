# CLI/process contract

## Parsing and modes

- Genuine -h/--help works before configuration loading. Required option values
  and everything after -- are data, even when equal to help/config flags.
- No general --flag=value parser is promised.
- Repeated scalar options use last value; prompts/skills/env files append.
- A positional prompt starts the TUI when stdin and stdout are terminals.
  `--prompt` and `--print` select batch mode. `--print` reads stdin when no
  prompts or compaction were supplied.
- Positional `@file` arguments attach files to the first prompt, including after
  `--`. Paths resolve from the launch directory. Piped text comes first,
  followed by file text or image references, then the first prompt. The
  Auto-resize images setting applies to images, and the journal keeps the
  prepared attachment bytes for replay.
- `--interactive` opens the TUI and submits any supplied prompts in order. It
  conflicts with `--print` and `--compact`.
- Batch prompts are text/skill input, not the TUI local-command language.
  Explain this in --help; do not silently execute slash commands from
  automation.
- --trace is boolean. --trace-file PATH enables tracing with an explicit
  destination. The old optional-path syntax is replaced; migrate scripts
  explicitly. Positional prompt text is never an optional trace filename.
- --no-env and --no-mcp override inherited configured paths. Reject combinations
  with explicitly supplied CLI paths, independent of argument order. --no-env
  does not clear process environment or saved credentials.
- `-r` and bare `--resume` open the session picker on the primary terminal
  screen. Escape closes it and exits successfully. The interactive `/resume`
  picker stays inside the current TUI.
- `--session PATH` opens or creates a journal. For compatibility, `--resume`
  followed by a recognizable session path also opens that path. `--session ID`
  searches the current workspace first and asks before forking a match from
  another workspace. `--continue` uses the most recent session for the current
  workspace or starts a fresh one.
- Resolve a selected journal and its workspace before loading workspace
  resources. For a missing saved directory, an interactive launch can continue
  once in the current directory, fork a new journal here, or cancel. A batch
  launch reports the missing directory before starting a Worker.

## Automatic recovery

See [Minimal's recovery policy](../../README.md#controller-policy) for resume,
retrieval, and fresh retry behavior. Retry waits are cancellable. Batch turns
write committed assistant text to stdout and progress to stderr.

Authentication/discovery use up to four total attempts for transient failures,
and live saved-subscription credentials renew before each model call as needed,
with one forced 401 refresh. Startup need not contact authorization servers to
open the UI. Device-code polling keeps its code through temporary outages.
Account changes, denied consent and permanent credential errors require explicit
authorization, never a billing/provider fallback.

Compaction retries incomplete/empty/tool-calling summaries up to three times
without executing proposed calls or replacing original context. Persistent
protocol/configuration/corruption/resource failures are not treated as
transient. Exhaustion is an explained controlled failure, not a crash or an
automatic whole-turn replay.

## Configuration and storage

Keep flat user config, external Lua registry, endpoint-scoped credential
selection, and config/env/CLI precedence. No implicit Pi credential import.
Unknown/malformed explicit configuration fails with actionable diagnostics;
--help remains available.

Credentials: private locked atomic auth.conf; successful OAuth is saved before
completion. Forgetting a migrated profile persists a suppression marker so
legacy credentials do not reappear. Reauthorization clears that marker for the
provider. No claim that local removal revokes browser authorization or clears
environment keys.

Minimal uses the [shared frame journal](../../../agent/docs/session-frames.md).
See [Sessions and compaction](../../README.md#sessions-and-compaction) for file
names and path normalization, and
[journal recovery](../../../agent/docs/journal.md#replay-and-recovery) for
corruption handling and uncertain effects.

MCP startup remains timeout-bounded; failed optional servers do not prevent
work. Unknown model capabilities need explicit declaration, not guessed
requests.

## Shutdown and verification

Interactive exit cancels/joins auth and execution jobs, detaches sinks only
after stop, drains final events, and restores terminal/paste/keyboard modes. No
rollback of completed effects is implied. Native signals in batch are not TUI
key actions.

Startup option changes require startup model checks;
queue/admission/cancellation changes require lifecycle correspondence review.
Model checks, native tests and missing proof tools must be reported separately.
