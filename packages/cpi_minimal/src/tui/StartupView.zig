const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const version = @import("build_options").version;
const UiPresentation = @import("UiPresentation.zig");
const Skills = @import("../skills.zig");
const md = @import("transcript.zig").markdown;
const Theme = @import("style.zig").Theme;
const Allocator = std.mem.Allocator;
const Nodes = std.ArrayList(tui.Node);

fn line(bytes: []const u8, color: tui.Style) tui.Node {
    return .{ .text = .{ .bytes = bytes, .style = color } };
}

fn logo(comptime fg: []const u8, comptime blue: []const u8, comptime blue_bg: []const u8, comptime yellow: []const u8) [2][]const u8 {
    const reset = "\x1b[0m";
    return .{
        fg ++ blue_bg ++ "▀" ++ reset ++ fg ++ "▀█" ++ reset ++ " ",
        blue ++ "█▀" ++ reset ++ " " ++ yellow ++ "█" ++ reset,
    };
}

pub fn appendHeader(a: Allocator, document: *Nodes, rows: []const UiPresentation.Row, truecolor: bool, show_logo: bool, palette: *const Theme.Palette) !void {
    if (rows.len == 0) return;
    const mark = if (truecolor)
        logo("\x1b[38;2;228;138;122m", "\x1b[38;2;79;142;179m", "\x1b[48;2;79;142;179m", "\x1b[38;2;234;182;93m")
    else
        logo("\x1b[38;5;174m", "\x1b[38;5;67m", "\x1b[48;5;67m", "\x1b[38;5;179m");
    const header = try a.alloc(tui.Node, rows.len);
    var dim_sgr: [96]u8 = undefined;
    var muted_sgr: [96]u8 = undefined;
    const dim = palette.style(.dim).sgr(&dim_sgr);
    const muted = palette.style(.muted).sgr(&muted_sgr);
    for (rows, header) |row, *node| {
        if (row.spans.len == 0) {
            node.* = .{ .spacer = 1 };
            continue;
        }
        var body: std.Io.Writer.Allocating = .init(a);
        if (show_logo and row.mark != .none) {
            try body.writer.print("{s} ", .{mark[if (row.mark == .title) 0 else 1]});
        }
        for (row.spans) |span| {
            try body.writer.print("\x1b[0m{s}{s}", .{ if (span.role == .muted) muted else dim, span.text });
            if (span.role == .version) try body.writer.writeAll(version);
        }
        const base = if (row.spans.len == 1)
            palette.style(if (row.spans[0].role == .muted) .muted else .dim)
        else
            tui.Style{};
        node.* = line(try body.toOwnedSlice(), base);
    }
    try document.appendSlice(a, &.{
        .{ .spacer = 1 },
        .{ .box = .{ .padding = .{ .left = 1, .right = 1 }, .children = header } },
        .{ .spacer = 1 },
    });
}

pub fn appendSkills(a: Allocator, document: *Nodes, skills: *const Skills, home: []const u8, palette: *const Theme.Palette, show_list: bool, expanded: bool) !void {
    if (show_list and skills.skills.len != 0) {
        try document.append(a, line("[Skills]", palette.style(.warning)));
        if (expanded) {
            try appendPaths(a, document, skills.skills, home, palette);
        } else {
            const names = try a.alloc([]const u8, skills.skills.len);
            for (names, skills.skills) |*name, skill| name.* = skill.name;
            std.mem.sort([]const u8, names, {}, byName);
            var body: std.Io.Writer.Allocating = .init(a);
            try body.writer.writeAll("  ");
            for (names, 0..) |name, i| {
                if (i != 0) try body.writer.writeAll(", ");
                try body.writer.writeAll(try md.clean(a, name));
            }
            try document.append(a, line(try body.toOwnedSlice(), palette.style(.dim)));
        }
        try document.append(a, .{ .spacer = 1 });
    }
    if (skills.diagnostics.len != 0) try appendWarnings(a, document, skills, home, palette);
}

fn byName(_: void, left: []const u8, right: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(left, right);
}

fn byPath(_: void, left: Skills.Skill, right: Skills.Skill) bool {
    return byName({}, left.file_path, right.file_path);
}

fn scopeName(scope: Skills.Scope) []const u8 {
    return switch (scope) {
        .project => "project",
        .user => "user",
        .temporary => "path",
    };
}

