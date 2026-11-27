//! Structural JSON operations and the tokenizer for wire and persistence boundaries.
const std = @import("std");
pub const text = @import("text.zig");
test {
    _ = @import("tests.zig");
}
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const CopyFrame = struct { source: Value, target: *Value, index: usize = 0, entered: bool = false };

pub fn copy(a: Allocator, value: Value) Allocator.Error!Value {
    var result: Value = .null;
    var frames: std.ArrayList(CopyFrame) = .empty;
    defer frames.deinit(a);
    try frames.append(a, .{ .source = value, .target = &result });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            switch (frame.source) {
                .null, .bool, .integer, .float => frame.target.* = frame.source,
                .string => |bytes| frame.target.* = .{ .string = try a.dupe(u8, bytes) },
                .number_string => |bytes| frame.target.* = .{ .number_string = try a.dupe(u8, bytes) },
                .array => |items| {
                    var out: Value = .{ .array = .init(a) };
                    try out.array.appendNTimes(.null, items.items.len);
                    frame.target.* = out;
                },
                .object => |fields| {
                    var out: Value = .{ .object = .empty };
                    try out.object.ensureTotalCapacity(a, fields.count());
                    for (fields.keys()) |key| try out.object.putNoClobber(a, try a.dupe(u8, key), .null);
                    frame.target.* = out;
                },
            }
        }
        const child: ?CopyFrame = switch (frame.source) {
            .array => |items| if (frame.index < items.items.len) .{ .source = items.items[frame.index], .target = &frame.target.array.items[frame.index] } else null,
            .object => |fields| if (frame.index < fields.count()) .{ .source = fields.values()[frame.index], .target = &frame.target.object.values()[frame.index] } else null,
            else => null,
        };
        if (child) |next| {
            frame.index += 1;
            try frames.append(a, next);
        } else _ = frames.pop();
    }
    return result;
}

const Pair = struct { left: Value, right: Value, index: usize = 0, entered: bool = false };

/// Groups equal blocks before reducing, for large source and serialized document comparisons.
pub fn equalBytes(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (left.ptr == right.ptr) return true;
    const width = std.simd.suggestVectorLength(u8) orelse return std.mem.eql(u8, left, right);
    const Block = @Vector(width, u8);
    const zero: Block = @splat(0);
    var offset: usize = 0;
    while (left.len - offset >= 4 * width) : (offset += 4 * width) {
        var difference = zero;
        inline for (0..4) |lane| {
            const at = offset + lane * width;
            difference |= @as(Block, left[at..][0..width].*) ^ @as(Block, right[at..][0..width].*);
        }
        if (@reduce(.Or, difference != zero)) return false;
    }
    return std.mem.eql(u8, left[offset..], right[offset..]);
}

pub fn equal(a: Allocator, left: Value, right: Value) Allocator.Error!bool {
    var frames: std.ArrayList(Pair) = .empty;
    defer frames.deinit(a);
    try frames.append(a, .{ .left = left, .right = right });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            if (std.meta.activeTag(frame.left) != std.meta.activeTag(frame.right)) return false;
            const same = switch (frame.left) {
                .null => true,
                .bool => frame.left.bool == frame.right.bool,
                .integer => frame.left.integer == frame.right.integer,
                .float => frame.left.float == frame.right.float,
                .string => equalBytes(frame.left.string, frame.right.string),
                .number_string => std.mem.eql(u8, frame.left.number_string, frame.right.number_string),
                .array => frame.left.array.items.len == frame.right.array.items.len,
                .object => frame.left.object.count() == frame.right.object.count(),
            };
            if (!same) return false;
        }
        const child: ?Pair = switch (frame.left) {
            .array => |items| if (frame.index < items.items.len) .{ .left = items.items[frame.index], .right = frame.right.array.items[frame.index] } else null,
            .object => |fields| if (frame.index < fields.count()) .{ .left = fields.values()[frame.index], .right = frame.right.object.get(fields.keys()[frame.index]) orelse return false } else null,
            else => null,
        };
        if (child) |next| {
            frame.index += 1;
            try frames.append(a, next);
        } else _ = frames.pop();
    }
    return true;
}

const WriteFrame = struct { value: Value, index: usize = 0, entered: bool = false };

