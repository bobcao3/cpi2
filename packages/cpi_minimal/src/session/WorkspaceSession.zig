//! Owns the workspace-bound Controller and retires its leases on a switch.
const std = @import("std");
const registry = @import("model_registry");
const Controller = @import("Controller.zig");
const Self = @This();
const Allocator = std.mem.Allocator;

current: *Controller,
launch: Controller.Settings,
environment: *const std.process.Environ.Map,
arena: ?*std.heap.ArenaAllocator = null,

pub const Candidate = struct {
    controller: *Controller,
    arena: ?*std.heap.ArenaAllocator,

    pub fn deinit(self: *Candidate) void {
        if (self.arena) |arena| release(self.controller, arena);
        self.arena = null;
    }
};

fn release(controller: *Controller, arena: ?*std.heap.ArenaAllocator) void {
    const gpa = controller.gpa;
    controller.close();
    if (arena) |owner| {
        owner.deinit();
        gpa.destroy(owner);
    }
}

pub fn deinit(self: *Self) void {
    release(self.current, self.arena);
}

pub fn defaultDirectory(a: Allocator, root: []const u8, workspace: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{x}", .{ root, std.hash.Wyhash.hash(0, workspace) });
}

pub fn build(self: *const Self, replacement: *Controller.SessionReplacement) !Candidate {
    const old = self.current;
    const workspace = replacement.workspace orelse return error.InvalidSessionWorkspace;
    const prepared = if (replacement.recovered) |*journal| journal else return error.InvalidSession;
    const path = replacement.path orelse return error.InvalidSession;
    const gpa = old.gpa;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var settings = self.launch;
    settings.run_policy = old.runPolicy();
    settings.workspace = try a.dupe(u8, workspace);
    settings.saved_workspace = if (replacement.missing_workspace) |saved| try a.dupe(u8, saved) else null;
    settings.session_directory = if (settings.session_root) |root| try defaultDirectory(a, root, settings.workspace) else settings.session_directory;
    settings.session_path = try a.dupe(u8, path);
    settings.startup_size_warnings = &.{};
    const previous = try Controller.decodeSelection(a, try prepared.contextDocument(a, "model_selection"));
    const provider = try copyRoute(a, &settings, old, previous);
    return .{
        .controller = try Controller.create(a, gpa, old.io, settings, provider, self.environment, .{ .previous = previous, .prepared = prepared }),
        .arena = arena,
    };
}

fn copyRoute(a: Allocator, settings: *Controller.Settings, old: *Controller, previous: ?Controller.ModelSelection) !*Controller.Provider {
    if (try Controller.resolveSavedSessionRoute(a, settings, previous)) |provider| return provider;
    settings.context_window = old.settings.context_window;
    settings.max_output_tokens = old.settings.max_output_tokens;
    settings.registry_provider = old.settings.registry_provider;
    settings.strict_registry = old.settings.strict_registry;
    settings.refresh_saved_auth = old.settings.refresh_saved_auth;
    settings.selected_metadata = if (old.settings.selected_metadata) |metadata| try registry.cloneModel(a, metadata) else null;
    settings.reasoning_effort = if (old.settings.reasoning_effort) |wire| try a.dupe(u8, wire) else null;
    const provider = try a.create(Controller.Provider);
    provider.* = try old.providerSnapshot(a);
    return provider;
}

/// The caller has already drained outgoing work and joined its UI consumers.
pub fn install(self: *Self, candidate: *Candidate) void {
    release(self.current, self.arena);
    self.current = candidate.controller;
    self.arena = candidate.arena;
    candidate.arena = null;
}
