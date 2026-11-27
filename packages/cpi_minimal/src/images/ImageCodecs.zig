//! Bounded RGBA decoding and encoding with the vendored native codecs.
const std = @import("std");
const c = @import("image_codecs");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Pixel = [4]u8;
pub const Size = struct { width: u32, height: u32 };
pub const Error = error{ InvalidImage, ImageTooLarge, OutOfMemory, Canceled };

const max_axis = 65535;
const max_pixels = 32 * 1024 * 1024;

pub const Raster = struct {
    size: Size,
    pixels: []Pixel,

    pub fn init(a: Allocator, size: Size) Error!Raster {
        if (size.width == 0 or size.height == 0) return error.InvalidImage;
        if (size.width > max_axis or size.height > max_axis) return error.ImageTooLarge;
        const count = @as(u64, size.width) * size.height;
        if (count > max_pixels) return error.ImageTooLarge;
        return .{ .size = size, .pixels = try a.alloc(Pixel, @intCast(count)) };
    }

    pub fn deinit(image: Raster, a: Allocator) void {
        a.free(image.pixels);
    }

    pub fn row(image: Raster, y: usize) []Pixel {
        const stride: usize = image.size.width;
        return image.pixels[y * stride ..][0..stride];
    }
};

pub fn decode(a: Allocator, io: Io, source: []const u8) Error!Raster {
    try io.checkCancel();
    const image = if (std.mem.startsWith(u8, source, "\x89PNG\r\n\x1a\n"))
        try decodePng(a, io, source)
    else if (std.mem.startsWith(u8, source, "\xff\xd8"))
        try decodeJpeg(a, io, source)
    else if (source.len >= 12 and std.mem.eql(u8, source[0..4], "RIFF") and std.mem.eql(u8, source[8..12], "WEBP"))
        try decodeWebp(a, source)
    else if (std.mem.startsWith(u8, source, "GIF87a") or std.mem.startsWith(u8, source, "GIF89a") or std.mem.startsWith(u8, source, "BM"))
        try decodeStb(a, source)
    else
        return error.InvalidImage;
    errdefer image.deinit(a);
    try io.checkCancel();
    return image;
}

fn pngStatus(status: c_int) Error!void {
    switch (status) {
        c.SPNG_OK => {},
        c.SPNG_EMEM => return error.OutOfMemory,
        c.SPNG_EUSER_WIDTH, c.SPNG_EUSER_HEIGHT => return error.ImageTooLarge,
        else => return error.InvalidImage,
    }
}

fn decodePng(a: Allocator, io: Io, source: []const u8) Error!Raster {
    const ctx = c.spng_ctx_new(0) orelse return error.OutOfMemory;
    defer c.spng_ctx_free(ctx);
    try pngStatus(c.spng_set_image_limits(ctx, max_axis, max_axis));
    try pngStatus(c.spng_set_chunk_limits(ctx, 8 * 1024 * 1024, 32 * 1024 * 1024));
    try pngStatus(c.spng_set_png_buffer(ctx, source.ptr, source.len));
    var header: c.spng_ihdr = undefined;
    try pngStatus(c.spng_get_ihdr(ctx, &header));
    const image = try Raster.init(a, .{ .width = header.width, .height = header.height });
    errdefer image.deinit(a);
    if (header.interlace_method != 0) @memset(image.pixels, @splat(0));
    try pngStatus(c.spng_decode_image(ctx, null, 0, c.SPNG_FMT_RGBA8, c.SPNG_DECODE_TRNS | c.SPNG_DECODE_PROGRESSIVE));
    while (true) {
        try io.checkCancel();
        var info: c.spng_row_info = undefined;
        try pngStatus(c.spng_get_row_info(ctx, &info));
        if (info.row_num >= image.size.height) return error.InvalidImage;
        const row = std.mem.sliceAsBytes(image.row(info.row_num));
        const status = c.spng_decode_row(ctx, row.ptr, row.len);
        if (status == c.SPNG_EOI) break;
        try pngStatus(status);
    }
    return image;
}

pub fn encodePng(a: Allocator, io: Io, image: Raster) Error![]u8 {
    try io.checkCancel();
    const ctx = c.spng_ctx_new(c.SPNG_CTX_ENCODER) orelse return error.OutOfMemory;
    defer c.spng_ctx_free(ctx);
    try pngStatus(c.spng_set_option(ctx, c.SPNG_ENCODE_TO_BUFFER, 1));
    var header: c.spng_ihdr = .{
        .width = image.size.width,
        .height = image.size.height,
        .bit_depth = 8,
        .color_type = c.SPNG_COLOR_TYPE_TRUECOLOR_ALPHA,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };
    try pngStatus(c.spng_set_ihdr(ctx, &header));
    try pngStatus(c.spng_encode_image(ctx, null, 0, c.SPNG_FMT_PNG, c.SPNG_ENCODE_PROGRESSIVE | c.SPNG_ENCODE_FINALIZE));
    for (0..image.size.height) |y| {
        try io.checkCancel();
        const row = std.mem.sliceAsBytes(image.row(y));
        const status = c.spng_encode_row(ctx, row.ptr, row.len);
        if (status == c.SPNG_EOI) break;
        try pngStatus(status);
    }
    var length: usize = 0;
    var status: c_int = 0;
    const output = c.spng_get_png_buffer(ctx, &length, &status);
    try pngStatus(status);
    return takeOutput(a, io, output, length);
}

