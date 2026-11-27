const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const j = @import("../../json.zig");
const md = @import("markdown.zig");
const fields = @import("args.zig");
const paths = @import("../../tools.zig").paths;
const EditPreview = @import("EditPreview.zig");
const EditWords = @import("EditWords.zig");
const Syntax = @import("../style.zig").Syntax;
const Theme = @import("../style.zig").Theme;
const ShellInput = @import("ShellInput.zig");
const ToolImages = @import("ToolImages.zig");
const UiPresentation = @import("../UiPresentation.zig");
const Event = @import("../../session.zig").Controller.Event;
const JsonDocument = @import("agent").JsonDocument;
const Allocator = std.mem.Allocator;

fn bold(style: tui.Style) tui.Style {
    var result = style;
    result.bold = true;
    return result;
}

pub fn isScript(name: []const u8) bool {
    return std.mem.eql(u8, name, "execute_lua");
}

pub const Live = union(enum) {
    none,
    edit: EditPreview.Body,
    write: *Syntax.WriteCache,
    shell: struct { output: []const u8, elapsed_ms: i64 },
    script: struct { calls: []const JsonDocument, elapsed_ms: i64 },
};
const ImageLayout = struct {
    previews: []const ?ToolImages.Preview,
    protocol: ToolImages.Protocol,
    cell_width: u16,
    cell_height: u16,
    preferred_width: u16,
};

pub const Display = struct {
    columns: u16,
    output_padding: u16 = 1,
    expanded: bool,
    theme: *const Theme.Palette,
    location: paths.Location,
    syntax: *Syntax.Engine,
    presentation: *const UiPresentation,
    images: ?ImageLayout = null,
    mouse_key: ?u64 = null,
};

