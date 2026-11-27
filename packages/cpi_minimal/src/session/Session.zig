const std = @import("std");
const j = @import("../json.zig");
const Self = @This();
const Value = j.Value;

path: ?[]const u8,
leaf: ?[]const u8 = null,

pub fn view(a: std.mem.Allocator, ctx: Value, path: ?[]const u8) !Self {
    if (ctx != .object) return error.InvalidSessionState;
    if (!ctx.object.contains("session")) return .{ .path = path };
    const graph = j.get(ctx, "session");
    if (graph != .object) return error.InvalidSessionState;
    for (graph.object.keys()) |key| {
        var known = false;
        inline for (.{ "revision", "next_id", "head", "config", "run", "context_tokens", "last_submission", "forked" }) |field| {
            if (std.mem.eql(u8, key, field)) known = true;
        }
        if (!known) return error.InvalidSessionState;
    }
    const revision = j.get(graph, "revision");
    const next_id = j.get(graph, "next_id");
    const head = j.get(graph, "head");
    if (revision != .integer or revision.integer < 0 or next_id != .integer or next_id.integer < 1 or
        (head != .null and (head != .string or head.string.len == 0))) return error.InvalidSessionState;
    const config = j.get(graph, "config");
    const run = j.get(graph, "run");
    const tokens = j.get(graph, "context_tokens");
    const last_submission = j.get(graph, "last_submission");
    const forked = j.get(graph, "forked");
    if (config != .object or (run != .null and run != .object) or
        tokens != .integer or tokens.integer < 0 or
        (last_submission != .null and last_submission != .string) or
        (forked != .null and !j.flag(forked))) return error.InvalidSessionState;
    return .{ .path = path, .leaf = if (head == .string) try a.dupe(u8, head.string) else null };
}
