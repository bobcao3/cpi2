const std = @import("std");
pub const api = @import("protocol.zig");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const ContextCodec = @import("LuauContextJournal.zig");
const PreparedJournal = @import("PreparedJournal.zig");
const semantic = @import("session_protocol");
pub const j = @import("json.zig");
const event_types = @import("events.zig");
const vm_types = @import("vm");
const logic = @import("logic.zig");
const io = @import("io.zig");
const Conversation = @import("Conversation.zig");
const Worker = @This();

pub const Value = j.Value;
pub const HistoryStream = enum { application, conversation };
pub const ApplicationCut = union(enum) {
    current,
    at: u64,
    before_creation: []const u8,
};
pub const HistoryQuery = struct {
    stream: HistoryStream,
    conversation: []const u8 = ContextCodec.main,
    id: ?[]const u8 = null,
    before: ?u64 = null,
    /// Weave display entries into the selected application transcript.
    /// Without an id, returns the selected display entry at the tail, if any.
    selected_display: bool = false,
    include_display_parent: bool = false,
};
pub const ApplicationFork = Persistence.ApplicationFork;
pub const HistoryRecord = struct {
    document: j.Document,
    value: Value,
    key: []u8,
    reference: u64,
    display_parent: ?[]const u8 = null,
    pub fn deinit(self: *HistoryRecord) void {
        self.document.gpa.free(self.key);
        self.document.deinit();
        self.* = undefined;
    }
};
pub const HistoryPage = struct {
    document: j.Document,
    before: ?u64,
};
pub const HistoryProjection = struct {
    stream: HistoryStream,
    conversation: []const u8 = ContextCodec.main,
    before: ?u64 = null,
    fields: []const []const u8,
    /// Include the preceding display-only entry from the message's commit.
    include_display_parent: bool = false,
};
const HistoryEntry = struct { key: []const u8, value: Value, reference: u64 };

pub const Notice = struct { kind: u32, request: []const u8 = "", payload: Value = .null };
pub const Admission = struct { id: []u8, kind: u32, payload: j.Document, registered: ?*vm_types.RegisteredTool = null };
pub const Operation = struct {
    id: u64,
    kind: enum { http, effect },
    invocation: []u8,
    data: std.ArrayList(u8) = .empty,
    meta: ?j.Document = null,
    terminal: bool = false,
    cancelled: bool = false,
    obsolete: bool = false,
    semantic_effect: ?u64 = null,
    semantic_model: ?u64 = null,
};
pub const Reply = struct { operation: u64, kind: u32, bytes: []u8 };

gpa: std.mem.Allocator,
io_backend: std.Io,
journal: Journal,
journal_open: bool = false,
application_size_warnings: ?semantic.Transaction.SizeSink = null,
recovery_pending: bool = false,
context_codec: ContextCodec.Codec = ContextCodec.default,
application_bindings: ContextCodec.ApplicationBindings = .{},
session_id: []u8,
workspace: []u8,
journal_uri: []u8,
options: j.Document,
initial: j.Document,
state: j.Document,
sequence: u64 = 0,
admissions: std.ArrayList(Admission) = .empty,
operations: std.ArrayList(Operation) = .empty,
replies: std.ArrayList(Reply) = .empty,
events: std.ArrayList(*event_types.Event) = .empty,
event_bytes: usize = 0,
next_operation: u64 = 1,
next_lease: u64 = 1,
opened: bool = false,
ready: bool = false,
failed: bool = false,
first_failure: ?anyerror = null,
closed: bool = false,
heap: vm_types.Owner,
registered_capabilities: std.ArrayList(*vm_types.RegisteredTool) = .empty,
capabilities_prepared: bool = false,
bootstrap: bool = false,
bootstrap_request: ?[]const u8 = null,
active_capabilities: std.ArrayList(*vm_types.RegisteredTool) = .empty,
suspended_capabilities: std.ArrayList(*vm_types.RegisteredTool) = .empty,
pending_capabilities: std.ArrayList(struct { id: []u8, capability: *vm_types.RegisteredTool }) = .empty,
vm: ?vm_types.Vm = null,
vm_reply: ?[]u8 = null,
vm_reply_failed: bool = false,
external: ?u64 = null,
max_rounds: ?u64 = null,

const Options = union(enum) { json: []const u8, value: Value };

pub fn init(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: []const u8, seed: Value) !*Worker {
    return initObserved(gpa, backend, id, directory, uri, options, seed, null);
}

pub fn initObserved(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: []const u8, seed: Value, size_warnings: ?@import("session_protocol").Transaction.SizeSink) !*Worker {
    return initOptions(gpa, backend, id, directory, uri, .{ .json = options }, seed, ContextCodec.default, size_warnings, null);
}

pub fn initValue(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: Value, seed: Value, codec: ContextCodec.Codec, size_warnings: ?@import("session_protocol").Transaction.SizeSink, prepared: ?*PreparedJournal) !*Worker {
    return initOptions(gpa, backend, id, directory, uri, .{ .value = options }, seed, codec, size_warnings, prepared);
}

fn openJournal(gpa: std.mem.Allocator, backend: std.Io, uri: []const u8, id: []const u8, codec: ContextCodec.Codec, size_warnings: ?@import("session_protocol").Transaction.SizeSink) !Journal {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var journal_options = try Persistence.options(scratch.allocator(), codec);
    journal_options.pipeline_replay = vm_types.MemoryBudget.fromAllocator(gpa) != null;
    if (size_warnings) |reporter| journal_options.size_warnings = reporter;
    return Journal.open(gpa, backend, uri, id, journal_options);
}

fn initOptions(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: Options, seed: Value, codec: ContextCodec.Codec, size_warnings: ?@import("session_protocol").Transaction.SizeSink, prepared: ?*PreparedJournal) !*Worker {
    var opening = if (prepared == null) try backend.concurrent(openJournal, .{ gpa, backend, uri, id, codec, size_warnings }) else null;
    defer if (opening) |*future| {
        if (future.cancel(backend) catch null) |result| {
            var abandoned = result;
            abandoned.deinit();
        }
    };
    const self = try prepareOptions(gpa, backend, id, directory, uri, options, seed, codec);
    errdefer self.deinit();
    self.journal = if (prepared) |journal| try journal.take(gpa, backend, uri, id, codec, size_warnings) else blk: {
        const result = opening.?.await(backend);
        opening = null;
        break :blk try result;
    };
    self.journal_open = true;
    return self;
}

pub fn prepare(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: []const u8, seed: Value) !*Worker {
    return prepareOptions(gpa, backend, id, directory, uri, .{ .json = options }, seed, ContextCodec.default);
}

fn prepareOptions(gpa: std.mem.Allocator, backend: std.Io, id: []const u8, directory: []const u8, uri: []const u8, options: Options, seed: Value, codec: ContextCodec.Codec) !*Worker {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id) or uri.len == 0)
        return error.InvalidArgument;
    const self = try gpa.create(Worker);
    errdefer gpa.destroy(self);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    const owned_directory = try gpa.dupe(u8, directory);
    errdefer gpa.free(owned_directory);
    const owned_uri = try gpa.dupe(u8, uri);
    errdefer gpa.free(owned_uri);
    var parsed_options = try switch (options) {
        .json => |bytes| j.Document.init(gpa, if (bytes.len == 0) "{}" else bytes),
        .value => |value| blk: {
            try j.validate(a, value);
            break :blk j.Document.initValue(gpa, value);
        },
    };
    errdefer parsed_options.deinit();
    if (parsed_options.value != .object) return error.InvalidArgument;
    const recovery = j.get(parsed_options.value, "recovery");
    if (recovery != .null) {
        if (recovery != .object) return error.InvalidArgument;
        if (recovery.object.get("queued")) |queued| {
            if (queued != .string or (!std.mem.eql(u8, queued.string, "fail") and !std.mem.eql(u8, queued.string, "resume"))) return error.InvalidArgument;
        }
    }
    const tokens = j.get(parsed_options.value, "max_output_tokens");
    if (tokens != .null and (tokens != .integer or tokens.integer < 1 or tokens.integer > std.math.maxInt(u32))) return error.InvalidArgument;
    try j.validate(a, seed);
    var initial = try j.Document.initValue(gpa, seed);
    errdefer initial.deinit();
    var state = try j.Document.init(gpa, Conversation.initial);
    errdefer state.deinit();
    self.* = .{
        .gpa = gpa,
        .io_backend = backend,
        .journal = undefined,
        .heap = undefined,
        .session_id = owned_id,
        .workspace = owned_directory,
        .journal_uri = owned_uri,
        .options = parsed_options,
        .context_codec = codec,
        .initial = initial,
        .state = state,
    };
    const limits = j.get(self.options.value, "limits");
    if (limits == .object) {
        var fields = limits.object.iterator();
        while (fields.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "max_rounds")) return error.InvalidArgument;
            if (entry.value_ptr.* == .null) continue;
            if (entry.value_ptr.* != .integer or entry.value_ptr.integer <= 0) return error.InvalidArgument;
        }
    }
    const rounds = j.number(j.get(limits, "max_rounds"));
    if (rounds > 0) self.max_rounds = @intCast(rounds);
    self.heap = try vm_types.Owner.init(gpa, backend);
    return self;
}

