const std = @import("std");
const F = @import("SessionFrame.zig");
const Transaction = @import("SessionTransaction.zig");
const Extensions = @import("SessionExtensions.zig");
const Encoding = @import("SessionEncoding.zig");
const Canonical = @import("CanonicalJson.zig");
pub const ProjectionCache = @import("ProjectionCache.zig");
const Value = F.Value;
const Allocator = std.mem.Allocator;
const State = @This();

pub const ReplayTiming = struct {
    io: std.Io,
    extensions: i96 = 0,
    projection: i96 = 0,
    render: i96 = 0,
    hash: i96 = 0,

    fn start(self: *const ReplayTiming) std.Io.Timestamp {
        return .now(self.io, .awake);
    }

    fn elapsed(self: *const ReplayTiming, at: std.Io.Timestamp) i96 {
        return at.durationTo(self.start()).nanoseconds;
    }
};

pub const Source = struct {
    context: *const anyopaque,
    frame: *const fn (*const anyopaque, u64) anyerror!*const F.Frame,
    transaction: *const fn (*const anyopaque, Allocator, u64) anyerror!Transaction,
    /// Borrows a previously validated message from the source's immutable cache.
    /// A cache miss returns null and leaves the regular frame lookup available.
    borrow_message: ?*const fn (*const anyopaque, u64) ?F.Message = null,
    borrow_frame: ?*const fn (*const anyopaque, u64) ?*const F.Frame = null,
    projection_cache: ?*ProjectionCache = null,
    extension_replay: ?*Extensions.ReplayStorage = null,
    replay_timing: ?*ReplayTiming = null,
    pub fn get(self: Source, ref: u64) !*const F.Frame {
        return self.frame(self.context, ref);
    }
    /// May replace the source's most recently read frame on a cache miss.
    pub fn message(self: Source, ref: u64) !F.Message {
        if (self.borrow_message) |lookup| if (lookup(self.context, ref)) |cached| return cached;
        return (try self.get(ref)).action.@"document.message.append".message;
    }
    pub fn cut(self: Source, ref: u64) !void {
        if (ref == 0) return;
        const f = try self.get(ref);
        if (f.tx.index + 1 != f.tx.count) return error.UncommittedPosition;
    }
};
pub const Context = struct {
    head: u64 = 0,
    created_at: u64 = 0,
    ids: std.ArrayList([]const u8) = .empty,
    display_ids: std.ArrayList([]const u8) = .empty,
};
pub const Operation = struct { intent: u64, finish: ?u64 = null, cancelled: bool = false };
pub const ModelRequest = struct {
    intent: u64,
    input_at: u64,
    conversation: ?[]const u8 = null,
    finish: ?u64 = null,
    cancelled: bool = false,
    progress: ?u64 = null,
};
pub const Call = struct { message: []const u8, registration: u64, answered: ?u64 = null, conversation: ?[]const u8 = null };
pub const Projection = struct { instructions: Value, messages: Value, tools: Value };
const ProjectionHashes = struct {
    instructions: [64]u8,
    messages: [64]u8,
    tools: [64]u8,

    fn compute(a: Allocator, projection: Projection, cache: ?*ProjectionCache) anyerror!ProjectionHashes {
        return .{
            .instructions = try Canonical.hash(a, projection.instructions),
            .messages = if (cache) |memo| try memo.hashMessages(a, projection.messages) else try Canonical.hash(a, projection.messages),
            .tools = try Canonical.hash(a, projection.tools),
        };
    }
};

fn copyProjection(a: Allocator, projection: Projection, _: ?*ProjectionCache) anyerror!Projection {
    return F.copy(Projection, a, projection);
}

