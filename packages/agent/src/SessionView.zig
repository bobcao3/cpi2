//! Read-only projections of the published session journal. Neither opening a
//! view nor following it creates a Worker or takes over recovery.
const std = @import("std");
const p = @import("session_protocol");
const Journal = @import("SessionJournal.zig");
const luau = @import("LuauJournal.zig");
const application = @import("LuauContextJournal.zig");
const tasks = @import("TaskJournal.zig");
const j = @import("json.zig");
const Self = @This();
const Allocator = std.mem.Allocator;
const F = p.frames;
const same = std.mem.eql;

journal: Journal,
codec: application.Codec,

pub const Conversation = struct {
    id: []const u8 = tasks.main_conversation,
    min: usize = 50,
    max: ?usize = null,
    /// Initial inclusive starting journal sequence. Later entries are appended.
    from: ?u64 = null,
};

pub const Query = union(enum) {
    conversation: Conversation,
    task_graph,
    session: Conversation,

    fn window(self: Query) ?Conversation {
        return switch (self) {
            .conversation, .session => |value| value,
            .task_graph => null,
        };
    }
};

pub fn open(gpa: Allocator, io: std.Io, path: []const u8, id: []const u8, codec: application.Codec) !Self {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    return .{ .journal = try .openViewer(gpa, io, path, id, try luau.options(scratch.allocator(), codec)), .codec = codec };
}

pub fn deinit(self: *Self) void {
    self.journal.deinit();
    self.* = undefined;
}

pub fn revision(self: *const Self) u64 {
    return self.journal.sequence;
}

pub fn sessionId(self: *const Self) []const u8 {
    return self.journal.state.extensions.session_id;
}

pub fn fileInode(self: *const Self) u64 {
    return self.journal.inode.?;
}

/// Visit owned application messages in journal order, including inactive
/// branches. Each decoded entry is borrowed only for the callback.
pub fn visitApplicationEntries(self: *const Self, gpa: Allocator, scope: []const u8, context_ptr: anytype, comptime visit: anytype) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const root = same(u8, scope, application.main);
    const prefix = if (root) "" else try application.entryPrefix(gpa, scope);
    defer if (!root) gpa.free(prefix);
    const source = self.journal.source();
    const messages = &self.journal.state.messages;
    for (messages.keys(), messages.values()) |key, reference| {
        if (applicationId(key, root, prefix) == null) continue;
        try self.journal.io.checkCancel();
        _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
        const message = try source.message(reference);
        const entry = (try luau.decodeEntry(scratch.allocator(), message)) orelse return error.InvalidLuauRecord;
        try visit(context_ptr, entry.value);
    }
}

pub fn refresh(self: *Self) !bool {
    return self.journal.refreshViewer();
}

/// Materialized application document at the current published revision.
pub fn context(self: *const Self, gpa: Allocator, id: []const u8) !j.Document {
    if (!self.journal.state.contexts.contains(id)) return error.UnknownContext;
    var document = try j.Document.init(gpa, "{}");
    errdefer document.deinit();
    document.value = try luau.applicationContext(&self.journal, self.codec, document.allocator(), id);
    return document;
}

/// The caller owns the snapshot independently of this view and later refreshes.
pub fn snapshot(self: *const Self, gpa: Allocator, query: Query) !j.Document {
    var document = try j.Document.init(gpa, "{}");
    errdefer document.deinit();
    _ = try self.project(&document, query, null);
    try self.addRevision(&document);
    return document;
}

/// A serialized, cancellable pull watch. Revision changes while the consumer
/// is busy fold into its next snapshot. Keep the view and query alive for it.
pub fn watch(self: *Self, query: Query) Watch {
    return .{ .view = self, .query = query };
}

pub const Watch = struct {
    view: *Self,
    query: Query,
    seen: ?u64 = null,
    digest: ?[64]u8 = null,
    start: ?u64 = null,

    pub fn next(self: *Watch, gpa: Allocator) !j.Document {
        while (true) {
            _ = try self.view.refresh();
            if (self.seen != self.view.revision()) {
                if (try self.advance(gpa)) |document| return document;
            }
            try self.view.journal.io.sleep(.fromMilliseconds(50), .awake);
        }
    }

    fn advance(self: *Watch, gpa: Allocator) !?j.Document {
        var document = try j.Document.init(gpa, "{}");
        errdefer document.deinit();
        const start = try self.view.project(&document, self.query, self.start);
        const digest = try p.Canonical.hash(document.allocator(), document.value);
        const changed = if (self.digest) |previous| !same(u8, &previous, &digest) else true;
        if (changed) try self.view.addRevision(&document);
        self.seen = self.view.revision();
        self.start = start;
        self.digest = digest;
        if (changed) return document;
        document.deinit();
        return null;
    }
};

fn addRevision(self: *const Self, document: *j.Document) !void {
    const a = document.allocator();
    try j.put(a, &document.value, "revision", try j.project(a, self.revision()));
}

fn project(self: *const Self, document: *j.Document, query: Query, start: ?u64) !?u64 {
    const a = document.allocator();
    const stored = self.journal.state.extensions.get(tasks.namespace);
    const task_state = if (stored) |entry| entry.value else .null;
    if (query != .conversation)
        try j.put(a, &document.value, "task_graph", try projectTasks(a, task_state));
    const window = query.window() orelse return null;
    const view = try self.projectConversation(a, window, start, task_state);
    try j.put(a, &document.value, "conversation", view.value);
    return view.start;
}

const Entry = struct { id: []const u8, sequence: u64, entry: j.Value };

