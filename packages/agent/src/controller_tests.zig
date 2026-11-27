const std = @import("std");
const json_text = @import("json_tree").text;
const agent = @import("root.zig");
const services = @import("services");
const j = services.json;
const allow = "return function(event, state) return {allow=true} end";

test {
    _ = @import("BoundedPageAllocator.zig");
    _ = @import("application_tests.zig");
    _ = @import("launch_tests.zig");
    _ = @import("lifecycle_tests.zig");
    _ = @import("vm_lifetime_tests.zig");
}

const AuditedService = struct {
    calls: usize = 0,
    const Args = struct { value: u32 };
    const Result = struct { value: u32 };
    const operation = services.Operation.define("fixture.audit", AuditedService, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    const other = services.Operation.define("fixture.other", AuditedService, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    const invalid = services.Operation.defineJson("fixture.invalid-result", Args, Result, .{ .arguments = 128, .result = 128 }, .never, badResult);
    fn badResult(raw: *anyopaque, _: services.Context, _: []const u8, _: j.Value) anyerror!j.Value {
        const self: *AuditedService = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .null;
    }
    fn call(self: *AuditedService, _: services.Context, args: Args) anyerror!Result {
        self.calls += 1;
        if (args.value == 12) return error.FixtureServiceFailure;
        return .{ .value = args.value };
    }
};
const AuditCapture = struct {
    const Record = struct { scope: u64, principal: u64, effect_id: u64, key: [64]u8, digest: [64]u8, execution_attempted: bool, descriptor: bool, error_present: bool, policy: u8, request_matches: bool, cancelled: bool = false, rewritten: bool = false };
    io: std.Io,
    terminals: std.atomic.Value(usize) = .init(0),
    records: [16]Record = undefined,
    finished: std.Io.Event = .unset,
    observed: std.Io.Event = .unset,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *AuditCapture = @ptrCast(@alignCast(raw.?));
        if (event != .audit or std.mem.eql(u8, event.audit.disposition, "admitted")) return;
        const index = self.terminals.load(.monotonic);
        if (index < self.records.len) {
            const audit = event.audit;
            self.records[index] = .{ .scope = audit.scope, .principal = audit.principal, .effect_id = audit.effect_id, .key = audit.effect_key_sha256[0..64].*, .digest = audit.arguments_sha256[0..64].*, .execution_attempted = audit.execution_attempted, .descriptor = audit.descriptor.len > 0, .error_present = audit.error_code.len > 0, .policy = if (std.mem.eql(u8, audit.policy_decision, "allow")) 1 else if (std.mem.eql(u8, audit.policy_decision, "deny")) 2 else if (std.mem.eql(u8, audit.policy_decision, "invalid")) 3 else 0, .request_matches = std.mem.eql(u8, audit.request_id, "audit-paths") };
        }
        if (index < self.records.len) {
            self.records[index].cancelled = std.mem.eql(u8, event.audit.disposition, "cancelled");
            self.records[index].rewritten = !std.mem.eql(u8, event.audit.requested_arguments_sha256, event.audit.arguments_sha256);
        }
        self.terminals.store(index + 1, .release);
        self.observed.set(self.io);
        if (std.mem.eql(u8, event.audit.disposition, "completed")) self.finished.set(self.io);
    }
};

test "Controller programs acquire backing pages without reserving the caller heap" {
    const io = std.testing.io;
    const buffer = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    var caller = std.heap.FixedBufferAllocator.init(buffer);
    const controller = try agent.Controller.open(caller.threadSafeAllocator(), io, .{ .authorize = allow });
    defer controller.close();
    const request = try controller.program("on-demand", "ctx.ready=true; return 123", .null);
    defer request.deinit();
    var outcome = try completed(request, io);
    defer outcome.deinit();
    try std.testing.expectEqual(123, outcome.result.integer);
}

test "Controller inherits a supplied budget and rejects a second memory policy" {
    const io = std.testing.io;
    const budget = try agent.MemoryBudget.create(std.testing.allocator, 64 * 1024 * 1024);
    defer budget.release();
    const controller = try agent.Controller.open(budget.allocator(), io, .{ .authorize = allow });
    try std.testing.expect(budget.usage().used > @sizeOf(agent.MemoryBudget));
    try std.testing.expectError(error.InvalidControllerPolicy, agent.Controller.open(budget.allocator(), io, .{ .authorize = allow, .memory_bytes = 1024 * 1024 }));
    controller.close();
    try std.testing.expectEqual(@sizeOf(agent.MemoryBudget), budget.usage().used);
}

test "every original and rewritten service rejection has a terminal audit" {
    const io = std.testing.io;
    var service: AuditedService = .{};
    var capture: AuditCapture = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = "return function(event,state) local n=event.arguments.value; if n==7 then return {allow=false} elseif n==8 then return {allow=true,operation='fixture.other'} elseif n==9 then return {allow=true,arguments={value='invalid'}} elseif n==10 then return {allow=true,principal=99} end return {allow=true} end",
        .services = &.{.{ .context = &service, .operations = &.{ &AuditedService.operation, &AuditedService.other, &AuditedService.invalid } }},
        .program_grants = &.{ "fixture.audit", "fixture.invalid-result" },
        .sink = .{ .context = &capture, .emit = AuditCapture.emit },
    });
    defer controller.close();
    const request = try controller.program("audit-paths", "local calls={{op='missing',args={}},{op='fixture.other',args={value=1}},{op='fixture.audit',args={value='invalid'}},{op='fixture.audit',args={value=7}},{op='fixture.audit',args={value=8}},{op='fixture.audit',args={value=9}},{op='fixture.audit',args={value=10}},{op='fixture.audit',args={value=12}},{op='fixture.invalid-result',args={value=13}},{op='fixture.audit',args={value=11}}}; local results={}; for i,call in ipairs(calls) do local ok=pcall(host.call,call.op,call.args); results[i]=ok end return results", .null);
    defer request.deinit();
    var outcome = try completed(request, io);
    defer outcome.deinit();
    try capture.finished.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expectEqual(10, capture.terminals.load(.acquire));
    try std.testing.expectEqual(3, service.calls);
    for (capture.records[0..10], 0..) |record, i| {
        try std.testing.expect(record.scope != 0);
        try std.testing.expectEqual(capture.records[0].scope, record.scope);
        try std.testing.expectEqual(0, record.principal);
        try std.testing.expectEqual(i + 1, record.effect_id);
        try std.testing.expectEqual(i >= 7, record.execution_attempted);
        try std.testing.expectEqual(i != 0, record.descriptor);
        try std.testing.expectEqual(i != 9, record.error_present);
        try std.testing.expectEqual(i == 5, record.rewritten);
        try std.testing.expect(record.request_matches);
        try std.testing.expectEqual(([_]u8{ 0, 0, 0, 2, 1, 1, 3, 1, 1, 1 })[i], record.policy);
        for (capture.records[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, &previous.key, &record.key));
    }
    for (outcome.result.array.items, 0..) |result, i| try std.testing.expectEqual(i == 9, result.bool);
}

