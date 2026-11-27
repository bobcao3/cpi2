const std = @import("std");
const kit = @import("kit");
const Theme = @import("../style.zig").Theme;
const tui = kit.tui;
const Controller = @import("../../session.zig").Controller;
const Record = Controller.UserShell;
const markdown = @import("markdown.zig");
const UiWake = @import("../UiWake.zig");

pub const Prefix = struct {
    command: []const u8,
    excluded: bool,

    pub fn parse(text: []const u8) ?Prefix {
        const input = skipWhitespace(text);
        if (!std.mem.startsWith(u8, input, "!")) return null;
        const excl = std.mem.startsWith(u8, input, "!!");
        const command = skipWhitespace(input[if (excl) 2 else 1..]);
        var end = command.len;
        while (end != 0) {
            var last = end - 1;
            while (last != 0 and command[last] & 0xc0 == 0x80) last -= 1;
            const scalar = kit.unicode.decodeUtf8Lossy(command[last..end]).?;
            if (!kit.unicode.isEcmaWhitespace(scalar.codepoint)) break;
            end = last;
        }
        return .{ .command = command[0..end], .excluded = excl };
    }

    fn skipWhitespace(text: []const u8) []const u8 {
        var remaining = text;
        while (kit.unicode.decodeUtf8Lossy(remaining)) |scalar| {
            if (!kit.unicode.isEcmaWhitespace(scalar.codepoint)) break;
            remaining = remaining[scalar.len..];
        }
        return remaining;
    }
};

pub const Job = struct {
    controller: *Controller,
    wake: *UiWake,
    arena: std.heap.ArenaAllocator,
    prefix: Prefix,
    cwd: []const u8,
    id: [32]u8,
    started: std.Io.Timestamp,
    future: std.Io.Future(void) = undefined,
    done: std.Io.Event = .unset,
    result: anyerror!Record = undefined,
    deferred: bool,

    pub fn start(a: std.mem.Allocator, controller: *Controller, wake: *UiWake, prefix: Prefix, deferred: bool) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        const io = wake.io;
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        job.* = .{
            .controller = controller,
            .wake = wake,
            .arena = .init(a),
            .prefix = prefix,
            .cwd = controller.settings.workspace,
            .id = std.fmt.bytesToHex(nonce, .lower),
            .started = .now(io, .awake),
            .deferred = deferred,
        };
        errdefer job.arena.deinit();
        job.prefix.command = try job.arena.allocator().dupe(u8, prefix.command);
        job.future = try io.concurrent(work, .{job});
        return job;
    }

    fn work(self: *Job) void {
        self.result = self.run();
        self.done.set(self.wake.io);
        self.wake.notify();
    }

    fn run(self: *Job) !Record {
        const a = self.arena.allocator();
        const output = try self.controller.runUserShell(a, &self.id, self.cwd, self.prefix.command);
        return Record.fromCapture(a, self.wake.io, self.prefix.command, self.prefix.excluded, output);
    }

    pub fn destroy(self: *Job, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn preview(self: *const Job, a: std.mem.Allocator) !Record {
        const output = try self.controller.userShellProgress(a, &self.id);
        return Record.preview(a, self.prefix.command, self.prefix.excluded, output);
    }
};

pub const Display = struct {
    columns: u16,
    padding: u16,
    expanded: bool,
    palette: *const Theme.Palette,
    expand_key: []const u8,
    collapsed_rows: usize,
};

