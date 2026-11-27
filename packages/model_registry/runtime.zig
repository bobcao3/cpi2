const std = @import("std");
const c = @import("registry_bridge");
const model = @import("model.zig");

/// Owns the arena and typed catalog produced by one evaluation.
pub const Owned = struct {
    arena: *std.heap.ArenaAllocator,
    value: model.Config,

    pub fn deinit(self: Owned) void {
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self.arena);
    }
};

pub const Runtime = struct {
    raw: c.cpi_registry_runtime,
    allocator: std.mem.Allocator,
    config: ?Owned = null,

    pub const safepoint_limit = 1000000;

    pub fn init(a: std.mem.Allocator) Runtime {
        return .{ .allocator = a, .raw = .{
            .alloc = allocate,
            .budget = safepoint_limit,
            .generic = 0,
        } };
    }

    /// Evaluate the fixed registry schema directly into `Config`.
    pub fn evaluate(self: *Runtime, source: []const u8) !model.Config {
        std.debug.assert(self.config == null and self.raw.state == null);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const Builder = @import("runtime/ConfigBuilder.zig");
        var builder: Builder = .{ .a = arena.allocator() };
        self.raw.allocator = &self.allocator;
        self.raw.generic = 0;
        self.raw.sink = Builder.emit;
        self.raw.sink_context = &builder;
        defer self.raw.sink_context = null;
        const status = c.cpi_registry_eval(&self.raw, source.ptr, source.len);
        if (builder.failure) |err| return err;
        try check(status);
        const value = builder.result orelse return error.InvalidRegistryShape;
        self.config = .{ .arena = arena, .value = value };
        return value;
    }

    /// Move the typed result arena out of the one-shot VM owner.
    pub fn takeConfig(self: *Runtime) Owned {
        const owned = self.config.?;
        self.config = null;
        return owned;
    }

    pub fn check(status: c_int) !void {
        return switch (status) {
            0 => {},
            1 => error.OutOfMemory,
            2 => error.RegistryHeapLimit,
            3 => error.RegistryExecutionLimit,
            4 => error.RegistrySyntax,
            5 => error.RegistryRuntime,
            6 => error.InvalidRegistryShape,
            7 => error.UnknownField,
            8 => error.InvalidRegistryNumber,
            10 => error.RegistryCycle,
            11 => error.RegistryMetatable,
            else => unreachable,
        };
    }

    pub fn deinit(self: *Runtime) void {
        c.cpi_registry_close(&self.raw);
        if (self.config) |owned| owned.deinit();
        self.* = undefined;
    }
};

fn bundledBytecode(a: std.mem.Allocator) ![]align(16) u8 {
    const bytes = @embedFile("bundled_bytecode");
    const code = try a.alignedAlloc(u8, .@"16", bytes.len);
    @memcpy(code, bytes);
    return code;
}

pub fn allocate(ud: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, size: usize) callconv(.c) ?*anyopaque {
    const a: *std.mem.Allocator = @ptrCast(@alignCast(ud.?));
    const alignment: std.mem.Alignment = .@"16";
    if (size == 0) {
        if (ptr) |p| a.rawFree(@as([*]u8, @ptrCast(p))[0..old_size], alignment, @returnAddress());
        return null;
    }
    if (ptr) |p| {
        const old = @as([*]u8, @ptrCast(p))[0..old_size];
        if (a.rawResize(old, alignment, size, @returnAddress())) return p;
        const next = a.rawAlloc(size, alignment, @returnAddress()) orelse return null;
        @memcpy(next[0..@min(size, old_size)], old[0..@min(size, old_size)]);
        a.rawFree(old, alignment, @returnAddress());
        return next;
    }
    return a.rawAlloc(size, alignment, @returnAddress());
}

export fn cpi_registry_compile(raw: *c.cpi_registry_runtime, source: [*]const u8, length: usize, size: *usize) ?[*]u8 {
    const a: *std.mem.Allocator = @ptrCast(@alignCast(raw.allocator.?));
    // Only the exact bundled source can select bytecode produced by our build.
    const result = if (@import("agent").session_protocol.json.equalBytes(source[0..length], @embedFile("data/models.lua")))
        bundledBytecode(a.*)
    else
        @import("agent").compileBytecode(a.*, source[0..length]);
    const code = result catch {
        size.* = 0;
        return null;
    };
    size.* = code.len;
    return code.ptr;
}

test "catalog compilation and VM storage share the supplied allocator budget" {
    const budget = try @import("agent").MemoryBudget.create(std.testing.allocator, 256 * 1024);
    defer budget.release();
    {
        var runtime = Runtime.init(budget.allocator());
        defer runtime.deinit();
        const source = try std.testing.allocator.alloc(u8, 512 * 1024);
        defer std.testing.allocator.free(source);
        @memset(source, ' ');
        try std.testing.expectError(error.OutOfMemory, runtime.evaluate(source));
    }
    {
        var runtime = Runtime.init(budget.allocator());
        defer runtime.deinit();
        try std.testing.expectError(error.OutOfMemory, runtime.evaluate("local x = {}; for i=1,100000 do x[i] = string.rep('x',100) end; return x"));
    }
    try std.testing.expectEqual(@sizeOf(@import("agent").MemoryBudget), budget.usage().used);
}
