const std = @import("std");
const json_text = @import("json_tree").text;
const agent = @import("agent");

test "duplicate and distinct saturation preserve cancel and close admission" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ true, false }) |duplicates| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        const parent = try directory.dir.realPathFileAlloc(io, ".", a);
        defer a.free(parent);
        const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
        defer a.free(path);
        var worker = try agent.Worker.open(a, io, .{ .session_id = "saturation", .journal_path = path });
        defer worker.deinit();
        var handles: std.ArrayList(*agent.Request) = .empty;
        defer {
            for (handles.items) |handle| handle.deinit();
            handles.deinit(a);
        }
        const active = try worker.submit("active", .{ .lua = "while true do end" });
        try handles.append(a, active);
        for (0..127) |n| {
            const id = try std.fmt.allocPrint(a, "queued-{d}", .{n});
            defer a.free(id);
            try handles.append(a, try worker.submit(if (duplicates) "active" else id, .{ .lua = if (duplicates) "while true do end" else "return 1" }));
        }
        const cancel = try worker.submit("cancel", .cancel);
        defer cancel.deinit();
        const close = try worker.submit("close", .close);
        defer close.deinit();
        var cancelled = try active.wait(io);
        defer cancelled.deinit();
        try std.testing.expectEqual(.cancelled, cancelled.status);
        var result = try close.wait(io);
        defer result.deinit();
        try std.testing.expectEqual(.completed, result.status);
        if (duplicates) for (handles.items) |handle| {
            var repeated = try handle.wait(io);
            repeated.deinit();
        };
    }
}

const EffectFixture = struct {
    path: []const u8,
    entered: std.Io.Event = .unset,
    cancel_seen: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    observed_start: bool = false,
    observed_finish: bool = false,
    runtime: ?@FieldType(agent.Worker, "runtime") = null,
    io: std.Io,

    fn replay(self: *EffectFixture, allocator: std.mem.Allocator, sequence: ?u64) !agent.SessionJournal {
        const live = &self.runtime.?.session.journal;
        var journal = try agent.SessionJournal.open(allocator, self.io, "memory:", live.state.extensions.session_id, live.options);
        errdefer journal.deinit();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, self.path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            var input: std.Io.Reader = .fixed(bytes[offset..]);
            var decoder: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
            const expanded = try decoder.reader.allocRemaining(allocator, .limited(4 * 1024 * 1024));
            defer allocator.free(expanded);
            var transaction = try agent.session_protocol.Transaction.parse(allocator, live.state.extensions.session_id, journal.sequence + 1, expanded, .{});
            _ = journal.append(&transaction) catch |err| {
                transaction.deinit();
                return err;
            };
            if (sequence) |expected| {
                if (journal.sequence == expected) return journal;
                if (journal.sequence > expected) return error.UncommittedPosition;
            }
            offset += input.seek;
        }
        if (sequence != null) return error.MissingDurableCommit;
        return journal;
    }

    fn notify(context: ?*anyopaque, notice: agent.Notice) !void {
        const self: *EffectFixture = @ptrCast(@alignCast(context.?));
        if (notice.kind != .tool_started and notice.kind != .tool_finished and notice.kind != .command_committed) return;
        var journal = try self.replay(std.testing.allocator, notice.sequence);
        defer journal.deinit();
        try std.testing.expectEqual(notice.sequence, journal.sequence);
        if (notice.kind == .command_committed) return;
        if (notice.kind == .tool_started) {
            var state = try agent.LuauJournal.restore(&journal, self.runtime.?.session.context_codec, std.testing.allocator);
            defer state.deinit();
            const effects = state.value.object.get("active").?.object.get("effects").?.array.items;
            try std.testing.expectEqualStrings("running", effects[effects.len - 1].object.get("status").?.string);
            self.observed_start = true;
            return;
        }
        for (journal.state.effects.values()) |effect| {
            if (notice.kind == .tool_finished and effect.finish != null) {
                self.observed_finish = true;
                return;
            }
        }
        return error.MissingDurableEffect;
    }

    fn call(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, request: agent.AdapterRequest) !agent.AdapterResponse {
        const self: *EffectFixture = @ptrCast(@alignCast(context.?));
        try std.testing.expectEqualStrings("effect", request.request_id);
        var arguments = try json_text.parseFromSlice(std.json.Value, allocator, request.json, .{});
        defer arguments.deinit();
        try std.testing.expectEqualStrings("test.effect", arguments.value.object.get("endpoint").?.string);
        var journal = try self.replay(allocator, null);
        defer journal.deinit();
        var pending = false;
        for (journal.state.effects.values()) |effect| if (effect.finish == null) {
            pending = true;
        };
        try std.testing.expect(pending);
        var state = try agent.LuauJournal.restore(&journal, self.runtime.?.session.context_codec, allocator);
        defer state.deinit();
        const ctx = state.value.object.get("ctx").?;
        try std.testing.expectEqual(@as(i64, 41), ctx.object.get("before").?.integer);
        self.entered.set(io);
        self.release.wait(io) catch |err| {
            self.cancel_seen.set(io);
            self.release.waitUncancelable(io);
            return err;
        };
        return .{ .json = try allocator.dupe(u8, "7") };
    }
};