const EventHook = struct {
    observed: std.Io.Event = .unset,
    worker: u64 = 0,
    const Args = struct { worker: u64 };
    const Result = struct { recorded: bool };
    const operation = services.Operation.define("fixture.event", EventHook, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *EventHook, c: services.Context, args: Args) anyerror!Result {
        self.worker = args.worker;
        self.observed.set(c.io);
        return .{ .recorded = true };
    }
};

test "controller event hooks run real programs on copied Worker notices" {
    const io = std.testing.io;
    var hook: EventHook = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = allow,
        .services = &.{.{ .context = &hook, .operations = &.{&EventHook.operation} }},
        .program_grants = &.{"fixture.event"},
        .on_event = "if input.notice.value.kind == 'ready' then ctx.ready=true; return host.call('fixture.event',{worker=input.notice.worker.index}) end return false",
    });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "event-hook", .persistence = .memory });
    try hook.observed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expectEqual(worker.index, hook.worker);
    var context = try controller.readProgramContext(std.testing.allocator);
    defer context.deinit();
    try std.testing.expect(j.get(context.value, "ready").bool);
}

const Loopback = struct {
    server: std.Io.net.Server,
    requests: std.atomic.Value(usize) = .init(0),
    sse: bool = false,
    const body = "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"total_tokens\":7},\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"loopback\"}]}]}";
    const stream_body = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"loopback\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":" ++ body ++ "}\n\n";
    fn run(self: *Loopback, io: std.Io) void {
        while (true) {
            const connection = self.server.accept(io) catch return;
            defer connection.close(io);
            var read_buffer: [16384]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            var writer = connection.writer(io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http.receiveHead() catch return;
            _ = self.requests.fetchAdd(1, .acq_rel);
            request.respond(if (self.sse) stream_body else body, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = if (self.sse) "text/event-stream" else "application/json" }} }) catch return;
        }
    }
};

test "model denial sends zero HTTP requests and both runtimes share the registered model service" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Loopback = .{ .server = try address.listen(io, .{}) };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Loopback.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{fixture.server.socket.address.getPort()});
    const routes = &.{agent.provider.Route{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }};
    const model: agent.Model = .{ .model = "fixture", .base_url = base };
    const denied = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = "return function(event,state) return {allow=event.kind~='model'} end", .providers = routes });
    defer denied.close();
    const denied_worker = try denied.start(.{ .session_id = "denied-model", .persistence = .memory, .model = model, .endpoint_grants = &.{"model.request"} });
    const request = try denied.submit(denied_worker, "denied", .{ .input = "hello" });
    defer request.deinit();
    var denied_outcome = try request.wait(io);
    defer denied_outcome.deinit();
    try std.testing.expectEqual(.failed, denied_outcome.status);
    try std.testing.expectEqual(0, fixture.requests.load(.acquire));
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = routes, .program_grants = &.{"model.request"} });
    defer controller.close();
    try std.testing.expectError(error.UnregisteredProvider, controller.start(.{ .session_id = "unknown-route", .persistence = .memory, .endpoint_grants = &.{"model.request"} }));
    const worker = try controller.start(.{ .session_id = "allowed-model", .persistence = .memory, .model = model, .endpoint_grants = &.{"model.request"} });
    const allowed_request = try controller.submit(worker, "allowed", .{ .input = "hello" });
    defer allowed_request.deinit();
    var outcome = try completed(allowed_request, io);
    defer outcome.deinit();
    try std.testing.expectEqualStrings("loopback", outcome.text());
    try std.testing.expectEqual(1, fixture.requests.load(.acquire));
    const input = try j.value(a, .{ .url = try std.fmt.allocPrint(a, "{s}/responses", .{base}), .credential = "", .body = j.Value{ .object = .empty } });
    const program = try controller.program("model-program", "return host.call('model.request', input)", input);
    defer program.deinit();
    var programmed = try completed(program, io);
    defer programmed.deinit();
    try std.testing.expectEqual(2, fixture.requests.load(.acquire));
}

