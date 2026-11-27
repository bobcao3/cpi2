const std = @import("std");
const protocol = @import("session_protocol");
const tree = protocol.json;
const Value = protocol.frames.Value;
const Allocator = std.mem.Allocator;

pub const namespace = "cpi-minimal.ctx";
pub const action = "assign";
pub const contract: protocol.Extensions.Contract = .{
    .version = .{ .id = "cpi-minimal.ctx", .version = "1" },
    .initial_state = initial,
    .validate = validate,
    .reduce = reduce,
    .replay_strings = replay,
};

pub fn selection(a: Allocator, ctx: Value) !?[]const u8 {
    if (ctx != .object) return error.InvalidMinimalContext;
    const session = ctx.object.get("session") orelse return null;
    if (session != .object) return error.InvalidMinimalContext;
    const head = session.object.get("head") orelse return null;
    if (head == .null) return null;
    if (head != .string) return error.InvalidMinimalContext;
    return try a.dupe(u8, head.string);
}

pub fn navigationTarget(before: Value, after: Value) ?[]const u8 {
    if (before != .object or after != .object) return null;
    const chosen = after.object.get("tree_navigation") orelse return null;
    if (chosen != .object) return null;
    const target = chosen.object.get("target") orelse return null;
    const revision = chosen.object.get("revision") orelse return null;
    if (target != .string or revision != .integer) return null;
    if (before.object.get("tree_navigation")) |prior| {
        if (prior == .object) {
            if (prior.object.get("revision")) |old| {
                if (old == .integer and old.integer == revision.integer) return null;
            }
        }
    }
    return target.string;
}

pub fn capture(a: Allocator, before: Value, after: Value) !?Value {
    if (before != .object or after != .object) return error.InvalidMinimalContext;
    var assignments: Value = .{ .array = .init(a) };
    var removals: Value = .{ .array = .init(a) };
    for (after.object.keys(), after.object.values()) |key, value| {
        if (before.object.get(key)) |old| if (try tree.equal(a, old, value)) continue;
        var entry: Value = .{ .object = .empty };
        try entry.object.put(a, "name", .{ .string = try a.dupe(u8, key) });
        try entry.object.put(a, "json", .{ .string = try encode(a, value) });
        try assignments.array.append(entry);
    }
    for (before.object.keys()) |key| {
        if (!after.object.contains(key)) try removals.array.append(.{ .string = try a.dupe(u8, key) });
    }
    if (assignments.array.items.len == 0 and removals.array.items.len == 0) return null;
    var result: Value = .{ .object = .empty };
    try result.object.put(a, "assign", assignments);
    try result.object.put(a, "erase", removals);
    return result;
}

pub fn materialize(a: Allocator, state: Value) !Value {
    if (state != .object) return error.InvalidMinimalContext;
    var result: Value = .{ .object = .empty };
    for (state.object.keys(), state.object.values()) |key, encoded| {
        if (encoded != .string) return error.InvalidMinimalContext;
        try result.object.put(a, try a.dupe(u8, key), try decode(a, encoded.string));
    }
    return result;
}

pub fn viewDocuments(a: Allocator, state: Value) !Value {
    if (state != .object) return error.InvalidMinimalContext;
    var docs: Value = .{ .object = .empty };
    for ([_][]const u8{ "model_selection", "launch_model_selection", "tree_reopen" }) |name| {
        const saved = state.object.get(name) orelse continue;
        if (saved != .string) return error.InvalidMinimalContext;
        try docs.object.put(a, name, try decode(a, saved.string));
    }
    return docs;
}

pub fn hasLiveRun(a: Allocator, state: Value) !bool {
    if (state != .object) return error.InvalidMinimalContext;
    if (state.object.get("after_run")) |encoded| {
        if (encoded != .string) return error.InvalidMinimalContext;
        if (try decode(a, encoded.string) != .null) return true;
    }
    const encoded = state.object.get("session") orelse return false;
    if (encoded != .string) return error.InvalidMinimalContext;
    const session = try decode(a, encoded.string);
    if (session != .object) return error.InvalidMinimalContext;
    const run = session.object.get("run") orelse return false;
    return run != .null;
}

fn initial(_: Allocator) !Value {
    return .{ .object = .empty };
}

fn validate(previous: Value, name: []const u8, input: Value) !void {
    if (!std.mem.eql(u8, name, action) or previous != .object or input != .object or input.object.count() != 2) return error.InvalidMinimalContext;
    const assignments = input.object.get("assign") orelse return error.InvalidMinimalContext;
    const removals = input.object.get("erase") orelse return error.InvalidMinimalContext;
    if (assignments != .array or removals != .array) return error.InvalidMinimalContext;
    if (assignments.array.items.len == 0 and removals.array.items.len == 0) return error.EmptyContextChange;
    for (previous.object.values()) |value| if (value != .string) return error.InvalidMinimalContext;
    for (assignments.array.items) |entry| {
        if (entry != .object or entry.object.count() != 2) return error.InvalidMinimalContext;
        const key = entry.object.get("name") orelse return error.InvalidMinimalContext;
        const value = entry.object.get("json") orelse return error.InvalidMinimalContext;
        if (key != .string or value != .string) return error.InvalidMinimalContext;
    }
    for (removals.array.items) |key| {
        if (key != .string or !previous.object.contains(key.string)) return error.InvalidMinimalContext;
    }
}

fn reduce(a: Allocator, previous: Value, _: []const u8, input: Value) !Value {
    return reduceInto(null, a, a, previous, input);
}

fn replay(pool: *protocol.Extensions.ReplayStorage, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    return reduceInto(pool, retained, scratch, previous, input);
}

fn reduceInto(pool: ?*protocol.Extensions.ReplayStorage, retained: Allocator, scratch: Allocator, previous: Value, input: Value) !Value {
    var result: Value = .{ .object = try previous.object.clone(retained) };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(scratch);
    for (input.object.get("erase").?.array.items) |key| {
        if ((try seen.getOrPut(scratch, key.string)).found_existing) return error.DuplicateContextEdit;
        _ = result.object.orderedRemove(key.string);
    }
    for (input.object.get("assign").?.array.items) |entry| {
        const key = entry.object.get("name").?.string;
        const encoded = entry.object.get("json").?.string;
        if ((try seen.getOrPut(scratch, key)).found_existing) return error.DuplicateContextEdit;
        if (pool) |intern| {
            try intern.put(&result, retained, scratch, key, encoded);
        } else {
            try tree.text.validate(scratch, encoded);
            try result.object.put(retained, key, .{ .string = encoded });
        }
    }
    return result;
}

fn encode(a: Allocator, value: Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    tree.write(a, &output.writer, value) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return output.toOwnedSlice();
}

fn decode(a: Allocator, bytes: []const u8) !Value {
    return tree.text.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = bytes.len });
}
