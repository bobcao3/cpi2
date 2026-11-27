//! Resolve the tools offered by a Minimal session. Capability registration is independent.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tool = enum { read, bash, edit, write, grep, find, ls, execute_lua };
pub const defaults: []const Tool = &.{ .read, .bash, .edit, .write };
pub const direct: []const Tool = &.{ .read, .bash, .edit, .write, .grep, .find, .ls };
pub const catalog: []const Tool = direct ++ &[_]Tool{.execute_lua};

pub const Reader = enum { read, bash };

pub fn reader(tools: []const Tool) ?Reader {
    if (std.mem.indexOfScalar(Tool, tools, .read) != null) return .read;
    if (std.mem.indexOfScalar(Tool, tools, .bash) != null) return .bash;
    return null;
}

selection: ?[]const []const u8 = null,
excluded: []const []const u8 = &.{},
disabled: enum { none, builtin, all } = .none,

const Self = @This();

pub fn split(a: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len != 0) try list.append(a, name);
    }
    return list.toOwnedSlice(a);
}

fn modifier(name: []const u8) bool {
    return name.len > 0 and (name[0] == '+' or name[0] == '-');
}

pub fn validateSelection(entries: []const []const u8) !void {
    if (entries.len == 0) return;
    const modifies = modifier(entries[0]);
    for (entries) |entry| {
        if (modifier(entry) != modifies or (modifies and std.mem.indexOfScalar(u8, entry, '*') != null))
            return error.InvalidToolSelection;
    }
}

pub fn resolve(self: Self, a: Allocator, configured: ?[]const []const u8, has_mcp: bool) ![]const Tool {
    var tools: std.ArrayList(Tool) = .empty;
    if (self.disabled == .none) {
        if (configured) |entries| {
            for (entries) |entry| {
                if (!modifier(entry)) if (std.meta.stringToEnum(Tool, entry)) |tool| try append(a, &tools, tool);
            }
            if (entries.len > 0 and allModifiers(entries)) try tools.appendSlice(a, defaults);
            try apply(a, &tools, entries);
        } else try tools.appendSlice(a, defaults);
    }
    if (self.selection) |entries| {
        if (entries.len > 0 and modifier(entries[0])) {
            try apply(a, &tools, entries);
        } else {
            tools.clearRetainingCapacity();
            for (entries) |entry| {
                if (std.meta.stringToEnum(Tool, entry)) |tool| try append(a, &tools, tool);
            }
            for (catalog) |tool| {
                if (matchesAny(entries, @tagName(tool))) try append(a, &tools, tool);
            }
        }
    }
    if (has_mcp and self.allowsAutomaticScript()) try append(a, &tools, .execute_lua);
    var kept: usize = 0;
    for (tools.items) |tool| {
        if (matchesAny(self.excluded, @tagName(tool))) continue;
        tools.items[kept] = tool;
        kept += 1;
    }
    tools.shrinkRetainingCapacity(kept);
    return tools.toOwnedSlice(a);
}

pub fn canRestoreAtLaunch(self: Self) bool {
    return self.disabled == .none and self.allowlist() == null;
}

pub fn launchModifiers(self: Self) []const []const u8 {
    if (self.allowlist() != null) return &.{};
    return self.selection orelse &.{};
}

pub fn allowsAutomaticScript(self: Self) bool {
    return self.disabled != .all and self.allowlist() == null and !matchesAny(self.excluded, "execute_lua");
}

pub fn permits(self: Self, tool: Tool, launch: []const Tool) bool {
    if (matchesAny(self.excluded, @tagName(tool))) return false;
    if (self.allowlist()) |entries| return matchesAny(entries, @tagName(tool));
    return self.disabled != .all or std.mem.indexOfScalar(Tool, launch, tool) != null;
}

fn allowlist(self: Self) ?[]const []const u8 {
    const entries = self.selection orelse return null;
    return if (entries.len == 0 or !modifier(entries[0])) entries else null;
}

fn allModifiers(entries: []const []const u8) bool {
    for (entries) |entry| if (!modifier(entry)) return false;
    return true;
}

fn append(a: Allocator, tools: *std.ArrayList(Tool), tool: Tool) !void {
    if (std.mem.indexOfScalar(Tool, tools.items, tool) == null) try tools.append(a, tool);
}

fn apply(a: Allocator, tools: *std.ArrayList(Tool), entries: []const []const u8) !void {
    for (entries) |entry| {
        if (!modifier(entry)) continue;
        const tool = std.meta.stringToEnum(Tool, entry[1..]) orelse continue;
        if (entry[0] == '+') {
            try append(a, tools, tool);
        } else if (std.mem.indexOfScalar(Tool, tools.items, tool)) |index| {
            _ = tools.orderedRemove(index);
        }
    }
}

fn matchesAny(entries: []const []const u8, name: []const u8) bool {
    for (entries) |entry| if (matches(entry, name)) return true;
    return false;
}

fn matches(pattern: []const u8, name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, pattern, '*');
    const first = parts.next().?;
    if (parts.index == null) return std.mem.eql(u8, first, name);
    if (!std.mem.startsWith(u8, name, first)) return false;
    var rest = name[first.len..];
    while (parts.next()) |part| {
        if (parts.index == null) return std.mem.endsWith(u8, rest, part);
        const index = std.mem.indexOf(u8, rest, part) orelse return false;
        rest = rest[index + part.len ..];
    }
    unreachable;
}
