const std = @import("std");
const c = @import("luau").c;
pub const MemoryBudget = @import("memory_budget");

pub const Tool = struct { name: []const u8, source: []const u8, registered: ?*const RegisteredTool = null };
pub const Reply = struct { json: []const u8, failed: bool = false };
pub const Yield = struct { tool_name: []const u8, endpoint: []const u8, arguments_json: []const u8, ctx_json: []const u8, images_json: []const u8 };
pub const Completed = struct { result_json: []const u8, ctx_json: []const u8, images_json: []const u8 };
pub const Failed = struct { message: []const u8, images_json: []const u8 };
pub const Step = union(enum) { budget, effect: Yield, done: Completed, failed: Failed };

const Engine = opaque {};
const Heap = opaque {};
const Span = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    fn from(bytes: []const u8) Span {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }
    fn slice(self: Span) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else "";
    }
};
const BridgeTool = extern struct { name: Span, source: Span, registered: c_int };
const BridgeStep = extern struct { tag: c_int, a: Span, b: Span, c: Span, d: Span, e: Span };
const BridgeMemory = extern struct {
    context: *anyopaque,
    vtable: *const std.mem.Allocator.VTable,
    ledger: ?*MemoryBudget,
    reallocate: *const fn (*anyopaque, *const std.mem.Allocator.VTable, ?*MemoryBudget, ?*anyopaque, usize, usize, usize, *c_int) callconv(.c) ?*anyopaque = reallocate,
};
fn reallocate(context: *anyopaque, vtable: *const std.mem.Allocator.VTable, ledger: ?*MemoryBudget, ptr: ?*anyopaque, old: usize, size: usize, alignment: usize, failure: *c_int) callconv(.c) ?*anyopaque {
    const a: std.mem.Allocator = .{ .ptr = context, .vtable = vtable };
    const align_value = std.mem.Alignment.fromByteUnits(alignment);
    if (size == 0) {
        if (ptr) |p| a.rawFree(@as([*]u8, @ptrCast(p))[0..old], align_value, @returnAddress());
        return null;
    }
    if (ptr) |p| {
        if (a.rawResize(@as([*]u8, @ptrCast(p))[0..old], align_value, size, @returnAddress())) return p;
    }
    const refused = if (ledger) |b| b.usage().refused else 0;
    const next = a.rawAlloc(size, align_value, @returnAddress()) orelse {
        failure.* = if (ledger != null and ledger.?.usage().refused != refused) 2 else 1;
        return null;
    };
    if (ptr) |p| {
        const bytes: [*]u8 = @ptrCast(p);
        @memcpy(next[0..@min(old, size)], bytes[0..@min(old, size)]);
        a.rawFree(bytes[0..old], align_value, @returnAddress());
    }
    return next;
}
extern fn cpi_luavm_open(out: *?*Heap, bootstrap: Span, memory: BridgeMemory) c_int;
extern fn cpi_luavm_compile(memory: BridgeMemory, failure: *c_int, source: [*]const u8, length: usize, size: *usize) ?[*]align(16) u8;

pub fn compileBytecode(allocator: std.mem.Allocator, source: []const u8) ![]align(16) u8 {
    var failure: c_int = 0;
    var size: usize = 0;
    const code = cpi_luavm_compile(.{ .context = allocator.ptr, .vtable = allocator.vtable, .ledger = MemoryBudget.fromAllocator(allocator) }, &failure, source.ptr, source.len, &size) orelse return error.OutOfMemory;
    return code[0..size];
}
extern fn cpi_luavm_close(heap: *Heap) void;
extern fn cpi_luavm_used(heap: *Heap) usize;
extern fn cpi_luavm_counts(values: *[7]u64) void;
extern fn cpi_luavm_begin(heap: *Heap, out: *?*Engine, ctx: Span, tools: [*]const BridgeTool, count: usize, source: Span, describe_only: c_int, input: Span, environment: Span) c_int;
extern fn cpi_luavm_advance(vm: *Engine, budget: u32, reply: ?*const Span, failed: c_int) BridgeStep;
extern fn cpi_luavm_destroy(vm: *Engine) void;
extern fn cpi_luavm_metadata(vm: *Engine) Span;
extern fn cpi_luavm_retain_tool(vm: *Engine, root: *c_int) c_int;
extern fn cpi_luavm_release_tool(heap: *Heap, root: c_int) void;

const bootstrap = "local originalMatch = string.match; local null = table.freeze({}); local shapes = setmetatable({}, {__mode='k'}); return function(...)\n" ++ @embedFile("vm/json.luau") ++ @embedFile("vm/schema.luau") ++ @embedFile("vm/stdlib.luau") ++ @embedFile("vm/application.luau") ++ @embedFile("vm/bootstrap.luau") ++ "\nend";
comptime {
    if (@sizeOf(c.lua_Number) != @sizeOf(f64)) @compileError("unsupported Luau number ABI");
}

