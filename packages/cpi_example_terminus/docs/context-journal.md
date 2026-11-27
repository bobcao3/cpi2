# Terminus private context actions

Terminus captures implicit private `ctx` updates at live yield and completion
boundaries. Capture commits before acknowledgement or a dependent effect. Its
only execution path uses the semantic journal.

```text
namespace = "cpi-terminus.ctx"
contract = {id: "cpi-terminus.ctx", version: "1"}
action = "capture"

input.value = string containing the encoded private JSON object
```

The namespace state is that encoded string. Unlike Minimal's per-key edits,
Terminus records the complete changed private value. This is not a framework
snapshot of the Worker or conversation.

See the [private context codec](../src/ContextJournal.zig) for the
implementation. Replay replaces opaque private state without executing helper
source or external effects. Pointers and live terminal handles are not restored
as resources.

Core messages hold conversation. Core contexts hold selections and compaction
results. `ContextStore.zig` reads and records those actions through serialized
host-only `readSession` and `recordSession` calls. Those calls require
`host_session_access` and are not exposed to guest tool execution.

There is no separate context persistence file, private conversation mirror,
alternate application runtime, or prototype command-line switch. Binding
fingerprints remain a versioned harness contract.

[Session journal persistence](../../agent/docs/journal.md) describes
synchronization, recovery, execution metadata, and ownership.

`test-session-contexts` covers the private codec and allocation failures.
`test-terminus` and `test-session-prototype` exercise the actual CLI with
loopback providers. Scripted fixtures are not evidence of a paid model or
Terminal-Bench run.
