const std = @import("std");
const j = @import("../json.zig");
const Allocator = std.mem.Allocator;

pub fn textContent(a: Allocator, content: j.Value) ![]const u8 {
    if (content == .string) return content.string;
    var out: std.ArrayList(u8) = .empty;
    for (j.items(content)) |block| {
        const text = j.get(block, "text");
        if (text == .string) try out.appendSlice(a, text.string);
    }
    return out.items;
}

pub fn assistantText(a: Allocator, output: j.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (j.items(output)) |item| if (j.equal(j.get(item, "type"), "message")) {
        try out.appendSlice(a, try textContent(a, j.get(item, "content")));
    };
    return out.items;
}
