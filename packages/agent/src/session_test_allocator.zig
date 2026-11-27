const std = @import("std");
const Allocator = std.mem.Allocator;

/// Route growth through alloc so failure indexes do not depend on slab reuse.
pub fn withoutRemap(backing: *Allocator) Allocator {
    return .{ .ptr = backing, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
}
fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const backing: *Allocator = @ptrCast(@alignCast(raw));
    return backing.rawAlloc(len, alignment, ra);
}
fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const backing: *Allocator = @ptrCast(@alignCast(raw));
    backing.rawFree(bytes, alignment, ra);
}
