const std = @import("std");
const thinking = agent.thinking;
const kit = @import("kit");
const agent = @import("agent");
const services = @import("services");
const registry = @import("model_registry");
const transport = agent.provider;
const j = @import("../json.zig");
const Session = @import("Session.zig");
const Paths = @import("../config.zig").Paths;
const Usage = @import("Usage.zig");
const coding_tools = @import("../tools.zig").builtins;
const compaction = @import("compaction.zig");
const AssistantContent = @import("AssistantContent.zig");
const prompts = @import("prompts.zig");
const Skills = @import("../skills.zig");
const Auth = @import("../providers.zig").Auth;
const mcp = @import("mcp");
const McpConfig = @import("../tools.zig").McpConfig;
const Mcp = @import("../tools.zig").Mcp;
const ScriptOutput = @import("../tools.zig").ScriptOutput;
const Inbox = @import("Inbox.zig");
const SessionName = @import("SessionName.zig");
const ContextJournal = @import("ContextJournal.zig");
const ScopedRoutes = @import("../providers.zig").ScopedRoutes;
const ImageProcessing = @import("../images.zig").ImageProcessing;
const ToolLoadout = @import("../tools.zig").ToolLoadout;
const codemode_store_entry = "pi.codemode-store";
const SearchTools = @import("../tools.zig").SearchTools;
const TaskScheduler = agent.TaskScheduler;
const TaskJournal = agent.TaskJournal;
pub const ModelSelection = @import("../providers.zig").ModelSelection;
const Self = @This();
const Value = j.Value;
pub const DeferredTools = @import("../tools.zig").DeferredTools;
pub const InputEntry = Inbox.InputEntry;
pub const Prepared = struct {
    text: []const u8,
    original: []const u8,
    submission: ?[]const u8 = null,
    entry: ?InputEntry = null,
    user_content: Value = .null,
    held: bool = false,
    compaction_seed: bool = false,

    pub fn firstReady(inputs: []const Prepared) ?usize {
        for (inputs, 0..) |entry, index| if (!entry.held and entry.compaction_seed) return index;
        for (inputs, 0..) |entry, index| if (!entry.held) return index;
        return null;
    }
};
pub const Provider = transport.Provider;
pub const CodexTransportPreference = transport.CodexTransportPreference;
pub const Retry = transport.Retry;
pub const DeferredRoute = ScopedRoutes.DeferredRoute;
pub const AfterFailedRun = enum { keep, @"continue", withdraw };
pub const QueueMode = Inbox.QueueMode;
pub const RunPolicy = packed struct(u8) {
    auto_compact: bool = true,
    queue: Inbox.QueueModes = .{},
    block_images: bool = false,
    auto_resize_images: bool = true,
    reserved: u3 = 0,
};
pub const AfterRunSummary = struct {
    reason: enum { answer, terminate },
    first: []const u8,
    answer: []const u8,
    last: []const u8,
};
pub const AfterRun = struct {
    pub const Task = struct { kind: []const u8, input: Value = .null };
    context: ?*anyopaque = null,
    plan: *const fn (?*anyopaque, TaskScheduler.Invocation, AfterRunSummary) anyerror![]const Task,
};
pub const CompactionReason = enum { manual, threshold, overflow };
pub const BeforeCompact = struct {
    pub const Request = struct {
        reason: CompactionReason,
        entries: []const Value,
        messages: []const Value,
        first_kept: []const u8,
        instructions: ?[]const u8 = null,
    };
    pub const Decision = union(enum) { decline, summary: []const u8 };
    context: ?*anyopaque = null,
    decide: *const fn (?*anyopaque, TaskScheduler.Invocation, Request) anyerror!?Decision,
};
pub const ToolCall = struct { name: []const u8, call_id: []const u8, arguments: Value };
pub const ToolDiagnostic = struct {
    code: enum { tool_unavailable, invalid_arguments, invalid_tool_output, blocked, interrupted, restart_limit, tool_error, aborted, abandoned },
    message: []const u8,
};
pub const ToolControl = struct { handoff: ?[]const u8 = null, terminate: ?bool = null };
pub const ToolResult = struct { result: Value, control: ?ToolControl = null, diagnostic: ?ToolDiagnostic = null };
pub const BeforeTool = struct {
    pub const Decision = union(enum) { block: []const u8, arguments: Value };
    context: ?*anyopaque = null,
    decide: *const fn (?*anyopaque, TaskScheduler.Invocation, ToolCall) anyerror!?Decision,
};
pub const AfterTool = struct {
    context: ?*anyopaque = null,
    transform: *const fn (?*anyopaque, TaskScheduler.Invocation, ToolCall, ToolResult) anyerror!?ToolResult,
};
pub const GenerationHooks = struct {
    pub const ToolRound = struct { assistant: []const u8, results: []const []const u8 };

    context: ?*anyopaque = null,
    before_request: ?*const fn (?*anyopaque, TaskScheduler.Invocation, []const Value) anyerror!?[]const Value = null,
    before_provider_request: ?@FieldType(transport.PayloadHook, "transform") = null,
    after_response: ?*const fn (?*anyopaque, TaskScheduler.Invocation, Value) anyerror!void = null,
    on_yield: ?*const fn (?*anyopaque, TaskScheduler.Invocation, Value) anyerror!?Value = null,
    after_tools: ?*const fn (?*anyopaque, TaskScheduler.Invocation, ToolRound) anyerror!void = null,
};
pub const codec: @FieldType(agent.Config, "context_journal") = .{
    .namespace = ContextJournal.namespace,
    .action = ContextJournal.action,
    .contract = ContextJournal.contract,
    .capture = ContextJournal.capture,
    .materialize = ContextJournal.materialize,
    .view_documents = ContextJournal.viewDocuments,
    .selection = ContextJournal.selection,
    .display_selection = .{ .follows_branch = SessionName.displayEntry, .navigation_target = ContextJournal.navigationTarget },
    .extra_contracts = &.{ Inbox.contract, TaskJournal.contract, SessionName.contract },
    .checkpoint_actions = applicationCheckpoint,
    .bootstrap_actions = Inbox.restoreLegacyHolds,
    .prepare_display_entries = Inbox.prepareDisplayEntries,
    .prepare_admission = prepareAdmission,
    .scoped_application = true,
    .model_cancel_task = provider_cancel_task,
    .defer_model_poll = true,
    .request_input_projection = true,
    .legacy_model_route = legacyModelRoute,
};
const Opening = struct {
    previous: ?ModelSelection,
    reason: enum { session, provider_selection, provider_rollback } = .session,
    prepared: ?*agent.PreparedJournal = null,
};

fn applicationCheckpoint(a: std.mem.Allocator, extensions: *const agent.session_protocol.Extensions, conversation: []const u8, before: Value, after: Value, actions: *std.ArrayList(agent.session_protocol.frames.Action)) !void {
    try Inbox.checkpoint(a, extensions, conversation, before, after, actions);
    const request = j.get(after, "background_compaction");
    const head = j.text(j.get(request, "head"));
    const owner = j.text(j.get(request, "owner"));
    if (head.len == 0 or owner.len == 0 or
        (j.equal(j.get(j.get(before, "background_compaction"), "head"), head) and
            j.equal(j.get(j.get(before, "background_compaction"), "owner"), owner))) return;
    const session = j.get(after, "session");
    if (!j.equal(j.get(session, "head"), head) or !j.equal(j.get(j.get(session, "run"), "owner"), owner)) return;
    const saved = extensions.get(TaskJournal.namespace) orelse return;
    const records = TaskJournal.taskValues(saved.value);
    if (records != .object) return;
    for (records.object.values()) |record| {
        if (!j.equal(j.get(record, "conversation"), conversation) or
            j.get(j.get(record, "state"), "terminal") != .null) continue;
        if (isConversationCompaction(record)) return;
        if (!j.equal(j.get(record, "kind"), foreground_kind)) continue;
        const work = j.get(j.get(record, "input"), "work");
        if (j.equal(work, "automatic_compaction") or j.equal(work, "compact")) return;
    }
    const id = Inbox.inputHash(try std.fmt.allocPrint(a, "background-compaction/{s}/{s}/{s}", .{ conversation, owner, head }));
    if (records.object.contains(&id)) return;
    try actions.append(a, try TaskJournal.action(a, saved.head, .{
        .now_ms = j.number(j.get(request, "at")),
        .operation = .{ .submit = .{
            .id = try a.dupe(u8, &id),
            .kind = background_compaction_kind,
            .conversation = conversation,
            .background = true,
            .input = try j.value(a, .{ .reason = CompactionReason.threshold }),
        } },
    }));
}

fn isConversationCompaction(record: Value) bool {
    const kind = j.get(record, "kind");
    return j.equal(kind, manual_compaction_kind) or j.equal(kind, background_compaction_kind);
}

fn prepareAdmission(a: std.mem.Allocator, journal: *const agent.SessionJournal, next: *const agent.session_protocol.Extensions) !?agent.ApplicationAdmission {
    const previous = if (journal.state.extensions.get(TaskJournal.namespace)) |saved| TaskJournal.taskValues(saved.value) else .null;
    const tasks = TaskJournal.taskValues((next.get(TaskJournal.namespace) orelse return null).value);
    if (tasks != .object) return null;
    for (tasks.object.keys(), tasks.object.values()) |id, task| {
        if (j.get(previous, id) != .null) continue;
        const conversation = j.text(j.get(task, "conversation"));
        const input = j.get(task, "input");
        const submission = j.text(j.get(input, "submission"));
        if (conversation.len == 0 or submission.len == 0) continue;
        const is_write = j.equal(j.get(task, "kind"), write_task);
        if (!is_write and (!j.equal(j.get(task, "kind"), foreground_kind) or !j.equal(j.get(input, "work"), "turn"))) continue;
        const scoped = try Inbox.scopeNamespace(a, conversation);
        const inbox = (next.get(scoped) orelse continue).value;
        const datagram = j.get(inbox, submission);
        if (Inbox.disposition(datagram) != .pending or Inbox.held(datagram)) continue;
        if (earlierAdmission(previous, conversation)) continue;
        const namespace = try agent.applicationScopeNamespace(a, ContextJournal.namespace, conversation);
        if (journal.state.extensions.get(namespace)) |saved| {
            const ctx = try ContextJournal.materialize(a, saved.value);
            if (j.get(j.get(ctx, "session"), "run") != .null or j.get(ctx, "after_run") != .null or
                j.get(ctx, "__interrupted_application") != .null or j.get(ctx, "foreground_continuation") != .null) continue;
        }
        var payload = if (is_write) try j.value(a, .{ .command = "drain_writes" }) else try Inbox.deliveredPrompt(a, submission, j.get(datagram, "input"));
        try payload.object.put(a, "foreground_task", j.string(try a.dupe(u8, id)));
        try payload.object.put(a, "admit_only", .{ .bool = true });
        if (is_write) try payload.object.put(a, "inbox_owner", .{ .bool = true });
        const selection = j.get(datagram, "model_selection");
        if (selection != .null) try payload.object.put(a, "submission_selection", try j.copy(a, selection));
        return .{ .conversation = try a.dupe(u8, conversation), .input = payload };
    }
    return null;
}

fn earlierAdmission(tasks: Value, conversation: []const u8) bool {
    if (tasks != .object) return false;
    for (tasks.object.values()) |task| {
        if (!j.equal(j.get(task, "conversation"), conversation) or j.get(j.get(task, "state"), "terminal") != .null) continue;
        const kind = j.get(task, "kind");
        if (j.equal(kind, foreground_kind) or j.equal(kind, write_task)) return true;
    }
    return false;
}

pub const Settings = struct {
    workspace: []const u8,
    saved_workspace: ?[]const u8 = null,
    session_directory: []const u8,
    session_root: ?[]const u8 = null,
    session_path: ?[]const u8,
    context_window: u64 = 128000,
    reserve_tokens: u64 = 16384,
    keep_recent_tokens: u64 = 20000,
    background_compaction_tokens: u64 = 32768,
    max_output_tokens: u32 = 16384,
    registry_provider: ?*const registry.Provider = null,
    registry: ?*const registry.Registry = null,
    // Live metadata applies only to this explicit selection, never to the catalog.
    selected_metadata: ?registry.Model = null,
    strict_registry: bool = false,
    registry_context: bool = false,
    registry_output: bool = false,
    reasoning_effort: ?[]const u8 = null,
    thinking_levels: ?[]const u8 = null,
    user_skill_paths: []const []const u8 = &.{},
    skill_paths: []const []const u8 = &.{},
    no_skills: bool = false,
    enable_skill_commands: ?bool = null,
    mcp_config: ?[]const u8 = null,
    no_mcp: bool = false,
    mcp_project: bool = false,
    tool_loadout: ToolLoadout = .{},
    default_tools: ?[]const []const u8 = null,
    provider_retry: Retry = .{ .max_attempts = 8, .initial_delay_ms = 500, .max_delay_ms = 30000 },
    fresh_retry_limit: ?u8 = null,
    deferred_routes: []const DeferredRoute = &.{},
    after_failed_run: AfterFailedRun = .keep,
    after_run: []const AfterRun = &.{},
    before_compact: []const BeforeCompact = &.{},
    before_tool: []const BeforeTool = &.{},
    after_tool: []const AfterTool = &.{},
    generation_hooks: []const GenerationHooks = &.{},
    run_policy: RunPolicy = .{},
    codex_sessions: ?*transport.CodexSessions = null,
    image_processing: bool = false,
    codex_transport_preference: ?*std.atomic.Value(CodexTransportPreference) = null,
    codex_transport_pinned: bool = false,
    auth_path: ?[]const u8 = null,
    auth_legacy_path: ?[]const u8 = null,
    refresh_saved_auth: bool = false,
    auth_store: ?*const Auth.Store = null,
    startup_size_warnings: []const services.SizeWarning = &.{},
    model_override: ?[]const u8 = null,
    route_override: bool = false,
    launch_effort: ?[]const u8 = null,
    batch_conversation: ?[]const u8 = null,
    task_definitions: []const TaskScheduler.Definition = &.{},
    task_settings: TaskScheduler.Settings = .{},
};
pub const EventKind = enum { user, user_shell, assistant_start, text_delta, reasoning_delta, assistant, thinking, tool_arguments_start, tool_arguments_delta, tool_arguments_end, tool_start, tool_update, tool_end, compacting, compacted, compaction_declined, compaction_failed, branch_summary, provider_retry, size_warning, notice };
pub const ToolImage = struct {
    mime_type: []const u8,
    dimensions: ?kit.media.image_dimensions.Dimensions,

    pub fn copy(a: std.mem.Allocator, images: []const ToolImage) ![]const ToolImage {
        const owned = try a.dupe(ToolImage, images);
        for (owned) |*image| image.mime_type = try a.dupe(u8, image.mime_type);
        return owned;
    }
};
/// One projection of controller activity. `call_id` identifies a tool call from
/// its first streamed argument through its recorded result; it is empty when the
/// publisher had no call to name.
pub const RetryProgress = struct {
    attempt: u64,
    max_attempts: ?u64,
    delay_ms: u64,
};

pub const Event = struct {
    kind: EventKind,
    text: []const u8 = "",
    name: []const u8 = "",
    call_id: []const u8 = "",
    entry_id: []const u8 = "",
    tool_delivery: []const u8 = "",
    data: Value = .null,
    arguments: Value = .null,
    images: []const ToolImage = &.{},
    reply: AssistantContent = .{},
    tokens: u64 = 0,
    resuming: bool = false,
    retry: ?RetryProgress = null,
    compaction_tokens_before: ?u64 = null,
    has_context_usage: bool = false,
    tool_started: ?std.Io.Timestamp = null,
    tool_duration_ms: ?i64 = null,
};
pub const Sink = struct { context: ?*anyopaque, emit: *const fn (?*anyopaque, Event) anyerror!void };

pub const session_extension = ".jsonl.zst";

pub fn isSessionName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, session_extension) or std.mem.endsWith(u8, name, ".jsonl.gz");
}

a: std.mem.Allocator,
gpa: std.mem.Allocator,
io: std.Io,
settings: Settings,
active_tools: []const ToolLoadout.Tool,
tool_launch: [32]u8,
run_policy: std.atomic.Value(u8),
read_auto_resize_images: std.atomic.Value(bool),
provider: *Provider,
unavailable_model: ?ModelSelection = null,
scoped_routes: ScopedRoutes,
scoped_defaults: Value = .null,
scoped_limit_overrides: registry.selection.Overrides = .{},
effort_override: bool = false,
selected_effort: ?thinking.Level = null,
selection_healthy: bool = true,
recovery_available: std.atomic.Value(bool) = .init(false),
auth_revision: std.atomic.Value(u64) = .init(0),
credential_mutex: std.Io.Mutex = .init,
session: Session,
ephemeral_session_id: ?[32]u8 = null,
view_arena: std.heap.ArenaAllocator,
gateway: *agent.Controller,
worker: ?agent.WorkerId = null,
task_bindings: []const TaskScheduler.Definition = &.{},
tasks: ?*TaskScheduler = null,
foreground_mutex: std.Io.Mutex = .init,
foreground_ready: std.atomic.Value(bool) = .init(false),
root_scheduling: std.atomic.Value(bool) = .init(false),
foreground_task: ?[64]u8 = null,
active_request: ?*agent.Request = null,
exec: services.Exec,
files: services.Files,
search_tools: SearchTools,
shell_environment: std.process.Environ.Map,
system_prompt: []const u8,
skills: Skills,
skill_options: Skills.Options,
mcp_gateway: *mcp.Gateway,
startup_warnings: std.ArrayList(services.SizeWarning) = .empty,
sink: ?Sink = null,
sink_mutex: std.Io.Mutex = .init,
sink_callbacks: usize = 0,
sink_idle: std.Io.Event = .unset,
stop: std.atomic.Value(bool) = .init(false),
context_tokens: std.atomic.Value(u64) = .init(0),
usage_stats: Usage.Stats = .{},
usage_context_tokens: u64 = 0,
usage_mutex: std.Io.Mutex = .init,
session_name_mutex: std.Io.Mutex = .init,
summarizing: std.atomic.Value(bool) = .init(false),
completion_mutex: std.Io.Mutex = .init,
delivered: std.StringHashMapUnmanaged(DeliveryState) = .empty,
delivery_failure: ?anyerror = null,
notification_ready: std.Io.Event = .unset,
visible_invocation: ?[]u8 = null,
steering_mutex: std.Io.Mutex = .init,
steering_token: []const u8 = "",
steering_target: []const u8 = "",
session_change_mutex: std.Io.Mutex = .init,

pub fn create(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, settings: Settings, provider: *Provider, environ: *const std.process.Environ.Map, opening: Opening) !*Self {
    const paths = try Paths.init(a, environ);
    const home = paths.home;
    const agent_dir = paths.config;
    const skill_options: Skills.Options = .{
        .cwd = settings.workspace,
        .home = home,
        .agent_dir = agent_dir,
        .user_paths = settings.user_skill_paths,
        .explicit_paths = settings.skill_paths,
        .no_skills = settings.no_skills,
        .enable_skill_commands = settings.enable_skill_commands,
    };
    var skills = blk: {
        var scope = kit.tracing.begin("cpi.controller.skills");
        defer _ = scope.end();
        break :blk try Skills.load(gpa, io, skill_options);
    };
    errdefer skills.deinit();
    const output = try std.fs.path.join(a, &.{ settings.session_directory, "tool-output" });
    try std.Io.Dir.cwd().createDirPath(io, output);
    const self = try a.create(Self);
    var config_warnings: StartupSizeWarnings = .{ .allocator = gpa, .operation = "MCP" };
    defer config_warnings.values.deinit(gpa);
    try config_warnings.values.appendSlice(gpa, settings.startup_size_warnings);
    const mcp_config = try McpConfig.load(gpa, io, .{
        .explicit_path = settings.mcp_config,
        .no_mcp = settings.no_mcp or settings.tool_loadout.disabled == .all,
        .allow_project = settings.mcp_project,
        .agent_dir = paths.config,
        .workspace = settings.workspace,
        .environment = environ,
        .size_warnings = .{ .context = &config_warnings, .notify = StartupSizeWarnings.collect },
    });
    const mcp_gateway = try mcp.Gateway.init(gpa, io, mcp_config, .{
        .environment = environ,
        .output_directory = output,
        .size_warnings = .{ .context = self, .notify = mcpSizeWarning },
    });
    errdefer mcp_gateway.deinit();
    const active_tools = try settings.tool_loadout.resolve(a, settings.default_tools, (try exposedMcpNames(a, mcp_gateway)).len != 0);
    var tool_nonce: [16]u8 = undefined;
    io.random(&tool_nonce);
    const system_prompt = blk: {
        var scope = kit.tracing.begin("cpi.controller.prompt");
        defer _ = scope.end();
        const mcp_prompt = if (std.mem.indexOfScalar(ToolLoadout.Tool, active_tools, .execute_lua) != null) try mcp_gateway.promptSection(a) else "";
        break :blk try prompts.system(gpa, settings.workspace, active_tools, try skills.prompt(a, ToolLoadout.reader(active_tools)), mcp_prompt);
    };
    self.* = .{
        .a = a,
        .gpa = gpa,
        .io = io,
        .settings = settings,
        .active_tools = active_tools,
        .tool_launch = std.fmt.bytesToHex(tool_nonce, .lower),
        .run_policy = .init(@bitCast(settings.run_policy)),
        .read_auto_resize_images = .init(settings.run_policy.auto_resize_images),
        .provider = provider,
        .unavailable_model = if (std.mem.eql(u8, provider.api_key, "unconfigured")) opening.previous else null,
        .scoped_routes = .{
            .workspace = settings.workspace,
            .retry = settings.provider_retry,
            .providers = if (settings.registry) |catalog| catalog.providers() else if (settings.registry_provider) |offer| @as(*const [1]registry.Provider, offer)[0..] else &.{},
            .auth_path = settings.auth_path,
            .legacy_path = settings.auth_legacy_path,
            .environment = if (settings.auth_store) |auth| auth.environment else null,
            .environment_provider_id = if (settings.auth_store) |auth| auth.environment_provider_id else null,
            .base_url_override = if (settings.auth_store) |auth| auth.base_url_override else null,
            .size_warnings = self.authSizeSink(),
            .auth_revision = &self.auth_revision,
        },
        .effort_override = settings.reasoning_effort != null,
        .session = .{ .path = settings.session_path },
        .view_arena = std.heap.ArenaAllocator.init(gpa),
        .gateway = undefined,
        .exec = undefined,
        .files = .{
            .workspace = settings.workspace,
            .inline_images = if (!settings.image_processing) null else .{
                .context = self,
                .classify = ImageProcessing.detect,
                .process = prepareReadImage,
            },
        },
        .shell_environment = .init(gpa),
        .search_tools = .{ .environment = &self.shell_environment },
        .system_prompt = system_prompt,
        .skills = skills,
        .skill_options = skill_options,
        .mcp_gateway = mcp_gateway,
    };
    errdefer gpa.free(system_prompt);
    if (settings.registry_context and settings.registry == null) {
        if (settings.registry_provider) |offer| if (offer.find(provider.model)) |entry| {
            self.settings.context_window = entry.context_window orelse settings.context_window;
        };
    }
    if (self.settings.context_window <= settings.reserve_tokens or self.settings.keep_recent_tokens == 0 or self.settings.max_output_tokens == 0) return error.InvalidContextSettings;
    self.settings.after_run = try a.dupe(AfterRun, settings.after_run);
    self.settings.before_compact = try a.dupe(BeforeCompact, settings.before_compact);
    self.settings.before_tool = try a.dupe(BeforeTool, settings.before_tool);
    self.settings.after_tool = try a.dupe(AfterTool, settings.after_tool);
    self.settings.generation_hooks = try a.dupe(GenerationHooks, settings.generation_hooks);
    self.scoped_routes.deferred_routes = try ScopedRoutes.ownDeferredRoutes(a, settings.deferred_routes);
    self.resolveEffort(settings.reasoning_effort orelse self.savedEffort(opening.previous)) catch |err| {
        if (try self.thinkingProfile()) |profile| {
            std.debug.print("Supported thinking levels:", .{});
            for (thinking.levels) |level| if (profile.supports(level)) {
                std.debug.print(" {s}", .{@tagName(level)});
            };
            std.debug.print("\n", .{});
        }
        return err;
    };
    errdefer self.view_arena.deinit();
    self.scoped_defaults = try self.configuration(a);
    self.scoped_limit_overrides = .{
        .context_window = if (settings.registry_context) null else settings.context_window,
        .max_output_tokens = if (settings.registry_output) null else settings.max_output_tokens,
    };
    self.sink_idle.set(io);
    errdefer self.shell_environment.deinit();
    var env = environ.iterator();
    while (env.next()) |entry| try self.shell_environment.put(entry.key_ptr.*, entry.value_ptr.*);
    self.exec = .{ .directory = output, .environment = &self.shell_environment, .observation_allocator = gpa };
    errdefer self.exec.deinit(io, .terminate);
    self.gateway = try self.openGateway();
    errdefer self.gateway.close();
    self.worker = try self.openWorker(self.gateway, settings.session_path, opening);
    errdefer self.gateway.stop(self.worker.?) catch {};
    const task_bindings = try a.alloc(TaskScheduler.Definition, 12 + settings.task_definitions.len);
    task_bindings[0] = .{ .kind = registration_task, .context = self, .run = runRegistrationTask, .replay_safe = true };
    task_bindings[1] = .{ .kind = provider_cancel_task, .context = self, .run = runProviderCancelTask, .replay_safe = true };
    task_bindings[2] = .{
        .kind = foreground_kind,
        .context = self,
        .run = runForegroundTask,
        .recover_invocation = runForegroundTask,
        .cleanup = cleanupForegroundTask,
        .manages_restarts = true,
        .ready_in_conversation = foregroundReady,
    };
    const phase_definition: TaskScheduler.Definition = .{
        .kind = model_kind,
        .context = self,
        .run = runPhaseTask,
        .recover_invocation = runPhaseTask,
        .cleanup = cleanupPhaseTask,
        .manages_restarts = true,
        .ready_task = foregroundChildReady,
    };
    task_bindings[3] = phase_definition;
    task_bindings[4] = phase_definition;
    task_bindings[4].kind = tool_kind;
    task_bindings[5] = .{
        .kind = write_task,
        .context = self,
        .run = runWriteTask,
        .recover_invocation = runWriteTask,
        .cleanup = cleanupWriteTask,
        .manages_restarts = true,
    };
    task_bindings[6] = .{
        .kind = after_run_kind,
        .context = self,
        .run = runAfterRunTask,
        .recover_invocation = runAfterRunTask,
        .cleanup = cleanupAfterRunTask,
        .ready_task = foregroundChildReady,
    };
    task_bindings[7] = .{
        .kind = before_compact_kind,
        .context = self,
        .run = runBeforeCompactTask,
        .recover_invocation = runBeforeCompactTask,
        .cleanup = cleanupBeforeCompactTask,
        .ready_task = foregroundChildReady,
    };
    task_bindings[8] = .{
        .kind = tool_hook_kind,
        .context = self,
        .run = runToolHookTask,
        .recover_invocation = runToolHookTask,
        .cleanup = cleanupPhaseTask,
        .manages_restarts = true,
        .ready_task = foregroundChildReady,
    };
    task_bindings[9] = .{
        .kind = generation_hook_kind,
        .context = self,
        .run = runGenerationHookTask,
        .recover_invocation = runGenerationHookTask,
        .cleanup = cleanupPhaseTask,
        .manages_restarts = true,
        .ready_task = foregroundChildReady,
    };
    task_bindings[10] = .{
        .kind = manual_compaction_kind,
        .context = self,
        .run = runConversationCompaction,
        .recover_invocation = runConversationCompaction,
        .cleanup = cleanupConversationCompaction,
    };
    task_bindings[11] = task_bindings[10];
    task_bindings[11].kind = background_compaction_kind;
    @memcpy(task_bindings[12..], settings.task_definitions);
    self.task_bindings = task_bindings;
    try self.metadata();
    try self.startTasks();
    errdefer self.closeTasks();
    try self.restoreRegistrations();
    {
        var scope = kit.tracing.begin("cpi.controller.refresh");
        defer _ = scope.end();
        var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
        defer snapshot.deinit();
        try self.refreshContext(snapshot.value);
        try self.refreshRecoveryContext(snapshot.allocator(), snapshot.value);
    }
    self.startup_warnings = config_warnings.values;
    self.settings.startup_size_warnings = &.{};
    config_warnings.values = .empty;
    mcp_gateway.startPreloads();
    return self;
}

pub fn close(self: *Self) void {
    self.closeTasks();
    self.gateway.close();
    self.mcp_gateway.deinit();
    for (self.startup_warnings.items) |warning| services.logSizeWarning(warning);
    self.startup_warnings.deinit(self.gpa);
    self.exec.deinit(self.io, .detach);
    self.view_arena.deinit();
    self.shell_environment.deinit();
    self.skills.deinit();
    self.gpa.free(self.system_prompt);
    var completed = self.delivered.keyIterator();
    while (completed.next()) |id| self.gpa.free(id.*);
    self.delivered.deinit(self.gpa);
    if (self.visible_invocation) |id| self.gpa.free(id);
}

pub fn sessionPath(self: *const Self) []const u8 {
    return self.session.path orelse "(memory)";
}
pub fn processProgress(self: *Self, a: std.mem.Allocator, request_id: []const u8) !?services.Exec.Observation {
    const worker = self.worker orelse return null;
    return self.exec.observeRequest(a, self.io, .{ .scope = worker.scope, .principal = worker.index, .request_id = request_id }, 50 * 1024);
}

fn terminalCommandOwner(id: []const u8) services.Exec.ObservationOwner {
    return .{ .scope = 0, .principal = std.math.maxInt(u64), .request_id = id };
}

pub fn runUserShell(self: *Self, a: std.mem.Allocator, id: []const u8, cwd: []const u8, command: []const u8) !services.Exec.InteractiveResult {
    const args: services.Exec.Args = .{ .argv = &.{ "/bin/bash", "-c", command }, .cwd = cwd };
    const owner = terminalCommandOwner(id);
    return self.exec.captureInteractive(.{
        .allocator = a,
        .io = self.io,
        .idempotency_key = try std.fmt.allocPrint(a, "terminal-shell/{s}", .{id}),
        .scope = owner.scope,
        .principal = owner.principal,
        .request_id = owner.request_id,
    }, args);
}

pub fn userShellProgress(self: *Self, a: std.mem.Allocator, id: []const u8) ![]const u8 {
    const observation = try self.exec.observeRequest(a, self.io, terminalCommandOwner(id), services.output.expected_bytes);
    return if (observation) |value| value.output else "";
}

/// Arena-owned UI projection across credential rotation. Hold the mutex only
/// for publication/copying, never across refresh network IO or backoff.
pub fn providerSnapshot(self: *Self, a: std.mem.Allocator) !Provider {
    self.credential_mutex.lockUncancelable(self.io);
    defer self.credential_mutex.unlock(self.io);
    const current = self.provider;
    return .{ .allocator = a, .kind = current.kind, .base_url = try a.dupe(u8, current.base_url), .responses_url = try a.dupe(u8, current.responses_url), .model = try a.dupe(u8, current.model), .api_key = try a.dupe(u8, current.api_key), .account_id = if (current.account_id) |id| try a.dupe(u8, id) else null, .transport = current.transport, .protocol = current.protocol };
}

pub fn modelName(self: *const Self) []const u8 {
    return self.provider.model;
}
pub fn footerProvider(self: *Self) struct { id: []const u8, subscription: bool } {
    self.credential_mutex.lockUncancelable(self.io);
    defer self.credential_mutex.unlock(self.io);
    const provider = self.catalogProvider(self.provider.model);
    const id = if (provider) |entry| entry.id else self.provider.name();
    return .{
        .id = id,
        .subscription = self.provider.kind == .openai_subscription or std.mem.eql(u8, id, "kimi-coding"),
    };
}
pub fn sessionName(self: *Self, a: std.mem.Allocator) !?[]const u8 {
    try self.session_name_mutex.lock(self.io);
    defer self.session_name_mutex.unlock(self.io);
    const worker = self.worker orelse return error.InvalidSession;
    var document = try self.gateway.readSessionExtension(worker, self.gpa, SessionName.namespace);
    defer document.deinit();
    const value = j.get(document.value, "value");
    if (value != .string) return null;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    self.updatePickerTitle(scratch.allocator(), value.string) catch |err| std.log.warn("Could not update session picker title: {s}", .{@errorName(err)});
    return try a.dupe(u8, value.string);
}

