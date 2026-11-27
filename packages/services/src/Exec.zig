const std = @import("std");
const root = @import("root.zig");
const j = root.json;
const Self = @This();
pub const Shutdown = enum(u8) { terminate, detach };
pub const Args = struct {
    argv: []const []const u8,
    cwd: []const u8 = ".",
    timeout_ms: ?u64 = null,
    environment: ?j.Value = null,
    pub fn validate(self: Args) !void {
        if (self.argv.len == 0) return error.InvalidArguments;
        for (self.argv) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArguments;
        if (std.mem.indexOfScalar(u8, self.cwd, 0) != null) return error.InvalidArguments;
        if (self.timeout_ms == 0) return error.InvalidArguments;
        if (self.environment) |env| {
            if (env != .object) return error.InvalidArguments;
            var entries = env.object.iterator();
            while (entries.next()) |entry| {
                if (entry.key_ptr.len == 0 or std.mem.indexOfAny(u8, entry.key_ptr.*, "=\x00") != null) return error.InvalidArguments;
                _ = try j.text(entry.value_ptr.*);
            }
        }
    }
};
pub const Result = struct { output_path: []const u8, exit_code: u32, timed_out: bool, output: root.output.Result };
const Receipt = struct {
    output_path: []const u8,
    exit_code: u32,
    timed_out: bool,
    output_bytes: ?u64 = null,
    output: ?root.output.Result = null,
};
pub const operation = root.Operation.defineJson("process.exec", Args, Result, .{ .arguments = 1024 * 1024, .result = 512 * 1024 }, .receipt, dispatch);
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn prctl(c_int, c_ulong, c_ulong, c_ulong, c_ulong) c_int;

directory: []const u8,
environment: *const std.process.Environ.Map,
descendants: std.Io.Group = .init,
shutdown: std.atomic.Value(Shutdown) = .init(.terminate),
observation_allocator: ?std.mem.Allocator = null,
observation_mutex: std.Io.Mutex = .init,
running: std.ArrayList(Running) = .empty,
pub const ObservationOwner = struct {
    scope: u64,
    principal: u64,
    request_id: []const u8,
};
const Running = struct { file: std.Io.File, path: []const u8, started_ms: i64, owner: ObservationOwner };
pub const Observation = struct { output: []const u8, bytes: u64, elapsed_ms: i64 };

fn track(self: *Self, context: root.Context, file: std.Io.File, path: []const u8, started_ms: i64) bool {
    const a = self.observation_allocator orelse return false;
    const io = context.io;
    self.observation_mutex.lockUncancelable(io);
    defer self.observation_mutex.unlock(io);
    self.running.ensureUnusedCapacity(a, 1) catch return false;
    const request_id = a.dupe(u8, context.request_id) catch return false;
    self.running.appendAssumeCapacity(.{
        .file = file,
        .path = path,
        .started_ms = started_ms,
        .owner = .{ .scope = context.scope, .principal = context.principal, .request_id = request_id },
    });
    return true;
}
fn untrack(self: *Self, io: std.Io, path: []const u8) void {
    self.observation_mutex.lockUncancelable(io);
    defer self.observation_mutex.unlock(io);
    for (self.running.items, 0..) |item, index| if (std.mem.eql(u8, path, item.path)) {
        const removed = self.running.swapRemove(index);
        self.observation_allocator.?.free(removed.owner.request_id);
        return;
    };
}
/// Copy at most four 2-KiB tails under the descriptor-lifetime lock. Positional
/// reads do not move process output offsets and never dispatch an operation.
pub fn observe(self: *Self, a: std.mem.Allocator, io: std.Io) ![]const Observation {
    self.observation_mutex.lockUncancelable(io);
    defer self.observation_mutex.unlock(io);
    var observations: std.ArrayList(Observation) = .empty;
    errdefer {
        for (observations.items) |item| a.free(item.output);
        observations.deinit(a);
    }
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    for (self.running.items[0..@min(self.running.items.len, 4)]) |item| {
        try observations.ensureUnusedCapacity(a, 1);
        observations.appendAssumeCapacity(try snapshot(a, io, item, now, 2048) orelse continue);
    }
    return observations.toOwnedSlice(a);
}

