const std = @import("std");
const json_text = @import("json_tree").text;
const walk = @import("json_walk.zig");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,
    value: Value,

    pub fn init(gpa: Allocator, bytes: []const u8) !Document {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const value = try parse(arena.allocator(), bytes);
        return .{ .arena = arena, .gpa = gpa, .value = value };
    }

    pub fn clone(self: *const Document, gpa: Allocator) !Document {
        return initValue(gpa, self.value);
    }

    pub fn initValue(gpa: Allocator, value: Value) !Document {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        return .{ .arena = arena, .gpa = gpa, .value = try copy(arena.allocator(), value) };
    }

    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn parse(a: Allocator, bytes: []const u8) !Value {
    return json_text.parseFromSliceLeaky(Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = bytes.len,
        .duplicate_field_behavior = .@"error",
    });
}

pub const validateText = json_text.validate;

pub fn encode(a: Allocator, value: anytype) ![]u8 {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const projected = try walk.fromAny(temporary.allocator(), value);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    walk.write(a, &output.writer, projected) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return output.toOwnedSlice();
}

pub fn sourceHash(source: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Borrowed projection for immediate use; use copy/initValue across lifetimes.
pub const project = walk.fromAny;
pub const projectOwned = @import("json_tree").fromOwned;
pub const copy = walk.copy;
pub const equal = walk.equal;

pub fn validate(a: Allocator, value: Value) !void {
    _ = try encodedLen(a, value);
}

pub fn encodedLen(a: Allocator, value: Value) !usize {
    var buffer: [256]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&buffer);
    try walk.write(a, &output.writer, value);
    return std.math.cast(usize, output.fullCount()) orelse error.Overflow;
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

pub fn integer(n: u64) Value {
    return .{ .integer = @intCast(n) };
}

pub fn put(a: Allocator, value: *Value, key: []const u8, item: Value) !void {
    if (value.* != .object) return error.ExpectedObject;
    try value.object.put(a, key, item);
}

pub fn get(value: Value, key: []const u8) Value {
    if (value != .object) return .null;
    return value.object.get(key) orelse .null;
}

pub fn ptr(value: *Value, key: []const u8) *Value {
    return value.object.getPtr(key).?;
}

pub fn text(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}

pub fn number(value: Value) u64 {
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else 0;
}

pub fn flag(value: Value) bool {
    return value == .bool and value.bool;
}

test "document clone owns structural state without a serialized intermediate" {
    const a = std.testing.allocator;
    var budget: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{};
    defer std.testing.expect(budget.deinit() == .ok) catch @panic("leak");
    budget.requested_memory_limit = 256 * 1024;
    var cloned = blk: {
        var original = try Document.init(a, "{\"items\":[1,3.5,null],\"large_number\":123456789012345678901234567890}");
        defer original.deinit();
        const payload = try original.allocator().alloc(u8, 128 * 1024);
        @memset(payload, 'x');
        try put(original.allocator(), &original.value, "payload", string(payload));
        break :blk try original.clone(budget.allocator());
    };
    defer cloned.deinit();
    try std.testing.expectEqual(@as(usize, 128 * 1024), text(get(cloned.value, "payload")).len);
    try std.testing.expectEqualStrings("123456789012345678901234567890", get(cloned.value, "large_number").number_string);
    try std.testing.expectEqual(@as(f64, 3.5), get(cloned.value, "items").array.items[1].float);
    try validate(a, cloned.value);
}

test "deep JSON owns and encodes nested values without recursive host walks" {
    const a = std.testing.allocator;
    const depth = 4096;
    const bytes = try a.alloc(u8, depth * 2 + 1);
    defer a.free(bytes);
    @memset(bytes[0..depth], '[');
    bytes[depth] = '0';
    @memset(bytes[depth + 1 ..], ']');
    var original = try Document.init(a, bytes);
    defer original.deinit();
    var cloned = try original.clone(a);
    defer cloned.deinit();
    try std.testing.expect(try equal(a, original.value, cloned.value));
    const encoded = try encode(a, cloned.value);
    defer a.free(encoded);
    try std.testing.expectEqualSlices(u8, bytes, encoded);
    try std.testing.expectEqual(bytes.len, try encodedLen(a, cloned.value));
}
