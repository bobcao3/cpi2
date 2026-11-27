//! Pixel transforms used by Minimal's inline image preparation.
const std = @import("std");
const Codec = @import("ImageCodecs.zig");
const Raster = Codec.Raster;
const Size = Codec.Size;
const Pixel = Codec.Pixel;
const FloatPixel = @Vector(4, f32);
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn orient(a: Allocator, io: Io, input: Raster, orientation: u8) Codec.Error!Raster {
    const size = input.size;
    const output = try Raster.init(a, if (orientation >= 5) .{ .width = size.height, .height = size.width } else size);
    errdefer output.deinit(a);
    for (0..size.height) |y| {
        try io.checkCancel();
        for (input.row(y), 0..) |pixel, x| {
            const to: struct { usize, usize } = switch (orientation) {
                2 => .{ size.width - 1 - x, y },
                3 => .{ size.width - 1 - x, size.height - 1 - y },
                4 => .{ x, size.height - 1 - y },
                5 => .{ y, x },
                6 => .{ size.height - 1 - y, x },
                7 => .{ size.height - 1 - y, size.width - 1 - x },
                8 => .{ y, size.width - 1 - x },
                else => .{ x, y },
            };
            output.row(to[1])[to[0]] = pixel;
        }
    }
    return output;
}

const Span = struct { first: usize, weights: []const f32 };

const Axis = struct {
    source: usize,
    ratio: f32,
    spread: f32,

    fn init(source: usize, target: usize) Axis {
        const ratio = float(source) / float(target);
        return .{ .source = source, .ratio = ratio, .spread = @max(1, ratio) };
    }

    fn bounds(axis: Axis, index: usize) struct { usize, usize } {
        const center = (float(index) + 0.5) * axis.ratio;
        const radius = 3 * axis.spread;
        const start: usize = @intFromFloat(@max(0, @min(float(axis.source - 1), @floor(center - radius))));
        const end: usize = @intFromFloat(@max(float(start + 1), @min(float(axis.source), @ceil(center + radius))));
        return .{ start, end };
    }

    fn fill(axis: Axis, index: usize, first: usize, weights: []f32) void {
        const center = (float(index) + 0.5) * axis.ratio - 0.5;
        var sum: f32 = 0;
        for (weights, first..) |*weight, position| {
            const distance = (float(position) - center) / axis.spread;
            weight.* = if (@abs(distance) < 3) sinc(distance) * sinc(distance / 3) else 0;
            sum += weight.*;
        }
        for (weights) |*weight| weight.* /= sum;
    }
};

fn float(value: usize) f32 {
    return @floatFromInt(value);
}

fn sinc(value: f32) f32 {
    if (value == 0) return 1;
    const angle = value * std.math.pi;
    return @sin(angle) / angle;
}

/// Lanczos3 samples pixel centers, widens its support when downsampling, and
/// normalizes taps at the edges. Keep the vertical pass in float until the
/// horizontal pass rounds to RGBA8. One intermediate row is sufficient.
pub fn resize(a: Allocator, io: Io, input: Raster, size: Size) Codec.Error!Raster {
    const output = try Raster.init(a, size);
    errdefer output.deinit(a);
    if (size.width == input.size.width and size.height == input.size.height) {
        @memcpy(output.pixels, input.pixels);
        return output;
    }

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const horizontal = Axis.init(input.size.width, size.width);
    const vertical = Axis.init(input.size.height, size.height);
    const columns = try temporary.alloc(Span, size.width);
    for (columns, 0..) |*column, x| {
        const first, const end = horizontal.bounds(x);
        const weights = try temporary.alloc(f32, end - first);
        horizontal.fill(x, first, weights);
        column.* = .{ .first = first, .weights = weights };
    }
    const row = try temporary.alloc(FloatPixel, input.size.width);
    const vertical_weights = try temporary.alloc(f32, input.size.height);
    for (0..size.height) |y| {
        try io.checkCancel();
        const first, const end = vertical.bounds(y);
        const weights = vertical_weights[0 .. end - first];
        vertical.fill(y, first, weights);
        @memset(row, @splat(0));
        for (weights, first..) |weight, source_y| {
            try io.checkCancel();
            const factor: FloatPixel = @splat(weight);
            for (row, input.row(source_y)) |*total, source| {
                const channels: @Vector(4, u8) = source;
                total.* += @as(FloatPixel, @floatFromInt(channels)) * factor;
            }
        }
        for (output.row(y), columns) |*pixel, column| {
            var channels: FloatPixel = @splat(0);
            for (column.weights, row[column.first..][0..column.weights.len]) |weight, source| {
                channels += source * @as(FloatPixel, @splat(weight));
            }
            const bounded = @min(@max(channels, @as(FloatPixel, @splat(0))), @as(FloatPixel, @splat(255)));
            const rounded: @Vector(4, u8) = @intFromFloat(@round(bounded));
            pixel.* = rounded;
        }
    }
    return output;
}
