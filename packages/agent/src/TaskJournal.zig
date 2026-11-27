//! Durable task transitions. The extension reducer validates the same actions
//! during live execution and journal replay.
const std = @import("std");
const protocol = @import("session_protocol");
const j = @import("json.zig");
const Allocator = std.mem.Allocator;
const Value = j.Value;
const Frame = protocol.frames;
pub const Document = @import("TaskDocument.zig");

pub const namespace = "agent.tasks";
pub const contract: protocol.Extensions.Contract = .{
    .version = .{ .id = namespace, .version = "1" },
    .initial_state = empty,
    .validate = validateEnvelope,
    .reduce = reduce,
    .validate_transaction = validateTransaction,
    .replay_typed = .{ .init = replayInit, .step = replayStep },
};

pub const Mode = enum { run, cleanup };
pub const AbortReason = enum { requested, owner, dependency, restart, indeterminate_effect, restart_limit };
pub const Outcome = struct {
    status: enum { completed, failed, aborted, orphaned, faulted },
    value: Value = .null,
};
pub const JoinPolicy = enum { all_settled, fail_fast };
pub const main_conversation = "main";

pub const Submission = struct {
    id: []const u8,
    kind: []const u8,
    version: u32 = 1,
    input: Value = .null,
    checkpoint: Value = .null,
    owner: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    exclusive_turn: bool = false,
    background: bool = false,
    abandon_on_restart: bool = false,
    documents: []const Document.Edit = &.{},
};

/// A fork selects the prefix through one visible entry at a committed cut.
/// Initial tasks are owned by the new conversation.
pub const ConversationDraft = struct {
    id: []const u8,
    base: ?Frame.ContextBase = null,
    tasks: []const Submission = &.{},
};

pub const ConversationRecord = struct {
    owner: ?[]const u8,
    base: ?Frame.ContextBase,
};

pub const EntryDraft = struct {
    message: Frame.Message,
    after: ?[]const u8,
};

pub const Step = struct {
    pub const Transition = union(enum) {
        checkpoint: Value,
        wait: struct { checkpoint: Value, on: []const []const u8, policy: JoinPolicy = .all_settled },
        sleep: struct { checkpoint: Value, until_ms: u64 },
        finish: Outcome,
    };
    next: Transition,
    children: []const Submission = &.{},
    documents: []const Document.Edit = &.{},
    conversations: []const ConversationDraft = &.{},
    entries: []const EntryDraft = &.{},
    extensions: []const @import("Session.zig").ExtensionWrite = &.{},
};

const RecordedStep = struct {
    next: Step.Transition,
    children: []const Submission = &.{},
    documents: []const Document.Edit = &.{},
    conversations: []const ConversationDraft = &.{},
    transcript: ?struct { context: []const u8, count: usize } = null,
};

pub const Work = struct {
    checkpoint: Value = .null,
    on: []const []const u8 = &.{},
    policy: JoinPolicy = .all_settled,
    until_ms: u64 = 0,
};

pub const Record = struct {
    pub const State = union(enum) {
        pending: Work,
        running: struct { mode: Mode, work: Work },
        waiting: Work,
        sleeping: Work,
        completing: Outcome,
        terminal: Outcome,
    };
    kind: []const u8,
    version: u32,
    input: Value,
    owner: ?[]const u8,
    conversation: []const u8 = main_conversation,
    exclusive_turn: bool = false,
    background: bool,
    abandon_on_restart: bool,
    submission_sha256: []const u8,
    state: State,
    abort_reason: ?AbortReason = null,
    attempt: u64 = 0,
    restarts: u32 = 0,
    interrupted: bool = false,
    memos: Value = .null,
    started_ms: ?u64 = null,
    ended_ms: ?u64 = null,
    documents: Value = .null,
    document_revision: u64 = 0,

    pub fn work(self: Record) ?Work {
        return switch (self.state) {
            .pending, .waiting, .sleeping => |saved| saved,
            .running => |running| running.work,
            .completing, .terminal => null,
        };
    }
};

