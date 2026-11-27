const std = @import("std");
const agent = @import("root.zig");
const services = @import("services");

const HeldService = struct {
    entered: std.Io.Event = .unset,
    cancelled: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    active: std.atomic.Value(bool) = .init(false),
    const Args = struct {};
    const operation = services.Operation.define("fixture.lifecycle-hold", HeldService, Args, bool, .{ .arguments = 128, .result = 128 }, .never, call);
    fn call(self: *HeldService, c: services.Context, _: Args) !bool {
        self.active.store(true, .release);
        defer self.active.store(false, .release);
        self.entered.set(c.io);
        self.release.wait(c.io) catch |err| {
            self.cancelled.set(c.io);
            return err;
        };
        return true;
    }
};

const FailingSink = struct {
    io: std.Io,
    after_failure: std.Io.Event = .unset,
    fn emit(raw: ?*anyopaque, event: agent.ControllerEvent) !void {
        const self: *FailingSink = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .notice => |notice| {
                if (notice.value.kind == .command_committed and std.mem.eql(u8, notice.value.request_id, "break-sink")) {
                    self.after_failure.set(self.io);
                    return error.FixtureSinkFailure;
                }
            },
            else => {},
        }
    }
};

fn await(io: std.Io, event: *std.Io.Event) !void {
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(5));
    while (true) {
        event.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
            error.Timeout => {
                if (std.Io.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.Timeout;
                continue;
            },
            error.Canceled => return error.Canceled,
        };
        return;
    }
}

test "targeted and ordinary cancellation remain available after notification failure" {
    const io = std.testing.io;
    var service: HeldService = .{};
    var sink: FailingSink = .{ .io = io };
    const controller = try agent.Controller.open(std.testing.allocator, io, .{
        .authorize = "return function(event,state) return {allow=event.operation~='cancel_invocation' or event.request_id~='policy-denied-target'} end",
        .services = &.{.{ .context = &service, .operations = &.{&HeldService.operation} }},
        .sink = .{ .context = &sink, .emit = FailingSink.emit },
    });
    var closed = false;
    defer if (!closed) controller.close();
    const worker = try controller.start(.{
        .session_id = "formal-lifecycle-replay",
        .persistence = .memory,
        .endpoint_grants = &.{"fixture.lifecycle-hold"},
        .capabilities = &.{.{ .source_name = "hold", .source = "return {name='hold',version=1,description='hold',parameters={type='object'},endpoints={'fixture.lifecycle-hold'},recovery='never',execute=function(args) return host.call('fixture.lifecycle-hold',args) end}" }},
    });
    const held = try controller.submit(worker, "held", .{ .lua = "return tools.hold({})" });
    defer held.deinit();
    try await(io, &service.entered);
    const break_sink = try controller.submit(worker, "break-sink", .{ .lua = "return true" });
    defer break_sink.deinit();
    try await(io, &sink.after_failure);
    for (0..1000) |_| {
        controller.checkNotifications() catch break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.NotificationDeliveryFailed, controller.checkNotifications());
    try std.testing.expectError(error.NotificationDeliveryFailed, controller.submit(worker, "denied-after-failure", .{ .lua = "return true" }));
    try std.testing.expectError(error.PermissionDenied, controller.cancelInvocation(worker, "policy-denied-target", "held"));
    try std.testing.expect(service.active.load(.acquire));
    const cancel = try controller.cancelInvocation(worker, "targeted-cancel", "held");
    defer cancel.deinit();
    try await(io, &cancel.done);
    var cancelled = try cancel.wait(io);
    defer cancelled.deinit();
    try std.testing.expectEqual(.completed, cancelled.status);
    try await(io, &held.done);
    var interrupted = try held.wait(io);
    defer interrupted.deinit();
    try std.testing.expectEqual(.cancelled, interrupted.status);
    try await(io, &service.cancelled);
    try std.testing.expect(!service.active.load(.acquire));
    const ordinary = try controller.submit(worker, "ordinary-cancel", .cancel);
    defer ordinary.deinit();
    try await(io, &ordinary.done);
    var ordinary_outcome = try ordinary.wait(io);
    defer ordinary_outcome.deinit();
    try std.testing.expectEqual(.completed, ordinary_outcome.status);
    controller.close();
    closed = true;
    try std.testing.expect(!service.active.load(.acquire));
}
