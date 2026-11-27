const std = @import("std");
const agent = @import("root.zig");
const services = @import("services");
const j = services.json;
const allow = "return function(event,state) return {allow=true} end";
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };

fn completed(request: *agent.Request) !agent.Outcome {
    try request.done.waitTimeout(std.testing.io, timeout);
    var outcome = try request.wait(std.testing.io);
    errdefer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    return outcome;
}

const Fixture = struct {
    server: std.Io.net.Server,
    body: ?[]const u8 = null,
    status: std.http.Status = .ok,
    requests: std.atomic.Value(usize) = .init(0),
    stall_first: bool = false,
    hold_second: bool = false,
    release_second: std.Io.Event = .unset,
    first: std.Io.Event = .unset,
    second: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    replied: std.Io.Event = .unset,
    const good = "{\"object\":\"response\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"corrected\"}]}]}";
    const obsolete = "{\"object\":\"response\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"name\":\"execute_lua\",\"call_id\":\"obsolete\",\"arguments\":\"{\\\"source\\\":\\\"ctx.obsolete=true; return tools.write({path='obsolete',content='bad'})\\\"}\"}]}";
    fn run(self: *Fixture, io: std.Io) void {
        var handlers: std.Io.Group = .init;
        defer handlers.cancel(io);
        while (true) {
            const connection = self.server.accept(io) catch return;
            handlers.concurrent(io, respond, .{ self, io, connection }) catch {
                connection.close(io);
                return;
            };
        }
    }
    fn respond(self: *Fixture, io: std.Io, connection: std.Io.net.Stream) void {
        defer connection.close(io);
        var input: [16384]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = connection.reader(io, &input);
        var writer = connection.writer(io, &output);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http.receiveHead() catch return;
        const number = self.requests.fetchAdd(1, .acq_rel) + 1;
        if (number == 1) self.first.set(io) else self.second.set(io);
        if (number == 1 and self.stall_first) self.release.wait(io) catch return;
        if (number == 2 and self.hold_second) self.release_second.wait(io) catch return;
        request.respond(self.body orelse (if (number == 1 and self.stall_first) obsolete else good), .{ .status = self.status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch {};
        if (number == 1) self.replied.set(io);
    }
    fn base(self: *Fixture, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }
};

const write_tool: agent.Capability = .{ .source_name = "write", .source = "return {name='write',version=1,description='write',parameters={type='object'},endpoints={'files.write'},recovery='never',execute=function(args) return host.call('files.write',args) end}" };
const exec_tool: agent.Capability = .{ .source_name = "exec", .source = "return {name='exec',version=1,description='exec',parameters={type='object'},endpoints={'process.exec'},recovery='never',execute=function(args) return host.call('process.exec',args) end}" };

test "unpublished launch rejects file process and provider effects and rolls checkpoints back to the durable prefix" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    const journal_path = try std.fs.path.join(a, &.{ workspace, "bootstrap.gz" });
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var files: services.Files = .{ .workspace = workspace };
    var exec: services.Exec = .{ .directory = workspace, .environment = &env };
    defer exec.deinit(io, .terminate);
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Fixture = .{ .server = try address.listen(io, .{}) };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Fixture.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try fixture.base(a);
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = allow,
        .services = &.{ files.service(), exec.service() },
        .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, workspace, base) }},
    });
    defer controller.close();
    var config: agent.Config = .{
        .session_id = "bootstrap-denial",
        .journal_path = journal_path,
        .model = .{ .base_url = base, .model = "fixture" },
        .endpoint_grants = &.{ "files.write", "process.exec", "model.request" },
        .application = .{ .source = "ctx.value='original'; return true" },
    };
    const seed = try controller.launch(config, .{ .initialize = .{ .input_json = "{}" } });
    try controller.stop(seed);
    const committed = try tmp.dir.readFileAlloc(io, "bootstrap.gz", a, .limited(1024 * 1024));
    const prefix = try std.mem.concat(a, u8, &.{ committed, "\x1f" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bootstrap.gz", .data = prefix });
    const desired = [_]agent.CatalogCapability{ .{ .name = "write", .capability = write_tool }, .{ .name = "exec", .capability = exec_tool } };
    const attempts = [_][]const u8{
        "return tools.write({path='forbidden-write',content='bad'})",
        "return tools.exec({argv={'/bin/sh','-c','printf bad > forbidden-process'},cwd=input.cwd})",
        "return agent.model({model='fixture',input={{role='user',content='hello'}}})",
        "error('initialization failed')",
    };
    for (attempts, 0..) |source, index| {
        config.application.?.source = try std.mem.concat(a, u8, &.{ "ctx.value='provisional'; agent.checkpoint({changed=true}); ", source });
        var diagnostic: ?agent.JsonDocument = null;
        defer if (diagnostic) |*document| document.deinit();
        const result = controller.launch(config, .{ .catalog = .{ .fixed = &desired }, .initialize = .{ .input_json = try j.encode(a, .{ .cwd = workspace }) }, .failure_diagnostic = &diagnostic });
        if (index < 3) try std.testing.expectError(error.BootstrapExternalEffect, result) else try std.testing.expectError(error.ApplicationInitializationFailed, result);
        if (index < 3) try std.testing.expect(diagnostic == null) else try std.testing.expect(std.mem.indexOf(u8, try j.text(j.get(diagnostic.?.value, "message")), "initialization failed") != null);
        const after = try tmp.dir.readFileAlloc(io, "bootstrap.gz", a, .limited(1024 * 1024));
        try std.testing.expectEqualSlices(u8, prefix, after);
        try std.testing.expectEqual(0, fixture.requests.load(.acquire));
        for ([_][]const u8{ "forbidden-write", "forbidden-process" }) |path| try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{}));
    }
    config.application.?.source = "return ctx.value";
    const recovered = try controller.launch(config, .{});
    var snapshot = try controller.readContext(recovered, a);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("original", try j.text(j.get(snapshot.value, "value")));
    var state = try controller.inspect(recovered, a);
    defer state.deinit();
    try std.testing.expectEqual(0, j.get(state.value, "capabilities").array.items.len);
}