const Reserve = struct {
    id: []const u8,
    mode: Mode,
    migration: ?struct { version: u32, checkpoint: Value } = null,
};
pub const Lease = struct { id: []const u8, attempt: u64 };
pub const Change = struct {
    now_ms: u64,
    operation: union(enum) {
        submit: Submission,
        create_conversation: ConversationDraft,
        reserve: Reserve,
        handoff: struct { lease: Lease, step: RecordedStep },
        abort: struct { id: []const u8, reason: AbortReason = .requested },
        abort_all: bool,
        abort_conversation: struct { id: []const u8, include_background: bool = false },
        memo: struct { lease: Lease, key: []const u8, value: Value },
        documents: struct { lease: Lease, edits: []const Document.Edit },
        release: Lease,
        restart,
        close,
        orphan: []const u8,
    },
};

pub fn handoffChange(lease: Lease, conversation: []const u8, step: Step) @FieldType(Change, "operation") {
    return .{ .handoff = .{
        .lease = lease,
        .step = .{
            .next = step.next,
            .children = step.children,
            .documents = step.documents,
            .conversations = step.conversations,
            .transcript = if (step.entries.len == 0) null else .{ .context = conversation, .count = step.entries.len },
        },
    } };
}

pub const Records = std.StringArrayHashMapUnmanaged(Record);
const Conversations = std.StringArrayHashMapUnmanaged(ConversationRecord);
pub const Graph = struct {
    tasks: Records = .empty,
    conversations: Conversations = .empty,
};

// A legacy task map contains only object values, even for these keys.
fn hasConversations(value: Value) bool {
    return j.get(value, "format") == .integer;
}

pub fn taskValues(value: Value) Value {
    return if (hasConversations(value)) j.get(value, "tasks") else value;
}

pub fn conversationValue(value: Value, id: []const u8) Value {
    return if (hasConversations(value)) j.get(j.get(value, "conversations"), id) else .null;
}

pub fn records(a: Allocator, value: Value) !Records {
    var result: Records = .empty;
    if (value == .null) return result;
    if (value != .object) return error.InvalidTaskGraph;
    try result.ensureTotalCapacity(a, value.object.count());
    for (value.object.keys(), value.object.values()) |id, entry| {
        result.putAssumeCapacityNoClobber(id, try std.json.parseFromValueLeaky(Record, a, entry, .{}));
    }
    return result;
}

pub fn graphAt(a: Allocator, value: Value) !Graph {
    var graph: Graph = .{ .tasks = try records(a, taskValues(value)) };
    if (hasConversations(value)) {
        const items = j.get(value, "conversations");
        if (j.number(j.get(value, "format")) != 1 or items != .object) return error.InvalidTaskGraph;
        try graph.conversations.ensureTotalCapacity(a, items.object.count());
        for (items.object.keys(), items.object.values()) |id, entry| {
            graph.conversations.putAssumeCapacityNoClobber(id, try std.json.parseFromValueLeaky(ConversationRecord, a, entry, .{}));
        }
    }
    return graph;
}

pub fn action(a: Allocator, head: u64, change: Change) !Frame.Action {
    return .{ .@"control.extension" = .{
        .namespace = namespace,
        .expected_head = head,
        .action = "change",
        .input = .{ .contract = contract.version, .value = try j.project(a, change) },
    } };
}

pub fn actions(a: Allocator, head: u64, change: Change, entries: []const EntryDraft) ![]const Frame.Action {
    var single: [1]ConversationDraft = undefined;
    const drafts: []const ConversationDraft = switch (change.operation) {
        .create_conversation => |draft| blk: {
            single[0] = draft;
            break :blk &single;
        },
        .handoff => |update| update.step.conversations,
        else => &.{},
    };
    const batch = try a.alloc(Frame.Action, drafts.len + entries.len + 1);
    for (drafts, batch[0..drafts.len]) |draft, *frame| {
        frame.* = .{ .@"control.context.create" = .{ .id = draft.id, .base = draft.base } };
    }
    if (entries.len != 0) {
        if (change.operation != .handoff) return error.ConversationContextMismatch;
        const placement = change.operation.handoff.step.transcript orelse return error.ConversationContextMismatch;
        if (placement.count != entries.len) return error.ConversationContextMismatch;
        for (entries, batch[drafts.len..][0..entries.len]) |entry, *frame| {
            frame.* = .{ .@"document.message.append" = .{
                .message = entry.message,
                .placement = .{ .context = placement.context, .after = entry.after },
            } };
        }
    }
    batch[batch.len - 1] = try action(a, head, change);
    return batch;
}

