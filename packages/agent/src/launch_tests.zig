const std = @import("std");
const agent = @import("root.zig");
const j = @import("json.zig");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const ContextCodec = @import("LuauContextJournal.zig");
const services = @import("services");
const allow = "return function() return {allow=true} end";
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
const tool: agent.Capability = .{ .source_name = "fixture-source", .source = "return {name='sum',version=1,description='sum',parameters={type='object',properties={value={type='number'}},required={'value'}},endpoints={},recovery='never',execute=function(args) return args.value+1 end}" };
const catalog = [_]agent.CatalogCapability{.{ .name = "sum", .capability = tool }};

test {
    _ = @import("semantic_recovery_tests.zig");
    _ = @import("replay_validation_tests.zig");
    _ = @import("startup_publication_tests.zig");
    _ = @import("json.zig");
}

fn completed(request: *agent.Request) !agent.Outcome {
    try request.done.waitTimeout(std.testing.io, timeout);
    var outcome = try request.wait(std.testing.io);
    errdefer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    return outcome;
}

const Capture = struct {
    notices: std.atomic.Value(usize) = .init(0),
    observed: std.Io.Event = .unset,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *Capture = @ptrCast(@alignCast(raw.?));
        if (event == .notice) {
            _ = self.notices.fetchAdd(1, .acq_rel);
            self.observed.set(std.testing.io);
        }
    }
};

test "launch commits configured catalog once, preserves dynamic tools and executes after readiness" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "launch.gz" });
    defer a.free(journal_path);
    const controller = try agent.Controller.open(a, io, .{ .authorize = allow });
    defer controller.close();
    const config: agent.Config = .{ .session_id = "launch", .journal_path = journal_path, .application = .{ .source = "ctx.initializations=(ctx.initializations or 0)+1; ctx.configured=input.value; agent.checkpoint({configured=true}); return ctx.configured" } };
    const worker = try controller.launch(config, .{ .catalog = .{ .fixed = &catalog }, .initialize = .{ .input_json = "{\"value\":41}" }, .initialize_id = "configure-once" });
    var snapshot = try controller.inspect(worker, a);
    defer snapshot.deinit();
    try std.testing.expectEqual(41, j.get(j.get(snapshot.value, "ctx"), "configured").integer);
    try std.testing.expectEqual(1, j.get(snapshot.value, "capabilities").array.items.len);
    for (j.get(snapshot.value, "commands").array.items) |command| try std.testing.expectEqualStrings("completed", j.text(j.get(command, "status")));
    try controller.stop(worker);
    var journal = try Journal.open(a, io, journal_path, "launch", try Persistence.options(snapshot.allocator(), ContextCodec.default));
    try std.testing.expectEqual(@as(usize, 1), journal.transactions.items.len);
    journal.deinit();
    const prefix = try tmp.dir.readFileAlloc(io, "launch.gz", a, .limited(1024 * 1024));
    defer a.free(prefix);
    const preserved = try controller.launch(config, .{ .initialize = .{ .input_json = "{\"value\":41}" }, .initialize_id = "configure-once" });
    var restored = try controller.readContext(preserved, a);
    defer restored.deinit();
    try std.testing.expectEqual(1, j.get(restored.value, "initializations").integer);
    const request = try controller.submit(preserved, "real-execution", .{ .lua = "return tools.sum({value=41})" });
    defer request.deinit();
    var outcome = try completed(request);
    defer outcome.deinit();
    try std.testing.expectEqual(42, outcome.result.integer);
    try controller.stop(preserved);
    const appended = try tmp.dir.readFileAlloc(io, "launch.gz", a, .limited(1024 * 1024));
    defer a.free(appended);
    try std.testing.expect(appended.len > prefix.len);
    try std.testing.expectEqualSlices(u8, prefix, appended[0..prefix.len]);
    const removed = try controller.launch(config, .{ .catalog = .{ .fixed = &.{} } });
    var empty = try controller.inspect(removed, a);
    defer empty.deinit();
    try std.testing.expectEqual(0, j.get(empty.value, "capabilities").array.items.len);
}

