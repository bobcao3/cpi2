const std = @import("std");
const json_text = @import("json_tree").text;
const HttpResponseReader = @import("services").HttpResponseReader;
const responses = @import("responses.zig");
const transport = @import("responses_transport.zig");
const CodexSessions = @import("CodexSessions.zig");
const CodexContinuation = @import("CodexContinuation.zig");
pub const Request = transport.Request;
const agent = @import("config.zig");

const Phase = enum { prepare, connecting, waiting_for_event, received_data, decoding, provider_rejection };

pub fn call(a: std.mem.Allocator, io: std.Io, request: transport.Request) !agent.AdapterResponse {
    return run(a, io, request, false);
}

pub fn callCodexWithSseFallback(a: std.mem.Allocator, io: std.Io, request: transport.Request) !agent.AdapterResponse {
    if (request.dialect != .codex) return error.InvalidRequest;
    try io.checkCancel();
    return run(a, io, request, true);
}

fn connectionInterrupted(err: anyerror, phase: Phase) bool {
    switch (phase) {
        .connecting, .waiting_for_event, .received_data => {},
        .prepare, .decoding, .provider_rejection => return false,
    }
    return switch (err) {
        error.Timeout, error.ConnectionTimedOut, error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionClosed, error.BrokenPipe, error.NetworkUnreachable, error.NetworkDown, error.HostUnreachable, error.TemporaryNameServerFailure, error.EndOfStream, error.ClosedBeforeCompletedResponse, error.HttpConnectionClosing, error.HttpRequestTruncated, error.TlsConnectionTruncated, error.WriteFailed => true,
        else => false,
    };
}

fn run(a: std.mem.Allocator, io: std.Io, request: transport.Request, allow_fallback: bool) !agent.AdapterResponse {
    const session = if (allow_fallback) request.codex_session else null;
    var lease: CodexSessions.Lease = .{};
    if (session) |owner| switch (try owner.acquire(request.url, request.headers)) {
        .sse => {
            try io.checkCancel();
            return @import("responses_http.zig").call(a, io, request);
        },
        .websocket => |acquired| lease = acquired,
    };
    var phase: Phase = .prepare;
    return exchange(a, io, request, session, &lease, &phase, allow_fallback) catch |err| {
        return failed(a, io, request, session, phase, allow_fallback, err);
    };
}

fn failed(a: std.mem.Allocator, io: std.Io, request: transport.Request, session: ?CodexSessions.Session, phase: Phase, allow_fallback: bool, err: anyerror) !agent.AdapterResponse {
    if (err == error.Canceled or err == error.OutOfMemory) return err;
    try io.checkCancel();
    if (allow_fallback and connectionInterrupted(err, phase)) {
        if (session) |owner| try owner.preferSse();
        if (phase != .received_data) {
            try io.checkCancel();
            std.log.debug("Codex SSE fallback after a pre-stream WebSocket failure ({s})", .{@errorName(err)});
            return @import("responses_http.zig").call(a, io, request);
        }
    }
    const retryable = transport.transientError(err) and !(allow_fallback and (phase == .received_data or phase == .decoding));
    return transport.errorResponse(a, if (retryable) "websocket_disconnected" else "websocket_exchange_failed", @errorName(err));
}

fn exchange(a: std.mem.Allocator, io: std.Io, request: transport.Request, session: ?CodexSessions.Session, lease: *CodexSessions.Lease, phase: *Phase, defer_start: bool) !agent.AdapterResponse {
    defer lease.release(false);
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try responses.createEventValue(arena, request.body, request.dialect);
    const full = try request.preparePayload(arena, io, .websocket, payload);
    switch (try attempt(a, arena, io, request, session, lease, phase, defer_start, full, true)) {
        .response => |response| return response,
        .stale_continuation => {},
    }
    try io.checkCancel();
    // The failed attempt has joined its watchdog and discarded the socket.
    // Retry the same post-hook payload in full, once.
    const scope = session.?;
    var recovery = request;
    recovery.prepared_codex_payload = full.object;
    switch (try scope.acquire(request.url, request.headers)) {
        .sse => return @import("responses_http.zig").call(a, io, recovery),
        .websocket => |fresh| lease.* = fresh,
    }
    phase.* = .prepare;
    const result = attempt(a, arena, io, request, session, lease, phase, defer_start, full, false) catch |err| {
        return failed(a, io, recovery, session, phase.*, true, err);
    };
    return switch (result) {
        .response => |response| response,
        .stale_continuation => unreachable, // The retry never sends a cached ID.
    };
}

