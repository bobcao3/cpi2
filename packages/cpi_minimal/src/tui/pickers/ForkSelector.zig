const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const Controller = @import("../../session.zig").Controller;
const Palette = @import("../style.zig").Theme.Palette;
const Frame = @import("../UiPresentation.zig").Frame;
const Self = @This();
const Allocator = std.mem.Allocator;
const page_size = 10;

arena: std.heap.ArenaAllocator,
messages: []const Controller.ForkMessage,
selected: usize,

pub fn open(a: Allocator, controller: *Controller) !?Self {
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const messages = try controller.forkMessages(arena.allocator());
    if (messages.len != 0) return .{ .arena = arena, .messages = messages, .selected = messages.len - 1 };
    arena.deinit();
    return null;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn key(self: *Self, input: kit.terminal.keys.Key) enum { none, confirm, cancel } {
    if (input.mods.ctrl) return .none;
    return switch (tui.select_list.List.keySelection(&self.selected, self.messages.len, page_size, input)) {
        .activate => .confirm,
        .cancel => .cancel,
        .none, .highlight => .none,
    };
}

fn preview(a: Allocator, text: []const u8, width: u16) ![]const u8 {
    const flat = try a.dupe(u8, try @import("../transcript.zig").markdown.clean(a, text));
    for (flat) |*byte| if (byte.* == '\n' or byte.* == '\r') {
        byte.* = ' ';
    };
    const trimmed = @import("../../session.zig").SessionName.trimWhitespace(flat);
    const clipped = tui.layout.clipColumns(trimmed, width);
    if (clipped.len == trimmed.len or width == 0) return clipped;
    return std.fmt.allocPrint(a, "{s}…", .{tui.layout.clipColumns(trimmed, width - 1)});
}

pub fn draw(self: *const Self, a: Allocator, nodes: *std.ArrayList(tui.Node), width: u16, palette: *const Palette, frame: Frame) !void {
    try Frame.append(a, nodes, frame.before, width, palette);
    const start = @min(self.selected -| (page_size / 2), self.messages.len -| page_size);
    const end = @min(start + page_size, self.messages.len);
    for (self.messages[start..end], start..) |message, index| {
        const selected = index == self.selected;
        const text = try preview(a, message.text, width -| 2);
        const line = try a.dupe(tui.layout.Track, &.{
            .{ .node = palette.text(.accent, if (selected) "› " else "  "), .basis = .{ .cells = 2 } },
            .{ .node = .{ .text = .{ .bytes = text, .style = .{ .bold = selected } } } },
        });
        try nodes.append(a, .{ .axis = .{ .children = line } });
        try nodes.append(a, palette.text(.muted, try std.fmt.allocPrint(a, "  Message {d} of {d}", .{ index + 1, self.messages.len })));
        try nodes.append(a, .{ .spacer = 1 });
    }
    if (start > 0 or end < self.messages.len)
        try nodes.append(a, palette.text(.muted, try std.fmt.allocPrint(a, "  ({d}/{d})", .{ self.selected + 1, self.messages.len })));
    try Frame.append(a, nodes, frame.after, width, palette);
}