fn waitRequest(request: *agent.Request, io: std.Io) !void {
    var outcome = try request.wait(io);
    outcome.deinit();
}

const SyncFailure = struct {
    committed: std.atomic.Value(usize) = .init(0),
    fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
        return error.InputOutput;
    }
    fn notify(context: ?*anyopaque, notice: agent.Notice) !void {
        const self: *SyncFailure = @ptrCast(@alignCast(context.?));
        if (notice.kind == .command_committed or notice.kind == .command_finished) _ = self.committed.fetchAdd(1, .monotonic);
        if (notice.kind == .fault) return error.FixtureNotificationFailure;
    }
};

test "native open reports unavailable independent concurrency and releases its journal lock" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
    defer a.free(path);
    const config: agent.Config = .{ .session_id = "concurrency", .journal_path = path };
    var backend: std.Io.Threaded = .init(a, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    try std.testing.expectError(error.ConcurrencyUnavailable, agent.Worker.open(a, backend.io(), config));
    var worker = try agent.Worker.open(a, io, config);
    defer worker.deinit();
    const request = try worker.submit("usable", .{ .lua = "return 17" });
    defer request.deinit();
    var result = try request.wait(io);
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 17), result.result.integer);
}

test "backend fsync failure poisons admission without publishing success" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
    defer a.free(path);
    var vtable = io.vtable.*;
    const backend: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var fixture: SyncFailure = .{};
    var worker = try agent.Worker.open(a, backend, .{
        .session_id = "failure",
        .journal_path = path,
        .observer = .{ .context = &fixture, .notify = SyncFailure.notify },
    });
    defer worker.deinit();
    vtable.fileSync = SyncFailure.sync;
    const request = try worker.submit("failure", .{ .lua = "ctx.bad=true; return 1" });
    defer request.deinit();
    try request.done.waitTimeout(backend, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expectError(error.JournalCommitUncertain, request.wait(backend));
    try std.testing.expectError(error.JournalCommitUncertain, worker.readContext(a));
    try std.testing.expectError(error.JournalCommitUncertain, worker.readConversation(a));
    try std.testing.expectError(error.JournalCommitUncertain, worker.runtime.inspect(a));
    try std.testing.expectEqual(@as(usize, 0), fixture.committed.load(.acquire));
    try std.testing.expectError(error.InvalidState, worker.submit("later", .{ .lua = "return 2" }));
}

const effect_source =
    \\return {name="effect",version=1,description="Controlled external effect",
    \\parameters={type="object",properties={},additionalProperties=false},
    \\endpoints={"test.effect"},recovery="never",
    \\execute=function(args) return host.call("test.effect",args) end}
;