fn validateTransaction(a: Allocator, frame: Frame.Frame, transaction: *const protocol.Transaction) !void {
    const op = j.get(frame.action.@"control.extension".input.value, "operation");
    const create = j.get(op, "create_conversation");
    if (create != .null) try validateContextFrame(try std.json.parseFromValueLeaky(ConversationDraft, a, create, .{}), transaction);
    const step = j.get(j.get(op, "handoff"), "step");
    const drafts = j.get(step, "conversations");
    if (drafts == .array) for (drafts.array.items) |draft| {
        try validateContextFrame(try std.json.parseFromValueLeaky(ConversationDraft, a, draft, .{}), transaction);
    };
    const transcript = j.get(step, "transcript");
    if (transcript != .null) {
        const context = j.text(j.get(transcript, "context"));
        const count = j.number(j.get(transcript, "count"));
        if (context.len == 0 or count == 0 or count > frame.tx.index) return error.ConversationContextMismatch;
        for (transaction.frames[frame.tx.index - count .. frame.tx.index]) |part| {
            if (part.frame.action != .@"document.message.append") return error.ConversationContextMismatch;
            const placement = part.frame.action.@"document.message.append".placement orelse return error.ConversationContextMismatch;
            if (!same(placement.context, context)) return error.ConversationContextMismatch;
        }
    }
}

