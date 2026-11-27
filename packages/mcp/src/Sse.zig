//! Server-Sent Events decoding for MCP Streamable HTTP responses.
//!
//! MCP servers commonly answer with `text/event-stream`, even for one response.
//! A response may contain notifications, a server request, and the matching
//! response in any order. This decoder returns each event's data payload
//! separately; it never concatenates events.

const std = @import("std");
const SizeSink = @import("Transport.zig").SizeSink;
pub const Allocator = std.mem.Allocator;
pub const max_events = 1024;
pub const max_payload = 32 * 1024 * 1024;

/// Decode a complete SSE body. Payload slices are allocated from `a` and remain
/// valid for the lifetime of that allocator/arena.
pub fn decode(a: Allocator, body: []const u8) ![]const []const u8 {
    return decodeObserved(a, body, .{});
}

pub fn decodeObserved(a: Allocator, body: []const u8, size_warnings: SizeSink) ![]const []const u8 {
    var events: std.ArrayList([]const u8) = .empty;
    var data: std.ArrayList(u8) = .empty;
    var has_data = false;
    var index: usize = 0;
    while (index <= body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, index, '\n') orelse body.len;
        var line = body[index..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            if (has_data) {
                size_warnings.report("SSE payload bytes", data.items.len, max_payload);
                try events.append(a, try data.toOwnedSlice(a));
                data = .empty;
                has_data = false;
            }
        } else if (line[0] != ':') {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            const field = line[0..colon];
            var value = if (colon < line.len) line[colon + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (std.mem.eql(u8, field, "data")) {
                if (has_data) try data.append(a, '\n');
                try data.appendSlice(a, value);
                has_data = true;
            }
        }
        if (end == body.len) break;
        index = end + 1;
    }
    if (has_data) {
        size_warnings.report("SSE payload bytes", data.items.len, max_payload);
        try events.append(a, try data.toOwnedSlice(a));
    }
    size_warnings.report("SSE event count", events.items.len, max_events);
    return events.toOwnedSlice(a);
}

test "multiple events stay separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try decode(arena.allocator(), "event: message\r\ndata: {\"id\":1}\r\n\r\n" ++
        ": keepalive\n" ++
        "data: {\"method\":\"notifications/tools/list_changed\"}\n\n");
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("{\"id\":1}", events[0]);
    try std.testing.expectEqualStrings("{\"method\":\"notifications/tools/list_changed\"}", events[1]);
}

test "multi-line data is joined with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try decode(arena.allocator(), "data: {\"a\":\ndata: 1}\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("{\"a\":\n1}", events[0]);
}

test "unterminated final event is still returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try decode(arena.allocator(), "data: {}\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("{}", events[0]);
}
