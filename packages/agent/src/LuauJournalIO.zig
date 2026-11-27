const std = @import("std");
const W = @import("Session.zig");
const j = @import("json.zig");
const persistence = @import("LuauJournal.zig");
const p = @import("session_protocol");
const F = p.frames;
const Value = j.Value;
const Allocator = std.mem.Allocator;

pub const Intent = struct { effect: ?u64 = null, model: ?u64 = null };

fn toolName(value: Value) []const u8 {
    const name = j.get(value, "name");
    return if (name == .string) name.string else j.text(j.get(value, "type"));
}

fn commit(self: *W, actions: []const F.Action) !void {
    if (actions.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    _ = try self.journal.commit(try std.fmt.allocPrint(arena.allocator(), "io-{d}", .{self.journal.sequence + 1}), .{ .kind = .host, .id = "luau" }, actions);
    self.sequence = self.journal.sequence;
}

pub fn progressModel(self: *W, ref: u64, progress: @import("services").ModelProgress) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const issued = (try self.journal.frame(a, ref)).action.@"control.model.request";
    try commit(self, &.{.{ .@"control.model.progress" = .{
        .request_id = issued.request_id,
        .response_id = progress.response_id,
        .cursor = progress.cursor,
        .next_poll_ms = progress.next_poll_ms,
        .poll_failures = progress.poll_failures,
        .reattach = if (progress.reattach == .stream) .stream else null,
        .deferred = if (progress.deferred) |deferred| .{ .adapter = deferred.adapter, .handle = deferred.handle } else null,
    } }});
}