pub fn render(a: Allocator, event: Event, tool: UiPresentation.Tool, display: Display, live: Live) !tui.Node {
    const palette = display.theme;
    const expanded = display.expanded;
    const expand_key = display.presentation.shortcuts.expand_tools.label;
    const location = display.location;
    const columns = display.columns;
    const name = if (event.name.len != 0) event.name else "tool";
    const search: ?*const UiPresentation.SearchCard = switch (tool) {
        inline .grep, .find, .ls => |kind| &@field(display.presentation.search, @tagName(kind)),
        else => null,
    };
    const settled = event.kind == .tool_end;
    const failed = settled and j.flag(j.get(event.data, "isError"));
    const args = switch (event.kind) {
        .tool_start => event.data,
        .tool_end => event.arguments,
        else => if (tool == .other) j.parse(a, event.text) catch .null else try fields.preview(a, event.text),
    };
    const file_path = j.get(args, "file_path");
    const path = stringArgument(if (file_path == .null) j.get(args, "path") else file_path);
    const details = j.get(event.data, "details");
    var body: std.ArrayList(tui.Node) = .empty;
    const heading = switch (tool) {
        .read => try readTitle(a, path, args, expanded, location, palette, expand_key),
        .write, .edit => try ordinaryFileTitle(a, name, path, "", location, palette),
        .bash => try shellTitle(a, stringArgument(j.get(args, "command")), args, palette),
        .grep, .find, .ls => try searchTitle(a, name, search.?, args, location, palette),
        .execute_lua => title: {
            var code: [96]u8 = undefined;
            var error_code: [96]u8 = undefined;
            const source = j.get(args, "source");
            break :title try std.fmt.allocPrint(a, "{s}{s}\x1b[0m{s}{s}\x1b[0m", .{
                bold(palette.style(.toolTitle)).sgr(&code),      name,
                display.theme.style(.@"error").sgr(&error_code), if (source == .null or source == .string) "" else " [invalid arg]",
            });
        },
        .other => try genericTitle(a, name, args, expanded, palette),
    };
    try body.append(a, tui.text(heading, .plain));

    const sections = switch (tool) {
        inline else => |kind| @field(display.presentation.tools, @tagName(kind)),
    };
    for (sections) |section| {
        const show = switch (section.when) {
            .always => true,
            .complete => settled,
            .expanded_or_failed => settled and (expanded or failed),
            .failed => failed,
        };
        if (!show) continue;
        const limit: ?usize = if (expanded) null else section.collapsed_rows orelse if (search) |card| card.collapsed_rows else null;
        switch (section.component) {
            .result, .content => {
                const content = section.component == .content;
                const text = if (content) stringArgument(j.get(args, "content")) else if (search != null)
                    std.mem.trim(u8, event.text, " \t\r\n")
                else if (display.images == null) try outputWithImages(a, event) else event.text;
                if (text) |bytes| {
                    const cache = if (content and live == .write) live.write else null;
                    const highlight = if (section.highlight and (content or !failed)) Highlight.file(display.syntax, path, cache) else null;
                    try appendHead(a, &body, bytes, limit, section.show_total, display, highlight);
                } else try appendResult(a, &body, "[invalid content arg - expected string]", palette.style(.toolDiffRemoved));
            },
            .error_message => try appendResult(a, &body, event.text, palette.style(.toolDiffRemoved)),
            .read_limit => if (try readTruncationWarning(a, j.get(details, "truncation"))) |warning|
                try body.append(a, colored(warning, palette.style(.warning))),
            .image_warning => {
                const unsupported = j.text(j.get(details, "imageUnsupportedByModel"));
                if (unsupported.len == 0) continue;
                if (body.items.len == 1) try body.append(a, .{ .spacer = 1 });
                const message = try std.fmt.allocPrint(a, "[{s} does not support images; it saw a placeholder instead]", .{try md.clean(a, unsupported)});
                try body.append(a, colored(message, palette.style(.warning)));
            },
            .diff => if (live == .edit) {
                switch (live.edit) {
                    .diff => |diff| try appendDiff(a, &body, diff, palette),
                    .failure => |message| try appendResult(a, &body, message, palette.style(.toolDiffRemoved)),
                }
            } else if (settled) {
                const diff = j.text(j.get(details, "diff"));
                if (!failed and diff.len != 0) {
                    try appendDiff(a, &body, diff, palette);
                } else {
                    try appendResult(a, &body, event.text, if (failed) palette.style(.toolDiffRemoved) else palette.style(.toolOutput));
                    if (!failed and j.flag(j.get(details, "diffOmitted")))
                        try appendResult(a, &body, "Diff omitted because it exceeds the display budget.", palette.style(.warning));
                }
            },
            .tail => if (limit != 0 and (settled or live == .shell)) {
                const text = if (settled) shellOutput(event.text, details) else live.shell.output;
                const output = std.mem.trim(u8, try plainOutput(a, text), " \n");
                if (output.len != 0)
                    try ShellInput.appendOutput(a, &body, output, columns -| (2 * display.output_padding), limit, palette, expand_key);
            },
            .shell_warning => {
                try appendResult(a, &body, j.text(j.get(details, "warning")), palette.style(.warning));
                try appendResult(a, &body, j.text(j.get(details, "status")), palette.style(.toolOutput));
            },
            .duration => {
                const duration = j.get(details, "durationMs");
                const elapsed = if (settled)
                    if (tool == .execute_lua and duration == .integer and duration.integer >= 0) duration.integer else event.tool_duration_ms
                else switch (live) {
                    inline .shell, .script => |preview| preview.elapsed_ms,
                    else => null,
                };
                if (elapsed) |ms| try appendToolTime(a, &body, if (settled) "Took" else "Elapsed", ms, palette.style(.muted));
            },
            .script_source => if (limit != 0) {
                const code = std.mem.trimEnd(u8, try plainOutput(a, j.text(j.get(args, "source"))), " \t\n");
                if (code.len == 0) continue;
                const text = if (section.highlight) try display.syntax.paint(a, code, "lua") else code;
                try appendHeadPreview(a, &body, text, limit, .{}, display, .visual);
            },
            .script_calls => if (limit != 0) {
                const calls = j.items(j.get(details, "calls"));
                const streamed = if (live == .script) live.script.calls else &.{};
                const count = if (settled) calls.len else streamed.len;
                if (count == 0) continue;
                try body.append(a, .{ .spacer = 1 });
                const first = count -| (limit orelse count);
                if (first != 0) try body.append(a, colored(try expansionHint(a, display, .muted, "... ({d} earlier calls, ", .{first}), palette.style(.muted)));
                for (first..count) |i| try appendScriptCall(a, &body, if (settled) calls[i] else streamed[i].value, expanded, palette);
            },
            .script_output => if (settled and limit != 0) {
                const text = if (display.images == null) try outputWithImages(a, event) else event.text;
                const output = std.mem.trim(u8, try plainOutput(a, scriptOutput(text)), " \t\n");
                if (output.len == 0) continue;
                try body.append(a, .{ .spacer = 1 });
                try appendHeadPreview(a, &body, output, limit, palette.style(if (failed) .@"error" else .toolOutput), display, .visual);
                const full = j.text(j.get(details, "fullOutputPath"));
                if (!expanded and full.len != 0) {
                    try body.append(a, colored(try std.fmt.allocPrint(a, "Full output: {s}", .{try md.clean(a, full)}), palette.style(.muted)));
                }
            },
            .search_warning => if (search) |card| try appendSearchWarning(a, &body, &display.presentation.search, card, details, palette.style(.warning)),
        }
    }
    const mouse_key = if (settled or live == .script or (live == .shell and live.shell.output.len != 0)) display.mouse_key else null;
    const content = if (tool != .other and mouse_key != null)
        try a.dupe(tui.Node, &.{try md.mouseRegion(a, mouse_key.?, .{ .stack = .{ .children = body.items } })})
    else
        body.items;
    const box: tui.Node = .{ .box = .{
        .background = if (live == .edit) switch (live.edit) {
            .diff => palette.color(.toolSuccessBg),
            .failure => palette.color(.toolErrorBg),
        } else if (!settled) palette.color(.toolPendingBg) else if (failed) palette.color(.toolErrorBg) else palette.color(.toolSuccessBg),
        .padding = .{ .left = display.output_padding, .right = display.output_padding, .top = 1, .bottom = 1 },
        .children = content,
    } };
    const card = if (tool == .other and mouse_key != null) try md.mouseRegion(a, mouse_key.?, box) else box;
    const image_layout = display.images orelse return card;
    var stack: std.ArrayList(tui.Node) = .empty;
    try stack.append(a, card);
    for (event.images, 0..) |image, i| {
        try stack.append(a, .{ .spacer = 1 });
        if (i < image_layout.previews.len) if (image_layout.previews[i]) |preview| {
            const size = preview.dimensions;
            const cells = imageCells(size, columns, image_layout);
            try stack.append(a, if (image_layout.protocol == .kitty) .{ .png_image = .{
                .png = .{ .bytes = preview.bytes, .identity = preview.identity },
                .width = size.width,
                .height = size.height,
                .columns = cells.columns,
                .rows = cells.rows,
            } } else .{ .inline_image = .{
                .bytes = preview.bytes,
                .columns = cells.columns,
                .rows = cells.rows,
            } });
            continue;
        };
        const label = try imageLabel(a, image.mime_type, image.dimensions orelse .{ .width = 800, .height = 600 });
        const text = if (kit.terminal.span_display_width.measure(label) > columns)
            try std.fmt.allocPrint(a, "{s}…", .{tui.layout.clipColumns(label, columns -| 1)})
        else
            label;
        try stack.append(a, .{ .text = .{ .bytes = text, .overflow = .clip, .style = palette.style(.toolOutput) } });
    }
    return .{ .stack = .{ .children = stack.items } };
}

