const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const Editor = @import("kit").tui.Editor;
const Skills = @import("../../skills.zig");
const Syntax = @import("../style.zig").Syntax;
const Theme = @import("../style.zig").Theme;
const reset = "\x1b[0m";

pub fn clean(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return Editor.normalize(a, bytes);
}

fn render(a: std.mem.Allocator, syntax: *Syntax.Engine, palette: *const Theme.Palette, bytes: []const u8, width: u16, style: ?tui.Style) !tui.Node {
    const safe = try clean(a, bytes);
    var out: std.ArrayList(u8) = .empty;
    var blocks: std.ArrayList(tui.Node) = .empty;
    var lines = std.mem.splitScalar(u8, safe, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const fence = Fence.parse(line);
        if (fence == null) {
            if (try tableBlock(a, palette, line, &lines, width)) |table| {
                if (out.items.len != 0) {
                    try blocks.append(a, .{ .text = .{ .bytes = out.items, .style = style } });
                    out = .empty;
                }
                try blocks.append(a, table);
                continue;
            }
        }
        if (out.items.len > 0) try out.append(a, '\n');
        if (fence) |opening| {
            try appendFence(a, syntax, palette, &out, opening, &lines);
        } else if (std.mem.startsWith(u8, trimmed, "#")) {
            var at: usize = 0;
            while (at < trimmed.len and trimmed[at] == '#') at += 1;
            if (at < trimmed.len and trimmed[at] == ' ') {
                var heading = palette.style(.mdHeading);
                heading.bold = true;
                try appendStyle(a, &out, heading);
                try inlineText(a, palette, &out, trimmed[at + 1 ..]);
            } else try inlineText(a, palette, &out, line);
        } else {
            if (std.mem.startsWith(u8, trimmed, ">")) try appendStyle(a, &out, palette.style(.mdQuote));
            try inlineText(a, palette, &out, line);
        }
        try out.appendSlice(a, reset);
    }
    if (blocks.items.len == 0) return .{ .text = .{ .bytes = out.items, .style = style } };
    if (out.items.len != 0) try blocks.append(a, .{ .text = .{ .bytes = out.items, .style = style } });
    return .{ .stack = .{ .children = blocks.items } };
}

const LineIter = std.mem.SplitIterator(u8, .scalar);
const Fence = struct {
    marker: u8,
    count: usize,
    indent: usize,
    language: []const u8,

    fn parse(line: []const u8) ?Fence {
        const text = std.mem.trimStart(u8, line, " ");
        const indent = line.len - text.len;
        if (indent > 3 or text.len < 3 or (text[0] != '`' and text[0] != '~')) return null;
        var end: usize = 1;
        while (end < text.len and text[end] == text[0]) end += 1;
        if (end < 3) return null;
        const info = std.mem.trim(u8, text[end..], " \t");
        if (text[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
        return .{ .marker = text[0], .count = end, .indent = indent, .language = info };
    }
};

fn appendFence(a: std.mem.Allocator, syntax: *Syntax.Engine, palette: *const Theme.Palette, out: *std.ArrayList(u8), opening: Fence, lines: *LineIter) !void {
    var source: std.ArrayList(u8) = .empty;
    var first = true;
    while (lines.next()) |line| {
        if (Fence.parse(line)) |closing| {
            if (closing.marker == opening.marker and closing.count >= opening.count and closing.language.len == 0) break;
        }
        if (lines.index == null) {
            if (line.len == 0) break;
            if (opening.indent == 0 and line.len < opening.count and std.mem.allEqual(u8, line, opening.marker)) break;
        }
        if (!first) try source.append(a, '\n');
        first = false;
        const leading = line.len - std.mem.trimStart(u8, line, " ").len;
        try source.appendSlice(a, line[if (leading >= opening.indent) opening.indent else 0..]);
    }
    const code = try syntax.paint(a, source.items, if (opening.language.len == 0) null else opening.language);
    try appendStyle(a, out, palette.style(.mdCodeBlockBorder));
    try out.appendSlice(a, "```");
    try out.appendSlice(a, opening.language);
    try out.appendSlice(a, reset);
    var rendered = std.mem.splitScalar(u8, code, '\n');
    while (rendered.next()) |line| {
        try out.appendSlice(a, "\n  ");
        try out.appendSlice(a, line);
    }
    try out.append(a, '\n');
    try appendStyle(a, out, palette.style(.mdCodeBlockBorder));
    try out.appendSlice(a, "```");
}

// Bound the number of measured tracks in a frame. Oversized rows stay readable as text.
const max_columns = 32;
const Row = struct {
    cells: [max_columns][]const u8 = undefined,
    len: usize = 0,

    fn add(row: *Row, cell: []const u8) bool {
        if (row.len == row.cells.len) return false;
        row.cells[row.len] = std.mem.trim(u8, cell, " \t");
        row.len += 1;
        return true;
    }

    fn parse(line: []const u8) ?Row {
        const s = std.mem.trim(u8, line, " \t");
        if (std.mem.indexOfScalar(u8, s, '|') == null or Fence.parse(s) != null) return null;
        var row: Row = .{};
        var start: usize = @intFromBool(s[0] == '|');
        var i = start;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len) {
                i += 1;
            } else if (s[i] == '|') {
                if (!row.add(s[start..i])) return null;
                start = i + 1;
            }
        }
        if (start == 0) return null;
        if (start < s.len and !row.add(s[start..])) return null;
        return if (row.len != 0) row else null;
    }
};