fn dimensions(width: c_int, height: c_int) Error!Size {
    if (width <= 0 or height <= 0) return error.InvalidImage;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn decodeStb(a: Allocator, source: []const u8) Error!Raster {
    const length = std.math.cast(c_int, source.len) orelse return error.ImageTooLarge;
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.stbi_info_from_memory(source.ptr, length, &width, &height, null) == 0) return error.InvalidImage;
    const image = try Raster.init(a, try dimensions(width, height));
    errdefer image.deinit(a);
    const pixels = c.stbi_load_from_memory(source.ptr, length, &width, &height, null, 4);
    if (pixels == null) {
        const reason = c.stbi_failure_reason();
        if (reason != null and std.mem.eql(u8, std.mem.span(reason), "outofmem")) return error.OutOfMemory;
        return error.InvalidImage;
    }
    defer c.stbi_image_free(pixels);
    if (width != image.size.width or height != image.size.height) return error.InvalidImage;
    const output = std.mem.sliceAsBytes(image.pixels);
    @memcpy(output, pixels[0..output.len]);
    return image;
}

fn webpStatus(status: c.VP8StatusCode) Error!void {
    switch (status) {
        c.VP8_STATUS_OK => {},
        c.VP8_STATUS_OUT_OF_MEMORY => return error.OutOfMemory,
        else => return error.InvalidImage,
    }
}

fn decodeWebp(a: Allocator, source: []const u8) Error!Raster {
    var config: c.WebPDecoderConfig = undefined;
    if (c.WebPInitDecoderConfig(&config) == 0) return error.InvalidImage;
    defer c.WebPFreeDecBuffer(&config.output);
    try webpStatus(c.WebPGetFeatures(source.ptr, source.len, &config.input));
    const image = try Raster.init(a, try dimensions(config.input.width, config.input.height));
    errdefer image.deinit(a);
    const output = std.mem.sliceAsBytes(image.pixels);
    if (config.input.has_animation != 0) {
        const data: c.WebPData = .{ .bytes = source.ptr, .size = source.len };
        const decoder = c.WebPAnimDecoderNew(&data, null) orelse return error.InvalidImage;
        defer c.WebPAnimDecoderDelete(decoder);
        var info: c.WebPAnimInfo = undefined;
        if (c.WebPAnimDecoderGetInfo(decoder, &info) == 0 or
            info.canvas_width != image.size.width or info.canvas_height != image.size.height) return error.InvalidImage;
        var frame: [*c]u8 = null;
        var timestamp: c_int = 0;
        if (c.WebPAnimDecoderGetNext(decoder, &frame, &timestamp) == 0 or frame == null) return error.InvalidImage;
        @memcpy(output, frame[0..output.len]);
    } else {
        config.output.colorspace = c.MODE_RGBA;
        config.output.is_external_memory = 1;
        config.output.u.RGBA = .{ .rgba = output.ptr, .stride = @intCast(image.size.width * @sizeOf(Pixel)), .size = output.len };
        try webpStatus(c.WebPDecode(source.ptr, source.len, &config));
    }
    return image;
}

const JpegRead = struct {
    allocator: Allocator,
    io: Io,
    image: ?Raster = null,
    failure: ?Error = null,

    fn allocate(raw: ?*anyopaque, width: u32, height: u32) callconv(.c) [*c]u8 {
        const context: *JpegRead = @ptrCast(@alignCast(raw.?));
        const image = Raster.init(context.allocator, .{ .width = width, .height = height }) catch |err| {
            context.failure = err;
            return null;
        };
        context.image = image;
        return std.mem.sliceAsBytes(image.pixels).ptr;
    }

    fn cancelled(raw: ?*anyopaque) callconv(.c) bool {
        const context: *JpegRead = @ptrCast(@alignCast(raw.?));
        context.io.checkCancel() catch {
            context.failure = error.Canceled;
            return true;
        };
        return false;
    }
};

fn jpegStatus(status: c_int) Error!void {
    switch (status) {
        c.CPI_JPEG_OK => {},
        c.CPI_JPEG_OUT_OF_MEMORY => return error.OutOfMemory,
        c.CPI_JPEG_STOPPED => return error.Canceled,
        else => return error.InvalidImage,
    }
}

fn decodeJpeg(a: Allocator, io: Io, source: []const u8) Error!Raster {
    var context: JpegRead = .{ .io = io, .allocator = a };
    errdefer if (context.image) |image| image.deinit(a);
    const status = c.cpi_jpeg_decode(source.ptr, source.len, JpegRead.allocate, JpegRead.cancelled, &context);
    if (context.failure) |failure| return failure;
    try jpegStatus(status);
    return context.image orelse error.InvalidImage;
}

fn jpegWriteCancelled(raw: ?*anyopaque) callconv(.c) bool {
    const io: *Io = @ptrCast(@alignCast(raw.?));
    io.checkCancel() catch return true;
    return false;
}

pub fn encodeJpeg(a: Allocator, io: Io, image: Raster, quality: u8) Error![]u8 {
    var context = io;
    var bytes: [*c]u8 = null;
    var size: usize = 0;
    try io.checkCancel();
    try jpegStatus(c.cpi_jpeg_encode(std.mem.sliceAsBytes(image.pixels).ptr, image.size.width, image.size.height, quality, jpegWriteCancelled, &context, &bytes, &size));
    return takeOutput(a, io, bytes, size);
}

fn takeOutput(a: Allocator, io: Io, raw: ?*anyopaque, length: usize) Error![]u8 {
    const ptr = raw orelse return error.InvalidImage;
    defer std.c.free(ptr);
    try io.checkCancel();
    const bytes: [*]const u8 = @ptrCast(ptr);
    return a.dupe(u8, bytes[0..length]);
}
