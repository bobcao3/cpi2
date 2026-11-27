//! The registry scopes model metadata by provider and owns returned slices until deinit.
const std = @import("std");
pub const MemoryBudget = @import("agent").MemoryBudget;
pub const default_memory_bytes = @import("agent").default_memory_bytes;
const Runtime = @import("runtime.zig").Runtime;
const GenericRuntime = @import("runtime/Generic.zig").GenericRuntime;
const types = @import("model.zig");
pub const selection = @import("selection.zig");
pub const discovery = @import("discovery.zig");
pub const Refresh = @import("Refresh.zig");

test {
    _ = @import("runtime.zig");
    _ = selection;
    _ = discovery;
}

pub const Pricing = types.Pricing;
pub const ImageResize = types.ImageResize;
pub const Model = types.Model;
pub const Provider = types.Provider;
pub const Config = types.Config;
pub const cloneModel = @import("ownership.zig").model;
pub const SizeSink = @import("agent").session_protocol.Transaction.SizeSink;

pub const expected_config_bytes = 32 * 1024 * 1024;
/// Compatibility name for the advisory threshold.
pub const max_config_bytes = expected_config_bytes;

/// Evaluate a Lua configuration file returning an arbitrary acyclic value.
/// The caller owns the returned JSON document. This is intentionally separate
/// from `Registry`, whose schema is fixed. Values cross the VM boundary
/// structurally; JSON text is only produced by the CLI/wire consumers.
pub fn parseLuaValue(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return parseLuaValueObserved(a, bytes, .{});
}

pub fn parseLuaValueObserved(a: std.mem.Allocator, bytes: []const u8, size_warnings: SizeSink) !std.json.Parsed(std.json.Value) {
    size_warnings.report("Lua configuration bytes", bytes.len, expected_config_bytes);
    var runtime = GenericRuntime.init(a);
    defer runtime.deinit();
    defer size_warnings.report("Lua configuration nesting depth", runtime.depth, 16);
    _ = try runtime.evaluateGeneric(bytes);
    return runtime.takeResult();
}

pub fn loadLuaValue(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(std.json.Value) {
    return loadLuaValueObserved(a, io, path, .{});
}

pub fn loadLuaValueObserved(a: std.mem.Allocator, io: std.Io, path: []const u8, size_warnings: SizeSink) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(bytes);
    return parseLuaValueObserved(a, bytes, size_warnings);
}

