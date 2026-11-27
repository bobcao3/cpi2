const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const api = W.api;
const work = @import("work.zig");
const RunState = @import("RunState.zig");
const application_context = @import("LuauContextJournal.zig");
const persistence = @import("LuauJournal.zig");
const Value = j.Value;

pub fn commandPtr(document: *j.Document, id: []const u8) *Value {
    for (j.ptr(&document.value, "commands").array.items) |*item| {
        if (std.mem.eql(u8, j.text(j.get(item.*, "id")), id)) return item;
    }
    unreachable;
}

pub fn outcome(a: std.mem.Allocator, status: []const u8, result: Value, err: Value) !Value {
    var value = j.object();
    try j.put(a, &value, "status", j.string(status));
    try j.put(a, &value, "result", result);
    try j.put(a, &value, "error", err);
    return value;
}

pub fn diagnostic(a: std.mem.Allocator, code: []const u8, message: []const u8) !Value {
    var value = j.object();
    try j.put(a, &value, "code", j.string(try a.dupe(u8, code)));
    try j.put(a, &value, "message", j.string(try a.dupe(u8, message)));
    return value;
}

pub fn finish(document: *j.Document, id: []const u8, status: []const u8, result: Value, err: Value) !Value {
    var value = try outcome(document.allocator(), status, result, err);
    try j.put(document.allocator(), &value, "capabilities_revision", j.get(document.value, "capabilities_revision"));
    const command = commandPtr(document, id);
    try j.put(document.allocator(), command, "status", j.string(status));
    try j.put(document.allocator(), command, "outcome", value);
    return value;
}

pub fn admitOne(self: *W) !bool {
    if (self.admissions.items.len == 0) return false;
    const item = self.admissions.orderedRemove(0);
    defer self.gpa.free(item.id);
    defer if (item.registered) |tool| tool.release();
    var payload = item.payload;
    defer payload.deinit();
    if (self.command(item.id)) |old| {
        if (j.number(j.get(old, "kind")) != item.kind or !(try j.equal(self.gpa, j.get(old, "payload"), payload.value))) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const failure = try diagnostic(arena.allocator(), "request_conflict", "The recovered request ID names different content.");
            const result = try outcome(arena.allocator(), "failed", .null, failure);
            try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, item.id, "", result);
            return true;
        }
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_COMMITTED, 0, self.sequence, item.id, "", .null);
        const state = j.text(j.get(old, "status"));
        if (!std.mem.eql(u8, state, "queued") and !std.mem.eql(u8, state, "running")) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, item.id, "", try self.expandOutcome(arena.allocator(), j.get(old, "outcome")));
        }
        return true;
    }
    if (try self.recordedCommand(self.gpa, item.id)) |saved| {
        var receipt = saved;
        defer receipt.deinit();
        const old = receipt.value;
        if (j.number(j.get(old, "kind")) != item.kind or !(try j.equal(self.gpa, j.get(old, "payload"), payload.value))) return error.RequestConflict;
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_COMMITTED, 0, self.sequence, item.id, "", .null);
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, item.id, "", j.get(old, "outcome"));
        return true;
    }
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const commands = j.ptr(&next.value, "commands");
    var entry = j.object();
    try j.put(a, &entry, "id", j.string(try a.dupe(u8, item.id)));
    try j.put(a, &entry, "kind", j.integer(item.kind));
    try j.put(a, &entry, "payload", try j.copy(a, payload.value));
    try j.put(a, &entry, "status", j.string("queued"));
    if (item.kind == 12 and j.flag(j.get(payload.value, "boundary"))) {
        const target = j.text(j.get(payload.value, "replace"));
        const scope = deliveryScope(payload.value);
        var live = std.mem.eql(u8, target, j.text(j.get(j.get(next.value, "active"), "id"))) and
            std.mem.eql(u8, scope, application_context.scope(next.value));
        for (commands.array.items) |command| {
            if (std.mem.eql(u8, target, j.text(j.get(command, "id"))) and std.mem.eql(u8, j.text(j.get(command, "status")), "queued") and
                std.mem.eql(u8, scope, deliveryScope(j.get(command, "payload")))) live = true;
        }
        try j.put(a, &entry, "boundary_admitted", .{ .bool = live });
    }
    try commands.array.append(entry);
    const pending_id = if (item.registered != null) try self.gpa.dupe(u8, item.id) else null;
    errdefer if (pending_id) |owned| self.gpa.free(owned);
    if (item.registered != null) try self.pending_capabilities.ensureUnusedCapacity(self.gpa, 1);
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_COMMITTED, .request = item.id }});
    if (item.registered) |tool| self.pending_capabilities.appendAssumeCapacity(.{ .id = pending_id.?, .capability = tool.retain() });
    return true;
}