pub fn render(a: std.mem.Allocator, record: Record, display: Display, spinner: ?[]const u8) !tui.Node {
    const palette = display.palette;
    const pending = spinner != null;
    const border = palette.style(if (record.excluded) .dim else .bashMode);
    const muted = palette.style(.muted);
    const warning = palette.style(.warning);
    const rule: tui.Node = .{ .text = .{ .bytes = try markdown.horizontalRule(a, display.columns), .style = border, .overflow = .clip } };
    var body: std.ArrayList(tui.Node) = .empty;
    const command = try markdown.clean(a, record.command);
    var header = border;
    header.bold = true;
    try body.append(a, .{ .text = .{ .bytes = try std.fmt.allocPrint(a, "$ {s}", .{command}), .style = header } });
    var hidden_lines: usize = 0;
    if (record.result.output.len != 0) {
        const spaced = try std.mem.replaceOwned(u8, a, record.result.output, "\t", "   ");
        const output = try markdown.clean(a, spaced);
        hidden_lines = (1 + std.mem.count(u8, output, "\n")) -| display.collapsed_rows;
        try appendOutput(a, &body, output, display.columns -| (2 * display.padding), if (display.expanded) null else display.collapsed_rows, palette, null);
    }
    if (pending) {
        var sgr: [96]u8 = undefined;
        var muted_sgr: [96]u8 = undefined;
        const tint = border.sgr(&sgr);
        const message = try std.fmt.allocPrint(a, "{s}{s}\x1b[22;39m {s}Running... (escape/ctrl+c to cancel)", .{ tint, spinner.?, muted.sgr(&muted_sgr) });
        try body.append(a, .{ .text = .{ .bytes = message } });
    } else {
        const code = record.result.exit_code orelse 0;
        if (hidden_lines != 0 or record.result.cancelled or code != 0 or record.result.truncated) try body.append(a, .{ .spacer = 1 });
        if (hidden_lines != 0) {
            const hint = if (display.expanded) try std.fmt.allocPrint(a, "({s} to collapse)", .{display.expand_key}) else try std.fmt.allocPrint(a, "... {d} more lines ({s} to expand)", .{ hidden_lines, display.expand_key });
            try body.append(a, .{ .text = .{ .bytes = hint, .style = muted } });
        }
        if (record.result.cancelled) {
            try body.append(a, .{ .text = .{ .bytes = "(cancelled)", .style = warning } });
        } else if (code != 0) {
            try body.append(a, .{ .text = .{ .bytes = try std.fmt.allocPrint(a, "(exit {d})", .{code}), .style = palette.style(.@"error") } });
        }
        if (record.result.truncated) try body.append(a, .{ .text = .{ .bytes = try record.truncationNote(a), .style = warning } });
    }
    return .{ .stack = .{ .children = try a.dupe(tui.Node, &.{
        .{ .spacer = 1 },
        rule,
        .{ .box = .{ .children = body.items, .padding = .{ .left = display.padding, .right = display.padding } } },
        rule,
    }) } };
}

pub fn appendOutput(a: std.mem.Allocator, body: *std.ArrayList(tui.Node), output: []const u8, width: u16, limit: ?usize, palette: *const Theme.Palette, tool_expand_key: ?[]const u8) !void {
    if (limit == 0) return;
    const style = palette.style(if (tool_expand_key != null) .toolOutput else .muted);
    if (limit == null or tool_expand_key != null) try body.append(a, .{ .spacer = 1 });
    const max = limit orelse return body.append(a, .{ .text = .{ .bytes = output, .style = style } });
    const text = if (tool_expand_key == null) try std.fmt.allocPrint(a, "\n{s}", .{tailLines(output, max)}) else output;
    const rows = try tui.layout.visualLines(a, text, @max(1, width));
    const first = rows.len -| max;
    if (first != 0) if (tool_expand_key) |key| {
        var dim_buffer: [96]u8 = undefined;
        var output_buffer: [96]u8 = undefined;
        const hint = try std.fmt.allocPrint(a, "... ({d} earlier lines, {s}{s}{s} to expand)", .{
            first, palette.style(.dim).sgr(&dim_buffer), key, style.sgr(&output_buffer),
        });
        try body.append(a, .{ .text = .{ .bytes = hint, .style = style, .overflow = .clip } });
    };
    for (rows[first..]) |row| {
        try body.append(a, if (tool_expand_key == null and row.start == row.end) .{ .spacer = 1 } else .{ .text = .{
            .bytes = text[row.start..row.end],
            .style = style,
            .overflow = .clip,
        } });
    }
}

fn tailLines(output: []const u8, max_lines: usize) []const u8 {
    var end = output.len;
    var remaining = max_lines;
    while (end != 0) {
        end -= 1;
        if (output[end] != '\n') continue;
        remaining -= 1;
        if (remaining == 0) return output[end + 1 ..];
    }
    return output;
}
