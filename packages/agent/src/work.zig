const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const api = W.api;
const vm = @import("vm");
const logic = @import("logic.zig");
const model = @import("model.zig");
const Conversation = @import("Conversation.zig");
const RunState = @import("RunState.zig");
const application_context = @import("LuauContextJournal.zig");
const Value = j.Value;

pub fn advance(self: *W, instructions: u32) !bool {
    const active = j.get(self.state.value, "active");
    const phase = j.text(j.get(active, "phase"));
    if (std.mem.eql(u8, phase, "model")) return model.dispatch(self);
    if (std.mem.eql(u8, phase, "effect")) {
        const effect = j.get(active, "effect");
        const name = j.text(j.get(effect, "tool_name"));
        const endpoint = j.text(j.get(effect, "endpoint"));
        if (!permitted(self, active, name, endpoint)) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const failure = try logic.diagnostic(arena.allocator(), "permission_denied", endpoint);
            try effectResult(self, failure, true);
            return true;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var packet = j.object();
        try j.put(a, &packet, "endpoint", j.string(endpoint));
        try j.put(a, &packet, "arguments", j.get(effect, "arguments"));
        const model_binding = j.flag(j.get(active, "application")) and std.mem.eql(u8, name, "__application") and std.mem.eql(u8, endpoint, "model.request");
        try j.put(a, &packet, "model_binding", .{ .bool = model_binding });
        if (model_binding) {
            const binding = j.get(active, "application_model");
            if (binding != .null) try j.put(a, &packet, "application_model", binding);
        }
        try j.put(a, &packet, "idempotency_key", j.string(try std.fmt.allocPrint(a, "{s}:{d}", .{ self.session_id, self.sequence })));
        self.external = try self.request(.effect, "rpc.call", j.text(j.get(active, "id")), packet);
        return false;
    }
    if (!std.mem.eql(u8, phase, "lua")) return error.InvalidState;
    if (self.vm == null) {
        const tools = j.get(active, "capabilities");
        const entries = try self.gpa.alloc(vm.Tool, tools.array.items.len);
        defer self.gpa.free(entries);
        for (tools.array.items, entries, 0..) |tool, *entry, index| entry.* = .{ .name = j.text(j.get(tool, "name")), .source = j.text(j.get(tool, "source")), .registered = self.active_capabilities.items[index] };
        const ctx = try j.encode(self.gpa, j.get(self.state.value, "ctx"));
        defer self.gpa.free(ctx);
        const machine = if (j.flag(j.get(active, "application")))
            self.heap.beginApplication(self.gpa, ctx, entries, j.text(j.get(active, "source")), .{
                .input_json = j.text(j.get(active, "input_json")),
                .environment_json = j.text(j.get(active, "environment_json")),
                .mutable = j.flag(j.get(active, "mutable")),
            })
        else
            self.heap.begin(self.gpa, ctx, entries, j.text(j.get(active, "source")));
        self.vm = machine catch |err| {
            try programFailed(self, @errorName(err));
            return true;
        };
    }
    const reply: ?vm.Reply = if (self.vm_reply) |bytes| .{ .json = bytes, .failed = self.vm_reply_failed } else null;
    const result = self.vm.?.step(instructions, reply) catch |err| {
        try programFailed(self, @errorName(err));
        return true;
    };
    self.clearVmReply();
    switch (result) {
        .budget => return false,
        .failed => |failure| {
            var next = try self.mutate();
            errdefer next.deinit();
            try images(&next, failure.images_json);
            try captureInterruption(self, &next);
            const diagnostic = try logic.diagnostic(next.allocator(), "lua_error", failure.message);
            try completeProgram(self, next, diagnostic, true);
            self.stopVm();
        },
        .done => |completed| {
            var next = try self.mutate();
            errdefer next.deinit();
            const a = next.allocator();
            try j.put(a, &next.value, "ctx", try j.parse(a, completed.ctx_json));
            try images(&next, completed.images_json);
            var result_value = try j.parse(a, completed.result_json);
            if (self.context_codec.defer_model_poll and j.flag(j.get(result_value, "retain_model_reply"))) {
                _ = result_value.object.orderedRemove("retain_model_reply");
                const running = j.get(next.value, "active");
                const model_reply = j.get(j.get(running, "reply"), "value");
                if (model_reply != .object or j.get(model_reply, "status") != .string or std.mem.eql(u8, j.text(j.get(model_reply, "status")), "poll_pending")) return error.InvalidModelReply;
                const context = j.ptr(&next.value, "ctx");
                const retained = try @import("io.zig").applicationInterruption(self, a, context.*, running, model_reply) orelse
                    try j.project(a, .{ .model_reply = model_reply });
                try j.put(a, context, "__interrupted_application", retained);
            }
            try completeProgram(self, next, result_value, false);
            self.stopVm();
        },
        .effect => |effect| {
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__claim_boundary_input")) {
                var scratch: std.heap.ArenaAllocator = .init(self.gpa);
                defer scratch.deinit();
                const a = scratch.allocator();
                const mode = j.text(j.get(try j.parse(a, effect.arguments_json), "mode"));
                const bindings = self.application_bindings;
                const claim = if (bindings.claim_boundary_input) |claim_input|
                    if (!self.bootstrap) try claim_input(bindings.context, a, &self.journal.state.extensions, application_context.scope(self.state.value), j.get(self.state.value, "ctx"), mode) else null
                else
                    null;
                const response = try j.encode(self.gpa, if (claim) |chosen| chosen.value else .null);
                errdefer self.gpa.free(response);
                if (claim) |chosen| if (chosen.action) |action| {
                    const tx = try std.fmt.allocPrint(a, "boundary-input-{d}", .{self.journal.sequence + 1});
                    _ = try self.recordSession(tx, &.{action});
                };
                self.vm_reply = response;
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__runtime_options")) {
                var scratch: std.heap.ArenaAllocator = .init(self.gpa);
                defer scratch.deinit();
                self.vm_reply = try j.encode(self.gpa, try self.application_bindings.options(scratch.allocator()));
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__size_warning")) {
                var report = try j.Document.init(self.gpa, effect.arguments_json);
                defer report.deinit();
                const measurement = j.text(j.get(report.value, "measurement"));
                const actual = std.math.cast(usize, j.number(j.get(report.value, "actual"))) orelse std.math.maxInt(usize);
                const threshold = std.math.cast(usize, j.number(j.get(report.value, "threshold"))) orelse std.math.maxInt(usize);
                const sink: @import("session_protocol").Transaction.SizeSink = self.application_size_warnings orelse .{};
                sink.report(measurement, actual, threshold);
                self.vm_reply = try self.gpa.dupe(u8, "null");
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__clock")) {
                self.vm_reply = try std.fmt.allocPrint(self.gpa, "{d}", .{std.Io.Clock.real.now(self.io_backend).toMilliseconds()});
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__history")) {
                var query = try j.Document.init(self.gpa, effect.arguments_json);
                defer query.deinit();
                const id = j.get(query.value, "id");
                if (id != .string or id.string.len == 0) return error.InvalidArgument;
                if (self.bootstrap) {
                    const pending = j.get(self.state.value, "pending_history");
                    if (pending == .array) for (pending.array.items) |entry| {
                        if (!std.mem.eql(u8, id.string, j.text(j.get(entry, "id")))) continue;
                        self.vm_reply = try j.encode(self.gpa, entry);
                        self.vm_reply_failed = false;
                        return true;
                    };
                }
                const scope = application_context.scope(self.state.value);
                const bytes = (try self.applicationHistoryJson(query.allocator(), scope, id.string)) orelse "null";
                try j.validateText(self.gpa, bytes);
                self.vm_reply = try self.gpa.dupe(u8, bytes);
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__progress")) {
                if (!self.bootstrap and effect.arguments_json.len <= 16 * 1024) {
                    var report = try j.Document.init(self.gpa, effect.arguments_json);
                    defer report.deinit();
                    if (report.value == .object) {
                        const scope = application_context.scope(self.state.value);
                        if (std.mem.eql(u8, scope, application_context.main)) {
                            _ = report.value.object.orderedRemove("conversation");
                        } else {
                            try j.put(report.allocator(), &report.value, "conversation", j.string(scope));
                        }
                        try self.emit(api.CPI_AGENT_EVENT_PROGRESS, 0, 0, j.text(j.get(active, "id")), "", report.value);
                    }
                }
                self.vm_reply = try self.gpa.dupe(u8, "null");
                self.vm_reply_failed = false;
                return true;
            }
            if (j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.tool_name, "__application") and std.mem.eql(u8, effect.endpoint, "__checkpoint")) {
                var next = try self.mutate();
                errdefer next.deinit();
                const a = next.allocator();
                var progress = try j.parse(a, effect.arguments_json);
                try j.put(a, &next.value, "ctx", try j.parse(a, effect.ctx_json));
                try images(&next, effect.images_json);
                const running = j.ptr(&next.value, "active");
                try j.put(a, running, "safe_boundary", j.get(progress, "boundary"));
                try j.put(a, running, "reply", try j.parse(a, "{\"value\":null,\"failed\":false}"));
                const id = j.text(j.get(running.*, "id"));
                const scope = application_context.scope(next.value);
                if (j.get(progress, "event") == .object and !std.mem.eql(u8, scope, application_context.main)) try j.put(a, j.ptr(&progress, "event"), "conversation", j.string(scope));
                try commitReply(self, next, &.{
                    .{ .kind = api.CPI_AGENT_EVENT_CTX_COMMITTED, .request = id },
                    .{ .kind = api.CPI_AGENT_EVENT_PROGRESS, .request = id, .payload = j.get(progress, "event") },
                }, j.get(progress, "history"));
                return true;
            }
            if (self.bootstrap) return error.BootstrapExternalEffect;
            const application_model = j.flag(j.get(active, "application")) and std.mem.eql(u8, effect.endpoint, "model.request");
            if (application_model) if (self.max_rounds) |maximum| if (j.number(j.get(active, "round")) >= maximum) {
                try model.fail(self, "turn_limit", "The application reached its explicitly configured model request limit.");
                return true;
            };
            var next = try self.mutate();
            errdefer next.deinit();
            const a = next.allocator();
            try j.put(a, &next.value, "ctx", try j.parse(a, effect.ctx_json));
            try images(&next, effect.images_json);
            const running = j.ptr(&next.value, "active");
            try j.put(a, running, "safe_boundary", .{ .bool = false });
            if (application_model) try j.put(a, running, "round", j.integer(j.number(j.get(running.*, "round")) + 1));
            var intent = j.object();
            try j.put(a, &intent, "tool_name", j.string(try a.dupe(u8, effect.tool_name)));
            try j.put(a, &intent, "endpoint", j.string(try a.dupe(u8, effect.endpoint)));
            try j.put(a, &intent, "arguments", try j.parse(a, effect.arguments_json));
            try j.put(a, &intent, "status", j.string("running"));
            try j.put(a, running, "effect", intent);
            try j.put(a, running, "reply", .null);
            try j.put(a, running, "phase", j.string("effect"));
            try j.put(a, running, "core_effect_id", .null);
            try j.ptr(running, "effects").array.append(intent);
            const id = j.text(j.get(running.*, "id"));
            try self.stage(next, &.{
                .{ .kind = api.CPI_AGENT_EVENT_CTX_COMMITTED, .request = id, .payload = j.get(next.value, "ctx") },
                .{ .kind = api.CPI_AGENT_EVENT_TOOL_STARTED, .request = id, .payload = intent },
            });
        },
    }
    return true;
}

