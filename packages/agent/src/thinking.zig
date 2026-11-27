const std = @import("std");

pub const Level = enum { off, minimal, low, medium, high, xhigh, max, ultra };
pub const levels = std.enums.values(Level);
pub const Wire = union(enum) { unsupported, omitted, effort: []const u8 };
pub const Profile = struct {
    entries: [levels.len]Wire = @splat(.unsupported),

    pub fn supports(self: Profile, level: Level) bool {
        return self.entries[@backingInt(level)] != .unsupported;
    }
    pub fn wire(self: Profile, level: Level) !?[]const u8 {
        return switch (self.entries[@backingInt(level)]) {
            .unsupported => error.UnsupportedThinkingLevel,
            .omitted => null,
            .effort => |value| value,
        };
    }
    pub fn cycle(self: Profile, current: ?Level) !Level {
        const start = if (current) |value| @as(usize, @backingInt(value)) + 1 else 0;
        for (0..levels.len) |offset| {
            const level = levels[(start + offset) % levels.len];
            if (self.supports(level)) return level;
        }
        return error.UnknownThinkingCapabilities;
    }
    pub fn clamp(self: Profile, requested: Level) !Level {
        for (@backingInt(requested)..levels.len) |index| if (self.supports(levels[index])) return levels[index];
        var index: usize = @backingInt(requested);
        while (index > 0) {
            index -= 1;
            if (self.supports(levels[index])) return levels[index];
        }
        return error.UnknownThinkingCapabilities;
    }
};

pub fn parse(text: []const u8) !Level {
    if (std.ascii.eqlIgnoreCase(text, "none")) return .off;
    for (levels) |level| if (std.ascii.eqlIgnoreCase(text, @tagName(level))) return level;
    return error.InvalidThinkingLevel;
}

pub fn fromList(text: []const u8) !Profile {
    var profile: Profile = .{};
    var parts = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        const level = try parse(std.mem.trim(u8, part, " "));
        if (profile.supports(level)) return error.DuplicateThinkingLevel;
        profile.entries[@backingInt(level)] = .{ .effort = if (level == .off) "none" else @tagName(level) };
        count += 1;
    }
    if (count == 0) return error.UnknownThinkingCapabilities;
    return profile;
}
