//! The C traversal calls this sink only inside its protected Lua frame. This
//! callback never invokes Lua or unwinds across C; errors return to C first.
const std = @import("std");
const c = @import("registry_bridge");
const Self = @This();
const Value = std.json.Value;
const Frame = struct { value: Value, key: ?[]const u8 = null };

a: std.mem.Allocator,
frames: std.ArrayList(Frame) = .empty,
depth: usize = 0,
result: Value = .null,
failure: ?anyerror = null,

pub fn emit(raw: ?*anyopaque, event: c_int, bytes: [*c]const u8, length: usize, number: f64) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    self.accept(event, if (length == 0) "" else bytes[0..length], number) catch |err| {
        self.failure = err;
        return if (err == error.OutOfMemory) 1 else 6;
    };
    return 0;
}

fn accept(self: *Self, event: c_int, bytes: []const u8, number: f64) !void {
    switch (event) {
        c.CPI_OBJECT, c.CPI_ARRAY => {
            try self.frames.append(self.a, .{ .value = if (event == c.CPI_OBJECT) .{ .object = .empty } else .{ .array = .init(self.a) } });
            self.depth = @max(self.depth, self.frames.items.len);
        },
        c.CPI_END => {
            const frame = self.frames.pop().?;
            try self.add(frame.value);
        },
        c.CPI_KEY => {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRegistryShape;
            self.frames.items[self.frames.items.len - 1].key = try self.a.dupe(u8, bytes);
        },
        c.CPI_STRING => {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRegistryShape;
            try self.add(.{ .string = try self.a.dupe(u8, bytes) });
        },
        c.CPI_NUMBER => try self.add(if (@trunc(number) == number and number >= -9223372036854775808.0 and number < 9223372036854775808.0) .{ .integer = @intFromFloat(number) } else .{ .float = number }),
        c.CPI_BOOL => try self.add(.{ .bool = number != 0 }),
        c.CPI_NULL => try self.add(.null),
        else => unreachable,
    }
}

fn add(self: *Self, value: Value) !void {
    if (self.frames.items.len == 0) {
        self.result = value;
        return;
    }
    const parent = &self.frames.items[self.frames.items.len - 1];
    switch (parent.value) {
        .array => try parent.value.array.append(value),
        .object => {
            try parent.value.object.put(self.a, parent.key.?, value);
            parent.key = null;
        },
        else => unreachable,
    }
}