test "recovered queued commands fail without execution and remain deduplicated after replacement" {
    const Session = @import("Session.zig");
    const Runtime = @import("Runtime.zig");
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "queued.gz" });
    defer a.free(journal_path);
    const source = "ctx.executions=(ctx.executions or 0)+1; return ctx.executions";
    {
        const interrupted = try Session.init(a, io, "queued", path, journal_path, "{}", j.array(a));
        defer interrupted.deinit();
        _ = try interrupted.run(1, 100);
        const payload = try Runtime.encodeCommand(a, .{ .lua = source });
        defer a.free(payload);
        try interrupted.admit("not-started", 4, payload);
        _ = try interrupted.run(1, 100);
        try std.testing.expectEqualStrings("queued", j.text(j.get(interrupted.command("not-started").?, "status")));
    }
    const controller = try agent.Controller.open(a, io, .{ .authorize = allow });
    defer controller.close();
    for (0..2) |_| {
        const worker = try controller.start(.{ .session_id = "queued", .journal_path = journal_path });
        const request = try controller.submit(worker, "not-started", .{ .lua = source });
        defer request.deinit();
        try request.done.waitTimeout(io, timeout);
        var outcome = try request.wait(io);
        defer outcome.deinit();
        try std.testing.expectEqual(.failed, outcome.status);
        try std.testing.expectEqualStrings("interrupted_not_started", j.text(j.get(outcome.diagnostic, "code")));
        var context = try controller.readContext(worker, a);
        defer context.deinit();
        try std.testing.expect(j.get(context.value, "executions") == .null);
        try controller.stop(worker);
    }
}

test "launch preserves recovered public queued work until private initialization is committed" {
    const Session = @import("Session.zig");
    const Runtime = @import("Runtime.zig");
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "queued.gz" });
    defer a.free(journal_path);
    const source = "ctx.recovered=ctx.configured+1; return ctx.recovered";
    const interrupted = try Session.init(a, io, "queued", path, journal_path, "{}", j.array(a));
    _ = try interrupted.run(1, 100);
    const payload = try Runtime.encodeCommand(a, .{ .lua = source });
    defer a.free(payload);
    try interrupted.admit("recovered-public", 4, payload);
    _ = try interrupted.run(1, 100);
    try std.testing.expectEqualStrings("queued", j.text(j.get(interrupted.command("recovered-public").?, "status")));
    interrupted.deinit();
    const controller = try agent.Controller.open(a, io, .{ .authorize = allow });
    defer controller.close();
    const worker = try controller.launch(.{ .session_id = "queued", .journal_path = journal_path, .recovery = .{ .queued = .@"resume" }, .application = .{ .source = "ctx.configured=input.value; agent.checkpoint({configured=true}); return true" } }, .{ .catalog = .{ .fixed = &catalog }, .initialize = .{ .input_json = "{\"value\":41}" } });
    const request = try controller.submit(worker, "recovered-public", .{ .lua = source });
    defer request.deinit();
    var outcome = try completed(request);
    defer outcome.deinit();
    try std.testing.expectEqual(42, outcome.result.integer);
}

test "launch uses real Worker command policy and denies registration delivery and rewrites without a snapshot" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "denied.gz" });
    defer a.free(journal_path);
    const config: agent.Config = .{ .session_id = "denied", .journal_path = journal_path, .application = .{ .source = "ctx.changed=true; agent.checkpoint({changed=true}); return true" } };
    const policies = [_][]const u8{
        "return function(e) return {allow=e.principal>0 and e.operation~='register_capability'} end",
        "return function(e) return {allow=e.principal>0 and e.operation~='deliver'} end",
        "return function(e) return {allow=true,operation=e.operation} end",
        "return function(e) return {allow=true,arguments=e.arguments} end",
    };
    for (policies) |policy| {
        var capture: Capture = .{};
        const controller = try agent.Controller.open(a, io, .{ .authorize = policy, .sink = .{ .context = &capture, .emit = Capture.emit } });
        try std.testing.expectError(error.PermissionDenied, controller.launch(config, .{ .catalog = .{ .fixed = &catalog }, .initialize = .{ .input_json = "{}" } }));
        controller.close();
        try std.testing.expectEqual(0, capture.notices.load(.acquire));
        try std.testing.expectEqual(0, (try tmp.dir.statFile(io, "denied.gz", .{})).size);
    }
    const controller = try agent.Controller.open(a, io, .{ .authorize = "return function(e) return {allow=e.principal>0} end" });
    defer controller.close();
    _ = try controller.launch(config, .{ .catalog = .{ .fixed = &catalog }, .initialize = .{ .input_json = "{}" } });
}

