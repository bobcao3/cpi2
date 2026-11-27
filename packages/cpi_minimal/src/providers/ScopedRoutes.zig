const std = @import("std");
const agent = @import("agent");
const transport = agent.provider;
const registry = @import("model_registry");
const services = @import("services");
const Auth = @import("Auth.zig");
const Selection = @import("ModelSelection.zig");
const Routes = @This();

pub const DeferredRoute = struct {
    base_url: []const u8,
    kind: @FieldType(transport.Provider, "kind"),
    adapter: transport.DeferredAdapter,
};

workspace: []const u8,
retry: transport.Retry,
providers: []const registry.Provider,
auth_path: ?[]const u8,
legacy_path: ?[]const u8,
environment: ?*const std.process.Environ.Map,
environment_provider_id: ?[]const u8,
base_url_override: ?[]const u8,
size_warnings: Auth.SizeSink,
auth_revision: *std.atomic.Value(u64),
deferred_routes: []const DeferredRoute = &.{},

pub fn deferredFor(self: *const Routes, provider: *const transport.Provider) ?transport.DeferredAdapter {
    for (self.deferred_routes) |route| {
        if (route.kind == provider.kind and sameUrl(route.base_url, provider.base_url)) return route.adapter;
    }
    return null;
}

pub fn ownDeferredRoutes(a: std.mem.Allocator, routes: []const DeferredRoute) ![]const DeferredRoute {
    const owned = try a.dupe(DeferredRoute, routes);
    for (owned, 0..) |*route, index| {
        if (route.base_url.len == 0 or !transport.validDeferredAdapterId(route.adapter.id)) return error.InvalidDeferredRoute;
        for (owned[0..index]) |previous| {
            if (previous.kind == route.kind and sameUrl(previous.base_url, route.base_url)) return error.DuplicateDeferredRoute;
        }
        route.base_url = try a.dupe(u8, route.base_url);
        route.adapter.id = try a.dupe(u8, route.adapter.id);
    }
    return owned;
}

fn sameUrl(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, left, "/"), std.mem.trimEnd(u8, right, "/"));
}

pub fn resolver(self: *Routes) transport.ResolveRoute {
    return .{ .context = self, .call = resolveCallback };
}

fn store(self: *const Routes, a: std.mem.Allocator, io: std.Io) Auth.Store {
    return .{
        .a = a,
        .io = io,
        .path = self.auth_path orelse "",
        .legacy_path = self.legacy_path,
        .environment = self.environment,
        .environment_provider_id = self.environment_provider_id,
        .base_url_override = self.base_url_override,
        .size_warnings = self.size_warnings,
    };
}

fn resolveCallback(raw: ?*anyopaque, call: services.Context, value: std.json.Value) !?transport.Route {
    const self: *const Routes = @ptrCast(@alignCast(raw.?));
    const selection = try std.json.parseFromValueLeaky(Selection, call.allocator, value, .{});
    return self.resolve(call.allocator, call.io, selection);
}

pub fn resolve(self: *const Routes, a: std.mem.Allocator, io: std.Io, selection: Selection) !?transport.Route {
    var credentials = self.store(a, io);
    if (selection.source == .saved) {
        if (self.auth_path == null) return null;
        try credentials.reload();
    }
    const provider = (try selection.resolveProviders(a, &credentials, self.providers, null)) orelse return null;
    const credential = try selection.credential(a);
    var effects = transport.Effects.initLive(self.workspace, provider);
    effects.credential_override = credential;
    effects.request_reasoning_summary = true;
    effects.codex_sse_fallback = true;
    const prepare: ?transport.Prepare = if (selection.source == .saved and provider.protocol == .codex) blk: {
        const scoped = try a.create(Refresh);
        scoped.* = .{ .routes = self, .selection = selection, .provider = provider };
        break :blk .{ .context = scoped, .call = Refresh.prepare, .can_refresh = Refresh.available };
    } else null;
    return .{
        .base_url = provider.base_url,
        .credential = credential,
        .transport = effects,
        .retry = self.retry,
        .retry_mode = .resume_only,
        .prepare = prepare,
        .deferred = self.deferredFor(provider),
    };
}

const Refresh = struct {
    routes: *const Routes,
    selection: Selection,
    provider: *transport.Provider,

    fn available(_: ?*anyopaque) bool {
        return true;
    }

    fn prepare(raw: ?*anyopaque, io: std.Io, force: bool) !void {
        const self: *Refresh = @ptrCast(@alignCast(raw.?));
        const provider = self.provider;
        const a = provider.allocator;
        var credentials = self.routes.store(a, io);
        try credentials.reload();
        var saved = credentials.find(.openai) orelse return error.CredentialRefreshUnavailable;
        if (!self.selection.matchesRecord(saved)) return error.CredentialRefreshUnavailable;
        const already_rotated = !std.mem.eql(u8, saved.token, provider.api_key);
        if (force and !already_rotated) saved.expires = 0;
        const renewed = Auth.refresh(a, io, saved, self.routes.size_warnings) catch |err| switch (err) {
            error.LoginRequired => return error.CredentialRefreshUnavailable,
            else => return err,
        };
        const changed = !std.mem.eql(u8, renewed.token, saved.token) or renewed.expires != saved.expires;
        if (!changed and !already_rotated) return;
        const replacement = try a.dupe(u8, renewed.token);
        errdefer a.free(replacement);
        if (changed) try credentials.remember(renewed);
        std.crypto.secureZero(u8, provider.api_key);
        a.free(provider.api_key);
        provider.api_key = replacement;
        _ = self.routes.auth_revision.fetchAdd(1, .release);
    }
};
