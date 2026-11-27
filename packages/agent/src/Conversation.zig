const std = @import("std");
const j = @import("json.zig");
const Value = j.Value;
const Kind = enum { input, response, program, checkpoint, branch };

pub fn validateEntry(entry: Value) !void {
    _ = std.meta.stringToEnum(Kind, j.text(j.get(entry, "kind"))) orelse return error.InvalidConversation;
}

pub const initial = "{\"ctx\":{},\"capabilities\":[],\"capabilities_revision\":0,\"conversation\":{\"revision\":0,\"head\":null,\"next\":1,\"entries\":[]},\"commands\":[],\"active\":null,\"closing\":false}";

fn find(conv: Value, id: []const u8) ?Value {
    for (j.get(conv, "entries").array.items) |entry| if (std.mem.eql(u8, j.text(j.get(entry, "id")), id)) return entry;
    return null;
}

fn appendEntry(doc: *j.Document, entry: Value) ![]const u8 {
    const a = doc.allocator();
    var owned = entry;
    const conv = j.ptr(&doc.value, "conversation");
    var next = j.number(j.get(conv.*, "next"));
    var id = try std.fmt.allocPrint(a, "e{d}", .{next});
    while (find(conv.*, id) != null) {
        next += 1;
        id = try std.fmt.allocPrint(a, "e{d}", .{next});
    }
    try j.put(a, conv, "next", j.integer(next + 1));
    try j.put(a, &owned, "id", j.string(id));
    try j.put(a, &owned, "parent", j.get(conv.*, "head"));
    try j.put(a, conv, "head", j.string(id));
    try j.put(a, conv, "revision", j.integer(j.number(j.get(conv.*, "revision")) + 1));
    try j.ptr(conv, "entries").array.append(owned);
    return id;
}

pub fn appendInput(doc: *j.Document, text: []const u8) ![]const u8 {
    const a = doc.allocator();
    var entry = j.object();
    try j.put(a, &entry, "kind", j.string("input"));
    try j.put(a, &entry, "text", j.string(try a.dupe(u8, text)));
    return appendEntry(doc, entry);
}

pub fn appendResponse(doc: *j.Document, output: Value, model: []const u8, usage: Value) ![]const u8 {
    const a = doc.allocator();
    var entry = j.object();
    try j.put(a, &entry, "kind", j.string("response"));
    try j.put(a, &entry, "output", try j.copy(a, output));
    try j.put(a, &entry, "model", j.string(try a.dupe(u8, model)));
    try j.put(a, &entry, "usage", try j.copy(a, usage));
    return appendEntry(doc, entry);
}

pub fn appendProgram(doc: *j.Document, call_id: []const u8, result: Value, failed: bool, effects: Value) ![]const u8 {
    const a = doc.allocator();
    var entry = j.object();
    try j.put(a, &entry, "kind", j.string("program"));
    try j.put(a, &entry, "call_id", j.string(try a.dupe(u8, call_id)));
    try j.put(a, &entry, "result", try j.copy(a, result));
    try j.put(a, &entry, "failed", .{ .bool = failed });
    try j.put(a, &entry, "effects", try j.copy(a, effects));
    try j.put(a, &entry, "images", try j.copy(a, j.get(j.get(doc.value, "active"), "images")));
    return appendEntry(doc, entry);
}

pub fn path(a: std.mem.Allocator, state: Value) ![]Value {
    return ancestry(a, state, true);
}

fn ancestry(a: std.mem.Allocator, state: Value, bounded: bool) ![]Value {
    const conv = j.get(state, "conversation");
    var chain: std.ArrayList(Value) = .empty;
    var cursor = j.text(j.get(conv, "head"));
    const entries = j.get(conv, "entries");
    var guard: usize = 0;
    var boundary: ?[]const u8 = null;
    while (cursor.len > 0) : (guard += 1) {
        if (guard >= entries.array.items.len) return error.InvalidConversation;
        const entry = find(conv, cursor) orelse return error.InvalidConversation;
        try validateEntry(entry);
        try chain.append(a, entry);
        if (bounded and boundary == null and std.mem.eql(u8, j.text(j.get(entry, "kind")), "checkpoint")) boundary = j.text(j.get(entry, "first_kept"));
        if (boundary) |first| if (std.mem.eql(u8, first, cursor)) break;
        cursor = j.text(j.get(entry, "parent"));
    }
    std.mem.reverse(Value, chain.items);
    return chain.items;
}