test "launch admits fresh Config seeds and fixed-catalog removals through outside policy" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const denied_seed = try agent.Controller.open(a, io, .{ .authorize = "return function(e) return {allow=e.operation~='register_capability'} end" });
    defer denied_seed.close();
    try std.testing.expectError(error.PermissionDenied, denied_seed.launch(.{ .session_id = "seed-policy", .persistence = .memory, .capabilities = &.{tool} }, .{}));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "removal.gz" });
    defer a.free(journal_path);
    const config: agent.Config = .{ .session_id = "removal-policy", .journal_path = journal_path };
    const seed = try agent.Controller.open(a, io, .{ .authorize = allow });
    _ = try seed.launch(config, .{ .catalog = .{ .fixed = &catalog } });
    seed.close();
    const prefix = try tmp.dir.readFileAlloc(io, "removal.gz", a, .limited(1024 * 1024));
    defer a.free(prefix);
    var capture: Capture = .{};
    const controller = try agent.Controller.open(a, io, .{ .authorize = "return function(e) return {allow=e.principal>0 and e.operation~='unregister_capability'} end", .sink = .{ .context = &capture, .emit = Capture.emit } });
    try std.testing.expectError(error.PermissionDenied, controller.launch(config, .{ .catalog = .{ .fixed = &.{} } }));
    controller.close();
    try std.testing.expectEqual(0, capture.notices.load(.acquire));
    const after = try tmp.dir.readFileAlloc(io, "removal.gz", a, .limited(1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, prefix, after);
}

var activation_gate: ?*ActivationGate = null;
const ActivationGate = struct {
    base: std.Io,
    armed: std.atomic.Value(bool) = .init(false),
    fail: bool = false,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
        const self = activation_gate.?;
        if (result_len == 0 and self.armed.swap(false, .acq_rel)) {
            self.entered.set(self.base);
            self.release.wait(self.base) catch self.base.recancel();
            if (self.fail) return error.ConcurrencyUnavailable;
        }
        return self.base.vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
    }
};

