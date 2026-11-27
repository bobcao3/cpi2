//! Full post-hook request and replayable output for one leased Codex socket.
const std = @import("std");
const tree = @import("json_tree");
const responses = @import("responses.zig");
const State = @This();
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

arena: std.heap.ArenaAllocator,
request: Value,
response_id: []const u8,

pub fn capture(owner: Allocator, scratch: Allocator, full: Value, result: Value) !?*State {
    if (!eligible(full)) return null;
    const id = field(result, "id");
    if (id != .string or id.string.len == 0) return null;
    // An unsuccessful or incomplete result can project to different history.
    var accepted = responses.parse(scratch, result) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer accepted.deinit(scratch);
    const state = try owner.create(State);
    errdefer owner.destroy(state);
    state.arena = .init(owner);
    errdefer state.arena.deinit();
    const a = state.arena.allocator();
    state.response_id = try a.dupe(u8, id.string);
    state.request = try tree.copy(a, full);
    if (!state.request.object.contains("input")) {
        try state.request.object.put(a, "input", .{ .array = .init(a) });
    }
    const prefix = &state.request.object.getPtr("input").?.array;
    for (field(result, "output").array.items) |item| {
        const kind = field(item, "type").string;
        if (std.mem.eql(u8, kind, "function_call_output") or std.mem.eql(u8, kind, "custom_tool_call_output")) continue;
        const replay = try responses.codexInputItem(scratch, item);
        try prefix.append(try tree.copy(a, replay));
    }
    return state;
}

pub fn destroy(self: *State) void {
    const owner = self.arena.child_allocator;
    self.arena.deinit();
    owner.destroy(self);
}

/// Returns null when changing any request setting or part of the old prefix
/// requires replay. The returned request borrows the full payload's children.
pub fn delta(self: *const State, a: Allocator, full: Value) !?Value {
    if (!eligible(full)) return null;
    var fields = self.request.object.iterator();
    while (fields.next()) |field_entry| {
        const key = field_entry.key_ptr.*;
        if (std.mem.eql(u8, key, "input")) continue;
        const current = full.object.get(key) orelse return null;
        if (!try tree.equal(a, field_entry.value_ptr.*, current)) return null;
    }
    // The saved request always has an input array, including an empty prefix.
    if (self.request.object.count() - 1 != full.object.count() - @intFromBool(full.object.contains("input"))) return null;

    const baseline = self.request.object.get("input").?.array.items;
    const current = if (full.object.get("input")) |value| value.array.items else &.{};
    if (current.len < baseline.len) return null;
    for (baseline, current[0..baseline.len]) |previous, item| {
        if (!try tree.equal(a, previous, item)) return null;
    }
    var items = std.array_list.Managed(Value).init(a);
    try items.appendSlice(current[baseline.len..]);
    var payload = try full.object.clone(a);
    try payload.put(a, "input", .{ .array = items });
    try payload.put(a, "previous_response_id", .{ .string = self.response_id });
    return .{ .object = payload };
}

fn eligible(full: Value) bool {
    if (full != .object or full.object.contains("previous_response_id")) return false;
    const store = field(full, "store");
    if (store != .bool or store.bool) return false;
    return if (full.object.get("input")) |input| input == .array else true;
}

fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