pub fn deinit(self: *Worker) void {
    if (self.vm) |*runner| runner.deinit();
    self.clearVmReply();
    for (self.admissions.items) |item| if (item.registered) |tool| tool.release();
    self.releasePins(&self.registered_capabilities);
    self.releasePins(&self.active_capabilities);
    self.releasePins(&self.suspended_capabilities);
    for (self.pending_capabilities.items) |item| {
        self.gpa.free(item.id);
        item.capability.release();
    }
    self.pending_capabilities.deinit(self.gpa);
    self.heap.deinit();
    if (self.journal_open) self.journal.deinit();
    for (self.admissions.items) |*item| {
        self.gpa.free(item.id);
        item.payload.deinit();
    }
    self.admissions.deinit(self.gpa);
    for (self.operations.items) |*operation| {
        self.gpa.free(operation.invocation);
        operation.data.deinit(self.gpa);
        if (operation.meta) |*meta| meta.deinit();
    }
    self.operations.deinit(self.gpa);
    for (self.replies.items) |reply| self.gpa.free(reply.bytes);
    self.replies.deinit(self.gpa);
    for (self.events.items) |event| event.deinit(self.gpa);
    self.events.deinit(self.gpa);
    self.options.deinit();
    self.initial.deinit();
    self.state.deinit();
    self.gpa.free(self.session_id);
    self.gpa.free(self.workspace);
    self.gpa.free(self.journal_uri);
    self.gpa.destroy(self);
}

pub fn admit(self: *Worker, id: []const u8, kind: u32, payload: []const u8) !void {
    return self.admitRegistered(id, kind, payload, null);
}
pub fn admitRegistered(self: *Worker, id: []const u8, kind: u32, payload: []const u8, registered: ?*vm_types.RegisteredTool) !void {
    if (self.closed or self.failed or j.flag(j.get(self.state.value, "closing"))) return error.InvalidState;
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidArgument;
    if (kind < 1 or kind > 13) return error.InvalidArgument;
    if ((kind == 9 or kind == 10 or kind == 11) and j.get(self.state.value, "active") != .null) return error.InvalidState;
    var document = try j.Document.init(self.gpa, payload);
    errdefer document.deinit();
    if (document.value != .object) return error.InvalidArgument;
    if (registered) |tool| {
        if (kind != 6 or !tool.belongsTo(&self.heap) or !std.mem.eql(u8, tool.source(), j.text(j.get(document.value, "source")))) return error.InvalidExtension;
    }
    const field = if (kind == 4 or kind == 6) "source" else if (kind == 7) "name" else "content";
    if (kind <= 7 and kind != 3 and kind != 5) {
        const content = j.get(document.value, field);
        if (content != .string or content.string.len == 0) return error.InvalidArgument;
    }
    if (kind == 12 or kind == 13) {
        const target = j.get(document.value, "replace");
        if (target != .null and (target != .string or target.string.len == 0 or std.mem.eql(u8, target.string, id))) return error.InvalidArgument;
        if (kind == 13 and target != .string) return error.InvalidArgument;
    }
    if (kind == 12) {
        if (j.get(self.options.value, "application") != .object) return error.NoApplication;
        const boundary = j.get(document.value, "boundary");
        if (boundary != .null and boundary != .bool) return error.InvalidArgument;
        if (j.flag(boundary) and j.get(document.value, "replace") == .null) return error.InvalidArgument;
        const conversation = j.get(document.value, "conversation");
        if (conversation != .null) {
            if (conversation != .string) return error.InvalidArgument;
            if (!std.mem.eql(u8, conversation.string, ContextCodec.main) and
                (!self.context_codec.scoped_application or !self.journal.state.contexts.contains(conversation.string))) return error.UnknownContext;
        }
        const binding = j.get(document.value, "application_model");
        if (binding != .null) {
            if (!self.context_codec.scoped_application) return error.InvalidArgument;
            const application_model = try std.json.parseFromValueLeaky(@import("config.zig").ApplicationModel, document.allocator(), binding, .{});
            if (application_model.selection != .object or application_model.model.credential.len == 0 or
                application_model.model.model.len == 0 or application_model.model.max_output_tokens == 0) return error.InvalidArgument;
            _ = try @import("responses.zig").url(document.allocator(), .{ .base_url = application_model.model.base_url });
        }
        _ = try j.parse(document.allocator(), j.text(j.get(document.value, "input_json")));
    }
    if (kind == 2) {
        const policy = j.get(document.value, "policy");
        if (policy != .null and !std.mem.eql(u8, j.text(policy), "at_boundary") and !std.mem.eql(u8, j.text(policy), "interrupt_generation")) return error.InvalidArgument;
    }
    for (self.admissions.items) |admission| {
        if (!std.mem.eql(u8, admission.id, id)) continue;
        if (admission.kind != kind or !(try j.equal(self.gpa, admission.payload.value, document.value))) return error.RequestConflict;
        document.deinit();
        return;
    }
    if (self.command(id)) |old| {
        if (j.number(j.get(old, "kind")) != kind or !(try j.equal(self.gpa, j.get(old, "payload"), document.value))) return error.RequestConflict;
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_COMMITTED, 0, self.sequence, id, "", .null);
        if (!std.mem.eql(u8, j.text(j.get(old, "status")), "queued") and !std.mem.eql(u8, j.text(j.get(old, "status")), "running")) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, id, "", try self.expandOutcome(arena.allocator(), j.get(old, "outcome")));
        }
        document.deinit();
        return;
    }
    if (try self.recordedCommand(self.gpa, id)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        const old = receipt.value;
        if (j.number(j.get(old, "kind")) != kind or !(try j.equal(self.gpa, j.get(old, "payload"), document.value))) return error.RequestConflict;
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_COMMITTED, 0, self.sequence, id, "", .null);
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, id, "", j.get(old, "outcome"));
        document.deinit();
        return;
    }
    const owned_id = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(owned_id);
    try self.admissions.ensureUnusedCapacity(self.gpa, 1);
    self.admissions.appendAssumeCapacity(.{ .id = owned_id, .kind = kind, .payload = document, .registered = if (registered) |tool| tool.retain() else null });
}

pub fn command(self: *Worker, id: []const u8) ?Value {
    const commands = j.get(self.state.value, "commands");
    for (commands.array.items) |command_value| if (std.mem.eql(u8, j.text(j.get(command_value, "id")), id)) return command_value;
    return null;
}

fn makeHistoryRecord(allocator: std.mem.Allocator, key: []const u8, value: Value, reference: u64) !HistoryRecord {
    var document = try j.Document.initValue(allocator, value);
    errdefer document.deinit();
    return .{ .document = document, .value = document.value, .key = try allocator.dupe(u8, key), .reference = reference };
}

pub fn recordedCommand(self: *Worker, allocator: std.mem.Allocator, id: []const u8) !?HistoryRecord {
    if (!self.journal_open) return null;
    const commands = self.journal.state.extensions.get(Persistence.commands_namespace) orelse return null;
    const encoded = commands.value.object.get(id) orelse return null;
    var document = try j.Document.init(allocator, encoded.string);
    errdefer document.deinit();
    return .{ .document = document, .value = document.value, .key = try allocator.dupe(u8, id), .reference = commands.head };
}