test "private activation rejects guessed-ID stop read and submit, joins close and removes failed activation once" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    for ([_]enum { publish, fail, close, cancel }{ .publish, .fail, .close, .cancel }) |mode| {
        var gate: ActivationGate = .{ .base = io, .fail = mode == .fail };
        activation_gate = &gate;
        defer activation_gate = null;
        var vtable = io.vtable.*;
        vtable.concurrent = ActivationGate.concurrent;
        const controlled: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        var capture: Capture = .{};
        const controller = try agent.Controller.open(a, controlled, .{ .authorize = allow, .sink = .{ .context = &capture, .emit = Capture.emit } });
        var closed = false;
        defer if (!closed) controller.close();
        const anchor = try controller.start(.{ .session_id = "activation-anchor", .persistence = .memory });
        try capture.observed.waitTimeout(io, timeout);
        try controller.stop(anchor);
        const notices = capture.notices.load(.acquire);
        gate.armed.store(true, .release);
        var task: LaunchTask = .{ .controller = controller, .config = .{ .session_id = "activating", .persistence = .memory } };
        var launch = try io.concurrent(LaunchTask.run, .{ &task, io });
        defer launch.await(io);
        defer gate.release.set(io);
        try gate.entered.waitTimeout(io, timeout);
        const guessed: agent.WorkerId = .{ .scope = anchor.scope, .index = anchor.index + 1 };
        try std.testing.expectError(error.WorkerStarting, controller.stop(guessed));
        try std.testing.expectError(error.WorkerStarting, controller.readContext(guessed, a));
        try std.testing.expectError(error.WorkerStarting, controller.submit(guessed, "too-soon", .{ .lua = "return true" }));
        try std.testing.expectEqual(notices, capture.notices.load(.acquire));
        if (mode == .cancel) {
            launch.cancel(io);
            try std.testing.expectError(error.Canceled, task.result);
            try std.testing.expectError(error.UnknownWorker, controller.stop(guessed));
            try std.testing.expectEqual(notices, capture.notices.load(.acquire));
        } else if (mode == .close) {
            controller.requestClose();
            var closer: CloseTask = .{ .controller = controller };
            var close = try io.concurrent(CloseTask.run, .{ &closer, io });
            try std.testing.expect(!closer.done.isSet());
            gate.release.set(io);
            try task.done.waitTimeout(io, timeout);
            try closer.done.waitTimeout(io, timeout);
            close.await(io);
            closed = true;
            try std.testing.expectError(error.ControllerClosed, task.result);
            try std.testing.expectEqual(notices, capture.notices.load(.acquire));
        } else {
            gate.release.set(io);
            try task.done.waitTimeout(io, timeout);
            if (mode == .fail) {
                try std.testing.expectError(error.ConcurrencyUnavailable, task.result);
                try std.testing.expectError(error.UnknownWorker, controller.stop(guessed));
                const successor = try controller.launch(task.config, .{});
                try std.testing.expect(successor.index > guessed.index);
                try controller.stop(successor);
            } else {
                const worker = try task.result;
                var context = try controller.readContext(worker, a);
                context.deinit();
                try controller.stop(worker);
            }
        }
    }
}

const BlockingAllocator = struct {
    io: std.Io,
    target: usize,
    armed: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(bool) = .init(false),
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    releases: std.atomic.Value(usize) = .init(0),
    var read_gate: ?*BlockingAllocator = null;
    var original_read: @TypeOf(std.testing.io.vtable.fileReadPositional) = undefined;
    fn read(raw: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        if (read_gate) |self| if (self.armed.swap(false, .acq_rel)) {
            self.active.store(true, .release);
            self.entered.set(self.io);
            self.release.waitUncancelable(self.io);
            self.active.store(false, .release);
        };
        return original_read(raw, file, data, offset);
    }
    fn allocator(self: *BlockingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BlockingAllocator = @ptrCast(@alignCast(raw));
        if (len == self.target and self.armed.swap(false, .acq_rel)) {
            self.active.store(true, .release);
            self.entered.set(self.io);
            self.release.waitUncancelable(self.io);
            self.active.store(false, .release);
        }
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        return std.testing.allocator.rawResize(memory, alignment, len, ra);
    }
    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(memory, alignment, len, ra);
    }
    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        std.testing.allocator.rawFree(memory, alignment, ra);
    }
    fn releaseService(raw: *anyopaque, _: services.Context) anyerror!void {
        const self: *BlockingAllocator = @ptrCast(@alignCast(raw));
        if (self.active.load(.acquire)) return error.PreparationStillBorrowing;
        _ = self.releases.fetchAdd(1, .acq_rel);
    }
};

