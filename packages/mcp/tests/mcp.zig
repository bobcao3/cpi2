const std = @import("std");
const mcp = @import("mcp");

const Json = mcp.Json;
const Config = mcp.Config;
const transport = mcp.Transport;

fn waitFixture(event: *std.Io.Event, io: std.Io) error{Canceled}!void {
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
    while (true) {
        event.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
            error.Timeout => {
                if (std.Io.Timestamp.now(io, .awake).compare(.gte, deadline))
                    std.debug.panic("MCP fixture synchronization deadline exceeded", .{});
                continue;
            },
            error.Canceled => return error.Canceled,
        };
        return;
    }
}

const Fixture = struct {
    mode: enum { normal, malformed, notifications, server_request, tool_error } = .normal,
    calls: usize = 0,
    answered: usize = 0,
    tool_calls: usize = 0,
    block_initialize: bool = false,
    block_tool_call: bool = false,
    called: std.Io.Event = .unset,
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,
    closed: bool = false,

    fn send(context: *anyopaque, a: std.mem.Allocator, io: std.Io, body: []const u8, _: ?[]const u8, _: []const u8, _: u64) anyerror!transport.Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.mode == .malformed) return .{ .body = try a.dupe(u8, "{not json") };
        const request = try Json.parse(a, body);
        const method = Json.text(Json.get(request, "method"));
        const id = Json.get(request, "id");
        // Response to a server-initiated request, not a request of our own.
        if (method.len == 0 and id != .null) {
            self.answered += 1;
            return .{};
        }
        if (std.mem.eql(u8, method, "notifications/initialized")) return .{};
        if (std.mem.eql(u8, method, "initialize")) {
            self.entered.set(io);
            if (self.block_initialize) try waitFixture(&self.released, io);
            const envelope = try Json.value(a, .{
                .jsonrpc = "2.0",
                .id = id,
                .result = .{
                    .protocolVersion = "2025-06-18",
                    .capabilities = .{ .tools = .{ .listChanged = true } },
                    .serverInfo = .{ .name = "fixture", .version = "1.0.0" },
                    .instructions = "fixture instructions",
                },
            });
            return .{ .body = try Json.encode(a, envelope), .session_id = try a.dupe(u8, "session-1") };
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            const params = Json.get(request, "params");
            const cursor = Json.text(Json.get(params, "cursor"));
            var list = Json.array(a);
            if (cursor.len == 0) try list.array.append(try Json.value(a, .{
                .name = "echo",
                .description = "echo text",
                .inputSchema = .{ .type = "object", .properties = .{ .text = .{ .type = "string" } } },
            }));
            var result = Json.object();
            try Json.put(a, &result, "tools", list);
            if (cursor.len == 0) try Json.put(a, &result, "nextCursor", Json.string("next"));
            const envelope = try Json.value(a, .{ .jsonrpc = "2.0", .id = id, .result = result });
            if (self.mode == .server_request) {
                const ping = try Json.encode(a, try Json.value(a, .{ .jsonrpc = "2.0", .id = 99, .method = "ping" }));
                const response = try Json.encode(a, envelope);
                const sse = try std.fmt.allocPrint(a, "data: {s}\n\ndata: {s}\n\n", .{ ping, response });
                return .{ .body = sse, .sse = true };
            }
            return .{ .body = try Json.encode(a, envelope) };
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            self.tool_calls += 1;
            self.called.set(io);
            if (self.block_tool_call) try waitFixture(&self.released, io);
            const params = Json.get(request, "params");
            const arguments = Json.get(params, "arguments");
            const text = Json.text(Json.get(arguments, "text"));
            const result = try Json.value(a, .{ .content = .{.{ .type = "text", .text = try std.fmt.allocPrint(a, "echo:{s}", .{text}) }}, .isError = false });
            const envelope = if (self.mode == .tool_error)
                try Json.value(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32000, .message = "tool failed" } })
            else
                try Json.value(a, .{ .jsonrpc = "2.0", .id = id, .result = result });
            if (self.mode == .notifications) {
                const notification = try Json.encode(a, try Json.value(a, .{ .jsonrpc = "2.0", .method = "notifications/tools/list_changed" }));
                const response = try Json.encode(a, envelope);
                const sse = try std.fmt.allocPrint(a, "data: {s}\n\ndata: {s}\n\n", .{ notification, response });
                return .{ .body = sse, .sse = true };
            }
            return .{ .body = try Json.encode(a, envelope) };
        }
        if (std.mem.eql(u8, method, "resources/list")) {
            const envelope = try Json.value(a, .{ .jsonrpc = "2.0", .id = id, .result = .{ .resources = Json.array(a) } });
            return .{ .body = try Json.encode(a, envelope) };
        }
        return error.UnsupportedMethod;
    }

    fn receive(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: u64) anyerror![]u8 {
        return error.Unsupported;
    }

    fn close(context: *anyopaque, _: std.mem.Allocator, _: std.Io) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.closed = true;
    }

    const vtable: transport.Transport.VTable = .{
        .send = send,
        .receive = receive,
        .close = close,
    };

    fn factory(context: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *const mcp.Server, _: *const std.process.Environ.Map, _: []const u8) anyerror!transport.Transport {
        return .{
            .context = @ptrCast(@alignCast(context.?)),
            .vtable = &vtable,
            .mode = .exchange,
        };
    }
};

