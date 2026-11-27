const std = @import("std");

pub const request_bytes = 1024 * 1024;
pub const response_bytes = 8 * 1024 * 1024;
pub const output_bytes = 64 * 1024;
pub const input_bytes = 64 * 1024;
pub const log_bytes = 64 * 1024 * 1024;

pub const Warning = struct { measurement: []const u8, actual: u64, expected: u64 };

pub const Report = struct {
    allocator: std.mem.Allocator,
    warnings: std.ArrayList(Warning) = .empty,

    fn record(self: *Report, warning: Warning) !void {
        for (self.warnings.items) |*prior| {
            if (std.mem.eql(u8, prior.measurement, warning.measurement) and prior.expected == warning.expected) {
                prior.actual = @max(prior.actual, warning.actual);
                return;
            }
        }
        try self.warnings.append(self.allocator, warning);
    }

    pub fn values(self: *const Report) ?[]const Warning {
        return if (self.warnings.items.len == 0) null else self.warnings.items;
    }
};

pub threadlocal var report: ?*Report = null;

pub fn warn(measurement: []const u8, actual: u64, expected: u64) void {
    if (actual <= expected) return;
    const warning: Warning = .{ .measurement = measurement, .actual = actual, .expected = expected };
    if (report) |sink| {
        sink.record(warning) catch log(warning);
    } else log(warning);
}

pub fn log(warning: Warning) void {
    std.log.scoped(.ghostmux_size).warn("{s} is {d}, above the expected {d}", .{ warning.measurement, warning.actual, warning.expected });
}

pub fn launch(argv: []const []const u8, env: []const []const u8, cwd: []const u8) void {
    warn("argument count", argv.len, 256);
    warn("working-directory bytes", cwd.len, 4096);
    warn("environment entries", env.len, 1024);
    var total_arguments: u64 = 0;
    var longest_argument: usize = 0;
    for (argv) |arg| {
        total_arguments +|= arg.len;
        longest_argument = @max(longest_argument, arg.len);
    }
    warn("total argument bytes", total_arguments, 256 * 1024);
    warn("longest argument bytes", longest_argument, 4096);
    var total_environment: u64 = 0;
    var longest_entry: usize = 0;
    for (env) |entry| {
        total_environment +|= entry.len;
        longest_entry = @max(longest_entry, entry.len);
    }
    warn("total environment bytes", total_environment, 256 * 1024);
    warn("longest environment entry bytes", longest_entry, 16384);
}
