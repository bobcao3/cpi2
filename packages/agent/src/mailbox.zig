const std = @import("std");

pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Node = struct { next: ?*Node = null, value: T = undefined, owned: bool = false };
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        head: ?*Node = null,
        tail: ?*Node = null,
        count: usize = 0,
        closed: bool = false,

        pub fn init(a: std.mem.Allocator) Self {
            return .{ .allocator = a };
        }
        pub fn putBorrowed(self: *Self, io: std.Io, node: *Node) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            node.next = null;
            if (self.tail) |tail| tail.next = node else self.head = node;
            self.tail = node;
            self.count += 1;
            self.condition.signal(io);
        }
        pub fn putOneUncancelable(self: *Self, io: std.Io, value: T) !void {
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = .{ .value = value, .owned = true };
            try self.putBorrowed(io, node);
        }
        pub fn putOne(self: *Self, io: std.Io, value: T) !void {
            try io.checkCancel();
            try self.putOneUncancelable(io, value);
        }
        pub fn getUncancelable(self: *Self, io: std.Io, output: []T, minimum: usize) !usize {
            std.debug.assert(minimum <= output.len);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.count < minimum and !self.closed) self.condition.waitUncancelable(io, &self.mutex);
            if (self.count == 0 and self.closed) return error.Closed;
            var count: usize = 0;
            while (count < output.len) : (count += 1) {
                const node = self.head orelse break;
                self.head = node.next;
                if (self.head == null) self.tail = null;
                self.count -= 1;
                output[count] = node.value;
                if (node.owned) self.allocator.destroy(node);
            }
            return count;
        }
        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.closed = true;
            self.condition.broadcast(io);
        }
        pub fn deinit(self: *Self) void {
            var node = self.head;
            while (node) |current| {
                node = current.next;
                if (current.owned) self.allocator.destroy(current);
            }
            self.* = undefined;
        }
    };
}
