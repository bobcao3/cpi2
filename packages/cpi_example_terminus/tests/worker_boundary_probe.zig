const std = @import("std");
const agent = @import("agent");
const services = @import("services");

const guest =
    \\return {
    \\ name="guest", version=1, description="Unprivileged guest program",
    \\ parameters={type="object", properties={state={type="object"}}, required={"state"}},
    \\ endpoints={"files.write"}, recovery="never",
    \\ execute=function(args)
    \\   local sees_ctx = ctx ~= nil
    \\   local changed = pcall(function() ctx.control.prefix="guest-wrote" end)
    \\   local host_ok = pcall(function() host.call("files.write", {path="boundary-proof",content="declared service write"}) end)
    \\   args.state.changed=true
    \\   return {sees_ctx=sees_ctx, changed=changed, host_ok=host_ok, state=args.state}
    \\ end,
    \\}
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedRunDirectory;
    const a = init.arena.allocator();
    var nonce: [8]u8 = undefined;
    init.io.random(&nonce);
    const requested_directory = try std.fs.path.join(a, &.{ args[1], try std.fmt.allocPrint(a, "boundary-{s}", .{std.fmt.bytesToHex(nonce, .lower)}) });
    try std.Io.Dir.cwd().createDirPath(init.io, requested_directory);
    const directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, requested_directory, a);
    var files: services.Files = .{ .workspace = directory };
    const controller = try agent.Controller.open(init.gpa, init.io, .{
        .authorize = "return function(event,state) return {allow=event.kind=='command' or event.kind=='snapshot' or (event.operation=='files.write' and state.allow_files==true)} end",
        .services = &.{files.service()},
    });
    defer controller.close();
    const setup = try controller.program("setup", "ctx.control={prefix='operator'}; return true", .null);
    defer setup.deinit();
    var setup_result = try setup.wait(init.io);
    defer setup_result.deinit();
    const direct = try controller.start(.{
        .session_id = "yielding",
        .journal_path = try std.fs.path.join(a, &.{ directory, "yielding.gz" }),
    });
    const first = try controller.submit(direct, "experiment", .{ .lua = "ctx.control={prefix='operator'}; ctx.control.prefix='guest-wrote'; return ctx.control.prefix" });
    defer first.deinit();
    var first_result = try first.wait(init.io);
    defer first_result.deinit();
    const bounded = try controller.start(.{
        .session_id = "reducer",
        .journal_path = try std.fs.path.join(a, &.{ directory, "reducer.gz" }),
        .capabilities = &.{.{ .source_name = "guest.luau", .source = guest }},
        .endpoint_grants = &.{"files.write"},
    });
    const second = try controller.submit(bounded, "experiment", .{ .lua = "ctx.control={prefix='operator'}; ctx.business={}; local r=tools.guest({state=ctx.business}); return {guest=r,prefix=ctx.control.prefix}" });
    defer second.deinit();
    var second_result = try second.wait(init.io);
    defer second_result.deinit();
    var policy_context = try controller.readProgramContext(a);
    defer policy_context.deinit();
    const j = services.json;
    if (!std.mem.eql(u8, try j.text(j.get(j.get(policy_context.value, "control"), "prefix")), "operator")) return error.ControllerContextLeaked;
    const observation = j.get(second_result.result, "guest");
    if (j.get(observation, "host_ok").bool or j.get(observation, "sees_ctx").bool or j.get(observation, "changed").bool) return error.GuestEscalated;
    const proof_path = try std.fs.path.join(a, &.{ directory, "boundary-proof" });
    if (std.Io.Dir.cwd().access(init.io, proof_path, .{})) |_| return error.DeniedWriteOccurred else |err| if (err != error.FileNotFound) return err;
    const permit = try controller.program("permit-write", "ctx.allow_files=true; return true", .null);
    defer permit.deinit();
    var permitted = try permit.wait(init.io);
    defer permitted.deinit();
    const allowed = try controller.submit(bounded, "allowed", .{ .lua = "return tools.guest({state={}})" });
    defer allowed.deinit();
    var written = try allowed.wait(init.io);
    defer written.deinit();
    if (written.status != .completed or !j.get(written.result, "host_ok").bool) return error.AllowedWriteFailed;
    if (!std.mem.eql(u8, "declared service write", try std.Io.Dir.cwd().readFileAlloc(init.io, proof_path, a, .limited(128)))) return error.IncorrectWrite;
    const result = try std.json.Stringify.valueAlloc(a, .{
        .yielding = first_result.document.value,
        .reducer = second_result.document.value,
        .allowed = written.document.value,
        .directory = directory,
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, result);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (first_result.status != .completed or second_result.status != .completed) return error.ExperimentFailed;
}
