# cpi-minimal design documentation

## Source tree

[`src/main.zig`](../src/main.zig) wires together the CLI. Each subsystem exposes
its shared types and operations in a Zig file beside its implementation
directory.

| Entry point                             | Responsibility                                           |
| --------------------------------------- | -------------------------------------------------------- |
| [`config.zig`](../src/config.zig)       | Launch configuration, user paths, and preferences        |
| [`session.zig`](../src/session.zig)     | Controller, session journals, queues, and export         |
| [`providers.zig`](../src/providers.zig) | Credentials and model routes                             |
| [`tools.zig`](../src/tools.zig)         | Tool catalog, Luau policies and implementations, and MCP |
| [`skills.zig`](../src/skills.zig)       | Skill discovery and expansion                            |
| [`images.zig`](../src/images.zig)       | Codecs, image normalization, and model attachments       |
| [`tui.zig`](../src/tui.zig)             | Terminal entry points and Luau presentation              |

The TUI has its own [composer](../src/tui/composer.zig),
[pickers](../src/tui/pickers.zig), [style](../src/tui/style.zig), and
[transcript](../src/tui/transcript.zig) entry points. Files within a subsystem
can import neighboring implementation files directly.

## UX contract

Start with the [UX contract](ux/README.md). This is the accepted target design
following the comparative usability audit, not a claim of complete
implementation or Pi parity. The coverage ledger identifies regression
requirements; implementation and verification results are reported separately.

See the [UX directory](ux/README.md#directory) for the individual contracts and
the [coverage ledger](ux/coverage.md) for their regression requirements.

## Session persistence

Both CLIs use the shared action journal. These pages describe its schema,
Minimal's private contracts, and request projection.

- [Shared session frames](../../agent/docs/session-frames.md) defines the linear
  capability, control and document log.
- [Complete JSONL examples](../../agent/docs/session-frame-examples.md) covers
  provider tools, replacement, compaction and custom JSON actions.
- [Minimal private context actions](context-journal.md) defines the
  harness-owned format for implicit ctx assignment and mutation capture.
- [Context rendering proposal](prompt-composition.md) records the design for
  pinning documents and controls at a committed position.
- [Deferred capability and tool registration](capability-registration.md)
  separates source discovery, native bindings, provider advertisements and
  Minimal-owned handler/state contracts. It requires no shared callable or
  prompt-part registry.