fn projectConversation(self: *const Self, a: Allocator, window: Conversation, start: ?u64, graph: j.Value) !struct { value: j.Value, start: u64 } {
    const max = window.max orelse window.min +| window.min;
    if (window.min == 0 or max < window.min) return error.InvalidConversationWindow;
    const state = &self.journal.state;
    const selected = state.contexts.get(window.id) orelse return error.UnknownContext;
    const record = tasks.conversationValue(graph, window.id);
    var newest: std.ArrayList(Entry) = .empty;
    var upper = self.revision();
    var scope = window.id;
    const source = self.journal.source();
    while (newest.items.len <= max) {
        const scoped = state.contexts.get(scope) orelse return error.UnknownContext;
        const limit = upper;
        const root = same(u8, scope, application.main);
        const prefix = try application.entryPrefix(a, scope);
        while (upper > scoped.created_at and newest.items.len <= max) : (upper -= 1) {
            const frame = try source.get(upper);
            if (try transcriptEntry(a, frame, scope, root, prefix)) |entry| try newest.append(a, entry);
        }
        if (newest.items.len > max or root) break;
        const parent = (try state.historyParent(source, scope)) orelse break;
        upper = @min(limit, parent.through);
        scope = try a.dupe(u8, parent.id);
    }
    var count = @min(window.min, newest.items.len);
    if (start orelse window.from) |from| {
        for (newest.items, 0..) |entry, i| {
            if (entry.sequence < from) {
                if (i <= max) count = i;
                break;
            }
        } else if (newest.items.len <= max) {
            count = newest.items.len;
        }
    }
    const entries = newest.items[0..count];
    const next = if (count > 0) entries[count - 1].sequence else self.revision() +| 1;
    std.mem.reverse(Entry, entries);
    const base = j.get(record, "base");
    const fork = j.get(base, "fork");
    const value = try j.project(a, .{
        .id = try a.dupe(u8, window.id),
        .owner = try j.copy(a, j.get(record, "owner")),
        .base = if (fork == .object) try j.projectOwned(a, .{
            .context = j.get(base, "context"),
            .at = j.get(base, "at"),
            .fork = .{ .parent = j.get(fork, "parent"), .anchor = j.get(fork, "anchor") },
        }) else try j.copy(a, base),
        .head = selected.head,
        .docs = try luau.viewDocuments(&self.journal, self.codec, a, window.id),
        .entries = entries,
        .before = if (count < newest.items.len) newest.items[count].id else null,
    });
    return .{ .value = value, .start = next };
}

fn transcriptEntry(a: Allocator, frame: *const F.Frame, scope: []const u8, root: bool, prefix: []const u8) !?Entry {
    switch (frame.action) {
        .@"document.message.append" => |append| {
            if (applicationId(append.message.id, root, prefix)) |id| {
                const entry = (try luau.decodeEntry(a, append.message)) orelse return error.InvalidLuauRecord;
                return .{ .id = try a.dupe(u8, id), .sequence = frame.seq, .entry = entry.value };
            }
            const placement = append.placement orelse return null;
            if (!same(u8, placement.context, scope)) return null;
            if (std.mem.startsWith(u8, append.message.id, "application/")) return null;
            return .{
                .id = try a.dupe(u8, append.message.id),
                .sequence = frame.seq,
                .entry = try j.projectOwned(a, append.message),
            };
        },
        .@"control.extension" => |change| {
            if (!same(u8, change.namespace, luau.markers_namespace)) return null;
            const key = j.text(j.get(change.input.value, "id"));
            const id = applicationId(key, root, prefix) orelse return null;
            return .{ .id = try a.dupe(u8, id), .sequence = frame.seq, .entry = try j.parse(a, j.text(j.get(change.input.value, "json"))) };
        },
        else => return null,
    }
}

fn applicationId(key: []const u8, root: bool, prefix: []const u8) ?[]const u8 {
    const stream = "application/";
    if (!std.mem.startsWith(u8, key, stream)) return null;
    const id = key[stream.len..];
    return if (root and !std.mem.startsWith(u8, id, "a/") or !root and std.mem.startsWith(u8, id, prefix)) id else null;
}

fn projectTasks(a: Allocator, value: j.Value) !j.Value {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const graph = try tasks.graphAt(temp, value);
    var conversations: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (graph.conversations.keys(), graph.conversations.values()) |id, record| {
        const owner = record.owner orelse continue;
        const existing = try conversations.getOrPut(temp, owner);
        if (!existing.found_existing) existing.value_ptr.* = .empty;
        try existing.value_ptr.append(temp, id);
    }
    var live = j.object();
    for (graph.tasks.keys(), graph.tasks.values()) |id, task| {
        if (task.state == .terminal) continue;
        const children = if (conversations.getPtr(id)) |owned| sorted: {
            std.mem.sort([]const u8, owned.items, {}, lessId);
            break :sorted owned.items;
        } else &.{};
        try j.put(a, &live, try a.dupe(u8, id), try j.projectOwned(a, .{
            .id = id,
            .kind = task.kind,
            .conversation = task.conversation,
            .owner = task.owner,
            .background = task.background,
            .abort_reason = task.abort_reason,
            .conversations = children,
            .state = .{
                .status = @tagName(task.state),
                .mode = if (task.state == .running) task.state.running.mode else null,
                .on = if (task.state == .waiting) task.state.waiting.on else null,
                .policy = if (task.state == .waiting) task.state.waiting.policy else null,
                .until_ms = if (task.state == .sleeping) task.state.sleeping.until_ms else null,
                .outcome = if (task.state == .completing) task.state.completing.status else null,
            },
        }));
    }
    return j.project(a, .{ .tasks = live });
}

fn lessId(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
