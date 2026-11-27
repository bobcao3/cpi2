# Capabilities and context

A Luau capability is a tool module. A native binding lets tools ask for an
endpoint. A provider tool tells the model what it can call. None of these grants
the others. See [session frames](session-frames.md#provider-tool-actions) for
what the journal records.

## Capability definitions and endpoints

Start with [read.lua](../extensions/read.lua) or
[bash.lua](../extensions/bash.lua). The module returns a tool descriptor. You
can add a tool with no Worker change. For a new endpoint, declare a service
operation too. Add it to the Worker's grants and the tool's allowed endpoints.
Attaching a service grants nothing.

Registered tools must return at most 128 KiB (131,072 bytes) of JSON-encoded
result text, including structured details and JSON escaping. Images emitted via
`output.image` are separate. Tools should page or truncate large results before
returning them. The VM raises a tool error above the limit; this does not undo
host effects. Applications can use `agent.encodeToolResult(value)` to enforce
the same limit on synthesized or hook-replaced tool results.

## Seed and recovered capabilities

`Config.capabilities` and the [C builder](foreign-controller.md#open-a-session)
seed new journals only. Reopen restores the saved tools. For a fixed catalog,
use [atomic launch](native-controller.md#launch-a-configured-worker-atomically).
Wait for a successful return or `READY`, not per-tool events. Leave the catalog
alone if the caller owns a dynamic set.

## Registration and capability revisions

Submit `.register_capability` or `.unregister_capability` through Controller.
The Worker loads the module once to check it but does not call `execute`.
Controller checks grants and policy before use. A denial leaves the catalog
unchanged. See
[request ID rules](foreign-controller.md#commands-and-request-ids).

| Event                    | Meaning                                                        |
| ------------------------ | -------------------------------------------------------------- |
| `COMMAND_COMMITTED`      | Command is durable. The tool is not active yet.                |
| `CAPABILITIES_COMMITTED` | New revision is active.                                        |
| `COMMAND_FINISHED`       | Command is done. Failed changes leave the old revision active. |

A model request pins the tool revision for both its ads and its Lua. A
stand-alone invocation pins its own revision at start. Nested calls keep that
version. Replace or remove tools without changing `ctx`. Old work keeps its
tools until it ends; use cancel to stop it. Native calls still check grants each
time.

The journal keeps source or immutable source links, not live closures. It keeps
older versions for work that still needs them. On reopen the Worker rebuilds the
closures without asking the host for a past catalog.

## Model-side Lua and checkpoints

Model code sees `tools`, `ctx`, and a small set of Lua libraries. It cannot load
native modules or call `host`, `debug`, `io`, or `os`. Only trusted tools get
`host.call`. See [where Luau runs](../README.md#where-luau-runs) for heaps and
state. This is not an OS sandbox.

A new session starts with an empty `ctx`. Use values that can be saved, such as
tables with no cycles and plain values. Do not store functions, threads, or
pointers. Reopen loads the last checkpoint. Each call has fresh locals. A tool
can keep private state in its live closure, but that state does not survive
replacement or reopen.

Before a tool effect, the Worker saves `ctx` and intent in the same commit. It
saves the result before Lua goes on. A successful return saves final `ctx` and
the result together. An error or stop drops only changes since the last
checkpoint. It cannot undo an effect.

## Mutable application helper publication

Use `agent.compile` to check source without running it. Use `agent.checkSchema`
then `agent.validate` for arguments. The
[VM library](../src/vm/application.luau) owns the API. Call `agent.prepareTools`
before the checkpoint. Call the closure it returns only after commit. It swaps
the tool bindings; it does not save them. See
[Minimal's deferred tools](../../cpi_minimal/docs/capability-registration.md).

## Example read and shell modules

[Read](../extensions/read.lua) maps a byte range to `files.read`. It needs text.
[Bash](../extensions/bash.lua) calls `process.exec`. A nonzero exit is a result,
not a tool error. The shell can reach files the host can reach. See the
[service guide](../../services/README.md) for exact result and log rules.

## Runtime limits and compatibility

Luau fuel counts safe points, not bytecode steps. The heap counts live calls,
tool versions, and kept bytecode. It does not count scratch space in the
upstream compiler. See [limits](../src/config.zig) and the [VM](../src/vm.zig).

This is [Luau](../../../vendor/luau/README.md), not Lua 5.4 or 5.5. Its
protected calls must catch nonlocal exits before they cross Zig cleanup frames.
The built-in libraries and JSON Schema subset are small. `string.find` is plain
search. JSON uses finite binary64 numbers. An empty table is an object. Lua
returns its first value, or JSON null if it returns none.

## Interrupted programs

[Recovery](journal.md#replay-and-recovery) keeps committed `ctx` and known
results. It does not bring back Lua stacks or replay uncertain effects.
