const std = @import("std");
const gzip = @import("journal_gzip.zig");
const zstd = @import("journal_zstd.zig");
const Allocator = std.mem.Allocator;

pub const Format = enum {
    gzip,
    zstandard,

    pub fn detect(file: std.Io.File, io: std.Io, size: u64) !?Format {
        if (size == 0) return null;
        var prefix: [4]u8 = undefined;
        const wanted: usize = @intCast(@min(size, prefix.len));
        if (try file.readPositionalAll(io, prefix[0..wanted], 0) != wanted) return error.InvalidJournal;
        const bytes = prefix[0..wanted];
        if (std.mem.startsWith(u8, "\x1f\x8b", bytes[0..@min(bytes.len, 2)])) return .gzip;
        if (std.mem.startsWith(u8, zstd.marker[0..4], bytes)) return .zstandard;
        return null;
    }
};

pub const Member = struct { bytes: []u8, length: u64 };

pub const Reader = struct {
    gpa: Allocator,
    io: std.Io,
    file: std.Io.File,
    format: Format,
    decoder: ?zstd.Decoder,
    end: u64,
    offset: u64 = 0,
    incomplete: bool = false,

    pub fn next(self: *Reader, input: *std.Io.File.Reader) !?Member {
        if (self.offset == self.end or self.incomplete) return null;
        try self.io.checkCancel();
        const member = self.read(input, self.offset) catch |err| {
            if (input.err) |failure| return failure;
            if (err != error.IncompleteJournal) return err;
            if (try self.laterMember(self.offset + 1)) return error.InvalidJournal;
            self.incomplete = true;
            return null;
        };
        self.offset += member.length;
        return member;
    }

    pub fn read(self: Reader, input: *std.Io.File.Reader, offset: u64) !Member {
        try input.seekTo(offset);
        const remaining = self.end - offset;
        switch (self.format) {
            .zstandard => {
                const decoded = try self.decoder.?.read(self.gpa, self.io, &input.interface, remaining);
                return .{ .bytes = decoded.bytes, .length = decoded.length };
            },
            .gzip => {
                const header = gzip.parse(&input.interface, self.io) catch |err| switch (err) {
                    error.IncompleteHeader => return error.IncompleteJournal,
                    else => return err,
                };
                try input.seekTo(offset);
                var buffer: [4096]u8 = undefined;
                var limited = input.interface.limited(.limited64(@min(header.length orelse remaining, remaining)), &buffer);
                var decoder: std.compress.flate.Decompress = .init(&limited.interface, .gzip, &.{});
                const bytes = decoder.reader.allocRemaining(self.gpa, .unlimited) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    if (decoder.err != null and decoder.err.? == error.EndOfStream and
                        (header.length == null or header.length.? > remaining))
                        return error.IncompleteJournal;
                    return error.InvalidJournal;
                };
                errdefer self.gpa.free(bytes);
                const consumed = input.logicalPos() - limited.interface.bufferedLen() - offset;
                if (header.length) |length| if (length != consumed) return error.InvalidJournal;
                if (consumed < 18 or decoder.container_metadata.gzip.crc != std.hash.Crc32.hash(bytes) or
                    decoder.container_metadata.gzip.count != @as(u32, @truncate(bytes.len)))
                    return error.InvalidJournal;
                return .{ .bytes = bytes, .length = consumed };
            },
        }
    }

    fn laterMember(self: Reader, start: u64) !bool {
        var position = start;
        var buffer: [4096]u8 = undefined;
        var read_buffer: [4096]u8 = undefined;
        var input = std.Io.File.Reader.initSize(self.file, self.io, &read_buffer, self.end);
        const first: u8 = switch (self.format) {
            .gzip => 0x1f,
            .zstandard => zstd.marker[0],
        };
        while (position < self.end) {
            try self.io.checkCancel();
            const wanted: usize = @intCast(@min(self.end - position, buffer.len));
            const count = try self.file.readPositionalAll(self.io, buffer[0..wanted], position);
            if (count != wanted) return error.InvalidJournal;
            for (buffer[0..count], 0..) |byte, index| {
                if (byte != first) continue;
                const member = self.read(&input, position + index) catch |err| {
                    if (input.err) |failure| return failure;
                    switch (err) {
                        error.IncompleteJournal, error.InvalidJournal => continue,
                        else => return err,
                    }
                };
                self.gpa.free(member.bytes);
                return true;
            }
            position += count;
        }
        return false;
    }
};