test "inside mutation cannot change outside policy or real file process and model authority" {
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
    var exec: services.Exec = .{ .directory = try std.fs.path.join(a, &.{ workspace, "receipts" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Fixture = .{ .server = try address.listen(io, .{}) };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Fixture.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try fixture.base(a);
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = "return function(event,state) if event.kind=='command' or event.kind=='snapshot' then return {allow=true} end return {allow=state.enabled==true and state.secret=='outside' and event.principal~=0} end",
        .services = &.{ files.service(), exec.service() },
        .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, workspace, base) }},
    });
    defer controller.close();
    const setup = try controller.program("setup", "ctx.secret='outside'; ctx.enabled=false; return true", .null);
    defer setup.deinit();
    var configured = try completed(setup);
    defer configured.deinit();
    const worker = try controller.start(.{
        .session_id = "inside-outside",
        .persistence = .memory,
        .model = .{ .base_url = base, .model = "fixture" },
        .capabilities = &.{ write_tool, exec_tool },
        .endpoint_grants = &.{ "files.write", "process.exec", "model.request" },
        .application = .{ .mutable = true, .source = "ctx.enabled=true; ctx.secret='forged'; ctx.endpoints={'*'}; local original=tools.write; tools.write=function(args) args.content='inside'; return original(args) end; local factory=pcall(agent.define,'effectful',[[tools.write({path='factory',content='bad'});return function()end]]); local wrote=pcall(tools.write,{path='written',content='bad'}); local spawned=pcall(tools.exec,{argv={'/bin/sh','-c','printf inside > spawned'},cwd=input.cwd}); local response=agent.model({model='fixture',input={{role='user',content='hello'}}}); return {factory=factory,wrote=wrote,spawned=spawned,model=response.status}" },
    });
    const payload = try j.encode(a, .{ .cwd = workspace });
    const denied = try controller.deliver(worker, "denied", .{ .input_json = payload });
    defer denied.deinit();
    var denial = try completed(denied);
    defer denial.deinit();
    try std.testing.expect(!j.get(denial.result, "wrote").bool);
    try std.testing.expect(!j.get(denial.result, "spawned").bool);
    try std.testing.expectEqualStrings("error", try j.text(j.get(denial.result, "model")));
    try std.testing.expectEqual(0, fixture.requests.load(.acquire));
    for ([_][]const u8{ "written", "spawned" }) |path| try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{}));
    var outside = try controller.readProgramContext(std.testing.allocator);
    defer outside.deinit();
    try std.testing.expectEqualStrings("outside", try j.text(j.get(outside.value, "secret")));
    try std.testing.expect(!j.get(outside.value, "enabled").bool);
    const enable = try controller.program("enable", "ctx.enabled=true; return true", .null);
    defer enable.deinit();
    var enabled = try completed(enable);
    defer enabled.deinit();
    const accepted = try controller.deliver(worker, "enabled", .{ .input_json = payload });
    defer accepted.deinit();
    var result = try completed(accepted);
    defer result.deinit();
    try std.testing.expect(!j.get(result.result, "factory").bool);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "factory", .{}));
    try std.testing.expect(j.get(result.result, "wrote").bool);
    try std.testing.expect(j.get(result.result, "spawned").bool);
    try std.testing.expectEqualStrings("completed", try j.text(j.get(result.result, "model")));
    try std.testing.expectEqual(1, fixture.requests.load(.acquire));
    for ([_][]const u8{ "written", "spawned" }) |path| try std.testing.expectEqualStrings("inside", try tmp.dir.readFileAlloc(io, path, a, .limited(100)));
}

