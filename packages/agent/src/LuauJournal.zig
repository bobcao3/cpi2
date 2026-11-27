const std = @import("std");
const json_text = @import("json_tree").text;
const p = @import("session_protocol");
const Journal = @import("SessionJournal.zig");
const ContextCodec = @import("LuauContextJournal.zig").Codec;
const application = @import("LuauContextJournal.zig");
const j = @import("json.zig");
const Conversation = @import("Conversation.zig");
const RunState = @import("RunState.zig");
const tasks = @import("TaskJournal.zig");
const Value = j.Value;
const F = p.frames;
const Allocator = std.mem.Allocator;
const Actions = std.ArrayList(F.Action);

pub const runtime_namespace = "agent.luau.runtime";
pub const commands_namespace = "agent.luau.commands";
pub const markers_namespace = "agent.luau.history";
pub const runtime_contract: p.Extensions.Contract = .{ .version = .{ .id = runtime_namespace, .version = "1" }, .initial_state = empty, .validate = validateEdits, .reduce = reduceEdits, .replay_strings = replayEdits };
pub const commands_contract = mapContract(commands_namespace);
pub const markers_contract = mapContract(markers_namespace);
pub const renderer: p.State.Renderer = .{
    .version = .{ .id = "agent.luau.responses", .version = "1" },
    .render = render,
    .accepts_cut_tool_group = acceptsCutToolGroup,
    .accepts_historical_tool_group = acceptsHistoricalToolGroup,
};

fn empty(_: Allocator) !Value {
    return j.object();
}
fn mapContract(comptime name: []const u8) p.Extensions.Contract {
    return .{ .version = .{ .id = name, .version = "1" }, .initial_state = empty, .validate = validatePut, .reduce = reducePut, .replay_strings = replayPut };
}
fn validatePut(previous: Value, action: []const u8, input: Value) !void {
    if (previous != .object or !std.mem.eql(u8, action, "put") or input != .object or input.object.count() != 2 or j.get(input, "id") != .string or j.get(input, "json") != .string) return error.InvalidLuauRecord;
    if (previous.object.contains(j.text(j.get(input, "id")))) return error.DuplicateLuauRecord;
}
fn reducePut(a: Allocator, previous: Value, _: []const u8, input: Value) !Value {
    try json_text.validate(a, j.text(j.get(input, "json")));
    var result = j.object();
    for (previous.object.keys(), previous.object.values()) |key, value| try j.put(a, &result, key, value);
    try j.put(a, &result, j.text(j.get(input, "id")), j.get(input, "json"));
    return result;
}
fn replayPut(pool: *p.Extensions.ReplayStorage, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    var result: Value = .{ .object = try previous.object.clone(retained) };
    try pool.put(&result, retained, scratch, j.text(j.get(input, "id")), j.text(j.get(input, "json")));
    return result;
}
fn validateEdits(previous: Value, action: []const u8, input: Value) !void {
    if (previous != .object or !std.mem.eql(u8, action, "assign") or input != .object) return error.InvalidLuauRuntime;
    for (input.object.values()) |value| if (value != .string and value != .null) return error.InvalidLuauRuntime;
}
fn reduceEdits(a: Allocator, previous: Value, _: []const u8, input: Value) !Value {
    return reduceEditsInto(null, a, a, previous, input);
}
fn replayEdits(pool: *p.Extensions.ReplayStorage, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    return reduceEditsInto(pool, retained, scratch, previous, input);
}
fn reduceEditsInto(pool: ?*p.Extensions.ReplayStorage, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    var result: Value = .{ .object = try previous.object.clone(retained) };
    for (input.object.keys(), input.object.values()) |key, value| {
        if (value == .null) {
            _ = result.object.orderedRemove(key);
            continue;
        }
        if (pool) |intern| {
            try intern.put(&result, retained, scratch, key, value.string);
        } else {
            try json_text.validate(scratch, value.string);
            try j.put(retained, &result, key, value);
        }
    }
    return result;
}

pub fn options(a: Allocator, codec: ContextCodec) !Journal.Options {
    var contracts: std.ArrayList(p.Extensions.Contract) = .empty;
    try contracts.appendSlice(a, &.{ runtime_contract, commands_contract, markers_contract, codec.contract });
    try contracts.appendSlice(a, codec.extra_contracts);
    var renderers: std.ArrayList(p.State.Renderer) = .empty;
    try renderers.appendSlice(a, &.{ renderer, p.State.standard_renderer });
    try renderers.appendSlice(a, codec.extra_renderers);
    return .{ .contracts = contracts.items, .renderers = renderers.items };
}

pub const JournalQuery = union(enum) {
    context_field: []const u8,
    extension: []const u8,
};

pub fn readJournal(gpa: Allocator, io: std.Io, path: []const u8, id: []const u8, codec: ContextCodec, query: JournalQuery) !j.Document {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var journal = Journal.openExisting(gpa, io, path, id, try options(a, codec)) catch |err| switch (err) {
        error.FileNotFound => return j.Document.initValue(gpa, .null),
        else => return err,
    };
    defer journal.deinit();
    const value = switch (query) {
        .extension => |namespace| if (journal.state.extensions.get(namespace)) |entry| entry.value else .null,
        .context_field => |field| if (journal.state.extensions.get(codec.namespace)) |entry|
            j.get(try codec.materialize(a, entry.value), field)
        else
            .null,
    };
    return j.Document.initValue(gpa, value);
}

fn extension(a: Allocator, actions: *Actions, journal: *const Journal, namespace: []const u8, contract: p.Extensions.Contract, action: []const u8, input: Value) !void {
    try actions.append(a, .{ .@"control.extension" = .{ .namespace = namespace, .expected_head = if (journal.state.extensions.get(namespace)) |entry| entry.head else 0, .action = action, .input = .{ .contract = contract.version, .value = input } } });
}

pub fn effectValue(journal: *const Journal, allocator: std.mem.Allocator, effect: Value) !Value {
    const reference = j.get(effect, "effect_ref");
    if (reference == .null) return j.copy(allocator, effect);
    if (reference != .integer or reference.integer <= 0) return error.InvalidReference;
    const result = (try journal.frame(allocator, @intCast(reference.integer))).action.@"control.effect.result";
    const operation = journal.state.effects.get(result.effect_id) orelse return error.UnknownEffect;
    const intent = (try journal.frame(allocator, operation.intent)).action.@"control.effect.intent";
    var value = try j.copy(allocator, effect);
    _ = value.object.orderedRemove("effect_ref");
    try j.put(allocator, &value, "endpoint", j.string(intent.endpoint.name));
    try j.put(allocator, &value, "arguments", try j.parse(allocator, j.text(j.get(intent.arguments, "json"))));
    try j.put(allocator, &value, "result", try j.parse(allocator, j.text(j.get(result.result, "json"))));
    return value;
}

pub fn expandEffects(journal: *const Journal, allocator: std.mem.Allocator, effects: Value) !Value {
    if (effects != .array) return j.copy(allocator, effects);
    var expanded = j.array(allocator);
    for (effects.array.items) |effect| try expanded.array.append(try effectValue(journal, allocator, effect));
    return expanded;
}

pub fn hasEffectReferences(effects: Value) bool {
    if (effects != .array) return false;
    for (effects.array.items) |effect| if (j.get(effect, "effect_ref") != .null) return true;
    return false;
}

pub fn expandInterruption(journal: *const Journal, allocator: std.mem.Allocator, diagnostic: *Value) !void {
    if (!std.mem.eql(u8, j.text(j.get(diagnostic.*, "code")), "interrupted")) return;
    const effects = j.get(diagnostic.*, "effects");
    if (hasEffectReferences(effects)) try j.put(allocator, diagnostic, "effects", try expandEffects(journal, allocator, effects));
}

