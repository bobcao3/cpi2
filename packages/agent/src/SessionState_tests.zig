const std = @import("std");
const F = @import("SessionFrame.zig");
const State = @import("SessionState.zig");
const Transaction = @import("SessionTransaction.zig");
const Encoding = @import("SessionEncoding.zig");
const Canonical = @import("CanonicalJson.zig");
const a = std.testing.allocator;

const Log = struct {
    state: State,
    transactions: std.ArrayList(Transaction) = .empty,
    frames: std.ArrayList(*const F.Frame) = .empty,
    pending: ?*const Transaction = null,
    fn init() !Log {
        return .{ .state = try State.init(a, "state-test") };
    }
    fn deinit(self: *Log) void {
        self.state.deinit();
        for (self.transactions.items) |*t| t.deinit();
        self.transactions.deinit(a);
        self.frames.deinit(a);
    }
    fn source(self: *const Log) State.Source {
        return .{ .context = self, .frame = frame, .transaction = transaction };
    }
    fn frame(raw: *const anyopaque, ref: u64) !*const F.Frame {
        const self: *const Log = @ptrCast(@alignCast(raw));
        if (ref == 0) return error.InvalidReference;
        if (ref <= self.frames.items.len) return self.frames.items[@intCast(ref - 1)];
        if (self.pending) |t| {
            const first = t.frames[0].frame.seq;
            if (ref >= first and ref <= t.lastSequence()) return &t.frames[@intCast(ref - first)].frame;
        }
        return error.InvalidReference;
    }
    fn transaction(raw: *const anyopaque, allocator: std.mem.Allocator, ref: u64) !Transaction {
        const self: *const Log = @ptrCast(@alignCast(raw));
        for (self.transactions.items) |*t| if (ref >= t.frames[0].frame.seq and ref <= t.lastSequence()) return t.clone(allocator);
        return error.InvalidReference;
    }
    fn append(self: *Log, actions: []const F.Action) !void {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        const id = try std.fmt.allocPrint(temporary, "t-{d}", .{self.state.sequence + 1});
        const bytes = try Encoding.transaction(temporary, "state-test", id, self.state.sequence + 1, .{ .kind = .host, .id = "host" }, actions);
        var t = try Transaction.parse(a, "state-test", self.state.sequence + 1, bytes, .{});
        errdefer t.deinit();
        self.pending = &t;
        defer self.pending = null;
        const candidate = try self.state.prepare(self.source(), &t, &.{}, &.{State.standard_renderer});
        var adopt = false;
        defer if (!adopt) {
            var discard = candidate;
            discard.deinit();
        };
        try self.frames.ensureUnusedCapacity(a, t.frames.len);
        try self.transactions.ensureUnusedCapacity(a, 1);
        for (t.frames) |*f| self.frames.appendAssumeCapacity(&f.frame);
        self.transactions.appendAssumeCapacity(t);
        self.state.deinit();
        self.state = candidate;
        adopt = true;
    }
};

