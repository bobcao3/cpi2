const std = @import("std");
const Session = @import("Session.zig");
const C = @import("Conversation.zig");
const RunState = @import("RunState.zig");
const j = Session.j;
const api = Session.api;

fn fillToCapacity(a: std.mem.Allocator, map: *j.Value, prefix: []const u8) !void {
    var index = map.object.entries.len;
    while (map.object.entries.len < map.object.entries.capacity) : (index += 1) {
        const key = try std.fmt.allocPrint(a, "{s}_{d}", .{ prefix, index });
        try j.put(a, map, key, j.integer(index));
    }
}

fn backing(a: std.mem.Allocator, value: j.Value, root: bool, addresses: *std.ArrayList(usize)) !void {
    switch (value) {
        .object => |object| {
            if (!root and object.entries.capacity > 0) try addresses.append(a, @intFromPtr(object.entries.bytes));
            var fields = object.iterator();
            while (fields.next()) |field| {
                const key = field.key_ptr.*;
                if (root and (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "continuation") or std.mem.eql(u8, key, "context_ceiling"))) continue;
                try backing(a, field.value_ptr.*, false, addresses);
            }
        },
        .array => |array| {
            if (array.capacity > 0) try addresses.append(a, @intFromPtr(array.items.ptr));
            for (array.items) |item| try backing(a, item, false, addresses);
        },
        .string, .number_string => |bytes| if (bytes.len > 0) try addresses.append(a, @intFromPtr(bytes.ptr)),
        .null, .bool, .integer, .float => {},
    }
}