test "external intent is durable and cancellation never joins a blocked adapter on the actor" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
    defer a.free(path);
    var fixture: EffectFixture = .{ .path = path, .io = io };
    var worker = try agent.Worker.open(a, io, .{
        .session_id = "effects",
        .journal_path = path,
        .capabilities = &.{.{ .source_name = "effect.lua", .source = effect_source }},
        .endpoint_grants = &.{"test.effect"},
        .adapters = .{ .rpc = .{ .context = &fixture, .call = EffectFixture.call } },
        .observer = .{ .context = &fixture, .notify = EffectFixture.notify },
    });
    defer worker.deinit();
    fixture.runtime = worker.runtime;
    defer fixture.release.set(io);
    const request = try worker.submit("effect", .{ .lua = "ctx.before=41; ctx.result=tools.effect({}); return ctx.result" });
    defer request.deinit();
    try fixture.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    var waiter = try io.concurrent(waitRequest, .{ request, io });
    try std.testing.expectError(error.Canceled, waiter.cancel(io));
    const cancel = try worker.submit("cancel", .cancel);
    defer cancel.deinit();
    var cancelled = try cancel.wait(io);
    defer cancelled.deinit();
    try std.testing.expectEqual(.completed, cancelled.status);
    fixture.cancel_seen.waitUncancelable(io);
    const register = try worker.submit("registration", .{ .register_capability = .{ .source_name = "effect.lua", .source = effect_source } });
    defer register.deinit();
    var registered = try register.wait(io);
    defer registered.deinit();
    try std.testing.expectEqual(.completed, registered.status);
    fixture.release.set(io);
    var result = try request.wait(io);
    defer result.deinit();
    try std.testing.expectEqual(.cancelled, result.status);
    try std.testing.expect(fixture.observed_start);
    try std.testing.expect(fixture.observed_finish);
    const check = try worker.submit("check", .{ .lua = "return {before=ctx.before,rolled_back=ctx.result==nil}" });
    defer check.deinit();
    var checked = try check.wait(io);
    defer checked.deinit();
    try std.testing.expectEqual(@as(i64, 41), checked.result.object.get("before").?.integer);
    try std.testing.expect(checked.result.object.get("rolled_back").?.bool);
}

test "storage failure settles active and queued requests before a canceled adapter joins" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
    defer a.free(path);
    var vtable = io.vtable.*;
    const backend: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var fixture: EffectFixture = .{ .path = path, .io = backend };
    var worker = try agent.Worker.open(a, backend, .{
        .session_id = "storage-cancel",
        .journal_path = path,
        .capabilities = &.{.{ .source_name = "effect.lua", .source = effect_source }},
        .endpoint_grants = &.{"test.effect"},
        .adapters = .{ .rpc = .{ .context = &fixture, .call = EffectFixture.call } },
    });
    defer worker.deinit();
    fixture.runtime = worker.runtime;
    defer fixture.release.set(backend);
    const active = try worker.submit("effect", .{ .lua = "ctx.before=41; return tools.effect({})" });
    defer active.deinit();
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
    try fixture.entered.waitTimeout(backend, timeout);
    vtable.fileSync = SyncFailure.sync;
    const queued = try worker.submit("queued", .{ .lua = "return 2" });
    defer queued.deinit();
    try active.done.waitTimeout(backend, timeout);
    try queued.done.waitTimeout(backend, timeout);
    try std.testing.expectError(error.JournalCommitUncertain, active.wait(backend));
    try std.testing.expectError(error.JournalCommitUncertain, queued.wait(backend));
    try fixture.cancel_seen.waitTimeout(backend, timeout);
    try std.testing.expect(!fixture.release.isSet());
    try std.testing.expectError(error.JournalCommitUncertain, worker.readContext(a));
}

test "committed in-memory terminal outcome survives an earlier notice delivery failure" {
    const io = std.testing.io;
    const Failing = struct {
        fn notify(_: ?*anyopaque, notice: agent.Notice) !void {
            if (notice.kind == .command_committed) return error.FixtureNotificationFailure;
        }
    };
    var worker = try agent.Worker.open(std.testing.allocator, io, .{ .session_id = "durable-before-fault", .persistence = .memory, .observer = .{ .context = null, .notify = Failing.notify } });
    defer worker.deinit();
    const request = try worker.submit("completed", .{ .lua = "return 41" });
    defer request.deinit();
    try request.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var outcome = try request.wait(io);
    defer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    try std.testing.expectEqual(@as(i64, 41), outcome.result.integer);
}

