const std = @import("std");
const json_text = @import("session_protocol").json.text;
const agent = @import("agent");
const services = @import("services");
const provider = agent.provider;
const Context = @import("ContextStore.zig");
const j = services.json;
const Value = j.Value;
const Self = @This();

pub const Seed = struct { role: []const u8, content: []const u8 };
pub const Definition = struct {
    name: []const u8,
    source: []const u8,
    terminal: bool = false,
    spawn: bool = false,
    spawnable: bool = false,
    protected_ids: []const u64 = &.{},
    initial_context: []const Seed = &.{},
};
pub const ReadGrant = Read;
pub const Principal = struct {
    controller: *Self,
    gateway: *agent.Controller,
    process: services.Process,
    id: u64,
    parent: ?u64,
    definition: *const Definition,
    worker: agent.WorkerId,
    context: Context,
    input: []const u8,
    grant: ?ReadGrant,
    cause: ?u64,
    request: ?*agent.Request = null,
    trigger: ?u64 = null,
    last_tokens: u64 = 0,
    calls: u64 = 0,
    terminal_id: ?[]const u8 = null,
    stopped: std.atomic.Value(bool) = .init(false),
    closure_scheduled: std.atomic.Value(bool) = .init(false),
    closed: std.Io.Event = .unset,
};
pub const Settings = struct {
    directory: []const u8,
    workspace: []const u8,
    model: union(enum) { fixture: []const u8, live: *const provider.Provider },
    ghostmux: []const u8,
    ghostmux_socket: []const u8,
    ghostmux_router: []const u8,
    definitions: []const Definition,
    policy_source: []const u8,
    context_window: u64 = 8192,
    reserve_tokens: u64 = 300,
    max_output_tokens: u64 = 4096,
    reasoning_effort: ?[]const u8 = null,
    max_model_calls: ?u64 = null,
};

gpa: std.mem.Allocator,
io: std.Io,
settings: Settings,
authorization: []const u8,
serial: std.atomic.Value(u64) = .init(0),
model_calls: std.atomic.Value(u64) = .init(0),
mutex: std.Io.Mutex = .init,
start_mutex: std.Io.Mutex = .init,
trace_mutex: std.Io.Mutex = .init,
trace: std.Io.File,
trace_offset: u64 = 0,
principals: std.ArrayList(*Principal) = .empty,
snapshots: std.ArrayList(Context.Snapshot) = .empty,
environment: std.process.Environ.Map,
closure_tasks: std.Io.Group = .init,
stopping: std.atomic.Value(bool) = .init(false),