fn completed(request: *agent.Request, io: std.Io) !agent.Outcome {
    var outcome = try request.wait(io);
    if (outcome.status != .completed) {
        const bytes = try j.encode(std.testing.allocator, outcome.diagnostic);
        defer std.testing.allocator.free(bytes);
        std.debug.print("unexpected outcome: {s}\n", .{bytes});
        outcome.deinit();
        return error.UnexpectedOutcome;
    }
    return outcome;
}

test "controller programs use declared services and enqueue independent Worker commands" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: services.Files = .{ .workspace = try tmp.dir.realPathFileAlloc(io, ".", a) };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{files.service()}, .program_grants = &.{ "files.write", "controller.command" } });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "model", .persistence = .memory });
    const input = try j.value(a, worker);
    const program = try controller.program("program", "ctx.owner='controller'; host.call('files.write',{path='result',content='written'}); return worker.command({worker=input,request_id='child',kind='lua',text=\"ctx.owner='model'; return 42\"})", input);
    defer program.deinit();
    var outcome = try completed(program, io);
    defer outcome.deinit();
    try std.testing.expectEqualStrings("written", try tmp.dir.readFileAlloc(io, "result", a, .limited(1024)));
    const child = try controller.submit(worker, "child", .{ .lua = "ctx.owner='model'; return 42" });
    defer child.deinit();
    var child_outcome = try completed(child, io);
    defer child_outcome.deinit();
    var model_ctx = try controller.readContext(worker, std.testing.allocator);
    defer model_ctx.deinit();
    var controller_ctx = try controller.readProgramContext(std.testing.allocator);
    defer controller_ctx.deinit();
    try std.testing.expectEqualStrings("model", try j.text(j.get(model_ctx.value, "owner")));
    try std.testing.expectEqualStrings("controller", try j.text(j.get(controller_ctx.value, "owner")));
    try std.testing.expectError(error.RequestConflict, controller.program("program", "return 9", input));
    const duplicate = try controller.program("program", "ctx.owner='controller'; host.call('files.write',{path='result',content='written'}); return worker.command({worker=input,request_id='child',kind='lua',text=\"ctx.owner='model'; return 42\"})", input);
    duplicate.deinit();
    try std.testing.expectError(error.UnknownWorker, controller.submit(.{ .scope = worker.scope ^ 1, .index = worker.index }, "foreign", .cancel));
}

test "a policy rewrite cannot escalate a read grant into a file write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: services.Files = .{ .workspace = try tmp.dir.realPathFileAlloc(io, ".", a) };
    const policy = "return function(event,state) if event.kind=='host' then return {allow=true,operation='files.write',arguments={path='forbidden',content='bad'}} end return {allow=true} end";
    for ([_]bool{ false, true }) |allow_write| {
        const controller = try agent.Controller.open(std.testing.allocator, io, .{
            .authorize = policy,
            .services = &.{files.service()},
            .program_grants = if (allow_write) &.{ "files.read", "files.write" } else &.{"files.read"},
        });
        defer controller.close();
        const request = try controller.program("rewrite", "return host.call('files.read',{path='forbidden'})", .null);
        defer request.deinit();
        if (allow_write) {
            var outcome = try request.wait(io);
            defer outcome.deinit();
            try std.testing.expect(outcome.status == .completed);
            try std.testing.expectEqualStrings("bad", try tmp.dir.readFileAlloc(io, "forbidden", a, .limited(32)));
        } else {
            try std.testing.expectError(error.ControllerProgramFailed, request.wait(io));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "forbidden", .{}));
        }
    }
}

const Reentry = struct {
    controller: ?*agent.Controller = null,
    worker: agent.WorkerId = undefined,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    cancelled: std.Io.Event = .unset,
    active: std.atomic.Value(bool) = .init(false),
    releases: usize = 0,
    released_scope: u64 = 0,
    fn releaseOwned(raw: *anyopaque, c: services.Context) anyerror!void {
        const self: *Reentry = @ptrCast(@alignCast(raw));
        if (self.active.load(.acquire)) return error.ServiceStillActive;
        self.releases += 1;
        self.released_scope = c.scope;
    }
    const Args = struct {};
    const Result = struct { accepted: bool };
    const operation = services.Operation.define("fixture.stall", Reentry, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *Reentry, c: services.Context, _: Args) anyerror!Result {
        self.active.store(true, .release);
        defer self.active.store(false, .release);
        const request = try self.controller.?.submit(self.worker, "reentrant", .{ .lua = "ctx.reentry=true; return true" });
        request.deinit();
        var snapshot = try self.controller.?.readContext(self.worker, c.allocator);
        snapshot.deinit();
        self.entered.set(c.io);
        self.release.wait(c.io) catch |err| {
            self.cancelled.set(c.io);
            return err;
        };
        return .{ .accepted = true };
    }
};
test "stalled program service permits reentry cancel and joined shutdown" {
    const io = std.testing.io;
    var service: Reentry = .{};
    var capture: AuditCapture = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = "return function(event,state) return {allow=event.operation~='cancel'} end", .services = &.{.{ .context = &service, .operations = &.{&Reentry.operation}, .release = Reentry.releaseOwned }}, .program_grants = &.{"fixture.stall"}, .sink = .{ .context = &capture, .emit = AuditCapture.emit } });
    var closed = false;
    defer if (!closed) controller.close();
    service.controller = controller;
    service.worker = try controller.start(.{ .session_id = "reentry", .persistence = .memory });
    const program = try controller.program("stalled", "return host.call('fixture.stall',{})", .null);
    defer program.deinit();
    try service.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const cancel = try controller.submit(service.worker, "operator-cancel", .cancel);
    defer cancel.deinit();
    var outcome = try completed(cancel, io);
    defer outcome.deinit();
    controller.close();
    closed = true;
    try std.testing.expectError(error.Canceled, program.wait(io));
    try std.testing.expect(!service.active.load(.acquire));
    try std.testing.expectEqual(1, capture.terminals.load(.acquire));
    try std.testing.expect(capture.records[0].cancelled);
    try std.testing.expectEqual(1, service.releases);
    try std.testing.expectEqual(capture.records[0].scope, service.released_scope);
}