const Attempt = union(enum) { response: agent.AdapterResponse, stale_continuation };

fn attempt(a: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, request: transport.Request, session: ?CodexSessions.Session, lease: *CodexSessions.Lease, phase: *Phase, defer_start: bool, full: std.json.Value, allow_delta: bool) !Attempt {
    var keep = false;
    defer lease.release(keep);
    const cache = request.codex_cached_context and lease.reservation != null;
    const cached = if (cache and allow_delta) cached: {
        const link = lease.link orelse break :cached null;
        const continuation = link.continuation orelse break :cached null;
        break :cached try continuation.delta(arena, full);
    } else null;
    const body = try std.json.Stringify.valueAlloc(arena, cached orelse full, .{});
    request.warnSize("WebSocket request bytes", body.len, transport.max_body);
    const reused = lease.link != null;
    const link = lease.link orelse fresh: {
        const owner = if (session) |scope| scope.sessions else null;
        const fresh_link = try Link.connect(if (owner) |scope| scope.allocator else a, if (owner) |scope| scope.io else io, request.url, phase);
        lease.link = fresh_link;
        break :fresh fresh_link;
    };
    var deadline: transport.Deadline = .{};
    const result = operation: {
        var watchdog = try io.concurrent(transport.Deadline.run, .{ &deadline, io, link.connection, request.timeout });
        defer {
            deadline.stop.set(io);
            watchdog.await(io);
        }
        if (!reused) {
            if (try link.upgrade(a, arena, io, request, &deadline, phase)) |rejection| return .{ .response = rejection };
        }
        phase.* = .waiting_for_event;
        break :operation try link.request(a, arena, io, request, body, &deadline, phase, defer_start, if (cache) full else null, cached != null);
    };
    if (result == .stale_continuation) return .stale_continuation;
    errdefer a.free(result.reply.response.json);
    if (deadline.expired.load(.acquire)) return error.Timeout;
    try io.checkCancel();
    keep = result.reply.keep;
    return .{ .response = result.reply.response };
}

