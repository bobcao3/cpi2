const std = @import("std");
const services = @import("services");
const j = services.json;

const Warnings = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(services.SizeWarning) = .empty,

    fn notify(raw: *anyopaque, event: services.SizeWarning) void {
        const self: *Warnings = @ptrCast(@alignCast(raw));
        services.logSizeWarning(event);
        self.events.append(self.allocator, event) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--repeat")) return repeat(init, args[2..]);
    if (args.len != 4) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: cpi-services WORKSPACE RUNTIME_DIRECTORY GHOSTMUX\n");
        std.process.exit(2);
    }
    var service: services.Process = .{ .workspace = args[1], .directory = args[2], .binary = args[3], .environment = init.environ_map };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    var warnings: Warnings = .{ .allocator = a };
    var envelope = execute(init, &registry, &warnings) catch |err| try j.value(a, .{ .@"error" = .{ .code = @errorName(err), .message = @errorName(err) } });
    if (warnings.events.items.len != 0) {
        if (j.value(a, warnings.events.items)) |events| {
            j.put(a, &envelope, "size_warnings", events) catch {};
        } else |_| {}
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, try j.encode(a, envelope));
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn repeat(init: std.process.Init, args: []const [:0]const u8) !void {
    const interval = try std.fmt.parseInt(u32, args[0], 10);
    if (interval < 100 or interval > 60000) return error.InvalidInterval;
    var argv: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| try argv.append(init.arena.allocator(), arg);
    while (true) {
        const started = std.Io.Clock.awake.now(init.io).toMilliseconds();
        const result = std.process.run(init.gpa, init.io, .{
            .argv = argv.items,
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(interval), .clock = .awake } },
        }) catch |err| {
            try std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err));
            std.process.exit(124);
        };
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        const context: services.Context = .{ .allocator = init.gpa, .io = init.io };
        context.warnSize("cpi-services repeat", "stdout bytes", result.stdout.len, 1024 * 1024);
        context.warnSize("cpi-services repeat", "stderr bytes", result.stderr.len, 1024 * 1024);
        try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
        try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);
        if (result.term != .exited) std.process.exit(125);
        if (result.term.exited != 0) std.process.exit(result.term.exited);
        const remaining = started + interval - std.Io.Clock.awake.now(init.io).toMilliseconds();
        if (remaining > 0) try std.Io.sleep(init.io, .fromMilliseconds(remaining), .awake);
    }
}

fn execute(init: std.process.Init, registry: *services.Registry, warnings: *Warnings) !j.Value {
    const a = init.arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = std.Io.File.stdin().readStreaming(init.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        try input.appendSlice(a, buffer[0..count]);
    }
    var context: services.Context = .{
        .allocator = a,
        .io = init.io,
        .size_warnings = .{ .context = warnings, .notify = Warnings.notify },
    };
    context.warnSize("cpi-services", "request bytes", input.items.len, 1024 * 1024);
    const request = try j.parse(a, input.items);
    context.warnSize("cpi-services", "request JSON nesting depth", try j.depth(a, request), j.expected_depth);
    const endpoint = try j.text(j.get(request, "endpoint"));
    context.idempotency_key = try j.string(request, "idempotency_key", "");
    const result = try registry.dispatch(context, endpoint, j.get(request, "arguments"));
    return j.value(a, .{ .result = result });
}
