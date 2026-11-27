const std = @import("std");

pub fn detect(input: []const u8) ?[]const u8 {
    const bytes = input[0..@min(input.len, 4100)];
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return if (bytes.len >= 4 and bytes[3] == 0xf7) null else "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return if (png(bytes)) "image/png" else null;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (std.mem.startsWith(u8, bytes, "BM") and bmp(bytes)) return "image/bmp";
    return null;
}

fn png(bytes: []const u8) bool {
    if (bytes.len < 16 or std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return false;
    var offset: usize = 8;
    while (offset + 8 <= bytes.len) {
        const kind = bytes[offset + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "acTL")) return false;
        if (std.mem.eql(u8, kind, "IDAT")) break;
        const size = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (offset + 12 > bytes.len or size > bytes.len - offset - 12) break;
        offset += 12 + @as(usize, size);
    }
    return true;
}

fn bmp(bytes: []const u8) bool {
    if (bytes.len < 26) return false;
    const file_size = std.mem.readInt(u32, bytes[2..6], .little);
    const pixel_offset = std.mem.readInt(u32, bytes[10..14], .little);
    const header = std.mem.readInt(u32, bytes[14..18], .little);
    if (file_size != 0 and (file_size < 26 or pixel_offset >= file_size)) return false;
    if (pixel_offset < 14 + @as(u64, header)) return false;
    const fields: usize = if (header == 12) 22 else if (header >= 40 and header <= 124 and bytes.len >= 30) 26 else return false;
    return std.mem.readInt(u16, bytes[fields..][0..2], .little) == 1 and switch (std.mem.readInt(u16, bytes[fields + 2 ..][0..2], .little)) {
        1, 4, 8, 16, 24, 32 => true,
        else => false,
    };
}