fn fixtureGateway(a: std.mem.Allocator, env: *const std.process.Environ.Map, fixture: *Fixture) !*mcp.Gateway {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const value = try Json.parse(temporary.allocator(), "{\"servers\":{\"fixture\":{\"url\":\"http://fixture/mcp\"}}}");
    const config = try Config.parse(a, value, env);
    return mcp.Gateway.init(a, std.testing.io, config, .{
        .environment = env,
        .output_directory = "/tmp",
        .transport_factory = .{ .context = fixture, .create = Fixture.factory },
    });
}

test "gateway discovers, describes, and calls through a transport" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{};
    var gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const listed = try gateway.tools(a, std.testing.io, "fixture");
    const tools = Json.items(Json.get(listed, "tools"));
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("echo", Json.text(Json.get(tools[0], "name")));
    try std.testing.expectEqualStrings("mcp_fixture_echo", Json.text(Json.get(tools[0], "identifier")));

    const described = try gateway.describeTool(a, std.testing.io, "fixture", "echo");
    try std.testing.expectEqualStrings("fixture", Json.text(Json.get(described, "server")));
    try std.testing.expect(Json.get(described, "input_schema") == .object);

    const result = try gateway.call(a, std.testing.io, "fixture", "echo", try Json.value(a, .{ .text = "hello" }));
    try std.testing.expectEqualStrings("echo:hello", Json.text(Json.get(Json.items(Json.get(result, "content"))[0], "text")));

    const bindings = try gateway.bindings(a);
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqualStrings("mcp_fixture_echo", bindings[0].name);

    const status = try gateway.status(a);
    try std.testing.expect(Json.get(Json.items(Json.get(status, "servers"))[0], "connected") == .bool);
    try std.testing.expect(Json.get(Json.items(Json.get(status, "servers"))[0], "connected").bool);
}

test "list_changed notifications mark the catalog dirty and sync refreshes it" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .mode = .notifications };
    var gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try gateway.tools(a, std.testing.io, "fixture");
    _ = try gateway.call(a, std.testing.io, "fixture", "echo", try Json.value(a, .{ .text = "hello" }));
    try std.testing.expect(gateway.syncCatalogs());
    try std.testing.expect(!gateway.syncCatalogs());
}

test "malformed server data fails the operation but does not poison the gateway" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .mode = .malformed };
    var gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.McpProtocol, gateway.tools(a, std.testing.io, "fixture"));
    fixture.mode = .normal;
    const listed = try gateway.tools(a, std.testing.io, "fixture");
    try std.testing.expectEqual(@as(usize, 1), Json.items(Json.get(listed, "tools")).len);
}

test "server requests are answered instead of being mistaken for responses" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .mode = .server_request };
    var gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try gateway.describeServer(a, std.testing.io, "fixture");
    // The fixture sends a ping request before the tools/list response. The
    // client must answer it rather than treating it as its own response.
    try std.testing.expect(fixture.answered == 2);
    try std.testing.expect(fixture.calls > 0);
}

