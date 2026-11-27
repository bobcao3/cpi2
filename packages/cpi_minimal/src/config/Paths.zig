//! User-scoped cpi-minimal locations.
//!
//! Configuration is intentionally separate from credentials and session data.
//! The config root is the documented `$HOME/.cpi-minimal` directory. Data and
//! state use the standard XDG variables with `$HOME/.local/...` fallbacks, and
//! every path is scoped by the application name.
const std = @import("std");

pub const ConfigDirectory = ".cpi-minimal";
pub const ApplicationName = "cpi-minimal";

pub const Paths = struct {
    a: std.mem.Allocator,
    home: []const u8,
    config: []const u8,
    data: []const u8,
    state: []const u8,

    pub fn init(a: std.mem.Allocator, env: *const std.process.Environ.Map) !Paths {
        const home = env.get("HOME") orelse ".";
        const config = try std.fs.path.join(a, &.{ home, ConfigDirectory });
        errdefer a.free(config);
        const data = try xdg(a, env, "XDG_DATA_HOME", home, ".local", "share");
        errdefer a.free(data);
        const state = try xdg(a, env, "XDG_STATE_HOME", home, ".local", "state");
        errdefer a.free(state);
        return .{
            .a = a,
            .home = home,
            .config = config,
            .data = data,
            .state = state,
        };
    }

    fn xdg(a: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, home: []const u8, fallback_a: []const u8, fallback_b: []const u8) ![]const u8 {
        if (env.get(name)) |value| {
            if (value.len > 0 and std.fs.path.isAbsolute(value)) {
                return std.fs.path.join(a, &.{ value, ApplicationName });
            }
        }
        return std.fs.path.join(a, &.{ home, fallback_a, fallback_b, ApplicationName });
    }

    pub fn configFile(self: Paths, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.config, name });
    }

    pub fn dataFile(self: Paths, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.data, name });
    }

    pub fn stateDirectory(self: Paths, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.state, name });
    }

    pub fn configPath(self: Paths) ![]const u8 {
        return self.configFile("config.conf");
    }

    pub fn modelsPath(self: Paths) ![]const u8 {
        return self.configFile("models.lua");
    }

    pub fn mcpPath(self: Paths) ![]const u8 {
        return self.configFile("mcp.lua");
    }

    pub fn skillsPath(self: Paths) ![]const u8 {
        return self.configFile("skills");
    }

    pub fn authPath(self: Paths) ![]const u8 {
        return self.dataFile("auth.conf");
    }

    /// Read-through compatibility for logins saved before credentials moved to data.
    pub fn legacyAuthPath(self: Paths, env: *const std.process.Environ.Map) ![]const u8 {
        if (env.get("XDG_CONFIG_HOME")) |root| {
            if (root.len > 0 and std.fs.path.isAbsolute(root)) return std.fs.path.join(self.a, &.{ root, "cpi", "auth.json" });
        }
        return std.fs.path.join(self.a, &.{ self.home, ".config", "cpi", "auth.json" });
    }

    pub fn sessionsPath(self: Paths) ![]const u8 {
        return self.stateDirectory("sessions");
    }
};