fn appendDiff(a: Allocator, body: *std.ArrayList(tui.Node), diff: []const u8, palette: *const Theme.Palette) !void {
    try body.append(a, .{ .spacer = 1 });
    var lines = std.mem.splitScalar(u8, diff, '\n');
    // Keep redraw work bounded even for several disjoint single-line edits.
    var word_budget: usize = 64 * 1024;
    var inside_removals = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const old_start = diffContentStart(line, '-');
        if (old_start) |old_at| {
            if (!inside_removals and word_budget > 0) {
                var lookahead = lines;
                const added = lookahead.next() orelse "";
                const next = lookahead.peek() orelse "";
                const new_at = diffContentStart(added, '+');
                if (new_at != null and diffContentStart(next, '+') == null and
                    try appendWordDiff(a, body, line, old_at, added, new_at.?, palette, &word_budget))
                {
                    lines = lookahead;
                    continue;
                }
            }
            inside_removals = true;
        } else inside_removals = false;
        const color = if (old_start != null) palette.style(.toolDiffRemoved) else if (diffContentStart(line, '+') != null) palette.style(.toolDiffAdded) else palette.style(.toolDiffContext);
        try body.append(a, colored(try plainOutput(a, line), color));
    }
}

fn diffContentStart(line: []const u8, sign: u8) ?usize {
    if (line.len == 0 or line[0] != sign) return null;
    const numeral = 1 + EditWords.leadingWhitespace(line[1..]).len;
    var after = numeral;
    while (after < line.len and std.ascii.isDigit(line[after])) after += 1;
    const content = if (after > numeral and EditWords.leadingWhitespace(line[after..]).len > 0)
        after + (std.unicode.utf8ByteSequenceLength(line[after]) catch return null)
    else if (numeral > 1)
        numeral
    else
        return null;
    // Pi's row pattern uses a JavaScript dot without dotAll for its content.
    if (std.mem.indexOfScalar(u8, line[content..], '\r') != null or
        std.mem.indexOf(u8, line[content..], "\u{2028}") != null or
        std.mem.indexOf(u8, line[content..], "\u{2029}") != null) return null;
    return content;
}

fn appendWordDiff(a: Allocator, body: *std.ArrayList(tui.Node), removed: []const u8, old_at: usize, added: []const u8, new_at: usize, palette: *const Theme.Palette, budget: *usize) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const work = scratch.allocator();
    const old = try plainOutput(work, removed[old_at..]);
    const new = try plainOutput(work, added[new_at..]);
    const old_indent = EditWords.leadingWhitespace(old);
    const new_indent = EditWords.leadingWhitespace(new);
    var common: usize = 0;
    while (common < @min(old_indent.len, new_indent.len) and old_indent[common] == new_indent[common]) common += 1;
    while (common > 0 and common < old_indent.len and old_indent[common] & 0xc0 == 0x80) common -= 1;
    const changes = (try EditWords.diff(work, old[common..], new[common..], budget)) orelse return false;
    try body.append(a, colored(try wordDiffLine(a, try plainOutput(work, removed[0..old_at]), old[0..common], changes, .remove), palette.style(.toolDiffRemoved)));
    try body.append(a, colored(try wordDiffLine(a, try plainOutput(work, added[0..new_at]), new[0..common], changes, .add), palette.style(.toolDiffAdded)));
    return true;
}

fn wordDiffLine(a: Allocator, prefix: []const u8, indent: []const u8, changes: []const EditWords.Change, kind: EditWords.Kind) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, prefix);
    try bytes.appendSlice(a, indent);
    var first = true;
    for (changes) |change| {
        if (change.kind == .keep) {
            try bytes.appendSlice(a, change.text);
        } else if (change.kind == kind) {
            const plain = if (first) EditWords.leadingWhitespace(change.text).len else 0;
            first = false;
            try bytes.appendSlice(a, change.text[0..plain]);
            if (plain == change.text.len) continue;
            try bytes.appendSlice(a, "\x1b[7m");
            try bytes.appendSlice(a, change.text[plain..]);
            try bytes.appendSlice(a, "\x1b[27m");
        }
    }
    return bytes.items;
}

