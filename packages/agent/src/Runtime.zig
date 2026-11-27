const std = @import("std");
const Session = @import("Session.zig");
const j = @import("json.zig");
const api = @import("protocol.zig");
const types = @import("config.zig");
const port_types = @import("port.zig");
const Conversation = @import("Conversation.zig");
const Runtime = @This();

pub const ContextSnapshot = j.Document;
pub const HistoryQuery = Session.HistoryQuery;
pub const HistoryRecord = Session.HistoryRecord;

pub const Outcome = struct {
    document: j.Document,
    status: enum { completed, failed, cancelled },
    result: j.Value,
    diagnostic: j.Value,
    capabilities_revision: u64,

    fn init(document: j.Document) Outcome {
        const value = document.value;
        const status = j.text(j.get(value, "status"));
        return .{ .document = document, .status = if (std.mem.eql(u8, status, "completed")) .completed else if (std.mem.eql(u8, status, "cancelled")) .cancelled else .failed, .result = j.get(value, "result"), .diagnostic = j.get(value, "error"), .capabilities_revision = j.number(j.get(value, "capabilities_revision")) };
    }
    pub fn boundary(self: *const Outcome) ?@import("conversation.zig").Boundary {
        if (j.get(self.result, "continuation") != .string) return null;
        return .{ .continuation = j.text(j.get(self.result, "continuation")), .cause = if (std.mem.eql(u8, j.text(j.get(self.result, "cause")), "provider_overflow")) .provider_overflow else .ceiling, .context_tokens = j.number(j.get(self.result, "context_tokens")) };
    }
    pub fn text(self: *const Outcome) []const u8 {
        return j.text(j.get(self.result, "text"));
    }
    pub fn deinit(self: *Outcome) void {
        self.document.deinit();
        self.* = undefined;
    }
};

pub const Request = struct {
    gpa: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(2),
    id: []u8,
    kind: u32,
    payload: []u8,
    accepted: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    failure: ?anyerror = null,
    admission_failure: ?anyerror = null,
    outcome: ?j.Document = null,
    canonical: ?*Request = null,
    registered: ?*@import("vm").RegisteredTool = null,

    fn releaseRegistration(self: *Request) void {
        if (self.registered) |item| item.release();
        self.registered = null;
    }
    pub fn retain(self: *Request) *Request {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn wait(self: *Request, io: std.Io) !Outcome {
        try self.done.wait(io);
        if (self.failure) |err| return err;
        return Outcome.init(try self.outcome.?.clone(self.gpa));
    }
    pub fn deinit(self: *Request) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        if (self.registered) |item| item.release();
        if (self.outcome) |*outcome| outcome.deinit();
        self.gpa.free(self.id);
        self.gpa.free(self.payload);
        self.gpa.destroy(self);
    }
};

