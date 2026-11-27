const std = @import("std");
const Frame = @import("SessionFrame.zig");
const Transaction = @This();

pub const Limits = struct {
    frame_bytes: usize = 8 * 1024 * 1024,
    transaction_bytes: usize = 32 * 1024 * 1024,
    transaction_frames: usize = 1024,
};
pub const SizeSink = Frame.SizeSink;

arena: *std.heap.ArenaAllocator,
frames: []Frame.Decoded,
owned_input: ?[]u8 = null,

pub fn parse(gpa: std.mem.Allocator, session: []const u8, next_sequence: u64, lines: []const u8, limits: Limits) !Transaction {
    return parseObserved(gpa, session, next_sequence, lines, limits, .{});
}

pub fn parseObserved(gpa: std.mem.Allocator, session: []const u8, next_sequence: u64, lines: []const u8, limits: Limits, sink: ?SizeSink) !Transaction {
    return parseFrames(false, gpa, session, next_sequence, lines, limits, sink);
}

/// Consumes the allocator-owned input on success or error and may mutate it.
/// Decoded frames may reference the input until the transaction is released.
pub fn parseOwnedObserved(gpa: std.mem.Allocator, session: []const u8, next_sequence: u64, lines: []u8, limits: Limits, sink: ?SizeSink) !Transaction {
    errdefer gpa.free(lines);
    return parseFrames(true, gpa, session, next_sequence, lines, limits, sink);
}

fn parseFrames(comptime consume_input: bool, gpa: std.mem.Allocator, session: []const u8, next_sequence: u64, lines: if (consume_input) []u8 else []const u8, limits: Limits, sink: ?SizeSink) !Transaction {
    if (lines.len == 0) return error.IncompleteTransaction;
    if (sink) |reporter| reporter.report("transaction bytes", lines.len, limits.transaction_bytes);
    if (lines[lines.len - 1] != '\n') return error.IncompleteTransaction;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var buffer: [4096]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, gpa);
    var parsed: std.ArrayList(Frame.Decoded) = .empty;
    var offset: usize = 0;
    while (offset < lines.len) {
        const end = offset + (std.mem.indexOfScalar(u8, lines[offset..], '\n') orelse return error.IncompleteTransaction);
        const line = lines[offset..end];
        offset = end + 1;
        if (line.len == 0) return error.InvalidTransaction;
        if (sink) |reporter| reporter.report("frame bytes", line.len, limits.frame_bytes);
        const decoded = if (consume_input)
            try Frame.Decoded.decodeInPlace(a, scratch.allocator(), line, sink)
        else
            try Frame.Decoded.decode(a, scratch.allocator(), line, sink);
        scratch.fixed_buffer_allocator.reset();
        const frame = decoded.frame;
        if (!std.mem.eql(u8, session, frame.session_id)) return error.WrongSession;
        const sequence = std.math.add(u64, next_sequence, parsed.items.len) catch return error.SequenceExhausted;
        if (sequence == 0 or sequence > Frame.max_sequence) return error.SequenceExhausted;
        if (frame.seq != sequence or frame.tx.index != parsed.items.len) return error.InvalidTransaction;
        if (parsed.items.len > 0) {
            const initial_frame = parsed.items[0].frame;
            if (frame.tx.count != initial_frame.tx.count or !std.mem.eql(u8, frame.tx.id, initial_frame.tx.id)) return error.InvalidTransaction;
            if (parsed.items.len >= initial_frame.tx.count) return error.InvalidTransaction;
        }
        try parsed.append(a, decoded);
    }
    if (parsed.items.len != parsed.items[0].frame.tx.count) return error.IncompleteTransaction;
    if (sink) |reporter| reporter.report("transaction frames", parsed.items.len, limits.transaction_frames);
    return .{ .arena = arena, .frames = parsed.items, .owned_input = if (consume_input) lines else null };
}

pub fn clone(self: *const Transaction, gpa: std.mem.Allocator) !Transaction {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const frames = try a.alloc(Frame.Decoded, self.frames.len);
    for (self.frames, frames) |original, *owned| {
        owned.* = .{
            .data = try Frame.copy(Frame.Value, a, original.data),
            .frame = try Frame.copy(Frame.Frame, a, original.frame),
            .order = original.order,
        };
    }
    return .{ .arena = arena, .frames = frames };
}

pub fn deinit(self: *Transaction) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    gpa.destroy(self.arena);
    if (self.owned_input) |bytes| gpa.free(bytes);
    self.* = undefined;
}

pub fn id(self: *const Transaction) []const u8 {
    return self.frames[0].frame.tx.id;
}

pub fn lastSequence(self: *const Transaction) u64 {
    return self.frames[self.frames.len - 1].frame.seq;
}

const first =
    \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":2},"class":"capability","op":"capability.bind","actor":{"kind":"host","id":"host"},"cause":null,"data":{"name":"files.read","service":{"id":"files","version":"1"},"config":{}}}
;
const second =
    \\{"v":1,"session_id":"test","seq":2,"tx":{"id":"t1","index":1,"count":2},"class":"document","op":"document.message.append","actor":{"kind":"user","id":"operator"},"cause":null,"data":{"message":{"id":"m1","role":"user","content":[]},"placement":{"context":"main","after":null}}}
;

test "a transaction owns all frames until released" {
    var transaction = try parse(std.testing.allocator, "test", 1, first ++ "\n" ++ second ++ "\n", .{});
    defer transaction.deinit();
    try std.testing.expectEqual(@as(usize, 2), transaction.frames.len);
    try std.testing.expectEqual(@as(u64, 2), transaction.lastSequence());
    try std.testing.expectEqualStrings("t1", transaction.id());
}

test "torn groups, sequence gaps, and wrong sessions reject" {
    try std.testing.expectError(error.IncompleteTransaction, parse(std.testing.allocator, "test", 1, first, .{}));
    try std.testing.expectError(error.IncompleteTransaction, parse(std.testing.allocator, "test", 1, first ++ "\n", .{}));
    try std.testing.expectError(error.InvalidTransaction, parse(std.testing.allocator, "test", 1, first ++ "\n" ++ first ++ "\n", .{}));
    try std.testing.expectError(error.InvalidTransaction, parse(std.testing.allocator, "test", 2, first ++ "\n" ++ second ++ "\n", .{}));
    try std.testing.expectError(error.WrongSession, parse(std.testing.allocator, "other", 1, first ++ "\n" ++ second ++ "\n", .{}));
}

test "allocation failures release every partially parsed frame" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var transaction = try parse(a, "test", 1, first ++ "\n" ++ second ++ "\n", .{});
            defer transaction.deinit();
        }
    };
    var backing = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(@import("session_test_allocator.zig").withoutRemap(&backing), Case.run, .{});
}
