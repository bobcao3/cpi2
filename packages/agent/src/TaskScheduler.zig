//! The journal owns task state. This driver owns only the native invocations,
//! their borrows, and wakeups. A handler must use cancellable I/O and join any
//! work it starts before returning.
const std = @import("std");
const j = @import("json.zig");
const graph = @import("TaskJournal.zig");
const controller = @import("Controller.zig");
const Self = @This();
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = j.Value;

pub const Invocation = struct {
    pub const Dependency = struct { id: []const u8, outcome: graph.Outcome };
    allocator: Allocator,
    io: Io,
    id: []const u8,
    conversation: []const u8,
    attempt: u64,
    restarts: u32 = 0,
    input: Value,
    checkpoint: Value,
    interrupted: bool,
    abort_reason: ?graph.AbortReason,
    dependencies: []const Dependency,
    driver: *Self,

    /// Read this conversation's selected transcript at a committed journal cut.
    pub fn transcript(self: Invocation, cut: ?u64) !j.Document {
        return self.driver.readTranscript(self.allocator, self.conversation, cut);
    }

    /// Return an invocation-owned snapshot of one of this task's documents.
    pub fn document(self: Invocation, address: graph.Document.Address) !?graph.Document.Snapshot {
        return self.driver.readDocument(self.allocator, self.id, address);
    }

    /// Commit before doing more work in the same phase. To commit with a
    /// checkpoint, wait, or result, return the edits in the phase's Step.
    pub fn commitDocuments(self: Invocation, edits: []const graph.Document.Edit) !void {
        if (edits.len == 0) return;
        try self.io.checkCancel();
        try self.driver.commit(.{ .documents = .{ .lease = .{ .id = self.id, .attempt = self.attempt }, .edits = edits } });
    }

    /// Store the first candidate before returning it to the phase.
    pub fn memo(self: Invocation, key: []const u8, candidate: Value) !Value {
        try self.driver.commit(.{ .memo = .{
            .lease = .{ .id = self.id, .attempt = self.attempt },
            .key = key,
            .value = candidate,
        } });
        var saved = try self.driver.snapshot(self.driver.gpa);
        defer saved.deinit();
        const task = j.get(graph.taskValues(j.get(saved.value, "value")), self.id);
        return j.copy(self.allocator, j.get(j.get(task, "memos"), key));
    }
};
pub const Handler = *const fn (?*anyopaque, Invocation) anyerror!graph.Step;
pub const Definition = struct {
    kind: []const u8,
    version: u32 = 1,
    context: ?*anyopaque = null,
    /// Optional checkpoint constructor for hosts that instantiate this kind.
    /// It can be called again if task admission has not committed.
    initial: ?*const fn (?*anyopaque, Allocator, Value) anyerror!Value = null,
    run: Handler,
    /// A cut-off invocation is ambiguous even after a graceful close. Supply
    /// a reconciler, or opt into replay only for safe or keyed effects.
    recover_invocation: ?Handler = null,
    replay_safe: bool = false,
    /// The handler can distinguish durable progress from repeated interruptions.
    manages_restarts: bool = false,
    /// A known definition can wait for its host to attach a runtime context.
    /// Call notify when readiness changes. The predicate must not block.
    ready: ?*const fn (?*anyopaque) bool = null,
    ready_in_conversation: ?*const fn (?*anyopaque, []const u8) bool = null,
    ready_task: ?*const fn (?*anyopaque, []const u8, Value) bool = null,
    cleanup: ?Handler = null,
    migrate: ?*const fn (?*anyopaque, Allocator, u32, Value, Value) anyerror!Value = null,
};
pub const Wake = struct { active: bool = false, at: ?u64 = null };
pub const WakeSink = struct {
    context: ?*anyopaque = null,
    /// Called off the Worker line after a committed change. Return promptly.
    /// The sink may read wake state or call resumeScheduling to kick the driver.
    notify: *const fn (?*anyopaque, Wake) anyerror!void,
};
pub const Settings = struct {
    concurrency: usize = 4,
    restart_limit: ?u32 = 5,
    start_paused: bool = false,
    /// When set, the host arms the alarm and calls resumeScheduling at the deadline.
    on_wake: ?WakeSink = null,
};

