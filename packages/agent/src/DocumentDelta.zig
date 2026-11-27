//! Apply decoded Chord operation tuples to an immutable JSON value.
const std = @import("std");
const j = @import("json.zig");
const Value = j.Value;
const Allocator = std.mem.Allocator;
const invalid = error.InvalidDocumentPatch;

const Verb = enum { r, s, d, a, t, p, m };
const Ancestor = struct { container: Value, segment: Value };

/// Unchanged subtrees and inserted values borrow the inputs. The caller owns
/// the arena for changed containers and retains both inputs until publication.
pub fn apply(a: Allocator, initial: Value, operations: []const Value) !Value {
    var value = initial;
    var ancestry: std.ArrayList(Ancestor) = .empty;
    for (operations) |operation| {
        if (operation != .array or operation.array.items.len == 0) return invalid;
        const fields = operation.array.items;
        const verb = std.meta.stringToEnum(Verb, j.text(fields[0])) orelse return invalid;
        const arity: usize = switch (verb) {
            .r, .d => 2,
            .s, .a, .t, .m => 3,
            .p => 5,
        };
        if (fields.len != arity) return invalid;
        if (verb == .r) {
            value = fields[1];
            continue;
        }
        if (fields[1] != .array) return invalid;
        const path = fields[1].array.items;
        const edits_array = verb == .p or verb == .m;
        if (path.len == 0 and !edits_array) return invalid;
        const parent_path = if (edits_array) path else path[0 .. path.len - 1];
        ancestry.clearRetainingCapacity();
        var target = value;
        for (parent_path) |segment| {
            try ancestry.append(a, .{ .container = target, .segment = segment });
            target = (try child(a, target, segment)) orelse return invalid;
        }
        value = switch (verb) {
            .r => unreachable,
            .s => try replaceChild(a, target, path[path.len - 1], fields[2]),
            .d => try replaceChild(a, target, path[path.len - 1], null),
            .a, .t => blk: {
                const key = path[path.len - 1];
                const previous = (try child(a, target, key)) orelse return invalid;
                if (previous != .string) return invalid;
                const updated = if (verb == .a) append: {
                    if (fields[2] != .string) return invalid;
                    break :append try std.mem.concat(a, u8, &.{ previous.string, fields[2].string });
                } else try dropUtf16(previous.string, try index(fields[2]));
                break :blk try replaceChild(a, target, key, j.string(updated));
            },
            .p => blk: {
                if (target != .array or fields[4] != .array) return invalid;
                const at = @min(try index(fields[2]), target.array.items.len);
                const end = at + @min(try index(fields[3]), target.array.items.len - at);
                break :blk try splice(a, target.array.items, at, end, fields[4].array.items);
            },
            .m => try reorder(a, target, fields[2]),
        };
        while (ancestry.pop()) |ancestor| value = try replaceChild(a, ancestor.container, ancestor.segment, value);
    }
    return value;
}

fn index(value: Value) !usize {
    return switch (value) {
        .integer => std.math.cast(usize, value.integer) orelse invalid,
        .float => if (value.float >= 0 and value.float <= 9007199254740991 and @trunc(value.float) == value.float)
            std.math.cast(usize, @as(u64, @intFromFloat(value.float))) orelse invalid
        else
            invalid,
        else => invalid,
    };
}

fn objectKey(a: Allocator, segment: Value) ![]const u8 {
    if (segment != .string) return std.fmt.allocPrint(a, "{d}", .{try index(segment)});
    const text = segment.string;
    for ([_][]const u8{ "__proto__", "constructor", "prototype" }) |reserved| {
        if (std.mem.eql(u8, text, reserved)) return invalid;
    }
    return text;
}

fn child(a: Allocator, container: Value, segment: Value) !?Value {
    return switch (container) {
        .object => container.object.get(try objectKey(a, segment)),
        .array => blk: {
            const at = try index(segment);
            break :blk if (at < container.array.items.len) container.array.items[at] else null;
        },
        else => invalid,
    };
}

fn replaceChild(a: Allocator, container: Value, segment: Value, value: ?Value) !Value {
    switch (container) {
        .object => {
            const key = try objectKey(a, segment);
            if (value == null and !container.object.contains(key)) return container;
            var result: Value = .{ .object = try container.object.clone(a) };
            if (value) |item| try result.object.put(a, key, item) else _ = result.object.orderedRemove(key);
            return result;
        },
        .array => {
            const at = try index(segment);
            const items = container.array.items;
            if (at > items.len or (at == items.len and value == null)) return invalid;
            return splice(a, items, at, @min(at + 1, items.len), if (value) |item| &.{item} else &.{});
        },
        else => return invalid,
    }
}

fn splice(a: Allocator, items: []const Value, at: usize, end: usize, inserted: []const Value) !Value {
    const result = try std.mem.concat(a, Value, &.{ items[0..at], inserted, items[end..] });
    return .{ .array = std.json.Array.fromOwnedSlice(a, result) };
}

fn reorder(a: Allocator, value: Value, permutation: Value) !Value {
    if (value != .array or permutation != .array or value.array.items.len != permutation.array.items.len) return invalid;
    const items = value.array.items;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(a, items.len);
    defer seen.deinit(a);
    const reordered = try a.alloc(Value, items.len);
    for (permutation.array.items, reordered) |segment, *result| {
        const at = try index(segment);
        if (at >= items.len or seen.isSet(at)) return invalid;
        seen.set(at);
        result.* = items[at];
    }
    return .{ .array = std.json.Array.fromOwnedSlice(a, reordered) };
}

fn dropUtf16(text: []const u8, count: usize) ![]const u8 {
    const view = std.unicode.Utf8View.init(text) catch return invalid;
    var chars = view.iterator();
    var remaining = count;
    while (remaining != 0) {
        const bytes = chars.nextCodepointSlice() orelse return "";
        const width: usize = if (bytes.len == 4) 2 else 1;
        // An isolated surrogate has no representation in the journal's UTF-8.
        if (width > remaining) return invalid;
        remaining -= width;
    }
    return text[chars.i..];
}