fn appendToolTime(a: Allocator, body: *std.ArrayList(tui.Node), label: []const u8, elapsed_ms: i64, style: tui.Style) !void {
    const millis: u64 = @intCast(@max(0, elapsed_ms));
    const seconds = millis / 1000;
    const time = if (seconds < 60)
        try std.fmt.allocPrint(a, "{d:.1}s", .{@as(f64, @floatFromInt(millis)) / 1000})
    else if (seconds < 3600)
        try std.fmt.allocPrint(a, "{d}m {d}s", .{ seconds / 60, seconds % 60 })
    else
        try std.fmt.allocPrint(a, "{d}h {d}m {d}s", .{ seconds / 3600, seconds / 60 % 60, seconds % 60 });
    try body.append(a, .{ .spacer = 1 });
    try body.append(a, colored(try std.fmt.allocPrint(a, "{s} {s}", .{ label, time }), style));
}

fn stringArgument(value: j.Value) ?[]const u8 {
    return switch (value) {
        .string => value.string,
        .null => "",
        else => null,
    };
}

fn lineNumber(value: j.Value) ?f64 {
    const number: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        .number_string => std.fmt.parseFloat(f64, value.number_string) catch return null,
        .string => parseLineNumber(value.string) orelse return null,
        else => return null,
    };
    return if (std.math.isFinite(number)) number else null;
}

fn parseLineNumber(raw: []const u8) ?f64 {
    var text = raw[EditWords.leadingWhitespace(raw).len..];
    while (text.len > 0) {
        var end = text.len - 1;
        while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
        if (EditWords.leadingWhitespace(text[end..]).len == 0) break;
        text = text[0..end];
    }
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '_') != null) return null;
    if (text.len > 2 and text[0] == '0') {
        const base: u8 = switch (std.ascii.toLower(text[1])) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 0,
        };
        if (base != 0) {
            var n: f64 = 0;
            for (text[2..]) |byte| n = n * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(std.fmt.charToDigit(byte, base) catch return null));
            return n;
        }
    }
    return std.fmt.parseFloat(f64, text) catch null;
}

fn printLineNumber(a: Allocator, number: f64) ![]const u8 {
    if (number == 0) return "0";
    if (!std.math.isFinite(number)) return if (number < 0) "-Infinity" else "Infinity";
    if (@abs(number) >= 1e-6 and @abs(number) < 1e21) return std.fmt.allocPrint(a, "{d}", .{number});
    const scientific = try std.fmt.allocPrint(a, "{e}", .{number});
    const exponent = std.mem.indexOfScalar(u8, scientific, 'e') orelse return scientific;
    if (scientific[exponent + 1] == '-' or scientific[exponent + 1] == '+') return scientific;
    return std.fmt.allocPrint(a, "{s}+{s}", .{ scientific[0 .. exponent + 1], scientific[exponent + 1 ..] });
}

pub fn readRange(a: Allocator, args: j.Value) ![]const u8 {
    const offset = j.get(args, "offset");
    const limit = j.get(args, "limit");
    if (offset == .null and limit == .null) return "";
    const start = if (offset == .null) 1 else lineNumber(offset) orelse return "";
    const last = if (limit == .null) 0 else start + (lineNumber(limit) orelse return "") - 1;
    const first = try printLineNumber(a, start);
    if (last == 0) return std.fmt.allocPrint(a, ":{s}", .{first});
    return std.fmt.allocPrint(a, ":{s}-{s}", .{ first, try printLineNumber(a, last) });
}

const FileTitle = enum { normal, skill, resource };

fn readTitle(a: Allocator, path: ?[]const u8, args: j.Value, expanded: bool, location: paths.Location, palette: *const Theme.Palette, expand_key: []const u8) ![]const u8 {
    const range = try readRange(a, args);
    if (!expanded) if (path) |raw| {
        if (raw.len > 0) {
            const absolute = paths.resolveRead(a, location, raw) catch |err| switch (err) {
                error.InvalidFileUrl => return ordinaryFileTitle(a, "read", path, range, location, palette),
                else => |failure| return failure,
            };
            const base = std.fs.path.basename(absolute);
            if (std.mem.eql(u8, base, "SKILL.md")) {
                const parent = std.fs.path.basename(std.fs.path.dirname(absolute) orelse "");
                return fileTitle(a, "[skill]", if (parent.len == 0) base else parent, range, .skill, null, palette, expand_key);
            }
            for ([_][]const u8{ "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD" }) |resource| {
                if (std.mem.eql(u8, base, resource)) {
                    const label = pathWithin(location.cwd, absolute) orelse absolute;
                    return fileTitle(a, "read resource", label, range, .resource, null, palette, expand_key);
                }
            }
        }
    };
    return ordinaryFileTitle(a, "read", path, range, location, palette);
}