const LaunchTask = struct {
    controller: *agent.Controller,
    config: agent.Config,
    startup: agent.Startup = .{},
    result: anyerror!agent.WorkerId = error.NotStarted,
    done: std.Io.Event = .unset,
    fn run(self: *LaunchTask, io: std.Io) void {
        self.result = self.controller.launch(self.config, self.startup);
        self.done.set(io);
    }
};
test "durable full catalog replaces a name at capacity and shrinks to one new executable tool" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", scratch);
    const journal_path = try std.fs.path.join(scratch, &.{ path, "capacity.gz" });
    const config: agent.Config = .{ .session_id = "capacity", .journal_path = journal_path };
    const Fixture = struct {
        fn definition(allocator: std.mem.Allocator, name: []const u8, result: usize) !agent.CatalogCapability {
            return .{ .name = name, .capability = .{ .source_name = name, .source = try std.fmt.allocPrint(allocator, "return {{name='{s}',version=1,description='fixture',parameters={{type='object'}},endpoints={{}},recovery='never',execute=function()return {d} end}}", .{ name, result }) } };
        }
    };
    var original: [64]agent.CatalogCapability = undefined;
    for (&original, 0..) |*entry, index| entry.* = try Fixture.definition(scratch, try std.fmt.allocPrint(scratch, "old{d}", .{index}), index);
    const controller = try agent.Controller.open(a, io, .{ .authorize = allow });
    defer controller.close();
    const first = try controller.launch(config, .{ .catalog = .{ .fixed = &original } });
    try controller.stop(first);
    var prefix = try tmp.dir.readFileAlloc(io, "capacity.gz", scratch, .limited(4 * 1024 * 1024));
    var desired = original;
    desired[0] = try Fixture.definition(scratch, "replacement", 777);
    const singleton = [_]agent.CatalogCapability{try Fixture.definition(scratch, "only", 888)};
    for ([_][]const agent.CatalogCapability{ &desired, &singleton }, [_][]const u8{ "return tools.replacement({})", "return tools.only({})" }, [_]u64{ 777, 888 }) |catalog_plan, source, expected| {
        const worker = try controller.launch(config, .{ .catalog = .{ .fixed = catalog_plan } });
        var snapshot = try controller.inspect(worker, a);
        defer snapshot.deinit();
        const installed = j.get(snapshot.value, "capabilities").array.items;
        try std.testing.expectEqual(catalog_plan.len, installed.len);
        for (catalog_plan) |entry| {
            var matches: usize = 0;
            for (installed) |actual| if (std.mem.eql(u8, entry.name, j.text(j.get(actual, "name")))) {
                matches += 1;
            };
            try std.testing.expectEqual(1, matches);
        }
        const request = try controller.submit(worker, try std.fmt.allocPrint(scratch, "execute-{d}", .{expected}), .{ .lua = source });
        defer request.deinit();
        var outcome = try completed(request);
        defer outcome.deinit();
        try std.testing.expectEqual(expected, j.number(outcome.result));
        try controller.stop(worker);
        const appended = try tmp.dir.readFileAlloc(io, "capacity.gz", scratch, .limited(4 * 1024 * 1024));
        try std.testing.expect(appended.len > prefix.len);
        try std.testing.expectEqualSlices(u8, prefix, appended[0..prefix.len]);
        prefix = appended;
    }
}

test "catalog beyond former tool ceiling remains private and infinite initialization fails closed" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var capture: Capture = .{};
    const controller = try agent.Controller.open(a, io, .{ .authorize = allow, .sink = .{ .context = &capture, .emit = Capture.emit } });
    defer controller.close();
    var desired: [96]agent.CatalogCapability = undefined;
    for (&desired, 0..) |*entry, index| {
        const name = try std.fmt.allocPrint(scratch, "tool{d}", .{index});
        entry.* = .{ .name = name, .capability = .{ .source_name = name, .source = try std.fmt.allocPrint(scratch, "return {{name='{s}',version=1,description='fixture',parameters={{type='object'}},endpoints={{}},recovery='never',execute=function()return 1 end}}", .{name}) } };
    }
    const worker = try controller.launch(.{ .session_id = "maximum-catalog", .persistence = .memory }, .{ .catalog = .{ .fixed = &desired } });
    var snapshot = try controller.inspect(worker, a);
    defer snapshot.deinit();
    try std.testing.expectEqual(96, j.get(snapshot.value, "capabilities").array.items.len);
    for (j.get(snapshot.value, "commands").array.items) |command| try std.testing.expectEqualStrings("completed", j.text(j.get(command, "status")));
    try controller.stop(worker);
    try capture.observed.waitTimeout(io, timeout);
    const notices = capture.notices.load(.acquire);
    var task: LaunchTask = .{ .controller = controller, .config = .{ .session_id = "infinite", .persistence = .memory, .application = .{ .source = "while true do end" } }, .startup = .{ .initialize = .{ .input_json = "{}" } } };
    var launch = try io.concurrent(LaunchTask.run, .{ &task, io });
    defer launch.await(io);
    task.done.waitTimeout(io, timeout) catch |err| {
        controller.requestClose();
        return err;
    };
    try std.testing.expectError(error.LimitExceeded, task.result);
    try std.testing.expectEqual(notices, capture.notices.load(.acquire));
    const successor = try controller.launch(.{ .session_id = "record-limit", .persistence = .memory }, .{});
    try controller.stop(successor);
}