/// The client, connection, and upgrade read-ahead stay at fixed addresses.
pub const Link = struct {
    client: std.http.Client,
    connection: *std.http.Client.Connection,
    input: HttpResponseReader,
    created_at: std.Io.Clock.Timestamp,
    continuation: ?*CodexContinuation,

    fn connect(a: std.mem.Allocator, io: std.Io, url: []const u8, phase: *Phase) !*Link {
        const uri = try std.Uri.parse(url);
        const link = try a.create(Link);
        errdefer a.destroy(link);
        link.client = .{ .allocator = a, .io = io };
        errdefer link.client.deinit();
        link.input = .{ .allocator = a };
        link.continuation = null;
        const client = &link.client;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidScheme;
        if (protocol == .tls) {
            const now = std.Io.Clock.real.now(io);
            try client.ca_bundle.rescan(a, io, now);
            client.now = now;
        }
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try std.Io.net.HostName.fromUri(uri, &host_buffer);
        phase.* = .connecting;
        link.connection = try client.connectTcpOptions(.{
            .host = host,
            .port = uri.port orelse if (protocol == .tls) 443 else 80,
            .protocol = protocol,
            .timeout = .{ .duration = transport.connect_timeout },
        });
        link.created_at = .now(io, .awake);
        return link;
    }

    pub fn destroy(self: *Link) void {
        const a = self.client.allocator;
        if (self.continuation) |state| state.destroy();
        self.input.deinit();
        self.connection.closing = true;
        self.client.connection_pool.release(self.connection, self.client.io);
        self.client.deinit();
        a.destroy(self);
    }

    fn upgrade(self: *Link, a: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, admitted: transport.Request, deadline: *const transport.Deadline, phase: *Phase) !?agent.AdapterResponse {
        const uri = try std.Uri.parse(admitted.url);
        const connection = self.connection;
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        var key_buffer: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buffer, &nonce);
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(a);
        try headers.appendSlice(a, admitted.headers);
        try headers.appendSlice(a, &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
            .{ .name = "Sec-WebSocket-Key", .value = key },
        });
        if (admitted.dialect == .codex) try headers.append(a, .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" });
        var http = try self.client.request(.GET, uri, .{
            .connection = connection,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .connection = .{ .override = "Upgrade" }, .accept_encoding = .omit },
            .extra_headers = headers.items,
        });
        defer {
            // The Link owns the pool's used connection. The temporary request
            // must neither drain bytes after HTTP 101 nor release the socket.
            http.connection = null;
            http.deinit();
        }
        try http.sendBodiless();
        var head = self.input.receiveHead(&http) catch |err| {
            if (deadline.expired.load(.acquire)) return error.Timeout;
            if (err == error.ReadFailed) return connection.getReadError() orelse err;
            return err;
        };
        admitted.warnSize("WebSocket upgrade head bytes", head.head.bytes.len, HttpResponseReader.expected_bytes);
        if (head.head.status != .switching_protocols) {
            if (@backingInt(head.head.status) < 400) return error.InvalidUpgrade;
            phase.* = .provider_rejection;
            var retry_after_ms: u32 = 0;
            var response_headers = head.head.iterateHeaders();
            while (response_headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) retry_after_ms = transport.retryAfterMilliseconds(header.value, std.Io.Timestamp.now(io, .real).toSeconds()) orelse 0;
            }
            const status = @backingInt(head.head.status);
            var transfer: [4096]u8 = undefined;
            const bytes = head.reader(&transfer).allocRemaining(arena, .limited(64 * 1024)) catch |err| {
                if (err == error.OutOfMemory) return err;
                try io.checkCancel();
                return try transport.remoteResponse(a, "websocket upgrade", status, .null, retry_after_ms);
            };
            const detail = json_text.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                break :blk std.json.Value.null;
            };
            return try transport.remoteResponse(a, "websocket upgrade", status, detail, retry_after_ms);
        }
        var expected: [28]u8 = undefined;
        acceptKey(key, &expected);
        var accepted = false;
        var upgraded = false;
        var connected = false;
        var iterator = head.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
                if (accepted or !std.mem.eql(u8, header.value, &expected)) return error.InvalidUpgrade;
                accepted = true;
            } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                upgraded = std.ascii.eqlIgnoreCase(header.value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                var tokens = std.mem.splitScalar(u8, header.value, ',');
                while (tokens.next()) |token| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) connected = true;
                }
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions") or
                std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) return error.UnrequestedExtension;
        }
        if (!accepted or !upgraded or !connected) return error.InvalidUpgrade;
        return null;
    }

    const Result = union(enum) {
        reply: struct { response: agent.AdapterResponse, keep: bool },
        stale_continuation,
    };

    fn request(self: *Link, a: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, admitted: transport.Request, body: []const u8, deadline: *const transport.Deadline, phase: *Phase, defer_start: bool, cache_full: ?std.json.Value, sent_delta: bool) !Result {
        const connection = self.connection;
        try send(connection.writer(), io, 1, body);
        try connection.flush();
        var decoder: responses.Decoder = .{
            .allocator = a,
            .preview = admitted.preview,
            .request_id = admitted.id,
            .dialect = admitted.dialect,
            .start_on_event = defer_start,
            .size_context = admitted.size_context,
        };
        defer decoder.deinit();
        if (!defer_start) if (admitted.preview) |preview| try preview.notify(preview.context, admitted.id, .started);
        const response_body = receive(a, io, connection, &self.input.interface, &decoder, admitted, phase) catch |err| {
            if (phase.* == .decoding) return err;
            if (self.input.failure) |failure| return failure;
            if ((err == error.ReadFailed or err == error.EndOfStream) and deadline.expired.load(.acquire)) return error.Timeout;
            if (err == error.ReadFailed) return connection.getReadError() orelse err;
            return err;
        };
        if (sent_delta and decoder.start_on_event and decoder.previous_response_missing) return .stale_continuation;
        const parsed = try json_text.parseFromSlice(std.json.Value, arena, response_body, .{});
        const status = if (parsed.value == .object) parsed.value.object.get("status") else null;
        const keep = if (status) |value| value == .string and
            (std.mem.eql(u8, value.string, "completed") or std.mem.eql(u8, value.string, "incomplete")) else false;
        if (self.continuation) |state| state.destroy();
        self.continuation = null;
        if (keep) {
            if (cache_full) |full| self.continuation = try CodexContinuation.capture(self.client.allocator, arena, full, parsed.value);
        }
        return .{ .reply = .{ .response = try transport.remoteResponse(a, "websocket event", 200, parsed.value, 0), .keep = keep } };
    }
};