// Scan long plain runs a block at a time. Delegate the escaping itself to std.json.
fn writeString(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len < 32) return std.json.Stringify.encodeJsonString(bytes, .{}, writer);
    try writer.writeByte('"');
    const Block = @Vector(32, u8);
    var start: usize = 0;
    var i: usize = 0;
    while (bytes.len - i >= 32) : (i += 32) {
        const block: Block = bytes[i..][0..32].*;
        var mask = @as(u32, @bitCast(block < @as(Block, @splat(32)))) |
            @as(u32, @bitCast(block == @as(Block, @splat('"')))) |
            @as(u32, @bitCast(block == @as(Block, @splat('\\'))));
        if (comptime @import("builtin").cpu.arch.endian() == .big) mask = @bitReverse(mask);
        while (mask != 0) : (mask &= mask - 1) {
            const at = i + @ctz(mask);
            try writer.writeAll(bytes[start..at]);
            try std.json.Stringify.encodeJsonStringChars(bytes[at..][0..1], .{}, writer);
            start = at + 1;
        }
    }
    try writer.writeAll(bytes[start..i]);
    try std.json.Stringify.encodeJsonStringChars(bytes[i..], .{}, writer);
    try writer.writeByte('"');
}

pub fn write(a: Allocator, writer: *std.Io.Writer, value: Value) !void {
    var frames: std.ArrayList(WriteFrame) = .empty;
    defer frames.deinit(a);
    try frames.append(a, .{ .value = value });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            switch (frame.value) {
                .null => try writer.writeAll("null"),
                .bool => |n| try std.json.Stringify.value(n, .{}, writer),
                .integer => |n| try std.json.Stringify.value(n, .{}, writer),
                .float => |n| {
                    if (!std.math.isFinite(n)) return error.InvalidJsonValue;
                    try std.json.Stringify.value(n, .{}, writer);
                },
                .string => |bytes| {
                    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJsonValue;
                    try writeString(writer, bytes);
                },
                .number_string => |bytes| {
                    if (!validNumber(bytes) or Value.parseFromNumberSlice(bytes) != .number_string) return error.InvalidJsonValue;
                    try writer.writeAll(bytes);
                },
                .array => try writer.writeByte('['),
                .object => try writer.writeByte('{'),
            }
        }
        const count = switch (frame.value) {
            .array => |items| items.items.len,
            .object => |fields| fields.count(),
            else => 0,
        };
        if (frame.index == count) {
            switch (frame.value) {
                .array => try writer.writeByte(']'),
                .object => try writer.writeByte('}'),
                else => {},
            }
            _ = frames.pop();
            continue;
        }
        if (frame.index != 0) try writer.writeByte(',');
        const child = switch (frame.value) {
            .array => |items| items.items[frame.index],
            .object => |fields| blk: {
                const key = fields.keys()[frame.index];
                if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidJsonValue;
                try writeString(writer, key);
                try writer.writeByte(':');
                break :blk fields.values()[frame.index];
            },
            else => unreachable,
        };
        frame.index += 1;
        try frames.append(a, .{ .value = child });
    }
}

/// Projection for an immediate encode. Strings and existing trees are borrowed.
pub fn fromAny(a: Allocator, input: anytype) anyerror!Value {
    return project(a, input, false);
}

/// Independently owned structural projection. The caller supplies an arena.
/// No text encoding, parsing, or normalization takes place.
pub fn fromOwned(a: Allocator, input: anytype) anyerror!Value {
    return project(a, input, true);
}