const Barrier = struct { done: std.Io.Event = .unset, disposition: u32 = api.CPI_AGENT_WAITING };
const StateRead = struct { allocator: std.mem.Allocator, namespace: []const u8 = "", extension_projection: ?Session.ExtensionProjection = null, application_cut: Session.ApplicationCut = .current, done: std.Io.Event = .unset, result: anyerror!j.Document = error.WorkerStopped };
const ExtensionVisit = struct { namespace: []const u8, visitor: Session.ExtensionVisitor, done: std.Io.Event = .unset, result: anyerror!void = error.WorkerStopped };
const InvocationJoin = struct { id: []const u8, done: std.Io.Event = .unset, result: anyerror!void = {} };
const ConversationRead = struct { allocator: std.mem.Allocator, done: std.Io.Event = .unset, result: anyerror!@import("conversation.zig").Snapshot = error.WorkerStopped };
const TranscriptRead = struct { allocator: std.mem.Allocator, context: []const u8, cut: ?u64, done: std.Io.Event = .unset, result: anyerror!j.Document = error.WorkerStopped };
const CapabilityPreparation = struct { id: []const u8, capability: types.Capability, done: std.Io.Event = .unset, result: anyerror!?*@import("vm").RegisteredTool = error.WorkerStopped };
const HistoryRead = struct { allocator: std.mem.Allocator, query: HistoryQuery, done: std.Io.Event = .unset, result: anyerror!?HistoryRecord = error.WorkerStopped };
const HistoryProject = struct { allocator: std.mem.Allocator, query: Session.HistoryProjection, done: std.Io.Event = .unset, result: anyerror!Session.HistoryPage = error.WorkerStopped };
const ApplicationForkRead = struct { allocator: std.mem.Allocator, conversation: []const u8, entry: []const u8, done: std.Io.Event = .unset, result: anyerror!Session.ApplicationFork = error.WorkerStopped };
const ApplicationBranchRead = struct { allocator: std.mem.Allocator, conversation: []const u8, leaf: ?[]const u8, done: std.Io.Event = .unset, result: anyerror!j.Document = error.WorkerStopped };
const ResidentJournalRead = struct { done: std.Io.Event = .unset, result: anyerror!?@import("PreparedJournal.zig") = error.WorkerStopped };
const ApplicationQuery = struct { allocator: std.mem.Allocator, scope: []const u8, input: j.Value, done: std.Io.Event = .unset, result: anyerror!j.Document = error.WorkerStopped };
const SessionWrite = struct { id: []const u8, actions: []const @import("session_protocol").frames.Action, extensions: []const Session.ExtensionWrite, done: std.Io.Event = .unset, result: anyerror!u64 = error.WorkerStopped };
const ProgressWrite = struct { operation: u64, progress: @import("services").ModelProgress, done: std.Io.Event = .unset, result: anyerror!void = error.WorkerStopped };
const Message = union(enum) { read_session: *StateRead, read_transcript: *TranscriptRead, read_extension: *StateRead, visit_extension: *ExtensionVisit, read_command: *StateRead, join_invocation: *InvocationJoin, record_session: *SessionWrite, model_progress: *ProgressWrite, prepare_capability: *CapabilityPreparation, submit: *Request, complete: *Job, barrier: *Barrier, read_context: *StateRead, read_state: *StateRead, read_conversation: *ConversationRead, read_history: *HistoryRead, project_history: *HistoryProject, plan_application_fork: *ApplicationForkRead, export_application_branch: *ApplicationBranchRead, prepare_resident_journal: *ResidentJournalRead, query_application: *ApplicationQuery, stop };
const Mailbox = @import("mailbox.zig").Mailbox(Message);
const Job = struct {
    runtime: *Runtime,
    completion: Mailbox.Node = .{},
    id: u64,
    method: @FieldType(port_types.Request, "method"),
    packet: []u8,
    request_id: []u8,
    durable_model: bool = false,
    wake: std.Io.Event = .unset,
    cancelled: std.atomic.Value(bool) = .init(false),
    response: ?types.AdapterResponse = null,
    failure: ?anyerror = null,

    fn execute(self: *Job) void {
        const runtime = self.runtime;
        self.response = runtime.port.exchange(runtime.port.context, runtime.gpa, runtime.io, .{ .request = .{
            .request_id = self.request_id,
            .operation_id = self.id,
            .method = self.method,
            .json = self.packet,
            .model_progress = if (self.durable_model) .{ .context = self, .write = writeProgress } else null,
        } }) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.wake.set(runtime.io);
    }
    fn writeProgress(raw: *anyopaque, progress: @import("services").ModelProgress) !void {
        const self: *Job = @ptrCast(@alignCast(raw));
        const runtime = self.runtime;
        var request: ProgressWrite = .{ .operation = self.id, .progress = progress };
        try runtime.mailbox.putOneUncancelable(runtime.io, .{ .model_progress = &request });
        request.done.waitUncancelable(runtime.io);
        return request.result;
    }
    fn own(self: *Job) void {
        const runtime = self.runtime;
        var future = runtime.io.concurrent(execute, .{self}) catch |err| {
            self.failure = err;
            runtime.mailbox.putBorrowed(runtime.io, &self.completion) catch {};
            return;
        };
        self.wake.waitUncancelable(runtime.io);
        if (self.cancelled.load(.acquire)) future.cancel(runtime.io) else future.await(runtime.io);
        runtime.mailbox.putBorrowed(runtime.io, &self.completion) catch {};
    }
};

gpa: std.mem.Allocator,
io: std.Io,
session: *Session,
port: port_types.Port,
mailbox: Mailbox,
stop_message: Mailbox.Node = .{ .value = .stop },
actor: ?std.Io.Future(void) = null,
operations: std.Io.Group = .init,
jobs: std.ArrayList(*Job) = .empty,
requests: std.ArrayList(*Request) = .empty,
startup: std.Io.Event = .unset,
startup_failure: ?anyerror = null,
activation: enum { ordinary, unpublished } = .ordinary,
publication: std.Io.Event = .unset,
abandoned: std.atomic.Value(bool) = .init(false),
disposition: u32 = api.CPI_AGENT_WAITING,

pub fn open(gpa: std.mem.Allocator, io: std.Io, config: types.Config, controller_port: port_types.Port) !*Runtime {
    return openConfigured(gpa, io, config, controller_port, null);
}

pub fn launch(gpa: std.mem.Allocator, io: std.Io, config: types.Config, controller_port: port_types.Port, startup: types.Startup) !*Runtime {
    return openConfigured(gpa, io, config, controller_port, startup);
}

