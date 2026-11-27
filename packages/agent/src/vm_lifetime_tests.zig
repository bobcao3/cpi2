const std = @import("std");
const agent = @import("root.zig");
const vm = @import("vm");
const services = @import("services");
const j = @import("json.zig");
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };

fn completed(request: *agent.Request) !agent.Outcome {
    try request.done.waitTimeout(std.testing.io, timeout);
    var outcome = try request.wait(std.testing.io);
    errdefer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    return outcome;
}

const allow = "local calls=0; return function(event,state) calls+=1; return {allow=calls==1} end";
const counter = "assert(ctx==nil and agent==nil and native==nil and getfenv==nil and tools==nil); local calls=0; return {name='counter',version=1,description='counter',parameters={type='object'},endpoints={},recovery='never',execute=function(args) calls+=1; return {calls=calls,value=args.value} end}";

test "registered admission releases its tool on allocation failure" {
    const Session = @import("Session.zig");
    const a = std.testing.allocator;
    const payload = try j.encode(a, .{ .source = counter });
    defer a.free(payload);
    var failures: usize = 0;
    var succeeded = false;
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = offset });
        const worker = try Session.prepare(a, std.testing.io, "admission-oom", ".", "memory", "{}", j.array(a));
        defer worker.deinit();
        const tool = try worker.heap.registerTool(counter);
        var tool_owned = true;
        defer if (tool_owned) tool.release();
        const result = blk: {
            worker.gpa = failing.allocator();
            defer worker.gpa = a;
            break :blk worker.admitRegistered("register", 6, payload, tool);
        };
        tool.release();
        tool_owned = false;
        if (result) |_| {
            try std.testing.expectEqual(1, worker.admissions.items.len);
            try std.testing.expectEqual(1, worker.heap.usage().registered_versions);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(0, worker.admissions.items.len);
            try std.testing.expectEqual(0, worker.heap.usage().registered_versions);
            failures += 1;
        }
    }
    try std.testing.expect(failures > 0 and succeeded);
}

test "native owner boundaries and real registrations survive repeated calls without re-evaluation" {
    const io = std.testing.io;
    const before = vm.counts();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    var closed = false;
    defer if (!closed) controller.close();
    const worker = try controller.start(.{ .session_id = "native-lifetimes", .persistence = .memory });
    const owners = vm.counts();
    try std.testing.expectEqual(2, owners.heaps_opened - before.heaps_opened);
    try std.testing.expectEqual(2, owners.bootstrap_loads - before.bootstrap_loads);
    for (0..4) |index| {
        const name = try std.fmt.allocPrint(a, "v{d}", .{index});
        const source = try std.mem.replaceOwned(u8, a, counter, "counter", name);
        const request = try controller.submit(worker, name, .{ .register_capability = .{ .source_name = name, .source = source } });
        defer request.deinit();
        var outcome = try completed(request);
        defer outcome.deinit();
        try std.testing.expectEqual(index + 1, outcome.capabilities_revision);
        const duplicate = try controller.submit(worker, name, .{ .register_capability = .{ .source_name = name, .source = source } });
        defer duplicate.deinit();
        var same = try completed(duplicate);
        defer same.deinit();
        try std.testing.expectEqual(outcome.capabilities_revision, same.capabilities_revision);
    }
    const registered = vm.counts();
    try std.testing.expectEqual(4, registered.tool_registrations - owners.tool_registrations);
    const source = "leaked=(leaked or 0)+1; return {localOnly=leaked,first=tools.v0({value=17}),last=tools.v3({value=93})}";
    for (0..6) |index| {
        const request = try controller.submit(worker, try std.fmt.allocPrint(a, "invoke-{d}", .{index}), .{ .lua = source });
        defer request.deinit();
        var outcome = try completed(request);
        defer outcome.deinit();
        try std.testing.expectEqual(1, j.number(j.get(outcome.result, "localOnly")));
        try std.testing.expectEqual(index + 1, j.number(j.get(j.get(outcome.result, "first"), "calls")));
        try std.testing.expectEqual(17, j.number(j.get(j.get(outcome.result, "first"), "value")));
        try std.testing.expectEqual(index + 1, j.number(j.get(j.get(outcome.result, "last"), "calls")));
        try std.testing.expectEqual(93, j.number(j.get(j.get(outcome.result, "last"), "value")));
        var snapshot = try controller.readContext(worker, a);
        snapshot.deinit();
        const program = try controller.program(try std.fmt.allocPrint(a, "program-{d}", .{index}), "leaked=(leaked or 0)+1; return {localOnly=leaked,input=input}", .{ .integer = @intCast(index + 7) });
        defer program.deinit();
        var result = try completed(program);
        defer result.deinit();
        try std.testing.expectEqual(1, j.number(j.get(result.result, "localOnly")));
        try std.testing.expectEqual(index + 7, j.number(j.get(result.result, "input")));
    }
    const repeated = vm.counts();
    try std.testing.expectEqual(2, repeated.heaps_opened - before.heaps_opened);
    try std.testing.expectEqual(0, repeated.heaps_closed - before.heaps_closed);
    try std.testing.expectEqual(2, repeated.bootstrap_loads - before.bootstrap_loads);
    try std.testing.expectEqual(0, repeated.tool_registrations - registered.tool_registrations);
    controller.close();
    closed = true;
    const after = vm.counts();
    try std.testing.expectEqual(2, after.heaps_closed - before.heaps_closed);
    try std.testing.expectEqual(after.activations_started - before.activations_started, after.activations_finished - before.activations_finished);
    std.debug.print("VM lifetime runtime check: heaps={d}, closes={d}, bootstrap={d}, fresh registrations={d}, registration compiles={d}, repeat compiles={d}, repeated registrations={d}, activations={d}/{d}\n", .{ after.heaps_opened - before.heaps_opened, after.heaps_closed - before.heaps_closed, after.bootstrap_loads - before.bootstrap_loads, registered.tool_registrations - owners.tool_registrations, registered.compilations - owners.compilations, repeated.compilations - registered.compilations, repeated.tool_registrations - registered.tool_registrations, after.activations_started - before.activations_started, after.activations_finished - before.activations_finished });
}

