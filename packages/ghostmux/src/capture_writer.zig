const std = @import("std");
const Self = @This();

pub const Capture = struct { text: []const u8, head_bytes: usize, omitted_bytes: usize };

allocator: std.mem.Allocator,
limit: usize,
writer: std.Io.Writer,
head: std.ArrayList(u8) = .empty,
tail: std.ArrayList(u8) = .empty,
tail_start: usize = 0,
total: usize = 0,

pub fn init(allocator: std.mem.Allocator, limit: usize, buffer: []u8) Self {
    return .{ .allocator = allocator, .limit = limit, .writer = .{
        .buffer = buffer,
        .vtable = &.{ .drain = drain },
    } };
}

pub fn deinit(self: *Self) void {
    self.head.deinit(self.allocator);
    self.tail.deinit(self.allocator);
}

fn append(self: *Self, bytes: []const u8) !void {
    self.total += bytes.len;
    const head_count = @min(bytes.len, self.limit / 2 - self.head.items.len);
    try self.head.appendSlice(self.allocator, bytes[0..head_count]);
    var rest = bytes[head_count..];
    const tail_limit = self.limit - self.limit / 2;
    if (tail_limit == 0) return;
    const fill = @min(rest.len, tail_limit - self.tail.items.len);
    try self.tail.appendSlice(self.allocator, rest[0..fill]);
    rest = rest[fill..];
    if (rest.len >= tail_limit) {
        @memcpy(self.tail.items, rest[rest.len - tail_limit ..]);
        self.tail_start = 0;
    } else if (rest.len > 0) {
        const first = @min(rest.len, tail_limit - self.tail_start);
        @memcpy(self.tail.items[self.tail_start..][0..first], rest[0..first]);
        @memcpy(self.tail.items[0 .. rest.len - first], rest[first..]);
        self.tail_start = (self.tail_start + rest.len) % tail_limit;
    }
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Self = @fieldParentPtr("writer", writer);
    self.append(writer.buffered()) catch return error.WriteFailed;
    writer.end = 0;
    var count: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        self.append(bytes) catch return error.WriteFailed;
        count += bytes.len;
    }
    const pattern = data[data.len - 1];
    if (pattern.len > 0) for (0..splat) |_| {
        self.append(pattern) catch return error.WriteFailed;
        count += pattern.len;
    };
    return count;
}

pub fn finish(self: *Self) !Capture {
    try self.writer.flush();
    std.mem.rotate(u8, self.tail.items, self.tail_start);
    var head = self.head.items;
    var tail = self.tail.items;
    if (self.total > self.limit) {
        if (head.len > 0) {
            var last = head.len - 1;
            while (last > 0 and head[last] & 0xc0 == 0x80) last -= 1;
            const width = std.unicode.utf8ByteSequenceLength(head[last]) catch 1;
            if (head.len - last < width) head = head[0..last];
        }
        var start: usize = 0;
        while (start < tail.len and tail[start] & 0xc0 == 0x80) start += 1;
        tail = tail[start..];
    }
    const text = try self.allocator.alloc(u8, head.len + tail.len);
    @memcpy(text[0..head.len], head);
    @memcpy(text[head.len..], tail);
    return .{
        .text = text,
        .head_bytes = if (self.total <= self.limit) text.len else head.len,
        .omitted_bytes = self.total - text.len,
    };
}
