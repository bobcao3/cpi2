const std = @import("std");
const json_text = @import("json_tree").text;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const openai = @import("openai.zig");
const services = @import("services");
pub const Call = openai.Call;
pub const Response = openai.Response;
pub const Status = openai.Status;
pub const Invocation = openai.Invocation;
pub const Result = openai.Result;
pub const Preview = openai.Preview;
const field = openai.field;
const stringField = openai.stringField;
const present = openai.present;
const appendCall = openai.appendCall;
const freeCalls = openai.freeCalls;

pub const Dialect = enum { responses, codex };

pub const Config = struct {
    model: []const u8 = "deepseek-flash",
    base_url: []const u8 = "https://api.deepseek.com",
    reasoning_effort: ?[]const u8 = null,
    max_output_tokens: u32 = 4096,
    instructions: []const u8 = "",
};

pub fn url(allocator: Allocator, config: Config) ![]u8 {
    const base = std.mem.trimEnd(u8, config.base_url, "/");
    const uri = std.Uri.parse(base) catch return error.InvalidBaseUrl;
    if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or
        uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null) return error.InvalidBaseUrl;
    for (base) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidBaseUrl;
    }
    if (std.mem.endsWith(u8, base, "/responses")) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}/responses", .{base});
}

pub fn request(allocator: Allocator, config: Config, input: Value, descriptors: Value) ![]u8 {
    if (config.model.len == 0 or (config.reasoning_effort != null and config.reasoning_effort.?.len == 0) or config.max_output_tokens == 0)
        return error.InvalidConfig;
    if (input != .array) return error.InvalidInput;
    const instructions = try openai.instructions(allocator, config.instructions, descriptors);
    defer allocator.free(instructions);
    return std.json.Stringify.valueAlloc(allocator, .{
        .model = config.model,
        .instructions = instructions,
        .input = input,
        .reasoning = if (config.reasoning_effort) |effort| .{ .effort = effort } else null,
        .max_output_tokens = config.max_output_tokens,
        .stream = false,
        .store = false,
        .parallel_tool_calls = false,
        .include = .{"reasoning.encrypted_content"},
        .tool_choice = "auto",
        .tools = .{.{
            .type = "function",
            .name = "execute_lua",
            .description = "Run a safe Luau program using registered tools and persistent ctx.",
            .strict = true,
            .parameters = .{
                .type = "object",
                .properties = .{ .source = .{ .type = "string" } },
                .required = .{"source"},
                .additionalProperties = false,
            },
        }},
    }, .{ .emit_null_optional_fields = false });
}

fn checkStatus(status: []const u8) !void {
    if (std.mem.eql(u8, status, "completed")) return;
    if (std.mem.eql(u8, status, "incomplete")) return error.ResponseIncomplete;
    if (std.mem.eql(u8, status, "failed")) return error.ResponseFailed;
    if (std.mem.eql(u8, status, "cancelled")) return error.ResponseCancelled;
    if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "in_progress"))
        return error.ResponseNotCompleted;
    return error.InvalidResponseStatus;
}

fn appendText(allocator: Allocator, text: *std.ArrayList(u8), item: Value) !void {
    const role = stringField(item, "role") orelse return error.InvalidMessage;
    if (!std.mem.eql(u8, role, "assistant")) return error.InvalidMessage;
    const content = field(item, "content") orelse return error.InvalidMessage;
    if (content != .array) return error.InvalidMessage;
    for (content.array.items) |part| {
        const kind = stringField(part, "type") orelse return error.InvalidMessage;
        if (std.mem.eql(u8, kind, "output_text")) {
            try text.appendSlice(allocator, stringField(part, "text") orelse return error.InvalidMessage);
        } else if (std.mem.eql(u8, kind, "refusal")) {
            return error.ResponseRefused;
        }
    }
}

fn usageCount(value: Value, key: []const u8) !?u64 {
    const count = field(value, key) orelse return null;
    if (count != .integer or count.integer < 0) return error.InvalidUsage;
    return @intCast(count.integer);
}

fn usageDetails(usage: Value, key: []const u8) !Value {
    const details = field(usage, key) orelse return .null;
    if (details != .null and details != .object) return error.InvalidUsage;
    return details;
}