fn validateContextFrame(draft: ConversationDraft, transaction: *const protocol.Transaction) !void {
    for (transaction.frames) |part| {
        if (part.frame.action != .@"control.context.create") continue;
        const creation = part.frame.action.@"control.context.create";
        if (!same(creation.id, draft.id)) continue;
        if (creation.base) |base| {
            const expected = draft.base orelse return error.ConversationContextMismatch;
            if (base.at != expected.at or !same(base.context, expected.context) or
                !same(base.through orelse "", expected.through orelse "")) return error.ConversationContextMismatch;
            if (base.fork) |fork| {
                const other = expected.fork orelse return error.ConversationContextMismatch;
                if (!same(fork.parent, other.parent) or fork.anchor != other.anchor or
                    fork.selected.len != other.selected.len) return error.ConversationContextMismatch;
                for (fork.selected, other.selected) |left, right| {
                    if (!same(left, right)) return error.ConversationContextMismatch;
                }
            } else if (expected.fork != null) return error.ConversationContextMismatch;
        } else if (draft.base != null) return error.ConversationContextMismatch;
        return;
    }
    return error.ConversationContextMismatch;
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn empty(_: Allocator) !Value {
    return j.object();
}

fn validateEnvelope(previous: Value, name: []const u8, input: Value) !void {
    if (previous != .object or input != .object or !std.mem.eql(u8, name, "change")) return error.InvalidTaskChange;
}

fn liveChildren(graph: *const Graph, id: []const u8) bool {
    for (graph.tasks.values()) |child| {
        if (child.state == .terminal) continue;
        if (same(liveParent(graph, child) orelse continue, id)) return true;
    }
    return false;
}

fn owns(child: Record, parent: []const u8) bool {
    return same(child.owner orelse return false, parent);
}

fn parentId(graph: *const Graph, task: Record) ?[]const u8 {
    if (task.owner) |owner| return owner;
    const conversation = graph.conversations.get(task.conversation) orelse return null;
    return conversation.owner;
}

fn liveParent(graph: *const Graph, child: Record) ?[]const u8 {
    var task = child;
    while (!task.background) {
        const owner = parentId(graph, task) orelse return null;
        const parent = graph.tasks.get(owner).?;
        if (parent.state != .terminal) return owner;
        task = parent;
    }
    return null;
}

pub fn inScope(graph: *const Graph, entry: Record, scope: ?[]const u8, include_background: bool) bool {
    var task = entry;
    while (include_background or !task.background) {
        if (scope) |conversation| {
            if (task.owner == null and same(task.conversation, conversation)) return true;
        }
        const owner = parentId(graph, task) orelse return scope == null;
        task = graph.tasks.get(owner).?;
    }
    return false;
}

pub fn hasConversation(graph: *const Graph, id: []const u8) bool {
    return same(id, main_conversation) or graph.conversations.contains(id);
}

pub fn joinReady(graph: *const Records, on: []const []const u8) bool {
    for (on) |id| {
        const target = graph.get(id) orelse return false;
        if (target.state != .terminal) return false;
    }
    return true;
}

pub fn runnable(graph: *const Graph, id: []const u8, entry: Record, now_ms: u64) ?Mode {
    const work = entry.work() orelse return null;
    if (entry.state == .running) return null;
    if (entry.abort_reason != null) return if (liveChildren(graph, id)) null else .cleanup;
    if (earlierTurn(graph, id, entry) != null) return null;
    if (entry.state == .waiting and !joinReady(&graph.tasks, work.on)) return null;
    if (entry.state == .sleeping and work.until_ms > now_ms) return null;
    return .run;
}

fn earlierTurn(graph: *const Graph, id: []const u8, entry: Record) ?[]const u8 {
    if (!entry.exclusive_turn) return null;
    for (graph.tasks.keys(), graph.tasks.values()) |candidate, record| {
        if (same(candidate, id)) break;
        if (record.exclusive_turn and record.state != .terminal and same(record.conversation, entry.conversation)) return candidate;
    }
    return null;
}

fn submit(a: Allocator, graph: *Graph, request: Submission, mode: Mode) !void {
    if (request.id.len == 0 or request.kind.len == 0 or request.version == 0) return error.InvalidTaskSubmission;
    var identity = try j.project(a, request);
    // Tasks from older journals already have a digest over the original shape.
    if (request.documents.len == 0) _ = identity.object.orderedRemove("documents");
    if (request.conversation == null) _ = identity.object.orderedRemove("conversation");
    if (!request.exclusive_turn) _ = identity.object.orderedRemove("exclusive_turn");
    const digest = try protocol.Canonical.hash(a, identity);
    if (graph.tasks.get(request.id)) |old| {
        if (!std.mem.eql(u8, old.submission_sha256, &digest)) return error.TaskIdConflict;
        return;
    }
    var conversation = request.conversation orelse main_conversation;
    if (request.owner) |owner| {
        const parent = graph.tasks.get(owner) orelse return error.UnknownTaskOwner;
        if (request.exclusive_turn or parent.work() == null or
            (parent.abort_reason != null and (mode != .cleanup or !request.background))) return error.InactiveTaskOwner;
        if (request.conversation != null and !same(conversation, parent.conversation)) return error.InvalidTaskConversation;
        conversation = parent.conversation;
    }
    if (!hasConversation(graph, conversation)) return error.UnknownTaskConversation;
    var entry: Record = .{
        .kind = request.kind,
        .version = request.version,
        .input = request.input,
        .owner = request.owner,
        .conversation = conversation,
        .exclusive_turn = request.exclusive_turn,
        .background = request.background,
        .abandon_on_restart = request.abandon_on_restart,
        .submission_sha256 = try a.dupe(u8, &digest),
        .state = .{ .pending = .{ .checkpoint = request.checkpoint } },
    };
    try Document.apply(a, &entry.documents, &entry.document_revision, request.documents);
    try graph.tasks.put(a, request.id, entry);
}

fn createConversation(a: Allocator, graph: *Graph, owner: ?[]const u8, draft: ConversationDraft) !void {
    if (draft.id.len == 0) return error.InvalidConversationAdmission;
    if (hasConversation(graph, draft.id)) return error.ConversationIdConflict;
    if (draft.base) |base| {
        if (!hasConversation(graph, base.context)) return error.UnknownTaskConversation;
        if (base.fork) |fork| {
            if (!hasConversation(graph, fork.parent)) return error.UnknownTaskConversation;
        } else if (base.through == null or base.through.?.len == 0) return error.InvalidConversationAdmission;
    }
    try graph.conversations.put(a, draft.id, .{ .owner = owner, .base = draft.base });
    for (draft.tasks) |initial| {
        if (initial.owner != null or initial.conversation != null or graph.tasks.contains(initial.id)) return error.InvalidConversationAdmission;
        var request = initial;
        request.conversation = draft.id;
        try submit(a, graph, request, .run);
    }
}

fn reserve(graph: *Graph, plan: Reserve, now_ms: u64) !void {
    const entry = graph.tasks.getPtr(plan.id) orelse return error.UnknownTask;
    const mode = runnable(graph, plan.id, entry.*, now_ms) orelse return error.TaskUnavailable;
    if (mode != plan.mode) return error.TaskSuperseded;
    var saved = entry.work().?;
    if (plan.migration) |migration| {
        if (migration.version <= entry.version) return error.InvalidTaskMigration;
        entry.version = migration.version;
        saved.checkpoint = migration.checkpoint;
    }
    if (entry.attempt >= Frame.max_sequence) return error.TaskLeaseExhausted;
    entry.attempt += 1;
    if (entry.started_ms == null) entry.started_ms = now_ms;
    entry.state = .{ .running = .{ .mode = mode, .work = saved } };
}

fn leaseTask(graph: *Records, lease: Lease) !*Record {
    const entry = graph.getPtr(lease.id) orelse return error.UnknownTask;
    if (entry.attempt != lease.attempt or entry.state != .running) return error.TaskSuperseded;
    return entry;
}

fn editingTask(graph: *Records, lease: Lease) !*Record {
    const entry = try leaseTask(graph, lease);
    if ((entry.abort_reason != null) != (entry.state.running.mode == .cleanup)) return error.TaskSuperseded;
    return entry;
}

fn checkWait(a: Allocator, graph: *const Graph, id: []const u8, on: []const []const u8, policy: JoinPolicy) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var scan: std.ArrayList([]const u8) = .empty;
    for (on) |dependency| {
        const entry = graph.tasks.get(dependency) orelse return error.UnknownTaskDependency;
        if (policy == .fail_fast and !owns(entry, id)) return error.UnownedTaskDependency;
        try scan.append(a, dependency);
    }
    while (scan.pop()) |current| {
        if (std.mem.eql(u8, current, id)) return error.TaskDependencyCycle;
        if ((try seen.getOrPut(a, current)).found_existing) continue;
        const entry = graph.tasks.get(current) orelse return error.UnknownTaskDependency;
        if (entry.state == .terminal) continue;
        if (entry.abort_reason == null) {
            if (entry.state == .waiting) try scan.appendSlice(a, entry.state.waiting.on);
            if (earlierTurn(graph, current, entry)) |prior| try scan.append(a, prior);
        }
        for (graph.tasks.keys(), graph.tasks.values()) |child_id, child| {
            if (child.state != .terminal and same(liveParent(graph, child) orelse continue, current)) try scan.append(a, child_id);
        }
    }
}