test "operator cancel interrupts the active Worker's stalled service" {
    const io = std.testing.io;
    var service: Reentry = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = "return function(event,state) return {allow=event.operation~='cancel'} end", .services = &.{.{ .context = &service, .operations = &.{&Reentry.operation} }} });
    defer controller.close();
    service.controller = controller;
    service.worker = try controller.start(.{ .session_id = "cancel-stalled", .persistence = .memory, .endpoint_grants = &.{"fixture.stall"}, .capabilities = &.{.{ .source_name = "stall", .source = "return {name='stall',version=1,description='stall',parameters={type='object'},endpoints={'fixture.stall'},recovery='never',execute=function(args) return host.call('fixture.stall',args) end}" }} });
    const request = try controller.submit(service.worker, "stalled", .{ .lua = "return tools.stall({})" });
    defer request.deinit();
    try service.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const cancel = try controller.submit(service.worker, "cancel", .cancel);
    defer cancel.deinit();
    try cancel.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var cancelled = try completed(cancel, io);
    defer cancelled.deinit();
    try service.cancelled.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var interrupted = try request.wait(io);
    defer interrupted.deinit();
    try std.testing.expectEqual(.cancelled, interrupted.status);
}

test "controller denial prevents real writes and native Exec while allow uses the same gateway" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var files: services.Files = .{ .workspace = workspace };
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "output" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    const input = try j.value(a, .{ .cwd = workspace });
    for ([_]bool{ false, true }) |allowed| {
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = if (allowed) allow else "return function(event,state) return {allow=event.kind~='host'} end", .services = &.{ files.service(), exec.service() }, .program_grants = &.{ "files.write", "process.exec" } });
        defer controller.close();
        const program = try controller.program("effects", "local wrote=pcall(host.call,'files.write',{path='written',content='yes'}); local spawned=pcall(host.call,'process.exec',{argv={'/bin/sh','-c','printf yes > spawned'},cwd=input.cwd}); return {wrote=wrote,spawned=spawned}", input);
        defer program.deinit();
        var outcome = try completed(program, io);
        defer outcome.deinit();
        try std.testing.expectEqual(allowed, j.get(outcome.result, "wrote").bool);
        try std.testing.expectEqual(allowed, j.get(outcome.result, "spawned").bool);
        for ([_][]const u8{ "written", "spawned" }) |path| {
            if (allowed) try std.testing.expectEqualStrings("yes", try tmp.dir.readFileAlloc(io, path, a, .limited(100))) else try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{}));
        }
    }
}

test "independent controllers do not share program effect receipt keys" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "output" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    const input = try j.value(a, .{ .cwd = workspace });
    var captures = [_]AuditCapture{ .{ .io = io }, .{ .io = io } };
    for (&captures) |*capture| {
        const controller = try agent.Controller.open(std.testing.allocator, io, .{
            .authorize = allow,
            .services = &.{exec.service()},
            .program_grants = &.{"process.exec"},
            .sink = .{ .context = capture, .emit = AuditCapture.emit },
        });
        defer controller.close();
        const request = try controller.program("same-id", "return host.call('process.exec',{argv={'/bin/sh','-c','printf x >> count'},cwd=input.cwd})", input);
        defer request.deinit();
        var outcome = try completed(request, io);
        defer outcome.deinit();
        try capture.finished.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    }
    try std.testing.expectEqualStrings("xx", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
    try std.testing.expect(captures[0].records[0].scope != captures[1].records[0].scope);
    try std.testing.expect(!std.mem.eql(u8, &captures[0].records[0].key, &captures[1].records[0].key));
}

const FailingSink = struct {
    io: std.Io,
    barrier: std.Io.Event = .unset,
    saw_completion: bool = false,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *FailingSink = @ptrCast(@alignCast(raw.?));
        if (event == .audit) {
            self.saw_completion = std.mem.eql(u8, event.audit.disposition, "completed") and event.audit.execution_attempted;
            return error.FixtureSinkFailure;
        }
        if (event == .notice and std.mem.eql(u8, event.notice.value.request_id, "audit-barrier")) self.barrier.set(self.io);
    }
};
test "sink failure cannot relabel or replay a completed native effect" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "output" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    var sink: FailingSink = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{exec.service()}, .program_grants = &.{"process.exec"}, .sink = .{ .context = &sink, .emit = FailingSink.emit } });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "sink-failure", .persistence = .memory });
    const request = try controller.program("completed-effect", "return host.call('process.exec',{argv={'/bin/sh','-c','printf x >> count'},cwd=input.cwd})", try j.value(a, .{ .cwd = workspace }));
    defer request.deinit();
    var result = try completed(request, io);
    defer result.deinit();
    try std.testing.expectEqual(0, j.get(result.result, "exit_code").integer);
    const cancel = try controller.submit(worker, "audit-barrier", .cancel);
    defer cancel.deinit();
    var cancelled = try completed(cancel, io);
    defer cancelled.deinit();
    try sink.barrier.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expect(sink.saw_completion);
    try std.testing.expectError(error.NotificationDeliveryFailed, controller.checkNotifications());
    try std.testing.expectError(error.NotificationDeliveryFailed, controller.program("retry", "return host.call('process.exec',input)", .null));
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
}

