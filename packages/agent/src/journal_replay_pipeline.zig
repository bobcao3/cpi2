const std = @import("std");
const protocol = @import("session_protocol");
const tracing = @import("kit").tracing;
const members = @import("journal_members.zig");
const zstd = @import("journal_zstd.zig");
const Transaction = protocol.Transaction;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const members_per_chunk = 16;
const target_chunk_bytes = 1024 * 1024;

const DecodedChunk = struct {
    items: [members_per_chunk]members.Member = undefined,
    count: usize = 0,

    fn releaseFrom(self: *const DecodedChunk, gpa: Allocator, first: usize) void {
        for (self.items[first..self.count]) |member| gpa.free(member.bytes);
    }
};

const ParsedMember = struct { transaction: Transaction, length: u64 };
const ParsedChunk = struct {
    items: [members_per_chunk]ParsedMember = undefined,
    count: usize = 0,

    fn releaseFrom(self: *ParsedChunk, first: usize) void {
        for (self.items[first..self.count]) |*member| member.transaction.deinit();
    }
};

const DecodedQueue = Io.Queue(DecodedChunk);
const ParsedQueue = Io.Queue(ParsedChunk);
pub const ParseOptions = struct {
    session_id: []const u8,
    first_sequence: u64,
    limits: Transaction.Limits,
    size_warnings: ?Transaction.SizeSink,
};

const DecoderResult = struct {
    incomplete: bool = false,
    bytes: u64 = 0,
    ns: i96 = 0,
    chunks: usize = 0,
};
const ParserResult = struct { frames: usize = 0, ns: i96 = 0 };
pub const Result = struct { decode: DecoderResult, parse: ParserResult };

fn mark(io: Io, profile: bool) ?Io.Timestamp {
    return if (profile) .now(io, .awake) else null;
}

fn elapsed(io: Io, start: ?Io.Timestamp) i96 {
    return if (start) |at| at.durationTo(.now(io, .awake)).nanoseconds else 0;
}

fn decode(initial: members.Reader, output: *DecodedQueue, profile: bool, decoded: *DecoderResult) !void {
    const io = initial.io;
    const gpa = initial.gpa;
    defer output.close(io);
    const span = tracing.beginEvent("cpi.journal.decode");
    defer tracing.endEvent(span);
    var reader = initial;
    // Preparation can load historical transactions while this decoder runs.
    const decoder: ?zstd.Decoder = if (reader.format == .zstandard) try .init() else null;
    defer if (decoder) |d| d.deinit();
    reader.decoder = decoder;
    var buffer: [4096]u8 = undefined;
    var input = Io.File.Reader.initSize(reader.file, io, &buffer, reader.end);
    var result: DecoderResult = .{};
    var done = false;
    while (!done) {
        var chunk: DecodedChunk = .{};
        errdefer chunk.releaseFrom(gpa, 0);
        var bytes: usize = 0;
        while (chunk.count < chunk.items.len and bytes < target_chunk_bytes) {
            const start = mark(io, profile);
            const member = try reader.next(&input);
            result.ns += elapsed(io, start);
            if (member) |value| {
                chunk.items[chunk.count] = value;
                chunk.count += 1;
                bytes += value.bytes.len;
            } else {
                done = true;
                break;
            }
        }
        if (chunk.count != 0) {
            try output.putOne(io, chunk);
            result.bytes += bytes;
            result.chunks += 1;
        }
    }
    result.incomplete = reader.incomplete;
    decoded.* = result;
}

pub fn parseMember(gpa: Allocator, options: ParseOptions, first_sequence: u64, bytes: []u8) !Transaction {
    return Transaction.parseOwnedObserved(gpa, options.session_id, first_sequence, bytes, options.limits, options.size_warnings) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidJournal;
    };
}

fn parse(gpa: Allocator, io: Io, options: ParseOptions, input: *DecodedQueue, output: *ParsedQueue, profile: bool, parsed_result: *ParserResult) !void {
    defer input.close(io);
    defer output.close(io);
    const span = tracing.beginEvent("cpi.journal.parse");
    defer tracing.endEvent(span);
    var result: ParserResult = .{};
    var sequence = options.first_sequence;
    while (true) {
        const chunk = input.getOne(io) catch |err| switch (err) {
            error.Closed => {
                parsed_result.* = result;
                return;
            },
            error.Canceled => return err,
        };
        var consumed: usize = 0;
        defer chunk.releaseFrom(gpa, consumed);
        var parsed: ParsedChunk = .{};
        errdefer parsed.releaseFrom(0);
        for (chunk.items[0..chunk.count]) |member| {
            try io.checkCancel();
            // The parser owns the bytes even when it rejects the transaction.
            consumed += 1;
            const start = mark(io, profile);
            const transaction = try parseMember(gpa, options, sequence, member.bytes);
            result.ns += elapsed(io, start);
            result.frames += transaction.frames.len;
            sequence = transaction.lastSequence() + 1;
            parsed.items[parsed.count] = .{ .transaction = transaction, .length = member.length };
            parsed.count += 1;
        }
        try output.putOne(io, parsed);
    }
}

/// A successful consumer call consumes the transaction. Returning null means
/// concurrency was unavailable and the consumer has not seen any transactions.
pub fn run(
    reader: members.Reader,
    options: ParseOptions,
    profile: bool,
    context: anytype,
    comptime consume: fn (@TypeOf(context), *Transaction, u64) anyerror!void,
) !?Result {
    const io = reader.io;
    var decoded_buffer: [1]DecodedChunk = undefined;
    var parsed_buffer: [1]ParsedChunk = undefined;
    var decoded: DecodedQueue = .init(&decoded_buffer);
    var parsed: ParsedQueue = .init(&parsed_buffer);
    // Keep the i96 timing counters in caller-owned storage. Zig 0.17.1's
    // threaded future allocation can underallocate an over-aligned result.
    var parse_result: ParserResult = undefined;
    var decode_result: DecoderResult = undefined;
    var parser = io.concurrent(parse, .{ reader.gpa, io, options, &decoded, &parsed, profile, &parse_result }) catch return null;
    var producer: ?Io.Future(@typeInfo(@TypeOf(decode)).@"fn".return_type.?) = null;
    defer {
        // Wake blocked putters and getters, then join before releasing storage.
        decoded.close(io);
        parsed.close(io);
        _ = parser.cancel(io) catch {};
        if (producer) |*task| _ = task.cancel(io) catch {};
        while (decoded.getOneUncancelable(io)) |chunk| chunk.releaseFrom(reader.gpa, 0) else |_| {}
        while (parsed.getOneUncancelable(io)) |chunk| {
            var remaining = chunk;
            remaining.releaseFrom(0);
        } else |_| {}
    }
    producer = io.concurrent(decode, .{ reader, &decoded, profile, &decode_result }) catch return null;
    while (true) {
        var chunk = parsed.getOne(io) catch |err| switch (err) {
            error.Closed => break,
            error.Canceled => return err,
        };
        var consumed: usize = 0;
        defer chunk.releaseFrom(consumed);
        for (chunk.items[0..chunk.count]) |*member| {
            try io.checkCancel();
            try consume(context, &member.transaction, member.length);
            consumed += 1;
        }
    }
    try parser.await(io);
    try producer.?.await(io);
    return .{ .decode = decode_result, .parse = parse_result };
}
