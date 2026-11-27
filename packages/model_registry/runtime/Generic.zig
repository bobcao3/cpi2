//! Generic Lua-to-value evaluation for open-ended configuration sources.
//!
//! The fixed registry schema does not use this module: `runtime.zig` builds
//! typed model-catalog structures directly. This path exists for callers such as
//! harness configuration files whose accepted shape is intentionally dynamic.
const std = @import("std");
const c = @import("registry_bridge");
const typed = @import("../runtime.zig");

pub const GenericRuntime = struct {
    raw: c.cpi_registry_runtime,
    allocator: std.mem.Allocator,
    output: ?std.json.Parsed(std.json.Value) = null,
    depth: usize = 0,

    pub fn init(a: std.mem.Allocator) GenericRuntime {
        return .{ .allocator = a, .raw = .{
            .alloc = typed.allocate,
            .budget = typed.Runtime.safepoint_limit,
            .generic = 1,
        } };
    }

    pub fn evaluateGeneric(self: *GenericRuntime, source: []const u8) !std.json.Value {
        std.debug.assert(self.output == null and self.raw.state == null);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        self.output = .{ .arena = arena, .value = .null };
        const Builder = @import("ValueBuilder.zig");
        var builder: Builder = .{ .a = arena.allocator() };
        self.raw.allocator = &self.allocator;
        self.raw.generic = 1;
        self.raw.sink = Builder.emit;
        self.raw.sink_context = &builder;
        defer self.raw.sink_context = null;
        const status = c.cpi_registry_eval(&self.raw, source.ptr, source.len);
        self.depth = builder.depth;
        if (builder.failure) |err| return err;
        try typed.Runtime.check(status);
        std.debug.assert(builder.frames.items.len == 0);
        self.output.?.value = builder.result;
        return builder.result;
    }

    /// Move the generic result arena out of the one-shot VM owner.
    pub fn takeResult(self: *GenericRuntime) std.json.Parsed(std.json.Value) {
        const output = self.output.?;
        self.output = null;
        return output;
    }

    pub fn deinit(self: *GenericRuntime) void {
        c.cpi_registry_close(&self.raw);
        if (self.output) |output| output.deinit();
        self.* = undefined;
    }
};
