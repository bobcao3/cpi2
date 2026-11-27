# Conversation and queues

## Submission

The table uses Unix defaults. Windows and WSL use Ctrl+Q for follow-ups and
Alt+Q to restore queued messages. Configure either action in `ui.shortcuts`.

| State/action                                                            | Outcome                                                                                                                                                            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Idle Enter / Alt+Enter                                                  | Start immediately; no idle deferred-send promise.                                                                                                                  |
| Working Enter                                                           | Attempt steering at the next committed boundary; otherwise queue a follow-up.                                                                                      |
| Working Alt+Enter                                                       | Queue a follow-up, never steer.                                                                                                                                    |
| During manual `/compact`                                                | Enter queues steering and Alt+Enter queues a follow-up. Once compaction settles, the oldest of those inputs starts the next turn.                                  |
| Manual compaction settles with earlier queued messages and no new input | Preserve the earlier queue and wait for the next prompt. The oldest steer joins that prompt under the default steering mode.                                       |
| Unconfigured prompt                                                     | Preserve draft; explain /login versus /model.                                                                                                                      |
| /send TEXT                                                              | Send TEXT literally, bypassing local commands and skill expansion. Unknown slash commands otherwise reject with literal-send guidance.                             |
| Paused queue with retained inputs + new prompt                          | Append to paused queue; do not implicitly resume older work. If no pending input remains, an explicit new prompt starts a fresh turn.                              |
| Successful completion                                                   | Deliver pending steering first. Run the next follow-up when steering is empty and the queue is running.                                                            |
| Transient provider/transport failure                                    | Remain working; retry the same model step with progress/backoff. Discard provisional previews only; no user resubmission or dependent-queue pause during recovery. |
| Permanent failure or recovery budget exhausted                          | Show one failure outcome; preserve and pause any pending inputs. No paused banner/actions for an empty queue.                                                      |
| Esc while working                                                       | Restore unconsumed steering and follow-ups ahead of the current draft, then interrupt execution. Completed effects remain.                                         |
| Esc during manual compaction                                            | Cancel the summary. Keep queued messages and the current draft.                                                                                                    |
| Esc idle                                                                | Dismiss the current notice or stop manual compaction.                                                                                                              |
| Ctrl+C                                                                  | Clear the draft and arm double-press quit.                                                                                                                         |
| Second Ctrl+C within 500ms                                              | Quit, with joined cleanup.                                                                                                                                         |
| Ctrl+D empty / nonempty                                                 | Quit / delete forward.                                                                                                                                             |

Cancellation reports “Stopped. Completed changes remain.” No rollback is
implied. It does not promise that owned processes keep running.

## Pending input

Follow-ups and unconsumed steering are visibly distinct. Queue pause shows
pending count and Continue/Edit/Discard commands.

- `/queue`: inspect pending status.
- `/queue continue`: resume pending FIFO execution when idle.
- `/queue discard`: discard retained pending input explicitly.
- Alt+Up restores all pending messages with steering first, follow-ups second,
  and the expanded current draft last. Blank lines separate messages.
- `/queue edit` restores the same pending messages into the editor and removes
  the command.
- `/draft` restores the latest displaced draft after submitting that local
  command.
- Failure/cancellation must not silently replay completed or uncertain effects.

Starting a new session or resuming a different one settles unconsumed steering
and follow-ups in the outgoing session. The incoming session loads its own
queue. Selecting a branch with `/select` requires an empty pending queue.

Queue preparation happens at admission. Retained input keeps original text for
editing; skill expansion may be repeated only on explicit resubmission. Shutdown
does not persist unsent drafts or the unadmitted UI queue.
