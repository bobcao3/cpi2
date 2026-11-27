const std = @import("std");
const kit = @import("kit");
const Allocator = std.mem.Allocator;

pub const Location = struct { cwd: []const u8, home: []const u8, hyperlinks: bool };

pub fn resolve(a: Allocator, location: Location, raw: []const u8) error{ OutOfMemory, InvalidFileUrl }![]const u8 {
    const path = if (std.mem.eql(u8, raw, "~"))
        location.home
    else if (std.mem.startsWith(u8, raw, "~/"))
        try std.fs.path.join(a, &.{ location.home, raw[2..] })
    else if (std.mem.startsWith(u8, raw, "file://"))
        try decodeFileUrl(a, raw["file://".len..])
    else
        raw;
    return std.fs.path.resolveAlloc(a, &.{ location.cwd, path });
}

pub fn resolveRead(a: Allocator, location: Location, raw: []const u8) ![]const u8 {
    const path = if (std.mem.startsWith(u8, raw, "@")) raw[1..] else raw;
    var normalized: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(path[offset..])) |decoded| {
        switch (decoded.codepoint) {
            0x00a0, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => try normalized.append(a, ' '),
            else => try normalized.appendSlice(a, path[offset..][0..decoded.len]),
        }
        offset += decoded.len;
    }
    return resolve(a, location, normalized.items);
}

fn decodeFileUrl(a: Allocator, raw: []const u8) ![]const u8 {
    // The URL input syntax treats literal backslashes as separators and skips
    // literal tabs and line breaks. Percent-encoded bytes remain in the path.
    var end = raw.len;
    while (end > 0 and raw[end - 1] <= ' ') end -= 1;
    var url: std.ArrayList(u8) = .empty;
    for (raw[0..end]) |byte| {
        switch (byte) {
            '\t', '\r', '\n' => {},
            '\\' => try url.append(a, '/'),
            else => try url.append(a, byte),
        }
    }
    const body = url.items[0 .. std.mem.indexOfAny(u8, url.items, "?#") orelse url.items.len];
    const slash = std.mem.indexOfScalar(u8, body, '/') orelse body.len;
    const host = try decodeUrlPart(a, body[0..slash]);
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.InvalidFileUrl;
    return if (slash == body.len) "/" else decodeUrlPart(a, body[slash..]);
}

fn decodeUrlPart(a: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        i += 1;
        if (byte != '%') {
            try output.append(a, byte);
            continue;
        }
        if (text.len - i < 2) return error.InvalidFileUrl;
        const high = std.fmt.charToDigit(text[i], 16) catch return error.InvalidFileUrl;
        const low = std.fmt.charToDigit(text[i + 1], 16) catch return error.InvalidFileUrl;
        const decoded = high << 4 | low;
        if (decoded == '/') return error.InvalidFileUrl;
        try output.append(a, decoded);
        i += 2;
    }
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.InvalidFileUrl;
    return output.items;
}

pub fn fileUri(a: Allocator, path: []const u8) ![]const u8 {
    var uri: std.Io.Writer.Allocating = .init(a);
    defer uri.deinit();
    uri.writer.writeAll("file://") catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(&uri.writer, path, fileUriPathByte) catch return error.OutOfMemory;
    return uri.toOwnedSlice();
}

fn fileUriPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!$&'()*+,-./:;=@_", byte) != null;
}