test "exact invocation replacement progresses before old provider reply and stale replacement cannot cancel it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var files: services.Files = .{ .workspace = workspace };
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Fixture = .{ .server = try address.listen(io, .{}), .stall_first = true, .hold_second = true };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Fixture.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try fixture.base(a);
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{files.service()}, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, workspace, base) }} });
    defer controller.close();
    defer fixture.release.set(io);
    defer fixture.release_second.set(io);
    const config: agent.Config = .{
        .session_id = "replacement",
        .journal_path = try std.fs.path.join(a, &.{ workspace, "replacement.gz" }),
        .model = .{ .base_url = base, .model = "fixture" },
        .capabilities = &.{write_tool},
        .endpoint_grants = &.{ "files.write", "model.request" },
        .application = .{ .mutable = true, .source = "ctx.input=input.text; local reply=agent.model({model='fixture',input={{role='user',content=input.text}}}); for _, call in ipairs(reply.calls) do agent.evaluate(call.arguments.source) end; ctx.answer=reply.text; return reply.text" },
    };
    const worker = try controller.start(config);
    const old = try controller.deliver(worker, "old", .{ .input_json = "{\"text\":\"old\"}" });
    defer old.deinit();
    try fixture.first.waitTimeout(io, timeout);
    const replacement = try controller.deliver(worker, "new", .{ .input_json = "{\"text\":\"new\"}", .replace = old.id });
    defer replacement.deinit();
    try fixture.second.waitTimeout(io, timeout);
    try std.testing.expect(!fixture.release.isSet());
    const stale = try controller.deliver(worker, "stale", .{ .input_json = "{\"text\":\"stale\"}", .replace = old.id });
    defer stale.deinit();
    try stale.done.waitTimeout(io, timeout);
    var rejected = try stale.wait(io);
    defer rejected.deinit();
    try std.testing.expectEqual(.failed, rejected.status);
    try std.testing.expectEqualStrings("stale_invocation", try j.text(j.get(rejected.diagnostic, "code")));
    try std.testing.expect(!replacement.done.isSet());
    fixture.release_second.set(io);
    var corrected = try completed(replacement);
    defer corrected.deinit();
    try std.testing.expectEqualStrings("corrected", try j.text(corrected.result));
    var cancelled = try old.wait(io);
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.status);
    fixture.release.set(io);
    try fixture.replied.waitTimeout(io, timeout);
    try controller.stop(worker);
    const reopened = try controller.start(config);
    var snapshot = try controller.inspect(reopened, std.testing.allocator);
    defer snapshot.deinit();
    const ctx = j.get(snapshot.value, "ctx");
    try std.testing.expectEqualStrings("new", try j.text(j.get(ctx, "input")));
    try std.testing.expectEqualStrings("corrected", try j.text(j.get(ctx, "answer")));
    try std.testing.expect(j.get(ctx, "obsolete") == .null);
    const receipts = j.get(snapshot.value, "late_receipts");
    try std.testing.expectEqual(1, receipts.array.items.len);
    try std.testing.expectEqualStrings("old", try j.text(j.get(receipts.array.items[0], "invocation")));
    try std.testing.expect(j.get(receipts.array.items[0], "cancel_requested").bool);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "obsolete", .{}));
    try std.testing.expectEqual(2, fixture.requests.load(.acquire));
}