fn parseUsage(raw: Value) !?openai.Usage {
    if (raw == .null) return null;
    if (raw != .object) return error.InvalidUsage;
    const input = try usageDetails(raw, "input_tokens_details");
    const output = try usageDetails(raw, "output_tokens_details");
    return .{
        .input_tokens = try usageCount(raw, "input_tokens"),
        .output_tokens = try usageCount(raw, "output_tokens"),
        .total_tokens = try usageCount(raw, "total_tokens"),
        .cache_read_tokens = try usageCount(input, "cached_tokens"),
        .cache_write_tokens = try usageCount(input, "cache_write_tokens"),
        .reasoning_tokens = try usageCount(output, "reasoning_tokens"),
    };
}

pub fn parse(allocator: Allocator, body: Value) !Response {
    if (body != .object) return error.InvalidResponse;
    if (present(body, "error")) return error.ResponseFailed;
    const status = stringField(body, "status") orelse return error.InvalidResponse;
    try checkStatus(status);
    if (present(body, "incomplete_details")) return error.ResponseIncomplete;
    const object = stringField(body, "object") orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, object, "response")) return error.InvalidResponse;
    const model = stringField(body, "model") orelse return error.InvalidResponse;
    if (model.len == 0) return error.InvalidResponse;
    const output = field(body, "output") orelse return error.InvalidOutput;
    if (output != .array) return error.InvalidOutput;
    const usage = field(body, "usage") orelse Value.null;
    const counts = try parseUsage(usage);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var calls: std.ArrayList(Call) = .empty;
    defer calls.deinit(allocator);
    errdefer freeCalls(allocator, calls.items);
    var call_ids: std.StringHashMap(void) = .init(allocator);
    defer call_ids.deinit();
    for (output.array.items) |item| {
        const kind = stringField(item, "type") orelse return error.InvalidOutput;
        if (kind.len == 0) return error.InvalidOutput;
        if (field(item, "status")) |item_status| {
            if (item_status != .null) {
                if (item_status != .string) return error.InvalidResponseStatus;
                try checkStatus(item_status.string);
            }
        }
        if (std.mem.eql(u8, kind, "function_call")) {
            const call_id = stringField(item, "call_id") orelse return error.InvalidFunctionCall;
            const entry = try call_ids.getOrPut(call_id);
            if (entry.found_existing) return error.DuplicateCallId;
            try appendCall(allocator, &calls, item);
        } else if (std.mem.eql(u8, kind, "message")) {
            try appendText(allocator, &text, item);
        }
    }
    const output_json = try std.json.Stringify.valueAlloc(allocator, output, .{});
    errdefer allocator.free(output_json);
    const usage_json = try std.json.Stringify.valueAlloc(allocator, usage, .{});
    errdefer allocator.free(usage_json);
    const owned_model = try allocator.dupe(u8, model);
    errdefer allocator.free(owned_model);
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_calls = try calls.toOwnedSlice(allocator);
    return .{
        .output_json = output_json,
        .text = owned_text,
        .calls = owned_calls,
        .usage_json = usage_json,
        .usage = counts,
        .model = owned_model,
    };
}

