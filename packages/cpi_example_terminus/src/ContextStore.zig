const std = @import("std");
const agent = @import("agent");
const p = agent.session_protocol;
const F = p.frames;
const codec = @import("ContextJournal.zig");
const j = @import("services").json;
const Value = j.Value;
const Self = @This();
pub const Snapshot = struct { id: u64, owner: u64, bytes: []const u8 };
pub const Generation = struct { id: []const u8, context: []const u8, user: u64, head: u64, after: ?[]const u8 };

gpa: std.mem.Allocator,
controller: *agent.Controller,
frozen: ?agent.JsonDocument = null,
closed_failure: ?anyerror = null,
worker: agent.WorkerId,
io: std.Io,
mutex: std.Io.Mutex = .init,
serial: u64 = 0,
owner: u64,
nonce: [8]u8,

pub fn init(gpa: std.mem.Allocator, io: std.Io, owner: u64, controller: *agent.Controller, worker: agent.WorkerId) Self {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return .{ .gpa = gpa, .controller = controller, .worker = worker, .io = io, .owner = owner, .nonce = nonce };
}
pub fn deinit(self: *Self) void {
    if (self.frozen) |*saved| saved.deinit();
    self.* = undefined;
}
pub fn freeze(self: *Self) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.frozen != null) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    self.frozen = try agent.JsonDocument.initValue(self.gpa, try self.readLocked(arena.allocator()));
}
fn write(self: *Self, a: std.mem.Allocator, actions: []const F.Action) !u64 {
    self.serial += 1;
    return self.controller.recordSession(self.worker, try std.fmt.allocPrint(a, "terminus/{s}/{d}", .{ std.fmt.bytesToHex(self.nonce, .lower), self.serial }), actions);
}
fn identity(a: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "terminus/{d}", .{id});
}

fn message(a: std.mem.Allocator, record: Value, raw: ?Value) !F.Message {
    const id = try number(j.get(record, "id"));
    const role = std.meta.stringToEnum(F.Role, try j.text(j.get(record, "role"))) orelse return error.InvalidRole;
    if (role == .tool) return error.InvalidRole;
    var content: std.ArrayList(Value) = .empty;
    try content.append(a, try j.value(a, .{ .type = "text", .text = j.get(record, "content") }));
    try content.append(a, try j.value(a, .{ .type = "json", .value = .{ .format = "cpi-terminus.message.v1", .id = id, .kind = j.get(record, "kind"), .origin_worker = j.get(record, "origin_worker"), .source_snapshot = j.get(record, "source_snapshot"), .generation = j.get(record, "generation") } }));
    if (raw) |value| {
        const bytes = try j.encode(a, value);
        const base64 = std.base64.standard.Encoder;
        const encoded = try a.alloc(u8, base64.calcSize(bytes.len));
        try content.append(a, try j.value(a, .{ .type = "provider_state", .provider = "configured", .format = "openai.responses.json", .base64 = base64.encode(encoded, bytes), .sha256 = j.hash(bytes) }));
    }
    return .{ .id = try identity(a, id), .role = role, .content = content.items };
}