pub const Renderer = struct {
    version: F.Version,
    render: *const fn (Allocator, Snapshot, Value) anyerror!Projection,
    /// A renderer that reconstructs tool pairs can accept explicitly cut
    /// transcript ranges that contain only one side of a tool exchange.
    accepts_cut_tool_group: ?*const fn (Allocator, []const F.Message) anyerror!bool = null,
    accepts_historical_tool_group: ?*const fn (Allocator, Snapshot, []const F.Message) anyerror!bool = null,
};
pub const Snapshot = struct {
    state: *const State,
    source: Source,
    at: u64,
    context: []const u8,
    extensions: *const Extensions,
    model_only: bool = false,
    validated_messages: ?[]const F.Message = null,

    /// The IDs are borrowed until the next frame read through this source.
    pub fn inheritedForkMessages(self: Snapshot) ![]const []const u8 {
        const context = self.state.contexts.get(self.context) orelse return error.UnknownContext;
        if (context.created_at == 0 or context.created_at > self.at) return &.{};
        const creation = (try self.source.get(context.created_at)).action.@"control.context.create";
        const base = creation.base orelse return &.{};
        const fork = base.fork orelse return &.{};
        return fork.selected;
    }

    pub fn messages(self: Snapshot, a: Allocator) ![]const F.Message {
        return self.collectMessages(a, false);
    }

    fn collectMessages(self: Snapshot, a: Allocator, borrow: bool) ![]const F.Message {
        const ids = try self.state.contextAt(a, self.source, self.context, self.at);
        var out: std.ArrayList(F.Message) = .empty;
        try out.ensureTotalCapacity(a, ids.len);
        for (ids) |id| {
            if (self.model_only and self.state.displays.contains(id)) continue;
            const ref = self.state.messages.get(id) orelse return error.UnknownMessage;
            if (ref > self.at) return error.FutureReference;
            if (self.source.borrow_message) |lookup| {
                if (lookup(self.source.context, ref)) |message| {
                    out.appendAssumeCapacity(if (borrow) message else try F.copy(F.Message, a, message));
                    continue;
                }
            }
            const frame = try self.source.get(ref);
            out.appendAssumeCapacity(try F.copy(F.Message, a, frame.action.@"document.message.append".message));
        }
        return out.toOwnedSlice(a);
    }

    /// Borrow the already validated messages during the renderer call.
    pub fn messagesForRendering(self: Snapshot, a: Allocator) ![]const F.Message {
        return self.validated_messages orelse self.messages(a);
    }

    pub fn model(self: Snapshot, a: Allocator) !*const F.Frame {
        return self.modelFrame(a, false);
    }

    pub fn modelForRendering(self: Snapshot, a: Allocator) !*const F.Frame {
        return self.modelFrame(a, true);
    }

    fn modelFrame(self: Snapshot, a: Allocator, borrow: bool) !*const F.Frame {
        return self.ownOrBorrowFrame(a, try self.state.modelAt(self.source, self.at), borrow);
    }

    fn ownOrBorrowFrame(self: Snapshot, a: Allocator, reference: u64, borrow: bool) !*const F.Frame {
        if (borrow) if (self.source.borrow_frame) |lookup| {
            if (lookup(self.source.context, reference)) |frame| return frame;
        };
        const result = try a.create(F.Frame);
        result.* = try F.copy(F.Frame, a, (try self.source.get(reference)).*);
        return result;
    }

    pub fn tools(self: Snapshot, a: Allocator) ![]const *const F.Frame {
        return self.collectTools(a, false);
    }

    pub fn toolsForRendering(self: Snapshot, a: Allocator) ![]const *const F.Frame {
        return self.collectTools(a, true);
    }

    fn collectTools(self: Snapshot, a: Allocator, borrow: bool) ![]const *const F.Frame {
        var historical: std.StringArrayHashMapUnmanaged(u64) = .empty;
        var names = &self.state.tools;
        if (self.at < self.state.tools_changed_at or self.at > self.state.sequence) {
            names = &historical;
            var seq: u64 = 1;
            while (seq <= self.at) : (seq += 1) {
                const f = try self.source.get(seq);
                switch (f.action) {
                    .@"control.provider_tool.register" => |v| try historical.put(a, try a.dupe(u8, v.name), seq),
                    .@"control.provider_tool.deregister" => |v| _ = historical.orderedRemove(v.name),
                    else => {},
                }
            }
        }
        const keys = try a.dupe([]const u8, names.keys());
        std.mem.sort([]const u8, keys, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        const out = try a.alloc(*const F.Frame, keys.len);
        for (keys, out) |key, *entry| {
            entry.* = try self.ownOrBorrowFrame(a, names.get(key).?, borrow);
        }
        return out;
    }
};

gpa: Allocator,
arena: *std.heap.ArenaAllocator,
extensions: Extensions,
sequence: u64 = 0,
selected: []const u8 = "main",
model_frame: ?u64 = null,
bindings: std.StringArrayHashMapUnmanaged(u64) = .empty,
tools: std.StringArrayHashMapUnmanaged(u64) = .empty,
tools_changed_at: u64 = 0,
messages: std.StringArrayHashMapUnmanaged(u64) = .empty,
displays: std.StringArrayHashMapUnmanaged(u64) = .empty,
contexts: std.StringArrayHashMapUnmanaged(Context) = .empty,
requests: std.StringArrayHashMapUnmanaged(ModelRequest) = .empty,
effects: std.StringArrayHashMapUnmanaged(Operation) = .empty,
calls: std.StringArrayHashMapUnmanaged(Call) = .empty,
effect_keys: std.StringHashMapUnmanaged(void) = .empty,

pub fn init(gpa: Allocator, session: []const u8) !State {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var extensions = try Extensions.init(gpa, session);
    errdefer extensions.deinit();
    var state: State = .{ .gpa = gpa, .arena = arena, .extensions = extensions };
    try state.contexts.put(arena.allocator(), "main", .{});
    return state;
}

pub fn deinit(self: *State) void {
    self.extensions.deinit();
    self.arena.deinit();
    self.gpa.destroy(self.arena);
    self.* = undefined;
}

fn prepareExtensions(self: *const State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, scratch: *std.heap.ArenaAllocator) !Extensions {
    const start = if (source.replay_timing) |timing| timing.start() else null;
    defer if (start) |at| {
        const timing = source.replay_timing.?;
        timing.extensions += timing.elapsed(at);
    };
    return self.extensions.prepareWithReplay(transaction, contracts, scratch, source.extension_replay);
}

fn clone(self: *const State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, scratch: *std.heap.ArenaAllocator) !State {
    const arena = try self.gpa.create(std.heap.ArenaAllocator);
    errdefer self.gpa.destroy(arena);
    arena.* = .init(self.gpa);
    errdefer arena.deinit();
    var ext = try self.prepareExtensions(source, transaction, contracts, scratch);
    errdefer ext.deinit();
    var next: State = .{ .gpa = self.gpa, .arena = arena, .extensions = ext, .sequence = self.sequence, .selected = try arena.allocator().dupe(u8, self.selected), .model_frame = self.model_frame };
    next.tools_changed_at = self.tools_changed_at;
    const a = arena.allocator();
    inline for (.{ "bindings", "tools", "messages", "displays", "requests", "effects", "calls" }) |field| {
        for (@field(self, field).keys(), @field(self, field).values()) |key, item| try @field(next, field).put(a, try a.dupe(u8, key), try F.copy(@TypeOf(item), a, item));
    }
    var keys = self.effect_keys.keyIterator();
    while (keys.next()) |key| try next.effect_keys.put(a, try a.dupe(u8, key.*), {});
    for (self.contexts.keys(), self.contexts.values()) |key, context| {
        var owned: Context = .{ .head = context.head, .created_at = context.created_at };
        for (context.ids.items) |id| try owned.ids.append(a, try a.dupe(u8, id));
        for (context.display_ids.items) |id| try owned.display_ids.append(a, try a.dupe(u8, id));
        try next.contexts.put(a, try a.dupe(u8, key), owned);
    }
    return next;
}

pub fn prepare(self: *const State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, renderers: []const Renderer) !State {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.prepareWithScratch(source, transaction, contracts, renderers, &scratch);
}

fn prepareWithScratch(self: *const State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, renderers: []const Renderer, scratch: *std.heap.ArenaAllocator) !State {
    var next = try self.clone(source, transaction, contracts, scratch);
    errdefer next.deinit();
    try self.apply(&next, source, transaction, contracts, renderers, null, scratch.allocator());
    return next;
}

const ContextHeads = std.StringHashMapUnmanaged(u64);

/// Fast replay for a private owner that discards the entire state on error.
/// Published journals still build an independent candidate with prepare().
pub fn replayUnpublished(self: *State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, renderers: []const Renderer, scratch: *std.heap.ArenaAllocator) !void {
    defer _ = scratch.reset(.{ .retain_with_limit = 4 * 1024 * 1024 });
    var changed = false;
    for (transaction.frames) |owned| {
        const needs_base = switch (owned.frame.action) {
            .@"control.extension" => continue,
            .@"control.context.create" => |create| create.base != null,
            .@"control.model.request" => true,
            else => false,
        };
        if (changed and needs_base) {
            const candidate = try self.prepareWithScratch(source, transaction, contracts, renderers, scratch);
            self.deinit();
            self.* = candidate;
            return;
        }
        changed = true;
    }
    var extensions = try self.prepareExtensions(source, transaction, contracts, scratch);
    errdefer extensions.deinit();

    const temporary = scratch.allocator();
    var heads: ContextHeads = .empty;
    for (transaction.frames) |owned| {
        if (owned.frame.action != .@"control.document_mutation") continue;
        const name = owned.frame.action.@"control.document_mutation".context;
        const head = if (self.contexts.get(name)) |context| context.head else 0;
        try heads.put(temporary, name, head);
    }
    try self.apply(self, source, transaction, contracts, renderers, &heads, temporary);
    self.extensions.deinit();
    self.extensions = extensions;
}

fn apply(self: *const State, next: *State, source: Source, transaction: *const Transaction, contracts: []const Extensions.Contract, renderers: []const Renderer, heads: ?*const ContextHeads, temporary: Allocator) !void {
    const a = next.arena.allocator();
    for (transaction.frames) |owned| {
        const frame = owned.frame;
        switch (frame.action) {
            .@"capability.bind" => |v| {
                if (next.bindings.contains(v.name)) return error.DuplicateBinding;
                try next.bindings.put(a, try a.dupe(u8, v.name), frame.seq);
            },
            .@"capability.unbind" => |v| {
                if (next.bindings.get(v.name) != v.binding) return error.StaleBinding;
                _ = next.bindings.orderedRemove(v.name);
            },
            .@"control.set_model" => next.model_frame = frame.seq,
            .@"control.provider_tool.register" => |v| {
                if (next.tools.contains(v.name)) return error.DuplicateProviderTool;
                try next.tools.put(a, try a.dupe(u8, v.name), frame.seq);
                next.tools_changed_at = frame.seq;
            },
            .@"control.provider_tool.deregister" => |v| {
                if (next.tools.get(v.name) != v.registration) return error.StaleRegistration;
                _ = next.tools.orderedRemove(v.name);
                next.tools_changed_at = frame.seq;
            },
            .@"control.extension" => {},
            .@"document.message.append" => |v| {
                const m = v.message;
                if (next.messages.contains(m.id)) return error.DuplicateMessage;
                const message_id = try a.dupe(u8, m.id);
                if (v.source) |ref| {
                    if (ref >= frame.seq) return error.FutureReference;
                    _ = try source.get(ref);
                }
                if (v.request) |id| {
                    const request = next.requests.get(id) orelse return error.UnknownRequest;
                    if (request.finish != null) return error.TerminalRequest;
                }
                if (m.tool_calls) |calls| for (calls) |call| {
                    if (next.calls.contains(call.id)) return error.DuplicateToolCall;
                    const request = next.requests.get(v.request.?) orelse return error.UnknownRequest;
                    const registration = try next.toolAt(source, call.name, request.input_at);
                    try next.calls.put(a, try a.dupe(u8, call.id), .{
                        .message = message_id,
                        .registration = registration,
                        .conversation = request.conversation,
                    });
                };
                if (m.role == .tool) {
                    const call = next.calls.getPtr(m.tool_call_id.?) orelse return error.UnknownToolCall;
                    if (call.answered != null) return error.DuplicateToolResult;
                    call.answered = frame.seq;
                }
                try next.messages.put(a, message_id, frame.seq);
                if (v.display_only orelse false) try next.displays.put(a, message_id, frame.seq);
                if (v.placement) |p| {
                    const context = next.contexts.getPtr(p.context) orelse return error.UnknownContext;
                    const index = try insertionIndex(context.ids.items, p.after);
                    try context.ids.insert(a, index, message_id);
                    if (v.display_only orelse false) try context.display_ids.append(a, message_id);
                    context.head = frame.seq;
                }
            },
            .@"control.context.create" => |v| {
                if (next.contexts.contains(v.id)) return error.DuplicateContext;
                var context: Context = .{ .head = frame.seq, .created_at = frame.seq };
                if (v.base) |base| {
                    if (base.at > self.sequence) return error.UncommittedPosition;
                    try source.cut(base.at);
                    const ids = if (base.fork) |fork| blk: {
                        const anchor = try source.get(fork.anchor);
                        if (base.at != anchor.seq + (anchor.tx.count - anchor.tx.index - 1)) return error.UncommittedPosition;
                        const origin = (try self.historyOrigin(source, fork.parent, fork.anchor)) orelse return error.UnselectedAnchor;
                        if (!std.mem.eql(u8, origin, base.context)) return error.UnselectedAnchor;
                        var seen: std.StringHashMapUnmanaged(void) = .empty;
                        defer seen.deinit(temporary);
                        for (fork.selected) |entry| {
                            if ((self.messages.get(entry) orelse return error.UnknownMessage) > fork.anchor) return error.FutureReference;
                            if ((try seen.getOrPut(temporary, entry)).found_existing) return error.DuplicateSelection;
                        }
                        break :blk fork.selected;
                    } else try self.contextAt(temporary, source, base.context, base.at);
                    const end = if (base.through) |entry| (find(ids, entry) orelse return error.UnselectedAnchor) + 1 else ids.len;
                    for (ids[0..end]) |id| {
                        const owned_id = try a.dupe(u8, id);
                        try context.ids.append(a, owned_id);
                        if (self.displays.contains(id)) try context.display_ids.append(a, owned_id);
                    }
                }
                try next.contexts.put(a, try a.dupe(u8, v.id), context);
            },
            .@"control.context.select" => |v| {
                if (!next.contexts.contains(v.context)) return error.UnknownContext;
                next.selected = try a.dupe(u8, v.context);
            },
            .@"control.document_mutation" => |v| {
                const head = if (heads) |original| original.get(v.context).? else if (self.contexts.get(v.context)) |old| old.head else 0;
                if (head != v.expected_head) return error.StaleContextHead;
                const context = next.contexts.getPtr(v.context) orelse return error.UnknownContext;
                for (v.edits) |edit| switch (edit) {
                    .drop => |ids| for (ids) |id| {
                        _ = context.ids.orderedRemove(find(context.ids.items, id) orelse return error.UnselectedMessage);
                    },
                    .insert => |e| {
                        for (e.ids) |id| {
                            if (!next.messages.contains(id)) return error.UnknownMessage;
                            if (next.displays.contains(id) and find(context.display_ids.items, id) == null) try context.display_ids.append(a, try a.dupe(u8, id));
                        }
                        try insert(a, context, e.after, e.ids);
                    },
                };
                context.head = frame.seq;
            },
            .@"control.model.request" => |v| {
                if (next.requests.contains(v.request_id)) return error.DuplicateRequest;
                if (v.conversation) |scope| if (!self.contexts.contains(scope)) return error.UnknownContext;
                if (v.input_at > self.sequence) return error.UncommittedPosition;
                try source.cut(v.input_at);
                if (try self.modelAt(source, v.input_at) != v.model_frame) return error.StaleModel;
                const hashes = try self.projectWith(temporary, source, v.input_at, v.context, v.renderer, v.kwargs, contracts, renderers, ProjectionHashes, ProjectionHashes.compute);
                if (!std.mem.eql(u8, v.instructions_sha256, &hashes.instructions) or !std.mem.eql(u8, v.messages_sha256, &hashes.messages) or !std.mem.eql(u8, v.tools_sha256, &hashes.tools)) return error.ProjectionMismatch;
                try next.requests.put(a, try a.dupe(u8, v.request_id), .{
                    .intent = frame.seq,
                    .input_at = v.input_at,
                    .conversation = if (v.conversation) |scope| try a.dupe(u8, scope) else null,
                });
            },
            .@"control.model.progress" => |v| {
                const request = next.requests.getPtr(v.request_id) orelse return error.UnknownRequest;
                if (request.finish != null or request.cancelled) return error.TerminalRequest;
                if (request.progress) |ref| {
                    const previous_frame = if (ref <= self.sequence) try source.get(ref) else &transaction.frames[@intCast(ref - self.sequence - 1)].frame;
                    const previous = previous_frame.action.@"control.model.progress";
                    if (!std.mem.eql(u8, v.response_id, previous.response_id) or v.cursor < previous.cursor) return error.InvalidProviderProgress;
                    if (v.deferred) |deferred| {
                        const earlier = previous.deferred orelse return error.InvalidProviderProgress;
                        if (!std.mem.eql(u8, deferred.adapter, earlier.adapter) or v.next_poll_ms.? <= previous.next_poll_ms.?) return error.InvalidProviderProgress;
                        if (v.cursor == previous.cursor and !try @import("json_tree").equal(temporary, deferred.handle, earlier.handle)) return error.InvalidProviderProgress;
                    } else if (previous.deferred != null) return error.InvalidProviderProgress;
                }
                request.progress = frame.seq;
            },
            .@"control.model.finish" => |v| {
                const request = next.requests.getPtr(v.request_id) orelse return error.UnknownRequest;
                if (request.finish != null) return error.TerminalRequest;
                request.finish = frame.seq;
            },
            .@"control.effect.intent" => |v| {
                if (next.effects.contains(v.effect_id)) return error.DuplicateEffect;
                if (next.effect_keys.contains(v.key)) return error.DuplicateEffectKey;
                if (next.bindings.get(v.endpoint.name) != v.endpoint.binding) return error.StaleBinding;
                if (v.source_message) |id| if (!next.messages.contains(id)) return error.UnknownMessage;
                try next.effect_keys.put(a, try a.dupe(u8, v.key), {});
                try next.effects.put(a, try a.dupe(u8, v.effect_id), .{ .intent = frame.seq });
            },
            .@"control.effect.result" => |v| {
                const effect = next.effects.getPtr(v.effect_id) orelse return error.UnknownEffect;
                if (effect.finish) |ref| if ((try source.get(ref)).action.@"control.effect.result".status != .indeterminate) return error.TerminalEffect;
                effect.finish = frame.seq;
            },
            .@"control.cancel" => |v| {
                const target = try source.get(v.target);
                switch (target.action) {
                    .@"control.model.request" => |r| {
                        const request = next.requests.getPtr(r.request_id) orelse return error.UnknownRequest;
                        if (request.finish != null) return error.TerminalOperation;
                        request.cancelled = true;
                    },
                    .@"control.effect.intent" => |e| {
                        const effect = next.effects.getPtr(e.effect_id) orelse return error.UnknownEffect;
                        if (effect.finish) |ref| {
                            const settled = try source.get(ref);
                            if (settled.action != .@"control.effect.result" or settled.action.@"control.effect.result".status != .indeterminate) return error.TerminalOperation;
                        }
                        effect.cancelled = true;
                    },
                    else => return error.InvalidCancellationTarget,
                }
            },
        }
    }
    next.sequence = transaction.lastSequence();
}

fn find(ids: []const []const u8, wanted: []const u8) ?usize {
    for (ids, 0..) |id, i| if (std.mem.eql(u8, id, wanted)) return i;
    return null;
}
fn insertionIndex(ids: []const []const u8, after: ?[]const u8) !usize {
    const id = after orelse return 0;
    if (ids.len != 0 and std.mem.eql(u8, ids[ids.len - 1], id)) return ids.len;
    return (find(ids, id) orelse return error.UnselectedAnchor) + 1;
}

fn insert(a: Allocator, context: *Context, after: ?[]const u8, ids: []const []const u8) !void {
    var index = try insertionIndex(context.ids.items, after);
    for (ids) |id| {
        if (find(context.ids.items, id) != null) return error.DuplicateSelection;
        try context.ids.insert(a, index, try a.dupe(u8, id));
        index += 1;
    }
}

pub fn contextAt(self: *const State, a: Allocator, source: Source, id: []const u8, at: u64) ![]const []const u8 {
    const current = self.contexts.get(id) orelse return error.UnknownContext;
    if (at <= self.sequence and current.head <= at) return current.ids.items;
    const Segment = struct { id: []const u8, start: u64, end: u64, through: ?[]const u8 };
    var segments: std.ArrayList(Segment) = .empty;
    var wanted = id;
    var end = at;
    var through: ?[]const u8 = null;
    var seed: []const []const u8 = &.{};
    while (true) {
        const created_at = (self.contexts.get(wanted) orelse return error.UnknownContext).created_at;
        if (created_at > end) return error.UnknownContext;
        if (created_at != 0) {
            const f = try source.get(created_at);
            const create = f.action.@"control.context.create";
            try segments.append(a, .{ .id = try a.dupe(u8, wanted), .start = f.seq + 1, .end = end, .through = through });
            if (create.base) |base| {
                if (base.fork) |fork| {
                    seed = try F.copy([]const []const u8, a, fork.selected);
                    break;
                }
                wanted = try a.dupe(u8, base.context);
                end = base.at;
                through = if (base.through) |entry| try a.dupe(u8, entry) else null;
                continue;
            }
        } else {
            if (!std.mem.eql(u8, wanted, "main")) return error.UnknownContext;
            try segments.append(a, .{ .id = try a.dupe(u8, wanted), .start = 1, .end = end, .through = through });
        }
        break;
    }
    var context: Context = .{};
    try context.ids.appendSlice(a, seed);
    while (segments.pop()) |segment| {
        var seq = segment.start;
        while (seq <= segment.end) : (seq += 1) {
            const f = try source.get(seq);
            switch (f.action) {
                .@"document.message.append" => |v| if (v.placement) |p| {
                    if (std.mem.eql(u8, p.context, segment.id)) try insert(a, &context, p.after, &.{v.message.id});
                },
                .@"control.document_mutation" => |v| if (std.mem.eql(u8, v.context, segment.id)) {
                    for (v.edits) |edit| switch (edit) {
                        .drop => |ids| for (ids) |item| {
                            _ = context.ids.orderedRemove(find(context.ids.items, item) orelse return error.UnselectedMessage);
                        },
                        .insert => |e| try insert(a, &context, e.after, e.ids),
                    };
                },
                else => {},
            }
        }
        if (segment.through) |entry| context.ids.shrinkRetainingCapacity((find(context.ids.items, entry) orelse return error.UnselectedAnchor) + 1);
    }
    return context.ids.items;
}

pub const HistoryParent = struct { id: []const u8, through: u64 };

/// The structural ancestry is independent of the active model projection.
/// Returned parent IDs are borrowed from the journal's current frame cache.
pub fn historyParent(self: *const State, source: Source, id: []const u8) !?HistoryParent {
    const context = self.contexts.get(id) orelse return error.UnknownContext;
    if (context.created_at == 0) return null;
    const creation = (try source.get(context.created_at)).action.@"control.context.create";
    const base = creation.base orelse return null;
    if (base.fork) |fork| return .{ .id = fork.parent, .through = fork.anchor };
    const through = if (base.through) |entry| @min(base.at, self.messages.get(entry) orelse return error.UnknownMessage) else base.at;
    return .{ .id = base.context, .through = through };
}

/// Resolve which segment of a conversation's ancestry covers a journal frame.
/// The caller confirms the frame is an entry written by the returned context.
pub fn historyOrigin(self: *const State, source: Source, conversation: []const u8, entry: u64) !?[]const u8 {
    var scope = conversation;
    while (true) {
        const index = self.contexts.getIndex(scope) orelse return error.UnknownContext;
        if (entry > self.contexts.values()[index].created_at) return self.contexts.keys()[index];
        const parent = (try self.historyParent(source, scope)) orelse return null;
        if (entry > parent.through) return null;
        scope = parent.id;
    }
}

pub fn modelAt(self: *const State, source: Source, at: u64) !u64 {
    if (at <= self.sequence) {
        const current = self.model_frame orelse return error.NoModel;
        if (current <= at) return current;
    }
    var seq = at;
    while (seq > 0) : (seq -= 1) if ((try source.get(seq)).action == .@"control.set_model") return seq;
    return error.NoModel;
}
fn toolAt(self: *const State, source: Source, name: []const u8, at: u64) !u64 {
    if (at >= self.tools_changed_at) return self.tools.get(name) orelse error.UnknownProviderTool;
    var seq = at;
    while (seq > 0) : (seq -= 1) switch ((try source.get(seq)).action) {
        .@"control.provider_tool.register" => |v| if (std.mem.eql(u8, name, v.name)) return seq,
        .@"control.provider_tool.deregister" => |v| if (std.mem.eql(u8, name, v.name)) return error.UnknownProviderTool,
        else => {},
    };
    return error.UnknownProviderTool;
}

pub fn extensionsAt(self: *const State, source: Source, at: u64, contracts: []const Extensions.Contract) !Extensions {
    if (at > self.sequence) return error.UncommittedPosition;
    try source.cut(at);
    var past = try Extensions.init(self.gpa, self.extensions.session_id);
    errdefer past.deinit();
    var seq: u64 = 1;
    while (seq <= at) {
        var transaction = try source.transaction(source.context, self.gpa, seq);
        defer transaction.deinit();
        const candidate = try past.prepare(&transaction, contracts);
        past.deinit();
        past = candidate;
        seq = transaction.lastSequence() + 1;
    }
    return past;
}

pub fn project(self: *const State, a: Allocator, source: Source, at: u64, context: []const u8, version: F.Version, kwargs: Value, contracts: []const Extensions.Contract, renderers: []const Renderer) !Projection {
    return self.projectWith(a, source, at, context, version, kwargs, contracts, renderers, Projection, copyProjection);
}

fn projectWith(self: *const State, a: Allocator, source: Source, at: u64, context: []const u8, version: F.Version, kwargs: Value, contracts: []const Extensions.Contract, renderers: []const Renderer, comptime Result: type, comptime finish: fn (Allocator, Projection, ?*ProjectionCache) anyerror!Result) !Result {
    const timing = if (Result == ProjectionHashes) source.replay_timing else null;
    const started = if (timing) |t| t.start() else null;
    defer if (timing) |t| {
        t.projection += t.elapsed(started.?);
    };
    var renderer: ?Renderer = null;
    for (renderers) |r| if (std.mem.eql(u8, r.version.id, version.id) and std.mem.eql(u8, r.version.version, version.version)) {
        if (renderer != null) return error.DuplicateRenderer;
        renderer = r;
    };
    const chosen = renderer orelse return error.MissingRenderer;
    var past: ?Extensions = null;
    defer if (past) |*state| state.deinit();
    if (at != self.sequence) past = try self.extensionsAt(source, at, contracts) else try source.cut(at);
    var snapshot: Snapshot = .{ .state = self, .source = source, .at = at, .context = context, .extensions = if (past) |*state| state else &self.extensions, .model_only = true };
    const messages = try snapshot.collectMessages(a, true);
    validateToolGroups(a, messages, null) catch |err| switch (err) {
        error.IncompleteToolGroup, error.UnmatchedToolResult => {
            const explicit_cut = if (chosen.accepts_cut_tool_group) |accepts| try accepts(a, messages) else false;
            if (!explicit_cut) {
                const accepts = chosen.accepts_historical_tool_group orelse return err;
                if (!try accepts(a, snapshot, messages)) return err;
            }
        },
        else => return err,
    };
    snapshot.validated_messages = messages;
    const render_start = if (timing) |t| t.start() else null;
    const projection = try chosen.render(a, snapshot, kwargs);
    const hash_start = if (timing) |t| blk: {
        t.render += t.elapsed(render_start.?);
        break :blk t.start();
    } else null;
    defer if (timing) |t| {
        t.hash += t.elapsed(hash_start.?);
    };
    return finish(a, projection, source.projection_cache);
}

pub fn validateToolGroups(a: Allocator, messages: []const F.Message, inherited: ?*const std.StringHashMapUnmanaged(void)) !void {
    var pending: std.StringHashMapUnmanaged(bool) = .empty;
    defer pending.deinit(a);
    var required: usize = 0;
    for (messages) |m| {
        const may_be_cut = if (inherited) |ids| ids.contains(m.id) else false;
        if (m.role == .tool) {
            if (pending.fetchRemove(m.tool_call_id.?)) |call| {
                if (call.value) required -= 1;
            } else if (!may_be_cut) return error.UnmatchedToolResult;
        } else {
            if (required != 0) return error.IncompleteToolGroup;
            pending.clearRetainingCapacity();
            if (m.tool_calls) |calls| for (calls) |call| {
                const entry = try pending.getOrPut(a, call.id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = !may_be_cut;
                    if (!may_be_cut) required += 1;
                }
            };
        }
    }
    if (required != 0) return error.IncompleteToolGroup;
}

pub const standard_renderer: Renderer = .{ .version = .{ .id = "session.messages", .version = "1" }, .render = standardRender };
pub fn standardRender(a: Allocator, snapshot: Snapshot, _: Value) !Projection {
    var instructions: Value = .{ .array = .init(a) };
    var messages: Value = .{ .array = .init(a) };
    var tools: Value = .{ .array = .init(a) };
    for (try snapshot.messagesForRendering(a)) |m| {
        const encoded = try Encoding.value(a, m);
        if (m.role == .system or m.role == .developer) try instructions.array.append(encoded) else try messages.array.append(encoded);
    }
    for (try snapshot.toolsForRendering(a)) |f| try tools.array.append(f.action.@"control.provider_tool.register".definition);
    return .{ .instructions = instructions, .messages = messages, .tools = tools };
}
