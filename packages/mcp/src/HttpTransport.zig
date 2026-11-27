//! Streamable HTTP transport.
//!
//! Each request uses a single connection with `keep_alive = false`. A watchdog
//! task shuts the socket down at the configured deadline so a server that stops
//! responding cannot pin a harness thread forever. The watchdog is always
//! joined before the request is deinitialized.

const std = @import("std");
const HttpResponseReader = @import("services").HttpResponseReader;
const Config = @import("Config.zig");
const transport = @import("Transport.zig");

const Allocator = std.mem.Allocator;

pub const HttpTransport = struct {
    a: Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const Config.Entry,
    timeout_ms: u64,
    client: std.http.Client,
    ca_ready: bool = false,
    size_warnings: transport.SizeSink = .{},

    pub fn create(a: Allocator, io: std.Io, server: *const Config.Server) !transport.Transport {
        const url = server.url orelse return error.UnsupportedMcpTransport;
        const self = try a.create(HttpTransport);
        self.* = .{
            .a = a,
            .io = io,
            .url = url,
            .headers = server.headers,
            .timeout_ms = server.timeout_ms,
            .client = .{ .allocator = a, .io = io },
        };
        return .{
            .context = self,
            .vtable = &vtable,
            .mode = .exchange,
        };
    }

    const vtable: transport.Transport.VTable = .{
        .send = sendRaw,
        .receive = receiveUnsupported,
        .close = closeRaw,
        .observe_sizes = observeSizes,
    };

    fn observeSizes(context: *anyopaque, sink: transport.SizeSink) void {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        self.size_warnings = sink;
    }

    fn closeRaw(context: *anyopaque, a: Allocator, io: std.Io) void {
        _ = io;
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        self.client.deinit();
        a.destroy(self);
    }

    fn receiveUnsupported(_: *anyopaque, _: Allocator, _: std.Io, _: u64) anyerror![]u8 {
        return error.UnsupportedMcpTransport;
    }

    fn sendRaw(context: *anyopaque, a: Allocator, io: std.Io, body: []const u8, session_id: ?[]const u8, protocol_version: []const u8, timeout_ms: u64) anyerror!transport.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        return self.send(a, io, body, session_id, protocol_version, if (timeout_ms == 0) self.timeout_ms else timeout_ms);
    }

    fn send(self: *HttpTransport, a: Allocator, io: std.Io, body: []const u8, session_id: ?[]const u8, protocol_version: []const u8, timeout_ms: u64) !transport.Response {
        const uri = std.Uri.parse(self.url) catch return error.InvalidMcpUrl;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedMcpUrl;
        if (protocol == .tls and !self.ca_ready) {
            const now = std.Io.Clock.real.now(io);
            self.client.ca_bundle.rescan(self.a, io, now) catch return error.McpTls;
            self.client.now = now;
            self.ca_ready = true;
        }
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidMcpUrl;
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        try headers.append(a, .{ .name = "User-Agent", .value = "cpi-mcp/0.1.0" });
        if (protocol_version.len > 0) try headers.append(a, .{ .name = "MCP-Protocol-Version", .value = protocol_version });
        if (session_id) |id| try headers.append(a, .{ .name = "Mcp-Session-Id", .value = id });
        for (self.headers) |header| try headers.append(a, .{ .name = header.name, .value = header.value });

        const connection = self.client.connectTcpOptions(.{
            .host = host,
            .port = uri.port orelse if (protocol == .tls) 443 else 80,
            .protocol = protocol,
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake } },
        }) catch |err| switch (err) {
            error.Timeout => return error.McpTimeout,
            else => return error.McpTransport,
        };

        var response_input: HttpResponseReader = .{ .allocator = a };
        defer response_input.deinit();
        var request = self.client.request(.POST, uri, .{
            .connection = connection,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
            .extra_headers = headers.items,
        }) catch {
            connection.closing = true;
            self.client.connection_pool.release(connection, self.client.io);
            return error.McpTransport;
        };
        defer request.deinit();

        var stop: std.Io.Event = .unset;
        var expired = std.atomic.Value(bool).init(false);
        const Watchdog = struct {
            fn run(watchdog_io: std.Io, event: *std.Io.Event, link: *std.http.Client.Connection, expired_flag: *std.atomic.Value(bool), duration: std.Io.Clock.Duration) void {
                event.waitTimeout(watchdog_io, .{ .duration = duration }) catch |err| switch (err) {
                    error.Timeout => {
                        expired_flag.store(true, .release);
                        link.stream_reader.stream.shutdown(watchdog_io, .both) catch {};
                    },
                    else => {},
                };
            }
        };
        const duration: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake };
        var watchdog = io.concurrent(Watchdog.run, .{ io, &stop, connection, &expired, duration }) catch return error.McpTransport;
        defer {
            stop.set(io);
            watchdog.await(io);
        }

        request.sendBodyComplete(@constCast(body)) catch return if (expired.load(.acquire)) error.McpTimeout else error.McpTransport;
        var response = response_input.receiveHead(&request) catch |err| {
            if (err == error.OutOfMemory) return err;
            return if (expired.load(.acquire)) error.McpTimeout else error.McpTransport;
        };
        self.size_warnings.report("HTTP response head bytes", response.head.bytes.len, HttpResponseReader.expected_bytes);
        if (response.head.status.class() == .redirect) return error.McpRedirect;
        if (response.head.status == .not_found) return error.McpSessionExpired;
        if (response.head.status == .unauthorized or response.head.status == .forbidden) return error.McpUnauthorized;
        if (response.head.status.class() != .success) return error.McpHttpStatus;

        var session: ?[]u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            session = try a.dupe(u8, header.value);
        }
        const sse = blk: {
            const content_type = response.head.content_type orelse break :blk false;
            const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
            const essence = std.mem.trim(u8, content_type[0..end], " \t");
            break :blk std.ascii.eqlIgnoreCase(essence, "text/event-stream");
        };

        var transfer: [8192]u8 = undefined;
        const reader = response.reader(&transfer);
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            try io.checkCancel();
            const bytes = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    if (response_input.failure) |failure| return failure;
                    return if (expired.load(.acquire)) error.McpTimeout else error.McpTransport;
                },
            };
            try out.appendSlice(a, bytes);
            reader.toss(bytes.len);
        }
        self.size_warnings.report("HTTP response trailer bytes", request.reader.trailers.len, HttpResponseReader.expected_bytes);
        if (expired.load(.acquire)) return error.McpTimeout;
        return .{ .body = try out.toOwnedSlice(a), .session_id = session, .sse = sse };
    }
};

pub fn create(a: Allocator, io: std.Io, server: *const Config.Server) !transport.Transport {
    return HttpTransport.create(a, io, server);
}

test "preconnect header allocation failures leave no pooled connection" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
    defer a.free(url);
    const extra: [20]Config.Entry = @splat(.{ .name = "X-Test", .value = "value" });

    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        var self: HttpTransport = .{
            .a = a,
            .io = io,
            .url = url,
            .headers = &extra,
            .timeout_ms = 1000,
            .client = .{ .allocator = a, .io = io },
        };
        defer self.client.deinit();
        try std.testing.expectError(error.OutOfMemory, self.send(failing.allocator(), io, "{}", "session", "version", 1000));
        try std.testing.expect(self.client.connection_pool.used.first == null);
    }
}
