const std = @import("std");
const zstd = @import("zstd");
const Allocator = std.mem.Allocator;

// A standard Zstandard skippable frame carries the compressed size. Its
// checksum distinguishes a damaged length from an incomplete final write.
pub const marker = "\x5a\x2a\x4d\x18\x08\x00\x00\x00";
pub const frame_magic = "\x28\xb5\x2f\xfd";
pub const header_size = marker.len + 8;

fn checked(result: usize, failure: anyerror) !usize {
    if (zstd.ZSTD_isError(result) == 0) return result;
    if (zstd.ZSTD_getErrorCode(result) == zstd.ZSTD_error_memory_allocation) return error.OutOfMemory;
    return failure;
}

pub const Encoder = struct {
    context: *zstd.ZSTD_CCtx,

    pub fn init() !Encoder {
        const context = zstd.ZSTD_createCCtx() orelse return error.OutOfMemory;
        errdefer _ = zstd.ZSTD_freeCCtx(context);
        _ = try checked(zstd.ZSTD_CCtx_setParameter(context, zstd.ZSTD_c_compressionLevel, 1), error.JournalCompressionFailed);
        _ = try checked(zstd.ZSTD_CCtx_setParameter(context, zstd.ZSTD_c_checksumFlag, 1), error.JournalCompressionFailed);
        return .{ .context = context };
    }

    pub fn deinit(self: Encoder) void {
        _ = zstd.ZSTD_freeCCtx(self.context);
    }

    pub fn compress(self: Encoder, a: Allocator, bytes: []const u8) ![]u8 {
        const bound = try checked(zstd.ZSTD_compressBound(bytes.len), error.JournalFramingOverflow);
        if (bound == 0) return error.JournalFramingOverflow;
        const capacity = std.math.add(usize, header_size, bound) catch return error.JournalFramingOverflow;
        const result = try a.alloc(u8, capacity);
        errdefer a.free(result);
        const length = try checked(zstd.ZSTD_compress2(self.context, result[header_size..].ptr, bound, bytes.ptr, bytes.len), error.JournalCompressionFailed);
        const encoded_length = std.math.cast(u32, length) orelse return error.JournalFramingOverflow;
        result[0..marker.len].* = marker.*;
        std.mem.writeInt(u32, result[8..12], encoded_length, .little);
        std.mem.writeInt(u32, result[12..16], std.hash.Crc32.hash(result[0..12]), .little);
        return a.realloc(result, header_size + length);
    }
};

pub const Decoder = struct {
    context: *zstd.ZSTD_DCtx,

    pub fn init() !Decoder {
        return .{ .context = zstd.ZSTD_createDCtx() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: Decoder) void {
        _ = zstd.ZSTD_freeDCtx(self.context);
    }

    pub fn read(self: Decoder, a: Allocator, io: std.Io, input: *std.Io.Reader, remaining: u64) !struct { bytes: []u8, length: u64 } {
        const header = input.takeArray(header_size) catch |err| switch (err) {
            error.EndOfStream => {
                const prefix = input.buffered();
                const common = @min(prefix.len, marker.len);
                if (!std.mem.eql(u8, prefix[0..common], marker[0..common])) return error.InvalidJournal;
                return error.IncompleteJournal;
            },
            else => return err,
        };
        if (!std.mem.eql(u8, header[0..marker.len], marker) or
            std.mem.readInt(u32, header[12..16], .little) != std.hash.Crc32.hash(header[0..12])) return error.InvalidJournal;
        const size = std.mem.readInt(u32, header[8..12], .little);
        if (size < 9) return error.InvalidJournal;
        const length = @as(u64, size) + header_size;
        if (length > remaining) return error.IncompleteJournal;
        const compressed = try a.alloc(u8, size);
        defer a.free(compressed);
        input.readSliceAll(compressed) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidJournal,
            else => return err,
        };
        const bytes = try self.decompress(a, io, compressed);
        return .{ .bytes = bytes, .length = length };
    }

    fn decompress(self: Decoder, a: Allocator, io: std.Io, bytes: []const u8) ![]u8 {
        var header: zstd.ZSTD_FrameHeader = undefined;
        if (try checked(zstd.ZSTD_getFrameHeader(&header, bytes.ptr, bytes.len), error.InvalidJournal) != 0 or
            header.frameType != zstd.ZSTD_frame or header.checksumFlag != 1 or header.dictID != 0 or
            header.frameContentSize >= std.math.maxInt(u64) - 1 or
            try checked(zstd.ZSTD_findFrameCompressedSize(bytes.ptr, bytes.len), error.InvalidJournal) != bytes.len)
            return error.InvalidJournal;
        const size = std.math.cast(usize, header.frameContentSize) orelse return error.InvalidJournal;
        // For large frames, grow after decoding each block so the declared
        // content size alone cannot request an advisory-size allocation.
        if (size > 32 * 1024 * 1024) return self.decompressLarge(a, io, bytes, size);
        const plain = try a.alloc(u8, size);
        errdefer a.free(plain);
        if (try checked(zstd.ZSTD_decompressDCtx(self.context, plain.ptr, plain.len, bytes.ptr, bytes.len), error.InvalidJournal) != size)
            return error.InvalidJournal;
        return plain;
    }

    fn decompressLarge(self: Decoder, a: Allocator, io: std.Io, bytes: []const u8, size: usize) ![]u8 {
        _ = try checked(zstd.ZSTD_DCtx_reset(self.context, zstd.ZSTD_reset_session_only), error.InvalidJournal);
        var source: zstd.ZSTD_inBuffer = .{ .src = bytes.ptr, .size = bytes.len, .pos = 0 };
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(a);
        var block: [128 * 1024]u8 = undefined;
        while (true) {
            try io.checkCancel();
            var destination: zstd.ZSTD_outBuffer = .{ .dst = &block, .size = block.len, .pos = 0 };
            const before = source.pos;
            const remaining = try checked(zstd.ZSTD_decompressStream(self.context, &destination, &source), error.InvalidJournal);
            if (destination.pos > size - plain.items.len) return error.InvalidJournal;
            try plain.appendSlice(a, block[0..destination.pos]);
            if (remaining == 0) break;
            if (source.pos == before and destination.pos == 0) return error.InvalidJournal;
        }
        if (source.pos != bytes.len or plain.items.len != size) return error.InvalidJournal;
        return plain.toOwnedSlice(a);
    }
};