const LifecycleCallback = struct {
    controller: *agent.Controller = undefined,
    worker: agent.WorkerId = undefined,
    const Args = struct {};
    const Result = struct { closed: bool };
    const operation = services.Operation.define("fixture.lifecycle", LifecycleCallback, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *LifecycleCallback, _: services.Context, _: Args) anyerror!Result {
        try std.testing.expectError(error.ControllerCallbackLifecycle, self.controller.stop(self.worker));
        self.controller.close();
        return .{ .closed = true };
    }
};
test "service callback close requests shutdown without joining its own task" {
    const io = std.testing.io;
    var service: LifecycleCallback = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &service, .operations = &.{&LifecycleCallback.operation} }}, .program_grants = &.{"fixture.lifecycle"} });
    defer controller.close();
    service.controller = controller;
    service.worker = try controller.start(.{ .session_id = "callback-close", .persistence = .memory });
    const request = try controller.program("callback-close", "return host.call('fixture.lifecycle',{})", .null);
    defer request.deinit();
    try request.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var result = try completed(request, io);
    defer result.deinit();
    try std.testing.expect(j.get(result.result, "closed").bool);
    try std.testing.expectError(error.ControllerClosed, controller.program("closed", "return true", .null));
}

const ClosingSink = struct {
    controller: *agent.Controller = undefined,
    io: std.Io,
    returned: std.Io.Event = .unset,
    explicit_request: bool = false,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *ClosingSink = @ptrCast(@alignCast(raw.?));
        if (event != .audit) return;
        if (self.explicit_request) self.controller.requestClose() else self.controller.close();
        self.returned.set(self.io);
    }
};
test "sink callback close cannot cancel and join itself" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |explicit_request| {
        var service: AuditedService = .{};
        var sink: ClosingSink = .{ .io = io, .explicit_request = explicit_request };
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &service, .operations = &.{&AuditedService.operation} }}, .program_grants = &.{"fixture.audit"}, .sink = .{ .context = &sink, .emit = ClosingSink.emit } });
        defer controller.close();
        sink.controller = controller;
        const request = try controller.program("sink-close", "return host.call('fixture.audit',{value=1})", .null);
        defer request.deinit();
        var result = try completed(request, io);
        defer result.deinit();
        try sink.returned.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        try std.testing.expectError(error.ControllerClosed, controller.program("closed", "return true", .null));
    }
}

const HookAck = struct {
    count: std.atomic.Value(usize) = .init(0),
    acknowledged: std.Io.Event = .unset,
    const Args = struct {};
    const operation = services.Operation.define("fixture.hook", HookAck, Args, bool, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *HookAck, c: services.Context, _: Args) anyerror!bool {
        _ = self.count.fetchAdd(1, .acq_rel);
        self.acknowledged.set(c.io);
        return true;
    }
};
test "ephemeral hooks survive more than 1024 ordinary notices without spending public dedup records" {
    const io = std.testing.io;
    var ack: HookAck = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = allow,
        .services = &.{.{ .context = &ack, .operations = &.{&HookAck.operation} }},
        .program_grants = &.{"fixture.hook"},
        .on_event = "ctx.notices=(ctx.notices or 0)+1; if input.notice.value.kind=='command_finished' then return host.call('fixture.hook',{}) end return false",
    });
    defer controller.close();
    const public = try controller.program("retained", "return 42", .null);
    defer public.deinit();
    var initial = try completed(public, io);
    defer initial.deinit();
    const worker = try controller.start(.{ .session_id = "long-lived-hooks", .persistence = .memory });
    for (0..400) |i| {
        ack.acknowledged.reset();
        var buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "notice-{d}", .{i});
        const request = try controller.submit(worker, id, .{ .lua = "return true" });
        defer request.deinit();
        var outcome = try completed(request, io);
        defer outcome.deinit();
        try ack.acknowledged.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    }
    try std.testing.expectEqual(400, ack.count.load(.acquire));
    var hook_context = try controller.readProgramContext(std.testing.allocator);
    defer hook_context.deinit();
    try std.testing.expect(j.get(hook_context.value, "notices").integer > 1024);
    const duplicate = try controller.program("retained", "return 42", .null);
    defer duplicate.deinit();
    var same = try completed(duplicate, io);
    defer same.deinit();
    try std.testing.expectEqual(42, same.result.integer);
    try std.testing.expectError(error.RequestConflict, controller.program("retained", "return 43", .null));
}