fn project(a: Allocator, input: anytype, comptime owned: bool) anyerror!Value {
    const T = @TypeOf(input);
    if (T == Value) return if (owned) copy(a, input) else input;
    return switch (@typeInfo(T)) {
        .null => .null,
        .bool => .{ .bool = input },
        .int, .comptime_int => if (std.math.cast(i64, input)) |n| .{ .integer = n } else .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{input}) },
        .float, .comptime_float => .{ .float = @floatCast(input) },
        .enum_literal, .@"enum" => .{ .string = @tagName(input) },
        .error_set => .{ .string = @errorName(input) },
        .optional => if (input) |payload| try project(a, payload, owned) else .null,
        .array => blk: {
            if (std.meta.Elem(T) == u8) break :blk .{ .string = try a.dupe(u8, &input) };
            var out: Value = .{ .array = .init(a) };
            for (input) |item| try out.array.append(try project(a, item, owned));
            break :blk out;
        },
        .vector => |info| blk: {
            const items: [info.len]info.child = input;
            break :blk try project(a, items, owned);
        },
        .pointer => |info| switch (info.size) {
            .one => if (@typeInfo(info.child) == .array) try project(a, @as([]const std.meta.Elem(info.child), input), owned) else try project(a, input.*, owned),
            .slice, .many => blk: {
                const items = if (info.size == .many) std.mem.span(input) else input;
                if (info.child == u8) break :blk .{ .string = if (owned) try a.dupe(u8, items) else items };
                var out: Value = .{ .array = .init(a) };
                for (items) |item| try out.array.append(try project(a, item, owned));
                break :blk out;
            },
            else => @compileError("unsupported JSON pointer " ++ @typeName(T)),
        },
        .@"struct" => |info| blk: {
            if (@hasDecl(T, "jsonStringify")) @compileError("provide a structural projection instead of jsonStringify for " ++ @typeName(T));
            var out: Value = if (info.is_tuple) .{ .array = .init(a) } else .{ .object = .empty };
            if (info.is_tuple) {
                try out.array.ensureTotalCapacity(info.field_names.len);
            } else {
                try out.object.ensureTotalCapacity(a, info.field_names.len);
            }
            inline for (info.field_names, info.field_types) |name, Field| {
                if (Field == void) continue;
                const child = try project(a, @field(input, name), owned);
                if (info.is_tuple) try out.array.append(child) else try out.object.put(a, name, child);
            }
            break :blk out;
        },
        .@"union" => |info| blk: {
            var out: Value = .{ .object = .empty };
            inline for (info.field_names, info.field_types) |name, Field| {
                if (input == @field(info.tag_type.?, name)) {
                    try out.object.put(a, name, if (Field == void) .{ .object = .empty } else try project(a, @field(input, name), owned));
                    break;
                }
            }
            break :blk out;
        },
        else => @compileError("unsupported JSON type " ++ @typeName(T)),
    };
}

/// Validate the in-memory tree without rendering it. Container depth is bounded
/// for wire adapters; null disables the bound for trusted internal state.
pub fn validate(a: Allocator, input: Value, max_depth: ?usize) !void {
    _ = try validateDepth(a, input, max_depth);
}

/// Validate the tree and report its deepest container, including the root.
pub fn depth(a: Allocator, input: Value) !usize {
    return validateDepth(a, input, null);
}

fn validateDepth(a: Allocator, input: Value, max_depth: ?usize) !usize {
    var deepest: usize = 0;
    var frames: std.ArrayList(WriteFrame) = .empty;
    defer frames.deinit(a);
    try frames.append(a, .{ .value = input });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (!frame.entered) {
            frame.entered = true;
            switch (frame.value) {
                .float => |n| if (!std.math.isFinite(n)) return error.InvalidJsonValue,
                .string => |bytes| if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJsonValue,
                .number_string => |bytes| if (!validNumber(bytes)) return error.InvalidJsonValue,
                .array, .object => {
                    deepest = @max(deepest, frames.items.len);
                    if (max_depth) |limit| if (frames.items.len > limit) return error.JsonTooDeep;
                    if (frame.value == .object) for (frame.value.object.keys()) |key| {
                        if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidJsonValue;
                    };
                },
                else => {},
            }
        }
        const child: ?Value = switch (frame.value) {
            .array => |items| if (frame.index < items.items.len) items.items[frame.index] else null,
            .object => |fields| if (frame.index < fields.count()) fields.values()[frame.index] else null,
            else => null,
        };
        if (child) |next| {
            frame.index += 1;
            try frames.append(a, .{ .value = next });
        } else _ = frames.pop();
    }
    return deepest;
}

fn validNumber(bytes: []const u8) bool {
    var i: usize = 0;
    if (i < bytes.len and bytes[i] == '-') i += 1;
    if (i == bytes.len) return false;
    if (bytes[i] == '0') {
        i += 1;
    } else {
        if (bytes[i] < '1' or bytes[i] > '9') return false;
        while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {}
    }
    if (i < bytes.len and bytes[i] == '.') {
        i += 1;
        const start = i;
        while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {}
        if (i == start) return false;
    }
    if (i < bytes.len and (bytes[i] == 'e' or bytes[i] == 'E')) {
        i += 1;
        if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) i += 1;
        const start = i;
        while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {}
        if (i == start) return false;
    }
    return i == bytes.len;
}