pub fn expandProgramEntry(journal: *const Journal, allocator: std.mem.Allocator, entry: *Value) !void {
    if (j.get(entry.*, "effects") == .array) try j.put(allocator, entry, "effects", try expandEffects(journal, allocator, j.get(entry.*, "effects")));
    if (std.mem.eql(u8, j.text(j.get(entry.*, "kind")), "program") and j.flag(j.get(entry.*, "failed")) and j.get(entry.*, "result") == .object)
        try expandInterruption(journal, allocator, j.ptr(entry, "result"));
}

fn effectView(a: Allocator, effect: Value) !Value {
    if (effect != .object or !std.mem.eql(u8, j.text(j.get(effect, "endpoint")), "model.request")) return effect;
    var result = j.object();
    for (effect.object.keys(), effect.object.values()) |key, value| {
        if (!std.mem.eql(u8, key, "arguments") or value != .object) {
            try j.put(a, &result, key, value);
            continue;
        }
        var arguments = j.object();
        for (value.object.keys(), value.object.values()) |name, item| {
            if (!std.mem.eql(u8, name, "body") or item != .object) {
                try j.put(a, &arguments, name, item);
                continue;
            }
            var settings = j.object();
            for (item.object.keys(), item.object.values()) |field, setting| {
                if (std.mem.eql(u8, field, "input") or std.mem.eql(u8, field, "messages") or std.mem.eql(u8, field, "tools") or std.mem.eql(u8, field, "instructions")) continue;
                try j.put(a, &settings, field, setting);
            }
            try j.put(a, &arguments, name, settings);
        }
        try j.put(a, &result, key, arguments);
    }
    return result;
}

fn runtimeView(a: Allocator, root: Value) !Value {
    var result = j.object();
    for (root.object.keys(), root.object.values()) |key, value| {
        if (std.mem.eql(u8, key, "ctx") or std.mem.eql(u8, key, "closing") or std.mem.eql(u8, key, "closed") or std.mem.eql(u8, key, "close_id") or std.mem.eql(u8, key, "archive") or std.mem.eql(u8, key, "pending_history") or std.mem.eql(u8, key, "bootstrap_context")) continue;
        if (std.mem.eql(u8, key, "conversation")) {
            var metadata = j.object();
            for (value.object.keys(), value.object.values()) |name, item| if (!std.mem.eql(u8, name, "entries")) {
                try j.put(a, &metadata, name, item);
            };
            try j.put(a, &result, key, metadata);
        } else if ((std.mem.eql(u8, key, "active") or std.mem.eql(u8, key, "suspended")) and value == .object) {
            var run = j.object();
            for (value.object.keys(), value.object.values()) |name, item| {
                if (std.mem.eql(u8, name, "reply")) continue;
                if (std.mem.eql(u8, name, "effect")) {
                    try j.put(a, &run, name, try effectView(a, item));
                    continue;
                }
                if (std.mem.eql(u8, name, "effects") and item == .array) {
                    var effects = j.array(a);
                    for (item.array.items) |effect| try effects.array.append(try effectView(a, effect));
                    try j.put(a, &run, name, effects);
                    continue;
                }
                if (std.mem.eql(u8, name, "model") and item == .object) {
                    var model = j.object();
                    for (item.object.keys(), item.object.values()) |field, setting| if (!std.mem.eql(u8, field, "credential")) {
                        try j.put(a, &model, field, setting);
                    };
                    try j.put(a, &run, name, model);
                } else try j.put(a, &run, name, item);
            }
            try j.put(a, &result, key, .{ .bool = true });
            for (run.object.keys(), run.object.values()) |name, item| try j.put(a, &result, try std.fmt.allocPrint(a, "{s}/{s}", .{ key, name }), item);
        } else try j.put(a, &result, key, value);
    }
    return result;
}

pub fn restore(journal: *const Journal, codec: ContextCodec, gpa: Allocator) !j.Document {
    const tracing = @import("kit").tracing;
    const scope = tracing.beginEvent("cpi.journal.restore_runtime");
    defer tracing.endEvent(scope);
    var document = try j.Document.init(gpa, Conversation.initial);
    errdefer document.deinit();
    const a = document.allocator();
    if (journal.state.extensions.get(runtime_namespace)) |entry| {
        for (entry.value.object.keys(), entry.value.object.values()) |key, encoded| {
            if (std.mem.startsWith(u8, key, "active/") or std.mem.startsWith(u8, key, "suspended/")) continue;
            var parsed = try j.parse(a, encoded.string);
            if ((std.mem.eql(u8, key, "active") or std.mem.eql(u8, key, "suspended")) and parsed == .bool) parsed = j.object();
            if (std.mem.eql(u8, key, "active")) try RunState.restore(&document, .active, &parsed) else if (std.mem.eql(u8, key, "suspended")) try RunState.restore(&document, .suspended, &parsed) else try j.put(a, &document.value, key, parsed);
        }
        for (entry.value.object.keys(), entry.value.object.values()) |key, encoded| {
            const slash = std.mem.indexOfScalar(u8, key, '/') orelse continue;
            const name = key[0..slash];
            if (!std.mem.eql(u8, name, "active") and !std.mem.eql(u8, name, "suspended")) continue;
            const run = j.ptr(&document.value, name);
            if (run.* != .object) return error.InvalidLuauRecord;
            try j.put(a, run, key[slash + 1 ..], try j.parse(a, encoded.string));
        }
    }
    try j.put(a, &document.value, "ctx", try applicationContext(journal, codec, a, application.scope(document.value)));
    const conversation = j.ptr(&document.value, "conversation");
    var entries = j.array(a);
    var id = j.text(j.get(conversation.*, "head"));
    var boundary_id: ?[]const u8 = null;
    while (id.len != 0) {
        if (entries.array.items.len > journal.state.messages.count() + 1) return error.InvalidConversation;
        const item = (try history(journal, a, "conversation", id)) orelse return error.UnknownEntry;
        try entries.array.append(item);
        if (boundary_id == null and std.mem.eql(u8, j.text(j.get(item, "kind")), "checkpoint")) boundary_id = j.text(j.get(item, "first_kept"));
        if (boundary_id) |first| if (std.mem.eql(u8, first, id)) break;
        id = j.text(j.get(item, "parent"));
    }
    std.mem.reverse(Value, entries.array.items);
    try j.put(a, conversation, "entries", entries);
    return document;
}

pub fn applicationContext(journal: *const Journal, codec: ContextCodec, a: Allocator, scope: []const u8) !Value {
    return decodeApplicationContext(&journal.state.extensions, codec, a, scope);
}

pub fn decodeApplicationContext(extensions: *const p.Extensions, codec: ContextCodec, a: Allocator, scope: []const u8) !Value {
    return codec.materialize(a, try privateApplicationContext(extensions, codec, a, scope));
}

pub fn viewDocuments(journal: *const Journal, codec: ContextCodec, a: Allocator, scope: []const u8) !Value {
    const project = codec.view_documents orelse return j.object();
    return project(a, try privateApplicationContext(&journal.state.extensions, codec, a, scope));
}

fn privateApplicationContext(extensions: *const p.Extensions, codec: ContextCodec, a: Allocator, scope: []const u8) !Value {
    const namespace = try application.namespace(a, codec.namespace, scope);
    return if (extensions.get(namespace)) |entry| entry.value else codec.contract.initial_state(a);
}

pub fn seedHead(journal: *const Journal, scope: []const u8) !?[]const u8 {
    const context = journal.state.contexts.get(scope) orelse return error.UnknownContext;
    var index = context.ids.items.len;
    while (index != 0) {
        index -= 1;
        const key = context.ids.items[index];
        if (!std.mem.startsWith(u8, key, "application/") or journal.state.displays.contains(key)) continue;
        return key["application/".len..];
    }
    return null;
}

pub fn ownsApplicationEntry(a: Allocator, scope: []const u8, id: []const u8) !bool {
    if (std.mem.eql(u8, scope, application.main)) return !std.mem.startsWith(u8, id, "a/");
    return std.mem.startsWith(u8, id, try application.entryPrefix(a, scope));
}

