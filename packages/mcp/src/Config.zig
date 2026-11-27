//! MCP server registration. This layer is intentionally independent of any
//! harness: it parses an already-decoded JSON value (from Lua, JSON, YAML, or a
//! remote configuration source) into owned server descriptions.
//!
//! Accepted shapes:
//!
//!     { servers = { name = { url = "..." }, ... } }
//!     { mcpServers = { ... } }
//!     { name = { url = "..." }, ... }
//!
//! An array of server tables carrying `name` is also accepted.

const std = @import("std");
const Json = @import("Json.zig");
const SizeSink = @import("Transport.zig").SizeSink;

pub const Allocator = std.mem.Allocator;
pub const Value = Json.Value;
pub const max_servers = 128;
pub const max_tools_per_server = 4096;

pub const Entry = struct { name: []const u8, value: []const u8 };

pub const Server = struct {
    name: []const u8,
    description: []const u8 = "",
    url: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const Entry = &.{},
    headers: []const Entry = &.{},
    cwd: ?[]const u8 = null,
    timeout_ms: u64 = 60_000,
    enabled: bool = true,
    /// Whether the harness should expose this server's tools to the model.
    expose: bool = true,
    /// Start background discovery when the harness opens. Cold sources connect
    /// only on demand; neither mode blocks session startup.
    preload: bool = false,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    servers: []const Server = &.{},
    source_path: ?[]const u8 = null,

    pub fn empty(gpa: Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn parse(gpa: Allocator, input: Value, environment: *const std.process.Environ.Map) !Config {
        return parseObserved(gpa, input, environment, .{});
    }

    pub fn parseObserved(gpa: Allocator, input: Value, environment: *const std.process.Environ.Map, warnings: SizeSink) !Config {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const servers = try parseServers(a, input, environment, warnings);
        return .{ .arena = arena, .servers = servers };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Config, name: []const u8) ?*const Server {
        for (self.servers) |*server| if (sameName(server.name, name)) return server;
        return null;
    }
};

fn parseServers(a: Allocator, value: Value, environment: *const std.process.Environ.Map, warnings: SizeSink) ![]const Server {
    if (value != .object) return error.InvalidMcpConfig;
    var source = Json.get(value, "servers");
    if (source == .null) source = Json.get(value, "mcpServers");
    if (source == .null) source = value;
    if (source != .object and source != .array) return error.InvalidMcpConfig;

    var out: std.ArrayList(Server) = .empty;
    if (source == .object) {
        warnings.report("configured servers", source.object.count(), max_servers);
        var it = source.object.iterator();
        while (it.next()) |entry| {
            if (!validName(entry.key_ptr.*)) return error.InvalidMcpServerName;
            try out.append(a, try parseServer(a, entry.key_ptr.*, entry.value_ptr.*, environment, warnings));
        }
    } else {
        warnings.report("configured servers", source.array.items.len, max_servers);
        for (source.array.items) |item| {
            if (item != .object) return error.InvalidMcpConfig;
            const name = Json.text(Json.get(item, "name"));
            if (!validName(name)) return error.InvalidMcpServerName;
            try out.append(a, try parseServer(a, name, item, environment, warnings));
        }
    }
    std.mem.sort(Server, out.items, {}, struct {
        fn less(_: void, lhs: Server, rhs: Server) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.less);
    for (out.items, 0..) |server, index| {
        for (out.items[0..index]) |prior| {
            if (sameName(prior.name, server.name)) return error.DuplicateMcpServer;
        }
    }
    return out.toOwnedSlice(a);
}

fn parseServer(a: Allocator, name: []const u8, value: Value, environment: *const std.process.Environ.Map, warnings: SizeSink) !Server {
    if (value != .object) return error.InvalidMcpServer;
    warnings.report("server name bytes", name.len, 64);
    const url = try optionalText(a, value, "url", "server URL bytes", environment, warnings);
    const command = try optionalText(a, value, "command", "server command bytes", environment, warnings);
    if (url != null and command != null) return error.InvalidMcpServer;
    if (url == null and command == null) return error.InvalidMcpServer;
    if (url) |text| {
        const uri = std.Uri.parse(text) catch return error.InvalidMcpUrl;
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.UnsupportedMcpUrl;
        if (uri.host == null) return error.InvalidMcpUrl;
    }

    var timeout_ms: u64 = 60_000;
    const timeout = Json.get(value, "timeout");
    if (timeout != .null) {
        const seconds = Json.number(timeout);
        if (seconds == 0 or seconds > 3600) return error.InvalidMcpTimeout;
        timeout_ms = seconds * 1000;
    }
    const timeout_ms_value = Json.get(value, "timeout_ms");
    if (timeout_ms_value != .null) {
        timeout_ms = Json.number(timeout_ms_value);
        if (timeout_ms < 100 or timeout_ms > 3_600_000) return error.InvalidMcpTimeout;
    }

    var expose = true;
    const expose_value = Json.get(value, "expose");
    if (expose_value != .null) {
        if (expose_value != .bool) return error.InvalidMcpExpose;
        expose = expose_value.bool;
    }
    const exposure = Json.get(value, "exposure");
    if (exposure != .null) {
        if (exposure != .string) return error.InvalidMcpExpose;
        // Pi-compatible spelling. `hidden` is the only value that suppresses
        // discovery; every script/codemode spelling means exposed.
        if (std.mem.eql(u8, exposure.string, "hidden")) expose = false else if (!std.mem.eql(u8, exposure.string, "script") and
            !std.mem.eql(u8, exposure.string, "codemode") and
            !std.mem.eql(u8, exposure.string, "codemode-deferred") and
            !std.mem.eql(u8, exposure.string, "execute_lua"))
            return error.InvalidMcpExpose;
    }

    return .{
        .name = try a.dupe(u8, name),
        .description = (try optionalText(a, value, "description", "server description bytes", environment, warnings)) orelse "",
        .url = url,
        .command = command,
        .args = try strings(a, Json.get(value, "args"), environment, warnings),
        .env = try entries(a, Json.get(value, "env"), environment, false, warnings),
        .headers = try entries(a, Json.get(value, "headers"), environment, true, warnings),
        .cwd = try optionalText(a, value, "cwd", "server working-directory bytes", environment, warnings),
        .timeout_ms = timeout_ms,
        .enabled = try optionalBool(value, "enabled", true),
        .expose = expose,
        .preload = try optionalBool(value, "preload", false),
    };
}

fn optionalBool(value: Value, key: []const u8, default: bool) !bool {
    const item = Json.get(value, key);
    if (item == .null) return default;
    if (item != .bool) return error.InvalidMcpConfig;
    return item.bool;
}

fn optionalText(a: Allocator, value: Value, key: []const u8, measurement: []const u8, environment: *const std.process.Environ.Map, warnings: SizeSink) !?[]const u8 {
    const item = Json.get(value, key);
    if (item == .null) return null;
    if (item != .string or item.string.len == 0 or std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidMcpConfig;
    const expanded = try expand(a, item.string, environment, warnings);
    warnings.report(measurement, expanded.len, 4096);
    return expanded;
}

fn strings(a: Allocator, value: Value, environment: *const std.process.Environ.Map, warnings: SizeSink) ![]const []const u8 {
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidMcpConfig;
    warnings.report("server argument count", value.array.items.len, 256);
    const out = try a.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *text| {
        if (item != .string or std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidMcpConfig;
        text.* = try expand(a, item.string, environment, warnings);
        warnings.report("server argument bytes", text.len, 8192);
    }
    return out;
}

fn entries(a: Allocator, value: Value, environment: *const std.process.Environ.Map, headers: bool, warnings: SizeSink) ![]const Entry {
    if (value == .null) return &.{};
    if (value != .object) return error.InvalidMcpConfig;
    warnings.report(if (headers) "server header count" else "server environment entries", value.object.count(), 256);
    var out: std.ArrayList(Entry) = .empty;
    var it = value.object.iterator();
    while (it.next()) |field| {
        const name = field.key_ptr.*;
        if (name.len == 0 or field.value_ptr.* != .string or
            std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, name, '=') != null or
            std.mem.indexOfScalar(u8, field.value_ptr.string, 0) != null or
            std.mem.indexOfScalar(u8, field.value_ptr.string, '\r') != null or
            std.mem.indexOfScalar(u8, field.value_ptr.string, '\n') != null)
            return error.InvalidMcpConfig;
        if (headers and !validHeaderName(name)) return error.InvalidMcpConfig;
        warnings.report(if (headers) "server header name bytes" else "server environment name bytes", name.len, 256);
        try out.append(a, .{
            .name = try a.dupe(u8, name),
            .value = try expand(a, field.value_ptr.string, environment, warnings),
        });
    }
    return out.toOwnedSlice(a);
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", byte) != null) return false;
    }
    return true;
}

fn expand(a: Allocator, text: []const u8, environment: *const std.process.Environ.Map, warnings: SizeSink) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '$' and index + 1 < text.len and text[index + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, text, index + 2, '}') orelse return error.InvalidMcpConfig;
            const name = text[index + 2 .. close];
            if (name.len == 0) return error.InvalidMcpConfig;
            warnings.report("server environment reference bytes", name.len, 128);
            try out.appendSlice(a, environment.get(name) orelse "");
            index = close + 1;
            continue;
        }
        try out.append(a, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

pub fn sameName(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left_byte, right_byte| {
        const left = if (left_byte == '-') '_' else left_byte;
        const right = if (right_byte == '-') '_' else right_byte;
        if (left != right) return false;
    }
    return true;
}

test "servers parse from all supported shapes and sort deterministically" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TOKEN", "secret");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try Json.parse(a,
        \\{"servers":{"z":{"command":"server","args":["--flag","${TOKEN}"],"env":{"A":"${TOKEN}"}},
        \\"a":{"url":"https://example.test/mcp","description":"A server","headers":{"Authorization":"Bearer ${TOKEN}"}}}}
    );
    var config = try Config.parse(std.testing.allocator, input, &env);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.servers.len);
    try std.testing.expectEqualStrings("a", config.servers[0].name);
    try std.testing.expectEqualStrings("Bearer secret", config.servers[0].headers[0].value);
    try std.testing.expectEqualStrings("secret", config.servers[1].args[1]);
    try std.testing.expectEqualStrings("secret", config.servers[1].env[0].value);
}

