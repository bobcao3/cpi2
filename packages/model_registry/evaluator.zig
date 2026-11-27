const std = @import("std");
const registry = @import("model_registry");

pub fn main(init: std.process.Init) void {
    evaluate(init) catch |err| {
        std.debug.print("cpi-model-registry: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn evaluate(init: std.process.Init) !void {
    const budget = try registry.MemoryBudget.create(init.gpa, registry.default_memory_bytes);
    defer budget.release();
    const a = budget.allocator();
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len != 2) return error.ExpectedRegistryPath;
    var loaded = try registry.Registry.load(a, init.io, args[1]);
    defer loaded.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(loaded.parsed.value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