pub fn visibleApplicationEntry(journal: *const Journal, a: Allocator, scope: []const u8, id: []const u8) !bool {
    if (try ownsApplicationEntry(a, scope, id)) return true;
    if (try applicationReference(journal, a, id)) |ref| {
        if (try journal.state.historyOrigin(journal.source(), scope, ref)) |origin| {
            if (try ownsApplicationEntry(a, origin, id)) return true;
        }
    }
    const context = journal.state.contexts.get(scope) orelse return error.UnknownContext;
    for (context.ids.items) |key| {
        if (std.mem.startsWith(u8, key, "application/") and std.mem.eql(u8, key["application/".len..], id)) return true;
    }
    return false;
}

fn applicationReference(journal: *const Journal, a: Allocator, id: []const u8) !?u64 {
    const key = try historyId(a, "application", id);
    if (journal.state.messages.get(key)) |ref| return ref;
    const markers = journal.state.extensions.get(markers_namespace) orelse return null;
    if (!markers.value.object.contains(key)) return null;
    const source = journal.source();
    var seq = journal.sequence;
    while (seq != 0) : (seq -= 1) {
        const frame = try source.get(seq);
        if (frame.action != .@"control.extension") continue;
        const action = frame.action.@"control.extension";
        if (std.mem.eql(u8, action.namespace, markers_namespace) and
            std.mem.eql(u8, j.text(j.get(action.input.value, "id")), key)) return seq;
    }
    return error.InvalidJournal;
}

pub const ApplicationFork = struct { base: F.ContextBase, head: ?[]const u8 };

pub const ApplicationTip = struct {
    /// Semantic ancestor at the tip. A display-only append retains its parent.
    head: ?[]const u8,
    /// The last committed entry, including display-only appends.
    target: []const u8,
};

pub fn lastOwnedApplicationTip(journal: *const Journal, a: Allocator, scope: []const u8) !?ApplicationTip {
    const prefix = "application/";
    const source = journal.source();
    const keys = journal.state.messages.keys();
    const references = journal.state.messages.values();
    var scratch: std.heap.ArenaAllocator = .init(journal.gpa);
    defer scratch.deinit();
    var i = keys.len;
    while (i > 0) {
        i -= 1;
        const key = keys[i];
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
        const id = key[prefix.len..];
        if (!try ownsApplicationEntry(scratch.allocator(), scope, id)) continue;
        const message = try source.message(references[i]);
        const entry = (try decodeEntry(scratch.allocator(), message)) orelse return error.InvalidLuauRecord;
        if (std.mem.eql(u8, j.text(j.get(entry.value, "kind")), "model_result")) continue;
        if (!journal.state.displays.contains(key)) {
            const target = try a.dupe(u8, id);
            return .{ .head = target, .target = target };
        }
        const parent = j.get(entry.value, "parent");
        return .{ .head = if (parent == .string) try a.dupe(u8, parent.string) else null, .target = try a.dupe(u8, id) };
    }
    return null;
}

pub fn planApplicationFork(journal: *const Journal, a: Allocator, parent: []const u8, id: []const u8) !ApplicationFork {
    const anchor = (try applicationReference(journal, a, id)) orelse return error.UnknownEntry;
    const source = journal.source();
    const origin = (try journal.state.historyOrigin(source, parent, anchor)) orelse return error.UnknownEntry;
    if (!try ownsApplicationEntry(a, origin, id)) return error.UnknownEntry;
    const frame = try source.get(anchor);
    const at = anchor + (frame.tx.count - frame.tx.index - 1);
    const entry = (try history(journal, a, "application", id)) orelse return error.UnknownEntry;
    const key = try historyId(a, "application", id);
    const head = if (journal.state.displays.contains(key) or std.mem.eql(u8, j.text(j.get(entry, "kind")), "model_result"))
        j.text(j.get(entry, "parent"))
    else
        id;
    const snapshot = try journal.state.contextAt(a, source, origin, at);
    var displays: std.ArrayList([]const u8) = .empty;
    for (snapshot) |item| {
        if (journal.state.displays.get(item)) |ref| if (ref <= anchor) try displays.append(a, try a.dupe(u8, item));
    }
    return .{
        .head = if (head.len == 0) null else try a.dupe(u8, head),
        .base = .{
            .context = try a.dupe(u8, origin),
            .at = at,
            .fork = .{
                .parent = try a.dupe(u8, parent),
                .anchor = anchor,
                .selected = try selectIds(a, journal, "application", head, .null, displays.items, null),
            },
        },
    };
}

pub const Entry = p.State.ProjectionCache.Entry;
const EntryWire = struct { stream: []const u8, json: []const u8 };

fn entryWire(message: F.Message) ?EntryWire {
    for (message.content) |part| {
        const value = j.get(part, "value");
        if (!std.mem.eql(u8, j.text(j.get(value, "format")), "agent.luau.entry.v1")) continue;
        return .{ .stream = j.text(j.get(value, "stream")), .json = j.text(j.get(value, "json")) };
    }
    return null;
}

pub fn hasApplicationDialogue(a: Allocator, transaction: *const p.Transaction) !bool {
    for (transaction.frames) |frame| {
        if (frame.frame.action != .@"document.message.append") continue;
        const message = frame.frame.action.@"document.message.append".message;
        if (message.role != .user and message.role != .assistant) continue;
        const wire = entryWire(message) orelse continue;
        const prefix = "application/";
        if (!std.mem.eql(u8, wire.stream, "application") or !std.mem.startsWith(u8, message.id, prefix) or
            !try ownsApplicationEntry(a, application.main, message.id[prefix.len..])) continue;
        const kind = j.text(j.get(try j.parse(a, wire.json), "kind"));
        if (std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "response")) return true;
    }
    return false;
}

pub fn decodeEntry(a: Allocator, message: F.Message) !?Entry {
    const entry = entryWire(message) orelse return null;
    return .{ .stream = entry.stream, .value = try j.parse(a, entry.json) };
}
pub fn historyId(a: Allocator, stream: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ stream, id });
}
pub fn displayApplicationEntry(a: Allocator, scope: []const u8, after: ?[]const u8, item: Value) !F.MessageAppend {
    const content = try a.alloc(Value, 1);
    content[0] = try j.project(a, .{ .type = "json", .value = .{ .format = "agent.luau.entry.v1", .stream = "application", .json = try j.encode(a, item) } });
    return .{
        .message = .{ .id = try historyId(a, "application", j.text(j.get(item, "id"))), .role = .system, .content = content },
        .placement = .{ .context = scope, .after = after },
        .display_only = true,
    };
}
pub fn history(journal: *const Journal, a: Allocator, stream: []const u8, id: []const u8) !?Value {
    const bytes = (try historyText(journal, stream, id)) orelse return null;
    return try j.parse(a, bytes);
}

/// Borrow the history JSON until the next journal read.
pub fn historyText(journal: *const Journal, stream: []const u8, id: []const u8) !?[]const u8 {
    var key_buffer: [256]u8 = undefined;
    var lookup: std.heap.BufferFirstAllocator = .init(&key_buffer, journal.gpa);
    const scratch = lookup.allocator();
    const key = try historyId(scratch, stream, id);
    defer scratch.free(key);
    if (journal.state.messages.get(key)) |ref| {
        const entry = entryWire(try journal.source().message(ref)) orelse return error.InvalidLuauRecord;
        return entry.json;
    }
    if (journal.state.extensions.get(markers_namespace)) |markers| if (markers.value.object.get(key)) |encoded| return encoded.string;
    return null;
}

