//! Pi's inline image preparation. The terminal receives display-ready bytes.
const std = @import("std");
const Exif = @import("ImageOrientation.zig");
const Codec = @import("ImageCodecs.zig");
const Transform = @import("ImageRaster.zig");
const Raster = Codec.Raster;
const Size = Codec.Size;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Encoder = std.base64.standard.Encoder;

pub const Limits = struct {
    max_width: u32 = 2000,
    max_height: u32 = 2000,
    max_base64: usize = 9 * 1024 * 1024 / 2,
    jpeg_quality: u8 = 80,

    pub fn forModel(model: ?*const @import("model_registry").Model) Limits {
        var limits: Limits = .{};
        const profile = (model orelse return limits).image_resize orelse return limits;
        limits.max_width = profile.max_width orelse limits.max_width;
        limits.max_height = profile.max_height orelse limits.max_height;
        if (profile.max_bytes) |bytes| limits.max_base64 = std.math.cast(usize, bytes) orelse std.math.maxInt(usize);
        limits.jpeg_quality = profile.jpeg_quality orelse limits.jpeg_quality;
        return limits;
    }
};

pub const Image = struct {
    mime_type: []const u8,
    data_base64: []const u8,
    note: []const u8 = "",
};
pub const Result = union(enum) { image: Image, omitted: []const u8 };
pub const DisplayPng = struct { bytes: []u8, width: u32, height: u32 };

const conversion_error = "[Image omitted: could not be converted to a supported inline image format.]";
const resize_error = "[Image omitted: could not be resized below the inline image size limit.]";

pub const detect = @import("ImageMime.zig").detect;

pub fn processEncoded(a: Allocator, temporary: Allocator, io: Io, source: Image, auto_resize: bool, limits: Limits) !Result {
    try io.checkCancel();
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(source.data_base64) catch return .{ .omitted = resize_error };
    const bytes = try temporary.alloc(u8, size);
    defer temporary.free(bytes);
    decoder.decode(bytes, source.data_base64) catch return .{ .omitted = resize_error };
    return process(a, io, bytes, source.mime_type, auto_resize, limits);
}

pub fn process(a: Allocator, io: Io, bytes: []const u8, mime: []const u8, auto_resize: bool, limits: Limits) !Result {
    const name = std.mem.trim(u8, std.mem.sliceTo(mime, ';'), " \t");
    const normalized_mime = supported(name);
    if (normalized_mime != null and !auto_resize) return .{ .image = .{
        .mime_type = normalized_mime.?,
        .data_base64 = try base64(a, bytes),
    } };
    const failure = if (normalized_mime == null) conversion_error else resize_error;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return prepare(a, scratch.allocator(), io, bytes, name, normalized_mime, auto_resize, limits) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return .{ .omitted = failure },
    };
}

/// Kitty displays the oriented image at its original resolution.
pub fn displayPng(a: Allocator, io: Io, bytes: []const u8) !?DisplayPng {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return preview(a, scratch.allocator(), io, bytes) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return null,
    };
}

fn preview(a: Allocator, scratch: Allocator, io: Io, bytes: []const u8) !DisplayPng {
    const decoded = try Codec.decode(scratch, io, bytes);
    const orientation = Exif.read(bytes);
    const image = if (orientation == 1) decoded else try Transform.orient(scratch, io, decoded, orientation);
    return .{ .bytes = try Codec.encodePng(a, io, image), .width = image.size.width, .height = image.size.height };
}

fn fits(size: Size, bytes: []const u8, limits: Limits) bool {
    return size.width <= limits.max_width and size.height <= limits.max_height and Encoder.calcSize(bytes.len) < limits.max_base64;
}