pub fn commandReceipt(self: *Worker, allocator: std.mem.Allocator, id: []const u8) !j.Document {
    if (self.journal.state.extensions.get(Persistence.commands_namespace)) |commands| {
        if (commands.value.object.get(id)) |encoded| return j.Document.init(allocator, encoded.string);
    }
    return j.Document.initValue(allocator, .null);
}

pub fn applicationHistoryJson(self: *Worker, scratch: std.mem.Allocator, scope: []const u8, id: []const u8) !?[]const u8 {
    if (self.context_codec.scoped_application and !try Persistence.visibleApplicationEntry(&self.journal, scratch, scope, id)) return null;
    return Persistence.historyText(&self.journal, "application", id);
}

pub fn clearVmReply(self: *Worker) void {
    if (self.vm_reply) |bytes| self.gpa.free(bytes);
    self.vm_reply = null;
}

pub fn historyRecord(self: *Worker, allocator: std.mem.Allocator, stream: HistoryStream, id: []const u8) !?HistoryRecord {
    var document = try j.Document.initValue(allocator, .null);
    errdefer document.deinit();
    const a = document.allocator();
    const key = try Persistence.historyId(a, @tagName(stream), id);
    const item = (try Persistence.history(&self.journal, a, @tagName(stream), id)) orelse {
        document.deinit();
        return null;
    };
    document.value = item;
    if (self.journal.state.messages.get(key)) |reference| return .{ .document = document, .value = item, .key = try allocator.dupe(u8, key), .reference = reference };
    var seq = self.journal.sequence;
    while (seq > 0) : (seq -= 1) {
        const frame = try self.journal.source().get(seq);
        if (frame.action != .@"control.extension") continue;
        const action = frame.action.@"control.extension";
        if (std.mem.eql(u8, action.namespace, Persistence.markers_namespace) and std.mem.eql(u8, j.text(j.get(action.input.value, "id")), key)) return .{ .document = document, .value = item, .key = try allocator.dupe(u8, key), .reference = seq };
    }
    return error.InvalidJournal;
}

pub fn readHistory(self: *Worker, allocator: std.mem.Allocator, query: HistoryQuery) !?HistoryRecord {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const scoped_application = self.context_codec.scoped_application and query.stream == .application;
    if (query.selected_display and query.stream == .application and query.before == null) {
        const context = self.journal.state.contexts.get(query.conversation) orelse return error.UnknownContext;
        const prefix = "application/";
        const id = query.id orelse blk: {
            const tail = context.ids.getLastOrNull() orelse return null;
            if (!std.mem.startsWith(u8, tail, prefix) or !self.journal.state.displays.contains(tail)) return null;
            break :blk tail[prefix.len..];
        };
        if (context.display_ids.items.len != 0) {
            const key = try Persistence.historyId(a, "application", id);
            var entries = std.mem.reverseIterator(context.ids.items);
            while (entries.next()) |entry| {
                if (!std.mem.eql(u8, entry, key)) continue;
                while (entries.next()) |parent| {
                    if (!std.mem.startsWith(u8, parent, prefix)) continue;
                    if (self.journal.state.displays.contains(parent)) {
                        var item = (try Persistence.history(&self.journal, a, "application", id)) orelse return error.UnknownEntry;
                        try j.put(a, &item, "parent", j.string(parent[prefix.len..]));
                        return try makeHistoryRecord(allocator, key, item, self.journal.state.messages.get(key) orelse return error.UnknownMessage);
                    }
                    break;
                }
                break;
            }
        }
        if (query.id == null) return self.historyRecord(allocator, .application, id);
    }
    if (query.id) |id| {
        if (scoped_application and !try Persistence.visibleApplicationEntry(&self.journal, a, query.conversation, id)) return null;
        var record = (try self.historyRecord(allocator, query.stream, id)) orelse return null;
        errdefer record.deinit();
        if (query.include_display_parent and query.stream == .application and self.journal.state.displays.count() != 0) {
            const origin = (try self.journal.state.historyOrigin(self.journal.source(), query.conversation, record.reference)) orelse return record;
            record.display_parent = try Persistence.recordedDisplayParent(&self.journal, record.document.allocator(), origin, record.key, record.reference);
        }
        return record;
    }
    const seq = query.before orelse (self.journal.sequence + 1);
    if (seq > self.journal.sequence + 1) return error.InvalidReference;
    var scan = self.historyScan(seq);
    const found = (try self.nextHistory(&scratch, &scan, query.stream, query.conversation)) orelse return null;
    return try makeHistoryRecord(allocator, found.key, found.value, found.reference);
}

/// Read newest first under a single Worker lease. Only requested fields leave
/// scratch storage. A page ending before exhaustion resumes at its last record.
pub fn projectHistory(self: *Worker, allocator: std.mem.Allocator, query: HistoryProjection) !HistoryPage {
    const seq = query.before orelse (self.journal.sequence + 1);
    if (seq > self.journal.sequence + 1) return error.InvalidReference;
    var scan = self.historyScan(seq);
    var document = try j.Document.initValue(allocator, .null);
    errdefer document.deinit();
    const a = document.allocator();
    document.value = j.array(a);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var next: ?u64 = null;
    for (0..128) |_| {
        const found = (try self.nextHistory(&scratch, &scan, query.stream, query.conversation)) orelse return .{ .document = document, .before = null };
        var row = j.object();
        if (found.value == .object) for (query.fields) |key| {
            if (found.value.object.get(key)) |value| try j.put(a, &row, try a.dupe(u8, key), try j.copy(a, value));
        };
        if (query.include_display_parent and query.stream == .application and self.journal.state.displays.count() != 0) {
            // A frame read can replace the cache that lent us the message ID.
            const key = try scratch.allocator().dupe(u8, found.key);
            if (try Persistence.recordedDisplayParent(&self.journal, a, query.conversation, key, found.reference)) |parent|
                try j.put(a, &row, "display_parent", j.string(parent));
        }
        try document.value.array.append(row);
        next = found.reference;
    }
    return .{ .document = document, .before = next };
}

const HistoryScan = struct { seq: u64, messages: ?[]const u64, index: usize };

fn historyScan(self: *const Worker, seq: u64) HistoryScan {
    // Message references are inserted in sequence order during replay. Branch
    // markers live in a separate extension and still need the merged scan.
    const messages = if (self.journal.state.extensions.get(Persistence.markers_namespace) == null)
        self.journal.state.messages.values()
    else
        null;
    const index = if (messages) |refs| std.sort.lowerBound(u64, refs, seq, struct {
        fn compare(before: u64, reference: u64) std.math.Order {
            return std.math.order(before, reference);
        }
    }.compare) else 0;
    return .{ .seq = seq, .messages = messages, .index = index };
}

fn nextHistory(self: *Worker, scratch: *std.heap.ArenaAllocator, scan: *HistoryScan, stream: HistoryStream, conversation: []const u8) !?HistoryEntry {
    const scoped_application = self.context_codec.scoped_application and stream == .application;
    const a = scratch.allocator();
    const source = self.journal.source();
    while (scan.seq > 1) {
        _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
        const message = if (scan.messages) |refs| blk: {
            if (scan.index == 0) return null;
            scan.index -= 1;
            scan.seq = refs[scan.index];
            break :blk try source.message(scan.seq);
        } else blk: {
            scan.seq -= 1;
            const frame = try source.get(scan.seq);
            switch (frame.action) {
                .@"document.message.append" => |append| break :blk append.message,
                .@"control.extension" => |action| {
                    if (!std.mem.eql(u8, action.namespace, Persistence.markers_namespace)) continue;
                    const key = j.text(j.get(action.input.value, "id"));
                    const prefix = @tagName(stream);
                    if (!std.mem.startsWith(u8, key, prefix) or key.len <= prefix.len or key[prefix.len] != '/') continue;
                    if (scoped_application and !try Persistence.ownsApplicationEntry(a, conversation, key[prefix.len + 1 ..])) continue;
                    return .{ .key = key, .value = try j.parse(a, j.text(j.get(action.input.value, "json"))), .reference = scan.seq };
                },
                else => continue,
            }
        };
        const saved = (try Persistence.decodeEntry(a, message)) orelse continue;
        if (!std.mem.eql(u8, saved.stream, @tagName(stream))) continue;
        if (scoped_application and !try Persistence.ownsApplicationEntry(a, conversation, j.text(j.get(saved.value, "id")))) continue;
        return .{ .key = message.id, .value = saved.value, .reference = scan.seq };
    }
    return null;
}

