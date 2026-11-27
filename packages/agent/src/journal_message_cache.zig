const std = @import("std");
const frames = @import("session_protocol").frames;
const Allocator = std.mem.Allocator;
const Cache = @This();

const Entry = struct {
    reference: u64,
    payload: union(enum) { message: *const frames.Message, control: *const frames.Frame },
};

const capacity = 4 * 1024 * 1024;

gpa: Allocator,
buffer: ?std.heap.FixedBufferAllocator = null,
entries: std.ArrayList(Entry) = .empty,
unavailable: bool = false,

pub fn init(gpa: Allocator) Cache {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Cache) void {
    if (self.buffer) |buffer| self.gpa.free(buffer.buffer);
    self.* = undefined;
}

/// Retain only message payloads from validated frames, in replay order.
/// A message that does not fit leaves the previous entries available.
pub fn remember(self: *Cache, frame: frames.Frame) void {
    switch (frame.action) {
        .@"document.message.append" => |message| if (message.display_only orelse false) return,
        .@"control.set_model", .@"control.provider_tool.register", .@"control.context.create" => {},
        else => return,
    }
    if (self.unavailable) return;
    if (self.buffer == null) {
        const bytes = self.gpa.alloc(u8, capacity) catch {
            self.unavailable = true;
            return;
        };
        self.buffer = .init(bytes);
    }
    const buffer = &self.buffer.?;
    const a = buffer.allocator();
    const mark = buffer.end_index;
    if (self.entries.getLastOrNull()) |last| std.debug.assert(last.reference < frame.seq);
    self.add(a, frame) catch {
        // add publishes the new entry only after the payload is fully owned.
        buffer.end_index = mark;
    };
}

fn add(self: *Cache, a: Allocator, frame: frames.Frame) !void {
    var entry: Entry = .{ .reference = frame.seq, .payload = undefined };
    switch (frame.action) {
        .@"document.message.append" => |append| {
            const owned = try a.create(frames.Message);
            owned.* = try frames.copy(frames.Message, a, append.message);
            entry.payload = .{ .message = owned };
        },
        else => {
            const owned = try a.create(frames.Frame);
            owned.* = try frames.copy(frames.Frame, a, frame);
            entry.payload = .{ .control = owned };
        },
    }
    try self.entries.append(a, entry);
}

fn lookup(self: *const Cache, reference: u64) ?Entry {
    const index = std.sort.binarySearch(Entry, self.entries.items, reference, struct {
        fn compare(needle: u64, entry: Entry) std.math.Order {
            return std.math.order(needle, entry.reference);
        }
    }.compare) orelse return null;
    return self.entries.items[index];
}

pub fn getMessage(self: *const Cache, reference: u64) ?frames.Message {
    const entry = self.lookup(reference) orelse return null;
    return if (entry.payload == .message) entry.payload.message.* else null;
}

pub fn getFrame(self: *const Cache, reference: u64) ?*const frames.Frame {
    const entry = self.lookup(reference) orelse return null;
    return if (entry.payload == .control) entry.payload.control else null;
}