fn callId(a: Allocator, request: []const u8, wire: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "call/{s}/{s}", .{ request, j.sourceHash(wire) });
}
fn pendingCall(journal: *const Journal, a: Allocator, scope: []const u8, wire: []const u8) !?[]const u8 {
    const suffix = try std.fmt.allocPrint(a, "/{s}", .{j.sourceHash(wire)});
    var index = journal.state.calls.count();
    while (index > 0) {
        index -= 1;
        const id = journal.state.calls.keys()[index];
        const call = journal.state.calls.values()[index];
        if (call.answered == null and std.mem.eql(u8, call.conversation orelse application.main, scope) and std.mem.endsWith(u8, id, suffix)) return id;
    }
    return null;
}
fn modelId(journal: *const Journal, ref: u64) ?[]const u8 {
    if (ref <= 0) return null;
    for (journal.state.requests.keys(), journal.state.requests.values()) |id, operation| if (operation.intent == ref and operation.finish == null) return id;
    return null;
}

fn captureEntry(a: Allocator, actions: *Actions, journal: *const Journal, scope: []const u8, stream: []const u8, item: Value, request: ?[]const u8) !bool {
    const identity = try historyId(a, stream, j.text(j.get(item, "id")));
    if (journal.state.messages.contains(identity)) return false;
    if (journal.state.extensions.get(markers_namespace)) |markers| if (markers.value.object.contains(identity)) return false;
    if (std.mem.eql(u8, j.text(j.get(item, "kind")), "branch")) {
        try extension(a, actions, journal, markers_namespace, markers_contract, "put", try j.project(a, .{ .id = identity, .json = try j.encode(a, item) }));
        return false;
    }
    const kind = j.text(j.get(item, "kind"));
    var role: F.Role = if (std.mem.eql(u8, kind, "response") or std.mem.eql(u8, kind, "model_result")) .assistant else if (std.mem.eql(u8, kind, "write")) .system else .user;
    const reply = if (std.mem.eql(u8, kind, "program")) try pendingCall(journal, a, scope, j.text(j.get(item, "call_id"))) else null;
    if (reply != null) role = .tool;
    var calls: std.ArrayList(F.ToolCall) = .empty;
    if (role == .assistant and request != null) {
        const output = j.get(item, "output");
        if (output == .array) for (output.array.items) |call| {
            if (!std.mem.eql(u8, j.text(j.get(call, "type")), "function_call")) continue;
            const name = j.text(j.get(call, "name"));
            if (!journal.state.tools.contains(name)) continue;
            try calls.append(a, .{ .id = try callId(a, request.?, j.text(j.get(call, "call_id"))), .name = name, .arguments = j.get(call, "arguments") });
        };
    }
    const content = try a.alloc(Value, 1);
    content[0] = try j.project(a, .{ .type = "json", .value = .{ .format = "agent.luau.entry.v1", .stream = stream, .json = try j.encode(a, item) } });
    try actions.append(a, .{ .@"document.message.append" = .{ .message = .{ .id = identity, .role = role, .content = content, .tool_calls = if (calls.items.len > 0) calls.items else null, .tool_call_id = reply }, .placement = null, .request = if (role == .assistant) request else null } });
    return role == .assistant and request != null;
}