pub fn setSessionName(self: *Self, name: []const u8) !void {
    try self.session_name_mutex.lock(self.io);
    defer self.session_name_mutex.unlock(self.io);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const id = try std.fmt.allocPrint(a, "session-name-{s}", .{try self.requestId(a)});
    const draft: EntryDraft = .{ .kind = SessionName.entry_kind, .data = j.string(name) };
    const write = try conversationWriteWithActivation(a, TaskJournal.main_conversation, id, draft, null, .passive);
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    try tasks.submitWithExtensions(write.task, &.{ write.admission, SessionName.admission(name) });
    self.updatePickerTitle(a, name) catch |err| std.log.warn("Could not update session picker title: {s}", .{@errorName(err)});
}

fn updatePickerTitle(self: *Self, a: std.mem.Allocator, name: []const u8) !void {
    const path = self.session.path orelse return;
    if (!self.sessionFileWritten(path)) return;
    try cacheSessionName(a, self.io, path, name);
}

fn cacheSessionName(a: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) !void {
    const destination = try std.fmt.allocPrint(a, "{s}.title", .{path});
    const cwd = std.Io.Dir.cwd();
    const old = cwd.readFileAlloc(io, destination, a, .limited(name.len)) catch null;
    if (old) |text| if (std.mem.eql(u8, text, name)) return;
    var file = try cwd.createFileAtomic(io, destination, .{
        .replace = true,
        .permissions = .fromMode(0o600),
    });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, name);
    try file.replace(io);
}

pub const SavedSession = struct { path: []const u8, id: []const u8, inode: u64 };

pub fn renameSavedSession(gpa: std.mem.Allocator, io: std.Io, target: SavedSession, name: []const u8) !void {
    try SessionName.validateName(j.string(name));
    var prepared = try agent.PreparedJournal.open(gpa, io, target.path, target.id, codec);
    defer prepared.deinit();
    try prepared.requireFile(target.inode);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const scope = TaskJournal.main_conversation;
    var context = try prepared.applicationContext(a, scope);
    const session = if (context == .object) context.object.getPtr("session") else null;
    var selection: ?Value = null;
    if (session) |saved| {
        if (j.flag(j.get(context, "tree_reopen")) and j.get(saved.*, "run") == .null and j.get(context, "after_run") == .null) {
            if (try prepared.lastOwnedApplicationTip(a, scope)) |tip| {
                const revision = j.number(j.get(saved.*, "revision")) + 1;
                try j.put(a, saved, "head", if (tip.head) |head| j.string(head) else .null);
                try j.put(a, saved, "revision", try j.value(a, revision));
                const navigation = try j.value(a, .{ .revision = revision, .target = tip.target });
                try j.put(a, &context, "tree_navigation", navigation);
                try j.put(a, &context, "tree_reopen", .null);
                selection = context;
            }
        }
    }
    const head = j.get(j.get(context, "session"), "head");
    var random: [32]u8 = undefined;
    io.random(&random);
    const nonce = std.fmt.bytesToHex(random, .lower);
    const id = try std.fmt.allocPrint(a, "adisplay/{s}", .{&nonce});
    const entry = try j.value(a, .{
        .kind = "write",
        .id = id,
        .parent = if (head == .string) head else .null,
        .event_kind = SessionName.entry_kind,
        .data = name,
        .placed_at_ms = std.Io.Clock.real.now(io).toMilliseconds(),
    });
    try prepared.appendApplicationDisplay(target.inode, &nonce, scope, entry, selection, SessionName.admission(name));
    cacheSessionName(a, io, target.path, name) catch {};
}

pub const SavedSessionRemoval = enum { trash, unlink };

pub fn deleteSavedSession(gpa: std.mem.Allocator, io: std.Io, target: SavedSession) !SavedSessionRemoval {
    var prepared = try agent.PreparedJournal.open(gpa, io, target.path, target.id, codec);
    defer prepared.deinit();
    try prepared.requireFile(target.inode);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const title = try std.fmt.allocPrint(a, "{s}.title", .{target.path});
    const cwd = std.Io.Dir.cwd();
    const method: SavedSessionRemoval = method: {
        _ = std.process.run(a, io, .{
            .argv = &.{ "trash", target.path },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        }) catch |err| switch (err) {
            error.Canceled => return err,
            else => null,
        };
        prepared.requireFile(target.inode) catch |err| switch (err) {
            error.FileNotFound => break :method .trash,
            else => return err,
        };
        try cwd.deleteFile(io, target.path);
        break :method .unlink;
    };
    const cancellation = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(cancellation);
    cwd.deleteFile(io, title) catch {};
    try prepared.syncParent();
    return method;
}
pub fn contextTokens(self: *const Self) u64 {
    return self.context_tokens.load(.acquire);
}
pub fn usageStats(self: *Self) Usage.Stats {
    self.usage_mutex.lockUncancelable(self.io);
    defer self.usage_mutex.unlock(self.io);
    return self.usage_stats;
}
pub fn footerUsage(self: *Self) struct { stats: Usage.Stats, context_tokens: u64 } {
    self.usage_mutex.lockUncancelable(self.io);
    defer self.usage_mutex.unlock(self.io);
    return .{ .stats = self.usage_stats, .context_tokens = self.usage_context_tokens };
}

pub const SessionCounts = struct {
    user: usize = 0,
    assistant: usize = 0,
    shell: usize = 0,
    tool_calls: usize = 0,
    tool_results: usize = 0,

    pub fn total(self: SessionCounts) usize {
        return self.user +| self.assistant +| self.shell +| self.tool_results;
    }

    fn add(self: *SessionCounts, entry: Value) void {
        const kind = j.get(entry, "kind");
        if (j.equal(kind, "input")) {
            self.user +|= 1;
        } else if (j.equal(kind, "response")) {
            self.assistant +|= 1;
            self.tool_calls +|= j.items(j.get(entry, "calls")).len;
        } else if (j.equal(kind, "program")) {
            self.tool_results +|= 1;
        } else if (j.equal(kind, "write") and j.equal(j.get(entry, "event_kind"), UserShell.kind)) {
            self.shell +|= 1;
        }
    }
};

pub fn sessionStats(self: *Self, a: std.mem.Allocator) !struct { id: []const u8, messages: SessionCounts, usage: Usage.Stats } {
    const id = try self.sessionIdentifier(a);
    errdefer a.free(id);
    var messages: SessionCounts = .{};
    const usage = try self.collectUsage(&messages);
    return .{ .id = id, .messages = messages, .usage = usage };
}

pub fn sessionIdentifier(self: *const Self, a: std.mem.Allocator) ![]const u8 {
    return if (self.session.path) |path| sessionId(a, self.io, path) else a.dupe(u8, &(self.ephemeral_session_id orelse return error.InvalidSession));
}

fn setUsageStats(self: *Self, stats: Usage.Stats, context_tokens: u64) void {
    self.usage_mutex.lockUncancelable(self.io);
    defer self.usage_mutex.unlock(self.io);
    self.usage_stats = stats;
    self.usage_context_tokens = context_tokens;
}
fn cancelRequest(self: *Self, target: *agent.Request) void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const request = self.gateway.cancelInvocation(self.worker.?, self.requestId(a) catch return, target.id) catch return;
    request.deinit();
}

pub fn cancel(self: *Self) void {
    const root_scheduling = self.root_scheduling.load(.acquire);
    self.steering_mutex.lockUncancelable(self.io);
    const task = self.foreground_task;
    const request = self.active_request;
    if (task != null or !root_scheduling) self.stop.store(true, .release);
    if (task == null and !root_scheduling) if (request) |target| self.cancelRequest(target);
    self.steering_mutex.unlock(self.io);
    if (task) |id| {
        if (self.tasks) |tasks| tasks.abort(&id) catch |err| {
            std.log.warn("Could not request foreground cancellation: {s}", .{@errorName(err)});
        };
        return;
    }
    if (!root_scheduling and request != null) return;
    const marked = self.cancelSavedRun(if (root_scheduling) .root else .inbox) catch |err| blk: {
        std.log.warn("Could not request foreground cancellation: {s}", .{@errorName(err)});
        break :blk false;
    };
    if (root_scheduling and !marked) {
        self.steering_mutex.lockUncancelable(self.io);
        defer self.steering_mutex.unlock(self.io);
        if (self.active_request) |target| self.cancelRequest(target);
    }
}

fn cancelSavedRun(self: *Self, scope: ForegroundOwnerScope) !bool {
    const tasks = self.tasks orelse return false;
    const worker = self.worker orelse return false;
    var context = try self.gateway.readContext(worker, self.gpa);
    defer context.deinit();
    const owner = (try savedForegroundOwner(context.allocator(), context.value, scope)) orelse return false;
    try tasks.abort(owner);
    return true;
}

fn emit(self: *Self, event: Event) !void {
    self.sink_mutex.lockUncancelable(self.io);
    const sink = self.sink;
    if (sink != null) {
        if (self.sink_callbacks == 0) self.sink_idle.reset();
        self.sink_callbacks += 1;
    }
    self.sink_mutex.unlock(self.io);
    if (sink) |target| {
        defer {
            self.sink_mutex.lockUncancelable(self.io);
            self.sink_callbacks -= 1;
            if (self.sink_callbacks == 0) self.sink_idle.set(self.io);
            self.sink_mutex.unlock(self.io);
        }
        try target.emit(target.context, event);
    } else if (event.kind == .size_warning) std.debug.print("{s}\n", .{event.text});
}

// The UI owner calls this outside an emit callback. Return joins the old borrow.
pub fn setSink(self: *Self, sink: ?Sink) void {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    self.sink_mutex.lockUncancelable(self.io);
    self.sink = null;
    self.sink_mutex.unlock(self.io);
    self.sink_idle.wait(self.io) catch unreachable;
    self.sink_mutex.lockUncancelable(self.io);
    self.sink = sink;
    var warnings: std.ArrayList(services.SizeWarning) = .empty;
    if (sink != null) std.mem.swap(@TypeOf(warnings), &warnings, &self.startup_warnings);
    self.sink_mutex.unlock(self.io);
    defer warnings.deinit(self.gpa);
    for (warnings.items) |warning| self.emitSizeWarning(warning) catch services.logSizeWarning(warning);
}

pub fn prepare(self: *Self, a: std.mem.Allocator, text: []const u8) !Prepared {
    const expanded = try self.skills.expand(a, self.io, text);
    if (expanded.diagnostic) |diagnostic| try self.emit(.{ .kind = .notice, .text = try std.fmt.allocPrint(a, "{s}: {s}", .{ diagnostic.path, diagnostic.message }) });
    return .{ .text = expanded.input.text, .original = expanded.input.original };
}

fn imageLimits(self: *const Self) ImageProcessing.Limits {
    return .forModel(self.modelMetadata(self.provider.model));
}

pub fn inputImageLimits(self: *Self, conversation: ?[]const u8) !ImageProcessing.Limits {
    const id = conversation orelse return self.imageLimits();
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, id);
    defer context.deinit();
    const stored = ModelSelection.effective(context.value);
    var inherited = try self.inheritedSelectionContext(id, stored);
    defer if (inherited) |*saved| saved.deinit();
    const selected = if (inherited) |saved| ModelSelection.effective(saved.value) else stored;
    return self.selectionImageLimits(temporary.allocator(), selected);
}

pub fn pendingDatagrams(self: *Self, a: std.mem.Allocator) !agent.JsonDocument {
    return self.conversationDatagrams(a, TaskJournal.main_conversation);
}

pub fn conversationDatagrams(self: *Self, a: std.mem.Allocator, conversation: []const u8) !agent.JsonDocument {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.gateway.readSessionExtension(self.worker.?, a, try Inbox.scopeNamespace(scratch.allocator(), conversation));
}

pub fn queuePaused(self: *Self) !bool {
    return (try self.queueState()).paused;
}

pub fn queueState(self: *Self) !struct { paused: bool, waiting_after_compaction: bool } {
    var snapshot = try self.pendingDatagrams(self.gpa);
    defer snapshot.deinit();
    const value = j.get(snapshot.value, "value");
    return .{ .paused = Inbox.paused(value), .waiting_after_compaction = Inbox.waitingAfterCompaction(value) };
}

pub fn setQueuePaused(self: *Self, paused: bool) !void {
    try self.writeInbox("pause", .{ .bool = paused });
}

pub fn resumeQueue(self: *Self) !void {
    try self.writeInbox("resume_inputs", .null);
}

fn writeInbox(self: *Self, name: []const u8, input: Value) !void {
    return self.writeConversationInbox(TaskJournal.main_conversation, name, input);
}

fn writeConversationInbox(self: *Self, conversation: []const u8, name: []const u8, input: Value) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const namespace = try Inbox.scopeNamespace(a, conversation);
    const tx = try std.fmt.allocPrint(a, "inbox-{s}", .{try self.requestId(a)});
    while (true) {
        var snapshot = try self.gateway.readSessionExtension(self.worker.?, self.gpa, namespace);
        defer snapshot.deinit();
        var change = input;
        if (std.mem.eql(u8, name, "pause")) {
            if (Inbox.paused(j.get(snapshot.value, "value")) == input.bool) return;
        } else if (std.mem.eql(u8, name, "resume_inputs")) {
            if (!Inbox.needsResume(j.get(snapshot.value, "value"))) return;
        } else if (std.mem.eql(u8, name, "settle") or std.mem.eql(u8, name, "withdraw")) {
            change = .{ .object = .empty };
            const current = j.get(snapshot.value, "value");
            if (current != .object) return;
            for (input.object.keys(), input.object.values()) |id, reason| {
                const entry = j.get(current, id);
                const status = Inbox.disposition(entry);
                if (status == .pending or (status == .claimed and j.equal(reason, "aborted") and
                    j.equal(j.get(entry, "kind"), "prompt") and j.get(entry, "continuation") == .null))
                {
                    try change.object.put(snapshot.allocator(), id, reason);
                }
            }
            if (change.object.count() == 0) return;
        } else if (std.mem.eql(u8, name, "enqueue")) {
            change = .{ .object = .empty };
            const current = j.get(snapshot.value, "value");
            for (input.object.keys(), input.object.values()) |id, record| {
                const existing = j.get(current, id);
                if (existing == .null) {
                    try change.object.put(snapshot.allocator(), id, record);
                    continue;
                }
                const digest = j.get(record, "sha256");
                if (digest != .string or !j.equal(j.get(existing, "sha256"), digest.string) or
                    !j.equal(j.get(existing, "kind"), j.text(j.get(record, "kind"))))
                    return error.RequestIdConflict;
            }
            if (change.object.count() == 0) return;
        }
        _ = self.gateway.recordSession(self.worker.?, tx, &.{Inbox.action(namespace, j.number(j.get(snapshot.value, "head")), name, change)}) catch |err| switch (err) {
            error.StaleExtensionHead => continue,
            else => return err,
        };
        return;
    }
}

pub fn enqueuePrompt(self: *Self, input: Prepared, request_id: []const u8) !void {
    return self.enqueueConversationPrompt(TaskJournal.main_conversation, input, request_id);
}

pub fn enqueueConversationPrompt(self: *Self, conversation: []const u8, input: Prepared, request_id: []const u8) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const id = try Inbox.requestId(a, request_id);
    try self.enqueueNamedPrompt(a, conversation, id, try Inbox.promptBody(a, input.text, input.original, input.entry, input.user_content), .null);
}

fn enqueueNamedPrompt(self: *Self, a: std.mem.Allocator, conversation: []const u8, id: []const u8, body: Value, selection: Value) !void {
    const admission = try Inbox.promptAdmission(a, conversation, id, body, selection);
    try self.writeConversationInbox(conversation, admission.action, admission.input.value);
}

pub fn readInputReceipt(a: std.mem.Allocator, io: std.Io, path: []const u8, request_id: []const u8) !?Inbox.Disposition {
    return readConversationInputReceipt(a, io, path, TaskJournal.main_conversation, request_id);
}

pub fn readConversationInputReceipt(a: std.mem.Allocator, io: std.Io, path: []const u8, conversation: []const u8, request_id: []const u8) !?Inbox.Disposition {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var snapshot = try readJournal(a, io, path, .{ .extension = try Inbox.scopeNamespace(scratch.allocator(), conversation) });
    defer snapshot.deinit();
    const id = try Inbox.requestId(snapshot.allocator(), request_id);
    return Inbox.disposition(j.get(snapshot.value, id));
}

pub fn readRunReceipt(a: std.mem.Allocator, io: std.Io, path: []const u8, request_id: []const u8) !Inbox.Receipt {
    return readConversationRunReceipt(a, io, path, TaskJournal.main_conversation, request_id);
}

pub fn readConversationRunReceipt(a: std.mem.Allocator, io: std.Io, path: []const u8, conversation: []const u8, request_id: []const u8) !Inbox.Receipt {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var snapshot = try readJournal(a, io, path, .{ .extension = try Inbox.scopeNamespace(scratch.allocator(), conversation) });
    defer snapshot.deinit();
    const id = try Inbox.requestId(snapshot.allocator(), request_id);
    return Inbox.receipt(a, j.get(snapshot.value, id));
}

pub const EntryDraft = Inbox.EntryDraft;
pub const UserShell = @import("ShellRecord.zig");
pub const WriteSubmission = struct { task: TaskJournal.Submission, admission: agent.ExtensionWrite };

/// The two pieces can be returned with a native task's Step. Supply that
/// task as owner when admitting a write from its handoff.
pub fn conversationWrite(a: std.mem.Allocator, conversation: []const u8, request_id: []const u8, draft: EntryDraft, owner: ?[]const u8) !WriteSubmission {
    return conversationWriteWithActivation(a, conversation, request_id, draft, owner, .normal);
}

fn conversationWriteWithActivation(a: std.mem.Allocator, conversation: []const u8, request_id: []const u8, draft: EntryDraft, owner: ?[]const u8, activation: Inbox.WriteActivation) !WriteSubmission {
    const submission = try Inbox.requestId(a, request_id);
    const key = try agent.session_protocol.Canonical.hash(a, try j.value(a, .{ .kind = write_task, .conversation = conversation, .id = submission, .owner = owner }));
    return .{
        .task = .{
            .id = try a.dupe(u8, &key),
            .kind = write_task,
            .conversation = conversation,
            .owner = owner,
            .input = try j.value(a, .{ .submission = submission }),
        },
        .admission = try Inbox.writeDraft(a, conversation, submission, draft, activation),
    };
}

pub fn enqueueWrite(self: *Self, conversation: []const u8, request_id: []const u8, draft: EntryDraft) !void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const write = try conversationWrite(scratch.allocator(), conversation, request_id, draft, null);
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    try tasks.submitWithExtensions(write.task, &.{write.admission});
}

pub fn recordUserShell(self: *Self, a: std.mem.Allocator, id: []const u8, shell: UserShell) !Value {
    const data = try j.value(a, shell);
    const model_entry: ?EntryDraft.Message = if (shell.excluded) null else .{
        .role = .user,
        .content = .{ .string = try shell.modelText(a) },
    };
    const draft: EntryDraft = .{ .kind = UserShell.kind, .data = data, .model = if (model_entry) |entry| &.{entry} else null };
    const key = try std.fmt.allocPrint(a, "terminal-shell/{s}", .{id});
    const write = try conversationWriteWithActivation(a, TaskJournal.main_conversation, key, draft, null, .passive);
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    try tasks.submitWithExtensions(write.task, &.{write.admission});
    return data;
}

/// Settle terminal shell writes while their original Worker still owns the journal.
pub fn waitUserShellWrites(self: *Self) !void {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var snapshot = try tasks.snapshot(self.gpa);
    defer snapshot.deinit();
    const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
    if (records != .object) return;
    for (records.object.keys(), records.object.values()) |id, task| {
        if (!j.equal(j.get(task, "kind"), write_task) or
            !std.mem.startsWith(u8, j.text(j.get(j.get(task, "input"), "submission")), "request/terminal-shell/") or
            j.get(j.get(task, "state"), "terminal") != .null) continue;
        var outcome = try tasks.wait(self.gpa, id);
        defer outcome.deinit();
        if (!j.equal(j.get(outcome.value, "status"), "completed") or
            !j.equal(j.get(j.get(outcome.value, "value"), "disposition"), "consumed")) return error.ShellRecordPlacementFailed;
    }
}

pub fn submissionReceipt(self: *Self, a: std.mem.Allocator, conversation: []const u8, request_id: []const u8) !Inbox.Receipt {
    var inbox = try self.conversationDatagrams(self.gpa, conversation);
    defer inbox.deinit();
    const submission = try Inbox.requestId(inbox.allocator(), request_id);
    return Inbox.receipt(a, j.get(j.get(inbox.value, "value"), submission));
}

pub const Withdrawal = Inbox.Withdrawal;

pub fn withdrawSubmission(self: *Self, conversation: []const u8, request_id: []const u8) !Withdrawal {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const namespace = try Inbox.scopeNamespace(a, conversation);
    const submission = try Inbox.requestId(a, request_id);
    const tx = try self.requestId(a);
    var selected = j.object();
    try selected.object.put(a, submission, j.string("aborted"));
    while (true) {
        var snapshot = try self.conversationDatagrams(self.gpa, conversation);
        defer snapshot.deinit();
        const entry = j.get(j.get(snapshot.value, "value"), submission);
        switch (Inbox.disposition(entry) orelse return .unknown) {
            .pending => {},
            .claimed => return .already_placed,
            .consumed => return if (j.equal(j.get(j.get(entry, "run"), "status"), "running")) .already_placed else .settled,
            .discarded, .rejected => return .settled,
        }
        _ = self.gateway.recordSession(self.worker.?, tx, &.{Inbox.action(namespace, j.number(j.get(snapshot.value, "head")), "withdraw", selected)}) catch |err| switch (err) {
            error.StaleExtensionHead => continue,
            else => return err,
        };
        return .withdrawn;
    }
}

pub fn writeReceipt(self: *Self, a: std.mem.Allocator, conversation: []const u8, request_id: []const u8) !Inbox.Receipt {
    return self.submissionReceipt(a, conversation, request_id);
}

pub fn enqueueInputs(self: *Self, a: std.mem.Allocator, inputs: []Prepared) !void {
    if (inputs.len == 0) return;
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const records = try self.promptBatch(a, scratch, inputs, null);
    try self.writeInbox("enqueue", records);
    for (inputs, records.object.keys()) |*input, id| {
        input.submission = id;
        input.held = false;
    }
}

pub const CompactionMessage = struct { input: Prepared, steering: bool };

/// The oldest message seeds the next turn. Later messages retain their mode.
pub fn enqueueCompactionMessages(self: *Self, messages: []const CompactionMessage) !void {
    if (messages.len == 0) return;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const seed = try self.requestId(a);
    var target = seed;
    var records = j.object();
    for (messages, 0..) |message, index| {
        const input = message.input;
        const id = if (index == 0) seed else try self.requestId(a);
        const body = try Inbox.promptBody(a, input.text, input.original, input.entry, input.user_content);
        const is_steering = index > 0 and message.steering;
        var record = if (is_steering)
            try steeringRecord(a, target, body)
        else
            try Inbox.promptRecord(a, body, false);
        if (index == 0) try record.object.put(a, "compaction_seed", .{ .bool = true });
        try records.object.put(a, id, record);
        if (is_steering) target = id;
    }
    try self.writeInbox("enqueue", records);
}

fn steeringRecord(a: std.mem.Allocator, target: []const u8, body: Value) !Value {
    return j.value(a, .{
        .kind = Inbox.Kind.steer,
        .target = target,
        .boundary = "model_or_tool",
        .input = body,
    });
}

fn promptBatch(self: *Self, a: std.mem.Allocator, scratch: std.mem.Allocator, inputs: []const Prepared, request_id: ?[]const u8) !Value {
    if (request_id != null and inputs.len != 1) return error.InvalidArguments;
    var records: Value = .{ .object = .empty };
    for (inputs) |input| {
        const id = if (request_id) |named| try Inbox.requestId(a, named) else try self.requestId(a);
        const body = try Inbox.promptBody(scratch, input.text, input.original, input.entry, input.user_content);
        var record = try Inbox.promptRecord(scratch, body, request_id != null);
        if (input.compaction_seed) try record.object.put(scratch, "compaction_seed", .{ .bool = true });
        try records.object.put(scratch, id, record);
    }
    return records;
}

/// Admit the whole batch before recovery can perform any provider work. When
/// the conversation can start immediately, its first task shares this commit.
pub fn submitBatchPrompts(self: *Self, inputs: []const Prepared, request_id: ?[]const u8) !void {
    if (inputs.len == 0) return;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const records = try self.promptBatch(a, a, inputs, request_id);
    if (!self.foreground_mutex.tryLock()) return self.writeInbox("enqueue", records);
    defer self.foreground_mutex.unlock(self.io);

    var saved = try self.pendingDatagrams(a);
    defer saved.deinit();
    const inbox = j.get(saved.value, "value");
    if (Inbox.paused(inbox) or self.recovery_available.load(.acquire)) return self.writeInbox("enqueue", records);

    var submission = records.object.keys()[0];
    var original = inputs[0].original;
    var eligible = Inbox.disposition(j.get(inbox, submission)) == null;
    if (inbox == .object) for (inbox.object.keys(), inbox.object.values()) |id, entry| {
        if (Inbox.disposition(entry) != .pending or Inbox.held(entry) or !j.equal(j.get(entry, "kind"), "prompt")) continue;
        submission = id;
        original = j.text(j.get(j.get(entry, "input"), "original"));
        eligible = true;
        break;
    };
    if (!eligible) return self.writeInbox("enqueue", records);
    const admission: agent.ExtensionWrite = .{ .namespace = Inbox.namespace, .action = "enqueue", .input = .{ .contract = Inbox.contract.version, .value = records } };
    self.rememberPromptTitle(a, original, false);
    try self.submitForegroundTask(a, .turn, submission, &.{admission});
}

fn rememberPromptTitle(self: *Self, a: std.mem.Allocator, original: []const u8, committed: bool) void {
    if (self.session.path) |path| {
        if (!self.sessionFileWritten(path)) return;
        const title_path = std.fmt.allocPrint(a, "{s}.title", .{path}) catch return;
        if (committed and !self.sessionFileWritten(title_path)) {
            if (self.sessionName(a) catch null) |_| return;
        }
        if (std.Io.Dir.cwd().createFile(self.io, title_path, .{ .exclusive = true, .permissions = .fromMode(0o600) })) |file| {
            defer file.close(self.io);
            file.writeStreamingAll(self.io, original[0..@min(original.len, 160)]) catch {};
        } else |_| {}
    }
}

fn sessionFileWritten(self: *const Self, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
    return stat.kind == .file and stat.size != 0;
}

/// The caller supplies an arena for the queued input strings and the slice.
pub fn pendingInputs(self: *Self, a: std.mem.Allocator) ![]Prepared {
    var snapshot = try self.pendingDatagrams(self.gpa);
    defer snapshot.deinit();
    const value = j.get(snapshot.value, "value");
    var result: std.ArrayList(Prepared) = .empty;
    if (value == .object) for (value.object.keys(), value.object.values()) |id, datagram| {
        if (Inbox.disposition(datagram) != .pending or !j.equal(j.get(datagram, "kind"), "prompt")) continue;
        const input = j.get(datagram, "input");
        const custom = j.get(input, "entry");
        try result.append(a, .{
            .text = try a.dupe(u8, j.text(j.get(input, "text"))),
            .original = try a.dupe(u8, j.text(j.get(input, "original"))),
            .submission = try a.dupe(u8, id),
            .entry = if (custom == .null) null else .{ .kind = try a.dupe(u8, j.text(j.get(custom, "kind"))), .data = try j.copy(a, j.get(custom, "data")) },
            .held = Inbox.held(datagram),
            .compaction_seed = j.flag(j.get(datagram, "compaction_seed")),
        });
    };
    return result.toOwnedSlice(a);
}

pub fn reportSkills(self: *Self) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    for (self.skills.diagnostics) |diagnostic| try self.emit(.{ .kind = .notice, .text = try std.fmt.allocPrint(a, "{s}: {s}", .{ diagnostic.path, diagnostic.message }) });
}

pub fn reloadSkills(self: *Self) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var next = try Skills.load(self.gpa, self.io, self.skill_options);
    errdefer next.deinit();
    const system_prompt = try self.buildPrompt(a, &next);
    errdefer self.gpa.free(system_prompt);
    try self.invoke(try j.value(a, .{
        .command = "configure",
        .config = try self.configuration(a),
        .tool_resources = try self.toolResources(a, &next),
    }));
    self.skills.deinit();
    self.skills = next;
    self.gpa.free(self.system_prompt);
    self.system_prompt = system_prompt;
    self.read_auto_resize_images.store(self.runPolicy().auto_resize_images, .monotonic);
}

pub fn steer(self: *Self, input: Prepared) !bool {
    self.steering_mutex.lockUncancelable(self.io);
    defer self.steering_mutex.unlock(self.io);
    if (self.active_request == null and self.foreground_task == null) return false;
    var context = try self.gateway.readContext(self.worker.?, self.gpa);
    defer context.deinit();
    const session = j.get(context.value, "session");
    var target = self.steering_target;
    if (self.active_request == null) {
        const foreground = self.foreground_task.?;
        const saved = j.get(context.value, "foreground_continuation");
        if (!j.equal(j.get(saved, "task"), &foreground) or j.get(session, "run") != .object) return false;
        target = j.text(j.get(session, "last_submission"));
    } else if (target.len > 0 and j.equal(j.get(context.value, "steering_invocation"), self.steering_token)) {
        const latest = j.text(j.get(session, "last_submission"));
        if (latest.len != 0) target = latest;
    }
    if (target.len == 0) return false;
    var snapshot = try self.pendingDatagrams(self.gpa);
    defer snapshot.deinit();
    const state = j.get(snapshot.value, "value");
    if (Inbox.paused(state)) return false;
    if (state == .object) for (state.object.keys(), state.object.values()) |id, entry| {
        if (Inbox.isSteering(entry) and j.equal(j.get(entry, "target"), target)) target = id;
    };
    const a = snapshot.allocator();
    var entries = j.object();
    try entries.object.put(a, try self.requestId(a), try steeringRecord(a, target, try Inbox.promptBody(a, input.text, input.original, input.entry, input.user_content)));
    try self.writeInbox("enqueue", entries);
    return true;
}

pub const PendingMessages = struct {
    worker: agent.WorkerId,
    revision: u64,
    messages: []const Inbox.PendingMessage,
};

const PendingRead = struct {
    allocator: std.mem.Allocator,
    dispatched: ?[]const u8 = null,
    previous: ?u64 = null,
    text: Inbox.PendingMessage.Text = .full,
    revision: u64 = 0,
    messages: ?[]const Inbox.PendingMessage = null,

    fn visit(raw: ?*anyopaque, revision: u64, value: Value) !void {
        const self: *PendingRead = @ptrCast(@alignCast(raw.?));
        self.revision = revision;
        if (self.previous == revision) return;
        self.messages = try Inbox.pendingMessages(self.allocator, value, self.dispatched, self.text);
    }
};

pub fn pendingMessages(self: *Self, a: std.mem.Allocator, dispatched: ?[]const u8) !PendingMessages {
    const worker = self.worker.?;
    var read: PendingRead = .{ .allocator = a, .dispatched = dispatched };
    try self.gateway.visitSessionExtension(worker, Inbox.namespace, .{ .context = &read, .visit = PendingRead.visit });
    return .{
        .worker = worker,
        .revision = read.revision,
        .messages = read.messages.?,
    };
}

pub const QueuePreview = struct {
    arena: std.heap.ArenaAllocator,
    batch: ?PendingMessages = null,

    pub fn messages(self: *const QueuePreview) []const Inbox.PendingMessage {
        return if (self.batch) |batch| batch.messages else &.{};
    }

    pub fn refresh(self: *QueuePreview, controller: *Self) !void {
        const worker = controller.worker.?;
        var next: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer next.deinit();
        var read: PendingRead = .{ .allocator = next.allocator(), .text = .first_line };
        if (self.batch) |batch| if (std.meta.eql(worker, batch.worker)) {
            read.previous = batch.revision;
        };
        try controller.gateway.visitSessionExtension(worker, Inbox.namespace, .{ .context = &read, .visit = PendingRead.visit });
        const rows = read.messages orelse return;
        std.mem.swap(std.heap.ArenaAllocator, &self.arena, &next);
        self.batch = .{ .worker = worker, .revision = read.revision, .messages = rows };
    }
};