fn handoff(a: Allocator, graph: *Graph, lease: Lease, step: RecordedStep) !void {
    const task = (try editingTask(&graph.tasks, lease)).*;
    const running = task.state.running;
    if (step.transcript) |transcript| {
        if (!same(transcript.context, task.conversation)) return error.InvalidTaskConversation;
    }
    if (running.mode == .cleanup and (step.next == .wait or step.next == .sleep)) return error.InvalidCleanupTransition;
    if (step.conversations.len != 0 and (running.mode == .cleanup or step.next == .finish)) return error.InactiveTaskOwner;
    for (step.conversations) |conversation| try createConversation(a, graph, lease.id, conversation);
    for (step.children) |child| {
        if (!std.mem.eql(u8, child.owner orelse return error.InvalidTaskOwner, lease.id)) return error.InvalidTaskOwner;
        if (running.mode == .cleanup and (!child.background or step.next != .finish)) return error.InvalidCleanupTransition;
        try submit(a, graph, child, running.mode);
    }
    if (step.next == .wait) try checkWait(a, graph, lease.id, step.next.wait.on, step.next.wait.policy);
    const entry = try leaseTask(&graph.tasks, lease);
    try Document.apply(a, &entry.documents, &entry.document_revision, step.documents);
    entry.state = switch (step.next) {
        .checkpoint => |checkpoint| .{ .pending = .{ .checkpoint = checkpoint } },
        .wait => |wait| .{ .waiting = .{ .checkpoint = wait.checkpoint, .on = wait.on, .policy = wait.policy } },
        .sleep => |sleep| .{ .sleeping = .{ .checkpoint = sleep.checkpoint, .until_ms = sleep.until_ms } },
        .finish => |outcome| .{ .completing = outcome },
    };
    entry.restarts = 0;
    entry.interrupted = false;
    if (step.next == .finish) entry.memos = .null;
}