fn pathWithin(parent: []const u8, path: []const u8) ?[]const u8 {
    if (parent.len == 0 or !std.fs.path.isAbsolute(path)) return null;
    const root = std.mem.trimEnd(u8, parent, &.{std.fs.path.sep});
    if (!std.mem.startsWith(u8, path, root)) return null;
    if (path.len == root.len) return ".";
    if (path[root.len] != std.fs.path.sep) return null;
    const relative = std.mem.trimStart(u8, path[root.len..], &.{std.fs.path.sep});
    return if (relative.len == 0) "." else relative;
}

fn shortPath(a: Allocator, raw: []const u8, home: []const u8) ![]const u8 {
    if (home.len == 0 or !std.fs.path.isAbsolute(raw)) return raw;
    const absolute = try std.fs.path.resolveAlloc(a, &.{raw});
    const relative = pathWithin(home, absolute) orelse return raw;
    if (std.mem.eql(u8, relative, ".")) return "~";
    return try std.fmt.allocPrint(a, "~{c}{s}", .{ std.fs.path.sep, relative });
}

fn ordinaryFileTitle(a: Allocator, name: []const u8, path: ?[]const u8, suffix: []const u8, location: paths.Location, palette: *const Theme.Palette) ![]const u8 {
    const raw = path orelse return fileTitle(a, name, null, suffix, .normal, null, palette, "");
    const label = try shortPath(a, raw, location.home);
    const uri = if (raw.len > 0 and location.hyperlinks) make_uri: {
        const absolute = paths.resolve(a, location, raw) catch |err| switch (err) {
            error.InvalidFileUrl => break :make_uri null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :make_uri try paths.fileUri(a, absolute);
    } else null;
    return fileTitle(a, name, label, suffix, .normal, uri, palette, "");
}

fn searchTitle(a: Allocator, name: []const u8, card: *const UiPresentation.SearchCard, args: j.Value, location: paths.Location, palette: *const Theme.Palette) ![]const u8 {
    var title_code: [96]u8 = undefined;
    var output_code: [96]u8 = undefined;
    var pattern_code: [96]u8 = undefined;
    const output = palette.style(.toolOutput).sgr(&output_code);
    const raw = stringArgument(j.get(args, "path"));
    const path = if (raw) |value| if (value.len == 0) "." else try shortPath(a, value, location.home) else "[invalid arg]";
    const count = j.get(args, "limit");
    const suffix = blk: {
        if (count == .null) break :blk "";
        const value = try md.clean(a, try j.encode(a, count));
        break :blk try std.fmt.allocPrint(a, "{s}{s}{s}", .{ card.limit[0], value, card.limit[1] });
    };
    if (card.heading == .file) {
        const heading = try ordinaryFileTitle(a, name, if (raw != null) path else null, "", location, palette);
        return std.fmt.allocPrint(a, "{s}{s}{s}\x1b[0m", .{ heading, output, suffix });
    }
    const pattern = stringArgument(j.get(args, "pattern"));
    const active_pattern_style = if (pattern == null) palette.style(.toolDiffRemoved) else palette.style(.accent);
    const pattern_label = if (pattern) |text|
        if (card.heading == .regex) try std.fmt.allocPrint(a, "/{s}/", .{try md.clean(a, text)}) else try md.clean(a, text)
    else
        "[invalid arg]";
    const glob = if (card.heading == .regex) j.text(j.get(args, "glob")) else "";
    const glob_label = if (glob.len == 0) "" else try std.fmt.allocPrint(a, " ({s})", .{try md.clean(a, glob)});
    return std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}{s}\x1b[0m{s} in {s}{s}{s}\x1b[0m", .{
        bold(palette.style(.toolTitle)).sgr(&title_code), name,                  active_pattern_style.sgr(&pattern_code), pattern_label,
        output,                                           try md.clean(a, path), glob_label,                              suffix,
    });
}

fn appendSearchWarning(a: Allocator, body: *std.ArrayList(tui.Node), policy: *const UiPresentation.SearchCards, card: *const UiPresentation.SearchCard, details: j.Value, style: tui.Style) !void {
    const limit = j.number(j.get(details, card.warning_field));
    const warnings = [_]?[]const u8{
        if (limit != 0) try std.fmt.allocPrint(a, "{d} {s} limit", .{ limit, card.warning_unit }) else null,
        if (j.flag(j.get(j.get(details, "truncation"), "truncated"))) policy.byte_warning else null,
        if (j.flag(j.get(details, "linesTruncated"))) policy.line_warning else null,
    };
    var text: std.Io.Writer.Allocating = .init(a);
    var prefix: []const u8 = "[Truncated: ";
    for (warnings) |warning| {
        try text.writer.print("{s}{s}", .{ prefix, warning orelse continue });
        prefix = ", ";
    }
    if (text.written().len == 0) return;
    try text.writer.writeByte(']');
    try body.append(a, colored(try text.toOwnedSlice(), style));
}

