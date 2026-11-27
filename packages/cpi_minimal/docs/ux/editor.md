# Editor and input

## Editing

Conversation and single-line dialog fields share Ctrl+A/E (logical-line
boundaries), Ctrl+U/K (delete prefix/suffix), Ctrl+W/Alt+Backspace (previous
word), Alt+Left/Right (word movement), and grapheme Left/Right/Backspace/Delete.
Dialogs retain single-line validation, masking and size limits. Cursor-only and
unsupported keys preserve highlighted choices.

The composer wraps at word boundaries and at boundaries next to CJK graphemes.
Long words wrap at grapheme boundaries. Up/Down move displayed rows, including
soft wraps, and reach history at the editor boundaries. Home/End target logical
lines. Shift+Enter or Ctrl+J inserts a newline in conversation. Modified Enter
requires terminal support.

Word movement and word deletion share boundaries. On supported systems Kit uses
the installed ICU word dictionaries for multilingual text. Kit groups letters
and punctuation directly when ICU is unavailable.

## Transcript selection

Drag in the transcript to select complete graphemes. Double-click selects a word
or path. Triple-click selects a displayed line. Drag at the transcript edge to
extend the selection through earlier or later rows. Releasing copies the
selected rows, with a newline at each visual wrap.

Ctrl+X and `/copy` copy the last assistant message in the session. Copies use
the desktop clipboard where available and OSC 52 in remote or headless Linux
terminals.

## Completion

- Type `/` at the start of the first line for commands. Type a skill’s bare name
  after the slash or use the `/skill:` prefix. Use Up/Down or PgUp/PgDn to
  browse the menu, which shows five suggestions at a time.
- Tab or a click inserts the choice and closes the menu. Enter inserts an
  argument or path and submits a command name. Escape closes the menu. Backspace
  and Delete can reopen it when the edited text matches.
- `/model`, `/login`, and `/thinking` suggest arguments from provider discovery,
  supported login providers, and the current model's thinking levels. After
  completing the command name with Tab, type part of the argument to open its
  suggestions. The text after a skill command goes to the skill as input.
- A command in `ui.luau` can supply its own argument choices as a `completion`
  list. With the menu closed, Tab on an empty slash-command argument leaves the
  draft alone. Tab after a nonempty argument can complete a path.
- Type `@` at the start of a token to find workspace files and directories with
  `fd` or `fdfind` on PATH. A directory prefix scopes the search. The menu
  quotes paths with separators, adds a space after a file, and leaves the cursor
  ready to continue a directory path. The reference is sent as prompt text.
- Tab on an ordinary path searches its current directory. With a single file or
  directory match, Tab can insert it directly.
- Shift+Tab cycles thinking effort. Ctrl+L opens model selection. Use `/draft`
  to restore a displaced draft.

## Undo and killed text

Ctrl+- undoes the last edit or typed word. A paste is one edit, including a
paste shown as a marker. Ctrl+U, Ctrl+K, Ctrl+W, and Alt+D cut text into the
kill ring. Ctrl+Y yanks the latest kill. Alt+Y cycles through earlier kills
immediately after a yank. The transcript search field has its own undo history
and kill ring.

## Character jumps and mouse placement

Press Ctrl+] or Ctrl+Alt+], then type a character to jump forward or backward.
The search is case-sensitive and continues across logical lines. Either jump
shortcut cancels a pending jump. A jump into a grapheme or an opaque paste
marker places the cursor at the start of that unit.

A click on a composer row moves the cursor to the corresponding displayed
character, including on wrapped lines. Dragging selects and copies visible text
without moving the cursor.

## External editor

Ctrl+G opens the full draft, including expanded paste markers, in a temporary
Markdown file. Set `external_editor` in `~/.cpi-minimal/config.conf` or set
`VISUAL` or `EDITOR`. Minimal checks those in order and defaults to `nano`
(`notepad` on Windows).

When the editor exits successfully, the edited text returns to the composer with
the cursor at the end. Use Ctrl+- to restore the previous draft or Enter to
submit the edited one. If the editor fails, the draft and cursor stay where they
were. A running model turn continues while the external editor has the terminal.

## Shell job control

Type `!command` to run a shell command in the workspace. Type `!!command` to
keep the command and its output local to the transcript. Both appear in shell
cards with live output. Ctrl+O expands their output alongside the model's tool
output. A `!` result becomes context for the next model turn. Running either
form leaves the model idle unless a turn is already running.

A command can run alongside a model turn. Escape interrupts an active model turn
first. With the model idle, Escape cancels the shell command and keeps its
output so far. Submitting another shell command while one is running keeps the
new command in the composer.

Opening or dismissing the resume picker leaves the shell running. `/new` and a
confirmed switch to a different session cancel the shell and place its partial
result in the outgoing transcript. Branch selection within the same session
keeps the shell running.

On POSIX, Ctrl+Z or an external SIGTSTP releases the terminal and suspends the
foreground process group. Run `fg` in the shell to redraw the interface and
resume the draft and active model turn.

## Paste

Ctrl+V reads the system clipboard while the composer has focus. It tries copied
file paths on macOS, then images, then text. Copied paths go on separate lines
or become quoted, space-separated arguments for a `!` command. Pasting an image
inserts the path of a temporary file that stays available after submission.
Clipboard text inserts at the current cursor as one undoable edit, including
long text.

On Linux, Minimal can read the X11 clipboard through the system's `libxcb.so.1`
when `xclip` and `xsel` are unavailable.

On Windows, an unmodified right-click in fullscreen can paste text into the
focused field. VS Code and Tabby handle their own right-click paste.

Bracketed paste never submits by itself. It normalizes line endings and tabs,
strips terminal controls, and replaces invalid UTF-8. A paste over 1,000 UTF-16
code units or 10 lines becomes a marker that preserves the full text. A marker
can wrap visually and remains one unit for editing. Submit expands markers
before interpretation.

Payloads up to 8 MiB are framed atomically. Overlimit input is discarded through
the closing delimiter, never interpreted as keys/commands; preserve the draft
and explain recovery. In dialogs, trim incidental leading/trailing CR/LF from
pasted fields, reject embedded newlines/Escape, retain the 8192-byte field
limit. Do not echo secret data in errors.

Modal focus owns paste; a thinking/confirmation picker does not modify the
underlying draft. Explain that the modal must close before pasting.