test "a JSON-RPC tool error keeps the connection and catalog" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .mode = .tool_error };
    var gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try gateway.tools(a, std.testing.io, "fixture");
    try std.testing.expectError(error.McpServerError, gateway.call(a, std.testing.io, "fixture", "echo", try Json.value(a, .{ .text = "hello" })));
    const calls = fixture.calls;
    const listed = try gateway.tools(a, std.testing.io, "fixture");
    try std.testing.expectEqual(@as(usize, 1), Json.items(Json.get(listed, "tools")).len);
    try std.testing.expectEqual(calls, fixture.calls);
}

test "cold sources stay cold and cached reads do not wait for discovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .block_initialize = true };
    const gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    gateway.startPreloads();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(try gateway.refresh("fixture"));
    try waitFixture(&fixture.entered, io);
    try std.testing.expect(!try gateway.refresh("fixture"));
    const state = Json.items(Json.get(try gateway.status(a), "servers"))[0];
    try std.testing.expectEqualStrings("loading", Json.text(Json.get(state, "state")));
    try std.testing.expectEqual(@as(usize, 0), Json.items(Json.get(try gateway.tools(a, io, ""), "tools")).len);
    try std.testing.expectEqual(@as(usize, 0), (try gateway.bindings(a)).len);
    try std.testing.expect(std.mem.indexOf(u8, try gateway.promptSection(a), "fixture") != null);
    fixture.released.set(io);
    const listed = try gateway.tools(a, io, "fixture");
    try std.testing.expectEqual(@as(usize, 1), Json.items(Json.get(listed, "tools")).len);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
}

test "canceling a discovery waiter does not replay calls and gateway shutdown joins its source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .block_initialize = true };
    const gateway = try fixtureGateway(gpa, &env, &fixture);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var waiting = try io.concurrent(mcp.Gateway.tools, .{ gateway, arena.allocator(), io, "fixture" });
    try waitFixture(&fixture.entered, io);
    try std.testing.expectError(error.Canceled, waiting.cancel(io));
    gateway.deinit();
    try std.testing.expect(fixture.closed);
    try std.testing.expectEqual(@as(usize, 0), fixture.tool_calls);
}

test "a blocked preloaded server does not serialize a healthy server" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const Servers = struct {
        slow: Fixture = .{ .block_initialize = true },
        healthy: Fixture = .{},

        fn create(raw: ?*anyopaque, a: std.mem.Allocator, task_io: std.Io, server: *const mcp.Server, environment: *const std.process.Environ.Map, directory: []const u8) anyerror!transport.Transport {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return Fixture.factory(if (std.mem.eql(u8, server.name, "slow")) &self.slow else &self.healthy, a, task_io, server, environment, directory);
        }
    };
    var servers: Servers = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try Config.parse(gpa, try Json.parse(a,
        \\{"servers":{"slow":{"url":"http://slow","preload":true},"healthy":{"url":"http://healthy"}}}
    ), &env);
    const gateway = try mcp.Gateway.init(gpa, io, config, .{
        .environment = &env,
        .output_directory = "/tmp",
        .transport_factory = .{ .context = &servers, .create = Servers.create },
    });
    defer gateway.deinit();
    gateway.startPreloads();
    try waitFixture(&servers.slow.entered, io);
    const listed = try gateway.tools(a, io, "healthy");
    try std.testing.expectEqual(@as(usize, 1), Json.items(Json.get(listed, "tools")).len);
    const result = try gateway.call(a, io, "healthy", "echo", try Json.value(a, .{ .text = "independent" }));
    try std.testing.expectEqualStrings("echo:independent", Json.text(Json.get(Json.items(Json.get(result, "content"))[0], "text")));
    try std.testing.expectEqual(@as(usize, 1), servers.slow.calls);
}

test "canceling a remote call joins transport I/O and never replays that call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var fixture: Fixture = .{ .block_tool_call = true };
    const gateway = try fixtureGateway(gpa, &env, &fixture);
    defer gateway.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var call = try io.concurrent(mcp.Gateway.call, .{ gateway, a, io, "fixture", "echo", try Json.value(a, .{ .text = "once" }) });
    try waitFixture(&fixture.called, io);
    try std.testing.expectError(error.Canceled, call.cancel(io));
    try std.testing.expect(fixture.closed);
    const listed = try gateway.tools(a, io, "fixture");
    try std.testing.expectEqual(@as(usize, 1), Json.items(Json.get(listed, "tools")).len);
    try std.testing.expectEqual(@as(usize, 1), fixture.tool_calls);
}
