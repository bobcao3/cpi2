const std = @import("std");
const agent = @import("agent");
const services = @import("services");
const ws = agent.responses_websocket;
const responses = agent.responses;

const Loopback = struct {
    server: std.Io.net.Server,
    body: [16384]u8 = undefined,
    body_len: usize = 0,
    bad_accept: bool = false,
    held: bool = false,
    close_after_request: bool = false,
    disconnect_first: bool = false,
    received: std.Io.Event = .unset,
    requests: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    const completed = "{\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}]}}";

    fn run(self: *Loopback, io: std.Io) void {
        const count: usize = if (self.close_after_request) 3 else if (self.disconnect_first) 2 else 1;
        for (0..count) |_| self.serve(io) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn serve(self: *Loopback, io: std.Io) !void {
        const connection = try self.server.accept(io);
        defer connection.close(io);
        const attempt_index = self.requests.fetchAdd(1, .acq_rel);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = connection.reader(io, &read_buffer);
        var writer = connection.writer(io, &write_buffer);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        try std.testing.expectEqual(.GET, request.head.method);
        var key: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) key = header.value;
            try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization"));
        }
        var accept: [28]u8 = undefined;
        ws.acceptKey(key orelse return error.MissingKey, &accept);
        if (self.bad_accept) accept[0] = '!';
        try writer.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
        try writer.interface.flush();
        const r = &reader.interface;
        if (self.bad_accept) {
            _ = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            self.body_len = 1;
            return;
        }
        try std.testing.expectEqual(0x81, try r.takeByte());
        const second = try r.takeByte();
        try std.testing.expect(second & 0x80 != 0);
        self.body_len = switch (second & 0x7f) {
            126 => try r.takeInt(u16, .big),
            127 => @intCast(try r.takeInt(u64, .big)),
            else => second & 0x7f,
        };
        if (self.body_len > self.body.len) return error.RequestTooLarge;
        var mask: [4]u8 = undefined;
        try r.readSliceAll(&mask);
        try r.readSliceAll(self.body[0..self.body_len]);
        for (self.body[0..self.body_len], 0..) |*byte, index| byte.* ^= mask[index % 4];
        self.received.set(io);
        if (self.disconnect_first and attempt_index == 0) {
            const delta = "{\"type\":\"response.output_text.delta\",\"delta\":\"uncommitted\"}";
            try writer.interface.writeAll(&.{ 0x81, delta.len });
            try writer.interface.writeAll(delta);
            try writer.interface.flush();
            return;
        }
        if (self.close_after_request) return;
        if (self.held) {
            _ = r.takeByte() catch return;
            return error.UnexpectedData;
        }
        const w = &writer.interface;
        try w.writeAll(&.{ 0x01, 10 });
        try w.writeAll(completed[0..10]);
        try w.writeAll(&.{ 0x89, 1, 'p' });
        const suffix = completed[10..];
        try w.writeAll(&.{ 0x80, 126 });
        try w.writeInt(u16, suffix.len, .big);
        try w.writeAll(suffix);
        try w.flush();
        try std.testing.expectEqual(0x8a, try r.takeByte());
        try std.testing.expectEqual(0x81, try r.takeByte());
        try r.readSliceAll(&mask);
        try std.testing.expectEqual(@as(u8, 'p'), (try r.takeByte()) ^ mask[0]);
    }
};

fn fixture(io: std.Io) !Loopback {
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    return .{ .server = try address.listen(io, .{}) };
}

fn invoke(a: std.mem.Allocator, io: std.Io, server: *Loopback) !std.json.Value {
    return invokeProgress(a, io, server, null);
}

fn invokeProgress(a: std.mem.Allocator, io: std.Io, server: *Loopback, progress: ?agent.provider.Preview) !std.json.Value {
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.server.socket.address.getPort()});
    var effects = try agent.provider.Effects.initFixture(a, ".", base);
    effects.fixture_transport = .websocket;
    var service: agent.provider.Service = .{ .preview = progress, .routes = &.{.{ .base_url = base, .transport = effects, .retry = .{ .max_attempts = 3, .initial_delay_ms = 0, .max_delay_ms = 0 } }} };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    const denied = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"credential\":\"unregistered\",\"body\":{{}}}}", .{base}));
    try std.testing.expectError(error.UnregisteredProvider, registry.dispatch(.{ .allocator = a, .io = io }, "model.request", denied));
    const packet = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"body\":{{\"model\":\"fixture\",\"instructions\":\"test\",\"input\":[],\"stream\":false}}}}", .{base}));
    return registry.dispatch(.{ .allocator = a, .io = io }, "model.request", packet);
}

test "WebSocket transport upgrades masks requests handles ping and fragmented responses" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try fixture(io);
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    const result = try invoke(arena.allocator(), io, &server);
    task.await(io);
    if (server.failure) |err| return err;
    const interpreted = try responses.interpret(arena.allocator(), result, false);
    try std.testing.expectEqual(.completed, interpreted.status);
    try std.testing.expectEqualStrings("hello", interpreted.text);
    const body = try services.json.parse(arena.allocator(), server.body[0..server.body_len]);
    try std.testing.expectEqualStrings("response.create", body.object.get("type").?.string);
    try std.testing.expect(body.object.get("stream") == null);
    try std.testing.expectEqual(false, body.object.get("store").?.bool);
}

test "WebSocket transport rejects a forged upgrade without sending a model request" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try fixture(io);
    server.bad_accept = true;
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    try std.testing.expectError(error.ProviderTransport, invoke(arena.allocator(), io, &server));
    task.await(io);
    if (server.failure) |err| return err;
    try std.testing.expectEqual(0, server.body_len);
}

