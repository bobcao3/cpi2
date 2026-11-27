//! Picker presentation over credential-bound discovery targets.
const std = @import("std");
const registry = @import("model_registry");
const Auth = @import("Auth.zig");
const Routes = @import("ModelRoutes.zig");
pub const Source = Routes.Source;
pub const Choice = struct {
    key: []const u8,
    label: []const u8,
    provider_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
    observed: ?registry.Model = null,
    record: Auth.Record,
    source: Source,
};
const Builder = struct {
    a: std.mem.Allocator,
    choices: std.ArrayList(Choice) = .empty,
    ids: std.StringHashMapUnmanaged(void) = .empty,
    keys: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Builder, target: Routes.Target, id: []const u8, name: []const u8, model_id: []const u8, model_name: []const u8) !void {
        if (model_id.len == 0 or std.mem.eql(u8, model_id, "unconfigured")) return;
        const key = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ id, model_id });
        if ((try self.keys.getOrPut(self.a, key)).found_existing) return;
        var selected = target.record;
        selected.model = try self.a.dupe(u8, model_id);
        try self.choices.append(self.a, .{
            .key = key,
            .label = try std.fmt.allocPrint(self.a, "{s} [{s}] / {s} [{s}]", .{ name, id, model_name, model_id }),
            .provider_id = id,
            .provider_name = name,
            .model_id = selected.model,
            .model_name = model_name,
            .record = selected,
            .source = target.source,
        });
    }
    fn route(self: *Builder, target: Routes.Target, live: ?[]const registry.Model) !void {
        const id = switch (target.record.kind) {
            .openai => "openai-subscription",
            .deepseek => "deepseek",
            .compatible => if (target.reference) |p| p.id else "compatible",
        };
        var unique = id;
        var suffix: usize = 1;
        while (self.ids.contains(unique)) {
            suffix += 1;
            unique = try std.fmt.allocPrint(self.a, "{s}-{d}", .{ id, suffix });
        }
        try self.ids.put(self.a, unique, {});
        const name = if (target.reference) |p| p.name else try std.fmt.allocPrint(self.a, "Provider ({s})", .{target.record.base_url});
        const models = live orelse if (target.reference) |p| p.models else &.{};
        for (models) |model| {
            if (!(live != null and model.transports.len == 0) and !model.supports(if (target.record.kind == .openai) "openai-codex-responses" else "openai-responses")) continue;
            const before = self.choices.items.len;
            try self.add(target, unique, name, model.id, model.name);
            if (live != null and before != self.choices.items.len) self.choices.items[before].observed = model;
        }
        if (live == null) try self.add(target, unique, name, target.record.model, target.record.model);
    }
};

/// The projection borrows catalog and live snapshot data. Consume it before
/// advancing discovery or reconciling routes.
pub fn project(a: std.mem.Allocator, targets: []const Routes.Target, discovery: *const registry.Refresh, pending_only: bool) ![]const Choice {
    var builder: Builder = .{ .a = a };
    for (targets, 0..) |target, index| {
        if ((target.source == .pending) != pending_only) continue;
        const offer = discovery.offer(index);
        try builder.route(target, if (offer) |listing| (if (listing.fallback_reason == null) listing.models else null) else null);
    }
    return builder.choices.items;
}
pub fn hasMultipleProviders(targets: []const Routes.Target, discovery: *const registry.Refresh) bool {
    var first: ?[]const u8 = null;
    for (targets, 0..) |target, index| {
        if (target.source == .pending) continue;
        const live = if (discovery.offer(index)) |offer| if (offer.fallback_reason == null) offer.models else null else null;
        const models = live orelse if (target.reference) |provider| provider.models else &.{};
        const transport = if (target.record.kind == .openai) "openai-codex-responses" else "openai-responses";
        const has_models = for (models) |model| {
            if ((live != null and model.transports.len == 0) or model.supports(transport)) break true;
        } else live == null and target.record.model.len != 0 and !std.mem.eql(u8, target.record.model, "unconfigured");
        if (!has_models) continue;
        const id = if (target.reference) |provider| provider.id else target.record.base_url;
        if (first) |seen| {
            if (!std.mem.eql(u8, seen, id)) return true;
        } else first = id;
    }
    return false;
}

pub fn lookup(choices: []const Choice, key: []const u8) !?Choice {
    for (choices) |choice| if (std.mem.eql(u8, choice.key, key) or std.mem.eql(u8, choice.label, key)) return choice;
    var found: ?Choice = null;
    for (choices) |choice| if (std.mem.eql(u8, choice.model_id, key)) {
        if (found) |previous| {
            if (!Routes.same(previous.record, choice.record)) return error.AmbiguousModelUseProviderModel;
        } else found = choice;
    };
    return found;
}
