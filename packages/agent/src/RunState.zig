const std = @import("std");
const j = @import("json.zig");
const Conversation = @import("Conversation.zig");

pub const Cause = enum { ceiling, provider_overflow };
pub const Slot = enum { active, suspended };

pub const Suspend = struct {
    session_id: []const u8,
    sequence: u64,
    cause: Cause,
    context_tokens: ?u64 = null,
};

pub const Suspension = struct {
    command_id: []const u8,
    continuation: []const u8,
    cause: Cause,
    context_tokens: u64,
};

pub const Resume = struct {
    continuation: []const u8,
    command_id: []const u8,
    context_ceiling: ?u64,
};

pub fn suspendRun(doc: *j.Document, request: Suspend) !Suspension {
    const a = doc.allocator();
    const active = j.get(doc.value, "active");
    if (active != .object or j.get(doc.value, "suspended") != .null) return error.InvalidState;
    const id = j.text(j.get(active, "id"));
    const token = try std.fmt.allocPrint(a, "{s}:{s}:{d}", .{ request.session_id, id, request.sequence });
    try j.put(a, &doc.value, "suspended", .null);
    const run = try slotPtr(doc, .active);
    try j.put(a, run, "continuation", j.string(token));
    const context_tokens = request.context_tokens orelse try Conversation.estimate(a, doc.value);
    try transfer(doc, .active, .suspended);
    return .{ .command_id = id, .continuation = token, .cause = request.cause, .context_tokens = context_tokens };
}

pub fn resumeRun(doc: *j.Document, request: Resume) !void {
    const suspended = j.get(doc.value, "suspended");
    if (suspended != .object or !std.mem.eql(u8, j.text(j.get(suspended, "continuation")), request.continuation)) return error.InvalidContinuation;
    if (j.get(doc.value, "active") != .null) return error.InvalidState;
    const a = doc.allocator();
    try j.put(a, &doc.value, "active", .null);
    const run = try slotPtr(doc, .suspended);
    try j.put(a, run, "id", j.string(try a.dupe(u8, request.command_id)));
    try j.put(a, run, "context_ceiling", if (request.context_ceiling) |ceiling| j.integer(ceiling) else .null);
    try transfer(doc, .suspended, .active);
    const model = j.get(j.get(j.get(doc.value, "active"), "model"), "model");
    try j.put(a, &doc.value, "conversation_model", model);
}

pub fn installFresh(doc: *j.Document, fresh: *j.Value) !void {
    if (fresh.* != .object) return error.InvalidState;
    if (j.get(doc.value, "active") != .null) return error.InvalidState;
    try j.put(doc.allocator(), &doc.value, "active", fresh.*);
    fresh.* = .null;
}

pub fn restore(doc: *j.Document, slot: Slot, serialized: *j.Value) !void {
    if (serialized.* != .null and serialized.* != .object) return error.InvalidState;
    if (j.get(doc.value, slotName(slot)) != .null) return error.InvalidState;
    try j.put(doc.allocator(), &doc.value, slotName(slot), serialized.*);
    serialized.* = .null;
}

pub fn clear(doc: *j.Document, slot: Slot) !void {
    try j.put(doc.allocator(), &doc.value, slotName(slot), .null);
}

fn transfer(doc: *j.Document, from: Slot, to: Slot) !void {
    if (from == to) return error.InvalidState;
    const source = try slotPtr(doc, from);
    const destination = try slotPtr(doc, to);
    destination.* = source.*;
    source.* = .null;
}

fn slotPtr(doc: *j.Document, slot: Slot) !*j.Value {
    if (doc.value != .object) return error.InvalidState;
    return doc.value.object.getPtr(slotName(slot)) orelse error.InvalidState;
}

fn slotName(slot: Slot) []const u8 {
    return switch (slot) {
        .active => "active",
        .suspended => "suspended",
    };
}