test "stopped Workers release capacity and never revive stale IDs" {
    const io = std.testing.io;
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    var previous: ?agent.WorkerId = null;
    for (0..150) |_| {
        const worker = try controller.start(.{ .session_id = "recycled", .persistence = .memory });
        if (previous) |old| {
            try std.testing.expect(worker.index > old.index);
            try std.testing.expectError(error.UnknownWorker, controller.submit(old, "stale", .cancel));
        }
        try controller.stop(worker);
        previous = worker;
    }
    var active: [128]agent.WorkerId = undefined;
    for (&active, 0..) |*worker, i| {
        var buffer: [32]u8 = undefined;
        worker.* = try controller.start(.{ .session_id = try std.fmt.bufPrint(&buffer, "live-{d}", .{i}), .persistence = .memory });
    }
    const additional = try controller.start(.{ .session_id = "beyond-former-capacity", .persistence = .memory });
    try controller.stop(additional);
    try controller.stop(active[0]);
    const last = try controller.submit(active[127], "survived-compaction", .{ .lua = "return 23" });
    defer last.deinit();
    var result = try completed(last, io);
    defer result.deinit();
    try std.testing.expectEqual(23, result.result.integer);
    const replacement = try controller.start(.{ .session_id = "replacement", .persistence = .memory });
    try std.testing.expect(replacement.index > active[127].index);
    try std.testing.expectError(error.UnknownWorker, controller.submit(active[0], "stale", .cancel));
}

test "failed Worker starts do not consume active capacity" {
    const io = std.testing.io;
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    for (0..150) |_| try std.testing.expectError(error.InvalidArgument, controller.start(.{ .session_id = "", .persistence = .memory }));
    const worker = try controller.start(.{ .session_id = "after-failures", .persistence = .memory });
    try controller.stop(worker);
}

test "duplicate live Worker session names are rejected without disturbing the original" {
    const io = std.testing.io;
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "duplicate", .persistence = .memory });
    try std.testing.expectError(error.DuplicateSession, controller.start(.{ .session_id = "duplicate", .persistence = .memory }));
    const request = try controller.submit(worker, "original", .{ .lua = "return 17" });
    defer request.deinit();
    var result = try completed(request, io);
    defer result.deinit();
    try std.testing.expectEqual(17, result.result.integer);
}

const exec_tool: agent.Capability = .{ .source_name = "exec", .source = "return {name='exec',version=1,description='exec',parameters={type='object'},endpoints={'process.exec'},recovery='never',execute=function(args) return host.call('process.exec',args) end}" };
test "memory Workers across Controllers and reopen do not share native Exec receipts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "receipts" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    const source = try std.fmt.allocPrint(a, "return tools.exec({{argv={{'/bin/sh','-c','printf x >> count'}},cwd={s}}})", .{try j.encode(a, j.Value{ .string = workspace })});
    for (0..2) |_| {
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{exec.service()} });
        defer controller.close();
        for (0..2) |_| {
            const worker = try controller.start(.{ .session_id = "same-memory-name", .persistence = .memory, .endpoint_grants = &.{"process.exec"}, .capabilities = &.{exec_tool} });
            const request = try controller.submit(worker, "same-command", .{ .lua = source });
            defer request.deinit();
            var result = try completed(request, io);
            defer result.deinit();
            try controller.stop(worker);
        }
    }
    try std.testing.expectEqualStrings("xxxx", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
}

const PreviewCapture = struct {
    io: std.Io,
    workers: [2]agent.WorkerId = undefined,
    attributed: [2]bool = .{ false, false },
    count: std.atomic.Value(usize) = .init(0),
    matching_ids: bool = true,
    delivered: std.Io.Event = .unset,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *PreviewCapture = @ptrCast(@alignCast(raw.?));
        if (event != .preview or event.preview.update != .delta) return;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const value = try j.value(arena.allocator(), event.preview);
        const worker = j.get(value, "worker");
        for (self.workers, 0..) |expected, i| {
            const scope = j.get(worker, "scope");
            const index = j.get(worker, "index");
            if (scope == .integer and index == .integer and scope.integer == @as(i64, @intCast(expected.scope)) and index.integer == @as(i64, @intCast(expected.index))) self.attributed[i] = true;
        }
        self.matching_ids = self.matching_ids and std.mem.eql(u8, event.preview.request_id, "same-run") and std.mem.eql(u8, event.preview.update.delta, "loopback");
        if (self.count.fetchAdd(1, .acq_rel) + 1 == 2) self.delivered.set(self.io);
    }
};
test "real model streams attribute two same-request-id Workers without changing request IDs" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Loopback = .{ .server = try address.listen(io, .{}), .sse = true };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Loopback.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{fixture.server.socket.address.getPort()});
    var sink: PreviewCapture = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }}, .sink = .{ .context = &sink, .emit = PreviewCapture.emit } });
    defer controller.close();
    for (&sink.workers, 0..) |*worker, i| worker.* = try controller.start(.{ .session_id = if (i == 0) "preview-a" else "preview-b", .persistence = .memory, .model = .{ .model = "fixture", .base_url = base }, .endpoint_grants = &.{"model.request"} });
    const first = try controller.submit(sink.workers[0], "same-run", .{ .input = "hello" });
    defer first.deinit();
    const second = try controller.submit(sink.workers[1], "same-run", .{ .input = "hello" });
    defer second.deinit();
    var one = try completed(first, io);
    defer one.deinit();
    var two = try completed(second, io);
    defer two.deinit();
    try sink.delivered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expectEqualStrings("loopback", one.text());
    try std.testing.expectEqualStrings("loopback", two.text());
    try std.testing.expect(sink.matching_ids);
    try std.testing.expect(sink.attributed[0] and sink.attributed[1]);
}

