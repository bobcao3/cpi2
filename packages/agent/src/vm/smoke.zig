const std = @import("std");
const json_text = @import("json_tree").text;
const api = @import("vm");
const testing = std.testing;
const read_source = @embedFile("read_source");
const bash_source = @embedFile("bash_source");
const limit = 4 * 1024 * 1024;
const tools: []const api.Tool = &.{ .{ .name = "read", .source = read_source }, .{ .name = "bash", .source = bash_source } };

fn next(vm: *api.Vm, reply: ?api.Reply) !api.Step {
    var response = reply;
    for (0..10000) |_| {
        const step = try vm.step(100, response);
        response = null;
        switch (step) {
            .budget => {},
            .failed => |failure| {
                std.debug.print("unexpected Lua error: {s}\n", .{failure.message});
                return error.LuaFailed;
            },
            else => return step,
        }
    }
    return error.NoProgress;
}

fn parse(json: []const u8) !std.json.Parsed(std.json.Value) {
    return json_text.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

test "actual extension metadata and bootstrap effect rejection" {
    for (tools) |tool| {
        const json = try describe(tool.source);
        defer testing.allocator.free(json);
        const metadata = try parse(json);
        defer metadata.deinit();
        try testing.expectEqualStrings(tool.name, metadata.value.object.get("name").?.string);
        try testing.expect(metadata.value.object.get("execute") == null);
        try testing.expectEqual(@as(usize, 1), metadata.value.object.get("endpoints").?.array.items.len);
    }
    const malicious = "pcall(function() host.call(nil, function() end) end)\n" ++ read_source;
    try testing.expectError(error.InvalidExtension, describe(malicious));
    try testing.expectError(error.LimitExceeded, describe("while true do end"));
    try testing.expectError(error.InvalidExtension, describe("return {name='bad'}"));
    try testing.expectError(error.InvalidExtension, describe(
        "return {name='old',version=1,description='Old',parameters={type='object',properties={}},capabilities={},recovery='never',execute=function() end}",
    ));
    try testing.expectError(error.InvalidLua, init("{}", &.{}, "local ="));
}

test "read and bash checkpoint arguments, JSON snapshots, native resume" {
    var vm = try init("{\"greeting\":\"quote\\\" slash\\\\ newline\\n 😺\",\"empty\":[],\"nothing\":null}", tools,
        \\assert(host == nil and getfenv == nil and setfenv == nil and debug == nil and os == nil and coroutine == nil and setmetatable == nil)
        \\assert(not pcall(function() rawset(tools, 'read', 1) end))
        \\assert(not pcall(function() math.pi = 1 end))
        \\assert(string.match == nil and getmetatable('').__index.match == nil)
        \\ctx.before = true
        \\local first = tools.read({path=ctx.greeting, offset_bytes=2})
        \\ctx.text = first.text
        \\local second = tools.bash({command='printf hello'})
        \\return {first=first, second=second, empty=ctx.empty, nothing=ctx.nothing}
    );
    defer vm.deinit();
    const first = (try next(&vm, null)).effect;
    try testing.expectEqualStrings("read", first.tool_name);
    try testing.expectEqualStrings("files.read", first.endpoint);
    const args = try parse(first.arguments_json);
    defer args.deinit();
    try testing.expectEqualStrings("quote\" slash\\ newline\n 😺", args.value.object.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), args.value.object.get("offset").?.integer);
    try testing.expectEqual(@as(i64, 65536), args.value.object.get("limit").?.integer);
    const before = try parse(first.ctx_json);
    defer before.deinit();
    try testing.expect(before.value.object.get("before").?.bool);
    try testing.expect(before.value.object.get("text") == null);
    const second = (try next(&vm, .{ .json = "{\"text\":\"你好\\n\",\"offset\":2,\"eof\":true}" })).effect;
    try testing.expectEqualStrings("bash", second.tool_name);
    try testing.expectEqualStrings("process.exec", second.endpoint);
    const command = try parse(second.arguments_json);
    defer command.deinit();
    try testing.expectEqualStrings("bash", command.value.object.get("argv").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 30000), command.value.object.get("timeout_ms").?.integer);
    const checkpoint = try parse(second.ctx_json);
    defer checkpoint.deinit();
    try testing.expectEqualStrings("你好\n", checkpoint.value.object.get("text").?.string);
    const done = (try next(&vm, .{ .json = "{\"exit_code\":7,\"stdout\":\"\",\"stderr\":\"no\",\"truncated\":false}" })).done;
    const result = try parse(done.result_json);
    defer result.deinit();
    try testing.expectEqual(@as(i64, 7), result.value.object.get("second").?.object.get("exit_code").?.integer);
    try testing.expect(result.value.object.get("empty").? == .array);
    try testing.expect(result.value.object.get("nothing").? == .null);
}