test "core actions preserve identities, historic cuts, pinned registrations and atomic failure" {
    var log = try Log.init();
    defer log.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const empty: F.Value = .{ .object = .empty };
    const text = try Encoding.value(temp, .{ .type = "text", .text = "hello" });
    try log.append(&.{
        .{ .@"capability.bind" = .{ .name = "files", .service = .{ .id = "files", .version = "1" }, .config = empty } },
        .{ .@"control.set_model" = .{ .provider = "test", .model = "test", .route = "test", .credential_ref = null, .adapter = .{ .id = "test", .version = "1" }, .kwargs = empty } },
        .{ .@"control.provider_tool.register" = .{ .name = "work", .definition = empty, .handler = null } },
        .{ .@"document.message.append" = .{ .message = .{ .id = "user", .role = .user, .content = &.{text} }, .placement = .{ .context = "main", .after = null } } },
    });
    const p = try log.state.project(temp, log.source(), 4, "main", State.standard_renderer.version, empty, &.{}, &.{State.standard_renderer});
    const ih = try Canonical.hash(temp, p.instructions);
    const mh = try Canonical.hash(temp, p.messages);
    const th = try Canonical.hash(temp, p.tools);
    try log.append(&.{.{ .@"control.model.request" = .{ .request_id = "request", .input_at = 4, .context = "main", .model_frame = 2, .renderer = State.standard_renderer.version, .kwargs = empty, .instructions_sha256 = &ih, .messages_sha256 = &mh, .tools_sha256 = &th } }});
    try log.append(&.{
        .{ .@"document.message.append" = .{ .message = .{ .id = "assistant", .role = .assistant, .content = &.{}, .tool_calls = &.{.{ .id = "call", .name = "work", .arguments = empty }} }, .placement = .{ .context = "main", .after = "user" }, .request = "request" } },
        .{ .@"control.model.finish" = .{ .request_id = "request", .status = .completed, .usage = .null, .diagnostic = .null } },
    });
    try std.testing.expectError(error.IncompleteToolGroup, log.state.project(temp, log.source(), 7, "main", State.standard_renderer.version, empty, &.{}, &.{State.standard_renderer}));
    try log.append(&.{
        .{ .@"capability.unbind" = .{ .name = "files", .binding = 1 } },
        .{ .@"control.provider_tool.deregister" = .{ .name = "work", .registration = 3 } },
    });
    try std.testing.expectEqual(@as(u64, 3), log.state.calls.get("call").?.registration);
    try std.testing.expectError(error.StaleBinding, log.append(&.{.{ .@"control.effect.intent" = .{ .effect_id = "denied", .endpoint = .{ .name = "files", .binding = 1 }, .arguments = empty, .source_message = null, .key = "denied", .recovery = .never } }}));
    try std.testing.expectEqual(@as(u64, 9), log.state.sequence);
    try log.append(&.{
        .{ .@"document.message.append" = .{ .message = .{ .id = "result", .role = .tool, .tool_call_id = "call", .content = &.{text} }, .placement = .{ .context = "main", .after = "assistant" } } },
        .{ .@"capability.bind" = .{ .name = "files", .service = .{ .id = "files", .version = "2" }, .config = empty } },
        .{ .@"control.effect.intent" = .{ .effect_id = "effect", .endpoint = .{ .name = "files", .binding = 11 }, .arguments = empty, .source_message = "assistant", .key = "effect", .recovery = .reconcile } },
        .{ .@"control.effect.result" = .{ .effect_id = "effect", .status = .indeterminate, .result = .null } },
    });
    try log.append(&.{
        .{ .@"control.context.create" = .{ .id = "branch", .base = .{ .context = "main", .at = 4 } } },
        .{ .@"control.context.select" = .{ .context = "branch" } },
        .{ .@"control.effect.result" = .{ .effect_id = "effect", .status = .completed, .result = empty } },
    });
    const branch = log.state.contexts.get("branch").?;
    try std.testing.expectEqual(@as(usize, 1), branch.ids.items.len);
    try std.testing.expectEqualStrings("user", branch.ids.items[0]);
    try std.testing.expectError(error.TerminalOperation, log.append(&.{.{ .@"control.cancel" = .{ .target = 12, .reason = "too late" } }}));
    try std.testing.expectError(error.StaleContextHead, log.append(&.{.{ .@"control.document_mutation" = .{ .context = "main", .expected_head = 0, .edits = &.{.{ .drop = &.{"user"} }} } }}));
    try log.append(&.{.{ .@"control.document_mutation" = .{ .context = "branch", .expected_head = 14, .edits = &.{ .{ .drop = &.{"user"} }, .{ .insert = .{ .after = null, .ids = &.{"result"} } } } } }});
    try std.testing.expectEqualStrings("result", log.state.contexts.get("branch").?.ids.items[0]);
    try std.testing.expectError(error.UncommittedPosition, log.source().cut(6));
}