pub fn control(self: *W) !bool {
    const commands = j.get(self.state.value, "commands");
    for (commands.array.items) |entry| {
        if (self.bootstrap and !std.mem.eql(u8, self.bootstrap_request orelse "", j.text(j.get(entry, "id")))) continue;
        const kind = j.number(j.get(entry, "kind"));
        if ((kind >= 8 and kind < 12) or kind == 1 or kind == 4 or !std.mem.eql(u8, j.text(j.get(entry, "status")), "queued")) continue;
        if (kind == 12 and (j.get(j.get(entry, "payload"), "replace") == .null or j.flag(j.get(entry, "replacement_checked")))) continue;
        const id = j.text(j.get(entry, "id"));
        var next = try self.mutate();
        errdefer next.deinit();
        const a = next.allocator();
        const payload = j.get(commandPtr(&next, id).*, "payload");
        var result: Value = .null;
        var failure: Value = .null;
        var changed = false;
        var candidate: ?*@import("vm").RegisteredTool = null;
        defer if (candidate) |tool| tool.release();
        switch (kind) {
            12, 13 => {
                const target = j.text(j.get(payload, "replace"));
                const active = j.get(next.value, "active");
                const scope = deliveryScope(payload);
                var queued = false;
                for (j.get(next.value, "commands").array.items) |queued_command| {
                    if (std.mem.eql(u8, target, j.text(j.get(queued_command, "id"))) and
                        std.mem.eql(u8, j.text(j.get(queued_command, "status")), "queued") and
                        (kind == 13 or std.mem.eql(u8, scope, deliveryScope(j.get(queued_command, "payload"))))) queued = true;
                }
                const running = active != .null and std.mem.eql(u8, target, j.text(j.get(active, "id"))) and
                    (kind == 13 or std.mem.eql(u8, scope, application_context.scope(next.value)));
                if (kind == 12 and j.flag(j.get(payload, "boundary"))) {
                    const admitted = j.flag(j.get(commandPtr(&next, id).*, "boundary_admitted"));
                    if ((running and !j.flag(j.get(active, "safe_boundary"))) or queued) {
                        if (!admitted) {
                            try j.put(a, commandPtr(&next, id), "boundary_admitted", .{ .bool = true });
                            try self.stage(next, &.{});
                            return true;
                        }
                        next.deinit();
                        continue;
                    }
                    if (!running and !queued and admitted) {
                        try j.put(a, commandPtr(&next, id), "replacement_checked", .{ .bool = true });
                        try self.stage(next, &.{});
                        return true;
                    }
                }
                if (!running and !queued) {
                    failure = try diagnostic(a, "stale_invocation", "Replacement target is no longer active.");
                } else {
                    if (running) {
                        try work.captureInterruption(self, &next);
                        try self.cancelExternal();
                        if (self.external) |external| for (self.operations.items) |*operation| {
                            if (operation.id == external) operation.obsolete = true;
                        };
                        self.external = null;
                        self.stopVm();
                    }
                    const old = try finish(&next, target, "cancelled", if (running) try self.expandEffects(a, j.get(active, "effects")) else .null, .null);
                    if (running) try RunState.clear(&next, .active);
                    if (kind == 12) try j.put(a, commandPtr(&next, id), "replacement_checked", .{ .bool = true });
                    if (kind == 13) {
                        const cancelled = try finish(&next, id, "completed", .null, .null);
                        try self.stage(next, &.{
                            .{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = target, .payload = old },
                            .{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = cancelled },
                        });
                    } else try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = target, .payload = old }});
                    return true;
                }
            },
            6 => {
                const source = j.text(j.get(payload, "source"));
                for (self.pending_capabilities.items) |pending| {
                    if (std.mem.eql(u8, pending.id, id)) {
                        candidate = pending.capability.retain();
                        break;
                    }
                }
                if (candidate == null) candidate = self.heap.registerTool(source) catch |err| {
                    failure = try diagnostic(a, "invalid_extension", @errorName(err));
                    const completed = try finish(&next, id, "failed", .null, failure);
                    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
                    return true;
                };
                if (!std.mem.eql(u8, candidate.?.source(), source)) return error.InvalidExtension;
                const descriptor = try j.parse(a, candidate.?.metadata());
                const name = j.text(j.get(descriptor, "name"));
                if (name.len == 0) return error.InvalidExtension;
                var tool = j.object();
                try j.put(a, &tool, "name", j.string(name));
                try j.put(a, &tool, "source", j.get(payload, "source"));
                try j.put(a, &tool, "source_name", j.get(payload, "source_name"));
                try j.put(a, &tool, "descriptor", descriptor);
                const hash = j.sourceHash(source);
                try j.put(a, &tool, "source_hash", j.string(try a.dupe(u8, &hash)));
                const tools = j.ptr(&next.value, "capabilities");
                var replaced = false;
                for (tools.array.items) |*old| if (std.mem.eql(u8, j.text(j.get(old.*, "name")), name)) {
                    old.* = tool;
                    replaced = true;
                    break;
                };
                if (!replaced) {
                    try tools.array.append(tool);
                }
                var response = j.object();
                var fields = tool.object.iterator();
                while (fields.next()) |field| try j.put(a, &response, field.key_ptr.*, field.value_ptr.*);
                result = response;
                changed = true;
            },
            7 => {
                const name = j.text(j.get(payload, "name"));
                const tools = j.ptr(&next.value, "capabilities");
                for (tools.array.items, 0..) |tool, index| {
                    if (!std.mem.eql(u8, j.text(j.get(tool, "name")), name)) continue;
                    _ = tools.array.orderedRemove(index);
                    changed = true;
                    break;
                }
                if (!changed) failure = try diagnostic(a, "unknown_tool", name);
            },
            2 => {
                const active = j.ptr(&next.value, "active");
                if (active.* == .null or j.number(j.get(active.*, "kind")) != 1) {
                    failure = try diagnostic(a, "invalid_state", "Steering requires an active model run.");
                } else {
                    try j.put(a, active, "stop", j.string("steer"));
                    try j.put(a, active, "steer_policy", j.get(payload, "policy"));
                    if (j.get(active.*, "steering") != .array) try j.put(a, active, "steering", j.array(a));
                    try j.ptr(active, "steering").array.append(j.get(payload, "content"));
                }
            },
            3, 5 => {
                try RunState.clear(&next, .suspended);
                const active = j.ptr(&next.value, "active");
                if (active.* != .null) try j.put(a, active, "stop", j.string("cancel"));
                if (kind == 5) {
                    try j.put(a, &next.value, "closing", .{ .bool = true });
                    try j.put(a, &next.value, "close_id", j.string(try a.dupe(u8, id)));
                    try j.put(a, commandPtr(&next, id), "status", j.string("running"));
                    try self.stage(next, &.{});
                    return true;
                }
            },
            else => return error.InvalidArgument,
        }
        if (changed) {
            const revision = j.number(j.get(next.value, "capabilities_revision")) + 1;
            try j.put(a, &next.value, "capabilities_revision", j.integer(revision));
            if (result == .null) result = j.object();
            try j.put(a, &result, "capabilities_revision", j.integer(revision));
        }
        const completed = try finish(&next, id, if (failure == .null) "completed" else "failed", result, failure);
        if (changed) {
            try self.stageRegistered(next, &.{
                .{ .kind = api.CPI_AGENT_EVENT_CAPABILITIES_COMMITTED, .request = id, .payload = completed },
                .{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed },
            }, candidate);
        } else try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
        return true;
    }
    return false;
}