fn permitted(self: *W, active: Value, name: []const u8, endpoint: []const u8) bool {
    const grants = j.get(self.options.value, "endpoint_grants");
    var granted = false;
    if (grants == .array) for (grants.array.items) |grant| {
        if (std.mem.eql(u8, j.text(grant), endpoint)) granted = true;
    };
    if (!granted) return false;
    if (j.flag(j.get(active, "application")) and std.mem.eql(u8, name, "__application") and
        (std.mem.eql(u8, endpoint, "model.request") or std.mem.eql(u8, endpoint, "harness.wait"))) return true;
    for (j.get(active, "capabilities").array.items) |capability| {
        if (!std.mem.eql(u8, j.text(j.get(capability, "name")), name)) continue;
        const endpoints = j.get(j.get(capability, "descriptor"), "endpoints");
        if (endpoints != .array) return false;
        for (endpoints.array.items) |entry| if (std.mem.eql(u8, j.text(entry), endpoint)) return true;
    }
    return false;
}

pub fn effectResult(self: *W, value: Value, failed: bool) !void {
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const active = j.ptr(&next.value, "active");
    const effects = j.ptr(active, "effects");
    const last = &effects.array.items[effects.array.items.len - 1];
    try j.put(a, last, "result", try j.copy(a, value));
    try j.put(a, last, "failed", .{ .bool = failed });
    try j.put(a, last, "status", j.string(if (failed) "failed" else "completed"));
    const effect = j.get(active.*, "effect");
    const application_model = j.flag(j.get(active.*, "application")) and
        std.mem.eql(u8, j.text(j.get(effect, "tool_name")), "__application") and
        std.mem.eql(u8, j.text(j.get(effect, "endpoint")), "model.request");
    const reply_value = if (application_model) blk: {
        const interpreted = try @import("responses.zig").interpret(a, value, failed);
        var projected = try j.projectOwned(a, interpreted);
        if (interpreted.status == .poll_pending) {
            const marker = try @import("io.zig").applicationInterruption(self, a, j.get(next.value, "ctx"), active.*, .null) orelse return error.MissingModelContinuation;
            if (j.number(j.get(marker, "model_resume")) == 0) return error.MissingModelContinuation;
            try j.put(a, &projected, "continuation", marker);
        }
        break :blk projected;
    } else try j.copy(a, value);
    var reply = j.object();
    try j.put(a, &reply, "value", reply_value);
    try j.put(a, &reply, "failed", .{ .bool = failed and !application_model });
    try j.put(a, active, "reply", reply);
    try j.put(a, active, "phase", j.string("lua"));
    const id = j.text(j.get(active.*, "id"));
    try commitReply(self, next, &.{.{ .kind = api.CPI_AGENT_EVENT_TOOL_FINISHED, .request = id, .payload = last.* }}, .null);
}