const Job = struct {
    scheduler: *Self,
    arena: std.heap.ArenaAllocator,
    request: Invocation,
    mode: graph.Mode,
    callback: ?Handler,
    context: ?*anyopaque,
    fallback: graph.Outcome,
    wake: Io.Event = .unset,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: Io.Future(anyerror!graph.Step) = undefined,

    fn execute(self: *Job) anyerror!graph.Step {
        defer self.wake.set(self.scheduler.io);
        if (self.callback) |handler| return handler(self.context, self.request);
        return .{ .next = .{ .finish = self.fallback } };
    }

    fn own(self: *Job) anyerror!graph.Step {
        const io = self.scheduler.io;
        defer {
            self.done.store(true, .release);
            self.scheduler.signal();
        }
        if (self.cancel_requested.load(.acquire)) return error.Canceled;
        var invocation = try io.concurrent(execute, .{self});
        self.wake.waitUncancelable(io);
        return if (self.cancel_requested.load(.acquire)) invocation.cancel(io) else invocation.await(io);
    }

    fn requestCancel(self: *Job) void {
        if (!self.cancel_requested.swap(true, .acq_rel)) self.wake.set(self.scheduler.io);
    }
};

gpa: Allocator,
io: Io,
gateway: *controller.Controller,
worker: controller.WorkerId,
definitions: std.StringHashMapUnmanaged(Definition) = .empty,
settings: Settings,
future: Io.Future(void) = undefined,
mutex: Io.Mutex = .init,
admission: Io.Mutex = .init,
change: Io.Condition = .init,
generation: u64 = 0,
enabled: std.atomic.Value(bool) = .init(true),
closing: bool = false,
failure: ?anyerror = null,
jobs: std.ArrayList(*Job) = .empty,

/// The harness owns the gateway, worker, definitions, and callback contexts
/// until close returns. Attach the driver before admitting task activity.
pub fn start(gpa: Allocator, io: Io, gateway: *controller.Controller, worker: controller.WorkerId, definitions: []const Definition, settings: Settings) !*Self {
    if (settings.concurrency == 0) return error.InvalidTaskSettings;
    for (definitions, 0..) |def, i| {
        if (def.kind.len == 0 or def.version == 0) return error.InvalidTaskDefinition;
        for (definitions[0..i]) |previous| {
            if (same(previous.kind, def.kind)) return error.DuplicateTaskDefinition;
        }
    }
    try gateway.attachTaskScheduler(worker, true);
    errdefer gateway.attachTaskScheduler(worker, false) catch {};
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .io = io, .gateway = gateway, .worker = worker, .settings = settings, .enabled = .init(!settings.start_paused) };
    errdefer self.freeDefinitions();
    for (definitions) |def| try self.installDefinition(def);
    var existing = try self.snapshot(gpa);
    defer existing.deinit();
    if (j.get(existing.value, "value") != .null) try self.commit(.restart);
    self.future = try io.concurrent(drive, .{self});
    return self;
}

pub fn close(self: *Self) void {
    self.admission.lockUncancelable(self.io);
    self.mutex.lockUncancelable(self.io);
    self.closing = true;
    self.mutex.unlock(self.io);
    self.admission.unlock(self.io);
    self.signal();
    self.future.cancel(self.io);
    self.gateway.attachTaskScheduler(self.worker, false) catch {};
    self.jobs.deinit(self.gpa);
    self.freeDefinitions();
    self.gpa.destroy(self);
}

pub fn snapshot(self: *Self, a: Allocator) !j.Document {
    return self.gateway.readSessionExtension(self.worker, a, graph.namespace);
}

/// The caller owns the returned value in its allocator.
pub fn readDocument(self: *Self, a: Allocator, id: []const u8, address: graph.Document.Address) !?graph.Document.Snapshot {
    var state = try self.snapshot(self.gpa);
    defer state.deinit();
    const task = j.get(graph.taskValues(j.get(state.value, "value")), id);
    var saved = (try graph.Document.read(state.allocator(), j.get(task, "documents"), address)) orelse return null;
    saved.value = try j.copy(a, saved.value);
    return saved;
}