fn prepareModel(self: *W, a: Allocator, packet: *Value, http: bool) !F.Action {
    const body = if (http) j.ptr(packet, "body") else j.ptr(j.ptr(packet, "arguments"), "body");
    if (body.* != .object) return error.InvalidModelRequest;
    var input = j.get(body.*, "input");
    if (input == .object and input.object.count() == 0) {
        input = j.array(a);
        try j.put(a, body, "input", input);
    }
    if (input == .string) {
        const text = input.string;
        input = j.array(a);
        try input.array.append(try j.project(a, .{ .role = "user", .content = text }));
        try j.put(a, body, "input", input);
    }
    if (input != .array) return error.InvalidModelInput;
    const desired_tools = if (j.get(body.*, "tools") == .array) j.get(body.*, "tools") else j.array(a);
    var order = j.array(a);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (desired_tools.array.items) |tool| {
        const name = toolName(tool);
        if (name.len == 0 or (try names.getOrPut(a, name)).found_existing) return error.InvalidProviderTool;
        try order.array.append(j.string(name));
    }
    var settings = j.object();
    for (body.object.keys(), body.object.values()) |key, value| {
        if (std.mem.eql(u8, key, "input") or std.mem.eql(u8, key, "tools") or std.mem.eql(u8, key, "model")) continue;
        try j.put(a, &settings, key, value);
    }
    if (j.get(settings, "instructions") == .null) try j.put(a, &settings, "instructions", j.string(""));
    try j.put(a, &settings, "journal_tool_order", order);
    const model_name = j.text(j.get(body.*, "model"));
    const binding = j.get(packet.*, "application_model");
    const model = if (binding == .object) j.get(binding, "model") else self.options.value;
    const route = if (http) j.text(j.get(packet.*, "url")) else j.text(j.get(model, "base_url"));
    const credential = j.text(j.get(model, "credential"));
    const selection: @FieldType(F.Action, "control.set_model") = .{
        .provider = "configured",
        .model = model_name,
        .route = route,
        .credential_ref = if (credential.len == 0) null else credential,
        .adapter = .{ .id = "agent.luau.responses", .version = "1" },
        .kwargs = settings,
        .selection = if (binding == .object) j.get(binding, "selection") else null,
    };
    var controls: std.ArrayList(F.Action) = .empty;
    const old_model = if (self.journal.state.model_frame) |ref| (try self.journal.frame(a, ref)).action.@"control.set_model" else null;
    if (old_model == null or !try j.equal(a, try p.Encoding.value(a, old_model.?), try p.Encoding.value(a, selection))) try controls.append(a, .{ .@"control.set_model" = selection });
    for (self.journal.state.tools.keys(), self.journal.state.tools.values()) |name, ref| {
        var keep = false;
        for (desired_tools.array.items) |tool| if (std.mem.eql(u8, name, toolName(tool)) and try j.equal(a, tool, (try self.journal.frame(a, ref)).action.@"control.provider_tool.register".definition)) {
            keep = true;
            break;
        };
        if (!keep) try controls.append(a, .{ .@"control.provider_tool.deregister" = .{ .name = name, .registration = ref } });
    }
    for (desired_tools.array.items) |tool| {
        const name = toolName(tool);
        const old = self.journal.state.tools.get(name);
        if (old != null and try j.equal(a, tool, (try self.journal.frame(a, old.?)).action.@"control.provider_tool.register".definition)) continue;
        const local = std.mem.eql(u8, j.text(j.get(tool, "type")), "function");
        try controls.append(a, .{ .@"control.provider_tool.register" = .{ .name = name, .definition = tool, .handler = if (local) .{ .contract = .{ .id = "agent.luau.provider_tool", .version = "1" }, .value = try j.project(a, .{ .name = name }) } else null } });
    }
    try commit(self, controls.items);
    const application = @import("LuauContextJournal.zig");
    const scope = application.scope(self.state.value);
    var context = scope;
    const snapshot: p.State.Snapshot = .{ .state = &self.journal.state, .source = self.journal.source(), .at = self.journal.sequence, .context = context, .extensions = &self.journal.state.extensions };
    const main = try persistence.render(a, snapshot, j.object());
    if (!try j.equal(a, main.messages, input)) {
        context = try std.fmt.allocPrint(a, "request-input/{d}", .{self.journal.sequence + 1});
        var documents: std.ArrayList(F.Action) = .empty;
        try documents.append(a, .{ .@"control.context.create" = .{ .id = context, .base = null } });
        var after: ?[]const u8 = null;
        for (input.array.items, 0..) |item, index| {
            const kind = j.text(j.get(item, "type"));
            const role = std.meta.stringToEnum(F.Role, j.text(j.get(item, "role"))) orelse .assistant;
            const raw_tool = role == .tool or std.mem.eql(u8, kind, "function_call") or std.mem.eql(u8, kind, "function_call_output");
            if (raw_tool and (http or !self.context_codec.request_input_projection)) return error.ProjectionMismatch;
            const id = try std.fmt.allocPrint(a, "{s}/{d}", .{ context, index });
            const content = try a.alloc(Value, 1);
            content[0] = try j.project(a, .{ .type = "json", .value = .{ .format = "agent.luau.input.v1", .json = try j.encode(a, item) } });
            try documents.append(a, .{ .@"document.message.append" = .{ .message = .{ .id = id, .role = if (raw_tool) .assistant else role, .content = content }, .placement = .{ .context = context, .after = after } } });
            after = id;
        }
        try commit(self, documents.items);
    }
    const prefix = self.journal.sequence;
    const projected = try self.journal.state.project(a, self.journal.source(), prefix, context, persistence.renderer.version, j.object(), self.journal.options.contracts, self.journal.options.renderers);
    if (!try j.equal(a, projected.messages, input) or !try j.equal(a, projected.tools, desired_tools)) return error.ProjectionMismatch;
    const instructions = try p.Canonical.hash(a, projected.instructions);
    const messages = try p.Canonical.hash(a, projected.messages);
    const tools = try p.Canonical.hash(a, projected.tools);
    return .{ .@"control.model.request" = .{
        .request_id = try std.fmt.allocPrint(a, "model/{d}", .{prefix + 1}),
        .input_at = prefix,
        .context = context,
        .conversation = if (std.mem.eql(u8, scope, application.main)) null else scope,
        .model_frame = self.journal.state.model_frame.?,
        .renderer = persistence.renderer.version,
        .kwargs = j.object(),
        .instructions_sha256 = try a.dupe(u8, &instructions),
        .messages_sha256 = try a.dupe(u8, &messages),
        .tools_sha256 = try a.dupe(u8, &tools),
    } };
}

