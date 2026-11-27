//! Validated OpenAI-compatible provider settings and host-owned credentials.

const std = @import("std");
const agent = @import("config.zig");

pub const default_base_url = "https://api.openai.com/v1";
pub const credential_label = "openai-compatible";
pub const Transport = enum { http, websocket, @"websocket-cached" };
pub const Protocol = @import("responses.zig").Dialect;
pub const codex_base_url = "https://chatgpt.com/backend-api/codex";

pub const Kind = enum { compatible, deepseek, openai_subscription };

pub const Provider = struct {
    allocator: std.mem.Allocator,
    kind: Kind = .compatible,
    base_url: []u8,
    responses_url: []u8,
    model: []u8,
    api_key: []u8,
    transport: Transport = .http,
    protocol: Protocol = .responses,
    account_id: ?[]u8 = null,

    pub const Options = struct {
        kind: Kind = .compatible,
        base_url: []const u8,
        model: []const u8,
        api_key: []const u8,
        protocol: Protocol = .responses,
        transport: Transport = .http,
        account_id: ?[]const u8 = null,
    };

    /// Legacy OpenAI-compatible environment adapter. Named providers use the
    /// typed constructor instead of rewriting OPENAI_* variables.
    pub fn init(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !Provider {
        return initWithCodexTransportDefault(allocator, environ, .websocket);
    }

    pub fn initWithCodexTransportDefault(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, codex_default: Transport) !Provider {
        const protocol = std.meta.stringToEnum(Protocol, environ.get("OPENAI_PROTOCOL") orelse "responses") orelse return error.InvalidProtocol;
        return initOptions(allocator, .{
            .kind = if (protocol == .codex) .openai_subscription else .compatible,
            .base_url = environ.get("OPENAI_BASE_URL") orelse if (protocol == .codex) codex_base_url else default_base_url,
            .model = environ.get("OPENAI_MODEL") orelse return error.MissingModel,
            .api_key = environ.get(if (protocol == .codex) "OPENAI_ACCESS_TOKEN" else "OPENAI_API_KEY") orelse return error.MissingCredential,
            .protocol = protocol,
            .transport = try environmentTransport(environ, if (protocol == .codex) codex_default else .http),
            .account_id = environ.get("CHATGPT_ACCOUNT_ID"),
        });
    }

    pub fn environmentTransport(environ: *const std.process.Environ.Map, default: Transport) !Transport {
        const value = environ.get("OPENAI_TRANSPORT") orelse return default;
        return std.meta.stringToEnum(Transport, value) orelse error.InvalidTransport;
    }

    pub fn initOptions(allocator: std.mem.Allocator, options: Options) !Provider {
        const protocol = options.protocol;
        const transport = options.transport;
        if (options.kind == .deepseek and (protocol != .responses or transport != .http)) return error.InvalidProtocol;
        if ((options.kind == .openai_subscription) != (protocol == .codex)) return error.InvalidProtocol;
        if (transport == .@"websocket-cached" and protocol != .codex) return error.InvalidTransport;
        const base = options.base_url;
        if (base.len == 0) return error.InvalidBaseUrl;
        try validateBaseUrl(base);
        const model = options.model;
        if (model.len == 0) return error.InvalidModel;
        for (model) |byte| if (byte < 0x21 or byte == 0x7f) return error.InvalidModel;
        if (protocol == .codex and !std.mem.eql(u8, std.mem.trimEnd(u8, base, "/"), codex_base_url)) return error.InvalidBaseUrl;
        const account = if (protocol == .codex) options.account_id orelse return error.MissingAccountId else null;
        if (account) |value| {
            if (value.len == 0) return error.InvalidAccountId;
            for (value) |byte| if (byte < 0x21 or byte == 0x7f) return error.InvalidAccountId;
        }
        const key = options.api_key;
        if (key.len == 0 or key[0] == '!') return error.InvalidCredential;
        for (key) |byte| if (byte < 0x21 or byte == 0x7f) return error.InvalidCredential;

        const base_copy = try allocator.dupe(u8, base);
        errdefer allocator.free(base_copy);
        const responses = try deriveResponsesUrl(allocator, base_copy);
        errdefer allocator.free(responses);
        const model_copy = try allocator.dupe(u8, model);
        errdefer allocator.free(model_copy);
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const account_copy = if (account) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .kind = options.kind,
            .base_url = base_copy,
            .responses_url = responses,
            .model = model_copy,
            .api_key = key_copy,
            .protocol = protocol,
            .transport = transport,
            .account_id = account_copy,
        };
    }

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.responses_url);
        self.allocator.free(self.model);
        self.allocator.free(self.api_key);
        if (self.account_id) |account_id| self.allocator.free(account_id);
    }

    pub fn name(self: *const Provider) []const u8 {
        return switch (self.kind) {
            .deepseek => "deepseek",
            .openai_subscription => "openai-subscription",
            .compatible => "openai-compatible",
        };
    }

    /// Only the first-party HTTP endpoint has the native replay contract.
    pub fn supportsNativeResume(self: *const Provider) bool {
        if (self.kind != .compatible or self.protocol != .responses or self.transport != .http) return false;
        const uri = std.Uri.parse(self.responses_url) catch return false;
        if (!std.mem.eql(u8, uri.scheme, "https") or (uri.port != null and uri.port.? != 443)) return false;
        const host = switch (uri.host orelse return false) {
            .raw, .percent_encoded => |text| text,
        };
        const path = switch (uri.path) {
            .raw, .percent_encoded => |text| text,
        };
        return std.ascii.eqlIgnoreCase(host, "api.openai.com") and std.mem.eql(u8, path, "/v1/responses");
    }

    pub fn credentialLabel(self: *const Provider) []const u8 {
        return if (self.kind == .deepseek) "deepseek" else credential_label;
    }

    pub fn modelConfig(self: *const Provider, instructions: []const u8) agent.Model {
        return .{
            .model = self.model,
            .base_url = self.base_url,
            .instructions = instructions,
            .credential = self.credentialLabel(),
        };
    }
};

fn deriveResponsesUrl(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (std.mem.endsWith(u8, trimmed, "/responses")) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
}

fn validateBaseUrl(base: []const u8) !void {
    for (base) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidBaseUrl;
    }
    const uri = std.Uri.parse(base) catch return error.InvalidBaseUrl;
    const secure = std.mem.eql(u8, uri.scheme, "https");
    const plain = std.mem.eql(u8, uri.scheme, "http");
    if (!secure and !plain) return error.InvalidBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidBaseUrl;
    const host = switch (uri.host orelse return error.InvalidBaseUrl) {
        .raw, .percent_encoded => |text| text,
    };
    if (host.len == 0 or std.mem.findScalar(u8, host, '%') != null) return error.InvalidBaseUrl;
    if (uri.port) |port| if (port == 0) return error.InvalidBaseUrl;
    if (plain) {
        const bare = if (host.len > 1 and host[0] == '[' and host[host.len - 1] == ']')
            host[1 .. host.len - 1]
        else
            host;
        if (!isLoopback(bare)) return error.InvalidBaseUrl;
    }
}

fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "::1")) return true;
    const address = std.Io.net.Ip4Address.parse(host, 0) catch return false;
    return std.mem.eql(u8, &address.bytes, &.{ 127, 0, 0, 1 });
}