fn fileTitle(a: Allocator, name: []const u8, path: ?[]const u8, suffix: []const u8, kind: FileTitle, uri: ?[]const u8, palette: *const Theme.Palette, expand_key: []const u8) ![]const u8 {
    var title_code: [96]u8 = undefined;
    var path_code: [96]u8 = undefined;
    var suffix_code: [96]u8 = undefined;
    var hint_code: [96]u8 = undefined;
    const raw = path orelse "[invalid arg]";
    const color = if (path == null) palette.style(.toolDiffRemoved) else if (raw.len == 0 or kind == .skill) palette.style(.toolOutput) else palette.style(.accent);
    const label = if (raw.len == 0) "..." else try md.clean(a, raw);
    const display = if (uri) |target| try kit.terminal.hyperlink.wrap(a, label, target) else label;
    return std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}{s}\x1b[0m{s}{s}\x1b[0m{s}{s}{s}{s}\x1b[0m", .{
        bold(if (kind == .skill) palette.style(.accent) else palette.style(.toolTitle)).sgr(&title_code),
        name,
        color.sgr(&path_code),
        display,
        palette.style(.warning).sgr(&suffix_code),
        suffix,
        palette.style(.dim).sgr(&hint_code),
        if (kind == .normal) "" else " (",
        expand_key,
        if (kind == .normal) "" else " to expand)",
    });
}

fn shellTitle(a: Allocator, command: ?[]const u8, args: j.Value, palette: *const Theme.Palette) ![]const u8 {
    var title_code: [96]u8 = undefined;
    var command_code: [96]u8 = undefined;
    var output_code: [96]u8 = undefined;
    const timeout = j.get(args, "timeout");
    const suffix = switch (timeout) {
        .null => "",
        .bool => if (timeout.bool) " (timeout trues)" else "",
        .string => if (timeout.string.len == 0) "" else try std.fmt.allocPrint(a, " (timeout {s}s)", .{try md.clean(a, timeout.string)}),
        .integer, .float, .number_string => block: {
            const value = lineNumber(timeout) orelse break :block "";
            break :block if (value == 0) "" else try std.fmt.allocPrint(a, " (timeout {s}s)", .{try printLineNumber(a, value)});
        },
        .object => " (timeout [object Object]s)",
        .array => " (timeout s)",
    };
    const raw = command orelse "[invalid arg]";
    const color = if (command == null) palette.style(.toolDiffRemoved) else if (raw.len == 0) palette.style(.toolOutput) else palette.style(.toolTitle);
    return std.fmt.allocPrint(a, "{s}$ {s}{s}\x1b[0m{s}{s}\x1b[0m", .{
        bold(palette.style(.toolTitle)).sgr(&title_code),
        bold(color).sgr(&command_code),
        if (raw.len == 0) "..." else try md.clean(a, raw),
        palette.style(.toolOutput).sgr(&output_code),
        suffix,
    });
}

fn genericTitle(a: Allocator, name: []const u8, args: j.Value, expanded: bool, palette: *const Theme.Palette) ![]const u8 {
    var title_code: [96]u8 = undefined;
    const safe = try md.clean(a, name);
    const style = bold(palette.style(.toolTitle)).sgr(&title_code);
    if (args == .null) return std.fmt.allocPrint(a, "{s}{s}\x1b[0m", .{ style, safe });
    const encoded = try std.json.Stringify.valueAlloc(a, args, .{ .whitespace = if (expanded) .indent_2 else .minified });
    const body = try md.clean(a, encoded);
    if (expanded) return std.fmt.allocPrint(a, "{s}{s}\x1b[0m\n{s}", .{ style, safe, body });
    if (body.len <= 100) return std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}", .{ style, safe, body });
    var cut: usize = 97;
    while (body[cut] & 0xc0 == 0x80) cut -= 1;
    return std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}...", .{ style, safe, body[0..cut] });
}

fn colored(text: []const u8, color: tui.Style) tui.Node {
    return .{ .text = .{ .bytes = text, .style = color } };
}

fn outputWithImages(a: Allocator, event: Event) ![]const u8 {
    if (event.images.len == 0) return event.text;
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    const writer = &text.writer;
    try writer.writeAll(event.text);
    for (event.images) |image| {
        if (text.written().len != 0) try writer.writeByte('\n');
        try writeImageLabel(writer, image.mime_type, image.dimensions);
    }
    return text.toOwnedSlice();
}

const Dimensions = kit.media.image_dimensions.Dimensions;

fn writeImageLabel(writer: *std.Io.Writer, mime: []const u8, dimensions: ?Dimensions) !void {
    try writer.print("[Image: [{s}]", .{mime});
    if (dimensions) |size| try writer.print(" {d}x{d}", .{ size.width, size.height });
    try writer.writeByte(']');
}

fn imageLabel(a: Allocator, mime: []const u8, size: Dimensions) ![]const u8 {
    return std.fmt.allocPrint(a, "[Image: [{s}] {d}x{d}]", .{ try md.clean(a, mime), size.width, size.height });
}

