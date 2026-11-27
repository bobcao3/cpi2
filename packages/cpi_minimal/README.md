# cpi-minimal

Minimal is a coding assistant built on [cpi2](../../README.md). It uses Pi's
four tools, skills, and a terminal UI. The [agent guide](../agent/README.md)
explains what the framework owns. Minimal owns the prompts, tools, and UI. Its
Pi reference is
[commit 90b42bca](https://github.com/earendil-works/pi/tree/90b42bca6ed161b8e7ee40ceda9755205c2882ec).

See the [source tree map](docs/README.md#source-tree) for module entry points.

## Run

Build from the repo root. Use a Kit checkout with the public Unicode API.

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" -j4
zig-out/bin/cpi-minimal
```

Use `/login` to sign in. For OpenAI API access, set `OPENAI_API_KEY` and
`OPENAI_MODEL`. For DeepSeek, use `--provider deepseek` and a saved profile or
`DEEPSEEK_API_KEY`. Custom endpoints need the Responses API. Use HTTPS except
for HTTP on a numeric loopback address.

```sh
zig-out/bin/cpi-minimal -p 'Explain this build.'
zig-out/bin/cpi-minimal --session ./work.jsonl.zst --prompt 'Read README.md'
zig-out/bin/cpi-minimal --session ./work.jsonl.zst --prompt 'Continue the work'
zig-out/bin/cpi-minimal --continue
```

Prompts run in batch mode by default. Add `--interactive` to stay in the TUI.
Batch input does not run local slash commands. See `--help` for options and
[CLI rules](docs/ux/process.md) for mode and flag conflicts.

### User configuration

Put `config.conf`, `models.lua`, `mcp.lua`, and user skills under
`$HOME/.cpi-minimal`. Use `key = value` in `config.conf`. Repeated `skill` or
`env_file` keys add paths. See [config keys](src/config/Config.zig). CLI flags
win. Use `--config PATH` to select a file or `--no-config` to skip it.

The TUI runs `$HOME/.cpi-minimal/ui.luau` once before its first screen, if
present. The script can edit the bundled
[presentation policy](src/tui/ui_presentation.luau) through the `ui` table.
Restart the TUI to pick up changes.

```lua
ui.search.grep.collapsed_rows = 8
ui.tools.bash[1].collapsed_rows = 8
ui.shell.collapsed_rows = 8
ui.shortcuts.expand_tools = "alt+o"
ui.footer = {"status"}
for _, entry in ipairs(ui.settings) do
    if entry.id == "quiet_startup" then entry.label = "Startup detail" end
end
table.insert(ui.commands, {
    name = "/prefs", action = "settings", description = "Open settings", arguments = "exact",
})
table.insert(ui.commands, {
    name = "/workqueue", action = "queue", description = "Manage queued messages",
    argument_hint = "<action>",
    completion = {"pause", "continue", "edit", "discard"},
})
```

`argument_hint` prefixes the slash-menu description. `completion` supplies
argument choices independently of the hint.

`ui.session_info.rows` controls the order and labels in `/session`. Each row
with a `field` displays the corresponding value from the session snapshot. For
example, `{text = "Total tokens:", field = "tokens", role = "dim"}` adds a label
beside the total.

`ui.queue_labels.steering`, `ui.queue_labels.follow_up`, and `ui.pending_hint`
set the text shown for queued messages above the composer.

Each list in `ui.tools` controls the components in that tool card's body, in
display order. `ui.tools.read[1].when = "complete"` shows the first rows of a
successful read while collapsed. `ui.tools.read = {}` shows just the heading and
any inline images.

`ui.syntax` maps Tree-sitter captures to theme roles or the `bold`, `italic`,
and `underline` styles. For example, `ui.syntax.keyword = "syntaxType"` recolors
keywords in Markdown fences and highlighted tool output.

`ui.shell.collapsed_rows` controls the preview for `!` and `!!`. Set
`ui.tools.bash[1].collapsed_rows` for model Bash calls.

`ui.tools.execute_lua` arranges the `script_source`, `script_calls`,
`script_output`, and `duration` components. Set `collapsed_rows` on the first
three to limit source lines, recent calls, or output lines while collapsed.

Set `ui.transcript.hidden_thinking_label` to change the placeholder for hidden
thinking summaries. An empty label removes the placeholder.

`ui.footer` displays the `location` and `status` rows in the listed order. Use
`{"status"}` to keep usage and model information on one row. An empty list hides
the footer.

`ui.shortcuts` binds `expand_tools`, `toggle_thinking`, `cycle_thinking`,
`select_model`, `external_editor`, `follow_up`, and `restore_queued` in the
conversation. Use Ctrl or Alt with a letter, optionally with Shift. Shift+Tab,
Alt+Enter, and Alt+Up are also available. Hints display the configured keys.
Windows and WSL default to Ctrl+Q for follow-up and Alt+Q for queue restore. The
composer reserves Ctrl+C, Ctrl+D, Ctrl+J, Ctrl+V, Ctrl+X, Ctrl+Z, and Alt+V.

`ui.pickers` defines the rows around the native picker controls. For example,
`ui.pickers.fork.before[2].text = " Fork from a prompt"` renames the fork
picker. Its `before` and `after` lists accept text rows, one-row gaps
(`{kind = "gap"}`), and horizontal rules (`{kind = "rule", role = "border"}`).
`ui.pickers.tree` also exposes `help`, `search_prompt`, `filter_suffix`, and
`summary_choices`. Picker rows can reference a shortcut as `{external_editor}`
to show the configured key.

`ui.pickers.resume_picker` sets the frame, titles, and hints shared by
`--resume` and `/resume`. `ui.pickers.workspace` labels the missing-workspace
prompt. Its `proceed` and `fork` choices each place the destination path between
two strings. `ui.pickers.dialog.rows` orders the login, logout, and model picker
widgets. For example,
`table.insert(ui.pickers.dialog.rows, 2, {component = "gap"})` adds space below
the title. Field prefixes and text rows use `text`, and `look` sets the Kit text
style.

Minimal can load `.env` from the launch folder. Use `--env-file PATH` to pick
files, or `--no-env` to skip them. See
[dotenv](../dotenv/README.md#precedence-and-failure) for precedence. Process
credentials win over saved defaults. A named provider never borrows a key from
another provider.

Saved keys are plaintext in `auth.conf`, under `$XDG_DATA_HOME/cpi-minimal` or
`$HOME/.local/share/cpi-minimal`. Keep it private. Minimal uses mode `0600`, a
lock, and atomic writes. It does not use Pi's credential store. It can read
legacy cpi profiles from `$XDG_CONFIG_HOME/cpi/auth.json` (default
`$HOME/.config/cpi/auth.json`). The current file wins; saves leave the old file
alone. Keys do not enter prompts, tool arguments, or journals.

### Interactive login

- `/login openai`: Open the device sign-in URL and enter the code.
- `/login deepseek`: Enter an API key.
- `/login compatible`: Enter the Responses URL and API key. Use Ctrl+B to go
  back.

Login saves a profile but does not switch routes. `/model` switches routes.
Cancel the model picker after OAuth to keep the saved login for later. Use
`/logout` to select a saved profile or `/forget KIND` to confirm removal by
name. Both commands remove the local profile and stop legacy re-import. Remote
access, environment keys, and the active route remain available for the current
process. See [login and picker rules](docs/ux/dialogs.md).

The saved OpenAI route can renew its key inside an admitted model call. It saves
the new key before use and stays on the same account. A `401` can force one
refresh. Startup needs no network refresh. API-key routes do not use saved
refresh tokens. There is no fallback to API-key billing.

### Interactive model selection

`/model` lists offers you have credentials for. Use `PROVIDER/MODEL` to resolve
a shared name. Ctrl+N enters a custom ID for the shown route. A search miss does
not select a model. An environment key stays bound to its own endpoint. See
[model picker rules](docs/ux/dialogs.md#model-picker) for focus and live
discovery.

Switch while idle. Minimal joins the old Worker before reopening the journal. If
the switch fails, it tries to restore the old route. It does not save
environment keys. Use `/thinking` to pick a supported effort. See
[thinking controls](docs/ux/thinking.md) and
[effort mapping](../agent/README.md#thinking-effort).

### Shared model registry

The [model registry](../model_registry/README.md) owns catalog shape and source
metadata. The root build installs `zig-out/share/cpi/models.lua`. Minimal loads
one file, in this order:

1. `--model-registry PATH`.
2. `CPI_MODEL_REGISTRY`.
3. `$HOME/.cpi-minimal/models.lua`.
4. `../share/cpi/models.lua` next to the installed `bin` folder.

Only a missing optional user file allows fallback. Bad files fail startup.
`--list-models` queries configured providers without opening a session. A
successful response determines which models appear, even if empty. If discovery
fails, CPI warns on stderr and uses the local reference catalog for that route.
Without credentials, it prints the reference catalog. Use `--provider` to limit
the query:

```sh
zig-out/bin/cpi-minimal --no-env --list-models
zig-out/bin/cpi-minimal --model-registry ./models.lua --list-models --provider openai
```

For a named provider, use a supported Responses or Codex offer. `--base-url` can
override its URL; a generic environment URL cannot. Without a named provider,
only an exact endpoint and model match supplies catalog limits. DeepSeek keeps
its own route and keys; see
[provider selection](../model_registry/selection.zig) for defaults. Catalog
prices are not a bill.

An embedder can pass one provider's model list in `Settings.registry_provider`
without loading a whole registry. Keep the provider and its models alive for the
controller's lifetime. Set `registry_context = true` to use the selected model's
`context_window` for compaction; otherwise `Settings.context_window` wins. The
same model's `reasoning_efforts` supplies the thinking profile unless
`thinking_levels` overrides it.

Use `--context-window` or `--max-output-tokens` to override limits. The override
stays in force when you switch models. Use `--thinking-levels off,low,high,max`
for a custom Responses profile. No profile means no picker choices; raw
`--reasoning-effort` is still available. A session restores its effort on reopen
with the same model unless a flag overrides it.

## MCP

Minimal uses the [MCP gateway](../mcp/README.md). The provider does not see its
remote tools. Lua can find them with
[deferred helpers](docs/capability-registration.md).

```lua
return {
  servers = {
    exa = { url = "https://mcp.exa.ai/mcp" },
    local_server = { command = "python3", args = { "/path/to/server.py" } },
  },
}
```

Minimal checks `--mcp-config PATH`, then `$HOME/.cpi-minimal/mcp.lua`, then
`$WORKSPACE/.pi/mcp.lua` with `--mcp-project`. A bad explicit file fails
startup. A bad discovered file is logged and skipped. `--no-mcp` disables MCP.
Only enabled, exposed servers can be called. See
[discovery and refresh](docs/capability-registration.md#discover-mcp-tools-from-code)
for a runnable Lua example and
[config fields](../mcp/README.md#configuration-and-discovery) for server
options.

## Tools

The default tools are `read`, `bash`, `edit`, and `write`. Use `--tools` to pick
names or `*` patterns, or pass a list of `+name` and `-name` modifiers.
`--exclude-tools` removes matching tools. The `defaultTools` setting in
`settings.json` sets the launch defaults.

Use `--tools +grep,+find,+ls` to add the read-only search and directory tools.
`grep` uses ripgrep (`rg`) from PATH, and `find` uses `fd` or `fdfind`.

Resuming a session restores the tools recorded on its selected branch. A launch
allowlist or either no-tools flag uses the launch selection instead. Launch
modifiers apply after restoration. Moving to another branch in `/tree` restores
that branch's selection within the launch allowlist and exclusions.

Use `--tools +execute_lua` to enable Luau scripts. Minimal also enables it
automatically for exposed MCP servers when the tool selection permits it.
Scripts reach selected built-ins and available deferred helpers through `tools`.
See the [built-in schemas](src/tools/catalog.json).

| Tool    | What it does                                                                                              |
| ------- | --------------------------------------------------------------------------------------------------------- |
| `read`  | Reads text or attaches an image. Line offsets start at one.                                               |
| `bash`  | Runs Bash with the host environment. Returns combined output. No default timeout.                         |
| `edit`  | Matches all edits against the old file. Missing, ambiguous, or overlapping matches fail before any write. |
| `write` | Writes or replaces a file. Creates missing parent folders.                                                |
| `grep`  | Searches file contents with a regular expression or literal string, with optional glob and context lines. |
| `find`  | Finds paths using a glob.                                                                                 |
| `ls`    | Lists directory entries, including hidden files.                                                          |

Tools have the host's file access. Bash is **not a sandbox**. Do not put secrets
in prompts or commands. Edit preserves line endings and the BOM. Its fallback
can match Unicode and white space; exact-only edits skip that path. Bash saves
logs and receipts in `tool-output`. A normal exit can leave background jobs
alive. Cancel or timeout kills and reaps the owned group. See
[Exec](../services/README.md#synchronous-execution) for output and receipt
rules. Service size warnings are not hard caps. In the model context, `read`
shows the head and `bash` the tail, up to 2,000 lines or 50 KiB. Follow the read
offset or the bash log path to see the rest. Direct core tool calls send result
text and image attachments, not UI details, structured JSON, or an added error
label. MCP and `execute_lua` retain their own result format.

## Controller policy

The [Minimal policy](src/tools/controller_policy.luau) governs commands and
effects. It checks the workspace, shell, and route. The
[framework](../agent/docs/native-controller.md#admission-policy) still checks
each grant and schema. Changes to Worker `ctx` cannot change policy. Stop and
shutdown cannot be vetoed.

Minimal owns fresh retries. A dropped direct OpenAI stream can resume at its
saved cursor. If that fails, Minimal can fetch the same response on its original
route. Reopen keeps the route, request, and wake time. A fresh generation may
cost more; it does not replay completed tools or append the user input again.
Use `--provider-retries N` to cap fresh retries. Permanent errors and
cancellation stop retry. See the
[transport guide](../agent/docs/openai-transports.md#native-resume) for resume
and [retry state](docs/context-journal.md#pending-inputs-and-retry-state) for
durable waits, lost credentials, and cleanup.

The inbox records pending input before delivery. Placing an input and removing
it from the inbox share one commit. The task scheduler owns child work,
checkpoints, and wait deadlines. A parked phase does not release an exclusive
[conversation slot](../agent/docs/native-controller.md#worker-and-conversation-slots).
See [private context actions](docs/context-journal.md) for host hooks and
read-only inspection. Use the [native guide](../agent/docs/native-controller.md)
for borrowed handles and joined shutdown.

## Skills

Minimal searches configured project skills, auto-discovered project skills,
configured user skills, auto-discovered user skills, local packages, and then
paths supplied with `--skill`. The first distinct file with a given skill name
wins. The slash menu shows `[p]`, `[u]`, or `[t]` for project, user, or
temporary scope. An explicit path can retain the scope of a matching discovered
resource. Use `--no-skills` to load only paths supplied with `--skill`. Use
`/reload` when idle to reload skills. Minimal reads workspace `.pi` settings and
user skill paths from its own `config.conf`.

Use `/skill:NAME [args]` to submit a skill with a prompt. Expansion failure
leaves input intact. Use `/send TEXT` to skip skill expansion and slash
commands. The startup `[Skills]` section lists loaded skill names. Ctrl+O
expands it to show paths grouped by scope. `/reload` refreshes the listing and
warnings. Set `quiet_startup = header` in `config.conf` to hide the listing, or
`quiet_startup = true` to hide the banner as well. Skill warnings remain
visible.

## Terminal controls

Type `/help` for [current commands](src/tui/ui_presentation.luau). See the
[UX guide](docs/ux/README.md) for [commands](docs/ux/commands.md),
[editor and paste](docs/ux/editor.md), and
[transcript states](docs/ux/transcript.md).

| Key                     | Action                                                            |
| ----------------------- | ----------------------------------------------------------------- |
| Enter                   | Send when idle. Try to steer when busy.                           |
| Alt+Enter               | Send when idle. Queue a follow-up when busy.                      |
| Alt+Up                  | Restore all queued messages ahead of the current draft.           |
| Esc                     | Close a picker or interrupt work and restore all queued messages. |
| Ctrl+C                  | Clear the draft. Press twice to exit.                             |
| Ctrl+O / Ctrl+T         | Expand tool output / toggle reasoning text.                       |
| PgUp / PgDn             | Scroll the transcript one page with four rows of overlap.         |
| Ctrl+Home / Ctrl+End    | Jump to the start / follow the latest output.                     |
| Ctrl+Up / Ctrl+Down     | Jump to the previous / next prompt.                               |
| Ctrl+Shift+F            | Find text in the transcript.                                      |
| Ctrl+L                  | Open model selection.                                             |
| Ctrl+G                  | Open the draft in your external editor.                           |
| Ctrl+Z                  | Suspend the foreground job on POSIX. Use `fg` to resume.          |
| Ctrl+- / Ctrl+Y / Alt+Y | Undo an edit / yank killed text / cycle the kill ring.            |
| Ctrl+] / Ctrl+Alt+]     | Jump forward / backward to the next character you type.           |

Use `/queue continue`, `/queue edit`, or `/queue discard` to manage a paused
queue. Completed effects stay done after an interruption. Ctrl+D quits from an
empty editor. Shift+Enter or Ctrl+J inserts a line break. Tab completes and
Shift+Tab cycles thinking effort. Type `@` for recursive file suggestions when
`fd` or `fdfind` is on PATH.

A tool panel can show arguments before any tool runs. Neither a preview nor a
shell tail is a receipt. Usage counts committed calls, not the provider bill.
Unknown token counts are not zero. See
[transcript and outcomes](docs/ux/transcript.md).

## Sessions and compaction

Use `-r` or `--resume` to open the session picker before startup. Use
`--session PATH` to open or create a journal, or give `--session` an existing
session ID or prefix. An ID found in another workspace asks whether to fork it
into the current workspace. `--continue` opens the latest workspace session or
starts a fresh one. `--no-session` keeps the conversation in memory.

Use `/session` to see the session name, file and ID, message and tool counts,
and recorded token usage including cached input.

Use `/export` to write the selected branch as a Markdown file in the launch
directory. Tool output is fenced, and images are listed by type. Use
`/export PATH.jsonl` to preserve image data and open the selected branch in Pi.
Quote paths with spaces. `ui.session_export` in `ui.luau` controls the default
filename prefix and status messages.

An existing session opened by path or through the picker uses its saved
workspace. If that directory is missing, an interactive launch offers to
continue once, fork the archive here, or cancel. A batch launch reports the
missing directory and exits. `--session-dir` overrides the default under
`$XDG_STATE_HOME/cpi-minimal/sessions` or
`$HOME/.local/state/cpi-minimal/sessions`. Interactive `/resume` also selects an
existing journal.

Minimal creates `.jsonl.zst` [journals](../agent/docs/journal.md) and can resume
`.jsonl.gz` journals. Optional `.title` files help users find sessions. Use
`--inspect` or `--watch` with a session path for a
[read-only view](docs/context-journal.md#read-only-inspection).

`/fork ID` creates a new conversation at that cut. Use `--conversation ID` in
batch mode or `/select ID` to change the current path. Forking does not revert
files or processes. See [fork rules](docs/context-journal.md#historical-forks).

Compaction replaces part of the model context with a summary. It does not erase
journal history. On failure the old selection stays in place; proposed summary
tools never run. Use `/compact [focus]` while idle. See
[cut planning](src/session/session.luau) and
[generation hooks](docs/context-journal.md#generation-hooks). Use
`--background-compaction-tokens 0` to turn off background summaries.

`--memory-bytes N` sets an advisory allocator threshold, not a process RSS cap.
See [the limit setting](src/main.zig) for the default. The allocator can still
fail. Thread stacks and native runtime overhead are outside the count.

## Parity limits

See the [UX contract](docs/ux/README.md) and
[coverage ledger](docs/ux/coverage.md) for the intended behavior and
verification evidence.

## Build and validation

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" check test
```

See the [UX coverage ledger](docs/ux/coverage.md) for the checks and their
limits.