/// Wake the driver after a task transition committed by the Worker as part
/// of a larger transaction.
pub fn notify(self: *Self) void {
    self.signal();
}

/// Enable scheduling and recheck the clock, including when already enabled.
pub fn resumeScheduling(self: *Self) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.statusLocked();
    self.enabled.store(true, .release);
    self.generation +%= 1;
    self.change.broadcast(self.io);
}

/// Observe committed task demand and the next absolute deadline without
/// enabling scheduling or replacing the host's alarm.
pub fn wake(self: *Self) !Wake {
    _ = try self.version();
    var state = try self.snapshot(self.gpa);
    defer state.deinit();
    const a = state.allocator();
    const saved = try graph.graphAt(a, j.get(state.value, "value"));
    return (try self.plan(a, &saved, self.now(), false)).wake;
}

pub fn submit(self: *Self, request: graph.Submission) !void {
    return self.submitWithExtensions(request, &.{});
}

pub fn submitWithExtensions(self: *Self, request: graph.Submission, extensions: []const @import("Session.zig").ExtensionWrite) !void {
    self.admission.lockUncancelable(self.io);
    defer self.admission.unlock(self.io);
    _ = try self.version();
    try self.commitEntries(.{ .submit = request }, &.{}, extensions);
}

/// Admit a conversation, its transcript context, and any initial tasks together.
/// A handler admits an owned conversation through Step.conversations.
pub fn createConversation(self: *Self, draft: graph.ConversationDraft) !void {
    return self.createConversationWithExtensions(draft, &.{});
}

/// The conversation and its prepared application documents share one commit.
pub fn createConversationWithExtensions(self: *Self, draft: graph.ConversationDraft, extensions: []const @import("Session.zig").ExtensionWrite) !void {
    self.admission.lockUncancelable(self.io);
    defer self.admission.unlock(self.io);
    _ = try self.version();
    try self.commitEntries(.{ .create_conversation = draft }, &.{}, extensions);
}

pub fn readTranscript(self: *Self, a: Allocator, id: []const u8, cut: ?u64) !j.Document {
    return self.gateway.readTranscript(self.worker, a, id, cut);
}

/// The caller owns the returned immutable record in its allocator.
pub fn readConversation(self: *Self, a: Allocator, id: []const u8) !?graph.ConversationRecord {
    if (same(id, graph.main_conversation)) return .{ .owner = null, .base = null };
    var state = try self.snapshot(self.gpa);
    defer state.deinit();
    const saved = graph.conversationValue(j.get(state.value, "value"), id);
    if (saved == .null) return null;
    const record = try std.json.parseFromValueLeaky(graph.ConversationRecord, state.allocator(), saved, .{});
    return try @import("session_protocol").frames.copy(graph.ConversationRecord, a, record);
}

/// Publish a definition and wake work waiting for it. An invocation already
/// reserved keeps its handler through the current phase. Callback contexts
/// from this and prior definitions must remain alive until close returns.
pub fn registerDefinition(self: *Self, def: Definition) !void {
    if (def.kind.len == 0 or def.version == 0) return error.InvalidTaskDefinition;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.statusLocked();
    try self.installDefinition(def);
    self.generation +%= 1;
    self.change.broadcast(self.io);
}

pub fn abort(self: *Self, id: []const u8) !void {
    return self.admit(.{ .abort = .{ .id = id } });
}

pub fn abortAll(self: *Self, include_background: bool) !void {
    return self.admit(.{ .abort_all = include_background });
}

/// Stop the selected tasks and join their cleanup. Background tasks admitted
/// after this operation do not delay it.
pub fn abortConversation(self: *Self, id: []const u8, include_background: bool) !void {
    var before = try self.admitConversationAbort(id, include_background);
    defer before.deinit();
    const saved = try graph.graphAt(before.allocator(), j.get(before.value, "value"));
    for (saved.tasks.keys(), saved.tasks.values()) |task_id, entry| {
        if (entry.state == .terminal or !graph.inScope(&saved, entry, id, include_background)) continue;
        var receipt = try self.wait(self.gpa, task_id);
        receipt.deinit();
    }
    try self.waitConversationIdle(id, false);
}