fn recoverModelArguments(self: *W, a: Allocator, request: *const F.Frame, model: @FieldType(F.Action, "control.set_model"), route: @import("LuauContextJournal.zig").Codec.ModelRoute, packet: *Value) !void {
    if (request.tx.index + 1 >= request.tx.count) return error.MissingModelEffect;
    const effect = (try self.journal.frame(a, request.seq + 1)).action;
    if (effect != .@"control.effect.intent" or !std.mem.eql(u8, effect.@"control.effect.intent".endpoint.name, "model.request")) return error.MissingModelEffect;
    const original = try j.parse(a, j.text(j.get(effect.@"control.effect.intent".arguments, "json")));
    const body = j.get(original, "body");
    const max_output = std.math.cast(u32, j.number(j.get(model.kwargs, "max_output_tokens"))) orelse return error.InvalidModelRequest;
    if (max_output == 0 or !std.mem.eql(u8, j.text(j.get(body, "model")), model.model) or
        j.number(j.get(body, "max_output_tokens")) != max_output) return error.InvalidModelRequest;
    const effort = j.get(j.get(model.kwargs, "reasoning"), "effort");
    const binding: @import("config.zig").ApplicationModel = .{
        .model = .{
            .model = model.model,
            .base_url = model.route,
            .credential = route.credential,
            .max_output_tokens = max_output,
            .reasoning_effort = if (effort == .string) effort.string else null,
        },
        .selection = route.selection,
    };
    try j.put(a, j.ptr(packet, "arguments"), "body", body);
    try j.put(a, packet, "application_model", try j.project(a, binding));
}

pub fn prepare(self: *W, kind: @FieldType(W.Operation, "kind"), document: *j.Document) !Intent {
    const packet = &document.value;
    const a = document.allocator();
    var actions: std.ArrayList(F.Action) = .empty;
    const is_model = kind == .http or j.flag(j.get(packet.*, "model_binding"));
    var request_id: ?[]const u8 = null;
    if (is_model) {
        if (kind == .effect and self.context_codec.defer_model_poll) {
            try j.put(a, packet, "defer_model_poll", .{ .bool = true });
        }
        if (kind == .effect and j.flag(j.get(j.get(packet.*, "arguments"), "resume"))) {
            const marker = j.get(j.get(self.state.value, "ctx"), "__interrupted_application");
            const ref = j.number(j.get(marker, "model_resume"));
            if (ref == 0) return error.MissingModelContinuation;
            const issued = try self.journal.frame(a, ref);
            const model = issued.action.@"control.model.request";
            const application = @import("LuauContextJournal.zig");
            if (!std.mem.eql(u8, model.conversation orelse application.main, application.scope(self.state.value))) return error.MissingModelContinuation;
            const request = self.journal.state.requests.get(model.request_id) orelse return error.UnknownRequest;
            if (request.finish != null or request.cancelled) return error.TerminalRequest;
            const saved = (try self.journal.frame(a, request.progress orelse return error.MissingModelContinuation)).action.@"control.model.progress";
            const selection = (try self.journal.frame(a, model.model_frame)).action.@"control.set_model";
            const route = try persistence.modelRoute(&self.journal, self.context_codec, a, model, selection);
            _ = j.ptr(packet, "arguments").object.orderedRemove("resume");
            if (route) |resolved| {
                try recoverModelArguments(self, a, issued, selection, resolved, packet);
            } else {
                _ = packet.object.orderedRemove("application_model");
            }
            try j.put(a, packet, "provider_resume", try j.project(a, .{
                .route = selection.route,
                .credential = if (route) |resolved| resolved.credential else selection.credential_ref orelse "",
                .progress = .{
                    .response_id = saved.response_id,
                    .cursor = saved.cursor,
                    .next_poll_ms = saved.next_poll_ms,
                    .poll_failures = saved.poll_failures,
                    .reattach = saved.reattach,
                    .deferred = saved.deferred,
                },
            }));
            request_id = model.request_id;
        } else {
            const model = try prepareModel(self, a, packet, kind == .http);
            request_id = model.@"control.model.request".request_id;
            try actions.append(a, model);
        }
    }
    var effect_id: ?[]const u8 = null;
    if (kind == .effect and self.context_codec.defer_model_poll) if (request_id) |id| {
        const identity = j.sourceHash(try std.fmt.allocPrint(a, "model/{s}/{s}", .{ self.session_id, id }));
        try j.put(a, packet, "model_attempt_key", j.string(try a.dupe(u8, &identity)));
    };
    if (kind == .effect) {
        const endpoint = j.text(j.get(packet.*, "endpoint"));
        if (!self.journal.state.bindings.contains(endpoint)) try commit(self, &.{.{ .@"capability.bind" = .{ .name = endpoint, .service = .{ .id = "agent.luau.rpc", .version = "1" }, .config = j.object() } }});
        effect_id = try std.fmt.allocPrint(a, "effect/{d}/{d}", .{ self.journal.sequence + 1, self.next_operation });
        const key = j.sourceHash(try std.fmt.allocPrint(a, "{s}/{s}", .{ self.session_id, effect_id.? }));
        const owned_key = try a.dupe(u8, &key);
        try j.put(a, packet, "idempotency_key", j.string(owned_key));
        try actions.append(a, .{ .@"control.effect.intent" = .{ .effect_id = effect_id.?, .endpoint = .{ .name = endpoint, .binding = self.journal.state.bindings.get(endpoint).? }, .arguments = try j.project(a, .{ .format = "agent.luau.json", .json = try j.encode(a, j.get(packet.*, "arguments")) }), .source_message = null, .key = owned_key, .recovery = .never } });
    }
    var next = try self.mutate();
    errdefer next.deinit();
    const na = next.allocator();
    const active = j.ptr(&next.value, "active");
    if (effect_id) |id| try j.put(na, active, "core_effect_id", j.string(try na.dupe(u8, id)));
    try persistence.boundary(&self.journal, self.context_codec, self.state.value, &next, .null, actions.items, false);
    if (request_id) |id| {
        const ref = self.journal.state.requests.get(id).?.intent;
        try j.put(na, active, "core_model_request", j.integer(@intCast(ref)));
        try persistence.boundary(&self.journal, self.context_codec, self.state.value, &next, .null, &.{}, false);
    }
    self.state.deinit();
    self.state = next;
    self.sequence = self.journal.sequence;
    return .{
        .effect = if (effect_id) |id| self.journal.state.effects.get(id).?.intent else null,
        .model = if (request_id) |id| self.journal.state.requests.get(id).?.intent else null,
    };
}

