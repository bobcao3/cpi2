const std = @import("std");
const MemoryBudget = @This();
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

backing: Allocator,
limit: usize,
used: usize,
peak: usize,
refused: usize = 0,
references: usize = 1,
mutex: std.atomic.Mutex = .unlocked,
advisory: bool = false,
warning_peak: usize = 0,

pub const Usage = struct { used: usize, peak: usize, limit: usize, refused: usize };
pub const Warning = struct { actual: usize, threshold: usize };
const Header = struct { capacity: usize };
const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

pub fn create(backing: Allocator, limit: usize) !*MemoryBudget {
    if (limit < @sizeOf(MemoryBudget)) return error.OutOfMemory;
    return init(backing, limit, false);
}

pub fn createAdvisory(backing: Allocator, limit: usize) !*MemoryBudget {
    return init(backing, limit, true);
}

fn init(backing: Allocator, limit: usize, advisory: bool) !*MemoryBudget {
    const self = try backing.create(MemoryBudget);
    const initial = @sizeOf(MemoryBudget);
    self.* = .{ .backing = backing, .limit = limit, .used = initial, .peak = initial, .advisory = advisory, .warning_peak = if (advisory and initial > limit) initial else 0 };
    return self;
}
pub fn allocator(self: *MemoryBudget) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}
pub fn fromAllocator(a: Allocator) ?*MemoryBudget {
    return if (a.vtable == &vtable) @ptrCast(@alignCast(a.ptr)) else null;
}
pub fn usage(self: *MemoryBudget) Usage {
    self.lock();
    defer self.mutex.unlock();
    return .{ .used = self.used, .peak = self.peak, .limit = self.limit, .refused = self.refused };
}
pub fn configure(self: *MemoryBudget, limit: usize) !void {
    self.lock();
    defer self.mutex.unlock();
    if (!self.advisory and limit < self.peak) return error.OutOfMemory;
    self.limit = limit;
    self.warning_peak = if (self.used > limit) self.used else 0;
}

pub fn takeWarning(self: *MemoryBudget) ?Warning {
    self.lock();
    defer self.mutex.unlock();
    if (self.warning_peak == 0) return null;
    const warning: Warning = .{ .actual = self.warning_peak, .threshold = self.limit };
    self.warning_peak = 0;
    return warning;
}
pub fn release(self: *MemoryBudget) void {
    self.lock();
    self.references -= 1;
    const destroy = self.references == 0;
    const backing = self.backing;
    self.mutex.unlock();
    if (destroy) backing.destroy(self);
}
fn lock(self: *MemoryBudget) void {
    while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
}
fn offset(alignment: Alignment) usize {
    return std.mem.alignForward(usize, @sizeOf(Header), alignment.max(.of(Header)).toByteUnits());
}
fn header(memory: [*]u8, alignment: Alignment) *Header {
    return @ptrCast(@alignCast(memory - offset(alignment)));
}
fn admit(self: *MemoryBudget, bytes: usize) bool {
    if ((!self.advisory and bytes > self.limit - self.used) or bytes > std.math.maxInt(usize) - self.used) {
        self.refused +|= 1;
        return false;
    }
    return true;
}
fn account(self: *MemoryBudget, next: usize) void {
    if (self.advisory and next > self.limit and (self.used <= self.limit or self.warning_peak != 0)) self.warning_peak = @max(self.warning_peak, next);
    self.used = next;
    self.peak = @max(self.peak, next);
}
fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    self.lock();
    defer self.mutex.unlock();
    const total = std.math.add(usize, offset(alignment), len) catch {
        self.refused +|= 1;
        return null;
    };
    if (!self.admit(total)) return null;
    const memory = self.backing.rawAlloc(total, alignment.max(.of(Header)), ret) orelse return null;
    const h: *Header = @ptrCast(@alignCast(memory));
    h.* = .{ .capacity = total };
    self.account(self.used + total);
    self.references += 1;
    return memory + offset(alignment);
}
fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) bool {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    self.lock();
    defer self.mutex.unlock();
    const total = std.math.add(usize, offset(alignment), len) catch return false;
    const h = header(memory.ptr, alignment);
    const old = h.capacity;
    if (total > old and !self.admit(total - old)) return false;
    const raw: [*]u8 = @ptrCast(h);
    if (!self.backing.rawResize(raw[0..old], alignment.max(.of(Header)), total, ret)) {
        return total <= old;
    }
    h.capacity = total;
    self.account(self.used - old + total);
    return true;
}
fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, len, ret)) memory.ptr else null;
}
fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    self.lock();
    const h = header(memory.ptr, alignment);
    const capacity = h.capacity;
    const raw: [*]u8 = @ptrCast(h);
    self.backing.rawFree(raw[0..capacity], alignment.max(.of(Header)), ret);
    self.used -= capacity;
    self.references -= 1;
    const destroy = self.references == 0;
    const backing = self.backing;
    self.mutex.unlock();
    if (destroy) backing.destroy(self);
}

