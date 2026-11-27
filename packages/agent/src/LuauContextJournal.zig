const std = @import("std");
const protocol = @import("session_protocol");
const j = @import("json.zig");
const Value = j.Value;
const Allocator = std.mem.Allocator;

pub const main = "main";

pub fn scope(value: Value) []const u8 {
    const saved = j.get(value, "application_scope");
    return if (saved == .string) saved.string else main;
}

pub fn namespace(a: Allocator, base: []const u8, conversation: []const u8) ![]const u8 {
    if (std.mem.eql(u8, conversation, main)) return base;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, j.sourceHash(conversation) });
}

pub fn entryPrefix(a: Allocator, conversation: []const u8) ![]const u8 {
    if (std.mem.eql(u8, conversation, main)) return "a";
    return std.fmt.allocPrint(a, "a/{s}/", .{j.sourceHash(conversation)});
}

pub const Codec = struct {
    pub const ModelRoute = struct { selection: Value, credential: []const u8 };
    pub const Admission = struct { conversation: []const u8, input: Value };
    pub const DisplaySelection = struct {
        follows_branch: *const fn (Value) bool,
        /// Return the selected historical entry, or an empty string for the root.
        navigation_target: *const fn (Value, Value) ?[]const u8,
    };
    namespace: []const u8,
    action: []const u8,
    contract: protocol.Extensions.Contract,
    capture: *const fn (Allocator, Value, Value) anyerror!?Value,
    materialize: *const fn (Allocator, Value) anyerror!Value,
    /// Projects public conversation documents from private state into the supplied allocator.
    view_documents: ?*const fn (Allocator, Value) anyerror!Value = null,
    extra_contracts: []const protocol.Extensions.Contract = &.{},
    extra_renderers: []const protocol.State.Renderer = &.{},
    checkpoint_actions: ?*const fn (Allocator, *const protocol.Extensions, []const u8, Value, Value, *std.ArrayList(protocol.frames.Action)) anyerror!void = null,
    /// Plan journal upgrades read-only. The actions commit with approved
    /// bootstrap state before the Worker becomes visible.
    bootstrap_actions: ?*const fn (Allocator, *const @import("SessionJournal.zig")) anyerror![]const protocol.frames.Action = null,
    selection: ?*const fn (Allocator, Value) anyerror!?[]const u8 = null,
    display_selection: ?DisplaySelection = null,
    /// Plan model-neutral transcript entries from the committed actor state.
    /// At most one entry per unbound extension write. The entries and writes
    /// publish in the same transaction.
    prepare_display_entries: ?*const fn (Allocator, *const @import("SessionJournal.zig"), []const protocol.frames.Action, []const protocol.frames.Action) anyerror![]const protocol.frames.MessageAppend = null,
    /// Select a newly admitted task using the transaction's provisional
    /// extension state. The Worker runs the application without effects and
    /// publishes its placement with the caller's actions when the application
    /// returns admission_commit=true.
    prepare_admission: ?*const fn (Allocator, *const @import("SessionJournal.zig"), *const protocol.Extensions) anyerror!?Admission = null,
    scoped_application: bool = false,
    /// A task kind supplied by a harness that owns cancellation of remote jobs.
    model_cancel_task: ?[]const u8 = null,
    /// Return pending provider polls to the harness with a durable wake deadline.
    defer_model_poll: bool = false,
    /// Permit a harness to project a replacement request input into an
    /// isolated, model-only context, including raw provider tool items.
    request_input_projection: bool = false,
    /// Recover a route reference from a historical context for requests
    /// journaled before model frames carried their route selection.
    legacy_model_route: ?*const fn (Allocator, Value, @FieldType(protocol.frames.Action, "control.set_model")) anyerror!?ModelRoute = null,
};

pub const ApplicationBindings = struct {
    pub const Claim = struct { value: Value, action: ?protocol.frames.Action = null };

    // The embedding harness keeps context alive until the worker has joined.
    context: ?*anyopaque = null,
    claim_boundary_input: ?*const fn (?*anyopaque, Allocator, *const protocol.Extensions, []const u8, Value, []const u8) anyerror!?Claim = null,
    read_options: ?*const fn (?*anyopaque, Allocator) anyerror!Value = null,

    pub fn options(self: ApplicationBindings, a: Allocator) !Value {
        const read = self.read_options orelse return .null;
        return read(self.context, a);
    }
};

pub const default: Codec = .{
    .namespace = "agent.luau.ctx",
    .action = "capture",
    .contract = .{ .version = .{ .id = "agent.luau.ctx", .version = "1" }, .initial_state = initial, .validate = validate, .reduce = reduce },
    .capture = capture,
    .materialize = materialize,
};
fn initial(_: Allocator) !Value {
    return .{ .string = "{}" };
}
fn validate(previous: Value, action: []const u8, input: Value) !void {
    if (previous != .string or input != .string or !std.mem.eql(u8, action, "capture")) return error.InvalidLuauContext;
}
fn reduce(a: Allocator, _: Value, _: []const u8, input: Value) !Value {
    _ = try materialize(a, input);
    return input;
}
fn capture(a: Allocator, before: Value, after: Value) !?Value {
    if (try j.equal(a, before, after)) return null;
    return .{ .string = try j.encode(a, after) };
}
fn materialize(a: Allocator, state: Value) !Value {
    if (state != .string) return error.InvalidLuauContext;
    return j.parse(a, state.string);
}