const CloseTask = struct {
    controller: *agent.Controller,
    done: std.Io.Event = .unset,
    fn run(self: *CloseTask, io: std.Io) void {
        self.controller.close();
        self.done.set(io);
    }
};

test "close joins either outstanding preparation job before releasing borrowed service and sink contexts" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const journal_path = try std.fs.path.join(a, &.{ path, "joined.gz" });
    defer a.free(journal_path);
    const config: agent.Config = .{ .session_id = "joined", .journal_path = journal_path };
    const seed = try agent.Controller.open(a, io, .{ .authorize = allow });
    _ = try seed.launch(config, .{});
    seed.close();
    const prefix = try tmp.dir.readFileAlloc(io, "joined.gz", a, .limited(1024 * 1024));
    defer a.free(prefix);
    for ([_]bool{ false, true }) |block_read| {
        var blocking: BlockingAllocator = .{ .io = io, .target = 0 };
        const budget = try agent.MemoryBudget.create(blocking.allocator(), agent.default_memory_bytes);
        defer budget.release();
        const base = budget.usage().used;
        const probe = try budget.allocator().create(@import("Session.zig"));
        const charged_size = budget.usage().used - base;
        budget.allocator().destroy(probe);
        blocking.target = if (block_read) 0 else charged_size;
        var vtable = io.vtable.*;
        BlockingAllocator.original_read = io.vtable.fileReadPositional;
        BlockingAllocator.read_gate = if (block_read) &blocking else null;
        defer BlockingAllocator.read_gate = null;
        if (block_read) vtable.fileReadPositional = BlockingAllocator.read;
        const backend: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        var capture: Capture = .{};
        const controller = try agent.Controller.open(budget.allocator(), backend, .{ .authorize = allow, .services = &.{.{ .context = &blocking, .operations = &.{}, .release = BlockingAllocator.releaseService }}, .sink = .{ .context = &capture, .emit = Capture.emit } });
        blocking.armed.store(true, .release);
        var task: LaunchTask = .{ .controller = controller, .config = config };
        var launch = try io.concurrent(LaunchTask.run, .{ &task, io });
        defer launch.await(io);
        defer blocking.release.set(io);
        try blocking.entered.waitTimeout(io, timeout);
        controller.requestClose();
        var closer: CloseTask = .{ .controller = controller };
        var close = try io.concurrent(CloseTask.run, .{ &closer, io });
        try std.testing.expect(!closer.done.isSet());
        try std.testing.expectEqual(0, blocking.releases.load(.acquire));
        blocking.release.set(io);
        try task.done.waitTimeout(io, timeout);
        try closer.done.waitTimeout(io, timeout);
        close.await(io);
        try std.testing.expectError(error.ControllerClosed, task.result);
        try std.testing.expectEqual(1, blocking.releases.load(.acquire));
        try std.testing.expectEqual(0, capture.notices.load(.acquire));
        const after = try tmp.dir.readFileAlloc(io, "joined.gz", a, .limited(1024 * 1024));
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, prefix, after);
    }
}
