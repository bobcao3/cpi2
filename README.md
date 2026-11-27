# cpi2

cpi2 is a Zig framework for developers building their own agent harnesses. It
provides a Controller, a Luau Worker runtime, and a journal for durable
sessions. The harness defines the prompts, tools, and user interaction. Minimal
is a coding assistant. Terminus is a terminal agent built on the same framework.
`cpi-agent` runs local Luau in a persistent session without a model.

- [Architecture](#architecture)
- [Build](#build)
- [Run an executable](#run-an-executable)
- [Package guide](#package-guide)
- [Verification](#verification)
- [Markdown formatting](#markdown-formatting)

## Architecture

Native harnesses use `agent.Controller` to start Workers, submit commands, and
mediate external effects. See
[how a turn runs and where each program executes](packages/agent/README.md#architecture-and-ownership).
Use the [C request/feed interface](packages/agent/docs/foreign-controller.md)
when an external host needs to drive the same engine.

The [session protocol](packages/agent/docs/session-frames.md#framework-boundary)
defines shared state transitions without requiring Luau or the Worker loop. The
harness defines its prompt rendering, tool handlers, and versioned private
state. It decides when to compact or retry within the framework’s journal and
effect guarantees.

## Build

Commands below run from the repository root. Use Zig 0.17.1 through `anyzig` and
a compatible local [Kit.zig](https://forge.bc3.moe/bob/Kit.zig) checkout. This
snapshot requires Kit APIs newer than the revisions pinned in the package
manifests, including `kit.timing`. Use `--fork` to select the compatible
checkout:

```sh
sh packages/ghostmux/fonts/fetch.sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" -j4
```

The font script downloads and verifies Ghostmux’s pinned font assets. Run it
once per fresh checkout before building or testing.

The build installs `cpi-agent`, `cpi-minimal`, `cpi-terminus`, Ghostmux and the
native process-service adapter under `zig-out`.

## Run an executable

Start without a provider by running local Lua:

```sh
zig-out/bin/cpi-agent --session demo --journal "$HOME/.local/state/cpi2/lua.jsonl.zst" \
  --lua 'ctx.count=(ctx.count or 0)+1; return ctx.count'
```

For the standalone Luau REPL:

```sh
anyzig 0.17.1 build repl --fork "$HOME/Kit.zig" -j4
```

The [Luau package](vendor/luau/README.md) documents the embedding and native
extension example. The [agent executable guide](packages/agent/docs/cli.md)
covers standalone Lua and persistent request IDs. For provider configuration and
interactive or headless model sessions, follow the coding assistant or terminal
agent guides below.

## Package guide

| Package                                             | Purpose                                                                                                                       |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [Agent](packages/agent/README.md)                   | Native Controller API, private Worker engine, Luau tools, durable context and foreign C ABI.                                  |
| [cpi-minimal](packages/cpi_minimal/README.md)       | Coding assistant with Pi's four default tools, fixed prompts, skills, persistent compaction and a Pi-like terminal interface. |
| [Model registry](packages/model_registry/README.md) | Shared Lua configuration catalog, Zig and Python loaders, provider-specific pricing, and public-catalog maintenance scripts.  |
| [MCP](packages/mcp/README.md)                       | Reusable MCP client, HTTP/stdio transports, request correlation, bounded lifecycle, and catalog/alias gateway.                |
| [Terminus](packages/cpi_example_terminus/README.md) | Terminal-based agent using Controller and Ghostmux-backed operations.                                                         |
| [Services](packages/services/README.md)             | Typed file, text and process operations, native Exec and Ghostmux-backed Process.                                             |
| [Ghostmux](packages/ghostmux/README.md)             | PTY and process multiplexing.                                                                                                 |
| [Luau](vendor/luau/README.md)                       | Embedded VM, compiler, REPL and native extension example.                                                                     |

The table lists the available packages. LSP support is planned, not an available
service in this checkout.

## Verification

Run the native tests and standalone checks from the repository root.

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" test -j4
./formal/check.sh
```

The native suite covers VM embedding, the REPL, controller and service
contracts, the C ABI, journal framing, dotenv fixtures and loopback agent
examples. It includes Terminus's real terminal checks. Ordinary tests use
synthetic configuration and loopback providers rather than local credentials or
paid APIs.

The shell script runs the controller and Kit boundary checks, TLC model checks,
and Lean proofs. See the
[agent verification guide](packages/agent/README.md#verify-the-package) for
focused native checks and the [formal verification guide](formal/README.md) for
tool setup and the scope of each formal suite.

## Markdown formatting

Install
[Biome 2.6.9](https://github.com/biomejs/biome/releases/tag/%40biomejs/biome%402.6.9)
using the standalone binary for your platform. Run `biome format --write .` from
the repository root to wrap Markdown prose at 80 columns. Run `biome format .`
to check formatting. Tables, fenced code, and unbreakable links can exceed the
prose width.