/// Settle the complete snapshot, or leave it untouched if a claim or enqueue won.
pub fn withdrawPendingMessages(self: *Self, batch: PendingMessages) !bool {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const tx = try self.requestId(a);
    var selected = j.object();
    for (batch.messages) |message| try selected.object.put(a, message.id, .null);
    // Steering chooses its predecessor while holding this mutex.
    self.steering_mutex.lockUncancelable(self.io);
    defer self.steering_mutex.unlock(self.io);
    _ = self.gateway.recordSession(batch.worker, tx, &.{Inbox.action(Inbox.namespace, batch.revision, "settle", selected)}) catch |err| switch (err) {
        error.StaleExtensionHead => return false,
        else => return err,
    };
    return true;
}

pub fn discardPendingInputs(self: *Self) !void {
    return self.adjustSteering(.settle);
}

pub fn promoteSteering(self: *Self) !void {
    return self.adjustSteering(.follow_up);
}

pub fn preserveSteeringForCompaction(self: *Self) !void {
    self.steering_mutex.lockUncancelable(self.io);
    defer self.steering_mutex.unlock(self.io);
    return self.adjustSteering(.preserve_steering);
}

const SteeringChange = enum { settle, follow_up, preserve_steering };

fn adjustSteering(self: *Self, change: SteeringChange) !void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const tx = try self.requestId(scratch.allocator());
    while (true) {
        var snapshot = try self.pendingDatagrams(self.gpa);
        defer snapshot.deinit();
        const state = j.get(snapshot.value, "value");
        if (state != .object) return;
        var selected = j.object();
        for (state.object.keys(), state.object.values()) |id, entry| {
            const status = Inbox.disposition(entry);
            const include = switch (change) {
                .settle => status == .pending and (Inbox.isSteering(entry) or j.equal(j.get(entry, "kind"), "prompt")),
                .follow_up => Inbox.isSteering(entry) and (status == .pending or status == .claimed),
                .preserve_steering => Inbox.isSteering(entry) and status == .pending,
            };
            if (include) try selected.object.put(snapshot.allocator(), id, .null);
        }
        if (selected.object.count() == 0) return;
        _ = self.gateway.recordSession(self.worker.?, tx, &.{Inbox.action(Inbox.namespace, j.number(j.get(snapshot.value, "head")), @tagName(change), selected)}) catch |err| switch (err) {
            error.StaleExtensionHead => continue,
            else => return err,
        };
        return;
    }
}

fn metadata(self: *Self) !void {
    const session_file = self.sessionPath();
    const stem = std.fs.path.stem(session_file);
    const session_id = if (std.mem.endsWith(u8, stem, ".jsonl")) stem[0 .. stem.len - ".jsonl".len] else stem;
    try self.shell_environment.put("PI_SESSION_FILE", session_file);
    try self.shell_environment.put("PI_SESSION_ID", session_id);
    try self.shell_environment.put("PI_MODEL", self.modelName());
    try self.shell_environment.put("PI_PROVIDER", self.provider.name());
    try self.shell_environment.put("PI_REASONING_LEVEL", self.effortLabel());
}

/// Normalize new `.jsonl` paths and reject nonempty files with the old extension.
pub fn writableSessionPath(a: std.mem.Allocator, io: std.Io, requested: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, requested, ".jsonl")) return requested;
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(io, requested, .{})) |stat| {
        if (stat.kind != .file or stat.size != 0) return error.UnsupportedSessionFormat;
    } else |err| if (err != error.FileNotFound) return err;
    const compressed = try std.fmt.allocPrint(a, "{s}.zst", .{requested});
    errdefer a.free(compressed);
    if (cwd.statFile(io, compressed, .{})) |_| {
        return compressed;
    } else |err| if (err != error.FileNotFound) return err;
    const legacy = try std.fmt.allocPrint(a, "{s}.gz", .{requested});
    if (cwd.statFile(io, legacy, .{})) |_| {
        a.free(compressed);
        return legacy;
    } else |err| {
        a.free(legacy);
        if (err != error.FileNotFound) return err;
    }
    return compressed;
}

pub fn newSessionPath(a: std.mem.Allocator, io: std.Io, directory: []const u8) ![]const u8 {
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    return std.fmt.allocPrint(a, "{s}/{s}" ++ session_extension, .{ directory, std.fmt.bytesToHex(nonce, .lower) });
}

pub const SessionTarget = union(enum) {
    new,
    existing: struct {
        path: []const u8,
        inode: ?u64 = null,
        legacy_workspace_known: bool = true,
    },
};
pub const SessionReplacement = struct {
    path: ?[]const u8,
    recovered: ?agent.PreparedJournal = null,
    workspace: ?[]const u8 = null,
    missing_workspace: ?[]const u8 = null,

    pub fn deinit(self: *SessionReplacement) void {
        if (self.recovered) |*journal| journal.deinit();
    }
};

pub const JournalWorkspace = union(enum) { unknown, available: []const u8, missing: []const u8 };

pub fn savedWorkspace(a: std.mem.Allocator, io: std.Io, journal: *const agent.PreparedJournal) !JournalWorkspace {
    const context = try journal.applicationContext(a, TaskJournal.main_conversation);
    const field = j.get(j.get(j.get(context, "session"), "config"), "workspace");
    if (field != .null and field != .string) return error.InvalidSessionWorkspace;
    const saved = j.text(field);
    if (saved.len == 0) return .unknown;
    if (!std.fs.path.isAbsolute(saved) or std.mem.indexOfScalar(u8, saved, 0) != null) return error.InvalidSessionWorkspace;
    const directory = std.Io.Dir.cwd().openDir(io, saved, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .missing = saved },
        else => return err,
    };
    defer directory.close(io);
    return .{ .available = try std.Io.Dir.cwd().realPathFileAlloc(io, saved, a) };
}

pub const InteractiveBranch = union(enum) { before_prompt: []const u8, current };

pub fn prepareInteractiveBranch(self: *Self, a: std.mem.Allocator, position: InteractiveBranch) !struct { replacement: SessionReplacement, draft: []const u8 } {
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const temp = temporary.allocator();
    const worker = self.worker orelse return error.InvalidSession;
    const root = TaskJournal.main_conversation;
    var current = try self.gateway.readContext(worker, self.gpa);
    defer current.deinit();
    var historical: ?agent.JsonDocument = null;
    defer if (historical) |*snapshot| snapshot.deinit();
    var draft: []const u8 = "";
    errdefer if (draft.len != 0) a.free(draft);
    const leaf = switch (position) {
        .before_prompt => |selected| leaf: {
            var chosen = (try self.gateway.readHistory(worker, self.gpa, .{ .stream = .application, .id = selected, .include_display_parent = true })) orelse return error.InvalidSessionEntry;
            defer chosen.deinit();
            const text = j.text(j.get(chosen.value, "text"));
            if (!j.equal(j.get(chosen.value, "kind"), "input") or text.len == 0) return error.InvalidSessionEntry;
            draft = try a.dupe(u8, text);
            const cut = try self.gateway.planApplicationFork(worker, temp, root, selected);
            historical = try self.gateway.readApplicationContextAt(worker, self.gpa, cut.base.context, .{ .at = cut.base.at });
            const parent = chosen.display_parent orelse j.text(j.get(chosen.value, "parent"));
            break :leaf if (parent.len == 0) null else try temp.dupe(u8, parent);
        },
        .current => leaf: {
            const head = j.text(j.get(j.get(current.value, "session"), "head"));
            break :leaf (try self.displayTreeHead(worker, temp)) orelse if (head.len != 0) head else null;
        },
    };
    const context = if (historical) |snapshot| snapshot.value else current.value;
    const saved = j.get(j.get(context, "session"), "config");
    var config = if (saved == .object) saved else self.scoped_defaults;
    if (self.settings.saved_workspace != null) {
        config = .{ .object = try config.object.clone(temp) };
        try j.put(temp, &config, "workspace", j.string(self.settings.workspace));
    }

    var branch = try self.gateway.exportApplicationBranch(worker, self.gpa, root, leaf);
    defer branch.deinit();
    const owned = branch.allocator();
    var entries = j.array(owned);
    var retained: std.StringHashMapUnmanaged(void) = .empty;
    var head: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var has_dialogue = false;
    var task_history: ?agent.JsonDocument = null;
    defer if (task_history) |*snapshot| snapshot.deinit();
    for (branch.value.array.items) |*row| {
        const entry = row.object.getPtr("entry").?;
        if (j.flag(j.get(entry.*, "tree_label"))) continue;
        const id = j.text(j.get(entry.*, "id"));
        const kind = j.get(entry.*, "kind");
        has_dialogue = has_dialogue or j.equal(kind, "input") or j.equal(kind, "response");
        if (j.equal(kind, "checkpoint") and j.get(entry.*, "summary_usage") == .null) {
            if (try self.forkCompactionUsage(owned, entry.*, &task_history)) |usage|
                try j.put(owned, entry, "summary_usage", usage);
        }
        try retained.put(owned, id, {});
        try j.put(owned, entry, "parent", if (head) |previous| j.string(previous) else .null);
        if (!j.flag(j.get(row.*, "display_only"))) head = id;
        if (j.equal(j.get(entry.*, "event_kind"), SessionName.entry_kind)) title = j.text(j.get(entry.*, "data"));
        try entries.array.append(row.*);
    }
    if (position == .current) if (self.session.path) |source| {
        if (!self.sessionFileWritten(source) or (!has_dialogue and !try self.hasSavedDialogue(worker))) return error.UnsavedSession;
    };

    var labels = j.object();
    var next_id = @max(1, j.number(j.get(j.get(current.value, "session"), "next_id")));
    const existing_labels = j.get(current.value, "tree_labels");
    if (existing_labels == .object) for (existing_labels.object.keys(), existing_labels.object.values()) |target, label| {
        if (!retained.contains(target)) continue;
        const id = try std.fmt.allocPrint(owned, "a{d}", .{next_id});
        next_id += 1;
        const entry = try j.value(owned, .{
            .id = id,
            .parent = head,
            .kind = "write",
            .tree_label = true,
            .data = .{ .target = target, .label = j.get(label, "text") },
            .placed_at_ms = j.get(label, "at_ms"),
        });
        try entries.array.append(try j.value(owned, .{ .entry = entry, .display_only = false }));
        try j.put(temp, &labels, target, label);
        head = id;
    };
    var seed = try j.value(temp, .{
        .session = .{ .revision = 0, .next_id = next_id, .head = head, .config = config, .context_tokens = 0, .forked = true },
        .parent_session = self.session.path,
    });
    if (labels.object.count() > 0) try j.put(temp, &seed, "tree_labels", labels);
    const selection = ModelSelection.effective(context);
    if (selection == .object) try j.put(temp, &seed, "model_selection", selection);
    const extras: []const @FieldType(agent.session_protocol.frames.Action, "control.extension") = if (title) |name| blk: {
        const write = SessionName.admission(name);
        break :blk &.{.{ .namespace = write.namespace, .expected_head = 0, .action = write.action, .input = write.input }};
    } else &.{};
    const path = if (self.session.path != null) try newSessionPath(a, self.io, self.settings.session_directory) else null;
    const id = if (path) |destination| try sessionId(temp, self.io, destination) else try self.requestId(temp);
    return .{
        .replacement = .{ .path = path, .recovered = try agent.PreparedJournal.createApplicationFork(self.gpa, self.io, path, id, self.sessionCodec(), entries.array.items, seed, extras, if (has_dialogue) .immediate else .on_dialogue) },
        .draft = draft,
    };
}

fn hasSavedDialogue(self: *Self, worker: agent.WorkerId) !bool {
    var query: agent.HistoryProjection = .{ .stream = .application, .fields = &.{"kind"} };
    while (true) {
        var page = try self.gateway.projectHistory(worker, self.gpa, query);
        defer page.document.deinit();
        for (j.items(page.document.value)) |entry| {
            const kind = j.get(entry, "kind");
            if (j.equal(kind, "input") or j.equal(kind, "response")) return true;
        }
        query.before = page.before orelse return false;
    }
}

fn forkCompactionUsage(self: *Self, a: std.mem.Allocator, entry: Value, task_history: *?agent.JsonDocument) !?Value {
    if (try retainedCompactionUsage(a, entry)) |usage| return usage;
    const owner = compactionEntryOwner(entry) orelse return null;
    if (task_history.* == null) {
        const tasks = self.tasks orelse return null;
        task_history.* = try tasks.snapshot(self.gpa);
    }
    return usageFromCompactionTask(a, entry, TaskJournal.taskValues(j.get(task_history.*.?.value, "value")), owner);
}

fn retainedCompactionUsage(a: std.mem.Allocator, entry: Value) !?Value {
    const usage = j.get(entry, "fork_summary_usage");
    if (usage == .object) return usage;
    return Usage.forkedCompactionUsage(a, j.get(entry, "summary_parts_usage"));
}

fn compactionEntryOwner(entry: Value) ?[]const u8 {
    const prefix = "request/compaction/";
    const submission = j.text(j.get(entry, "submission"));
    return if (std.mem.startsWith(u8, submission, prefix)) submission[prefix.len..] else null;
}

fn usageFromCompactionTask(a: std.mem.Allocator, entry: Value, records: Value, owner: []const u8) !?Value {
    const task = j.get(records, owner);
    if (!isConversationCompaction(task) or !j.equal(j.get(task, "conversation"), TaskJournal.main_conversation)) return null;
    const state = j.get(task, "state");
    const terminal = j.get(state, "terminal");
    const outcome = if (terminal != .null) terminal else j.get(state, "completing");
    const value = j.get(outcome, "value");
    const placement = j.get(records, j.text(j.get(value, "placement")));
    if (!j.equal(j.get(outcome, "status"), "completed") or !j.equal(j.get(placement, "kind"), write_task) or
        !j.equal(j.get(placement, "owner"), owner) or !j.equal(j.get(j.get(placement, "input"), "submission"), j.text(j.get(entry, "submission"))) or
        j.get(value, "usage") != .object) return null;
    return try Usage.encodeSpend(a, try savedCompactionUsage(a, value));
}

const ArchiveCompaction = struct {
    allocator: std.mem.Allocator,
    source: *const agent.PreparedJournal,
    records: ?Value = null,

    fn project(raw: *anyopaque, a: std.mem.Allocator, entry: *Value) !void {
        if (!j.equal(j.get(entry.*, "kind"), "checkpoint") or j.get(entry.*, "summary_usage") != .null) return;
        if (try retainedCompactionUsage(a, entry.*)) |usage| return j.put(a, entry, "summary_usage", usage);
        const owner = compactionEntryOwner(entry.*) orelse return;
        const self: *ArchiveCompaction = @ptrCast(@alignCast(raw));
        if (self.records == null) self.records = TaskJournal.taskValues(try self.source.extensionDocument(self.allocator, TaskJournal.namespace));
        if (try usageFromCompactionTask(a, entry.*, self.records.?, owner)) |usage| try j.put(a, entry, "summary_usage", usage);
    }
};

/// Validate an existing destination before the UI cancels work in the current session.
pub fn prepareSessionReplacement(self: *Self, a: std.mem.Allocator, target: SessionTarget) !?SessionReplacement {
    if (target == .new) {
        const path = if (self.session.path != null) try newSessionPath(a, self.io, self.settings.session_directory) else null;
        return .{ .path = path };
    }
    const existing = target.existing;
    const path = existing.path;
    const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});
    if (stat.kind != .file or stat.size == 0) return error.InvalidSession;
    const normalized = try writableSessionPath(a, self.io, path);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(self.io, normalized, a);
    if (self.session.path) |current| {
        const active = std.Io.Dir.cwd().realPathFileAlloc(self.io, current, a) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => current,
        };
        if (std.mem.eql(u8, absolute, active)) return null;
    }
    var recovered = (try prepareResume(self.gpa, self.io, absolute, self.sessionCodec())) orelse return error.InvalidSession;
    errdefer recovered.deinit();
    if (existing.inode) |expected| try recovered.requireFile(expected);
    var replacement: SessionReplacement = .{ .path = absolute, .recovered = recovered };
    switch (try savedWorkspace(a, self.io, &recovered)) {
        .unknown => if (!existing.legacy_workspace_known) return error.UnknownSessionWorkspace,
        .available => |workspace| if (!std.mem.eql(u8, workspace, self.settings.workspace)) {
            replacement.workspace = workspace;
        },
        .missing => |workspace| replacement.missing_workspace = workspace,
    }
    return replacement;
}

/// Fork all committed history in the locked archive into the effective workspace.
pub fn forkSessionArchive(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, source: *const agent.PreparedJournal, workspace: []const u8, directory: []const u8) !SessionReplacement {
    try source.revalidateFile();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const context = try source.applicationContext(temp, TaskJournal.main_conversation);
    const session = j.get(context, "session");
    const saved_config = j.get(session, "config");
    if (saved_config != .object) return error.InvalidSession;
    var config: Value = .{ .object = try saved_config.object.clone(temp) };
    try j.put(temp, &config, "workspace", j.string(workspace));
    var seed = try j.value(temp, .{
        .session = .{
            .revision = j.get(session, "revision"),
            .next_id = j.get(session, "next_id"),
            .head = j.get(session, "head"),
            .config = config,
            .context_tokens = j.get(session, "context_tokens"),
            .forked = true,
        },
        .parent_session = try std.Io.Dir.cwd().realPathFileAlloc(io, source.path, temp),
    });
    const selection = ModelSelection.effective(context);
    if (selection == .object) try j.put(temp, &seed, "model_selection", selection);
    inline for (.{ "tree_labels", "tree_reopen" }) |field| {
        const value = j.get(context, field);
        if (value != .null) try j.put(temp, &seed, field, value);
    }
    const title = try source.extensionDocument(temp, SessionName.namespace);
    const extras: []const @FieldType(agent.session_protocol.frames.Action, "control.extension") = if (title == .string) blk: {
        const write = SessionName.admission(title.string);
        break :blk &.{.{ .namespace = write.namespace, .expected_head = 0, .action = write.action, .input = write.input }};
    } else &.{};
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try newSessionPath(a, io, directory);
    const id = try sessionId(temp, io, path);
    var projection: ArchiveCompaction = .{ .allocator = temp, .source = source };
    return .{ .path = path, .recovered = try source.forkApplicationArchive(path, id, seed, extras, .{ .context = &projection, .entry = ArchiveCompaction.project }) };
}

pub fn changeSession(self: *Self, replacement: *SessionReplacement) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    if (!self.session_change_mutex.tryLock()) return error.ControllerBusy;
    defer self.session_change_mutex.unlock(self.io);
    if (self.active_request != null) return error.ControllerBusy;
    const normalized = replacement.path;
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const prepared = if (replacement.recovered) |*journal| journal else null;
    const previous_selection = if (prepared) |journal| try decodeSelection(temporary.allocator(), try journal.contextDocument(temporary.allocator(), "model_selection")) else null;
    const old_provider = self.provider;
    const old_settings = self.settings;
    const old_level = self.selected_effort;
    const old_unavailable_model = self.unavailable_model;
    var published = false;
    errdefer if (!published) {
        self.provider = old_provider;
        self.settings = old_settings;
        self.selected_effort = old_level;
        self.unavailable_model = old_unavailable_model;
    };
    self.settings.saved_workspace = null;
    if (try resolveSavedSessionRoute(self.a, &self.settings, previous_selection)) |provider| {
        self.provider = provider;
        self.unavailable_model = if (self.configured()) null else try decodeSelection(self.a, try j.value(temporary.allocator(), previous_selection.?));
        try self.resolveEffort(self.settings.launch_effort orelse self.savedEffort(previous_selection));
    }
    const next_path = if (normalized) |location| try self.a.dupe(u8, location) else null;
    const gateway = try self.openGateway();
    var gateway_owned = true;
    errdefer if (gateway_owned) gateway.close();
    const next = try self.openWorker(gateway, normalized, .{ .previous = previous_selection, .prepared = prepared });
    self.closeTasks();
    self.gateway.close();
    self.clearDelivery();
    self.gateway = gateway;
    gateway_owned = false;
    self.worker = next;
    self.session.path = next_path;
    published = true;
    self.metadata() catch |err| {
        self.selection_healthy = false;
        return err;
    };
    try self.startTasks();
    try self.restoreRegistrations();
    try self.refresh();
    try self.refreshRecovery();
}

pub fn registerDeferredTools(self: *Self, id: []const u8, batch: DeferredTools.Batch) !*agent.Request {
    if (!self.session_change_mutex.tryLock()) return error.ControllerBusy;
    defer self.session_change_mutex.unlock(self.io);
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const submission = try Inbox.requestId(a, id);
    const value = try batch.value(a);
    const encoded = try agent.session_protocol.Canonical.encode(a, value);
    const digest = Inbox.inputHash(encoded);
    var records: Value = .{ .object = .empty };
    try records.object.put(a, submission, try j.value(a, .{
        .kind = Inbox.Kind.register_tools,
        .input = .{ .json = encoded },
        .sha256 = &digest,
    }));
    try self.writeInbox("enqueue", records);
    return self.deliverRegistration(a, submission, value);
}

fn deliverRegistration(self: *Self, a: std.mem.Allocator, submission: []const u8, batch: Value) !*agent.Request {
    return self.gateway.deliver(self.worker.?, try self.requestId(a), .{
        .input_json = try j.encode(a, .{ .command = "register_tools", .batch = batch, .submission = submission }),
    });
}

const registration_task = "cpi-minimal.register-tools";
const write_task = "cpi-minimal.drain-writes";
const provider_cancel_task = "cpi-minimal.cancel-provider-response";
const foreground_kind = Inbox.prompt_task_kind;
const model_kind = "cpi-minimal.model";
const tool_kind = "cpi-minimal.tool";
const after_run_kind = "cpi-minimal.after-run";
const before_compact_kind = "cpi-minimal.before-compact";
const manual_compaction_kind = "cpi-minimal.manual-compaction";
const background_compaction_kind = "cpi-minimal.background-compaction";
const tool_hook_kind = "cpi-minimal.tool-hook";
// Invalidate derived request snapshots and usage anchors when model rendering changes.
const model_view_version = 3;
const generation_hook_kind = "cpi-minimal.generation-hook";
const GenerationHookStage = enum { request, response, tools };
const ForegroundWork = enum { turn, compact, recover, automatic_compaction, continue_turn, reset, drain_writes };
const ForegroundPhase = enum { model, tool, after_run, before_compact, before_tool, after_tool, generation_hook };
const ForegroundProgress = union(enum) { completed, nothing_to_answer, retry_at: u64, retry_admission_at: u64, delegate: ForegroundPhase };
const ForegroundAttempt = struct {
    id: []const u8,
    task: []const u8,
    conversation: []const u8 = TaskJournal.main_conversation,
    phase: ?ForegroundPhase = null,
    inbox_owner: bool = false,
    resume_input: Value = .null,

    fn scoped(self: ForegroundAttempt) bool {
        return !std.mem.eql(u8, self.conversation, TaskJournal.main_conversation);
    }

    fn resumeInput(self: ForegroundAttempt, a: std.mem.Allocator) !Value {
        return if (self.resume_input == .null) j.value(a, .{ .command = "resume" }) else self.resume_input;
    }

    fn hookPhase(self: ForegroundAttempt) bool {
        return switch (self.phase orelse return false) {
            .model, .tool => false,
            else => true,
        };
    }
};

/// A prompt can be admitted as an initial task in a conversation draft.
/// The task input is durable before the application is able to place it.
pub fn conversationPrompt(a: std.mem.Allocator, id: []const u8, prepared: Prepared) !TaskJournal.Submission {
    return conversationPromptWithSelection(a, id, prepared, null);
}

pub fn conversationPromptWithSelection(a: std.mem.Allocator, id: []const u8, prepared: Prepared, selection: ?ModelSelection) !TaskJournal.Submission {
    var input = try j.value(a, .{
        .work = ForegroundWork.turn,
        .submission = try Inbox.requestId(a, id),
        .prompt = try Inbox.promptBody(a, prepared.text, prepared.original, prepared.entry, prepared.user_content),
    });
    if (selection) |chosen| try input.object.put(a, "model_selection", try j.value(a, chosen));
    return .{
        .id = id,
        .kind = foreground_kind,
        .exclusive_turn = true,
        .input = input,
    };
}

pub const InputSubmission = struct { task: TaskJournal.Submission, admission: agent.ExtensionWrite };
pub const InputPolicy = Inbox.InputPolicy;

/// Compose the scoped inbox admission with the task that will place it.
/// Submit both in the same transaction.
pub fn conversationInput(a: std.mem.Allocator, conversation: []const u8, request_id: []const u8, prepared: Prepared, selection: ?ModelSelection) !InputSubmission {
    return conversationInputWithPolicy(a, conversation, request_id, prepared, selection, .{});
}

/// Evaluate the input policy against the committed run at admission. A refusal
/// returns ConversationBusy or ConversationIdle and publishes no transaction.
pub fn conversationInputWithPolicy(a: std.mem.Allocator, conversation: []const u8, request_id: []const u8, prepared: Prepared, selection: ?ModelSelection, policy: InputPolicy) !InputSubmission {
    const submission = try Inbox.requestId(a, request_id);
    const key = try Inbox.promptTaskHash(a, conversation, submission);
    var input = try j.value(a, .{ .work = ForegroundWork.turn, .submission = submission });
    const chosen = if (selection) |picked| try j.value(a, picked) else .null;
    if (chosen != .null) try input.object.put(a, "model_selection", chosen);
    return .{
        .task = .{
            .id = try a.dupe(u8, &key),
            .kind = foreground_kind,
            .conversation = conversation,
            .exclusive_turn = true,
            .input = input,
        },
        .admission = try Inbox.promptAdmissionWithPolicy(a, conversation, submission, try Inbox.promptBody(a, prepared.text, prepared.original, prepared.entry, prepared.user_content), chosen, policy),
    };
}

/// Let host-submitted foreground tasks in the root proceed without a CLI
/// foreground wait. The host may then wait on tasks independently.
pub fn resumeRootScheduling(self: *Self) !void {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    self.root_scheduling.store(true, .release);
    try tasks.resumeScheduling();
}

pub fn wake(self: *Self) !TaskScheduler.Wake {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    return tasks.wake();
}

fn startTasks(self: *Self) !void {
    const tasks = try TaskScheduler.start(self.gpa, self.io, self.gateway, self.worker.?, self.task_bindings, self.settings.task_settings);
    self.tasks = tasks;
    errdefer self.closeTasks();
    var snapshot = try tasks.snapshot(self.gpa);
    defer snapshot.deinit();
    const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
    if (records == .object) for (records.object.keys(), records.object.values()) |id, task| {
        if (j.get(j.get(task, "state"), "terminal") != .null) continue;
        const owner = j.get(records, j.text(j.get(task, "owner")));
        if (!j.equal(j.get(owner, "kind"), after_run_kind)) continue;
        const definition = tasks.definition(j.text(j.get(task, "kind")));
        const version = j.number(j.get(task, "version"));
        if (definition) |installed| {
            if (installed.version == version or (installed.version > version and installed.migrate != null)) continue;
        }
        try tasks.abort(id);
        self.reportAfterRunError(j.text(j.get(task, "kind")), error.TaskDefinitionUnavailable);
    };
}

fn closeTasks(self: *Self) void {
    if (self.tasks) |tasks| tasks.close();
    self.tasks = null;
}

fn foregroundCommandId(a: std.mem.Allocator, id: []const u8, attempt: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "foreground/{s}/{d}", .{ id, attempt });
}

fn retryTask(deadline: u64) TaskJournal.Step {
    return .{ .next = .{ .sleep = .{ .checkpoint = j.string("continue"), .until_ms = deadline } } };
}

fn failedTask(err: anyerror) TaskJournal.Outcome {
    return .{ .status = if (err == error.Canceled) .aborted else .failed, .value = j.string(@errorName(err)) };
}

fn finishForegroundFailure(self: *Self, work: ForegroundWork, a: std.mem.Allocator, outcome: TaskJournal.Outcome) !TaskJournal.Step {
    if (work == .automatic_compaction) {
        if (j.equal(outcome.value, "NothingToCompact")) return .{ .next = .{ .finish = .{ .status = .completed } } };
        if (outcome.status != .aborted) try self.emit(.{
            .kind = .notice,
            .text = try std.fmt.allocPrint(a, "Automatic compaction failed after recovery attempts ({s}). Answer and history saved; compaction will be retried automatically before the next turn.", .{j.text(outcome.value)}),
        });
    }
    return .{ .next = .{ .finish = outcome } };
}

fn delegateForeground(invocation: TaskScheduler.Invocation, phase: ForegroundPhase, inbox_owner: bool) !TaskJournal.Step {
    const a = invocation.allocator;
    const child = Inbox.inputHash(try std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ @tagName(phase), invocation.id, invocation.attempt }));
    const on = try a.alloc([]const u8, 1);
    on[0] = try a.dupe(u8, &child);
    const children = try a.alloc(TaskJournal.Submission, 1);
    var input = try j.value(a, .{ .task = invocation.id, .phase = phase });
    if (inbox_owner) try input.object.put(a, "inbox_owner", .{ .bool = true });
    children[0] = .{
        .id = on[0],
        .kind = switch (phase) {
            .model => model_kind,
            .tool => tool_kind,
            .after_run => after_run_kind,
            .before_compact => before_compact_kind,
            .before_tool, .after_tool => tool_hook_kind,
            .generation_hook => generation_hook_kind,
        },
        .owner = invocation.id,
        .input = input,
    };
    return .{ .children = children, .next = .{ .wait = .{ .checkpoint = .null, .on = on } } };
}

fn runForegroundTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const work = std.meta.stringToEnum(ForegroundWork, j.text(j.get(invocation.input, "work"))) orelse return error.InvalidForegroundTask;
    return self.advanceForegroundTask(invocation, work);
}

fn advanceForegroundTask(self: *Self, invocation: TaskScheduler.Invocation, work: ForegroundWork) !TaskJournal.Step {
    const progress = blk: {
        if (invocation.dependencies.len == 0) {
            break :blk self.runForegroundAttempt(invocation, work) catch |err| return self.finishForegroundFailure(work, invocation.allocator, failedTask(err));
        }
        if (invocation.dependencies.len != 1) return error.InvalidForegroundTask;
        const receipt = invocation.dependencies[0].outcome;
        if (receipt.status != .completed) {
            var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
            defer context.deinit();
            if (j.equal(j.get(j.get(context.value, "after_run"), "owner"), invocation.id)) {
                try self.configureConversation(invocation.conversation, "after_run_interrupted");
                self.reportAfterRunError("phase", error.AfterRunTaskFailed);
                return .{ .next = .{ .finish = .{ .status = .completed } } };
            }
            return self.finishForegroundFailure(work, invocation.allocator, receipt);
        }
        if (receipt.value == .null) break :blk ForegroundProgress.completed;
        const phase = std.meta.stringToEnum(ForegroundPhase, j.text(j.get(receipt.value, "phase"))) orelse return error.InvalidForegroundTask;
        break :blk ForegroundProgress{ .delegate = phase };
    };
    switch (progress) {
        .retry_at => |deadline| return retryTask(deadline),
        .retry_admission_at => |deadline| return .{ .next = .{ .sleep = .{ .checkpoint = .null, .until_ms = deadline } } },
        .delegate => |phase| return delegateForeground(invocation, phase, work == .drain_writes),
        .nothing_to_answer => return .{ .next = .{ .finish = .{ .status = .completed } } },
        .completed => {},
    }
    if ((work == .turn or work == .continue_turn) and try self.foregroundNeedsCompaction(invocation)) {
        const a = invocation.allocator;
        const child_id = Inbox.inputHash(try std.fmt.allocPrint(a, "automatic-compaction/{s}", .{invocation.id}));
        const children = try a.alloc(TaskJournal.Submission, 1);
        children[0] = .{
            .id = try a.dupe(u8, &child_id),
            .kind = foreground_kind,
            .owner = invocation.id,
            .input = try j.value(a, .{ .work = ForegroundWork.automatic_compaction }),
        };
        return .{ .children = children, .next = .{ .finish = .{ .status = .completed } } };
    }
    return .{ .next = .{ .finish = .{ .status = .completed } } };
}

