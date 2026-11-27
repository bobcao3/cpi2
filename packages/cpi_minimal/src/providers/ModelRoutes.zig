//! Bind local credentials to endpoints before asking the registry for models.
//! A catalog model is not required to discover a route's first model.
const std = @import("std");
const Auth = @import("Auth.zig");
const registry = @import("model_registry");

pub const Source = enum { environment, saved, current, pending };
pub const Target = struct {
    record: Auth.Record,
    reference: ?*const registry.Provider,
    source: Source,

    pub fn discovery(self: Target) registry.discovery.Target {
        const r = self.record;
        return .{ .reference = self.reference, .route = .{ .base_url = r.base_url, .kind = if (r.kind == .openai) .codex else .standard, .token = r.token, .account_id = r.account_id } };
    }
};

pub fn same(a: Auth.Record, b: Auth.Record) bool {
    return a.kind == b.kind and sameEndpoint(a.base_url, b.base_url) and std.mem.eql(u8, a.token, b.token) and std.mem.eql(u8, a.account_id orelse "", b.account_id orelse "");
}
pub fn sameEndpoint(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

/// Endpoint overrides are bound to the selected credential, not applied to
/// other providers that happen to be discoverable in the same harness.
pub fn selectedEndpoint(store: *const Auth.Store, provider: registry.Provider) []const u8 {
    const generic = std.mem.eql(u8, provider.api_key_env, "OPENAI_API_KEY");
    const environment_base = if (generic) (if (store.environment) |env| env.get("OPENAI_BASE_URL") else null) else null;
    return store.base_url_override orelse environment_base orelse provider.base_url;
}

pub fn collect(a: std.mem.Allocator, catalog: ?*const registry.Registry, store: *const Auth.Store, current: ?Auth.Record, only: ?*const registry.Provider) ![]const Target {
    var targets: std.ArrayList(Target) = .empty;
    if (store.environment_route) |r| try add(a, &targets, catalog, only, r, .environment, null);
    if (store.environment) |env| {
        if (catalog) |c| for (c.providers()) |*p| {
            if (only != null and only != p) continue;
            const token = env.get(p.api_key_env) orelse continue;
            const selected = if (store.environment_provider_id) |id| c.find(id) else null;
            const explicit = p == selected;
            var base = p.base_url;
            const codex = std.mem.eql(u8, p.id, "openai-codex");
            const generic = std.mem.eql(u8, p.api_key_env, "OPENAI_API_KEY");
            if (generic and !explicit and std.mem.eql(u8, env.get("OPENAI_PROTOCOL") orelse "", "codex")) continue;
            if (explicit) {
                base = selectedEndpoint(store, p.*);
            } else if (selected != null and std.mem.eql(u8, selected.?.api_key_env, p.api_key_env)) continue else if (generic) {
                // Never spray the generic key across every compatible endpoint.
                base = (if (selected == null) store.base_url_override else null) orelse env.get("OPENAI_BASE_URL") orelse registry.selection.openai.base_url;
                if (!sameEndpoint(base, p.base_url) and !(std.mem.eql(u8, p.id, "openai") and c.endpoint(base) == null)) continue;
            } else if (std.mem.eql(u8, p.api_key_env, "OPENAI_ACCESS_TOKEN")) {
                if (!codex or !sameEndpoint(base, "https://chatgpt.com/backend-api/codex")) continue;
            } else {
                // A shared environment variable is not authorization to try
                // the same secret at several hosts. Require a named route.
                for (c.providers()) |other| {
                    if (std.mem.eql(u8, other.api_key_env, p.api_key_env) and !sameEndpoint(other.base_url, base)) break;
                } else {
                    try add(a, &targets, catalog, only, .{ .kind = if (std.mem.eql(u8, p.id, "deepseek")) .deepseek else .compatible, .base_url = base, .model = "unconfigured", .token = token }, .environment, p);
                }
                continue;
            }
            if (codex and !sameEndpoint(base, @import("agent").provider.codex_base_url)) continue;
            const record: Auth.Record = .{ .kind = if (codex) .openai else if (std.mem.eql(u8, p.id, "deepseek")) .deepseek else .compatible, .base_url = base, .account_id = if (codex) env.get("CHATGPT_ACCOUNT_ID") orelse continue else null, .model = "unconfigured", .token = token };
            try add(a, &targets, catalog, only, record, .environment, if (explicit or sameEndpoint(base, p.base_url)) p else null);
        };
        // The conventional environment route works even with a catalog that
        // omits OpenAI or when there is not yet a chosen model.
        const selected = if (catalog) |c| if (store.environment_provider_id) |id| c.find(id) else null else null;
        if (only == null and (selected == null or !std.mem.eql(u8, selected.?.api_key_env, "OPENAI_API_KEY")) and
            std.mem.eql(u8, env.get("OPENAI_PROTOCOL") orelse "responses", "responses"))
        {
            if (env.get("OPENAI_API_KEY")) |token| {
                const base = (if (selected == null) store.base_url_override else null) orelse env.get("OPENAI_BASE_URL") orelse registry.selection.openai.base_url;
                const kind: Auth.Kind = if (sameEndpoint(base, registry.selection.deepseek.base_url)) .deepseek else .compatible;
                try add(a, &targets, catalog, only, .{ .kind = kind, .base_url = base, .model = "unconfigured", .token = token }, .environment, null);
            }
        }
    }
    for (store.document.profiles) |r| try add(a, &targets, catalog, only, r, .saved, null);
    if (current) |r| try add(a, &targets, catalog, only, r, .current, null);
    return targets.items;
}

fn add(a: std.mem.Allocator, targets: *std.ArrayList(Target), catalog: ?*const registry.Registry, only: ?*const registry.Provider, r: Auth.Record, source: Source, hint: ?*const registry.Provider) !void {
    if (r.token.len == 0 or r.token[0] == '!' or std.mem.eql(u8, r.token, "unconfigured")) return;
    const reference = hint orelse (if (catalog) |c| c.endpoint(r.base_url) else null);
    if (only) |p| if (reference != p) return;
    for (targets.items) |*t| if (same(t.record, r)) {
        if (t.reference == null) t.reference = reference;
        if (std.mem.eql(u8, t.record.model, "unconfigured")) t.record.model = r.model;
        return;
    };
    try targets.append(a, .{ .record = r, .reference = reference, .source = source });
}
