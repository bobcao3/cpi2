const std = @import("std");

pub const expected_bytes = 51200;
pub const expected_lines = 2000;

pub const Result = struct {
    content: []const u8,
    truncated: bool = false,
    truncatedBy: ?[]const u8 = null,
    totalLines: usize,
    totalBytes: usize,
    outputLines: usize,
    outputBytes: usize,
    lastLinePartial: bool = false,
    firstLineExceedsLimit: bool = false,
    maxLines: usize = expected_lines,
    maxBytes: usize = expected_bytes,
};

pub fn read(a: std.mem.Allocator, io: std.Io, file: std.Io.File) !Result {
    return readSnapshot(a, io, file, (try file.stat(io)).size);
}

pub fn readSnapshot(a: std.mem.Allocator, io: std.Io, file: std.Io.File, size: u64) !Result {
    return readRange(a, io, file, 0, size);
}

pub fn readTail(a: std.mem.Allocator, io: std.Io, file: std.Io.File, size: u64) !Result {
    const start = size -| expected_bytes;
    var result = try readRange(a, io, file, start, size);
    result.truncated = start != 0;
    result.totalBytes = @intCast(@min(size, std.math.maxInt(usize)));
    return result;
}

fn readRange(a: std.mem.Allocator, io: std.Io, file: std.Io.File, start: u64, end: u64) !Result {
    const bytes = try a.alloc(u8, std.math.cast(usize, end - start) orelse return error.Overflow);
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try file.readPositional(io, &.{bytes[offset..]}, start + offset);
        if (count == 0) return error.FileChanged;
        offset += count;
    }
    var first: usize = 0;
    if (start != 0) while (first < bytes.len and bytes[first] & 0xc0 == 0x80) {
        first += 1;
    };
    const content = if (first == 0 and std.unicode.utf8ValidateSlice(bytes)) bytes else blk: {
        const decoded = try replacementDecoded(a, bytes[first..]);
        a.free(bytes);
        break :blk decoded;
    };
    const lines = std.mem.count(u8, content, "\n") + @intFromBool(content.len != 0 and content[content.len - 1] != '\n');
    return .{ .content = content, .totalLines = lines, .totalBytes = content.len, .outputLines = lines, .outputBytes = content.len };
}

fn replacementDecoded(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var copied: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const lead = bytes[i];
        const width = if (lead < 0x80) 1 else if (lead >= 0xc2 and lead <= 0xf4) std.unicode.utf8ByteSequenceLength(lead) catch 0 else 0;
        var end = i + 1;
        if (width > 1) {
            const limit = i + @min(@as(usize, width), bytes.len - i);
            while (end < limit) : (end += 1) {
                const byte = bytes[end];
                if (byte & 0xc0 != 0x80) break;
                if (end == i + 1 and ((lead == 0xe0 and byte < 0xa0) or (lead == 0xed and byte > 0x9f) or
                    (lead == 0xf0 and byte < 0x90) or (lead == 0xf4 and byte > 0x8f))) break;
            }
        }
        if (end - i != width) {
            try output.appendSlice(a, bytes[copied..i]);
            try output.appendSlice(a, "\xef\xbf\xbd");
            copied = end;
        }
        i = end;
    }
    try output.appendSlice(a, bytes[copied..]);
    return output.toOwnedSlice(a);
}
