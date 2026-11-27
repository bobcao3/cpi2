const std = @import("std");
const ghostty = @import("ghostty-vt");
const font = @import("font.zig");
const png = @import("png.zig");
const size = @import("size.zig");
const RGB = ghostty.color.RGB;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    engine: ?font.Engine = null,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.engine) |*engine| engine.deinit();
    }

    pub fn screenshot(self: *Renderer, io: std.Io, state: *ghostty.RenderState, terminal: *ghostty.Terminal, path: []const u8, font_size: u16) !void {
        const allocator = self.allocator;
        if (self.engine == null) self.engine = try font.Engine.init(allocator);
        const engine = &self.engine.?;
        defer engine.finish();
        size.warn("screenshot font size", font_size, 96);
        const metrics = try engine.metrics(font_size);
        if (state.cols != terminal.screens.active.pages.cols or state.rows != terminal.screens.active.pages.rows) {
            state.deinit(allocator);
            state.* = .empty;
        }
        errdefer {
            state.deinit(allocator);
            state.* = .empty;
        }
        try state.update(allocator, terminal);
        if (state.rows == 0 or state.cols == 0) return error.EmptyViewport;
        const width = try std.math.mul(usize, state.cols, metrics.width);
        const height = try std.math.mul(usize, state.rows, metrics.height);
        const count = try std.math.mul(usize, width, height);
        const byte_count = try std.math.mul(usize, count, 3);
        size.warn("screenshot width", width, 8192);
        size.warn("screenshot height", height, 8192);
        size.warn("screenshot pixel bytes", byte_count, 128 * 1024 * 1024);
        const png_width = std.math.cast(u31, width) orelse return error.UnrepresentableImageDimensions;
        const png_height = std.math.cast(u31, height) orelse return error.UnrepresentableImageDimensions;
        const pixels = try allocator.alloc(u8, byte_count);
        defer allocator.free(pixels);
        const rows = state.row_data.items(.cells);
        var input: std.ArrayList(font.Input) = .empty;
        defer input.deinit(allocator);
        for (0..state.rows) |y| {
            const cells = rows[state.viewportStart() + y].slice();
            const raw = cells.items(.raw);
            const styles = cells.items(.style);
            for (0..state.cols) |x| {
                const source = if (raw[x].wide == .spacer_tail and x > 0 and raw[x - 1].wide == .wide) x - 1 else x;
                const style: ghostty.Style = if (raw[source].style_id == 0) .{} else styles[source];
                const colors = cellColors(state, raw[source], style, source, y);
                fill(pixels, width, x * metrics.width, y * metrics.height, metrics.width, metrics.height, colors.bg);
            }
        }
        for (0..state.rows) |y| {
            const cells = rows[state.viewportStart() + y].slice();
            const raw = cells.items(.raw);
            const styles = cells.items(.style);
            const graphemes = cells.items(.grapheme);
            input.clearRetainingCapacity();
            var start: usize = 0;
            var end: usize = 0;
            var face_index: usize = 0;
            var run_style: ghostty.Style = .{};
            var run_ink: RGB = undefined;
            for (0..state.cols) |x| {
                const cell = raw[x];
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
                const style: ghostty.Style = if (cell.style_id == 0) .{} else styles[x];
                const colors = cellColors(state, cell, style, x, y);
                const trailing: []const u21 = if (cell.content_tag == .codepoint_grapheme) graphemes[x] else &.{};
                const point_count: usize = if (cell.hasText() and !style.flags.invisible) trailing.len + 1 else 0;
                size.warn("grapheme codepoints", point_count, font.run_points);
                const chosen = if (point_count > 0) engine.choose(cell.codepoint(), trailing, style.flags.bold) else 0;
                const ink = faintColor(colors.fg, colors.bg, style.flags.faint);
                if (input.items.len > 0 and (point_count == 0 or x != end or x - start + (if (cell.wide == .wide) @as(usize, 2) else 1) > font.max_run_cells or
                    input.items.len + point_count > font.run_points or chosen != face_index or !std.meta.eql(style, run_style) or !std.meta.eql(ink, run_ink)))
                {
                    try engine.draw(pixels, width, height, start * metrics.width, y * metrics.height, end - start, input.items, face_index, run_style.flags.italic, metrics, .{ run_ink.r, run_ink.g, run_ink.b });
                    input.clearRetainingCapacity();
                }
                if (point_count == 0) continue;
                if (input.items.len == 0) {
                    start = x;
                    face_index = chosen;
                    run_style = style;
                    run_ink = ink;
                }
                const points = try input.addManyAsSlice(allocator, point_count);
                points[0] = .{ .point = cell.codepoint(), .cell = @intCast(x - start) };
                for (points[1..], trailing) |*item, point| item.* = .{ .point = point, .cell = @intCast(x - start) };
                end = x + (if (cell.wide == .wide and x + 1 < state.cols) @as(usize, 2) else 1);
            }
            if (input.items.len > 0) try engine.draw(pixels, width, height, start * metrics.width, y * metrics.height, end - start, input.items, face_index, run_style.flags.italic, metrics, .{ run_ink.r, run_ink.g, run_ink.b });
            for (0..state.cols) |x| {
                const cell = raw[x];
                if (cell.wide == .spacer_tail) continue;
                const style: ghostty.Style = if (cell.style_id == 0) .{} else styles[x];
                const colors = cellColors(state, cell, style, x, y);
                const span: usize = if (cell.wide == .wide and x + 1 < state.cols) 2 else 1;
                const line_color = style.underlineColor(&state.colors.palette) orelse colors.fg;
                if (style.flags.underline != .none) {
                    const line_y = y * metrics.height + @min(metrics.height - 1, @as(usize, @intFromFloat(@floor(metrics.baseline + 2))));
                    line(pixels, width, x * metrics.width, line_y, span * metrics.width, line_color);
                    if (style.flags.underline == .double and line_y + 2 < (y + 1) * metrics.height) line(pixels, width, x * metrics.width, line_y + 2, span * metrics.width, line_color);
                }
                if (style.flags.strikethrough) line(pixels, width, x * metrics.width, y * metrics.height + metrics.height / 2, span * metrics.width, colors.fg);
                if (style.flags.overline) line(pixels, width, x * metrics.width, y * metrics.height, span * metrics.width, colors.fg);
            }
        }
        engine.finish();
        try png.write(allocator, io, path, png_width, png_height, pixels);
    }
};