/// Observe one unambiguous running process owned by the admitted request.
pub fn observeRequest(self: *Self, a: std.mem.Allocator, io: std.Io, owner: ObservationOwner, max_bytes: usize) !?Observation {
    if (owner.request_id.len == 0) return null;
    self.observation_mutex.lockUncancelable(io);
    defer self.observation_mutex.unlock(io);
    var match: ?Running = null;
    for (self.running.items) |item| {
        if (item.owner.scope != owner.scope or item.owner.principal != owner.principal or
            !std.mem.eql(u8, item.owner.request_id, owner.request_id)) continue;
        if (match != null) return null;
        match = item;
    }
    const item = match orelse return null;
    return snapshot(a, io, item, std.Io.Clock.awake.now(io).toMilliseconds(), max_bytes);
}

fn snapshot(a: std.mem.Allocator, io: std.Io, item: Running, now: i64, max_bytes: usize) !?Observation {
    const size = (item.file.stat(io) catch return null).size;
    const length: usize = @intCast(@min(size, max_bytes));
    const buffer = try a.alloc(u8, length);
    defer a.free(buffer);
    const n = item.file.readPositional(io, &.{buffer}, size - length) catch return null;
    return .{ .output = try a.dupe(u8, buffer[0..n]), .bytes = size, .elapsed_ms = now - item.started_ms };
}

pub fn deinit(self: *Self, io: std.Io, policy: Shutdown) void {
    self.shutdown.store(policy, .release);
    self.descendants.cancel(io);
    self.observation_mutex.lockUncancelable(io);
    defer self.observation_mutex.unlock(io);
    std.debug.assert(self.running.items.len == 0);
    if (self.observation_allocator) |a| self.running.deinit(a);
}

pub fn service(self: *Self) root.Service {
    return .{ .context = self, .operations = &.{&operation} };
}

pub const InteractiveResult = struct {
    output: []const u8 = "",
    output_bytes: u64 = 0,
    exit_code: ?u32 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
};

/// For a host that has already admitted a user command. Uses the ordinary
/// process-group lifetime and gives the caller a bounded tail after cancellation.
pub fn captureInteractive(self: *Self, c: root.Context, args: Args) !InteractiveResult {
    try args.validate();
    const a = c.allocator;
    const encoded = try j.value(a, args);
    const value = self.dispatchCapture(c, encoded, .tail) catch |err| {
        if (err != error.Canceled) return err;
        const protection = c.io.swapCancelProtection(.blocked);
        defer _ = c.io.swapCancelProtection(protection);
        const hash = j.hash(c.idempotency_key);
        const path = try std.fmt.allocPrint(a, "{s}/{s}.log", .{ self.directory, hash });
        const file = std.Io.Dir.cwd().openFile(c.io, path, .{}) catch |open_err| {
            if (open_err == error.FileNotFound) return .{ .cancelled = true };
            return open_err;
        };
        defer file.close(c.io);
        const output = try root.output.readTail(a, c.io, file, (try file.stat(c.io)).size);
        return .{ .output = output.content, .output_bytes = output.totalBytes, .cancelled = true, .truncated = output.truncated, .full_output_path = path };
    };
    const result = try std.json.parseFromValueLeaky(Result, a, value, .{});
    return .{
        .output = result.output.content,
        .output_bytes = result.output.totalBytes,
        .exit_code = result.exit_code,
        .truncated = result.output.truncated,
        .full_output_path = result.output_path,
    };
}

const Capture = enum { full, tail };

fn dispatch(pointer: *anyopaque, c: root.Context, _: []const u8, args: j.Value) !j.Value {
    const self: *Self = @ptrCast(@alignCast(pointer));
    return self.dispatchCapture(c, args, .full);
}

