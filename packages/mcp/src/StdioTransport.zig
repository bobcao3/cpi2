//! Newline-delimited JSON transport for stdio MCP servers.
//!
//! The reader returns an owned copy of each line. It never returns a slice into
//! the internal buffer: callers commonly parse the line with a temporary arena,
//! and the next read may compact or reset the buffer.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");
const transport = @import("Transport.zig");

const Allocator = std.mem.Allocator;
const read_chunk = 8192;

pub const StdioTransport = struct {
    a: Allocator,
    io: std.Io,
    child: std.process.Child,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    start: usize = 0,
    timeout_ms: u64,

    pub fn create(a: Allocator, io: std.Io, server: *const Config.Server, environment: *const std.process.Environ.Map, output_directory: []const u8) !transport.Transport {
        const command = server.command orelse return error.UnsupportedMcpTransport;
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        const ta = temporary.allocator();

        const argv = try ta.alloc([]const u8, server.args.len + 1);
        argv[0] = command;
        @memcpy(argv[1..], server.args);

        var child_environment = std.process.Environ.Map.init(ta);
        defer child_environment.deinit();
        var inherited = environment.iterator();
        while (inherited.next()) |entry| try child_environment.put(entry.key_ptr.*, entry.value_ptr.*);
        for (server.env) |entry| try child_environment.put(entry.name, entry.value);

        try std.Io.Dir.cwd().createDirPath(io, output_directory);
        const log_name = try std.fmt.allocPrint(ta, "mcp-{s}.log", .{server.name});
        const log_path = try std.fs.path.join(ta, &.{ output_directory, log_name });
        const log = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true, .permissions = .fromMode(0o600) }) catch return error.McpLogUnavailable;
        defer log.close(io);

        const self = try a.create(StdioTransport);
        errdefer a.destroy(self);
        const child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (server.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = &child_environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .{ .file = log },
            .pgid = 0,
        }) catch return error.McpSpawnFailed;
        self.* = .{
            .a = a,
            .io = io,
            .child = child,
            .timeout_ms = server.timeout_ms,
        };
        return .{
            .context = self,
            .vtable = &vtable,
            .mode = .stream,
        };
    }

    const vtable: transport.Transport.VTable = .{
        .send = sendRaw,
        .receive = receiveRaw,
        .close = closeRaw,
    };

    fn sendRaw(context: *anyopaque, a: Allocator, io: std.Io, body: []const u8, _: ?[]const u8, _: []const u8, timeout_ms: u64) anyerror!transport.Response {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        try self.write(a, io, body, if (timeout_ms == 0) self.timeout_ms else timeout_ms);
        return .{};
    }

    fn receiveRaw(context: *anyopaque, a: Allocator, io: std.Io, timeout_ms: u64) anyerror![]u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        return self.readLine(a, io, if (timeout_ms == 0) self.timeout_ms else timeout_ms);
    }

    fn closeRaw(context: *anyopaque, a: Allocator, io: std.Io) void {
        const self: *StdioTransport = @ptrCast(@alignCast(context));
        self.terminate(io);
        self.pending.deinit(a);
        a.destroy(self);
    }

    fn terminate(self: *StdioTransport, io: std.Io) void {
        const pid = self.child.id orelse return;
        if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            // The child is a process-group leader (pgid = 0). Signal the group
            // so a shell wrapper cannot leave grandchildren behind. Escalate to
            // SIGKILL after a short grace period; Child.kill always reaps.
            std.posix.kill(-pid, .TERM) catch {};
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            std.posix.kill(-pid, .KILL) catch {};
        }
        self.child.kill(io);
    }

    fn write(self: *StdioTransport, a: Allocator, io: std.Io, body: []const u8, timeout_ms: u64) !void {
        const file = self.child.stdin orelse return error.McpClosed;
        const line = try std.fmt.allocPrint(a, "{s}\n", .{body});
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake });
        var offset: usize = 0;
        while (offset < line.len) {
            const result = io.operateTimeout(.{ .file_write_streaming = .{
                .file = file,
                .header = line[offset..],
                .data = &.{""},
            } }, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => return error.McpTimeout,
                error.Canceled => return error.Canceled,
                else => return error.McpTransport,
            };
            const written = result.file_write_streaming catch |err| switch (err) {
                error.BrokenPipe => return error.McpClosed,
                else => return error.McpTransport,
            };
            if (written == 0) return error.McpTransport;
            offset += written;
        }
    }

    fn readLine(self: *StdioTransport, a: Allocator, io: std.Io, timeout_ms: u64) ![]u8 {
        const file = self.child.stdout orelse return error.McpClosed;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake });
        const timeout: std.Io.Timeout = .{ .deadline = deadline };
        var scanned = self.start;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.pending.items, scanned, '\n')) |end| {
                const line = try a.dupe(u8, self.pending.items[self.start..end]);
                self.start = end + 1;
                self.compact();
                return line;
            }
            var scratch: [read_chunk]u8 = undefined;
            const result = io.operateTimeout(.{ .file_read_streaming = .{
                .file = file,
                .data = &.{&scratch},
            } }, timeout) catch |err| switch (err) {
                error.Timeout => return error.McpTimeout,
                error.Canceled => return error.Canceled,
                else => return error.McpTransport,
            };
            const count = result.file_read_streaming catch |err| switch (err) {
                error.EndOfStream => return error.McpClosed,
                else => return error.McpTransport,
            };
            if (count == 0) return error.McpClosed;
            scanned = self.pending.items.len;
            try self.pending.appendSlice(self.a, scratch[0..count]);
        }
    }

    fn compact(self: *StdioTransport) void {
        if (self.start == 0) return;
        const remaining = self.pending.items.len - self.start;
        if (remaining == 0) {
            self.pending.clearRetainingCapacity();
            self.start = 0;
        } else if (self.start >= 4096) {
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[self.start..]);
            self.pending.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }
    }
};

pub fn create(a: Allocator, io: std.Io, server: *const Config.Server, environment: *const std.process.Environ.Map, output_directory: []const u8) !transport.Transport {
    return StdioTransport.create(a, io, server, environment, output_directory);
}
