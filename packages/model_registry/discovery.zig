//! Provider model-list protocol, independent of credentials storage and UI.
//! HTTP ownership/cancellation stays with the calling service. Parsing copies all
//! strings into the caller allocator; metadata is never inferred from ID prefixes.
const std = @import("std");
const json_text = @import("agent").session_protocol.json.text;
const registry = @import("root.zig");
const Value = std.json.Value;
pub const Kind = enum { standard, codex };
// This is the upstream model-discovery compatibility version, not CPI's version.
// OpenAI filters this endpoint's results by client version, including at 0.0.0.
pub const codex_client_version = std.mem.trim(u8, @embedFile("data/codex_client_version.txt"), "\r\n");

pub fn url(a: std.mem.Allocator, base_url: []const u8, kind: Kind) ![]const u8 {
    for (base_url) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidDiscoveryUrl;
    const uri = try std.Uri.parse(base_url);
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidDiscoveryUrl;
    const base = std.mem.trimEnd(u8, base_url, "/");
    const root = if (std.mem.endsWith(u8, base, "/responses")) base[0 .. base.len - "/responses".len] else base;
    if (kind == .codex) return std.fmt.allocPrint(a, "{s}/models?client_version={s}", .{ root, codex_client_version });
    return std.fmt.allocPrint(a, "{s}/models", .{root});
}

/// The caller supplies a credential bound to this endpoint and a cancellable HTTP
/// adapter. Both interactive and headless management use the same wire protocol.
pub const Listing = struct {
    models: []const registry.Model,
    fallback_reason: ?anyerror = null,
};
pub const Route = struct {
    base_url: []const u8,
    kind: Kind,
    token: []const u8,
    account_id: ?[]const u8 = null,
};
pub const Target = struct { route: Route, reference: ?*const registry.Provider = null };

/// Discover over HTTP with the framework adapter. The caller supplies only a
/// route that it has already authorized; credentials never follow redirects.
pub fn discover(a: std.mem.Allocator, io: std.Io, route: Route, reference: ?*const registry.Provider, warnings: registry.SizeSink) !Listing {
    return list(a, io, route, reference, warnings, @import("discovery_http.zig").get);
}

/// A successful (even empty) list owns membership. Reference metadata only
/// fills absent fields. Failed discovery leaves the reference list available.
pub fn list(a: std.mem.Allocator, io: std.Io, route: Route, reference: ?*const registry.Provider, warnings: registry.SizeSink, comptime get: anytype) !Listing {
    const models = fetch(a, io, route.base_url, route.kind, route.token, route.account_id, reference, warnings, get) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return .{ .models = if (reference) |p| p.models else &.{}, .fallback_reason = err },
    };
    return .{ .models = models };
}

fn fetch(a: std.mem.Allocator, io: std.Io, base_url: []const u8, kind: Kind, token: []const u8, account_id: ?[]const u8, reference: ?*const registry.Provider, warnings: registry.SizeSink, comptime get: anytype) ![]const registry.Model {
    const target = try url(a, base_url, kind);
    if (!registry.token(token)) return error.InvalidCredential;
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    defer std.crypto.secureZero(u8, bearer);
    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "Authorization", .value = bearer };
    var count: usize = 1;
    if (kind == .codex) {
        const account = account_id orelse return error.MissingAccountId;
        if (!registry.token(account)) return error.InvalidCredential;
        headers[1] = .{ .name = "ChatGPT-Account-Id", .value = account };
        count = 2;
    }
    const response = try get(a, io, target, headers[0..count], warnings);
    if (response.status == 401 or response.status == 403) return error.LoginRequired;
    if (response.status != 200) return error.ModelDiscoveryFailed;
    return parseObserved(a, response.body, kind, reference, target, warnings);
}

pub fn parse(a: std.mem.Allocator, body: Value, kind: Kind, reference: ?*const registry.Provider, source_url: ?[]const u8) ![]const registry.Model {
    return parseObserved(a, body, kind, reference, source_url, .{});
}