/// Install transcript data into a fresh journal. The staging writer remains
/// private until its caller publishes the complete, validated journal.
pub fn seedApplicationBranch(journal: *Journal, codec: ContextCodec, entries: []const Value, context: Value, extra: []const @FieldType(F.Action, "control.extension")) !void {
    if (journal.sequence != 0) return error.InvalidState;
    var scratch: std.heap.ArenaAllocator = .init(journal.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const actor: F.Actor = .{ .kind = .host, .id = "application-fork" };
    var offset: usize = 0;
    while (offset < entries.len) {
        const end = @min(offset + 32, entries.len);
        var actions: Actions = .empty;
        var after = journal.state.contexts.get(application.main).?.ids.getLastOrNull();
        for (entries[offset..end]) |row| {
            const entry = j.get(row, "entry");
            const id = j.text(j.get(entry, "id"));
            if (id.len == 0 or !try ownsApplicationEntry(a, application.main, id)) return error.InvalidLuauRecord;
            if (j.flag(j.get(row, "display_only"))) {
                try actions.append(a, .{ .@"document.message.append" = try displayApplicationEntry(a, application.main, after, entry) });
            } else {
                const start = actions.items.len;
                _ = try captureEntry(a, &actions, journal, application.main, "application", entry, null);
                if (actions.items.len == start) return error.InvalidLuauRecord;
                const action = &actions.items[start];
                if (action.* != .@"document.message.append") continue;
                action.@"document.message.append".placement = .{ .context = application.main, .after = after };
            }
            after = actions.items[actions.items.len - 1].@"document.message.append".message.id;
        }
        _ = try journal.commit(try std.fmt.allocPrint(a, "application-fork/{d}", .{offset}), actor, actions.items);
        offset = end;
        _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
    }
    var actions: Actions = .empty;
    const head = if (codec.selection) |selection| try selection(a, context) else null;
    try select(a, &actions, journal, application.main, "application", head orelse "", .null, null);
    try finishApplicationSeed(journal, a, codec, context, extra, &actions, actor);
}

/// Copy the complete main application archive. Host request and effect frames
/// remain in the source. Entries retain their semantic and display ancestry.
pub fn seedApplicationArchive(journal: *Journal, original: *const Journal, codec: ContextCodec, context: Value, extra: []const @FieldType(F.Action, "control.extension"), projection: ?ArchiveProjection) !void {
    if (journal.sequence != 0 or !codec.scoped_application) return error.InvalidState;
    const scope = application.main;
    const prefix = "application/";
    const actor: F.Actor = .{ .kind = .host, .id = "application-archive" };
    var scratch: std.heap.ArenaAllocator = .init(journal.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var actions: Actions = .empty;
    var marker_head: u64 = 0;
    const source = original.source();
    var reference: u64 = 1;
    while (reference <= original.sequence) : (reference += 1) {
        try original.io.checkCancel();
        switch ((try source.get(reference)).action) {
            .@"document.message.append" => |append| {
                const id = savedApplicationId(append.message.id) orelse continue;
                if (!try ownsApplicationEntry(a, scope, id)) continue;
                const decoded = (try decodeEntry(a, append.message)) orelse return error.InvalidLuauRecord;
                var entry = decoded.value;
                const display = append.display_only orelse false;
                // The source reader may rotate its frame cache during nested lookups.
                const key = try historyId(a, "application", j.text(j.get(entry, "id")));
                if (!std.mem.eql(u8, key, append.message.id)) return error.InvalidLuauRecord;
                const predecessor = try recordedDisplayParent(original, a, scope, key, reference);
                const after = if (predecessor) |previous| try historyId(a, "application", previous) else null;
                try expandProgramEntry(original, a, &entry);
                if (projection) |project| try project.entry(project.context, a, &entry);
                if (display) {
                    try actions.append(a, .{ .@"document.message.append" = try displayApplicationEntry(a, scope, after, entry) });
                } else {
                    const index = actions.items.len;
                    _ = try captureEntry(a, &actions, journal, scope, "application", entry, null);
                    if (actions.items.len != index + 1 or actions.items[index] != .@"document.message.append") return error.InvalidLuauRecord;
                    if (after != null) actions.items[index].@"document.message.append".placement = .{ .context = scope, .after = after };
                }
            },
            .@"control.extension" => |change| {
                if (!std.mem.eql(u8, change.namespace, markers_namespace)) continue;
                const id = savedApplicationId(j.text(j.get(change.input.value, "id"))) orelse continue;
                if (!try ownsApplicationEntry(a, scope, id)) continue;
                try actions.append(a, .{ .@"control.extension" = .{
                    .namespace = markers_namespace,
                    .expected_head = marker_head,
                    .action = "put",
                    .input = .{ .contract = markers_contract.version, .value = try j.copy(a, change.input.value) },
                } });
            },
            else => continue,
        }
        if (actions.items.len == 32) {
            try commitApplicationArchive(journal, a, actor, actions.items);
            marker_head = if (journal.state.extensions.get(markers_namespace)) |entry| entry.head else 0;
            _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
            actions = .empty;
        }
    }
    if (actions.items.len != 0) try commitApplicationArchive(journal, a, actor, actions.items);
    _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
    actions = .empty;
    const selected = original.state.contexts.get(scope) orelse return error.UnknownContext;
    var desired: std.ArrayList([]const u8) = .empty;
    for (selected.ids.items) |key| if (std.mem.startsWith(u8, key, prefix) and journal.state.messages.contains(key)) {
        try desired.append(a, key);
    };
    try replaceSelected(a, &actions, journal, scope, desired.items);
    try finishApplicationSeed(journal, a, codec, context, extra, &actions, actor);
}

pub const ArchiveProjection = struct {
    context: *anyopaque,
    /// Materialize application-owned display metadata before the batch is saved.
    /// The entry's ID, kind and parent are part of its archived identity.
    entry: *const fn (*anyopaque, Allocator, *Value) anyerror!void,
};

fn savedApplicationId(key: []const u8) ?[]const u8 {
    const prefix = "application/";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    return key[prefix.len..];
}

fn commitApplicationArchive(journal: *Journal, a: Allocator, actor: F.Actor, actions: []const F.Action) !void {
    const id = try std.fmt.allocPrint(a, "application-archive/{d}", .{journal.sequence});
    _ = try journal.commit(id, actor, actions);
}

fn finishApplicationSeed(journal: *Journal, a: Allocator, codec: ContextCodec, context: Value, extra: []const @FieldType(F.Action, "control.extension"), actions: *Actions, actor: F.Actor) !void {
    if (try codec.capture(a, try applicationContext(journal, codec, a, application.main), context)) |change|
        try extension(a, actions, journal, codec.namespace, codec.contract, codec.action, change);
    for (extra) |change| try actions.append(a, .{ .@"control.extension" = change });
    if (actions.items.len != 0) _ = try journal.commit("application-fork/context", actor, actions.items);
}

fn lookupEntry(journal: *const Journal, a: Allocator, stream: []const u8, id: []const u8, added: Value) !Value {
    if (added == .array) for (added.array.items) |item| if (std.mem.eql(u8, j.text(j.get(item, "id")), id)) return item;
    return (try history(journal, a, stream, id)) orelse error.UnknownEntry;
}

const DisplayGroup = struct {
    ids: std.ArrayList([]const u8) = .empty,
    through: ?[]const u8 = null,

    fn appendSelected(self: DisplayGroup, a: Allocator, target: *std.ArrayList([]const u8)) !void {
        for (self.ids.items) |id| {
            try target.append(a, id);
            if (std.mem.eql(u8, id, self.through orelse "")) break;
        }
    }
};

const DisplayFilter = struct {
    follows_branch: *const fn (Value) bool,
    retained: std.StringHashMapUnmanaged(void) = .empty,

    fn historical(self: *DisplayFilter, a: Allocator, journal: *const Journal, scope: []const u8, target: []const u8) !void {
        var cursor = target;
        var limit = journal.sequence + 1;
        while (cursor.len != 0) {
            const ref = (try applicationReference(journal, a, cursor)) orelse return error.UnknownEntry;
            if (ref >= limit) return error.InvalidConversation;
            limit = ref;
            const key = try historyId(a, "application", cursor);
            if (journal.state.displays.contains(key)) try self.retained.put(a, key, {});
            const origin = (try journal.state.historyOrigin(journal.source(), scope, ref)) orelse return error.UnknownEntry;
            cursor = (try recordedDisplayParent(journal, a, origin, key, ref)) orelse blk: {
                const entry = (try history(journal, a, "application", cursor)) orelse return error.UnknownEntry;
                break :blk j.text(j.get(entry, "parent"));
            };
        }
    }
};

fn selectIds(a: Allocator, journal: *const Journal, stream: []const u8, head: []const u8, added: Value, display_ids: []const []const u8, filter: ?*const DisplayFilter) ![]const []const u8 {
    var chain: std.ArrayList(Value) = .empty;
    var cursor = head;
    var first_kept: ?[]const u8 = null;
    var summary: ?[]const u8 = null;
    while (cursor.len != 0) {
        if (chain.items.len > journal.state.messages.count() + @as(usize, @intCast(journal.sequence)) + 1024) return error.InvalidConversation;
        const item = try lookupEntry(journal, a, stream, cursor, added);
        try chain.append(a, item);
        if (first_kept == null) {
            const kind = j.text(j.get(item, "kind"));
            if (std.mem.eql(u8, kind, "checkpoint")) {
                first_kept = j.text(j.get(item, "first_kept"));
                summary = cursor;
            } else if (std.mem.eql(u8, kind, "write")) {
                const anchor = j.get(item, "context_start");
                if (anchor == .string) first_kept = anchor.string;
            }
        }
        if (first_kept) |first| if (std.mem.eql(u8, first, cursor)) break;
        cursor = j.text(j.get(item, "parent"));
    }
    std.mem.reverse(Value, chain.items);
    var desired: std.ArrayList([]const u8) = .empty;
    var display: std.StringHashMapUnmanaged(DisplayGroup) = .empty;
    if (std.mem.eql(u8, stream, "application")) for (display_ids) |id| {
        const ref = journal.state.displays.get(id) orelse return error.UnknownMessage;
        const stored = (try journal.frame(a, ref)).action.@"document.message.append";
        const entry = (try decodeEntry(a, stored.message)) orelse continue;
        if (!std.mem.eql(u8, entry.stream, stream)) continue;
        if (filter) |view| {
            if (view.follows_branch(entry.value) and !view.retained.contains(id)) continue;
        }
        const list = try display.getOrPut(a, j.text(j.get(entry.value, "parent")));
        if (!list.found_existing) list.value_ptr.* = .{};
        try list.value_ptr.ids.append(a, id);
    };
    if (display.count() != 0) for (chain.items) |item| {
        const key = try historyId(a, stream, j.text(j.get(item, "id")));
        if (!journal.state.displays.contains(key)) continue;
        if (display.getPtr(j.text(j.get(item, "parent")))) |group| group.through = key;
    };
    if (summary) |id| try desired.append(a, try historyId(a, stream, id));
    const reset_root = chain.items.len != 0 and j.flag(j.get(chain.items[0], "reset"));
    if (first_kept == null and !reset_root) if (display.get("")) |notes| try notes.appendSelected(a, &desired);
    for (chain.items) |item| {
        const kind = j.text(j.get(item, "kind"));
        const id = j.text(j.get(item, "id"));
        if (!std.mem.eql(u8, kind, "branch") and !std.mem.eql(u8, kind, "checkpoint") and !std.mem.eql(u8, kind, "model_result")) {
            const key = try historyId(a, stream, id);
            if (!journal.state.displays.contains(key)) try desired.append(a, key);
        }
        if (display.get(id)) |notes| try notes.appendSelected(a, &desired);
    }
    return desired.items;
}

pub fn recordedDisplayParent(journal: *const Journal, a: Allocator, scope: []const u8, key: []const u8, reference: u64) !?[]const u8 {
    const source = journal.source();
    const frame = try source.get(reference);
    if (frame.action != .@"document.message.append") return null;
    if (frame.action.@"document.message.append".placement) |placement| {
        if (!std.mem.eql(u8, placement.context, scope)) return null;
        return earlierDisplay(journal, a, placement.after, reference);
    }
    const last = reference + frame.tx.count - frame.tx.index - 1;
    var seq = reference + 1;
    while (seq <= last) : (seq += 1) {
        const action = (try source.get(seq)).action;
        if (action != .@"control.document_mutation") continue;
        const mutation = action.@"control.document_mutation";
        if (!std.mem.eql(u8, mutation.context, scope)) continue;
        for (mutation.edits) |edit| {
            if (edit != .insert) continue;
            const inserted = edit.insert;
            var index = inserted.ids.len;
            while (index > 0) {
                index -= 1;
                if (!std.mem.eql(u8, inserted.ids[index], key)) continue;
                return earlierDisplay(journal, a, if (index == 0) inserted.after else inserted.ids[index - 1], reference);
            }
        }
    }
    return null;
}

fn earlierDisplay(journal: *const Journal, a: Allocator, after: ?[]const u8, reference: u64) !?[]const u8 {
    const key = after orelse return null;
    const prefix = "application/";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const display = journal.state.displays.get(key) orelse return null;
    if (display >= reference) return null;
    return try a.dupe(u8, key[prefix.len..]);
}

fn select(a: Allocator, actions: *Actions, journal: *const Journal, scope: []const u8, stream: []const u8, head: []const u8, added: Value, filter: ?*const DisplayFilter) !void {
    const context = journal.state.contexts.get(scope) orelse return error.UnknownContext;
    const desired = try selectIds(a, journal, stream, head, added, context.display_ids.items, filter);
    try replaceSelected(a, actions, journal, scope, desired);
}

fn replaceSelected(a: Allocator, actions: *Actions, journal: *const Journal, scope: []const u8, desired: []const []const u8) !void {
    const context = journal.state.contexts.get(scope) orelse return error.UnknownContext;
    var equal = context.ids.items.len == desired.len;
    if (equal) for (context.ids.items, desired) |x, y| {
        if (!std.mem.eql(u8, x, y)) {
            equal = false;
            break;
        }
    };
    if (equal) return;
    const edits = try a.alloc(F.Edit, @as(usize, @intFromBool(context.ids.items.len > 0)) + @as(usize, @intFromBool(desired.len > 0)));
    var index: usize = 0;
    if (context.ids.items.len > 0) {
        edits[index] = .{ .drop = context.ids.items };
        index += 1;
    }
    if (desired.len > 0) edits[index] = .{ .insert = .{ .after = null, .ids = desired } };
    try actions.append(a, .{ .@"control.document_mutation" = .{ .context = scope, .expected_head = context.head, .edits = edits } });
}

fn selectApplication(a: Allocator, actions: *Actions, journal: *const Journal, codec: ContextCodec, scope: []const u8, before: Value, after: Value, entries: Value) !void {
    const selection = codec.selection orelse return;
    const old = try selection(a, before) orelse "";
    const current = try selection(a, after) orelse "";
    const rules = codec.display_selection;
    const target = if (rules) |display| display.navigation_target(before, after) else null;
    const has_entries = entries == .array and entries.array.items.len != 0;
    if (target == null and !has_entries and std.mem.eql(u8, old, current)) return;

    var filter: DisplayFilter = undefined;
    if (rules) |display| {
        filter = .{ .follows_branch = display.follows_branch };
        const context = journal.state.contexts.get(scope) orelse return error.UnknownContext;
        if (context.display_ids.items.len != 0) {
            if (target) |entry| {
                try filter.historical(a, journal, scope, entry);
            } else {
                for (context.ids.items) |id| {
                    if (journal.state.displays.contains(id)) try filter.retained.put(a, id, {});
                }
            }
        }
    }
    try select(a, actions, journal, scope, "application", current, entries, if (rules != null) &filter else null);
}

pub fn appendApplicationDisplay(journal: *Journal, codec: ContextCodec, transaction_id: []const u8, scope: []const u8, entry: Value, context: ?Value, companion: @import("Session.zig").ExtensionWrite) !void {
    var scratch: std.heap.ArenaAllocator = .init(journal.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const id = j.text(j.get(entry, "id"));
    if (id.len == 0 or !try ownsApplicationEntry(a, scope, id)) return error.InvalidLuauRecord;
    const selected = journal.state.contexts.get(scope) orelse return error.UnknownContext;
    var after = selected.ids.getLastOrNull();
    var actions: Actions = .empty;
    const before = if (context != null) try applicationContext(journal, codec, a, scope) else .null;
    if (context) |next| {
        try selectApplication(a, &actions, journal, codec, scope, before, next, .null);
        if (actions.items.len != 0) {
            after = null;
            for (actions.items[0].@"control.document_mutation".edits) |edit| {
                if (edit == .insert and edit.insert.ids.len != 0) after = edit.insert.ids[edit.insert.ids.len - 1];
            }
        }
    }
    try actions.append(a, .{ .@"document.message.append" = try displayApplicationEntry(a, scope, after, entry) });
    if (context) |next| {
        if (try codec.capture(a, before, next)) |change|
            try extension(a, &actions, journal, try application.namespace(a, codec.namespace, scope), codec.contract, codec.action, change);
    }
    const saved = journal.state.extensions.get(companion.namespace);
    try actions.append(a, .{ .@"control.extension" = .{
        .namespace = companion.namespace,
        .expected_head = if (saved) |value| value.head else 0,
        .action = companion.action,
        .input = companion.input,
    } });
    _ = try journal.commit(transaction_id, .{ .kind = .host, .id = "application-display" }, actions.items);
}

fn modelStatus(item: Value) F.Status {
    const status = j.text(j.get(item, "status"));
    if (status.len == 0 or std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "incomplete") and std.mem.eql(u8, j.text(j.get(item, "kind")), "response") and
        std.mem.eql(u8, j.text(j.get(item, "stop_reason")), "length")) return .completed;
    return if (std.mem.eql(u8, status, "cancelled")) .cancelled else .failed;
}

pub fn planAdmission(a: Allocator, actions: *Actions, journal: *const Journal, codec: ContextCodec, extensions: *const p.Extensions, scope: []const u8, before: Value, after: Value, entries: Value) !void {
    for (entries.array.items) |entry| {
        const kind = j.text(j.get(entry, "kind"));
        if (!std.mem.eql(u8, kind, "input") and !std.mem.eql(u8, kind, "write") and !std.mem.eql(u8, kind, "checkpoint")) return error.InvalidAdmissionEntry;
        _ = try captureEntry(a, actions, journal, scope, "application", entry, null);
    }
    try selectApplication(a, actions, journal, codec, scope, before, after, entries);
    if (try codec.capture(a, before, after)) |change| {
        try extension(a, actions, journal, try application.namespace(a, codec.namespace, scope), codec.contract, codec.action, change);
    }
    if (codec.checkpoint_actions) |collect| try collect(a, extensions, scope, before, after, actions);
}

pub fn modelRoute(journal: *const Journal, codec: ContextCodec, a: Allocator, request: @FieldType(F.Action, "control.model.request"), model: @FieldType(F.Action, "control.set_model")) !?ContextCodec.ModelRoute {
    if (model.selection) |selection| return .{ .selection = selection, .credential = model.credential_ref orelse return error.MissingModelCredential };
    const legacy = codec.legacy_model_route orelse return null;
    var historical = try journal.state.extensionsAt(journal.source(), request.input_at, journal.options.contracts);
    defer historical.deinit();
    const value = try decodeApplicationContext(&historical, codec, a, request.conversation orelse application.main);
    return legacy(a, value, model);
}

pub fn providerCancellation(journal: *Journal, a: Allocator, codec: ContextCodec, model: @FieldType(F.Action, "control.model.request")) !?F.Action {
    const task_kind = codec.model_cancel_task orelse return null;
    const saved = journal.state.requests.get(model.request_id) orelse return null;
    const progress = (try journal.frame(a, saved.progress orelse return null)).action.@"control.model.progress";
    const selection = (try journal.frame(a, model.model_frame)).action.@"control.set_model";
    const route = try modelRoute(journal, codec, a, model, selection);
    const task_state = journal.state.extensions.get(tasks.namespace);
    var input = try j.project(a, .{
        .response_id = progress.response_id,
        .route = selection.route,
        .credential = if (route) |resolved| resolved.credential else selection.credential_ref orelse "",
    });
    if (progress.deferred) |deferred| try j.put(a, &input, "deferred", try j.project(a, deferred));
    if (route) |resolved| try j.put(a, &input, "selection", resolved.selection);
    return try tasks.action(a, if (task_state) |current| current.head else 0, .{
        .now_ms = @intCast(@max(0, std.Io.Clock.real.now(journal.io).toMilliseconds())),
        .operation = .{ .submit = .{
            .id = try std.fmt.allocPrint(a, "provider-cancel/{s}", .{model.request_id}),
            .kind = task_kind,
            .background = true,
            .conversation = model.conversation,
            .input = input,
        } },
    });
}

pub fn boundary(journal: *Journal, codec: ContextCodec, before: Value, document: *j.Document, application_history: Value, extra: []const F.Action, recovering: bool) !void {
    const a = document.allocator();
    var actions: Actions = .empty;
    const scope = application.scope(document.value);
    const namespace = try application.namespace(a, codec.namespace, scope);
    const previous_scope = application.scope(before);
    const old_ctx = try applicationContext(journal, codec, a, scope);
    const bootstrap_context = j.get(document.value, "bootstrap_context");
    const bootstrap_scope = j.text(j.get(bootstrap_context, "scope"));
    if (bootstrap_context == .object and !std.mem.eql(u8, bootstrap_scope, scope)) {
        const saved = j.get(bootstrap_context, "value");
        const previous = try applicationContext(journal, codec, a, bootstrap_scope);
        if (try codec.capture(a, previous, saved)) |change| {
            try extension(a, &actions, journal, try application.namespace(a, codec.namespace, bootstrap_scope), codec.contract, codec.action, change);
        }
        if (codec.checkpoint_actions) |collect| try collect(a, &journal.state.extensions, bootstrap_scope, previous, saved, &actions);
    }
    const old_run = j.get(before, "active");
    const run = j.get(document.value, "active");
    const current_model = j.number(j.get(run, "core_model_request"));
    const previous_model = j.number(j.get(old_run, "core_model_request"));
    const old_marker = if (std.mem.eql(u8, scope, previous_scope)) j.get(j.get(before, "ctx"), "__interrupted_application") else .null;
    const interrupted_model = j.number(j.get(old_marker, "model_resume"));
    const active_request = modelId(journal, previous_model) orelse modelId(journal, current_model);
    const request = active_request orelse if (j.get(old_marker, "model_reply") == .object) modelId(journal, interrupted_model) else null;
    var finish: ?F.Status = null;
    const conversation = j.get(j.get(document.value, "conversation"), "entries");
    if (conversation == .array) for (conversation.array.items) |item| {
        if (try captureEntry(a, &actions, journal, application.main, "conversation", item, request)) finish = modelStatus(item);
    };
    if (application_history == .array) for (application_history.array.items) |item| {
        if (try captureEntry(a, &actions, journal, scope, "application", item, request)) finish = modelStatus(item);
    };
    const old_head = j.get(j.get(before, "conversation"), "head");
    const new_head = j.get(j.get(document.value, "conversation"), "head");
    if (!try j.equal(a, old_head, new_head)) try select(a, &actions, journal, application.main, "conversation", j.text(new_head), conversation, null);
    const next_ctx = j.get(document.value, "ctx");
    try selectApplication(a, &actions, journal, codec, scope, old_ctx, next_ctx, application_history);
    const retained = j.get(next_ctx, "__interrupted_application");
    const retained_model = j.number(j.get(retained, "model_resume"));
    if (try codec.capture(a, old_ctx, next_ctx)) |change| try extension(a, &actions, journal, namespace, codec.contract, codec.action, change);
    if (codec.checkpoint_actions) |collect| try collect(a, &journal.state.extensions, scope, old_ctx, next_ctx, &actions);
    const cancelled_model = j.number(j.get(next_ctx, "cancelled_model_resume"));
    if (codec.model_cancel_task != null and cancelled_model != 0 and cancelled_model == interrupted_model and
        cancelled_model != retained_model and cancelled_model != j.number(j.get(old_ctx, "cancelled_model_resume")))
    {
        const model = (try journal.frame(a, cancelled_model)).action.@"control.model.request";
        const saved = journal.state.requests.get(model.request_id).?;
        if (saved.finish == null and !saved.cancelled) {
            try actions.append(a, .{ .@"control.cancel" = .{ .target = cancelled_model, .reason = "execution cancelled" } });
            if (try providerCancellation(journal, a, codec, model)) |task| try actions.append(a, task);
        }
    }
    const commands = j.ptr(&document.value, "commands");
    var index: usize = 0;
    while (index < commands.array.items.len) {
        const item = commands.array.items[index];
        const status = j.text(j.get(item, "status"));
        if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) {
            index += 1;
            continue;
        }
        try extension(a, &actions, journal, commands_namespace, commands_contract, "put", try j.project(a, .{ .id = j.text(j.get(item, "id")), .json = try j.encode(a, item) }));
        _ = commands.array.orderedRemove(index);
    }
    const view = try runtimeView(a, document.value);
    var edits = j.object();
    const previous = if (journal.state.extensions.get(runtime_namespace)) |saved| saved.value else j.object();
    for (view.object.keys(), view.object.values()) |key, value| {
        const encoded = try j.encode(a, value);
        const old = previous.object.get(key);
        if (old != null and p.json.equalBytes(old.?.string, encoded)) continue;
        try j.put(a, &edits, key, j.string(encoded));
    }
    for (previous.object.keys()) |key| if (!view.object.contains(key)) {
        try j.put(a, &edits, key, .null);
    };
    if (edits.object.count() > 0) try extension(a, &actions, journal, runtime_namespace, runtime_contract, "assign", edits);
    const gone = run == .null or !std.mem.eql(u8, j.text(j.get(old_run, "id")), j.text(j.get(run, "id")));
    const reply = j.get(j.get(old_run, "reply"), "value");
    const deferred_poll = codec.defer_model_poll and std.mem.eql(u8, j.text(j.get(reply, "status")), "poll_pending");
    const keep_model = retained_model != 0 and retained_model == previous_model and (recovering or deferred_poll or j.get(retained, "model_reply") == .object);
    const close_active = active_request != null and gone and !keep_model;
    const closing_request = if (finish != null or close_active) request else null;
    if (closing_request) |id| {
        try actions.append(a, .{ .@"control.model.finish" = .{ .request_id = id, .status = finish orelse .interrupted, .usage = .null, .diagnostic = .null } });
    }
    if (retained_model != interrupted_model and interrupted_model != current_model) {
        if (modelId(journal, interrupted_model)) |id| {
            if (closing_request == null or !std.mem.eql(u8, closing_request.?, id)) {
                try actions.append(a, .{ .@"control.model.finish" = .{ .request_id = id, .status = .interrupted, .usage = .null, .diagnostic = .null } });
            }
        }
    }
    try actions.appendSlice(a, extra);
    if (recovering) {
        for (journal.state.requests.keys(), journal.state.requests.values()) |id, operation| {
            if (operation.finish != null or (operation.intent == retained_model and !operation.cancelled)) continue;
            if (codec.scoped_application and !operation.cancelled) {
                const issued = (try journal.frame(a, operation.intent)).action.@"control.model.request";
                const owner = issued.conversation orelse application.main;
                if (!std.mem.eql(u8, scope, owner)) {
                    const saved = if (std.mem.eql(u8, bootstrap_scope, owner)) j.get(bootstrap_context, "value") else try applicationContext(journal, codec, a, owner);
                    if (j.number(j.get(j.get(saved, "__interrupted_application"), "model_resume")) == operation.intent) continue;
                }
            }
            var settled = false;
            for (actions.items) |action| if (action == .@"control.model.finish" and std.mem.eql(u8, action.@"control.model.finish".request_id, id)) {
                settled = true;
                break;
            };
            if (!settled) try actions.append(a, .{ .@"control.model.finish" = .{ .request_id = id, .status = .interrupted, .usage = .null, .diagnostic = .null } });
        }
        for (journal.state.effects.keys(), journal.state.effects.values()) |id, operation| {
            if (operation.finish != null) continue;
            try actions.append(a, .{ .@"control.effect.result" = .{ .effect_id = id, .status = .indeterminate, .result = try j.project(a, .{ .format = "agent.luau.json", .json = "{\"code\":\"interrupted\"}" }) } });
        }
    }
    if (actions.items.len == 0) return;
    const tx = try std.fmt.allocPrint(a, "luau-{d}", .{journal.sequence + 1});
    _ = try journal.commit(tx, .{ .kind = .host, .id = "luau" }, actions.items);
}

fn renderEntry(a: Allocator, input: *std.json.Array, message: F.Message, entry: ?Entry, edits: *const std.StringHashMapUnmanaged(Value), cache: ?*p.State.ProjectionCache) !void {
    if (entry) |saved| if (edits.get(j.text(j.get(saved.value, "id")))) |edit| {
        const replacements = j.get(edit, "messages");
        if (replacements == .array) try input.appendSlice(replacements.array.items);
        return;
    };
    const items = if (cache) |memo| try memo.rendered(a, message, entry, renderUnedited) else try renderUnedited(a, message, entry);
    try input.appendSlice(items);
}

fn renderUnedited(a: Allocator, message: F.Message, entry: ?Entry) anyerror![]const Value {
    if (entry) |saved| {
        const item = saved.value;
        const kind = j.text(j.get(item, "kind"));
        if (std.mem.eql(u8, kind, "checkpoint")) {
            const result = try a.alloc(Value, 1);
            result[0] = try j.project(a, .{ .role = "user", .content = try std.fmt.allocPrint(a, "The conversation history before this point was compacted into the following summary:\n\n<summary>\n{s}\n</summary>", .{j.text(j.get(item, "summary"))}) });
            return result;
        }
        const items = try @import("openai.zig").borrowedContext(a, &.{item});
        return items.array.items;
    }
    var raw: ?Value = null;
    for (message.content) |part| {
        const value = j.get(part, "value");
        if (std.mem.eql(u8, j.text(j.get(value, "format")), "agent.luau.input.v1")) raw = try j.parse(a, j.text(j.get(value, "json")));
    }
    const result = try a.alloc(Value, 1);
    if (raw) |item| {
        result[0] = item;
    } else {
        var text: std.ArrayList(u8) = .empty;
        for (message.content) |part| if (std.mem.eql(u8, j.text(j.get(part, "type")), "text")) {
            try text.appendSlice(a, j.text(j.get(part, "text")));
        };
        result[0] = try j.project(a, .{ .role = @tagName(message.role), .content = text.items });
    }
    return result;
}

fn toolPairs(a: Allocator, items: []const Value) !Value {
    var results: std.StringHashMapUnmanaged(usize) = .empty;
    defer results.deinit(a);
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, j.text(j.get(item, "type")), "function_call_output")) try results.put(a, j.text(j.get(item, "call_id")), i);
    }
    var output = j.array(a);
    var pending: std.ArrayList(Value) = .empty;
    defer pending.deinit(a);
    for (items, 0..) |item, i| {
        const kind = j.text(j.get(item, "type"));
        if (std.mem.eql(u8, kind, "function_call_output")) continue;
        if (std.mem.eql(u8, kind, "function_call")) {
            try output.array.append(item);
            const call = j.text(j.get(item, "call_id"));
            const position = results.get(call);
            try pending.append(a, if (position != null and position.? > i) items[position.?] else try j.project(a, .{
                .type = "function_call_output",
                .call_id = call,
                .output = "Tool result unavailable in the selected conversation context.",
            }));
        } else {
            try output.array.appendSlice(pending.items);
            pending.clearRetainingCapacity();
            try output.array.append(item);
        }
    }
    try output.array.appendSlice(pending.items);
    return output;
}

