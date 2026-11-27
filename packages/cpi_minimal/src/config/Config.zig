//! The optional user configuration file.
//!
//! `~/.cpi-minimal/config.conf` is deliberately a flat `key = value` file. It
//! has no sections, quoting, interpolation, or JSON. Blank lines and lines that
//! begin with `#` or `;` are ignored. Repeated `skill` and `env_file` keys
//! append; a repeated scalar key replaces the earlier value.
const std = @import("std");
const SizeSink = @import("session_protocol").Transaction.SizeSink;

pub const QuietStartup = enum { full, header, hidden };

pub const Config = struct {
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model_registry: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    context_window: ?u64 = null,
    reserve_tokens: ?u64 = null,
    keep_recent_tokens: ?u64 = null,
    background_compaction_tokens: ?u64 = null,
    max_output_tokens: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    thinking_levels: ?[]const u8 = null,
    provider_retries: ?u8 = null,
    provider_retry_delay_ms: ?u32 = null,
    provider_retry_max_delay_ms: ?u32 = null,
    mcp_config: ?[]const u8 = null,
    enable_skill_commands: ?bool = null,
    external_editor: ?[]const u8 = null,
    quiet_startup: QuietStartup = .full,
    skills: []const []const u8 = &.{},
    env_files: []const []const u8 = &.{},

    pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, required: bool, size_warnings: SizeSink) !Config {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => if (!required) return .{} else return err,
            else => return err,
        };
        size_warnings.report("configuration file bytes", data.len, 1024 * 1024);
        return parse(a, data);
    }

    pub fn parse(a: std.mem.Allocator, data: []const u8) !Config {
        var config: Config = .{};
        var skills: std.ArrayList([]const u8) = .empty;
        defer skills.deinit(a);
        var env_files: std.ArrayList([]const u8) = .empty;
        defer env_files.deinit(a);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
            const key = std.mem.trim(u8, line[0..equals], " \t");
            const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
            if (key.len == 0) return error.InvalidConfigLine;
            if (std.mem.eql(u8, key, "external_editor")) {
                config.external_editor = value;
                continue;
            }
            if (std.mem.eql(u8, key, "quiet_startup")) {
                config.quiet_startup = if (std.mem.eql(u8, value, "header"))
                    .header
                else if (try boolean(value))
                    .hidden
                else
                    .full;
                continue;
            }
            if (std.mem.eql(u8, key, "model")) config.model = value else if (std.mem.eql(u8, key, "base_url")) config.base_url = value else if (std.mem.eql(u8, key, "provider")) config.provider = value else if (std.mem.eql(u8, key, "model_registry")) config.model_registry = value else if (std.mem.eql(u8, key, "session_dir")) config.session_dir = value else if (std.mem.eql(u8, key, "reasoning_effort")) config.reasoning_effort = value else if (std.mem.eql(u8, key, "thinking_levels")) config.thinking_levels = value else if (std.mem.eql(u8, key, "mcp_config")) config.mcp_config = value else if (std.mem.eql(u8, key, "enable_skill_commands")) config.enable_skill_commands = try boolean(value) else if (std.mem.eql(u8, key, "context_window")) config.context_window = try positive(u64, value) else if (std.mem.eql(u8, key, "reserve_tokens")) config.reserve_tokens = try unsigned(u64, value) else if (std.mem.eql(u8, key, "keep_recent_tokens")) config.keep_recent_tokens = try positive(u64, value) else if (std.mem.eql(u8, key, "background_compaction_tokens")) config.background_compaction_tokens = try unsigned(u64, value) else if (std.mem.eql(u8, key, "max_output_tokens")) config.max_output_tokens = try positive(u32, value) else if (std.mem.eql(u8, key, "provider_retries")) config.provider_retries = try unsigned(u8, value) else if (std.mem.eql(u8, key, "provider_retry_delay_ms")) config.provider_retry_delay_ms = try unsigned(u32, value) else if (std.mem.eql(u8, key, "provider_retry_max_delay_ms")) config.provider_retry_max_delay_ms = try unsigned(u32, value) else if (std.mem.eql(u8, key, "skill")) {
                if (value.len == 0) return error.InvalidConfigValue;
                try skills.append(a, value);
            } else if (std.mem.eql(u8, key, "env_file")) {
                if (value.len == 0) return error.InvalidConfigValue;
                try env_files.append(a, value);
            } else return error.UnknownConfigKey;
        }
        config.skills = try skills.toOwnedSlice(a);
        errdefer a.free(config.skills);
        config.env_files = try env_files.toOwnedSlice(a);
        return config;
    }
};

fn boolean(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidConfigValue;
}

fn unsigned(comptime T: type, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10) catch error.InvalidConfigValue;
}

fn positive(comptime T: type, text: []const u8) !T {
    const value = try unsigned(T, text);
    if (value == 0) return error.InvalidConfigValue;
    return value;
}