fn admitConversationAbort(self: *Self, id: []const u8, include_background: bool) !j.Document {
    self.admission.lockUncancelable(self.io);
    defer self.admission.unlock(self.io);
    _ = try self.version();
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    const ticket = std.fmt.bytesToHex(nonce, .lower);
    while (true) {
        var before = try self.snapshot(self.gpa);
        const operation: @FieldType(graph.Change, "operation") = .{ .abort_conversation = .{
            .id = id,
            .include_background = include_background,
        } };
        self.commitAt(before.allocator(), &ticket, j.number(j.get(before.value, "head")), operation, &.{}, &.{}) catch |err| {
            before.deinit();
            if (err == error.StaleExtensionHead) continue;
            return err;
        };
        return before;
    }
}

fn admit(self: *Self, op: @FieldType(graph.Change, "operation")) !void {
    self.admission.lockUncancelable(self.io);
    defer self.admission.unlock(self.io);
    _ = try self.version();
    try self.commit(op);
}

/// Caller owns the returned document containing the terminal outcome. Stopping
/// the wait is independent of stopping the task.
pub fn wait(self: *Self, a: Allocator, id: []const u8) !j.Document {
    while (true) {
        const generation = self.readGeneration();
        var state = try self.snapshot(self.gpa);
        defer state.deinit();
        const entry = j.get(graph.taskValues(j.get(state.value, "value")), id);
        if (entry == .null) return error.UnknownTask;
        const outcome = j.get(j.get(entry, "state"), "terminal");
        if (outcome != .null) return j.Document.initValue(a, outcome);
        if (!self.enabled.load(.acquire)) try self.resumeScheduling();
        try self.waitForChange(generation, null);
    }
}

pub fn waitIdle(self: *Self, include_background: bool) !void {
    return self.waitScope(null, include_background);
}

pub fn waitConversationIdle(self: *Self, id: []const u8, include_background: bool) !void {
    return self.waitScope(id, include_background);
}

fn waitScope(self: *Self, id: ?[]const u8, include_background: bool) !void {
    while (true) {
        const generation = self.readGeneration();
        var state = try self.snapshot(self.gpa);
        defer state.deinit();
        const saved = try graph.graphAt(state.allocator(), j.get(state.value, "value"));
        if (id) |scope| if (!graph.hasConversation(&saved, scope)) return error.UnknownTaskConversation;
        for (saved.tasks.values()) |entry| {
            if (entry.state != .terminal and graph.inScope(&saved, entry, id, include_background)) break;
        } else return;
        if (!self.enabled.load(.acquire)) try self.resumeScheduling();
        try self.waitForChange(generation, null);
    }
}

fn readGeneration(self: *Self) u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.generation;
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn now(self: *Self) u64 {
    return @intCast(@max(0, Io.Clock.real.now(self.io).toMilliseconds()));
}

fn signal(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.generation +%= 1;
    self.change.broadcast(self.io);
}

fn statusLocked(self: *Self) !void {
    if (self.failure) |err| return err;
    if (self.closing) return error.TaskSchedulerClosed;
}

fn version(self: *Self) !u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.statusLocked();
    return self.generation;
}

fn waitForChange(self: *Self, seen: u64, until: ?u64) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.statusLocked();
    if (self.generation != seen) return;
    if (until) |deadline| {
        const remaining = deadline -| self.now();
        if (remaining == 0) return;
        self.change.waitTimeout(self.io, &self.mutex, .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(@min(remaining, std.math.maxInt(i64)))),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
    } else try self.change.wait(self.io, &self.mutex);
}

fn commit(self: *Self, op: @FieldType(graph.Change, "operation")) !void {
    return self.commitEntries(op, &.{}, &.{});
}

fn commitHandoff(self: *Self, request: Invocation, step: graph.Step) !void {
    const lease: graph.Lease = .{ .id = request.id, .attempt = request.attempt };
    try self.commitEntries(graph.handoffChange(lease, request.conversation, step), step.entries, step.extensions);
}