fn imageCells(size: Dimensions, columns: u16, layout: ImageLayout) struct { columns: u16, rows: u32 } {
    const max_width: f64 = @floatFromInt(@max(1, @min(columns -| 2, layout.preferred_width)));
    const cell_width: f64 = @floatFromInt(@max(1, layout.cell_width));
    const cell_height: f64 = @floatFromInt(@max(1, layout.cell_height));
    const max_height = @max(1, @ceil(max_width * cell_width / cell_height));
    const width: f64 = @floatFromInt(size.width);
    const height: f64 = @floatFromInt(size.height);
    const width_scale = max_width * cell_width / width;
    const height_scale = max_height * cell_height / height;
    const scale = @min(width_scale, height_scale);
    var fitted_width = @max(1, @min(max_width, @ceil(width * scale / cell_width)));
    var fitted_height = @max(1, @min(max_height, @ceil(height * scale / cell_height)));
    if (layout.protocol == .kitty) {
        if (width_scale <= height_scale) {
            fitted_height = lessDistorted(fitted_height, fitted_width * cell_width * height / (width * cell_height));
        } else {
            fitted_width = lessDistorted(fitted_width, fitted_height * cell_height * width / (height * cell_width));
        }
    }
    return .{ .columns = @intFromFloat(fitted_width), .rows = @intFromFloat(fitted_height) };
}

fn lessDistorted(upper: f64, ideal: f64) f64 {
    if (upper <= 1) return upper;
    const lower = upper - 1;
    return if (@max(lower / ideal, ideal / lower) < @max(upper / ideal, ideal / upper)) lower else upper;
}

const Highlight = struct {
    engine: *Syntax.Engine,
    path: []const u8,
    language: []const u8,
    write_cache: ?*Syntax.WriteCache,

    fn file(engine: *Syntax.Engine, path: ?[]const u8, cache: ?*Syntax.WriteCache) ?Highlight {
        const name = path orelse return null;
        return .{ .engine = engine, .path = name, .language = Syntax.languageForPath(name) orelse return null, .write_cache = cache };
    }

    fn paint(self: Highlight, a: Allocator, raw: []const u8, source: []const u8) ![]const u8 {
        if (self.write_cache) |cache| return cache.paint(self.engine, a, self.path, self.language, raw, source);
        return self.engine.paint(a, source, self.language);
    }
};

fn appendHead(a: Allocator, body: *std.ArrayList(tui.Node), text: []const u8, limit: ?usize, show_total: bool, display: Display, highlight: ?Highlight) !void {
    if (limit == 0) return;
    const source = try plainOutput(a, text);
    const clean = std.mem.trimEnd(u8, if (highlight) |syntax| try syntax.paint(a, text, source) else source, "\n");
    if (clean.len == 0) return;
    try body.append(a, .{ .spacer = 1 });
    const style = if (highlight != null) tui.Style{} else display.theme.style(.toolOutput);
    try appendHeadPreview(a, body, clean, limit, style, display, if (show_total) .logical_with_total else .logical);
}

const PreviewLines = enum { logical, logical_with_total, visual };

fn appendHeadPreview(a: Allocator, body: *std.ArrayList(tui.Node), text: []const u8, limit: ?usize, style: tui.Style, display: Display, mode: PreviewLines) !void {
    const max = limit orelse return body.append(a, colored(text, style));
    if (max == 0) return;
    const end, const remaining = if (mode == .visual) visual: {
        const rows = try tui.layout.visualLines(a, text, @max(1, display.columns -| (2 * display.output_padding)));
        if (rows.len <= max) return body.append(a, colored(text, style));
        break :visual .{ rows[max - 1].end, rows.len - max };
    } else logical: {
        var lines = std.mem.splitScalar(u8, text, '\n');
        for (0..max) |_| if (lines.next() == null) break;
        const next = lines.index orelse return body.append(a, colored(text, style));
        break :logical .{ next - 1, std.mem.count(u8, text[next - 1 ..], "\n") };
    };
    try body.append(a, colored(text[0..end], style));
    const hint_role: Theme.Role = if (mode == .visual) .muted else .toolOutput;
    const hint = if (mode == .logical_with_total)
        try expansionHint(a, display, hint_role, "... ({d} more lines, {d} total, ", .{ remaining, max + remaining })
    else
        try expansionHint(a, display, hint_role, "... ({d} more lines, ", .{remaining});
    var node = colored(hint, display.theme.style(hint_role));
    if (mode == .visual) node.text.overflow = .clip;
    try body.append(a, node);
}

fn expansionHint(a: Allocator, display: Display, role: Theme.Role, comptime prefix: []const u8, args: anytype) ![]const u8 {
    const palette = display.theme;
    var dim_code: [96]u8 = undefined;
    var muted_code: [96]u8 = undefined;
    return std.fmt.allocPrint(a, prefix ++ "{s}{s}{s} to expand)", args ++ .{
        palette.style(.dim).sgr(&dim_code),
        display.presentation.shortcuts.expand_tools.label,
        palette.style(role).sgr(&muted_code),
    });
}

fn appendResult(a: Allocator, body: *std.ArrayList(tui.Node), text: []const u8, color: tui.Style) !void {
    if (text.len == 0) return;
    try body.append(a, .{ .spacer = 1 });
    try body.append(a, colored(try plainOutput(a, text), color));
}