pub fn planApplicationFork(self: *Worker, allocator: std.mem.Allocator, conversation: []const u8, entry: []const u8) !ApplicationFork {
    if (!self.context_codec.scoped_application) return error.UnsupportedConversationFork;
    return Persistence.planApplicationFork(&self.journal, allocator, conversation, entry);
}

pub fn prepareResidentJournal(self: *Worker) !?PreparedJournal {
    return PreparedJournal.snapshotResident(&self.journal, self.context_codec);
}

/// Own a complete application path, including entries outside the model's
/// current context window and passive entries woven into the transcript.
pub fn exportApplicationBranch(self: *Worker, allocator: std.mem.Allocator, conversation: []const u8, leaf: ?[]const u8) !j.Document {
    if (!self.context_codec.scoped_application) return error.UnsupportedConversationFork;
    var document = try j.Document.initValue(allocator, .null);
    errdefer document.deinit();
    const a = document.allocator();
    document.value = j.array(a);
    var cursor = leaf;
    var limit = self.journal.sequence + 1;
    while (cursor) |id| {
        var record = (try self.readHistory(self.gpa, .{
            .stream = .application,
            .conversation = conversation,
            .id = id,
            .include_display_parent = true,
        })) orelse return error.UnknownEntry;
        defer record.deinit();
        if (record.reference >= limit) return error.InvalidConversation;
        limit = record.reference;
        var entry = try j.copy(a, record.value);
        try Persistence.expandProgramEntry(&self.journal, a, &entry);
        const parent = j.get(entry, "parent");
        cursor = if (record.display_parent) |display| try a.dupe(u8, display) else if (parent == .string) parent.string else null;
        var row = j.object();
        try j.put(a, &row, "entry", entry);
        try j.put(a, &row, "display_only", .{ .bool = self.journal.state.displays.contains(record.key) });
        try document.value.array.append(row);
    }
    std.mem.reverse(Value, document.value.array.items);
    return document;
}

/// Run an application projection on the actor against a committed scope.
/// The projection has a separate VM activation and only read effects.
pub fn queryApplication(self: *Worker, allocator: std.mem.Allocator, scope: []const u8, input: Value) !j.Document {
    if (!self.journal.state.contexts.contains(scope)) return error.UnknownContext;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const application = j.get(self.options.value, "application");
    if (application != .object) return error.NoApplication;
    const before = try Persistence.applicationContext(&self.journal, self.context_codec, a, scope);
    var environment = try j.parse(a, j.text(j.get(application, "environment_json")));
    try j.put(a, &environment, "conversation", j.string(scope));
    try j.put(a, &environment, "conversation_entry_prefix", j.string(try ContextCodec.entryPrefix(a, scope)));
    if (j.get(before, "session") == .null) {
        if (try Persistence.seedHead(&self.journal, scope)) |head| try j.put(a, &environment, "conversation_head", j.string(head));
    }
    var machine = try self.heap.beginApplication(self.gpa, try j.encode(a, before), &.{}, j.text(j.get(application, "source")), .{
        .input_json = try j.encode(a, input),
        .environment_json = try j.encode(a, environment),
        .mutable = j.flag(j.get(application, "mutable")),
    });
    defer machine.deinit();
    var reply: ?vm_types.Reply = null;
    while (true) {
        try self.io_backend.checkCancel();
        switch (try machine.step(10000, reply)) {
            .budget => reply = null,
            .failed => return error.ApplicationQueryFailed,
            .done => |done| return j.Document.init(allocator, done.result_json),
            .effect => |effect| {
                if (!std.mem.eql(u8, effect.tool_name, "__application")) return error.InvalidApplicationQueryEffect;
                const args = try j.parse(a, effect.arguments_json);
                const value: Value = if (std.mem.eql(u8, effect.endpoint, "__history")) history: {
                    const id = j.text(j.get(args, "id"));
                    if (id.len == 0 or (self.context_codec.scoped_application and !try Persistence.visibleApplicationEntry(&self.journal, a, scope, id))) return error.UnknownEntry;
                    break :history (try Persistence.history(&self.journal, a, "application", id)) orelse .null;
                } else if (std.mem.eql(u8, effect.endpoint, "__size_warning")) warning: {
                    const sink: semantic.Transaction.SizeSink = self.application_size_warnings orelse .{};
                    sink.report(j.text(j.get(args, "measurement")), std.math.lossyCast(usize, j.number(j.get(args, "actual"))), std.math.lossyCast(usize, j.number(j.get(args, "threshold"))));
                    break :warning .null;
                } else return error.InvalidApplicationQueryEffect;
                reply = .{ .json = try j.encode(a, value) };
            },
        }
    }
}

pub fn selectConversation(self: *Worker, document: *j.Document, head: []const u8) !void {
    const a = document.allocator();
    var entries = j.array(a);
    var id = head;
    var boundary: ?[]const u8 = null;
    while (id.len != 0) {
        var record = (try self.historyRecord(self.gpa, .conversation, id)) orelse return error.UnknownEntry;
        defer record.deinit();
        const entry = try j.copy(a, record.value);
        try entries.array.append(entry);
        if (boundary == null and std.mem.eql(u8, j.text(j.get(entry, "kind")), "checkpoint")) boundary = j.text(j.get(entry, "first_kept"));
        if (boundary) |first| if (std.mem.eql(u8, first, id)) break;
        id = j.text(j.get(entry, "parent"));
    }
    std.mem.reverse(Value, entries.array.items);
    const conv = j.ptr(&document.value, "conversation");
    try j.put(a, conv, "entries", entries);
    try j.put(a, conv, "head", j.string(try a.dupe(u8, head)));
}

pub fn exportConversation(self: *Worker, allocator: std.mem.Allocator) !j.Document {
    var document = try self.state.clone(allocator);
    errdefer document.deinit();
    const a = document.allocator();
    var entries = j.array(a);
    var query: HistoryQuery = .{ .stream = .conversation };
    while (try self.readHistory(allocator, query)) |saved| {
        var record = saved;
        defer record.deinit();
        query.before = record.reference;
        var entry = try j.copy(a, record.value);
        try Persistence.expandProgramEntry(&self.journal, a, &entry);
        try entries.array.append(entry);
    }
    std.mem.reverse(Value, entries.array.items);
    try j.put(a, j.ptr(&document.value, "conversation"), "entries", entries);
    return document;
}

pub fn sessionSnapshot(self: *Worker, allocator: std.mem.Allocator) !j.Document {
    var document = try j.Document.init(allocator, "{}");
    errdefer document.deinit();
    const a = document.allocator();
    var messages = j.array(a);
    for (self.journal.state.messages.values()) |ref| {
        const append = (try self.journal.frame(a, ref)).action.@"document.message.append";
        try messages.array.append(try semantic.Encoding.value(a, .{ .frame = ref, .message = append.message }));
    }
    var contexts = j.object();
    for (self.journal.state.contexts.keys(), self.journal.state.contexts.values()) |id, context| try j.put(a, &contexts, try a.dupe(u8, id), try semantic.Encoding.value(a, .{ .head = context.head, .ids = context.ids.items }));
    var requests = j.object();
    for (self.journal.state.requests.keys(), self.journal.state.requests.values()) |id, operation| {
        const issued = (try self.journal.frame(a, operation.intent)).action.@"control.model.request";
        const status = if (operation.finish) |ref| @tagName((try self.journal.frame(a, ref)).action.@"control.model.finish".status) else "pending";
        try j.put(a, &requests, try a.dupe(u8, id), try semantic.Encoding.value(a, .{ .intent = operation.intent, .context = issued.context, .status = status, .progress = operation.progress }));
    }
    var extensions = j.object();
    const private = &self.journal.state.extensions.entries;
    for (private.keys(), private.values()) |id, entry| try j.put(a, &extensions, try a.dupe(u8, id), try semantic.Encoding.value(a, .{ .head = entry.head, .contract = entry.contract, .value = entry.value }));
    document.value = try semantic.Encoding.value(a, .{ .sequence = self.journal.sequence, .messages = messages, .contexts = contexts, .extensions = extensions, .requests = requests, .model_frame = self.journal.state.model_frame });
    return document;
}

pub fn recordSession(self: *Worker, id: []const u8, actions: []const semantic.frames.Action) !u64 {
    const sequence = try self.journal.commit(id, .{ .kind = .host, .id = "harness" }, actions);
    self.sequence = self.journal.sequence;
    return sequence;
}

