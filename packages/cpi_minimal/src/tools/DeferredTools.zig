const std = @import("std");
const j = @import("../json.zig");

pub const application_source = @embedFile("../session/session.luau") ++ "\n" ++ @embedFile("tool_loadout.luau") ++ "\n" ++ @embedFile("tool_search.luau") ++ "\n" ++ @embedFile("deferred_tools.luau") ++ "\n" ++ @embedFile("script_tool.luau") ++ "\n" ++ @embedFile("application.luau");

pub const Definition = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters: j.Value,
    handler: union(enum) {
        luau: []const u8,
        mcp: struct { server: []const u8, tool: []const u8 },
    },
};

pub const Batch = struct {
    source: []const u8 = "local",
    replace_source: bool = false,
    definitions: []const Definition,
    remove: []const []const u8 = &.{},

    pub fn value(self: Batch, a: std.mem.Allocator) !j.Value {
        var definitions = j.array(a);
        for (self.definitions) |entry| {
            const handler = switch (entry.handler) {
                .luau => |source| try j.value(a, .{ .kind = "luau", .source = source }),
                .mcp => |remote| try j.value(a, .{ .kind = "mcp", .server = remote.server, .tool = remote.tool }),
            };
            try definitions.array.append(try j.value(a, .{
                .name = entry.name,
                .description = entry.description,
                .parameters = entry.parameters,
                .handler = handler,
            }));
        }
        return j.value(a, .{ .source = self.source, .replace_source = self.replace_source, .definitions = definitions, .remove = self.remove });
    }
};
