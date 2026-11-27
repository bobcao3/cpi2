const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        const message = std.fmt.allocPrint(init.arena.allocator(), "cpi-agent: {s}\n", .{@errorName(err)}) catch "cpi-agent: out of memory\n";
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(1);
    };
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var session: []const u8 = "default";
    var journal: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var nonce: [16]u8 = undefined;
    init.io.random(&nonce);
    const identity = std.fmt.bytesToHex(nonce, .lower);
    var request_id: []const u8 = &identity;
    var workspace: []const u8 = ".";
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "usage: cpi-agent --journal PATH --lua SOURCE [--session ID] [--request-id ID] [--workspace PATH]\nStandalone Lua only. Native embedders register execution services with agent.Controller.\n");
            return;
        }
        if (index + 1 == args.len) return error.MissingArgument;
        const flag = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--journal")) journal = args[index] else if (std.mem.eql(u8, flag, "--session")) session = args[index] else if (std.mem.eql(u8, flag, "--request-id")) request_id = args[index] else if (std.mem.eql(u8, flag, "--workspace")) workspace = args[index] else if (std.mem.eql(u8, flag, "--lua")) source = args[index] else return error.UnknownArgument;
    }
    const controller = try agent.Controller.open(init.gpa, init.io, .{ .authorize = "return function(event, state) return {allow=true} end" });
    defer controller.close();
    const worker = try controller.start(.{ .session_id = session, .workspace = workspace, .journal_path = journal orelse return error.MissingJournal });
    const request = try controller.submit(worker, request_id, .{ .lua = source orelse return error.MissingLua });
    defer request.deinit();
    var outcome = try request.wait(init.io);
    defer outcome.deinit();
    const close_id = try std.fmt.allocPrint(a, "close/{s}", .{identity});
    const close = try controller.submit(worker, close_id, .close);
    defer close.deinit();
    var closed = try close.wait(init.io);
    defer closed.deinit();
    const json = try std.json.Stringify.valueAlloc(a, outcome.document.value, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (outcome.status != .completed) return error.CommandFailed;
}