/// Resolve these extension heads on the actor, against the same state used
/// for the accompanying actions. Extension reducers validate the draft.
pub const ExtensionWrite = struct {
    namespace: []const u8,
    action: []const u8,
    input: semantic.frames.HarnessValue,
};

pub fn recordSessionWithExtensions(self: *Worker, id: []const u8, actions: []const semantic.frames.Action, writes: []const ExtensionWrite) !u64 {
    if (writes.len == 0) return self.recordSession(id, actions);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const bound = try a.alloc(semantic.frames.Action, writes.len);
    const prior = self.journal.transactionRange(id);
    const input_count = actions.len + writes.len;
    const saved_display_count: usize = if (prior) |range| blk: {
        const count = range.last - range.first + 1;
        if (count < input_count) return error.TransactionConflict;
        var displays: usize = 0;
        while (displays < @min(writes.len, count - input_count)) : (displays += 1) {
            const frame = (try self.journal.frame(a, range.first + actions.len + displays)).action;
            if (frame != .@"document.message.append" or !(frame.@"document.message.append".display_only orelse false)) break;
        }
        if (displays != 0 and self.context_codec.prepare_display_entries == null) return error.TransactionConflict;
        if (count != input_count + displays and self.context_codec.prepare_admission == null) return error.TransactionConflict;
        break :blk displays;
    } else 0;
    for (writes, bound, 0..) |write, *entry, index| {
        const head = if (prior) |range| blk: {
            const saved = (try self.journal.frame(a, range.first + actions.len + saved_display_count + index)).action;
            if (saved != .@"control.extension") return error.TransactionConflict;
            break :blk saved.@"control.extension".expected_head;
        } else if (self.journal.state.extensions.get(write.namespace)) |current| current.head else 0;
        entry.* = .{ .@"control.extension" = .{
            .namespace = write.namespace,
            .expected_head = head,
            .action = write.action,
            .input = write.input,
        } };
    }
    const displays: []const semantic.frames.MessageAppend = if (prior == null) if (self.context_codec.prepare_display_entries) |plan|
        try plan(a, &self.journal, actions, bound)
    else
        &.{} else &.{};
    if (displays.len > writes.len) return error.InvalidDisplayPlan;
    var batch: std.ArrayList(semantic.frames.Action) = .empty;
    try batch.appendSlice(a, actions);
    if (prior) |range| {
        for (0..saved_display_count) |index| {
            const saved = (try self.journal.frame(a, range.first + actions.len + index)).action;
            if (saved != .@"document.message.append" or !(saved.@"document.message.append".display_only orelse false)) return error.TransactionConflict;
            try batch.append(a, saved);
        }
    } else {
        for (displays) |display| {
            if (!(display.display_only orelse false)) return error.InvalidDisplayPlan;
            try batch.append(a, .{ .@"document.message.append" = display });
        }
    }
    try batch.appendSlice(a, bound);
    if (prior) |range| {
        var index = range.first + batch.items.len;
        while (index <= range.last) : (index += 1) {
            try batch.append(a, (try self.journal.frame(a, index)).action);
        }
        return self.recordSession(id, batch.items);
    }
    var progress = j.array(a);
    var adopted: ?j.Document = if (displays.len == 0) try self.planHostAdmission(a, id, &batch, &progress) else null;
    errdefer if (adopted) |*document| document.deinit();
    const count = progress.array.items.len;
    const notices = try a.alloc(*event_types.Event, if (count == 0) 0 else count + 1);
    try self.events.ensureUnusedCapacity(self.gpa, notices.len);
    var initialized: usize = 0;
    errdefer for (notices[0..initialized]) |notice| notice.deinit(self.gpa);
    if (count != 0) {
        notices[0] = try event_types.Event.init(self.gpa, self.next_lease, api.CPI_AGENT_EVENT_CTX_COMMITTED, 0, 0, id, "", .null);
        initialized = 1;
        for (progress.array.items, notices[1..]) |payload, *notice| {
            notice.* = try event_types.Event.init(self.gpa, self.next_lease + initialized, api.CPI_AGENT_EVENT_PROGRESS, 0, 0, id, "", payload);
            initialized += 1;
        }
    }
    const sequence = try self.recordSession(id, batch.items);
    if (adopted) |document| {
        self.state.deinit();
        self.state = document;
    }
    for (notices) |notice| {
        notice.value.sequence = sequence;
        self.events.appendAssumeCapacity(notice);
        self.event_bytes += notice.bytes;
    }
    self.next_lease += notices.len;
    return sequence;
}

fn previewExtensions(self: *Worker, id: []const u8, actions: []const semantic.frames.Action) !semantic.Extensions {
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const first = self.journal.sequence + 1;
    const session_id = self.journal.state.extensions.session_id;
    const bytes = try semantic.Encoding.transaction(a, session_id, id, first, .{ .kind = .host, .id = "harness" }, actions);
    var tx = try semantic.Transaction.parseObserved(a, session_id, first, bytes, self.journal.options.limits, null);
    defer tx.deinit();
    return self.journal.state.extensions.prepare(&tx, self.journal.options.contracts);
}

fn rebaseAdmissionExtension(self: *Worker, a: std.mem.Allocator, action: *semantic.frames.Action) !void {
    if (action.* != .@"control.extension") return;
    const extension = &action.@"control.extension";
    extension.expected_head = if (self.journal.state.extensions.get(extension.namespace)) |entry| entry.head else 0;
    extension.input.value = try j.copy(a, extension.input.value);
}

fn planHostAdmission(self: *Worker, a: std.mem.Allocator, id: []const u8, batch: *std.ArrayList(semantic.frames.Action), progress: *Value) !?j.Document {
    const select = self.context_codec.prepare_admission orelse return null;
    var preview = try self.previewExtensions(id, batch.items);
    defer preview.deinit();
    const admission = (try select(a, &self.journal, &preview)) orelse return null;
    const scope = admission.conversation;
    const current = std.mem.eql(u8, scope, ContextCodec.scope(self.state.value));
    if (current and (j.get(self.state.value, "active") != .null or j.get(self.state.value, "suspended") != .null)) return null;
    if (!self.journal.state.contexts.contains(scope)) return null;
    for (batch.items) |action| switch (action) {
        .@"document.message.append" => |entry| {
            if (entry.placement) |placement| if (std.mem.eql(u8, placement.context, scope)) return null;
        },
        .@"control.document_mutation" => |mutation| {
            if (std.mem.eql(u8, mutation.context, scope)) return null;
        },
        else => {},
    };
    const before = try Persistence.applicationContext(&self.journal, self.context_codec, a, scope);
    const application = j.get(self.options.value, "application");
    var environment = try j.parse(a, j.text(j.get(application, "environment_json")));
    try j.put(a, &environment, "conversation", j.string(scope));
    try j.put(a, &environment, "conversation_entry_prefix", j.string(try ContextCodec.entryPrefix(a, scope)));
    if (j.get(before, "session") == .null) {
        if (try Persistence.seedHead(&self.journal, scope)) |head| try j.put(a, &environment, "conversation_head", j.string(head));
    }
    var machine = try self.heap.beginApplication(self.gpa, try j.encode(a, before), &.{}, j.text(j.get(application, "source")), .{
        .input_json = try j.encode(a, admission.input),
        .environment_json = try j.encode(a, environment),
        .mutable = j.flag(j.get(application, "mutable")),
    });
    defer machine.deinit();
    const original = batch.items.len;
    var history = j.array(a);
    var reply: ?vm_types.Reply = null;
    while (true) {
        try self.io_backend.checkCancel();
        switch (try machine.step(10000, reply)) {
            .budget => reply = null,
            .failed => return error.ApplicationAdmissionFailed,
            .done => |done| {
                if (!j.flag(j.get(try j.parse(a, done.result_json), "admission_commit"))) {
                    batch.shrinkRetainingCapacity(original);
                    progress.array.clearRetainingCapacity();
                    return null;
                }
                const after = try j.parse(a, done.ctx_json);
                const start = batch.items.len;
                try Persistence.planAdmission(a, batch, &self.journal, self.context_codec, &preview, scope, before, after, history);
                for (batch.items[start..]) |*action| try self.rebaseAdmissionExtension(a, action);
                if (!current) return null;
                var document = try self.mutate();
                errdefer document.deinit();
                j.ptr(&document.value, "ctx").* = try j.copy(document.allocator(), after);
                return document;
            },
            .effect => |effect| {
                if (!std.mem.eql(u8, effect.tool_name, "__application")) return error.InvalidAdmissionEffect;
                var arguments = try j.parse(a, effect.arguments_json);
                const result: Value = if (std.mem.eql(u8, effect.endpoint, "__clock"))
                    .{ .integer = std.Io.Clock.real.now(self.io_backend).toMilliseconds() }
                else if (std.mem.eql(u8, effect.endpoint, "__history")) result: {
                    const entry = j.get(arguments, "id");
                    if (entry != .string or entry.string.len == 0) return error.InvalidArgument;
                    if (self.context_codec.scoped_application and !try Persistence.visibleApplicationEntry(&self.journal, a, scope, entry.string)) break :result .null;
                    break :result (try Persistence.history(&self.journal, a, "application", entry.string)) orelse .null;
                } else if (std.mem.eql(u8, effect.endpoint, "__checkpoint")) result: {
                    if (j.get(arguments, "history") == .array) try history.array.appendSlice(j.get(arguments, "history").array.items);
                    if (j.get(arguments, "event") == .object) {
                        if (!std.mem.eql(u8, scope, ContextCodec.main)) try j.put(a, j.ptr(&arguments, "event"), "conversation", j.string(scope));
                        try progress.array.append(j.get(arguments, "event"));
                    }
                    break :result .null;
                } else if (std.mem.eql(u8, effect.endpoint, "__runtime_options"))
                    try self.application_bindings.options(a)
                else if (std.mem.eql(u8, effect.endpoint, "__claim_boundary_input")) result: {
                    const bindings = self.application_bindings;
                    const claim_input = bindings.claim_boundary_input orelse break :result .null;
                    const claim = (try claim_input(bindings.context, a, &preview, scope, before, j.text(j.get(arguments, "mode")))) orelse break :result .null;
                    reply = .{ .json = try j.encode(a, claim.value) };
                    if (claim.action) |value| {
                        var action = value;
                        try self.rebaseAdmissionExtension(a, &action);
                        try batch.append(a, action);
                        var next = try self.previewExtensions(id, batch.items);
                        std.mem.swap(semantic.Extensions, &preview, &next);
                        next.deinit();
                    }
                    continue;
                } else return error.InvalidAdmissionEffect;
                reply = .{ .json = try j.encode(a, result) };
            },
        }
    }
}

