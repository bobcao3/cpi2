//! Small JSON helpers shared by the MCP protocol implementation.
//!
//! Values are ordinary `std.json.Value` trees. Every function that parses or
//! copies a value allocates from the caller's allocator; ownership follows the
//! allocator. The MCP package never retains a parsed request/response value.

const std = @import("std");
const tree = @import("json_tree");
const SizeSink = @import("Transport.zig").SizeSink;
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
pub const expected_depth = 64;

pub fn parse(a: Allocator, bytes: []const u8) !Value {
    return parseObserved(a, bytes, .{});
}

pub fn parseObserved(a: Allocator, bytes: []const u8, warnings: SizeSink) !Value {
    const value_ = try tree.text.parseFromSliceLeaky(Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    warnings.report("JSON nesting depth", try tree.depth(a, value_), expected_depth);
    return value_;
}

pub fn encode(a: Allocator, item: anytype) ![]u8 {
    return encodeObserved(a, item, .{});
}

pub fn encodeObserved(a: Allocator, item: anytype, warnings: SizeSink) ![]u8 {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const value_ = try tree.fromAny(temporary.allocator(), item);
    warnings.report("JSON nesting depth", try tree.depth(a, value_), expected_depth);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try tree.write(a, &out.writer, value_);
    return out.toOwnedSlice();
}

pub fn value(a: Allocator, item: anytype) !Value {
    const result = try tree.fromOwned(a, item);
    try tree.validate(a, result, null);
    return result;
}

pub fn get(v: Value, name: []const u8) Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

pub fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}

pub fn number(v: Value) u64 {
    return switch (v) {
        .integer => if (v.integer > 0) @intCast(v.integer) else 0,
        .float => if (v.float > 0 and v.float < @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(v.float) else 0,
        else => 0,
    };
}

pub fn items(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}

pub fn object() Value {
    return .{ .object = .empty };
}

pub fn array(a: Allocator) Value {
    return .{ .array = std.json.Array.init(a) };
}

pub fn string(bytes: []const u8) Value {
    return .{ .string = bytes };
}

pub fn integer(value_: i64) Value {
    return .{ .integer = value_ };
}

pub fn boolean(value_: bool) Value {
    return .{ .bool = value_ };
}

pub fn put(a: Allocator, target: *Value, key: []const u8, item: Value) !void {
    try target.object.put(a, try a.dupe(u8, key), item);
}

pub fn copy(a: Allocator, item: Value) !Value {
    try tree.validate(a, item, null);
    return tree.copy(a, item);
}

pub fn equal(a: Value, b: []const u8) bool {
    return a == .string and std.mem.eql(u8, a.string, b);
}

test "duplicate object keys are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.DuplicateField, parse(arena.allocator(), "{\"a\":1,\"a\":2}"));
    const distinct = try parse(arena.allocator(), "{\"a\":1,\"b\":2}");
    try std.testing.expectEqual(@as(i64, 1), get(distinct, "a").integer);
    try std.testing.expectEqual(@as(i64, 2), get(distinct, "b").integer);
}