pub fn open(gpa: std.mem.Allocator, io: std.Io, settings: Settings) !*Self {
    var temporary = std.heap.ArenaAllocator.init(gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    const trace = try std.Io.Dir.cwd().createFile(io, try std.fs.path.join(a, &.{ settings.directory, "broker.jsonl" }), .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer trace.close(io);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .settings = settings,
        .authorization = undefined,
        .trace = trace,
        .trace_offset = (try trace.stat(io)).size,
        .environment = .init(gpa),
    };
    errdefer self.environment.deinit();
    try self.environment.put("PATH", "/usr/bin:/bin");
    try self.environment.put("HOME", settings.directory);
    try self.environment.put("TERM", "xterm-256color");
    try self.environment.put("PS1", "prototype> ");
    try self.environment.put("CPI2_GHOSTMUX_BIN", settings.ghostmux);
    try self.environment.put("CPI2_GHOSTMUX_SOCKET", settings.ghostmux_socket);
    self.authorization = try std.fmt.allocPrint(gpa, "{s}\nlocal applicationPolicy=function(packet)\n{s}\nend\n{s}", .{
        @embedFile("guest/authorize_metadata.luau"), settings.policy_source, @embedFile("guest/authorize.luau"),
    });
    return self;
}

fn model(self: *Self) agent.Model {
    return switch (self.settings.model) {
        .fixture => |url| .{ .base_url = url, .model = "fixture" },
        .live => |live| live.modelConfig(""),
    };
}

fn capability(a: std.mem.Allocator, operation: *const services.Operation) !agent.Capability {
    const name = try a.dupe(u8, operation.name);
    for (name) |*byte| if (byte.* == '.') {
        byte.* = '_';
    };
    const recovery = switch (operation.recovery) {
        .read_only => "retry_safe",
        .receipt => "reconcile",
        .never => "never",
    };
    return .{ .source_name = try std.fmt.allocPrint(a, "{s}.luau", .{name}), .source = try std.fmt.allocPrint(a, "return {{name='{s}',version=1,description='{s}',parameters={{type='object'}},endpoints={{'{s}'}},recovery='{s}',execute=function(args) return host.call('{s}',args) end}}", .{ name, operation.name, operation.name, recovery, operation.name }) };
}

pub fn start(self: *Self, name: []const u8, input: Value, parent: ?u64, grant: ?ReadGrant) !*Principal {
    try self.start_mutex.lock(self.io);
    defer self.start_mutex.unlock(self.io);
    if (self.stopping.load(.acquire)) return error.ControllerStopping;
    var definition: ?*const Definition = null;
    for (self.settings.definitions) |*item| if (std.mem.eql(u8, item.name, name)) {
        definition = item;
        break;
    };
    const def = definition orelse return error.UnknownProgram;
    self.mutex.lockUncancelable(self.io);
    const id: u64 = self.principals.items.len + 1;
    const parent_p = if (parent) |pid| self.findPrincipalLocked(pid) else null;
    self.mutex.unlock(self.io);
    if (id > 32) return error.WorkerLimit;
    if (parent_p) |q| if (q.stopped.load(.acquire)) return error.ParentStopped;
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    const p = try self.gpa.create(Principal);
    errdefer self.gpa.destroy(p);
    p.* = .{ .controller = self, .gateway = undefined, .process = undefined, .id = id, .parent = parent, .definition = def, .worker = undefined, .context = undefined, .input = try j.encode(self.gpa, input), .grant = grant, .cause = if (parent_p) |q| q.trigger orelse q.cause else null };
    errdefer self.gpa.free(p.input);
    p.process = .{ .workspace = self.settings.workspace, .directory = try std.fmt.allocPrint(self.gpa, "{s}/processes/worker-{d}", .{ self.settings.directory, p.id }), .binary = self.settings.ghostmux_router, .environment = &self.environment };
    errdefer self.gpa.free(p.process.directory);
    const transport = switch (self.settings.model) {
        .fixture => |url| try provider.Effects.initFixture(a, self.settings.workspace, url),
        .live => |live| provider.Effects.initLive(self.settings.workspace, live),
    };
    const configured_model = self.model();
    p.gateway = try agent.Controller.open(self.gpa, self.io, .{
        .authorize = self.authorization,
        .services = &.{ self.service(p), p.process.service() },
        .host_session_access = true,
        .providers = &.{.{ .base_url = configured_model.base_url, .credential = configured_model.credential, .transport = transport }},
        .program_grants = if (def.terminal) &.{ "model.request", "process.spawn" } else &.{"model.request"},
        .sink = .{ .context = p, .emit = event },
    });
    errdefer p.gateway.close();
    var capabilities: std.ArrayList(agent.Capability) = .empty;
    var grants: std.ArrayList([]const u8) = .empty;
    for (self.service(p).operations) |operation| {
        try capabilities.append(a, try capability(a, operation));
        try grants.append(a, operation.name);
    }
    for (p.process.service().operations) |operation| {
        if (!def.terminal or std.mem.eql(u8, operation.name, "process.spawn") or std.mem.eql(u8, operation.name, "process.repeat") or std.mem.eql(u8, operation.name, "process.detach") or std.mem.eql(u8, operation.name, "process.list") or std.mem.eql(u8, operation.name, "process.wait")) continue;
        try capabilities.append(a, try capability(a, operation));
        try grants.append(a, operation.name);
    }
    const namespace = j.hash(self.settings.directory);
    const catalog = try a.alloc(agent.CatalogCapability, capabilities.items.len);
    for (capabilities.items, catalog) |entry, *item| item.* = .{ .name = entry.source_name[0 .. entry.source_name.len - ".luau".len], .capability = entry };
    p.worker = try p.gateway.launch(.{
        .context_journal = .{
            .namespace = @import("ContextJournal.zig").namespace,
            .action = @import("ContextJournal.zig").action,
            .contract = @import("ContextJournal.zig").contract,
            .capture = @import("ContextJournal.zig").capture,
            .materialize = @import("ContextJournal.zig").materialize,
            .extra_contracts = &.{@import("ContextJournal.zig").binding_contract},
            .extra_renderers = &.{@import("ContextJournal.zig").renderer},
        },
        .session_id = try std.fmt.allocPrint(a, "terminus-{s}-worker-{d}", .{ namespace[0..16], id }),
        .journal_path = try std.fmt.allocPrint(a, "{s}/worker-{d}.guest.gz", .{ self.settings.directory, id }),
        .workspace = self.settings.workspace,
        .model = self.model(),
        .capabilities = capabilities.items,
        .endpoint_grants = grants.items,
        .limits = .{ .max_rounds = self.settings.max_model_calls },
    }, .{ .catalog = .{ .fixed = catalog } });
    p.context = Context.init(self.gpa, self.io, id, p.gateway, p.worker);
    const binding = j.hash(try j.encode(a, .{ .program = def.name, .source = j.hash(def.source), .input = input, .terminal = def.terminal, .spawn = def.spawn, .protected = def.protected_ids, .parent = parent, .seed = def.initial_context }));
    try p.context.bind(a, &binding, try j.value(a, def.initial_context));

    var snapshot_owners: Value = .{ .object = .empty };
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.snapshots.items) |snap| try j.put(a, &snapshot_owners, try std.fmt.allocPrint(a, "{d}", .{snap.id}), try j.value(a, .{ .owner = snap.owner }));
    }
    _ = try self.program(p, a, "ctx.principals=ctx.principals or {}; ctx.principals[tostring(input.worker)]=input.caller; ctx.snapshots=input.snapshots; return true", try j.value(a, .{
        .worker = p.worker.index,
        .snapshots = snapshot_owners,
        .caller = .{ .id = p.id, .parent = p.parent, .terminal = def.terminal, .spawn = def.spawn, .application = false, .cause = p.cause, .grant = grant },
    }));
    self.mutex.lockUncancelable(self.io);
    self.principals.append(self.gpa, p) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    errdefer {
        self.mutex.lockUncancelable(self.io);
        _ = self.principals.pop();
        self.mutex.unlock(self.io);
    }
    if (parent_p) |q| _ = try self.program(q, a, "ctx.children=ctx.children or {}; ctx.children[tostring(input.child)]=input.parent; return true", try j.value(a, .{ .child = p.id, .parent = q.id }));
    p.request = try p.gateway.submit(p.worker, "run", .{ .lua = def.source });
    return p;
}

