const std = @import("std");
const json_text = @import("json_tree").text;
const types = @import("config.zig");
const Runtime = @import("Runtime.zig");
const port = @import("port.zig");
const j = @import("json.zig");
const vm = @import("vm");
const services = @import("services");
const provider = @import("provider.zig");
const MemoryBudget = vm.MemoryBudget;

pub const WorkerId = struct { scope: u64, index: u64 };
pub const Audit = struct {
    principal: u64,
    request_id: []const u8,
    operation: []const u8,
    arguments_sha256: []const u8,
    disposition: []const u8,
    scope: u64 = 0,
    effect_id: u64 = 0,
    effect_key_sha256: []const u8 = "",
    requested_arguments_sha256: []const u8 = "",
    requested_operation: []const u8 = "",
    descriptor: []const u8 = "",
    policy_decision: []const u8 = "not_evaluated",
    error_code: []const u8 = "",
    execution_attempted: bool = false,
};
pub const Event = union(enum) {
    notice: struct { worker: WorkerId, value: types.Notice },
    preview: struct { request_id: []const u8, update: provider.Preview.Update, worker: ?WorkerId = null, scope: u64 = 0 },
    audit: Audit,
    size_warning: services.SizeWarning,
};
pub const Sink = struct { context: ?*anyopaque, emit: *const fn (?*anyopaque, Event) anyerror!void };
pub const Options = struct {
    services: []const services.Service = &.{},
    providers: []const provider.Route = &.{},
    resolve_provider: ?provider.ResolveRoute = null,
    provider_payload_hooks: []const provider.PayloadHook = &.{},
    /// Optional process-local transport state that outlives joined closure.
    codex_sessions: ?*provider.CodexSessions = null,
    codex_transport_preference: ?*const std.atomic.Value(provider.CodexTransportPreference) = null,
    authorize: []const u8,
    preserve_policy_nulls: bool = false,
    host_session_access: bool = false,
    program_grants: []const []const u8 = &.{},
    on_event: ?[]const u8 = null,
    sink: ?Sink = null,
    memory_bytes: ?usize = null,
    admission_budget: u32 = 10000,
    program_budget: u32 = 1000000,
};