test "context boundaries preserve and resume active runs across object growth" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "ceiling", "provider_overflow" }) |cause| {
        const session = try Session.init(a, std.testing.io, "boundary-growth", ".", "memory:", "{}", j.array(a));
        defer session.deinit();
        _ = try session.run(1, 1000);
        try session.admit("original", 8, "{\"input\":\"continue the conversation\",\"model\":{\"model\":\"fixture\"}}");
        _ = try session.run(2, 1000);

        var fixture = try session.mutate();
        const fa = fixture.allocator();
        _ = try C.appendResponse(&fixture, j.array(fa), "fixture", try j.parse(fa, "{\"total_tokens\":37}"));
        const active = j.ptr(&fixture.value, "active");
        try j.put(fa, active, "context_ceiling", j.integer(if (std.mem.eql(u8, cause, "ceiling")) 1 else 0));
        try j.put(fa, active, "round", j.integer(2));
        try j.put(fa, active, "effects", try j.parse(fa, "[{\"endpoint\":\"fixture\",\"result\":{\"value\":42}}]"));
        try j.put(fa, active, "nested", try j.parse(fa, "{\"tags\":[\"a\",\"b\"],\"meta\":{\"kept\":true}}"));
        // Exercise the rehash that adding a continuation can trigger after cloning a snapshot.
        var at_growth = false;
        for (0..128) |index| {
            var probe = try j.copy(fa, active.*);
            const header = probe.object.index_header;
            try j.put(fa, &probe, "continuation", j.string("probe"));
            if (header != null and header != probe.object.index_header) {
                at_growth = true;
                break;
            }
            const key = try std.fmt.allocPrint(fa, "inert_{d}", .{index});
            try j.put(fa, active, key, try j.parse(fa, "{\"preserved\":[1,2,3]}"));
        }
        try std.testing.expect(at_growth);
        var original = try fixture.clone(a);
        defer original.deinit();
        try session.stage(fixture, &.{});

        _ = try session.run(1, 1000);
        if (std.mem.eql(u8, cause, "provider_overflow")) {
            try std.testing.expect(session.external != null);
            try session.feed(session.external.?, api.CPI_AGENT_IO_DONE, "{\"status\":400,\"body\":{\"error\":{\"code\":\"context_length_exceeded\"}}}");
            _ = try session.run(1, 1000);
        }
        var outcome_receipt = (try session.recordedCommand(a, "original")).?;
        defer outcome_receipt.deinit();
        const outcome = j.get(outcome_receipt.value, "outcome");
        try std.testing.expectEqualStrings("completed", j.text(j.get(outcome, "status")));
        const boundary = j.get(outcome, "result");
        try std.testing.expectEqualStrings(cause, j.text(j.get(boundary, "cause")));
        try std.testing.expectEqual(@as(u64, 37), j.number(j.get(boundary, "context_tokens")));
        const continuation = j.text(j.get(boundary, "continuation"));
        try std.testing.expect(continuation.len > 0);
        try std.testing.expect(j.get(session.state.value, "active") == .null);
        const suspended = j.get(session.state.value, "suspended");
        try std.testing.expectEqualStrings(continuation, j.text(j.get(suspended, "continuation")));
        var fields = j.get(original.value, "active").object.iterator();
        while (fields.next()) |field| {
            try std.testing.expect((try j.equal(a, field.value_ptr.*, j.get(suspended, field.key_ptr.*))));
        }
        var finished = false;
        for (session.events.items) |event| {
            if (event.value.kind != api.CPI_AGENT_EVENT_COMMAND_FINISHED or !std.mem.eql(u8, event.value.request_id, "original")) continue;
            var notice = try j.Document.init(a, event.value.json);
            defer notice.deinit();
            try std.testing.expect((try j.equal(a, outcome, notice.value)));
            finished = true;
        }
        try std.testing.expect(finished);

        const resume_payload = try j.encode(a, .{ .continuation = continuation, .context_ceiling = 1000 });
        defer a.free(resume_payload);
        try session.admit("resumed", 8, resume_payload);
        _ = try session.run(2, 1000);
        try std.testing.expect(j.get(session.state.value, "suspended") == .null);
        const resumed = j.get(session.state.value, "active");
        try std.testing.expectEqualStrings("resumed", j.text(j.get(resumed, "id")));
        fields = j.get(original.value, "active").object.iterator();
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field.key_ptr.*, "id") or std.mem.eql(u8, field.key_ptr.*, "context_ceiling")) continue;
            try std.testing.expect((try j.equal(a, field.value_ptr.*, j.get(resumed, field.key_ptr.*))));
        }
        _ = try session.run(1, 1000);
        try std.testing.expect(session.external != null);
        try session.feed(session.external.?, api.CPI_AGENT_IO_DONE, "{\"status\":200,\"body\":{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"resumed successfully\"}]}],\"usage\":{\"total_tokens\":40}}}");
        _ = try session.run(1, 1000);
        var completed_receipt = (try session.recordedCommand(a, "resumed")).?;
        defer completed_receipt.deinit();
        const completed = j.get(completed_receipt.value, "outcome");
        try std.testing.expectEqualStrings("completed", j.text(j.get(completed, "status")));
        try std.testing.expectEqualStrings("resumed successfully", j.text(j.get(j.get(completed, "result"), "text")));
        try std.testing.expect(j.get(session.state.value, "active") == .null);
        try std.testing.expect(j.get(session.state.value, "suspended") == .null);
        try session.admit("replayed", 8, resume_payload);
        _ = try session.run(3, 1000);
        var replayed_receipt = (try session.recordedCommand(a, "replayed")).?;
        defer replayed_receipt.deinit();
        const replayed = j.get(replayed_receipt.value, "outcome");
        try std.testing.expectEqualStrings("failed", j.text(j.get(replayed, "status")));
        try std.testing.expectEqualStrings("InvalidContinuation", j.text(j.get(j.get(replayed, "error"), "code")));
    }
}