// The snapshot retains the last reply for recovery. Only the commit that
// produced it may enqueue it for the live coroutine.
fn commitReply(self: *W, next: j.Document, notices: []const W.Notice, history: Value) !void {
    const reply = j.get(j.get(next.value, "active"), "reply");
    const failed = j.flag(j.get(reply, "failed"));
    const pending = if (self.vm != null) try j.encode(self.gpa, j.get(reply, "value")) else null;
    errdefer if (pending) |bytes| self.gpa.free(bytes);
    try self.stageHistory(next, notices, history);
    std.debug.assert(self.vm_reply == null);
    self.vm_reply = pending;
    self.vm_reply_failed = failed;
}

pub fn programFailed(self: *W, message: []const u8) !void {
    var next = try self.mutate();
    errdefer next.deinit();
    try captureInterruption(self, &next);
    const failure = try logic.diagnostic(next.allocator(), "lua_error", message);
    try completeProgram(self, next, failure, true);
    self.stopVm();
}

pub fn completeProgram(self: *W, document: j.Document, result: Value, failed: bool) !void {
    var next = document;
    const active = j.ptr(&next.value, "active");
    const id = j.text(j.get(active.*, "id"));
    if (j.number(j.get(active.*, "kind")) == 1) {
        try appendOutput(&next, j.text(j.get(active.*, "call_id")), result, failed);
        const pending = j.get(active.*, "pending_calls");
        if (pending == .array and pending.array.items.len > 0) {
            const call = j.ptr(active, "pending_calls").array.orderedRemove(0);
            try configureCall(&next, call);
        } else try prepareModel(&next);
        try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_CTX_COMMITTED, .request = id, .payload = j.get(next.value, "ctx") }});
    } else {
        const completed = try logic.finish(&next, id, if (failed) "failed" else "completed", if (failed) .null else result, if (failed) result else .null);
        try RunState.clear(&next, .active);
        try self.stage(next, &.{
            .{ .kind = api.CPI_AGENT_EVENT_CTX_COMMITTED, .request = id, .payload = j.get(next.value, "ctx") },
            .{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed },
        });
    }
}