pub fn readApplicationContext(self: *Worker, allocator: std.mem.Allocator, scope: []const u8, cut: ApplicationCut) !j.Document {
    if (cut == .current and std.mem.eql(u8, scope, ContextCodec.scope(self.state.value))) return j.Document.initValue(allocator, j.get(self.state.value, "ctx"));
    if (!self.journal.state.contexts.contains(scope)) return error.UnknownContext;
    var document = try j.Document.init(allocator, "{}");
    errdefer document.deinit();
    const a = document.allocator();
    const at = switch (cut) {
        .current => self.journal.sequence,
        .at => |seq| seq,
        .before_creation => |id| blk: {
            const created = (self.journal.state.contexts.get(id) orelse return error.UnknownContext).created_at;
            if (created == 0) break :blk 0;
            const frame = try self.journal.source().get(created);
            break :blk frame.seq - frame.tx.index - 1;
        },
    };
    if (at == self.journal.sequence) {
        document.value = try Persistence.applicationContext(&self.journal, self.context_codec, a, scope);
    } else {
        var extensions = try self.journal.state.extensionsAt(self.journal.source(), at, self.journal.options.contracts);
        defer extensions.deinit();
        document.value = try Persistence.decodeApplicationContext(&extensions, self.context_codec, a, scope);
    }
    return document;
}

pub fn transcriptSnapshot(self: *Worker, allocator: std.mem.Allocator, context: []const u8, cut: ?u64) !j.Document {
    const at = cut orelse self.journal.sequence;
    if (at > self.journal.sequence) return error.UncommittedPosition;
    const source = self.journal.source();
    try source.cut(at);
    const snapshot: semantic.State.Snapshot = .{
        .state = &self.journal.state,
        .source = source,
        .at = at,
        .context = context,
        .extensions = &self.journal.state.extensions,
    };
    var document = try j.Document.init(allocator, "{}");
    errdefer document.deinit();
    const a = document.allocator();
    document.value = try j.project(a, .{ .at = at, .messages = try snapshot.messages(a) });
    return document;
}

pub fn recordModelProgress(self: *Worker, id: u64, progress: @import("services").ModelProgress) !void {
    for (self.operations.items) |operation| {
        if (operation.id != id) continue;
        if (operation.cancelled or operation.obsolete or operation.terminal) return error.Canceled;
        return @import("LuauJournalIO.zig").progressModel(self, operation.semantic_model orelse return error.InvalidModelRequest, progress);
    }
    return error.StaleOperation;
}

pub const ExtensionProjection = *const fn (std.mem.Allocator, Value) anyerror!Value;
pub const ExtensionVisitor = struct {
    context: ?*anyopaque,
    visit: *const fn (?*anyopaque, u64, Value) anyerror!void,
};

pub fn visitExtension(self: *const Worker, namespace: []const u8, visitor: ExtensionVisitor) !void {
    const entry = self.journal.state.extensions.get(namespace);
    try visitor.visit(visitor.context, if (entry) |saved| saved.head else 0, if (entry) |saved| saved.value else .null);
}

pub fn extensionSnapshot(self: *Worker, allocator: std.mem.Allocator, namespace: []const u8, projection: ?ExtensionProjection) !j.Document {
    var document = try j.Document.init(allocator, "{}");
    errdefer document.deinit();
    const entry = self.journal.state.extensions.get(namespace);
    if (projection) |project| {
        document.value = try project(document.allocator(), if (entry) |saved| saved.value else .null);
    } else if (entry) |saved| {
        document.value = try semantic.Encoding.value(document.allocator(), .{ .head = saved.head, .value = saved.value });
    }
    return document;
}
pub fn exportState(self: *Worker, allocator: std.mem.Allocator) !j.Document {
    var document = try self.exportConversation(allocator);
    errdefer document.deinit();
    const a = document.allocator();
    var commands = j.array(a);
    if (self.journal.state.extensions.get(Persistence.commands_namespace)) |saved| {
        for (saved.value.object.values()) |encoded| try commands.array.append(try j.parse(a, encoded.string));
    }
    try commands.array.appendSlice(j.get(document.value, "commands").array.items);
    for (commands.array.items) |*command_value| try self.expandCommand(a, command_value);
    try j.put(a, &document.value, "commands", commands);
    return document;
}