test "failed native replies raise catchable Lua errors" {
    var vm = try init("{}", tools, "local ok, err = pcall(function() return tools.read({path='x'}) end); return {ok=ok, err=err}");
    defer vm.deinit();
    _ = (try next(&vm, null)).effect;
    const done = (try next(&vm, .{ .json = "{\"message\":\"denied\"}", .failed = true })).done;
    const result = try parse(done.result_json);
    defer result.deinit();
    try testing.expect(!result.value.object.get("ok").?.bool);
    try testing.expect(std.mem.indexOf(u8, result.value.object.get("err").?.string, "denied") != null);
}

test "budget suspension makes progress and infinite Lua stays interruptible" {
    var vm = try init("{}", &.{}, "local sum=0; for i=1,10000 do sum+=i end; ctx.sum=sum; return sum");
    defer vm.deinit();
    try testing.expect((try vm.step(1, null)) == .budget);
    const done = (try next(&vm, null)).done;
    try testing.expectEqualStrings("50005000", done.result_json);
    for ([_][]const u8{ "while true do end", "pcall(function() while true do end end)", "table.sort({2,1}, function() while true do end end)" }) |source| {
        var infinite = try init("{}", &.{}, source);
        defer infinite.deinit();
        for (0..3) |_| {
            const step = try infinite.step(10, null);
            if (step == .failed) std.debug.print("interrupt source={s}: {s}\n", .{ source, step.failed.message });
            try testing.expect(step == .budget);
        }
    }
}

test "schema, serializability and memory failures are bounded runtime failures" {
    const programs = [_][]const u8{
        "return tools.read({path=''})",
        "return tools.read({path='x', extra=true})",
        "ctx.self=ctx; return true",
        "ctx.f=function() end; return true",
        "return string.char(255)",
        "return 0/0",
        "return {[1]=true, [3]=true}",
        "return string.rep('x', 100000000)",
        "error({message='not a string'})",
        "error(string.char(255,0))",
    };
    for (programs) |source| {
        var vm = try init("{}", tools, source);
        defer vm.deinit();
        var failed = false;
        for (0..1000) |_| {
            switch (try vm.step(1000, null)) {
                .budget => {},
                .failed => |failure| {
                    const message = failure.message;
                    try testing.expect(message.len > 0);
                    try testing.expect(std.unicode.utf8ValidateSlice(message));
                    failed = true;
                    break;
                },
                else => return error.ExpectedFailure,
            }
        }
        try testing.expect(failed);
    }
    const tiny = try api.MemoryBudget.create(testing.allocator, 256);
    defer tiny.release();
    try testing.expectError(error.LimitExceeded, api.Vm.init(tiny.allocator(), "{}", &.{}, "return 1"));
}

test "JSON round trips Unicode escapes, nulls, empty containers and rejects malformed inputs" {
    var vm = try init("{\"a\":[null,{},[],true,false,-12.5e2],\"n\":\"\\u0000\\b\\f\\r\\t\\n\",\"u\":\"\\uD83D\\uDE3A\",\"\\u006b\":\"v\"}", &.{}, "return ctx");
    defer vm.deinit();
    const done = (try next(&vm, null)).done;
    const result = try parse(done.result_json);
    defer result.deinit();
    const items = result.value.object.get("a").?.array.items;
    try testing.expect(items[0] == .null and items[1] == .object and items[2] == .array);
    try testing.expect(items[3].bool and !items[4].bool);
    try testing.expectEqual(@as(i64, -1250), items[5].integer);
    try testing.expectEqualStrings("\x00\x08\x0c\r\t\n", result.value.object.get("n").?.string);
    try testing.expectEqualStrings("😺", result.value.object.get("u").?.string);
    try testing.expectEqualStrings("v", result.value.object.get("k").?.string);
    for ([_][]const u8{ "", "+1", "01", "1e9999", "[1,]", "{\"a\":1,\"a\":2}", "\"\\uD800\"", "\"\\uDC00\"", "\"\xff\"", "true false" }) |json| {
        try testing.expectError(error.InvalidJson, init(json, &.{}, "return ctx"));
    }
}