fn openConfigured(gpa: std.mem.Allocator, io: std.Io, config: types.Config, controller_port: port_types.Port, startup: ?types.Startup) !*Runtime {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (config.application) |application| {
        if (application.source.len == 0) return error.LimitExceeded;
        _ = try j.parse(a, application.environment_json);
    }
    var options = try j.project(a, config.model);
    try j.put(a, &options, "limits", try j.project(a, config.limits));
    try j.put(a, &options, "recovery", try j.project(a, config.recovery));
    try j.put(a, &options, "application", try j.project(a, config.application));
    try j.put(a, &options, "endpoint_grants", try j.project(a, config.endpoint_grants));
    const path = if (config.persistence == .memory) "memory:" else config.journal_path;
    const prepared = if (startup) |plan| plan.prepared_journal else null;
    const session = try Session.initValue(gpa, io, config.session_id, config.workspace, path, options, j.array(a), config.context_journal, controller_port.journal_size_warnings, prepared);
    errdefer session.deinit();
    session.application_bindings = config.application_bindings;
    session.application_size_warnings = controller_port.application_size_warnings;
    var seed = j.array(a);
    for (if (session.journal.sequence == 0) config.capabilities else &.{}, 0..) |capability, capability_index| {
        if (capability.source.len == 0) return error.LimitExceeded;
        const registered = try session.heap.registerTool(capability.source);
        defer registered.release();
        if (startup != null) {
            const admit = controller_port.startup_command orelse return error.PermissionDenied;
            const hash = j.sourceHash(capability.source);
            try admit(controller_port.context, try std.fmt.allocPrint(a, "startup/seed/{d}/{s}", .{ capability_index, hash }), .{ .register_capability = capability }, registered);
        }
        try session.registered_capabilities.ensureUnusedCapacity(gpa, 1);
        session.registered_capabilities.appendAssumeCapacity(registered.retain());
        if (controller_port.validate_tool) |validate| try validate(controller_port.context, registered);
        const descriptor = try j.parse(a, registered.metadata());
        const name = j.text(j.get(descriptor, "name"));
        if (name.len == 0) return error.InvalidExtension;
        for (seed.array.items) |entry| if (std.mem.eql(u8, j.text(j.get(entry, "name")), name)) return error.DuplicateTool;
        const hash = j.sourceHash(capability.source);
        try seed.array.append(try j.project(a, .{ .name = name, .source = capability.source, .source_name = capability.source_name, .descriptor = descriptor, .source_hash = try a.dupe(u8, &hash) }));
    }
    const initial = try j.Document.initValue(gpa, seed);
    session.initial.deinit();
    session.initial = initial;
    if (startup) |plan| {
        try bootstrap(session, controller_port, plan);
        const runtime = try createRuntime(gpa, io, session, controller_port);
        runtime.activation = .unpublished;
        return runtime;
    }
    return startSession(gpa, io, session, controller_port);
}

fn bootstrap(session: *Session, controller_port: port_types.Port, plan: types.Startup) !void {
    const tracing = @import("kit").tracing;
    const scope = tracing.beginEvent("cpi.worker.bootstrap");
    defer tracing.endEvent(scope);
    var arena = std.heap.ArenaAllocator.init(session.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    session.bootstrap = true;
    if (controller_port.startup_check) |check| try check(controller_port.context);
    {
        const recover = tracing.beginEvent("cpi.worker.restore");
        defer tracing.endEvent(recover);
        _ = try session.run(1, 10000);
    }
    if (plan.catalog == .fixed) {
        const desired = plan.catalog.fixed;
        for (desired, 0..) |entry, index| {
            if (entry.name.len == 0 or entry.capability.source.len == 0) return error.InvalidArgument;
            for (desired[0..index]) |prior| if (std.mem.eql(u8, prior.name, entry.name)) return error.DuplicateTool;
        }
        var index: usize = 0;
        while (index < j.get(session.state.value, "capabilities").array.items.len) {
            const old = j.get(session.state.value, "capabilities").array.items[index];
            const name = try a.dupe(u8, j.text(j.get(old, "name")));
            var keep = false;
            for (desired) |entry| if (std.mem.eql(u8, entry.name, name)) {
                keep = true;
                break;
            };
            if (keep) {
                index += 1;
                continue;
            }
            const id = try std.fmt.allocPrint(a, "startup/remove/{d}/{s}", .{ j.number(j.get(session.state.value, "capabilities_revision")), name });
            try bootstrapCommand(session, controller_port, id, .{ .unregister_capability = name }, null, null);
        }
        for (desired) |entry| {
            const hash = j.sourceHash(entry.capability.source);
            var matches = false;
            for (j.get(session.state.value, "capabilities").array.items) |old| {
                if (std.mem.eql(u8, j.text(j.get(old, "name")), entry.name) and
                    std.mem.eql(u8, j.text(j.get(old, "source_name")), entry.capability.source_name) and
                    std.mem.eql(u8, j.text(j.get(old, "source")), entry.capability.source) and
                    std.mem.eql(u8, j.text(j.get(old, "source_hash")), &hash)) matches = true;
            }
            if (matches) continue;
            const revision = j.number(j.get(session.state.value, "capabilities_revision"));
            const id = try std.fmt.allocPrint(a, "startup/tool/{d}/{s}/{s}", .{ revision, entry.name, hash });
            const candidate = try session.heap.registerTool(entry.capability.source);
            defer candidate.release();
            const metadata = try j.parse(a, candidate.metadata());
            if (!std.mem.eql(u8, j.text(j.get(metadata, "name")), entry.name)) return error.InvalidExtension;
            try bootstrapCommand(session, controller_port, id, .{ .register_capability = entry.capability }, candidate, null);
        }
    }
    if (plan.initialize) |delivery| {
        const initialize = tracing.beginEvent("cpi.worker.initialize");
        defer tracing.endEvent(initialize);
        const id = plan.initialize_id orelse try std.fmt.allocPrint(a, "startup/initialize/{d}", .{session.sequence + 1});
        try bootstrapCommand(session, controller_port, id, .{ .deliver = delivery }, null, plan.failure_diagnostic);
    }
    if (controller_port.startup_check) |check| try check(controller_port.context);
    const durable = tracing.beginEvent("cpi.worker.commit_bootstrap");
    defer tracing.endEvent(durable);
    try session.commitBootstrap();
}

fn bootstrapCommand(session: *Session, controller_port: port_types.Port, id: []const u8, command: types.Command, candidate: ?*@import("vm").RegisteredTool, diagnostic: ?*?j.Document) !void {
    session.bootstrap_request = id;
    defer session.bootstrap_request = null;
    const admit = controller_port.startup_command orelse return error.PermissionDenied;
    try admit(controller_port.context, id, command, candidate);
    const payload = try encodeCommand(session.gpa, command);
    defer session.gpa.free(payload);
    try session.admitRegistered(id, @as(u32, @backingInt(command)) + 1, payload, candidate);
    if (session.command(id) == null) {
        if (try session.recordedCommand(session.gpa, id)) |saved| {
            var receipt = saved;
            defer receipt.deinit();
            if (std.mem.eql(u8, j.text(j.get(receipt.value, "status")), "completed")) return;
            if (diagnostic) |slot| {
                slot.* = try j.Document.initValue(session.gpa, j.get(j.get(receipt.value, "outcome"), "error"));
            }
            return error.ApplicationInitializationFailed;
        }
    }
    var steps: usize = 0;
    while (steps < 10000) : (steps += 1) {
        if (controller_port.startup_check) |check| try check(controller_port.context);
        _ = try session.run(8, 10000);
        if (session.failed) return session.first_failure orelse error.WorkerFailed;
        if (session.command(id)) |record| {
            const status = j.text(j.get(record, "status"));
            if (std.mem.eql(u8, status, "completed")) return;
            if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) {
                if (diagnostic) |slot| {
                    slot.* = try j.Document.initValue(session.gpa, j.get(j.get(record, "outcome"), "error"));
                }
                return error.ApplicationInitializationFailed;
            }
        }
    }
    return error.LimitExceeded;
}

