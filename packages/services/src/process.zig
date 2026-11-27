const std = @import("std");
const root = @import("root.zig");
const j = root.json;
const Jobs = @import("jobs.zig");
const Self = @This();

workspace: []const u8,
directory: []const u8,
binary: []const u8,
environment: *const std.process.Environ.Map,

pub const Spawn = struct {
    argv: []const []const u8,
    cwd: []const u8 = ".",
    description: []const u8 = "",
    is_pty: bool = false,
    columns: u16 = 80,
    rows: u16 = 24,
    env: ?j.Value = null,
    interval_ms: ?u32 = null,
    pub fn validate(self: Spawn) !void {
        if (self.argv.len == 0 or self.columns == 0 or self.rows == 0) return error.InvalidArguments;
        for (self.argv, 0..) |arg, i| if ((i == 0 and arg.len == 0) or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArguments;
        if (self.interval_ms) |interval| if (interval < 100 or interval > 60000) return error.InvalidArguments;
        if (self.env) |env| {
            if (env != .object) return error.InvalidArguments;
            var entries = env.object.iterator();
            while (entries.next()) |entry| {
                if (entry.key_ptr.len == 0 or std.mem.indexOfAny(u8, entry.key_ptr.*, "=\x00") != null) return error.InvalidArguments;
                _ = try j.text(entry.value_ptr.*);
            }
        }
    }
};
pub const Id = struct { id: []const u8 };
pub const Read = struct {
    id: []const u8,
    offset: u64 = 0,
    limit: ?u64 = null,
    wait_ms: u32 = 1000,
    pub fn validate(self: Read) !void {
        if (self.wait_ms > 30000) return error.InvalidArguments;
        if (self.limit) |limit| if (limit == 0) return error.InvalidArguments;
    }
};
pub const Status = struct {
    id: []const u8,
    description: []const u8,
    cwd: []const u8,
    is_pty: bool,
    detached: bool,
    status: []const u8,
    exit_code: ?i32,
    pid: ?i32,
    output_path: []const u8,
    backend_error: ?[]const u8 = null,
    base64: ?[]const u8 = null,
    output: ?[]const u8 = null,
    offset: ?u64 = null,
    next_offset: ?u64 = null,
    truncated: ?bool = null,
    eof: ?bool = null,
};
const bounds: root.Operation.Limits = .{ .arguments = 1024 * 1024, .result = 8 * 1024 * 1024 };
pub const operations = [_]root.Operation{
    root.Operation.defineJson("process.spawn", Spawn, Status, bounds, .receipt, dispatch),
    root.Operation.defineJson("process.repeat", Spawn, Status, bounds, .receipt, dispatch),
    root.Operation.defineJson("process.status", Id, Status, bounds, .read_only, dispatch),
    root.Operation.defineJson("process.list", struct { include_completed: bool = false }, struct { jobs: []const Status }, bounds, .read_only, dispatch),
    root.Operation.defineJson("process.read", Read, Status, bounds, .read_only, dispatch),
    root.Operation.defineJson("process.wait", Read, Status, bounds, .read_only, dispatch),
    root.Operation.defineJson("process.write", struct { id: []const u8, data: []const u8 }, Status, .{ .arguments = 128 * 1024, .result = 16384 }, .never, dispatch),
    root.Operation.defineJson("process.signal", struct { id: []const u8, signal: []const u8 = "SIGINT" }, Status, bounds, .never, dispatch),
    root.Operation.defineJson("process.resize", struct { id: []const u8, columns: u16 = 80, rows: u16 = 24 }, Status, bounds, .never, dispatch),
    root.Operation.defineJson("process.capture", struct { id: []const u8, history: bool = true, join: bool = true, max_bytes: ?usize = null }, struct { id: []const u8, text: []const u8, head_bytes: u64, omitted_bytes: u64 }, bounds, .read_only, dispatch),
    root.Operation.defineJson("process.screenshot", struct { id: []const u8, font_size: u16 = 14 }, struct { id: []const u8, path: []const u8, mime_type: []const u8 }, bounds, .never, dispatch),
    root.Operation.defineJson("process.detach", Id, Status, bounds, .never, dispatch),
};
const operation_pointers = blk: {
    var pointers: [operations.len]*const root.Operation = undefined;
    for (&operations, 0..) |*operation, i| pointers[i] = operation;
    break :blk pointers;
};

pub fn service(self: *Self) root.Service {
    return .{ .context = self, .operations = &operation_pointers };
}

pub fn ownedService(self: *Self) root.Service {
    return .{ .context = self, .operations = &operation_pointers, .release = release };
}

fn release(pointer: *anyopaque, c: root.Context) !void {
    const self: *Self = @ptrCast(@alignCast(pointer));
    return self.cleanup(c);
}

pub fn cleanup(self: *Self, c: root.Context) !void {
    const protection = c.io.swapCancelProtection(.blocked);
    defer _ = c.io.swapCancelProtection(protection);
    const jobs: Jobs = .{ .directory = self.directory, .binary = self.binary, .environment = self.environment };
    const records = jobs.list(c, true) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var pending: std.ArrayList(Jobs.Job) = .empty;
    defer pending.deinit(c.allocator);
    var failure: ?anyerror = null;
    for (records.array.items) |record| {
        if (j.get(record, "detached").bool or j.get(record, "exit_code") != .null) continue;
        const job = try jobs.load(c, try j.text(j.get(record, "id")));
        try pending.append(c.allocator, job);
        _ = jobs.run(c, &.{ "signal-session", "--signal", "SIGKILL", "--uid", job.id, "--json" }, null, true, null) catch |err| {
            if (err != error.JobNotRunning and failure == null) failure = err;
            continue;
        };
    }
    const deadline = std.Io.Clock.awake.now(c.io).toMilliseconds() + 3000;
    while (pending.items.len > 0) {
        var index: usize = 0;
        while (index < pending.items.len) {
            const state = try jobs.status(c, pending.items[index]);
            if (j.get(state, "exit_code") != .null) _ = pending.swapRemove(index) else index += 1;
        }
        if (pending.items.len == 0) break;
        if (std.Io.Clock.awake.now(c.io).toMilliseconds() >= deadline) return failure orelse error.ProcessCleanupTimeout;
        try std.Io.sleep(c.io, .fromMilliseconds(20), .awake);
    }
    if (failure) |err| return err;
}

fn dispatch(pointer: *anyopaque, c: root.Context, endpoint: []const u8, args: j.Value) !j.Value {
    const self: *Self = @ptrCast(@alignCast(pointer));
    const jobs: Jobs = .{ .directory = self.directory, .binary = self.binary, .environment = self.environment };
    if (!std.fs.path.isAbsolute(self.directory) or !std.fs.path.isAbsolute(self.workspace)) return error.InvalidConfiguration;
    try jobs.prepare(c);
    if (std.mem.eql(u8, endpoint, "process.spawn")) return self.spawn(c, jobs, args);
    if (std.mem.eql(u8, endpoint, "process.repeat")) {
        var repeated = args;
        const command = j.get(args, "argv");
        if (command != .array) return error.InvalidArguments;
        var argv: j.Value = .{ .array = std.json.Array.init(c.allocator) };
        try argv.array.append(.{ .string = try std.process.executablePathAlloc(c.io, c.allocator) });
        try argv.array.append(.{ .string = "--repeat" });
        try argv.array.append(.{ .string = try std.fmt.allocPrint(c.allocator, "{d}", .{try j.integer(args, "interval_ms", 5000, 100, 60000)}) });
        for (command.array.items) |arg| try argv.array.append(arg);
        try j.put(c.allocator, &repeated, "argv", argv);
        return self.spawn(c, jobs, repeated);
    }
    if (std.mem.eql(u8, endpoint, "process.list")) return j.value(c.allocator, .{ .jobs = try jobs.list(c, try j.boolean(args, "include_completed", false)) });
    const id = try j.text(j.get(args, "id"));
    const job = try jobs.load(c, id);
    if (std.mem.eql(u8, endpoint, "process.status")) return jobs.status(c, job);
    if (std.mem.eql(u8, endpoint, "process.read")) return jobs.read(c, endpoint, job, args);
    if (std.mem.eql(u8, endpoint, "process.wait")) {
        const wait_ms = try j.integer(args, "wait_ms", 1000, 0, 30000);
        const deadline = std.Io.Clock.awake.now(c.io).toMilliseconds() + @as(i64, @intCast(wait_ms));
        while (true) {
            const status = try jobs.status(c, job);
            if (j.get(status, "exit_code") != .null or std.Io.Clock.awake.now(c.io).toMilliseconds() >= deadline) return jobs.read(c, endpoint, job, args);
            try std.Io.sleep(c.io, .fromMilliseconds(20), .awake);
        }
    }
    if (try jobs.detached(c, id)) return error.JobDetached;
    var argv: std.ArrayList([]const u8) = .empty;
    const a = c.allocator;
    var input: ?[]const u8 = null;
    if (std.mem.eql(u8, endpoint, "process.detach")) {
        const state = try jobs.status(c, job);
        if (j.get(state, "exit_code") != .null) return error.JobNotRunning;
        const file = try std.Io.Dir.cwd().createFile(c.io, try jobs.path(a, id, "detached"), .{ .exclusive = true, .permissions = .fromMode(0o600) });
        file.close(c.io);
        return jobs.status(c, job);
    } else if (std.mem.eql(u8, endpoint, "process.signal")) {
        try argv.appendSlice(a, &.{ "signal-session", "--signal", try j.string(args, "signal", "SIGINT") });
    } else if (std.mem.eql(u8, endpoint, "process.write")) {
        const data = try j.text(j.get(args, "data"));
        c.warnSize(endpoint, "input bytes", data.len, 65536);
        input = data;
        try argv.append(a, "send-input");
    } else if (std.mem.eql(u8, endpoint, "process.resize")) {
        try argv.append(a, "resize-window");
        try dimensions(c, endpoint, &argv, args);
    } else if (std.mem.eql(u8, endpoint, "process.capture")) {
        try argv.append(a, "capture-pane");
        if (try j.boolean(args, "history", true)) try argv.append(a, "--history");
        if (try j.boolean(args, "join", true)) try argv.append(a, "--join");
        if (j.get(args, "max_bytes") != .null) try argv.appendSlice(a, &.{ "--max-bytes", try std.fmt.allocPrint(a, "{d}", .{try j.integer(args, "max_bytes", 0, 0, std.math.maxInt(usize))}) });
    } else if (std.mem.eql(u8, endpoint, "process.screenshot")) {
        const path = try jobs.path(a, id, "png");
        try argv.appendSlice(a, &.{ "screenshot", "--output", path, "--font-size", try std.fmt.allocPrint(a, "{d}", .{try j.integer(args, "font_size", 14, 1, std.math.maxInt(u16))}) });
    } else return error.UnsupportedEndpoint;
    try argv.appendSlice(a, &.{ "--uid", id, "--json" });
    const response = try jobs.run(c, argv.items, null, true, input);
    if (std.mem.eql(u8, endpoint, "process.capture")) return j.value(a, .{
        .id = id,
        .text = j.get(response, "text"),
        .head_bytes = j.get(response, "head_bytes"),
        .omitted_bytes = j.get(response, "omitted_bytes"),
    });
    if (std.mem.eql(u8, endpoint, "process.screenshot")) return j.value(a, .{ .id = id, .path = j.get(response, "path"), .mime_type = "image/png" });
    return jobs.status(c, job);
}

fn spawn(self: *Self, c: root.Context, jobs: Jobs, args: j.Value) !j.Value {
    const a = c.allocator;
    if (c.idempotency_key.len == 0) return error.MissingIdempotencyKey;
    c.warnSize("process.spawn", "idempotency key bytes", c.idempotency_key.len, 4096);
    const id = try a.dupe(u8, &j.hash(c.idempotency_key));
    const fingerprint = try a.dupe(u8, &j.hash(try j.encode(a, args)));
    const lock_path = try std.fs.path.join(a, &.{ self.directory, "admission.lock" });
    const lock = try std.Io.Dir.cwd().createFile(c.io, lock_path, .{ .read = true, .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(c.io);
    try lock.lock(c.io, .exclusive);
    if (jobs.load(c, id)) |existing| {
        if (!std.mem.eql(u8, existing.fingerprint, fingerprint)) return error.RequestConflict;
        return jobs.status(c, existing);
    } else |err| if (err != error.UnknownJob) return err;
    const command = j.get(args, "argv");
    if (command != .array or command.array.items.len == 0) return error.InvalidArguments;
    c.warnSize("process.spawn", "argument count", command.array.items.len, 256);
    var argv: std.ArrayList([]const u8) = .empty;
    const cwd = try std.fs.path.resolve(a, &.{ self.workspace, try j.string(args, "cwd", ".") });
    const is_pty = try j.boolean(args, "is_pty", false);
    const job: Jobs.Job = .{ .id = id, .fingerprint = fingerprint, .description = try j.string(args, "description", ""), .cwd = cwd, .is_pty = is_pty };
    c.warnSize("process.spawn", "description bytes", job.description.len, 4096);
    c.warnSize("process.spawn", "working-directory bytes", cwd.len, 4096);
    try argv.appendSlice(a, &.{ "new-session", "--uid", id, "--json", "--cwd", cwd, "--is-pty", if (is_pty) "true" else "false", "--log", try jobs.path(a, id, "log"), "--status-path", try jobs.path(a, id, "status") });
    if (is_pty) try dimensions(c, "process.spawn", &argv, args);
    try argv.append(a, "--");
    var longest: usize = 0;
    for (command.array.items, 0..) |arg, i| {
        const text = try j.text(arg);
        if (i == 0 and text.len == 0) return error.InvalidArguments;
        longest = @max(longest, text.len);
        try argv.append(a, text);
    }
    c.warnSize("process.spawn", "longest argument bytes", longest, 4096);
    var environment = try self.environment.clone(a);
    defer environment.deinit();
    const overrides = j.get(args, "env");
    if (overrides != .null) {
        if (overrides != .object) return error.InvalidArguments;
        c.warnSize("process.spawn", "environment overrides", overrides.object.count(), 1024);
        var iterator = overrides.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.len == 0 or std.mem.indexOfAny(u8, entry.key_ptr.*, "=\x00") != null) return error.InvalidArguments;
            try environment.put(entry.key_ptr.*, try j.text(entry.value_ptr.*));
        }
    }
    try jobs.save(c, job);
    _ = try jobs.run(c, argv.items, &environment, true, null);
    return jobs.status(c, job);
}

fn dimensions(c: root.Context, operation: []const u8, argv: *std.ArrayList([]const u8), args: j.Value) !void {
    const columns = try j.integer(args, "columns", 80, 1, std.math.maxInt(u16));
    const rows = try j.integer(args, "rows", 24, 1, std.math.maxInt(u16));
    c.warnSize(operation, "terminal columns", columns, 500);
    c.warnSize(operation, "terminal rows", rows, 300);
    const a = c.allocator;
    try argv.appendSlice(a, &.{ "--cols", try std.fmt.allocPrint(a, "{d}", .{columns}), "--rows", try std.fmt.allocPrint(a, "{d}", .{rows}) });
}