fn readLocked(self: *Self, a: std.mem.Allocator) !Value {
    if (self.closed_failure) |err| return err;
    if (self.frozen) |saved| return j.copy(a, saved.value);
    var snapshot = try self.controller.readSession(self.worker, a);
    defer snapshot.deinit();
    var history: Value = .{ .array = .init(a) };
    var view: Value = .{ .array = .init(a) };
    var next: u64 = 1;
    for (try items(j.get(snapshot.value, "messages"))) |row| {
        const msg = j.get(row, "message");
        var metadata: Value = .null;
        var text: std.ArrayList(u8) = .empty;
        for (try items(j.get(msg, "content"))) |part| {
            if (std.mem.eql(u8, try j.string(part, "type", ""), "text")) try text.appendSlice(a, try j.text(j.get(part, "text")));
            const data = j.get(part, "value");
            if (std.mem.eql(u8, j.string(data, "format", "") catch "", "cpi-terminus.message.v1")) metadata = data;
        }
        if (metadata == .null) continue;
        var record = try j.copy(a, metadata);
        _ = record.object.orderedRemove("format");
        try j.put(a, &record, "role", j.get(msg, "role"));
        try j.put(a, &record, "content", .{ .string = text.items });
        const id = try number(j.get(record, "id"));
        next = @max(next, id + 1);
        const generation = j.get(record, "generation");
        if (generation == .string) {
            const request = j.get(j.get(snapshot.value, "requests"), generation.string);
            if (!std.mem.eql(u8, j.string(request, "status", "") catch "", "completed")) continue;
        }
        _ = record.object.orderedRemove("generation");
        try history.array.append(record);
    }
    const context = j.get(j.get(snapshot.value, "contexts"), "main");
    for (try items(j.get(context, "ids"))) |id| {
        const name = try j.text(id);
        if (!std.mem.startsWith(u8, name, "terminus/")) return error.InvalidContext;
        try view.array.append(.{ .integer = @intCast(try std.fmt.parseInt(u64, name[9..], 10)) });
    }
    return j.value(a, .{ .history = history, .view = view, .version = j.get(context, "head"), .next_id = next, .position = j.get(snapshot.value, "sequence") });
}

pub fn bind(self: *Self, a: std.mem.Allocator, fingerprint: []const u8, initial: Value) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    var snapshot = try self.controller.readSession(self.worker, a);
    defer snapshot.deinit();
    const binding = j.get(j.get(snapshot.value, "extensions"), codec.binding_namespace);
    if (binding != .null) {
        if (!std.mem.eql(u8, try j.text(j.get(binding, "value")), fingerprint)) return error.SessionConflict;
        return;
    }
    var actions: std.ArrayList(F.Action) = .empty;
    try actions.append(a, .{ .@"control.extension" = .{ .namespace = codec.binding_namespace, .expected_head = 0, .action = "bind", .input = .{ .contract = codec.binding_contract.version, .value = .{ .string = fingerprint } } } });
    var after: ?[]const u8 = null;
    for (try items(initial), 0..) |item, index| {
        const msg = try message(a, try newRecord(a, item, index + 1, 0, null), null);
        try actions.append(a, .{ .@"document.message.append" = .{ .message = msg, .placement = .{ .context = "main", .after = after } } });
        after = msg.id;
    }
    _ = try self.write(a, actions.items);
}

pub fn read(self: *Self, a: std.mem.Allocator) !Value {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    var state = try self.readLocked(a);
    _ = state.object.orderedRemove("position");
    return state;
}
pub fn visible(a: std.mem.Allocator, state: Value) !Value {
    var result: Value = .{ .array = .init(a) };
    for (try items(j.get(state, "view"))) |id| try result.array.append(find(try items(j.get(state, "history")), try number(id)) orelse return error.InvalidContext);
    return result;
}
pub fn append(self: *Self, a: std.mem.Allocator, messages: Value) !Value {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const state = try self.readLocked(a);
    const selected = try items(j.get(state, "view"));
    var after = if (selected.len > 0) try identity(a, try number(selected[selected.len - 1])) else null;
    var next = try number(j.get(state, "next_id"));
    var actions: std.ArrayList(F.Action) = .empty;
    for (try items(messages)) |item| {
        const msg = try message(a, try newRecord(a, item, next, self.owner, null), null);
        next += 1;
        try actions.append(a, .{ .@"document.message.append" = .{ .message = msg, .placement = .{ .context = "main", .after = after } } });
        after = msg.id;
    }
    if (actions.items.len != 0) _ = try self.write(a, actions.items);
    const current = try self.readLocked(a);
    return j.value(a, .{ .version = j.get(current, "version") });
}
pub fn capture(self: *Self, a: std.mem.Allocator) !Value {
    const state = try self.read(a);
    return j.value(a, .{ .version = j.get(state, "version"), .groups = try visible(a, state) });
}
pub fn pinSnapshot(self: *Self, a: std.mem.Allocator, id: u64) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const state = try self.readLocked(a);
    _ = try self.write(a, &.{.{ .@"control.context.create" = .{ .id = try std.fmt.allocPrint(a, "snapshot/{s}/{d}", .{ std.fmt.bytesToHex(self.nonce, .lower), id }), .base = .{ .context = "main", .at = try number(j.get(state, "position")) } } }});
}

