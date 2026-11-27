const std = @import("std");
const tree = @import("json_tree");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
pub const expected_depth = 64;
pub const depth = tree.depth;
pub const write = tree.write;

pub fn parse(a: Allocator, bytes: []const u8) !Value {
    return tree.text.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}

pub fn encode(a: Allocator, item: anytype) ![]u8 {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const projected = try tree.fromAny(temporary.allocator(), item);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try tree.write(a, &out.writer, projected);
    return out.toOwnedSlice();
}

pub fn value(a: Allocator, item: anytype) !Value {
    const result = try tree.fromOwned(a, item);
    try tree.validate(a, result, null);
    return result;
}

pub const copy = tree.copy;

pub fn get(v: Value, name: []const u8) Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

pub fn text(v: Value) ![]const u8 {
    if (v != .string or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidArguments;
    return v.string;
}

pub fn string(v: Value, name: []const u8, default: []const u8) ![]const u8 {
    const item = get(v, name);
    return if (item == .null) default else text(item);
}

pub fn integer(v: Value, name: []const u8, default: u64, minimum: u64, maximum: u64) !u64 {
    const item = get(v, name);
    if (item == .null) return default;
    if (item != .integer or item.integer < 0) return error.InvalidArguments;
    const n: u64 = @intCast(item.integer);
    if (n < minimum or n > maximum) return error.InvalidArguments;
    return n;
}

pub fn boolean(v: Value, name: []const u8, default: bool) !bool {
    const item = get(v, name);
    if (item == .null) return default;
    if (item != .bool) return error.InvalidArguments;
    return item.bool;
}

pub fn put(a: Allocator, v: *Value, name: []const u8, item: Value) !void {
    try v.object.put(a, name, item);
}

pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
