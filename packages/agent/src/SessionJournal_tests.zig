const std = @import("std");
const Journal = @import("SessionJournal.zig");
const protocol = @import("session_protocol");
const gzip = @import("journal_gzip.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn member(bytes: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer output.deinit();
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var encoder: std.compress.flate.Compress = try .init(&output.writer, window, .gzip, .fastest);
    try encoder.writer.writeAll(bytes);
    try encoder.finish();
    return gzip.frame(a, output.written());
}

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

test "legacy snapshots, complete corruption and malformed semantic groups preserve durable bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "reject.jsonl.gz" });
    defer a.free(path);
    const fixtures = [_][]const u8{
        "{\"kind\":\"checkpoint\",\"sequence\":1,\"session_id\":\"test\",\"snapshot\":{}}\n",
        "{\"kind\":\"delta\",\"sequence\":1,\"session_id\":\"test\",\"base\":0,\"changes\":[]}\n",
        "{\"v\":1,\"session_id\":\"test\",\"seq\":1,\"tx\":{\"id\":\"t1\",\"index\":0,\"count\":2},\"class\":\"control\",\"op\":\"control.context.select\",\"actor\":{\"kind\":\"host\",\"id\":\"host\"},\"cause\":null,\"data\":{\"context\":\"main\"}}\n",
    };
    for (fixtures) |fixture| {
        const bytes = try member(fixture);
        defer a.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        try std.testing.expectError(error.InvalidJournal, Journal.open(a, io, path, "test", .{}));
        const after = try read(path);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, bytes, after);
    }
    const bytes = try member(fixtures[0]);
    defer a.free(bytes);
    bytes[bytes.len - 8] ^= 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    try std.testing.expectError(error.InvalidJournal, Journal.open(a, io, path, "test", .{}));
    const after = try read(path);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, bytes, after);
}

test "a complete member after a truncated member is corruption, not a repairable suffix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "middle.jsonl.gz" });
    defer a.free(path);
    const part = try member("{\"incomplete\":true}\n");
    defer a.free(part);
    const tail = try member("{}\n");
    defer a.free(tail);
    const combined = try std.mem.concat(a, u8, &.{ part[0 .. part.len - 9], tail });
    defer a.free(combined);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined });
    try std.testing.expectError(error.InvalidJournal, Journal.open(a, io, path, "test", .{}));
    const after = try read(path);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, combined, after);
}

test "identical transaction retries return their prior commit and conflicting retries reject" {
    var journal = try Journal.open(a, io, "memory:", "test", .{});
    defer journal.deinit();
    const actions = [_]protocol.frames.Action{.{ .@"control.context.create" = .{ .id = "branch", .base = null } }};
    try std.testing.expectEqual(@as(u64, 1), try journal.commit("once", .{ .kind = .host, .id = "host" }, &actions));
    try std.testing.expectEqual(@as(u64, 1), try journal.commit("once", .{ .kind = .host, .id = "host" }, &actions));
    try std.testing.expectEqual(@as(usize, 1), journal.transactions.items.len);
    try std.testing.expectError(error.TransactionConflict, journal.commit("once", .{ .kind = .host, .id = "different" }, &actions));
    try std.testing.expectEqual(@as(u64, 1), journal.sequence);
}

test "disk replay pages transactions and owns historical context identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const file = try std.fs.path.join(a, &.{ path, "pages.gz" });
    defer a.free(file);
    var journal = try Journal.open(a, io, file, "test", .{});
    defer journal.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var previous: ?[]const u8 = null;
    const body: [16384]u8 = @splat('x');
    for (0..24) |index| {
        const id = try std.fmt.allocPrint(temp, "message-{d}", .{index});
        const content = try protocol.Encoding.value(temp, .{ .type = "text", .text = &body });
        _ = try journal.commit(id, .{ .kind = .user, .id = "user" }, &.{.{ .@"document.message.append" = .{ .message = .{ .id = id, .role = .user, .content = &.{content} }, .placement = .{ .context = "main", .after = previous } } }});
        previous = id;
    }
    for (journal.transactions.items) |stored| try std.testing.expect(stored.resident == null);
    var past = try journal.stateAt(a, 12);
    defer past.deinit();
    const projection = try past.project(temp, journal.source(), 12, "main", protocol.State.standard_renderer.version, .null, &.{}, &.{protocol.State.standard_renderer});
    try std.testing.expectEqual(@as(usize, 12), projection.messages.array.items.len);
    _ = try journal.frame(temp, 24);
    try std.testing.expectEqualStrings("message-0", projection.messages.array.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("message-11", past.contexts.get("main").?.ids.items[11]);
}

test "private state is durable and unknown reducer code cannot silently reopen it" {
    const Private = struct {
        fn initial(_: std.mem.Allocator) !protocol.frames.Value {
            return .null;
        }
        fn validate(_: protocol.frames.Value, name: []const u8, _: protocol.frames.Value) !void {
            if (!std.mem.eql(u8, name, "set")) return error.InvalidPrivateAction;
        }
        fn reduce(_: std.mem.Allocator, _: protocol.frames.Value, _: []const u8, value: protocol.frames.Value) !protocol.frames.Value {
            return value;
        }
        const contract: protocol.Extensions.Contract = .{ .version = .{ .id = "private", .version = "1" }, .initial_state = initial, .validate = validate, .reduce = reduce };
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "private.jsonl.gz" });
    defer a.free(path);
    {
        var journal = try Journal.open(a, io, path, "test", .{ .contracts = &.{Private.contract} });
        defer journal.deinit();
        _ = try journal.commit("set-private", .{ .kind = .host, .id = "host" }, &.{.{ .@"control.extension" = .{
            .namespace = "private",
            .expected_head = 0,
            .action = "set",
            .input = .{ .contract = Private.contract.version, .value = .{ .string = "restored" } },
        } }});
    }
    try std.testing.expectError(error.MissingExtensionContract, Journal.open(a, io, path, "test", .{}));
    var journal = try Journal.open(a, io, path, "test", .{ .contracts = &.{Private.contract} });
    defer journal.deinit();
    try std.testing.expectEqualStrings("restored", journal.state.extensions.get("private").?.value.string);
}