pub fn commit(self: *Self, a: std.mem.Allocator, snapshot: Value, selected: Value, replacements: Value, protected_ids: []const u64, snapshot_id: u64, after_id: ?u64) !Value {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const current = try self.readLocked(a);
    const revision = try number(j.get(current, "version"));
    const base = try items(j.get(snapshot, "groups"));
    const ids = try items(selected);
    const live = try items(j.get(current, "view"));
    var start: ?usize = null;
    if (ids.len == 0) {
        if (after_id) |anchor| {
            _ = find(base, anchor) orelse return error.InvalidSelection;
            for (live, 0..) |id, index| if (try number(id) == anchor) {
                start = index + 1;
                break;
            };
        } else if (live.len == 0 and base.len == 0) {
            start = 0;
        } else return error.EmptySelection;
    } else for (live, 0..) |id, index| if (try number(id) == try number(ids[0])) {
        start = index;
        break;
    };
    const first = start orelse return error.StaleContext;
    if (first + ids.len > live.len) return error.StaleContext;
    for (ids, 0..) |id, index| {
        const n = try number(id);
        for (protected_ids) |protected| if (protected == n) return error.ProtectedContext;
        if (n != try number(live[first + index])) return error.StaleContext;
        const before = find(base, n) orelse return error.InvalidSelection;
        const after = find(try items(j.get(current, "history")), n) orelse return error.StaleContext;
        if (!try p.json.equal(a, before, after)) return error.StaleContext;
    }
    var actions: std.ArrayList(F.Action) = .empty;
    var desired: std.ArrayList([]const u8) = .empty;
    for (live[0..first]) |id| try desired.append(a, try identity(a, try number(id)));
    var next = try number(j.get(current, "next_id"));
    for (try items(replacements)) |item| {
        const msg = try message(a, try newRecord(a, item, next, self.owner, snapshot_id), null);
        next += 1;
        try actions.append(a, .{ .@"document.message.append" = .{ .message = msg, .placement = null } });
        try desired.append(a, msg.id);
    }
    for (live[first + ids.len ..]) |id| try desired.append(a, try identity(a, try number(id)));
    const old = try a.alloc([]const u8, live.len);
    for (live, old) |id, *name| name.* = try identity(a, try number(id));
    var edits: std.ArrayList(F.Edit) = .empty;
    if (old.len != 0) try edits.append(a, .{ .drop = old });
    if (desired.items.len != 0) try edits.append(a, .{ .insert = .{ .after = null, .ids = desired.items } });
    try actions.append(a, .{ .@"control.document_mutation" = .{ .context = "main", .expected_head = revision, .edits = edits.items } });
    _ = try self.write(a, actions.items);
    var state = try self.readLocked(a);
    _ = state.object.orderedRemove("position");
    return state;
}

