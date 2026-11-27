const std = @import("std");
const kit = @import("kit");
const ComposerView = @import("../composer.zig").ComposerView;
const tui = kit.tui;
const Self = @This();
const Allocator = std.mem.Allocator;
const Direction = tui.TranscriptSearch.Direction;
const measure = kit.terminal.span_display_width.measure;

input: tui.Editor,
index: tui.TranscriptSearch,
bounds: ?tui.Buffer.Rect = null,
hovered: ?Direction = null,
hardware_cursor: bool = false,

pub fn init(a: Allocator) Self {
    return .{ .input = .initWithEditingHistory(a), .index = .init(a) };
}

pub fn deinit(self: *Self) void {
    self.input.deinit();
    self.index.deinit();
}

pub fn key(self: *Self, event: kit.terminal.keys.Key, top: u32) !void {
    if (event.mods.super or event.mods.meta or event.mods.hyper) return;
    const before = self.input.revision;
    if (!try self.input.editKey(event) and event.code == .char and !event.mods.alt and !event.mods.ctrl) {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(event.code.char, &bytes) catch return;
        try self.input.typeText(bytes[0..len]);
    }
    if (before != self.input.revision) try self.index.setQuery(self.input.text(), top);
}

pub fn paste(self: *Self, a: Allocator, text: []const u8, top: u32) !void {
    var line: std.ArrayList(u8) = .empty;
    for (text) |byte| switch (byte) {
        '\r', '\n' => {},
        '\t' => try line.appendSlice(a, "    "),
        else => try line.append(a, byte),
    };
    const before = self.input.revision;
    try self.input.insert(line.items);
    if (before != self.input.revision) try self.index.setQuery(self.input.text(), top);
}

pub fn overlay(self: *Self, columns: u16, rows: u16, hardware: bool) ?tui.layout.Overlay {
    self.bounds = null;
    self.hardware_cursor = hardware;
    if (columns <= 1 or rows <= 1) return null;
    const width: u16 = @min(@max(1, columns -| 2), @max(32, @as(u16, @intCast(@as(u32, columns) * 40 / 100))));
    const column = @max(1, columns -| width -| 1);
    const height = @min(rows - 1, 3);
    self.bounds = .{ .x = column, .y = 1, .width = width, .height = height };
    return .{ .node = .{ .custom = tui.Component.init(Self, self) }, .column = column, .row = 1, .width = width, .height = height };
}

pub fn mouse(self: *Self, event: kit.terminal.keys.Mouse) bool {
    const bounds = self.bounds orelse return false;
    const hit = bounds.contains(event.column, event.row);
    self.hovered = if (hit and event.row - bounds.y == 2)
        controls(bounds.width).directionAt(event.column - bounds.x)
    else
        null;
    if (event.kind == .scroll) return false;
    if (self.hovered) |direction| {
        if (event.kind == .press and event.button == .left) self.index.navigate(direction);
    }
    return hit;
}

pub fn build(self: *const Self, a: Allocator, width: u16) tui.layout.Error!tui.Node {
    const rows = try a.alloc(tui.Node, 3);
    if (width == 1) {
        rows[0] = lineNode("┌");
        rows[1] = lineNode("│");
        rows[2] = lineNode("└");
        return .{ .stack = .{ .children = rows } };
    }
    const inner = width - 2;
    const rule = try repeat(a, "─", inner);
    rows[0] = lineNode(try std.fmt.allocPrint(a, "┌{s}┐", .{rule}));
    const result = if (self.input.text().len == 0)
        ""
    else if (self.index.selected) |index|
        try std.fmt.allocPrint(a, "{d}/{d}", .{ index + 1, self.index.count() })
    else
        "No matches";
    const visible_result = tui.layout.clipColumns(result, inner -| 3);
    const input_width = inner - @as(u16, @intCast(if (visible_result.len == 0) 0 else visible_result.len + 2));
    const input_line = try self.inputLine(a, input_width);
    const padding = try repeat(a, " ", input_width -| measure(input_line.bytes));
    const counter = if (visible_result.len == 0) "" else try std.fmt.allocPrint(a, "\x1b[2m {s} \x1b[22m", .{visible_result});
    rows[1] = lineNode(try std.fmt.allocPrint(a, "│{s}{s}{s}│", .{ input_line.bytes, padding, counter }));
    if (input_line.cursor_column) |column| rows[1].text.cursor_column = column + 1;

    const buttons = controls(width);
    rows[2] = if (buttons.show) lineNode(try std.fmt.allocPrint(a, "└{s} {s}{s}{s} {s}┘", .{
        rule[0 .. buttons.left_rule * "─".len],
        try self.button(a, buttons.previous, .previous),
        buttons.separator,
        try self.button(a, buttons.next, .next),
        rule[0 .. buttons.right_rule * "─".len],
    })) else lineNode(try std.fmt.allocPrint(a, "└{s}┘", .{rule}));
    return .{ .stack = .{ .children = rows } };
}

fn button(self: *const Self, a: Allocator, text: []const u8, direction: Direction) ![]const u8 {
    if (self.hovered != direction) return text;
    return std.fmt.allocPrint(a, "\x1b[4m{s}\x1b[24m", .{text});
}

fn inputLine(self: *const Self, a: Allocator, width: u16) !tui.Text {
    if (width <= 1) return .{ .bytes = if (width == 0) "" else " " };
    const available = width - 1;
    const text = self.input.text();
    if (text.len == 0) {
        const placeholder = tui.layout.clipColumns("Find in transcript", available);
        return .{
            .bytes = if (self.hardware_cursor)
                try std.fmt.allocPrint(a, " \x1b[2m{s}\x1b[22m", .{placeholder})
            else
                try std.fmt.allocPrint(a, " \x1b[2;7m{s}\x1b[27m{s}\x1b[22m", .{ placeholder[0..1], placeholder[1..] }),
            .cursor_column = 1,
        };
    }
    return (try ComposerView.inputLine(a, &self.input, " ", width, self.hardware_cursor)).text;
}

const Controls = struct {
    previous: []const u8,
    separator: []const u8,
    next: []const u8,
    left_rule: usize,
    right_rule: usize,
    show: bool,

    fn directionAt(self: Controls, column: u32) ?Direction {
        if (!self.show) return null;
        const start = self.left_rule + 2;
        const end = start + measure(self.previous);
        const next = end + measure(self.separator);
        if (column >= start and column < end) return .previous;
        if (column >= next and column < next + measure(self.next)) return .next;
        return null;
    }
};

fn controls(width: u16) Controls {
    const inner = width -| 2;
    const available = inner -| 3;
    const labeled = available >= measure("↑ Shift+Enter · ↓ Enter");
    const previous = if (labeled) "↑ Shift+Enter" else "↑";
    const next = if (labeled) "↓ Enter" else "↓";
    const separator = if (labeled) " · " else " ";
    const size = measure(previous) + measure(separator) + measure(next);
    const show = size <= available;
    const right: usize = @intFromBool(show and inner > size + 2);
    return .{
        .previous = previous,
        .separator = separator,
        .next = next,
        .left_rule = if (show) inner - size - 2 - right else inner,
        .right_rule = right,
        .show = show,
    };
}

fn repeat(a: Allocator, glyph: []const u8, count: usize) ![]const u8 {
    const out = try a.alloc(u8, glyph.len * count);
    var i: usize = 0;
    while (i < out.len) : (i += glyph.len) @memcpy(out[i..][0..glyph.len], glyph);
    return out;
}

fn lineNode(bytes: []const u8) tui.Node {
    return .{ .text = .{ .bytes = bytes, .overflow = .clip } };
}