fn dispatchCapture(self: *Self, c: root.Context, args: j.Value, capture: Capture) !j.Value {
    if (c.idempotency_key.len == 0 or !std.fs.path.isAbsolute(self.directory)) return error.InvalidArguments;
    c.warnSize("process.exec", "idempotency key bytes", c.idempotency_key.len, 1024);
    const a = c.allocator;
    const io = c.io;
    const argv_value = j.get(args, "argv");
    if (argv_value != .array or argv_value.array.items.len == 0) return error.InvalidArguments;
    c.warnSize("process.exec", "argument count", argv_value.array.items.len, 1024);
    const argv = try a.alloc([]const u8, argv_value.array.items.len);
    var longest: usize = 0;
    for (argv_value.array.items, argv) |value, *arg| {
        arg.* = try j.text(value);
        longest = @max(longest, arg.len);
    }
    c.warnSize("process.exec", "longest argument bytes", longest, 65536);
    const cwd = try j.string(args, "cwd", ".");
    c.warnSize("process.exec", "working-directory bytes", cwd.len, 4096);
    const timeout = j.get(args, "timeout_ms");
    if (timeout != .null and (timeout != .integer or timeout.integer <= 0)) return error.InvalidArguments;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var it = self.environment.iterator();
    while (it.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
    const overrides = j.get(args, "environment");
    if (overrides != .null) {
        if (overrides != .object) return error.InvalidArguments;
        c.warnSize("process.exec", "environment overrides", overrides.object.count(), 1024);
        var entries = overrides.object.iterator();
        while (entries.next()) |entry| {
            if (std.mem.indexOfScalar(u8, entry.key_ptr.*, 0) != null or std.mem.indexOfScalar(u8, entry.key_ptr.*, '=') != null) return error.InvalidArguments;
            try env.put(entry.key_ptr.*, try j.text(entry.value_ptr.*));
        }
    }
    try std.Io.Dir.cwd().createDirPath(io, self.directory);
    const key = j.hash(c.idempotency_key);
    const encoded = try j.encode(a, args);
    const fingerprint = j.hash(encoded);
    const intent_path = try std.fmt.allocPrint(a, "{s}/{s}.intent", .{ self.directory, key });
    const result_path = try std.fmt.allocPrint(a, "{s}/{s}.result", .{ self.directory, key });
    const output_path = try std.fmt.allocPrint(a, "{s}/{s}.log", .{ self.directory, key });
    const intent = std.Io.Dir.cwd().createFile(io, intent_path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const old = try std.Io.Dir.cwd().readFileAlloc(io, intent_path, a, .unlimited);
        c.warnSize("process.exec", "intent bytes", old.len, 1024);
        if (!std.mem.eql(u8, old, &fingerprint)) return error.RequestConflict;
        const completed = std.Io.Dir.cwd().readFileAlloc(io, result_path, a, .unlimited) catch return error.IndeterminateExecution;
        c.warnSize("process.exec", "receipt bytes", completed.len, 1024 * 1024);
        const receipt = try std.json.parseFromValueLeaky(Receipt, a, try j.parse(a, completed), .{});
        return receiptResult(c, receipt, null, capture);
    };
    defer intent.close(io);
    try intent.writePositionalAll(io, &fingerprint, 0);
    try intent.sync(io);
    var directory = try std.Io.Dir.cwd().openDir(io, self.directory, .{ .iterate = true });
    defer directory.close(io);
    try syncDirectory(directory);
    const output = try std.Io.Dir.cwd().createFile(io, output_path, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) });
    defer output.close(io);
    if (@import("builtin").os.tag == .linux and prctl(36, 1, 0, 0, 0) != 0) return error.SubreaperUnavailable;
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = &env, .stdin = .ignore, .stdout = .{ .file = output }, .stderr = .{ .file = output }, .pgid = 0 });
    const pid = child.id.?;
    var finished = false;
    defer if (!finished) {
        _ = cleanup(io, &child, pid);
    };
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const tracked = self.track(c, output, output_path, started);
    defer if (tracked) self.untrack(io, output_path);
    var status: c_int = 0;
    var timed_out = false;
    while (true) {
        try io.checkCancel();
        const waited = waitpid(pid, &status, 1);
        if (waited == pid) {
            child.id = null;
            if (try descendantsPending(pid)) try self.descendants.concurrent(io, reapDescendants, .{ self, io, pid });
            finished = true;
            break;
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            return error.ChildWaitFailed;
        }
        if (timeout == .integer and std.Io.Clock.awake.now(io).toMilliseconds() - started >= timeout.integer) {
            timed_out = true;
            status = cleanup(io, &child, pid) orelse return error.ChildWaitFailed;
            finished = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    const code: u32 = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else 128 + @as(u32, @intCast(status & 0x7f));
    const saved = blk: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const metadata: Receipt = .{
            .output_path = output_path,
            .exit_code = code,
            .timed_out = timed_out,
            .output_bytes = (try output.stat(io)).size,
        };
        try output.sync(io);
        try syncDirectory(directory);
        const receipt = try std.Io.Dir.cwd().createFile(io, result_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer receipt.close(io);
        try receipt.writePositionalAll(io, try j.encode(a, metadata), 0);
        try receipt.sync(io);
        try syncDirectory(directory);
        break :blk metadata;
    };
    return receiptResult(c, saved, output, capture);
}

fn receiptResult(c: root.Context, saved: Receipt, open_file: ?std.Io.File, capture: Capture) !j.Value {
    const captured = saved.output orelse blk: {
        const file = open_file orelse try std.Io.Dir.cwd().openFile(c.io, saved.output_path, .{});
        defer if (open_file == null) file.close(c.io);
        if (capture == .tail) break :blk try root.output.readTail(c.allocator, c.io, file, saved.output_bytes orelse (try file.stat(c.io)).size);
        break :blk if (saved.output_bytes) |size|
            try root.output.readSnapshot(c.allocator, c.io, file, size)
        else
            try root.output.read(c.allocator, c.io, file);
    };
    if (capture == .full) {
        c.warnSize("process.exec", "output bytes", captured.totalBytes, root.output.expected_bytes);
        c.warnSize("process.exec", "output lines", captured.totalLines, root.output.expected_lines);
    }
    return j.value(c.allocator, Result{
        .output_path = saved.output_path,
        .exit_code = saved.exit_code,
        .timed_out = saved.timed_out,
        .output = captured,
    });
}

fn descendantsPending(pid: std.posix.pid_t) !bool {
    var status: c_int = 0;
    while (true) {
        const result = waitpid(-pid, &status, 1);
        if (result > 0) continue;
        if (result == 0) return true;
        switch (std.posix.errno(result)) {
            .INTR => continue,
            .CHILD => return false,
            else => return error.ChildWaitFailed,
        }
    }
}

fn reapDescendants(self: *Self, io: std.Io, pid: std.posix.pid_t) std.Io.Cancelable!void {
    var finished = false;
    defer if (!finished and self.shutdown.load(.acquire) == .terminate) terminateGroup(io, pid);
    while (descendantsPending(pid) catch return) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    finished = true;
}

fn terminateGroup(io: std.Io, pid: std.posix.pid_t) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    std.posix.kill(-pid, .KILL) catch {};
    if (@import("builtin").os.tag == .linux) {
        var status: c_int = 0;
        while (true) {
            const result = waitpid(-pid, &status, 0);
            if (result > 0) continue;
            if (result < 0 and std.posix.errno(result) == .INTR) continue;
            break;
        }
    }
}

