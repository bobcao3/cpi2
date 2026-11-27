const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub fn hash(a: Allocator, input: Value) ![64]u8 {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try write(a, &output.writer, input);
    try output.writer.flush();
    return std.fmt.bytesToHex(output.hasher.finalResult(), .lower);
}

pub fn encode(a: Allocator, input: Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    write(a, &output.writer, input) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return output.toOwnedSlice();
}

const Cursor = struct { value: Value, index: usize = 0, keys: ?[]usize = null, entered: bool = false };
pub fn write(a: Allocator, writer: *std.Io.Writer, input: Value) !void {
    var stack: std.ArrayList(Cursor) = .empty;
    defer {
        for (stack.items) |item| if (item.keys) |keys| a.free(keys);
        stack.deinit(a);
    }
    try stack.append(a, .{ .value = input });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            switch (frame.value) {
                .null => try writer.writeAll("null"),
                .bool => |n| try writer.writeAll(if (n) "true" else "false"),
                .integer => |n| try writer.print("{d}", .{n}),
                .float => |n| try number(writer, n),
                .number_string => return error.InvalidJsonNumber,
                .string => |s| {
                    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidJsonValue;
                    try std.json.Stringify.value(s, .{}, writer);
                },
                .array => try writer.writeByte('['),
                .object => |object| {
                    for (object.keys()) |key| if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidJsonValue;
                    const keys = try a.alloc(usize, object.count());
                    for (keys, 0..) |*key, i| key.* = i;
                    std.mem.sort(usize, keys, object.keys(), struct {
                        fn less(names: []const []const u8, x: usize, y: usize) bool {
                            return lessUtf16(names[x], names[y]);
                        }
                    }.less);
                    frame.keys = keys;
                    try writer.writeByte('{');
                },
            }
        }
        const count = switch (frame.value) {
            .array => |v| v.items.len,
            .object => |v| v.count(),
            else => 0,
        };
        if (frame.index == count) {
            switch (frame.value) {
                .array => try writer.writeByte(']'),
                .object => try writer.writeByte('}'),
                else => {},
            }
            if (frame.keys) |keys| a.free(keys);
            _ = stack.pop();
            continue;
        }
        if (frame.index != 0) try writer.writeByte(',');
        const child = switch (frame.value) {
            .array => |v| v.items[frame.index],
            .object => |v| blk: {
                const index = frame.keys.?[frame.index];
                try std.json.Stringify.value(v.keys()[index], .{}, writer);
                try writer.writeByte(':');
                break :blk v.values()[index];
            },
            else => unreachable,
        };
        frame.index += 1;
        try stack.append(a, .{ .value = child });
    }
}

fn number(writer: *std.Io.Writer, n: f64) !void {
    if (!std.math.isFinite(n)) return error.InvalidJsonNumber;
    if (n == 0) return writer.writeByte('0');
    var buffer: [347]u8 = undefined;
    const absolute = @abs(n);
    const bytes = try std.fmt.float.render(&buffer, n, .{ .mode = if (absolute >= 1e-6 and absolute < 1e21) .decimal else .scientific });
    if (std.mem.indexOfScalar(u8, bytes, 'e')) |index| {
        try writer.writeAll(bytes[0..index]);
        try writer.writeByte('e');
        const exponent = try std.fmt.parseInt(i16, bytes[index + 1 ..], 10);
        if (exponent >= 0) try writer.writeByte('+');
        try writer.print("{d}", .{exponent});
    } else try writer.writeAll(bytes);
}

const Units = struct {
    bytes: []const u8,
    index: usize = 0,
    low: ?u16 = null,
    fn next(self: *Units) ?u16 {
        if (self.low) |low| {
            self.low = null;
            return low;
        }
        if (self.index == self.bytes.len) return null;
        const count = std.unicode.utf8ByteSequenceLength(self.bytes[self.index]) catch unreachable;
        const point = std.unicode.utf8Decode(self.bytes[self.index..][0..count]) catch unreachable;
        self.index += count;
        if (point < 0x10000) return @intCast(point);
        const v = point - 0x10000;
        self.low = @intCast(0xdc00 + (v & 0x3ff));
        return @intCast(0xd800 + (v >> 10));
    }
};
fn lessUtf16(x: []const u8, y: []const u8) bool {
    var left: Units = .{ .bytes = x };
    var right: Units = .{ .bytes = y };
    while (left.next()) |l| {
        const r = right.next() orelse return false;
        if (l != r) return l < r;
    }
    return right.next() != null;
}

test "canonical JSON follows UTF-16 ordering and ECMAScript numeric thresholds" {
    const a = std.testing.allocator;
    var parsed = try @import("json_tree").text.parseFromSlice(Value, a, "{\"z\":-0.0,\"a\":[1.0,0.000001,1e-7,1e21]}", .{});
    defer parsed.deinit();
    const bytes = try encode(a, parsed.value);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{\"a\":[1,0.000001,1e-7,1e+21],\"z\":0}", bytes);
    try std.testing.expect(lessUtf16("\xf0\x9f\x98\x80", "\xee\x80\x80"));
}

test "canonical JSON rejects malformed UTF-8 keys and nested values" {
    const a = std.testing.allocator;
    const malformed = [_][]const u8{ "\xff", "\xe2\x82", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80" };
    for (malformed) |bytes| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var object: Value = .{ .object = .empty };
        try object.object.put(scratch, "valid", .null);
        try object.object.put(scratch, bytes, .null);
        try std.testing.expectError(error.InvalidJsonValue, encode(a, object));
        var nested: Value = .{ .array = .init(scratch) };
        try nested.array.append(.{ .string = bytes });
        try std.testing.expectError(error.InvalidJsonValue, encode(a, nested));
    }
    const valid = try encode(a, .{ .string = "é🙂" });
    defer a.free(valid);
    try std.testing.expectEqualStrings("\"é🙂\"", valid);
    var object: Value = .{ .object = .empty };
    defer object.object.deinit(a);
    try object.object.put(a, "é", .{ .string = "🙂" });
    const valid_object = try encode(a, object);
    defer a.free(valid_object);
    try std.testing.expectEqualStrings("{\"é\":\"🙂\"}", valid_object);
}