fn writeHead(entry: Value) bool {
    return std.mem.eql(u8, j.text(j.get(entry, "kind")), "write") and j.get(entry, "context_start") == .string;
}

fn acceptsCutToolGroup(a: Allocator, messages: []const F.Message) !bool {
    var cut = false;
    for (messages) |message| {
        const saved = (try decodeEntry(a, message)) orelse return false;
        if (!std.mem.eql(u8, saved.stream, "application")) return false;
        cut = cut or writeHead(saved.value);
    }
    return cut;
}

fn acceptsHistoricalToolGroup(a: Allocator, snapshot: p.State.Snapshot, messages: []const F.Message) !bool {
    const selected = try snapshot.inheritedForkMessages();
    if (selected.len == 0) return false;
    for (messages) |message| {
        const entry = (try decodeEntry(a, message)) orelse return false;
        if (!std.mem.eql(u8, entry.stream, "application")) return false;
    }
    var inherited: std.StringHashMapUnmanaged(void) = .empty;
    defer inherited.deinit(a);
    for (selected) |id| try inherited.put(a, id, {});
    p.State.validateToolGroups(a, messages, &inherited) catch |err| switch (err) {
        error.IncompleteToolGroup, error.UnmatchedToolResult => return false,
        else => return err,
    };
    return true;
}