pub fn beginGeneration(self: *Self, a: std.mem.Allocator, prompt: []const u8, body: Value, model: agent.Model) !Generation {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const state = try self.readLocked(a);
    const next = try number(j.get(state, "next_id"));
    const live = try items(j.get(state, "view"));
    const after = if (live.len == 0) null else try identity(a, try number(live[live.len - 1]));
    const token = try std.fmt.allocPrint(a, "generation/{s}/{d}", .{ std.fmt.bytesToHex(self.nonce, .lower), self.serial + 1 });
    var kwargs = try j.copy(a, body);
    _ = kwargs.object.orderedRemove("input");
    var actions: std.ArrayList(F.Action) = .empty;
    try actions.append(a, .{ .@"control.set_model" = .{ .provider = "configured", .model = model.model, .route = model.base_url, .credential_ref = if (model.credential.len == 0) null else model.credential, .adapter = codec.renderer.version, .kwargs = kwargs } });
    try actions.append(a, .{ .@"control.context.create" = .{ .id = token, .base = .{ .context = "main", .at = try number(j.get(state, "position")) } } });
    var user_record = try newRecord(a, try j.value(a, .{ .role = "user", .content = prompt }), next, self.owner, null);
    try j.put(a, &user_record, "generation", .{ .string = token });
    const user = try message(a, user_record, null);
    try actions.append(a, .{ .@"document.message.append" = .{ .message = user, .placement = .{ .context = token, .after = after } } });
    const prefix = try self.write(a, actions.items);
    const input = j.get(body, "input");
    const instructions = if (j.get(body, "instructions") == .string) j.get(body, "instructions") else Value{ .string = "" };
    const ih = try p.Canonical.hash(a, instructions);
    const mh = try p.Canonical.hash(a, input);
    const th = try p.Canonical.hash(a, .{ .array = .init(a) });
    _ = try self.write(a, &.{.{ .@"control.model.request" = .{ .request_id = token, .input_at = prefix, .context = token, .model_frame = prefix - actions.items.len + 1, .renderer = codec.renderer.version, .kwargs = .{ .object = .empty }, .instructions_sha256 = &ih, .messages_sha256 = &mh, .tools_sha256 = &th } }});
    return .{ .id = token, .context = token, .user = next, .head = try number(j.get(state, "version")), .after = after };
}

pub fn finishGeneration(self: *Self, a: std.mem.Allocator, generation: Generation, status: F.Status, text: []const u8, raw: Value, usage: Value) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const state = try self.readLocked(a);
    const next = try number(j.get(state, "next_id"));
    var record = try newRecord(a, try j.value(a, .{ .role = "assistant", .content = text }), next, self.owner, null);
    try j.put(a, &record, "generation", .{ .string = generation.id });
    const output = try message(a, record, raw);
    const user = try identity(a, generation.user);
    var actions: std.ArrayList(F.Action) = .empty;
    try actions.append(a, .{ .@"document.message.append" = .{ .message = output, .placement = .{ .context = generation.context, .after = user }, .request = generation.id } });
    try actions.append(a, .{ .@"control.model.finish" = .{ .request_id = generation.id, .status = status, .usage = if (usage == .object) usage else .null, .diagnostic = if (j.get(raw, "error") == .object) j.get(raw, "error") else .null } });
    if (status == .completed) {
        if (try number(j.get(state, "version")) != generation.head) return error.StaleContext;
        try actions.append(a, .{ .@"control.document_mutation" = .{ .context = "main", .expected_head = generation.head, .edits = &.{.{ .insert = .{ .after = generation.after, .ids = &.{ user, output.id } } }} } });
    }
    _ = try self.write(a, actions.items);
}

fn newRecord(a: std.mem.Allocator, item: Value, id: u64, owner: u64, snapshot: ?u64) !Value {
    const role = try j.text(j.get(item, "role"));
    if (std.meta.stringToEnum(F.Role, role) == null or std.mem.eql(u8, role, "tool")) return error.InvalidRole;
    _ = try j.text(j.get(item, "content"));
    return j.value(a, .{ .id = id, .role = role, .content = j.get(item, "content"), .kind = if (snapshot != null) "summary" else "message", .origin_worker = owner, .source_snapshot = snapshot });
}
pub fn readGroups(a: std.mem.Allocator, snapshot: Value, ids: Value) !Value {
    var result: Value = .{ .array = .init(a) };
    const groups = try items(j.get(snapshot, "groups"));
    for (try items(ids)) |id| try result.array.append(find(groups, try number(id)) orelse return error.InvalidSelection);
    return result;
}
pub fn items(value: Value) ![]Value {
    if (value == .array) return value.array.items;
    return error.ExpectedArray;
}
pub fn number(value: Value) !u64 {
    if (value != .integer or value.integer < 0 or value.integer > F.max_sequence) return error.InvalidInteger;
    return @intCast(value.integer);
}
fn find(history: []const Value, id: u64) ?Value {
    for (history) |item| {
        const found = number(j.get(item, "id")) catch continue;
        if (found == id) return item;
    }
    return null;
}