const HeldNativeEffect = struct {
    exec: *services.Exec,
    executed: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    const Args = struct { cwd: []const u8 };
    const operation = services.Operation.define("fixture.held-native", HeldNativeEffect, Args, bool, .{ .arguments = 4096, .result = 128 }, .never, call);
    fn call(self: *HeldNativeEffect, c: services.Context, args: Args) anyerror!bool {
        var registry = services.Registry.init(c.allocator);
        defer registry.deinit();
        try registry.add(self.exec.service());
        _ = try registry.dispatch(c, "process.exec", try j.value(c.allocator, .{ .argv = [_][]const u8{ "/bin/sh", "-c", "printf x >> count" }, .cwd = args.cwd }));
        self.executed.set(c.io);
        try self.release.wait(c.io);
        return true;
    }
};
const SlowSink = struct {
    io: std.Io,
    blocked: bool = false,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    completed_audit: std.Io.Event = .unset,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *SlowSink = @ptrCast(@alignCast(raw.?));
        if (!self.blocked) {
            self.blocked = true;
            self.entered.set(self.io);
            try self.release.wait(self.io);
        }
        if (event == .audit and std.mem.eql(u8, event.audit.disposition, "completed")) self.completed_audit.set(self.io);
    }
};
test "stalled sink preserves real effect results and does not poison the Worker actor" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "receipts" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    var held: HeldNativeEffect = .{ .exec = &exec };
    var sink: SlowSink = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &held, .operations = &.{&HeldNativeEffect.operation} }}, .program_grants = &.{"fixture.held-native"}, .sink = .{ .context = &sink, .emit = SlowSink.emit } });
    defer controller.close();
    defer sink.release.set(io);
    defer held.release.set(io);
    const worker = try controller.start(.{ .session_id = "slow-ui", .persistence = .memory });
    try sink.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const effect = try controller.program("real-held-effect", "return host.call('fixture.held-native',input)", try j.value(a, .{ .cwd = workspace }));
    defer effect.deinit();
    try held.executed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var poisoned = false;
    for (0..400) |i| {
        var buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "flood-{d}", .{i});
        const request = controller.submit(worker, id, .{ .lua = "return true" }) catch {
            poisoned = true;
            break;
        };
        defer request.deinit();
        var result = request.wait(io) catch {
            poisoned = true;
            break;
        };
        defer result.deinit();
        if (result.status != .completed) {
            poisoned = true;
            break;
        }
    }
    try controller.checkNotifications();
    held.release.set(io);
    sink.release.set(io);
    var result = try completed(effect, io);
    defer result.deinit();
    try std.testing.expect(result.result.bool);
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
    try sink.completed_audit.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expect(!poisoned);
    const cancel = try controller.submit(worker, "still-controllable", .cancel);
    defer cancel.deinit();
    var cancelled = try completed(cancel, io);
    defer cancelled.deinit();
    const recovered = try controller.program("recovered-after-stall", "return true", .null);
    defer recovered.deinit();
    var recovered_result = try completed(recovered, io);
    defer recovered_result.deinit();
    try std.testing.expectEqual(true, recovered_result.result.bool);
}

const KeyedNativeEffect = struct {
    exec: *services.Exec,
    const Args = struct { cwd: []const u8 };
    const Result = struct { key: []const u8 };
    const operation = services.Operation.define("fixture.keyed-native", KeyedNativeEffect, Args, Result, .{ .arguments = 4096, .result = 4096 }, .never, call);
    fn call(self: *KeyedNativeEffect, c: services.Context, args: Args) anyerror!Result {
        var registry = services.Registry.init(c.allocator);
        defer registry.deinit();
        try registry.add(self.exec.service());
        _ = try registry.dispatch(c, "process.exec", try j.value(c.allocator, .{ .argv = [_][]const u8{ "/bin/sh", "-c", "printf x >> count" }, .cwd = args.cwd }));
        return .{ .key = c.idempotency_key };
    }
};
test "journal Worker identity survives reopen but isolates distinct journals and never replays completed effects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "receipts" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    var native: KeyedNativeEffect = .{ .exec = &exec };
    const tool: agent.Capability = .{ .source_name = "keyed", .source = "return {name='keyed',version=1,description='keyed',parameters={type='object'},endpoints={'fixture.keyed-native'},recovery='never',execute=function(args) return host.call('fixture.keyed-native',args) end}" };
    const source = try std.fmt.allocPrint(a, "return tools.keyed({{cwd={s}}})", .{try j.encode(a, j.Value{ .string = workspace })});
    var keys: [3][]const u8 = undefined;
    for (0..3) |round| {
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &native, .operations = &.{&KeyedNativeEffect.operation} }} });
        defer controller.close();
        const path = try std.fmt.allocPrint(a, "{s}/{s}{s}.gz", .{ workspace, if (round == 1) "./" else "", if (round < 2) "journal-a" else "journal-b" });
        const worker = try controller.start(.{ .session_id = "same-journal-name", .journal_path = path, .endpoint_grants = &.{"fixture.keyed-native"}, .capabilities = &.{tool} });
        const request = try controller.submit(worker, "first", .{ .lua = source });
        defer request.deinit();
        var result = try completed(request, io);
        defer result.deinit();
        keys[round] = try a.dupe(u8, j.get(result.result, "key").string);
        if (round == 1) {
            try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
            try std.testing.expectEqualStrings(keys[0], keys[1]);
            const second = try controller.submit(worker, "second", .{ .lua = source });
            defer second.deinit();
            var next = try completed(second, io);
            defer next.deinit();
            const next_key = j.get(next.result, "key").string;
            try std.testing.expect(!std.mem.eql(u8, keys[0], next_key));
            try std.testing.expectEqualStrings(keys[0][0..std.mem.lastIndexOfScalar(u8, keys[0], '/').?], next_key[0..std.mem.lastIndexOfScalar(u8, next_key, '/').?]);
        }
    }
    try std.testing.expectEqualStrings("xxx", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
    try std.testing.expect(!std.mem.eql(u8, keys[0], keys[2]));
}

