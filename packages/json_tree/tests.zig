const std = @import("std");
const tree = @import("root.zig");
const Value = std.json.Value;

test "owned projections survive source teardown and preserve JSON kinds" {
    var target = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target.deinit();
    const a = target.allocator();
    const result = blk: {
        var source = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source.deinit();
        const s = source.allocator();
        var nested: Value = .{ .object = .empty };
        for (0..100) |index| try nested.object.put(s, try std.fmt.allocPrint(s, "key-{d}", .{index}), .{ .string = try s.dupe(u8, "owned") });
        const data: Value = .{ .number_string = try s.dupe(u8, "123456789012345678901234567890") };
        break :blk try tree.fromOwned(a, .{ .name = try s.dupe(u8, "source"), .nested = nested, .number = data, .items = .{ true, @as(?u32, null), @as(i64, -5), @as(f64, 1.5) }, .tag = .ready });
    };
    try std.testing.expectEqualStrings("source", result.object.get("name").?.string);
    try std.testing.expectEqualStrings("owned", result.object.get("nested").?.object.get("key-99").?.string);
    try std.testing.expectEqualStrings("123456789012345678901234567890", result.object.get("number").?.number_string);
    try std.testing.expectEqualStrings("ready", result.object.get("tag").?.string);
    const items = result.object.get("items").?.array.items;
    try std.testing.expect(items[0].bool and items[1] == .null);
    try std.testing.expectEqual(@as(i64, -5), items[2].integer);
    try std.testing.expectEqual(@as(f64, 1.5), items[3].float);
    try tree.validate(a, result, 64);
}

test "copy needs space for owned bytes, not an escaped serialized intermediate" {
    const source = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(source);
    @memset(source, 1); // JSON text would need six bytes per source byte.
    var budget: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .{};
    defer std.testing.expect(budget.deinit() == .ok) catch @panic("leak");
    budget.requested_memory_limit = 256 * 1024;
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    const result = try tree.fromOwned(arena.allocator(), Value{ .string = source });
    @memset(source, 2);
    try std.testing.expectEqual(@as(u8, 1), result.string[0]);
    try std.testing.expectEqual(@as(usize, 128 * 1024), result.string.len);
}

test "structural copy and validation handle 4096 nested arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var input: Value = .null;
    for (0..4096) |_| {
        var parent: Value = .{ .array = .init(a) };
        try parent.array.append(input);
        input = parent;
    }
    const result = try tree.copy(a, input);
    try std.testing.expect(try tree.equal(a, input, result));
    try tree.validate(a, result, null);
    try std.testing.expectError(error.JsonTooDeep, tree.validate(a, result, 64));
}

test "structural validation checks scalars and exact container depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidJsonValue, tree.validate(a, .{ .float = std.math.inf(f64) }, null));
    try std.testing.expectError(error.InvalidJsonValue, tree.validate(a, .{ .string = "\xff" }, null));
    try std.testing.expectError(error.InvalidJsonValue, tree.validate(a, .{ .number_string = "01" }, null));
    var array: Value = .{ .array = .init(a) };
    try array.array.append(.null);
    try tree.validate(a, array, 1);
    try std.testing.expectError(error.JsonTooDeep, tree.validate(a, array, 0));
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try tree.fromOwned(arena.allocator(), .{ .name = "allocation", .items = .{ 1, 2, 3 }, .nested = .{ .value = "payload" } });
}

test "partial structural projections propagate allocation failure from a caller-owned arena" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