fn styledCell(a: std.mem.Allocator, palette: *const Theme.Palette, cell: []const u8) ![]const u8 {
    const text = if (std.mem.indexOf(u8, cell, "\\|") != null) try std.mem.replaceOwned(u8, a, cell, "\\|", "|") else cell;
    if (std.mem.indexOfAny(u8, text, "*`") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    try inlineText(a, palette, &out, text);
    return out.items;
}

fn tableBlock(a: std.mem.Allocator, palette: *const Theme.Palette, line: []const u8, lines: *std.mem.SplitIterator(u8, .scalar), width: u16) !?tui.Node {
    const header = Row.parse(line) orelse return null;
    var probe = lines.*;
    const rule = Row.parse(probe.next() orelse return null) orelse return null;
    if (header.len != rule.len) return null;
    var tracks: [max_columns]tui.Column = undefined;
    for (rule.cells[0..rule.len], 0..) |marker, i| {
        if (marker.len < 3) return null;
        const left = marker[0] == ':';
        const right = marker[marker.len - 1] == ':';
        const dashes = marker[@intFromBool(left) .. marker.len - @intFromBool(right)];
        if (dashes.len < 3 or !std.mem.allEqual(u8, dashes, '-')) return null;
        tracks[i] = .{ .title = header.cells[i], .alignment = if (left and right) .center else if (right) .right else .left };
    }
    const columns = try a.dupe(tui.Column, tracks[0..header.len]);
    for (columns) |*column| column.title = try styledCell(a, palette, column.title);
    lines.* = probe;
    var rows: std.ArrayList([]const []const u8) = .empty;
    while (probe.next()) |body| {
        const row = Row.parse(body) orelse break;
        if (row.len > columns.len) break;
        const cells = try a.alloc([]const u8, columns.len);
        for (cells, 0..) |*cell, i| cell.* = if (i < row.len) try styledCell(a, palette, row.cells[i]) else "";
        try rows.append(a, cells);
        lines.* = probe;
    }
    const gap = 2; // Kit separates adjacent table columns by two cells.
    var needed: usize = (columns.len - 1) * gap;
    for (columns, 0..) |column, i| {
        var widest = @max(1, kit.terminal.span_display_width.measure(column.title));
        for (rows.items) |row| widest = @max(widest, kit.terminal.span_display_width.measure(row[i]));
        needed += widest;
        if (needed > width) return try fieldList(a, columns, rows.items, width);
    }
    return .{ .table = .{ .columns = columns, .rows = rows.items } };
}

pub fn horizontalRule(a: std.mem.Allocator, width: u16) ![]const u8 {
    const rule = try a.alloc(u8, @as(usize, width) * "─".len);
    for (0..width) |i| @memcpy(rule[i * "─".len ..][0.."─".len], "─");
    return rule;
}

fn fieldList(a: std.mem.Allocator, columns: []const tui.Column, rows: []const []const []const u8, width: u16) !tui.Node {
    var fields: std.ArrayList(tui.Node) = .empty;
    const rule = tui.text(try horizontalRule(a, width), .muted);
    // While only the header has arrived, keep the field names visible.
    for (0..@max(rows.len, 1)) |r| {
        if (r != 0) try fields.append(a, rule);
        for (columns, 0..) |column, i| {
            const title = if (column.title.len != 0) column.title else try std.fmt.allocPrint(a, "Column {d}", .{i + 1});
            const value = if (rows.len == 0) "" else rows[r][i];
            try fields.append(a, tui.text(try std.fmt.allocPrint(a, "{s} : {s}", .{ title, value }), .plain));
        }
    }
    return .{ .stack = .{ .children = fields.items } };
}

fn appendStyle(a: std.mem.Allocator, out: *std.ArrayList(u8), style: tui.Style) !void {
    var bytes: [96]u8 = undefined;
    try out.appendSlice(a, style.sgr(&bytes));
}

fn inlineText(a: std.mem.Allocator, palette: *const Theme.Palette, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const marker: []const u8 = if (std.mem.startsWith(u8, text[i..], "**")) "**" else if (text[i] == '`') "`" else if (text[i] == '*') "*" else "";
        if (marker.len > 0) {
            if (std.mem.indexOf(u8, text[i + marker.len ..], marker)) |distance| {
                const end = i + marker.len + distance;
                if (marker[0] == '`')
                    try appendStyle(a, out, palette.style(.mdCode))
                else
                    try out.appendSlice(a, if (marker.len == 2) "\x1b[1m" else "\x1b[3m");
                try out.appendSlice(a, text[i + marker.len .. end]);
                try out.appendSlice(a, reset);
                i = end + marker.len;
                continue;
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
}

pub fn event(a: std.mem.Allocator, syntax: *Syntax.Engine, kind: anytype, text: []const u8, expanded: bool, columns: u16, padding: u16, palette: *const Theme.Palette, expand_key: []const u8) !tui.Node {
    const width = @max(1, columns -| (2 * padding));
    const user_background = palette.color(.userMessageBg);
    switch (kind) {
        .user => {
            if (Skills.parseBlock(text)) |skill| {
                const background = palette.color(.customMessageBg);
                var children: std.ArrayList(tui.Node) = .empty;
                const title = if (expanded)
                    "[skill]"
                else
                    try std.fmt.allocPrint(a, "[skill] {s} ({s} to expand)", .{ try clean(a, skill.name), expand_key });
                try children.append(a, .{ .text = .{ .bytes = title, .style = .{ .bold = true } } });
                if (expanded) {
                    try children.append(a, .{ .text = .{ .bytes = try clean(a, skill.name), .style = .{ .bold = true } } });
                    try children.append(a, .{ .spacer = 1 });
                    try children.append(a, try render(a, syntax, palette, skill.content, width, null));
                }
                const invocation = tui.Node{ .box = .{
                    .background = background,
                    .padding = .{ .top = 1, .bottom = 1, .left = padding, .right = padding },
                    .children = children.items,
                } };
                const prompt = skill.user_message orelse return invocation;
                return .{ .stack = .{ .gap = 1, .children = try a.dupe(tui.Node, &.{
                    invocation,
                    try userMessage(a, syntax, palette, prompt, width, padding, user_background),
                }) } };
            }
            return userMessage(a, syntax, palette, text, width, padding, user_background);
        },
        .compacting => return palette.text(.muted, "Compacting context…"),
        else => return palette.text(.muted, try clean(a, text)),
    }
}

pub fn mouseRegion(a: std.mem.Allocator, key: u64, node: tui.Node) !tui.Node {
    const child = try a.create(tui.Node);
    child.* = node;
    return .{ .mouse_region = .{ .key = key, .child = child } };
}

pub fn assistantBlock(a: std.mem.Allocator, syntax: *Syntax.Engine, palette: *const Theme.Palette, text: []const u8, width: u16, kind: enum { prose, reasoning, placeholder }) !tui.Node {
    if (kind == .prose) return render(a, syntax, palette, text, width, null);
    var style = palette.style(.thinkingText);
    style.italic = true;
    return if (kind == .placeholder) .{ .text = .{ .bytes = text, .style = style } } else render(a, syntax, palette, text, width, style);
}

pub const Summary = union(enum) {
    compacted: ?u64,
    branch,
};

fn tokenCount(a: std.mem.Allocator, tokens: u64) ![]const u8 {
    var buffer: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{tokens}) catch unreachable;
    var result: std.Io.Writer.Allocating = .init(a);
    for (digits, 0..) |digit, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try result.writer.writeByte(',');
        try result.writer.writeByte(digit);
    }
    return result.toOwnedSlice();
}

pub fn summary(a: std.mem.Allocator, syntax: *Syntax.Engine, palette: *const Theme.Palette, kind: Summary, text: []const u8, columns: u16, padding: u16, expanded: bool, expand_key: []const u8) !tui.Node {
    const heading = switch (kind) {
        .branch => if (expanded) "Branch Summary" else "Branch summary",
        .compacted => |tokens| if (tokens) |count| try std.fmt.allocPrint(a, "Compacted from {s} tokens", .{try tokenCount(a, count)}) else "Context compacted",
    };
    const color = palette.style(.customMessageText);
    const body = if (expanded)
        try render(a, syntax, palette, try std.fmt.allocPrint(a, "**{s}**\n\n{s}", .{ heading, text }), @max(1, columns -| (2 * padding)), color)
    else collapsed: {
        var dim_buffer: [96]u8 = undefined;
        var body_buffer: [96]u8 = undefined;
        const bytes = try std.fmt.allocPrint(a, "{s} (\x1b[22;39m{s}{s}\x1b[22;39m{s} to expand)", .{
            heading, palette.style(.dim).sgr(&dim_buffer), expand_key, color.sgr(&body_buffer),
        });
        break :collapsed tui.Node{ .text = .{ .bytes = bytes, .style = color } };
    };
    return .{ .box = .{
        .background = palette.color(.customMessageBg),
        .padding = .{ .top = 1, .bottom = 1, .left = padding, .right = padding },
        .children = try a.dupe(tui.Node, &.{
            .{ .text = .{
                .bytes = if (kind == .branch) "[branch]" else "[compaction]",
                .style = .{ .bold = true, .foreground = palette.color(.customMessageLabel) },
            } },
            .{ .spacer = 1 },
            body,
        }),
    } };
}

fn userMessage(a: std.mem.Allocator, syntax: *Syntax.Engine, palette: *const Theme.Palette, text: []const u8, width: u16, padding: u16, color: ?tui.Color) !tui.Node {
    return .{ .box = .{
        .background = color,
        .padding = .{ .top = 1, .bottom = 1, .left = padding, .right = padding },
        .children = try a.dupe(tui.Node, &.{try render(a, syntax, palette, text, width, null)}),
    } };
}