test "hidden exposure and preload are explicit" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try Json.parse(a, "{\"x\":{\"url\":\"http://localhost/mcp\",\"exposure\":\"hidden\",\"preload\":true}}");
    var config = try Config.parse(std.testing.allocator, input, &env);
    defer config.deinit();
    try std.testing.expect(!config.servers[0].expose);
    try std.testing.expect(config.servers[0].preload);
}

test "invalid transports and duplicate normalized names fail" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"x\":{}}",
        "{\"x\":{\"url\":\"http://localhost\",\"command\":\"x\"}}",
    }) |bytes| {
        const input = try Json.parse(a, bytes);
        try std.testing.expectError(error.InvalidMcpServer, Config.parse(std.testing.allocator, input, &env));
    }
    const injected = try Json.parse(a, "{\"x\":{\"url\":\"http://localhost\",\"headers\":{\"X\":\"a\\r\\nInjected: 1\"}}}");
    try std.testing.expectError(error.InvalidMcpConfig, Config.parse(std.testing.allocator, injected, &env));
    const duplicate = try Json.parse(a, "{\"x-y\":{\"url\":\"http://localhost\"},\"x_y\":{\"url\":\"http://localhost\"}}");
    try std.testing.expectError(error.DuplicateMcpServer, Config.parse(std.testing.allocator, duplicate, &env));
}
