const std = @import("std");
const Session = @import("Session.zig");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const Context = @import("LuauContextJournal.zig");
const Conversation = @import("Conversation.zig");
const p = @import("session_protocol");
const j = @import("json.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn seed(path: []const u8, commands: []const u8, active: ?[]const u8, suspended: ?[]const u8, checkpoint: ?[]const u8) !u64 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var journal = try Journal.open(a, io, path, "validation", try Persistence.options(scratch, Context.default));
    defer journal.deinit();
    var actions: std.ArrayList(p.frames.Action) = .empty;
    var edits = j.object();
    try j.put(scratch, &edits, "commands", j.string(commands));
    if (active) |value| try j.put(scratch, &edits, "active", j.string(value));
    if (suspended) |value| try j.put(scratch, &edits, "suspended", j.string(value));
    if (checkpoint) |first| {
        const entries = [_]j.Value{
            try j.project(scratch, .{ .id = "e1", .parent = @as(?[]const u8, null), .kind = "input", .text = "retained" }),
            try j.project(scratch, .{ .id = "e2", .parent = "e1", .kind = "checkpoint", .first_kept = first, .summary = "summary" }),
        };
        for (entries) |entry| {
            const content = try scratch.alloc(j.Value, 1);
            content[0] = try j.project(scratch, .{ .type = "json", .value = .{ .format = "agent.luau.entry.v1", .stream = "conversation", .json = try j.encode(scratch, entry) } });
            try actions.append(scratch, .{ .@"document.message.append" = .{ .message = .{ .id = try Persistence.historyId(scratch, "conversation", j.text(j.get(entry, "id"))), .role = .user, .content = content }, .placement = null } });
        }
        try j.put(scratch, &edits, "conversation", j.string("{\"head\":\"e2\",\"revision\":2,\"next\":3}"));
    }
    try actions.append(scratch, .{ .@"control.extension" = .{ .namespace = Persistence.runtime_namespace, .expected_head = 0, .action = "assign", .input = .{ .contract = Persistence.runtime_contract.version, .value = edits } } });
    return journal.commit("fixture", .{ .kind = .host, .id = "test" }, actions.items);
}

fn reject(path: []const u8, directory: []const u8, expected: anyerror) !void {
    const prefix = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(prefix);
    const session = try Session.init(a, io, "validation", directory, path, "{}", j.array(a));
    defer session.deinit();
    try std.testing.expectError(expected, session.run(1, 100));
    try std.testing.expectEqual(@as(usize, 0), session.operations.items.len);
    try std.testing.expect(session.vm == null and !session.ready);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, prefix, after);
}

const command = "{\"id\":\"live\",\"kind\":4,\"status\":\"running\",\"payload\":{\"source\":\"return true\"}}";
const run = "{\"id\":\"live\",\"kind\":4,\"capabilities\":[],\"capabilities_revision\":0,\"phase\":\"lua\"}";
const orphan = "{\"id\":\"missing\",\"kind\":4,\"capabilities\":[],\"capabilities_revision\":0,\"phase\":\"lua\"}";

test "replay rejects inconsistent working-command identities without appending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "invalid.gz" });
    defer a.free(path);
    const variants = [_]struct { commands: []const u8, active: ?[]const u8 }{
        .{ .commands = "[" ++ command ++ "," ++ command ++ "]", .active = null },
        .{ .commands = "[{\"id\":\"\",\"kind\":4,\"status\":\"running\",\"payload\":{}}]", .active = null },
        .{ .commands = "[]", .active = orphan },
        .{ .commands = "[" ++ command ++ "]", .active = orphan },
    };
    for (variants) |variant| {
        _ = try seed(path, variant.commands, variant.active, null, null);
        try reject(path, directory, error.InvalidJournal);
        try tmp.dir.deleteFile(io, "invalid.gz");
    }
    _ = try seed(path, "[" ++ command ++ "]", run, orphan, null);
    const session = try Session.init(a, io, "validation", directory, path, "{}", j.array(a));
    defer session.deinit();
    _ = try session.run(1, 100);
    try std.testing.expect(session.ready);
    try std.testing.expect(j.get(session.state.value, "active") == .null);
    try std.testing.expect(j.get(session.state.value, "suspended") == .null);
    var receipt = (try session.recordedCommand(a, "live")).?;
    defer receipt.deinit();
    try std.testing.expectEqualStrings("failed", j.text(j.get(receipt.value, "status")));
    try std.testing.expectEqual(@as(usize, 0), session.operations.items.len);
}

test "replay rejects invalid checkpoint retention instead of panicking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "checkpoint.gz" });
    defer a.free(path);
    for ([_][]const u8{ "missing", "e2", "" }) |first| {
        _ = try seed(path, "[]", null, null, first);
        try reject(path, directory, error.InvalidConversation);
        try tmp.dir.deleteFile(io, "checkpoint.gz");
    }
    _ = try seed(path, "[]", null, null, "e1");
    const session = try Session.init(a, io, "validation", directory, path, "{}", j.array(a));
    defer session.deinit();
    _ = try session.run(1, 100);
    try std.testing.expect(session.ready);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const projected = try Conversation.project(arena.allocator(), session.state.value);
    try std.testing.expectEqual(@as(usize, 2), projected.array.items.len);
    try std.testing.expectEqualStrings("retained", j.text(j.get(projected.array.items[1], "content")));
}
