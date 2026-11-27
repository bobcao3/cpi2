const std = @import("std");
const json_text = @import("json_tree").text;
const j = @import("json.zig");
const Context = @import("root.zig").Context;
const Self = @This();
const expected_backend_log_bytes = 64 * 1024 * 1024;

directory: []const u8,
binary: []const u8,
environment: *const std.process.Environ.Map,

pub const Job = struct {
    id: []const u8,
    fingerprint: []const u8,
    description: []const u8,
    cwd: []const u8,
    is_pty: bool,
};

pub fn prepare(self: Self, context: Context) !void {
    try std.Io.Dir.cwd().createDirPath(context.io, std.fs.path.dirname(self.directory) orelse return error.InvalidConfiguration);
    _ = try self.run(context, &.{ "prepare-runtime", self.directory }, null, false, null);
}

pub fn run(self: Self, c: Context, args: []const []const u8, environment: ?*const std.process.Environ.Map, socket: bool, input: ?[]const u8) !j.Value {
    const a = c.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, self.binary);
    if (socket) try argv.appendSlice(a, &.{ "-S", try std.fs.path.join(a, &.{ self.directory, "control.sock" }) });
    try argv.appendSlice(a, args);
    const env = environment orelse self.environment;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } };
    const result = if (input) |bytes| try runWithInput(a, c.io, argv.items, env, bytes, timeout) else try std.process.run(a, c.io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    });
    c.warnSize("process.backend", "stdout bytes", result.stdout.len, 8 * 1024 * 1024);
    c.warnSize("process.backend", "stderr bytes", result.stderr.len, 65536);
    reportBackendWarnings(c, result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        if (std.mem.indexOf(u8, result.stderr, "UnknownUid") != null) return error.JobNotRunning;
        if (std.mem.indexOf(u8, result.stderr, "NotPty") != null) return error.NotPty;
        if (std.mem.indexOf(u8, result.stderr, "InvalidSignal") != null) return error.InvalidArguments;
        if (std.mem.indexOf(u8, result.stderr, "Unsafe") != null) return error.UnsafeRuntime;
        return error.GhostmuxFailed;
    }
    return if (result.stdout.len == 0) .null else j.parse(a, result.stdout);
}

fn runWithInput(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map, bytes: []const u8, timeout: std.Io.Timeout) !std.process.RunResult {
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    var sender = try io.concurrent(sendInput, .{ io, child.stdin.?, bytes });
    child.stdin = null;
    defer sender.cancel(io) catch {};

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var streams: std.Io.File.MultiReader = undefined;
    streams.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer streams.deinit();
    while (streams.fill(64, timeout)) |_| {} else |err| {
        if (err != error.EndOfStream) return err;
    }
    try streams.checkAnyError();
    const term = try child.wait(io);
    try sender.await(io);
    const stdout = try streams.toOwnedSlice(0);
    errdefer a.free(stdout);
    return .{ .term = term, .stdout = stdout, .stderr = try streams.toOwnedSlice(1) };
}

fn sendInput(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn reportBackendWarnings(c: Context, stderr: []const u8) void {
    const prefix = "warning(ghostmux_size): ";
    var records = std.mem.splitScalar(u8, stderr, '\n');
    while (records.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const measurement, const sizes = std.mem.cut(u8, line[prefix.len..], " is ") orelse continue;
        const actual, const expected = std.mem.cut(u8, sizes, ", above the expected ") orelse continue;
        c.warnSize("process.backend", measurement, std.fmt.parseInt(u64, actual, 10) catch continue, std.fmt.parseInt(u64, expected, 10) catch continue);
    }
}

pub fn path(self: Self, a: std.mem.Allocator, id: []const u8, extension: []const u8) ![]const u8 {
    if (id.len != 64) return error.InvalidArguments;
    for (id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidArguments;
    return std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ self.directory, id, extension });
}

pub fn load(self: Self, c: Context, id: []const u8) !Job {
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, try self.path(c.allocator, id, "job"), c.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.UnknownJob,
        else => return err,
    };
    c.warnSize("process.backend", "job record bytes", bytes.len, 16384);
    return json_text.parseFromSliceLeaky(Job, c.allocator, bytes, .{ .allocate = .alloc_always });
}