pub const Registry = struct {
    parsed: @import("runtime.zig").Owned,

    /// Evaluation owns a fresh, effect-free VM. The arena outlives the source and VM.
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Registry {
        return parseObserved(a, bytes, .{});
    }

    pub fn parseObserved(a: std.mem.Allocator, bytes: []const u8, size_warnings: SizeSink) !Registry {
        size_warnings.report("model registry bytes", bytes.len, expected_config_bytes);
        var runtime = Runtime.init(a);
        defer runtime.deinit();
        _ = try runtime.evaluate(bytes);
        var result = runtime.takeConfig();
        errdefer result.deinit();
        try validate(a, result.value, size_warnings);
        return .{ .parsed = result };
    }

    pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Registry {
        return loadObserved(a, io, path, .{});
    }

    pub fn loadObserved(a: std.mem.Allocator, io: std.Io, path: []const u8, size_warnings: SizeSink) !Registry {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        defer a.free(bytes);
        return parseObserved(a, bytes, size_warnings);
    }

    pub fn bundled(a: std.mem.Allocator) !Registry {
        return parse(a, @embedFile("data/models.lua"));
    }

    pub fn deinit(self: *Registry) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    /// Replace or inject an entire offer list. Copies caller memory into the
    /// registry arena; a discovery job or harness override may be freed at once.
    pub fn putProvider(self: *Registry, provider: Provider) !void {
        return self.putProviderObserved(provider, .{});
    }

    pub fn putProviderObserved(self: *Registry, provider: Provider, size_warnings: SizeSink) !void {
        const a = self.parsed.arena.allocator();
        const owned = try @import("ownership.zig").provider(a, provider);
        try validate(a, .{ .version = 2, .providers = &.{owned} }, size_warnings);
        const old = self.providers();
        var replacement: ?usize = null;
        for (old, 0..) |item, index| if (std.mem.eql(u8, item.id, owned.id)) {
            replacement = index;
            break;
        };
        const next = try a.alloc(Provider, old.len + @intFromBool(replacement == null));
        @memcpy(next[0..old.len], old);
        next[replacement orelse old.len] = owned;
        self.parsed.value.providers = next;
    }

    /// Merge first-party live metadata without losing documentation-only fields.
    /// The account list is not treated as a replacement for the public catalog.
    pub fn mergeDiscovery(self: *Registry, base_url: []const u8, discovered: []const Model) !void {
        return self.mergeDiscoveryObserved(base_url, discovered, .{});
    }

    pub fn mergeDiscoveryObserved(self: *Registry, base_url: []const u8, discovered: []const Model, size_warnings: SizeSink) !void {
        const a = self.parsed.arena.allocator();
        const reference = self.endpoint(base_url);
        var models: std.ArrayList(Model) = .empty;
        if (reference) |provider| try models.appendSlice(a, provider.models);
        for (discovered) |incoming| {
            var index: ?usize = null;
            for (models.items, 0..) |prior, i| if (std.mem.eql(u8, prior.id, incoming.id)) {
                index = i;
                break;
            };
            var merged = incoming;
            if (index) |i| {
                const prior = models.items[i];
                merged.context_window = incoming.context_window orelse prior.context_window;
                merged.max_output_tokens = incoming.max_output_tokens orelse prior.max_output_tokens;
                merged.image_resize = incoming.image_resize orelse prior.image_resize;
                if (incoming.image_resize != null and prior.image_resize != null) {
                    inline for (@typeInfo(ImageResize).@"struct".field_names) |field| {
                        @field(merged.image_resize.?, field) = @field(incoming.image_resize.?, field) orelse @field(prior.image_resize.?, field);
                    }
                }
                if (incoming.transports.len == 0) merged.transports = prior.transports;
                if (incoming.reasoning_efforts.len == 0) merged.reasoning_efforts = prior.reasoning_efforts;
                merged.pricing = prior.pricing;
                merged.source_url = incoming.source_url orelse prior.source_url;
                models.items[i] = merged;
            } else try models.append(a, merged);
        }
        var provider: Provider = if (reference) |entry| entry.* else .{
            .id = try std.fmt.allocPrint(a, "custom-{x}", .{std.hash.Wyhash.hash(0, base_url)}),
            .name = "Custom provider",
            .base_url = base_url,
            .api_key_env = "",
            .models = &.{},
        };
        provider.models = models.items;
        try self.putProviderObserved(provider, size_warnings);
    }

    pub fn providers(self: *const Registry) []const Provider {
        return self.parsed.value.providers;
    }

    pub fn find(self: *const Registry, id: []const u8) ?*const Provider {
        for (self.providers()) |*provider| if (std.mem.eql(u8, provider.id, id)) return provider;
        return null;
    }

    pub fn endpoint(self: *const Registry, base_url: []const u8) ?*const Provider {
        var found: ?*const Provider = null;
        for (self.providers()) |*provider| {
            if (!std.mem.eql(u8, std.mem.trimEnd(u8, base_url, "/"), std.mem.trimEnd(u8, provider.base_url, "/"))) continue;
            if (found != null) return null;
            found = provider;
        }
        return found;
    }

    /// The caller must select a provider explicitly when multiple providers match.
    pub fn matchEndpoint(self: *const Registry, base_url: []const u8, model_id: []const u8) ?*const Provider {
        const base = std.mem.trimEnd(u8, base_url, "/");
        var found: ?*const Provider = null;
        for (self.providers()) |*provider| {
            if (!std.mem.eql(u8, base, std.mem.trimEnd(u8, provider.base_url, "/"))) continue;
            if (provider.find(model_id) == null) continue;
            if (found != null) return null;
            found = provider;
        }
        return found;
    }
};

pub fn token(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}

fn validate(a: std.mem.Allocator, config: Config, size_warnings: SizeSink) !void {
    if (config.version != 2) return error.UnsupportedRegistryVersion;
    var provider_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer provider_ids.deinit(a);
    for (config.providers) |provider| {
        if (!token(provider.id) or provider.name.len == 0) return error.InvalidProvider;
        size_warnings.report("provider ID bytes", provider.id.len, 128);
        const entry = try provider_ids.getOrPut(a, provider.id);
        if (entry.found_existing) return error.DuplicateProvider;
        var model_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer model_ids.deinit(a);
        for (provider.models) |model| {
            if (!token(model.id) or model.name.len == 0) return error.InvalidModel;
            size_warnings.report("model ID bytes", model.id.len, 512);
            inline for (.{ .{ model.transports, "transport name bytes" }, .{ model.reasoning_efforts, "reasoning effort name bytes" } }) |group| {
                const items = group[0];
                for (items, 0..) |item, index| {
                    if (!token(item)) return error.InvalidModelApi;
                    size_warnings.report(group[1], item.len, 128);
                    for (items[0..index]) |prior| if (std.mem.eql(u8, prior, item)) return error.InvalidModelApi;
                }
            }
            if (model.context_window == 0 or model.max_output_tokens == 0) return error.InvalidModelLimits;
            if (model.context_window) |limit| if (limit > 9007199254740991) return error.InvalidModelLimits;
            if (model.image_resize) |limits| {
                if (limits.max_width == 0 or limits.max_height == 0 or limits.max_bytes == 0 or limits.jpeg_quality == 0)
                    return error.InvalidModelLimits;
                if (limits.max_bytes) |bytes| if (bytes > 9007199254740991) return error.InvalidModelLimits;
                if (limits.jpeg_quality) |quality| if (quality > 100) return error.InvalidModelLimits;
            }
            const model_entry = try model_ids.getOrPut(a, model.id);
            if (model_entry.found_existing) return error.DuplicateModel;
            inline for (@typeInfo(Pricing).@"struct".field_names) |name| {
                if (@field(model.pricing, name)) |price| {
                    if (!std.math.isFinite(price) or price < 0) return error.InvalidPrice;
                }
            }
        }
    }
}
