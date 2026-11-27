const std = @import("std");
const agent = @import("agent");
const Io = std.Io;
const a = std.testing.allocator;
const io = std.testing.io;
const gate_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };

fn check(request: *agent.Request) !agent.Outcome {
    defer request.deinit();
    return request.wait(io);
}

const Steering = struct {
    entered: Io.Event = .unset,
    release: Io.Event = .unset,
    cancelled: Io.Event = .unset,
    calls: std.atomic.Value(usize) = .init(0),

    fn call(context: ?*anyopaque, allocator: std.mem.Allocator, callback_io: Io, request: agent.AdapterRequest) !agent.AdapterResponse {
        const self: *Steering = @ptrCast(@alignCast(context.?));
        if (self.calls.fetchAdd(1, .seq_cst) == 0) {
            self.entered.set(callback_io);
            self.release.wait(callback_io) catch |err| {
                self.cancelled.set(callback_io);
                return err;
            };
            return .{ .json = try allocator.dupe(u8, "{\"status\":200,\"body\":{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"function_call\",\"name\":\"execute_lua\",\"call_id\":\"stale\",\"arguments\":\"{\\\"source\\\":\\\"ctx.stale=true; return 1\\\"}\"}]}}") };
        }
        try std.testing.expect(std.mem.indexOf(u8, request.json, "revised-input") != null);
        return .{ .json = try allocator.dupe(u8, "{\"status\":200,\"body\":{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"REVISED\"}]}]}}") };
    }
};

test "steering pending model interrupt and boundary discard stale Lua plans" {
    for ([_]bool{ true, false }) |interrupt| {
        var dir = std.testing.tmpDir(.{});
        defer dir.cleanup();
        const parent = try dir.dir.realPathFileAlloc(io, ".", a);
        defer a.free(parent);
        const path = try std.fs.path.join(a, &.{ parent, "steer.gz" });
        defer a.free(path);
        var fixture: Steering = .{};
        var worker = try agent.Worker.open(a, io, .{ .session_id = "steer", .journal_path = path, .adapters = .{ .http = .{ .context = &fixture, .call = Steering.call } } });
        defer worker.deinit();
        defer fixture.release.set(io);
        const input = try worker.submit("input", .{ .input = "original" });
        defer input.deinit();
        try fixture.entered.waitTimeout(io, gate_timeout);
        var steered = try check(try worker.submit("steer", .{ .steer = .{ .content = "revised-input", .policy = if (interrupt) .interrupt_generation else .at_boundary } }));
        defer steered.deinit();
        try std.testing.expectEqual(.completed, steered.status);
        if (interrupt) {
            try fixture.cancelled.waitTimeout(io, gate_timeout);
        } else {
            try std.testing.expect(!fixture.cancelled.isSet());
            try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.seq_cst));
        }
        fixture.release.set(io);
        var outcome = try input.wait(io);
        defer outcome.deinit();
        try std.testing.expectEqual(.completed, outcome.status);
        try std.testing.expectEqualStrings("REVISED", outcome.result.object.get("text").?.string);
        var stale = try check(try worker.submit("verify", .{ .lua = "return ctx.stale == nil" }));
        defer stale.deinit();
        try std.testing.expect(stale.result.bool);
    }
}

const old_tool =
    \\return {name="revision",version=1,description="Revision",parameters={type="object",properties={},additionalProperties=false},endpoints={"test.revision"},recovery="never",execute=function(args) host.call("test.revision",args); return "old" end}
;
const new_tool =
    \\return {name="revision",version=1,description="Revision",parameters={type="object",properties={},additionalProperties=false},endpoints={},recovery="never",execute=function(args) return "new" end}
;
const Registry = struct {
    entered: Io.Event = .unset,
    release: Io.Event = .unset,
    fn call(context: ?*anyopaque, allocator: std.mem.Allocator, callback_io: Io, _: agent.AdapterRequest) !agent.AdapterResponse {
        const self: *Registry = @ptrCast(@alignCast(context.?));
        self.entered.set(callback_io);
        try self.release.wait(callback_io);
        return .{ .json = try allocator.dupe(u8, "null") };
    }
};

test "tool replacement captures revision and durable removal survives initial seeds" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "registry.gz" });
    defer a.free(path);
    var fixture: Registry = .{};
    const config: agent.Config = .{ .session_id = "registry", .journal_path = path, .capabilities = &.{.{ .source_name = "revision.lua", .source = old_tool }}, .endpoint_grants = &.{"test.revision"}, .adapters = .{ .rpc = .{ .context = &fixture, .call = Registry.call } } };
    {
        var worker = try agent.Worker.open(a, io, config);
        defer worker.deinit();
        defer fixture.release.set(io);
        const active = try worker.submit("old", .{ .lua = "local first=tools.revision({}); return {first,tools.revision({})}" });
        defer active.deinit();
        try fixture.entered.waitTimeout(io, gate_timeout);
        var replaced = try check(try worker.submit("replace", .{ .register_capability = .{ .source_name = "replacement.lua", .source = new_tool } }));
        defer replaced.deinit();
        try std.testing.expectEqual(.completed, replaced.status);
        fixture.release.set(io);
        var old = try active.wait(io);
        defer old.deinit();
        try std.testing.expectEqual(.completed, old.status);
        for (old.result.array.items) |value| try std.testing.expectEqualStrings("old", value.string);
        var fresh = try check(try worker.submit("new", .{ .lua = "return tools.revision({})" }));
        defer fresh.deinit();
        try std.testing.expectEqualStrings("new", fresh.result.string);
        var removed = try check(try worker.submit("remove", .{ .unregister_capability = "revision" }));
        defer removed.deinit();
        try std.testing.expectEqual(.completed, removed.status);
        var closed = try check(try worker.submit("close", .close));
        defer closed.deinit();
        try std.testing.expectEqual(.completed, closed.status);
    }
    var reopened = try agent.Worker.open(a, io, config);
    defer reopened.deinit();
    var absent = try check(try reopened.submit("absent", .{ .lua = "return tools.revision == nil" }));
    defer absent.deinit();
    try std.testing.expectEqual(.completed, absent.status);
    try std.testing.expect(absent.result.bool);
}

test "tool grants deny RPC before adapter dispatch" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "denied.gz" });
    defer a.free(path);
    var fixture: Registry = .{};
    fixture.release.set(io);
    var worker = try agent.Worker.open(a, io, .{
        .session_id = "denied",
        .journal_path = path,
        .capabilities = &.{.{ .source_name = "revision.lua", .source = old_tool }},
        .adapters = .{ .rpc = .{ .context = &fixture, .call = Registry.call } },
    });
    defer worker.deinit();
    var outcome = try check(try worker.submit("denied", .{ .lua = "return tools.revision({})" }));
    defer outcome.deinit();
    try std.testing.expectEqual(.failed, outcome.status);
    try std.testing.expect(!fixture.entered.isSet());
}