fn cleanup(io: std.Io, child: *std.process.Child, pid: std.posix.pid_t) ?c_int {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    std.posix.kill(-pid, .KILL) catch {};
    var status: c_int = 0;
    var leader_status: ?c_int = null;
    if (child.id != null) {
        while (true) {
            const result = waitpid(pid, &status, 0);
            if (result == pid) {
                child.id = null;
                leader_status = status;
                break;
            }
            if (result < 0 and std.posix.errno(result) == .INTR) continue;
            child.kill(io);
            break;
        }
    }
    terminateGroup(io, pid);
    return leader_status;
}

test "Exec keyed intent deduplicates and cancellation reaps its process group" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var exec: Self = .{ .directory = dir, .environment = &environment };
    defer exec.deinit(io, .terminate);
    var registry = root.Registry.init(a);
    defer registry.deinit();
    try registry.add(exec.service());
    const args = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "echo once >> count; printf merged; printf err >&2" }, .cwd = dir });
    const context: root.Context = .{ .allocator = a, .io = io, .idempotency_key = "once" };
    const first = try registry.dispatch(context, "process.exec", args);
    _ = try registry.dispatch(context, "process.exec", args);
    try std.testing.expectEqualStrings("once\n", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
    try std.testing.expectEqualStrings("mergederr", try std.Io.Dir.cwd().readFileAlloc(io, try j.text(j.get(first, "output_path")), a, .limited(100)));
    const hanging = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "echo $$ > leader; /bin/sleep 30 & echo $! > descendant; wait" }, .cwd = dir });
    var future = try io.concurrent(root.Registry.dispatch, .{ &registry, root.Context{ .allocator = a, .io = io, .idempotency_key = "cancel" }, "process.exec", hanging });
    var child_pid: std.posix.pid_t = 0;
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const bytes = tmp.dir.readFileAlloc(io, "descendant", a, .limited(100)) catch |err| {
            if (err != error.FileNotFound) return err;
            try std.Io.sleep(io, .fromMilliseconds(5), .awake);
            continue;
        };
        if (bytes.len == 0) continue;
        child_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, "\n"), 10);
        break;
    }
    try std.testing.expect(child_pid > 0);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(child_pid, @fromBackingInt(@intCast(0))));
    try std.testing.expectError(error.IndeterminateExecution, registry.dispatch(.{ .allocator = a, .io = io, .idempotency_key = "cancel" }, "process.exec", hanging));
}

