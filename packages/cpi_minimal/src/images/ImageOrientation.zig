//! JPEG and WebP EXIF orientation, applied before computing image limits.
const std = @import("std");
const marker = "Exif\x00\x00";

pub fn read(bytes: []const u8) u8 {
    const exif = if (std.mem.startsWith(u8, bytes, "\xff\xd8"))
        jpeg(bytes)
    else if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"))
        webp(bytes)
    else
        null;
    return tiff(exif orelse return 1) orelse 1;
}

fn jpeg(bytes: []const u8) ?[]const u8 {
    var offset: usize = 2;
    while (offset + 4 <= bytes.len) {
        if (bytes[offset] != 0xff) return null;
        const kind = bytes[offset + 1];
        if (kind == 0xff) {
            offset += 1;
            continue;
        }
        if (kind == 0xda or kind == 0xd9) return null;
        const size = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .big);
        if (size < 2 or size > bytes.len - offset - 2) return null;
        const data = bytes[offset + 4 ..][0 .. size - 2];
        if (kind == 0xe1 and std.mem.startsWith(u8, data, marker)) return data[marker.len..];
        offset += 2 + @as(usize, size);
    }
    return null;
}

fn webp(bytes: []const u8) ?[]const u8 {
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const start = offset + 8;
        if (size > bytes.len - start) return null;
        if (std.mem.eql(u8, bytes[offset..][0..4], "EXIF")) {
            const data = bytes[start..][0..size];
            return if (std.mem.startsWith(u8, data, marker)) data[marker.len..] else data;
        }
        offset = start + size + size % 2;
    }
    return null;
}

fn tiff(bytes: []const u8) ?u8 {
    if (bytes.len < 8) return null;
    const order: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..2], "II")) .little else .big;
    const offset = std.mem.readInt(u32, bytes[4..8], order);
    if (offset > bytes.len - 2) return null;
    const directory = bytes[offset..];
    const count = std.mem.readInt(u16, directory[0..2], order);
    var entries = directory[2..];
    for (0..count) |_| {
        if (entries.len < 12) return null;
        if (std.mem.readInt(u16, entries[0..2], order) == 0x0112) {
            const value = std.mem.readInt(u16, entries[8..10], order);
            if (value < 1 or value > 8) return null;
            return @intCast(value);
        }
        entries = entries[12..];
    }
    return null;
}
