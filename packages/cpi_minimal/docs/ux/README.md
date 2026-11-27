# UX contract

This directory specifies the cpi-minimal interaction contract. It is a target
design, not a claim of complete implementation or Pi parity.
[Coverage](coverage.md) records implementation and verification evidence.

## Principles

- Stop execution without losing drafts or silently running dependent work.
- Focus owns both keys and paste. Modal cancellation closes only the modal.
- Search selects listed choices; custom identifiers require an explicit action.
- Recognize sessions and fork points from previews, not filesystem archaeology.
- Preserve meaningful outcomes independently of transient help/notices.
- Conversation changes and cancellation do not roll back external effects.

## State and dispatch

Process: launch → batch/list or interactive → joined shutdown. Interactive state
combines run (idle/working), queue (running/paused), editor, focus
(conversation/dialog/thinking), and view (live/history). UI queues contain
prepared input, not admitted Worker commands.

1. Frame input; ignore release events.
2. Route keys **and paste** to focused modal. Escape/Ctrl+C/Ctrl+D cancel
   locally.
3. In conversation, typing updates the command or file suggestions for the
   current prefix. Escape closes an open completion menu.
4. Apply editing/submission shortcuts. Unsupported keys do not change selection.
5. Shift+Tab cycles the available thinking levels when the conversation composer
   has focus. Ctrl+T toggles reasoning visibility. Ctrl+O toggles tool output
   and expands or collapses startup help.

## Directory

- [Process and CLI](process.md)
- [Conversation, cancellation, queues](conversation.md)
- [Editor and completion](editor.md)
- [Commands](commands.md)
- [Authentication/model/session/fork dialogs](dialogs.md)
- [Thinking](thinking.md)
- [Transcript and outcomes](transcript.md)

The formal lifecycle contracts, manual source correspondence, and known findings
are in `formal/tla/`. These UX tables establish no Zig refinement proof.