test "restored context data does not spend the untrusted module initialization budget" {
    const payload = try testing.allocator.alloc(u8, 60000);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    const context = try std.json.Stringify.valueAlloc(testing.allocator, .{ .text = payload }, .{});
    defer testing.allocator.free(context);
    var vm = try init(context, &.{}, "return ctx.text");
    defer vm.deinit();
    const done = (try next(&vm, null)).done;
    const result = try parse(done.result_json);
    defer result.deinit();
    try testing.expectEqualStrings(payload, result.value.string);
    try testing.expectError(error.LimitExceeded, init(context, &.{.{ .name = "busy", .source = "while true do end" }}, "return ctx.text"));
}

test "nested tools retain native identity and standalone owners have private module locals" {
    const nested_source =
        \\local calls = 0
        \\return {name='nested', version=1, description='nested test', parameters={type='object'},
        \\endpoints={'custom.audit'}, recovery='never', execute=function(args)
        \\calls += 1
        \\if args.local_only then return calls end
        \\local read = tools.read({path='nested.txt'})
        \\return host.call('custom.audit', {text=read.text})
        \\end}
    ;
    const definitions: []const api.Tool = &.{ tools[0], .{ .name = "nested", .source = nested_source } };
    var vm = try init("{}", definitions, "return tools.nested({})");
    defer vm.deinit();
    try testing.expectEqualStrings("read", (try next(&vm, null)).effect.tool_name);
    const inner = (try next(&vm, .{ .json = "{\"text\":\"nested result\",\"offset\":0,\"eof\":true}" })).effect;
    try testing.expectEqualStrings("nested", inner.tool_name);
    try testing.expectEqualStrings("custom.audit", inner.endpoint);
    try testing.expectEqualStrings("{\"text\":\"nested result\"}", inner.arguments_json);
    try testing.expectEqualStrings("true", (try next(&vm, .{ .json = "true" })).done.result_json);
    for (0..2) |_| {
        var fresh = try init("{}", definitions, "return {tools.nested({local_only=true}), tools.nested({local_only=true})}");
        defer fresh.deinit();
        try testing.expectEqualStrings("[1,2]", (try next(&fresh, null)).done.result_json);
    }
}

test "safe sort and plain substring search resume and produce correct results" {
    var vm = try init("{}", &.{},
        \\local values = {9,-1,4,4,0,17,2}
        \\table.sort(values, function(a,b) return a < b end)
        \\local text = string.rep('a',10000)..'b'
        \\local first,last = text:find('aaaab')
        \\return {values=values, first=first, last=last, literal=('a.b'):find('%.')}
    );
    defer vm.deinit();
    try testing.expect((try vm.step(1, null)) == .budget);
    const result = try parse((try next(&vm, null)).done.result_json);
    defer result.deinit();
    const sorted = result.value.object.get("values").?.array.items;
    for (sorted, [_]i64{ -1, 0, 2, 4, 4, 9, 17 }) |actual, expected| try testing.expectEqual(expected, actual.integer);
    try testing.expectEqual(@as(i64, 9997), result.value.object.get("first").?.integer);
    try testing.expectEqual(@as(i64, 10001), result.value.object.get("last").?.integer);
    try testing.expect(result.value.object.get("literal") == null);
}

test "small heap limits fail inside protected native boundaries" {
    for ([_]usize{ 1024, 8192, 65536, 131072, 262144, 524288, 1048576 }) |bytes| {
        const ledger = try api.MemoryBudget.create(testing.allocator, bytes);
        defer ledger.release();
        var vm = api.Vm.init(ledger.allocator(), "{}", &.{}, "return 1") catch |err| {
            try testing.expect(err == error.LimitExceeded or err == error.OutOfMemory);
            continue;
        };
        defer vm.deinit();
        try testing.expectEqualStrings("1", (try next(&vm, null)).done.result_json);
    }
}