/// The result borrows the envelope; projection allocations belong to the caller's arena.
pub fn interpret(a: Allocator, envelope: Value, transport_failed: bool) !Result {
    const j = @import("json.zig");
    var result: Result = .{ .status = .@"error", .output = j.array(a) };
    if (transport_failed) {
        const code = j.text(j.get(envelope, "code"));
        if (std.mem.eql(u8, code, "cancelled") or std.mem.eql(u8, code, "Canceled")) result.status = .cancelled;
        result.@"error" = envelope;
        return result;
    }
    const wake = j.get(envelope, "next_poll_ms");
    if (wake == .integer and wake.integer > 0) {
        result.status = .poll_pending;
        result.next_poll_ms = @intCast(wake.integer);
        return result;
    }
    const body = j.get(envelope, "body");
    result.raw = body;
    result.retryable = j.flag(j.get(envelope, "retryable"));
    result.retry_after_ms = @intCast(@min(j.number(j.get(envelope, "retry_after_ms")), 300000));
    const status = j.get(envelope, "status");
    if (body != .object or status != .integer or status.integer < 100 or status.integer > 599) {
        result.status = .invalid_response;
        result.@"error" = try diagnostic(a, "InvalidResponse", "Expected an HTTP status and a response object.");
        return result;
    }
    result.model = j.text(j.get(body, "model"));
    result.usage = parseUsage(j.get(body, "usage")) catch null;
    const provider_error = j.get(body, "error");
    if (isOverflow(body)) {
        result.status = .overflow;
        result.@"error" = provider_error;
        return result;
    }
    if (status.integer < 200 or status.integer >= 300 or provider_error != .null) {
        const terminal = j.text(j.get(body, "status"));
        result.status = if (std.mem.eql(u8, terminal, "cancelled")) .cancelled else if (std.mem.eql(u8, terminal, "failed")) .failed else .@"error";
        if (rejection(status.integer, body)) |reason| {
            result.retryable = false;
            result.@"error" = if (stringField(provider_error, "message")) |message| blk: {
                if (message.len != 0) break :blk provider_error;
                break :blk try diagnostic(a, @tagName(reason), reason.message());
            } else try diagnostic(a, @tagName(reason), reason.message());
            return result;
        }
        result.@"error" = if (provider_error != .null) provider_error else try diagnostic(a, "http_error", "The provider returned an unsuccessful HTTP status.");
        return result;
    }
    var response = parse(a, body) catch |err| {
        if (err == error.OutOfMemory) return err;
        result.status = switch (err) {
            error.ResponseIncomplete => .incomplete,
            error.ResponseCancelled => .cancelled,
            error.ResponseFailed => .failed,
            error.ResponseRefused => .refusal,
            else => .invalid_response,
        };
        result.@"error" = try diagnostic(a, @errorName(err), "The provider response could not complete this run.");
        if (j.get(body, "incomplete_details") != .null) try j.put(a, &result.@"error", "details", j.get(body, "incomplete_details"));
        if (err == error.ResponseIncomplete) try projectLength(a, body, &result);
        return result;
    };
    defer response.deinit(a);
    result.output = j.get(body, "output");
    result.text = try a.dupe(u8, response.text);
    result.usage = response.usage;
    result.thinking = try collectThinking(a, result.output);
    var calls: std.ArrayList(Invocation) = .empty;
    for (result.output.array.items) |item| {
        if (!std.mem.eql(u8, j.text(j.get(item, "type")), "function_call")) continue;
        try calls.append(a, .{
            .call_id = j.text(j.get(item, "call_id")),
            .name = j.text(j.get(item, "name")),
            .arguments = try j.parse(a, j.text(j.get(item, "arguments"))),
        });
    }
    result.calls = try calls.toOwnedSlice(a);
    result.status = .completed;
    return result;
}

fn projectLength(a: Allocator, body: Value, result: *Result) !void {
    const j = @import("json.zig");
    const details = j.get(body, "incomplete_details");
    if (!std.mem.eql(u8, j.text(j.get(body, "status")), "incomplete") or
        !std.mem.eql(u8, j.text(j.get(details, "reason")), "max_output_tokens") or
        !std.mem.eql(u8, j.text(j.get(body, "object")), "response") or result.model.len == 0) return;
    const raw_output = j.get(body, "output");
    if (raw_output != .array) return;

    var text: std.ArrayList(u8) = .empty;
    for (raw_output.array.items) |item| {
        if (item != .object) return;
        if (std.mem.eql(u8, j.text(j.get(item, "type")), "message")) {
            if (present(item, "status")) {
                const status = stringField(item, "status") orelse return;
                if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "incomplete")) return;
            }
            appendText(a, &text, item) catch |err| {
                if (err == error.OutOfMemory) return err;
                return;
            };
        }
    }
    result.retryable = false;
    result.stop_reason = .length;
    result.text = try text.toOwnedSlice(a);
    result.thinking = try collectThinking(a, raw_output);
    if (result.text.len != 0) try result.output.array.append(try j.project(a, .{
        .type = "message",
        .role = "assistant",
        .status = "completed",
        .content = .{.{ .type = "output_text", .text = result.text, .annotations = [_]Value{} }},
    }));
}

