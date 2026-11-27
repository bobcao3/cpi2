const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const api = W.api;
const logic = @import("logic.zig");
const work = @import("work.zig");
const model = @import("model.zig");
const Conversation = @import("Conversation.zig");
const RunState = @import("RunState.zig");

pub fn process(self: *W, reply_index: usize) !void {
    const reply = self.replies.orderedRemove(reply_index);
    defer self.gpa.free(reply.bytes);
    var index: usize = 0;
    while (index < self.operations.items.len and self.operations.items[index].id != reply.operation) : (index += 1) {}
    if (index == self.operations.items.len) return error.StaleOperation;
    const current = &self.operations.items[index];
    if (reply.kind == api.CPI_AGENT_IO_META) {
        const replacement = try j.Document.init(self.gpa, reply.bytes);
        if (current.meta) |*old| old.deinit();
        current.meta = replacement;
        return;
    }
    if (reply.kind == api.CPI_AGENT_IO_DATA) {
        try current.data.appendSlice(self.gpa, reply.bytes);
        return;
    }
    var operation = self.operations.orderedRemove(index);
    defer self.gpa.free(operation.invocation);
    defer operation.data.deinit(self.gpa);
    defer if (operation.meta) |*meta| meta.deinit();
    if (self.external == operation.id) self.external = null;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const value = if (reply.kind == api.CPI_AGENT_IO_CANCELLED)
        try logic.diagnostic(a, "cancelled", "The host operation was cancelled.")
    else if (reply.bytes.len > 0)
        try j.parse(a, reply.bytes)
    else
        j.object();
    if (operation.kind == .effect) try @import("LuauJournalIO.zig").receipt(self, operation, reply.kind, value);
    if (operation.obsolete) {
        if (operation.kind == .http) try @import("LuauJournalIO.zig").receipt(self, operation, reply.kind, value);
        var next = try self.mutate();
        errdefer next.deinit();
        const allocator = next.allocator();
        if (j.get(next.value, "late_receipts") != .array) try j.put(allocator, &next.value, "late_receipts", j.array(allocator));
        const receipt = try j.projectOwned(allocator, .{ .operation = operation.id, .invocation = operation.invocation, .cancel_requested = operation.cancelled, .outcome_kind = reply.kind, .outcome = value });
        try j.ptr(&next.value, "late_receipts").array.append(receipt);
        try self.stage(next, &.{});
        return;
    }
    if (operation.kind == .effect) return work.effectResult(self, value, reply.kind != api.CPI_AGENT_IO_DONE);
    const active = j.get(self.state.value, "active");
    if (j.text(j.get(active, "stop")).len > 0) {
        _ = try work.stop(self);
        return;
    }
    var envelope = value;
    if (reply.kind == api.CPI_AGENT_IO_DONE and j.get(envelope, "body") == .null and operation.data.items.len > 0) {
        const body = try j.parse(a, operation.data.items);
        envelope = j.object();
        try j.put(a, &envelope, "body", body);
        const status = if (operation.meta) |meta| j.get(meta.value, "status") else j.integer(200);
        try j.put(a, &envelope, "status", status);
    }
    try @import("LuauJournalIO.zig").receipt(self, operation, reply.kind, envelope);
    try model.receive(self, envelope, reply.kind != api.CPI_AGENT_IO_DONE);
}

pub fn committed(self: *W) !void {
    self.closed = j.flag(j.get(self.state.value, "closed"));
    const active = j.get(self.state.value, "active");
    const stop = j.text(j.get(active, "stop"));
    if (std.mem.eql(u8, stop, "cancel")) try self.cancelExternal();
    if (std.mem.eql(u8, stop, "steer") and std.mem.eql(u8, j.text(j.get(active, "phase")), "model") and
        !std.mem.eql(u8, j.text(j.get(active, "steer_policy")), "at_boundary")) try self.cancelExternal();
}

