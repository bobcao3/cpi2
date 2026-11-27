const std = @import("std");
const json_text = protocol.json.text;
const protocol = @import("session_protocol");
const Terminus = @import("terminus_context_journal");
const Value = protocol.frames.Value;
const a = std.testing.allocator;

fn parse(allocator: std.mem.Allocator, text: []const u8) !Value {
    return json_text.parseFromSliceLeaky(Value, allocator, text, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
}

fn encodeChange(gpa: std.mem.Allocator, comptime Codec: type, sequence: u64, head: u64, change: Value) ![]u8 {
    const transaction_id = try std.fmt.allocPrint(gpa, "ctx-{d}", .{sequence});
    defer gpa.free(transaction_id);
    const encoded = try std.json.Stringify.valueAlloc(gpa, .{
        .v = @as(u8, 1),
        .session_id = "ctx-test",
        .seq = sequence,
        .tx = .{ .id = transaction_id, .index = @as(u64, 0), .count = @as(u64, 1) },
        .class = "control",
        .op = "control.extension",
        .actor = .{ .kind = "host", .id = "harness" },
        .cause = @as(?u64, null),
        .data = .{
            .namespace = Codec.namespace,
            .expected_head = head,
            .action = Codec.action,
            .input = .{ .contract = Codec.contract.version, .value = change },
        },
    }, .{});
    defer gpa.free(encoded);
    return std.fmt.allocPrint(gpa, "{s}\n", .{encoded});
}

fn applyChange(gpa: std.mem.Allocator, comptime Codec: type, store: *protocol.Extensions, change: Value) !void {
    const head = if (store.get(Codec.namespace)) |entry| entry.head else 0;
    const encoded = try encodeChange(gpa, Codec, store.sequence + 1, head, change);
    defer gpa.free(encoded);
    var transaction = try protocol.Transaction.parse(gpa, "ctx-test", store.sequence + 1, encoded, .{});
    defer transaction.deinit();
    const candidate = try store.prepare(&transaction, &.{Terminus.contract});
    store.deinit();
    store.* = candidate;
}

fn ctxRoundTrip(comptime Codec: type, gpa: std.mem.Allocator) !void {
    var inputs: std.heap.ArenaAllocator = .init(gpa);
    defer inputs.deinit();
    const input = inputs.allocator();
    const before = try parse(input, "{}");
    const after = try parse(input, "{\"nested\":{\"items\":[1]},\"erase_me\":true}");
    var store = try protocol.Extensions.init(gpa, "ctx-test");
    defer store.deinit();
    const first = (try Codec.capture(input, before, after)).?;
    try applyChange(gpa, Codec, &store, first);
    const restored = try Codec.materialize(input, store.get(Codec.namespace).?.value);
    try std.testing.expect(try protocol.json.equal(input, after, restored));
    var mutated = try protocol.json.copy(input, restored);
    const nested = mutated.object.getPtr("nested").?;
    try nested.object.getPtr("items").?.array.append(.{ .integer = 2 });
    try mutated.object.put(input, "assigned", .{ .string = "new value" });
    _ = mutated.object.orderedRemove("erase_me");
    const second = (try Codec.capture(input, restored, mutated)).?;
    try applyChange(gpa, Codec, &store, second);
    const replayed = try Codec.materialize(input, store.get(Codec.namespace).?.value);
    try std.testing.expect(try protocol.json.equal(input, mutated, replayed));
    try std.testing.expect((try Codec.capture(input, replayed, replayed)) == null);
    try std.testing.expectEqual(@as(u64, 2), store.sequence);
    try std.testing.expectEqual(@as(u64, 2), store.get(Codec.namespace).?.head);
}

test "Terminus ctx assignments and nested mutations round-trip through native journal frames" {
    try ctxRoundTrip(Terminus, a);
}