fn commitEntries(self: *Self, op: @FieldType(graph.Change, "operation"), entries: []const graph.EntryDraft, extensions: []const @import("Session.zig").ExtensionWrite) !void {
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    const ticket = std.fmt.bytesToHex(nonce, .lower);
    while (true) {
        var state = try self.snapshot(self.gpa);
        defer state.deinit();
        self.commitAt(state.allocator(), &ticket, j.number(j.get(state.value, "head")), op, entries, extensions) catch |err| switch (err) {
            error.StaleExtensionHead => continue,
            else => return err,
        };
        return;
    }
}

fn commitAt(self: *Self, a: Allocator, ticket: []const u8, head: u64, op: @FieldType(graph.Change, "operation"), entries: []const graph.EntryDraft, extensions: []const @import("Session.zig").ExtensionWrite) !void {
    _ = try self.gateway.recordSessionWithExtensions(self.worker, ticket, try graph.actions(a, head, .{ .now_ms = self.now(), .operation = op }, entries), extensions);
    self.signal();
}

fn installDefinition(self: *Self, def: Definition) !void {
    if (self.definitions.getPtr(def.kind)) |current| {
        const kind = current.kind;
        current.* = def;
        current.kind = kind;
        return;
    }
    const kind = try self.gpa.dupe(u8, def.kind);
    errdefer self.gpa.free(kind);
    var owned = def;
    owned.kind = kind;
    try self.definitions.putNoClobber(self.gpa, kind, owned);
}

fn freeDefinitions(self: *Self) void {
    var keys = self.definitions.keyIterator();
    while (keys.next()) |key| self.gpa.free(key.*);
    self.definitions.deinit(self.gpa);
}

/// Snapshot the installed callbacks. Their context and kind remain valid until close.
pub fn definition(self: *Self, kind: []const u8) ?Definition {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.definitions.get(kind);
}

fn destroyJob(self: *Self, job: *Job) void {
    job.arena.deinit();
    self.gpa.destroy(job);
}

fn drive(self: *Self) void {
    const failure = self.loop();
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    for (self.jobs.items) |job| job.requestCancel();
    for (self.jobs.items) |job| {
        _ = job.future.await(self.io) catch {};
        self.destroyJob(job);
    }
    self.jobs.clearRetainingCapacity();
    var result: ?anyerror = if (failure) |_| null else |err| err;
    if (result == null or result.? == error.Canceled or result.? == error.TaskSchedulerClosed) {
        if (self.snapshot(self.gpa)) |opened| {
            var saved = opened;
            defer saved.deinit();
            if (j.get(saved.value, "value") != .null) self.commit(.close) catch |err| {
                result = err;
            };
        } else |err| result = err;
    }
    self.mutex.lockUncancelable(self.io);
    self.failure = result;
    self.generation +%= 1;
    self.change.broadcast(self.io);
    self.mutex.unlock(self.io);
}

fn loop(self: *Self) !void {
    var reported: ?Wake = null;
    while (true) {
        try self.io.checkCancel();
        const seen = try self.version();
        var snapshot_state = try self.snapshot(self.gpa);
        defer snapshot_state.deinit();
        const a = snapshot_state.allocator();
        const saved = try graph.graphAt(a, j.get(snapshot_state.value, "value"));
        if (try self.finishOne(&saved.tasks)) continue;
        const enabled = self.enabled.load(.acquire);
        const can_start = enabled and self.jobs.items.len < self.settings.concurrency;
        const schedule = try self.plan(a, &saved, self.now(), can_start);
        if (try self.version() != seen) continue;
        if (self.settings.on_wake) |sink| {
            if (reported == null or !std.meta.eql(reported.?, schedule.wake)) {
                if (sink.notify(sink.context, schedule.wake)) |_| {
                    reported = schedule.wake;
                } else |err| {
                    std.log.warn("task wake callback failed ({s})", .{@errorName(err)});
                }
            }
        }
        if (schedule.picked) |picked| {
            try self.startOne(a, j.number(j.get(snapshot_state.value, "head")), &saved.tasks, picked);
            continue;
        }
        try self.waitForChange(seen, if (enabled and self.settings.on_wake == null) schedule.wake.at else null);
    }
}

fn taskFault(code: anyerror) graph.Step {
    return .{ .next = .{ .finish = .{ .status = .faulted, .value = j.string(@errorName(code)) } } };
}