fn validate(a: std.mem.Allocator, snapshot: j.Value) !void {
    if (snapshot != .object or j.get(snapshot, "commands") != .array or j.get(snapshot, "capabilities") != .array or
        j.get(snapshot, "capabilities_revision") != .integer) return error.InvalidJournal;
    for (snapshot.object.keys()) |key| {
        var known = false;
        inline for (.{ "ctx", "application_scope", "capabilities", "capabilities_revision", "conversation", "commands", "active", "suspended", "conversation_model", "closing", "closed", "close_id", "late_receipts" }) |field| {
            if (std.mem.eql(u8, key, field)) known = true;
        }
        if (!known) return error.InvalidJournal;
    }
    const conversation = j.get(snapshot, "conversation");
    if (conversation != .object or j.get(conversation, "entries") != .array or j.get(conversation, "revision") != .integer or
        (j.get(conversation, "head") != .null and j.get(conversation, "head") != .string)) return error.InvalidJournal;
    for (j.get(conversation, "entries").array.items) |entry| {
        Conversation.validateEntry(entry) catch return error.InvalidJournal;
    }
    const ctx = j.get(snapshot, "ctx");
    if (ctx != .object and ctx != .array) return error.InvalidJournal;
    const scope = j.get(snapshot, "application_scope");
    if (scope != .null and (scope != .string or scope.string.len == 0)) return error.InvalidJournal;
    const active = j.get(snapshot, "active");
    if (active != .null and active != .object) return error.InvalidJournal;
    var commands: std.StringHashMapUnmanaged(void) = .empty;
    defer commands.deinit(a);
    for (j.get(snapshot, "commands").array.items) |entry| {
        if (entry != .object or j.get(entry, "id") != .string or j.get(entry, "kind") != .integer or
            j.get(entry, "status") != .string or j.get(entry, "payload") != .object) return error.InvalidJournal;
        const id = j.text(j.get(entry, "id"));
        if (id.len == 0 or (try commands.getOrPut(a, id)).found_existing) return error.InvalidJournal;
    }
    if (active != .null and !commands.contains(j.text(j.get(active, "id")))) return error.InvalidJournal;
    for (j.get(snapshot, "capabilities").array.items) |entry| {
        if (j.get(entry, "name") != .string or j.get(entry, "source") != .string or j.get(entry, "descriptor") != .object) return error.InvalidJournal;
        const expected = j.sourceHash(j.text(j.get(entry, "source")));
        if (!std.mem.eql(u8, &expected, j.text(j.get(entry, "source_hash")))) return error.InvalidJournal;
    }
    for ([_]j.Value{ active, j.get(snapshot, "suspended") }) |run| {
        if (run == .null) continue;
        if (run != .object or j.get(run, "id") != .string or j.get(run, "kind") != .integer or
            j.get(run, "capabilities") != .array or j.get(run, "capabilities_revision") != .integer or
            j.get(run, "phase") != .string or run.object.contains("tools") or
            run.object.contains("registry_revision")) return error.InvalidJournal;
    }
}

fn recoveredModelReply(self: *W, a: std.mem.Allocator, active: j.Value) !j.Value {
    const id = j.text(j.get(active, "core_effect_id"));
    const operation = self.journal.state.effects.get(id) orelse return .null;
    const finish = operation.finish orelse return .null;
    const intent = (try self.journal.frame(a, operation.intent)).action.@"control.effect.intent";
    if (!std.mem.eql(u8, intent.endpoint.name, "model.request")) return .null;
    const receipt = (try self.journal.frame(a, finish)).action.@"control.effect.result";
    if (receipt.status != .completed and receipt.status != .failed) return .null;
    const raw = try j.parse(a, j.text(j.get(receipt.result, "json")));
    const reply = try @import("responses.zig").interpret(a, raw, receipt.status == .failed);
    if (reply.status == .poll_pending) return .null;
    return j.projectOwned(a, reply);
}

fn interruptedModel(self: *W, a: std.mem.Allocator, active: j.Value, has_reply: bool) !?u64 {
    if (!j.flag(j.get(j.get(self.options.value, "recovery"), "model_progress"))) return null;
    const ref = j.number(j.get(active, "core_model_request"));
    if (ref == 0) return null;
    const intent = (try self.journal.frame(a, ref)).action.@"control.model.request";
    const request = self.journal.state.requests.get(intent.request_id) orelse return null;
    return if ((has_reply or request.progress != null) and request.finish == null and !request.cancelled) ref else null;
}

