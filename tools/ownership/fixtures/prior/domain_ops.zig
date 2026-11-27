const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const logic = @import("logic.zig");
const C = @import("Conversation.zig");
const api = W.api;

pub fn start(self: *W, next: *j.Document, id: []const u8, kind: u64, payload: j.Value) !void {
    const a = next.allocator();
    const suspended = j.get(next.value, "suspended");
    if (kind == 11) {
        const current = j.get(j.get(next.value, "conversation"), "entries");
        if (current.array.items.len > 0 or suspended != .null) return error.ConversationNotEmpty;
        const entries = j.get(payload, "entries");
        if (entries != .array or entries.array.items.len > 100000) return error.InvalidImport;
        var seen = std.StringHashMap(j.Value).init(a);
        for (entries.array.items) |entry| {
            if (entry != .object or j.get(entry, "id") != .string) return error.InvalidImportId;
            const entry_id = j.text(j.get(entry, "id"));
            if (entry_id.len == 0 or entry_id.len > 256 or seen.contains(entry_id)) return error.InvalidImportId;
            const parent = j.get(entry, "parent");
            if (parent != .null and (parent != .string or !seen.contains(j.text(parent)))) return error.InvalidImportParent;
            const kind_name = j.text(j.get(entry, "kind"));
            const entry_kind = std.meta.stringToEnum(@FieldType(@import("conversation.zig").Entry, "kind"), kind_name) orelse return error.InvalidImportKind;
            if (entry_kind == .response and j.get(entry, "output") != .array) return error.InvalidImportResponse;
            if (entry_kind == .input and j.get(entry, "text") != .string) return error.InvalidImportInput;
            if (entry_kind == .checkpoint) {
                const kept = j.get(entry, "first_kept");
                if (kept != .string) return error.InvalidImportCheckpoint;
                const target = seen.get(kept.string) orelse return error.InvalidImportCheckpoint;
                if (!C.retainable(target)) return error.InvalidImportCheckpoint;
                var cursor = parent;
                while (cursor == .string and !std.mem.eql(u8, cursor.string, kept.string)) {
                    cursor = j.get(seen.get(cursor.string).?, "parent");
                }
                if (cursor != .string) return error.InvalidImportCheckpoint;
            }
            const material = j.get(entry, "output");
            if (material != .null) _ = try @import("provider_continuation.zig").capture(a, material);
            try seen.put(entry_id, entry);
        }
        const head = j.get(payload, "head");
        if (head != .null and (head != .string or !seen.contains(j.text(head)))) return error.InvalidImportHead;
        var conv = j.object();
        try j.put(a, &conv, "entries", try j.copy(a, entries));
        try j.put(a, &conv, "head", head);
        try j.put(a, &conv, "revision", j.integer(1));
        try j.put(a, &conv, "next", j.integer(entries.array.items.len + 1));
        try j.put(a, &next.value, "conversation", conv);
        _ = try C.path(a, next.value);
        try C.repair(next);
        try complete(self, next.*, id, .null);
        return;
    }
    if (kind == 10) {
        if (suspended != .null) return error.SuspendedRun;
        try revision(next.value, payload);
        try C.branch(next, j.text(j.get(payload, "at")));
        try complete(self, next.*, id, .null);
        return;
    }
    if (kind == 9) {
        try revision(next.value, payload);
        const chain = try C.path(a, next.value);
        const first = j.text(j.get(payload, "first_kept"));
        const boundary = C.retentionIndex(chain, first) orelse return error.InvalidRetentionBoundary;
        if (boundary <= C.retained(chain).first) return error.InvalidRetentionBoundary;
        const parts = j.get(payload, "parts");
        if (parts != .array or parts.array.items.len == 0 or parts.array.items.len > 16) return error.InvalidSummaryParts;
        var running = try j.copy(a, payload);
        try j.put(a, &running, "id", j.string(try a.dupe(u8, id)));
        try j.put(a, &running, "kind", j.integer(9));
        try j.put(a, &running, "phase", j.string("model"));
        try j.put(a, &running, "tools", j.array(a));
        try j.put(a, &running, "summary", j.string(""));
        try j.put(a, &running, "summary_usage", j.array(a));
        try j.put(a, &running, "part", j.integer(0));
        try j.put(a, &next.value, "active", running);
        try self.stage(next.*, &.{});
        return;
    }
    if (kind != 8) return error.InvalidArgument;
    const continuation = j.get(payload, "continuation");
    var running: j.Value = undefined;
    if (continuation == .string) {
        if (suspended != .object or !std.mem.eql(u8, j.text(j.get(suspended, "continuation")), continuation.string)) return error.InvalidContinuation;
        running = try j.copy(a, suspended);
        try j.put(a, &next.value, "suspended", .null);
    } else {
        if (suspended != .null) return error.SuspendedRun;
        const text = j.get(payload, "input");
        if (text != .string or text.string.len == 0) return error.InvalidInput;
        _ = try C.appendInput(next, text.string);
        running = j.object();
        try j.put(a, &running, "kind", j.integer(1));
        try j.put(a, &running, "phase", j.string("model"));
        try j.put(a, &running, "tools", try j.copy(a, j.get(next.value, "tools")));
        try j.put(a, &running, "registry_revision", j.get(next.value, "registry_revision"));
        try j.put(a, &running, "round", j.integer(0));
        try j.put(a, &running, "effects", j.array(a));
        try j.put(a, &running, "model", try j.copy(a, j.get(payload, "model")));
    }
    try j.put(a, &running, "id", j.string(try a.dupe(u8, id)));
    try j.put(a, &running, "context_ceiling", j.get(payload, "context_ceiling"));
    try j.put(a, &next.value, "active", running);
    try j.put(a, &next.value, "conversation_model", j.get(j.get(running, "model"), "model"));
    try self.stage(next.*, &.{});
}