test "Worker journal restores explicit helper source and upgrades fixed tools without replaying invocations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ workspace, "worker.gz" });
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    const original: agent.Capability = .{ .source_name = "version", .source = "return {name='version',version=1,description='version',parameters={type='object'},endpoints={},recovery='never',execute=function() return 'old' end}" };
    const updated: agent.Capability = .{ .source_name = "version", .source = "return {name='version',version=1,description='version',parameters={type='object'},endpoints={},recovery='never',execute=function() return 'new' end}" };
    const config: agent.Config = .{ .session_id = "reopen-app", .journal_path = path, .capabilities = &.{original}, .application = .{ .mutable = true, .source = "agent.restore(); if input.define then ctx.value='saved'; agent.define('helper',[[return function() return ctx.value .. '-helper' end]]) end; ctx.invocations=(ctx.invocations or 0)+1; return {helper=helper(),version=tools.version({}),invocations=ctx.invocations}" } };
    const first_worker = try controller.start(config);
    const first = try controller.deliver(first_worker, "first", .{ .input_json = "{\"define\":true}" });
    defer first.deinit();
    var defined = try completed(first);
    defer defined.deinit();
    try std.testing.expectEqualStrings("saved-helper", try j.text(j.get(defined.result, "helper")));
    try controller.stop(first_worker);
    const prefix = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    const worker = try controller.start(config);
    const upgrade = try controller.submit(worker, "fixed-tool-upgrade", .{ .register_capability = updated });
    defer upgrade.deinit();
    var upgraded = try completed(upgrade);
    defer upgraded.deinit();
    const restored = try controller.deliver(worker, "restored", .{ .input_json = "{}" });
    defer restored.deinit();
    var result = try completed(restored);
    defer result.deinit();
    try std.testing.expectEqualStrings("saved-helper", try j.text(j.get(result.result, "helper")));
    try std.testing.expectEqualStrings("new", try j.text(j.get(result.result, "version")));
    try std.testing.expectEqual(2, j.get(result.result, "invocations").integer);
    var snapshot = try controller.inspect(worker, std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expect(j.get(j.get(snapshot.value, "ctx"), "definitions") == .object);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    try std.testing.expect(std.mem.startsWith(u8, after, prefix));
}

const StopWorker = struct {
    controller: *agent.Controller,
    worker: agent.WorkerId,
    done: std.Io.Event = .unset,
    failure: ?anyerror = null,
    fn run(self: *StopWorker, io: std.Io) void {
        self.controller.stop(self.worker) catch |err| {
            self.failure = err;
        };
        self.done.set(io);
    }
};

test "observation release is not cancellation and queued replacement preserves the unrelated active invocation" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Fixture = .{ .server = try address.listen(io, .{}), .stall_first = true };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Fixture.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try fixture.base(a);
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }} });
    defer controller.close();
    defer fixture.release.set(io);
    const worker = try controller.start(.{ .session_id = "observation-and-queue", .persistence = .memory, .model = .{ .model = "fixture", .base_url = base }, .endpoint_grants = &.{"model.request"}, .application = .{ .source = "return agent.model({model='fixture',input={{role='user',content=input.text}}}).text" } });
    const delivery: agent.Delivery = .{ .input_json = "{\"text\":\"old\"}" };
    const observer = try controller.deliver(worker, "old", delivery);
    try fixture.first.waitTimeout(io, timeout);
    const retained = observer.retain();
    defer retained.deinit();
    observer.deinit();
    const queued = try controller.deliver(worker, "queued", .{ .input_json = "{\"text\":\"queued\"}" });
    defer queued.deinit();
    const replacement = try controller.deliver(worker, "replacement", .{ .input_json = "{\"text\":\"replacement\"}", .replace = queued.id });
    defer replacement.deinit();
    try queued.done.waitTimeout(io, timeout);
    var removed = try queued.wait(io);
    defer removed.deinit();
    try std.testing.expectEqual(.cancelled, removed.status);
    var snapshot = try controller.inspect(worker, std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("old", try j.text(j.get(j.get(snapshot.value, "active"), "id")));
    try std.testing.expectEqual(1, fixture.requests.load(.acquire));
    const cancel = try controller.cancelInvocation(worker, "cancel-old", "old");
    defer cancel.deinit();
    var receipt = try completed(cancel);
    defer receipt.deinit();
    var observed = try retained.wait(io);
    defer observed.deinit();
    try std.testing.expectEqual(.cancelled, observed.status);
    var result = try completed(replacement);
    defer result.deinit();
    try std.testing.expectEqualStrings("corrected", try j.text(result.result));
    const original = try controller.deliver(worker, "old", delivery);
    defer original.deinit();
    var cancelled = try original.wait(io);
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.status);
    var stopping: StopWorker = .{ .controller = controller, .worker = worker };
    var join = try io.concurrent(StopWorker.run, .{ &stopping, io });
    defer join.cancel(io);
    try stopping.done.waitTimeout(io, timeout);
    join.await(io);
    if (stopping.failure) |err| return err;
    try std.testing.expect(!fixture.release.isSet());
    try std.testing.expectEqual(2, fixture.requests.load(.acquire));
}