pub fn openRaw(gpa: std.mem.Allocator, io: std.Io, id: []const u8, workspace: []const u8, path: []const u8, options: []const u8, seed: j.Value, controller_port: port_types.Port) !*Runtime {
    const session = try Session.initObserved(gpa, io, id, workspace, path, options, seed, controller_port.journal_size_warnings);
    errdefer session.deinit();
    session.application_size_warnings = controller_port.application_size_warnings;
    return startSession(gpa, io, session, controller_port);
}

fn startSession(gpa: std.mem.Allocator, io: std.Io, session: *Session, controller_port: port_types.Port) !*Runtime {
    const self = try createRuntime(gpa, io, session, controller_port);
    errdefer gpa.destroy(self);
    try self.activate();
    return self;
}

fn createRuntime(gpa: std.mem.Allocator, io: std.Io, session: *Session, controller_port: port_types.Port) !*Runtime {
    const self = try gpa.create(Runtime);
    self.* = .{ .gpa = gpa, .io = io, .session = session, .port = controller_port, .mailbox = undefined };
    self.mailbox = .init(gpa);
    return self;
}

pub fn activate(self: *Runtime) !void {
    self.actor = try self.io.concurrent(run, .{self});
    self.startup.waitUncancelable(self.io);
    if (self.startup_failure) |err| {
        self.mailbox.putBorrowed(self.io, &self.stop_message) catch {};
        self.actor.?.await(self.io);
        self.actor = null;
        self.operations.cancel(self.io);
        self.requests.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
        self.requests = .empty;
        self.jobs = .empty;
        return err;
    }
}

pub fn publish(self: *Runtime) void {
    self.publication.set(self.io);
}