fn findPrincipalLocked(self: *Self, id: u64) ?*Principal {
    if (id == 0 or id > self.principals.items.len) return null;
    return self.principals.items[@intCast(id - 1)];
}
fn principal(self: *Self, id: u64) !*Principal {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return self.findPrincipalLocked(id) orelse error.UnknownWorker;
}
fn caller(self: *Self, c: services.Context) !*Principal {
    try self.mutex.lock(c.io);
    defer self.mutex.unlock(c.io);
    for (self.principals.items) |p| if (p.id == c.principal) {
        if (self.stopping.load(.acquire) or p.stopped.load(.acquire)) return error.ControllerStopping;
        return p;
    };
    return error.UnknownWorker;
}
fn snapshot(self: *Self, id: u64) !Context.Snapshot {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    if (id == 0 or id > self.snapshots.items.len) return error.UnknownSnapshot;
    return self.snapshots.items[@intCast(id - 1)];
}
pub fn join(self: *Self, p: *Principal) !agent.Outcome {
    return p.request.?.wait(self.io);
}
pub fn cancel(self: *Self, p: *Principal) !void {
    p.stopped.store(true, .release);
    if (p.closure_scheduled.swap(true, .acq_rel)) return;
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    if (p.gateway.submit(p.worker, "controller-cancel", .cancel)) |request| {
        request.deinit();
    } else |_| {}
    self.closure_tasks.concurrent(self.io, closePrincipal, .{ self, p }) catch |err| {
        p.closure_scheduled.store(false, .release);
        return err;
    };
}
fn closePrincipal(self: *Self, p: *Principal) void {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    defer p.closed.set(self.io);
    if (p.gateway.submit(p.worker, "controller-cancel", .cancel)) |request| {
        defer request.deinit();
        if (request.wait(self.io)) |value| {
            var outcome = value;
            outcome.deinit();
        } else |_| {}
    } else |_| {}
    p.context.freeze() catch |err| {
        p.context.closed_failure = err;
    };
    p.gateway.close();
    var children: [32]*Principal = undefined;
    var count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    for (self.principals.items) |child| if (child.parent == p.id) {
        children[count] = child;
        count += 1;
    };
    self.mutex.unlock(self.io);
    for (children[0..count]) |child| self.cancel(child) catch {};
}
pub fn deinit(self: *Self) void {
    const io = self.io;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    self.stopping.store(true, .release);
    var active: [32]*Principal = undefined;
    self.mutex.lockUncancelable(self.io);
    const count = self.principals.items.len;
    @memcpy(active[0..count], self.principals.items);
    self.mutex.unlock(self.io);
    for (active[0..count]) |p| self.cancel(p) catch {};
    self.start_mutex.lockUncancelable(self.io);
    self.start_mutex.unlock(self.io);
    for (self.principals.items) |p| self.cancel(p) catch {};
    self.closure_tasks.await(self.io) catch unreachable;
    for (self.principals.items) |p| if (!p.closure_scheduled.swap(true, .acq_rel)) {
        self.closePrincipal(p);
    };
    self.closure_tasks.await(self.io) catch unreachable;
    for (self.principals.items) |p| self.cleanupProcesses(p) catch {};
    for (self.principals.items) |p| {
        if (p.request) |request| request.deinit();
        p.context.deinit();
        self.gpa.free(p.process.directory);
        self.gpa.free(p.input);
        if (p.grant) |grant| self.gpa.free(grant.ids);
        if (p.terminal_id) |id| self.gpa.free(id);
        self.gpa.destroy(p);
    }
    for (self.snapshots.items) |snap| self.gpa.free(snap.bytes);
    self.principals.deinit(self.gpa);
    self.snapshots.deinit(self.gpa);
    self.trace.close(self.io);
    self.environment.deinit();
    self.gpa.free(self.authorization);
    self.gpa.destroy(self);
}
fn cleanupProcesses(self: *Self, p: *Principal) !void {
    const cleanup = try agent.Controller.open(self.gpa, self.io, .{
        .authorize = "return function(event,state) return {allow=event.principal==0 and (event.operation=='process.list' or event.operation=='process.signal' or event.operation=='process.wait')} end",
        .services = &.{p.process.service()},
        .program_grants = &.{ "process.list", "process.signal", "process.wait" },
    });
    defer cleanup.close();
    const request = try cleanup.program("release-terminals", "local jobs=host.call('process.list',{include_completed=true}); for _, job in ipairs(jobs.jobs) do pcall(function() host.call('process.signal',{id=job.id,signal='SIGKILL'}) end); pcall(function() host.call('process.wait',{id=job.id,wait_ms=3000}) end) end; return true", .null);
    defer request.deinit();
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
}
fn program(self: *Self, p: *Principal, a: std.mem.Allocator, source: []const u8, input: Value) !Value {
    const request = try p.gateway.program(try std.fmt.allocPrint(a, "terminus/{d}", .{self.serial.fetchAdd(1, .monotonic)}), source, input);
    defer request.deinit();
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    if (outcome.status != .completed) return error.ControllerProgramFailed;
    return j.copy(a, outcome.result);
}
fn record(self: *Self, a: std.mem.Allocator, item: anytype) !void {
    const bytes = try std.fmt.allocPrint(a, "{s}\n", .{try j.encode(a, item)});
    try self.trace_mutex.lock(self.io);
    defer self.trace_mutex.unlock(self.io);
    try self.trace.writePositionalAll(self.io, bytes, self.trace_offset);
    self.trace_offset += bytes.len;
    try self.trace.sync(self.io);
}
fn event(raw: ?*anyopaque, value: agent.ControllerEvent) !void {
    const p: *Principal = @ptrCast(@alignCast(raw.?));
    const self = p.controller;
    if (value != .audit) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const audit = value.audit;
    const admitted = std.mem.eql(u8, audit.disposition, "admitted");
    const denied = std.mem.eql(u8, audit.disposition, "denied") or std.mem.eql(u8, audit.disposition, "invalid_policy");
    var entry = .{ .event = @as([]const u8, if (admitted or denied) "policy" else audit.disposition), .caller = p.id, .controller_scope = audit.scope, .controller_principal = audit.principal, .operation = audit.operation, .allow = std.mem.eql(u8, audit.policy_decision, "allow"), .policy_decision = audit.policy_decision, .disposition = audit.disposition, .request_id = audit.request_id, .effect_id = audit.effect_id, .effect_key_sha256 = audit.effect_key_sha256, .arguments_sha256 = audit.arguments_sha256, .error_code = audit.error_code, .execution_attempted = audit.execution_attempted };
    try self.record(arena.allocator(), entry);
    if (admitted) {
        entry.event = "started";
        try self.record(arena.allocator(), entry);
    }
}