test "slot transitions consume stored headers without copying nested containers" {
    const a = std.testing.allocator;
    var doc = try j.Document.init(a,
        \\{"active":{"id":"run-1","kind":1,"phase":"model","round":3,"capabilities":[{"name":"fixture","descriptor":{"name":"fixture"}}],"effects":[{"endpoint":"fixture","result":{"value":42}}],"model":{"model":"fixture"},"notes":{"kept":[1,2,3],"meta":{"flag":true}}},"capabilities_revision":7,"conversation":{"revision":0,"head":null,"next":1,"entries":[]},"commands":[],"ctx":{"marker":"stable"},"session_marker":"sibling"}
    );
    defer doc.deinit();
    const fa = doc.allocator();
    const active = j.ptr(&doc.value, "active");
    try fillToCapacity(fa, active, "inert");
    const run_capacity = active.object.entries.capacity;
    var original_backing: std.ArrayList(usize) = .empty;
    defer original_backing.deinit(a);
    try backing(a, active.*, true, &original_backing);
    try std.testing.expect(j.get(doc.value, "suspended") == .null);
    try std.testing.expect(doc.value.object.getPtr("suspended") == null);
    try fillToCapacity(fa, &doc.value, "root");
    const root_capacity = doc.value.object.entries.capacity;

    const boundary = try RunState.suspendRun(&doc, .{ .session_id = "session", .sequence = 9, .cause = .ceiling });
    try std.testing.expectEqualStrings("run-1", boundary.command_id);
    try std.testing.expectEqualStrings("session:run-1:9", boundary.continuation);
    try std.testing.expectEqual(RunState.Cause.ceiling, boundary.cause);
    try std.testing.expectEqual(@as(u64, 0), boundary.context_tokens);
    try std.testing.expect(j.ptr(&doc.value, "active").* == .null);
    const suspended = j.get(doc.value, "suspended");
    try std.testing.expect(suspended == .object);
    try std.testing.expectEqualStrings(boundary.continuation, j.text(j.get(suspended, "continuation")));
    var suspended_backing: std.ArrayList(usize) = .empty;
    defer suspended_backing.deinit(a);
    try backing(a, suspended, true, &suspended_backing);
    try std.testing.expectEqualSlices(usize, original_backing.items, suspended_backing.items);
    try std.testing.expect(suspended.object.entries.capacity > run_capacity);
    try std.testing.expect(doc.value.object.entries.capacity > root_capacity);
    try std.testing.expectEqual(@as(i64, 7), j.get(doc.value, "capabilities_revision").integer);
    try std.testing.expectEqualStrings("stable", j.text(j.get(j.get(doc.value, "ctx"), "marker")));
    try std.testing.expectEqualStrings("sibling", j.text(j.get(doc.value, "session_marker")));

    try RunState.resumeRun(&doc, .{ .continuation = boundary.continuation, .command_id = "run-2", .context_ceiling = 1234 });
    const resumed = j.get(doc.value, "active");
    try std.testing.expectEqualStrings("run-2", j.text(j.get(resumed, "id")));
    try std.testing.expectEqual(@as(u64, 1234), j.number(j.get(resumed, "context_ceiling")));
    try std.testing.expect(j.get(doc.value, "suspended") == .null);
    var resumed_backing: std.ArrayList(usize) = .empty;
    defer resumed_backing.deinit(a);
    try backing(a, resumed, true, &resumed_backing);
    try std.testing.expectEqualSlices(usize, original_backing.items, resumed_backing.items);
    try std.testing.expectEqualStrings("fixture", j.text(j.get(doc.value, "conversation_model")));
    try std.testing.expectEqual(@as(i64, 7), j.get(doc.value, "capabilities_revision").integer);
}

test "resume creates an absent destination after validating the continuation" {
    const a = std.testing.allocator;
    var doc = try j.Document.init(a, "{\"suspended\":{\"id\":\"old\",\"continuation\":\"token\",\"model\":{\"model\":\"fixture\"},\"context_ceiling\":null},\"capabilities_revision\":3}");
    defer doc.deinit();
    const fa = doc.allocator();
    try std.testing.expect(doc.value.object.getPtr("active") == null);
    try fillToCapacity(fa, &doc.value, "root");
    const capacity = doc.value.object.entries.capacity;
    try std.testing.expectError(error.InvalidContinuation, RunState.resumeRun(&doc, .{ .continuation = "wrong", .command_id = "stale", .context_ceiling = null }));
    try std.testing.expect(doc.value.object.getPtr("active") == null);
    try std.testing.expectEqualStrings("token", j.text(j.get(j.get(doc.value, "suspended"), "continuation")));
    try RunState.resumeRun(&doc, .{ .continuation = "token", .command_id = "new", .context_ceiling = 512 });
    try std.testing.expect(doc.value.object.entries.capacity > capacity);
    const active = j.get(doc.value, "active");
    try std.testing.expectEqualStrings("new", j.text(j.get(active, "id")));
    try std.testing.expectEqual(@as(u64, 512), j.number(j.get(active, "context_ceiling")));
    try std.testing.expectEqualStrings("fixture", j.text(j.get(doc.value, "conversation_model")));
    try std.testing.expect(j.get(doc.value, "suspended") == .null);
    try std.testing.expect(doc.value.object.getPtr("suspended") != null);
}

