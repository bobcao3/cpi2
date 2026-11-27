const std = @import("std");
const j = @import("../json.zig");
const ImageProcessing = @import("ImageProcessing.zig");

/// Image payloads live in the entry's attachment list. Embedded blocks keep
/// their position in result.content and refer to that list by one-based index.
pub fn normalize(a: std.mem.Allocator, temporary: std.mem.Allocator, io: std.Io, result: *j.Value, captured: j.Value, auto_resize: bool, limits: ImageProcessing.Limits) !?j.Value {
    const blocks = j.items(j.get(result.*, "content"));
    const emitted = j.items(captured);
    const first = if (isEnvelope(result.*)) for (blocks, 0..) |block, i| {
        if (isImage(block)) break i;
    } else blocks.len else blocks.len;
    if (first == blocks.len and emitted.len == 0) return null;

    var images = j.array(a);
    if (first < blocks.len) {
        var content = j.array(a);
        try content.array.appendSlice(blocks[0..first]);
        for (blocks[first..]) |block| {
            if (!isImage(block)) {
                try content.array.append(block);
                continue;
            }
            const image = try process(a, temporary, io, j.get(block, "mimeType").string, j.get(block, "data").string, auto_resize, limits);
            try images.array.append(try attachment(a, image, true));
            try content.array.append(try j.value(a, .{ .type = "image", .image_index = images.array.items.len }));
            if (image.note.len != 0) try content.array.append(try j.value(a, .{ .type = "text", .text = image.note }));
        }
        result.object = try result.object.clone(a);
        try j.put(a, result, "content", content);
    }
    for (emitted) |block| {
        const image = try process(a, temporary, io, j.text(j.get(block, "mime_type")), j.text(j.get(block, "data_base64")), auto_resize, limits);
        try images.array.append(try attachment(a, image, false));
    }
    return images;
}

fn isEnvelope(result: j.Value) bool {
    if (result != .object or j.get(result, "content") != .array) return false;
    if (j.get(result, "details") != .null or j.get(result, "isError") != .null or j.get(result, "_meta") != .null) return true;
    for (result.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "content") and !std.mem.eql(u8, key, "structuredContent")) return false;
    }
    const content = j.items(j.get(result, "content"));
    return j.get(result, "structuredContent") != .null or (content.len != 0 and j.get(content[0], "type") == .string);
}

fn isImage(block: j.Value) bool {
    return j.equal(j.get(block, "type"), "image") and j.get(block, "data") == .string and j.get(block, "mimeType") == .string;
}

fn attachment(a: std.mem.Allocator, image: ImageProcessing.Image, embedded: bool) !j.Value {
    var out = j.object();
    try j.put(a, &out, "mime_type", j.string(image.mime_type));
    try j.put(a, &out, "data_base64", j.string(image.data_base64));
    if (embedded) {
        try j.put(a, &out, "embedded", .{ .bool = true });
    } else if (image.note.len != 0) {
        try j.put(a, &out, "note", j.string(image.note));
    }
    return out;
}

fn process(a: std.mem.Allocator, temporary: std.mem.Allocator, io: std.Io, mime: []const u8, encoded: []const u8, auto_resize: bool, limits: ImageProcessing.Limits) !ImageProcessing.Image {
    const source: ImageProcessing.Image = .{ .mime_type = mime, .data_base64 = encoded };
    return switch (try ImageProcessing.processEncoded(a, temporary, io, source, auto_resize, limits)) {
        .image => |image| image,
        .omitted => source,
    };
}