pub fn advance(self: *W, instructions: u32) !bool {
    const active = j.get(self.state.value, "active");
    if (active != .null) {
        if (j.text(j.get(active, "stop")).len > 0) return work.stop(self);
        return work.advance(self, instructions);
    }
    if (j.flag(j.get(self.state.value, "closing"))) {
        var next = try self.mutate();
        errdefer next.deinit();
        const id = j.text(j.get(next.value, "close_id"));
        const completed = try finish(&next, id, "completed", .null, .null);
        try j.put(next.allocator(), &next.value, "closed", .{ .bool = true });
        try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
        return true;
    }
    for (j.get(self.state.value, "commands").array.items) |entry| {
        if (self.bootstrap and !std.mem.eql(u8, self.bootstrap_request orelse "", j.text(j.get(entry, "id")))) continue;
        if (!std.mem.eql(u8, j.text(j.get(entry, "status")), "queued")) continue;
        const kind = j.number(j.get(entry, "kind"));
        if (kind != 1 and kind != 4 and kind < 8) continue;
        var next = try self.mutate();
        errdefer next.deinit();
        const a = next.allocator();
        const id = j.text(j.get(entry, "id"));
        const command = commandPtr(&next, id);
        const payload = j.get(command.*, "payload");
        const requested = if (kind == 12) j.get(payload, "conversation") else .null;
        const scope = if (requested == .string) requested.string else application_context.main;
        if ((requested != .null and requested != .string) or
            (!std.mem.eql(u8, scope, application_context.main) and (!self.context_codec.scoped_application or !self.journal.state.contexts.contains(scope))))
        {
            const failure = try diagnostic(a, "unknown_conversation", "The delivery requires an existing application conversation.");
            const completed = try finish(&next, id, "failed", .null, failure);
            try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
            return true;
        }
        try switchApplicationContext(self, &next, scope);
        try j.put(a, command, "status", j.string("running"));
        if (kind == 1 or (kind >= 8 and kind <= 11)) {
            var lowered = payload;
            if (kind == 1) {
                lowered = j.object();
                try j.put(a, &lowered, "input", j.get(payload, "content"));
                try j.put(a, &lowered, "model", self.options.value);
            }
            @import("domain_ops.zig").start(self, &next, id, if (kind == 1) 8 else kind, lowered) catch |err| {
                next.deinit();
                next = try self.mutate();
                const failure = try diagnostic(next.allocator(), @errorName(err), "The conversation command was rejected.");
                const completed = try finish(&next, id, "failed", .null, failure);
                try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
            };
            return true;
        }
        var running = j.object();
        try j.put(a, &running, "id", j.string(try a.dupe(u8, id)));
        try j.put(a, &running, "kind", j.integer(kind));
        try j.put(a, &running, "phase", j.string("lua"));
        const application = j.get(self.options.value, "application");
        try j.put(a, &running, "source", if (kind == 12) j.string(try a.dupe(u8, j.text(j.get(application, "source")))) else j.get(payload, "source"));
        if (kind == 12) {
            try j.put(a, &running, "application", .{ .bool = true });
            try j.put(a, &running, "mutable", j.get(application, "mutable"));
            try j.put(a, &running, "input_json", j.get(payload, "input_json"));
            const binding = j.get(payload, "application_model");
            if (binding != .null) try j.put(a, &running, "application_model", binding);
            const environment = j.text(j.get(application, "environment_json"));
            if (std.mem.eql(u8, scope, application_context.main)) {
                try j.put(a, &running, "environment_json", j.string(try a.dupe(u8, environment)));
            } else {
                var scoped = try j.parse(a, environment);
                try j.put(a, &scoped, "conversation", j.string(scope));
                try j.put(a, &scoped, "conversation_entry_prefix", j.string(try application_context.entryPrefix(a, scope)));
                const head = if (j.get(j.get(next.value, "ctx"), "session") == .null) try persistence.seedHead(&self.journal, scope) else null;
                if (head) |anchor| try j.put(a, &scoped, "conversation_head", j.string(anchor));
                try j.put(a, &running, "environment_json", j.string(try j.encode(a, scoped)));
            }
        }
        try j.put(a, &running, "capabilities", try j.copy(a, j.get(next.value, "capabilities")));
        try j.put(a, &running, "capabilities_revision", j.get(next.value, "capabilities_revision"));
        try j.put(a, &running, "round", j.integer(0));
        try j.put(a, &running, "effects", j.array(a));
        try RunState.installFresh(&next, &running);
        try self.stage(next, &.{});
        return true;
    }
    return false;
}

fn deliveryScope(payload: Value) []const u8 {
    const scope = j.get(payload, "conversation");
    return if (scope == .string) scope.string else application_context.main;
}

fn switchApplicationContext(self: *W, next: *j.Document, scope: []const u8) !void {
    const previous = application_context.scope(next.value);
    if (std.mem.eql(u8, previous, scope)) return;
    const a = next.allocator();
    if (self.bootstrap) {
        try j.put(a, &next.value, "bootstrap_context", try j.project(a, .{ .scope = previous, .value = j.get(next.value, "ctx") }));
    }
    const context = try persistence.applicationContext(&self.journal, self.context_codec, a, scope);
    try j.put(a, &next.value, "ctx", context);
    if (std.mem.eql(u8, scope, application_context.main)) {
        _ = next.value.object.orderedRemove("application_scope");
    } else {
        try j.put(a, &next.value, "application_scope", j.string(try a.dupe(u8, scope)));
    }
}