pub fn appendOutput(document: *j.Document, call_id: []const u8, result: Value, failed: bool) !void {
    if (call_id.len == 0) return;
    _ = try Conversation.appendProgram(document, call_id, result, failed, j.get(j.get(document.value, "active"), "effects"));
}

pub fn configureCall(document: *j.Document, call: Value) !void {
    const a = document.allocator();
    const active = j.ptr(&document.value, "active");
    try j.put(a, active, "call_id", j.get(call, "call_id"));
    var source: Value = j.string("error('Only execute_lua is supported')");
    if (std.mem.eql(u8, j.text(j.get(call, "name")), "execute_lua")) {
        const args = j.parse(a, j.text(j.get(call, "arguments"))) catch j.object();
        const candidate = j.get(args, "source");
        source = if (candidate == .string) candidate else j.string("error('execute_lua requires source')");
    }
    try j.put(a, active, "source", source);
    try j.put(a, active, "phase", j.string("lua"));
    try j.put(a, active, "reply", .null);
    try j.put(a, active, "images", j.array(a));
}

pub fn prepareModel(document: *j.Document) !void {
    const a = document.allocator();
    const active = j.ptr(&document.value, "active");
    try j.put(a, active, "phase", j.string("model"));
    try j.put(a, active, "source", .null);
    try j.put(a, active, "call_id", .null);
    try j.put(a, active, "stop", .null);
    try j.put(a, active, "reply", .null);
    try j.put(a, active, "capabilities", try j.copy(a, j.get(document.value, "capabilities")));
    try j.put(a, active, "capabilities_revision", j.get(document.value, "capabilities_revision"));
}