const Empty = struct {};
const Now = struct { ms: i64 };
const Sleep = struct { ms: u32 = 0 };
const Slept = struct { slept_ms: u32 };
const Append = struct { messages: []const Message };
const Text = struct { text: []const u8 };
const Read = struct { snapshot: u64, ids: []const u64 };
const Info = struct { context_window: u64, max_output_tokens: u64, estimator: []const u8 };
const Finished = struct { finished: bool };
const Child = struct { child: u64 };
const Prompt = struct { prompt: []const u8 = "" };
const GeneratePrompt = struct { prompt: []const u8 };
const Message = struct { role: []const u8, content: []const u8 };
const Record = struct { id: u64, role: []const u8, content: []const u8, kind: []const u8, origin_worker: u64, source_snapshot: ?u64 = null };
const State = struct { history: []const Record, view: []const u64, version: u64, next_id: u64 };
const Revision = struct { version: u64 };
const Captured = struct { version: u64, groups: []const Record };
const SnapshotResult = struct { id: u64, owner: u64, data: Captured };
const Commit = struct { snapshot: u64, selected: []const u64, replacement: []const Message, target_session: ?u64 = null, after: ?u64 = null };
const Spawn = struct {
    program: []const u8,
    input: Value = .null,
    snapshot: ?u64 = null,
    ids: ?[]const u64 = null,
    pub fn validate(self: Spawn) !void {
        if (self.snapshot != null and self.ids == null) return error.InvalidArguments;
    }
};
const Generated = struct { ok: bool, text: ?[]const u8 = null, @"error": ?[]const u8 = null, raw: Value = .null, usage: Value = .null, finish_reason: ?[]const u8 = null };
const Prepared = struct { kind: []const u8, tokens: u64, job: ?u64 = null };
const Job = struct { job: u64 };
const Trigger = struct { job: u64, coalesced: bool };
const Parsed = struct { ok: bool, value: Value = .null, types: Value = .null, @"error": ?[]const u8 = null };
const Waited = struct { status: []const u8, result: Value, @"error": Value, child: u64 };
const bounds: services.Operation.Limits = .{ .arguments = 2 * 1024 * 1024, .result = 4 * 1024 * 1024 };
const operations = [_]services.Operation{
    declare("session.input", Empty, Value, bounds, .read_only, sessionInput),
    declare("clock.now", Empty, Now, bounds, .read_only, clockNow),
    declare("clock.sleep", Sleep, Slept, bounds, .never, clockSleep),
    declare("codec.parse", Text, Parsed, bounds, .read_only, codecParse),
    declare("context.read", Empty, State, bounds, .read_only, contextRead),
    declare("context.append", Append, Revision, bounds, .never, contextAppend),
    declare("context.snapshot", Empty, SnapshotResult, bounds, .never, contextSnapshot),
    declare("history.read", Read, []const Record, bounds, .read_only, historyRead),
    declare("context.commit", Commit, State, bounds, .never, contextCommit),
    declare("model.info", Empty, Info, bounds, .read_only, modelInfo),
    declare("model.prepare", Prompt, Prepared, bounds, .never, modelPrepare),
    declare("model.generate", GeneratePrompt, Generated, bounds, .never, generate),
    declare("events.begin", Empty, Trigger, bounds, .never, eventsBegin),
    declare("events.finish", Job, Finished, bounds, .never, eventsFinish),
    declare("agents.spawn", Spawn, Child, bounds, .never, agentsSpawn),
    declare("agents.wait", Child, Waited, bounds, .never, agentsWait),
    declare("terminal.open", services.Process.Spawn, services.Process.Status, bounds, .never, terminalOpen),
};
fn declare(comptime name: []const u8, comptime Args: type, comptime Result: type, comptime limits: services.Operation.Limits, comptime recovery: services.Operation.Recovery, comptime implementation: fn (*Self, services.Context, Args) anyerror!Result) services.Operation {
    const Bound = struct {
        fn call(p: *Principal, context: services.Context, args: Args) anyerror!Result {
            if (context.principal != p.worker.index) return error.PermissionDenied;
            var c = context;
            c.principal = p.id;
            return implementation(p.controller, c, args);
        }
    };
    return services.Operation.define(name, Principal, Args, Result, limits, recovery, Bound.call);
}
fn service(self: *Self, p: *Principal) services.Service {
    _ = self;
    const pointers = comptime blk: {
        var items: [operations.len]*const services.Operation = undefined;
        for (&operations, 0..) |*operation, index| items[index] = operation;
        break :blk items;
    };
    return .{ .context = p, .operations = &pointers };
}
fn decode(comptime T: type, a: std.mem.Allocator, value: Value) !T {
    return std.json.parseFromValueLeaky(T, a, value, .{ .allocate = .alloc_always });
}
fn sessionInput(self: *Self, c: services.Context, _: Empty) anyerror!Value {
    return j.parse(c.allocator, (try self.caller(c)).input);
}
fn clockNow(self: *Self, c: services.Context, _: Empty) anyerror!Now {
    _ = try self.caller(c);
    return .{ .ms = @intCast(std.Io.Clock.awake.now(c.io).toMilliseconds()) };
}
fn clockSleep(self: *Self, c: services.Context, args: Sleep) anyerror!Slept {
    _ = try self.caller(c);
    if (args.ms > 60000) return error.InvalidArguments;
    try std.Io.sleep(c.io, .fromMilliseconds(args.ms), .awake);
    return .{ .slept_ms = args.ms };
}
fn codecParse(self: *Self, c: services.Context, args: Text) anyerror!Parsed {
    _ = try self.caller(c);
    const value = parseJson(c.allocator, args.text) catch |err| return .{ .ok = false, .@"error" = @errorName(err) };
    var types: Value = .{ .object = .empty };
    try shapes(c.allocator, value, "", &types);
    return .{ .ok = true, .value = value, .types = types };
}
fn contextRead(self: *Self, c: services.Context, _: Empty) anyerror!State {
    return decode(State, c.allocator, try (try self.caller(c)).context.read(c.allocator));
}
fn contextAppend(self: *Self, c: services.Context, args: Append) anyerror!Revision {
    return decode(Revision, c.allocator, try (try self.caller(c)).context.append(c.allocator, try j.value(c.allocator, args.messages)));
}
fn contextSnapshot(self: *Self, c: services.Context, _: Empty) anyerror!SnapshotResult {
    const p = try self.caller(c);
    const data = try p.context.capture(c.allocator);
    self.mutex.lockUncancelable(c.io);
    if (self.snapshots.items.len >= 128) {
        self.mutex.unlock(c.io);
        return error.SnapshotLimit;
    }
    const id = self.snapshots.items.len + 1;
    const bytes = self.gpa.dupe(u8, try j.encode(c.allocator, data)) catch |err| {
        self.mutex.unlock(c.io);
        return err;
    };
    self.snapshots.append(self.gpa, .{ .id = id, .owner = p.id, .bytes = bytes }) catch |err| {
        self.gpa.free(bytes);
        self.mutex.unlock(c.io);
        return err;
    };
    self.mutex.unlock(c.io);
    try p.context.pinSnapshot(c.allocator, id);
    _ = try self.program(p, c.allocator, "ctx.snapshots=ctx.snapshots or {}; ctx.snapshots[tostring(input.id)]={owner=input.owner}; return true", try j.value(c.allocator, .{ .id = id, .owner = p.id }));
    return .{ .id = id, .owner = p.id, .data = try decode(Captured, c.allocator, data) };
}
fn historyRead(self: *Self, c: services.Context, args: Read) anyerror![]const Record {
    const p = try self.caller(c);
    const snap = try self.snapshot(args.snapshot);
    if (snap.owner != p.id) {
        const grant = p.grant orelse return error.PermissionDenied;
        if (grant.snapshot != snap.id) return error.PermissionDenied;
        for (args.ids) |id| {
            var found = false;
            for (grant.ids) |allowed| if (id == allowed) {
                found = true;
                break;
            };
            if (!found) return error.PermissionDenied;
        }
    }
    return decode([]const Record, c.allocator, try Context.readGroups(c.allocator, try j.parse(c.allocator, snap.bytes), try j.value(c.allocator, args.ids)));
}
fn contextCommit(self: *Self, c: services.Context, args: Commit) anyerror!State {
    const p = try self.caller(c);
    const target = try self.principal(args.target_session orelse p.id);
    if (target.id != p.id) return error.PermissionDenied;
    const snap = try self.snapshot(args.snapshot);
    if (snap.owner != target.id) return error.WrongSnapshotOwner;
    const result = try target.context.commit(c.allocator, try j.parse(c.allocator, snap.bytes), try j.value(c.allocator, args.selected), try j.value(c.allocator, args.replacement), target.definition.protected_ids, snap.id, args.after);
    p.last_tokens = 0;
    return decode(State, c.allocator, result);
}
fn modelInfo(self: *Self, c: services.Context, _: Empty) anyerror!Info {
    _ = try self.caller(c);
    return .{ .context_window = self.settings.context_window, .max_output_tokens = self.settings.max_output_tokens, .estimator = "UTF-8 bytes / 4" };
}
fn modelPrepare(self: *Self, c: services.Context, args: Prompt) anyerror!Prepared {
    const p = try self.caller(c);
    const messages = try Context.visible(c.allocator, try p.context.read(c.allocator));
    const estimated = (try j.encode(c.allocator, messages)).len / 4 + args.prompt.len / 4;
    const tokens = @max(estimated, p.last_tokens);
    const pressured = tokens + self.settings.reserve_tokens > self.settings.context_window;
    if (pressured and p.cause == null and p.trigger == null) {
        const serial = self.serial.fetchAdd(1, .monotonic) + 1;
        p.trigger = serial;
        try self.record(c.allocator, .{ .event = "context_near_full", .caller = p.id, .job = serial, .tokens = tokens });
        return .{ .kind = "context_near_full", .job = serial, .tokens = tokens };
    }
    if (p.cause != null) try self.record(c.allocator, .{ .event = "trigger_suppressed", .caller = p.id, .cause = p.cause, .pressured = pressured });
    return .{ .kind = "ready", .tokens = tokens };
}
fn eventsBegin(self: *Self, c: services.Context, _: Empty) anyerror!Trigger {
    const p = try self.caller(c);
    if (p.cause != null) return error.TriggerSuppressed;
    if (p.trigger) |job| return .{ .job = job, .coalesced = true };
    const serial = self.serial.fetchAdd(1, .monotonic) + 1;
    p.trigger = serial;
    return .{ .job = serial, .coalesced = false };
}
fn eventsFinish(self: *Self, c: services.Context, args: Job) anyerror!Finished {
    const p = try self.caller(c);
    if (p.trigger == null or p.trigger.? != args.job) return error.UnknownTrigger;
    p.trigger = null;
    return .{ .finished = true };
}
fn agentsSpawn(self: *Self, c: services.Context, args: Spawn) anyerror!Child {
    const p = try self.caller(c);
    if (!p.definition.spawn) return error.PermissionDenied;
    var approved = false;
    for (self.settings.definitions) |definition| if (std.mem.eql(u8, definition.name, args.program) and definition.spawnable) {
        approved = true;
        break;
    };
    if (!approved) return error.DelegationDenied;
    var grant: ?ReadGrant = null;
    errdefer if (grant) |g| self.gpa.free(g.ids);
    const ids = args.ids orelse &.{};
    if (args.snapshot) |snapshot_id| {
        const snap = try self.snapshot(snapshot_id);
        if (snap.owner != p.id) return error.DelegationDenied;
        _ = try Context.readGroups(c.allocator, try j.parse(c.allocator, snap.bytes), try j.value(c.allocator, ids));
        grant = .{ .snapshot = snap.id, .ids = try self.gpa.dupe(u64, ids) };
    } else if (ids.len > 0) return error.DelegationDenied;
    const child = try self.start(args.program, args.input, p.id, grant);
    grant = null;
    return .{ .child = child.id };
}
fn agentsWait(self: *Self, c: services.Context, args: Child) anyerror!Waited {
    const p = try self.caller(c);
    const child = try self.principal(args.child);
    if (child.parent != p.id) return error.PermissionDenied;
    var outcome = try self.join(child);
    defer outcome.deinit();
    return .{ .status = @tagName(outcome.status), .result = try j.copy(c.allocator, outcome.result), .@"error" = try j.copy(c.allocator, outcome.diagnostic), .child = child.id };
}
fn terminalOpen(self: *Self, c: services.Context, args: services.Process.Spawn) anyerror!services.Process.Status {
    const p = try self.caller(c);
    if (!p.definition.terminal) return error.PermissionDenied;
    if (p.terminal_id != null) return error.ProcessLimit;
    const result = try self.program(p, c.allocator, "ctx.terminals=ctx.terminals or {}; if ctx.terminals[tostring(input.owner)] then error('ProcessLimit') end; local result=host.call('process.spawn',input.arguments); ctx.terminals[tostring(input.owner)]=result.id; return result", try j.value(c.allocator, .{ .owner = p.id, .arguments = args }));
    p.terminal_id = try self.gpa.dupe(u8, try j.text(j.get(result, "id")));
    return decode(services.Process.Status, c.allocator, result);
}
fn generate(self: *Self, c: services.Context, args: GeneratePrompt) anyerror!Generated {
    const p = try self.caller(c);
    const calls = self.model_calls.fetchAdd(1, .monotonic);
    if (self.settings.max_model_calls) |maximum| if (calls >= maximum) return error.ModelCallLimit;
    p.calls += 1;
    const a = c.allocator;
    const active = try Context.visible(a, try p.context.read(a));
    var messages: Value = .{ .array = std.json.Array.init(a) };
    for (active.array.items) |record_| try messages.array.append(try j.value(a, .{ .role = j.get(record_, "role"), .content = j.get(record_, "content") }));
    try messages.array.append(try j.value(a, .{ .role = "user", .content = args.prompt }));
    var body = try j.value(a, .{ .model = self.model().model, .input = messages, .store = false, .max_output_tokens = self.settings.max_output_tokens });
    if (self.settings.reasoning_effort) |effort| try body.object.put(a, "reasoning", try j.value(a, .{ .effort = effort }));
    const url, const credential = switch (self.settings.model) {
        .fixture => |base| blk: {
            try body.object.put(a, "metadata", try j.value(a, .{ .worker = p.id, .parent = p.parent, .label = j.get(try j.parse(a, p.input), "label"), .call = p.calls }));
            break :blk .{ try std.fmt.allocPrint(a, "{s}/responses", .{base}), "" };
        },
        .live => |live| .{ live.responses_url, provider.credential_label },
    };
    const generation = try p.context.beginGeneration(a, args.prompt, body, self.model());
    const envelope = try self.program(p, a, "return host.call('model.request',input)", try j.value(a, .{ .url = url, .credential = credential, .body = body }));
    const raw = j.get(envelope, "body");
    if (try Context.number(j.get(envelope, "status")) != 200 or j.get(raw, "error") == .object) {
        try p.context.finishGeneration(a, generation, .failed, "", raw, j.get(raw, "usage"));
        return .{ .ok = false, .@"error" = try j.string(j.get(raw, "error"), "code", "provider_error"), .raw = raw };
    }
    var text: std.ArrayList(u8) = .empty;
    for (try Context.items(j.get(raw, "output"))) |output| {
        if (j.get(output, "content") != .array) continue;
        for (try Context.items(j.get(output, "content"))) |block| {
            if (j.get(block, "text") == .string and std.mem.eql(u8, try j.string(block, "type", ""), "output_text")) {
                try text.appendSlice(a, try j.text(j.get(block, "text")));
            }
        }
    }
    const usage = j.get(raw, "usage");
    p.last_tokens = (Context.number(j.get(usage, "input_tokens")) catch 0) + (Context.number(j.get(usage, "output_tokens")) catch 0);
    const status = j.string(raw, "status", "") catch "";
    if (!std.mem.eql(u8, status, "completed")) {
        try p.context.finishGeneration(a, generation, .failed, text.items, raw, usage);
        return .{ .ok = false, .@"error" = if (std.mem.eql(u8, status, "incomplete")) "output_incomplete" else "response_not_completed", .text = text.items, .raw = raw, .usage = usage, .finish_reason = status };
    }
    try p.context.finishGeneration(a, generation, .completed, text.items, raw, usage);
    return .{ .ok = true, .text = text.items, .raw = raw, .usage = usage, .finish_reason = status };
}

fn parseJson(a: std.mem.Allocator, text: []const u8) !Value {
    if (text.len > 512 * 1024) return error.JsonInputLimit;
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, a);
    var window: json_text.Source.Window = .{};
    var source = json_text.Source.init(text, &window, scratch.allocator());
    defer source.deinit();
    source.max_depth = 64;
    return json_text.parseFromSourceLeaky(Value, a, &source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .use_last });
}
fn pointerKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (key) |byte| switch (byte) {
        '~' => try result.appendSlice(a, "~0"),
        '/' => try result.appendSlice(a, "~1"),
        else => try result.append(a, byte),
    };
    return result.toOwnedSlice(a);
}
fn shapes(a: std.mem.Allocator, value: Value, path: []const u8, types: *Value) !void {
    try j.put(a, types, path, .{ .string = @tagName(value) });
    if (value == .array) for (value.array.items, 0..) |item, index| try shapes(a, item, try std.fmt.allocPrint(a, "{s}/{d}", .{ path, index }), types);
    if (value == .object) {
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| try shapes(a, entry.value_ptr.*, try std.fmt.allocPrint(a, "{s}/{s}", .{ path, try pointerKey(a, entry.key_ptr.*) }), types);
    }
}