fn retireEffects(self: *Worker, document: *j.Document) !void {
    const a = document.allocator();
    inline for (.{ "active", "suspended" }) |slot| {
        const invocation = j.get(document.value, slot);
        const effects = j.get(invocation, "effects");
        const id = j.text(j.get(invocation, "core_effect_id"));
        const operation = self.journal.state.effects.get(id);
        if (effects == .array and operation != null and operation.?.finish != null and effects.array.items.len > 0) {
            const last = &effects.array.items[effects.array.items.len - 1];
            const status = j.text(j.get(last.*, "status"));
            if (j.get(last.*, "effect_ref") == .null and (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed"))) {
                var reference = j.object();
                try j.put(a, &reference, "effect_ref", j.integer(@intCast(operation.?.finish.?)));
                inline for (.{ "tool_name", "status", "failed" }) |field| try j.put(a, &reference, field, j.get(last.*, field));
                last.* = reference;
            }
        }
        if (invocation == .object and !std.mem.eql(u8, j.text(j.get(invocation, "phase")), "effect")) {
            const stored = j.ptr(&document.value, slot);
            _ = stored.object.orderedRemove("effect");
        }
    }
}

pub fn effectValue(self: *Worker, allocator: std.mem.Allocator, effect: Value) !Value {
    return Persistence.effectValue(&self.journal, allocator, effect);
}

pub fn expandEffects(self: *Worker, allocator: std.mem.Allocator, effects: Value) !Value {
    return Persistence.expandEffects(&self.journal, allocator, effects);
}

fn expandCommand(self: *Worker, allocator: std.mem.Allocator, command_value: *Value) !void {
    const outcome = j.get(command_value.*, "outcome");
    if (j.get(outcome, "error") != .object) return;
    try Persistence.expandInterruption(&self.journal, allocator, j.ptr(j.ptr(command_value, "outcome"), "error"));
}

pub fn expandOutcome(self: *Worker, allocator: std.mem.Allocator, outcome: Value) !Value {
    const diagnostic = j.get(outcome, "error");
    if (!std.mem.eql(u8, j.text(j.get(diagnostic, "code")), "interrupted") or !Persistence.hasEffectReferences(j.get(diagnostic, "effects"))) return outcome;
    var expanded = try j.copy(allocator, outcome);
    if (j.get(expanded, "error") == .object) try Persistence.expandInterruption(&self.journal, allocator, j.ptr(&expanded, "error"));
    return expanded;
}

pub fn projectionState(self: *Worker, allocator: std.mem.Allocator) !Value {
    var view = try j.parse(allocator, "{\"conversation\":{\"head\":null,\"entries\":[]},\"conversation_model\":null}");
    const model = j.get(j.get(self.state.value, "active"), "model");
    try j.put(allocator, &view, "conversation_model", if (model == .object) j.get(model, "model") else j.get(self.state.value, "conversation_model"));
    const conversation = j.get(self.state.value, "conversation");
    try j.put(allocator, j.ptr(&view, "conversation"), "head", j.get(conversation, "head"));
    const entries = j.ptr(j.ptr(&view, "conversation"), "entries");
    for (try Conversation.path(allocator, self.state.value)) |saved| {
        var entry = saved;
        const result = j.get(entry, "result");
        const effects = j.get(result, "effects");
        if (std.mem.eql(u8, j.text(j.get(entry, "kind")), "program") and j.flag(j.get(entry, "failed")) and
            std.mem.eql(u8, j.text(j.get(result, "code")), "interrupted") and Persistence.hasEffectReferences(effects))
        {
            entry = try j.copy(allocator, entry);
            try Persistence.expandProgramEntry(&self.journal, allocator, &entry);
        }
        try entries.array.append(entry);
    }
    return view;
}

pub fn mutate(self: *Worker) !j.Document {
    return self.state.clone(self.gpa);
}

fn releasePins(self: *Worker, pins: *std.ArrayList(*vm_types.RegisteredTool)) void {
    for (pins.items) |tool| tool.release();
    pins.deinit(self.gpa);
    pins.* = .empty;
}

fn resolveCapability(self: *Worker, tool: Value, candidate: ?*vm_types.RegisteredTool, prior: []const *vm_types.RegisteredTool) !*vm_types.RegisteredTool {
    const source = j.text(j.get(tool, "source"));
    if (candidate) |item| if (semantic.json.equalBytes(item.source(), source)) return item.retain();
    for (prior) |item| if (semantic.json.equalBytes(item.source(), source)) return item.retain();
    return self.heap.registerTool(source);
}
fn pinSnapshot(self: *Worker, snapshot: Value, pins: *std.ArrayList(*vm_types.RegisteredTool), registry: []const *vm_types.RegisteredTool) !void {
    const tools = j.get(snapshot, "capabilities");
    if (tools != .array) return;
    const revision = j.number(j.get(snapshot, "capabilities_revision"));
    var prior = registry;
    const old_active = j.get(self.state.value, "active");
    const old_suspended = j.get(self.state.value, "suspended");
    if (old_active != .null and revision == j.number(j.get(old_active, "capabilities_revision"))) prior = self.active_capabilities.items else if (old_suspended != .null and revision == j.number(j.get(old_suspended, "capabilities_revision"))) prior = self.suspended_capabilities.items;
    for (tools.array.items) |tool| {
        const receipt = try self.resolveCapability(tool, null, prior);
        errdefer receipt.release();
        try pins.append(self.gpa, receipt);
    }
}

pub fn stage(self: *Worker, document: j.Document, notices: []const Notice) !void {
    return self.stageRegistered(document, notices, null);
}
pub fn stageRegistered(self: *Worker, document: j.Document, notices: []const Notice, candidate: ?*vm_types.RegisteredTool) !void {
    return self.stageTransaction(document, notices, candidate, .null);
}

pub fn stageHistory(self: *Worker, document: j.Document, notices: []const Notice, history: Value) !void {
    return self.stageTransaction(document, notices, null, history);
}

fn publication(self: *Worker, value: Value) !j.Document {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var view = j.object();
    for (value.object.keys(), value.object.values()) |key, item| {
        if (std.mem.eql(u8, key, "pending_history") or std.mem.eql(u8, key, "bootstrap_context")) continue;
        if (std.mem.eql(u8, key, "conversation")) {
            var conversation = j.object();
            for (item.object.keys(), item.object.values()) |name, field| {
                if (std.mem.eql(u8, name, "entries")) {
                    var selected = j.array(a);
                    try selected.array.appendSlice(try Conversation.path(a, value));
                    try j.put(a, &conversation, name, selected);
                } else try j.put(a, &conversation, name, field);
            }
            try j.put(a, &view, key, conversation);
        } else if (std.mem.eql(u8, key, "commands")) {
            var queued = j.array(a);
            for (item.array.items) |command_value| {
                const status = j.text(j.get(command_value, "status"));
                if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) try queued.array.append(command_value);
            }
            try j.put(a, &view, key, queued);
        } else try j.put(a, &view, key, item);
    }
    return j.Document.initValue(self.gpa, view);
}

fn stageTransaction(self: *Worker, document: j.Document, notices: []const Notice, candidate: ?*vm_types.RegisteredTool, history: Value) !void {
    var next = document;
    const a = next.allocator();
    if (self.bootstrap and history == .array) {
        if (j.get(next.value, "pending_history") != .array) try j.put(a, &next.value, "pending_history", j.array(a));
        try j.ptr(&next.value, "pending_history").array.appendSlice(history.array.items);
    }
    var prepared: std.ArrayList(*event_types.Event) = .empty;
    defer prepared.deinit(self.gpa);
    errdefer for (prepared.items) |event| event.deinit(self.gpa);
    if (!self.bootstrap) {
        try self.events.ensureUnusedCapacity(self.gpa, notices.len + 2);
        for (notices, 0..) |notice, index| {
            const event = try event_types.Event.init(self.gpa, self.next_lease + index, notice.kind, 0, if (notice.kind == api.CPI_AGENT_EVENT_READY) 0 else self.sequence + 1, notice.request, "", notice.payload);
            prepared.append(self.gpa, event) catch |err| {
                event.deinit(self.gpa);
                return err;
            };
        }
        const old_entries = j.get(j.get(self.state.value, "conversation"), "entries");
        const entries = j.get(j.get(next.value, "conversation"), "entries");
        const old_count = if (old_entries == .array) old_entries.array.items.len else 0;
        if (entries == .array and entries.array.items.len > old_count) {
            var payload = j.object();
            var added = j.array(a);
            for (entries.array.items[old_count..]) |entry| try added.array.append(try Conversation.domainEntry(a, entry));
            try j.put(a, &payload, "entries", added);
            try j.put(a, &payload, "revision", j.get(j.get(next.value, "conversation"), "revision"));
            const event = try event_types.Event.init(self.gpa, self.next_lease + prepared.items.len, 12, 0, self.sequence + 1, "", "", payload);
            prepared.insert(self.gpa, 0, event) catch |err| {
                event.deinit(self.gpa);
                return err;
            };
        }
    }
    var registered: std.ArrayList(*vm_types.RegisteredTool) = .empty;
    const capabilities_changed = !self.capabilities_prepared or j.number(j.get(self.state.value, "capabilities_revision")) != j.number(j.get(next.value, "capabilities_revision"));
    errdefer self.releasePins(&registered);
    if (capabilities_changed) {
        const tools = j.get(next.value, "capabilities").array.items;
        for (tools) |tool| {
            const receipt = try self.resolveCapability(tool, candidate, self.registered_capabilities.items);
            errdefer receipt.release();
            if (!(try j.equal(self.gpa, try j.parse(a, receipt.metadata()), j.get(tool, "descriptor")))) return error.InvalidExtension;
            if (!self.capabilities_prepared or candidate == receipt) {
                const warnings: semantic.Transaction.SizeSink = self.application_size_warnings orelse .{};
                warnings.report("capability name bytes", j.text(j.get(tool, "name")).len, @import("config.zig").expected_capability_name_bytes);
            }
            try registered.append(self.gpa, receipt);
        }
    }
    var active_pins: std.ArrayList(*vm_types.RegisteredTool) = .empty;
    var suspended_pins: std.ArrayList(*vm_types.RegisteredTool) = .empty;
    errdefer self.releasePins(&active_pins);
    errdefer self.releasePins(&suspended_pins);
    try self.pinSnapshot(j.get(next.value, "active"), &active_pins, if (capabilities_changed) registered.items else self.registered_capabilities.items);
    try self.pinSnapshot(j.get(next.value, "suspended"), &suspended_pins, if (capabilities_changed) registered.items else self.registered_capabilities.items);
    if (!self.bootstrap) {
        try self.retireEffects(&next);
        var published = try self.publication(next.value);
        errdefer published.deinit();
        try Persistence.boundary(&self.journal, self.context_codec, self.state.value, &next, history, &.{}, self.recovery_pending);
        self.recovery_pending = false;
        next.deinit();
        next = published;
        for (prepared.items) |event| if (event.value.kind != api.CPI_AGENT_EVENT_READY) {
            event.value.sequence = self.journal.sequence;
        };
    }
    self.releasePins(&self.active_capabilities);
    self.active_capabilities = active_pins;
    self.releasePins(&self.suspended_capabilities);
    self.suspended_capabilities = suspended_pins;
    if (capabilities_changed) {
        self.releasePins(&self.registered_capabilities);
        self.registered_capabilities = registered;
        self.capabilities_prepared = true;
    }
    const old = self.state;
    self.state = next;
    if (!self.bootstrap) self.sequence = self.journal.sequence;
    if (self.bootstrap) for (notices) |notice| {
        if (notice.kind == api.CPI_AGENT_EVENT_READY) self.ready = true;
    };
    var pending_index: usize = 0;
    while (pending_index < self.pending_capabilities.items.len) {
        const item = self.pending_capabilities.items[pending_index];
        const status = if (self.command(item.id)) |command_value| j.text(j.get(command_value, "status")) else "";
        if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) {
            pending_index += 1;
            continue;
        }
        _ = self.pending_capabilities.swapRemove(pending_index);
        self.gpa.free(item.id);
        item.capability.release();
    }
    for (prepared.items) |event| {
        self.events.appendAssumeCapacity(event);
        self.event_bytes += event.bytes;
        self.next_lease += 1;
        if (event.value.kind == api.CPI_AGENT_EVENT_READY) self.ready = true;
    }
    var previous = old;
    previous.deinit();
    io.committed(self) catch |err| self.fault(err);
}

