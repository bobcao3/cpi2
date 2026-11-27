const std = @import("std");
const tree = @import("json_tree");
const F = @import("SessionFrame.zig");
const Value = F.Value;
const Allocator = std.mem.Allocator;
const Envelope = struct { v: u8, session_id: []const u8, seq: u64, tx: F.Transaction, class: F.Class, op: []const u8, actor: F.Actor, cause: ?u64, data: Value };
const Drop = struct { op: enum { drop }, ids: []const []const u8 };
const Insert = struct { op: enum { insert }, after: ?[]const u8, ids: []const []const u8 };

pub fn value(a: Allocator, input: anytype) !Value {
    return project(a, input, true);
}

fn project(a: Allocator, input: anytype, comptime owned: bool) !Value {
    const T = @TypeOf(input);
    if (T == Value) return if (owned) tree.copy(a, input) else input;
    if (T == F.Edit) return switch (input) {
        .drop => |ids| project(a, Drop{ .op = .drop, .ids = ids }, owned),
        .insert => |edit| project(a, Insert{ .op = .insert, .after = edit.after, .ids = edit.ids }, owned),
    };
    return switch (@typeInfo(T)) {
        .optional => if (input) |item| project(a, item, owned) else .null,
        .null => .null,
        .bool => .{ .bool = input },
        .int, .comptime_int => .{ .integer = std.math.cast(i64, input) orelse return error.InvalidNumber },
        .@"enum" => .{ .string = @tagName(input) },
        .pointer => |info| if (info.size == .slice) blk: {
            if (info.child == u8) break :blk .{ .string = if (owned) try a.dupe(u8, input) else input };
            var result: Value = .{ .array = .init(a) };
            try result.array.ensureTotalCapacity(input.len);
            for (input) |item| result.array.appendAssumeCapacity(try project(a, item, owned));
            break :blk result;
        } else if (info.size == .one and @typeInfo(info.child) == .array) blk: {
            const slice: []const @typeInfo(info.child).array.child = input;
            break :blk project(a, slice, owned);
        } else @compileError("unsupported journal value"),
        .array => |info| blk: {
            const slice: []const info.child = &input;
            break :blk project(a, slice, owned);
        },
        .@"struct" => |info| blk: {
            var result: Value = .{ .object = .empty };
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                const item = @field(input, name);
                const omitted = if (@typeInfo(Field) == .optional and attrs.default_value_ptr != null) item == null else false;
                if (!omitted) try result.object.put(a, name, try project(a, item, owned));
            }
            break :blk result;
        },
        else => @compileError("unsupported journal value"),
    };
}

pub fn transaction(a: Allocator, session: []const u8, id: []const u8, first: u64, actor: F.Actor, actions: []const F.Action) ![]u8 {
    if (actions.len == 0) return error.EmptyTransaction;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    for (actions, 0..) |action, index| {
        const data = switch (action) {
            inline else => |payload| try project(a, payload, false),
        };
        const envelope = try project(a, Envelope{
            .v = @as(u8, 1),
            .session_id = session,
            .seq = first + index,
            .tx = F.Transaction{ .id = id, .index = index, .count = actions.len },
            .class = action.class(),
            .op = @tagName(action),
            .actor = actor,
            .cause = @as(?u64, null),
            .data = data,
        }, false);
        tree.write(a, &output.writer, envelope) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        output.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return output.toOwnedSlice();
}