fn foregroundNeedsCompaction(self: *Self, invocation: TaskScheduler.Invocation) !bool {
    if (!self.runPolicy().auto_compact) return false;
    if (std.mem.eql(u8, invocation.conversation, TaskJournal.main_conversation)) return self.contextTokens() > self.settings.context_window - self.settings.reserve_tokens;
    var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
    defer context.deinit();
    const session = j.get(context.value, "session");
    const config = j.get(session, "config");
    return j.number(j.get(session, "context_tokens")) > j.number(j.get(config, "context_window")) -| j.number(j.get(config, "reserve_tokens"));
}

fn runPhaseTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    const task = j.text(j.get(invocation.input, "task"));
    const phase = std.meta.stringToEnum(ForegroundPhase, j.text(j.get(invocation.input, "phase"))) orelse return error.InvalidForegroundTask;
    if (task.len == 0) return error.InvalidForegroundTask;
    const attempt: ForegroundAttempt = .{ .id = try foregroundCommandId(a, invocation.id, invocation.attempt), .task = task, .conversation = invocation.conversation, .phase = phase, .inbox_owner = j.flag(j.get(invocation.input, "inbox_owner")) };
    const progress = self.runPhaseAttempt(invocation, attempt) catch |err| return .{ .next = .{ .finish = failedTask(err) } };
    return phaseHandoff(a, progress);
}

fn phaseHandoff(a: std.mem.Allocator, progress: ForegroundProgress) !TaskJournal.Step {
    return switch (progress) {
        .retry_at => |deadline| retryTask(deadline),
        .retry_admission_at => |deadline| .{ .next = .{ .sleep = .{ .checkpoint = .null, .until_ms = deadline } } },
        .delegate => |next| .{ .next = .{ .finish = .{ .status = .completed, .value = try j.value(a, .{ .phase = next }) } } },
        .completed, .nothing_to_answer => .{ .next = .{ .finish = .{ .status = .completed } } },
    };
}

fn reportAfterRunError(self: *Self, kind: []const u8, err: anyerror) void {
    std.log.warn("afterRun {s}: {s}", .{ kind, @errorName(err) });
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const text = std.fmt.allocPrint(scratch.allocator(), "afterRun {s} skipped ({s}).", .{ kind, @errorName(err) }) catch return;
    self.emit(.{ .kind = .notice, .text = text, .name = "afterRun" }) catch {};
}

fn runAfterRunTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    const owner = j.text(j.get(invocation.input, "task"));
    if (owner.len == 0) return error.InvalidForegroundTask;
    if (j.equal(invocation.checkpoint, "drain")) {
        const attempt: ForegroundAttempt = .{
            .id = try foregroundCommandId(a, invocation.id, invocation.attempt),
            .task = owner,
            .conversation = invocation.conversation,
            .phase = .after_run,
            .inbox_owner = j.flag(j.get(invocation.input, "inbox_owner")),
        };
        return phaseHandoff(a, try self.runPhaseAttempt(invocation, attempt));
    }

    var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
    defer context.deinit();
    const pending = j.get(context.value, "after_run");
    if (!j.equal(j.get(pending, "owner"), owner)) return .{ .next = .{ .finish = .{ .status = .completed } } };
    const summary = try std.json.parseFromValueLeaky(AfterRunSummary, a, j.get(pending, "summary"), .{ .allocate = .alloc_always });
    var children: std.ArrayList(TaskJournal.Submission) = .empty;
    for (self.settings.after_run) |hook| {
        const planned = hook.plan(hook.context, invocation, summary) catch |err| {
            if (err == error.Canceled) return err;
            self.reportAfterRunError("hook", err);
            continue;
        };
        for (planned) |task| {
            const definition = if (std.mem.startsWith(u8, task.kind, "cpi-minimal.") or std.mem.startsWith(u8, task.kind, "pi.")) null else invocation.driver.definition(task.kind);
            const installed = definition orelse {
                self.reportAfterRunError(task.kind, error.UnknownAfterRunTask);
                continue;
            };
            const child = afterRunChild(invocation, installed, task, children.items.len) catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                self.reportAfterRunError(task.kind, err);
                continue;
            };
            try children.append(a, child);
        }
    }
    if (children.items.len == 0) return .{ .next = .{ .checkpoint = j.string("drain") } };
    const dependencies = try a.alloc([]const u8, children.items.len);
    for (children.items, dependencies) |child, *id| id.* = child.id;
    return .{ .children = children.items, .next = .{ .wait = .{ .checkpoint = j.string("drain"), .on = dependencies } } };
}

fn afterRunChild(invocation: TaskScheduler.Invocation, installed: TaskScheduler.Definition, task: AfterRun.Task, index: usize) !TaskJournal.Submission {
    const a = invocation.allocator;
    try agent.session_protocol.json.validate(a, task.input, null);
    const checkpoint = if (installed.initial) |initial| try initial(installed.context, a, task.input) else .null;
    try agent.session_protocol.json.validate(a, checkpoint, null);
    const id = Inbox.inputHash(try std.fmt.allocPrint(a, "after-run/{s}/{d}", .{ invocation.id, index }));
    return .{ .id = try a.dupe(u8, &id), .kind = try a.dupe(u8, task.kind), .version = installed.version, .input = try j.copy(a, task.input), .checkpoint = try j.copy(a, checkpoint), .owner = invocation.id };
}

fn cleanupAfterRunTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    if (invocation.abort_reason == .restart_limit) {
        try self.cancelForegroundAttempt(invocation);
        try self.configureConversation(invocation.conversation, "after_run_interrupted");
        self.reportAfterRunError("phase", error.RestartLimit);
        return .{ .next = .{ .finish = .{ .status = .completed } } };
    }
    return cleanupPhaseTask(raw, invocation);
}

const CompactionHookPlan = struct {
    reason: CompactionReason,
    entries: []const []const u8,
    messages: []const Value,
    first_kept: []const u8,
    head: []const u8,
    instructions: ?[]const u8 = null,
};

fn runBeforeCompactTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    const owner = j.text(j.get(invocation.input, "task"));
    if (owner.len == 0) return error.InvalidForegroundTask;
    if (invocation.checkpoint == .null) {
        var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
        defer context.deinit();
        if (!j.equal(j.get(j.get(context.value, "foreground_continuation"), "task"), owner)) {
            return .{ .next = .{ .finish = .{ .status = .completed } } };
        }
        const saved = j.get(j.get(context.value, "compaction_progress"), "hook");
        if (saved == .null) return error.MissingCompactionHookPlan;
        const plan = try std.json.parseFromValueLeaky(CompactionHookPlan, a, saved, .{});
        const decision = try self.decideCompaction(invocation, plan);
        return .{ .next = .{ .checkpoint = decision } };
    }
    const attempt: ForegroundAttempt = .{
        .id = try foregroundCommandId(a, invocation.id, invocation.attempt),
        .task = owner,
        .conversation = invocation.conversation,
        .phase = .before_compact,
        .inbox_owner = j.flag(j.get(invocation.input, "inbox_owner")),
        .resume_input = try j.value(a, .{ .command = "resume", .compaction_decision = invocation.checkpoint }),
    };
    return phaseHandoff(a, try self.runPhaseAttempt(invocation, attempt));
}

fn decideCompaction(self: *Self, invocation: TaskScheduler.Invocation, plan: CompactionHookPlan) !Value {
    const a = invocation.allocator;
    const worker = self.worker orelse return error.WorkerStopped;
    if (self.settings.before_compact.len != 0) {
        const history = try a.alloc(agent.HistoryRecord, plan.entries.len);
        var loaded: usize = 0;
        defer for (history[0..loaded]) |*record| record.deinit();
        const entries = try a.alloc(Value, plan.entries.len);
        for (plan.entries, entries, 0..) |id, *entry, index| {
            history[index] = (try self.gateway.readHistory(worker, self.gpa, .{
                .stream = .application,
                .conversation = invocation.conversation,
                .id = id,
            })) orelse return error.MissingCompactionEntry;
            loaded += 1;
            entry.* = history[index].value;
        }
        const request: BeforeCompact.Request = .{
            .reason = plan.reason,
            .entries = entries,
            .messages = plan.messages,
            .first_kept = plan.first_kept,
            .instructions = plan.instructions,
        };
        for (self.settings.before_compact) |hook| {
            try invocation.io.checkCancel();
            const decision = hook.decide(hook.context, invocation, request) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => {
                    std.log.warn("beforeCompact skipped ({s})", .{@errorName(err)});
                    continue;
                },
            };
            if (decision) |chosen| {
                try invocation.io.checkCancel();
                return j.value(a, .{
                    .head = plan.head,
                    .first_kept = plan.first_kept,
                    .kind = @tagName(chosen),
                    .summary = if (chosen == .summary) chosen.summary else null,
                });
            }
        }
    }
    return j.value(a, .{ .head = plan.head, .first_kept = plan.first_kept, .kind = "provider" });
}

const compaction_progress_document: TaskJournal.Document.Address = .{ .kind = "compaction-provider" };
const CompactionCheckpoint = struct {
    plan: Value,
    approved: bool = false,
    history: ?[]const u8 = null,
    turn: ?[]const u8 = null,
    failures: u32 = 0,
    invalid: u8 = 0,
    usage: Usage.Stats = .{},
    retained_usage: ?Usage.Stats = null,
};

const CompactionOutcome = struct {
    status: @FieldType(TaskJournal.Outcome, "status"),
    reason: ?[]const u8 = null,
    placement: ?[]const u8 = null,
    usage: Usage.Stats,
    cancel_provider: bool = false,
};

fn savedCompactionUsage(a: std.mem.Allocator, checkpoint: Value) !Usage.Stats {
    const usage = j.get(checkpoint, "usage");
    return if (usage == .object) std.json.parseFromValueLeaky(Usage.Stats, a, usage, .{}) else .{};
}

const CompactionProgress = struct {
    invocation: TaskScheduler.Invocation,
    revision: ?TaskJournal.Document.Revision,

    fn write(raw: *anyopaque, progress: services.ModelProgress) !void {
        const self: *CompactionProgress = @ptrCast(@alignCast(raw));
        const value = try j.value(self.invocation.allocator, progress);
        const change: @FieldType(TaskJournal.Document.Edit, "change") = if (self.revision) |revision|
            .{ .base = .{ .expected = revision, .value = value } }
        else
            .{ .create = .{ .value = value } };
        try self.invocation.commitDocuments(&.{.{ .address = compaction_progress_document, .change = change }});
        const current = (try self.invocation.document(compaction_progress_document)) orelse return error.MissingModelProgress;
        self.revision = current.version;
    }

    fn retire(self: CompactionProgress) ![]const TaskJournal.Document.Edit {
        const revision = self.revision orelse return &.{};
        const edits = try self.invocation.allocator.alloc(TaskJournal.Document.Edit, 1);
        edits[0] = .{ .address = compaction_progress_document, .change = .{ .retire = revision } };
        return edits;
    }
};

fn runConversationCompaction(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const step = self.advanceConversationCompaction(invocation) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => try finishConversationCompaction(invocation, .{
            .status = .failed,
            .reason = @errorName(err),
            .usage = try savedCompactionUsage(invocation.allocator, invocation.checkpoint),
        }),
    };
    if (step.next == .finish and step.next.finish.status == .failed and
        std.mem.eql(u8, invocation.conversation, TaskJournal.main_conversation))
    {
        const text = std.fmt.allocPrint(invocation.allocator, "Compaction failed ({s}).", .{
            j.text(j.get(step.next.finish.value, "reason")),
        }) catch return step;
        self.emit(.{ .kind = .notice, .text = text }) catch {};
    }
    return step;
}

fn advanceConversationCompaction(self: *Self, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const a = invocation.allocator;
    const worker = self.worker orelse return error.WorkerStopped;
    if (invocation.checkpoint == .null) {
        var plan = try self.gateway.queryApplication(worker, a, invocation.conversation, try j.value(a, .{
            .command = "plan_compaction",
            .focus = j.text(j.get(invocation.input, "focus")),
            .reason = j.get(invocation.input, "reason"),
        }));
        defer plan.deinit();
        if (j.flag(j.get(plan.value, "nothing"))) return finishConversationCompaction(invocation, .{ .status = .completed, .reason = "nothing_to_compact", .usage = .{} });
        const saved: CompactionCheckpoint = .{ .plan = plan.value, .approved = j.get(plan.value, "hook") == .null };
        return .{ .next = .{ .checkpoint = try j.value(a, saved) } };
    }
    var stage = try std.json.parseFromValueLeaky(CompactionCheckpoint, a, invocation.checkpoint, .{});
    if (!stage.approved) {
        const plan = try std.json.parseFromValueLeaky(CompactionHookPlan, a, j.get(stage.plan, "hook"), .{});
        const decision = try self.decideCompaction(invocation, plan);
        const kind = j.get(decision, "kind");
        if (j.equal(kind, "decline"))
            return finishConversationCompaction(invocation, .{ .status = .completed, .reason = "declined", .usage = stage.usage });
        if (j.equal(kind, "summary")) return placeConversationCompaction(invocation, stage, j.text(j.get(decision, "summary")));
        stage.approved = true;
        return .{ .next = .{ .checkpoint = try j.value(a, stage) } };
    }

    const history = j.get(stage.plan, "history");
    const turn = j.get(stage.plan, "turn");
    const summarize_history = history == .string and stage.history == null;
    const summarize_turn = turn == .string and stage.turn == null;
    if (!summarize_history and !summarize_turn) {
        const base = stage.history orelse j.text(j.get(stage.plan, "base_summary"));
        const suffix = j.text(j.get(stage.plan, "suffix"));
        const text = if (stage.turn) |prefix|
            try std.fmt.allocPrint(a, "{s}\n\n---\n\n**Turn Context (split turn):**\n\n{s}{s}", .{ base, prefix, suffix })
        else
            try std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix });
        return placeConversationCompaction(invocation, stage, text);
    }

    const selection = (try decodeSelection(a, j.get(stage.plan, "selection"))) orelse return error.ModelUnavailable;
    const config = j.get(stage.plan, "config");
    const limit = std.math.cast(u32, j.number(j.get(config, "max_output_tokens"))) orelse return error.InvalidContextSettings;
    if (limit == 0) return error.InvalidContextSettings;
    const binding: agent.ApplicationModel = .{
        .model = .{
            .model = selection.model,
            .base_url = selection.base_url,
            .credential = try selection.credential(a),
            .reasoning_effort = selection.reasoning_effort,
            .max_output_tokens = limit,
        },
        .selection = try j.value(a, selection),
    };
    var body = try j.value(a, .{
        .model = selection.model,
        .instructions = prompts.summary_system,
        .input = .{.{ .role = "user", .content = if (summarize_history) history.string else turn.string }},
        .tools = j.array(a),
        .max_output_tokens = limit,
    });
    if (selection.reasoning_effort) |effort| try body.object.put(a, "reasoning", try j.value(a, .{ .effort = effort }));
    const saved = try invocation.document(compaction_progress_document);
    const resume_state: ?services.ModelResume = if (saved) |document| .{
        .route = binding.model.base_url,
        .credential = binding.model.credential,
        .progress = try std.json.parseFromValueLeaky(services.ModelProgress, a, document.value, .{}),
    } else null;
    var progress: CompactionProgress = .{ .invocation = invocation, .revision = if (saved) |document| document.version else null };
    const key = try std.fmt.allocPrint(a, "summary/{s}/{s}/{d}/{d}", .{ invocation.id, if (summarize_history) "history" else "turn", stage.failures, stage.invalid });
    const response = try self.gateway.requestTaskModel(worker, a, invocation.io, .{
        .id = key,
        .binding = binding,
        .body = body,
        .resume_state = resume_state,
        .progress = .{ .context = &progress, .write = CompactionProgress.write },
    });
    const reply = try agent.responses.interpret(a, response, false);
    if (reply.status == .poll_pending) {
        return .{ .next = .{ .sleep = .{ .checkpoint = invocation.checkpoint, .until_ms = reply.next_poll_ms orelse return error.InvalidRetryDeadline } } };
    }
    Usage.add(&stage.usage, j.get(reply.raw, "usage"), false);

    if (reply.status == .completed and reply.calls.len == 0 and std.mem.trim(u8, reply.text, " \t\r\n").len != 0) {
        if (stage.retained_usage == null) stage.retained_usage = .{};
        Usage.add(&stage.retained_usage.?, j.get(reply.raw, "usage"), false);
        if (summarize_history) stage.history = reply.text else stage.turn = reply.text;
        stage.failures = 0;
        stage.invalid = 0;
    } else if (reply.retryable) {
        stage.failures +|= 1;
        if (self.settings.fresh_retry_limit) |max| if (stage.failures > max) return finishConversationCompaction(invocation, .{
            .status = .failed,
            .reason = "provider_retry_limit",
            .usage = stage.usage,
        });
        const delay = self.settings.provider_retry.delay(invocation.io, @intCast(@min(stage.failures, 32)), reply.retry_after_ms);
        const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(invocation.io).toMilliseconds()));
        return .{
            .documents = try progress.retire(),
            .next = .{ .sleep = .{ .checkpoint = try j.value(a, stage), .until_ms = now +| delay } },
        };
    } else {
        stage.invalid += 1;
        if (stage.invalid >= 3 or (reply.status != .completed and reply.status != .incomplete)) return finishConversationCompaction(invocation, .{
            .status = .failed,
            .reason = @tagName(reply.status),
            .usage = stage.usage,
        });
        stage.failures = 0;
    }
    return .{ .documents = try progress.retire(), .next = .{ .checkpoint = try j.value(a, stage) } };
}

fn cleanupConversationCompaction(_: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const limited = invocation.abort_reason == .restart_limit;
    return finishConversationCompaction(invocation, .{
        .status = if (limited) .failed else .aborted,
        .reason = if (limited) "restart_limit" else "cancelled",
        .usage = try savedCompactionUsage(invocation.allocator, invocation.checkpoint),
        .cancel_provider = true,
    });
}

fn cancelCompactionResponse(invocation: TaskScheduler.Invocation, progress: Value) ![]const TaskJournal.Submission {
    const a = invocation.allocator;
    const id = j.text(j.get(progress, "response_id"));
    if (!agent.session_protocol.frames.validProviderResponseId(id)) return &.{};
    const saved = j.get(j.get(invocation.checkpoint, "plan"), "selection");
    const selection = (try decodeSelection(a, saved)) orelse return &.{};
    const children = try a.alloc(TaskJournal.Submission, 1);
    children[0] = .{
        .id = try std.fmt.allocPrint(a, "provider-cancel/compaction/{s}", .{invocation.id}),
        .kind = provider_cancel_task,
        .owner = invocation.id,
        .background = true,
        .input = try j.value(a, .{
            .response_id = id,
            .route = selection.base_url,
            .credential = try selection.credential(a),
            .selection = saved,
        }),
    };
    return children;
}

fn finishConversationCompaction(invocation: TaskScheduler.Invocation, outcome: CompactionOutcome) !TaskJournal.Step {
    const a = invocation.allocator;
    const extensions: []const agent.ExtensionWrite = if (!j.equal(j.get(invocation.input, "reason"), "threshold")) settle: {
        var input = j.object();
        try input.object.put(a, invocation.id, .null);
        const edits = try a.alloc(agent.ExtensionWrite, 1);
        edits[0] = .{
            .namespace = try Inbox.scopeNamespace(a, invocation.conversation),
            .action = "settle",
            .input = .{ .contract = Inbox.contract.version, .value = input },
        };
        break :settle edits;
    } else &.{};
    const current = try invocation.document(compaction_progress_document);
    const progress: CompactionProgress = .{ .invocation = invocation, .revision = if (current) |doc| doc.version else null };
    return .{
        .extensions = extensions,
        .documents = try progress.retire(),
        .children = if (outcome.cancel_provider and current != null) try cancelCompactionResponse(invocation, current.?.value) else &.{},
        .next = .{ .finish = .{ .status = outcome.status, .value = try j.value(a, .{
            .reason = outcome.reason,
            .placement = outcome.placement,
            .usage = outcome.usage,
        }) } },
    };
}

fn placeConversationCompaction(invocation: TaskScheduler.Invocation, stage: CompactionCheckpoint, summary: []const u8) !TaskJournal.Step {
    const a = invocation.allocator;
    const id = try std.fmt.allocPrint(a, "compaction/{s}", .{invocation.id});
    const activation: Inbox.WriteActivation = if (j.flag(j.get(invocation.input, "terminal"))) .passive else .normal;
    const placement = try conversationWriteWithActivation(a, invocation.conversation, id, .{
        .kind = "pi.compaction",
        .head = j.text(j.get(stage.plan, "first_kept")),
        .data = try j.value(a, .{
            .summary = summary,
            .metadata = j.get(stage.plan, "metadata"),
            .fork_summary_usage = if (stage.retained_usage) |usage| try Usage.encodeSpend(a, usage) else null,
        }),
    }, invocation.id, activation);
    var step = try finishConversationCompaction(invocation, .{ .status = .completed, .placement = placement.task.id, .usage = stage.usage });
    const children = try a.alloc(TaskJournal.Submission, 1);
    children[0] = placement.task;
    children[0].background = true;
    step.children = children;
    const extensions = try a.alloc(agent.ExtensionWrite, step.extensions.len + 1);
    @memcpy(extensions[0..step.extensions.len], step.extensions);
    extensions[step.extensions.len] = placement.admission;
    step.extensions = extensions;
    return step;
}

fn cleanupBeforeCompactTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const step = try cleanupPhaseTask(raw, invocation);
    if (invocation.abort_reason == .restart_limit) try self.configureConversation(invocation.conversation, "compaction_interrupted");
    return step;
}

fn runToolHookTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    const owner = j.text(j.get(invocation.input, "task"));
    const phase = std.meta.stringToEnum(ForegroundPhase, j.text(j.get(invocation.input, "phase"))) orelse return error.InvalidForegroundTask;
    if (owner.len == 0 or (phase != .before_tool and phase != .after_tool)) return error.InvalidForegroundTask;
    if (invocation.checkpoint == .null) {
        var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
        defer context.deinit();
        if (!j.equal(j.get(j.get(context.value, "foreground_continuation"), "task"), owner)) {
            return .{ .next = .{ .finish = .{ .status = .completed } } };
        }
        const active_turn = j.get(j.get(context.value, "session"), "run");
        const calls = j.items(j.get(active_turn, "pending"));
        const response = j.text(j.get(active_turn, "response_id"));
        if (calls.len == 0 or response.len == 0) return error.MissingToolHookInput;
        const call: ToolCall = .{
            .name = j.text(j.get(calls[0], "name")),
            .call_id = j.text(j.get(calls[0], "call_id")),
            .arguments = j.get(calls[0], "arguments"),
        };
        const limit = invocation.driver.settings.restart_limit;
        const cutoff = if (limit) |n| invocation.restarts != 0 and invocation.restarts >= n else false;
        const staged = j.get(active_turn, "tool_result");
        const decision = if (phase == .before_tool) try self.beforeToolDecision(invocation, call, response, cutoff) else blk: {
            const requested = j.get(active_turn, "model_selection");
            const limits = if (requested == .object)
                try self.selectionImageLimits(a, requested)
            else if (std.mem.eql(u8, invocation.conversation, TaskJournal.main_conversation))
                self.imageLimits()
            else
                try self.selectionImageLimits(a, ModelSelection.effective(context.value));
            break :blk try self.afterToolDecision(invocation, call, response, j.get(staged, "reply"), j.get(j.get(staged, "captured"), "images"), cutoff, limits);
        };
        return .{ .next = .{ .checkpoint = decision } };
    }
    const attempt: ForegroundAttempt = .{
        .id = try foregroundCommandId(a, invocation.id, invocation.attempt),
        .task = owner,
        .conversation = invocation.conversation,
        .phase = phase,
        .inbox_owner = j.flag(j.get(invocation.input, "inbox_owner")),
        .resume_input = try j.value(a, .{ .command = "resume", .tool_decision = invocation.checkpoint }),
    };
    return phaseHandoff(a, try self.runPhaseAttempt(invocation, attempt));
}

fn runGenerationHookTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    const owner = j.text(j.get(invocation.input, "task"));
    if (owner.len == 0) return error.InvalidForegroundTask;
    if (invocation.checkpoint == .null) {
        var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
        defer context.deinit();
        if (!j.equal(j.get(j.get(context.value, "foreground_continuation"), "task"), owner)) {
            return .{ .next = .{ .finish = .{ .status = .completed } } };
        }
        const run_state = j.get(j.get(context.value, "session"), "run");
        const saved = j.get(run_state, "generation_hook");
        const stage = std.meta.stringToEnum(GenerationHookStage, j.text(j.get(saved, "stage"))) orelse return error.MissingGenerationHookInput;
        const revision = j.get(saved, "revision");
        if (revision != .integer or revision.integer < 0) return error.MissingGenerationHookInput;
        const cutoff = if (invocation.driver.settings.restart_limit) |n| invocation.restarts != 0 and invocation.restarts >= n else false;
        // The application re-stages a legacy request with freshly projected history.
        const stale_request = stage == .request and j.number(j.get(run_state, "model_view")) != model_view_version;
        const decision = if (stale_request) Value.null else if (cutoff) skipped: {
            try skipGenerationHook(invocation, stage, error.RestartLimit);
            break :skipped Value.null;
        } else try self.generationDecision(invocation, stage, if (stage == .response)
            j.get(j.get(context.value, "__interrupted_application"), "model_reply")
        else
            j.get(saved, "data"));
        try invocation.io.checkCancel();
        return .{ .next = .{ .checkpoint = try j.value(a, .{ .stage = stage, .revision = revision, .value = decision }) } };
    }
    const attempt: ForegroundAttempt = .{
        .id = try foregroundCommandId(a, invocation.id, invocation.attempt),
        .task = owner,
        .conversation = invocation.conversation,
        .phase = .generation_hook,
        .inbox_owner = j.flag(j.get(invocation.input, "inbox_owner")),
        .resume_input = try j.value(a, .{ .command = "resume", .generation_decision = invocation.checkpoint }),
    };
    return phaseHandoff(a, try self.runPhaseAttempt(invocation, attempt));
}

fn skipGenerationHook(invocation: TaskScheduler.Invocation, stage: GenerationHookStage, err: anyerror) !void {
    if (err == error.OutOfMemory) return err;
    try invocation.io.checkCancel();
    std.log.warn("generation {s} hook skipped ({s})", .{ @tagName(stage), @errorName(err) });
}

fn generationHookOptions(hooks: []const GenerationHooks) std.enums.EnumFieldStruct(GenerationHookStage, bool, false) {
    var options: std.enums.EnumFieldStruct(GenerationHookStage, bool, false) = .{};
    for (hooks) |hook| {
        options.request = options.request or hook.before_request != null;
        options.response = options.response or hook.after_response != null or hook.on_yield != null;
        options.tools = options.tools or hook.after_tools != null;
    }
    return options;
}

fn hasProviderPayloadHook(hooks: []const GenerationHooks) bool {
    for (hooks) |hook| if (hook.before_provider_request != null) return true;
    return false;
}

fn generationDecision(self: *Self, invocation: TaskScheduler.Invocation, stage: GenerationHookStage, data: Value) !Value {
    const a = invocation.allocator;
    const hooks = self.settings.generation_hooks;
    switch (stage) {
        .request => {
            if (data != .array) return error.MissingGenerationHookInput;
            var messages = data;
            var changed = false;
            for (hooks) |hook| if (hook.before_request) |callback| {
                try invocation.io.checkCancel();
                const replacement = callback(hook.context, invocation, j.items(messages)) catch |err| {
                    try skipGenerationHook(invocation, stage, err);
                    continue;
                } orelse continue;
                for (replacement) |item| {
                    if (item != .object) break;
                } else {
                    const next = try j.value(a, replacement);
                    agent.session_protocol.json.validate(a, next, null) catch |err| {
                        try skipGenerationHook(invocation, stage, err);
                        continue;
                    };
                    messages = next;
                    changed = true;
                    continue;
                }
                try skipGenerationHook(invocation, stage, error.InvalidModelInput);
            };
            return if (changed) messages else .null;
        },
        .response => {
            if (data != .object) return error.MissingGenerationHookInput;
            for (hooks) |hook| if (hook.after_response) |callback| {
                try invocation.io.checkCancel();
                callback(hook.context, invocation, data) catch |err| try skipGenerationHook(invocation, stage, err);
            };
            const answer = j.equal(j.get(data, "status"), "completed") or j.equal(j.get(data, "stop_reason"), "length");
            if (!answer or j.items(j.get(data, "calls")).len != 0) return .null;
            for (hooks) |hook| if (hook.on_yield) |callback| {
                try invocation.io.checkCancel();
                const content = callback(hook.context, invocation, data) catch |err| {
                    try skipGenerationHook(invocation, stage, err);
                    continue;
                } orelse continue;
                Inbox.validateUserContent(content) catch |err| {
                    try skipGenerationHook(invocation, stage, err);
                    continue;
                };
                agent.session_protocol.json.validate(a, content, null) catch |err| {
                    try skipGenerationHook(invocation, stage, err);
                    continue;
                };
                return try j.copy(a, content);
            };
            return .null;
        },
        .tools => {
            const round = try std.json.parseFromValueLeaky(GenerationHooks.ToolRound, a, data, .{});
            for (hooks) |hook| if (hook.after_tools) |callback| {
                try invocation.io.checkCancel();
                callback(hook.context, invocation, round) catch |err| try skipGenerationHook(invocation, stage, err);
            };
            return .null;
        },
    }
}

fn beforeToolDecision(self: *Self, invocation: TaskScheduler.Invocation, original: ToolCall, response: []const u8, cutoff: bool) !Value {
    const a = invocation.allocator;
    var call = original;
    var block: ?[]const u8 = null;
    if (!cutoff) for (self.settings.before_tool) |hook| {
        try invocation.io.checkCancel();
        const decision = hook.decide(hook.context, invocation, call) catch |err| blocked: {
            if (err == error.OutOfMemory) return err;
            try invocation.io.checkCancel();
            break :blocked BeforeTool.Decision{ .block = @errorName(err) };
        };
        if (decision) |chosen| switch (chosen) {
            .arguments => |arguments| {
                agent.session_protocol.json.validate(a, arguments, null) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    block = @errorName(err);
                    break;
                };
                call.arguments = arguments;
            },
            .block => |message| {
                block = if (std.unicode.utf8ValidateSlice(message)) message else @errorName(error.InvalidUtf8);
                break;
            },
        };
    };
    try invocation.io.checkCancel();
    return j.value(a, .{
        .call_id = call.call_id,
        .response = response,
        .arguments = call.arguments,
        .kind = if (cutoff) "restart_limit" else if (block != null) "blocked" else "execute",
        .message = if (cutoff) "Tool preparation reached its restart limit." else block,
    });
}

fn afterToolDecision(self: *Self, invocation: TaskScheduler.Invocation, call: ToolCall, response: []const u8, saved: Value, captured_images: ?Value, cutoff: bool, limits: ImageProcessing.Limits) !Value {
    const a = invocation.allocator;
    var reply = try std.json.parseFromValueLeaky(ToolResult, a, saved, .{});
    if (!cutoff) for (self.settings.after_tool) |hook| {
        try invocation.io.checkCancel();
        const replacement = hook.transform(hook.context, invocation, call, reply) catch |err| {
            if (err == error.OutOfMemory) return err;
            try invocation.io.checkCancel();
            std.log.warn("afterTool skipped ({s})", .{@errorName(err)});
            continue;
        };
        if (replacement) |updated| {
            agent.session_protocol.json.validate(a, updated.result, null) catch |err| {
                if (err == error.OutOfMemory) return err;
                std.log.warn("afterTool returned an invalid result ({s})", .{@errorName(err)});
                continue;
            };
            if (updated.control) |control| if (control.handoff) |handoff| {
                if (!std.unicode.utf8ValidateSlice(handoff)) {
                    std.log.warn("afterTool returned invalid UTF-8 in its handoff", .{});
                    continue;
                }
            };
            reply.result = updated.result;
            reply.control = updated.control;
        }
    };
    const images = if (captured_images != null and self.settings.image_processing)
        try @import("../images.zig").ToolResultImages.normalize(a, self.gpa, invocation.io, &reply.result, captured_images.?, self.runPolicy().auto_resize_images, limits)
    else
        null;
    try invocation.io.checkCancel();
    var decision = try j.value(a, .{ .call_id = call.call_id, .response = response, .reply = reply });
    if (images) |attachments| try j.put(a, &decision, "images", try j.copy(a, attachments));
    return decision;
}

fn runPhaseAttempt(self: *Self, invocation: TaskScheduler.Invocation, attempt: ForegroundAttempt) !ForegroundProgress {
    if (try self.recoverWorkerAttempt(invocation, attempt)) |progress| return progress;
    return self.invokeAttempt(try attempt.resumeInput(invocation.allocator), attempt);
}