fn init(ctx: []const u8, definitions: []const api.Tool, source: []const u8) !api.Vm {
    const ledger = try api.MemoryBudget.create(testing.allocator, limit);
    defer ledger.release();
    return api.Vm.init(ledger.allocator(), ctx, definitions, source);
}
fn describe(source: []const u8) ![]u8 {
    const ledger = try api.MemoryBudget.create(testing.allocator, limit);
    defer ledger.release();
    const metadata = try api.describe(ledger.allocator(), source);
    defer ledger.allocator().free(metadata);
    return testing.allocator.dupe(u8, metadata);
}

test "compiler temporary pressure shares the ledger and failed compilation refunds ownership" {
    const ledger = try api.MemoryBudget.create(testing.allocator, 8 * 1024 * 1024);
    defer ledger.release();
    const a = ledger.allocator();
    const baseline = ledger.usage().used;
    {
        var owner = try api.Owner.init(a, testing.io);
        defer owner.deinit();
        const source = try testing.allocator.alloc(u8, 512 * 1024);
        defer testing.allocator.free(source);
        @memset(source, ' ');
        @memcpy(source[source.len - "return 37".len ..], "return 37");
        const before = ledger.usage();
        {
            const held = try a.alloc(u8, before.limit - before.used - 256 * 1024);
            defer a.free(held);
            if (owner.begin(a, "{}", &.{}, source)) |machine| {
                var unexpected = machine;
                unexpected.deinit();
                return error.CompilerBypassedLedger;
            } else |err| {
                try testing.expectEqual(error.LimitExceeded, err);
            }
            try testing.expect(ledger.usage().refused > before.refused);
        }
        var recovered = try owner.begin(a, "{}", &.{}, source);
        defer recovered.deinit();
        try testing.expectEqualStrings("37", (try next(&recovered, null)).done.result_json);
    }
    try testing.expectEqual(baseline, ledger.usage().used);
    try testing.expect(ledger.usage().peak <= ledger.usage().limit);
}

test "returned metadata keeps its allocator alive after VM and budget root release" {
    const ledger = try api.MemoryBudget.create(testing.allocator, limit);
    const a = ledger.allocator();
    const metadata = try api.describe(a, read_source);
    ledger.release();
    defer a.free(metadata);
    const parsed = try parse(metadata);
    defer parsed.deinit();
    try testing.expectEqualStrings("read", parsed.value.object.get("name").?.string);
}

test "diagnostics allocate on demand and preserve complete sanitized errors" {
    var machine = try init("{}", &.{}, "error(string.rep('😺',2048)..string.char(0,255))");
    defer machine.deinit();
    const failed = (try machine.step(10000, null)).failed;
    try testing.expectEqual(@as(usize, 2048), std.mem.count(u8, failed.message, "😺"));
    try testing.expect(std.mem.endsWith(u8, failed.message, "\\x00\\xff"));
    try testing.expect(std.unicode.utf8ValidateSlice(failed.message));
}

test "live registrations and invocation catalogs consume bytes rather than count slots" {
    const ledger = try api.MemoryBudget.create(testing.allocator, 8 * 1024 * 1024);
    defer ledger.release();
    const a = ledger.allocator();
    const baseline = ledger.usage().used;
    {
        var owner = try api.Owner.init(a, testing.io);
        defer owner.deinit();
        const definitions = try a.alloc(api.Tool, 385);
        defer a.free(definitions);
        var initialized: usize = 0;
        defer for (definitions[0..initialized]) |tool| {
            @constCast(tool.registered.?).release();
            a.free(tool.name);
        };
        for (definitions, 0..) |*tool, index| {
            const name = try std.fmt.allocPrint(a, "tool_{d}", .{index});
            errdefer a.free(name);
            var buffer: [512]u8 = undefined;
            const source = try std.fmt.bufPrint(&buffer, "return {{name='{s}',version=1,description='catalog',parameters={{type='object'}},endpoints={{}},recovery='never',execute=function()return {d} end}}", .{ name, index });
            const registered = try owner.registerTool(source);
            tool.* = .{ .name = name, .source = registered.source(), .registered = registered };
            initialized += 1;
        }
        var machine = try owner.begin(a, "{}", definitions, "return tools.tool_0({})+tools.tool_384({})");
        defer machine.deinit();
        try testing.expectEqualStrings("384", (try next(&machine, null)).done.result_json);
        try testing.expectEqual(@as(usize, definitions.len), owner.usage().registered_versions);
    }
    try testing.expectEqual(baseline, ledger.usage().used);
}