test "fresh auxiliary runs coexist with a suspended run and release only their own slot" {
    const a = std.testing.allocator;
    var doc = try j.Document.init(a, "{\"suspended\":{\"id\":\"model\",\"continuation\":\"token\",\"model\":{\"model\":\"fixture\"}},\"capabilities_revision\":1}");
    defer doc.deinit();
    const fa = doc.allocator();
    const suspended_pointer = @intFromPtr(j.get(doc.value, "suspended").object.entries.bytes);
    var summary = j.object();
    try j.put(fa, &summary, "id", j.string("summary"));
    try j.put(fa, &summary, "kind", j.integer(9));
    try j.put(fa, &summary, "phase", j.string("model"));
    try RunState.installFresh(&doc, &summary);
    try std.testing.expect(summary == .null);
    try std.testing.expectEqualStrings("summary", j.text(j.get(j.get(doc.value, "active"), "id")));
    try std.testing.expectEqual(suspended_pointer, @intFromPtr(j.get(doc.value, "suspended").object.entries.bytes));
    var blocked = j.object();
    try std.testing.expectError(error.InvalidState, RunState.installFresh(&doc, &blocked));
    try std.testing.expect(blocked == .object);
    try std.testing.expectError(error.InvalidState, RunState.suspendRun(&doc, .{ .session_id = "s", .sequence = 1, .cause = .provider_overflow }));
    try RunState.clear(&doc, .active);
    try std.testing.expect(j.get(doc.value, "active") == .null);
    try std.testing.expectEqual(suspended_pointer, @intFromPtr(j.get(doc.value, "suspended").object.entries.bytes));
    try RunState.resumeRun(&doc, .{ .continuation = "token", .command_id = "resumed", .context_ceiling = null });
    const active = j.get(doc.value, "active");
    try std.testing.expectEqualStrings("resumed", j.text(j.get(active, "id")));
    try std.testing.expect(j.get(active, "context_ceiling") == .null);
    try std.testing.expect(j.get(doc.value, "suspended") == .null);
}

test "provider failure and cancellation discard partial body bytes without poisoning the session" {
    const a = std.testing.allocator;
    for ([_]u32{ api.CPI_AGENT_IO_ERROR, api.CPI_AGENT_IO_CANCELLED }) |terminal| {
        const session = try Session.init(a, std.testing.io, "partial-reply", ".", "memory:", "{}", j.array(a));
        defer session.deinit();
        _ = try session.run(1, 1000);
        try session.admit("request", 8, "{\"input\":\"hello\",\"model\":{\"model\":\"fixture\"}}");
        _ = try session.run(32, 1000);
        const operation = session.external.?;
        try session.feed(operation, api.CPI_AGENT_IO_DATA, "{\"output\":[");
        try session.feed(operation, terminal, if (terminal == api.CPI_AGENT_IO_ERROR) "{\"code\":\"timeout\",\"message\":\"fixture deadline\"}" else "");
        _ = try session.run(32, 1000);
        try std.testing.expect(!session.failed);
        var receipt = (try session.recordedCommand(a, "request")).?;
        defer receipt.deinit();
        const outcome = j.get(receipt.value, "outcome");
        try std.testing.expectEqualStrings(if (terminal == api.CPI_AGENT_IO_CANCELLED) "cancelled" else "failed", j.text(j.get(outcome, "status")));
        try std.testing.expectEqualStrings(if (terminal == api.CPI_AGENT_IO_CANCELLED) "cancelled" else "timeout", j.text(j.get(j.get(outcome, "error"), "code")));
        try session.admit("next", 4, "{\"source\":\"return 42\"}");
        _ = try session.run(32, 1000);
        var next = (try session.recordedCommand(a, "next")).?;
        defer next.deinit();
        try std.testing.expectEqualStrings("completed", j.text(j.get(j.get(next.value, "outcome"), "status")));
    }
}
