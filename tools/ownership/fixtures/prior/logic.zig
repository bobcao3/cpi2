const std = @import("std");
const W = @import("Session.zig");
const j = W.j;
const api = W.api;
const vm = @import("vm");
const work = @import("work.zig");
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
    try j.put(document.allocator(), &value, "registry_revision", j.get(document.value, "registry_revision"));
    const command = commandPtr(document, id);
    try j.put(document.allocator(), command, "status", j.string(status));
    try j.put(document.allocator(), command, "outcome", value);
    return value;
}

pub fn admitOne(self: *W) !bool {
    if (self.admissions.items.len == 0) return false;
    const item = self.admissions.orderedRemove(0);
    defer self.gpa.free(item.id);
    var payload = item.payload;
    defer payload.deinit();
    if (self.command(item.id)) |old| {
        if (j.number(j.get(old, "kind")) != item.kind or !j.equal(j.get(old, "payload"), payload.value)) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const failure = try diagnostic(arena.allocator(), "request_conflict", "The recovered request ID names different content.");
            const result = try outcome(arena.allocator(), "failed", .null, failure);
            try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, item.id, "", result);
            return true;
        }
        try self.emit(api.CPI_AGENT_EVENT_COMMAND_COMMITTED, 0, self.sequence, item.id, "", .null);
        const state = j.text(j.get(old, "status"));
        if (!std.mem.eql(u8, state, "queued") and !std.mem.eql(u8, state, "running"))
            try self.emit(api.CPI_AGENT_EVENT_COMMAND_FINISHED, 0, self.sequence, item.id, "", j.get(old, "outcome"));
        return true;
    }
    var next = try self.mutate();
    errdefer next.deinit();
    const a = next.allocator();
    const commands = j.ptr(&next.value, "commands");
    if (commands.array.items.len >= 1024) return error.LimitExceeded;
    var entry = j.object();
    try j.put(a, &entry, "id", j.string(try a.dupe(u8, item.id)));
    try j.put(a, &entry, "kind", j.integer(item.kind));
    try j.put(a, &entry, "payload", try j.copy(a, payload.value));
    try j.put(a, &entry, "status", j.string("queued"));
    try commands.array.append(entry);
    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_COMMITTED, .request = item.id }});
    return true;
}

pub fn control(self: *W) !bool {
    const commands = j.get(self.state.value, "commands");
    for (commands.array.items) |entry| {
        const kind = j.number(j.get(entry, "kind"));
        if (kind == 1 or kind == 4 or kind >= 8 or !std.mem.eql(u8, j.text(j.get(entry, "status")), "queued")) continue;
        const id = j.text(j.get(entry, "id"));
        var next = try self.mutate();
        errdefer next.deinit();
        const a = next.allocator();
        const payload = j.get(commandPtr(&next, id).*, "payload");
        var result: Value = .null;
        var failure: Value = .null;
        var changed = false;
        switch (kind) {
            6 => {
                const source = j.text(j.get(payload, "source"));
                const metadata = vm.describe(self.gpa, source, self.max_vm) catch |err| {
                    failure = try diagnostic(a, "invalid_extension", @errorName(err));
                    const completed = try finish(&next, id, "failed", .null, failure);
                    try self.stage(next, &.{.{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed }});
                    return true;
                };
                defer self.gpa.free(metadata);
                const descriptor = try j.parse(a, metadata);
                const name = j.text(j.get(descriptor, "name"));
                if (name.len == 0 or name.len > 128) return error.InvalidExtension;
                var tool = j.object();
                try j.put(a, &tool, "name", j.string(name));
                try j.put(a, &tool, "source", j.get(payload, "source"));
                try j.put(a, &tool, "source_name", j.get(payload, "source_name"));
                try j.put(a, &tool, "descriptor", descriptor);
                const hash = j.sourceHash(source);
                try j.put(a, &tool, "source_hash", j.string(try a.dupe(u8, &hash)));
                const tools = j.ptr(&next.value, "tools");
                var replaced = false;
                for (tools.array.items) |*old| if (std.mem.eql(u8, j.text(j.get(old.*, "name")), name)) {
                    old.* = tool;
                    replaced = true;
                    break;
                };
                if (!replaced) {
                    if (tools.array.items.len >= 64) return error.LimitExceeded;
                    try tools.array.append(tool);
                }
                result = tool;
                changed = true;
            },
            7 => {
                const name = j.text(j.get(payload, "name"));
                const tools = j.ptr(&next.value, "tools");
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
                try j.put(a, &next.value, "suspended", .null);
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
            const revision = j.number(j.get(next.value, "registry_revision")) + 1;
            try j.put(a, &next.value, "registry_revision", j.integer(revision));
            if (result == .null) result = j.object();
            try j.put(a, &result, "registry_revision", j.integer(revision));
        }
        const completed = try finish(&next, id, if (failure == .null) "completed" else "failed", result, failure);
        if (changed) {
            try self.stage(next, &.{
                .{ .kind = api.CPI_AGENT_EVENT_TOOL_REGISTRY_COMMITTED, .request = id, .payload = completed },
                .{ .kind = api.CPI_AGENT_EVENT_COMMAND_FINISHED, .request = id, .payload = completed },
            });
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
        if (!std.mem.eql(u8, j.text(j.get(entry, "status")), "queued")) continue;
        const kind = j.number(j.get(entry, "kind"));
        if (kind != 1 and kind != 4 and kind < 8) continue;
        var next = try self.mutate();
        errdefer next.deinit();
        const a = next.allocator();
        const id = j.text(j.get(entry, "id"));
        const command = commandPtr(&next, id);
        const payload = j.get(command.*, "payload");
        try j.put(a, command, "status", j.string("running"));
        if (kind == 1 or kind >= 8) {
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
        try j.put(a, &running, "source", j.get(payload, "source"));
        try j.put(a, &running, "tools", try j.copy(a, j.get(next.value, "tools")));
        try j.put(a, &running, "registry_revision", j.get(next.value, "registry_revision"));
        try j.put(a, &running, "round", j.integer(0));
        try j.put(a, &running, "effects", j.array(a));
        try j.put(a, &next.value, "active", running);
        try self.stage(next, &.{});
        return true;
    }
    return false;
}