fn finishOne(self: *Self, tasks: *const graph.Records) !bool {
    for (self.jobs.items, 0..) |job, i| {
        const record = tasks.get(job.request.id) orelse return error.UnknownTask;
        const superseded = job.mode == .run and record.abort_reason != null;
        if (superseded) job.requestCancel();
        if (!job.done.load(.acquire)) continue;
        _ = self.jobs.swapRemove(i);
        defer self.destroyJob(job);
        const result = job.future.await(self.io);
        const lease: graph.Lease = .{ .id = job.request.id, .attempt = job.request.attempt };
        if (superseded) {
            try self.commit(.{ .release = lease });
            return true;
        }
        const step = result catch |err| taskFault(err);
        self.commitHandoff(job.request, step) catch |err| switch (err) {
            error.TaskSuperseded => try self.commit(.{ .release = lease }),
            error.TaskDependencyCycle,
            error.UnknownTaskDependency,
            error.UnownedTaskDependency,
            error.InvalidTaskOwner,
            error.UnknownTaskOwner,
            error.InactiveTaskOwner,
            error.InvalidCleanupTransition,
            error.InvalidTaskSubmission,
            error.TaskIdConflict,
            error.InvalidTaskDocument,
            error.StaleTaskDocument,
            error.TaskDocumentExists,
            error.UnknownTaskDocument,
            error.InvalidDocumentPatch,
            error.TaskDocumentRevisionExhausted,
            error.ConversationContextMismatch,
            error.ConversationIdConflict,
            error.InvalidConversationAdmission,
            error.InvalidTaskConversation,
            error.UnknownTaskConversation,
            error.DuplicateContext,
            error.UnknownContext,
            error.UnselectedAnchor,
            error.UncommittedPosition,
            error.DuplicateMessage,
            error.InvalidMessage,
            error.InvalidContent,
            error.InvalidId,
            error.InvalidHash,
            error.InvalidJsonDomain,
            error.UnknownToolCall,
            error.DuplicateToolResult,
            => self.commitHandoff(job.request, taskFault(err)) catch |failure| switch (failure) {
                error.TaskSuperseded => try self.commit(.{ .release = lease }),
                else => return failure,
            },
            else => {
                if (step.extensions.len == 0) return err;
                self.commitHandoff(job.request, taskFault(err)) catch |failure| switch (failure) {
                    error.TaskSuperseded => try self.commit(.{ .release = lease }),
                    else => return failure,
                };
            },
        };
        return true;
    }
    return false;
}

const Candidate = struct { id: []const u8, entry: graph.Record, mode: graph.Mode, def: ?Definition, migration: ?Value };
const Plan = struct { wake: Wake = .{}, picked: ?Candidate = null };

fn plan(self: *Self, a: Allocator, saved: *const graph.Graph, current: u64, can_start: bool) !Plan {
    const tasks = &saved.tasks;
    var schedule: Plan = .{};
    for (tasks.keys(), tasks.values()) |id, entry| {
        if (entry.state == .running) schedule.wake.active = true;
        if (entry.state == .terminal or entry.state == .completing or entry.state == .running) continue;
        if (entry.state == .sleeping and entry.state.sleeping.until_ms > current and entry.abort_reason == null) {
            schedule.wake.at = @min(schedule.wake.at orelse std.math.maxInt(u64), entry.state.sleeping.until_ms);
            continue;
        }
        if (!can_start and schedule.wake.active) continue;
        const raw = self.definition(entry.kind);
        if (raw) |candidate| {
            if (candidate.ready) |ready| if (!ready(candidate.context)) continue;
            if (candidate.ready_in_conversation) |ready| if (!ready(candidate.context, entry.conversation)) continue;
            if (candidate.ready_task) |ready| if (!ready(candidate.context, entry.conversation, entry.input)) continue;
        }
        const mode = graph.runnable(saved, id, entry, current) orelse continue;
        if (schedule.picked) |old| if (old.entry.attempt <= entry.attempt) continue;
        var def = if (raw) |candidate| if (candidate.version >= entry.version) candidate else null else null;
        var migration: ?Value = null;
        if (def) |candidate| {
            if (candidate.version > entry.version) {
                if (candidate.migrate) |upgrade| {
                    migration = upgrade(candidate.context, a, entry.version, entry.input, entry.work().?.checkpoint) catch |err| switch (err) {
                        error.OutOfMemory, error.Canceled => return err,
                        else => blocked: {
                            def = null;
                            break :blocked null;
                        },
                    };
                } else {
                    def = null;
                }
            }
        }
        if (def == null and mode != .cleanup) continue;
        schedule.wake.active = true;
        if (can_start) schedule.picked = .{ .id = id, .entry = entry, .mode = mode, .def = def, .migration = migration };
    }
    return schedule;
}