/// Owns Worker and program lifetimes. The allocator, I/O context, borrowed
/// services, provider contexts and sink context must outlive joined closure.
pub const Controller = opaque {
    pub fn open(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Controller {
        return (try State.open(gpa, io, options)).handle();
    }
    pub fn start(self: *Controller, config: types.Config) !WorkerId {
        return self.state().start(config, null);
    }
    pub fn launch(self: *Controller, config: types.Config, startup: types.Startup) !WorkerId {
        if (startup.failure_diagnostic) |slot| if (slot.* != null) return error.InvalidArgument;
        return self.state().start(config, startup);
    }
    pub fn stop(self: *Controller, worker: WorkerId) !void {
        return self.state().stop(worker);
    }
    /// Copies the command inputs. Releasing or canceling a wait does not cancel
    /// the command. Submit an explicit cancel command instead.
    pub fn submit(self: *Controller, worker: WorkerId, id: []const u8, command: types.Command) !*Runtime.Request {
        return self.state().submit(worker, id, command);
    }
    pub fn inspect(self: *Controller, worker: WorkerId, a: std.mem.Allocator) !j.Document {
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        try self.state().admitRead(worker, "context");
        return entry.runtime.?.inspect(a);
    }
    /// Native harness access. Guest programs cannot obtain this recorder.
    pub fn readSession(self: *Controller, worker: WorkerId, a: std.mem.Allocator) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.readSession(a);
    }
    pub fn readTranscript(self: *Controller, worker: WorkerId, a: std.mem.Allocator, context: []const u8, cut: ?u64) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.readTranscript(a, context, cut);
    }
    pub fn readSessionExtension(self: *Controller, worker: WorkerId, a: std.mem.Allocator, namespace: []const u8) !j.Document {
        return self.readExtension(worker, a, namespace, null);
    }
    /// Reads the durable terminal Worker outcome for a host command ID.
    pub fn readCommandReceipt(self: *Controller, worker: WorkerId, a: std.mem.Allocator, id: []const u8) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.readCommandReceipt(a, id);
    }
    /// Join already-dispatched host work after the invocation has stopped.
    pub fn joinInvocation(self: *Controller, worker: WorkerId, id: []const u8) !void {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.joinInvocation(id);
    }
    /// The projection runs on the session actor. Its output must use the supplied
    /// allocator, and it must not call back into the Controller.
    pub fn projectSessionExtension(self: *Controller, worker: WorkerId, a: std.mem.Allocator, namespace: []const u8, projection: @import("Session.zig").ExtensionProjection) !j.Document {
        return self.readExtension(worker, a, namespace, projection);
    }
    fn readExtension(self: *Controller, worker: WorkerId, a: std.mem.Allocator, namespace: []const u8, projection: ?@import("Session.zig").ExtensionProjection) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.readSessionExtension(a, namespace, projection);
    }
    /// Runs a read-only callback on the session actor. The revision and value
    /// come from the same state. The callback must neither retain the borrowed
    /// value nor call back into the Controller.
    pub fn visitSessionExtension(self: *Controller, worker: WorkerId, namespace: []const u8, visitor: @import("Session.zig").ExtensionVisitor) !void {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.visitSessionExtension(namespace, visitor);
    }
    pub fn recordSession(self: *Controller, worker: WorkerId, id: []const u8, actions: []const @import("session_protocol").frames.Action) !u64 {
        return self.recordSessionWithExtensions(worker, id, actions, &.{});
    }
    pub fn recordSessionWithExtensions(self: *Controller, worker: WorkerId, id: []const u8, actions: []const @import("session_protocol").frames.Action, extensions: []const @import("Session.zig").ExtensionWrite) !u64 {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.recordSession(id, actions, extensions);
    }
    pub fn attachTaskScheduler(self: *Controller, worker: WorkerId, attach: bool) !void {
        const state_ptr = self.state();
        if (!state_ptr.options.host_session_access) return error.PermissionDenied;
        state_ptr.mutex.lockUncancelable(state_ptr.io);
        defer state_ptr.mutex.unlock(state_ptr.io);
        if (state_ptr.closing.load(.acquire)) return error.ControllerClosed;
        const entry = try state_ptr.findWorker(worker);
        if (entry.runtime == null) return error.WorkerStarting;
        if (attach and entry.tasks_attached) return error.TaskSchedulerAlreadyAttached;
        entry.tasks_attached = attach;
    }
    pub fn readContext(self: *Controller, worker: WorkerId, a: std.mem.Allocator) !Runtime.ContextSnapshot {
        return self.state().readContext(worker, a);
    }
    pub fn readApplicationContext(self: *Controller, worker: WorkerId, a: std.mem.Allocator, scope: []const u8) !Runtime.ContextSnapshot {
        return self.readApplicationContextAt(worker, a, scope, .current);
    }
    pub fn readApplicationContextAt(self: *Controller, worker: WorkerId, a: std.mem.Allocator, scope: []const u8, cut: @import("Session.zig").ApplicationCut) !Runtime.ContextSnapshot {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.readApplicationContextAt(a, scope, cut);
    }
    pub fn readConversation(self: *Controller, worker: WorkerId, a: std.mem.Allocator) !@import("conversation.zig").Snapshot {
        return self.state().readConversation(worker, a);
    }
    pub fn readHistory(self: *Controller, worker: WorkerId, a: std.mem.Allocator, query: Runtime.HistoryQuery) !?Runtime.HistoryRecord {
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        try self.state().admitRead(worker, "history");
        return entry.runtime.?.readHistory(a, query);
    }
    pub fn projectHistory(self: *Controller, worker: WorkerId, a: std.mem.Allocator, query: @import("Session.zig").HistoryProjection) !@import("Session.zig").HistoryPage {
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        try self.state().admitRead(worker, "history");
        return entry.runtime.?.projectHistory(a, query);
    }
    pub fn planApplicationFork(self: *Controller, worker: WorkerId, a: std.mem.Allocator, conversation: []const u8, anchor: []const u8) !@import("Session.zig").ApplicationFork {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.planApplicationFork(a, conversation, anchor);
    }
    pub fn exportApplicationBranch(self: *Controller, worker: WorkerId, a: std.mem.Allocator, conversation: []const u8, leaf: ?[]const u8) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        try self.state().admitRead(worker, "history");
        return entry.runtime.?.exportApplicationBranch(a, conversation, leaf);
    }
    pub fn prepareResidentJournal(self: *Controller, worker: WorkerId) !?@import("PreparedJournal.zig") {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        try self.state().admitRead(worker, "history");
        return entry.runtime.?.prepareResidentJournal();
    }
    pub fn queryApplication(self: *Controller, worker: WorkerId, a: std.mem.Allocator, scope: []const u8, input: j.Value) !j.Document {
        if (!self.state().options.host_session_access) return error.PermissionDenied;
        const entry = try self.state().worker(worker);
        defer self.state().releaseWorker(entry);
        return entry.runtime.?.queryApplication(a, scope, input);
    }

    pub const TaskModel = struct {
        id: []const u8,
        binding: types.ApplicationModel,
        body: j.Value,
        progress: services.ModelProgressSink,
        resume_state: ?services.ModelResume = null,
    };

    /// Dispatch a native task's journaled model step through the worker's
    /// model grant, controller policy, and provider route admission.
    pub fn requestTaskModel(self: *Controller, worker: WorkerId, a: std.mem.Allocator, io: std.Io, call: TaskModel) !j.Value {
        const state_ptr = self.state();
        if (!state_ptr.options.host_session_access or state_ptr.options.resolve_provider == null) return error.PermissionDenied;
        const entry = try state_ptr.worker(worker);
        defer state_ptr.releaseWorker(entry);
        const model = call.binding.model;
        const identity: ModelIdentity = .{
            .url = try @import("responses.zig").url(a, .{ .base_url = model.base_url }),
            .credential = model.credential,
        };
        const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.effect_namespace, call.id });
        const args = try j.project(a, .{ .url = identity.url, .credential = identity.credential, .body = call.body });
        return state_ptr.dispatch(a, io, worker.index, call.id, 0, key, entry.grants, identity, "model.request", args, .{
            .binding = call.binding,
            .session_id = entry.session_id,
            .progress = call.progress,
            .resume_state = call.resume_state,
            .defer_poll = true,
            .attempt_key = key,
            .immediate = true,
        });
    }
    pub fn program(self: *Controller, id: []const u8, source: []const u8, input: j.Value) !*Runtime.Request {
        return self.state().program(id, source, input);
    }
    pub fn deliver(self: *Controller, worker: WorkerId, id: []const u8, delivery: types.Delivery) !*Runtime.Request {
        return self.submit(worker, id, .{ .deliver = delivery });
    }
    pub fn cancelInvocation(self: *Controller, worker: WorkerId, id: []const u8, target: []const u8) !*Runtime.Request {
        return self.submit(worker, id, .{ .cancel_invocation = target });
    }
    pub fn readProgramContext(self: *Controller, a: std.mem.Allocator) !Runtime.ContextSnapshot {
        return self.state().context(a);
    }
    /// Reports sticky observer-delivery failure without waiting for delivery.
    pub fn checkNotifications(self: *Controller) !void {
        if (self.state().notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
    }
    pub fn memoryUsage(self: *Controller) MemoryBudget.Usage {
        return MemoryBudget.fromAllocator(self.state().gpa).?.usage();
    }
    /// Requests cancellation without joining. Safe from a controller callback.
    pub fn requestClose(self: *Controller) void {
        self.state().requestClose();
    }
    /// Cancels and joins before destruction. Finish using request handles first.
    /// From a controller callback this only requests closure. An external owner
    /// must subsequently call close to join and destroy the controller.
    pub fn close(self: *Controller) void {
        self.state().close();
    }
    fn state(self: *Controller) *State {
        return @ptrCast(@alignCast(self));
    }
};

const ModelIdentity = struct {
    url: []const u8,
    credential: []const u8,
    fn matches(self: ModelIdentity, args: j.Value) bool {
        return std.mem.eql(u8, self.url, j.text(j.get(args, "url"))) and std.mem.eql(u8, self.credential, j.text(j.get(args, "credential")));
    }
};