const Hold = struct {
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    const Args = struct {};
    const operation = services.Operation.define("fixture.hold", Hold, Args, bool, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *Hold, c: services.Context, _: Args) anyerror!bool {
        self.entered.set(c.io);
        try self.release.wait(c.io);
        return true;
    }
};

const holding = "local calls=0; return {name='hold',version=1,description='hold',parameters={type='object'},endpoints={'fixture.hold'},recovery='never',execute=function(args) calls+=1; local ok=host.call('fixture.hold',{}); return {calls=calls,ok=ok,version=1} end}";

test "live tool replacement and registration during a Worker effect retain the captured version" {
    const io = std.testing.io;
    var hold: Hold = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &hold, .operations = &.{&Hold.operation} }} });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "captured-version", .persistence = .memory, .endpoint_grants = &.{"fixture.hold"}, .capabilities = &.{.{ .source_name = "hold", .source = holding }} });
    const request = try controller.submit(worker, "old", .{ .lua = "ctx.tag='old'; return tools.hold({})" });
    defer request.deinit();
    try hold.entered.waitTimeout(io, timeout);
    const before = vm.counts();
    const replacement = try controller.submit(worker, "replace", .{ .register_capability = .{ .source_name = "hold", .source = "local calls=100; return {name='hold',version=2,description='hold',parameters={type='object'},endpoints={},recovery='never',execute=function(args) calls+=1; return {calls=calls,version=2} end}" } });
    defer replacement.deinit();
    var replaced = try completed(replacement);
    defer replaced.deinit();
    try std.testing.expectEqual(1, vm.counts().tool_registrations - before.tool_registrations);
    try std.testing.expectEqual(before.heaps_opened, vm.counts().heaps_opened);
    hold.release.set(io);
    var old = try completed(request);
    defer old.deinit();
    try std.testing.expectEqual(1, j.number(j.get(old.result, "calls")));
    try std.testing.expectEqual(1, j.number(j.get(old.result, "version")));
    for (0..2) |index| {
        const next = try controller.submit(worker, if (index == 0) "new-1" else "new-2", .{ .lua = "return tools.hold({})" });
        defer next.deinit();
        var result = try completed(next);
        defer result.deinit();
        try std.testing.expectEqual(101 + index, j.number(j.get(result.result, "calls")));
        try std.testing.expectEqual(2, j.number(j.get(result.result, "version")));
    }
}