fn revision(state: j.Value, payload: j.Value) !void {
    if (j.number(j.get(j.get(state, "conversation"), "revision")) != j.number(j.get(payload, "expected_revision"))) return error.StaleRevision;
}

pub fn complete(self: *W, document: j.Document, id: []const u8, result: j.Value) !void {
    var next = document;
    const outcome = try logic.finish(&next, id, "completed", result, .null);
    try j.put(next.allocator(), &next.value, "active", .null);
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = outcome }});
}

pub fn yieldContext(self: *W, cause: []const u8) !void {
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    var running = j.get(next.value, "active");
    const id = j.text(j.get(running, "id"));
    const token = try std.fmt.allocPrint(a, "{s}:{s}:{d}", .{ self.session_id, id, self.sequence });
    try j.put(a, &running, "continuation", j.string(token));
    try j.put(a, &next.value, "suspended", running);
    var result = j.object();
    try j.put(a, &result, "continuation", j.string(token));
    try j.put(a, &result, "cause", j.string(cause));
    try j.put(a, &result, "context_tokens", j.integer(try C.estimate(a, next.value)));
    const outcome = try logic.finish(&next, id, "completed", result, .null);
    try j.put(a, &next.value, "active", .null);
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = outcome }});
}

pub fn summaryAdvance(self: *W) !bool {
    const active = j.get(self.state.value, "active");
    const parts = j.get(active, "parts").array.items;
    const index: usize = @intCast(j.number(j.get(active, "part")));
    if (index < parts.len and j.get(parts[index], "generate") != .null) return false;
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const running = j.ptr(&next.value, "active");
    if (index == parts.len) {
        const summary = j.text(j.get(running.*, "summary"));
        if (std.mem.trim(u8, summary, " \n\r\t").len == 0) return error.EmptySummary;
        const id = j.text(j.get(running.*, "id"));
        _ = try C.appendCheckpoint(&next, j.text(j.get(running.*, "first_kept")), summary, j.get(running.*, "metadata"), j.get(running.*, "summary_usage"));
        var result = j.object();
        try j.put(a, &result, "text", j.string(summary));
        try complete(self, next, id, result);
    } else {
        const literal = j.get(parts[index], "literal");
        if (literal != .string) return error.InvalidSummaryParts;
        try addPart(&next, literal.string, .null, false);
        try self.stage(next, &.{});
    }
    return true;
}

pub fn addPart(next: *j.Document, text: []const u8, usage: j.Value, generated: bool) !void {
    const a = next.allocator();
    const active = j.ptr(&next.value, "active");
    const previous = j.text(j.get(active.*, "summary"));
    if (previous.len + text.len > 1024 * 1024) return error.SummaryLimitExceeded;
    try j.put(a, active, "summary", j.string(try std.mem.concat(a, u8, &.{ previous, text })));
    try j.put(a, active, "part", j.integer(j.number(j.get(active.*, "part")) + 1));
    if (generated) try j.ptr(active, "summary_usage").array.append(try j.copy(a, usage));
}