fn collectThinking(a: Allocator, output: Value) ![]const u8 {
    const j = @import("json.zig");
    var thinking: std.ArrayList(u8) = .empty;
    for (output.array.items) |item| {
        if (!std.mem.eql(u8, j.text(j.get(item, "type")), "reasoning")) continue;
        const summary = j.get(item, "summary");
        if (summary != .array) continue;
        for (summary.array.items) |part| {
            if (!std.mem.eql(u8, j.text(j.get(part, "type")), "summary_text")) continue;
            try thinking.appendSlice(a, j.text(j.get(part, "text")));
        }
    }
    return thinking.toOwnedSlice(a);
}
fn diagnostic(a: Allocator, code: []const u8, message: []const u8) !Value {
    const j = @import("json.zig");
    var value = j.object();
    try j.put(a, &value, "code", j.string(code));
    try j.put(a, &value, "message", j.string(message));
    return value;
}

pub fn isOverflow(body: Value) bool {
    const problem = field(body, "error") orelse return false;
    const code = stringField(problem, "code") orelse "";
    const message = stringField(problem, "message") orelse "";
    return std.mem.eql(u8, code, "context_length_exceeded") or std.mem.eql(u8, code, "context_window_exceeded") or
        std.mem.indexOf(u8, message, "maximum context length") != null or std.mem.indexOf(u8, message, "context window") != null;
}

pub fn retryableStatus(status: i64) bool {
    return status == 408 or status == 409 or status == 425 or status == 429 or
        (status >= 500 and status <= 599 and status != 501 and status != 505);
}

pub fn retryableFailureCode(code: []const u8) bool {
    const transient = [_][]const u8{
        "timeout",               "http_error",          "provider_error", "connection_error",        "network_error",       "rate_limit_exceeded",
        "server_error",          "overloaded",          "unavailable",    "temporarily_unavailable", "stream_disconnected", "websocket_disconnected",
        "internal_server_error", "service_unavailable",
    };
    for (transient) |candidate| if (std.mem.eql(u8, code, candidate)) return true;
    return false;
}

pub const Rejection = enum {
    authentication,
    credits,

    pub fn message(self: Rejection) []const u8 {
        return switch (self) {
            .authentication => "Provider rejected the credential. Check or renew it before retrying.",
            .credits => "Provider reports insufficient credits or a billing limit. Check the account balance before retrying.",
        };
    }
};

pub fn rejection(status: i64, body: Value) ?Rejection {
    const detail = field(body, "error") orelse Value.null;
    for ([_][]const u8{ "code", "type" }) |key| {
        const value = stringField(detail, key) orelse continue;
        for ([_][]const u8{ "insufficient_quota", "insufficient_credits", "insufficient_balance", "billing_hard_limit_reached", "credit_balance_too_low" }) |code| {
            if (std.ascii.eqlIgnoreCase(value, code)) return .credits;
        }
        for ([_][]const u8{ "invalid_api_key", "authentication_error", "invalid_token", "token_expired", "expired_token" }) |code| {
            if (std.ascii.eqlIgnoreCase(value, code)) return .authentication;
        }
    }
    return switch (status) {
        401 => .authentication,
        402 => .credits,
        else => null,
    };
}

pub fn retryableResponse(status: i64, body: Value) bool {
    return rejection(status, body) == null and (retryableStatus(status) or (status >= 200 and status < 300 and retryableBody(body)));
}

pub fn retryableBody(body: Value) bool {
    if (rejection(200, body) != null) return false;
    const status = stringField(body, "status") orelse "";
    if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "incomplete") or std.mem.eql(u8, status, "cancelled") or isOverflow(body)) return false;
    return retryableFailureCode(stringField(field(body, "error") orelse return false, "code") orelse "");
}

