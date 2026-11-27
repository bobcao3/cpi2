//! Keep standard HTTP parsing and let it buffer valid heads and trailers of
//! any allocatable size. Own the read-ahead for the life of the exchange.
const std = @import("std");
const Reader = std.Io.Reader;
const ResponseReader = @This();

pub const expected_bytes = 8192;

allocator: std.mem.Allocator,
source: *Reader = undefined,
interface: Reader = undefined,
initial: [expected_bytes]u8 = undefined,
storage: []u8 = &.{},
failure: ?error{OutOfMemory} = null,

pub fn deinit(self: *ResponseReader) void {
    self.allocator.free(self.storage);
}

pub fn receiveHead(self: *ResponseReader, request: *std.http.Client.Request) !std.http.Client.Response {
    std.debug.assert(!request.keep_alive and request.redirect_behavior == .unhandled);
    self.source = request.reader.in;
    self.interface = .{
        .vtable = &.{ .stream = stream, .readVec = readVec, .rebase = rebase },
        .buffer = &self.initial,
        .seek = 0,
        .end = 0,
    };
    request.reader.in = &self.interface;
    request.reader.max_head_len = std.math.maxInt(usize);
    return request.receiveHead(&.{}) catch |err| return self.failure orelse err;
}

fn stream(input: *Reader, writer: *std.Io.Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const self: *ResponseReader = @fieldParentPtr("interface", input);
    return self.source.stream(writer, limit);
}

fn readVec(input: *Reader, output: [][]u8) Reader.Error!usize {
    const self: *ResponseReader = @fieldParentPtr("interface", input);
    if (output[0].len != 0) return self.source.readVec(output);
    // The stock trailer parser asks for more data only while it has spare
    // capacity. Leave one byte free so its next fill can grow the buffer.
    if (input.end == input.buffer.len - 1) try rebase(input, input.bufferedLen() + 2);
    // Give the parser buffered bytes before waiting on the socket again.
    // An upgraded server may wait for the next request after its head.
    const available = try self.source.peekGreedy(1);
    const count = @min(available.len, input.buffer.len - 1 - input.end);
    @memcpy(input.buffer[input.end..][0..count], available[0..count]);
    self.source.toss(count);
    input.end += count;
    return 0;
}

fn rebase(input: *Reader, capacity: usize) Reader.Error!void {
    const self: *ResponseReader = @fieldParentPtr("interface", input);
    if (capacity > input.buffer.len) {
        const new_length = @max(capacity, input.buffer.len *| 2);
        const allocation = if (self.storage.len == 0)
            self.allocator.alloc(u8, new_length)
        else
            self.allocator.realloc(self.storage, new_length);
        const grown = allocation catch |err| {
            self.failure = err;
            return error.ReadFailed;
        };
        if (self.storage.len == 0) @memcpy(grown[0..input.end], input.buffer[0..input.end]);
        self.storage = grown;
        input.buffer = grown;
    }
    const buffered = input.buffered();
    @memmove(input.buffer[0..buffered.len], buffered);
    input.seek = 0;
    input.end = buffered.len;
}
