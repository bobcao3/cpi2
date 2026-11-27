const std = @import("std");

pub const Pricing = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
};

pub const ImageResize = struct {
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    max_bytes: ?u64 = null,
    jpeg_quality: ?u8 = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    transports: []const []const u8 = &.{},
    reasoning_efforts: []const []const u8 = &.{},
    context_window: ?u64 = null,
    max_output_tokens: ?u32 = null,
    image_resize: ?ImageResize = null,
    pricing: Pricing = .{},
    source_url: ?[]const u8 = null,

    pub fn supports(self: Model, transport: []const u8) bool {
        for (self.transports) |item| if (std.mem.eql(u8, item, transport)) return true;
        return false;
    }

    pub fn thinkingProfile(self: Model) !?@import("agent").thinking.Profile {
        if (self.reasoning_efforts.len == 0) return null;
        var profile: @import("agent").thinking.Profile = .{};
        var known: usize = 0;
        for (self.reasoning_efforts) |effort| {
            const level = @import("agent").thinking.parse(effort) catch continue;
            known += 1;
            if (profile.supports(level)) return error.DuplicateThinkingLevel;
            profile.entries[@backingInt(level)] = if (std.mem.eql(u8, effort, "off")) .omitted else .{ .effort = effort };
        }
        return if (known == 0) null else profile;
    }
};

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    source_url: ?[]const u8 = null,
    retrieved_at: ?[]const u8 = null,
    models: []const Model,

    pub fn find(self: *const Provider, id: []const u8) ?*const Model {
        for (self.models) |*model| if (std.mem.eql(u8, model.id, id)) return model;
        return null;
    }
};

pub const Config = struct {
    version: u32,
    providers: []const Provider,
};