fn memo(a: Allocator, graph: *Records, lease: Lease, key: []const u8, value: Value) !void {
    const entry = try editingTask(graph, lease);
    if (key.len == 0) return error.InvalidTaskMemo;
    if (entry.memos == .object and entry.memos.object.contains(key)) return;
    var replacement = j.object();
    if (entry.memos == .object) for (entry.memos.object.keys(), entry.memos.object.values()) |name, previous| {
        try j.put(a, &replacement, name, previous);
    };
    try j.put(a, &replacement, key, value);
    entry.memos = replacement;
}

fn mark(entry: *Record, reason: AbortReason) bool {
    if (entry.state == .terminal or entry.abort_reason != null) return false;
    entry.abort_reason = reason;
    entry.restarts = 0;
    return true;
}

fn unsuccessful(entry: Record) bool {
    return switch (entry.state) {
        .completing, .terminal => |outcome| outcome.status != .completed,
        else => false,
    };
}

fn reconcile(graph: *Graph, now_ms: u64) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.tasks.values()) |entry| {
            if (entry.state != .waiting or entry.abort_reason != null or entry.state.waiting.policy != .fail_fast) continue;
            const on = entry.state.waiting.on;
            var failed = false;
            for (on) |id| failed = failed or unsuccessful(graph.tasks.get(id).?);
            if (!failed) continue;
            for (on) |id| changed = mark(graph.tasks.getPtr(id).?, .dependency) or changed;
        }
        for (graph.tasks.values()) |*child| {
            if (child.state == .terminal) continue;
            const parent = graph.tasks.get(liveParent(graph, child.*) orelse continue).?;
            if (parent.abort_reason != null or unsuccessful(parent)) {
                changed = mark(child, .owner) or changed;
            }
        }
        for (graph.tasks.keys(), graph.tasks.values()) |id, *entry| {
            if (entry.state != .completing or liveChildren(graph, id)) continue;
            const outcome = entry.state.completing;
            entry.state = .{ .terminal = outcome };
            entry.ended_ms = now_ms;
            entry.documents = .null;
            changed = true;
        }
    }
}

fn recover(graph: *Records, crashed: bool) void {
    for (graph.values()) |*entry| {
        if (entry.state == .running) {
            const saved = entry.state.running.work;
            entry.state = .{ .pending = saved };
            entry.interrupted = true;
            if (crashed) entry.restarts +|= 1;
        }
        if (crashed and entry.abandon_on_restart) _ = mark(entry, .restart);
    }
}

fn reduce(a: Allocator, previous: Value, _: []const u8, input: Value) !Value {
    const change = try std.json.parseFromValueLeaky(Change, a, input, .{});
    var graph = try graphAt(a, previous);
    try applyChange(a, &graph, change);
    var tasks = j.object();
    for (graph.tasks.keys(), graph.tasks.values()) |id, entry| try j.put(a, &tasks, id, try j.project(a, entry));
    if (graph.conversations.count() == 0) return tasks;
    var conversations = j.object();
    for (graph.conversations.keys(), graph.conversations.values()) |id, entry| try j.put(a, &conversations, id, try j.project(a, entry));
    return graphValue(a, tasks, conversations);
}

