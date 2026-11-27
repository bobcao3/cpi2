const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const api = W.api;
const responses = @import("responses.zig");
const logic = @import("logic.zig");
const work = @import("work.zig");
const Conversation = @import("Conversation.zig");
const RunState = @import("RunState.zig");

fn setting(self: *W, name: []const u8, fallback: []const u8) []const u8 {
    const options = j.get(j.get(self.state.value, "active"), "model");
    const item = j.get(if (options == .object) options else self.options.value, name);
    return if (item == .string) item.string else fallback;
}

pub fn dispatch(self: *W) !bool {
    const active = j.get(self.state.value, "active");
    const summary = j.number(j.get(active, "kind")) == 9;
    if (summary and (@import("domain_ops.zig").summaryAdvance(self) catch |err| {
        try fail(self, @errorName(err), "The summary could not be committed.");
        return true;
    })) return true;
    var estimate_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer estimate_arena.deinit();
    const ceiling = j.number(j.get(active, "context_ceiling"));
    const projection = if (summary) @as(j.Value, .null) else try self.projectionState(estimate_arena.allocator());
    if (!summary and ceiling > 0 and try Conversation.estimate(estimate_arena.allocator(), projection) > ceiling) {
        try @import("domain_ops.zig").yieldContext(self, .ceiling);
        return true;
    }
    if (!summary) if (self.max_rounds) |maximum| if (j.number(j.get(active, "round")) >= maximum) {
        try fail(self, "turn_limit", "The model run reached its explicitly configured turn limit.");
        return true;
    };
    const config: responses.Config = .{
        .model = setting(self, "model", "deepseek-flash"),
        .base_url = setting(self, "base_url", "https://api.deepseek.com"),
        .reasoning_effort = blk: {
            const options = j.get(active, "model");
            const value = j.get(if (options == .object) options else self.options.value, "reasoning_effort");
            break :blk if (value == .string) value.string else null;
        },
        .max_output_tokens = @intCast(j.number(j.get(j.get(active, "model"), "max_output_tokens")) + if (j.number(j.get(j.get(active, "model"), "max_output_tokens")) == 0) @as(u64, 4096) else 0),
        .instructions = setting(self, "instructions", ""),
    };
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var descriptors = j.array(a);
    for (j.get(active, "capabilities").array.items) |capability| try descriptors.array.append(j.get(capability, "descriptor"));
    const body = if (summary) blk: {
        const index: usize = @intCast(j.number(j.get(active, "part")));
        const generate = j.get(j.get(active, "parts").array.items[index], "generate");
        break :blk try std.json.Stringify.valueAlloc(a, .{ .model = config.model, .instructions = j.get(generate, "instructions"), .input = .{.{ .role = "user", .content = j.get(generate, "input") }}, .max_output_tokens = config.max_output_tokens, .reasoning = if (config.reasoning_effort) |effort| .{ .effort = effort } else null, .store = false, .include = .{"reasoning.encrypted_content"} }, .{ .emit_null_optional_fields = false });
    } else try responses.request(a, config, try Conversation.project(a, projection), descriptors);
    const url = try responses.url(a, config);
    var packet = j.object();
    try j.put(a, &packet, "url", j.string(url));
    const credential = setting(self, "credential", if (std.mem.startsWith(u8, url, "https://api.deepseek.com/")) "deepseek" else "");
    try j.put(a, &packet, "credential", j.string(credential));
    try j.put(a, &packet, "body", try j.parse(a, body));
    self.external = try self.request(.http, "http.request", j.text(j.get(active, "id")), packet);
    return false;
}

pub fn receive(self: *W, envelope: j.Value, transport_failed: bool) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const response = try responses.interpret(arena.allocator(), envelope, transport_failed);
    const summarizing = j.number(j.get(j.get(self.state.value, "active"), "kind")) == 9;
    if (response.status != .completed and (summarizing or response.stop_reason != .length)) {
        if (response.status == .overflow and !summarizing)
            return @import("domain_ops.zig").yieldContext(self, .provider_overflow);
        const code = j.text(j.get(response.@"error", "code"));
        const message = j.text(j.get(response.@"error", "message"));
        if (response.status == .cancelled) return cancelled(self, code, message);
        return fail(self, code, message);
    }
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    if (summarizing) {
        if (response.calls.len > 0 or std.mem.trim(u8, response.text, " \r\n\t").len == 0) {
            next.deinit();
            return fail(self, "invalid_summary", "Summary must contain nonempty text and no tool calls.");
        }
        try @import("domain_ops.zig").addPart(&next, response.text, j.get(response.raw, "usage"), true);
        try self.stage(next, &.{});
        return;
    }
    const response_model = j.text(j.get(response.raw, "model"));
    _ = try Conversation.appendResponse(&next, response.output, response_model, j.get(response.raw, "usage"));
    const active = j.ptr(&next.value, "active");
    const id = j.text(j.get(active.*, "id"));
    try j.put(a, active, "round", j.integer(j.number(j.get(active.*, "round")) + 1));
    if (response.calls.len > 0) {
        var calls = j.array(a);
        for (response.calls) |call| {
            var item = j.object();
            try j.put(a, &item, "call_id", j.string(try a.dupe(u8, call.call_id)));
            try j.put(a, &item, "name", j.string(try a.dupe(u8, call.name)));
            try j.put(a, &item, "arguments", j.string(try j.encode(a, call.arguments)));
            try calls.array.append(item);
        }
        const first = calls.array.orderedRemove(0);
        try j.put(a, active, "pending_calls", calls);
        try work.configureCall(&next, first);
        try self.stage(next, &.{});
    } else {
        var result = j.object();
        try j.put(a, &result, "text", j.string(try a.dupe(u8, response.text)));
        try j.put(a, &result, "model", j.string(try a.dupe(u8, response_model)));
        try j.put(a, &result, "usage", try j.copy(a, j.get(response.raw, "usage")));
        if (response.stop_reason) |reason| try j.put(a, &result, "stop_reason", j.string(@tagName(reason)));
        const completed = try logic.finish(&next, id, "completed", result, .null);
        try RunState.clear(&next, .active);
        try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
    }
}

pub fn fail(self: *W, code: []const u8, message: []const u8) !void {
    return finishFailure(self, "failed", code, message);
}

pub fn cancelled(self: *W, code: []const u8, message: []const u8) !void {
    return finishFailure(self, "cancelled", code, message);
}

fn finishFailure(self: *W, status: []const u8, code: []const u8, message: []const u8) !void {
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const active = j.get(next.value, "active");
    const id = j.text(j.get(active, "id"));
    const failure = try logic.diagnostic(a, code, message);
    const completed = try logic.finish(&next, id, status, .null, failure);
    try RunState.clear(&next, .active);
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
    self.stopVm();
}
