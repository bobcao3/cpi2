const std = @import("std");

pub const Header = struct { length: ?u32 = null };

const HeaderReader = struct {
    reader: *std.Io.Reader,
    io: std.Io,
    crc: std.hash.Crc32 = .init(),
    count: u64 = 0,

    fn byte(self: *HeaderReader) !u8 {
        if (self.count % 4096 == 0) try self.io.checkCancel();
        const value = self.reader.takeByte() catch |err| {
            if (err == error.EndOfStream) return error.IncompleteHeader;
            return err;
        };
        self.crc.update(&.{value});
        self.count += 1;
        return value;
    }

    fn int(self: *HeaderReader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        for (&bytes) |*value| value.* = try self.byte();
        return std.mem.readInt(T, &bytes, .little);
    }
};

pub fn parse(reader: *std.Io.Reader, io: std.Io) !Header {
    var input: HeaderReader = .{ .reader = reader, .io = io };
    for ("\x1f\x8b\x08") |expected| if (try input.byte() != expected) return error.InvalidJournal;
    const flags = try input.byte();
    if (flags & 0xe0 != 0) return error.InvalidJournal;
    for (0..6) |_| _ = try input.byte();
    var result: Header = .{};
    if (flags & 4 != 0) {
        var remaining: usize = try input.int(u16);
        while (remaining != 0) {
            if (remaining < 4) return error.InvalidJournal;
            const first = try input.byte();
            const second = try input.byte();
            const size = try input.int(u16);
            remaining -= 4;
            if (size > remaining) return error.InvalidJournal;
            if (first == 'C' and second == 'P') {
                if (result.length != null or size != 4 or flags & 2 == 0) return error.InvalidJournal;
                if (input.count == 16 and (flags != 6 or remaining != 4)) return error.InvalidJournal;
                result.length = try input.int(u32);
            } else for (0..size) |_| _ = try input.byte();
            remaining -= size;
        }
    }
    for ([_]u8{ 8, 16 }) |flag| {
        if (flags & flag != 0) while (try input.byte() != 0) {};
    }
    if (flags & 2 != 0) {
        const expected: u16 = @truncate(input.crc.final());
        if (try input.int(u16) != expected) return error.InvalidJournal;
    }
    if (result.length) |length| if (length < input.count + 8) return error.InvalidJournal;
    return result;
}

pub fn frame(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    const size = std.math.add(usize, plain.len, 12) catch return error.JournalFramingOverflow;
    const length = std.math.cast(u32, size) orelse return error.JournalFramingOverflow;
    const bytes = try gpa.alloc(u8, size);
    @memcpy(bytes[0..10], plain[0..10]);
    bytes[3] = 6;
    std.mem.writeInt(u16, bytes[10..12], 8, .little);
    @memcpy(bytes[12..14], "CP");
    std.mem.writeInt(u16, bytes[14..16], 4, .little);
    std.mem.writeInt(u32, bytes[16..20], length, .little);
    std.mem.writeInt(u16, bytes[20..22], @truncate(std.hash.Crc32.hash(bytes[0..20])), .little);
    @memcpy(bytes[22..], plain[10..]);
    return bytes;
}