test "WebSocket cancellation closes and joins a held exchange" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try fixture(io);
    server.held = true;
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    var call = try io.concurrent(invoke, .{ arena.allocator(), io, &server });
    errdefer _ = call.cancel(io) catch {};
    try server.received.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try std.testing.expectError(error.Canceled, call.cancel(io));
    task.await(io);
    if (server.failure) |err| return err;
}

test "WebSocket deadline closes and joins a held exchange" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try fixture(io);
    server.held = true;
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    const response = try ws.call(a, io, .{
        .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/responses", .{server.server.socket.address.getPort()}),
        .body = try services.json.parse(a, "{\"model\":\"fixture\",\"input\":[]}"),
        .headers = &.{},
        .preview = null,
        .id = "deadline",
        .timeout = .{ .raw = .fromMilliseconds(100), .clock = .awake },
    });
    try std.testing.expect(response.failed);
    const failure = try services.json.parse(a, response.json);
    try std.testing.expectEqualStrings("Timeout", failure.object.get("message").?.string);
    task.await(io);
    if (server.failure) |err| return err;
}

const RecoveryProgress = struct {
    deltas: usize = 0,
    retries: usize = 0,
    fn emit(raw: ?*anyopaque, _: []const u8, update: agent.provider.Preview.Update) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        switch (update) {
            .delta => self.deltas += 1,
            .retrying => self.retries += 1,
            else => {},
        }
    }
};

test "WebSocket model disconnect reconnects and completes without caller resubmission" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try fixture(io);
    server.disconnect_first = true;
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    var progress: RecoveryProgress = .{};
    const result = try invokeProgress(arena.allocator(), io, &server, .{ .context = &progress, .notify = RecoveryProgress.emit });
    try std.testing.expect(progress.deltas != 0);
    try std.testing.expectEqual(@as(usize, 1), progress.retries);
    task.await(io);
    if (server.failure) |err| return err;
    const reply = try responses.interpret(arena.allocator(), result, false);
    try std.testing.expectEqual(.completed, reply.status);
    try std.testing.expectEqualStrings("hello", reply.text);
    try std.testing.expectEqual(2, server.requests.load(.acquire));
}

test "WebSocket model disconnect retries to its configured bound" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = try fixture(io);
    server.close_after_request = true;
    defer server.server.deinit(io);
    var task = try io.concurrent(Loopback.run, .{ &server, io });
    defer task.cancel(io);
    try std.testing.expectError(error.ProviderTransport, invoke(arena.allocator(), io, &server));
    task.await(io);
    if (server.failure) |err| return err;
    try std.testing.expectEqual(3, server.requests.load(.acquire));
}

test "Responses event encoding preserves context and separates public and Codex dialects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try services.json.parse(a, "{\"model\":\"fixture\",\"input\":[{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}],\"instructions\":\"hello\",\"max_output_tokens\":128,\"stream\":false,\"background\":true}");
    const public = try services.json.parse(a, try responses.createEvent(a, original, .responses));
    const codex = try services.json.parse(a, try responses.createEvent(a, original, .codex));
    try std.testing.expect(public.object.get("stream") == null);
    try std.testing.expect(public.object.get("background") == null);
    try std.testing.expectEqual(128, public.object.get("max_output_tokens").?.integer);
    try std.testing.expectEqual(true, codex.object.get("stream").?.bool);
    try std.testing.expect(codex.object.get("max_output_tokens") == null);
    try std.testing.expectEqualStrings("opaque", codex.object.get("input").?.array.items[0].object.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", codex.object.get("include").?.array.items[0].string);
    try std.testing.expectEqual(false, original.object.get("stream").?.bool);
    try std.testing.expectEqual(true, original.object.get("background").?.bool);
}

test "Codex replay projects response-only status without mutating history or tool arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try services.json.parse(a,
        \\{"input":[{"role":"user","content":"hello"},{"type":"reasoning","status":"completed","encrypted_content":"opaque","summary":[]},{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"answer"}]},{"type":"function_call","status":"completed","call_id":"call","name":"bash","arguments":"{\"status\":\"user-defined\"}"}]}
    );
    const encoded = try responses.createEvent(a, original, .codex);
    const wire = try services.json.parse(a, encoded);
    const input = wire.object.get("input").?.array.items;
    for (input) |item| try std.testing.expect(item.object.get("status") == null);
    try std.testing.expectEqualStrings("opaque", input[1].object.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings("{\"status\":\"user-defined\"}", input[3].object.get("arguments").?.string);
    try std.testing.expectEqualStrings("completed", original.object.get("input").?.array.items[1].object.get("status").?.string);
}

test "WebSocket parser rejects masked server frames oversized controls and noncanonical lengths" {
    for ([_][]const u8{ &.{ 0x81, 0x80 }, &.{ 0x09, 1 }, &.{ 0x89, 126, 0, 126 }, &.{ 0x81, 126, 0, 1 }, &.{ 0xc1, 0 } }) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        if (ws.readHeader(&reader)) |_| return error.AcceptedInvalidFrame else |_| {}
    }
}

test "Codex settings require explicit subscription credentials and restrict their destination" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("OPENAI_PROTOCOL", "codex");
    try env.put("OPENAI_MODEL", "fixture");
    try env.put("OPENAI_ACCESS_TOKEN", "dummy-token");
    try env.put("CHATGPT_ACCOUNT_ID", "test-account");
    var settings = try agent.provider.Provider.init(a, &env);
    defer settings.deinit();
    try std.testing.expectEqual(.websocket, settings.transport);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", settings.responses_url);
    try env.put("OPENAI_BASE_URL", "https://example.com");
    try std.testing.expectError(error.InvalidBaseUrl, agent.provider.Provider.init(a, &env));
}