test "allocation owns ledger after root release and alignment is preserved" {
    const budget = try create(std.testing.allocator, 4096);
    const a = budget.allocator();
    const bytes = try a.alignedAlloc(u8, .fromByteUnits(256), 513);
    try std.testing.expect(budget.usage().used >= bytes.len + @sizeOf(MemoryBudget) + @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 256);
    budget.release();
    @memset(bytes, 31);
    a.free(bytes);
}

test "moving growth charges overlap and denied attempts preserve old bytes" {
    const Moving = struct {
        fn allocate(_: *anyopaque, size: usize, alignment: Alignment, ret: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(size, alignment, ret);
        }
        fn releaseMemory(_: *anyopaque, bytes: []u8, alignment: Alignment, ret: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    const backing: Allocator = .{ .ptr = undefined, .vtable = &.{ .alloc = Moving.allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = Moving.releaseMemory } };
    const budget = try create(backing, 2048);
    defer budget.release();
    const a = budget.allocator();
    const base = budget.usage().used;
    var bytes = try a.alloc(u8, 1000);
    defer a.free(bytes);
    @memset(bytes, 19);
    try std.testing.expectError(error.OutOfMemory, a.realloc(bytes, 1100));
    try std.testing.expectEqual(@as(u8, 19), bytes[999]);
    try std.testing.expect(budget.usage().refused > 0);
    try std.testing.expect(a.resize(bytes, 800));
    bytes = bytes[0..800];
    try std.testing.expectEqual(base + 1000 + @sizeOf(Header), budget.usage().used);
    try std.testing.expect(budget.usage().peak <= budget.usage().limit);
}

test "backing failure refunds admission without reporting quota denial" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const budget = try create(failing.allocator(), 4096);
    defer budget.release();
    const before = budget.usage();
    try std.testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 512));
    try std.testing.expectEqual(before.used, budget.usage().used);
    try std.testing.expectEqual(before.refused, budget.usage().refused);
}

test "concurrent allocations and moving growth share one ledger" {
    const Worker = struct {
        fn run(a: Allocator, failed: *std.atomic.Value(bool)) void {
            for (0..512) |index| {
                const size = index % 1024 + 1;
                var bytes = a.alloc(u8, size) catch {
                    failed.store(true, .release);
                    return;
                };
                defer a.free(bytes);
                @memset(bytes, 23);
                bytes = a.realloc(bytes, size * 2) catch {
                    failed.store(true, .release);
                    return;
                };
                for (bytes[0..size]) |byte| if (byte != 23) {
                    failed.store(true, .release);
                    return;
                };
            }
        }
    };
    const budget = try create(std.testing.allocator, 64 * 1024);
    defer budget.release();
    const baseline = budget.usage().used;
    var failed: std.atomic.Value(bool) = .init(false);
    {
        var threads: [4]std.Thread = undefined;
        var launched: usize = 0;
        defer for (threads[0..launched]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ budget.allocator(), &failed });
            launched += 1;
        }
    }
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(baseline, budget.usage().used);
    try std.testing.expect(budget.usage().peak <= budget.usage().limit);
}
