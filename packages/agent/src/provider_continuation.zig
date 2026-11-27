const std = @import("std");
const j = @import("json.zig");
const SizeSink = @import("session_protocol").Transaction.SizeSink;
pub const Capsule = opaque {};
const Storage = struct { bytes: []const u8 };

pub fn capture(a: std.mem.Allocator, items: j.Value) !*const Capsule {
    return captureObserved(a, items, .{});
}

pub fn captureObserved(a: std.mem.Allocator, items: j.Value, warnings: SizeSink) !*const Capsule {
    if (items != .array) return error.InvalidContinuationMaterial;
    warnings.report("continuation items", items.array.items.len, 100000);
    for (items.array.items) |item| {
        const kind = j.text(j.get(item, "type"));
        if (!std.mem.eql(u8, kind, "message") and !std.mem.eql(u8, kind, "reasoning") and !std.mem.eql(u8, kind, "function_call") and !std.mem.eql(u8, kind, "function_call_output")) return error.UnsupportedContinuationItem;
        if (std.mem.eql(u8, kind, "function_call") and (j.get(item, "call_id") != .string or j.get(item, "name") != .string or j.get(item, "arguments") != .string)) return error.InvalidContinuationMaterial;
        if (std.mem.eql(u8, kind, "function_call_output") and (j.get(item, "call_id") != .string or j.get(item, "output") == .null)) return error.InvalidContinuationMaterial;
    }
    const bytes = try j.encode(a, items);
    errdefer a.free(bytes);
    warnings.report("continuation bytes", bytes.len, 32 * 1024 * 1024);
    const storage = try a.create(Storage);
    storage.* = .{ .bytes = bytes };
    return @ptrCast(storage);
}
pub fn material(capsule: *const Capsule) []const u8 {
    const storage: *const Storage = @ptrCast(@alignCast(capsule));
    return storage.bytes;
}