fn faintColor(fg: RGB, bg: RGB, faint: bool) RGB {
    if (!faint) return fg;
    return .{ .r = @intCast((@as(u16, fg.r) + bg.r) / 2), .g = @intCast((@as(u16, fg.g) + bg.g) / 2), .b = @intCast((@as(u16, fg.b) + bg.b) / 2) };
}

fn cellColors(state: *const ghostty.RenderState, cell: anytype, style: ghostty.Style, x: usize, y: usize) struct { fg: RGB, bg: RGB } {
    var fg = style.fg(.{ .default = state.colors.foreground, .palette = &state.colors.palette });
    var bg = style.bg(&cell, &state.colors.palette) orelse state.colors.background;
    if (style.flags.inverse) std.mem.swap(RGB, &bg, &fg);
    const cursor = state.cursor.viewport;
    if (state.cursor.visible and cursor != null and cursor.?.y == y and state.cursor.visual_style == .block and
        (cursor.?.x == x or (cell.wide == .wide and cursor.?.wide_tail and cursor.?.x == x + 1)))
    {
        const cursor_color = state.colors.cursor orelse fg;
        fg = bg;
        bg = cursor_color;
    }
    return .{ .fg = fg, .bg = bg };
}

fn fill(pixels: []u8, image_width: usize, left: usize, top: usize, width: usize, height: usize, rgb: RGB) void {
    for (top..top + height) |y| for (left..left + width) |x| {
        pixels[(y * image_width + x) * 3 ..][0..3].* = .{ rgb.r, rgb.g, rgb.b };
    };
}

fn line(pixels: []u8, image_width: usize, left: usize, y: usize, width: usize, rgb: RGB) void {
    for (left..left + width) |x| pixels[(y * image_width + x) * 3 ..][0..3].* = .{ rgb.r, rgb.g, rgb.b };
}
