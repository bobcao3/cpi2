const std = @import("std");

pub const Limits = struct {
    max_rounds: ?u64 = null,
};

pub const default_memory_bytes: usize = 512 * 1024 * 1024;
pub const expected_capability_name_bytes: usize = 128;

pub const Capability = struct { source_name: []const u8, source: []const u8 };
pub const Model = struct {
    model: []const u8 = "deepseek-flash",
    base_url: []const u8 = "https://api.deepseek.com",
    reasoning_effort: ?[]const u8 = null,
    max_output_tokens: u32 = 4096,
    instructions: []const u8 = "",
    credential: []const u8 = "",

    pub fn withThinking(self: Model, profile: @import("thinking.zig").Profile, level: @import("thinking.zig").Level) !Model {
        var result = self;
        result.reasoning_effort = try profile.wire(level);
        return result;
    }
};

pub const Application = struct {
    source: []const u8,
    environment_json: []const u8 = "{}",
    mutable: bool = false,
};
/// Native harness metadata. The selection is a credential reference whose
/// secret is resolved by the host when the model operation is dispatched.
pub const ApplicationModel = struct {
    model: Model,
    selection: @import("json.zig").Value,
};
pub const Delivery = struct {
    input_json: []const u8,
    replace: ?[]const u8 = null,
    boundary: bool = false,
    conversation: ?[]const u8 = null,
    application_model: ?ApplicationModel = null,
};

pub const CatalogCapability = struct { name: []const u8, capability: Capability };
pub const Startup = struct {
    catalog: union(enum) { preserve, fixed: []const CatalogCapability } = .preserve,
    initialize: ?Delivery = null,
    initialize_id: ?[]const u8 = null,
    failure_diagnostic: ?*?@import("json.zig").Document = null,
    prepared_journal: ?*@import("PreparedJournal.zig") = null,
};

pub const ContextJournal = @import("LuauContextJournal.zig").Codec;
pub const ApplicationBindings = @import("LuauContextJournal.zig").ApplicationBindings;

pub const Config = struct {
    context_journal: ContextJournal = @import("LuauContextJournal.zig").default,
    application_bindings: ApplicationBindings = .{},
    application: ?Application = null,
    session_id: []const u8,
    journal_path: []const u8 = "memory:",
    persistence: enum { journal, memory } = .journal,
    workspace: []const u8 = ".",
    model: Model = .{},
    limits: Limits = .{},
    recovery: struct {
        model_progress: bool = false,
        queued: enum { fail, @"resume" } = .fail,
        /// Expose interrupted application work to the harness through the
        /// recovered context. The harness owns the resumable phase machine.
        application_checkpoint: bool = false,
    } = .{},
    endpoint_grants: []const []const u8 = &.{},
    capabilities: []const Capability = &.{},
};

pub const Command = union(enum) {
    input: []const u8,
    steer: struct { content: []const u8, policy: enum { at_boundary, interrupt_generation } = .interrupt_generation },
    cancel,
    lua: []const u8,
    close,
    register_capability: Capability,
    unregister_capability: []const u8,
    run: @import("conversation.zig").Run,
    compact: @import("conversation.zig").Compact,
    branch: @import("conversation.zig").Branch,
    import_conversation: @import("conversation.zig").Import,
    deliver: Delivery,
    cancel_invocation: []const u8,
};

pub const AdapterResponse = @import("port.zig").Response;
pub const AdapterRequest = struct {
    request_id: []const u8,
    json: []const u8,
};
pub const Adapter = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, std.mem.Allocator, std.Io, AdapterRequest) anyerror!AdapterResponse,
};
pub const Adapters = struct { http: ?Adapter = null, rpc: ?Adapter = null };

pub const Notice = struct {
    kind: Kind,
    sequence: u64,
    request_id: []const u8,
    json: []const u8,
    pub const Kind = enum(u32) {
        ready = 1,
        command_committed = 4,
        command_finished = 5,
        ctx_committed = 6,
        tool_started = 7,
        tool_finished = 8,
        progress = 9,
        fault = 10,
        capabilities_committed = 11,
        conversation_committed = 12,
    };
};
pub const Observer = struct {
    context: ?*anyopaque,
    notify: *const fn (?*anyopaque, Notice) anyerror!void,
};
