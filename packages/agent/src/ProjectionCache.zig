//! Immutable renderer data and SHA-256 prefixes for one private replay.
const std = @import("std");
const Frame = @import("SessionFrame.zig");
const Canonical = @import("CanonicalJson.zig");
const Cache = @This();
const Allocator = std.mem.Allocator;
const Value = Frame.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Entry = struct { stream: []const u8, value: Value };
const Decode = fn (Allocator, Frame.Message) anyerror!?Entry;
const Render = fn (Allocator, Frame.Message, ?Entry) anyerror![]const Value;
const Item = struct { decoded: ?Entry, rendered: ?[]const Value = null };
const Prefix = struct { identity: usize, sha256: Sha256 };
const capacity = 12 * 1024 * 1024;

gpa: Allocator,
backing: ?std.heap.FixedBufferAllocator = null,
items: std.StringHashMapUnmanaged(Item) = .empty,
prefix: std.ArrayList(Prefix) = .empty,
full: bool = false,

pub fn deinit(self: *Cache) void {
    if (self.backing) |b| self.gpa.free(b.buffer);
}

fn allocator(self: *Cache) error{OutOfMemory}!Allocator {
    if (self.full) return error.OutOfMemory;
    if (self.backing == null) self.backing = .init(try self.gpa.alloc(u8, capacity));
    return self.backing.?.allocator();
}

fn add(self: *Cache, message: Frame.Message, comptime decode: Decode) !?Entry {
    const a = try self.allocator();
    var parsed = try decode(a, message);
    if (parsed) |*entry| entry.stream = try a.dupe(u8, entry.stream);
    try self.items.putNoClobber(a, try a.dupe(u8, message.id), .{ .decoded = parsed });
    return parsed;
}

pub fn decoded(self: *Cache, a: Allocator, message: Frame.Message, comptime decode: Decode) !?Entry {
    if (self.items.get(message.id)) |item| return item.decoded;
    if (!self.full) return self.add(message, decode) catch |err| switch (err) {
        error.OutOfMemory => {
            self.full = true;
            return decode(a, message);
        },
        else => return err,
    };
    return decode(a, message);
}

pub fn rendered(self: *Cache, a: Allocator, message: Frame.Message, entry: ?Entry, comptime render: Render) ![]const Value {
    const cached = self.items.getPtr(message.id) orelse return render(a, message, entry);
    if (cached.rendered) |items| return items;
    if (!self.full) {
        // The renderer can borrow the cached entry, and owns any projections
        // it produces from the transient wire message.
        const stored = render(self.backing.?.allocator(), message, cached.decoded) catch |err| switch (err) {
            error.OutOfMemory => {
                self.full = true;
                return render(a, message, entry);
            },
            else => return err,
        };
        cached.rendered = stored;
        return stored;
    }
    return render(a, message, entry);
}

/// The backing of a nonempty object inside this cache is immutable and
/// never recycled during replay. Scratch values cannot share its identity.
fn identity(self: *const Cache, item: Value) ?usize {
    const backing = self.backing orelse return null;
    if (item != .object or item.object.count() == 0) return null;
    const ptr = @intFromPtr(item.object.keys().ptr);
    const start = @intFromPtr(backing.buffer.ptr);
    return if (ptr >= start and ptr - start < backing.end_index) ptr else null;
}

pub fn hashMessages(self: *Cache, a: Allocator, input: Value) ![64]u8 {
    if (input != .array or self.backing == null) return Canonical.hash(a, input);
    const items = input.array.items;
    var common: usize = 0;
    const limit = @min(items.len, self.prefix.items.len);
    for (items[0..limit], self.prefix.items[0..limit]) |item, state| {
        if (self.identity(item) != state.identity) break;
        common += 1;
    }

    var buffer: [4096]u8 = undefined;
    var output: std.Io.Writer.Hashing(Sha256) = .init(&buffer);
    if (common == 0) {
        try output.writer.writeByte('[');
    } else {
        output.hasher = self.prefix.items[common - 1].sha256;
    }
    self.prefix.shrinkRetainingCapacity(common);
    var keep_prefix = !self.full;
    for (items[common..], common..) |item, index| {
        if (index != 0) try output.writer.writeByte(',');
        try Canonical.write(a, &output.writer, item);
        if (keep_prefix) {
            if (self.identity(item)) |id| {
                try output.writer.flush();
                self.prefix.append(self.backing.?.allocator(), .{ .identity = id, .sha256 = output.hasher }) catch {
                    self.full = true;
                    keep_prefix = false;
                };
            } else keep_prefix = false;
        }
    }
    try output.writer.writeByte(']');
    try output.writer.flush();
    return std.fmt.bytesToHex(output.hasher.finalResult(), .lower);
}
