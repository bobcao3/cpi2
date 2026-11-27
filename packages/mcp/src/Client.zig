//! One MCP server connection. A Client owns its transport and catalog; the
//! Gateway serializes access to each Client. A failed connection is always closed
//! and can be retried by the next operation. Calls are never automatically
//! replayed, because `tools/call` may have side effects.

const std = @import("std");
const Config = @import("Config.zig");
const Json = @import("Json.zig");
const Sse = @import("Sse.zig");
const transport = @import("Transport.zig");

const Allocator = std.mem.Allocator;
const Value = Json.Value;
const Cursor = @import("json_tree").text.Cursor;
const protocol_version = "2025-06-18";
const max_tools = Config.max_tools_per_server;
const max_messages = 1024;
const max_tool_pages = 128;

pub const Tool = struct {
    name: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    input_schema: Value = .null,
    annotations: Value = .null,
};

pub const Changes = struct {
    tools: bool = false,
    resources: bool = false,
};

pub const Client = struct {
    a: Allocator,
    io: std.Io,
    server: *const Config.Server,
    factory: transport.Factory,
    environment: *const std.process.Environ.Map,
    output_directory: []const u8,
    transport: ?transport.Transport = null,
    connected: bool = false,
    session_id: ?[]u8 = null,
    negotiated_version: []u8 = &.{},
    next_id: u64 = 1,
    catalog: std.heap.ArenaAllocator,
    tools: []const Tool = &.{},
    instructions: []u8 = &.{},
    server_name: []u8 = &.{},
    server_version: []u8 = &.{},
    last_error: [512]u8 = @splat(0),
    last_error_len: usize = 0,
    catalog_revision: u64 = 0,
    tools_dirty: bool = false,
    resources_dirty: bool = false,
    size_warnings: transport.SizeSink = .{},

    pub fn init(a: Allocator, io: std.Io, server: *const Config.Server, factory: transport.Factory, environment: *const std.process.Environ.Map, output_directory: []const u8) !*Client {
        const self = try a.create(Client);
        self.* = .{
            .a = a,
            .io = io,
            .server = server,
            .factory = factory,
            .environment = environment,
            .output_directory = output_directory,
            .catalog = std.heap.ArenaAllocator.init(a),
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.disconnect(self.io);
        self.catalog.deinit();
        self.clearMetadata();
        self.a.destroy(self);
    }

    pub fn errorText(self: *const Client) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn changes(self: *Client) Changes {
        const result: Changes = .{ .tools = self.tools_dirty, .resources = self.resources_dirty };
        self.tools_dirty = false;
        self.resources_dirty = false;
        return result;
    }

    pub fn connect(self: *Client, a: Allocator, io: std.Io) !void {
        if (self.connected) return;
        self.disconnect(io);
        const created = self.factory.create(self.factory.context, self.a, io, self.server, self.environment, self.output_directory) catch |err| {
            self.setError(err);
            return err;
        };
        if (created.vtable.observe_sizes) |observe| observe(created.context, self.size_warnings);
        self.transport = created;
        errdefer self.disconnect(io);

        var params = Json.object();
        try Json.put(a, &params, "protocolVersion", Json.string(protocol_version));
        try Json.put(a, &params, "capabilities", Json.object());
        var info = Json.object();
        try Json.put(a, &info, "name", Json.string("cpi-mcp"));
        try Json.put(a, &info, "version", Json.string("0.1.0"));
        try Json.put(a, &params, "clientInfo", info);

        const result = self.request(a, io, "initialize", params, true) catch |err| {
            self.setError(err);
            return err;
        };
        self.setMetadata(result) catch |err| {
            self.setError(err);
            return err;
        };
        self.connected = true;
        self.notify(a, io, "notifications/initialized", Json.object()) catch |err| {
            self.setError(err);
            return err;
        };
        self.refreshTools(a, io) catch |err| {
            self.setError(err);
            return err;
        };
        self.clearError();
    }

    fn setMetadata(self: *Client, result: Value) !void {
        const info = Json.get(result, "serverInfo");
        self.replaceMetadata(&self.server_name, try self.a.dupe(u8, Json.text(Json.get(info, "name"))));
        self.replaceMetadata(&self.server_version, try self.a.dupe(u8, Json.text(Json.get(info, "version"))));
        self.replaceMetadata(&self.instructions, try self.a.dupe(u8, Json.text(Json.get(result, "instructions"))));
        const version = Json.text(Json.get(result, "protocolVersion"));
        if (version.len > 0) self.replaceMetadata(&self.negotiated_version, try self.a.dupe(u8, version));
    }

    fn replaceMetadata(self: *Client, slot: *[]u8, value: []u8) void {
        if (slot.*.len > 0) self.a.free(slot.*);
        slot.* = value;
    }

    fn clearMetadata(self: *Client) void {
        if (self.negotiated_version.len > 0) self.a.free(self.negotiated_version);
        if (self.instructions.len > 0) self.a.free(self.instructions);
        if (self.server_name.len > 0) self.a.free(self.server_name);
        if (self.server_version.len > 0) self.a.free(self.server_version);
        self.negotiated_version = &.{};
        self.instructions = &.{};
        self.server_name = &.{};
        self.server_version = &.{};
    }

    pub fn disconnect(self: *Client, io: std.Io) void {
        if (self.transport) |t| t.close(self.a, io);
        self.transport = null;
        self.connected = false;
        if (self.session_id) |id| self.a.free(id);
        self.session_id = null;
        self.tools = &.{};
        self.catalog_revision +%= 1;
        self.tools_dirty = true;
        _ = self.catalog.reset(.retain_capacity);
    }

    pub fn refreshTools(self: *Client, a: Allocator, io: std.Io) !void {
        var next = std.heap.ArenaAllocator.init(self.a);
        errdefer next.deinit();
        const na = next.allocator();
        var list: std.ArrayListUnmanaged(Tool) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        var cursors: std.StringHashMapUnmanaged(void) = .empty;
        defer cursors.deinit(a);
        var cursor: []const u8 = "";
        var pages: usize = 0;
        while (true) {
            if (pages == max_tool_pages) self.size_warnings.report("catalog pages", pages + 1, max_tool_pages);
            pages += 1;
            var params = Json.object();
            if (cursor.len > 0) try Json.put(a, &params, "cursor", Json.string(cursor));
            const result = try self.request(a, io, "tools/list", params, true);
            for (Json.items(Json.get(result, "tools"))) |tool| {
                const name = Json.text(Json.get(tool, "name"));
                if (name.len == 0) continue;
                const entry = try names.getOrPut(na, name);
                if (entry.found_existing) return error.DuplicateMcpTool;
                try list.append(na, .{
                    .name = try na.dupe(u8, name),
                    .title = try na.dupe(u8, Json.text(Json.get(tool, "title"))),
                    .description = try na.dupe(u8, Json.text(Json.get(tool, "description"))),
                    .input_schema = try Json.copy(na, Json.get(tool, "inputSchema")),
                    .annotations = try Json.copy(na, Json.get(tool, "annotations")),
                });
            }
            const next_cursor = Json.text(Json.get(result, "nextCursor"));
            if (next_cursor.len == 0 or std.mem.eql(u8, next_cursor, cursor)) break;
            cursor = try a.dupe(u8, next_cursor);
            if ((try cursors.getOrPut(a, cursor)).found_existing) return error.McpProtocol;
        }
        self.size_warnings.report("catalog tools", list.items.len, max_tools);
        const tools = try list.toOwnedSlice(na);
        self.catalog.deinit();
        self.catalog = next;
        self.tools = tools;
        self.catalog_revision +%= 1;
        self.tools_dirty = false;
    }

    pub fn callTool(self: *Client, a: Allocator, io: std.Io, name: []const u8, arguments: Value) !Value {
        var params = Json.object();
        try Json.put(a, &params, "name", Json.string(name));
        try Json.put(a, &params, "arguments", if (arguments == .null) Json.object() else arguments);
        return self.request(a, io, "tools/call", params, true) catch |err| {
            self.setError(err);
            return err;
        };
    }

    pub fn listResources(self: *Client, a: Allocator, io: std.Io, cursor: []const u8) !Value {
        var params = Json.object();
        if (cursor.len > 0) try Json.put(a, &params, "cursor", Json.string(cursor));
        return self.request(a, io, "resources/list", params, true);
    }

    pub fn readResource(self: *Client, a: Allocator, io: std.Io, uri: []const u8) !Value {
        var params = Json.object();
        try Json.put(a, &params, "uri", Json.string(uri));
        return self.request(a, io, "resources/read", params, true);
    }

    fn notify(self: *Client, a: Allocator, io: std.Io, method: []const u8, params: Value) !void {
        const t = self.transport orelse return error.McpClosed;
        var object = Json.object();
        try Json.put(a, &object, "jsonrpc", Json.string("2.0"));
        try Json.put(a, &object, "method", Json.string(method));
        try Json.put(a, &object, "params", params);
        const body = try Json.encodeObserved(a, object, self.size_warnings);
        const session = if (self.connected) self.session_id else null;
        const response = t.send(a, io, body, session, self.negotiated_version, self.server.timeout_ms) catch |err| {
            self.setError(err);
            return err;
        };
        if (t.mode == .exchange) _ = self.handleExchange(a, io, response, null) catch |err| {
            self.setError(err);
            return err;
        };
    }

    fn request(self: *Client, a: Allocator, io: std.Io, method: []const u8, params: Value, expect_response: bool) !Value {
        const t = self.transport orelse return error.McpClosed;
        const id = self.next_id;
        self.next_id +%= 1;
        var object = Json.object();
        try Json.put(a, &object, "jsonrpc", Json.string("2.0"));
        try Json.put(a, &object, "id", Json.integer(@intCast(id)));
        try Json.put(a, &object, "method", Json.string(method));
        try Json.put(a, &object, "params", params);
        const body = try Json.encodeObserved(a, object, self.size_warnings);
        const session = if (self.connected) self.session_id else null;
        const response = t.send(a, io, body, session, self.negotiated_version, self.server.timeout_ms) catch |err| {
            self.setError(err);
            self.disconnect(io);
            return err;
        };
        if (response.session_id) |new_session| {
            const replacement = try self.a.dupe(u8, new_session);
            errdefer self.a.free(replacement);
            if (self.session_id) |old| self.a.free(old);
            self.session_id = replacement;
        }
        const result = switch (t.mode) {
            .exchange => self.handleExchange(a, io, response, if (expect_response) id else null),
            .stream => self.handleStream(a, io, t, if (expect_response) id else null),
        } catch |err| {
            self.setError(err);
            if (err != error.McpServerError) self.disconnect(io);
            return err;
        };
        self.clearError();
        return result;
    }

    fn handleExchange(self: *Client, a: Allocator, io: std.Io, response: transport.Response, expected_id: ?u64) !Value {
        var found: ?Value = null;
        self.size_warnings.report("HTTP response bytes", response.body.len, transport.expected_message_bytes);
        if (response.body.len == 0) return if (expected_id == null) .null else error.McpProtocol;
        if (response.sse) {
            const events = try Sse.decodeObserved(a, response.body, self.size_warnings);
            for (events) |event| {
                _ = try self.handleMessage(a, io, event, expected_id, &found);
            }
        } else {
            _ = try self.handleMessage(a, io, response.body, expected_id, &found);
        }
        return if (found) |value| value else if (expected_id == null) .null else error.McpProtocol;
    }

    fn handleStream(self: *Client, a: Allocator, io: std.Io, t: transport.Transport, expected_id: ?u64) !Value {
        if (expected_id == null) return .null;
        var messages: usize = 0;
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + @as(i64, @intCast(self.server.timeout_ms));
        while (true) {
            if (messages == max_messages) self.size_warnings.report("stdio response messages", messages + 1, max_messages);
            messages += 1;
            const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
            if (remaining <= 0) return error.McpTimeout;
            const line = try t.receive(a, io, @intCast(remaining));
            self.size_warnings.report("stdio message bytes", line.len, transport.expected_message_bytes);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            var found: ?Value = null;
            if (try self.handleMessage(a, io, trimmed, expected_id, &found)) return found.?;
        }
    }

    fn handleMessage(self: *Client, a: Allocator, io: std.Io, bytes: []const u8, expected_id: ?u64, found: *?Value) !bool {
        var local: [256]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&local, a);
        var window: Cursor.Window = undefined;
        var cursor = Cursor.init(bytes, &window, scratch.allocator());
        defer cursor.deinit();
        const fields = cursor.select(enum { method, id, @"error", result }) catch |err| {
            self.setMessage(if (err == error.UnexpectedToken) "response is not an object" else "invalid JSON response");
            return error.McpProtocol;
        };
        self.size_warnings.report("JSON nesting depth", cursor.depth(), Json.expected_depth);
        const method = fields.get(.method);
        const id = fields.get(.id);
        if (method != null and method.?.kind != .null) {
            var temporary = std.heap.ArenaAllocator.init(a);
            defer temporary.deinit();
            const name = (try method.?.string(temporary.allocator())) orelse "";
            if (id == null or id.?.kind == .null) {
                self.handleNotification(name);
                return false;
            }
            self.answerServerRequest(a, io, try self.decodeMessageField(temporary.allocator(), id.?), name);
            return false;
        }
        if (id == null or id.?.kind == .null) {
            self.setMessage("response is missing id");
            return error.McpProtocol;
        }
        const expected = expected_id orelse return false;
        if (!try idMatches(a, id.?, expected)) return false;
        if (fields.get(.@"error")) |failure| if (failure.kind != .null) {
            var temporary = std.heap.ArenaAllocator.init(a);
            defer temporary.deinit();
            const error_object = try self.decodeMessageField(temporary.allocator(), failure);
            const message = Json.text(Json.get(error_object, "message"));
            self.setMessage(if (message.len > 0) message else "MCP server error");
            return error.McpServerError;
        };
        found.* = if (fields.get(.result)) |result| try self.decodeMessageField(a, result) else .null;
        return true;
    }

    fn decodeMessageField(self: *Client, a: Allocator, raw: Cursor.Raw) !Value {
        return raw.parse(Value, a, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch {
            self.setMessage("invalid JSON response");
            return error.McpProtocol;
        };
    }

    fn answerServerRequest(self: *Client, a: Allocator, io: std.Io, id: Value, method: []const u8) void {
        var object = Json.object();
        Json.put(a, &object, "jsonrpc", Json.string("2.0")) catch return;
        Json.put(a, &object, "id", Json.copy(a, id) catch return) catch return;
        if (std.mem.eql(u8, method, "ping")) {
            Json.put(a, &object, "result", Json.object()) catch return;
        } else if (std.mem.eql(u8, method, "roots/list")) {
            var result = Json.object();
            Json.put(a, &result, "roots", Json.array(a)) catch return;
            Json.put(a, &object, "result", result) catch return;
        } else {
            var error_object = Json.object();
            Json.put(a, &error_object, "code", Json.integer(-32601)) catch return;
            Json.put(a, &error_object, "message", Json.string("Method not found")) catch return;
            Json.put(a, &object, "error", error_object) catch return;
        }
        const body = Json.encodeObserved(a, object, self.size_warnings) catch return;
        const t = self.transport orelse return;
        const response = t.send(a, io, body, self.session_id, self.negotiated_version, self.server.timeout_ms) catch return;
        if (t.mode == .exchange) {
            if (response.session_id) |new_session| {
                const replacement = self.a.dupe(u8, new_session) catch return;
                errdefer self.a.free(replacement);
                if (self.session_id) |old| self.a.free(old);
                self.session_id = replacement;
            }
        }
    }

    fn handleNotification(self: *Client, name: []const u8) void {
        if (std.mem.eql(u8, name, "notifications/tools/list_changed")) self.tools_dirty = true;
        if (std.mem.eql(u8, name, "notifications/resources/list_changed")) self.resources_dirty = true;
    }

    pub fn setError(self: *Client, err: anyerror) void {
        self.setMessage(@errorName(err));
    }

    pub fn setMessage(self: *Client, message: []const u8) void {
        const length = @min(message.len, self.last_error.len);
        @memcpy(self.last_error[0..length], message[0..length]);
        self.last_error_len = length;
    }

    pub fn clearError(self: *Client) void {
        self.last_error_len = 0;
    }
};

test "session replacement preserves the old ID on allocation failure" {
    const Fixture = struct {
        response_id: u64 = 1,

        fn send(context: *anyopaque, a: Allocator, _: std.Io, _: []const u8, session_id: ?[]const u8, _: []const u8, _: u64) anyerror!transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, session_id orelse return error.MissingSession, "old-session")) return error.WrongSession;
            return .{
                .body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}", .{self.response_id}),
                .session_id = try a.dupe(u8, "new-session"),
            };
        }

        fn receive(_: *anyopaque, _: Allocator, _: std.Io, _: u64) anyerror![]u8 {
            return error.Unsupported;
        }

        fn close(_: *anyopaque, _: Allocator, _: std.Io) void {}

        const vtable: transport.Transport.VTable = .{ .send = send, .receive = receive, .close = close };
    };

    for ([_]bool{ true, false }) |server_request| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const owner = failing.allocator();
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        const server: Config.Server = .{ .name = "fixture" };
        var fixture: Fixture = .{};
        const client = try Client.init(owner, std.testing.io, &server, transport.default_factory, &env, "");
        defer client.deinit();
        client.transport = .{ .context = &fixture, .vtable = &Fixture.vtable, .mode = .exchange };
        client.connected = true;
        client.session_id = try owner.dupe(u8, "old-session");
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        failing.fail_index = failing.alloc_index;
        if (server_request) {
            client.answerServerRequest(a, std.testing.io, Json.integer(99), "ping");
        } else {
            try std.testing.expectError(error.OutOfMemory, client.request(a, std.testing.io, "test", Json.object(), true));
            fixture.response_id = 2;
        }
        failing.fail_index = std.math.maxInt(usize);
        _ = try client.request(a, std.testing.io, "test", Json.object(), true);
        try std.testing.expectEqualStrings("new-session", client.session_id.?);
    }
}

fn idMatches(a: Allocator, raw: Cursor.Raw, id: u64) !bool {
    if (raw.integer()) |number| return number >= 0 and @as(u64, @intCast(number)) == id;
    if (raw.kind != .string) return false;
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const value = (try raw.string(temporary.allocator())).?;
    const parsed = std.fmt.parseInt(u64, value, 10) catch return false;
    return parsed == id;
}
