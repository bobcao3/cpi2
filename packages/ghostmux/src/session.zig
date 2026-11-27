const std = @import("std");
const ghostty = @import("ghostty-vt");
const options = @import("options.zig");
const Self = @This();

allocator: std.mem.Allocator,
terminal: ghostty.Terminal,
stream: ghostty.TerminalStream,
render_state: ghostty.RenderState,

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, config: options.Options) !void {
    self.allocator = allocator;
    self.render_state = .empty;
    self.terminal = try ghostty.Terminal.init(io, allocator, .{
        .cols = config.cols,
        .rows = config.rows,
        .max_scrollback_bytes = config.scrollback_bytes,
        .default_modes = .{ .grapheme_cluster = true },
        .colors = .{
            .foreground = .init(.{ .r = 255, .g = 255, .b = 255 }),
            .background = .init(.{ .r = 0, .g = 0, .b = 0 }),
            .cursor = .unset,
            .palette = .default,
        },
    });
    self.stream = ghostty.TerminalStream.init(.{
        .allocator = allocator,
        .handler = .{ .terminal = &self.terminal },
    });
}

pub fn deinit(self: *Self) void {
    self.render_state.deinit(self.allocator);
    self.stream.deinit();
    self.terminal.deinit(self.allocator);
}

pub fn feed(self: *Self, data: []const u8) !void {
    self.stream.nextSlice(data);
    if (self.stream.handler.semantic_failure) return error.TerminalStateFailure;
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    try options.geometry(cols, rows);
    try self.stream.handler.resize(.{ .cols = cols, .rows = rows });
}

pub const Capture = @import("capture_writer.zig").Capture;

pub fn capture(self: *Self, allocator: std.mem.Allocator, history: bool, join: bool, max_bytes: ?usize) !Capture {
    const pages = &self.terminal.screens.active.pages;
    var formatter = ghostty.formatter.PageListFormatter.init(pages, .{ .emit = .plain, .unwrap = join });
    if (!history) {
        formatter.top_left = pages.getTopLeft(.active);
        formatter.bottom_right = pages.getBottomRight(.active);
    }
    if (max_bytes) |limit| {
        var buffer: [4096]u8 = undefined;
        var writer = @import("capture_writer.zig").init(allocator, limit, &buffer);
        defer writer.deinit();
        formatter.format(&writer.writer) catch return error.OutOfMemory;
        return writer.finish() catch return error.OutOfMemory;
    }
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    formatter.format(&writer.writer) catch return error.OutOfMemory;
    const text = try writer.toOwnedSlice();
    return .{ .text = text, .head_bytes = text.len, .omitted_bytes = 0 };
}