pub fn prepareCapability(self: *Runtime, id: []const u8, capability: types.Capability) !?*@import("vm").RegisteredTool {
    var request: CapabilityPreparation = .{ .id = id, .capability = capability };
    try self.mailbox.putOneUncancelable(self.io, .{ .prepare_capability = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn submit(self: *Runtime, id: []const u8, command: types.Command) !*Request {
    return self.submitRegistered(id, command, null);
}

pub fn submitRegistered(self: *Runtime, id: []const u8, command: types.Command, registered: ?*@import("vm").RegisteredTool) !*Request {
    switch (command) {
        .unregister_capability => |name| if (name.len == 0) return error.InvalidArgument,
        .cancel_invocation => |target| if (target.len == 0 or !std.unicode.utf8ValidateSlice(target)) return error.InvalidArgument,
        .cancel, .close, .run, .compact, .branch, .import_conversation => {},
        else => {},
    }
    if (registered) |item| {
        if (command != .register_capability or !std.mem.eql(u8, item.source(), command.register_capability.source)) return error.InvalidExtension;
    }
    const payload = try encodeCommand(self.gpa, command);
    defer self.gpa.free(payload);
    return self.submitRawRegistered(id, @as(u32, @backingInt(command)) + 1, payload, registered);
}

pub fn encodeCommand(allocator: std.mem.Allocator, command: types.Command) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return j.encode(allocator, try commandValue(arena.allocator(), command));
}

/// Canonical command projection shared by admission and the serialized mailbox.
pub fn commandValue(a: std.mem.Allocator, command: types.Command) !j.Value {
    return switch (command) {
        .deliver => |delivery| blk: {
            var value = try j.project(a, delivery);
            if (std.mem.eql(u8, delivery.conversation orelse "main", "main")) _ = value.object.orderedRemove("conversation");
            if (delivery.application_model == null) _ = value.object.orderedRemove("application_model");
            break :blk value;
        },
        .cancel_invocation => |target| try j.project(a, .{ .replace = target }),
        .input => |text| try j.project(a, .{ .content = text }),
        .steer => |steer| try j.project(a, .{ .content = steer.content, .policy = @tagName(steer.policy) }),
        .lua => |source| try j.project(a, .{ .source = source }),
        .register_capability => |tool| try j.project(a, tool),
        .unregister_capability => |name| try j.project(a, .{ .name = name }),
        .run => |operation| try j.project(a, .{ .input = switch (operation.input) {
            .text => |t| @as(?[]const u8, t),
            else => null,
        }, .continuation = switch (operation.input) {
            .continuation => |t| @as(?[]const u8, t),
            else => null,
        }, .model = operation.model, .context_ceiling = operation.context_ceiling }),
        .compact => |compact| blk: {
            var parts = j.array(a);
            for (compact.parts) |part| try parts.array.append(switch (part) {
                .literal => |t| try j.project(a, .{ .literal = t }),
                .generate => |g| try j.project(a, .{ .generate = g }),
            });
            break :blk try j.project(a, .{ .expected_revision = compact.expected_revision, .first_kept = compact.first_kept, .parts = parts, .model = compact.model, .metadata = compact.metadata });
        },
        .branch => |branch| try j.project(a, branch),
        .import_conversation => |seed| blk: {
            var entries = j.array(a);
            for (seed.entries) |entry| {
                var value = try j.project(a, .{ .id = entry.id, .parent = entry.parent, .kind = @tagName(entry.kind), .text = entry.text, .summary = entry.text, .model = entry.model, .usage = entry.usage, .result = entry.result, .effects = entry.observations, .first_kept = entry.first_kept, .metadata = entry.metadata });
                if (entry.continuation) |capsule| try j.put(a, &value, "output", try j.parse(a, @import("provider_continuation.zig").material(capsule)));
                try entries.array.append(value);
            }
            break :blk try j.project(a, .{ .entries = entries, .head = seed.head });
        },
        .cancel, .close => j.object(),
    };
}

pub fn submitRaw(self: *Runtime, id: []const u8, kind: u32, payload: []const u8) !*Request {
    return self.submitRawRegistered(id, kind, payload, null);
}

fn submitRawRegistered(self: *Runtime, id: []const u8, kind: u32, payload: []const u8, registered: ?*@import("vm").RegisteredTool) !*Request {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidArgument;
    const request = try self.gpa.create(Request);
    errdefer self.gpa.destroy(request);
    const owned_id = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(owned_id);
    const bytes = try self.gpa.dupe(u8, payload);
    errdefer self.gpa.free(bytes);
    request.* = .{ .gpa = self.gpa, .id = owned_id, .kind = kind, .payload = bytes, .registered = if (registered) |item| item.retain() else null };
    errdefer request.releaseRegistration();
    try self.mailbox.putOne(self.io, .{ .submit = request });
    request.accepted.waitUncancelable(self.io);
    if (request.admission_failure) |err| return err;
    if (request.canonical) |existing| {
        request.deinit();
        return existing;
    }
    return request;
}

pub fn barrier(self: *Runtime) u32 {
    var value: Barrier = .{};
    self.mailbox.putOneUncancelable(self.io, .{ .barrier = &value }) catch return api.CPI_AGENT_FAILED;
    value.done.waitUncancelable(self.io);
    return value.disposition;
}

pub fn inspect(self: *Runtime, allocator: std.mem.Allocator) !j.Document {
    var request: StateRead = .{ .allocator = allocator };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_state = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn readContext(self: *Runtime, allocator: std.mem.Allocator) !ContextSnapshot {
    return self.readApplicationContext(allocator, @import("LuauContextJournal.zig").main);
}

pub fn readApplicationContext(self: *Runtime, allocator: std.mem.Allocator, scope: []const u8) !ContextSnapshot {
    return self.readApplicationContextAt(allocator, scope, .current);
}

pub fn readApplicationContextAt(self: *Runtime, allocator: std.mem.Allocator, scope: []const u8, cut: Session.ApplicationCut) !ContextSnapshot {
    var request: StateRead = .{ .allocator = allocator, .namespace = scope, .application_cut = cut };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_context = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

/// Returns an owned domain snapshot of the selected conversation path.
pub fn readConversation(self: *Runtime, allocator: std.mem.Allocator) !@import("conversation.zig").Snapshot {
    var request: ConversationRead = .{ .allocator = allocator };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_conversation = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

fn conversationSnapshot(self: *Runtime, allocator: std.mem.Allocator) !@import("conversation.zig").Snapshot {
    var document = try self.session.exportConversation(allocator);
    document.value = Conversation.snapshot(document.allocator(), document.value) catch |err| {
        document.deinit();
        return err;
    };
    return @import("conversation.zig").Snapshot.fromDocument(document);
}

pub fn readSession(self: *Runtime, allocator: std.mem.Allocator) !j.Document {
    var request: StateRead = .{ .allocator = allocator };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_session = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn readTranscript(self: *Runtime, allocator: std.mem.Allocator, context: []const u8, cut: ?u64) !j.Document {
    var request: TranscriptRead = .{ .allocator = allocator, .context = context, .cut = cut };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_transcript = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn readSessionExtension(self: *Runtime, allocator: std.mem.Allocator, namespace: []const u8, projection: ?Session.ExtensionProjection) !j.Document {
    var request: StateRead = .{ .allocator = allocator, .namespace = namespace, .extension_projection = projection };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_extension = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn visitSessionExtension(self: *Runtime, namespace: []const u8, visitor: Session.ExtensionVisitor) !void {
    var request: ExtensionVisit = .{ .namespace = namespace, .visitor = visitor };
    try self.mailbox.putOneUncancelable(self.io, .{ .visit_extension = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn readCommandReceipt(self: *Runtime, allocator: std.mem.Allocator, id: []const u8) !j.Document {
    var request: StateRead = .{ .allocator = allocator, .namespace = id };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_command = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn joinInvocation(self: *Runtime, id: []const u8) !void {
    var request: InvocationJoin = .{ .id = id };
    try self.mailbox.putOneUncancelable(self.io, .{ .join_invocation = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn recordSession(self: *Runtime, id: []const u8, actions: []const @import("session_protocol").frames.Action, extensions: []const Session.ExtensionWrite) !u64 {
    var request: SessionWrite = .{ .id = id, .actions = actions, .extensions = extensions };
    try self.mailbox.putOneUncancelable(self.io, .{ .record_session = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn readHistory(self: *Runtime, allocator: std.mem.Allocator, query: HistoryQuery) !?HistoryRecord {
    var request: HistoryRead = .{ .allocator = allocator, .query = query };
    try self.mailbox.putOneUncancelable(self.io, .{ .read_history = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn projectHistory(self: *Runtime, allocator: std.mem.Allocator, query: Session.HistoryProjection) !Session.HistoryPage {
    var request: HistoryProject = .{ .allocator = allocator, .query = query };
    try self.mailbox.putOneUncancelable(self.io, .{ .project_history = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn planApplicationFork(self: *Runtime, allocator: std.mem.Allocator, conversation: []const u8, entry: []const u8) !Session.ApplicationFork {
    var request: ApplicationForkRead = .{ .allocator = allocator, .conversation = conversation, .entry = entry };
    try self.mailbox.putOneUncancelable(self.io, .{ .plan_application_fork = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn exportApplicationBranch(self: *Runtime, allocator: std.mem.Allocator, conversation: []const u8, leaf: ?[]const u8) !j.Document {
    var request: ApplicationBranchRead = .{ .allocator = allocator, .conversation = conversation, .leaf = leaf };
    try self.mailbox.putOneUncancelable(self.io, .{ .export_application_branch = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn prepareResidentJournal(self: *Runtime) !?@import("PreparedJournal.zig") {
    var request: ResidentJournalRead = .{};
    try self.mailbox.putOneUncancelable(self.io, .{ .prepare_resident_journal = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn queryApplication(self: *Runtime, allocator: std.mem.Allocator, scope: []const u8, input: j.Value) !j.Document {
    var request: ApplicationQuery = .{ .allocator = allocator, .scope = scope, .input = input };
    try self.mailbox.putOneUncancelable(self.io, .{ .query_application = &request });
    request.done.waitUncancelable(self.io);
    return request.result;
}

pub fn destroy(self: *Runtime) void {
    if (self.actor) |*actor| {
        self.abandoned.store(true, .release);
        self.publication.set(self.io);
        self.mailbox.putBorrowed(self.io, &self.stop_message) catch {};
        actor.await(self.io);
    }
    self.operations.cancel(self.io);
    for (self.jobs.items) |job| self.freeJob(job);
    self.jobs.deinit(self.gpa);
    self.requests.deinit(self.gpa);
    self.mailbox.deinit();
    self.session.deinit();
    self.gpa.destroy(self);
}

fn freeJob(self: *Runtime, job: *Job) void {
    if (job.response) |response| self.gpa.free(response.json);
    self.gpa.free(job.packet);
    self.gpa.free(job.request_id);
    self.gpa.destroy(job);
}

fn tick(self: *Runtime) void {
    self.disposition = self.session.run(8, 100) catch |err| blk: {
        if (!self.startup.isSet()) self.startup_failure = err;
        self.session.fault(err);
        break :blk api.CPI_AGENT_FAILED;
    };
    self.settleFailure();
    self.drain() catch |err| {
        self.session.fault(err);
        self.disposition = api.CPI_AGENT_FAILED;
    };
    self.settleFailure();
}

fn settleFailure(self: *Runtime) void {
    if (self.session.failed) {
        for (self.session.events.items) |event| {
            if (event.value.kind == api.CPI_AGENT_EVENT_COMMAND_FINISHED) self.settleFinished(event.value.request_id, event.value.json);
        }
        for (self.jobs.items) |job| {
            job.cancelled.store(true, .release);
            job.wake.set(self.io);
        }
        for (self.requests.items) |request| {
            request.failure = self.session.first_failure orelse error.WorkerFailed;
            request.releaseRegistration();
            request.done.set(self.io);
            request.deinit();
        }
        self.requests.clearRetainingCapacity();
    }
}

fn prepareRegistration(self: *Runtime, id: []const u8, capability: types.Capability) !?*@import("vm").RegisteredTool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try commandValue(a, .{ .register_capability = capability });
    for (self.requests.items) |request| {
        if (!std.mem.eql(u8, request.id, id)) continue;
        if (request.kind != 6 or !(try j.equal(a, try j.parse(a, request.payload), payload))) return error.RequestConflict;
        if (request.registered) |registered| return registered.retain();
    }
    if (self.session.command(id)) |command| {
        if (j.number(j.get(command, "kind")) != 6 or !(try j.equal(a, j.get(command, "payload"), payload))) return error.RequestConflict;
        for (self.session.pending_capabilities.items) |pending| if (std.mem.eql(u8, pending.id, id)) return pending.capability.retain();
        for (self.session.registered_capabilities.items) |registered| {
            if (std.mem.eql(u8, registered.source(), capability.source)) return registered.retain();
        }
    }
    if (try self.session.recordedCommand(self.gpa, id)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        if (j.number(j.get(receipt.value, "kind")) != 6 or !(try j.equal(a, j.get(receipt.value, "payload"), payload))) return error.RequestConflict;
        for (self.session.registered_capabilities.items) |registered| if (std.mem.eql(u8, registered.source(), capability.source)) return registered.retain();
        return null;
    }
    return self.session.heap.registerTool(capability.source);
}

fn run(self: *Runtime) void {
    if (self.activation == .unpublished) {
        self.startup.set(self.io);
        self.publication.waitUncancelable(self.io);
        if (self.abandoned.load(.acquire)) return;
    }
    self.tick();
    if (self.session.failed and self.startup_failure == null) self.startup_failure = self.session.first_failure orelse error.WorkerFailed;
    self.startup.set(self.io);
    var stopping = false;
    var joins: std.ArrayList(*InvocationJoin) = .empty;
    defer {
        for (joins.items) |join| {
            join.result = error.WorkerStopped;
            join.done.set(self.io);
        }
        joins.deinit(self.gpa);
    }
    while (true) {
        var messages: [1]Message = undefined;
        const count = self.mailbox.getUncancelable(self.io, &messages, if (self.disposition == api.CPI_AGENT_RUNNABLE and !stopping) 0 else 1) catch break;
        if (count != 0) switch (messages[0]) {
            .prepare_capability => |value| {
                value.result = if (stopping) error.WorkerStopped else self.prepareRegistration(value.id, value.capability);
                value.done.set(self.io);
            },
            .stop => {
                stopping = true;
                for (self.jobs.items) |job| {
                    job.cancelled.store(true, .release);
                    job.wake.set(self.io);
                }
                for (self.requests.items) |request| {
                    request.failure = error.WorkerStopped;
                    request.releaseRegistration();
                    request.done.set(self.io);
                    request.deinit();
                }
                self.requests.clearRetainingCapacity();
            },
            .submit => |request| {
                const result: anyerror!void = if (stopping) error.InvalidState else blk: {
                    for (self.requests.items) |existing| {
                        if (!std.mem.eql(u8, existing.id, request.id)) continue;
                        self.session.admitRegistered(request.id, request.kind, request.payload, request.registered) catch |err| break :blk err;
                        _ = existing.references.fetchAdd(1, .monotonic);
                        request.canonical = existing;
                        request.deinit();
                        break :blk;
                    }
                    self.requests.ensureUnusedCapacity(self.gpa, 1) catch |err| break :blk err;
                    self.session.admitRegistered(request.id, request.kind, request.payload, request.registered) catch |err| break :blk err;
                    self.requests.appendAssumeCapacity(request);
                };
                result catch |err| {
                    request.admission_failure = err;
                    request.deinit();
                };
                request.accepted.set(self.io);
            },
            .barrier => |value| {
                if (!stopping) self.tick();
                value.disposition = self.disposition;
                value.done.set(self.io);
            },
            .read_session => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.sessionSnapshot(value.allocator);
                value.done.set(self.io);
            },
            .read_transcript => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.transcriptSnapshot(value.allocator, value.context, value.cut);
                value.done.set(self.io);
            },
            .read_extension => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.extensionSnapshot(value.allocator, value.namespace, value.extension_projection);
                value.done.set(self.io);
            },
            .visit_extension => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.visitExtension(value.namespace, value.visitor);
                value.done.set(self.io);
            },
            .read_command => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.commandReceipt(value.allocator, value.namespace);
                value.done.set(self.io);
            },
            .join_invocation => |value| {
                if (!self.hasInvocationJobs(value.id)) {
                    value.done.set(self.io);
                } else joins.append(self.gpa, value) catch |err| {
                    value.result = err;
                    value.done.set(self.io);
                };
            },
            .record_session => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.recordSessionWithExtensions(value.id, value.actions, value.extensions);
                value.done.set(self.io);
            },
            .model_progress => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.recordModelProgress(value.operation, value.progress);
                value.done.set(self.io);
            },
            .read_state => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.exportState(value.allocator);
                value.done.set(self.io);
            },
            .read_context => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.readApplicationContext(value.allocator, value.namespace, value.application_cut);
                value.done.set(self.io);
            },
            .read_conversation => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.conversationSnapshot(value.allocator);
                value.done.set(self.io);
            },
            .read_history => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.readHistory(value.allocator, value.query);
                value.done.set(self.io);
            },
            .project_history => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.projectHistory(value.allocator, value.query);
                value.done.set(self.io);
            },
            .plan_application_fork => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.planApplicationFork(value.allocator, value.conversation, value.entry);
                value.done.set(self.io);
            },
            .export_application_branch => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.exportApplicationBranch(value.allocator, value.conversation, value.leaf);
                value.done.set(self.io);
            },
            .prepare_resident_journal => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.prepareResidentJournal();
                value.done.set(self.io);
            },
            .query_application => |value| {
                value.result = if (stopping) error.WorkerStopped else if (self.session.failed) self.session.first_failure orelse error.WorkerFailed else self.session.queryApplication(value.allocator, value.scope, value.input);
                value.done.set(self.io);
            },
            .complete => |job| {
                for (self.jobs.items, 0..) |entry, index| if (entry == job) {
                    _ = self.jobs.swapRemove(index);
                    break;
                };
                if (!self.session.failed) {
                    const diagnostic: ?[]u8 = if (job.response == null) j.encode(self.gpa, .{
                        .code = @errorName(job.failure orelse error.UnsupportedEffect),
                        .message = @errorName(job.failure orelse error.UnsupportedEffect),
                    }) catch |err| blk: {
                        self.session.fault(err);
                        break :blk null;
                    } else null;
                    defer if (diagnostic) |bytes| self.gpa.free(bytes);
                    const bytes = if (job.response) |response| response.json else diagnostic orelse "";
                    const kind: u32 = if (job.cancelled.load(.acquire) and job.response == null) api.CPI_AGENT_IO_CANCELLED else if (job.failure != null or (job.response != null and job.response.?.failed)) api.CPI_AGENT_IO_ERROR else api.CPI_AGENT_IO_DONE;
                    if (!self.session.failed) {
                        const late = self.session.feedLate(job.id, kind, bytes) catch |err| blk: {
                            self.session.fault(err);
                            break :blk true;
                        };
                        if (!late and !stopping) self.session.feed(job.id, kind, bytes) catch |err| self.session.fault(err);
                    }
                }
                var i: usize = 0;
                while (i < joins.items.len) {
                    const join = joins.items[i];
                    if (!std.mem.eql(u8, job.request_id, join.id) or self.hasInvocationJobs(join.id)) {
                        i += 1;
                        continue;
                    }
                    _ = joins.swapRemove(i);
                    join.done.set(self.io);
                }
                self.freeJob(job);
            },
        };
        if (stopping) {
            if (self.jobs.items.len == 0) break;
        } else self.tick();
    }
}

fn hasInvocationJobs(self: *const Runtime, id: []const u8) bool {
    for (self.jobs.items) |job| {
        if (std.mem.eql(u8, job.request_id, id)) return true;
    }
    return false;
}

fn settleFinished(self: *Runtime, id: []const u8, json: []const u8) void {
    var index: usize = 0;
    while (index < self.requests.items.len) {
        const request = self.requests.items[index];
        if (!std.mem.eql(u8, request.id, id)) {
            index += 1;
            continue;
        }
        request.outcome = j.Document.init(self.gpa, json) catch |err| blk: {
            request.failure = err;
            break :blk null;
        };
        request.releaseRegistration();
        request.done.set(self.io);
        _ = self.requests.swapRemove(index);
        request.deinit();
    }
}

fn drain(self: *Runtime) !void {
    while (self.session.events.items.len > 0) {
        const event = self.session.events.orderedRemove(0);
        defer event.deinit(self.gpa);
        self.session.event_bytes -= event.bytes;
        const value = event.value;
        if (value.kind == api.CPI_AGENT_EVENT_IO_REQUEST) {
            try self.jobs.ensureUnusedCapacity(self.gpa, 1);
            const job = try self.gpa.create(Job);
            errdefer self.gpa.destroy(job);
            const packet = try self.gpa.dupe(u8, value.json);
            errdefer self.gpa.free(packet);
            const request_id = try self.gpa.dupe(u8, value.request_id);
            errdefer self.gpa.free(request_id);
            job.* = .{ .runtime = self, .id = value.operation_id, .packet = packet, .request_id = request_id, .method = if (std.mem.eql(u8, value.method, "http.request")) .model else .host };
            if (j.flag(j.get(j.get(self.session.options.value, "recovery"), "model_progress"))) {
                for (self.session.operations.items) |operation| {
                    if (operation.id == job.id) {
                        job.durable_model = operation.semantic_model != null;
                        break;
                    }
                }
            }
            job.completion.value = .{ .complete = job };
            try self.operations.concurrent(self.io, Job.own, .{job});
            self.jobs.appendAssumeCapacity(job);
            continue;
        }
        if (value.kind == api.CPI_AGENT_EVENT_IO_CANCEL) {
            for (self.jobs.items) |job| if (job.id == value.operation_id) {
                job.cancelled.store(true, .release);
                job.wake.set(self.io);
            };
            continue;
        }
        if (value.kind == api.CPI_AGENT_EVENT_COMMAND_FINISHED) {
            self.settleFinished(value.request_id, value.json);
        }
        if (try self.port.exchange(self.port.context, self.gpa, self.io, .{ .notice = .{ .kind = @fromBackingInt(@intCast(value.kind)), .sequence = value.sequence, .request_id = value.request_id, .json = value.json } })) |response| self.gpa.free(response.json);
    }
}
