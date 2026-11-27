# Thinking

Reasoning visibility (Ctrl+T) and request effort are separate controls.
Canonical supported levels are off/minimal/low/medium/high/xhigh/max/ultra; none
aliases off. Never infer capability from an unknown model name.

- /thinking opens a supported-choice picker; /thinking LEVEL commits only a
  supported level.
- Ctrl+R cycles committed supported effort while idle; busy changes reject with
  draft intact.
- Shift+Tab is backward navigation/completion, never an implicit request-setting
  change.
- Picker Up/Shift+Tab move backward; Down/Tab forward; Enter commits.
- Escape/Ctrl+C/Ctrl+D cancel locally without clearing draft, quitting, or
  changing effort.
- Paste does not reach the conversation draft while picker focus is active; show
  local feedback.
- Unsupported/unknown capability completion supplies no speculative options.
- Unknown profile guidance includes a concrete --thinking-levels example and
  --session path (when persistent). Warn that unsent drafts are not persisted
  and memory-only sessions cannot be resumed.
- Model changes clamp unsupported committed selection and report adjustments.
  Same-model restart restores session selection unless explicit startup effort
  overrides it.
- Footer/rules show committed effort, not highlighted candidate. Retain existing
  colors; this change is behavioral, not a theme redesign.