pub fn receipt(self: *W, operation: W.Operation, kind: u32, value: Value) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var actions: std.ArrayList(F.Action) = .empty;
    if (operation.semantic_effect) |ref| {
        const intent_frame = (try self.journal.frame(a, ref)).action.@"control.effect.intent";
        const effect = self.journal.state.effects.get(intent_frame.effect_id).?;
        if (effect.finish == null) {
            const status: F.EffectStatus = if (kind == W.api.CPI_AGENT_IO_CANCELLED) .cancelled else if (kind == W.api.CPI_AGENT_IO_ERROR) .failed else .completed;
            try actions.append(a, .{ .@"control.effect.result" = .{ .effect_id = intent_frame.effect_id, .status = status, .result = try j.project(a, .{ .format = "agent.luau.json", .json = try j.encode(a, value) }) } });
        }
    }
    if (operation.semantic_model) |ref| {
        const id = (try self.journal.frame(a, ref)).action.@"control.model.request".request_id;
        const pending = self.journal.state.requests.get(id).?.finish == null;
        const summary = j.number(j.get(j.get(self.state.value, "active"), "kind")) == 9;
        if (pending and (operation.obsolete or (operation.kind == .http and (summary or kind != W.api.CPI_AGENT_IO_DONE)))) {
            if (!operation.obsolete and kind == W.api.CPI_AGENT_IO_DONE) {
                const content = try a.alloc(Value, 1);
                content[0] = try j.project(a, .{ .type = "json", .value = .{ .format = "agent.luau.response.v1", .json = try j.encode(a, value) } });
                try actions.append(a, .{ .@"document.message.append" = .{ .message = .{ .id = try std.fmt.allocPrint(a, "output/{s}", .{id}), .role = .assistant, .content = content }, .placement = null, .request = id } });
            }
            try actions.append(a, .{ .@"control.model.finish" = .{ .request_id = id, .status = if (kind == W.api.CPI_AGENT_IO_CANCELLED) .cancelled else if (kind == W.api.CPI_AGENT_IO_ERROR or operation.obsolete) .failed else .completed, .usage = .null, .diagnostic = .null } });
        }
    }
    try commit(self, actions.items);
}

pub fn cancel(self: *W, operation: W.Operation) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var actions: [3]F.Action = undefined;
    var count: usize = 0;
    for ([_]?u64{ operation.semantic_effect, operation.semantic_model }) |maybe| if (maybe) |ref| {
        const frame = try self.journal.frame(a, ref);
        const pending = switch (frame.action) {
            .@"control.effect.intent" => |v| self.journal.state.effects.get(v.effect_id).?.finish == null,
            .@"control.model.request" => |v| self.journal.state.requests.get(v.request_id).?.finish == null,
            else => false,
        };
        if (pending) {
            actions[count] = .{ .@"control.cancel" = .{ .target = ref, .reason = "execution cancelled" } };
            count += 1;
            if (frame.action == .@"control.model.request") {
                const model = frame.action.@"control.model.request";
                if (try persistence.providerCancellation(&self.journal, a, self.context_codec, model)) |action| {
                    actions[count] = action;
                    count += 1;
                }
            }
        }
    };
    try commit(self, actions[0..count]);
}
