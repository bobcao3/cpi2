# Transcript and outcome visibility

The transcript renders a committed
[context selection](../../../agent/docs/session-frames.md#context-actions).
Changing the selection does not delete earlier messages.

Fullscreen displays one continuous transcript for the selected session,
including live output. Page Up and Page Down move by the viewport height minus
four rows, with a minimum of one row. Ctrl+Home and Ctrl+End jump to the start
and latest output. Ctrl+Up and Ctrl+Down move between prompts relative to the
top visible row.

Scrolling back keeps the viewport on the rows you are reading as new output
arrives. Select **Jump to latest message** or press Ctrl+End to resume following
new output. The scrollbar appears while scrolling or hovering at the right edge.
Click the track to jump within the transcript, or drag the thumb.

Ctrl+Shift+F opens **Find in transcript**. Search is case-insensitive and treats
runs of whitespace and rendered row breaks as a single space. Enter or Ctrl+G
advances to the next match. Shift+Enter or Ctrl+Shift+G goes to the previous
match. The overlay arrows do the same. Esc closes search and leaves the viewport
in place.

The default composer embeds the working, retry, compaction, and branch-summary
indicators in its top border. Retries show the attempt and countdown with an Esc
cancellation hint. The spinner can take the place of the label when the border
also needs to show hidden lines. The session tree replaces the composer while it
is open. Reset only uncommitted text/argument cards; committed assistant/tool
results and external effects remain. Batch stdout emits committed replies only
so transient previews cannot duplicate script output.

Tool cards retain arguments/queued/running/result phases. Partial arguments are
not execution evidence. Ctrl+O globally expands retained results; [+] is not a
mouse button. Ctrl+T only changes reasoning-summary visibility. Compaction
retains archive/branches; incomplete summaries do not replace context.

Replies keep reasoning and prose in order. In fullscreen, click a reasoning run
or its placeholder to toggle that run. Ctrl+T resets individual overrides and
changes the global preference.

Show elapsed time and bounded, sanitized output on running shell cards when
available. Observations are provisional, not durable receipts or proof of
completion. Reading progress must not execute tools, bypass Controller
authorization, alter process lifetime, or create an implicit timeout. Keep
no-default-timeout behavior for intentional long work.

Follow-up and unconsumed steering input are inspectable while working. Show
paused queue status and explicit recovery commands only when pending input
actually exists. Output and queue previews must remain bounded.

Persistent in-process outcome is separate from replaceable notice/help.
`/outcome dismiss` clears it without erasing history; restart-required outcomes
cannot be dismissed. This is not notice persistence across process exit. It
retains failure, cancellation, session-only preference success, and
rollback/restart instructions for `/outcome`, but an acknowledged error is no
longer displayed as current after a new turn or successful model change. Modal
pickers do not repeat the underlying outcome. Restart-required outcomes remain
visible. Distinguish known completed effects from unknown outcomes; never
promise a full effect inventory or automatic safe replay. A terminal request
failure has one concise outcome containing the actionable provider message, not
a raw JSON card plus a generic failure notice plus repeated queue instructions.
Structured diagnostics remain available in recorded data/batch diagnostics; the
active route stays in the footer. Ordinary local validation stays transient.

Fork outcome: “Conversation changed. Files and processes were not reverted.”
Cancel outcome: “Stopped. Completed changes remain.” This is not rollback.

## Footer

The first row shows the workspace, its Git branch when available, and the
explicit session name. It follows branch switches while the UI is open. Detached
HEAD appears as `(detached)`. Set or inspect the title with `/name`.

The second row shows cumulative usage and the context estimate. Context usage
appears as unknown after compaction until another assistant response reports
usage. The provider prefix appears when multiple providers offer models and
there is room for the complete label.

## Streaming Markdown tables

A pipe-separated header stays ordinary text until the next line has one
delimiter per column (`---`, `:---`, `:---:`, or `---:`; extra dashes are fine).
Once recognized, the header and body become a table in the same transcript card.
Rows need not have outer pipes. Short pipe rows, including the one currently
streaming, leave missing cells blank; an overfull row ends the table rather than
hiding its extra text. Use `\|` for a literal pipe. Fenced code and headers
wider than 32 columns stay text.

**Why Kit's `table` node?** Kit's
[framework design and examples](https://forge.bc3.moe/bob/Kit.zig/src/commit/24f6742702cf7a5906d8c5f8a4dd4aaf28aac341/docs/tui_framework_design.tsx)
distinguish measured tables from fixed-width report columns. Fixed widths suit
append-only metrics with known fields; chat has neither known widths nor
irrevocable rows. Measured columns can reflow earlier cells as new text arrives.
A `grid` is useful for spans and joined borders, neither of which pipe tables
express. Padding a `text` node by hand would duplicate terminal-cell measurement
and wrapping. A `stack` is enough to interleave the native table with prose.

Tables that fit, including exact fits, keep their columns. If the measured
column widths plus gaps exceed the space inside the card, each row becomes a
`title : content` list with a horizontal divider between rows. Streaming more
text or receiving a terminal resize report recalculates the fit. On terminals
without resize reports, the next input or update redraws at the new size.

The fullscreen renderer supplies the accumulated message on each frame. History
renders the same source. Batch replies keep their Markdown.

## Code highlighting

Expanded Read results, Write previews, and Markdown fences use Tree-sitter.
While Write arguments stream, the first 50 lines share parser context. Newly
appended lines beyond that prefix are highlighted individually. A finished Write
uses the whole source. Markdown fences use their declared language and indent
the rendered code two spaces. Unsupported languages use a single code color.

Code-mode cards show elapsed time and nested tool calls while the script runs.
Collapsed cards show the first ten wrapped source rows, the most recent eight
calls, and the first five wrapped output rows. Ctrl+O expands the card. Finished
cards show the script's duration and omit the execution header that accompanies
the result sent to the model. Cancelling a script during a nested host operation
retains the last recorded call list in the transcript.

## Tool images

Inline previews sit below the tool card in both collapsed and expanded views.
Kitty displays PNG directly and receives a converted PNG for JPEG, WebP, GIF,
and BMP. Kitty conversion applies EXIF orientation where present and uses the
first frame of animated GIF and WebP. iTerm2 receives the original image bytes
in regular mode. Fullscreen uses the text fallback on iTerm2. Image width and
terminal cell size affect placement.

Tool results go through inline image preparation after the final tool hook. When
conversion or resizing succeeds, the saved transcript and subsequent model
requests use the prepared image and include its conversion or resize hint. When
preparation fails, the result keeps the image it received. Code-mode downloads
keep the bytes originally emitted by the script.

Footer retains workspace, active model, committed effort, estimated context and
committed usage. Usage is not billing; branches/compaction do not reset
cumulative accounting.
