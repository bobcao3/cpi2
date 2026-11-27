const std = @import("std");
const Session = @import("Session.zig");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const Context = @import("LuauContextJournal.zig");
const j = @import("json.zig");
const a = std.testing.allocator;

const AllocationGate = struct {
    armed: bool = false,
    synced: bool = false,
    deny: std.atomic.Value(bool) = .init(false),
    refused: usize = 0,
    var current: ?*AllocationGate = null;
    var original_sync: @TypeOf(std.testing.io.vtable.fileSync) = undefined;

    fn sync(raw: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        try original_sync(raw, file);
        if (current) |gate| if (gate.armed) {
            gate.synced = true;
            gate.deny.store(true, .release);
        };
    }
    fn allocator(self: *AllocationGate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationGate = @ptrCast(@alignCast(raw));
        if (self.deny.load(.acquire)) {
            self.refused += 1;
            return null;
        }
        return a.rawAlloc(len, alignment, ra);
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *AllocationGate = @ptrCast(@alignCast(raw));
        if (self.deny.load(.acquire)) {
            self.refused += 1;
            return false;
        }
        return a.rawResize(memory, alignment, len, ra);
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *AllocationGate = @ptrCast(@alignCast(raw));
        if (self.deny.load(.acquire)) {
            self.refused += 1;
            return null;
        }
        return a.rawRemap(memory, alignment, len, ra);
    }
    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        a.rawFree(memory, alignment, ra);
    }
};

test "bootstrap publishes READY without allocating after successful journal sync" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "startup.gz" });
    defer a.free(path);
    var gate: AllocationGate = .{};
    var vtable = io.vtable.*;
    AllocationGate.original_sync = vtable.fileSync;
    AllocationGate.current = &gate;
    defer AllocationGate.current = null;
    vtable.fileSync = AllocationGate.sync;
    const backend: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    gate.deny.store(true, .release);
    if (gate.allocator().alloc(u8, 1)) |unexpected| {
        a.free(unexpected);
        return error.AllocationGateDidNotDeny;
    } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    gate.deny.store(false, .release);
    try std.testing.expectEqual(@as(usize, 1), gate.refused);
    gate.refused = 0;
    var sequence: u64 = 0;
    {
        const session = try Session.init(gate.allocator(), backend, "startup", directory, path, "{}", j.array(a));
        defer session.deinit();
        session.bootstrap = true;
        _ = try session.run(1, 100);
        try std.testing.expectEqual(@as(u64, 0), session.journal.sequence);
        try std.testing.expectEqual(@as(usize, 0), session.events.items.len);
        gate.armed = true;
        const committed = session.commitBootstrap();
        const denial_armed = gate.deny.load(.acquire);
        gate.deny.store(false, .release);
        gate.armed = false;
        try committed;
        try std.testing.expect(gate.synced and denial_armed);
        try std.testing.expectEqual(@as(usize, 0), gate.refused);
        try std.testing.expectEqual(@as(usize, 1), session.events.items.len);
        try std.testing.expectEqual(Session.api.CPI_AGENT_EVENT_READY, session.events.items[0].value.kind);
        sequence = session.journal.sequence;
        try std.testing.expect(sequence > 0);
    }
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var reopened = try Journal.open(a, io, path, "startup", try Persistence.options(scratch.allocator(), Context.default));
    defer reopened.deinit();
    try std.testing.expectEqual(sequence, reopened.sequence);
}