test "native Lua invocation accepts and executes source beyond 64 KiB" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "source.gz" });
    defer a.free(path);
    const payload = try a.alloc(u8, 70000);
    defer a.free(payload);
    @memset(payload, 'x');
    const source = try std.fmt.allocPrint(a, "ctx.payload='{s}'; return #ctx.payload", .{payload});
    defer a.free(source);
    var worker = try agent.Worker.open(a, io, .{ .session_id = "source", .journal_path = path });
    defer worker.deinit();
    const write = try worker.submit("write", .{ .lua = source });
    defer write.deinit();
    var written = try write.wait(io);
    defer written.deinit();
    try std.testing.expectEqual(.completed, written.status);
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), written.result.integer);
    const read = try worker.submit("read", .{ .lua = "return ctx.payload" });
    defer read.deinit();
    var restored = try read.wait(io);
    defer restored.deinit();
    try std.testing.expectEqual(.completed, restored.status);
    try std.testing.expectEqualStrings(payload, restored.result.string);
}

test "native context queries return owned checkpoints without journal writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "queries.gz" });
    defer a.free(path);
    var worker = try agent.Worker.open(a, io, .{ .session_id = "queries", .journal_path = path });
    defer worker.deinit();
    var empty = try worker.readContext(a);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.object.count());
    const write = try worker.submit("one", .{ .lua = "ctx.count=1; return true" });
    defer write.deinit();
    var written = try write.wait(io);
    defer written.deinit();
    try std.testing.expectEqual(.completed, written.status);
    const before = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(before);
    for (0..50) |_| {
        var snapshot = try worker.readContext(a);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(i64, 1), snapshot.value.object.get("count").?.integer);
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var old = try worker.readContext(a);
    defer old.deinit();
    const update = try worker.submit("two", .{ .lua = "ctx.count=2; return true" });
    defer update.deinit();
    var updated = try update.wait(io);
    defer updated.deinit();
    try std.testing.expectEqual(.completed, updated.status);
    var current = try worker.readContext(a);
    defer current.deinit();
    try std.testing.expectEqual(@as(i64, 1), old.value.object.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), current.value.object.get("count").?.integer);
}

test "native Lua actor persists context and deduplicates across close and reopen" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "session.gz" });
    defer a.free(path);
    const config: agent.Config = .{ .session_id = "native", .journal_path = path, .capabilities = &.{.{ .source_name = "effect.lua", .source = effect_source }} };
    const source = "ctx.count=(ctx.count or 0)+1; return ctx.count";
    {
        var worker = try agent.Worker.open(a, io, config);
        defer worker.deinit();
        const request = try worker.submit("once", .{ .lua = source });
        defer request.deinit();
        const duplicate = try worker.submit("once", .{ .lua = source });
        defer duplicate.deinit();
        var result = try request.wait(io);
        defer result.deinit();
        try std.testing.expectEqual(.completed, result.status);
        try std.testing.expectEqual(@as(i64, 1), result.result.integer);
        var repeated = try duplicate.wait(io);
        defer repeated.deinit();
        try std.testing.expectEqual(@as(i64, 1), repeated.result.integer);
        try std.testing.expectError(error.RequestConflict, worker.submit("once", .{ .lua = "return 9" }));
        const close = try worker.submit("close", .close);
        defer close.deinit();
        var closed = try close.wait(io);
        defer closed.deinit();
        try std.testing.expectEqual(.completed, closed.status);
    }
    {
        var worker = try agent.Worker.open(a, io, config);
        defer worker.deinit();
        const duplicate = try worker.submit("once", .{ .lua = source });
        defer duplicate.deinit();
        var repeated = try duplicate.wait(io);
        defer repeated.deinit();
        try std.testing.expectEqual(@as(i64, 1), repeated.result.integer);
        const increment = try worker.submit("twice", .{ .lua = source });
        defer increment.deinit();
        var result = try increment.wait(io);
        defer result.deinit();
        try std.testing.expectEqual(@as(i64, 2), result.result.integer);
    }
}

const ConversationFixture = struct {
    expected_efforts: []const ?[]const u8 = &.{},
    requests: usize = 0,
    fn call(context: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, request: agent.AdapterRequest) !agent.AdapterResponse {
        if (context) |pointer| {
            const self: *ConversationFixture = @ptrCast(@alignCast(pointer));
            const packet = try json_text.parseFromSlice(std.json.Value, allocator, request.json, .{});
            defer packet.deinit();
            const body = packet.value.object.get("body").?;
            try std.testing.expect(self.requests < self.expected_efforts.len);
            if (self.expected_efforts[self.requests]) |effort| {
                try std.testing.expectEqualStrings(effort, body.object.get("reasoning").?.object.get("effort").?.string);
            } else try std.testing.expect(body.object.get("reasoning") == null);
            self.requests += 1;
        }
        return .{ .json = try allocator.dupe(u8, "{\"status\":200,\"body\":{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}],\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"total_tokens\":7}}}") };
    }
};