fn streamTerminal(a: Allocator, event: Value, dialect: Dialect) !?Value {
    const kind = stringField(event, "type") orelse return error.InvalidStreamEvent;
    const terminal = .{
        .{ "response.completed", "completed" },
        .{ "response.incomplete", "incomplete" },
        .{ "response.failed", "failed" },
        .{ "response.cancelled", "cancelled" },
    };
    inline for (terminal) |pair| {
        if (std.mem.eql(u8, kind, pair[0])) {
            const body = field(event, "response") orelse return error.InvalidStreamEvent;
            if (body != .object or !std.mem.eql(u8, stringField(body, "status") orelse "", pair[1])) return error.InvalidStreamEvent;
            return body;
        }
    }
    if (dialect == .codex and std.mem.eql(u8, kind, "response.done")) {
        const body = field(event, "response") orelse return error.InvalidStreamEvent;
        const status = stringField(body, "status") orelse return error.InvalidStreamEvent;
        inline for (terminal) |pair| if (std.mem.eql(u8, status, pair[1])) return body;
        return error.InvalidStreamEvent;
    }
    if (std.mem.eql(u8, kind, "error")) {
        const j = @import("json.zig");
        var body = j.object();
        try j.put(a, &body, "status", j.string("failed"));
        try j.put(a, &body, "error", field(event, "error") orelse event);
        return body;
    }
    return null;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    preview: ?Preview,
    request_id: []const u8,
    dialect: Dialect = .responses,
    start_on_event: bool = false,
    size_context: ?services.Context = null,
    previous_response_missing: bool = false,
    result: ?[]u8 = null,
    /// The function calls of this response, in the order the provider added
    /// them. The decoder owns the copies, because an argument delta may arrive
    /// long after the event that named the call.
    calls: std.ArrayList(Decoder.Call) = .empty,
    reasoning_slots: std.AutoHashMapUnmanaged(u32, void) = .empty,

    const expected_calls = 32;
    const Call = struct {
        /// The provider's output index, when the stream event carried one.
        output_index: ?u32 = null,
        call_id: []u8,
        name: []u8,
        ended: bool = false,
    };

    pub fn deinit(self: *Decoder) void {
        if (self.result) |result| self.allocator.free(result);
        for (self.calls.items) |call| {
            self.allocator.free(call.call_id);
            self.allocator.free(call.name);
        }
        self.calls.deinit(self.allocator);
        self.reasoning_slots.deinit(self.allocator);
    }

    pub fn finish(self: *Decoder) ![]const u8 {
        return self.result orelse error.MissingCompletedResponse;
    }

    pub fn event(self: *Decoder, data: []const u8) !void {
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.result == null) return error.MissingCompletedResponse;
            return;
        }
        var parsed = try json_text.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidStreamEvent;
        const object = parsed.value.object;
        const kind = object.get("type") orelse return error.InvalidStreamEvent;
        if (kind != .string) return error.InvalidStreamEvent;
        if (self.result != null) return error.EventAfterCompletedResponse;
        if (self.start_on_event and !std.mem.eql(u8, kind.string, "error") and !std.mem.eql(u8, kind.string, "response.failed") and
            !(self.dialect == .codex and std.mem.eql(u8, kind.string, "codex.rate_limits")))
        {
            self.start_on_event = false;
            try self.notify(.started);
        }
        if (std.mem.eql(u8, kind.string, "response.output_text.delta")) {
            const delta = object.get("delta") orelse return error.InvalidStreamEvent;
            if (delta != .string) return error.InvalidStreamEvent;
            try self.notify(.{ .delta = delta.string });
        } else if (std.mem.eql(u8, kind.string, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, kind.string, "response.reasoning_text.delta"))
        {
            const slot = index(object, "output_index") orelse return;
            if (!self.reasoning_slots.contains(slot)) return;
            const delta = object.get("delta") orelse return error.InvalidStreamEvent;
            if (delta != .string) return error.InvalidStreamEvent;
            try self.notify(.{ .reasoning_delta = delta.string });
        } else if (std.mem.eql(u8, kind.string, "response.reasoning_summary_part.done")) {
            const slot = index(object, "output_index") orelse return;
            if (self.reasoning_slots.contains(slot)) try self.notify(.{ .reasoning_delta = "\n\n" });
        } else if (std.mem.eql(u8, kind.string, "response.output_item.added")) {
            const item = object.get("item") orelse return error.InvalidStreamEvent;
            if (item != .object) return error.InvalidStreamEvent;
            if (self.preview != null and fieldEqual(item, "type", "reasoning")) {
                if (index(object, "output_index")) |slot| try self.reasoning_slots.put(self.allocator, slot, {});
                return;
            }
            if (!fieldEqual(item, "type", "function_call")) return;
            const call_id = fieldText(item, "call_id") orelse return error.InvalidStreamEvent;
            const name = fieldText(item, "name") orelse return error.InvalidStreamEvent;
            try self.addCall(index(object, "output_index"), call_id, name, fieldText(item, "arguments") orelse "");
        } else if (std.mem.eql(u8, kind.string, "response.function_call_arguments.delta")) {
            const delta = object.get("delta") orelse return error.InvalidStreamEvent;
            if (delta != .string) return error.InvalidStreamEvent;
            const call = self.openCall(index(object, "output_index")) orelse return;
            try self.appendArguments(call, delta.string);
        } else if (std.mem.eql(u8, kind.string, "response.function_call_arguments.done")) {
            const arguments = object.get("arguments") orelse return error.InvalidStreamEvent;
            if (arguments != .string) return error.InvalidStreamEvent;
            const call = self.openCall(index(object, "output_index")) orelse return;
            try self.endCall(call, arguments.string);
        } else if (std.mem.eql(u8, kind.string, "response.output_item.done")) {
            const item = object.get("item") orelse return error.InvalidStreamEvent;
            if (item != .object) return error.InvalidStreamEvent;
            if (fieldEqual(item, "type", "reasoning")) {
                if (index(object, "output_index")) |slot| _ = self.reasoning_slots.remove(slot);
                return;
            }
            if (!fieldEqual(item, "type", "function_call")) return;
            const call = self.openCall(index(object, "output_index")) orelse return;
            try self.endCall(call, fieldText(item, "arguments") orelse "");
        } else if (try streamTerminal(parsed.arena.allocator(), parsed.value, self.dialect)) |response| {
            if (self.dialect == .codex) {
                const code = if (std.mem.eql(u8, kind.string, "error"))
                    fieldText(parsed.value, "code") orelse fieldText(field(parsed.value, "error") orelse .null, "code")
                else
                    fieldText(field(response, "error") orelse .null, "code");
                self.previous_response_missing = if (code) |value| std.mem.eql(u8, value, "previous_response_not_found") else false;
            }
            // A provider may report the final text only in the completed
            // response. Take it from there, then close whatever is left open so
            // a consumer never waits for arguments that will not arrive.
            for (jItems(response.object.get("output"))) |item| {
                if (!fieldEqual(item, "type", "function_call")) continue;
                const call_id = fieldText(item, "call_id") orelse continue;
                for (self.calls.items) |*call| {
                    if (call.ended or !std.mem.eql(u8, call.call_id, call_id)) continue;
                    try self.endCall(call, fieldText(item, "arguments") orelse "");
                }
            }
            for (self.calls.items) |*call| if (!call.ended) try self.endCall(call, "");
            self.result = try std.json.Stringify.valueAlloc(self.allocator, response, .{});
        }
    }

    fn notify(self: *Decoder, update: Preview.Update) !void {
        const preview = self.preview orelse return;
        try preview.notify(preview.context, self.request_id, update);
    }

    fn addCall(self: *Decoder, output_index: ?u32, call_id: []const u8, name: []const u8, initial: []const u8) !void {
        if (self.calls.items.len == expected_calls) {
            if (self.size_context) |context| {
                context.warnSize("model.request", "streamed function calls", expected_calls + 1, expected_calls);
            } else {
                services.logSizeWarning(.{ .operation = "model.request", .measurement = "streamed function calls", .actual = expected_calls + 1, .threshold = expected_calls, .request_id = self.request_id, .principal = 0 });
            }
        }
        const owned_id = try self.allocator.dupe(u8, call_id);
        errdefer self.allocator.free(owned_id);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.calls.append(self.allocator, .{ .output_index = output_index, .call_id = owned_id, .name = owned_name });
        const call = &self.calls.items[self.calls.items.len - 1];
        try self.notify(.{ .tool_start = .{ .call_id = call.call_id, .name = call.name } });
        try self.appendArguments(call, initial);
    }

    fn openCall(self: *Decoder, output_index: ?u32) ?*Decoder.Call {
        if (output_index) |wanted| {
            for (self.calls.items) |*call| {
                if (call.ended) continue;
                if (call.output_index) |candidate| {
                    if (candidate == wanted) return call;
                }
            }
            return null;
        }
        var single: ?*Decoder.Call = null;
        for (self.calls.items) |*call| {
            if (call.ended) continue;
            if (single != null) return null;
            single = call;
        }
        return single;
    }

    fn appendArguments(self: *Decoder, call: *Decoder.Call, delta: []const u8) !void {
        if (delta.len == 0) return;
        try self.notify(.{ .tool_delta = .{ .call_id = call.call_id, .delta = delta } });
    }

    fn endCall(self: *Decoder, call: *Decoder.Call, arguments: []const u8) !void {
        if (call.ended) return;
        call.ended = true;
        try self.notify(.{ .tool_end = .{ .call_id = call.call_id, .arguments = arguments } });
    }

    fn jItems(value: ?std.json.Value) []const std.json.Value {
        const items = value orelse return &.{};
        return if (items == .array) items.array.items else &.{};
    }

    fn index(object: std.json.ObjectMap, name: []const u8) ?u32 {
        const value = object.get(name) orelse return null;
        return switch (value) {
            .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else null,
            else => null,
        };
    }

    fn fieldText(item: std.json.Value, name: []const u8) ?[]const u8 {
        if (item != .object) return null;
        const value = item.object.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }

    fn fieldEqual(item: std.json.Value, name: []const u8, expected: []const u8) bool {
        const text = fieldText(item, name) orelse return false;
        return std.mem.eql(u8, text, expected);
    }
};