fn create(owner: *Owner, allocator: std.mem.Allocator, ctx_json: []const u8, tools: []const Tool, source: []const u8, mode: c_int, input: []const u8, environment: []const u8) !*Engine {
    const definitions = try allocator.alloc(BridgeTool, tools.len);
    defer allocator.free(definitions);
    for (tools, definitions) |tool, *definition| {
        if (tool.registered) |registered| {
            if (registered.value().owner != owner or !std.mem.eql(u8, registered.source(), tool.source)) return error.InvalidExtension;
        }
        definition.* = .{ .name = Span.from(tool.name), .source = Span.from(tool.source), .registered = if (tool.registered) |registered| registered.value().root else -1 };
    }
    var engine: ?*Engine = null;
    const status = cpi_luavm_begin(owner.heap, &engine, Span.from(ctx_json), definitions.ptr, definitions.len, Span.from(source), mode, Span.from(input), Span.from(environment));
    switch (status) {
        0 => return engine orelse error.OutOfMemory,
        1 => return error.OutOfMemory,
        2 => return error.LimitExceeded,
        3 => return error.InvalidExtension,
        4 => return error.InvalidJson,
        5 => return error.InvalidLua,
        else => return error.InvalidState,
    }
}

pub const Counts = struct {
    heaps_opened: u64,
    heaps_closed: u64,
    bootstrap_loads: u64,
    compilations: u64,
    tool_registrations: u64,
    activations_started: u64,
    activations_finished: u64,
};
pub fn counts() Counts {
    var values: [7]u64 = undefined;
    cpi_luavm_counts(&values);
    return .{ .heaps_opened = values[0], .heaps_closed = values[1], .bootstrap_loads = values[2], .compilations = values[3], .tool_registrations = values[4], .activations_started = values[5], .activations_finished = values[6] };
}

const ToolVersion = struct {
    owner: *Owner,
    root: c_int,
    source: []u8,
    metadata: []u8,
    references: std.atomic.Value(usize) = .init(1),
    fn handle(self: *ToolVersion) *RegisteredTool {
        return @ptrCast(self);
    }
};
pub const RegisteredTool = opaque {
    fn value(self: *const RegisteredTool) *ToolVersion {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn belongsTo(self: *const RegisteredTool, owner: *const Owner) bool {
        return self.value().owner == owner;
    }
    pub fn metadata(self: *const RegisteredTool) []const u8 {
        return self.value().metadata;
    }
    pub fn source(self: *const RegisteredTool) []const u8 {
        return self.value().source;
    }
    pub fn retain(self: *RegisteredTool) *RegisteredTool {
        _ = self.value().references.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *RegisteredTool) void {
        const item = self.value();
        if (item.references.fetchSub(1, .acq_rel) != 1) return;
        const owner = item.owner;
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        const bytes = item.source.len + item.metadata.len + @sizeOf(ToolVersion);
        cpi_luavm_release_tool(owner.heap, item.root);
        owner.tool_bytes -= bytes;
        owner.live_tools -= 1;
        owner.allocator.free(item.source);
        owner.allocator.free(item.metadata);
        owner.allocator.destroy(item);
    }
};

pub const Owner = struct {
    heap: *Heap,
    allocator: std.mem.Allocator,
    live_tools: usize = 0,
    tool_bytes: usize = 0,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Owner {
        var heap: ?*Heap = null;
        const status = cpi_luavm_open(&heap, Span.from(bootstrap), .{ .context = allocator.ptr, .vtable = allocator.vtable, .ledger = MemoryBudget.fromAllocator(allocator) });
        if (status != 0) return if (status == 2) error.LimitExceeded else error.OutOfMemory;
        return .{ .heap = heap orelse return error.OutOfMemory, .io = io, .allocator = allocator };
    }
    pub fn deinit(self: *Owner) void {
        std.debug.assert(self.live_tools == 0);
        cpi_luavm_close(self.heap);
        self.* = undefined;
    }
    pub fn usage(self: *Owner) struct { heap_bytes: usize, registered_versions: usize } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .heap_bytes = cpi_luavm_used(self.heap) + self.tool_bytes, .registered_versions = self.live_tools };
    }
    pub fn registerTool(self: *Owner, source: []const u8) !*RegisteredTool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const engine = try create(self, self.allocator, "{}", &.{.{ .name = "", .source = source }}, "", 1, "", "");
        defer cpi_luavm_destroy(engine);
        const metadata = try self.allocator.dupe(u8, cpi_luavm_metadata(engine).slice());
        errdefer self.allocator.free(metadata);
        const bytes = source.len + metadata.len + @sizeOf(ToolVersion);
        const item = try self.allocator.create(ToolVersion);
        errdefer self.allocator.destroy(item);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        var root: c_int = -1;
        if (cpi_luavm_retain_tool(engine, &root) != 0) return error.LimitExceeded;
        item.* = .{ .owner = self, .root = root, .source = owned_source, .metadata = metadata };
        self.tool_bytes += bytes;
        self.live_tools += 1;
        return item.handle();
    }
    pub fn describe(self: *Owner, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        const item = try self.registerTool(source);
        defer item.release();
        return allocator.dupe(u8, item.metadata());
    }
    pub fn begin(self: *Owner, allocator: std.mem.Allocator, ctx: []const u8, tools: []const Tool, source: []const u8) !Vm {
        return self.start(allocator, ctx, tools, source, 0, "", "");
    }
    pub fn beginPolicy(self: *Owner, allocator: std.mem.Allocator, ctx: []const u8, source: []const u8, event: []const u8, preserve_nulls: bool) !Vm {
        return self.start(allocator, ctx, &.{}, source, 8 | (if (preserve_nulls) @as(c_int, 32) else 0), event, "");
    }
    pub fn beginProgram(self: *Owner, allocator: std.mem.Allocator, ctx: []const u8, tools: []const Tool, source: []const u8, input: []const u8) !Vm {
        return self.start(allocator, ctx, tools, source, 16, input, "");
    }
    pub fn beginApplication(self: *Owner, allocator: std.mem.Allocator, ctx: []const u8, tools: []const Tool, source: []const u8, application: Vm.Application) !Vm {
        return self.start(allocator, ctx, tools, source, 2 | (if (application.mutable) @as(c_int, 4) else 0), application.input_json, application.environment_json);
    }
    fn start(self: *Owner, allocator: std.mem.Allocator, ctx: []const u8, tools: []const Tool, source: []const u8, mode: c_int, input: []const u8, environment: []const u8) !Vm {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .engine = try create(self, allocator, ctx, tools, source, mode, input, environment), .owner = self };
    }
};