fn runForegroundAttempt(self: *Self, invocation: TaskScheduler.Invocation, work: ForegroundWork) !ForegroundProgress {
    const a = invocation.allocator;
    const submission = j.text(j.get(invocation.input, "submission"));
    const attempt: ForegroundAttempt = .{ .id = try foregroundCommandId(a, invocation.id, invocation.attempt), .task = invocation.id, .conversation = invocation.conversation, .inbox_owner = work == .drain_writes };
    if (try self.recoverWorkerAttempt(invocation, attempt)) |progress| return progress;
    if ((work == .turn or work == .drain_writes) and invocation.checkpoint == .null and try self.hasPlacedRun(invocation)) {
        return .{ .delegate = .model };
    }
    if (work == .drain_writes) {
        var inbox = try self.conversationDatagrams(self.gpa, invocation.conversation);
        defer inbox.deinit();
        const item = j.get(j.get(inbox.value, "value"), submission);
        const state = Inbox.disposition(item) orelse return error.InvalidDatagram;
        if ((state != .pending and state != .claimed) or Inbox.held(item)) return .completed;
        return self.invokeInboxAdmission(a, attempt);
    }
    if (j.equal(invocation.checkpoint, "continue")) {
        return self.invokeAttempt(try j.value(a, .{ .command = "resume" }), attempt);
    }
    if (work == .automatic_compaction) {
        return self.invokeAttempt(try j.value(a, .{
            .command = "compact",
            .focus = "",
            .reason = CompactionReason.threshold,
            .submission = try std.fmt.allocPrint(a, "auto/{s}", .{invocation.id}),
            .config = if (attempt.scoped()) null else try self.configuration(a),
        }), attempt);
    }
    try self.ensureTaskPrompt(invocation);
    const input = if (work == .recover) try j.value(a, .{ .command = "resume" }) else blk: {
        var inbox = try self.conversationDatagrams(self.gpa, invocation.conversation);
        defer inbox.deinit();
        const datagram = j.get(j.get(inbox.value, "value"), submission);
        const status = Inbox.disposition(datagram);
        if (work == .turn and (Inbox.held(datagram) or status == .consumed or (status == .discarded and j.get(datagram, "reason") == .string))) return .nothing_to_answer;
        if (status != .pending and !(status == .claimed and (work == .reset or
            (work == .turn and j.get(datagram, "continuation") == .null)))) return error.ForegroundInputUnavailable;
        const body = j.get(datagram, "input");
        const config = if (attempt.scoped()) .null else try self.configuration(a);
        break :blk switch (work) {
            .turn => turn: {
                var prompt = try Inbox.deliveredPrompt(a, submission, body);
                try prompt.object.put(a, "config", config);
                const recorded = j.get(datagram, "model_selection");
                const selection = if (recorded != .null) recorded else j.get(invocation.input, "model_selection");
                if (selection != .null) try prompt.object.put(a, "submission_selection", try j.copy(a, selection));
                break :turn prompt;
            },
            .compact => try j.value(a, .{ .command = "compact", .focus = try a.dupe(u8, j.text(j.get(body, "focus"))), .submission = submission, .config = config }),
            .continue_turn => try j.value(a, .{ .command = "continue_turn", .submission = submission, .config = config }),
            .reset => try j.value(a, .{ .command = "reset", .note = try a.dupe(u8, j.text(j.get(body, "note"))), .submission = submission, .config = config }),
            .recover, .automatic_compaction, .drain_writes => unreachable,
        };
    };
    return self.invokeAttempt(input, attempt);
}

fn hasPlacedRun(self: *Self, invocation: TaskScheduler.Invocation) !bool {
    var ctx = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
    defer ctx.deinit();
    const placed = j.get(j.get(ctx.value, "session"), "run");
    return j.equal(j.get(placed, "owner"), invocation.id) and j.equal(j.get(placed, "phase"), "model") and
        j.equal(j.get(j.get(ctx.value, "foreground_continuation"), "task"), invocation.id);
}

fn ensureTaskPrompt(self: *Self, invocation: TaskScheduler.Invocation) !void {
    const prompt = j.get(invocation.input, "prompt");
    if (prompt == .null) return;
    const id = j.text(j.get(invocation.input, "submission"));
    const text = j.get(prompt, "text");
    const original = j.get(prompt, "original");
    if (id.len == 0 or text != .string or original != .string) return error.InvalidForegroundTask;
    try self.enqueueNamedPrompt(invocation.allocator, invocation.conversation, id, prompt, j.get(invocation.input, "model_selection"));
}

fn recoverWorkerAttempt(self: *Self, invocation: TaskScheduler.Invocation, attempt: ForegroundAttempt) !?ForegroundProgress {
    if (!invocation.interrupted) return null;
    const a = invocation.allocator;
    const placing_write = attempt.inbox_owner and attempt.phase == null;
    var previous = invocation.attempt - 1;
    while (previous != 0) : (previous -= 1) {
        const command = try foregroundCommandId(a, invocation.id, previous);
        var receipt = try self.gateway.readCommandReceipt(self.worker.?, self.gpa, command);
        defer receipt.deinit();
        if (receipt.value == .null) continue;
        const outcome = j.get(receipt.value, "outcome");
        const diagnostic = j.get(outcome, "error");
        if (j.equal(j.get(diagnostic, "code"), "interrupted_not_started")) continue;
        if (j.equal(j.get(diagnostic, "code"), "interrupted")) {
            if (placing_write) return try self.invokeInboxAdmission(a, attempt);
            return try self.invokeAttempt(try attempt.resumeInput(a), attempt);
        }
        if (placing_write and j.equal(j.get(j.get(outcome, "result"), "status"), "write_waiting")) return try self.invokeInboxAdmission(a, attempt);
        const progress = try self.checkForegroundOutcome(a, attempt.conversation, j.text(j.get(outcome, "status")), j.get(outcome, "result"), diagnostic);
        if (!attempt.scoped() and !attempt.inbox_owner and (progress == .completed or progress == .nothing_to_answer)) try self.promoteSteering();
        return progress;
    }
    return null;
}

fn cancelForegroundAttempt(self: *Self, invocation: TaskScheduler.Invocation) !void {
    const a = invocation.allocator;
    if (invocation.attempt > 1) {
        const target = try foregroundCommandId(a, invocation.id, invocation.attempt - 1);
        const cancel_request = try self.gateway.cancelInvocation(self.worker.?, try self.requestId(a), target);
        defer cancel_request.deinit();
        var outcome = try cancel_request.wait(self.io);
        defer outcome.deinit();
        if (outcome.status != .completed and !j.equal(j.get(outcome.diagnostic, "code"), "stale_invocation")) return error.ForegroundCancelFailed;
        try self.gateway.joinInvocation(self.worker.?, target);
    }
}

fn cleanupPhaseTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    try self.cancelForegroundAttempt(invocation);
    if (self.tasks) |tasks| tasks.notify();
    return .{ .next = .{ .finish = .{ .status = .aborted, .value = j.string("cancelled") } } };
}

fn cleanupForegroundTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const a = invocation.allocator;
    try self.cancelForegroundAttempt(invocation);
    const main = std.mem.eql(u8, invocation.conversation, TaskJournal.main_conversation);
    if (try self.ownsScopedRun(invocation)) try self.settleAbortedConversation(invocation);
    if (self.tasks) |tasks| tasks.notify();
    if (main) try self.promoteSteering();
    const submission = j.text(j.get(invocation.input, "submission"));
    if (submission.len != 0) {
        try self.ensureTaskPrompt(invocation);
        var pending = j.object();
        const work = j.get(invocation.input, "work");
        const prompt = j.equal(work, "turn");
        try pending.object.put(a, submission, if (prompt) j.string("aborted") else .null);
        try self.writeConversationInbox(invocation.conversation, if (prompt) "withdraw" else "settle", pending);
    }
    if (main) try self.refresh();
    return .{ .next = .{ .finish = .{ .status = .aborted, .value = j.string("cancelled") } } };
}

fn ownsScopedRun(self: *Self, invocation: TaskScheduler.Invocation) !bool {
    var document = try self.gateway.readApplicationContext(self.worker.?, self.gpa, invocation.conversation);
    defer document.deinit();
    const ctx = document.value;
    const session = j.get(ctx, "session");
    for ([_]Value{ j.get(j.get(session, "run"), "owner"), j.get(j.get(ctx, "after_run"), "owner"), j.get(j.get(ctx, "foreground_continuation"), "task") }) |owner| {
        if (owner == .string) return j.equal(owner, invocation.id);
    }
    const selection = j.get(invocation.input, "submission");
    if (selection == .string and j.get(session, "run") == .object and j.equal(j.get(session, "last_submission"), selection.string)) return true;
    const saved = j.get(j.get(ctx, "__interrupted_application"), "input_json");
    if (saved != .string) return false;
    const input = try j.parse(document.allocator(), saved.string);
    return j.equal(j.get(input, "foreground_task"), invocation.id);
}

fn foregroundReady(raw: ?*anyopaque, conversation: []const u8) bool {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    return !std.mem.eql(u8, conversation, TaskJournal.main_conversation) or
        self.root_scheduling.load(.acquire) or self.foreground_ready.load(.acquire);
}

fn foregroundChildReady(raw: ?*anyopaque, conversation: []const u8, input: Value) bool {
    return j.flag(j.get(input, "inbox_owner")) or foregroundReady(raw, conversation);
}

fn foregroundWait(self: *Self, tasks: *TaskScheduler, a: std.mem.Allocator, id: [64]u8) !void {
    self.steering_mutex.lockUncancelable(self.io);
    self.foreground_task = id;
    self.steering_mutex.unlock(self.io);
    defer {
        self.foreground_ready.store(false, .release);
        tasks.notify();
        self.steering_mutex.lockUncancelable(self.io);
        self.foreground_task = null;
        self.steering_mutex.unlock(self.io);
    }
    if (self.stop.load(.acquire)) try tasks.abort(&id);
    self.foreground_ready.store(true, .release);
    tasks.notify();
    var outcome = tasks.wait(a, &id) catch |err| {
        if (err == error.Canceled) {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            self.stop.store(true, .release);
            try tasks.abort(&id);
            var settled = try tasks.wait(a, &id);
            settled.deinit();
        }
        return err;
    };
    defer outcome.deinit();
    const status = j.text(j.get(outcome.value, "status"));
    if (std.mem.eql(u8, status, "completed")) return;
    if (std.mem.eql(u8, status, "aborted")) return error.Canceled;
    const reason = j.text(j.get(outcome.value, "value"));
    const failures = .{ error.NothingToCompact, error.ContextOverflow, error.WorkerCommandFailed, error.ApplicationFailed, error.ControllerPolicyRestoreFailed, error.NotificationDeliveryFailed };
    inline for (failures) |failure| if (std.mem.eql(u8, reason, @errorName(failure))) return failure;
    try self.emit(.{ .kind = .notice, .text = try std.fmt.allocPrint(a, "Foreground task stopped ({s}).", .{reason}) });
    return error.ForegroundTaskFailed;
}

fn scheduleForeground(self: *Self, work: ForegroundWork, submission: ?[]const u8) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    try self.scheduleForegroundLocked(work, submission);
}

fn scheduleForegroundLocked(self: *Self, work: ForegroundWork, submission: ?[]const u8) !void {
    try self.io.checkCancel();
    if (work == .turn) {
        var inbox = try self.pendingDatagrams(self.gpa);
        defer inbox.deinit();
        const input = j.get(j.get(inbox.value, "value"), submission orelse return error.InvalidForegroundTask);
        if (Inbox.held(input)) return;
    }
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    try self.submitForegroundTask(temporary.allocator(), work, submission, &.{});
}

fn submitForegroundTask(self: *Self, a: std.mem.Allocator, work: ForegroundWork, submission: ?[]const u8, extensions: []const agent.ExtensionWrite) !void {
    try self.io.checkCancel();
    self.stop.store(false, .release);
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ @tagName(work), submission orelse try self.requestId(a) });
    const id = Inbox.inputHash(key);
    try tasks.submitWithExtensions(.{ .id = &id, .kind = foreground_kind, .input = try j.value(a, .{ .work = work, .submission = submission }) }, extensions);
    try self.foregroundWait(tasks, a, id);
}

fn runRegistrationTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const submission = j.text(j.get(invocation.input, "submission"));
    const batch = j.get(invocation.input, "batch");
    if (submission.len == 0 or batch != .object) return error.InvalidDatagram;
    const request = try self.deliverRegistration(invocation.allocator, submission, batch);
    defer request.deinit();
    var outcome = try request.wait(invocation.io);
    defer outcome.deinit();
    if (outcome.status == .cancelled) return error.Canceled;
    const value = if (outcome.status == .completed) outcome.result else outcome.diagnostic;
    return .{ .next = .{ .finish = .{
        .status = if (outcome.status == .completed) .completed else .failed,
        .value = try j.copy(invocation.allocator, value),
    } } };
}

fn runWriteTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    var step = try self.advanceForegroundTask(invocation, .drain_writes);
    if (step.next != .finish or step.next.finish.status == .aborted) return step;
    const submission = j.text(j.get(invocation.input, "submission"));
    var inbox = try self.conversationDatagrams(self.gpa, invocation.conversation);
    defer inbox.deinit();
    const item = j.get(j.get(inbox.value, "value"), submission);
    const receipt = try Inbox.receipt(invocation.allocator, item);
    if (step.next.finish.status != .completed and receipt.disposition != .consumed and receipt.disposition != .rejected) return step;
    if (std.mem.startsWith(u8, submission, "request/compaction/") and std.mem.eql(u8, invocation.conversation, TaskJournal.main_conversation)) {
        self.presentCompactionPlacement(receipt) catch |err| std.log.warn("compaction presentation failed ({s})", .{@errorName(err)});
    }
    step.next.finish = .{ .status = .completed, .value = try j.value(invocation.allocator, receipt) };
    return step;
}

fn presentCompactionPlacement(self: *Self, receipt: Inbox.Receipt) !void {
    const worker = self.worker orelse return error.WorkerStopped;
    var context = try self.gateway.readApplicationContext(worker, self.gpa, TaskJournal.main_conversation);
    defer context.deinit();
    const tokens = j.number(j.get(j.get(context.value, "session"), "context_tokens"));
    self.context_tokens.store(tokens, .release);
    self.scanUsage(tokens) catch |err| std.log.warn("compaction usage refresh failed ({s})", .{@errorName(err)});
    if (receipt.entry) |id| {
        var entry = (try self.gateway.readHistory(worker, self.gpa, .{ .stream = .application, .id = id })) orelse return;
        defer entry.deinit();
        if (j.equal(j.get(entry.value, "kind"), "checkpoint")) {
            try self.emit(.{
                .kind = .compacted,
                .entry_id = id,
                .text = j.text(j.get(entry.value, "summary")),
                .tokens = self.contextTokens(),
                .compaction_tokens_before = compactionTokensBefore(entry.value),
            });
        }
    } else if (receipt.disposition == .rejected) {
        try self.emit(.{ .kind = .notice, .text = "Compaction range changed before placement." });
    }
}

fn invokeInboxAdmission(self: *Self, a: std.mem.Allocator, attempt: ForegroundAttempt) !ForegroundProgress {
    const input = try j.value(a, .{
        .command = "drain_writes",
        .foreground_task = attempt.task,
        .steering_invocation = attempt.id,
        .inbox_owner = true,
    });
    const request = try self.deliverWithId(attempt.id, .{
        .input_json = try j.encode(a, input),
        .conversation = if (attempt.scoped()) attempt.conversation else null,
    }, null, .{});
    defer request.deinit();
    defer self.forgetDelivery(request.id);
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    try self.awaitDelivery(request.id, false);
    return self.checkForegroundOutcome(a, attempt.conversation, @tagName(outcome.status), outcome.result, outcome.diagnostic);
}

fn cleanupWriteTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    try self.cancelForegroundAttempt(invocation);
    if (try self.ownsScopedRun(invocation)) try self.settleAbortedConversation(invocation);
    return .{ .next = .{ .finish = .{ .status = .aborted, .value = j.string("cancelled") } } };
}

const provider_cancel_document: TaskJournal.Document.Address = .{ .kind = "provider-cancellation" };
const ProviderCancelPause = enum { controller_busy, route_unavailable, unauthorized, provider_retry };

fn runProviderCancelTask(raw: ?*anyopaque, invocation: TaskScheduler.Invocation) !TaskJournal.Step {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    const id = j.text(j.get(invocation.input, "response_id"));
    const route = j.text(j.get(invocation.input, "route"));
    const credential = j.text(j.get(invocation.input, "credential"));
    const value = j.get(invocation.input, "deferred");
    const deferred = if (value == .null) null else try std.json.parseFromValueLeaky(services.ModelDeferred, invocation.allocator, value, .{});
    if (route.len == 0 or credential.len == 0) return error.InvalidCancellationTask;
    if (deferred) |saved_handle| {
        if (id.len != 0 or saved_handle.handle == .null or !transport.validDeferredAdapterId(saved_handle.adapter)) return error.InvalidCancellationTask;
    } else if (!agent.session_protocol.frames.validProviderResponseId(id)) return error.InvalidCancellationTask;
    const saved = try invocation.document(provider_cancel_document);
    const failure_value = if (saved) |document| j.get(document.value, "failures") else invocation.checkpoint;
    const failures: u8 = @intCast(@min(j.number(failure_value), std.math.maxInt(u8)));
    const source: struct { provider: Provider, retry: Retry, adapter: ?transport.DeferredAdapter } = blk: {
        if (try decodeSelection(invocation.allocator, j.get(invocation.input, "selection"))) |selection| {
            const candidate = self.scoped_routes.resolve(invocation.allocator, invocation.io, selection) catch |err| {
                if (!transport.transientError(err)) return err;
                return providerCancelSleep(invocation, saved, failures, .route_unavailable, 30000);
            };
            const resolved = candidate orelse
                return providerCancelSleep(invocation, saved, failures, .route_unavailable, 30000);
            if (!std.mem.eql(u8, std.mem.trimEnd(u8, resolved.base_url, "/"), std.mem.trimEnd(u8, route, "/")) or
                !std.mem.eql(u8, resolved.credential, credential) or !canCancelProvider(resolved.transport.mode.live, resolved.deferred, deferred))
                return providerCancelSleep(invocation, saved, failures, .route_unavailable, 30000);
            break :blk .{ .provider = resolved.transport.mode.live.*, .retry = resolved.retry, .adapter = resolved.deferred };
        }
        if (!self.session_change_mutex.tryLock()) return providerCancelSleep(invocation, saved, failures, .controller_busy, 500);
        defer self.session_change_mutex.unlock(self.io);
        const current = self.provider;
        const adapter = self.scoped_routes.deferredFor(current);
        if (!canCancelProvider(current, adapter, deferred) or current.api_key.len == 0 or
            !std.mem.eql(u8, std.mem.trimEnd(u8, current.base_url, "/"), std.mem.trimEnd(u8, route, "/")) or
            !std.mem.eql(u8, current.credentialLabel(), credential)) return providerCancelSleep(invocation, saved, failures, .route_unavailable, 30000);
        break :blk .{ .provider = try self.providerSnapshot(invocation.allocator), .retry = self.settings.provider_retry, .adapter = adapter };
    };
    const provider = source.provider;
    defer std.crypto.secureZero(u8, provider.api_key);
    const result = if (deferred) |saved_handle| try transport.cancelDeferred(source.adapter.?, .{
        .allocator = invocation.allocator,
        .io = invocation.io,
        .provider = &provider,
        .handle = saved_handle.handle,
    }) else try transport.cancelBackground(invocation.allocator, invocation.io, &provider, id);
    return switch (result.status) {
        .settled => .{ .next = .{ .finish = .{ .status = .completed, .value = j.string("provider_response_settled") } } },
        .unavailable, .rejected => .{ .next = .{ .finish = .{ .status = .failed, .value = j.string(@tagName(result.status)) } } },
        .unauthorized => providerCancelSleep(invocation, saved, failures, .unauthorized, 30000),
        .retry => providerCancelSleep(invocation, saved, failures +| 1, .provider_retry, @max(500, source.retry.delay(invocation.io, failures +| 1, result.retry_after_ms))),
    };
}

fn canCancelProvider(provider: *const Provider, adapter: ?transport.DeferredAdapter, deferred: ?services.ModelDeferred) bool {
    const saved = deferred orelse return provider.supportsNativeResume();
    const current = adapter orelse return false;
    return std.mem.eql(u8, saved.adapter, current.id);
}

fn providerCancelSleep(invocation: TaskScheduler.Invocation, saved: ?TaskJournal.Document.Snapshot, failures: u8, reason: ProviderCancelPause, delay: u32) !TaskJournal.Step {
    const a = invocation.allocator;
    const edits = try a.alloc(TaskJournal.Document.Edit, 1);
    edits[0] = .{
        .address = provider_cancel_document,
        .change = if (saved) |document| .{ .patch = .{
            .expected = document.version,
            .ops = (try j.value(a, .{ .{ "s", .{"failures"}, failures }, .{ "s", .{"reason"}, @tagName(reason) } })).array.items,
        } } else .{ .create = .{ .value = try j.value(a, .{ .failures = failures, .reason = reason }) } },
    };
    const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(invocation.io).toMilliseconds()));
    return .{ .next = .{ .sleep = .{ .checkpoint = .null, .until_ms = now +| delay } }, .documents = edits };
}

fn restoreRegistrations(self: *Self) !void {
    const scheduler = self.tasks orelse return error.TaskSchedulerClosed;
    var pending = try self.pendingDatagrams(self.gpa);
    defer pending.deinit();
    const state = j.get(pending.value, "value");
    if (state != .object) return;
    const a = pending.allocator();
    for (state.object.keys(), state.object.values()) |submission, datagram| {
        if (Inbox.disposition(datagram) != .pending or !j.equal(j.get(datagram, "kind"), "register_tools")) continue;
        const batch = try j.parse(a, j.text(j.get(j.get(datagram, "input"), "json")));
        const id = try std.fmt.allocPrint(a, "registration/{s}", .{submission});
        try scheduler.submit(.{
            .id = id,
            .kind = registration_task,
            .input = try j.value(a, .{ .submission = submission, .batch = batch }),
        });
        var outcome = try scheduler.wait(self.gpa, id);
        defer outcome.deinit();
        if (j.equal(j.get(outcome.value, "status"), "completed")) continue;
        var updated = try self.pendingDatagrams(self.gpa);
        defer updated.deinit();
        const current = j.get(j.get(updated.value, "value"), submission);
        if (Inbox.disposition(current) != .rejected) return error.WorkerCommandFailed;
        const detail = j.get(outcome.value, "value");
        try self.emit(.{ .kind = .notice, .text = try j.encode(a, detail), .data = detail });
    }
}

pub fn select(self: *Self, id: []const u8) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var ctx = try self.gateway.readContext(self.worker.?, self.gpa);
    defer ctx.deinit();
    try self.invoke(try j.value(a, .{ .command = "select", .at = id, .expected_revision = j.get(j.get(ctx.value, "session"), "revision"), .config = try self.configuration(a) }));
}

pub const TreeNavigation = union(enum) { unchanged, navigated: ?[]const u8 };
const TreeChange = union(enum) { navigate, label: []const u8, summarize: []const u8 };

pub fn navigateTree(self: *Self, a: std.mem.Allocator, id: []const u8) !TreeNavigation {
    return self.changeTree(a, id, .navigate);
}

pub fn summarizeTree(self: *Self, a: std.mem.Allocator, id: []const u8, focus: []const u8) !TreeNavigation {
    return self.changeTree(a, id, .{ .summarize = focus });
}

pub fn labelTree(self: *Self, id: []const u8, label: []const u8) !void {
    _ = try self.changeTree(self.gpa, id, .{ .label = label });
}

fn changeTree(self: *Self, a: std.mem.Allocator, id: []const u8, change: TreeChange) !TreeNavigation {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const worker = self.worker orelse return error.InvalidSession;
    var ctx = try self.gateway.readContext(worker, temp);
    defer ctx.deinit();
    const state = j.get(ctx.value, "session");
    const shown_head = if (change != .label) try self.treeHead(temp) else null;
    if (shown_head) |shown| if (std.mem.eql(u8, shown, id)) return .unchanged;
    var target = (try self.gateway.readHistory(worker, temp, .{ .stream = .application, .id = id, .include_display_parent = change != .label })) orelse return error.InvalidSessionEntry;
    defer target.deinit();
    const input = if (change != .label and j.equal(j.get(target.value, "kind"), "input")) j.get(target.value, "text") else .null;
    const draft = if (input == .string) try a.dupe(u8, input.string) else null;
    errdefer if (draft) |value| a.free(value);
    var payload = try j.value(temp, .{
        .command = if (change == .label) "label_tree" else "navigate_tree",
        .at = id,
        .label = if (change == .label) change.label else null,
        .display_parent = target.display_parent,
        .expected_revision = j.get(state, "revision"),
    });
    if (change == .summarize) {
        if (!self.configured()) return error.ModelUnavailable;
        var plan = try self.gateway.queryApplication(worker, temp, TaskJournal.main_conversation, try j.value(temp, .{
            .command = "plan_tree_summary",
            .at = id,
            .focus = change.summarize,
        }));
        defer plan.deinit();
        const status = j.get(plan.value, "status");
        if (j.equal(status, "unchanged")) {
            if (draft) |value| a.free(value);
            return .unchanged;
        }
        if (j.equal(status, "conversation_busy")) return error.ControllerBusy;
        if (!j.equal(status, "planned")) return error.InvalidSessionEntry;
        try j.put(temp, &payload, "expected_revision", j.get(plan.value, "revision"));
        const request = j.get(plan.value, "prompt");
        if (request == .string) {
            const summary = try self.generateBranchSummary(temp, worker, request.string, j.text(j.get(plan.value, "suffix")));
            try j.put(temp, &payload, "summary", j.string(summary.text));
            try j.put(temp, &payload, "summary_usage", summary.usage);
            try j.put(temp, &payload, "details", j.get(plan.value, "details"));
        } else {
            try j.put(temp, &payload, "summary", j.get(plan.value, "summary"));
        }
        // Encode before releasing the plan document. The commit is short and joined,
        // so a late Escape can observe its real result.
        const encoded = try j.encode(temp, payload);
        try self.io.checkCancel();
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        try self.commitTreeChange(encoded);
    } else try self.commitTreeChange(try j.encode(temp, payload));
    return .{ .navigated = draft };
}

fn commitTreeChange(self: *Self, encoded: []const u8) !void {
    defer self.refresh() catch {};
    const request = try self.deliver(.{ .input_json = encoded }, null);
    defer request.deinit();
    defer self.forgetDelivery(request.id);
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    try self.awaitDelivery(request.id, false);
    if (outcome.status != .completed) return error.WorkerCommandFailed;
    const status = j.get(outcome.result, "status");
    if (j.equal(status, "conversation_busy")) return error.ControllerBusy;
    if (j.equal(status, "stale_selection")) return error.StaleTreeSelection;
    if (!j.equal(status, "completed")) return error.ApplicationFailed;
}

const SummaryProgress = struct {
    allocator: std.mem.Allocator,
    latest: ?services.ModelProgress = null,

    fn write(raw: *anyopaque, progress: services.ModelProgress) !void {
        const self: *SummaryProgress = @ptrCast(@alignCast(raw));
        const previous_id = if (self.latest) |previous| previous.response_id else "";
        const response_id = if (std.mem.eql(u8, previous_id, progress.response_id))
            previous_id
        else
            try self.allocator.dupe(u8, progress.response_id);
        self.latest = progress;
        self.latest.?.response_id = response_id;
    }

    fn clear(self: *SummaryProgress) void {
        self.latest = null;
    }
};

fn generateBranchSummary(self: *Self, a: std.mem.Allocator, worker: agent.WorkerId, prompt: []const u8, suffix: []const u8) !struct { text: []const u8, usage: Value } {
    const base_id = try self.requestId(a);
    const selection = try self.captureModelSelection(a, TaskJournal.main_conversation);
    const binding: agent.ApplicationModel = .{
        .model = .{
            .model = selection.model,
            .base_url = selection.base_url,
            .credential = try selection.credential(a),
            .reasoning_effort = selection.reasoning_effort,
            .max_output_tokens = self.settings.max_output_tokens,
        },
        .selection = try j.value(a, selection),
    };
    var body = try j.value(a, .{
        .model = selection.model,
        .instructions = prompts.summary_system,
        .input = .{.{ .role = "user", .content = prompt }},
        .tools = j.array(a),
        .max_output_tokens = binding.model.max_output_tokens,
    });
    if (selection.reasoning_effort) |effort| try j.put(a, &body, "reasoning", try j.value(a, .{ .effort = effort }));
    var progress: SummaryProgress = .{ .allocator = a };
    errdefer if (progress.latest) |latest| {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.cancelBranchResponse(a, base_id, binding, latest.response_id) catch |err|
            std.log.warn("Could not schedule branch summary cancellation: {s}", .{@errorName(err)});
    };
    self.summarizing.store(true, .release);
    defer self.summarizing.store(false, .release);
    var failures: u32 = 0;
    while (true) {
        var attempt: std.heap.ArenaAllocator = .init(self.gpa);
        defer attempt.deinit();
        const temp = attempt.allocator();
        const resume_state: ?services.ModelResume = if (progress.latest) |saved| .{
            .route = binding.model.base_url,
            .credential = binding.model.credential,
            .progress = saved,
        } else null;
        const response = try self.gateway.requestTaskModel(worker, temp, self.io, .{
            .id = try std.fmt.allocPrint(temp, "branch-summary/{s}/{d}", .{ base_id, failures }),
            .binding = binding,
            .body = body,
            .resume_state = resume_state,
            .progress = .{ .context = &progress, .write = SummaryProgress.write },
        });
        const reply = try agent.responses.interpret(temp, response, false);
        if (reply.status == .poll_pending) {
            const deadline = reply.next_poll_ms orelse return error.InvalidRetryDeadline;
            if (progress.latest == null) return error.MissingModelProgress;
            const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(self.io).toMilliseconds()));
            try std.Io.sleep(self.io, .fromMilliseconds(@intCast(deadline -| now)), .awake);
            continue;
        }
        progress.clear();
        if (reply.calls.len != 0) return error.BranchSummaryToolCall;
        if (reply.status == .completed) return .{
            .text = try std.fmt.allocPrint(a, "The user explored a different conversation branch before returning here.\nSummary of that exploration:\n\n{s}{s}", .{ reply.text, suffix }),
            .usage = try j.copy(a, j.get(reply.raw, "usage")),
        };
        if (!reply.retryable) return error.BranchSummaryFailed;
        failures +|= 1;
        if (self.settings.fresh_retry_limit) |limit| if (failures > limit) return error.BranchSummaryFailed;
        const delay = self.settings.provider_retry.delay(self.io, @intCast(@min(failures, 32)), reply.retry_after_ms);
        try std.Io.sleep(self.io, .fromMilliseconds(delay), .awake);
    }
}

fn cancelBranchResponse(self: *Self, a: std.mem.Allocator, id: []const u8, binding: agent.ApplicationModel, response_id: []const u8) !void {
    if (!agent.session_protocol.frames.validProviderResponseId(response_id)) return;
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    try tasks.submit(.{
        .id = try std.fmt.allocPrint(a, "provider-cancel/branch-summary/{s}", .{id}),
        .kind = provider_cancel_task,
        .background = true,
        .input = try j.value(a, .{
            .response_id = response_id,
            .route = binding.model.base_url,
            .credential = binding.model.credential,
            .selection = binding.selection,
        }),
    });
}

/// Fork the selected journal entry into an ownerless conversation.
pub fn forkConversation(self: *Self, a: std.mem.Allocator, parent: []const u8, anchor: []const u8) ![]const u8 {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const worker = self.worker orelse return error.TaskSchedulerClosed;
    const fork = try self.gateway.planApplicationFork(worker, temp, parent, anchor);
    var historical = try self.gateway.readApplicationContextAt(worker, temp, fork.base.context, .{ .at = fork.base.at });
    defer historical.deinit();
    const saved = j.get(j.get(historical.value, "session"), "config");
    const config = if (saved == .object) saved else self.scoped_defaults;
    var seed = try j.value(temp, .{
        .session = .{ .revision = 0, .next_id = 1, .head = fork.head, .config = config, .context_tokens = 0, .forked = true },
    });
    const chosen = ModelSelection.effective(historical.value);
    if (chosen == .object) try seed.object.put(temp, "model_selection", chosen);
    const captured = (try ContextJournal.capture(temp, j.object(), seed)) orelse return error.InvalidMinimalContext;
    const child = try self.requestId(a);
    errdefer a.free(child);
    try tasks.createConversationWithExtensions(.{ .id = child, .base = fork.base }, &.{.{
        .namespace = try agent.applicationScopeNamespace(temp, ContextJournal.namespace, child),
        .action = ContextJournal.action,
        .input = .{ .contract = ContextJournal.contract.version, .value = captured },
    }});
    return child;
}

