const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const Editor = tui.Editor;
const md = @import("../transcript.zig").markdown;
const Allocator = std.mem.Allocator;
const measure = kit.terminal.span_display_width.measure;
const glyph = "─";
const reset = "\x1b[0m";

pub const Status = struct {
    spinner: []const u8,
    message: []const u8,
    spinner_style: tui.Style,
    message_style: tui.Style,
};

fn borderLine(bytes: []const u8, color: tui.Style) tui.Node {
    return .{ .text = .{ .bytes = bytes, .style = color, .overflow = .clip } };
}

fn scrollBorder(a: Allocator, rule: []const u8, direction: []const u8, hidden: usize, color: tui.Style) !tui.Node {
    if (hidden == 0) return borderLine(rule, color);
    const width = rule.len / glyph.len;
    const label = try std.fmt.allocPrint(a, " {s} {d} more ", .{ direction, hidden });
    const cells = measure(label);
    const bytes = if (cells + 2 <= width) centered: {
        const left = (width - cells) / 2;
        break :centered try std.mem.concat(a, u8, &.{ rule[0 .. left * glyph.len], label, rule[(left + cells) * glyph.len ..] });
    } else shortened: {
        const abbreviated = try std.mem.concat(a, u8, &.{ "───", label });
        const dots = "..."[0..@min(width, 3)];
        break :shortened try std.mem.concat(a, u8, &.{ tui.layout.clipColumns(abbreviated, @intCast(width - dots.len)), dots });
    };
    return borderLine(bytes, color);
}

fn topBorder(a: Allocator, rule: []const u8, hidden: usize, active: ?Status, color: tui.Style) !tui.Node {
    const width = rule.len / glyph.len;
    const status = active orelse return scrollBorder(a, rule, "↑", hidden, color);
    if (width == 0) return borderLine(rule, color);

    const text = try std.fmt.allocPrint(a, "{s} {s}", .{ status.spinner, status.message });
    const rows = try tui.layout.visualLines(a, text, @intCast(@max(1, width -| 5)));
    var message = std.mem.trimEnd(u8, text[status.spinner.len..@max(status.spinner.len, rows[0].end)], " ");
    var status_width = measure(status.spinner) + measure(message);
    const label = if (hidden == 0) "" else try std.fmt.allocPrint(a, " ↑ {d} more ", .{hidden});
    const label_width = measure(label);
    const label_start = (width -| label_width) / 2;
    if (hidden != 0 and label_start < status_width + 5) {
        message = "";
        status_width = measure(status.spinner);
    }

    var buf_spinner: [96]u8 = undefined;
    var buf_message: [96]u8 = undefined;
    var buf_border: [96]u8 = undefined;
    const spinner_style = status.spinner_style.sgr(&buf_spinner);
    const message_style = status.message_style.sgr(&buf_message);
    const border_style = color.sgr(&buf_border);
    const styled = try std.mem.concat(a, u8, &.{ reset, spinner_style, status.spinner, reset, message_style, message, reset, border_style });
    const bytes = if (hidden != 0 and label_start >= status_width + 5) with_label: {
        const padding = label_start - status_width - 4;
        break :with_label try std.mem.concat(a, u8, &.{ "── ", styled, " ", rule[0 .. padding * glyph.len], label, rule[(label_start + label_width) * glyph.len ..] });
    } else if (width >= status_width + 5)
        try std.mem.concat(a, u8, &.{ "── ", styled, " ", rule[(status_width + 4) * glyph.len ..] })
    else narrow: {
        const spinner_width = measure(status.spinner);
        const left = @min(3, width -| spinner_width);
        break :narrow try std.mem.concat(a, u8, &.{ rule[0 .. left * glyph.len], reset, spinner_style, tui.layout.clipColumns(status.spinner, @intCast(width)), reset, border_style, rule[@min(width, left + spinner_width) * glyph.len ..] });
    };
    return borderLine(bytes, color);
}

pub const Frame = struct { node: tui.Node, editable_rows: u32 };

pub fn inputLine(a: Allocator, input: *const Editor, prefix: []const u8, width: u16, hardware: bool) !tui.Node {
    const prefix_width = measure(prefix);
    if (prefix_width >= width) return borderLine(prefix, .{});
    const text = input.text();
    const available = width - prefix_width;
    const total = measure(text);
    if (total < available) {
        const next = input.following(input.cursor);
        return tui.layout.inputLine(a, prefix, text[0..input.cursor], text[input.cursor..next], text[next..], hardware);
    }
    const visible = available - @intFromBool(input.cursor == text.len);
    const start = @min(measure(text[0..input.cursor]) -| (visible / 2), total -| visible);
    const left = columnOffset(text, start, true);
    const right = @max(left, columnOffset(text, start + visible, false));
    const cursor = std.math.clamp(input.cursor, left, right);
    const next = @min(right, input.following(cursor));
    return tui.layout.inputLine(a, prefix, text[left..cursor], text[cursor..next], text[next..right], hardware);
}

fn columnOffset(text: []const u8, target: usize, round_up: bool) usize {
    var clusters = kit.unicode.grapheme.Iterator.init(text) catch unreachable;
    var column: usize = 0;
    var offset: usize = 0;
    while (clusters.next()) |cluster| {
        if (column == target) return offset;
        if (column + cluster.width > target) return if (round_up) offset + cluster.bytes.len else offset;
        column += cluster.width;
        offset += cluster.bytes.len;
    }
    return text.len;
}

pub fn render(a: Allocator, input: *Editor, columns: u16, padding: u16, height: u32, color: tui.Style, status: ?Status, hardware: bool) !Frame {
    // The end-of-line caret uses the first right-padding cell when available.
    const width = @max(1, columns -| (2 * padding + @intFromBool(padding == 0)));
    input.setWidth(width);
    const rows = try input.layout(a, width);
    const cursor_row = input.cursorRow(rows);
    const count = @max(1, height);
    const first = input.firstVisibleRow(rows.len, cursor_row, count);
    const end = @min(rows.len, first + count);
    const rule = try md.horizontalRule(a, columns);
    const editable = try a.alloc(tui.Node, end - first);
    const text = input.text();
    for (rows[first..end], editable, first..) |row, *node, row_index| {
        if (row_index == cursor_row) {
            const glyph_end = @min(row.end, input.following(input.cursor));
            node.* = try tui.layout.inputLine(
                a,
                "",
                text[row.start..input.cursor],
                text[input.cursor..glyph_end],
                text[glyph_end..row.end],
                hardware,
            );
        } else {
            node.* = .{ .text = .{ .bytes = text[row.start..row.end], .overflow = .clip } };
        }
    }
    const children = try a.dupe(tui.Node, &.{
        try topBorder(a, rule, first, status, color),
        .{ .box = .{ .padding = .{ .left = padding, .right = padding -| 1 }, .children = editable } },
        try scrollBorder(a, rule, "↓", rows.len - end, color),
    });
    return .{ .node = .{ .stack = .{ .children = children } }, .editable_rows = @intCast(editable.len) };
}