pub fn describe(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var owner = try Owner.init(allocator, std.Io.Threaded.global_single_threaded.io());
    defer owner.deinit();
    return owner.describe(allocator, source);
}

pub const Vm = struct {
    engine: *Engine,
    owner: *Owner,
    standalone: ?std.mem.Allocator = null,

    pub fn init(allocator: std.mem.Allocator, ctx_json: []const u8, tools: []const Tool, source: []const u8) !Vm {
        const owner = try allocator.create(Owner);
        errdefer allocator.destroy(owner);
        owner.* = try Owner.init(allocator, std.Io.Threaded.global_single_threaded.io());
        errdefer owner.deinit();
        var machine = try owner.begin(allocator, ctx_json, tools, source);
        machine.standalone = allocator;
        return machine;
    }
    pub const Application = struct { input_json: []const u8, environment_json: []const u8, mutable: bool };
    pub fn initApplication(allocator: std.mem.Allocator, ctx_json: []const u8, tools: []const Tool, source: []const u8, application: Application) !Vm {
        const owner = try allocator.create(Owner);
        errdefer allocator.destroy(owner);
        owner.* = try Owner.init(allocator, std.Io.Threaded.global_single_threaded.io());
        errdefer owner.deinit();
        var machine = try owner.beginApplication(allocator, ctx_json, tools, source, application);
        machine.standalone = allocator;
        return machine;
    }

    // Luau interrupt safepoints, not individual instructions, consume this budget.
    pub fn step(self: *Vm, instruction_budget: u32, reply: ?Reply) !Step {
        self.owner.mutex.lockUncancelable(self.owner.io);
        defer self.owner.mutex.unlock(self.owner.io);
        const response = if (reply) |r| Span.from(r.json) else null;
        const result = cpi_luavm_advance(self.engine, instruction_budget, if (response) |*s| s else null, if (reply) |r| @intFromBool(r.failed) else 0);
        return switch (result.tag) {
            0 => .budget,
            1 => .{ .effect = .{ .tool_name = result.a.slice(), .endpoint = result.b.slice(), .arguments_json = result.c.slice(), .ctx_json = result.d.slice(), .images_json = result.e.slice() } },
            2 => .{ .done = .{ .result_json = result.a.slice(), .ctx_json = result.b.slice(), .images_json = result.e.slice() } },
            3 => .{ .failed = .{ .message = result.a.slice(), .images_json = if (result.e.len > 0) result.e.slice() else "[]" } },
            else => error.InvalidState,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.owner.mutex.lockUncancelable(self.owner.io);
        cpi_luavm_destroy(self.engine);
        self.owner.mutex.unlock(self.owner.io);
        if (self.standalone) |a| {
            self.owner.deinit();
            a.destroy(self.owner);
        }
        self.* = undefined;
    }
};