/// Admit addressed prompts and wait for the conversation's durable work.
/// An empty batch resumes the selected conversation's existing work.
pub fn runConversationBatch(self: *Self, conversation: []const u8, inputs: []const Prepared, request: ?[]const u8) !void {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    if ((try tasks.readConversation(a, conversation)) == null) return error.UnknownContext;
    var ids: std.ArrayList([]const u8) = .empty;
    if (inputs.len == 0) {
        var snapshot = try tasks.snapshot(a);
        defer snapshot.deinit();
        const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
        if (records == .object) for (records.object.keys(), records.object.values()) |id, record| {
            if (j.equal(j.get(record, "conversation"), conversation) and j.equal(j.get(record, "kind"), foreground_kind) and
                j.get(j.get(record, "state"), "terminal") == .null) try ids.append(a, try a.dupe(u8, id));
        };
    }
    for (inputs) |input| {
        const submission = request orelse try self.requestId(a);
        const pending = try conversationInput(a, conversation, submission, input, null);
        try tasks.submitWithExtensions(pending.task, &.{pending.admission});
        try ids.append(a, pending.task.id);
    }
    try tasks.resumeScheduling();
    try tasks.waitConversationIdle(conversation, false);
    for (ids.items) |id| {
        var outcome = try tasks.wait(a, id);
        defer outcome.deinit();
        if (!j.equal(j.get(outcome.value, "status"), "completed")) return error.ApplicationFailed;
    }
}

fn configuration(self: *Self, a: std.mem.Allocator) !Value {
    const missing = self.unavailable_model;
    return j.value(a, .{
        .model = if (missing) |selection| selection.model else self.modelName(),
        .workspace = self.settings.saved_workspace orelse self.settings.workspace,
        .instructions = self.system_prompt,
        .max_output_tokens = self.settings.max_output_tokens,
        .reasoning_effort = if (missing) |selection| selection.reasoning_effort else self.settings.reasoning_effort,
        .thinking_level = if (missing) |selection| selection.thinking_level else self.effortLabel(),
        .thinking_levels = if (missing == null) try thinkingLevels(a, try self.thinkingProfile()) else null,
        .context_window = self.settings.context_window,
        .reserve_tokens = self.settings.reserve_tokens,
        .keep_recent_tokens = self.settings.keep_recent_tokens,
        .background_compaction_tokens = self.settings.background_compaction_tokens,
    });
}

fn thinkingLevels(a: std.mem.Allocator, profile: ?thinking.Profile) !?[]const thinking.Level {
    const known = profile orelse return null;
    var levels: std.ArrayList(thinking.Level) = .empty;
    for (thinking.levels) |level| if (known.supports(level)) try levels.append(a, level);
    return levels.items;
}

pub fn unconfiguredProvider(a: std.mem.Allocator) !*Provider {
    const result = try a.create(Provider);
    errdefer a.destroy(result);
    result.* = try Provider.initOptions(a, .{ .base_url = "http://127.0.0.1:1/v1", .model = "unconfigured", .api_key = "unconfigured" });
    return result;
}

pub fn configured(self: *const Self) bool {
    return !std.mem.eql(u8, self.provider.api_key, "unconfigured");
}

fn modelSelection(self: *Self, a: std.mem.Allocator) !?ModelSelection {
    if (!self.configured()) return null;
    return try self.captureModelSelection(a, try self.requestId(a));
}

fn captureModelSelection(self: *Self, a: std.mem.Allocator, id: []const u8) !ModelSelection {
    var selection = try ModelSelection.capture(a, id, self.provider, if (self.settings.refresh_saved_auth) .saved else .environment, self.settings.reasoning_effort, self.effortLabel());
    if (self.settings.auth_store) |auth| selection.provider_ref = selection.environmentReference(self.provider, auth, self.scoped_routes.providers);
    return selection;
}

fn legacyModelRoute(a: std.mem.Allocator, context: Value, model_frame: @FieldType(agent.session_protocol.frames.Action, "control.set_model")) !?@FieldType(agent.Config, "context_journal").ModelRoute {
    const selection = ModelSelection.effective(context);
    const chosen = (try decodeSelection(a, selection)) orelse return null;
    const label = if (chosen.kind == .deepseek) "deepseek" else transport.credential_label;
    if (!std.mem.eql(u8, label, model_frame.credential_ref orelse "") or
        !std.mem.eql(u8, chosen.base_url, std.mem.trimEnd(u8, model_frame.route, "/")) or
        !std.mem.eql(u8, chosen.model, model_frame.model)) return null;
    return .{ .selection = selection, .credential = try chosen.credential(a) };
}

fn savedEffort(self: *const Self, preference: ?ModelSelection) ?[]const u8 {
    const saved = preference orelse return null;
    if (!self.configured() or !saved.matchesProvider(self.provider) or !std.mem.eql(u8, saved.model, self.modelName())) return null;
    return if (std.mem.eql(u8, saved.thinking_level, "provider default")) saved.reasoning_effort else saved.thinking_level;
}

fn exposedMcpNames(a: std.mem.Allocator, gateway: *mcp.Gateway) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (gateway.configServers()) |server| {
        if (server.enabled and server.expose) try names.append(a, server.name);
    }
    return names.toOwnedSlice(a);
}

fn configureMcpPolicy(self: *Self, gateway: *agent.Controller) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (self.mcp_gateway.configServers()) |server| {
        if (!server.enabled or !server.expose) continue;
        const normalized = try a.dupe(u8, server.name);
        std.mem.replaceScalar(u8, normalized, '-', '_');
        try names.append(a, normalized);
    }
    const request = try gateway.program(
        try self.requestId(a),
        "ctx.mcp_servers={}; for _,name in ipairs(input.names) do ctx.mcp_servers[name]=true end; return true",
        try j.value(a, .{ .names = names.items }),
    );
    defer request.deinit();
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    if (outcome.status != .completed) return error.InvalidControllerPolicy;
}

fn configurePolicy(self: *Self, gateway: *agent.Controller) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const request = try gateway.program(try self.requestId(a), "ctx.application_model=input; return true", try j.value(a, .{ .model = self.model().model, .max_output_tokens = self.model().max_output_tokens, .reasoning_effort = self.model().reasoning_effort }));
    defer request.deinit();
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    if (outcome.status != .completed) return error.InvalidControllerPolicy;
}

fn catalogProvider(self: *const Self, model_id: []const u8) ?*const registry.Provider {
    if (self.settings.strict_registry) return self.settings.registry_provider;
    const catalog = self.settings.registry orelse return self.settings.registry_provider;
    return providerMetadata(catalog, self.provider, model_id);
}

fn providerMetadata(catalog: *const registry.Registry, provider: *const Provider, model_id: []const u8) ?*const registry.Provider {
    if (provider.kind == .deepseek) return catalog.find(registry.selection.deepseek.id);
    return catalog.matchEndpoint(provider.base_url, model_id);
}

pub fn resolveSavedSessionRoute(a: std.mem.Allocator, settings: *Settings, previous: ?ModelSelection) !?*Provider {
    if (settings.route_override) return null;
    const saved = previous orelse return null;
    const auth = settings.auth_store orelse return null;
    const catalog = settings.registry orelse return null;
    const provider = (try saved.resolve(a, auth, catalog, settings.model_override)) orelse try unconfiguredProvider(a);
    settings.refresh_saved_auth = saved.source == .saved;
    settings.strict_registry = false;
    settings.registry_provider = null;
    settings.selected_metadata = null;
    const entry = if (std.mem.eql(u8, provider.api_key, "unconfigured"))
        selectedModelMetadata(catalog.providers(), saved)
    else if (providerMetadata(catalog, provider, provider.model)) |reference|
        reference.find(provider.model)
    else
        null;
    const limits = registry.selection.limits(entry, .{
        .context_window = if (settings.registry_context) null else settings.context_window,
        .max_output_tokens = if (settings.registry_output) null else settings.max_output_tokens,
    }, .{});
    settings.context_window = limits.context_window;
    settings.max_output_tokens = limits.max_output_tokens;
    return provider;
}

fn modelMetadata(self: *const Self, id: []const u8) ?*const registry.Model {
    if (self.settings.selected_metadata) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    const provider = self.catalogProvider(id) orelse return null;
    return provider.find(id);
}

pub fn thinkingProfile(self: *const Self) !?thinking.Profile {
    if (self.settings.thinking_levels) |list| return try thinking.fromList(list);
    const entry = self.modelMetadata(self.provider.model) orelse return null;
    return try entry.thinkingProfile();
}

pub fn effortLabel(self: *const Self) []const u8 {
    if (self.selected_effort) |level| return @tagName(level);
    return self.settings.reasoning_effort orelse "provider default";
}

fn resolveEffort(self: *Self, requested: ?[]const u8) !void {
    const profile = try self.thinkingProfile();
    self.selected_effort = null;
    self.settings.reasoning_effort = null;
    if (requested) |text| {
        if (profile) |known| {
            const level = try thinking.parse(text);
            self.settings.reasoning_effort = try known.wire(level);
            self.selected_effort = level;
        } else {
            if (text.len == 0) return error.InvalidThinkingLevel;
            self.settings.reasoning_effort = try self.a.dupe(u8, text);
        }
    } else if (profile) |known| {
        if (known.supports(.off) and (try known.wire(.off)) == null) self.selected_effort = .off;
    }
}

const TreeSettingsChange = enum { open, model, thinking };

fn commitSelection(self: *Self, change: TreeSettingsChange, old_model: []u8, old_settings: Settings, old_level: ?thinking.Level) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    errdefer {
        self.provider.model = old_model;
        self.settings = old_settings;
        self.selected_effort = old_level;
        self.configurePolicy(self.gateway) catch {
            self.selection_healthy = false;
        };
        if (self.selection_healthy) {
            const previous = self.configuration(a) catch null;
            if (previous) |config| {
                const input = j.value(a, .{ .command = "configure", .config = config, .preserve_interrupted = true }) catch null;
                if (input) |value| self.invoke(value) catch {
                    self.selection_healthy = false;
                } else self.selection_healthy = false;
            } else self.selection_healthy = false;
        }
        self.metadata() catch {
            self.selection_healthy = false;
        };
    }
    try self.metadata();
    try self.configurePolicy(self.gateway);
    try self.invoke(try j.value(a, .{
        .command = "configure",
        .config = try self.configuration(a),
        .selection = try self.modelSelection(a),
        .tree_settings = change,
        .preserve_interrupted = true,
    }));
}

pub fn setThinking(self: *Self, level: thinking.Level) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    if (self.active_request != null) return error.ControllerBusy;
    const profile = (try self.thinkingProfile()) orelse return error.UnknownThinkingCapabilities;
    const wire = try profile.wire(level);
    const old_settings = self.settings;
    const old_level = self.selected_effort;
    self.settings.reasoning_effort = wire;
    self.selected_effort = level;
    try self.commitSelection(.thinking, self.provider.model, old_settings, old_level);
}

pub fn cycleThinking(self: *Self) !void {
    const profile = (try self.thinkingProfile()) orelse return error.UnknownThinkingCapabilities;
    try self.setThinking(try profile.cycle(self.selected_effort));
}

fn applyModelLimits(self: *Self, entry: ?*const registry.Model) void {
    const limits = registry.selection.limits(entry, .{
        .context_window = if (self.settings.registry_context) null else self.settings.context_window,
        .max_output_tokens = if (self.settings.registry_output) null else self.settings.max_output_tokens,
    }, .{});
    self.settings.context_window = limits.context_window;
    self.settings.max_output_tokens = limits.max_output_tokens;
}

pub fn setProvider(self: *Self, next: *Provider, source: ModelSelection.Source, observed: ?registry.Model) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    if (!self.session_change_mutex.tryLock()) return error.ControllerBusy;
    defer self.session_change_mutex.unlock(self.io);
    if (self.active_request != null) return error.ControllerBusy;
    var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
    defer snapshot.deinit();
    const preference = try decodeSelection(snapshot.allocator(), j.get(snapshot.value, "model_selection"));
    const previous = self.provider;
    const old_settings = self.settings;
    const old_level = self.selected_effort;
    const old_unavailable_model = self.unavailable_model;
    self.settings.selected_metadata = if (observed) |entry| try registry.cloneModel(self.a, entry) else null;
    self.provider = next;
    self.unavailable_model = null;
    self.settings.refresh_saved_auth = source == .saved;
    self.settings.strict_registry = false;
    self.settings.registry_provider = null;
    const old_override = self.effort_override;
    self.effort_override = true;
    defer self.effort_override = old_override;
    var published = false;
    errdefer if (!published) {
        self.provider = previous;
        self.settings = old_settings;
        self.selected_effort = old_level;
        self.unavailable_model = old_unavailable_model;
    };
    self.applyModelLimits(self.modelMetadata(next.model));
    if (self.settings.context_window <= self.settings.reserve_tokens) return error.InvalidContextSettings;
    if (try self.thinkingProfile()) |profile| {
        if (old_level) |level| {
            self.selected_effort = try profile.clamp(level);
            self.settings.reasoning_effort = try profile.wire(self.selected_effort.?);
        } else try self.resolveEffort(null);
    } else try self.resolveEffort(null);
    const candidate = try self.openGateway();
    self.closeTasks();
    var preparing_resident = true;
    errdefer if (preparing_resident) {
        candidate.close();
        self.provider = previous;
        self.settings = old_settings;
        self.selected_effort = old_level;
        self.unavailable_model = old_unavailable_model;
        self.startTasks() catch {
            self.selection_healthy = false;
        };
    };
    var resident = try self.gateway.prepareResidentJournal(self.worker.?);
    defer if (resident) |*journal| journal.deinit();
    if (resident) |*journal| {
        const worker = try self.openWorker(candidate, self.session.path, .{ .previous = preference, .reason = .provider_selection, .prepared = journal });
        preparing_resident = false;
        self.gateway.close();
        self.clearDelivery();
        self.gateway = candidate;
        self.worker = worker;
    } else {
        preparing_resident = false;
        self.gateway.close();
        self.gateway = candidate;
        self.worker = null;
        self.clearDelivery();
        self.worker = self.openWorker(candidate, self.session.path, .{ .previous = preference, .reason = .provider_selection }) catch |err| {
            self.provider = previous;
            self.settings = old_settings;
            self.selected_effort = old_level;
            self.unavailable_model = old_unavailable_model;
            const restored = self.openGateway() catch {
                self.selection_healthy = false;
                return err;
            };
            candidate.close();
            self.gateway = restored;
            self.worker = self.openWorker(restored, self.session.path, .{ .previous = preference, .reason = .provider_rollback }) catch {
                self.selection_healthy = false;
                return err;
            };
            self.startTasks() catch {
                self.selection_healthy = false;
            };
            return err;
        };
    }
    published = true;
    self.selection_healthy = true;
    self.metadata() catch |err| {
        self.selection_healthy = false;
        return err;
    };
    try self.startTasks();
    try self.restoreRegistrations();
    try self.refresh();
    try self.refreshRecovery();
}

fn clearDelivery(self: *Self) void {
    self.completion_mutex.lockUncancelable(self.io);
    defer self.completion_mutex.unlock(self.io);
    var delivered = self.delivered.keyIterator();
    while (delivered.next()) |id| self.gpa.free(id.*);
    self.delivered.clearRetainingCapacity();
    self.delivery_failure = null;
}

pub fn setModel(self: *Self, name: []const u8, observed: ?registry.Model) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    if (self.active_request != null) return error.ControllerBusy;
    if (name.len == 0) return error.InvalidModel;
    for (name) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidModel;
    const old_model = self.provider.model;
    const old_settings = self.settings;
    const old_level = self.selected_effort;
    self.provider.model = try self.a.dupe(u8, name);
    errdefer {
        self.provider.model = old_model;
        self.settings = old_settings;
        self.selected_effort = old_level;
    }
    self.settings.selected_metadata = if (observed) |entry| try registry.cloneModel(self.a, entry) else null;
    const entry = self.modelMetadata(name);
    if (self.settings.strict_registry) if (entry) |model_entry| {
        if (!(observed != null and model_entry.transports.len == 0) and !model_entry.supports(if (self.provider.protocol == .codex) "openai-codex-responses" else "openai-responses")) return error.UnsupportedRegistryApi;
    };
    if (self.settings.registry != null or entry != null) {
        self.applyModelLimits(entry);
        if (self.settings.context_window <= self.settings.reserve_tokens) return error.InvalidContextSettings;
    }
    const profile = try self.thinkingProfile();
    if (profile != null and old_level != null) {
        const level = try profile.?.clamp(old_level.?);
        self.selected_effort = level;
        self.settings.reasoning_effort = try profile.?.wire(level);
    } else try self.resolveEffort(null);
    try self.commitSelection(.model, old_model, old_settings, old_level);
}

fn setVisibleInvocation(self: *Self, id: ?[]const u8) !void {
    const next = if (id) |value| try self.gpa.dupe(u8, value) else null;
    if (self.visible_invocation) |previous| self.gpa.free(previous);
    self.visible_invocation = next;
}

fn preview(raw: ?*anyopaque, request_id: []const u8, update: transport.Preview.Update) !void {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    if (self.summarizing.load(.acquire) and update != .retrying) return;
    self.steering_mutex.lockUncancelable(self.io);
    const current = self.visible_invocation;
    const valid = current != null and std.mem.eql(u8, current.?, request_id);
    self.steering_mutex.unlock(self.io);
    if (!valid) return;
    switch (update) {
        .started => try self.emit(.{ .kind = .assistant_start }),
        .retrying => |retry| {
            const text = try std.fmt.allocPrint(self.gpa, "{s} {d}/{d} · next attempt in {d} ms", .{ if (retry.resuming) @as([]const u8, "Resume") else "Retry", retry.attempt - 1, retry.max_attempts - 1, retry.delay_ms });
            defer self.gpa.free(text);
            try self.emit(.{
                .kind = .provider_retry,
                .text = text,
                .resuming = retry.resuming,
                .retry = .{ .attempt = retry.attempt - 1, .max_attempts = retry.max_attempts - 1, .delay_ms = retry.delay_ms },
            });
        },
        .delta => |delta| try self.emit(.{ .kind = .text_delta, .text = delta }),
        .reasoning_delta => |delta| try self.emit(.{ .kind = .reasoning_delta, .text = delta }),
        .tool_start => |call| try self.emit(.{ .kind = .tool_arguments_start, .name = call.name, .call_id = call.call_id }),
        .tool_delta => |arguments| try self.emit(.{ .kind = .tool_arguments_delta, .text = arguments.delta, .call_id = arguments.call_id }),
        .tool_end => |complete| try self.emit(.{ .kind = .tool_arguments_end, .text = complete.arguments, .call_id = complete.call_id }),
    }
}

fn requestId(self: *Self, a: std.mem.Allocator) ![]const u8 {
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    return a.dupe(u8, &std.fmt.bytesToHex(nonce, .lower));
}

fn model(self: *Self) agent.Model {
    var config = self.provider.modelConfig(self.system_prompt);
    config.max_output_tokens = self.settings.max_output_tokens;
    config.reasoning_effort = self.settings.reasoning_effort;
    return config;
}

fn canRefreshSaved(raw: ?*anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    return self.settings.refresh_saved_auth and self.settings.auth_path != null and self.provider.protocol == .codex;
}

fn prepareProvider(raw: ?*anyopaque, io: std.Io, force: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    if (!self.configured()) return error.CredentialRefreshUnavailable;
    if (!canRefreshSaved(raw)) return;
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var store: Auth.Store = .{
        .a = a,
        .io = io,
        .path = self.settings.auth_path.?,
        .legacy_path = self.settings.auth_legacy_path,
        .size_warnings = self.authSizeSink(),
    };
    try store.reload();
    var saved = store.find(.openai) orelse {
        if (force) return error.LoginRequired;
        return;
    };
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, saved.base_url, "/"), std.mem.trimEnd(u8, self.provider.base_url, "/")) or !std.mem.eql(u8, saved.account_id orelse "", self.provider.account_id orelse "")) {
        if (force) return error.AccountMismatch;
        return;
    }
    // Another process may already have renewed this same account. Adopt that
    // saved key rather than spending its old one-time refresh token again.
    const already_rotated = !std.mem.eql(u8, saved.token, self.provider.api_key);
    if (force and !already_rotated) saved.expires = 0;
    const renewed = try Auth.refresh(a, io, saved, self.authSizeSink());
    const changed = !std.mem.eql(u8, renewed.token, saved.token) or renewed.expires != saved.expires;
    if (!changed and !already_rotated) return;
    const key = try self.provider.allocator.dupe(u8, renewed.token);
    errdefer self.provider.allocator.free(key);
    if (changed) try store.remember(renewed);
    self.credential_mutex.lockUncancelable(io);
    defer self.credential_mutex.unlock(io);
    std.crypto.secureZero(u8, self.provider.api_key);
    self.provider.allocator.free(self.provider.api_key);
    self.provider.api_key = key;
    _ = self.auth_revision.fetchAdd(1, .release);
}

fn openGateway(self: *Self) !*agent.Controller {
    var scope = kit.tracing.begin("cpi.controller.gateway");
    defer _ = scope.end();
    var payload_hooks: std.ArrayList(transport.PayloadHook) = .empty;
    defer payload_hooks.deinit(self.gpa);
    for (self.settings.generation_hooks) |hook| if (hook.before_provider_request) |callback| {
        try payload_hooks.append(self.gpa, .{ .context = hook.context, .transform = callback });
    };
    var effects = transport.Effects.initLive(self.settings.workspace, self.provider);
    effects.request_reasoning_summary = true;
    effects.codex_sse_fallback = true;
    const gateway = try agent.Controller.open(self.gpa, self.io, .{
        .services = &.{ self.files.service(), self.exec.service(), self.search_tools.service(), Mcp.service(self.mcp_gateway), ScriptOutput.service(&self.exec) },
        .providers = &.{.{
            .base_url = self.provider.base_url,
            .credential = self.provider.credentialLabel(),
            .transport = effects,
            .retry = self.settings.provider_retry,
            .retry_mode = .resume_only,
            .prepare = .{ .context = self, .call = prepareProvider, .can_refresh = canRefreshSaved },
            .deferred = self.scoped_routes.deferredFor(self.provider),
        }},
        .resolve_provider = self.scoped_routes.resolver(),
        .provider_payload_hooks = payload_hooks.items,
        .codex_sessions = self.settings.codex_sessions,
        .codex_transport_preference = self.settings.codex_transport_preference,
        .authorize = coding_tools.authorize,
        .host_session_access = true,
        .preserve_policy_nulls = true,
        .admission_budget = 100000,
        .sink = .{ .context = self, .emit = controllerEvent },
    });
    errdefer gateway.close();
    try coding_tools.configure(gateway, self.a, self.io, self.settings.workspace);
    try self.configureMcpPolicy(gateway);
    try self.configurePolicy(gateway);
    return gateway;
}

fn sessionId(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".zst")) {
        if (try agent.SessionJournal.zstdSessionId(a, io, path)) |saved| return saved;
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const absolute = try std.fs.path.resolve(a, &.{ cwd, path });
    const id = Inbox.inputHash(absolute);
    return a.dupe(u8, &id);
}

fn readJournal(a: std.mem.Allocator, io: std.Io, path: []const u8, query: agent.JournalQuery) !agent.JsonDocument {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const id = try sessionId(scratch.allocator(), io, path);
    return agent.readJournal(a, io, path, id, codec, query);
}

pub fn openSessionView(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !agent.SessionView {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const id = try sessionId(scratch.allocator(), io, path);
    return .open(gpa, io, path, id, codec);
}

pub fn decodeSelection(a: std.mem.Allocator, value: Value) !?ModelSelection {
    if (value == .null) return null;
    return try std.json.parseFromValueLeaky(ModelSelection, a, value, .{ .allocate = .alloc_always });
}

pub fn prepareResume(gpa: std.mem.Allocator, io: std.Io, path: []const u8, context_codec: @FieldType(agent.Config, "context_journal")) !?agent.PreparedJournal {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.size == 0) return null;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const id = try sessionId(scratch.allocator(), io, path);
    return try agent.PreparedJournal.open(gpa, io, path, id, context_codec);
}

fn sessionCodec(self: *const Self) @FieldType(agent.Config, "context_journal") {
    var context_codec = codec;
    if (self.scoped_routes.environment == null or self.scoped_routes.auth_path == null) context_codec.legacy_model_route = null;
    return context_codec;
}

pub fn runPolicy(self: *const Self) RunPolicy {
    return @bitCast(self.run_policy.load(.monotonic));
}

fn prepareReadImage(raw: *anyopaque, ctx: services.Context, bytes: []const u8, mime: []const u8) !services.Files.InlineImage {
    const self: *Self = @ptrCast(@alignCast(raw));
    // A tool delivery retains its resolved limits until its effects are joined.
    self.completion_mutex.lockUncancelable(ctx.io);
    const limits = if (self.delivered.get(ctx.request_id)) |delivery| delivery.image_limits else ImageProcessing.Limits{};
    self.completion_mutex.unlock(ctx.io);
    const result = try ImageProcessing.process(ctx.allocator, ctx.io, bytes, mime, self.read_auto_resize_images.load(.monotonic), limits);
    return switch (result) {
        .image => |image| .{ .mime_type = image.mime_type, .base64 = image.data_base64, .note = image.note },
        .omitted => |note| .{ .mime_type = mime, .base64 = "", .note = note },
    };
}

pub fn setRunPolicy(self: *Self, value: RunPolicy) void {
    self.run_policy.store(@bitCast(value), .monotonic);
}

pub fn setCodexTransportPreference(self: *Self, value: CodexTransportPreference) void {
    if (self.settings.codex_transport_pinned) return;
    if (self.settings.codex_transport_preference) |preference| preference.store(value, .monotonic);
}

fn claimBoundary(raw: ?*anyopaque, a: std.mem.Allocator, extensions: *const agent.session_protocol.Extensions, conversation: []const u8, context: Value, mode: []const u8) !?agent.BoundaryInputClaim {
    const self: *const Self = @ptrCast(@alignCast(raw.?));
    return Inbox.claimBoundary(a, extensions, conversation, context, mode, self.runPolicy().queue);
}

fn readRunOptions(raw: ?*anyopaque, a: std.mem.Allocator) !Value {
    const self: *const Self = @ptrCast(@alignCast(raw.?));
    const policy = self.runPolicy();
    return j.value(a, .{ .auto_compact = policy.auto_compact, .block_images = policy.block_images });
}

fn openWorker(self: *Self, gateway: *agent.Controller, path: ?[]const u8, opening: Opening) !agent.WorkerId {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var scope = kit.tracing.begin("cpi.controller.worker");
    defer _ = scope.end();
    var session_scope = kit.tracing.begin("cpi.controller.worker.session");
    defer _ = session_scope.end();
    const actual = path orelse "memory:";
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    const ephemeral_id = std.fmt.bytesToHex(nonce, .lower);
    const memory_id = if (opening.reason == .session) ephemeral_id else self.ephemeral_session_id orelse ephemeral_id;
    const session_id = if (opening.prepared) |prepared| try prepared.sessionId() else if (path != null) try sessionId(a, self.io, actual) else &memory_id;
    const tools = blk: {
        var tools_scope = kit.tracing.begin("cpi.controller.worker.tools");
        defer _ = tools_scope.end();
        break :blk try coding_tools.definitions(a, self.settings.workspace, self.shell_environment.get("HOME") orelse "");
    };
    const catalog = try self.a.alloc(agent.CatalogCapability, tools.len);
    for (tools, catalog) |capability, *entry| entry.* = .{ .name = capability.source_name, .capability = capability };
    const reset_provider = opening.reason == .provider_selection;
    const restore_legacy_effort = opening.previous == null and !reset_provider and !self.effort_override;
    const launch_selection = opening.previous != null and !reset_provider;
    const selection = if (try self.modelSelection(a)) |current|
        if (launch_selection and current.sameChoice(opening.previous.?)) null else current
    else
        null;
    const worker_config = try self.configuration(a);
    const reopen_tip = blk: {
        if (opening.reason != .session) break :blk null;
        const prepared = opening.prepared orelse break :blk null;
        if (!j.flag(try prepared.contextDocument(a, "tree_reopen"))) break :blk null;
        break :blk try prepared.lastOwnedApplicationTip(a, TaskJournal.main_conversation);
    };
    const tree_settings: ?TreeSettingsChange = switch (opening.reason) {
        .session => .open,
        .provider_selection => .model,
        .provider_rollback => null,
    };
    const initialization = try j.encode(a, .{
        .command = "configure",
        .config = worker_config,
        .expected_selection = if (opening.previous) |saved| saved.id else "",
        .selection = selection,
        .tree_settings = tree_settings,
        .reopen_tip = reopen_tip,
        .restore_tool_selection = opening.reason == .session,
        .launch_selection = launch_selection,
        .preserve_thinking = restore_legacy_effort,
        .preserve_interrupted = true,
    });
    var initialization_diagnostic: ?agent.JsonDocument = null;
    defer if (initialization_diagnostic) |*diagnostic| diagnostic.deinit();
    const worker = blk: {
        var start_scope = kit.tracing.begin("cpi.controller.worker.start");
        defer _ = start_scope.end();
        break :blk gateway.launch(.{
            .application = .{
                .source = DeferredTools.application_source,
                .mutable = true,
                .environment_json = try j.encode(a, .{
                    .config = worker_config,
                    .tool_catalog = try coding_tools.providerTools(a, ToolLoadout.catalog),
                    .tool_policy = try self.toolPolicy(a),
                    .tool_prompt = prompts.tool_text,
                    .tool_resources = try self.toolResources(a, &self.skills),
                    .direct_tools = ToolLoadout.direct,
                    .mcp_servers = try exposedMcpNames(a, self.mcp_gateway),
                    .tool_controls = true,
                    .summary_system = prompts.summary_system,
                    .branch_summary = prompts.branch_summary,
                    .summary = prompts.summary,
                    .update_summary = prompts.update_summary,
                    .turn_prefix = prompts.turn_prefix,
                    .after_failed_run = self.settings.after_failed_run,
                    .after_run = self.settings.after_run.len != 0,
                    .before_compact = self.settings.before_compact.len != 0,
                    .before_tool = self.settings.before_tool.len != 0,
                    .after_tool = self.settings.after_tool.len != 0,
                    .normalize_tool_images = self.settings.image_processing,
                    .model_view_version = model_view_version,
                    .generation_hooks = generationHookOptions(self.settings.generation_hooks),
                    .provider_payload_hook = hasProviderPayloadHook(self.settings.generation_hooks),
                    .retry = .{ .limit = self.settings.fresh_retry_limit, .initial_ms = self.settings.provider_retry.initial_delay_ms, .max_ms = self.settings.provider_retry.max_delay_ms },
                }),
            },
            .context_journal = self.sessionCodec(),
            .application_bindings = .{
                .context = self,
                .claim_boundary_input = claimBoundary,
                .read_options = readRunOptions,
            },
            .session_id = session_id,
            .journal_path = actual,
            .persistence = if (path == null) .memory else .journal,
            .workspace = self.settings.workspace,
            .model = self.model(),
            .recovery = .{ .application_checkpoint = true, .model_progress = true },
            .endpoint_grants = coding_tools.grants,
        }, .{ .catalog = .{ .fixed = catalog }, .initialize = .{ .input_json = initialization }, .initialize_id = &ephemeral_id, .failure_diagnostic = &initialization_diagnostic, .prepared_journal = opening.prepared }) catch |err| {
            if (initialization_diagnostic) |diagnostic| {
                if (std.mem.indexOf(u8, j.text(j.get(diagnostic.value, "message")), "InvalidSessionState") != null) return error.InvalidSessionState;
                if (std.mem.indexOf(u8, j.text(j.get(diagnostic.value, "message")), "SessionSelectionChanged") != null) return error.SessionSelectionChanged;
            }
            return err;
        };
    };
    errdefer gateway.stop(worker) catch {};
    if (restore_legacy_effort) {
        var restored = try gateway.readContext(worker, self.gpa);
        defer restored.deinit();
        const config = j.get(j.get(restored.value, "session"), "config");
        if (j.equal(j.get(config, "model"), self.modelName())) {
            const label = j.get(config, "thinking_level");
            const wire = j.get(config, "reasoning_effort");
            if (label == .string and !std.mem.eql(u8, label.string, "provider default")) {
                try self.resolveEffort(label.string);
            } else if (wire == .string) try self.resolveEffort(wire.string) else try self.resolveEffort(null);
            try self.configurePolicy(gateway);
        }
    }
    self.ephemeral_session_id = if (path == null) memory_id else null;
    return worker;
}