pub fn retainable(entry: Value) bool {
    const kind = j.text(j.get(entry, "kind"));
    return std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "response");
}

pub fn retentionIndex(chain: []const Value, first: []const u8) ?usize {
    for (chain, 0..) |entry, index| {
        if (std.mem.eql(u8, j.text(j.get(entry, "id")), first) and retainable(entry)) return index;
    }
    return null;
}

pub fn retained(chain: []const Value) !struct { first: usize, checkpoint: ?Value } {
    var index = chain.len;
    while (index > 0) {
        index -= 1;
        const entry = chain[index];
        if (!std.mem.eql(u8, j.text(j.get(entry, "kind")), "checkpoint")) continue;
        return .{ .first = retentionIndex(chain[0..index], j.text(j.get(entry, "first_kept"))) orelse return error.InvalidConversation, .checkpoint = entry };
    }
    return .{ .first = 0, .checkpoint = null };
}

pub fn project(a: std.mem.Allocator, state: Value) !Value {
    const chain = try path(a, state);
    const boundary = try retained(chain);
    return @import("openai.zig").context(a, chain[boundary.first..], if (boundary.checkpoint) |entry| j.text(j.get(entry, "summary")) else null);
}

pub fn domainEntry(a: std.mem.Allocator, entry: Value) !Value {
    try validateEntry(entry);
    var out = j.object();
    inline for (.{ "id", "parent", "model", "usage", "result", "failed", "first_kept", "metadata", "summary_usage", "summary_model" }) |key| try j.put(a, &out, key, j.get(entry, key));
    const kind = j.text(j.get(entry, "kind"));
    const output = j.get(entry, "output");
    try j.put(a, &out, "kind", j.string(kind));
    if (std.mem.eql(u8, kind, "input") and j.get(entry, "text") != .null) try j.put(a, &out, "text", j.get(entry, "text"));
    if (std.mem.eql(u8, kind, "checkpoint")) try j.put(a, &out, "text", j.get(entry, "summary"));
    if (std.mem.eql(u8, kind, "program")) try j.put(a, &out, "observations", j.get(entry, "effects"));
    if (output == .array) {
        var text: std.ArrayList(u8) = .empty;
        var thinking: std.ArrayList(u8) = .empty;
        var calls = j.array(a);
        for (output.array.items) |item| {
            const t = j.text(j.get(item, "type"));
            if (std.mem.eql(u8, t, "function_call")) {
                var call = j.object();
                try j.put(a, &call, "id", j.get(item, "call_id"));
                try j.put(a, &call, "name", j.get(item, "name"));
                try j.put(a, &call, "arguments", j.parse(a, j.text(j.get(item, "arguments"))) catch .null);
                try calls.array.append(call);
            }
            const content = j.get(item, if (std.mem.eql(u8, t, "reasoning")) "summary" else "content");
            if (content == .array) for (content.array.items) |part| {
                const value = j.get(part, "text");
                if (value == .string) try (if (std.mem.eql(u8, t, "reasoning")) &thinking else &text).appendSlice(a, value.string);
            };
        }
        try j.put(a, &out, "text", j.string(text.items));
        try j.put(a, &out, "thinking", j.string(thinking.items));
        try j.put(a, &out, "calls", calls);
    }
    return out;
}

pub fn estimate(a: std.mem.Allocator, state: Value) !u64 {
    const chain = try path(a, state);
    var trailing: u64 = 0;
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const entry = chain[i];
        if (std.mem.eql(u8, j.text(j.get(entry, "kind")), "checkpoint")) return contentTokens(try project(a, state));
        const usage = j.get(entry, "usage");
        const measured = j.number(j.get(usage, "total_tokens"));
        const total = if (measured > 0) measured else j.number(j.get(usage, "input_tokens")) + j.number(j.get(usage, "output_tokens"));
        const model_config = j.get(j.get(state, "active"), "model");
        const wanted = if (model_config == .object) j.text(j.get(model_config, "model")) else j.text(j.get(state, "conversation_model"));
        if (total > 0 and (wanted.len == 0 or std.mem.eql(u8, wanted, j.text(j.get(entry, "model"))))) return total + trailing;
        trailing += contentTokens(try domainEntry(a, entry));
        const images = j.get(entry, "images");
        if (images == .array) trailing += images.array.items.len * 1200;
    }
    return trailing;
}

