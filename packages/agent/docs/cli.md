# Standalone agent executable

The executable uses the [semantic session journal](journal.md). Legacy
checkpoint journals are rejected without conversion.

Run the commands on this page from the repository root after
[building cpi2](../../../README.md#build). `cpi-agent` runs local standalone
Luau against a persistent Worker session. It does not connect to a model
provider. For the coding assistant, see
[cpi-minimal](../../cpi_minimal/README.md). For the terminal agent, see
[Terminus](../../cpi_example_terminus/README.md).

[Agent documentation](../README.md) · [Project README](../../../README.md)

## Run Lua

```sh
zig-out/bin/cpi-agent --session demo --journal /absolute/path/demo.jsonl.zst \
  --lua 'ctx.count=(ctx.count or 0)+1; return ctx.count'
```

Reusing the session and journal restores committed `ctx`, so this example
increments the counter across invocations. Each invocation uses a fresh request
ID unless `--request-id ID` is supplied. The executable submits durable close
and closes the file before exiting. It prints an outcome as JSON. Invalid
configuration, corrupt storage, and failed Lua return a nonzero exit with a
readable diagnostic.

This executable installs no external tools or RPC adapters. To attach execution
services, use the [native Controller API](native-controller.md).