test "policy calls share a heap with an effect-suspended serialized trusted program" {
    const io = std.testing.io;
    var hold: Hold = .{};
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow, .services = &.{.{ .context = &hold, .operations = &.{&Hold.operation} }}, .program_grants = &.{"fixture.hold"} });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "policy-during-program", .persistence = .memory });
    const first = try controller.program("first", "ctx.first=true; host.call('fixture.hold',{}); ctx.finished=true; return input", .{ .integer = 31 });
    defer first.deinit();
    try hold.entered.waitTimeout(io, timeout);
    const second = try controller.program("second", "assert(ctx.finished); return input", .{ .integer = 47 });
    defer second.deinit();
    const before = vm.counts();
    const command = try controller.submit(worker, "during", .{ .lua = "return 19" });
    defer command.deinit();
    var result = try completed(command);
    defer result.deinit();
    try std.testing.expectEqual(19, result.result.integer);
    try std.testing.expect(!second.done.isSet());
    try std.testing.expectEqual(before.heaps_opened, vm.counts().heaps_opened);
    hold.release.set(io);
    var one = try completed(first);
    defer one.deinit();
    var two = try completed(second);
    defer two.deinit();
    try std.testing.expectEqual(31, one.result.integer);
    try std.testing.expectEqual(47, two.result.integer);
}

test "same owner recovers from registration errors OOM and bounded version churn" {
    const a = std.testing.allocator;
    const before = vm.counts();
    const cap = 4 * 1024 * 1024;
    const ledger = try vm.MemoryBudget.create(a, cap);
    defer ledger.release();
    var owner = try vm.Owner.init(ledger.allocator(), std.testing.io);
    var closed = false;
    defer if (!closed) owner.deinit();
    for (0..6) |_| {
        try std.testing.expectError(error.InvalidExtension, owner.registerTool("local ="));
        try std.testing.expectError(error.InvalidExtension, owner.registerTool("pcall(function() host.call('files.write',{}) end); " ++ counter));
        try std.testing.expectError(error.InvalidExtension, owner.registerTool("pcall(function() output.image({}) end); " ++ counter));
        try std.testing.expectError(error.LimitExceeded, owner.registerTool("local values={}; while true do table.insert(values,string.rep('x',4096)..tostring(#values)) end"));
        var invocation = try owner.begin(a, "{}", &.{}, "return 37");
        defer invocation.deinit();
        try std.testing.expectEqualStrings("37", (try invocation.step(10000, null)).done.result_json);
    }
    for (0..300) |index| {
        const source = try std.fmt.allocPrint(a, "local payload=string.rep('x',8192); {s} -- version {d}", .{ counter, index });
        defer a.free(source);
        const tool = try owner.registerTool(source);
        try std.testing.expectEqual(1, owner.usage().registered_versions);
        tool.release();
        try std.testing.expectEqual(0, owner.usage().registered_versions);
        try std.testing.expect(owner.usage().heap_bytes < cap);
    }
    const after = vm.counts();
    try std.testing.expectEqual(1, after.heaps_opened - before.heaps_opened);
    try std.testing.expectEqual(0, after.heaps_closed - before.heaps_closed);
    try std.testing.expectEqual(1, after.bootstrap_loads - before.bootstrap_loads);
    try std.testing.expectEqual(after.activations_started - before.activations_started, after.activations_finished - before.activations_finished);
    const retained = owner.usage().heap_bytes;
    owner.deinit();
    closed = true;
    std.debug.print("VM churn runtime check: one heap, 300 retired versions, six OOM recoveries, retained={d} < cap={d}\n", .{ retained, cap });
}

