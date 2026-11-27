//! Per-server connections with independently owned cached catalogs.

const std = @import("std");
const Config = @import("Config.zig");
const Client = @import("Client.zig").Client;
const Tool = @import("Client.zig").Tool;
const Json = @import("Json.zig");
const transport = @import("Transport.zig");

const Allocator = std.mem.Allocator;
const Value = Json.Value;
const max_tools = 4096;

pub const Binding = struct {
    server: []const u8,
    tool: []const u8,
    name: []const u8,
    description: []const u8,
    parameters: Value,
};

pub const Options = struct {
    /// Borrowed until deinit has joined discovery and closed every transport.
    environment: *const std.process.Environ.Map,
    output_directory: []const u8,
    transport_factory: ?transport.Factory = null,
    size_warnings: transport.SizeSink = .{},
};

const Phase = enum { cold, loading, ready, failed };
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    tools: []const Tool = &.{},
    connected: bool = false,
    session: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    instructions: []const u8 = "",
    failure: []const u8 = "",
};
const Entry = struct {
    client: *Client,
    connection: std.Io.Mutex = .init,
    phase: Phase = .cold,
    catalog_revision: ?u64 = null,
    dirty: bool = false,
    failure: ?anyerror = null,
    ready: std.Io.Event = .unset,
    snapshot: Snapshot,
};

