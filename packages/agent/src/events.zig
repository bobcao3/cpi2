const std = @import("std");
const j = @import("json.zig");

pub const Value = struct {
    kind: u32,
    lease_id: u64,
    operation_id: u64,
    sequence: u64,
    request_id: []const u8,
    method: []const u8,
    json: []const u8,
};

pub const Event = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    delivered: bool = false,
    bytes: usize,

    pub fn init(gpa: std.mem.Allocator, lease: u64, kind: u32, operation: u64, sequence: u64, request: []const u8, method: []const u8, payload: j.Value) !*Event {
        const event = try gpa.create(Event);
        errdefer gpa.destroy(event);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const id = try a.dupe(u8, request);
        const name = try a.dupe(u8, method);
        const bytes = try j.encode(a, payload);
        event.* = .{ .arena = arena, .bytes = bytes.len + id.len + name.len, .value = .{
            .kind = kind,
            .lease_id = lease,
            .operation_id = operation,
            .sequence = sequence,
            .request_id = id,
            .method = name,
            .json = bytes,
        } };
        return event;
    }

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};