pub fn applicationInterruption(self: *W, a: std.mem.Allocator, context: j.Value, active: j.Value, reply: j.Value) !?j.Value {
    const saved = j.get(context, "__interrupted_application");
    const ref = try interruptedModel(self, a, active, reply == .object);
    if (saved == .object and ref == null) return null;
    var interrupted = try j.project(a, .{
        .request_id = j.get(active, "id"),
        .input_json = if (saved == .object) j.get(saved, "input_json") else j.get(active, "input_json"),
    });
    const restarts = j.get(saved, "restarts");
    if (restarts == .integer) try j.put(a, &interrupted, "restarts", restarts);
    if (reply == .object) try j.put(a, &interrupted, "model_reply", reply);
    if (ref) |request| {
        try j.put(a, &interrupted, "model_resume", j.integer(request));
        const part = j.get(j.get(context, "compaction_progress"), "active_part");
        if (part == .string) try j.put(a, &interrupted, "model_part", part);
    }
    return interrupted;
}

fn captureApplicationInterruption(self: *W, a: std.mem.Allocator, context: *j.Value, active: j.Value) !void {
    const reply = try recoveredModelReply(self, a, active);
    if (try applicationInterruption(self, a, context.*, active, reply)) |interrupted| {
        try j.put(a, context, "__interrupted_application", interrupted);
    }
}

pub fn recover(self: *W) !void {
    const sequence = self.journal.sequence;
    self.recovery_pending = sequence != 0;
    if (sequence != 0) {
        var recovered = try @import("LuauJournal.zig").restore(&self.journal, self.context_codec, self.gpa);
        errdefer recovered.deinit();
        try validate(recovered.allocator(), recovered.value);
        self.state.deinit();
        self.state = recovered;
    }
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    self.sequence = sequence;
    if (sequence == 0) {
        try j.put(a, &next.value, "capabilities", try j.copy(a, self.initial.value));
        if (self.initial.value.array.items.len > 0) try j.put(a, &next.value, "capabilities_revision", j.integer(1));
    }
    const active = j.get(next.value, "active");
    if (active != .null) {
        try work.captureInterruption(self, &next);
        if (j.flag(j.get(j.get(self.options.value, "recovery"), "application_checkpoint")) and j.flag(j.get(active, "application"))) {
            const context = j.ptr(&next.value, "ctx");
            if (std.mem.eql(u8, j.text(j.get(active, "stop")), "cancel")) {
                _ = context.object.orderedRemove("__interrupted_application");
            } else {
                try captureApplicationInterruption(self, a, context, active);
            }
        }
        var failure = try logic.diagnostic(a, "interrupted", "The previous invocation did not reach completion; its effects are not replayed.");
        try j.put(a, &failure, "effects", j.get(active, "effects"));
        if (j.number(j.get(active, "kind")) == 1) {
            _ = try Conversation.appendProgram(&next, j.text(j.get(active, "call_id")), failure, true, j.get(active, "effects"));
            const pending = j.get(active, "pending_calls");
            if (pending == .array) for (pending.array.items) |call| {
                _ = try Conversation.appendProgram(&next, j.text(j.get(call, "call_id")), failure, true, j.get(active, "effects"));
            };
        }
    }
    const resume_queued = std.mem.eql(u8, j.text(j.get(j.get(self.options.value, "recovery"), "queued")), "resume");
    for (j.ptr(&next.value, "commands").array.items) |*entry| {
        const status = j.text(j.get(entry.*, "status"));
        const running = std.mem.eql(u8, status, "running");
        const queued = std.mem.eql(u8, status, "queued");
        if (!running and !(queued and !resume_queued)) continue;
        var failure = try logic.diagnostic(a, if (running) "interrupted" else "interrupted_not_started", if (running)
            "The previous process stopped during this command."
        else
            "This command was admitted but did not start before the previous process stopped.");
        const id = j.text(j.get(entry.*, "id"));
        if (active != .null and std.mem.eql(u8, id, j.text(j.get(active, "id"))))
            try j.put(a, &failure, "effects", j.get(active, "effects"));
        _ = try logic.finish(&next, id, "failed", .null, failure);
    }
    try RunState.clear(&next, .suspended);
    try Conversation.repair(&next);
    try RunState.clear(&next, .active);
    try j.put(a, &next.value, "closing", .{ .bool = false });
    try j.put(a, &next.value, "closed", .{ .bool = false });
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_READY }});
}