fn replayInit(a: Allocator, previous: Value) !*anyopaque {
    const graph = try a.create(Graph);
    graph.* = try graphAt(a, previous);
    return graph;
}

fn replayStep(raw: *anyopaque, storage: Allocator, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    const graph: *Graph = @ptrCast(@alignCast(raw));
    const before = try scratch.dupe(Record, graph.tasks.values());
    const old_conversations = graph.conversations.count();
    const change = try Frame.copy(Change, storage, try std.json.parseFromValueLeaky(Change, scratch, input, .{}));
    try applyChange(storage, graph, change);

    var tasks: Value = .{ .object = try taskValues(previous).object.clone(retained) };
    for (graph.tasks.keys(), graph.tasks.values(), 0..) |id, entry, i| {
        if (i < before.len and std.meta.eql(before[i], entry)) continue;
        const row = try j.project(storage, entry);
        try Frame.validateValue(scratch, row);
        try j.put(retained, &tasks, id, row);
    }
    if (graph.conversations.count() == 0) return tasks;
    var conversations = j.object();
    if (old_conversations != 0) conversations.object = try j.get(previous, "conversations").object.clone(retained);
    for (graph.conversations.keys()[old_conversations..], graph.conversations.values()[old_conversations..]) |id, entry| {
        const row = try j.project(storage, entry);
        try Frame.validateValue(scratch, row);
        try j.put(retained, &conversations, id, row);
    }
    return graphValue(retained, tasks, conversations);
}

fn graphValue(a: Allocator, tasks: Value, conversations: Value) !Value {
    var result = j.object();
    try j.put(a, &result, "format", .{ .integer = 1 });
    try j.put(a, &result, "tasks", tasks);
    try j.put(a, &result, "conversations", conversations);
    return result;
}

fn applyChange(a: Allocator, graph: *Graph, change: Change) !void {
    switch (change.operation) {
        .submit => |request| {
            if (request.background and request.owner != null) return error.InactiveTaskOwner;
            try submit(a, graph, request, .run);
        },
        .create_conversation => |draft| try createConversation(a, graph, null, draft),
        .reserve => |plan| try reserve(graph, plan, change.now_ms),
        .handoff => |update| try handoff(a, graph, update.lease, update.step),
        .abort => |intent| {
            const entry = graph.tasks.getPtr(intent.id) orelse return error.UnknownTask;
            _ = mark(entry, intent.reason);
        },
        .abort_all => |include_background| for (graph.tasks.values()) |*entry| {
            if (entry.background) {
                if (include_background) _ = mark(entry, .requested);
            } else if (liveParent(graph, entry.*) == null) _ = mark(entry, .requested);
        },
        .abort_conversation => |scope| {
            if (!hasConversation(graph, scope.id)) return error.UnknownTaskConversation;
            abortScope(graph, scope.id, scope.include_background);
        },
        .memo => |saved| try memo(a, &graph.tasks, saved.lease, saved.key, saved.value),
        .documents => |change_docs| {
            const entry = try editingTask(&graph.tasks, change_docs.lease);
            try Document.apply(a, &entry.documents, &entry.document_revision, change_docs.edits);
        },
        .release => |lease| {
            const entry = try leaseTask(&graph.tasks, lease);
            const saved = entry.state.running.work;
            entry.state = .{ .pending = saved };
            entry.interrupted = true;
        },
        .restart => recover(&graph.tasks, true),
        .close => recover(&graph.tasks, false),
        .orphan => |id| {
            const entry = graph.tasks.getPtr(id) orelse return error.UnknownTask;
            if (entry.abort_reason == null or runnable(graph, id, entry.*, change.now_ms) != .cleanup) return error.TaskUnavailable;
            entry.state = .{ .completing = .{ .status = .orphaned, .value = j.string(@tagName(entry.abort_reason.?)) } };
            entry.memos = .null;
        },
    }
    reconcile(graph, change.now_ms);
}

fn abortScope(graph: *Graph, id: []const u8, include_background: bool) void {
    for (graph.tasks.values()) |*entry| {
        if (entry.state == .terminal or !inScope(graph, entry.*, id, include_background)) continue;
        _ = mark(entry, .requested);
    }
}