test "interrupted journal Worker does not replay an already performed native effect" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "receipts" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    var held: HeldNativeEffect = .{ .exec = &exec };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &held, .operations = &.{&HeldNativeEffect.operation} }} });
    defer controller.close();
    const tool: agent.Capability = .{ .source_name = "hold", .source = "return {name='hold',version=1,description='hold',parameters={type='object'},endpoints={'fixture.held-native'},recovery='never',execute=function(args) return host.call('fixture.held-native',args) end}" };
    const config: agent.Config = .{ .session_id = "interrupted", .journal_path = try std.fs.path.join(a, &.{ workspace, "journal.gz" }), .endpoint_grants = &.{"fixture.held-native"}, .capabilities = &.{tool} };
    const source = try std.fmt.allocPrint(a, "return tools.hold({{cwd={s}}})", .{try j.encode(a, j.Value{ .string = workspace })});
    const worker = try controller.start(config);
    const request = try controller.submit(worker, "interrupted-effect", .{ .lua = source });
    defer request.deinit();
    try held.executed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try controller.stop(worker);
    held.executed.reset();
    const reopened = try controller.start(config);
    const duplicate = try controller.submit(reopened, "interrupted-effect", .{ .lua = source });
    defer duplicate.deinit();
    var result = try duplicate.wait(io);
    defer result.deinit();
    try std.testing.expectEqual(.failed, result.status);
    try std.testing.expect(!held.executed.isSet());
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "count", a, .limited(100)));
}

test "thinking cycle wraps and skips unsupported levels" {
    const thinking = agent.thinking;
    const all = try thinking.fromList("off,minimal,low,medium,high,xhigh,max,ultra");
    try std.testing.expectEqual(thinking.Level.off, try all.cycle(null));
    for (thinking.levels, 0..) |level, index| {
        try std.testing.expectEqual(thinking.levels[(index + 1) % thinking.levels.len], try all.cycle(level));
    }
    const sparse = try thinking.fromList("low,ultra");
    try std.testing.expectEqual(thinking.Level.low, try sparse.cycle(.ultra));
    try std.testing.expectEqual(thinking.Level.ultra, try sparse.cycle(.low));
    try std.testing.expectEqual(thinking.Level.ultra, try sparse.cycle(.max));
    const single = try thinking.fromList("ultra");
    for (thinking.levels) |level| try std.testing.expectEqual(thinking.Level.ultra, try single.cycle(level));
    try std.testing.expectError(error.UnknownThinkingCapabilities, (thinking.Profile{}).cycle(null));
    for (thinking.levels) |level| try std.testing.expectError(error.UnknownThinkingCapabilities, (thinking.Profile{}).cycle(level));
}

test "thinking profiles translate typed selections and omit nonreasoning requests" {
    const a = std.testing.allocator;
    const thinking = agent.thinking;
    const reasoning = try thinking.fromList("low,medium,high,xhigh,max");
    try std.testing.expectEqual(thinking.Level.low, try reasoning.cycle(.max));
    try std.testing.expectError(error.UnsupportedThinkingLevel, reasoning.wire(.off));
    try std.testing.expectEqual(thinking.Level.xhigh, try (try thinking.fromList("medium,high,xhigh")).clamp(.max));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const input = try json_text.parseFromSlice(std.json.Value, arena.allocator(), "[]", .{});
    var custom: thinking.Profile = .{};
    custom.entries[@backingInt(thinking.Level.high)] = .{ .effort = "deep" };
    var nonreasoning: thinking.Profile = .{};
    nonreasoning.entries[@backingInt(thinking.Level.off)] = .omitted;
    for ([_]struct { level: thinking.Level, wire: ?[]const u8, profile: thinking.Profile }{
        .{ .level = .max, .wire = "max", .profile = reasoning },
        .{ .level = .off, .wire = "none", .profile = try thinking.fromList("none,low,high") },
        .{ .level = .off, .wire = null, .profile = nonreasoning },
        .{ .level = .low, .wire = "low", .profile = reasoning },
        .{ .level = .ultra, .wire = "ultra", .profile = try thinking.fromList("low,ultra") },
        .{ .level = .high, .wire = "deep", .profile = custom },
    }) |case| {
        const model = try (agent.Model{ .model = "injected-model" }).withThinking(case.profile, case.level);
        const body = try agent.responses.request(arena.allocator(), .{ .model = model.model, .reasoning_effort = model.reasoning_effort }, input.value, input.value);
        const parsed = try json_text.parseFromSlice(std.json.Value, arena.allocator(), body, .{});
        if (case.wire) |wire| {
            try std.testing.expectEqualStrings(wire, parsed.value.object.get("reasoning").?.object.get("effort").?.string);
        } else try std.testing.expect(parsed.value.object.get("reasoning") == null);
    }
}
