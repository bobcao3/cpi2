const std = @import("std");
const kit = @import("kit");
const md = @import("transcript.zig").markdown;
const Theme = @import("style.zig").Theme;
const Usage = @import("../session.zig").Usage;
const Row = @import("UiPresentation.zig").FooterRow;
const tui = kit.tui;
const Allocator = std.mem.Allocator;
const measure = kit.terminal.span_display_width.measure;

pub const Info = struct {
    workspace: []const u8,
    home: []const u8,
    branch: ?[]const u8,
    title: ?[]const u8,
    stats: Usage.Stats,
    context_tokens: ?u64,
    context_window: u64,
    auto_compact: bool,
    model: []const u8,
    provider: ?[]const u8,
    thinking: ?@import("agent").thinking.Level,
    subscription: bool,
};

fn text(bytes: []const u8, style: tui.Style) tui.Node {
    return .{ .text = .{ .bytes = bytes, .style = style, .overflow = .clip } };
}

fn singleLine(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, bytes, "\r\n\t") == null) return md.clean(a, bytes);
    const plain = try a.dupe(u8, bytes);
    for (plain) |*byte| switch (byte.*) {
        '\r', '\n', '\t' => byte.* = ' ',
        else => {},
    };
    return md.clean(a, plain);
}

fn location(a: Allocator, info: Info) ![]const u8 {
    const workspace = info.workspace;
    const home = std.mem.trimEnd(u8, info.home, std.fs.path.sep_str);
    const inside_home = home.len != 0 and std.mem.startsWith(u8, workspace, home) and
        (workspace.len == home.len or std.fs.path.isSep(workspace[home.len]));
    var line: std.Io.Writer.Allocating = .init(a);
    if (inside_home) {
        try line.writer.print("~{s}", .{workspace[home.len..]});
    } else if (home.len == 0 and info.home.len != 0 and workspace.len != 0 and std.fs.path.isSep(workspace[0])) {
        try line.writer.print("~{s}", .{if (workspace.len == 1) "" else workspace});
    } else try line.writer.writeAll(workspace);
    if (info.branch) |branch| try line.writer.print(" ({s})", .{branch});
    if (info.title) |title| try line.writer.print(" • {s}", .{title});
    return singleLine(a, try line.toOwnedSlice());
}

pub fn ellipsize(a: Allocator, bytes: []const u8, width: u16) ![]const u8 {
    if (measure(bytes) <= width) return bytes;
    const suffix = "..."[0..@min(width, 3)];
    return std.mem.concat(a, u8, &.{ tui.layout.clipColumns(bytes, width -| 3), suffix });
}

fn statsLine(a: Allocator, columns: u16, palette: *const Theme.Palette, info: Info) ![]const u8 {
    const used = info.context_tokens;
    const ratio: ?f64 = if (info.context_window == 0) 0 else if (used) |count|
        @as(f64, @floatFromInt(count)) * 100 / @as(f64, @floatFromInt(info.context_window))
    else
        null;
    const percent = if (ratio) |value| try std.fmt.allocPrint(a, "{d:.1}%", .{value}) else "?";
    const left = try Usage.summary(a, info.stats);
    const cost: []const u8 = if (info.subscription) "$0.000 (sub) " else "";
    const context = try std.fmt.allocPrint(a, "{s}/{s}{s}", .{
        percent,
        try Usage.formatTokens(a, info.context_window),
        if (info.auto_compact) " (auto)" else "",
    });
    var warning: [96]u8 = undefined;
    var normal: [96]u8 = undefined;
    const dim = palette.style(.dim).sgr(&normal);
    const unstyled = "\x1b[22;39m";
    const decorated = if ((ratio orelse 0) > 70)
        try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{
            unstyled,
            palette.style(if (ratio.? > 90) .@"error" else .warning).sgr(&warning),
            context,
            unstyled,
            dim,
        })
    else
        context;
    const stats = try std.mem.concat(a, u8, &.{ left, if (left.len != 0) " " else "", cost, decorated });
    const cells = measure(stats);
    if (cells > columns) {
        const suffix = "..."[0..@min(columns, 3)];
        return std.mem.concat(a, u8, &.{ tui.layout.clipColumns(stats, columns -| 3), unstyled, dim, suffix });
    }
    const available = @as(usize, columns) -| (cells + 2);
    if (available == 0) return stats;
    const model = try singleLine(a, info.model);
    var right = if (info.thinking) |level|
        try std.fmt.allocPrint(a, "{s} • {s}", .{ model, if (level == .off) "thinking off" else @tagName(level) })
    else
        model;
    if (info.provider) |provider| {
        const name = try singleLine(a, provider);
        if (measure(name) + 3 + measure(right) <= available)
            right = try std.fmt.allocPrint(a, "({s}) {s}", .{ name, right });
    }
    const visible_right = tui.layout.clipColumns(right, @intCast(available));
    if (visible_right.len == 0) return stats;
    return std.fmt.allocPrint(a, "{[stats]s}{[space]s: >[padding]}{[route]s}", .{
        .stats = stats,
        .space = "",
        .padding = columns - cells - measure(visible_right),
        .route = visible_right,
    });
}

pub fn append(a: Allocator, nodes: *std.ArrayList(tui.Node), rows: []const Row, width: u16, palette: *const Theme.Palette, info: Info) !void {
    const dim = palette.style(.dim);
    for (rows) |row| try nodes.append(a, text(switch (row) {
        .location => try ellipsize(a, try location(a, info), width),
        .status => try statsLine(a, width, palette, info),
    }, dim));
}
