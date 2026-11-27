const std = @import("std");
const json_text = @import("json_tree").text;
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;

pub fn get(input: Value, key: []const u8) Value {
    return if (input == .object) input.object.get(key) orelse .null else .null;
}

pub fn text(input: Value) []const u8 {
    return if (input == .string) input.string else "";
}

pub fn flag(input: Value) bool {
    return input == .bool and input.bool;
}

pub fn number(input: Value) u64 {
    return switch (input) {
        .integer => if (input.integer > 0) @intCast(input.integer) else 0,
        .float => if (input.float > 0 and input.float < @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(input.float) else 0,
        else => 0,
    };
}

pub fn items(input: Value) []const Value {
    return if (input == .array) input.array.items else &.{};
}

pub fn parse(a: Allocator, bytes: []const u8) !Value {
    return json_text.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
}

pub fn encode(a: Allocator, input: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, input, .{});
}

pub fn value(a: Allocator, input: anytype) !Value {
    return @import("json_tree").fromOwned(a, input);
}

pub fn array(a: Allocator) Value {
    return .{ .array = std.json.Array.init(a) };
}
pub fn object() Value {
    return .{ .object = .empty };
}
pub fn string(text_value: []const u8) Value {
    return .{ .string = text_value };
}
pub fn integer(number_value: i64) Value {
    return .{ .integer = number_value };
}

pub fn put(a: Allocator, target: *Value, key: []const u8, item: Value) !void {
    try target.object.put(a, try a.dupe(u8, key), item);
}

pub fn copy(a: Allocator, item: Value) !Value {
    return @import("json_tree").copy(a, item);
}

pub fn equal(a: Value, b: []const u8) bool {
    return a == .string and std.mem.eql(u8, a.string, b);
}

pub fn characters(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const size = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        count += if (size == 4) @as(usize, 2) else 1;
        i += @min(size, bytes.len - i);
    }
    return count;
}
