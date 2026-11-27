# Minimal private context actions

Minimal saves changes to `ctx` at yield and return. It commits before its reply
or next effect. The core sees `control.extension`. Minimal owns the payload:

```text
namespace = "cpi-minimal.ctx"
contract = {id: "cpi-minimal.ctx", version: "1"}
action = "assign"

input.value = {
  assign: [{name: string, json: string}],
  erase: [string]
}
```

Each key holds encoded JSON. A nested edit replaces the whole value for that
key. Use `erase` for a lost key, not for a key set to JSON null. No change means
no action. The [codec](../src/session/ContextJournal.zig) owns the exact checks
and value rules. Bad edits or a stale head reject the whole change. Replay reads
helper source as data.

The [shared journal](../../agent/docs/journal.md) holds the messages. Private
state tracks the chosen head, model, and unfinished work. A launch override
applies to the scope at its committed cut, not to the saved preference. Provider
refs do not store keys.

Compaction is a VM operation, not a provider tool call. Its target is the
model-facing context: the next request sees a summary followed by the retained
suffix. The VM appends a checkpoint (`summary`, `first_kept`) so replay can
reconstruct that view. It does not rewrite earlier entries or replace the UI
transcript with the summary. Tool results likewise have separate model and UI
views; UI details are not input to the summarizer.

Reopen uses saved tool and model results. It can start work that never ran. An
interrupted tool can retry only with both old and new declarations marked
retry-safe. An uncertain effect stays interrupted. A manual summary can resume
with its saved input.

## Pending inputs and retry state

The [inbox](../src/session/Inbox.zig) keeps prompts and summary jobs under
stable IDs. Input placement and its receipt commit as one. An idle input may be
placed in its own admission commit. A busy scope can queue it for a later
boundary. A repeated request keeps its first decision. Hosts can gate input with
`when_busy` and `when_idle`. An entry for display alone need not wait on an open
model call.

A summary starts from a saved cut. A stale cut drops the write without changing
context. Background work starts only if there is no active summary in that
scope. A stop joins local work first. Saved OpenAI jobs can get a background
cancel task with the old route, response ID, and retry time.

A turn failure holds pending inputs. Queue resume clears the holds and pause in
one action. The [placement code](../src/session/Controller.zig) owns the rules
for older journals, resets, and after-run work. A prompt's chosen model travels
with its inbox entry and is bound before dispatch.

Host code can call `resumeRootScheduling()` without a CLI wait. `wake()` reports
demand and the next wake time in Unix milliseconds. With `on_wake`, the host
owns the timer; without it, the scheduler owns it. `start_paused` delays work
until resume or wait. The wake callback runs outside the Worker.

Saved waits retain an absolute deadline across restart. See
[Minimal retry policy](../README.md#controller-policy) for when a retry keeps
the request and when it starts fresh.

## Read-only inspection

Use `cpi-minimal --inspect --session PATH` for a JSON view. Use `--watch` for
that view and later changes as JSON Lines. Both accept `--continue` and
`--view-conversation ID`. Neither starts a Worker or needs a provider key.

The view shows committed state, even while another process writes. It includes
the task graph and keeps a bounded window of recent entries. Use `before` to
find the start of an earlier page. A slow watcher gets the latest changed view.

## Historical forks

Use `cpi-minimal --session PATH --fork ENTRY_ID` to get a new ID. Use
`--conversation ID` to work on a fork or fork from it. The TUI has `/fork`.

The fork shares past messages through its anchor. It has its own inbox, tasks,
and later messages. It starts with model settings and selected context at the
cut. A tool result beyond the cut may show as interrupted to keep the next model
request valid. Forking does not undo external changes.

## Tool hooks

`before_tool` sees a checked call. Hooks run in order and can change arguments
or block the tool. Minimal checks and saves the final arguments before dispatch.

`after_tool` can change what goes into the transcript. It sees the raw result
and any fault, even for blocked or interrupted calls. Minimal saves the hook's
decision before applying it. Recovery uses that decision or the staged result;
it does not rerun a known effect. At the restart limit, the staged result wins.

## Generation hooks

Set `generation_hooks` in the
[Minimal Controller](../src/session/Controller.zig).

| Hook                      | What it sees                                                                           |
| ------------------------- | -------------------------------------------------------------------------------------- |
| `before_request`          | Model input for a fresh attempt. The journal keeps the actual projection.              |
| `before_provider_request` | Built wire payload. A rewrite cannot change the admitted model, effort, or output cap. |
| `after_response`          | Terminal reply before the harness decides what comes next.                             |
| `after_tools`             | Saved entry and result IDs in call order.                                              |
| `on_yield`                | A completed answer. First supplied input wins after queued input and resets.           |

The UI reads the recorded tool result. Fresh requests, history replay,
compaction, and context estimates render the model-facing content instead.
Wire-only imports have no recorded result to render and keep their supplied
output. Malformed content blocks produce a tool diagnostic, not a failed
generation.

Request-hook snapshots and provider usage anchors carry a model-view version.
After a rendering upgrade, Minimal discards unsent stale message lists
(including hook rewrites) and runs the configured request hook on rebuilt
history. Historical usage still counts toward spend, but not toward the current
context estimate. Resume and fetch use saved provider state. They do not rebuild
a fresh payload. An adapter can run payload hooks via `Call.preparePayload` for
a fresh start. A hook can run again if stopped before its checkpoint. At the
restart limit, Minimal advances with the staged input or result.

A length cutoff keeps the text, usage, and full reply record. Minimal does not
run calls from a cutoff reply. Compaction still needs a complete summary.