fn controllerEvent(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    self.handleControllerEvent(event) catch |err| {
        if (event == .size_warning) return err;
        self.completion_mutex.lockUncancelable(self.io);
        defer self.completion_mutex.unlock(self.io);
        if (self.delivery_failure == null) self.delivery_failure = err;
        self.notification_ready.set(self.io);
        return err;
    };
}

pub const StartupSizeWarnings = struct {
    allocator: std.mem.Allocator,
    operation: []const u8,
    values: std.ArrayList(services.SizeWarning) = .empty,

    pub fn sink(self: *StartupSizeWarnings) Auth.SizeSink {
        return .{ .context = self, .notify = collect };
    }

    pub fn log(self: *const StartupSizeWarnings) void {
        for (self.values.items) |warning| services.logSizeWarning(warning);
    }

    fn collect(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
        const self: *StartupSizeWarnings = @ptrCast(@alignCast(raw.?));
        const warning: services.SizeWarning = .{ .operation = self.operation, .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = "", .principal = 0 };
        self.values.append(self.allocator, warning) catch services.logSizeWarning(warning);
    }
};

fn mcpSizeWarning(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    self.warnSize("MCP", measurement, actual, threshold);
}

pub fn warnSize(self: *Self, operation: []const u8, measurement: []const u8, actual: u64, threshold: u64) void {
    if (actual <= threshold) return;
    const warning: services.SizeWarning = .{ .operation = operation, .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = "", .principal = 0 };
    self.emitSizeWarning(warning) catch services.logSizeWarning(warning);
}

pub fn authSizeSink(self: *Self) Auth.SizeSink {
    return .{ .context = self, .notify = warnAuthSize };
}

fn warnAuthSize(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    const self: *Self = @ptrCast(@alignCast(raw.?));
    self.warnSize("authorization", measurement, actual, threshold);
}

fn emitSizeWarning(self: *Self, warning: services.SizeWarning) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.fmt.allocPrint(a, "Warning: {s} {s} is {d}, above the expected {d}.", .{ warning.operation, warning.measurement, warning.actual, warning.threshold });
    try self.emit(.{ .kind = .size_warning, .text = text, .data = try j.value(a, warning) });
}

fn handleControllerEvent(self: *Self, event: agent.ControllerEvent) !void {
    switch (event) {
        .preview => |update| {
            if (self.worker == null or update.worker == null or !std.meta.eql(self.worker.?, update.worker.?)) return;
            try preview(self, update.request_id, update.update);
        },
        .notice => |notice| {
            if (self.worker == null or !std.meta.eql(self.worker.?, notice.worker)) return;
            try observe(self, notice.value);
            if (notice.value.kind == .command_finished) {
                self.completion_mutex.lockUncancelable(self.io);
                defer self.completion_mutex.unlock(self.io);
                if (self.delivered.getPtr(notice.value.request_id)) |delivered| delivered.finished = true;
                self.notification_ready.set(self.io);
            }
        },
        .audit => {},
        .size_warning => |warning| {
            if (warning.principal != 0) if (self.worker) |worker| if (worker.index != warning.principal) return;
            try self.emitSizeWarning(warning);
        },
    }
}

fn deliver(self: *Self, delivery: agent.Delivery, visible_id: ?*[]u8) !*agent.Request {
    var nonce: [16]u8 = undefined;
    self.io.random(&nonce);
    return self.deliverWithId(&std.fmt.bytesToHex(nonce, .lower), delivery, visible_id, .{});
}

const DeliveryState = struct {
    finished: bool = false,
    phase: ?ForegroundPhase = null,
    image_limits: ImageProcessing.Limits = .{},
};

fn deliverWithId(self: *Self, command: []const u8, delivery: agent.Delivery, visible_id: ?*[]u8, state: DeliveryState) !*agent.Request {
    const id = try self.gpa.dupe(u8, command);
    self.completion_mutex.lockUncancelable(self.io);
    self.delivered.put(self.gpa, id, state) catch |err| {
        self.completion_mutex.unlock(self.io);
        self.gpa.free(id);
        return err;
    };
    self.completion_mutex.unlock(self.io);
    errdefer self.forgetDelivery(id);
    const visible = if (visible_id != null) try self.gpa.dupe(u8, id) else null;
    errdefer if (visible) |copy| self.gpa.free(copy);
    const request = try self.gateway.deliver(self.worker.?, id, delivery);
    if (visible_id) |out| out.* = visible.?;
    return request;
}

fn forgetDelivery(self: *Self, id: []const u8) void {
    self.completion_mutex.lockUncancelable(self.io);
    const entry = self.delivered.fetchRemove(id);
    self.completion_mutex.unlock(self.io);
    if (entry) |owned| self.gpa.free(owned.key);
}

fn awaitDelivery(self: *Self, id: []const u8, respect_stop: bool) !void {
    defer self.forgetDelivery(id);
    while (true) {
        try self.io.checkCancel();
        const health = self.gateway.checkNotifications();
        self.completion_mutex.lockUncancelable(self.io);
        const failure = self.delivery_failure;
        const delivered = if (self.delivered.get(id)) |delivery| delivery.finished else false;
        if (failure == null and !delivered) self.notification_ready.reset();
        self.completion_mutex.unlock(self.io);
        if (failure) |err| return err;
        try health;
        if (respect_stop and self.stop.load(.acquire)) return error.Canceled;
        if (delivered) return;
        self.notification_ready.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
    }
}

fn hasContextUsage(entry: Value) bool {
    const state = j.get(entry, "status");
    const stop = j.get(entry, "stop_reason");
    if (j.equal(state, "failed") or j.equal(state, "aborted") or
        j.equal(stop, "error") or j.equal(stop, "aborted")) return false;
    const usage = j.get(entry, "usage");
    return j.number(j.get(usage, "total_tokens")) != 0 or
        j.number(j.get(usage, "input_tokens")) != 0 or
        j.number(j.get(usage, "output_tokens")) != 0;
}

fn compactionTokensBefore(entry: Value) ?u64 {
    const tokens = j.get(j.get(entry, "metadata"), "tokensBefore");
    return if (tokens == .integer) j.number(tokens) else null;
}

fn observe(raw: ?*anyopaque, notice: agent.Notice) !void {
    if (notice.kind != .progress) return;
    const self: *Self = @ptrCast(@alignCast(raw.?));
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var payload = try j.parse(a, notice.json);
    const scope = j.get(payload, "conversation");
    const conversation = if (scope == .string) scope.string else TaskJournal.main_conversation;
    if (!std.mem.eql(u8, conversation, self.settings.batch_conversation orelse TaskJournal.main_conversation)) return;
    if (scope == .string and !j.equal(j.get(payload, "kind"), "assistant") and !j.equal(j.get(payload, "kind"), "provider_retry")) return;
    if (j.equal(j.get(payload, "kind"), "continued_inputs")) {
        try self.observeHandoff(j.get(payload, "handoff"));
        return self.observeInputs(a, payload);
    }
    const kind = std.meta.stringToEnum(EventKind, j.text(j.get(payload, "kind"))) orelse return self.observeInputs(a, payload);
    var history_record: ?agent.HistoryRecord = null;
    var call_arguments: Value = .null;
    var call_images: []const ToolImage = &.{};
    var reply: AssistantContent = .{};
    defer if (history_record) |*record| record.deinit();
    if (j.get(payload, "slim") == .bool) {
        history_record = try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .conversation = conversation, .id = j.text(j.get(payload, "id")) });
        const entry = if (history_record) |record| record.value else return error.InvalidSession;
        if (kind == .tool_end) {
            try j.put(a, &payload, "data", j.get(entry, "result"));
            call_arguments = j.get(entry, "arguments");
            call_images = try toolImages(a, entry);
        }
        if (kind == .user) try j.put(a, &payload, "text", j.get(entry, "text"));
        if (kind == .compacted) try j.put(a, &payload, "text", j.get(entry, "summary"));
        if (kind == .assistant) reply = try AssistantContent.fromJournal(a, entry);
        if (kind == .tool_start) {
            const effective = j.get(payload, "effective_arguments");
            if (effective != .null) {
                try j.put(a, &payload, "data", effective);
            } else for (j.items(j.get(entry, "output"))) |call| {
                if (j.equal(j.get(call, "call_id"), j.text(j.get(payload, "call_id")))) {
                    try j.put(a, &payload, "data", j.parse(a, j.text(j.get(call, "arguments"))) catch .null);
                    break;
                }
            }
        }
    } else if (kind == .assistant) reply = try AssistantContent.fromLegacy(a, j.text(j.get(payload, "text")), j.text(j.get(payload, "thinking")));
    const retry: ?RetryProgress = if (kind == .provider_retry and j.get(j.get(payload, "data"), "attempt") == .integer) progress: {
        const details = j.get(payload, "data");
        const limit = j.get(details, "max_attempts");
        break :progress .{
            .attempt = j.number(j.get(details, "attempt")),
            .max_attempts = if (limit == .integer) j.number(limit) else null,
            .delay_ms = j.number(j.get(details, "delay_ms")),
        };
    } else null;
    if (scope == .string) return self.emit(.{ .kind = kind, .text = j.text(j.get(payload, "text")), .reply = reply, .retry = retry });
    switch (kind) {
        .compacting => self.summarizing.store(true, .release),
        .compacted, .compaction_declined, .compaction_failed => self.summarizing.store(false, .release),
        else => {},
    }
    if (j.get(payload, "tokens") == .integer) self.context_tokens.store(j.number(j.get(payload, "tokens")), .release);
    const data = if (kind == .tool_end) try toolResult(a, j.get(payload, "data")) else j.get(payload, "data");
    const text = if (kind == .tool_end)
        try toolDisplayText(a, data, if (history_record) |record| record.value else .null)
    else
        j.text(j.get(payload, "text"));
    const tool_delivery: []const u8 = id: {
        if (kind != .tool_start or !j.equal(j.get(payload, "name"), "bash")) break :id "";
        self.completion_mutex.lockUncancelable(self.io);
        defer self.completion_mutex.unlock(self.io);
        const delivery = self.delivered.get(notice.request_id) orelse break :id "";
        break :id if (delivery.phase == .tool) notice.request_id else "";
    };
    if (kind == .user) {
        const original = if (history_record) |record| j.get(record.value, "original") else .null;
        self.rememberPromptTitle(a, if (original == .string) original.string else text, true);
    }
    try self.emit(.{
        .kind = kind,
        .text = text,
        .name = j.text(j.get(payload, "name")),
        .call_id = j.text(j.get(payload, "call_id")),
        .entry_id = j.text(j.get(payload, "id")),
        .tool_delivery = tool_delivery,
        .data = data,
        .arguments = call_arguments,
        .images = call_images,
        .reply = reply,
        .tokens = j.number(j.get(payload, "tokens")),
        .retry = retry,
        .compaction_tokens_before = if (kind == .compacted and history_record != null) compactionTokensBefore(history_record.?.value) else null,
        .has_context_usage = kind == .assistant and history_record != null and hasContextUsage(history_record.?.value),
    });
    if (kind == .tool_end) try self.observeHandoff(j.get(payload, "handoff"));
    try self.observeInputs(a, payload);
}

fn observeHandoff(self: *Self, handoff: Value) !void {
    if (handoff != .string) return;
    try self.emit(.{ .kind = .notice, .text = "Tool started a new context." });
    if (handoff.string.len != 0) try self.emit(.{ .kind = .user, .text = handoff.string });
}

fn observeInputs(self: *Self, a: std.mem.Allocator, payload: Value) !void {
    const failed = j.text(j.get(payload, "failed_run"));
    if (failed.len != 0) try self.emit(.{ .kind = .notice, .text = try std.fmt.allocPrint(a, "Turn ended ({s}). Starting queued input.", .{failed}) });
    for (j.items(j.get(payload, "inputs"))) |text| try self.emit(.{ .kind = .user, .text = j.text(text) });
}

fn replaceSessionView(self: *Self, value: Value) !void {
    var next_arena = std.heap.ArenaAllocator.init(self.gpa);
    errdefer next_arena.deinit();
    const next_session = try Session.view(next_arena.allocator(), value, self.session.path);
    self.view_arena.deinit();
    self.view_arena = next_arena;
    self.session = next_session;
}

fn refresh(self: *Self) !void {
    var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
    defer snapshot.deinit();
    try self.refreshContext(snapshot.value);
}

fn refreshContext(self: *Self, value: Value) !void {
    try self.replaceSessionView(value);
    const tokens = j.number(j.get(j.get(value, "session"), "context_tokens"));
    self.context_tokens.store(tokens, .release);
    try self.scanUsage(tokens);
}

fn refreshRecovery(self: *Self) !void {
    var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
    defer snapshot.deinit();
    try self.refreshRecoveryContext(snapshot.allocator(), snapshot.value);
}

fn refreshRecoveryContext(self: *Self, a: std.mem.Allocator, value: Value) !void {
    const scope = kit.tracing.beginEvent("cpi.controller.recovery_status");
    defer kit.tracing.endEvent(scope);
    var available = j.get(value, "__interrupted_application") == .object or try savedForegroundOwner(a, value, .inbox) != null;
    if (self.tasks) |tasks| {
        var graph = try tasks.snapshot(self.gpa);
        defer graph.deinit();
        const state = TaskJournal.taskValues(j.get(graph.value, "value"));
        if (state == .object) for (state.object.values()) |entry| {
            if (isLiveForeground(entry)) available = true;
        };
    }
    var pending = try self.pendingDatagrams(self.gpa);
    defer pending.deinit();
    const inbox = j.get(pending.value, "value");
    if (inbox == .object) for (inbox.object.values()) |datagram| {
        if (legacyCompaction(datagram) or j.equal(j.get(datagram, "kind"), "reset") or
            j.equal(j.get(datagram, "kind"), "continue_turn") or Inbox.isSteering(datagram)) available = true;
    };
    self.recovery_available.store(available, .release);
}

fn isLiveForeground(entry: Value) bool {
    const scope = j.get(entry, "conversation");
    return (scope == .null or j.equal(scope, TaskJournal.main_conversation)) and
        j.equal(j.get(entry, "kind"), foreground_kind) and j.get(entry, "owner") == .null and j.get(j.get(entry, "state"), "terminal") == .null;
}

const ForegroundOwnerScope = enum { inbox, root };

fn savedForegroundOwner(a: std.mem.Allocator, context: Value, scope: ForegroundOwnerScope) !?[]const u8 {
    const active_run = j.get(j.get(context, "session"), "run");
    const after_run = j.get(context, "after_run");
    for ([_]Value{ active_run, after_run }) |active| {
        if (scope == .root or j.flag(j.get(active, "inbox_owner"))) {
            const owner = j.text(j.get(active, "owner"));
            if (owner.len != 0) return owner;
        }
    }
    const interrupted = j.get(j.get(context, "__interrupted_application"), "input_json");
    if (interrupted != .string) return null;
    const input = try j.parse(a, interrupted.string);
    const owner = j.text(j.get(input, "foreground_task"));
    return if (owner.len != 0 and (scope == .root or j.flag(j.get(input, "inbox_owner")))) owner else null;
}

fn recoverForeground(self: *Self) !bool {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var graph = try tasks.snapshot(self.gpa);
    defer graph.deinit();
    var context = try self.gateway.readContext(self.worker.?, self.gpa);
    defer context.deinit();
    const autonomous = try savedForegroundOwner(context.allocator(), context.value, .inbox);
    const state = TaskJournal.taskValues(j.get(graph.value, "value"));
    var recovered = false;
    if (state == .object) for (state.object.keys(), state.object.values()) |key, entry| {
        const owned = autonomous != null and std.mem.eql(u8, autonomous.?, key) and j.equal(j.get(entry, "kind"), write_task) and
            j.get(j.get(entry, "state"), "terminal") == .null;
        if (!isLiveForeground(entry) and !owned) continue;
        if (key.len != 64) return error.InvalidForegroundTask;
        self.stop.store(false, .release);
        self.foregroundWait(tasks, graph.allocator(), key[0..64].*) catch |err| {
            if (err != error.Canceled or self.stop.load(.acquire)) return err;
        };
        recovered = true;
    };
    return recovered;
}

pub fn resumeInterrupted(self: *Self) !void {
    if (!self.recovery_available.swap(false, .acq_rel)) return;
    if (!try self.recoverForeground()) {
        var context = try self.gateway.readContext(self.worker.?, self.gpa);
        defer context.deinit();
        if (j.get(context.value, "__interrupted_application") == .object) try self.scheduleForeground(.recover, null);
    }
    var pending = try self.pendingDatagrams(self.gpa);
    defer pending.deinit();
    const value = j.get(pending.value, "value");
    if (value == .object) for (value.object.keys(), value.object.values()) |id, datagram| {
        const kind = j.get(datagram, "kind");
        if (legacyCompaction(datagram)) try self.scheduleForeground(.compact, id);
        if (j.equal(kind, "reset")) try self.resetQueued(id);
        if (j.equal(kind, "continue_turn")) try self.scheduleForeground(.continue_turn, id);
    };
    try self.promoteSteering();
}

/// Pi's footer scans the session's append-only entries for cumulative provider
/// usage and takes the cache-hit rate from the newest assistant response.
fn scanUsage(self: *Self, context_tokens: u64) !void {
    if (self.worker == null) return;
    self.setUsageStats(try self.collectUsage(null), context_tokens);
}

fn collectUsage(self: *Self, messages: ?*SessionCounts) !Usage.Stats {
    const scope = kit.tracing.beginEvent("cpi.controller.usage");
    defer kit.tracing.endEvent(scope);
    const worker = self.worker orelse return error.InvalidSession;
    const usage_fields = [_][]const u8{ "kind", "purpose", "usage", "usage_format", "summary_usage" };
    const stats_fields = usage_fields ++ [_][]const u8{ "event_kind", "calls" };
    var stats: Usage.Stats = .{};
    var query: agent.HistoryProjection = .{ .stream = .application, .fields = if (messages == null) &usage_fields else &stats_fields };
    var latest = true;
    while (true) {
        var page = try self.gateway.projectHistory(worker, self.gpa, query);
        defer page.document.deinit();
        for (page.document.value.array.items) |entry| {
            Usage.addEntry(&stats, entry, &latest);
            if (messages) |counts| counts.add(entry);
        }
        query.before = page.before orelse break;
    }
    if (self.tasks) |tasks| {
        var snapshot = try tasks.snapshot(self.gpa);
        defer snapshot.deinit();
        const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
        if (records == .object) for (records.object.values()) |record| {
            if (!j.equal(j.get(record, "conversation"), TaskJournal.main_conversation) or
                !isConversationCompaction(record)) continue;
            const state = j.get(record, "state");
            const outcome = j.get(state, "terminal");
            const completing = j.get(state, "completing");
            const saved = if (outcome != .null) j.get(outcome, "value") else if (completing != .null)
                j.get(completing, "value")
            else if (j.get(state, "running") != .null)
                j.get(j.get(j.get(state, "running"), "work"), "checkpoint")
            else if (j.get(state, "sleeping") != .null)
                j.get(j.get(state, "sleeping"), "checkpoint")
            else
                j.get(j.get(state, "pending"), "checkpoint");
            stats.addSpend(try savedCompactionUsage(snapshot.allocator(), saved));
        };
    }
    return stats;
}

pub fn toolResult(a: std.mem.Allocator, value: Value) !Value {
    if (j.get(value, "content") == .array) return value;
    const cancelled = j.equal(j.get(value, "code"), "cancelled");
    const text = if (cancelled)
        "Interrupted before a tool result was recorded. Inspect the current state before repeating the operation."
    else if (j.get(value, "message") == .string)
        j.text(j.get(value, "message"))
    else
        try j.encode(a, value);
    return j.value(a, .{ .content = .{.{ .type = "text", .text = text }}, .isError = cancelled or j.get(value, "code") == .string });
}

fn toolImages(a: std.mem.Allocator, entry: Value) ![]const ToolImage {
    const source = j.items(j.get(entry, "images"));
    const images = try a.alloc(ToolImage, source.len);
    for (source, images) |image, *projected| {
        const mime = j.text(j.get(image, "mime_type"));
        projected.* = .{
            .mime_type = if (mime.len == 0) "image/unknown" else try a.dupe(u8, mime),
            .dimensions = kit.media.image_dimensions.fromBase64(j.text(j.get(image, "data_base64")), mime),
        };
    }
    return images;
}

fn toolDisplayText(a: std.mem.Allocator, result: Value, entry: Value) ![]const u8 {
    const content = j.get(result, "content");
    if (!j.flag(j.get(entry, "normalized_images"))) return compaction.textContent(a, content);
    var parts: std.ArrayList([]const u8) = .empty;
    if (content == .string) try parts.append(a, content.string);
    for (j.items(content)) |block| {
        const text = j.get(block, "text");
        if (j.equal(j.get(block, "type"), "text") and text == .string) try parts.append(a, text.string);
    }
    for (j.items(j.get(entry, "images"))) |image| {
        const note = j.text(j.get(image, "note"));
        if (note.len != 0) try parts.append(a, note);
    }
    return std.mem.join(a, "\n", parts.items);
}

pub fn toolImageEntry(self: *Self, a: std.mem.Allocator, id: []const u8) !?agent.HistoryRecord {
    const worker = self.worker orelse return null;
    return self.gateway.readHistory(worker, a, .{ .stream = .application, .id = id, .selected_display = true });
}

pub fn run(self: *Self, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    try self.runPrepared(try self.prepare(arena.allocator(), text));
}

pub fn runPrepared(self: *Self, input: Prepared) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    self.rememberPromptTitle(a, input.original, false);
    if (input.submission) |id| return self.scheduleForeground(.turn, id);
    if (!self.foreground_mutex.tryLock()) {
        var queued = [1]Prepared{input};
        try self.enqueueInputs(a, &queued);
        return error.ControllerBusy;
    }
    defer self.foreground_mutex.unlock(self.io);
    const submission = try self.requestId(a);
    const admission = try Inbox.promptAdmission(a, TaskJournal.main_conversation, submission, try Inbox.promptBody(a, input.text, input.original, input.entry, input.user_content), .null);
    try self.submitForegroundTask(a, .turn, submission, &.{admission});
}

fn invoke(self: *Self, input: Value) !void {
    const progress = try self.invokeAttempt(input, null);
    if (progress != .completed) return error.UnexpectedForegroundWait;
}

fn invokeAttempt(self: *Self, input: Value, attempt: ?ForegroundAttempt) !ForegroundProgress {
    if (attempt) |owned| if (owned.scoped() or owned.inbox_owner) return self.invokeScopedAttempt(input, owned);
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    if (!self.selection_healthy) return error.ControllerPolicyRestoreFailed;
    errdefer if (attempt == null) self.cancel();
    if (attempt == null) self.stop.store(false, .release);
    defer {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        if (self.stop.load(.acquire) and attempt == null) {
            self.configureWorker("cancelled") catch {};
            if (self.tasks) |tasks| tasks.notify();
        }
        self.refresh() catch {};
        if (!self.stop.load(.acquire)) {
            _ = self.mcp_gateway.syncCatalogs();
        }
        self.summarizing.store(false, .release);
    }
    var payload = try j.copy(a, input);
    const token = if (attempt) |owned| owned.id else try self.requestId(a);
    try payload.object.put(a, "steering_invocation", j.string(token));
    if (attempt) |owned| {
        try payload.object.put(a, "foreground_task", j.string(owned.task));
        if (owned.phase) |phase| try payload.object.put(a, "foreground_phase", j.string(@tagName(phase)));
    }
    const command = j.text(j.get(input, "command"));
    var target = j.text(j.get(input, "submission"));
    const resumable = std.mem.eql(u8, command, "resume");
    var uses_requested_model = false;
    if (resumable) {
        var context = try self.gateway.readContext(self.worker.?, self.gpa);
        defer context.deinit();
        const session = j.get(context.value, "session");
        const run_checkpoint = j.get(session, "run");
        if (run_checkpoint == .object) {
            target = try a.dupe(u8, j.text(j.get(session, "last_submission")));
            uses_requested_model = j.get(run_checkpoint, "model_selection") == .object;
        }
    }
    var visible_id: []u8 = undefined;
    const binding: ?agent.ApplicationModel = blk: {
        if (attempt != null and attempt.?.hookPhase()) break :blk null;
        if (uses_requested_model) break :blk try self.bindScopedModel(a, TaskJournal.main_conversation, &payload);
        if (!(command.len == 0 or resumable or std.mem.eql(u8, command, "compact") or std.mem.eql(u8, command, "continue_turn"))) break :blk null;
        const selection = self.unavailable_model orelse if (self.configured()) try self.captureModelSelection(a, TaskJournal.main_conversation) else break :blk null;
        switch (selection.source) {
            .environment => if (self.scoped_routes.environment == null) break :blk null,
            .saved => if (self.scoped_routes.auth_path == null) break :blk null,
        }
        break :blk .{
            .model = .{
                .model = selection.model,
                .base_url = selection.base_url,
                .credential = try selection.credential(a),
                .reasoning_effort = selection.reasoning_effort,
                .max_output_tokens = self.settings.max_output_tokens,
            },
            .selection = try j.value(a, selection),
        };
    };
    const delivery: agent.Delivery = .{ .input_json = try j.encode(a, payload), .application_model = binding };
    const request = if (attempt) |owned| blk: {
        const limits = if (owned.phase != .tool)
            ImageProcessing.Limits{}
        else if (uses_requested_model and binding != null)
            try self.selectionImageLimits(a, binding.?.selection)
        else
            self.imageLimits();
        break :blk try self.deliverWithId(owned.id, delivery, &visible_id, .{ .phase = owned.phase, .image_limits = limits });
    } else try self.deliver(delivery, &visible_id);
    self.steering_mutex.lockUncancelable(self.io);
    const tracked = self.active_request == null;
    const steerable = tracked and (attempt == null or !attempt.?.hookPhase()) and (command.len == 0 or resumable or std.mem.eql(u8, command, "continue_turn"));
    if (tracked) {
        if (self.visible_invocation) |previous| self.gpa.free(previous);
        self.visible_invocation = visible_id;
        self.active_request = request;
        self.steering_token = token;
        self.steering_target = if (steerable) target else "";
    } else self.gpa.free(visible_id);
    self.steering_mutex.unlock(self.io);
    defer {
        if (tracked) {
            self.steering_mutex.lockUncancelable(self.io);
            self.active_request = null;
            self.steering_token = "";
            self.steering_target = "";
            self.setVisibleInvocation(null) catch unreachable;
            self.steering_mutex.unlock(self.io);
        }
        self.forgetDelivery(request.id);
        request.deinit();
    }
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    try self.awaitDelivery(request.id, true);
    const status = j.get(outcome.result, "status");
    const continuing = outcome.status == .completed and (j.equal(status, "waiting") or j.equal(status, "admission_waiting") or j.equal(status, "delegate"));
    if (steerable and !continuing) {
        self.steering_mutex.lockUncancelable(self.io);
        self.steering_target = "";
        self.steering_mutex.unlock(self.io);
        try self.promoteSteering();
    }
    if (self.stop.load(.acquire)) return error.Canceled;
    return self.checkForegroundOutcome(a, TaskJournal.main_conversation, @tagName(outcome.status), outcome.result, outcome.diagnostic);
}

fn invokeScopedAttempt(self: *Self, input: Value, attempt: ForegroundAttempt) !ForegroundProgress {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    if (!self.selection_healthy) return error.ControllerPolicyRestoreFailed;
    var payload = try j.copy(a, input);
    try payload.object.put(a, "steering_invocation", j.string(attempt.id));
    try payload.object.put(a, "foreground_task", j.string(attempt.task));
    if (attempt.phase) |phase| try payload.object.put(a, "foreground_phase", j.string(@tagName(phase)));
    if (attempt.inbox_owner) try payload.object.put(a, "inbox_owner", .{ .bool = true });
    const binding = if (attempt.hookPhase()) null else try self.bindScopedModel(a, attempt.conversation, &payload);
    const limits = if (attempt.phase == .tool and binding != null)
        try self.selectionImageLimits(a, binding.?.selection)
    else
        ImageProcessing.Limits{};
    const request = try self.deliverWithId(attempt.id, .{
        .input_json = try j.encode(a, payload),
        .conversation = attempt.conversation,
        .application_model = binding,
    }, null, .{ .phase = attempt.phase, .image_limits = limits });
    defer request.deinit();
    defer self.forgetDelivery(request.id);
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    try self.awaitDelivery(request.id, false);
    return self.checkForegroundOutcome(a, attempt.conversation, @tagName(outcome.status), outcome.result, outcome.diagnostic);
}

fn bindScopedModel(self: *Self, a: std.mem.Allocator, conversation: []const u8, payload: *Value) !?agent.ApplicationModel {
    var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, conversation);
    defer context.deinit();
    const stored = ModelSelection.effective(context.value);
    const supplied = j.get(payload.*, "selection");
    const requested = if (supplied != .null or !j.equal(j.get(payload.*, "command"), "resume"))
        supplied
    else
        j.get(j.get(j.get(context.value, "session"), "run"), "model_selection");
    const current = j.get(j.get(context.value, "session"), "config");
    var inherited = try self.inheritedSelectionContext(conversation, stored);
    defer if (inherited) |*saved| saved.deinit();
    const original = if (inherited) |saved| ModelSelection.effective(saved.value) else stored;
    const chosen = (try decodeSelection(a, if (requested == .null) original else requested)) orelse return null;
    const previous = if (current == .object) current else if (inherited) |saved| j.get(j.get(saved.value, "session"), "config") else .null;
    var config = try j.copy(a, if (previous == .object) previous else self.scoped_defaults);
    if (previous != .object or !j.equal(j.get(original, "id"), chosen.id)) {
        const limits = registry.selection.limits(self.scopedModelMetadata(chosen), self.scoped_limit_overrides, .{
            .context_window = j.number(j.get(config, "context_window")),
            .max_output_tokens = std.math.cast(u32, j.number(j.get(config, "max_output_tokens"))) orelse return error.InvalidContextSettings,
        });
        try config.object.put(a, "context_window", try j.value(a, limits.context_window));
        try config.object.put(a, "max_output_tokens", try j.value(a, limits.max_output_tokens));
        try config.object.put(a, "reserve_tokens", try j.value(a, @min(j.number(j.get(config, "reserve_tokens")), limits.context_window -| 1)));
    }
    try config.object.put(a, "model", j.string(chosen.model));
    try config.object.put(a, "reasoning_effort", try j.value(a, chosen.reasoning_effort));
    try config.object.put(a, "thinking_level", j.string(chosen.thinking_level));
    const profile = if (self.settings.thinking_levels) |list| try thinking.fromList(list) else if (self.scopedModelMetadata(chosen)) |entry| try entry.thinkingProfile() else null;
    try config.object.put(a, "thinking_levels", try j.value(a, try thinkingLevels(a, profile)));
    const selection = try j.value(a, chosen);
    try payload.object.put(a, "config", config);
    if (!j.equal(j.get(stored, "id"), chosen.id)) try payload.object.put(a, "selection", selection);
    return .{
        .model = .{
            .model = chosen.model,
            .base_url = chosen.base_url,
            .credential = try chosen.credential(a),
            .reasoning_effort = chosen.reasoning_effort,
            .max_output_tokens = std.math.cast(u32, j.number(j.get(config, "max_output_tokens"))) orelse return error.InvalidContextSettings,
        },
        .selection = selection,
    };
}

fn inheritedSelectionContext(self: *Self, conversation: []const u8, stored: Value) !?agent.JsonDocument {
    if (stored != .null or (self.scoped_routes.auth_path == null and self.scoped_routes.environment == null)) return null;
    return try self.inheritedSettings(conversation);
}