test "live observations are bounded owned snapshots and cancellation retires descriptors" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var exec: Self = .{ .directory = dir, .environment = &environment, .observation_allocator = std.testing.allocator };
    defer exec.deinit(io, .terminate);
    var registry = root.Registry.init(a);
    defer registry.deinit();
    try registry.add(exec.service());
    const args = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "printf '%05000d' 0; printf progress; /bin/sleep 30" }, .cwd = dir });
    var future = try io.concurrent(root.Registry.dispatch, .{ &registry, root.Context{ .allocator = a, .io = io, .idempotency_key = "observe" }, "process.exec", args });
    var joined = false;
    defer if (!joined) {
        _ = future.cancel(io) catch {};
    };
    var observed = false;
    for (0..400) |_| {
        const snapshots = try exec.observe(std.testing.allocator, io);
        defer {
            for (snapshots) |item| std.testing.allocator.free(item.output);
            std.testing.allocator.free(snapshots);
        }
        if (snapshots.len != 0 and snapshots[0].bytes >= 5008) {
            try std.testing.expect(snapshots[0].output.len <= 2048);
            try std.testing.expect(std.mem.endsWith(u8, snapshots[0].output, "progress"));
            observed = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(observed);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    joined = true;
    const empty = try exec.observe(std.testing.allocator, io);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.IndeterminateExecution, registry.dispatch(.{ .allocator = a, .io = io, .idempotency_key = "observe" }, "process.exec", args));
}

fn syncDirectory(directory: std.Io.Dir) !void {
    while (true) switch (std.posix.errno(std.posix.system.fsync(directory.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.DirectorySyncFailed,
    };
}

test "Exec timeout receipt reports the killed leader status" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var exec: Self = .{ .directory = dir, .environment = &environment };
    defer exec.deinit(io, .terminate);
    var registry = root.Registry.init(a);
    defer registry.deinit();
    try registry.add(exec.service());
    const args = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "printf retained; /bin/sleep 30 & wait" }, .cwd = dir, .timeout_ms = 50 });
    const c: root.Context = .{ .allocator = a, .io = io, .idempotency_key = "timeout" };
    const result = try registry.dispatch(c, "process.exec", args);
    try std.testing.expect(j.get(result, "timed_out").bool);
    try std.testing.expectEqual(@as(i64, 137), j.get(result, "exit_code").integer);
    const repeated = try registry.dispatch(c, "process.exec", args);
    try std.testing.expectEqual(@as(i64, 137), j.get(repeated, "exit_code").integer);
    try std.testing.expectEqualStrings("retained", try std.Io.Dir.cwd().readFileAlloc(io, try j.text(j.get(result, "output_path")), a, .limited(100)));
}

test "Exec owns descendant shutdown without stealing other child statuses or keys" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var exec: Self = .{ .directory = dir, .environment = &environment };
    defer exec.deinit(io, .terminate);
    var registry = root.Registry.init(a);
    defer registry.deinit();
    try registry.add(exec.service());
    var unrelated = try std.process.spawn(io, .{ .argv = &.{ "/bin/bash", "-c", "sleep 0.1; exit 23" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer unrelated.kill(io);
    const background = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "/bin/sleep 30 & echo $! > descendant" }, .cwd = dir });
    _ = try registry.dispatch(.{ .allocator = a, .io = io, .idempotency_key = "survivor" }, "process.exec", background);
    const bytes = try tmp.dir.readFileAlloc(io, "descendant", a, .limited(100));
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, "\n"), 10);
    const timeout = try j.value(a, .{ .argv = .{ "/bin/sleep", "30" }, .cwd = dir, .timeout_ms = 50 });
    _ = try registry.dispatch(.{ .allocator = a, .io = io, .idempotency_key = "other-timeout" }, "process.exec", timeout);
    try std.posix.kill(pid, @fromBackingInt(0));
    const distinct = try j.value(a, .{ .argv = .{ "/bin/bash", "-c", "echo tick >> count; sleep 0.1" }, .cwd = dir });
    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var first = try io.concurrent(root.Registry.dispatch, .{ &registry, root.Context{ .allocator = first_arena.allocator(), .io = io, .idempotency_key = "distinct-one" }, "process.exec", distinct });
    defer _ = first.cancel(io) catch {};
    var second = try io.concurrent(root.Registry.dispatch, .{ &registry, root.Context{ .allocator = second_arena.allocator(), .io = io, .idempotency_key = "distinct-two" }, "process.exec", distinct });
    defer _ = second.cancel(io) catch {};
    _ = try first.await(io);
    _ = try second.await(io);
    try std.testing.expectEqualStrings("tick\ntick\n", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
    exec.deinit(io, .terminate);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @fromBackingInt(0)));
    const term = try unrelated.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 23), term.exited);
}