fn matchesApplicationModel(model: types.Model, args: j.Value) bool {
    const body = j.get(args, "body");
    if (!std.mem.eql(u8, model.model, j.text(j.get(body, "model")))) return false;
    const limit = j.number(j.get(body, "max_output_tokens"));
    if (limit == 0 or limit > model.max_output_tokens) return false;
    const reasoning = j.get(body, "reasoning");
    return if (model.reasoning_effort) |effort|
        std.mem.eql(u8, effort, j.text(j.get(reasoning, "effort")))
    else
        reasoning == .null;
}
const Entry = struct { controller: *State, id: WorkerId, runtime: ?*Runtime = null, grants: []const *const services.Operation, model: ModelIdentity, session_id: []const u8, effect_namespace: []const u8, readers: usize = 0, idle: std.Io.Event = .unset, tasks_attached: bool = false };
threadlocal var callback_controller: ?*State = null;
const Program = struct { controller: *State, request: *Runtime.Request, source: []u8, input: []u8, fingerprint: [64]u8, event_hook: bool = false };
const Notification = struct { controller: *State, arena: std.heap.ArenaAllocator, event: Event, serial: u64, next: ?*Notification = null };
const NotificationQueue = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    head: ?*Notification = null,
    tail: ?*Notification = null,
    closed: bool = false,

    fn push(self: *NotificationQueue, _: std.mem.Allocator, io: std.Io, notification: *Notification) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.ControllerClosed;
        notification.next = null;
        if (self.tail) |tail| tail.next = notification else self.head = notification;
        self.tail = notification;
        self.condition.signal(io);
    }
    fn pop(self: *NotificationQueue, io: std.Io) ?*Notification {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.head) |notification| {
                self.head = notification.next;
                if (self.head == null) self.tail = null;
                return notification;
            }
            if (self.closed) return null;
            self.condition.wait(io, &self.mutex) catch return null;
        }
    }
    fn close(self: *NotificationQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.condition.broadcast(io);
    }
    fn deinit(self: *NotificationQueue, _: std.mem.Allocator) void {
        std.debug.assert(self.head == null);
    }
};
const Decision = struct { allow: bool, operation: ?[]const u8 = null, arguments: ?j.Value = null };
const Admission = struct {
    kind: []const u8,
    principal: u64,
    request_id: []const u8,
    operation: []const u8,
    arguments: j.Value,
    application_model: ?types.Model = null,
};
const controller_source = "return {name='controller',version=1,description='Controller operations',parameters={type='object'},endpoints={},recovery='never',execute=function(args) return host.call(args.operation,args.arguments) end}";

