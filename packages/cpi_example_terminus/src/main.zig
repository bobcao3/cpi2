const std = @import("std");
const builtin = @import("builtin");
const Controller = @import("RuntimeController.zig");
const provider = @import("agent").provider;
const Effects = @import("agent").provider.Effects;
const j = @import("services").json;

var interrupted = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Signals = struct {
    old_int: std.posix.Sigaction = undefined,
    old_term: std.posix.Sigaction = undefined,

    fn init() Signals {
        var self: Signals = .{};
        if (builtin.os.tag != .windows) {
            interrupted.store(false, .release);
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.INT, &action, &self.old_int);
            std.posix.sigaction(.TERM, &action, &self.old_term);
        }
        return self;
    }

    fn deinit(self: *Signals) void {
        if (builtin.os.tag == .windows) return;
        std.posix.sigaction(.INT, &self.old_int, null);
        std.posix.sigaction(.TERM, &self.old_term, null);
    }
};

fn watchSignals(io: std.Io, controller: *Controller, principal: *Controller.Principal) void {
    while (!interrupted.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(50), .awake) catch return;
    controller.cancel(principal) catch {};
}

const usage =
    \\usage: cpi-terminus (--task TEXT | --task-file FILE) --workspace DIR --state-dir NEW_DIR
    \\       (--live | --fixture-url http://127.0.0.1:PORT) --ghostmux ABSOLUTE_PATH
    \\       [--socket ABSOLUTE_PATH] [--max-turns N] [--max-model-calls N]
    \\       [--context-window N] [--reserve-tokens N] [--max-output-tokens N]
    \\       [--reasoning-effort VALUE]
    \\  --live uses OPENAI_MODEL, OPENAI_BASE_URL and OPENAI_API_KEY from the environment.
    \\  Fixture mode never reads provider configuration. No dotenv files are loaded.
    \\  The terminal runs with your OS permissions. The workspace is not a sandbox.
    \\
;

const Options = struct {
    task: ?[]const u8 = null,
    task_file: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    state: ?[]const u8 = null,
    fixture_url: ?[]const u8 = null,
    live: bool = false,
    ghostmux: ?[]const u8 = null,
    socket: ?[]const u8 = null,
    max_turns: ?u64 = null,
    max_model_calls: ?u64 = null,
    context_window: u64 = 128000,
    reserve_tokens: u64 = 8000,
    max_output_tokens: u64 = 4096,
    reasoning_effort: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err)) catch {};
        std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch {};
        std.process.exit(1);
    };
}

fn number(value: []const u8, maximum: u64) !u64 {
    const n = try std.fmt.parseInt(u64, value, 10);
    if (n == 0 or n > maximum) return error.InvalidLimit;
    return n;
}

