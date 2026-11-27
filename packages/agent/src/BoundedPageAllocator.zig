const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Self = @This();

limit: usize,
used: std.atomic.Value(usize) = .init(0),

pub fn allocator(self: *Self) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn pageBytes(len: usize) ?usize {
    const mask = std.heap.pageSize() - 1;
    return (std.math.add(usize, len, mask) catch return null) & ~mask;
}

fn reserve(self: *Self, bytes: usize) bool {
    var used = self.used.load(.monotonic);
    while (true) {
        if (bytes > self.limit - used) return false;
        used = self.used.cmpxchgWeak(used, used + bytes, .monotonic, .monotonic) orelse return true;
    }
}

fn release(self: *Self, bytes: usize) void {
    const previous = self.used.fetchSub(bytes, .monotonic);
    std.debug.assert(previous >= bytes);
}

fn alloc(raw: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(raw));
    const bytes = pageBytes(len) orelse return null;
    if (!self.reserve(bytes)) return null;
    const ptr = std.heap.page_allocator.rawAlloc(len, alignment, ra) orelse {
        self.release(bytes);
        return null;
    };
    return ptr;
}

fn resize(raw: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    const before = pageBytes(memory.len).?;
    const after = pageBytes(new_len) orelse return false;
    // Windows may retain pages after a successful shrinking resize.
    if (after < before) return false;
    const growth = after - before;
    if (!self.reserve(growth)) return false;
    if (!std.heap.page_allocator.rawResize(memory, alignment, new_len, ra)) {
        self.release(growth);
        return false;
    }
    return true;
}

fn remap(raw: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(raw, memory, alignment, new_len, ra)) memory.ptr else null;
}

fn free(raw: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const bytes = pageBytes(memory.len).?;
    std.heap.page_allocator.rawFree(memory, alignment, ra);
    self.release(bytes);
}

test "page-backed allocator maintains a live-allocation model across generated traces" {
    const Entry = struct { memory: []u8, alignment: Alignment, pattern: u8 };
    const page = std.heap.pageSize();
    for (0..8) |seed| {
        var random_state = std.Random.DefaultPrng.init(seed);
        const random = random_state.random();
        var bounded: Self = .{ .limit = (3 + seed) * page + page / 2 };
        const a = bounded.allocator();
        var entries: [16]?Entry = @splat(null);
        defer for (entries) |entry| {
            if (entry) |live| a.rawFree(live.memory, live.alignment, @returnAddress());
        };
        const limit_pages = bounded.limit / page;
        try std.testing.expectEqual(0, bounded.used.load(.monotonic));
        for (0..512) |step| {
            var live_pages: usize = 0;
            for (entries) |entry| {
                if (entry) |live| live_pages += (live.memory.len - 1) / page + 1;
            }
            const index = random.uintLessThan(usize, entries.len);
            const len = if (step % 8 == 0)
                std.math.maxInt(usize) - random.uintLessThan(usize, page)
            else
                @max(1, (1 + random.uintLessThan(usize, 6) * page) -| random.uintLessThan(usize, 3));
            const pages = (len - 1) / page + 1;
            if (entries[index]) |live| {
                switch (random.uintLessThan(u8, 3)) {
                    0 => {
                        a.rawFree(live.memory, live.alignment, @returnAddress());
                        entries[index] = null;
                    },
                    1, 2 => |operation| {
                        const ptr = if (operation == 1)
                            if (a.rawResize(live.memory, live.alignment, len, @returnAddress())) live.memory.ptr else null
                        else
                            a.rawRemap(live.memory, live.alignment, len, @returnAddress());
                        if (ptr) |memory| {
                            try std.testing.expect(memory == live.memory.ptr);
                            const old_pages = (live.memory.len - 1) / page + 1;
                            try std.testing.expect(pages <= limit_pages - (live_pages - old_pages));
                            try std.testing.expect(std.mem.allEqual(u8, memory[0..@min(len, live.memory.len)], live.pattern));
                            entries[index] = .{ .memory = memory[0..len], .alignment = live.alignment, .pattern = live.pattern };
                            @memset(memory[0..len], live.pattern);
                        }
                    },
                    else => unreachable,
                }
            } else {
                const exponent = random.uintLessThan(u8, @intCast(std.math.log2_int(usize, std.heap.page_size_max) + 2));
                const alignment = Alignment.fromByteUnits(@as(usize, 1) << @intCast(exponent));
                const ptr = a.rawAlloc(len, alignment, @returnAddress());
                if (ptr) |memory| {
                    entries[index] = .{ .memory = memory[0..len], .alignment = alignment, .pattern = random.int(u8) };
                    @memset(memory[0..len], entries[index].?.pattern);
                }
                try std.testing.expectEqual(pages <= limit_pages - live_pages, ptr != null);
            }
            var expected_pages: usize = 0;
            for (entries) |entry| {
                if (entry) |live| {
                    expected_pages += (live.memory.len - 1) / page + 1;
                    try std.testing.expectEqual(0, @intFromPtr(live.memory.ptr) % live.alignment.toByteUnits());
                    try std.testing.expect(std.mem.allEqual(u8, live.memory, live.pattern));
                }
            }
            try std.testing.expect(expected_pages <= limit_pages);
            try std.testing.expectEqual(expected_pages * page, bounded.used.load(.monotonic));
        }
        for (&entries) |*entry| {
            if (entry.*) |live| a.rawFree(live.memory, live.alignment, @returnAddress());
            entry.* = null;
        }
        try std.testing.expectEqual(0, bounded.used.load(.monotonic));
        const full = try a.alloc(u8, limit_pages * page);
        a.free(full);
        try std.testing.expectEqual(0, bounded.used.load(.monotonic));
    }
}