test "model completions calls refusal incomplete errors and cancellation remain inside data" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { body: []const u8, status: []const u8, http: std.http.Status = .ok, calls: i64 = 0 };
    const cases = [_]Case{
        .{ .body = "{\"object\":\"response\",\"model\":\"fixture\",\"status\":\"completed\",\"error\":null,\"output\":[{\"type\":\"function_call\",\"name\":\"execute_lua\",\"call_id\":\"no-auto\",\"arguments\":\"{\\\"source\\\":\\\"ctx.auto_executed=true\\\"}\"}]}", .status = "completed", .calls = 1 },
        .{ .body = "{\"object\":\"response\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}", .status = "refusal" },
        .{ .body = "{\"status\":\"incomplete\",\"output\":[]}", .status = "incomplete" },
        .{ .body = "{\"status\":\"cancelled\",\"output\":[]}", .status = "cancelled" },
        .{ .body = "{\"status\":\"failed\",\"error\":{\"code\":\"provider_failure\"}}", .status = "failed" },
        .{ .body = "{\"error\":{\"code\":\"context_length_exceeded\"}}", .status = "overflow", .http = .bad_request },
        .{ .body = "{\"output\":[]}", .status = "invalid_response" },
        .{ .body = "{\"status\":\"completed\",\"output\":\"malformed\"}", .status = "invalid_response" },
    };
    for (cases) |case| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
        var fixture: Fixture = .{ .server = try address.listen(io, .{}), .body = case.body, .status = case.http };
        defer fixture.server.deinit(io);
        var server = try io.concurrent(Fixture.run, .{ &fixture, io });
        defer server.cancel(io);
        const base = try fixture.base(a);
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }} });
        defer controller.close();
        const worker = try controller.start(.{ .session_id = "model-data", .persistence = .memory, .model = .{ .model = "fixture", .base_url = base }, .endpoint_grants = &.{"model.request"}, .application = .{ .source = "local reply=agent.model({model='fixture',input={}}); return {status=reply.status,calls=#reply.calls,executed=ctx.auto_executed==true}" } });
        const request = try controller.deliver(worker, "request", .{ .input_json = "{}" });
        defer request.deinit();
        var result = try completed(request);
        defer result.deinit();
        try std.testing.expectEqualStrings(case.status, try j.text(j.get(result.result, "status")));
        try std.testing.expectEqual(case.calls, j.get(result.result, "calls").integer);
        try std.testing.expect(!j.get(result.result, "executed").bool);
        try std.testing.expectEqual(1, fixture.requests.load(.acquire));
    }
}

test "application model effects share the native call budget even inside evaluated code" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: Fixture = .{ .server = try address.listen(io, .{}) };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(Fixture.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try fixture.base(a);
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }} });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "application-model-budget", .persistence = .memory, .model = .{ .base_url = base, .model = "fixture" }, .endpoint_grants = &.{"model.request"}, .limits = .{ .max_rounds = 1 }, .application = .{ .source = "return agent.evaluate([[for _=1,3 do agent.model({model='fixture',input={{role='user',content='nested'}}}) end; return true]])" } });
    const request = try controller.deliver(worker, "nested", .{ .input_json = "{}" });
    defer request.deinit();
    try request.done.waitTimeout(io, timeout);
    var result = try request.wait(io);
    defer result.deinit();
    try std.testing.expectEqual(.failed, result.status);
    try std.testing.expectEqualStrings("turn_limit", try j.text(j.get(result.diagnostic, "code")));
    try std.testing.expectEqual(1, fixture.requests.load(.acquire));
}