pub fn createEvent(a: Allocator, body: Value, dialect: Dialect) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return std.json.Stringify.valueAlloc(a, try createEventValue(scratch.allocator(), body, dialect), .{});
}

/// Allocates the event in the caller's arena and borrows request children.
pub fn createEventValue(a: Allocator, body: Value, dialect: Dialect) !Value {
    return wireValue(a, body, dialect, true);
}

/// The SSE request shares the Codex projection and has no WebSocket event tag.
pub fn codexHttpValue(a: Allocator, body: Value) !Value {
    return wireValue(a, body, .codex, false);
}

fn wireValue(a: Allocator, body: Value, dialect: Dialect, websocket: bool) !Value {
    const codex = dialect == .codex;
    if (body != .object) return error.InvalidRequest;
    var object: std.json.ObjectMap = .empty;
    var iterator = body.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "stream") or
            std.mem.eql(u8, key, "background")) continue;
        if (codex and std.mem.eql(u8, key, "max_output_tokens")) continue;
        if (codex and std.mem.eql(u8, key, "input")) {
            // Response items are durable history, not request DTOs. Codex
            // rejects response-only status fields when that history is replayed.
            const input = entry.value_ptr.*;
            if (input != .array) return error.InvalidRequest;
            var projected = std.array_list.Managed(Value).init(a);
            for (input.array.items) |item| {
                try projected.append(try codexInputItem(a, item));
            }
            try object.put(a, key, .{ .array = projected });
        } else try object.put(a, key, entry.value_ptr.*);
    }
    if (websocket) try object.put(a, "type", .{ .string = "response.create" });
    try object.put(a, "store", .{ .bool = false });
    if (codex) {
        try object.put(a, "stream", .{ .bool = true });
        var include = std.array_list.Managed(Value).init(a);
        if (body.object.get("include")) |value| {
            if (value != .array) return error.InvalidRequest;
            try include.appendSlice(value.array.items);
        }
        var encrypted = false;
        for (include.items) |value| {
            if (value == .string and std.mem.eql(u8, value.string, "reasoning.encrypted_content")) encrypted = true;
        }
        if (!encrypted) try include.append(.{ .string = "reasoning.encrypted_content" });
        try object.put(a, "include", .{ .array = include });
    }
    return .{ .object = object };
}

pub fn codexInputItem(a: Allocator, item: Value) !Value {
    if (item != .object) return error.InvalidRequest;
    var fields: std.json.ObjectMap = .empty;
    var entries = item.object.iterator();
    while (entries.next()) |field_entry| {
        if (std.mem.eql(u8, field_entry.key_ptr.*, "status")) continue;
        try fields.put(a, field_entry.key_ptr.*, field_entry.value_ptr.*);
    }
    return .{ .object = fields };
}

pub const Continuation = @import("provider_continuation.zig").Capsule;
pub const captureContinuation = @import("provider_continuation.zig").capture;