test "worker conversation projection exposes input response model and usage" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, "conversation.gz" });
    defer a.free(path);
    var worker = try agent.Worker.open(a, io, .{
        .session_id = "conversation",
        .journal_path = path,
        .adapters = .{ .http = .{ .call = ConversationFixture.call } },
    });
    defer worker.deinit();
    const request = try worker.submit("turn", .{ .input = "hello" });
    defer request.deinit();
    var outcome = try request.wait(io);
    defer outcome.deinit();
    try std.testing.expectEqual(.completed, outcome.status);
    var snapshot = try worker.readConversation(a);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.path.len);
    try std.testing.expectEqual(.input, snapshot.entries[0].kind);
    try std.testing.expectEqual(.response, snapshot.entries[1].kind);
    try std.testing.expectEqualStrings("hello", snapshot.entries[1].text);
    try std.testing.expectEqualStrings("fixture", snapshot.entries[1].model);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.entries[1].usage.?.input_tokens);
}

test "memory conversation suspends compacts resumes once and branches without changing ctx" {
    for ([_]?[]const u8{ "medium", null }) |summary_effort| {
        const a = std.testing.allocator;
        const io = std.testing.io;
        const selected: agent.Model = .{ .model = "gpt-6.1-sol", .reasoning_effort = "deep" };
        var fixture: ConversationFixture = .{ .expected_efforts = &.{ "deep", summary_effort, "high" } };
        var worker = try agent.Worker.open(a, io, .{ .session_id = "domain-memory", .persistence = .memory, .adapters = .{ .http = .{ .context = &fixture, .call = ConversationFixture.call } } });
        defer worker.deinit();
        const first = try worker.submit("first", .{ .run = .{ .input = .{ .text = "one" }, .model = selected } });
        defer first.deinit();
        var first_out = try first.wait(io);
        defer first_out.deinit();
        try std.testing.expectEqual(.completed, first_out.status);
        const second = try worker.submit("second", .{ .run = .{ .input = .{ .text = "two" }, .model = .{ .reasoning_effort = "high" }, .context_ceiling = 8 } });
        defer second.deinit();
        var blocked = try second.wait(io);
        defer blocked.deinit();
        const boundary = blocked.boundary().?;
        const legacy_input = try worker.submit("legacy-while-suspended", .{ .input = "must not replace the suspended run" });
        defer legacy_input.deinit();
        var legacy_rejected = try legacy_input.wait(io);
        defer legacy_rejected.deinit();
        try std.testing.expectEqual(.failed, legacy_rejected.status);
        var before = try worker.readConversation(a);
        defer before.deinit();
        try std.testing.expectEqual(@as(usize, 3), before.entries.len);
        try std.testing.expect(before.suspended != null);
        const compact = try worker.submit("compact", .{ .compact = .{ .expected_revision = before.revision, .first_kept = before.entries[2].id, .parts = &.{ .{ .literal = "prior conversation" }, .{ .generate = .{ .input = "summarize", .instructions = "summary" } } }, .model = .{ .reasoning_effort = summary_effort } } });
        defer compact.deinit();
        var compact_out = try compact.wait(io);
        defer compact_out.deinit();
        try std.testing.expectEqual(.completed, compact_out.status);
        const resumed = try worker.submit("resumed", .{ .run = .{ .input = .{ .continuation = boundary.continuation } } });
        defer resumed.deinit();
        var done = try resumed.wait(io);
        defer done.deinit();
        try std.testing.expectEqualStrings("hello", done.text());
        try std.testing.expectEqual(@as(usize, 3), fixture.requests);
        var after = try worker.readConversation(a);
        defer after.deinit();
        try std.testing.expectEqual(@as(usize, 5), after.entries.len);
        try std.testing.expectEqual(.checkpoint, after.entries[3].kind);
        try std.testing.expectEqualStrings("prior conversationhello", after.entries[3].text);
        const ctx_request = try worker.submit("current-effects", .{ .lua = "ctx.external_state=42; return true" });
        defer ctx_request.deinit();
        var ctx_done = try ctx_request.wait(io);
        defer ctx_done.deinit();
        const branch = try worker.submit("branch", .{ .branch = .{ .expected_revision = after.revision, .at = before.entries[1].id } });
        defer branch.deinit();
        var branched = try branch.wait(io);
        defer branched.deinit();
        try std.testing.expectEqual(.completed, branched.status);
        var tree = try worker.readConversation(a);
        defer tree.deinit();
        try std.testing.expectEqual(@as(usize, 6), tree.entries.len);
        try std.testing.expectEqual(@as(usize, 3), tree.path.len);
        try std.testing.expect(tree.checkpoint == null);
        var context = try worker.readContext(a);
        defer context.deinit();
        try std.testing.expectEqual(@as(i64, 42), context.value.object.get("external_state").?.integer);
        const stale = try worker.submit("stale", .{ .branch = .{ .expected_revision = after.revision, .at = before.entries[1].id } });
        defer stale.deinit();
        var rejected = try stale.wait(io);
        defer rejected.deinit();
        try std.testing.expectEqual(.failed, rejected.status);
    }
}

