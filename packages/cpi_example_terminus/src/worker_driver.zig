const std = @import("std");
const Controller = @import("RuntimeController.zig");
const j = @import("services").json;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err)) catch {};
        std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch {};
        std.process.exit(1);
    };
}

fn file(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128 * 1024));
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var root: ?[]const u8 = null;
    var fixture: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var program: []const u8 = "echo";
    var source_root: []const u8 = ".";
    var ghostmux: ?[]const u8 = null;
    var socket: ?[]const u8 = null;
    var policy_path: ?[]const u8 = null;
    var cancel_ms: ?u64 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingArgument;
        const flag = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, flag, "--root")) {
            root = value;
        } else if (std.mem.eql(u8, flag, "--fixture-url")) {
            fixture = value;
        } else if (std.mem.eql(u8, flag, "--input")) {
            input_path = value;
        } else if (std.mem.eql(u8, flag, "--program")) {
            program = value;
        } else if (std.mem.eql(u8, flag, "--sources")) {
            source_root = value;
        } else if (std.mem.eql(u8, flag, "--ghostmux")) {
            ghostmux = value;
        } else if (std.mem.eql(u8, flag, "--socket")) {
            socket = value;
        } else if (std.mem.eql(u8, flag, "--policy")) {
            policy_path = value;
        } else if (std.mem.eql(u8, flag, "--cancel-ms")) {
            cancel_ms = try std.fmt.parseInt(u64, value, 10);
        } else {
            return error.UnknownArgument;
        }
    }
    const directory = root orelse return error.MissingRoot;
    if (!std.fs.path.isAbsolute(directory)) return error.RootMustBeAbsolute;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const common = try file(a, init.io, try std.fs.path.join(a, &.{ source_root, "common.luau" }));
    var definitions: std.ArrayList(Controller.Definition) = .empty;
    for ([_][]const u8{ "echo", "once", "probe", "probe_child", "parser_driver", "terminus" }) |name| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}.luau", .{ source_root, name });
        const code = file(a, init.io, path) catch |err| {
            if (err == error.FileNotFound) continue else return err;
        };
        var bundle: std.ArrayList(u8) = .empty;
        try bundle.appendSlice(a, common);
        try bundle.append(a, '\n');
        if (std.mem.eql(u8, name, "terminus") or std.mem.eql(u8, name, "parser_driver")) {
            try bundle.appendSlice(a, try file(a, init.io, try std.fs.path.join(a, &.{ source_root, "parser.luau" })));
            try bundle.append(a, '\n');
        }
        if (std.mem.eql(u8, name, "terminus")) {
            try bundle.appendSlice(a, try file(a, init.io, try std.fs.path.join(a, &.{ source_root, "prompts.luau" })));
            try bundle.append(a, '\n');
        }
        try bundle.appendSlice(a, code);
        try definitions.append(a, .{
            .name = name,
            .source = bundle.items,
            .terminal = std.mem.eql(u8, name, "terminus") or std.mem.eql(u8, name, "probe"),
            .spawn = std.mem.eql(u8, name, "terminus") or std.mem.eql(u8, name, "probe"),
            .spawnable = std.mem.eql(u8, name, "once") or std.mem.eql(u8, name, "probe_child"),
            .protected_ids = if (std.mem.eql(u8, name, "probe")) &.{1} else &.{},
            .initial_context = if (std.mem.eql(u8, name, "probe")) &.{.{ .role = "system", .content = "protected-prefix" }} else &.{},
        });
    }
    const policy = try file(a, init.io, policy_path orelse try std.fs.path.join(a, &.{ source_root, "access.luau" }));
    const input = try j.parse(a, try file(a, init.io, input_path orelse return error.MissingInput));
    const controller = try Controller.open(init.gpa, init.io, .{
        .directory = directory,
        .workspace = directory,
        .model = .{ .fixture = fixture orelse return error.MissingFixture },
        .ghostmux = ghostmux orelse return error.MissingGhostmux,
        .ghostmux_socket = socket orelse return error.MissingSocket,
        .ghostmux_router = try std.fs.path.join(a, &.{ source_root, "ghostmux-router.sh" }),
        .definitions = definitions.items,
        .policy_source = policy,
    });
    defer controller.deinit();
    const p = try controller.start(program, input, null, null);
    const Timer = struct {
        fn fire(io: std.Io, ms: u64, c: *Controller, target: *Controller.Principal) void {
            std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch return;
            c.cancel(target) catch {};
        }
    };
    var timer: ?std.Io.Future(void) = if (cancel_ms) |ms| try init.io.concurrent(Timer.fire, .{ init.io, ms, controller, p }) else null;
    defer if (timer) |*future| future.cancel(init.io);
    var outcome = try controller.join(p);
    defer outcome.deinit();
    const context = try p.context.read(a);
    const output = try j.encode(a, .{ .outcome = outcome.document.value, .context = context, .workers = controller.principals.items.len });
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (outcome.status != .completed and outcome.status != .cancelled) return error.AgentFailed;
}
