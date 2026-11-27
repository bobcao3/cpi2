const std = @import("std");
const Value = std.json.Value;

pub fn encode(a: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(a, &out, value, 0);
    return out.toOwnedSlice(a);
}

fn quoted(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try out.append(a, '\\');
                try out.append(a, byte);
            },
            0...31, 127 => try out.appendSlice(a, try std.fmt.allocPrint(a, "\\{d:0>3}", .{byte})),
            else => try out.append(a, byte),
        }
    }
    try out.append(a, '"');
}

fn append(a: std.mem.Allocator, out: *std.ArrayList(u8), value: Value, depth: usize) !void {
    if (depth > 48) return error.ValueTooDeep;
    switch (value) {
        .null => try out.appendSlice(a, "nil"),
        .bool => |v| try out.appendSlice(a, if (v) "true" else "false"),
        .integer => |v| try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{v})),
        .float => |v| {
            if (!std.math.isFinite(v)) return error.InvalidNumber;
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{v}));
        },
        .number_string => |v| try out.appendSlice(a, v),
        .string => |v| try quoted(a, out, v),
        .array => |v| {
            try out.append(a, '{');
            for (v.items) |item| {
                try append(a, out, item, depth + 1);
                try out.append(a, ',');
            }
            try out.append(a, '}');
        },
        .object => |v| {
            try out.append(a, '{');
            var iterator = v.iterator();
            while (iterator.next()) |entry| {
                try out.append(a, '[');
                try quoted(a, out, entry.key_ptr.*);
                try out.appendSlice(a, "]=");
                try append(a, out, entry.value_ptr.*, depth + 1);
                try out.append(a, ',');
            }
            try out.append(a, '}');
        },
    }
}