test "candidate denial after warming cannot install tools or retain registration authority" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: services.Files = .{ .workspace = try tmp.dir.realPathFileAlloc(io, ".", a) };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = "return function(event,state) return {allow=event.arguments.source_name~='policy-denied'} end", .services = &.{files.service()} });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "candidate-denial", .persistence = .memory, .capabilities = &.{.{ .source_name = "counter", .source = counter }} });
    const before = vm.counts();
    const denied = "return {name='denied',version=1,description='denied',parameters={type='object'},endpoints={'files.write'},recovery='never',execute=function(args) return host.call('files.write',args) end}";
    try std.testing.expectError(error.PermissionDenied, controller.submit(worker, "cap-denied", .{ .register_capability = .{ .source_name = "cap-denied", .source = denied } }));
    try std.testing.expectError(error.PermissionDenied, controller.submit(worker, "policy-denied", .{ .register_capability = .{ .source_name = "policy-denied", .source = "return {name='denied',version=1,description='denied',parameters={type='object'},endpoints={},recovery='never',execute=function() return 9 end}" } }));
    for (0..12) |index| {
        const source = try std.fmt.allocPrint(a, "pcall(function() host.call('files.write',{{path='forbidden',content='bad'}}) end); {s}", .{counter});
        try std.testing.expectError(error.InvalidExtension, controller.submit(worker, try std.fmt.allocPrint(a, "factory-{d}", .{index}), .{ .register_capability = .{ .source_name = "factory", .source = source } }));
    }
    const request = try controller.submit(worker, "still-live", .{ .lua = "assert(tools.denied==nil); return tools.counter({value=41})" });
    defer request.deinit();
    var result = try completed(request);
    defer result.deinit();
    try std.testing.expectEqual(1, j.number(j.get(result.result, "calls")));
    try std.testing.expectEqual(1, result.capabilities_revision);
    try std.testing.expectEqual(before.heaps_opened, vm.counts().heaps_opened);
    try std.testing.expectEqual(14, vm.counts().tool_registrations - before.tool_registrations);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "forbidden", .{}));
}

test "registered lexical state belongs to one Worker and resets for a new registered version" {
    const io = std.testing.io;
    const controller = try agent.Controller.open(std.testing.allocator, io, .{ .authorize = allow });
    defer controller.close();
    const first = try controller.start(.{ .session_id = "lexical-first", .persistence = .memory, .capabilities = &.{.{ .source_name = "counter", .source = counter }} });
    const second = try controller.start(.{ .session_id = "lexical-second", .persistence = .memory, .capabilities = &.{.{ .source_name = "counter", .source = counter }} });
    for ([_]agent.WorkerId{ first, first, second }, [_][]const u8{ "one", "two", "three" }, [_]u64{ 1, 2, 1 }) |worker, id, expected| {
        const request = try controller.submit(worker, id, .{ .lua = "return tools.counter({})" });
        defer request.deinit();
        var result = try completed(request);
        defer result.deinit();
        try std.testing.expectEqual(expected, j.number(j.get(result.result, "calls")));
    }
    const before = vm.counts();
    const replace = try controller.submit(first, "new-version", .{ .register_capability = .{ .source_name = "counter", .source = counter } });
    defer replace.deinit();
    var replacement = try completed(replace);
    defer replacement.deinit();
    const invoke = try controller.submit(first, "reset", .{ .lua = "return tools.counter({})" });
    defer invoke.deinit();
    var reset = try completed(invoke);
    defer reset.deinit();
    try std.testing.expectEqual(1, j.number(j.get(reset.result, "calls")));
    try std.testing.expectEqual(1, vm.counts().tool_registrations - before.tool_registrations);
}

test "registered tool caches preserve JSON null and empty array identity across invocations" {
    const a = std.testing.allocator;
    var owner = try vm.Owner.init(a, std.testing.io);
    defer owner.deinit();
    const source = "local saved; return {name='memo',version=1,description='memo',parameters={type='object'},endpoints={'fixture.json'},recovery='never',execute=function(args) if args.save then saved=host.call('fixture.json',{}) end; return saved end}";
    const tool = try owner.registerTool(source);
    defer tool.release();
    {
        var first = try owner.begin(a, "{}", &.{.{ .name = "memo", .source = source, .registered = tool }}, "return tools.memo({save=true})");
        defer first.deinit();
        try std.testing.expect((try first.step(10000, null)) == .effect);
        const result = try first.step(10000, .{ .json = "{\"nothing\":null,\"empty\":[]}" });
        try std.testing.expect(result == .done);
    }
    var second = try owner.begin(a, "{}", &.{.{ .name = "memo", .source = source, .registered = tool }}, "return tools.memo({})");
    defer second.deinit();
    const result = try second.step(10000, null);
    try std.testing.expect(result == .done);
    var parsed = try j.Document.init(a, result.done.result_json);
    defer parsed.deinit();
    try std.testing.expectEqual(.null, std.meta.activeTag(j.get(parsed.value, "nothing")));
    try std.testing.expectEqual(.array, std.meta.activeTag(j.get(parsed.value, "empty")));
    try std.testing.expectEqual(0, j.get(parsed.value, "empty").array.items.len);
}

