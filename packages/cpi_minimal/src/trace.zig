//! Opt-in startup tracing for cpi-minimal.
//!
//! Tracing is off unless the caller passes `--trace` or `--trace-file`. By default it
//! lands in `cpi-trace.json` under the session directory; `--trace-file PATH` writes
//! it to `PATH` instead. Spans are recorded with `kit.tracing.begin` at their
//! call sites; this module only owns the lifecycle of the global tracer and the
//! summary.
//!
//! The summary is printed on exit so that a plain terminal run yields startup
//! latencies without opening a trace viewer. It is derived from the exported
//! trace, so a viewer and the summary never disagree about a span's duration.

const std = @import("std");
const kit = @import("kit");

const tracing = kit.tracing;

/// A span whose exact-ended duration the summary reports, in milliseconds.
pub const Milestone = struct {
    /// The span name, matching its `kit.tracing.begin` call site.
    name: []const u8,
    /// Span start relative to the root span start.
    start_ms: f64 = 0,
    /// Span duration.
    duration_ms: f64 = 0,
};

/// Span names the summary reports, in startup order. Offsets are relative to
/// `root`, so the phases add up to the time to a usable interface.
pub const milestones: []const []const u8 = &.{
    "cpi.startup.total",
    "cpi.startup.args",
    "cpi.startup.workspace",
    "cpi.startup.dotenv",
    "cpi.startup.session",
    "cpi.resume.model_selection",
    "cpi.startup.registry",
    "cpi.startup.provider",
    "cpi.controller.create",
    "cpi.controller.skills",
    "cpi.controller.prompt",
    "cpi.controller.gateway",
    "cpi.controller.worker",
    "cpi.controller.worker.session",
    "cpi.controller.worker.tools",
    "cpi.controller.worker.start",
    "cpi.controller.worker.register",
    "cpi.worker.bootstrap",
    "cpi.worker.restore",
    "cpi.worker.initialize",
    "cpi.worker.commit_bootstrap",
    "cpi.controller.refresh",
    "cpi.controller.usage",
    "cpi.controller.recovery_status",
    "cpi.ui.run",
    "cpi.ui.history",
    "cpi.ui.init",
    "cpi.ui.first_draw",
};

pub const Summary = struct {
    entries: []const Milestone,
    /// The root span's duration, or zero when the root span is absent.
    total_ms: f64 = 0,
    events: usize = 0,
};

/// Enables tracing into `directory`'s `cpi-trace.json` when `path` is null, or
/// into `path` when the caller named one. Tracing is off unless the caller passes
/// `--trace` or `--trace-file`, so `init` is never called on a default run. The returned path is
/// allocated from `gpa` and must be passed to `finish`.
pub fn init(io: std.Io, gpa: std.mem.Allocator, path: ?[]const u8, directory: []const u8) !?[]const u8 {
    const out = if (path) |named|
        try gpa.dupe(u8, named)
    else
        try std.fmt.allocPrint(gpa, "{s}/cpi-trace.json", .{directory});
    errdefer gpa.free(out);
    if (std.fs.path.dirname(out)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    tracing.setEnabled(true);
    root_scope = tracing.begin(root_name);
    return out;
}

var root_scope: ?tracing.Scope = null;

/// Ends the root span, writes the Chrome trace to `path` and returns the
/// summary. Always call it once tracing started, including on error paths.
pub fn finish(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Summary {
    if (root_scope) |*scope| {
        _ = scope.end();
        root_scope = null;
    }
    tracing.setEnabled(false);
    tracing.writeChromeTraceFile(io, gpa, path) catch |err| {
        std.debug.print("Could not write trace {f}: {s}\n", .{ std.zig.fmtString(path), @errorName(err) });
        return .{ .entries = &.{} };
    };
    std.debug.print("Trace file: {f}\n", .{std.zig.fmtString(path)});
    return summarize(gpa, io, path) catch .{ .entries = &.{} };
}

/// Formats the summary as lines of text, ending with a newline. The caller
/// owns the returned slice.
pub fn format(gpa: std.mem.Allocator, summary: Summary) !?[]const u8 {
    if (summary.entries.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("startup trace: {d} events, {d:.1} ms total\n", .{ summary.events, summary.total_ms });
    var longest: usize = "span".len;
    for (summary.entries) |entry| longest = @max(longest, entry.name.len);
    try writer.print("  {s: <[3]}  {s: >11}  {s: >11}\n", .{ "span", "start", "duration", longest });
    for (summary.entries) |entry| {
        if (std.mem.eql(u8, entry.name, root_name)) continue;
        try writer.print("  {s: <[3]}  {d: >8.2} ms  {d: >8.2} ms\n", .{ entry.name, entry.start_ms, entry.duration_ms, longest });
    }
    return try out.toOwnedSlice();
}

const root_name = "cpi.startup.total";

fn summarize(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Summary {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(input);
    const warnings: @import("session_protocol").Transaction.SizeSink = .{};
    warnings.report("trace bytes", input.len, 64 * 1024 * 1024);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var recorded: [milestones.len]?Milestone = @splat(null);
    var found = false;
    var root_start: f64 = 0;
    var root_duration: f64 = 0;
    var events: usize = 0;
    var window: kit.json.Tokenizer.Window = .{};
    var parser = kit.tracing.chrome_trace.Parser.init(arena.allocator(), input, &window);
    var event: kit.tracing.chrome_trace.Event = .{};
    while (try parser.next(&event)) {
        events += 1;
        if (event.phase != 'X') continue;
        if (std.mem.eql(u8, event.name, root_name)) {
            root_start = event.timestamp;
            root_duration = event.duration;
            found = true;
        }
        for (milestones, 0..) |name, i| {
            if (!std.mem.eql(u8, name, event.name)) continue;
            recorded[i] = .{
                .name = name,
                .start_ms = event.timestamp / 1000,
                .duration_ms = event.duration / 1000,
            };
            break;
        }
    }
    if (!found) return .{ .entries = &.{} };
    var entries: std.ArrayList(Milestone) = .empty;
    defer entries.deinit(gpa);
    for (recorded) |maybe_entry| {
        var entry = maybe_entry orelse continue;
        entry.start_ms -= root_start / 1000;
        try entries.append(gpa, entry);
    }
    return .{ .entries = try entries.toOwnedSlice(gpa), .total_ms = root_duration / 1000, .events = events };
}