fn prepare(a: Allocator, scratch: Allocator, io: Io, source: []const u8, source_mime: []const u8, normalized_mime: ?[]const u8, auto_resize: bool, limits: Limits) !Result {
    const decoded = try Codec.decode(scratch, io, source);
    const orientation = Exif.read(source);
    const original: Size = if (orientation >= 5) .{ .width = decoded.size.height, .height = decoded.size.width } else decoded.size;
    if (normalized_mime) |name| {
        if (fits(original, source, limits)) return .{ .image = .{
            .mime_type = name,
            .data_base64 = try base64(a, source),
        } };
    }

    const image = if (orientation == 1) decoded else try Transform.orient(scratch, io, decoded, orientation);
    var mime = normalized_mime orelse "image/png";
    var bytes = if (normalized_mime == null) try Codec.encodePng(scratch, io, image) else source;
    var target = original;
    const resized = auto_resize and !fits(original, bytes, limits);
    if (resized) {
        target = fit(original, limits);
        if (target.width == 0 or target.height == 0) return .{ .omitted = resize_error };
        const candidate = (try resize(scratch, io, image, &target, limits)) orelse return .{ .omitted = resize_error };
        bytes = candidate.bytes;
        mime = candidate.format.mime();
    }
    try io.checkCancel();
    var note: std.Io.Writer.Allocating = .init(scratch);
    if (normalized_mime == null) {
        const name = try std.ascii.allocLowerString(scratch, source_mime);
        try note.writer.print("[Image converted from {s} to {s}.]", .{ name, mime });
    }
    if (resized) {
        if (note.written().len != 0) try note.writer.writeByte('\n');
        const ratio = @as(f64, @floatFromInt(original.width)) / @as(f64, @floatFromInt(target.width));
        try note.writer.print("[Image: original {d}x{d}, displayed at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]", .{
            original.width, original.height, target.width, target.height, ratio,
        });
    }
    return .{ .image = .{ .mime_type = mime, .data_base64 = try base64(a, bytes), .note = try a.dupe(u8, note.written()) } };
}

fn supported(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "image/jpg")) return "image/jpeg";
    for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" }) |mime| {
        if (std.ascii.eqlIgnoreCase(name, mime)) return mime;
    }
    return null;
}

fn base64(a: Allocator, bytes: []const u8) ![]const u8 {
    return Encoder.encode(try a.alloc(u8, Encoder.calcSize(bytes.len)), bytes);
}

const Format = enum {
    png,
    jpeg,

    fn mime(format: Format) []const u8 {
        return if (format == .png) "image/png" else "image/jpeg";
    }
};
const Candidate = struct { format: Format, bytes: []const u8 };

fn resize(a: Allocator, io: Io, image: Raster, size: *Size, limits: Limits) !?Candidate {
    while (true) {
        if (try trySize(a, io, image, size.*, limits)) |value| return value;
        if (size.width == 1 and size.height == 1) return null;
        size.width = @max(1, size.width * 3 / 4);
        size.height = @max(1, size.height * 3 / 4);
    }
}

fn trySize(a: Allocator, io: Io, image: Raster, size: Size, limits: Limits) !?Candidate {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const small = if (image.size.width == size.width and image.size.height == size.height) image else try Transform.resize(temporary, io, image, size);
    const png = try Codec.encodePng(temporary, io, small);
    const jpeg = try Codec.encodeJpeg(temporary, io, small, limits.jpeg_quality);
    const png_size = Encoder.calcSize(png.len);
    const jpeg_size = Encoder.calcSize(jpeg.len);
    if (@min(png_size, jpeg_size) < limits.max_base64) {
        return if (jpeg_size < png_size)
            .{ .bytes = try a.dupe(u8, jpeg), .format = .jpeg }
        else
            .{ .bytes = try a.dupe(u8, png), .format = .png };
    }
    for ([_]u8{ 85, 70, 55, 40 }) |quality| {
        if (quality == limits.jpeg_quality) continue;
        const smaller = try Codec.encodeJpeg(temporary, io, small, quality);
        if (Encoder.calcSize(smaller.len) < limits.max_base64)
            return .{ .bytes = try a.dupe(u8, smaller), .format = .jpeg };
        temporary.free(smaller);
    }
    return null;
}

fn fit(original: Size, limits: Limits) Size {
    var size = original;
    if (size.width > limits.max_width) {
        size.height = scale(size.height, limits.max_width, size.width);
        size.width = limits.max_width;
    }
    if (size.height > limits.max_height) {
        size.width = scale(size.width, limits.max_height, size.height);
        size.height = limits.max_height;
    }
    return size;
}

fn scale(value: u32, target: u32, divisor: u32) u32 {
    return @intCast((@as(u64, value) * target + divisor / 2) / divisor);
}