fn inheritedSettings(self: *Self, conversation: []const u8) !agent.JsonDocument {
    var graph = try self.gateway.readSessionExtension(self.worker.?, self.gpa, TaskJournal.namespace);
    defer graph.deinit();
    const graph_state = j.get(graph.value, "value");
    var child = conversation;
    while (!std.mem.eql(u8, child, TaskJournal.main_conversation)) {
        const record = TaskJournal.conversationValue(graph_state, child);
        const base = j.get(record, "base");
        const parent = if (base == .object) j.text(j.get(base, "context")) else blk: {
            const owner = j.get(record, "owner");
            if (owner != .string) break;
            const task = j.get(TaskJournal.taskValues(graph_state), owner.string);
            const scope = j.get(task, "conversation");
            break :blk if (scope == .string) scope.string else TaskJournal.main_conversation;
        };
        var saved = try self.gateway.readApplicationContextAt(self.worker.?, self.gpa, parent, if (base == .object)
            .{ .at = j.number(j.get(base, "at")) }
        else
            .{ .before_creation = child });
        if (ModelSelection.effective(saved.value) == .object) return saved;
        saved.deinit();
        child = parent;
    }
    return self.gateway.readContext(self.worker.?, self.gpa);
}

fn scopedModelMetadata(self: *const Self, selection: ModelSelection) ?*const registry.Model {
    return selectedModelMetadata(self.scoped_routes.providers, selection);
}

fn selectionImageLimits(self: *const Self, a: std.mem.Allocator, value: Value) !ImageProcessing.Limits {
    const selection = (try decodeSelection(a, value)) orelse return .{};
    return .forModel(self.scopedModelMetadata(selection));
}

fn selectedModelMetadata(providers: []const registry.Provider, selection: ModelSelection) ?*const registry.Model {
    if (selection.provider_ref) |id| {
        for (providers) |*provider| {
            if (std.mem.eql(u8, provider.id, id)) return provider.find(selection.model);
        }
        return null;
    }
    var found: ?*const registry.Model = null;
    for (providers) |*provider| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, provider.base_url, "/"), selection.base_url)) continue;
        if (provider.find(selection.model)) |model_entry| {
            if (found != null) return null;
            found = model_entry;
        }
    }
    return found;
}

fn checkForegroundOutcome(self: *Self, a: std.mem.Allocator, conversation: []const u8, disposition: []const u8, result: Value, diagnostic: Value) !ForegroundProgress {
    const main = std.mem.eql(u8, conversation, TaskJournal.main_conversation);
    if (std.mem.eql(u8, disposition, "cancelled")) return error.Canceled;
    if (!std.mem.eql(u8, disposition, "completed")) {
        self.configureConversation(conversation, "faulted") catch |err| std.log.warn("Could not settle interrupted turn: {s}", .{@errorName(err)});
        if (main) try self.emit(.{ .kind = .notice, .text = try j.encode(a, diagnostic), .data = diagnostic });
        return error.WorkerCommandFailed;
    }
    const status = j.text(j.get(result, "status"));
    if (std.mem.eql(u8, status, "waiting") or std.mem.eql(u8, status, "admission_waiting")) {
        const deadline = j.get(result, "deadline_ms");
        if (deadline != .integer or deadline.integer <= 0) return error.InvalidRetryDeadline;
        return if (std.mem.eql(u8, status, "admission_waiting")) .{ .retry_admission_at = @intCast(deadline.integer) } else .{ .retry_at = @intCast(deadline.integer) };
    }
    if (std.mem.eql(u8, status, "delegate")) {
        const phase = std.meta.stringToEnum(ForegroundPhase, j.text(j.get(result, "phase"))) orelse return error.InvalidForegroundTask;
        return .{ .delegate = phase };
    }
    if (std.mem.eql(u8, status, "nothing_to_compact")) return error.NothingToCompact;
    if (std.mem.eql(u8, status, "nothing_to_answer")) return .nothing_to_answer;
    if (std.mem.eql(u8, status, "conversation_busy")) return error.ControllerBusy;
    if (std.mem.eql(u8, status, "overflow")) return error.ContextOverflow;
    if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "after_run_pending")) {
        if (main) try self.emit(.{ .kind = .notice, .text = try j.encode(a, result), .data = result });
        return error.ApplicationFailed;
    }
    return .completed;
}

pub fn compact(self: *Self, instructions: []const u8) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const id = try self.enqueueCompact(a, instructions);
    try self.compactQueued(id);
}

pub fn enqueueCompact(self: *Self, a: std.mem.Allocator, instructions: []const u8) ![]const u8 {
    return self.enqueueConversationCompaction(a, TaskJournal.main_conversation, instructions);
}

pub fn enqueueConversationCompaction(self: *Self, a: std.mem.Allocator, scope: []const u8, focus: []const u8) ![]const u8 {
    return self.enqueueManagedCompaction(a, scope, focus, false);
}

pub fn enqueueTerminalCompaction(self: *Self, a: std.mem.Allocator, focus: []const u8) ![]const u8 {
    return self.enqueueManagedCompaction(a, TaskJournal.main_conversation, focus, true);
}

fn enqueueManagedCompaction(self: *Self, a: std.mem.Allocator, scope: []const u8, focus: []const u8, terminal: bool) ![]const u8 {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const id = try self.requestId(a);
    errdefer a.free(id);
    var body = try j.value(temp, .{ .focus = focus, .managed = true });
    if (terminal) try body.object.put(temp, "terminal", .{ .bool = true });
    var pending = j.object();
    try pending.object.put(temp, id, try j.value(temp, .{ .kind = Inbox.Kind.compact, .input = body }));
    try tasks.submitWithExtensions(.{ .id = id, .kind = manual_compaction_kind, .conversation = scope, .input = body }, &.{.{
        .namespace = try Inbox.scopeNamespace(temp, scope),
        .action = "enqueue",
        .input = .{ .contract = Inbox.contract.version, .value = pending },
    }});
    return id;
}

fn legacyCompaction(datagram: Value) bool {
    return j.equal(j.get(datagram, "kind"), "compact") and !j.flag(j.get(j.get(datagram, "input"), "managed"));
}

fn enqueueControl(self: *Self, a: std.mem.Allocator, kind: Inbox.Kind, input: Value) ![]const u8 {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const id = try self.requestId(a);
    errdefer a.free(id);
    var pending: Value = .{ .object = .empty };
    try pending.object.put(scratch, id, try j.value(scratch, .{ .kind = kind, .input = input }));
    try self.writeInbox("enqueue", pending);
    return id;
}

pub fn compactQueued(self: *Self, id: []const u8) !void {
    _ = try self.waitManualCompaction(id);
}

pub const ManualCompactionResult = enum { finished, nothing_to_compact, declined };

pub fn waitManualCompaction(self: *Self, id: []const u8) !ManualCompactionResult {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var outcome = try tasks.wait(a, id);
    defer outcome.deinit();
    const value = j.get(outcome.value, "value");
    const disposition = j.get(outcome.value, "status");
    if (j.equal(disposition, "aborted")) return error.Canceled;
    if (!j.equal(disposition, "completed")) return error.InvalidSummary;
    const placement = j.get(value, "placement");
    if (placement == .string) {
        var placed = try tasks.wait(a, placement.string);
        defer placed.deinit();
        const status = j.get(placed.value, "status");
        if (!j.equal(status, "completed")) return error.CompactionPlacementFailed;
    }
    const reason = j.get(value, "reason");
    if (j.equal(reason, "nothing_to_compact")) return .nothing_to_compact;
    if (j.equal(reason, "declined")) return .declined;
    return .finished;
}

pub fn cancelManualCompaction(self: *Self, id: []const u8) !void {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    try tasks.abort(id);
}

pub fn waitManualCompactions(self: *Self, conversation: []const u8) !void {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var snapshot = try tasks.snapshot(self.gpa);
    defer snapshot.deinit();
    const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
    if (records != .object) return;
    for (records.object.keys(), records.object.values()) |id, record| {
        if (!j.equal(j.get(record, "conversation"), conversation) or j.get(j.get(record, "state"), "terminal") != .null) continue;
        if (j.equal(j.get(record, "kind"), manual_compaction_kind)) try self.compactQueued(id);
        if (j.equal(j.get(record, "kind"), write_task) and
            std.mem.startsWith(u8, j.text(j.get(j.get(record, "input"), "submission")), "request/compaction/"))
        {
            var done = try tasks.wait(snapshot.allocator(), id);
            defer done.deinit();
        }
    }
}

pub fn abortManualCompactions(self: *Self) !bool {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var snapshot = try tasks.snapshot(self.gpa);
    defer snapshot.deinit();
    const records = TaskJournal.taskValues(j.get(snapshot.value, "value"));
    if (records != .object) return false;
    var stopped = false;
    for (records.object.keys(), records.object.values()) |id, record| {
        if (!j.equal(j.get(record, "kind"), manual_compaction_kind) or
            !j.equal(j.get(record, "conversation"), TaskJournal.main_conversation) or
            j.get(j.get(record, "state"), "terminal") != .null) continue;
        try tasks.abort(id);
        var outcome = try tasks.wait(snapshot.allocator(), id);
        defer outcome.deinit();
        stopped = stopped or j.equal(j.get(outcome.value, "status"), "aborted");
    }
    return stopped;
}

pub fn enqueueReset(self: *Self, a: std.mem.Allocator, note: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const id = try self.enqueueControl(a, .reset, try j.value(arena.allocator(), .{ .note = note }));
    self.recovery_available.store(true, .release);
    return id;
}

pub fn resetQueued(self: *Self, id: []const u8) !void {
    try self.scheduleForeground(.reset, id);
}

pub fn continueTurn(self: *Self) !void {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    try self.scheduleForegroundLocked(.continue_turn, try self.enqueueContinuationLocked(arena.allocator()));
}

pub fn enqueueContinuation(self: *Self, a: std.mem.Allocator) ![]const u8 {
    if (!self.foreground_mutex.tryLock()) return error.ControllerBusy;
    defer self.foreground_mutex.unlock(self.io);
    return self.enqueueContinuationLocked(a);
}

pub fn continueQueued(self: *Self, id: []const u8) !void {
    try self.scheduleForeground(.continue_turn, id);
}

fn enqueueContinuationLocked(self: *Self, a: std.mem.Allocator) ![]const u8 {
    const tasks = self.tasks orelse return error.TaskSchedulerClosed;
    var graph = try tasks.snapshot(self.gpa);
    defer graph.deinit();
    const state = TaskJournal.taskValues(j.get(graph.value, "value"));
    if (state == .object) for (state.object.values()) |entry| {
        if (isLiveForeground(entry)) return error.ControllerBusy;
    };
    var context = try self.gateway.readContext(self.worker.?, self.gpa);
    defer context.deinit();
    if (j.get(j.get(context.value, "session"), "run") == .object or j.get(context.value, "after_run") == .object) return error.ControllerBusy;
    var inbox = try self.pendingDatagrams(self.gpa);
    defer inbox.deinit();
    const datagrams = j.get(inbox.value, "value");
    if (datagrams == .object) for (datagrams.object.values()) |entry| {
        const kind = j.get(entry, "kind");
        if (j.equal(kind, "continue_turn") or j.equal(kind, "reset")) return error.ControllerBusy;
    };
    return self.enqueueControl(a, .continue_turn, j.object());
}

fn refreshPrompt(self: *Self) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const next = try self.buildPrompt(a, &self.skills);
    self.gpa.free(self.system_prompt);
    self.system_prompt = next;
}

fn buildPrompt(self: *Self, a: std.mem.Allocator, skills: *const Skills) ![]const u8 {
    const mcp_prompt = if (std.mem.indexOfScalar(ToolLoadout.Tool, self.active_tools, .execute_lua) != null) try self.mcp_gateway.promptSection(a) else "";
    return prompts.system(self.gpa, self.settings.workspace, self.active_tools, try skills.prompt(a, ToolLoadout.reader(self.active_tools)), mcp_prompt);
}

fn toolPolicy(self: *Self, a: std.mem.Allocator) !Value {
    const loadout = self.settings.tool_loadout;
    var allowed: std.ArrayList(ToolLoadout.Tool) = .empty;
    for (ToolLoadout.catalog) |tool| {
        if (loadout.permits(tool, self.active_tools)) try allowed.append(a, tool);
    }
    return j.value(a, .{
        .id = &self.tool_launch,
        .initial = self.active_tools,
        .allowed = allowed.items,
        .modifiers = loadout.launchModifiers(),
        .restore_at_launch = loadout.canRestoreAtLaunch(),
        .auto_script = loadout.allowsAutomaticScript() and (try exposedMcpNames(a, self.mcp_gateway)).len != 0,
    });
}

fn toolResources(self: *Self, a: std.mem.Allocator, skills: *const Skills) !Value {
    return j.value(a, .{
        .cwd = self.settings.workspace,
        .read_skills = try skills.prompt(a, .read),
        .bash_skills = try skills.prompt(a, .bash),
        .mcp = try self.mcp_gateway.promptSection(a),
    });
}

fn configureWorker(self: *Self, end_run: []const u8) !void {
    return self.configureConversation(TaskJournal.main_conversation, end_run);
}

const AbortedTools = struct {
    owner: []const u8,
    reason: TaskJournal.AbortReason,
    at_ms: i64,
    decisions: Value,
};

fn settleAbortedConversation(self: *Self, invocation: TaskScheduler.Invocation) !void {
    var settlement: AbortedTools = .{
        .owner = invocation.id,
        .reason = invocation.abort_reason orelse .requested,
        .at_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
        .decisions = j.object(),
    };
    if (self.settings.after_tool.len != 0) {
        const a = invocation.allocator;
        const worker = self.worker orelse return error.WorkerStopped;
        var plan = try self.gateway.queryApplication(worker, a, invocation.conversation, try j.value(a, .{
            .command = "plan_abort_tools",
            .owner = settlement.owner,
            .reason = settlement.reason,
            .at_ms = settlement.at_ms,
        }));
        defer plan.deinit();
        const limit = invocation.driver.settings.restart_limit;
        const cutoff = if (limit) |n| invocation.restarts >= n -| 1 else false;
        const response = j.text(j.get(plan.value, "response"));
        for (j.items(j.get(plan.value, "calls"))) |entry| {
            const draft = j.get(entry, "call");
            const call: ToolCall = .{
                .name = j.text(j.get(draft, "name")),
                .call_id = j.text(j.get(draft, "call_id")),
                .arguments = j.get(draft, "arguments"),
            };
            const key = try agent.session_protocol.Canonical.hash(a, try j.value(a, .{ response, call.call_id }));
            const address: TaskJournal.Document.Address = .{ .kind = "aborted-tool-result", .key = &key };
            const decision = if (try invocation.document(address)) |saved| saved.value else computed: {
                if (cutoff) continue;
                const decided = try self.afterToolDecision(invocation, call, response, j.get(entry, "reply"), null, false, .{});
                try invocation.commitDocuments(&.{.{ .address = address, .change = .{ .create = .{ .value = decided } } }});
                break :computed decided;
            };
            try j.put(a, &settlement.decisions, call.call_id, decision);
        }
    }
    return self.configureConversationWithAbortedTools(invocation.conversation, "cancelled", settlement);
}

fn configureConversation(self: *Self, conversation: []const u8, end_run: []const u8) !void {
    return self.configureConversationWithAbortedTools(conversation, end_run, null);
}

fn configureConversationWithAbortedTools(self: *Self, conversation: []const u8, end_run: []const u8, aborted: ?AbortedTools) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const scoped = !std.mem.eql(u8, conversation, TaskJournal.main_conversation);
    const config = if (scoped) blk: {
        var context = try self.gateway.readApplicationContext(self.worker.?, self.gpa, conversation);
        defer context.deinit();
        const saved = j.get(j.get(context.value, "session"), "config");
        break :blk try j.copy(a, if (saved == .object) saved else self.scoped_defaults);
    } else try self.configuration(a);
    const request = try self.deliver(.{
        .input_json = try j.encode(a, .{ .command = "configure", .config = config, .end_run = end_run, .abort_tools = aborted }),
        .conversation = if (scoped) conversation else null,
    }, null);
    defer request.deinit();
    defer self.forgetDelivery(request.id);
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    try self.awaitDelivery(request.id, false);
    if (outcome.status != .completed) return error.ConfigureFailed;
}

pub const HistoryPage = struct { events: []Event, next: ?[]const u8 };

pub fn promptHistory(self: *Self, a: std.mem.Allocator, index: usize) !?[]const u8 {
    var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
    defer snapshot.deinit();
    var cursor = try self.gpa.dupe(u8, j.text(j.get(j.get(snapshot.value, "session"), "head")));
    defer self.gpa.free(cursor);
    var found: usize = 0;
    while (cursor.len != 0) {
        var record = (try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .id = cursor })) orelse return error.InvalidSession;
        defer record.deinit();
        if (j.equal(j.get(record.value, "kind"), "input")) {
            if (found == index) {
                const original = j.get(record.value, "original");
                return try a.dupe(u8, if (original == .string) original.string else j.text(j.get(record.value, "text")));
            }
            found += 1;
        }
        const parent = try self.gpa.dupe(u8, j.text(j.get(record.value, "parent")));
        self.gpa.free(cursor);
        cursor = parent;
    }
    return null;
}

pub fn historyHead(self: *Self, a: std.mem.Allocator) !?[]const u8 {
    var snapshot = try self.gateway.readContext(self.worker.?, self.gpa);
    defer snapshot.deinit();
    const head = j.get(j.get(snapshot.value, "session"), "head");
    return if (head == .string) try a.dupe(u8, head.string) else null;
}

fn transcriptHead(self: *Self, a: std.mem.Allocator) !?[]const u8 {
    const worker = self.worker orelse return error.InvalidSession;
    return (try self.displayTreeHead(worker, a)) orelse try self.historyHead(a);
}

pub fn transcriptSnapshot(self: *Self, a: std.mem.Allocator) !agent.JsonDocument {
    const worker = self.worker orelse return error.InvalidSession;
    const leaf = try self.transcriptHead(a);
    defer if (leaf) |id| a.free(id);
    return self.gateway.exportApplicationBranch(worker, a, TaskJournal.main_conversation, leaf);
}

pub fn lastAssistantText(self: *Self, a: std.mem.Allocator) !?[]u8 {
    var cursor = try self.transcriptHead(a);
    defer if (cursor) |id| a.free(id);
    while (cursor) |id| {
        var record = (try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .id = id, .selected_display = true })) orelse break;
        defer record.deinit();
        if (j.equal(j.get(record.value, "kind"), "response")) {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const output = j.get(record.value, "output");
            const text = std.mem.trim(u8, try compaction.assistantText(scratch.allocator(), output), " \t\r\n");
            if (text.len != 0) return try a.dupe(u8, text);
            const tool_calls = j.items(j.get(record.value, "calls"));
            if (tool_calls.len == 0 and !j.equal(j.get(record.value, "stop_reason"), "length")) return null;
        }
        const parent = j.get(record.value, "parent");
        const next = if (parent == .string) try a.dupe(u8, parent.string) else null;
        a.free(id);
        cursor = next;
    }
    return null;
}

pub fn historyPage(self: *Self, a: std.mem.Allocator, at: ?[]const u8, rows: usize) !HistoryPage {
    var events: std.ArrayList(Event) = .empty;
    var cursor = at orelse try self.transcriptHead(a);
    var read: usize = 0;
    while (cursor) |id| {
        if (read >= rows) break;
        var record = (try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .id = id, .selected_display = true })) orelse return error.InvalidSession;
        defer record.deinit();
        const entry = record.value;
        cursor = if (j.get(entry, "parent") == .string) try a.dupe(u8, j.text(j.get(entry, "parent"))) else null;
        const kind = j.text(j.get(entry, "kind"));
        var event: ?Event = null;
        if (std.mem.eql(u8, kind, "input")) {
            event = .{ .kind = .user, .text = j.text(j.get(entry, "text")) };
        } else if (std.mem.eql(u8, kind, "response")) {
            event = .{ .kind = .assistant, .reply = try AssistantContent.fromJournal(a, entry), .has_context_usage = hasContextUsage(entry) };
        } else if (std.mem.eql(u8, kind, "program")) {
            const observations = j.items(j.get(entry, "observations"));
            const recorded = j.text(j.get(entry, "name"));
            const name = if (recorded.len > 0) recorded else if (observations.len > 0) j.text(j.get(observations[0], "tool_name")) else "execute_lua";
            const result = try toolResult(a, j.get(entry, "result"));
            event = .{
                .kind = .tool_end,
                .name = name,
                .call_id = j.text(j.get(entry, "call_id")),
                .entry_id = j.text(j.get(entry, "id")),
                .data = result,
                .arguments = j.get(entry, "arguments"),
                .images = try toolImages(a, entry),
                .text = try toolDisplayText(a, result, entry),
            };
        } else if (std.mem.eql(u8, kind, "checkpoint")) {
            const tokens_before = compactionTokensBefore(entry);
            event = .{ .kind = .compacted, .entry_id = id, .text = j.text(j.get(entry, "summary")), .tokens = tokens_before orelse 0, .compaction_tokens_before = tokens_before };
        } else if (std.mem.eql(u8, kind, "branch_summary")) {
            event = .{ .kind = .branch_summary, .entry_id = id, .text = j.text(j.get(entry, "summary")) };
        } else if (std.mem.eql(u8, kind, "write") and j.equal(j.get(entry, "event_kind"), UserShell.kind)) {
            const data = j.get(entry, "data");
            event = .{ .kind = .user_shell, .text = j.text(j.get(data, "command")), .data = data };
        } else if (std.mem.eql(u8, kind, "write") and j.get(entry, "model") == .null and j.get(entry, "context_start") == .null and j.get(entry, "edits") == .null) {
            const data = j.get(entry, "data");
            const label = j.text(j.get(entry, "event_kind"));
            if (!std.mem.eql(u8, label, SessionName.entry_kind) and j.get(entry, "session_setting") == .null and
                !j.flag(j.get(entry, "tree_label")) and !j.flag(j.get(entry, "system_revision")))
                event = .{ .kind = .notice, .name = label, .text = if (data == .string) data.string else label, .data = data };
        }
        if (event) |value| {
            var owned = value;
            owned.text = try a.dupe(u8, value.text);
            owned.name = try a.dupe(u8, value.name);
            owned.call_id = try a.dupe(u8, value.call_id);
            owned.entry_id = try a.dupe(u8, value.entry_id);
            owned.data = try j.copy(a, value.data);
            owned.arguments = try j.copy(a, value.arguments);
            try events.append(a, owned);
        }
        read += 1;
    }
    std.mem.reverse(Event, events.items);
    return .{ .events = events.items, .next = cursor };
}

pub const TreePage = struct { text: []const u8, next: ?u64 };

pub fn newerHistory(self: *Self, a: std.mem.Allocator, head: []const u8, rows: usize) !?[]const u8 {
    var ids: std.ArrayList([]u8) = .empty;
    defer {
        for (ids.items) |id| self.gpa.free(id);
        ids.deinit(self.gpa);
    }
    var cursor = (try self.transcriptHead(self.gpa)) orelse return null;
    defer self.gpa.free(cursor);
    while (!std.mem.eql(u8, cursor, head)) {
        if (ids.items.len == rows and ids.items.len != 0) self.gpa.free(ids.orderedRemove(0));
        const saved = try self.gpa.dupe(u8, cursor);
        ids.append(self.gpa, saved) catch |err| {
            self.gpa.free(saved);
            return err;
        };
        var record = (try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .id = cursor, .selected_display = true })) orelse return error.InvalidSession;
        defer record.deinit();
        const parent = j.get(record.value, "parent");
        if (parent != .string) return null;
        const next = try self.gpa.dupe(u8, parent.string);
        self.gpa.free(cursor);
        cursor = next;
    }
    return if (ids.items.len == 0) null else try a.dupe(u8, ids.items[0]);
}

pub const ForkMessage = struct { id: []const u8, text: []const u8 };

pub fn forkMessages(self: *Self, a: std.mem.Allocator) ![]const ForkMessage {
    const worker = self.worker orelse return error.InvalidSession;
    var messages: std.ArrayList(ForkMessage) = .empty;
    var query: agent.HistoryProjection = .{ .stream = .application, .fields = &.{ "id", "kind", "text" } };
    while (true) {
        var page = try self.gateway.projectHistory(worker, self.gpa, query);
        defer page.document.deinit();
        for (j.items(page.document.value)) |entry| {
            const text = j.text(j.get(entry, "text"));
            if (!j.equal(j.get(entry, "kind"), "input") or text.len == 0) continue;
            try messages.append(a, .{ .id = try a.dupe(u8, j.text(j.get(entry, "id"))), .text = try a.dupe(u8, text) });
        }
        query.before = page.before orelse break;
    }
    std.mem.reverse(ForkMessage, messages.items);
    return messages.items;
}

pub const TreeEntry = struct {
    pub const Kind = enum { system, user, assistant, tool, bash, compaction, branch_summary, model, thinking, context, title, label, custom, codemode_store, internal };
    id: []const u8,
    parent: []const u8,
    kind: Kind,
    text: []const u8 = "",
    name: []const u8 = "",
    arguments: Value = .null,
    tokens: usize = 0,
    status: []const u8 = "",
    diagnostic: []const u8 = "",
    label: []const u8 = "",
    label_time: i64 = 0,
};

pub const TreeSnapshot = struct { entries: []TreeEntry, head: ?[]const u8 };

pub fn treeHead(self: *Self, a: std.mem.Allocator) !?[]const u8 {
    const worker = self.worker orelse return error.InvalidSession;
    return (try self.displayTreeHead(worker, a)) orelse try self.historyHead(a);
}

fn displayTreeHead(self: *Self, worker: agent.WorkerId, a: std.mem.Allocator) !?[]const u8 {
    var tail = (try self.gateway.readHistory(worker, self.gpa, .{ .stream = .application, .selected_display = true })) orelse return null;
    defer tail.deinit();
    return try a.dupe(u8, j.text(j.get(tail.value, "id")));
}

/// Return journal topology and display metadata without changing the active conversation.
/// The caller owns the returned data in its snapshot arena.
pub fn sessionTree(self: *Self, a: std.mem.Allocator) !TreeSnapshot {
    const worker = self.worker orelse return error.InvalidSession;
    var ctx = try self.gateway.readContext(worker, self.gpa);
    defer ctx.deinit();
    const head_value = j.get(j.get(ctx.value, "session"), "head");
    const head = (try self.displayTreeHead(worker, a)) orelse
        if (head_value == .string) try a.dupe(u8, head_value.string) else null;
    const labels = j.get(ctx.value, "tree_labels");
    var tree: std.ArrayList(TreeEntry) = .empty;
    var query: agent.HistoryProjection = .{ .stream = .application, .include_display_parent = true, .fields = &.{
        "id",       "parent",       "kind",            "event_kind",      "data",       "model",  "edits", "context_start",
        "text",     "output",       "arguments",       "result",          "name",       "status", "error", "summary",
        "metadata", "observations", "system_revision", "session_setting", "tree_label",
    } };
    while (true) {
        var page = try self.gateway.projectHistory(worker, self.gpa, query);
        defer page.document.deinit();
        for (j.items(page.document.value)) |entry| {
            const id = j.text(j.get(entry, "id"));
            const label = j.get(labels, id);
            const parent = j.get(entry, "display_parent");
            var item: TreeEntry = .{
                .id = try a.dupe(u8, id),
                .parent = try a.dupe(u8, if (parent == .string) parent.string else j.text(j.get(entry, "parent"))),
                .kind = .internal,
                .label = try a.dupe(u8, j.text(j.get(label, "text"))),
                .label_time = @intCast(j.number(j.get(label, "at_ms"))),
            };
            const kind = j.get(entry, "kind");
            if (j.equal(kind, "input")) {
                item.kind = .user;
                item.text = try a.dupe(u8, j.text(j.get(entry, "text")));
            } else if (j.equal(kind, "response")) {
                item.kind = .assistant;
                item.text = try compaction.assistantText(a, j.get(entry, "output"));
                item.status = try a.dupe(u8, j.text(j.get(entry, "status")));
                const diagnostic = j.get(entry, "error");
                item.diagnostic = try a.dupe(u8, if (diagnostic == .string) diagnostic.string else j.text(j.get(diagnostic, "message")));
            } else if (j.equal(kind, "program")) {
                item.kind = .tool;
                const name = j.text(j.get(entry, "name"));
                const observations = j.items(j.get(entry, "observations"));
                item.name = try a.dupe(u8, if (name.len != 0) name else if (observations.len != 0) j.text(j.get(observations[0], "tool_name")) else "");
                const args = j.get(entry, "arguments");
                item.arguments = if (args == .object and std.mem.eql(u8, item.name, "write"))
                    try j.value(a, .{ .path = j.get(args, "path"), .file_path = j.get(args, "file_path") })
                else
                    try j.copy(a, args);
                item.text = try toolDisplayText(a, j.get(entry, "result"), entry);
            } else if (j.equal(kind, "checkpoint")) {
                item.kind = .compaction;
                item.text = try a.dupe(u8, j.text(j.get(entry, "summary")));
                item.tokens = j.number(j.get(j.get(entry, "metadata"), "tokensBefore"));
            } else if (j.equal(kind, "branch_summary")) {
                item.kind = .branch_summary;
                item.text = try a.dupe(u8, j.text(j.get(entry, "summary")));
            } else if (j.equal(kind, "branch") and j.equal(j.get(entry, "event_kind"), codemode_store_entry)) {
                item.kind = .codemode_store;
                item.name = "codemode-store";
            } else if (j.equal(kind, "write")) {
                const data = j.get(entry, "data");
                const name = j.text(j.get(entry, "event_kind"));
                item.name = try a.dupe(u8, name);
                if (std.mem.eql(u8, name, UserShell.kind)) {
                    item.kind = .bash;
                    item.text = try a.dupe(u8, j.text(j.get(data, "command")));
                } else if (std.mem.eql(u8, name, SessionName.entry_kind)) {
                    item.kind = .title;
                    item.name = "";
                    item.text = try a.dupe(u8, j.text(data));
                } else if (j.equal(j.get(entry, "session_setting"), "model")) {
                    item.kind = .model;
                    item.name = "";
                    item.text = try a.dupe(u8, j.text(j.get(data, "model")));
                } else if (j.equal(j.get(entry, "session_setting"), "thinking")) {
                    item.kind = .thinking;
                    item.name = "";
                    item.text = try a.dupe(u8, j.text(data));
                } else if (j.flag(j.get(entry, "tree_label"))) {
                    item.kind = .label;
                    item.name = "";
                    item.text = try a.dupe(u8, j.text(j.get(data, "label")));
                } else if (j.flag(j.get(entry, "system_revision"))) {
                    item.kind = .system;
                    item.name = "";
                } else if (j.get(entry, "model") != .null) {
                    item.kind = .model;
                    item.text = try a.dupe(u8, j.text(j.get(j.get(entry, "model"), "id")));
                } else if (j.get(entry, "context_start") != .null or j.get(entry, "edits") != .null) {
                    item.kind = .context;
                } else {
                    item.kind = .custom;
                    item.text = try a.dupe(u8, j.text(data));
                }
            }
            try tree.append(a, item);
        }
        query.before = page.before orelse break;
    }
    std.mem.reverse(TreeEntry, tree.items);
    return .{ .entries = tree.items, .head = head };
}

pub fn treePage(self: *Self, a: std.mem.Allocator, before: ?u64, rows: usize) !TreePage {
    const head = try self.historyHead(a);
    var text: std.ArrayList(u8) = .empty;
    var cursor = before;
    var read: usize = 0;
    while (read < rows) : (read += 1) {
        var record = (try self.gateway.readHistory(self.worker.?, self.gpa, .{ .stream = .application, .before = cursor })) orelse return .{ .text = text.items, .next = null };
        defer record.deinit();
        cursor = record.reference;
        const entry = record.value;
        const raw = if (j.get(entry, "original") == .string) j.text(j.get(entry, "original")) else j.text(j.get(entry, "text"));
        const excerpt = try a.dupe(u8, raw[0..@min(raw.len, 100)]);
        for (excerpt) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        const id = j.text(j.get(entry, "id"));
        const line = try std.fmt.allocPrint(a, "{s}{s} ← {s}  {s}  {s}\n", .{ if (head != null and std.mem.eql(u8, head.?, id)) "* " else "", id, if (j.get(entry, "parent") == .string) j.text(j.get(entry, "parent")) else "(root)", j.text(j.get(entry, "kind")), excerpt });
        try text.appendSlice(a, line);
    }
    return .{ .text = text.items, .next = cursor };
}