fn appendPaths(a: Allocator, document: *Nodes, skills: []const Skills.Skill, home: []const u8, palette: *const Theme.Palette) !void {
    const ordered = try a.dupe(Skills.Skill, skills);
    std.mem.sort(Skills.Skill, ordered, {}, byPath);
    for ([_]Skills.Scope{ .project, .user, .temporary }) |scope| {
        var first = true;
        for (ordered) |skill| {
            if (skill.source.scope != scope) continue;
            if (first) {
                first = false;
                try document.append(a, line(try std.fmt.allocPrint(a, "  {s}", .{scopeName(scope)}), palette.style(.accent)));
            }
            const path = try displayPath(a, skill.file_path, home);
            try document.append(a, line(try std.fmt.allocPrint(a, "    {s}", .{path}), palette.style(.dim)));
        }
    }
}

fn displayPath(a: Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return md.clean(a, path);
    if (path.len == home.len) return "~";
    if (path[home.len] != std.fs.path.sep) return md.clean(a, path);
    return std.fmt.allocPrint(a, "~{s}", .{try md.clean(a, path[home.len..])});
}

fn skillPath(a: Allocator, skill: Skills.Skill, home: []const u8) ![]const u8 {
    const path = try displayPath(a, skill.file_path, home);
    const scope = if (skill.source.scope == .temporary) "temp" else scopeName(skill.source.scope);
    return switch (skill.source.origin) {
        .local => try std.fmt.allocPrint(a, "{s} {s}", .{ if (skill.source.scope == .temporary) "path (temp)" else scope, path }),
        .auto => try std.fmt.allocPrint(a, "auto ({s}) {s}", .{ scope, path }),
        .package => |specifier| try std.fmt.allocPrint(a, "{s} ({s}) {s}", .{ try md.clean(a, specifier), scope, path }),
    };
}

fn collisionRow(a: Allocator, glyph: []const u8, color: tui.Style, path: []const u8, suffix: []const u8, dim: tui.Style) !tui.Node {
    var mark_sgr: [96]u8 = undefined;
    var dim_sgr: [96]u8 = undefined;
    const mark = color.sgr(&mark_sgr);
    const rest = dim.sgr(&dim_sgr);
    const bytes = try std.fmt.allocPrint(a, "    {s}{s}{s} {s}{s}", .{ mark, glyph, rest, path, suffix });
    return line(bytes, dim);
}

fn appendWarnings(a: Allocator, document: *Nodes, skills: *const Skills, home: []const u8, palette: *const Theme.Palette) !void {
    try document.append(a, line("[Skill warnings]", palette.style(.warning)));
    var collisions: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (skills.diagnostics) |diagnostic| {
        if (diagnostic.kind != .collision) continue;
        const entry = try collisions.getOrPut(a, diagnostic.kind.collision);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, diagnostic.path);
    }
    for (collisions.keys(), collisions.values()) |name, losers| {
        try document.append(a, line(try std.fmt.allocPrint(a, "  \"{s}\" collision:", .{try md.clean(a, name)}), palette.style(.warning)));
        const winner = skills.find(name).?;
        try document.append(a, try collisionRow(a, "✓", palette.style(.success), try skillPath(a, winner.*, home), "", palette.style(.dim)));
        for (losers.items) |path| {
            try document.append(a, try collisionRow(a, "✗", palette.style(.warning), try displayPath(a, path, home), " (skipped)", palette.style(.dim)));
        }
    }
    for (skills.diagnostics) |diagnostic| {
        if (diagnostic.kind == .collision) continue;
        const color = if (diagnostic.kind == .err) palette.style(.@"error") else palette.style(.warning);
        var path = try displayPath(a, diagnostic.path, home);
        for (skills.skills) |skill| {
            if (!std.mem.eql(u8, skill.file_path, diagnostic.path)) continue;
            path = try skillPath(a, skill, home);
            break;
        }
        try document.append(a, line(try std.fmt.allocPrint(a, "  {s}", .{path}), color));
        try document.append(a, line(try std.fmt.allocPrint(a, "    {s}", .{try md.clean(a, diagnostic.message)}), color));
    }
    try document.append(a, .{ .spacer = 1 });
}
