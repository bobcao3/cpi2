# mcp

This client and gateway speak Model Context Protocol. They do not depend on a
Worker, journal, or agent policy.

## Configuration and discovery

```zig
const config = try mcp.Config.parse(gpa, value, &environment);
const gateway = try mcp.Gateway.init(gpa, io, config, .{
    .environment = &environment,
    .output_directory = log_directory,
});
defer gateway.deinit();
gateway.startPreloads();
```

`Gateway.init` takes the config even on error. Keep the environment and log path
alive until shutdown. See the [config parser](src/Config.zig) for fields and
forms. Each server has one URL or one command, never both. URLs use HTTP or
HTTPS. Header values cannot hold CR or LF. `${NAME}` uses the given environment.

Servers start cold. Preload starts jobs for enabled, exposed servers marked
`preload=true`. It does not wait. `refresh` returns false for a job already in
flight. A failed source can reconnect on a later request.

## Cached reads and operations

`status`, `bindings`, `promptSection`, and `tools` with no server read the cache
without connecting. Named `tools`, `describeServer`, and `describeTool` may wait
for discovery. Results belong to the caller. They keep the server's full schema.

A slow server does not block another server. Foreground calls use the caller's
cancellable I/O. See [Gateway](src/Gateway.zig) for the methods. Its tool IDs
are stable across discovery order, at most 64 bytes, and can include a hash.
Collisions fail rather than rename an existing tool.

## Transport and lifetime rules

Each server has its own link and deadline. A link or protocol fault disconnects
that server. A JSON-RPC error keeps a healthy link. A new call can reconnect; it
does not replay an old call. Stdio close signals the group and reaps the child.
Size warnings do not cap the data. See [Client](src/Client.zig) and
[stdio](src/StdioTransport.zig) for the transport rules.

Canceling one wait does not stop shared discovery. Join foreground calls before
`Gateway.deinit`. The gateway then cancels and joins its own jobs before freeing
clients and config. Cached data does not borrow the client's live catalog.

## Minimal integration

Minimal imports
[deferred tools](../cpi_minimal/docs/capability-registration.md). It owns the
grants and policy. See the [service adapter](../cpi_minimal/src/tools/Mcp.zig)
for Minimal's operation names.

## Verification

```sh
anyzig 0.17.1 build test-mcp
```

The [gateway tests](tests/mcp.zig) use an in-memory link without a VM.