test "registered module globals tolerate single-safepoint slices and rooted yields survive other activations" {
    const a = std.testing.allocator;
    var owner = try vm.Owner.init(a, std.testing.io);
    defer owner.deinit();
    const source = "return {name='slice',version=1,description='slice',parameters={type='object'},endpoints={'fixture.hold'},recovery='never',execute=function() local n=0; for i=1,300 do assert(type(tostring(i))=='string'); n+=math.floor(i/3) end; return host.call('fixture.hold',{value=n}) end}";
    const tool = try owner.registerTool(source);
    defer tool.release();
    var invocation = try owner.begin(a, "{\"tag\":\"original\"}", &.{.{ .name = "slice", .source = source, .registered = tool }}, "return tools.slice({})");
    defer invocation.deinit();
    var effect: ?vm.Yield = null;
    for (0..10000) |_| {
        const step = try invocation.step(1, null);
        if (step == .effect) {
            effect = step.effect;
            break;
        }
        try std.testing.expect(step == .budget);
    }
    try std.testing.expect(effect != null);
    const held = effect.?;
    var policy = try owner.beginPolicy(a, "{}", "return {allow=true}", "{}", false);
    defer policy.deinit();
    try std.testing.expect((try policy.step(10000, null)) == .done);
    const rejected = owner.registerTool("local values={}; for i=1,1000 do values[i]={i} end; error('expected')");
    try std.testing.expectError(error.InvalidExtension, rejected);
    try std.testing.expectEqualStrings("slice", held.tool_name);
    try std.testing.expectEqualStrings("{\"tag\":\"original\"}", held.ctx_json);
    try std.testing.expectEqualStrings("{\"value\":14950}", held.arguments_json);
    var reply: ?vm.Reply = .{ .json = "true" };
    for (0..10000) |_| {
        const step = try invocation.step(1, reply);
        reply = null;
        if (step == .done) {
            try std.testing.expectEqualStrings("true", step.done.result_json);
            return;
        }
        try std.testing.expect(step == .budget);
    }
    return error.NoProgress;
}

test "policy and trusted input data retain literal semantics without spending module instruction budget" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const controller = try agent.Controller.open(a, io, .{ .authorize = "return function(event,state) return {allow=event.arguments.optional==nil} end" });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = "large-data", .persistence = .memory });
    const source = try a.alloc(u8, 300000);
    defer a.free(source);
    @memcpy(source[0..13], "return 13 -- ");
    @memset(source[13..], 'x');
    const request = try controller.submit(worker, "large-event", .{ .lua = source });
    defer request.deinit();
    var result = try completed(request);
    defer result.deinit();
    try std.testing.expectEqual(13, result.result.integer);
    const program = try controller.program("null-input", "assert(input==nil); return 29", .null);
    defer program.deinit();
    var nil_input = try completed(program);
    defer nil_input.deinit();
    try std.testing.expectEqual(29, nil_input.result.integer);
}

test "shared math bindings do not share random state between suspended activations" {
    const a = std.testing.allocator;
    var owner = try vm.Owner.init(a, std.testing.io);
    defer owner.deinit();
    const registered = try owner.registerTool(holding);
    defer registered.release();
    var suspended = try owner.begin(a, "{}", &.{.{ .name = "hold", .source = holding, .registered = registered }}, "math.randomseed(71); local first=math.random(); tools.hold({}); return {first,math.random()}");
    defer suspended.deinit();
    try std.testing.expect((try suspended.step(10000, null)) == .effect);
    var control = try owner.begin(a, "{}", &.{}, "math.randomseed(71); return {math.random(),math.random()}");
    defer control.deinit();
    const expected = (try control.step(10000, null)).done.result_json;
    var other = try owner.begin(a, "{}", &.{}, "math.randomseed(99); for i=1,20 do math.random() end; return true");
    defer other.deinit();
    try std.testing.expect((try other.step(10000, null)) == .done);
    const actual = (try suspended.step(10000, .{ .json = "true" })).done.result_json;
    try std.testing.expectEqualStrings(expected, actual);
}