test "application compilation is demand allocated and selected tool mutability does not expose native globals" {
    const io = std.testing.io;
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    for ([_]bool{ false, true }) |mutable| {
        const worker = try controller.start(.{ .session_id = if (mutable) "mutable" else "fixed", .persistence = .memory, .application = .{ .mutable = mutable, .source = "local oversized=pcall(agent.evaluate,string.rep(' ',65537)); local successes=0; for _=1,17 do if pcall(agent.evaluate,string.rep(' ',65500)) then successes+=1 end end; local changed=pcall(function() tools.new_tool=function()return true end end); return {oversized=oversized,successes=successes,changed=changed,private=agent.evaluate('return native==nil and host==nil and getfenv==nil and setfenv==nil')}" } });
        const request = try controller.deliver(worker, "budget", .{ .input_json = "{}" });
        defer request.deinit();
        var result = try completed(request);
        defer result.deinit();
        try std.testing.expect(j.get(result.result, "oversized").bool);
        try std.testing.expectEqual(17, j.get(result.result, "successes").integer);
        try std.testing.expectEqual(mutable, j.get(result.result, "changed").bool);
        try std.testing.expect(j.get(result.result, "private").bool);
    }
}

test "application delivery and environment are JSON data rather than interpolated source" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "nul\x00 control\x01 quote\" newline\n雪'; ctx.injected=true; --";
    const bytes = try j.encode(a, .{ .text = text });
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "data-not-source", .persistence = .memory, .application = .{ .source = "return {text=input.text,option=options.text,injected=ctx.injected==true}", .environment_json = bytes } });
    const request = try controller.deliver(worker, "data", .{ .input_json = bytes });
    defer request.deinit();
    var result = try completed(request);
    defer result.deinit();
    try std.testing.expectEqualStrings(text, j.get(result.result, "text").string);
    try std.testing.expectEqualStrings(text, j.get(result.result, "option").string);
    try std.testing.expect(!j.get(result.result, "injected").bool);
}

const HeldFact = struct {
    entered: std.Io.Event = .unset,
    cancelled: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    const Args = struct {};
    const Result = struct { fact: u32 };
    const operation = services.Operation.define("fixture.fact", HeldFact, Args, Result, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *HeldFact, c: services.Context, _: Args) anyerror!Result {
        self.entered.set(c.io);
        self.release.wait(c.io) catch |err| {
            if (err != error.Canceled) return err;
            self.cancelled.set(c.io);
            const protection = c.io.swapCancelProtection(.blocked);
            defer _ = c.io.swapCancelProtection(protection);
            self.release.waitUncancelable(c.io);
        };
        return .{ .fact = 7 };
    }
};

test "joined shutdown persists completed obsolete effect facts without resuming a VM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", a);
    var effect: HeldFact = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &effect, .operations = &.{&HeldFact.operation} }} });
    defer controller.close();
    defer effect.release.set(io);
    const config: agent.Config = .{ .session_id = "late-fact", .journal_path = try std.fs.path.join(a, &.{ workspace, "worker.gz" }), .endpoint_grants = &.{"fixture.fact"}, .capabilities = &.{.{ .source_name = "fact", .source = "return {name='fact',version=1,description='fact',parameters={type='object'},endpoints={'fixture.fact'},recovery='never',execute=function(args)return host.call('fixture.fact',args)end}" }}, .application = .{ .source = "if input.hold then tools.fact({}); ctx.obsolete=true elseif input.loop then while true do end else ctx.replaced=true end; return true" } };
    const worker = try controller.start(config);
    const old = try controller.deliver(worker, "old-fact", .{ .input_json = "{\"hold\":true}" });
    defer old.deinit();
    try effect.entered.waitTimeout(io, timeout);
    const replacement = try controller.deliver(worker, "replacement", .{ .input_json = "{}", .replace = old.id });
    defer replacement.deinit();
    var result = try completed(replacement);
    defer result.deinit();
    try effect.cancelled.waitTimeout(io, timeout);
    const guard = try controller.deliver(worker, "shutdown-guard", .{ .input_json = "{\"loop\":true}" });
    defer guard.deinit();
    var stopping: StopWorker = .{ .controller = controller, .worker = worker };
    var joining = try io.concurrent(StopWorker.run, .{ &stopping, io });
    defer {
        effect.release.set(io);
        joining.cancel(io);
    }
    try guard.done.waitTimeout(io, timeout);
    try std.testing.expectError(error.WorkerStopped, guard.wait(io));
    try std.testing.expect(!stopping.done.isSet());
    effect.release.set(io);
    try stopping.done.waitTimeout(io, timeout);
    joining.await(io);
    if (stopping.failure) |err| return err;
    const reopened = try controller.start(config);
    var snapshot = try controller.inspect(reopened, std.testing.allocator);
    defer snapshot.deinit();
    const ctx = j.get(snapshot.value, "ctx");
    try std.testing.expect(j.get(ctx, "replaced").bool);
    try std.testing.expect(j.get(ctx, "obsolete") == .null);
    const receipts = j.get(snapshot.value, "late_receipts").array.items;
    try std.testing.expectEqual(1, receipts.len);
    try std.testing.expectEqualStrings("old-fact", try j.text(j.get(receipts[0], "invocation")));
    try std.testing.expect(j.get(receipts[0], "cancel_requested").bool);
    try std.testing.expectEqual(3, j.get(receipts[0], "outcome_kind").integer);
    try std.testing.expectEqual(7, j.get(j.get(receipts[0], "outcome"), "fact").integer);
}