fn startOne(self: *Self, a: Allocator, head: u64, tasks: *const graph.Records, candidate: Candidate) !void {
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    const ticket = std.fmt.bytesToHex(nonce, .lower);
    const def = candidate.def orelse {
        self.commitAt(a, &ticket, head, .{ .orphan = candidate.id }, &.{}, &.{}) catch |err| if (err != error.StaleExtensionHead) return err;
        return;
    };
    const entry = candidate.entry;
    const work = entry.work().?;
    const expired = if (!def.manages_restarts) if (self.settings.restart_limit) |limit| entry.restarts != 0 and entry.restarts >= limit else false else false;
    if (candidate.mode == .run and (expired or (entry.interrupted and !def.replay_safe and def.recover_invocation == null))) {
        self.commitAt(a, &ticket, head, .{ .abort = .{
            .id = candidate.id,
            .reason = if (expired) .restart_limit else .indeterminate_effect,
        } }, &.{}, &.{}) catch |err| if (err != error.StaleExtensionHead) return err;
        return;
    }
    const handler = switch (candidate.mode) {
        .run => if (entry.interrupted) def.recover_invocation orelse def.run else def.run,
        .cleanup => if (expired) null else def.cleanup,
    };
    const reason = entry.abort_reason orelse .requested;
    const fallback: graph.Outcome = .{
        .status = if (expired or reason == .restart_limit or reason == .indeterminate_effect) .faulted else .aborted,
        .value = j.string(@tagName(reason)),
    };

    try self.jobs.ensureUnusedCapacity(self.gpa, 1);
    const job = try self.gpa.create(Job);
    var owned = true;
    defer if (owned) self.destroyJob(job);
    job.* = .{ .scheduler = self, .arena = .init(self.gpa), .request = undefined, .mode = candidate.mode, .callback = handler, .context = def.context, .fallback = fallback };
    const data = job.arena.allocator();
    var dependencies: std.ArrayList(Invocation.Dependency) = .empty;
    for (work.on) |id| {
        const dependency = tasks.get(id).?;
        if (dependency.state != .terminal) continue;
        var outcome = dependency.state.terminal;
        outcome.value = try j.copy(data, outcome.value);
        try dependencies.append(data, .{ .id = try data.dupe(u8, id), .outcome = outcome });
    }
    job.request = .{
        .allocator = data,
        .io = self.io,
        .id = try data.dupe(u8, candidate.id),
        .conversation = try data.dupe(u8, entry.conversation),
        .attempt = entry.attempt + 1,
        .restarts = entry.restarts,
        .input = try j.copy(data, entry.input),
        .checkpoint = try j.copy(data, candidate.migration orelse work.checkpoint),
        .interrupted = entry.interrupted,
        .abort_reason = entry.abort_reason,
        .dependencies = dependencies.items,
        .driver = self,
    };
    self.commitAt(a, &ticket, head, .{ .reserve = .{
        .id = candidate.id,
        .mode = candidate.mode,
        .migration = if (candidate.migration) |checkpoint| .{ .version = def.version, .checkpoint = checkpoint } else null,
    } }, &.{}, &.{}) catch |err| switch (err) {
        error.StaleExtensionHead => return,
        else => return err,
    };
    job.future = self.io.concurrent(Job.own, .{job}) catch |err| {
        const lease: graph.Lease = .{ .id = job.request.id, .attempt = job.request.attempt };
        self.commitHandoff(job.request, taskFault(err)) catch |failure| switch (failure) {
            error.TaskSuperseded => try self.commit(.{ .release = lease }),
            else => return failure,
        };
        return;
    };
    self.jobs.appendAssumeCapacity(job);
    owned = false;
}
