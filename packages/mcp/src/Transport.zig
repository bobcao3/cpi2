//! Transport boundary for MCP JSON-RPC messages.
//!
//! A transport has one of two shapes:
//! * `exchange`: send one body and receive one body. HTTP's body may contain
//!   JSON or a complete SSE response.
//! * `stream`: write one newline-delimited message, then read one message at a
//!   time. Stdio uses this shape and must be able to deliver notifications and
//!   server requests before the response with the matching id.
//!
//! Implementations own their context. `close` must be idempotent, free the
//! context with the supplied allocator, and terminate any child process.

const std = @import("std");
const Config = @import("Config.zig");

pub const Allocator = std.mem.Allocator;
pub const expected_message_bytes = 32 * 1024 * 1024;

pub const SizeSink = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, []const u8, usize, usize) void = logSizeWarning,

    pub fn report(self: SizeSink, measurement: []const u8, actual: usize, threshold: usize) void {
        if (actual > threshold) self.notify(self.context, measurement, actual, threshold);
    }
};

fn logSizeWarning(_: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    std.log.warn("MCP {s} is {d}, above the expected {d}", .{ measurement, actual, threshold });
}

pub const Mode = enum { exchange, stream };

pub const Response = struct {
    /// Owned by the caller's allocator.
    body: []u8 = &.{},
    /// Owned by the caller's allocator.
    session_id: ?[]u8 = null,
    sse: bool = false,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,
    mode: Mode,

    pub const VTable = struct {
        send: *const fn (
            context: *anyopaque,
            a: Allocator,
            io: std.Io,
            body: []const u8,
            session_id: ?[]const u8,
            protocol_version: []const u8,
            timeout_ms: u64,
        ) anyerror!Response,
        receive: *const fn (
            context: *anyopaque,
            a: Allocator,
            io: std.Io,
            timeout_ms: u64,
        ) anyerror![]u8,
        close: *const fn (context: *anyopaque, a: Allocator, io: std.Io) void,
        observe_sizes: ?*const fn (context: *anyopaque, SizeSink) void = null,
    };

    pub fn send(self: Transport, a: Allocator, io: std.Io, body: []const u8, session_id: ?[]const u8, protocol_version: []const u8, timeout_ms: u64) !Response {
        return self.vtable.send(self.context, a, io, body, session_id, protocol_version, timeout_ms);
    }

    pub fn receive(self: Transport, a: Allocator, io: std.Io, timeout_ms: u64) ![]u8 {
        return self.vtable.receive(self.context, a, io, timeout_ms);
    }

    pub fn close(self: Transport, a: Allocator, io: std.Io) void {
        self.vtable.close(self.context, a, io);
    }
};

pub const Factory = struct {
    context: ?*anyopaque = null,
    create: *const fn (
        context: ?*anyopaque,
        a: Allocator,
        io: std.Io,
        server: *const Config.Server,
        environment: *const std.process.Environ.Map,
        output_directory: []const u8,
    ) anyerror!Transport,
};

pub fn createDefault(_: ?*anyopaque, a: Allocator, io: std.Io, server: *const Config.Server, environment: *const std.process.Environ.Map, output_directory: []const u8) !Transport {
    if (server.url != null) {
        const Http = @import("HttpTransport.zig");
        return Http.create(a, io, server);
    }
    const Stdio = @import("StdioTransport.zig");
    return Stdio.create(a, io, server, environment, output_directory);
}

pub const default_factory: Factory = .{ .create = createDefault };