fn parse(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--live")) {
            if (options.live) return error.InvalidArguments;
            options.live = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, flag, "--task")) {
            options.task = value;
        } else if (std.mem.eql(u8, flag, "--task-file")) {
            options.task_file = value;
        } else if (std.mem.eql(u8, flag, "--workspace")) {
            options.workspace = value;
        } else if (std.mem.eql(u8, flag, "--state-dir")) {
            options.state = value;
        } else if (std.mem.eql(u8, flag, "--fixture-url")) {
            options.fixture_url = value;
        } else if (std.mem.eql(u8, flag, "--ghostmux")) {
            options.ghostmux = value;
        } else if (std.mem.eql(u8, flag, "--socket")) {
            options.socket = value;
        } else if (std.mem.eql(u8, flag, "--max-turns")) {
            options.max_turns = try number(value, 9007199254740991);
        } else if (std.mem.eql(u8, flag, "--max-model-calls")) {
            options.max_model_calls = try number(value, 9007199254740991);
        } else if (std.mem.eql(u8, flag, "--context-window")) {
            options.context_window = try number(value, 10000000);
        } else if (std.mem.eql(u8, flag, "--reserve-tokens")) {
            options.reserve_tokens = try number(value, 10000000);
        } else if (std.mem.eql(u8, flag, "--max-output-tokens")) {
            options.max_output_tokens = try number(value, 1000000);
        } else if (std.mem.eql(u8, flag, "--reasoning-effort")) {
            options.reasoning_effort = value;
        } else {
            return error.UnknownArgument;
        }
    }
    if ((options.task == null) == (options.task_file == null)) return error.InvalidTask;
    if (options.live == (options.fixture_url != null)) return error.InvalidModelMode;
    if (options.reserve_tokens >= options.context_window) return error.InvalidLimit;
    return options;
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(io, usage);
        return;
    }
    const options = parse(args) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return err;
    };
    const requested_workspace = options.workspace orelse return error.MissingWorkspace;
    const requested_state = options.state orelse return error.MissingStateDirectory;
    const ghostmux = options.ghostmux orelse return error.MissingGhostmux;
    const socket = options.socket orelse init.environ_map.get("CPI_GHOSTMUX_SOCKET") orelse return error.MissingSocket;
    if (!std.fs.path.isAbsolute(ghostmux) or !std.fs.path.isAbsolute(socket)) return error.AbsolutePathRequired;
    const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, requested_workspace, a);
    var workspace_dir = try std.Io.Dir.cwd().openDir(io, workspace, .{});
    workspace_dir.close(io);
    const state_absolute = try std.fs.path.resolve(a, &.{requested_state});
    const state_parent_path = std.fs.path.dirname(state_absolute) orelse return error.InvalidStateDirectory;
    const state_name = std.fs.path.basename(state_absolute);
    if (state_name.len == 0 or std.mem.eql(u8, state_name, ".") or std.mem.eql(u8, state_name, "..")) return error.InvalidStateDirectory;
    const state_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, state_parent_path, a);
    const state = try std.fs.path.join(a, &.{ state_parent, state_name });
    if (std.mem.eql(u8, state, workspace) or
        (std.mem.startsWith(u8, state, workspace) and
            (workspace.len == 1 or state[workspace.len] == std.fs.path.sep)))
    {
        return error.StateInsideWorkspace;
    }
    const task = if (options.task) |text| text else try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.task_file.?,
        a,
        .limited(128 * 1024),
    );
    if (task.len == 0 or task.len > 128 * 1024 or
        std.mem.indexOfScalar(u8, task, 0) != null)
    {
        return error.InvalidTask;
    }
    var live: ?provider.Provider = null;
    defer if (live) |*settings| settings.deinit();
    if (options.live) live = try provider.Provider.init(a, init.environ_map);
    if (options.fixture_url) |url| {
        const preflight = try Effects.initFixture(a, workspace, url);
        a.free(preflight.mode.fixture.host);
    }
    const mode: @FieldType(Controller.Settings, "model") =
        if (options.fixture_url) |url| .{ .fixture = url } else .{ .live = &live.? };
    try std.Io.Dir.cwd().createDir(io, state, .fromMode(0o700));
    const router = try std.fs.path.join(a, &.{ state, "ghostmux-router" });
    const router_file = try std.Io.Dir.cwd().createFile(io, router, .{ .exclusive = true, .permissions = .fromMode(0o700) });
    router_file.writeStreamingAll(io, @embedFile("guest/ghostmux-router.sh")) catch |err| {
        router_file.close(io);
        return err;
    };
    router_file.close(io);
    const common = @embedFile("guest/common.luau");
    const terminus = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}", .{
        common,
        @embedFile("guest/parser.luau"),
        @embedFile("guest/prompts.luau"),
        @embedFile("guest/terminus.luau"),
    });
    const once = try std.fmt.allocPrint(a, "{s}\n{s}", .{
        common,
        @embedFile("guest/once.luau"),
    });
    const definitions = [_]Controller.Definition{
        .{ .name = "terminus", .source = terminus, .terminal = true, .spawn = true },
        .{ .name = "once", .source = once, .spawnable = true },
    };
    var signals = Signals.init();
    defer signals.deinit();
    const controller = try Controller.open(init.gpa, io, .{
        .directory = state,
        .workspace = workspace,
        .model = mode,
        .ghostmux = ghostmux,
        .ghostmux_socket = socket,
        .ghostmux_router = router,
        .definitions = &definitions,
        .policy_source = @embedFile("guest/access.luau"),
        .context_window = options.context_window,
        .reserve_tokens = options.reserve_tokens,
        .max_output_tokens = options.max_output_tokens,
        .reasoning_effort = options.reasoning_effort,
        .max_model_calls = options.max_model_calls,
    });
    defer controller.deinit();
    const principal = try controller.start(
        "terminus",
        try j.value(a, .{
            .task = task,
            .label = "main",
            .max_turns = options.max_turns,
        }),
        null,
        null,
    );
    var watcher = try io.concurrent(watchSignals, .{ io, controller, principal });
    defer watcher.cancel(io);
    var outcome = try controller.join(principal);
    defer outcome.deinit();
    const result = j.get(outcome.document.value, "result");
    const status = try j.string(result, "status", "failed");
    const output = try j.encode(a, .{
        .worker_status = @tagName(outcome.status),
        .agent_status = status,
        .workspace = workspace,
        .state_dir = state,
        .result = result,
        .@"error" = outcome.diagnostic,
    });
    try std.Io.File.stdout().writeStreamingAll(io, output);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    if (outcome.status != .completed or !std.mem.eql(u8, status, "complete")) return error.AgentFailed;
}