test "boundary deliveries wait for checkpoints, can be withdrawn, and follow a naturally ended target" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |natural| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
        var fixture: Fixture = .{ .server = try address.listen(io, .{}), .stall_first = true, .hold_second = true };
        defer fixture.server.deinit(io);
        var server = try io.concurrent(Fixture.run, .{ &fixture, io });
        defer server.cancel(io);
        const base = try fixture.base(a);
        const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .providers = &.{.{ .base_url = base, .transport = try agent.provider.Effects.initFixture(a, ".", base) }} });
        defer controller.close();
        defer fixture.release.set(io);
        defer fixture.release_second.set(io);
        const worker = try controller.start(.{ .session_id = if (natural) "natural" else "boundary", .persistence = .memory, .model = .{ .base_url = base }, .endpoint_grants = &.{"model.request"}, .application = .{ .source = "ctx.input=input.text; agent.model({model='fixture',input={{role='user',content=input.text}}}); ctx.after_effect=input.text; if not input.natural then agent.checkpoint({value=input.text}, true) end; ctx.finished=input.text; return input.text" } });
        const old = try controller.deliver(worker, "old", .{ .input_json = if (natural) "{\"text\":\"old\",\"natural\":true}" else "{\"text\":\"old\"}" });
        defer old.deinit();
        try fixture.first.waitTimeout(io, timeout);
        const withdrawn = try controller.deliver(worker, "withdrawn", .{ .input_json = "{\"text\":\"withdrawn\"}", .replace = old.id, .boundary = true });
        defer withdrawn.deinit();
        const cancel = try controller.cancelInvocation(worker, "withdraw", withdrawn.id);
        defer cancel.deinit();
        var cancelled = try completed(cancel);
        defer cancelled.deinit();
        try std.testing.expect(!old.done.isSet());
        const next = try controller.deliver(worker, "next", .{ .input_json = "{\"text\":\"next\"}", .replace = old.id, .boundary = true });
        defer next.deinit();
        var snapshot = try controller.inspect(worker, a);
        defer snapshot.deinit();
        try std.testing.expect(!next.done.isSet());
        try std.testing.expectEqual(1, fixture.requests.load(.acquire));
        fixture.release.set(io);
        try fixture.second.waitTimeout(io, timeout);
        fixture.release_second.set(io);
        var outcome = try completed(next);
        defer outcome.deinit();
        try std.testing.expectEqualStrings("next", try j.text(outcome.result));
        var old_outcome = try old.wait(io);
        defer old_outcome.deinit();
        try std.testing.expectEqual(@as(@TypeOf(old_outcome.status), if (natural) .completed else .cancelled), old_outcome.status);
        var ctx = try controller.readContext(worker, a);
        defer ctx.deinit();
        try std.testing.expectEqualStrings("next", try j.text(j.get(ctx.value, "finished")));
        try std.testing.expectEqual(2, fixture.requests.load(.acquire));
        const stale = try controller.deliver(worker, "stale-boundary", .{ .input_json = "{\"text\":\"stale\"}", .replace = old.id, .boundary = true });
        defer stale.deinit();
        try stale.done.waitTimeout(io, timeout);
        var rejected = try stale.wait(io);
        defer rejected.deinit();
        try std.testing.expectEqual(.failed, rejected.status);
        try std.testing.expectEqualStrings("stale_invocation", try j.text(j.get(rejected.diagnostic, "code")));
    }
}
