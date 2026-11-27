//! Shared selection policy. Harnesses supply overrides/defaults, not forked metadata.
const std = @import("std");
const registry = @import("root.zig");

pub const Limits = struct {
    context_window: u64 = 128000,
    max_output_tokens: u32 = 16384,
};
pub const Overrides = struct {
    context_window: ?u64 = null,
    max_output_tokens: ?u32 = null,
};
pub fn limits(model: ?*const registry.Model, overrides: Overrides, defaults: Limits) Limits {
    return .{
        .context_window = overrides.context_window orelse (if (model) |m| m.context_window else null) orelse defaults.context_window,
        .max_output_tokens = overrides.max_output_tokens orelse @min(defaults.max_output_tokens, (if (model) |m| m.max_output_tokens else null) orelse defaults.max_output_tokens),
    };
}

pub const Service = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    model_env: []const u8 = "OPENAI_MODEL",
    default_model: ?[]const u8 = null,
};
pub const openai: Service = .{ .id = "openai", .name = "OpenAI", .base_url = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY" };
pub const deepseek: Service = .{ .id = "deepseek", .name = "DeepSeek", .base_url = "https://api.deepseek.com", .api_key_env = "DEEPSEEK_API_KEY", .model_env = "DEEPSEEK_MODEL", .default_model = "deepseek-flash" };

/// Choose the direct DeepSeek service when it is the only configured credential.
/// Explicit provider/model settings always win. No aggregator fallback is implicit.
pub fn environmentProvider(catalog: *const registry.Registry, env: *std.process.Environ.Map, explicit: ?[]const u8) !?*const registry.Provider {
    const id = explicit orelse if (env.get(deepseek.api_key_env) != null and env.get("OPENAI_API_KEY") == null and env.get("OPENAI_ACCESS_TOKEN") == null) deepseek.id else return null;
    const provider = catalog.find(id) orelse return error.UnknownRegistryProvider;
    return provider;
}

/// Model preferences are provider-scoped; selecting DeepSeek must not consume
/// an unrelated OPENAI_MODEL or manufacture OpenAI environment state.
pub fn providerModel(provider: *const registry.Provider, env: *const std.process.Environ.Map, explicit: ?[]const u8, remembered: ?[]const u8) ?[]const u8 {
    if (explicit) |name| return name;
    const native_deepseek = std.mem.eql(u8, provider.id, deepseek.id);
    if (env.get(if (native_deepseek) deepseek.model_env else openai.model_env)) |name| return name;
    if (remembered) |name| if (!std.mem.eql(u8, name, "unconfigured")) return name;
    if (native_deepseek) {
        const name = deepseek.default_model.?;
        if (provider.find(name) != null) return name;
    }
    return null;
}

test "same limit policy for startup and selection with explicit harness overrides" {
    const model: registry.Model = .{ .id = "m", .name = "M", .context_window = 1048576, .max_output_tokens = 8000 };
    const value = limits(&model, .{}, .{});
    try std.testing.expectEqual(@as(u64, 1048576), value.context_window);
    try std.testing.expectEqual(@as(u32, 8000), value.max_output_tokens);
    const overridden = limits(&model, .{ .context_window = 4096, .max_output_tokens = 2000 }, .{});
    try std.testing.expectEqual(@as(u64, 4096), overridden.context_window);
    try std.testing.expectEqual(@as(u32, 2000), overridden.max_output_tokens);
}
