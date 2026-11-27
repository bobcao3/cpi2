const std = @import("std");
const types = @import("config.zig");
const Runtime = @import("Runtime.zig");
const port = @import("port.zig");

pub const Command = types.Command;
pub const Limits = types.Limits;
pub const Capability = types.Capability;
pub const Model = types.Model;
pub const Adapter = types.Adapter;
pub const AdapterRequest = types.AdapterRequest;
pub const AdapterResponse = types.AdapterResponse;
pub const Adapters = types.Adapters;
pub const Observer = types.Observer;
pub const Notice = types.Notice;
pub const Request = Runtime.Request;
pub const Outcome = Runtime.Outcome;
pub const ContextSnapshot = Runtime.ContextSnapshot;
pub const conversation = @import("conversation.zig");
pub const responses = @import("responses.zig");
pub const ConversationSnapshot = conversation.Snapshot;
pub const SessionJournal = @import("SessionJournal.zig");
pub const session_protocol = @import("session_protocol");
pub const LuauJournal = @import("LuauJournal.zig");

pub const Config = struct {
    session_id: []const u8,
    journal_path: []const u8 = "memory:",
    persistence: enum { journal, memory } = .journal,
    workspace: []const u8 = ".",
    model: Model = .{},
    limits: Limits = .{},
    endpoint_grants: []const []const u8 = &.{},
    capabilities: []const Capability = &.{},
    adapters: Adapters = .{},
    observer: ?Observer = null,
};

const Bridge = struct {
    adapters: Adapters,
    observer: ?Observer,
    fn exchange(raw: *anyopaque, a: std.mem.Allocator, io: std.Io, event: port.Event) !?port.Response {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (event == .notice) {
            if (self.observer) |observer| try observer.notify(observer.context, event.notice);
            return null;
        }
        const request = event.request;
        const adapter = (if (request.method == .model) self.adapters.http else self.adapters.rpc) orelse return error.UnsupportedEffect;
        return try adapter.call(adapter.context, a, io, .{ .request_id = request.request_id, .json = request.json });
    }
};

pub const Worker = struct {
    runtime: *Runtime,
    bridge: *Bridge,
    gpa: std.mem.Allocator,
    pub fn open(a: std.mem.Allocator, io: std.Io, config: Config) !Worker {
        const bridge = try a.create(Bridge);
        errdefer a.destroy(bridge);
        bridge.* = .{ .adapters = config.adapters, .observer = config.observer };
        const runtime = try Runtime.open(a, io, .{ .session_id = config.session_id, .journal_path = config.journal_path, .persistence = if (config.persistence == .memory) .memory else .journal, .workspace = config.workspace, .model = config.model, .limits = config.limits, .endpoint_grants = config.endpoint_grants, .capabilities = config.capabilities }, .{ .context = bridge, .exchange = Bridge.exchange });
        return .{ .runtime = runtime, .bridge = bridge, .gpa = a };
    }
    pub fn submit(self: *Worker, id: []const u8, command: Command) !*Request {
        return self.runtime.submit(id, command);
    }
    pub fn readContext(self: *Worker, a: std.mem.Allocator) !ContextSnapshot {
        return self.runtime.readContext(a);
    }
    pub fn readConversation(self: *Worker, a: std.mem.Allocator) !ConversationSnapshot {
        return self.runtime.readConversation(a);
    }
    pub fn deinit(self: *Worker) void {
        self.runtime.destroy();
        self.gpa.destroy(self.bridge);
    }
};
