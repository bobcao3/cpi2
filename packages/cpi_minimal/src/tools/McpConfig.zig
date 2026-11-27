//! A malformed discovered user/project file is reported and ignored: MCP is an
//! optional integration and must not prevent the session from opening. An
//! explicit `--mcp-config` is different: the user asked for that file, so a
//! parse or validation failure is returned to the caller.

const std = @import("std");
const registry = @import("model_registry");
const mcp = @import("mcp");

pub const Options = struct {
    explicit_path: ?[]const u8 = null,
    no_mcp: bool = false,
    allow_project: bool = false,
    agent_dir: []const u8,
    workspace: []const u8,
    environment: *const std.process.Environ.Map,
    size_warnings: mcp.Transport.SizeSink = .{},
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, options: Options) !mcp.Config {
    if (options.no_mcp) return mcp.Config.empty(gpa);
    var temporary = std.heap.ArenaAllocator.init(gpa);
    defer temporary.deinit();
    const a = temporary.allocator();

    var selected: ?[]const u8 = null;
    if (options.explicit_path) |path| {
        selected = try a.dupe(u8, path);
    } else {
        const user_path = try std.fs.path.join(a, &.{ options.agent_dir, "mcp.lua" });
        if (fileExists(io, user_path)) selected = user_path;
        if (selected == null and options.allow_project) {
            const project_path = try std.fs.path.join(a, &.{ options.workspace, ".pi", "mcp.lua" });
            if (fileExists(io, project_path)) selected = project_path;
        }
    }
    if (selected == null) return mcp.Config.empty(gpa);

    var value = registry.loadLuaValueObserved(gpa, io, selected.?, .{
        .context = options.size_warnings.context,
        .notify = options.size_warnings.notify,
    }) catch |err| {
        if (options.explicit_path == null) {
            std.log.err("ignoring MCP configuration {s}: {s}", .{ selected.?, @errorName(err) });
            return mcp.Config.empty(gpa);
        }
        return err;
    };
    defer value.deinit();
    var config = mcp.Config.parseObserved(gpa, value.value, options.environment, options.size_warnings) catch |err| {
        if (options.explicit_path == null) {
            std.log.err("ignoring MCP configuration {s}: {s}", .{ selected.?, @errorName(err) });
            return mcp.Config.empty(gpa);
        }
        return err;
    };
    errdefer config.deinit();
    config.source_path = try config.arena.allocator().dupe(u8, selected.?);
    return config;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}
