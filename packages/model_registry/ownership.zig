//! Copies across discovery/injection lifetimes retain typed metadata, not a
//! serialized surrogate. All allocations belong to the registry arena.
const std = @import("std");
const registry = @import("root.zig");
const Allocator = std.mem.Allocator;

pub fn provider(a: Allocator, input: registry.Provider) !registry.Provider {
    var result = input;
    inline for (.{ "id", "name", "base_url", "api_key_env" }) |field| @field(result, field) = try a.dupe(u8, @field(input, field));
    inline for (.{ "source_url", "retrieved_at" }) |field| @field(result, field) = try optional(a, @field(input, field));
    const models = try a.alloc(registry.Model, input.models.len);
    for (input.models, models) |source, *target| {
        target.* = try model(a, source);
    }
    result.models = models;
    return result;
}

pub fn model(a: Allocator, source: registry.Model) !registry.Model {
    var result = source;
    result.id = try a.dupe(u8, source.id);
    result.name = try a.dupe(u8, source.name);
    result.source_url = try optional(a, source.source_url);
    result.transports = try strings(a, source.transports);
    result.reasoning_efforts = try strings(a, source.reasoning_efforts);
    return result;
}
fn optional(a: Allocator, input: ?[]const u8) !?[]const u8 {
    return if (input) |bytes| try a.dupe(u8, bytes) else null;
}

fn strings(a: Allocator, input: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, input.len);
    for (input, result) |source, *target| target.* = try a.dupe(u8, source);
    return result;
}