pub fn parseObserved(a: std.mem.Allocator, body: Value, kind: Kind, reference: ?*const registry.Provider, source_url: ?[]const u8, warnings: registry.SizeSink) ![]const registry.Model {
    const data = field(body, if (kind == .codex) "models" else "data");
    if (data != .array) return error.InvalidModelList;
    var models: std.ArrayList(registry.Model) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (data.array.items) |item| {
        const visibility = field(item, "visibility");
        if (kind == .codex and visibility == .string and std.mem.eql(u8, visibility.string, "hide")) continue;
        const identity = field(item, if (kind == .codex) "slug" else "id");
        if (identity != .string or !registry.token(identity.string)) return error.InvalidModelList;
        if ((try seen.getOrPut(a, identity.string)).found_existing) continue;
        warnings.report("model ID bytes", identity.string.len, 512);
        const known = if (reference) |provider| provider.find(identity.string) else null;
        var model: registry.Model = if (known) |entry| entry.* else .{ .id = identity.string, .name = identity.string };
        model.id = try a.dupe(u8, identity.string);
        const name = field(item, if (kind == .codex) "display_name" else "name");
        model.name = try a.dupe(u8, if (name == .string and name.string.len > 0) name.string else model.name);
        model.context_window = try limit(u64, field(item, "context_window"), model.context_window);
        model.max_output_tokens = try limit(u32, field(item, "max_output_tokens"), model.max_output_tokens);
        const effort = field(field(item, "effort"), "supported_levels");
        const codex_efforts = field(item, "supported_reasoning_levels");
        if (kind == .codex and codex_efforts != .null) {
            if (codex_efforts != .array) return error.InvalidModelList;
            const values = try a.alloc([]const u8, codex_efforts.array.items.len);
            for (codex_efforts.array.items, values) |entry, *value| {
                const level = field(entry, "effort");
                if (level != .string) return error.InvalidModelList;
                warnings.report("reasoning effort name bytes", level.string.len, 128);
                value.* = try a.dupe(u8, level.string);
            }
            model.reasoning_efforts = values;
        } else if (effort != .null) {
            const values = try strings(a, effort, warnings, "reasoning effort name bytes");
            const all = try a.alloc([]const u8, values.len + 1);
            all[0] = "none";
            @memcpy(all[1..], values);
            model.reasoning_efforts = all;
        } else model.reasoning_efforts = try copyStrings(a, model.reasoning_efforts);
        const transports = field(item, "transports");
        model.transports = if (transports != .null) try strings(a, transports, warnings, "transport name bytes") else if (kind == .codex) &.{"openai-codex-responses"} else try copyStrings(a, model.transports);
        if (source_url orelse model.source_url) |source| model.source_url = try a.dupe(u8, source);
        try models.append(a, model);
    }
    return models.items;
}
fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn limit(comptime T: type, value: Value, fallback: ?T) !?T {
    if (value == .null) return fallback;
    if (value != .integer or value.integer <= 0 or value.integer > @as(u64, std.math.maxInt(T)) or value.integer > 9007199254740991) return error.InvalidModelLimits;
    return @intCast(value.integer);
}
fn strings(a: std.mem.Allocator, value: Value, warnings: registry.SizeSink, measurement: []const u8) ![]const []const u8 {
    if (value != .array) return error.InvalidModelList;
    const result = try a.alloc([]const u8, value.array.items.len);
    for (value.array.items, result) |item, *out| {
        if (item != .string or !registry.token(item.string)) return error.InvalidModelList;
        warnings.report(measurement, item.string.len, 128);
        out.* = try a.dupe(u8, item.string);
    }
    return result;
}
fn copyStrings(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, items.len);
    for (items, result) |item, *out| out.* = try a.dupe(u8, item);
    return result;
}

test "Codex discovery uses a pinned non-placeholder upstream compatibility version" {
    const a = std.testing.allocator;
    const request_url = try url(a, "https://chatgpt.com/backend-api/codex", .codex);
    defer a.free(request_url);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/models?client_version=0.172.0", request_url);
}

test "first-party discovery retains limits efforts and per-model transports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try json_text.parseFromSliceLeaky(Value, a,
        \\{"data":[{"id":"novel","name":"Novel","context_window":1048576,"max_output_tokens":393216,"effort":{"supported_levels":["low","high","max"]},"transports":["openai-responses","openai-chat"]}]}
    , .{});
    const models = try parse(a, body, .standard, null, null);
    try std.testing.expectEqual(@as(?u64, 1048576), models[0].context_window);
    try std.testing.expectEqual(@as(?u32, 393216), models[0].max_output_tokens);
    try std.testing.expect(models[0].supports("openai-responses"));
    try std.testing.expect((try models[0].thinkingProfile()).?.supports(.max));
}