pub fn save(self: Self, c: Context, job: Job) !void {
    const file = try std.Io.Dir.cwd().createFile(c.io, try self.path(c.allocator, job.id, "job"), .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(c.io);
    try file.writeStreamingAll(c.io, try j.encode(c.allocator, job));
    try file.sync(c.io);
}

pub fn detached(self: Self, c: Context, id: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(c.io, try self.path(c.allocator, id, "detached"), .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn status(self: Self, c: Context, job: Job) !j.Value {
    var result = try j.value(c.allocator, .{
        .id = job.id,
        .description = job.description,
        .cwd = job.cwd,
        .is_pty = job.is_pty,
        .detached = try self.detached(c, job.id),
        .status = "unknown",
        .exit_code = @as(?i32, null),
        .pid = @as(?i32, null),
        .output_path = try self.path(c.allocator, job.id, "log"),
    });
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, try self.path(c.allocator, job.id, "status"), c.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    c.warnSize("process.backend", "status record bytes", bytes.len, 16384);
    if (bytes.len == 0) return result;
    const record = try j.parse(c.allocator, bytes);
    const session = j.get(record, "session");
    const output_bytes = j.get(session, "bytes");
    if (output_bytes == .integer and output_bytes.integer >= 0) c.warnSize("process.backend", "retained log bytes", @intCast(output_bytes.integer), expected_backend_log_bytes);
    const exit_code = j.get(session, "exit_code");
    try j.put(c.allocator, &result, "exit_code", exit_code);
    try j.put(c.allocator, &result, "pid", j.get(session, "pid"));
    const state = if (exit_code != .null) "completed" else if (j.get(result, "detached").bool) "detached" else "running";
    try j.put(c.allocator, &result, "status", .{ .string = state });
    try j.put(c.allocator, &result, "backend_error", j.get(record, "error_name"));
    return result;
}

pub fn list(self: Self, c: Context, include_completed: bool) !j.Value {
    var result: j.Value = .{ .array = std.json.Array.init(c.allocator) };
    var dir = try std.Io.Dir.cwd().openDir(c.io, self.directory, .{ .iterate = true });
    defer dir.close(c.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(c.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".job")) continue;
        count += 1;
        const job = try self.load(c, entry.name[0 .. entry.name.len - 4]);
        const item = try self.status(c, job);
        if (!include_completed and !std.mem.eql(u8, try j.text(j.get(item, "status")), "running")) continue;
        try result.array.append(item);
    }
    c.warnSize("process.list", "job count", count, 256);
    return result;
}

pub fn read(self: Self, c: Context, endpoint: []const u8, job: Job, args: j.Value) !j.Value {
    var result = try self.status(c, job);
    const offset = try j.integer(args, "offset", 0, 0, std.math.maxInt(u64));
    c.warnSize(endpoint, "log offset", offset, 1 << 53);
    const limit = try j.integer(args, "limit", std.math.maxInt(u64), 1, std.math.maxInt(u64));
    const file = std.Io.Dir.cwd().openFile(c.io, try self.path(c.allocator, job.id, "log"), .{}) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer file.close(c.io);
    const size = (try file.stat(c.io)).size;
    if (j.get(result, "exit_code") == .null) c.warnSize("process.backend", "retained log bytes", size, expected_backend_log_bytes);
    if (offset > size) return error.InvalidOffset;
    const requested = @min(limit, size - offset);
    c.warnSize(endpoint, "selected log bytes", requested, 65536);
    const buffer = try c.allocator.alloc(u8, std.math.cast(usize, requested) orelse return error.Overflow);
    const length = try file.readPositionalAll(c.io, buffer, offset);
    const bytes = buffer[0..length];
    const encoder = std.base64.standard.Encoder;
    const encoded = try c.allocator.alloc(u8, encoder.calcSize(length));
    try j.put(c.allocator, &result, "base64", .{ .string = encoder.encode(encoded, bytes) });
    try j.put(c.allocator, &result, "output", .{ .string = try utf8(c.allocator, bytes) });
    try j.put(c.allocator, &result, "offset", .{ .integer = @intCast(offset) });
    try j.put(c.allocator, &result, "next_offset", .{ .integer = @intCast(offset + length) });
    try j.put(c.allocator, &result, "truncated", .{ .bool = offset + length < size });
    const completed = j.get(result, "exit_code") != .null;
    try j.put(c.allocator, &result, "eof", .{ .bool = completed and offset + length >= size });
    return result;
}

fn utf8(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 0;
        const valid = length > 0 and index + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index..][0..length]);
        if (valid) {
            try result.appendSlice(a, bytes[index..][0..length]);
            index += length;
        } else {
            try result.appendSlice(a, "\xef\xbf\xbd");
            index += 1;
        }
    }
    return result.toOwnedSlice(a);
}