pub fn commitBootstrap(self: *Worker) !void {
    if (!self.bootstrap or self.failed or self.external != null or self.vm != null) return error.InvalidState;
    const history = j.get(self.state.value, "pending_history");
    var published = try self.publication(self.state.value);
    errdefer published.deinit();
    try self.events.ensureUnusedCapacity(self.gpa, 1);
    const ready_event = try event_types.Event.init(self.gpa, self.next_lease, api.CPI_AGENT_EVENT_READY, 0, 0, "", "", .null);
    errdefer ready_event.deinit(self.gpa);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const actions = if (self.context_codec.bootstrap_actions) |plan| try plan(scratch.allocator(), &self.journal) else &.{};
    try Persistence.boundary(&self.journal, self.context_codec, self.state.value, &self.state, history, actions, self.recovery_pending);
    self.recovery_pending = false;
    self.state.deinit();
    self.state = published;
    self.sequence = self.journal.sequence;
    self.bootstrap = false;
    self.events.appendAssumeCapacity(ready_event);
    self.event_bytes += ready_event.bytes;
    self.next_lease += 1;
}

pub fn emit(self: *Worker, kind: u32, operation: u64, sequence: u64, request_id: []const u8, method: []const u8, payload: Value) !void {
    if (self.bootstrap) return;
    const event = try event_types.Event.init(self.gpa, self.next_lease, kind, operation, sequence, request_id, method, payload);
    errdefer event.deinit(self.gpa);
    try self.events.append(self.gpa, event);
    self.event_bytes += event.bytes;
    self.next_lease += 1;
}

pub fn request(self: *Worker, kind: @FieldType(Operation, "kind"), method: []const u8, request_id: []const u8, payload: Value) !u64 {
    if (self.bootstrap) return error.BootstrapExternalEffect;
    const id = self.next_operation;
    self.next_operation += 1;
    const invocation = try self.gpa.dupe(u8, request_id);
    errdefer self.gpa.free(invocation);
    var packet = try j.Document.initValue(self.gpa, payload);
    defer packet.deinit();
    try self.operations.ensureUnusedCapacity(self.gpa, 1);
    const recorded = try @import("LuauJournalIO.zig").prepare(self, kind, &packet);
    self.operations.appendAssumeCapacity(.{ .id = id, .kind = kind, .invocation = invocation, .semantic_effect = recorded.effect, .semantic_model = recorded.model });
    errdefer _ = self.operations.pop();
    try self.emit(api.CPI_AGENT_EVENT_IO_REQUEST, id, 0, invocation, method, packet.value);
    return id;
}

pub fn feed(self: *Worker, id: u64, kind: u32, data: []const u8) !void {
    if (kind < 1 or kind > 5) return error.InvalidArgument;
    for (self.operations.items) |*operation| {
        if (operation.id != id or operation.terminal) continue;
        const bytes = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(bytes);
        try self.replies.append(self.gpa, .{ .operation = id, .kind = kind, .bytes = bytes });
        if (kind >= api.CPI_AGENT_IO_DONE) operation.terminal = true;
        return;
    }
    return error.StaleOperation;
}

pub fn feedLate(self: *Worker, id: u64, kind: u32, data: []const u8) !bool {
    for (self.operations.items) |operation| {
        if (operation.id != id or !operation.obsolete) continue;
        try self.feed(id, kind, data);
        try io.process(self, self.replies.items.len - 1);
        return true;
    }
    return false;
}

pub fn cancelExternal(self: *Worker) !void {
    const id = self.external orelse return;
    for (self.operations.items) |*operation| {
        if (operation.id != id or operation.cancelled) continue;
        try @import("LuauJournalIO.zig").cancel(self, operation.*);
        operation.cancelled = true;
        try self.emit(api.CPI_AGENT_EVENT_IO_CANCEL, id, 0, "", "", .null);
    }
}

pub fn stopVm(self: *Worker) void {
    if (self.vm) |*runner| runner.deinit();
    self.vm = null;
    self.clearVmReply();
}

pub fn run(self: *Worker, transitions: u32, instructions: u32) !u32 {
    if (transitions == 0 or instructions == 0) return error.InvalidArgument;
    var runnable = false;
    if (!self.failed and !self.closed) {
        var remaining = transitions;
        while (remaining > 0) : (remaining -= 1) {
            if (self.failed or self.closed) break;
            if (self.replyIndex()) |reply_index| {
                try io.process(self, reply_index);
                continue;
            }
            if (!self.opened) {
                try io.recover(self);
                self.opened = true;
                continue;
            }
            if (!self.ready) break;
            if (try logic.admitOne(self)) continue;
            if (try logic.control(self)) continue;
            if (self.external != null) break;
            if (try logic.advance(self, instructions)) continue;
            break;
        }
        runnable = remaining == 0 or self.replyIndex() != null or (self.ready and
            (self.admissions.items.len > 0 or (self.external == null and self.vm != null)));
    }
    return if (self.failed) api.CPI_AGENT_FAILED else if (self.closed) api.CPI_AGENT_CLOSED else if (runnable) api.CPI_AGENT_RUNNABLE else api.CPI_AGENT_WAITING;
}

pub fn fault(self: *Worker, err: anyerror) void {
    if (self.first_failure != null) return;
    self.first_failure = err;
    self.failed = true;
    self.cancelExternal() catch {};
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var payload = j.object();
    j.put(arena.allocator(), &payload, "code", j.string(@errorName(err))) catch return;
    self.emit(api.CPI_AGENT_EVENT_FAULT, 0, 0, "", "", payload) catch {};
}

fn replyIndex(self: *Worker) ?usize {
    return if (self.replies.items.len > 0) 0 else null;
}
