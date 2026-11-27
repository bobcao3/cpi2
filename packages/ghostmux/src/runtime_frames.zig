const std = @import("std");
const json_text = @import("json_text");
const wire = @import("wire.zig");
const size = @import("size.zig");

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, measurement: []const u8, expected: u64) ![]u8 {
    var header: [4]u8 = undefined;
    try reader.readSliceAll(&header);
    const length = std.mem.readInt(u32, &header, .big);
    if (length == 0) return error.InvalidFrameSize;
    size.warn(measurement, length, expected);
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    try reader.readSliceAll(bytes);
    return bytes;
}

pub fn encode(allocator: std.mem.Allocator, request: wire.Request) ![]u8 {
    const bytes = try encode_capacity(allocator, request, 256);
    size.warn("request bytes", bytes.len - 4, size.request_bytes);
    return bytes;
}

fn encode_capacity(allocator: std.mem.Allocator, value: anytype, capacity: usize) ![]u8 {
    const frame_capacity: usize = @intCast(@min(@as(u64, std.math.maxInt(u32)) + 4, std.math.maxInt(usize)));
    var buffer = @import("bounded_writer.zig").init(allocator, frame_capacity);
    defer buffer.deinit();
    _ = buffer.writer.writableSliceGreedy(@min(frame_capacity, @max(capacity, 4))) catch return error.OutOfMemory;
    buffer.writer.end = 4;
    std.json.Stringify.value(value, .{}, &buffer.writer) catch {
        return switch (buffer.failure orelse return error.WriteFailed) {
            error.LimitExceeded => error.InvalidFrameSize,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    const length = buffer.writer.end - 4;
    if (length == 0) return error.InvalidFrameSize;
    std.mem.writeInt(u32, buffer.writer.buffer[0..4], @intCast(length), .big);
    return buffer.toOwnedSlice();
}

pub const Shared = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    references: std.atomic.Value(usize) = .init(1),

    pub fn create(allocator: std.mem.Allocator, value: wire.Response) !*Shared {
        const self = try allocator.create(Shared);
        errdefer allocator.destroy(self);
        const capacity = if (value.base64) |encoded| encoded.len +| 512 +| (if (value.uid) |uid| uid.len *| 6 else 0) else 256;
        self.* = .{ .allocator = allocator, .bytes = try encode_capacity(allocator, value, capacity) };
        size.warn("response bytes", self.bytes.len - 4, size.response_bytes);
        return self;
    }

    pub fn retain(self: *Shared) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
    }

    pub fn release(self: *Shared) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

pub fn data(allocator: std.mem.Allocator, uid: []const u8, offset: u64, raw: []const u8) !*Shared {
    const encoder = std.base64.standard.Encoder;
    std.debug.assert(raw.len <= wire.output_chunk);
    var encoded: [encoder.calcSize(wire.output_chunk)]u8 = undefined;
    return Shared.create(allocator, .{ .server_pid = wire.process_id(), .event = "data", .uid = uid, .offset = offset, .next_offset = offset + raw.len, .base64 = encoder.encode(&encoded, raw) });
}

pub fn response(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) !std.json.Parsed(wire.Response) {
    var reader = stream.reader(io, &.{});
    const bytes = try read(allocator, &reader.interface, "response bytes", size.response_bytes);
    defer allocator.free(bytes);
    const parsed = try json_text.parseFromSlice(wire.Response, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.version != wire.protocol_version) return error.ProtocolVersionMismatch;
    return parsed;
}

pub fn watchdog(io: std.Io, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromMilliseconds(wire.timeout_ms), .awake);
    stream.shutdown(io, .both) catch {};
}