fn readTruncationWarning(a: Allocator, truncation: j.Value) !?[]const u8 {
    if (!j.flag(j.get(truncation, "truncated"))) return null;
    const max_bytes = j.get(truncation, "maxBytes");
    const max_lines = j.get(truncation, "maxLines");
    const shown = j.number(j.get(truncation, "outputLines"));
    if (!j.flag(j.get(truncation, "firstLineExceedsLimit")) and j.equal(j.get(truncation, "truncatedBy"), "lines")) {
        return try std.fmt.allocPrint(a, "[Truncated: showing {d} of {d} lines ({d} line limit)]", .{
            shown, j.number(j.get(truncation, "totalLines")), if (max_lines == .null) 2000 else j.number(max_lines),
        });
    }
    const capacity = try formatByteSize(a, if (max_bytes == .null) 50 * 1024 else j.number(max_bytes));
    return if (j.flag(j.get(truncation, "firstLineExceedsLimit")))
        try std.fmt.allocPrint(a, "[First line exceeds {s} limit]", .{capacity})
    else
        try std.fmt.allocPrint(a, "[Truncated: {d} lines shown ({s} limit)]", .{ shown, capacity });
}

fn formatByteSize(a: Allocator, bytes: u64) ![]const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(a, "{d}B", .{bytes});
    const size: f64 = @floatFromInt(bytes);
    return if (bytes < 1024 * 1024)
        std.fmt.allocPrint(a, "{d:.1}KB", .{size / 1024})
    else
        std.fmt.allocPrint(a, "{d:.1}MB", .{size / (1024 * 1024)});
}

fn shellOutput(text: []const u8, details: j.Value) []const u8 {
    const length = j.get(details, "outputBytes");
    if (length != .integer) return text;
    const end = std.math.cast(usize, length.integer) orelse return text;
    return if (end <= text.len and std.mem.startsWith(u8, text[end..], "\n\n[")) text[0..end] else text;
}

fn scriptOutput(text: []const u8) []const u8 {
    const header = if (std.mem.startsWith(u8, text, "Script completed\nWall time "))
        "Script completed\nWall time "
    else if (std.mem.startsWith(u8, text, "Script failed\nWall time "))
        "Script failed\nWall time "
    else
        return text;
    const rest = text[header.len..];
    const label = " seconds\nOutput:\n";
    const end = std.mem.indexOf(u8, rest, label) orelse return text;
    if (end == 0) return text;
    for (rest[0..end]) |byte| if (!std.ascii.isDigit(byte) and byte != '.') return text;
    return rest[end + label.len ..];
}

fn appendScriptCall(a: Allocator, body: *std.ArrayList(tui.Node), call: j.Value, expanded: bool, theme: *const Theme.Palette) !void {
    const status = j.text(j.get(call, "status"));
    const icon, const role = if (std.mem.eql(u8, status, "ok"))
        .{ "✓", Theme.Role.success }
    else if (std.mem.eql(u8, status, "error"))
        .{ "✗", Theme.Role.@"error" }
    else if (std.mem.eql(u8, status, "cancelled"))
        .{ "⊘", Theme.Role.muted }
    else
        .{ "…", Theme.Role.warning };
    var icon_style: [96]u8 = undefined;
    var title_style: [96]u8 = undefined;
    var muted_style: [96]u8 = undefined;
    var dim_style: [96]u8 = undefined;
    var args = try plainOutput(a, j.text(j.get(call, "args")));
    if (!expanded) {
        const short = utf16Head(args, 80);
        if (short.len < args.len) args = try std.mem.concat(a, u8, &.{ utf16Head(args, 77), "..." });
    }
    const timing = j.get(call, "durationMs");
    const duration = if (timing == .integer and timing.integer >= 0)
        if (timing.integer < 1000)
            try std.fmt.allocPrint(a, " {d}ms", .{timing.integer})
        else
            try std.fmt.allocPrint(a, " {d:.1}s", .{@as(f64, @floatFromInt(timing.integer)) / 1000})
    else
        "";
    const name = try md.clean(a, j.text(j.get(call, "name")));
    try body.append(a, tui.text(try std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}{s}\x1b[0m{s}{s}{s}\x1b[0m{s}{s}\x1b[0m", .{
        theme.style(role).sgr(&icon_style),        icon,
        theme.style(.toolTitle).sgr(&title_style), name,
        theme.style(.muted).sgr(&muted_style),     if (args.len == 0) "" else " ",
        args,                                      theme.style(.dim).sgr(&dim_style),
        duration,
    }), .plain));
    if (expanded) {
        const reason = try plainOutput(a, j.text(j.get(call, "error")));
        if (reason.len == 0) return;
        var lines = std.mem.splitScalar(u8, reason, '\n');
        while (lines.next()) |line| try body.append(a, colored(try std.mem.concat(a, u8, &.{ "    ", line }), theme.style(.@"error")));
    }
}

fn utf16Head(text: []const u8, max: usize) []const u8 {
    var offset: usize = 0;
    var units: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(text[offset..])) |scalar| {
        units += if (scalar.codepoint > 65535) @as(usize, 2) else 1;
        if (units > max) break;
        offset += scalar.len;
    }
    return text[0..offset];
}

fn plainOutput(a: Allocator, text: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        if (kit.terminal.vt_escape.escapeLength(text[at..], .{ .end_of_input = true })) |len| {
            at += len;
            continue;
        }
        if (text[at] == '\t') {
            try bytes.appendSlice(a, "   ");
        } else if (text[at] != '\r') {
            try bytes.append(a, text[at]);
        }
        at += 1;
    }
    return md.clean(a, bytes.items);
}