const State = struct {
    const ProgramCommand = struct { worker: WorkerId, request_id: []const u8, kind: enum { lua, input, cancel }, text: []const u8 = "" };
    const Enqueued = struct { accepted: bool };
    const command_operation = services.Operation.define("controller.command", State, ProgramCommand, Enqueued, .{ .arguments = 1024 * 1024, .result = 128 }, .receipt, programCommand);
    const Wait = struct { until_ms: i64 };
    const wait_operation = services.Operation.define("harness.wait", State, Wait, bool, .{ .arguments = 128, .result = 32 }, .read_only, waitUntil);

    fn waitUntil(_: *State, service: services.Context, args: Wait) anyerror!bool {
        while (true) {
            const now = std.Io.Clock.real.now(service.io).toMilliseconds();
            const remaining = args.until_ms -| now;
            if (remaining <= 0) return true;
            try std.Io.sleep(service.io, .fromMilliseconds(@min(remaining, 300000)), .real);
        }
    }
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    options: Options,
    registry: services.Registry,
    providers: provider.Service,
    scope: u64,
    mutex: std.Io.Mutex = .init,
    workers: std.ArrayList(*Entry) = .empty,
    next_worker_index: u64 = 1,
    programs: std.StringHashMapUnmanaged(*Program) = .empty,
    program_tasks: std.Io.Group = .init,
    notifications: std.Io.Future(void),
    notification_queue: NotificationQueue = .{},
    notification_failure: std.atomic.Value(bool) = .init(false),
    notifications_stopped: std.Io.Event = .unset,
    serial: std.atomic.Value(u64) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),
    heap: vm.Owner,
    controller_tool: *vm.RegisteredTool,
    policy_source: []const u8,
    program_active: bool = false,
    program_idle: std.Io.Condition = .init,
    starting: usize = 0,
    starts_idle: std.Io.Event = .unset,
    ctx: []u8,
    program_grants: []const *const services.Operation,
    budget: ?*MemoryBudget = null,

    fn handle(self: *State) *Controller {
        return @ptrCast(self);
    }
    fn open(gpa: std.mem.Allocator, io: std.Io, options: Options) !*State {
        if (options.authorize.len == 0 or options.admission_budget == 0 or options.admission_budget > 100000) return error.InvalidControllerPolicy;
        for (options.providers) |route| try route.retry.validate();
        const inherited = MemoryBudget.fromAllocator(gpa);
        if (inherited != null and options.memory_bytes != null) return error.InvalidControllerPolicy;
        const budget: ?*MemoryBudget = if (inherited == null) blk: {
            const bytes = options.memory_bytes orelse types.default_memory_bytes;
            if (bytes == 0) return error.InvalidControllerPolicy;
            break :blk try MemoryBudget.createAdvisory(gpa, bytes);
        } else null;
        errdefer if (budget) |b| b.release();
        const charged = if (budget) |b| b.allocator() else gpa;
        const self = try charged.create(State);
        errdefer charged.destroy(self);
        var scope: u64 = undefined;
        io.random(std.mem.asBytes(&scope));
        scope &= (1 << 52) - 1;
        self.* = .{ .gpa = charged, .io = io, .arena = .init(charged), .options = options, .registry = .init(charged), .providers = .{ .routes = options.providers }, .scope = scope, .ctx = try charged.dupe(u8, "{}"), .program_grants = &.{}, .notifications = undefined, .notification_queue = .{}, .heap = undefined, .controller_tool = undefined, .policy_source = "", .budget = budget };
        errdefer self.arena.deinit();
        errdefer charged.free(self.ctx);
        errdefer self.registry.deinit();
        self.heap = try vm.Owner.init(charged, io);
        errdefer self.heap.deinit();
        self.controller_tool = try self.heap.registerTool(controller_source);
        errdefer self.controller_tool.release();
        const a = self.arena.allocator();
        self.policy_source = try std.fmt.allocPrint(a, "local authorize = (function() {s} end)(); return authorize(input, ctx)", .{options.authorize});
        self.options.authorize = try a.dupe(u8, options.authorize);
        if (options.on_event) |source| self.options.on_event = try a.dupe(u8, source);
        const routes = try a.alloc(provider.Route, options.providers.len);
        for (options.providers, routes) |route, *copy| {
            copy.* = route;
            copy.base_url = try a.dupe(u8, route.base_url);
            copy.credential = try a.dupe(u8, route.credential);
            copy.transport.workspace = try a.dupe(u8, route.transport.workspace);
            if (route.transport.mode == .fixture) copy.transport.mode.fixture.host = try a.dupe(u8, route.transport.mode.fixture.host);
        }
        self.providers.routes = routes;
        self.providers.resolve_route = options.resolve_provider;
        self.providers.payload_hooks = try a.dupe(provider.PayloadHook, options.provider_payload_hooks);
        self.providers.codex_sessions = options.codex_sessions;
        self.providers.codex_transport_preference = options.codex_transport_preference;
        self.providers.preview = .{ .context = self, .notify = preview, .notify_scoped = previewScoped };
        self.registry.defer_registration_warnings = options.sink != null;
        try self.registry.add(self.providers.service());
        try self.registry.add(.{ .context = self, .operations = &.{&wait_operation} });
        try self.registry.add(.{ .context = self, .operations = &.{&command_operation} });
        for (options.services) |service| try self.registry.add(service);
        self.registry.freeze();
        self.program_grants = try self.resolveGrants(a, options.program_grants);
        self.starts_idle.set(io);
        self.notifications = try io.concurrent(runNotifications, .{self});
        if (options.sink != null) self.registry.reportRegistrationSizes(.{
            .allocator = charged,
            .io = io,
            .scope = self.scope,
            .size_warnings = .{ .context = self, .notify = sizeWarning },
        });
        return self;
    }

    fn resolveGrants(self: *State, a: std.mem.Allocator, names: []const []const u8) ![]const *const services.Operation {
        const grants = try a.alloc(*const services.Operation, names.len);
        for (names, grants, 0..) |name, *grant, index| {
            grant.* = try self.registry.resolve(name);
            for (grants[0..index]) |prior| if (prior == grant.*) return error.DuplicateGrant;
        }
        return grants;
    }
    fn validateRegistered(raw: *anyopaque, tool: *const vm.RegisteredTool) !void {
        const entry: *Entry = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(entry.controller.gpa);
        defer arena.deinit();
        try entry.controller.validateTool(arena.allocator(), tool, entry.grants);
    }
    fn validateTool(self: *State, a: std.mem.Allocator, tool: *const vm.RegisteredTool, grants: []const *const services.Operation) !void {
        const descriptor = try j.parse(a, tool.metadata());
        const endpoints = j.get(descriptor, "endpoints");
        if (endpoints != .array) return error.InvalidExtension;
        for (endpoints.array.items) |endpoint| {
            const operation = try self.registry.resolve(j.text(endpoint));
            if (!contains(grants, operation)) return error.PermissionDenied;
        }
    }
    fn startupCheck(raw: *anyopaque) !void {
        const entry: *Entry = @ptrCast(@alignCast(raw));
        try entry.controller.io.checkCancel();
        if (entry.controller.closing.load(.acquire)) return error.ControllerClosed;
        if (entry.controller.notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
    }

    fn startupCommand(raw: *anyopaque, id: []const u8, command: types.Command, candidate: ?*const vm.RegisteredTool) !void {
        const entry: *Entry = @ptrCast(@alignCast(raw));
        try startupCheck(raw);
        try entry.controller.admitCommand(entry, id, command, candidate);
    }

    fn start(self: *State, config: types.Config, startup: ?types.Startup) !WorkerId {
        self.mutex.lockUncancelable(self.io);
        if (self.closing.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.ControllerClosed;
        }
        if (self.starting == 0) self.starts_idle.reset();
        self.starting += 1;
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.starting -= 1;
            if (self.starting == 0) self.starts_idle.set(self.io);
            self.mutex.unlock(self.io);
        }
        if (self.notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const grants = try self.resolveGrants(arena.allocator(), config.endpoint_grants);
        if (contains(grants, &command_operation)) return error.PermissionDenied;
        if (contains(grants, &provider.Service.operation) and !self.providers.matches(config.model)) return error.UnregisteredProvider;
        const entry = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(entry);
        const owned_grants = try self.gpa.dupe(*const services.Operation, grants);
        errdefer self.gpa.free(owned_grants);
        const url = try @import("responses.zig").url(self.gpa, .{ .base_url = config.model.base_url });
        errdefer self.gpa.free(url);
        const credential = try self.gpa.dupe(u8, config.model.credential);
        errdefer self.gpa.free(credential);
        const session_id = try self.gpa.dupe(u8, config.session_id);
        errdefer self.gpa.free(session_id);
        const journal_namespace = if (config.persistence == .journal and !std.mem.eql(u8, config.journal_path, "memory:")) try self.journalNamespace(arena.allocator(), config) else null;
        self.mutex.lockUncancelable(self.io);
        if (self.next_worker_index >= 1 << 52) {
            self.mutex.unlock(self.io);
            return error.LimitExceeded;
        }
        for (self.workers.items) |existing| if (std.mem.eql(u8, existing.session_id, session_id)) {
            self.mutex.unlock(self.io);
            return error.DuplicateSession;
        };
        const id: WorkerId = .{ .scope = self.scope, .index = self.next_worker_index };
        const effect_namespace = (if (journal_namespace) |namespace| self.gpa.dupe(u8, namespace) else std.fmt.allocPrint(self.gpa, "worker-memory/{d}/{d}", .{ self.scope, id.index })) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        errdefer self.gpa.free(effect_namespace);
        entry.* = .{ .controller = self, .id = id, .grants = owned_grants, .model = .{ .url = url, .credential = credential }, .session_id = session_id, .effect_namespace = effect_namespace };
        entry.idle.set(self.io);
        self.workers.append(self.gpa, entry) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.next_worker_index += 1;
        self.mutex.unlock(self.io);
        defer self.reportMemory(id.index, "");
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.removeWorker(entry);
            self.mutex.unlock(self.io);
        }
        const controller_port: port.Port = .{
            .context = entry,
            .exchange = exchange,
            .validate_tool = validateRegistered,
            .startup_command = startupCommand,
            .startup_check = startupCheck,
            .journal_size_warnings = .{ .context = entry, .notify = journalSizeWarning },
            .application_size_warnings = .{ .context = entry, .notify = applicationSizeWarning },
        };
        const runtime = if (startup) |plan| try Runtime.launch(self.gpa, self.io, config, controller_port, plan) else try Runtime.open(self.gpa, self.io, config, controller_port);
        errdefer runtime.destroy();
        if (startup != null) try runtime.activate();
        if (startup != null) try self.io.checkCancel();
        self.mutex.lockUncancelable(self.io);
        if (self.closing.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.ControllerClosed;
        }
        entry.runtime = runtime;
        if (startup != null) runtime.publish();
        self.mutex.unlock(self.io);
        return id;
    }
    fn journalNamespace(self: *State, a: std.mem.Allocator, config: types.Config) ![]const u8 {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", a);
        const absolute = try std.fs.path.resolve(a, &.{ cwd, config.journal_path });
        var prefix: []const u8 = absolute;
        while (true) {
            const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, prefix, a) catch |err| switch (err) {
                error.FileNotFound => {
                    prefix = std.fs.path.dirname(prefix) orelse return err;
                    continue;
                },
                else => return err,
            };
            const path = try std.fs.path.join(a, &.{ canonical, std.mem.trimStart(u8, absolute[prefix.len..], std.fs.path.sep_str) });
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(config.session_id);
            hash.update(&.{0});
            hash.update(path);
            return std.fmt.allocPrint(a, "worker-journal/{s}", .{std.fmt.bytesToHex(hash.finalResult(), .lower)});
        }
    }
    fn findWorker(self: *State, id: WorkerId) !*Entry {
        if (id.scope != self.scope or id.index == 0) return error.UnknownWorker;
        for (self.workers.items) |entry| if (entry.id.index == id.index) return entry;
        return error.UnknownWorker;
    }
    fn removeWorker(self: *State, entry: *Entry) void {
        for (self.workers.items, 0..) |existing, index| if (existing == entry) {
            _ = self.workers.swapRemove(index);
            return;
        };
        unreachable;
    }
    fn worker(self: *State, id: WorkerId) !*Entry {
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        const entry = try self.findWorker(id);
        if (entry.runtime == null) return error.WorkerStarting;
        if (entry.readers == 0) entry.idle.reset();
        entry.readers += 1;
        return entry;
    }
    fn releaseWorker(self: *State, entry: *Entry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        entry.readers -= 1;
        if (entry.readers == 0) entry.idle.set(self.io);
    }
    fn stop(self: *State, id: WorkerId) !void {
        if (callback_controller == self) return error.ControllerCallbackLifecycle;
        self.mutex.lockUncancelable(self.io);
        const entry = self.findWorker(id) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (entry.runtime == null) {
            self.mutex.unlock(self.io);
            return error.WorkerStarting;
        }
        self.removeWorker(entry);
        self.mutex.unlock(self.io);
        self.destroyWorker(entry);
    }
    fn destroyWorker(self: *State, entry: *Entry) void {
        entry.idle.waitUncancelable(self.io);
        if (entry.runtime) |runtime| runtime.destroy();
        if (self.providers.codex_sessions) |sessions| sessions.closeSockets(entry.session_id);
        self.gpa.free(entry.grants);
        self.gpa.free(entry.model.url);
        self.gpa.free(entry.model.credential);
        self.gpa.free(entry.session_id);
        self.gpa.free(entry.effect_namespace);
        self.gpa.destroy(entry);
    }
    fn submit(self: *State, id: WorkerId, request_id: []const u8, command: types.Command) !*Runtime.Request {
        const entry = try self.worker(id);
        defer self.releaseWorker(entry);
        const registered = if (command == .register_capability) try entry.runtime.?.prepareCapability(request_id, command.register_capability) else null;
        defer if (registered) |item| item.release();
        try self.admitCommand(entry, request_id, command, registered);
        return entry.runtime.?.submitRegistered(request_id, command, registered);
    }

    fn admitCommand(self: *State, entry: *Entry, request_id: []const u8, command: types.Command, registered: ?*const vm.RegisteredTool) !void {
        switch (command) {
            .cancel, .close => {},
            else => {
                if (command != .cancel_invocation and self.notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const a = arena.allocator();
                if (registered) |item| try self.validateTool(a, item, entry.grants);
                const args = try Runtime.commandValue(a, command);
                try j.validate(a, args);
                const decision = try self.admit(a, .{ .kind = "command", .principal = entry.id.index, .request_id = request_id, .operation = @tagName(command), .arguments = args });
                if (!decision.allow or decision.operation != null or decision.arguments != null) return error.PermissionDenied;
            },
        }
    }
    fn readContext(self: *State, id: WorkerId, a: std.mem.Allocator) !Runtime.ContextSnapshot {
        const entry = try self.worker(id);
        defer self.releaseWorker(entry);
        try self.admitRead(id, "context");
        return entry.runtime.?.readContext(a);
    }
    fn readConversation(self: *State, id: WorkerId, a: std.mem.Allocator) !@import("conversation.zig").Snapshot {
        const entry = try self.worker(id);
        defer self.releaseWorker(entry);
        try self.admitRead(id, "conversation");
        return entry.runtime.?.readConversation(a);
    }
    fn admitRead(self: *State, id: WorkerId, kind: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const decision = try self.admit(arena.allocator(), .{ .kind = "snapshot", .principal = id.index, .request_id = "", .operation = kind, .arguments = j.object() });
        if (!decision.allow or decision.operation != null or decision.arguments != null) return error.PermissionDenied;
    }
    fn context(self: *State, a: std.mem.Allocator) !j.Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return j.Document.init(a, self.ctx);
    }
    fn admit(self: *State, a: std.mem.Allocator, event: Admission) !Decision {
        var public = try j.project(a, event);
        if (event.application_model == null) _ = public.object.orderedRemove("application_model");
        const event_json = try j.encode(a, public);
        var snapshot = try self.context(a);
        defer snapshot.deinit();
        var machine = self.heap.beginPolicy(a, try j.encode(a, snapshot.value), self.policy_source, event_json, self.options.preserve_policy_nulls) catch return error.InvalidControllerPolicy;
        defer machine.deinit();
        const step = try machine.step(self.options.admission_budget, null);
        if (step != .done) return error.InvalidControllerPolicy;
        return json_text.parseFromSliceLeaky(Decision, a, step.done.result_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch error.InvalidControllerPolicy;
    }
    const ModelDelivery = struct {
        session_id: ?[]const u8 = null,
        progress: ?services.ModelProgressSink = null,
        resume_state: ?services.ModelResume = null,
        defer_poll: bool = false,
        attempt_key: []const u8 = "",
        immediate: bool = false,
        binding: ?types.ApplicationModel = null,
    };

    fn dispatch(self: *State, a: std.mem.Allocator, io: std.Io, principal: u64, request_id: []const u8, effect_id: u64, key: []const u8, grants: []const *const services.Operation, ceiling: ?ModelIdentity, endpoint: []const u8, args: j.Value, delivery: ModelDelivery) !j.Value {
        const notification = try self.beginAudit(principal, request_id, effect_id, key, endpoint, args);
        defer if (notification) |n| self.enqueue(n);
        var audit: Audit = if (notification) |n| n.event.audit else .{ .principal = principal, .request_id = request_id, .operation = endpoint, .arguments_sha256 = "", .disposition = "rejected" };
        defer if (notification) |n| {
            n.event.audit = audit;
        };
        return self.dispatchEffect(a, io, principal, request_id, effect_id, key, grants, ceiling, endpoint, args, delivery, &audit, notification) catch |err| {
            audit.error_code = @errorName(err);
            if (err == error.Canceled) audit.disposition = "cancelled";
            return err;
        };
    }
    fn dispatchEffect(self: *State, a: std.mem.Allocator, io: std.Io, principal: u64, request_id: []const u8, effect_id: u64, key: []const u8, grants: []const *const services.Operation, ceiling: ?ModelIdentity, endpoint: []const u8, args: j.Value, delivery: ModelDelivery, audit: *Audit, notification: ?*Notification) !j.Value {
        defer self.reportMemory(principal, request_id);
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        if (self.notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
        var c: services.Context = .{
            .allocator = a,
            .io = io,
            .idempotency_key = key,
            .principal = principal,
            .scope = self.scope,
            .request_id = request_id,
            .effect_id = effect_id,
            .size_warnings = .{ .context = self, .notify = sizeWarning },
            .immediate_model = delivery.immediate,
        };
        const original = try self.registry.resolve(endpoint);
        audit.descriptor = original.name;
        _ = try self.registry.validate(c, endpoint, args);
        if (!contains(grants, original)) return error.PermissionDenied;
        if (ceiling) |identity| if (original == &provider.Service.operation and !identity.matches(args)) return error.PermissionDenied;
        if (delivery.binding) |binding| if (!matchesApplicationModel(binding.model, args)) return error.PermissionDenied;
        const decision = self.admit(a, .{
            .kind = if (std.mem.eql(u8, endpoint, "model.request")) "model" else "host",
            .principal = principal,
            .request_id = request_id,
            .operation = endpoint,
            .arguments = args,
            .application_model = if (delivery.binding) |binding| binding.model else null,
        }) catch |err| {
            audit.policy_decision = "invalid";
            return err;
        };
        audit.policy_decision = if (decision.allow) "allow" else "deny";
        if (!decision.allow) {
            audit.disposition = "denied";
            return error.PermissionDenied;
        }
        const effective_endpoint = decision.operation orelse endpoint;
        const effective_args = decision.arguments orelse args;
        if (notification) |n| {
            const owned = n.arena.allocator();
            audit.operation = try owned.dupe(u8, effective_endpoint);
            const digest = j.sourceHash(try j.encode(a, effective_args));
            @memcpy(@constCast(audit.arguments_sha256), &digest);
        }
        audit.descriptor = "";
        const operation = try self.registry.resolve(effective_endpoint);
        if (delivery.binding) |binding| {
            if (operation != original or !matchesApplicationModel(binding.model, effective_args)) return error.PermissionDenied;
            c.model_selection = binding.selection;
        }
        if (operation == &provider.Service.operation and original == operation) {
            c.model_session_id = delivery.session_id;
            if (decision.operation == null and decision.arguments == null) {
                c.model_progress = delivery.progress;
                c.model_resume = delivery.resume_state;
                c.defer_model_poll = delivery.defer_poll;
                c.model_attempt_key = delivery.attempt_key;
            } else if (delivery.resume_state != null) return error.PermissionDenied;
        }
        audit.descriptor = operation.name;
        _ = try self.registry.validate(c, effective_endpoint, effective_args);
        if (!contains(grants, operation)) return error.PermissionDenied;
        if (ceiling) |identity| if (operation == &provider.Service.operation and !identity.matches(effective_args)) return error.PermissionDenied;
        audit.disposition = "failed";
        audit.execution_attempted = true;
        const previous_callback = callback_controller;
        callback_controller = self;
        defer callback_controller = previous_callback;
        const result = try self.registry.dispatchGranted(c, grants, effective_endpoint, effective_args);
        audit.disposition = "completed";
        return result;
    }
    fn beginAudit(self: *State, principal: u64, request_id: []const u8, effect_id: u64, key: []const u8, endpoint: []const u8, args: j.Value) !?*Notification {
        if (self.options.sink == null) return null;
        const notification = try self.reserveNotification();
        errdefer self.freeNotification(notification);
        const a = notification.arena.allocator();
        const digest = j.sourceHash(try j.encode(a, args));
        const effect_digest = j.sourceHash(key);
        notification.event = .{ .audit = .{
            .scope = self.scope,
            .principal = principal,
            .request_id = try a.dupe(u8, request_id),
            .effect_id = effect_id,
            .effect_key_sha256 = try a.dupe(u8, &effect_digest),
            .requested_arguments_sha256 = try a.dupe(u8, &digest),
            .requested_operation = try a.dupe(u8, endpoint),
            .operation = try a.dupe(u8, endpoint),
            .arguments_sha256 = try a.dupe(u8, &digest),
            .disposition = "rejected",
        } };
        return notification;
    }
    fn exchange(raw: *anyopaque, a: std.mem.Allocator, io: std.Io, event: port.Event) !?port.Response {
        const entry: *Entry = @ptrCast(@alignCast(raw));
        const self = entry.controller;
        if (event == .notice) {
            self.reportMemory(entry.id.index, event.notice.request_id);
            self.notify(.{ .notice = .{ .worker = entry.id, .value = event.notice } }) catch {
                self.notification_failure.store(true, .release);
            };
            return null;
        }
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        const request = event.request;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        const packet = try j.parse(temporary, request.json);
        const endpoint = if (request.method == .model) "model.request" else j.text(j.get(packet, "endpoint"));
        var args = if (request.method == .model) packet else j.get(packet, "arguments");
        var ceiling = entry.model;
        var binding: ?types.ApplicationModel = null;
        if (request.method == .host and j.flag(j.get(packet, "model_binding")) and std.mem.eql(u8, endpoint, "model.request")) {
            const selected = j.get(packet, "application_model");
            if (selected != .null) {
                if (!self.options.host_session_access or self.options.resolve_provider == null) return error.PermissionDenied;
                binding = try std.json.parseFromValueLeaky(types.ApplicationModel, temporary, selected, .{});
                ceiling = .{ .url = try @import("responses.zig").url(temporary, .{ .base_url = binding.?.model.base_url }), .credential = binding.?.model.credential };
            }
            try j.put(temporary, &args, "url", j.string(ceiling.url));
            try j.put(temporary, &args, "credential", j.string(ceiling.credential));
        }
        const effect_key = if (request.method == .model) request.request_id else j.text(j.get(packet, "idempotency_key"));
        const key = try std.fmt.allocPrint(temporary, "{s}/{s}", .{ entry.effect_namespace, effect_key });
        const resume_value = j.get(packet, "provider_resume");
        const resume_state = if (resume_value == .object and request.model_progress != null)
            try std.json.parseFromValueLeaky(services.ModelResume, temporary, resume_value, .{})
        else
            null;
        const result = try self.dispatch(temporary, io, entry.id.index, request.request_id, request.operation_id, key, entry.grants, ceiling, endpoint, args, .{
            .session_id = entry.session_id,
            .progress = request.model_progress,
            .resume_state = resume_state,
            .defer_poll = request.model_progress != null and j.flag(j.get(packet, "defer_model_poll")),
            .attempt_key = if (request.model_progress != null) j.text(j.get(packet, "model_attempt_key")) else "",
            .binding = binding,
        });
        return .{ .json = try j.encode(a, result) };
    }
    fn preview(raw: ?*anyopaque, request_id: []const u8, update: provider.Preview.Update) !void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        return previewScoped(raw, self.scope, 0, request_id, update);
    }
    fn previewScoped(raw: ?*anyopaque, scope: u64, principal: u64, request_id: []const u8, update: provider.Preview.Update) !void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        self.notify(.{ .preview = .{ .request_id = request_id, .update = update, .scope = scope, .worker = if (principal == 0) null else .{ .scope = scope, .index = principal } } }) catch {
            self.notification_failure.store(true, .release);
        };
    }
    fn sizeWarning(raw: *anyopaque, warning: services.SizeWarning) void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (self.options.sink == null or self.closing.load(.acquire)) {
            services.logSizeWarning(warning);
            return;
        }
        self.notify(.{ .size_warning = warning }) catch services.logSizeWarning(warning);
    }
    fn journalSizeWarning(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
        const entry: *Entry = @ptrCast(@alignCast(raw.?));
        sizeWarning(entry.controller, .{ .operation = "session journal", .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = "", .principal = entry.id.index });
    }
    fn applicationSizeWarning(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
        const entry: *Entry = @ptrCast(@alignCast(raw.?));
        sizeWarning(entry.controller, .{ .operation = "harness application", .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = "", .principal = entry.id.index });
    }
    fn reportMemory(self: *State, principal: u64, request_id: []const u8) void {
        const ledger = MemoryBudget.fromAllocator(self.gpa) orelse return;
        const warning = ledger.takeWarning() orelse return;
        sizeWarning(self, .{ .operation = "memory", .measurement = "allocated bytes", .actual = warning.actual, .threshold = warning.threshold, .request_id = request_id, .principal = principal });
    }
    fn notify(self: *State, event: Event) !void {
        if (self.closing.load(.acquire) or (self.options.sink == null and self.options.on_event == null)) return;
        const notification = try self.reserveNotification();
        errdefer self.freeNotification(notification);
        const a = notification.arena.allocator();
        notification.event = switch (event) {
            .notice => |n| .{ .notice = .{ .worker = n.worker, .value = .{ .kind = n.value.kind, .sequence = n.value.sequence, .request_id = try a.dupe(u8, n.value.request_id), .json = try a.dupe(u8, n.value.json) } } },
            .preview => |p| .{ .preview = .{ .request_id = try a.dupe(u8, p.request_id), .update = try copyPreview(a, p.update), .worker = p.worker, .scope = p.scope } },
            .size_warning => |warning| .{ .size_warning = .{
                .operation = try a.dupe(u8, warning.operation),
                .measurement = try a.dupe(u8, warning.measurement),
                .actual = warning.actual,
                .threshold = warning.threshold,
                .request_id = try a.dupe(u8, warning.request_id),
                .principal = warning.principal,
            } },
            .audit => unreachable,
        };
        self.enqueue(notification);
    }
    fn copyPreview(a: std.mem.Allocator, update: provider.Preview.Update) !provider.Preview.Update {
        return switch (update) {
            .started => .started,
            .retrying => |retry| .{ .retrying = retry },
            .delta => |text| .{ .delta = try a.dupe(u8, text) },
            .reasoning_delta => |text| .{ .reasoning_delta = try a.dupe(u8, text) },
            .tool_start => |call| .{ .tool_start = .{ .call_id = try a.dupe(u8, call.call_id), .name = try a.dupe(u8, call.name) } },
            .tool_delta => |arguments| .{ .tool_delta = .{ .call_id = try a.dupe(u8, arguments.call_id), .delta = try a.dupe(u8, arguments.delta) } },
            .tool_end => |complete| .{ .tool_end = .{ .call_id = try a.dupe(u8, complete.call_id), .arguments = try a.dupe(u8, complete.arguments) } },
        };
    }
    fn reserveNotification(self: *State) !*Notification {
        const notification = try self.gpa.create(Notification);
        errdefer self.gpa.destroy(notification);
        notification.* = .{ .controller = self, .arena = .init(self.gpa), .event = undefined, .serial = self.serial.fetchAdd(1, .monotonic) };
        errdefer notification.arena.deinit();
        return notification;
    }
    fn enqueue(self: *State, notification: *Notification) void {
        self.notification_queue.push(self.gpa, self.io, notification) catch |err| {
            if (notification.event == .size_warning) {
                services.logSizeWarning(notification.event.size_warning);
            } else if (err != error.ControllerClosed) {
                self.notification_failure.store(true, .release);
            }
            self.freeNotification(notification);
        };
    }
    fn freeNotification(self: *State, notification: *Notification) void {
        notification.arena.deinit();
        self.gpa.destroy(notification);
    }
    fn runNotifications(self: *State) void {
        defer self.notifications_stopped.set(self.io);
        while (self.notification_queue.pop(self.io)) |notification| deliver(notification);
    }
    fn deliver(notification: *Notification) void {
        const self = notification.controller;
        defer self.freeNotification(notification);
        const previous_callback = callback_controller;
        callback_controller = self;
        defer callback_controller = previous_callback;
        if (self.options.sink) |sink| sink.emit(sink.context, notification.event) catch {
            if (notification.event == .size_warning) services.logSizeWarning(notification.event.size_warning) else self.notification_failure.store(true, .release);
        };
        if (self.options.on_event) |source| {
            if (notification.event != .notice or self.closing.load(.acquire)) return;
            const a = notification.arena.allocator();
            const input = j.project(a, notification.event) catch {
                self.notification_failure.store(true, .release);
                return;
            };
            const id = std.fmt.allocPrint(a, "event/{d}", .{notification.serial}) catch {
                self.notification_failure.store(true, .release);
                return;
            };
            const request = self.programImpl(id, source, input, true) catch {
                self.notification_failure.store(true, .release);
                return;
            };
            request.deinit();
        }
    }
    fn program(self: *State, id: []const u8, source: []const u8, input: j.Value) !*Runtime.Request {
        return self.programImpl(id, source, input, false);
    }
    fn programImpl(self: *State, id: []const u8, source: []const u8, input: j.Value, event_hook: bool) !*Runtime.Request {
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        if (self.notification_failure.load(.acquire)) return error.NotificationDeliveryFailed;
        if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidArgument;
        const input_bytes = try j.encode(self.gpa, input);
        defer self.gpa.free(input_bytes);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(source);
        hasher.update(&.{0});
        hasher.update(input_bytes);
        const fingerprint = std.fmt.bytesToHex(hasher.finalResult(), .lower);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing.load(.acquire)) return error.ControllerClosed;
        if (!event_hook) if (self.programs.get(id)) |existing| {
            if (!std.mem.eql(u8, &fingerprint, &existing.fingerprint)) return error.RequestConflict;
            _ = existing.request.references.fetchAdd(1, .monotonic);
            return existing.request;
        };
        const p = try self.gpa.create(Program);
        errdefer self.gpa.destroy(p);
        const request = try self.gpa.create(Runtime.Request);
        errdefer self.gpa.destroy(request);
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        const payload = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(payload);
        const copied_input = try self.gpa.dupe(u8, input_bytes);
        errdefer self.gpa.free(copied_input);
        request.* = .{ .gpa = self.gpa, .id = owned_id, .kind = 4, .payload = payload };
        p.* = .{ .controller = self, .request = request, .source = payload, .input = copied_input, .fingerprint = fingerprint, .event_hook = event_hook };
        if (!event_hook) try self.programs.put(self.gpa, owned_id, p);
        errdefer {
            if (!event_hook) _ = self.programs.remove(owned_id);
        }
        try self.program_tasks.concurrent(self.io, runProgram, .{p});
        return request;
    }
    fn runProgram(p: *Program) void {
        const self = p.controller;
        defer if (p.event_hook) {
            p.request.deinit();
            self.gpa.free(p.input);
            self.gpa.destroy(p);
        };
        self.executeProgram(p) catch |err| {
            p.request.failure = err;
            if (p.event_hook and err != error.Canceled) self.notification_failure.store(true, .release);
        };
        self.reportMemory(0, p.request.id);
        p.request.done.set(self.io);
    }
    fn executeProgram(self: *State, p: *Program) !void {
        try self.io.checkCancel();
        self.mutex.lockUncancelable(self.io);
        while (self.program_active) {
            self.program_idle.wait(self.io, &self.mutex) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
        }
        self.program_active = true;
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.program_active = false;
            self.program_idle.signal(self.io);
            self.mutex.unlock(self.io);
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var snapshot = try self.context(a);
        defer snapshot.deinit();
        const source = try std.fmt.allocPrint(a, "local host = {{call=function(operation, arguments) return tools.controller({{operation=operation, arguments=arguments}}) end}}; local worker = {{command=function(args) return host.call('controller.command', args) end}}; {s}", .{p.source});
        var machine = try self.heap.beginProgram(a, try j.encode(a, snapshot.value), &.{.{ .name = "controller", .source = controller_source, .registered = self.controller_tool }}, source, p.input);
        defer machine.deinit();
        var reply: ?vm.Reply = null;
        var remaining = self.options.program_budget;
        var effect: u64 = 0;
        while (remaining > 0) {
            try self.io.checkCancel();
            const budget = @min(remaining, 10000);
            remaining -= budget;
            const step = try machine.step(budget, reply);
            reply = null;
            switch (step) {
                .budget => {},
                .failed => return error.ControllerProgramFailed,
                .done => |done| {
                    try self.commitContext(done.ctx_json);
                    p.request.outcome = try j.Document.initValue(self.gpa, try j.project(a, .{ .status = "completed", .result = try j.parse(a, done.result_json), .capabilities_revision = 0 }));
                    return;
                },
                .effect => |call| {
                    try self.commitContext(call.ctx_json);
                    const endpoint = try a.dupe(u8, call.endpoint);
                    const args = try j.parse(a, call.arguments_json);
                    effect += 1;
                    const key = if (p.event_hook) try std.fmt.allocPrint(a, "controller-event/{d}/{s}/{d}", .{ self.scope, p.request.id, effect }) else try std.fmt.allocPrint(a, "controller/{d}/{s}/{d}", .{ self.scope, p.request.id, effect });
                    const result = self.dispatch(a, self.io, 0, p.request.id, effect, key, self.program_grants, null, endpoint, args, .{});
                    if (result) |value| {
                        reply = .{ .json = try j.encode(a, value) };
                    } else |err| {
                        if (err == error.Canceled) return err;
                        reply = .{ .json = try j.encode(a, .{ .code = @errorName(err) }), .failed = true };
                    }
                },
            }
        }
        return error.ControllerProgramBudget;
    }
    fn programCommand(self: *State, _: services.Context, command: ProgramCommand) !Enqueued {
        const request = try self.submit(command.worker, command.request_id, switch (command.kind) {
            .lua => .{ .lua = command.text },
            .input => .{ .input = command.text },
            .cancel => .cancel,
        });
        request.deinit();
        return .{ .accepted = true };
    }
    fn commitContext(self: *State, bytes: []const u8) !void {
        const next = try self.gpa.dupe(u8, bytes);
        self.mutex.lockUncancelable(self.io);
        const old = self.ctx;
        self.ctx = next;
        self.mutex.unlock(self.io);
        self.gpa.free(old);
    }
    fn requestClose(self: *State) void {
        self.mutex.lockUncancelable(self.io);
        self.closing.store(true, .release);
        self.mutex.unlock(self.io);
    }
    fn close(self: *State) void {
        self.requestClose();
        if (callback_controller == self) return;
        self.program_tasks.cancel(self.io);
        self.starts_idle.waitUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        self.mutex.unlock(self.io);
        for (self.workers.items) |entry| {
            self.destroyWorker(entry);
        }
        {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            const previous_callback = callback_controller;
            callback_controller = self;
            defer callback_controller = previous_callback;
            self.registry.releaseAll(.{ .allocator = arena.allocator(), .io = self.io, .scope = self.scope }) catch |err| std.log.err("controller service release failed: {s}", .{@errorName(err)});
        }
        self.notification_queue.close(self.io);
        self.notifications_stopped.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } }) catch {};
        self.notifications.cancel(self.io);
        self.notifications_stopped.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } }) catch {};
        while (self.notification_queue.pop(self.io)) |notification| self.freeNotification(notification);
        self.notification_queue.deinit(self.gpa);
        self.workers.deinit(self.gpa);
        var iterator = self.programs.valueIterator();
        while (iterator.next()) |p| {
            p.*.request.deinit();
            self.gpa.free(p.*.input);
            self.gpa.destroy(p.*);
        }
        self.programs.deinit(self.gpa);
        self.controller_tool.release();
        self.heap.deinit();
        self.registry.deinit();
        self.gpa.free(self.ctx);
        self.arena.deinit();
        const budget = self.budget;
        const gpa = self.gpa;
        gpa.destroy(self);
        if (budget) |b| b.release();
    }
};

fn contains(grants: []const *const services.Operation, operation: *const services.Operation) bool {
    for (grants) |grant| if (grant == operation) return true;
    return false;
}
