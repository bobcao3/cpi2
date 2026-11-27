//! A session selection names a route. Only host configuration supplies credentials.
const std = @import("std");
const registry = @import("model_registry");
const Auth = @import("Auth.zig");
const Provider = @import("agent").provider.Provider;
const Inbox = @import("../session.zig").Inbox;
const j = @import("../json.zig");
const Self = @This();

pub const Source = enum { environment, saved };
const Kind = @FieldType(Provider.Options, "kind");
const Protocol = @FieldType(Provider.Options, "protocol");
const Transport = @FieldType(Provider.Options, "transport");

id: []const u8,
source: Source,
provider_ref: ?[]const u8 = null,
kind: Kind,
base_url: []const u8,
protocol: Protocol,
transport: Transport,
account_ref: ?[]const u8,
model: []const u8,
reasoning_effort: ?[]const u8,
thinking_level: []const u8,

pub fn capture(a: std.mem.Allocator, id: []const u8, provider: *const Provider, source: Source, effort: ?[]const u8, label: []const u8) !Self {
    return .{
        .id = id,
        .source = source,
        .kind = provider.kind,
        .base_url = std.mem.trimEnd(u8, provider.base_url, "/"),
        .protocol = provider.protocol,
        .transport = provider.transport,
        .account_ref = if (provider.account_id) |account| try a.dupe(u8, &Inbox.inputHash(account)) else null,
        .model = provider.model,
        .reasoning_effort = effort,
        .thinking_level = label,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn effective(context: std.json.Value) std.json.Value {
    const launch = j.get(context, "launch_model_selection");
    return if (launch == .object) launch else j.get(context, "model_selection");
}

pub fn sameChoice(self: Self, other: Self) bool {
    return self.source == other.source and self.kind == other.kind and self.protocol == other.protocol and
        self.transport == other.transport and eql(self.base_url, other.base_url) and eql(self.model, other.model) and
        eql(self.thinking_level, other.thinking_level) and
        eql(self.account_ref orelse "", other.account_ref orelse "") and
        eql(self.provider_ref orelse "", other.provider_ref orelse "") and
        eql(self.reasoning_effort orelse "", other.reasoning_effort orelse "");
}

pub fn environmentReference(self: Self, provider: *const Provider, auth: *const Auth.Store, providers: []const registry.Provider) ?[]const u8 {
    if (self.source != .environment or self.protocol != .responses) return null;
    const env = auth.environment orelse return null;
    var reference: ?[]const u8 = null;
    var ambiguous = false;
    for (providers) |entry| {
        const candidate = namedOptions(self, auth, env, entry, false) orelse continue;
        if (!self.matches(candidate) or !eql(provider.api_key, candidate.api_key)) continue;
        if (eql(auth.environment_provider_id orelse "", entry.id)) return entry.id;
        ambiguous = ambiguous or reference != null;
        reference = entry.id;
    }
    return if (ambiguous) null else reference;
}

fn matches(self: Self, candidate: Provider.Options) bool {
    if (candidate.kind != self.kind or candidate.protocol != self.protocol or
        !eql(std.mem.trimEnd(u8, candidate.base_url, "/"), self.base_url)) return false;
    const account = candidate.account_id orelse return self.account_ref == null;
    return eql(self.account_ref orelse return false, &Inbox.inputHash(account));
}

pub fn matchesRecord(self: Self, record: Auth.Record) bool {
    return self.matches(Auth.providerOptions(record));
}

pub fn matchesProvider(self: Self, provider: *const Provider) bool {
    return provider.transport == self.transport and self.matches(.{
        .kind = provider.kind,
        .base_url = provider.base_url,
        .protocol = provider.protocol,
        .account_id = provider.account_id,
        .model = provider.model,
        .api_key = provider.api_key,
    });
}

/// The provider service uses this identity for resumptions across transport
/// and account changes. It contains no secret or per-turn model preference.
pub fn credential(self: Self, a: std.mem.Allocator) ![]const u8 {
    var reference = try j.value(a, .{
        .source = self.source,
        .kind = self.kind,
        .base_url = self.base_url,
        .protocol = self.protocol,
        .transport = self.transport,
        .account_ref = self.account_ref,
    });
    if (self.provider_ref) |id| try reference.object.put(a, "provider_ref", j.string(id));
    const identity = try j.encode(a, reference);
    defer a.free(identity);
    return std.fmt.allocPrint(a, "minimal/{s}", .{Inbox.inputHash(identity)});
}

fn load(self: Self, a: std.mem.Allocator, candidate: Provider.Options, override_model: ?[]const u8) !?*Provider {
    if (!self.matches(candidate)) return null;
    var options = candidate;
    options.model = override_model orelse self.model;
    options.transport = self.transport;
    const provider = try a.create(Provider);
    errdefer a.destroy(provider);
    provider.* = try Provider.initOptions(a, options);
    return provider;
}

pub fn resolve(self: Self, a: std.mem.Allocator, auth: *const Auth.Store, catalog: *const registry.Registry, override_model: ?[]const u8) !?*Provider {
    return self.resolveProviders(a, auth, catalog.providers(), override_model);
}

pub fn resolveProviders(self: Self, a: std.mem.Allocator, auth: *const Auth.Store, providers: []const registry.Provider, override_model: ?[]const u8) !?*Provider {
    if (self.source == .saved) {
        const record = auth.find(switch (self.kind) {
            .compatible => .compatible,
            .deepseek => .deepseek,
            .openai_subscription => .openai,
        }) orelse return null;
        var settings = Auth.providerOptions(record);
        if (record.kind == .openai) {
            if (auth.environment) |env| settings.transport = try Provider.environmentTransport(env, .@"websocket-cached");
        }
        return self.load(a, settings, override_model);
    }

    const env = auth.environment orelse return null;
    if (self.kind == .openai_subscription) {
        const token = env.get("OPENAI_ACCESS_TOKEN") orelse return null;
        const account = env.get("CHATGPT_ACCOUNT_ID") orelse return null;
        return self.load(a, .{
            .kind = .openai_subscription,
            .base_url = @import("agent").provider.codex_base_url,
            .model = self.model,
            .api_key = token,
            .protocol = .codex,
            .transport = try Provider.environmentTransport(env, .@"websocket-cached"),
            .account_id = account,
        }, override_model);
    }
    if (self.provider_ref) |id| {
        for (providers) |entry| {
            if (!eql(entry.id, id)) continue;
            const candidate = namedOptions(self, auth, env, entry, true) orelse return null;
            return self.load(a, candidate, override_model);
        }
        return null;
    }
    const environment_base = env.get("OPENAI_BASE_URL");
    var generic_base = environment_base orelse @import("agent").provider.default_base_url;
    if (auth.environment_provider_id) |id| {
        for (providers) |entry| if (eql(entry.id, id) and eql(entry.api_key_env, "OPENAI_API_KEY")) {
            generic_base = @import("ModelRoutes.zig").selectedEndpoint(auth, entry);
            break;
        };
    } else if (auth.base_url_override) |base| generic_base = base;
    var selected: ?Provider.Options = null;
    var key_name: ?[]const u8 = null;
    if (eql(env.get("OPENAI_PROTOCOL") orelse "responses", "responses")) {
        if (env.get("OPENAI_API_KEY")) |token| {
            for ([_]?[]const u8{ generic_base, environment_base }) |base| {
                const candidate = responseOptions(self, base orelse continue, token, null);
                if (!self.matches(candidate)) continue;
                selected = candidate;
                key_name = "OPENAI_API_KEY";
                break;
            }
        }
    }
    for (providers) |entry| {
        if (eql(entry.api_key_env, "OPENAI_API_KEY") or eql(entry.id, "openai-codex")) continue;
        const candidate = namedOptions(self, auth, env, entry, false) orelse continue;
        if (!self.matches(candidate)) continue;
        if (key_name) |prior| if (!eql(prior, entry.api_key_env)) return null;
        selected = candidate;
        key_name = entry.api_key_env;
    }
    return self.load(a, selected orelse return null, override_model);
}

fn namedOptions(self: Self, auth: *const Auth.Store, env: *const std.process.Environ.Map, entry: registry.Provider, pinned: bool) ?Provider.Options {
    if (entry.api_key_env.len == 0 or eql(entry.id, "openai-codex")) return null;
    const selected = eql(auth.environment_provider_id orelse "", entry.id);
    const base = if (selected) @import("ModelRoutes.zig").selectedEndpoint(auth, entry) else entry.base_url;
    if (eql(entry.api_key_env, "OPENAI_API_KEY") and !selected and !pinned) {
        if (!eql(env.get("OPENAI_PROTOCOL") orelse "responses", "responses")) return null;
        const configured = env.get("OPENAI_BASE_URL") orelse @import("agent").provider.default_base_url;
        if (!eql(std.mem.trimEnd(u8, configured, "/"), std.mem.trimEnd(u8, base, "/"))) return null;
    }
    const token = env.get(entry.api_key_env) orelse return null;
    return responseOptions(self, base, token, if (eql(entry.id, registry.selection.deepseek.id)) .deepseek else null);
}

fn responseOptions(self: Self, base: []const u8, token: []const u8, known_kind: ?Kind) Provider.Options {
    return .{
        .kind = known_kind orelse if (eql(std.mem.trimEnd(u8, base, "/"), registry.selection.deepseek.base_url)) .deepseek else .compatible,
        .base_url = base,
        .model = self.model,
        .api_key = token,
    };
}