pub fn stop(self: *W) !bool {
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const active = j.ptr(&next.value, "active");
    const id = j.text(j.get(active.*, "id"));
    try captureInterruption(self, &next);
    const reason = j.text(j.get(active.*, "stop"));
    const failure = try logic.diagnostic(a, if (std.mem.eql(u8, reason, "steer")) "steered" else "cancelled", "The invocation stopped at a scheduling boundary.");
    if (j.number(j.get(active.*, "kind")) == 1) {
        try appendOutput(&next, j.text(j.get(active.*, "call_id")), failure, true);
        const pending = j.get(active.*, "pending_calls");
        if (pending == .array) for (pending.array.items) |call| try appendOutput(&next, j.text(j.get(call, "call_id")), failure, true);
        try j.put(a, active, "pending_calls", j.array(a));
    }
    const steering = j.get(active.*, "steering");
    if (steering == .array) for (steering.array.items) |input| {
        _ = try Conversation.appendInput(&next, j.text(input));
    };
    try j.put(a, active, "steering", j.array(a));
    self.stopVm();
    if (std.mem.eql(u8, reason, "steer")) {
        try prepareModel(&next);
        try self.stage(next, &.{});
    } else {
        const completed = try logic.finish(&next, id, "cancelled", try self.expandEffects(a, j.get(active.*, "effects")), failure);
        try RunState.clear(&next, .active);
        try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
    }
    return true;
}

fn images(next: *j.Document, bytes: []const u8) !void {
    const a = next.allocator();
    const active = j.ptr(&next.value, "active");
    if (j.get(active.*, "images") != .array) try j.put(a, active, "images", j.array(a));
    const parts = try j.parse(a, bytes);
    for (parts.array.items) |part| try j.ptr(active, "images").array.append(part);
}

pub fn captureInterruption(self: *W, document: *j.Document) !void {
    const ctx = j.ptr(&document.value, "ctx");
    if (j.get(ctx.*, "__capture") != .object) return;
    const a = document.allocator();
    const active = j.get(document.value, "active");
    const capture = j.ptr(ctx, "__capture");
    const first = j.number(j.get(capture.*, "start_sequence"));
    var observations = j.array(a);
    var sequence: u64 = 0;
    for (j.get(active, "effects").array.items) |effect| {
        if (std.mem.eql(u8, j.text(j.get(effect, "tool_name")), "__application")) continue;
        sequence += 1;
        const status = j.text(j.get(effect, "status"));
        if (sequence <= first or (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "failed"))) continue;
        try observations.array.append(try self.effectValue(a, effect));
    }
    try j.put(a, capture, "observations", observations);
    var retained = j.array(a);
    const images_value = j.get(active, "images");
    const start: usize = @intCast(j.number(j.get(capture.*, "start_image")) -| j.number(j.get(active, "image_base")));
    if (images_value == .array) for (images_value.array.items[@min(start, images_value.array.items.len)..]) |image| try retained.array.append(image);
    try j.put(a, capture, "images", retained);
}
