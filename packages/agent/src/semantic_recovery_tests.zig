const std = @import("std");
const agent = @import("root.zig");
const p = @import("session_protocol");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const Context = @import("LuauContextJournal.zig");
const j = @import("json.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const Nested = struct {
    fn initial(_: std.mem.Allocator) !j.Value {
        return .null;
    }
    fn validate(_: j.Value, action: []const u8, value: j.Value) !void {
        if (std.mem.eql(u8, action, "set") and value == .string) return;
        if (std.mem.eql(u8, action, "advance") and value == .integer) return;
        return error.InvalidNestedAction;
    }
    fn reduce(allocator: std.mem.Allocator, previous: j.Value, action: []const u8, value: j.Value) !j.Value {
        if (std.mem.eql(u8, action, "set")) return value;
        var root = try j.parse(allocator, previous.string);
        const last = &j.ptr(&root, "items").array.items[4095];
        j.ptr(j.ptr(last, "arguments"), "input").array.items[0] = value;
        return .{ .string = try j.encode(allocator, root) };
    }
    const contract: p.Extensions.Contract = .{ .version = .{ .id = "nested", .version = "1" }, .initial_state = initial, .validate = validate, .reduce = reduce };
};

test "private reducers replay nested state under a shared memory bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "nested.gz" });
    defer a.free(path);
    var initial = try j.Document.init(a, "{\"items\":[]}");
    defer initial.deinit();
    for (0..4096) |_| try j.ptr(&initial.value, "items").array.append(try j.parse(initial.allocator(), "{\"arguments\":{\"input\":[1,2],\"keep\":{\"nested\":true}}}"));
    const encoded = try j.encode(a, initial.value);
    defer a.free(encoded);
    {
        var journal = try Journal.open(a, io, path, "nested", .{ .contracts = &.{Nested.contract} });
        defer journal.deinit();
        _ = try journal.commit("initial", .{ .kind = .host, .id = "test" }, &.{.{ .@"control.extension" = .{ .namespace = "nested", .expected_head = 0, .action = "set", .input = .{ .contract = Nested.contract.version, .value = .{ .string = encoded } } } }});
        for (0..8) |index| {
            var scratch: std.heap.ArenaAllocator = .init(a);
            defer scratch.deinit();
            _ = try journal.commit(try std.fmt.allocPrint(scratch.allocator(), "advance-{d}", .{index}), .{ .kind = .host, .id = "test" }, &.{.{ .@"control.extension" = .{ .namespace = "nested", .expected_head = journal.state.extensions.get("nested").?.head, .action = "advance", .input = .{ .contract = Nested.contract.version, .value = .{ .integer = @intCast(index) } } } }});
        }
    }
    const budget = try agent.MemoryBudget.create(a, 9500000);
    defer budget.release();
    var journal = try Journal.open(budget.allocator(), io, path, "nested", .{ .contracts = &.{Nested.contract} });
    defer journal.deinit();
    var final = try j.Document.init(a, journal.state.extensions.get("nested").?.value.string);
    defer final.deinit();
    const last = j.get(final.value, "items").array.items[4095];
    try std.testing.expectEqual(@as(i64, 7), j.get(j.get(last, "arguments"), "input").array.items[0].integer);
    try std.testing.expectEqual(@as(usize, 0), budget.usage().refused);
}

test "interrupted recovery retains native receipts and never dispatches them again" {
    const Session = @import("Session.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "interrupted.gz" });
    defer a.free(path);
    const payload = try a.alloc(u8, 128 * 1024);
    defer a.free(payload);
    @memset(payload, 'x');
    {
        var projection = try j.Document.init(a, @import("Conversation.zig").initial);
        defer projection.deinit();
        const pa = projection.allocator();
        var journal = try Journal.open(a, io, path, "interrupted", try Persistence.options(pa, Context.default));
        defer journal.deinit();
        _ = try journal.commit("bind", .{ .kind = .host, .id = "test" }, &.{.{ .@"capability.bind" = .{ .name = "test", .service = .{ .id = "test", .version = "1" }, .config = j.object() } }});
        var active = try j.parse(pa, "{\"id\":\"interrupted\",\"kind\":4,\"capabilities\":[],\"capabilities_revision\":0,\"phase\":\"effect\",\"effects\":[],\"images\":[]}");
        for (0..20) |index| {
            const id = try std.fmt.allocPrint(pa, "receipt-{d}", .{index});
            const arguments = try j.project(pa, .{ .request = .{ .body = payload, .user_object = .{ .effect_ref = @as(u64, 999) } } });
            _ = try journal.commit(id, .{ .kind = .host, .id = "test" }, &.{
                .{ .@"control.effect.intent" = .{ .effect_id = id, .endpoint = .{ .name = "test", .binding = 1 }, .arguments = try j.project(pa, .{ .json = try j.encode(pa, arguments) }), .source_message = null, .key = id, .recovery = .never } },
                .{ .@"control.effect.result" = .{ .effect_id = id, .status = .completed, .result = try j.project(pa, .{ .json = "{\"response\":\"saved\"}" }) } },
            });
            try j.ptr(&active, "effects").array.append(try j.project(pa, .{ .tool_name = "__application", .status = "completed", .effect_ref = journal.sequence, .failed = false }));
        }
        const pending = try j.parse(pa, "{\"tool_name\":\"pending\",\"endpoint\":\"test\",\"status\":\"running\",\"arguments\":{}}");
        try j.ptr(&active, "effects").array.append(pending);
        try j.put(pa, &active, "effect", pending);
        try @import("RunState.zig").installFresh(&projection, &active);
        try j.ptr(&projection.value, "commands").array.append(try j.parse(pa, "{\"id\":\"interrupted\",\"kind\":4,\"status\":\"running\",\"payload\":{\"source\":\"never replay\"}}"));
        try j.put(pa, j.ptr(&projection.value, "ctx"), "padding", .{ .string = payload });
        try Persistence.boundary(&journal, Context.default, projection.value, &projection, .null, &.{}, false);
    }
    const budget = try agent.MemoryBudget.create(a, 12 * 1024 * 1024);
    defer budget.release();
    for (0..2) |_| {
        const session = try Session.init(budget.allocator(), io, "interrupted", directory, path, "{}", j.array(a));
        defer session.deinit();
        _ = try session.run(1, 100);
        try std.testing.expect(session.ready and session.vm == null and session.external == null);
        try std.testing.expectEqual(@as(usize, 0), session.operations.items.len);
        var receipt = (try session.recordedCommand(a, "interrupted")).?;
        defer receipt.deinit();
        const effects = j.get(j.get(j.get(receipt.value, "outcome"), "error"), "effects");
        try std.testing.expectEqual(@as(usize, 21), effects.array.items.len);
        for (effects.array.items[0..20]) |effect| {
            const expanded = try session.effectValue(receipt.document.allocator(), effect);
            try std.testing.expectEqualStrings(payload, j.text(j.get(j.get(j.get(expanded, "arguments"), "request"), "body")));
            try std.testing.expectEqual(@as(i64, 999), j.get(j.get(j.get(j.get(expanded, "arguments"), "request"), "user_object"), "effect_ref").integer);
            try std.testing.expectEqualStrings("saved", j.text(j.get(j.get(expanded, "result"), "response")));
        }
    }
}