const ImageFixture = struct {
    count: std.atomic.Value(usize) = .init(0),
    effects: std.atomic.Value(usize) = .init(0),
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    block: bool,
    source: []const u8 = "output.image({mime_type='image/png',data_base64='YQ=='}); tools.echo({}); error('after image')",
    fn http(raw: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, request: agent.AdapterRequest) !agent.AdapterResponse {
        const self: *ImageFixture = @ptrCast(@alignCast(raw.?));
        if (self.count.fetchAdd(1, .seq_cst) == 0) {
            const args = try std.json.Stringify.valueAlloc(allocator, .{ .source = self.source }, .{});
            defer allocator.free(args);
            return .{ .json = try std.json.Stringify.valueAlloc(allocator, .{ .status = 200, .body = .{ .object = "response", .status = "completed", .model = "fixture", .usage = .{ .total_tokens = 1000 }, .output = .{.{ .type = "function_call", .name = "execute_lua", .call_id = "image-call", .arguments = args }} } }, .{}) };
        }
        var parsed = try json_text.parseFromSlice(std.json.Value, allocator, request.json, .{});
        defer parsed.deinit();
        const input = parsed.value.object.get("body").?.object.get("input").?.array.items;
        var images: usize = 0;
        for (input) |item| {
            const output = item.object.get("output") orelse continue;
            if (output != .array) continue;
            for (output.array.items) |part| {
                const kind = part.object.get("type").?.string;
                if (!std.mem.eql(u8, kind, "input_image")) continue;
                images += 1;
                try std.testing.expectEqualStrings("data:image/png;base64,YQ==", part.object.get("image_url").?.string);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), images);
        return ConversationFixture.call(null, allocator, io, request);
    }
    fn rpc(raw: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, _: agent.AdapterRequest) !agent.AdapterResponse {
        const self: *ImageFixture = @ptrCast(@alignCast(raw.?));
        _ = self.effects.fetchAdd(1, .seq_cst);
        self.entered.set(io);
        if (self.block) try self.release.wait(io);
        return .{ .json = try allocator.dupe(u8, "{}") };
    }
};

