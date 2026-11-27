const std = @import("std");
const kit = @import("kit");
const limits = @import("services").output;
const Allocator = std.mem.Allocator;

pub const Tail = struct { text: []const u8, truncated: bool };

pub fn preview(a: Allocator, raw: []const u8) !Tail {
    var output: Filter = .{ .a = a };
    errdefer output.text.deinit(a);
    try output.append(raw);
    return output.finish();
}

pub fn read(a: Allocator, io: std.Io, path: []const u8, size: u64) !Tail {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var output: Filter = .{ .a = a };
    errdefer output.text.deinit(a);
    var chunk: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const count = try file.readPositional(io, &.{chunk[0..@min(chunk.len, size - offset)]}, offset);
        if (count == 0) return error.FileChanged;
        try output.append(chunk[0..count]);
        offset += count;
    }
    return output.finish();
}

// Keep enough sanitized UTF-8 to distinguish a whole older line from a byte-truncated line.
const Filter = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    dropped: bool = false,
    mode: enum { text, escape, intermediate, csi, osc, control_string } = .text,
    string_escape: bool = false,
    scalar: [4]u8 = undefined,
    scalar_len: usize = 0,
    scalar_width: usize = 0,

    fn append(self: *Filter, bytes: []const u8) !void {
        for (bytes) |byte| switch (self.mode) {
            .text => {
                if (byte == 0x1b) {
                    try self.flushScalar();
                    self.mode = .escape;
                } else try self.appendTextByte(byte);
            },
            .escape => self.mode = switch (byte) {
                '[' => .csi,
                ']' => .osc,
                'P', '_', '^', 'X' => .control_string,
                0x20...0x2f => .intermediate,
                0x1b => .escape,
                else => .text,
            },
            .intermediate => if (byte < 0x20 or byte > 0x2f) {
                self.mode = if (byte == 0x1b) .escape else .text;
            },
            .csi => if (byte == 0x1b or (byte >= 0x40 and byte <= 0x7e)) {
                self.mode = if (byte == 0x1b) .escape else .text;
            },
            .osc, .control_string => {
                if ((self.mode == .osc and byte == 0x07) or (self.string_escape and byte == '\\')) self.mode = .text;
                self.string_escape = self.mode != .text and byte == 0x1b;
            },
        };
    }

    fn appendTextByte(self: *Filter, byte: u8) !void {
        if (self.scalar_len != 0) {
            if (byte & 0xc0 == 0x80) {
                self.scalar[self.scalar_len] = byte;
                self.scalar_len += 1;
                if (self.scalar_len == self.scalar_width) try self.flushScalar();
                return;
            }
            try self.flushScalar();
        }
        if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte <= 0x7f)) {
            return self.keep(&.{byte});
        }
        if (byte < 0x80) return;
        const width = std.unicode.utf8ByteSequenceLength(byte) catch return self.keep("�");
        self.scalar[0] = byte;
        self.scalar_len = 1;
        self.scalar_width = width;
    }

    fn flushScalar(self: *Filter) !void {
        if (self.scalar_len == 0) return;
        const bytes = self.scalar[0..self.scalar_len];
        self.scalar_len = 0;
        const cp = std.unicode.utf8Decode(bytes) catch return self.keep("�");
        if (cp < 0xfff9 or cp > 0xfffb) try self.keep(bytes);
    }

    fn keep(self: *Filter, bytes: []const u8) !void {
        if (self.text.items.len > 2 * limits.expected_bytes) {
            const tail = utf8Tail(self.text.items, limits.expected_bytes + 4);
            @memmove(self.text.items[0..tail.len], tail);
            self.text.items.len = tail.len;
            self.dropped = true;
        }
        try self.text.appendSlice(self.a, bytes);
    }

    fn finish(self: *Filter) !Tail {
        try self.flushScalar();
        const bytes = try self.text.toOwnedSlice(self.a);
        const end = if (std.mem.endsWith(u8, bytes, "\n")) bytes.len - 1 else bytes.len;
        const split = bytes[0..end];
        if (!self.dropped and bytes.len <= limits.expected_bytes and std.mem.count(u8, split, "\n") < limits.expected_lines) {
            return .{ .text = bytes, .truncated = false };
        }

        var line_end = end;
        var start = end;
        var accepted: usize = 0;
        var blank = true;
        while (accepted < limits.expected_lines) : (accepted += 1) {
            const delimiter = std.mem.lastIndexOfScalar(u8, split[0..line_end], '\n');
            const line_start = if (delimiter) |i| i + 1 else 0;
            const line = split[line_start..line_end];
            if (end - line_start > limits.expected_bytes) {
                const room = limits.expected_bytes -| (end - line_end);
                if (accepted == 0 or (blank and !kit.unicode.onlyEcmaWhitespace(line) and room != 0)) start = line_end - utf8Tail(line, room).len;
                break;
            }
            blank = blank and kit.unicode.onlyEcmaWhitespace(line);
            start = line_start;
            line_end = delimiter orelse break;
        }
        return .{ .text = split[start..], .truncated = true };
    }
};

fn utf8Tail(bytes: []const u8, limit: usize) []const u8 {
    var start = bytes.len -| limit;
    while (start < bytes.len and bytes[start] & 0xc0 == 0x80) start += 1;
    return bytes[start..];
}