pub fn snapshot(a: std.mem.Allocator, state: Value) !Value {
    var result = j.object();
    const conv = j.get(state, "conversation");
    try j.put(a, &result, "revision", j.get(conv, "revision"));
    try j.put(a, &result, "head", j.get(conv, "head"));
    var entries = j.array(a);
    for (j.get(conv, "entries").array.items) |entry| try entries.array.append(try domainEntry(a, entry));
    try j.put(a, &result, "entries", entries);
    var ids = j.array(a);
    var checkpoint: Value = .null;
    for (try ancestry(a, state, false)) |entry| {
        try ids.array.append(j.get(entry, "id"));
        if (std.mem.eql(u8, j.text(j.get(entry, "kind")), "checkpoint")) checkpoint = j.get(entry, "id");
    }
    try j.put(a, &result, "path", ids);
    try j.put(a, &result, "checkpoint", checkpoint);
    try j.put(a, &result, "suspended", j.get(j.get(state, "suspended"), "continuation"));
    var estimate_value = j.object();
    try j.put(a, &estimate_value, "tokens", j.integer(try estimate(a, state)));
    try j.put(a, &result, "context_estimate", estimate_value);
    return result;
}

pub fn appendCheckpoint(doc: *j.Document, first: []const u8, summary: []const u8, metadata: Value, usage: Value) ![]const u8 {
    const a = doc.allocator();
    if (retentionIndex(try path(a, doc.value), first) == null) return error.InvalidRetentionBoundary;
    var entry = j.object();
    try j.put(a, &entry, "kind", j.string("checkpoint"));
    try j.put(a, &entry, "first_kept", j.string(try a.dupe(u8, first)));
    try j.put(a, &entry, "summary", j.string(try a.dupe(u8, summary)));
    try j.put(a, &entry, "metadata", try j.copy(a, metadata));
    try j.put(a, &entry, "summary_usage", try j.copy(a, usage));
    try j.put(a, &entry, "summary_model", j.get(j.get(j.get(doc.value, "active"), "model"), "model"));
    return appendEntry(doc, entry);
}

pub fn branch(doc: *j.Document, at: []const u8) !void {
    const a = doc.allocator();
    const conv = j.ptr(&doc.value, "conversation");
    if (find(conv.*, at) == null) return error.UnknownEntry;
    try j.put(a, conv, "head", j.string(try a.dupe(u8, at)));
    var entry = j.object();
    try j.put(a, &entry, "kind", j.string("branch"));
    _ = try appendEntry(doc, entry);
    try repair(doc);
}

pub fn repair(doc: *j.Document) !void {
    const a = doc.allocator();
    const history = try project(a, doc.value);
    for (history.array.items, 0..) |item, i| {
        if (!std.mem.eql(u8, j.text(j.get(item, "type")), "function_call")) continue;
        const id = j.text(j.get(item, "call_id"));
        var found = false;
        for (history.array.items[i + 1 ..]) |later| if (std.mem.eql(u8, j.text(j.get(later, "call_id")), id) and std.mem.eql(u8, j.text(j.get(later, "type")), "function_call_output")) {
            found = true;
            break;
        };
        if (!found) _ = try appendProgram(doc, id, j.string("Interrupted historical call. Inspect current state before repeating effects."), true, j.array(a));
    }
}

fn contentTokens(value: Value) u64 {
    switch (value) {
        .string => |bytes| return (bytes.len + 3) / 4,
        .array => |values| {
            var total: u64 = 0;
            for (values.items) |item| total += contentTokens(item);
            return total;
        },
        .object => |object| {
            if (std.mem.eql(u8, j.text(object.get("type") orelse .null), "input_image")) return 1200;
            var total: u64 = 8;
            var it = object.iterator();
            while (it.next()) |entry| total += (entry.key_ptr.len + 3) / 4 + contentTokens(entry.value_ptr.*);
            return total;
        },
        else => return 1,
    }
}