fn receive(a: std.mem.Allocator, io: std.Io, connection: *std.http.Client.Connection, reader: *std.Io.Reader, decoder: *responses.Decoder, request: transport.Request, phase: *Phase) ![]const u8 {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(a);
    var fragmented = false;
    var received: usize = 0;
    while (decoder.result == null) {
        const first = try reader.takeByte();
        // A fragment or partial header can already be output from this request.
        if ((first & 0x0f) < 8) phase.* = .received_data;
        const frame = try finishHeader(reader, first);
        if (received <= transport.max_response) request.warnSize("WebSocket response bytes", received +| frame.length, transport.max_response);
        received +|= frame.length;
        if (frame.opcode >= 8) {
            var control: [125]u8 = undefined;
            const payload = control[0..frame.length];
            try reader.readSliceAll(payload);
            switch (frame.opcode) {
                8 => {
                    if (payload.len == 1) return error.InvalidControlFrame;
                    if (payload.len >= 2) {
                        const code = std.mem.readInt(u16, payload[0..2], .big);
                        if (!validCloseCode(code) or !std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidControlFrame;
                    }
                    return error.ClosedBeforeCompletedResponse;
                },
                9 => {
                    try send(connection.writer(), io, 10, payload);
                    try connection.flush();
                },
                10 => {},
                else => return error.InvalidOpcode,
            }
            continue;
        }
        switch (frame.opcode) {
            1 => if (fragmented) {
                return error.InvalidFragment;
            },
            0 => if (!fragmented) {
                return error.InvalidFragment;
            },
            else => return error.InvalidOpcode,
        }
        const old_len = message.items.len;
        try message.resize(a, try std.math.add(usize, old_len, frame.length));
        try reader.readSliceAll(message.items[old_len..]);
        fragmented = !frame.final;
        if (frame.final) {
            if (!std.unicode.utf8ValidateSlice(message.items)) return error.InvalidUtf8;
            phase.* = .decoding;
            try decoder.event(message.items);
            phase.* = .received_data;
            message.clearRetainingCapacity();
        }
    }
    return decoder.finish();
}

fn validCloseCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

pub fn acceptKey(key: []const u8, output: *[28]u8) void {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(output, &digest);
}

const Header = struct { final: bool, opcode: u4, length: usize };

pub fn readHeader(reader: *std.Io.Reader) !Header {
    return finishHeader(reader, try reader.takeByte());
}

fn finishHeader(reader: *std.Io.Reader, first: u8) !Header {
    if (first & 0x70 != 0) return error.InvalidFrame;
    const opcode: u4 = @truncate(first);
    const final = first & 0x80 != 0;
    if (opcode >= 8 and !final) return error.InvalidControlFrame;
    if ((opcode >= 3 and opcode < 8) or opcode > 10) return error.InvalidOpcode;
    const second = try reader.takeByte();
    if (second & 0x80 != 0) return error.InvalidFrame;
    const short = second & 0x7f;
    const length: u64 = switch (short) {
        126 => try reader.takeInt(u16, .big),
        127 => try reader.takeInt(u64, .big),
        else => short,
    };
    if (length > std.math.maxInt(usize) or length >> 63 != 0 or
        (short == 126 and length < 126) or (short == 127 and length < 65536)) return error.InvalidFrame;
    if (opcode >= 8 and length > 125) return error.InvalidControlFrame;
    return .{ .final = final, .opcode = opcode, .length = @intCast(length) };
}

pub fn send(writer: *std.Io.Writer, io: std.Io, opcode: u4, payload: []const u8) !void {
    try writer.writeByte(0x80 | @as(u8, opcode));
    if (payload.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try writer.writeByte(0x80 | 126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(0x80 | 127);
        try writer.writeInt(u64, payload.len, .big);
    }
    var mask: [4]u8 = undefined;
    io.random(&mask);
    try writer.writeAll(&mask);
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const count = @min(buffer.len, payload.len - offset);
        for (buffer[0..count], 0..) |*byte, index| byte.* = payload[offset + index] ^ mask[(offset + index) % 4];
        try writer.writeAll(buffer[0..count]);
        offset += count;
    }
}
