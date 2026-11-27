const std = @import("std");
const agent = @import("agent");
const services = @import("services");
const j = services.json;
const allow = "return function(event,state) return {allow=true} end";

fn inspect(process: *services.Process, c: services.Context, id: []const u8) !j.Value {
    var registry = services.Registry.init(c.allocator);
    defer registry.deinit();
    try registry.add(process.service());
    return registry.dispatch(c, "process.status", try j.value(c.allocator, .{ .id = id }));
}

fn spawn(controller: *agent.Controller, c: services.Context, id: []const u8, detach: bool) !agent.Outcome {
    const request = try controller.program(id, "local job=host.call('process.spawn',{argv={'/bin/sh','-c','sleep 30'}}); if input.detach then job=host.call('process.detach',{id=job.id}) end return job", try j.value(c.allocator, .{ .detach = detach }));
    defer request.deinit();
    var outcome = try request.wait(c.io);
    errdefer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    return outcome;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    const io = init.io;
    const c: services.Context = .{ .allocator = a, .io = io };
    var owned: services.Process = .{ .workspace = args[2], .directory = try std.fs.path.join(a, &.{ args[2], "nested", "owned" }), .binary = args[1], .environment = init.environ_map };
    var borrowed: services.Process = .{ .workspace = args[2], .directory = try std.fs.path.join(a, &.{ args[2], "borrowed" }), .binary = args[1], .environment = init.environ_map };
    defer borrowed.cleanup(c) catch {};
    defer owned.cleanup(c) catch {};
    const external = try agent.Controller.open(init.gpa, io, .{ .authorize = allow, .services = &.{borrowed.service()}, .program_grants = &.{"process.spawn"} });
    var external_open = true;
    defer if (external_open) external.close();
    var survivor = try spawn(external, c, "borrowed", false);
    defer survivor.deinit();
    external.close();
    external_open = false;
    const survivor_id = j.get(survivor.result, "id").string;
    try std.testing.expectEqualStrings("running", j.get(try inspect(&borrowed, c, survivor_id), "status").string);

    const controller = try agent.Controller.open(init.gpa, io, .{ .authorize = allow, .services = &.{owned.ownedService()}, .program_grants = &.{ "process.spawn", "process.detach" } });
    var controller_open = true;
    defer if (controller_open) controller.close();
    var managed = try spawn(controller, c, "managed", false);
    defer managed.deinit();
    var detached = try spawn(controller, c, "detached", true);
    defer detached.deinit();
    controller.close();
    controller_open = false;
    const ended = try inspect(&owned, c, j.get(managed.result, "id").string);
    try std.testing.expectEqual(137, j.get(ended, "exit_code").integer);
    const preserved = try inspect(&owned, c, j.get(detached.result, "id").string);
    try std.testing.expectEqualStrings("detached", j.get(preserved, "status").string);
    try std.testing.expect(j.get(preserved, "exit_code") == .null);
    try std.testing.expectEqualStrings("running", j.get(try inspect(&borrowed, c, survivor_id), "status").string);
    const socket = try std.fs.path.join(a, &.{ owned.directory, "control.sock" });
    const result = try std.process.run(a, io, .{ .argv = &.{ args[1], "-S", socket, "signal-session", "--signal", "SIGKILL", "--uid", j.get(detached.result, "id").string, "--json" }, .environ_map = init.environ_map, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(owned.service());
    const stopped = try registry.dispatch(c, "process.wait", try j.value(a, .{ .id = j.get(detached.result, "id").string, .wait_ms = 3000 }));
    try std.testing.expectEqual(137, j.get(stopped, "exit_code").integer);
    try std.Io.File.stdout().writeStreamingAll(io, "Controller Process release, borrowed ownership and detach passed\n");
}