test "committed image emissions survive program failure cancellation and restart exactly once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for (0..4) |mode| {
        const cancel = mode == 1;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(dir);
        const path = try std.fs.path.join(a, &.{ dir, "images.gz" });
        defer a.free(path);
        var fixture: ImageFixture = .{ .block = cancel };
        if (mode == 2) fixture.source = "tools.echo({}); output.image({mime_type='image/png',data_base64='YQ=='}); ctx.uncommitted=true; error('after image')";
        if (mode == 3) fixture.source = "tools.echo({}); output.image({mime_type='image/png',data_base64='YQ=='}); ctx.self=ctx; return true";
        const config: agent.Config = .{ .session_id = "images", .journal_path = path, .capabilities = &.{.{ .source_name = "echo", .source = "return {name='echo', version=1, description='echo', parameters={type='object'}, endpoints={'test.image'}, recovery='never', execute=function(args) return host.call('test.image',args) end}" }}, .endpoint_grants = &.{"test.image"}, .adapters = .{ .http = .{ .context = &fixture, .call = ImageFixture.http }, .rpc = .{ .context = &fixture, .call = ImageFixture.rpc } } };
        {
            var worker = try agent.Worker.open(a, io, config);
            defer worker.deinit();
            const run_request = try worker.submit("image", .{ .run = .{ .input = .{ .text = "read image" }, .context_ceiling = 500 } });
            defer run_request.deinit();
            if (cancel) {
                try fixture.entered.wait(io);
                const cancel_request = try worker.submit("cancel-image", .cancel);
                defer cancel_request.deinit();
                var canceled = try cancel_request.wait(io);
                defer canceled.deinit();
            }
            var outcome = try run_request.wait(io);
            defer outcome.deinit();
            try std.testing.expectEqual(if (cancel) @as(@TypeOf(outcome.status), .cancelled) else .completed, outcome.status);
            if (!cancel) {
                const boundary = outcome.boundary().?;
                var snapshot = try worker.readConversation(a);
                defer snapshot.deinit();
                try std.testing.expectEqual(@as(usize, 3), snapshot.entries.len);
                try std.testing.expect(snapshot.entries[2].failed);
                var context = try worker.readContext(a);
                defer context.deinit();
                try std.testing.expect(context.value.object.get("uncommitted") == null);
                try std.testing.expect(context.value.object.get("self") == null);
                const compact = try worker.submit("between-rounds", .{ .compact = .{ .expected_revision = snapshot.revision, .first_kept = snapshot.entries[1].id, .parts = &.{.{ .literal = "Earlier input summarized" }}, .model = .{} } });
                defer compact.deinit();
                var compacted = try compact.wait(io);
                defer compacted.deinit();
                try std.testing.expectEqual(.completed, compacted.status);
                const continuation_request = try worker.submit("resume-image", .{ .run = .{ .input = .{ .continuation = boundary.continuation } } });
                defer continuation_request.deinit();
                var resumed = try continuation_request.wait(io);
                defer resumed.deinit();
                try std.testing.expectEqualStrings("hello", resumed.text());
            }
        }
        {
            var worker = try agent.Worker.open(a, io, config);
            defer worker.deinit();
            const resumed = try worker.submit("after-restart", .{ .input = "continue" });
            defer resumed.deinit();
            var outcome = try resumed.wait(io);
            defer outcome.deinit();
            try std.testing.expectEqual(.completed, outcome.status);
            try std.testing.expectEqual(@as(usize, 1), fixture.effects.load(.seq_cst));
        }
    }
}

test "conversation import validates checkpoint ancestry on every branch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for (0..8) |mode| {
        var worker = try agent.Worker.open(a, io, .{ .session_id = "import-checkpoint", .persistence = .memory });
        defer worker.deinit();
        var entries = [_]agent.conversation.ImportEntry{
            .{ .id = "root", .parent = null, .kind = .input, .text = "root" },
            .{ .id = "sibling", .parent = "root", .kind = .input, .text = "sibling" },
            .{ .id = "checkpoint", .parent = "root", .kind = .checkpoint, .text = "summary", .first_kept = "sibling" },
        };
        switch (mode) {
            1 => entries[2].first_kept = "checkpoint",
            2 => {
                entries[1].kind = .program;
                entries[2].parent = "sibling";
            },
            3 => {
                entries[1].kind = .branch;
                entries[2].parent = "sibling";
            },
            4 => entries[2].parent = "missing",
            5 => entries[2].first_kept = "missing",
            6, 7 => entries[2].first_kept = "root",
            else => {},
        }
        const request = try worker.submit("import", .{ .import_conversation = .{ .entries = &entries, .head = if (mode == 0 or mode == 7) "sibling" else "checkpoint" } });
        defer request.deinit();
        var outcome = try request.wait(io);
        defer outcome.deinit();
        try std.testing.expectEqual(if (mode >= 6) @as(@TypeOf(outcome.status), .completed) else .failed, outcome.status);
        var snapshot = try worker.readConversation(a);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(usize, if (mode >= 6) 3 else 0), snapshot.entries.len);
    }
}