pub const Gateway = struct {
    a: Allocator,
    io: std.Io,
    config: Config.Config,
    entries: []Entry,
    mutex: std.Io.Mutex = .init,
    jobs: std.Io.Group = .init,
    closing: bool = false,
    generation: u64 = 0,
    size_warnings: transport.SizeSink,

    /// Takes ownership of config on both success and failure.
    pub fn init(a: Allocator, io: std.Io, config: Config.Config, options: Options) !*Gateway {
        var owned = config;
        errdefer owned.deinit();
        const self = try a.create(Gateway);
        errdefer a.destroy(self);
        const entries = try a.alloc(Entry, owned.servers.len);
        errdefer a.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |*entry| {
            entry.client.deinit();
            entry.snapshot.arena.deinit();
        };
        const factory = options.transport_factory orelse transport.default_factory;
        for (owned.servers, entries) |*server, *entry| {
            entry.* = .{
                .client = try Client.init(a, io, server, factory, options.environment, options.output_directory),
                .snapshot = .{ .arena = .init(a) },
            };
            entry.client.size_warnings = options.size_warnings;
            initialized += 1;
        }
        self.* = .{ .a = a, .io = io, .config = owned, .entries = entries, .size_warnings = options.size_warnings };
        return self;
    }

    pub fn deinit(self: *Gateway) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.mutex.unlock(self.io);
        self.jobs.cancel(self.io);
        for (self.entries) |*entry| {
            entry.client.deinit();
            entry.snapshot.arena.deinit();
        }
        self.a.free(self.entries);
        self.config.deinit();
        self.a.destroy(self);
    }

    pub fn configServers(self: *const Gateway) []const Config.Server {
        return self.config.servers;
    }

    pub fn startPreloads(self: *Gateway) void {
        for (self.config.servers) |server| {
            if (server.enabled and server.expose and server.preload) _ = self.refresh(server.name) catch {};
        }
    }

    /// Starts at most one job for this source. No network I/O runs on the caller.
    pub fn refresh(self: *Gateway, server_name: []const u8) !bool {
        const entry = try self.find(server_name);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.startRefresh(entry);
    }

    fn startRefresh(self: *Gateway, entry: *Entry) !bool {
        if (self.closing) return error.McpGatewayClosed;
        if (entry.phase == .loading) return false;
        entry.phase = .loading;
        entry.ready.reset();
        self.jobs.concurrent(self.io, refreshJob, .{ self, entry }) catch |err| {
            entry.phase = .failed;
            entry.failure = err;
            entry.ready.set(self.io);
            return err;
        };
        return true;
    }

    fn refreshJob(self: *Gateway, entry: *Entry) std.Io.Cancelable!void {
        entry.connection.lock(self.io) catch |err| {
            self.finishRefresh(entry, err);
            return err;
        };
        defer entry.connection.unlock(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        const was_connected = entry.client.connected;
        const outcome = if (was_connected)
            entry.client.refreshTools(arena.allocator(), self.io)
        else
            entry.client.connect(arena.allocator(), self.io);
        if (outcome) |_| {
            self.capture(entry, null) catch |err| {
                self.finishRefresh(entry, err);
                return;
            };
            self.finishRefresh(entry, null);
        } else |err| {
            entry.client.setError(err);
            self.capture(entry, err) catch {};
            self.finishRefresh(entry, err);
            if (err == error.Canceled) return error.Canceled;
        }
    }

    fn finishRefresh(self: *Gateway, entry: *Entry, failure: ?anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        entry.failure = failure;
        entry.phase = if (failure == null) .ready else .failed;
        entry.dirty = false;
        self.generation +%= 1;
        entry.ready.set(self.io);
    }

    fn ensure(self: *Gateway, io: std.Io, entry: *Entry) !void {
        return self.ensureCatalog(io, entry, false);
    }

    fn ensureCatalog(self: *Gateway, io: std.Io, entry: *Entry, refresh_catalog: bool) !void {
        self.mutex.lockUncancelable(io);
        if (!refresh_catalog and entry.phase == .ready and !entry.dirty) {
            self.mutex.unlock(io);
            return;
        }
        _ = self.startRefresh(entry) catch |err| {
            self.mutex.unlock(io);
            return err;
        };
        self.mutex.unlock(io);
        try entry.ready.wait(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return error.McpGatewayClosed;
        if (entry.phase != .ready) return entry.failure orelse error.McpDiscoveryFailed;
    }

    fn capture(self: *Gateway, entry: *Entry, failure: ?anyerror) !void {
        const client = entry.client;
        const failure_text = if (failure) |err| @errorName(err) else client.errorText();
        self.mutex.lockUncancelable(self.io);
        const same = entry.catalog_revision != null and entry.catalog_revision.? == client.catalog_revision and
            entry.snapshot.connected == client.connected and
            std.mem.eql(u8, entry.snapshot.session, client.session_id orelse "") and
            std.mem.eql(u8, entry.snapshot.failure, failure_text);
        if (same) {
            entry.dirty = client.tools_dirty;
            self.mutex.unlock(self.io);
            return;
        }
        self.mutex.unlock(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        errdefer arena.deinit();
        const a = arena.allocator();
        var identifiers: std.StringHashMapUnmanaged(void) = .empty;
        for (client.tools) |tool| {
            const id = try self.identifier(a, client.server.name, tool.name);
            if ((try identifiers.getOrPut(a, id)).found_existing) return error.McpIdentifierCollision;
        }
        const copied_tools = try a.alloc(Tool, client.tools.len);
        for (client.tools, copied_tools) |tool, *copy| copy.* = .{
            .name = try a.dupe(u8, tool.name),
            .description = try a.dupe(u8, tool.description),
            .title = try a.dupe(u8, tool.title),
            .input_schema = try Json.copy(a, tool.input_schema),
            .annotations = try Json.copy(a, tool.annotations),
        };
        var snapshot: Snapshot = .{
            .arena = undefined,
            .tools = copied_tools,
            .connected = client.connected,
            .session = try a.dupe(u8, client.session_id orelse ""),
            .name = try a.dupe(u8, client.server_name),
            .version = try a.dupe(u8, client.server_version),
            .instructions = try a.dupe(u8, client.instructions),
            .failure = try a.dupe(u8, failure_text),
        };
        snapshot.arena = arena;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        entry.snapshot.arena.deinit();
        entry.snapshot = snapshot;
        entry.catalog_revision = client.catalog_revision;
        entry.dirty = client.tools_dirty;
        if (entry.phase != .loading) entry.phase = if (client.connected) .ready else .failed;
    }

    /// Schedules notification-driven refresh without waiting for a server.
    pub fn syncCatalogs(self: *Gateway) bool {
        var changed = false;
        for (self.entries) |*entry| {
            self.mutex.lockUncancelable(self.io);
            const dirty = entry.dirty and entry.phase != .loading;
            self.mutex.unlock(self.io);
            if (dirty) changed = (self.refresh(entry.client.server.name) catch false) or changed;
        }
        return changed;
    }

    pub fn status(self: *Gateway, a: Allocator) !Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out = Json.array(a);
        for (self.entries) |*entry| {
            const server = entry.client.server;
            const snapshot = &entry.snapshot;
            try out.array.append(try Json.value(a, .{
                .name = server.name,
                .description = server.description,
                .transport = if (server.url != null) "http" else "stdio",
                .enabled = server.enabled,
                .expose = server.expose,
                .preload = server.preload,
                .state = @tagName(entry.phase),
                .connected = snapshot.connected,
                .session = snapshot.session,
                .server_name = snapshot.name,
                .server_version = snapshot.version,
                .tools = snapshot.tools.len,
                .@"error" = snapshot.failure,
            }));
        }
        return Json.value(a, .{ .servers = out, .generation = self.generation });
    }

    /// An empty server selects only cached catalogs. A named source is awaited.
    pub fn tools(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8) !Value {
        return self.toolCatalog(a, io, server_name, false);
    }

    pub fn toolCatalog(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8, refresh_catalog: bool) !Value {
        const selected = if (server_name.len > 0) try self.find(server_name) else null;
        if (selected) |entry| try self.ensureCatalog(io, entry, refresh_catalog);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out = Json.array(a);
        for (self.entries) |*entry| {
            const server = entry.client.server;
            if (!server.enabled or !server.expose) continue;
            if (server_name.len > 0 and !Config.sameName(server_name, server.name)) continue;
            for (entry.snapshot.tools) |tool| try out.array.append(try self.toolValue(a, server, tool));
        }
        return Json.value(a, .{
            .server = if (selected) |entry| entry.client.server.name else null,
            .description = if (selected) |entry| entry.client.server.description else "",
            .instructions = if (selected) |entry| entry.snapshot.instructions else "",
            .tools = out,
            .generation = self.generation,
        });
    }

    fn toolValue(self: *const Gateway, a: Allocator, server: *const Config.Server, tool: Tool) !Value {
        return Json.value(a, .{
            .server = server.name,
            .name = tool.name,
            .identifier = try self.identifier(a, server.name, tool.name),
            .description = tool.description,
            .title = tool.title,
            .input_schema = tool.input_schema,
            .annotations = tool.annotations,
        });
    }

    pub fn describeServer(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8) !Value {
        const entry = try self.find(server_name);
        try self.ensure(io, entry);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var tools_list = Json.array(a);
        for (entry.snapshot.tools) |tool| try tools_list.array.append(try self.toolValue(a, entry.client.server, tool));
        return Json.value(a, .{
            .name = entry.client.server.name,
            .description = entry.client.server.description,
            .server_name = entry.snapshot.name,
            .server_version = entry.snapshot.version,
            .instructions = entry.snapshot.instructions,
            .tools = tools_list,
        });
    }

    pub fn describeTool(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8, tool_name: []const u8) !Value {
        const entry = try self.find(server_name);
        try self.ensure(io, entry);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (entry.snapshot.tools) |tool| {
            if (std.mem.eql(u8, tool.name, tool_name)) return self.toolValue(a, entry.client.server, tool);
        }
        return error.UnknownMcpTool;
    }

    pub fn call(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8, tool_name: []const u8, arguments: Value) !Value {
        if (tool_name.len == 0) return error.InvalidMcpCall;
        const entry = try self.find(server_name);
        try entry.connection.lock(io);
        defer entry.connection.unlock(io);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        defer self.capture(entry, null) catch {};
        try entry.client.connect(arena.allocator(), io);
        return entry.client.callTool(a, io, tool_name, arguments);
    }

    pub fn listResources(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8, cursor: []const u8) !Value {
        if (server_name.len == 0) return Json.value(a, .{ .resources = Json.array(a) });
        const entry = try self.find(server_name);
        try entry.connection.lock(io);
        defer entry.connection.unlock(io);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        defer self.capture(entry, null) catch {};
        try entry.client.connect(arena.allocator(), io);
        return entry.client.listResources(a, io, cursor);
    }

    pub fn readResource(self: *Gateway, a: Allocator, io: std.Io, server_name: []const u8, uri: []const u8) !Value {
        if (uri.len == 0) return error.InvalidMcpResource;
        const entry = try self.find(server_name);
        try entry.connection.lock(io);
        defer entry.connection.unlock(io);
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        defer self.capture(entry, null) catch {};
        try entry.client.connect(arena.allocator(), io);
        return entry.client.readResource(a, io, uri);
    }

    pub fn bindings(self: *Gateway, a: Allocator) ![]const Binding {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.ArrayList(Binding) = .empty;
        for (self.entries) |*entry| {
            const server = entry.client.server;
            if (!server.enabled or !server.expose) continue;
            for (entry.snapshot.tools) |tool| {
                try out.append(a, .{
                    .server = try a.dupe(u8, server.name),
                    .tool = try a.dupe(u8, tool.name),
                    .name = try self.identifier(a, server.name, tool.name),
                    .description = try a.dupe(u8, tool.description),
                    .parameters = try Json.copy(a, tool.input_schema),
                });
            }
        }
        self.size_warnings.report("exposed tools", out.items.len, max_tools);
        return out.toOwnedSlice(a);
    }

    pub fn promptSection(self: *Gateway, a: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var writer: std.Io.Writer.Allocating = .init(a);
        errdefer writer.deinit();
        var remaining: usize = 0;
        for (self.entries) |*entry| {
            if (entry.client.server.enabled and entry.client.server.expose) remaining += 1;
        }
        if (remaining == 0) return writer.toOwnedSlice();
        try writer.writer.writeAll("MCP servers whose tools are not declared to you. Call the tools of `execute_lua` servers from Luau scripts.");
        for (self.entries) |*entry| {
            const server = entry.client.server;
            if (!server.enabled or !server.expose) continue;
            const budget: usize = 4096;
            const heading_bytes = "\n- mcp__ (execute_lua)".len + server.name.len;
            const available = budget - writer.written().len;
            const reserve: usize = if (remaining > 1) 96 else 0; // Carries the omission line.
            if (heading_bytes + reserve > available) {
                try writer.writer.print("\n- … {d} more server{s}; find their tools with searchTools()", .{ remaining, if (remaining == 1) "" else "s" });
                break;
            }
            const configured = std.mem.trim(u8, server.description, " \t\r\n");
            const text = if (configured.len > 0) configured else entry.snapshot.instructions;
            const summary = std.mem.trim(u8, text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len], " \t");
            try writer.writer.print("\n- mcp__{s} (execute_lua)", .{server.name});
            const limit = @min(250, available - heading_bytes - reserve -| 2);
            if (summary.len > 0 and limit > 3) {
                if (summary.len <= limit) {
                    try writer.writer.print(": {s}", .{summary});
                } else {
                    var end = limit - "…".len;
                    while (summary[end] & 0xc0 == 0x80) end -= 1;
                    try writer.writer.print(": {s}…", .{std.mem.trimEnd(u8, summary[0..end], " \t")});
                }
            }
            remaining -= 1;
        }
        return writer.toOwnedSlice();
    }

    fn find(self: *Gateway, name: []const u8) !*Entry {
        for (self.entries) |*entry| {
            if (!Config.sameName(name, entry.client.server.name)) continue;
            if (!entry.client.server.enabled) return error.McpServerDisabled;
            if (!entry.client.server.expose) return error.McpServerHidden;
            return entry;
        }
        return error.UnknownMcpServer;
    }

    fn identifier(self: *const Gateway, a: Allocator, server: []const u8, tool: []const u8) ![]u8 {
        var ambiguous = false;
        for (self.config.servers) |other| {
            if (std.mem.eql(u8, other.name, server)) continue;
            const length = @min(other.name.len, server.len);
            if (Config.sameName(other.name[0..length], server[0..length])) ambiguous = true;
        }
        return identifierFor(a, server, tool, ambiguous);
    }
};

fn identifierFor(a: Allocator, server: []const u8, tool: []const u8, ambiguous: bool) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(a);
    errdefer writer.deinit();
    try writer.writer.writeAll("mcp_");
    var hash = ambiguous;
    for (server) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '_';
        hash = hash or !safe;
        try writer.writer.writeByte(if (safe) byte else '_');
    }
    try writer.writer.writeByte('_');
    for (tool) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '_';
        hash = hash or !safe;
        try writer.writer.writeByte(if (safe) byte else '_');
    }
    if (writer.written().len > 64 or hash) {
        writer.shrinkRetainingCapacity(@min(writer.written().len, 47));
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(server);
        hasher.update(&.{0});
        hasher.update(tool);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        try writer.writer.print("_{s}", .{hex[0..16]});
    }
    return writer.toOwnedSlice();
}

test "identifiers do not depend on discovery order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("mcp_fixture_echo", try identifierFor(a, "fixture", "echo", false));
    const first = try identifierFor(a, "a-b", "tool", false);
    const second = try identifierFor(a, "a_b", "tool", false);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const long = try identifierFor(a, "s", &@as([100]u8, @splat('a')), false);
    try std.testing.expect(long.len <= 64);
}