fn renderMessages(a: Allocator, snapshot: p.State.Snapshot) !Value {
    const messages = try snapshot.messagesForRendering(a);
    const entries = try a.alloc(?Entry, messages.len);
    var edits: std.StringHashMapUnmanaged(Value) = .empty;
    defer edits.deinit(a);
    const cache = snapshot.source.projection_cache;
    var head: ?usize = null;
    for (messages, entries, 0..) |message, *entry, i| {
        entry.* = if (cache) |memo| try memo.decoded(a, message, decodeEntry) else try decodeEntry(a, message);
        const item = if (entry.*) |saved| saved.value else continue;
        if (!std.mem.eql(u8, j.text(j.get(item, "kind")), "write")) continue;
        if (writeHead(item)) head = i;
        const updates = j.get(item, "edits");
        if (updates == .array) for (updates.array.items) |edit| try edits.put(a, j.text(j.get(edit, "target")), edit);
    }
    var input = j.array(a);
    if (head) |i| {
        const first = entries[0];
        const summary = if (first) |saved| std.mem.eql(u8, j.text(j.get(saved.value, "kind")), "checkpoint") else false;
        if (!summary) try renderEntry(a, &input.array, messages[i], entries[i], &edits, cache);
    }
    for (messages, entries) |message, entry| {
        if (entry) |saved| if (writeHead(saved.value)) continue;
        try renderEntry(a, &input.array, message, entry, &edits, cache);
    }
    return if (head != null or edits.count() != 0 or (try snapshot.inheritedForkMessages()).len != 0)
        toolPairs(a, input.array.items)
    else
        input;
}

pub fn render(a: Allocator, snapshot: p.State.Snapshot, _: Value) !p.State.Projection {
    const input = try renderMessages(a, snapshot);
    var tools = j.array(a);
    const model = (try snapshot.modelForRendering(a)).action.@"control.set_model";
    const registered = try snapshot.toolsForRendering(a);
    const order = j.get(model.kwargs, "journal_tool_order");
    if (order == .array) {
        for (order.array.items) |name| {
            var found = false;
            for (registered) |tool| if (std.mem.eql(u8, name.string, tool.action.@"control.provider_tool.register".name)) {
                try tools.array.append(tool.action.@"control.provider_tool.register".definition);
                found = true;
                break;
            };
            if (!found) return error.UnknownProviderTool;
        }
    } else for (registered) |tool| try tools.array.append(tool.action.@"control.provider_tool.register".definition);
    const instructions = j.get(model.kwargs, "instructions");
    return .{ .instructions = if (instructions == .string) instructions else j.string(""), .messages = input, .tools = tools };
}
