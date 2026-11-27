const std = @import("std");
const j = @import("../json.zig");
const Value = j.Value;

/// Provider usage normalized the way Pi reports it. Responses include cached
/// and cache-write tokens in `input_tokens`; the displayed input excludes them.
pub const Counts = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    pub fn prompt(self: @This()) u64 {
        return self.input +| self.cache_read +| self.cache_write;
    }

    pub fn cacheHitRate(self: @This()) ?f64 {
        const total = self.prompt();
        if (total == 0) return null;
        return @as(f64, @floatFromInt(self.cache_read)) / @as(f64, @floatFromInt(total)) * 100;
    }
};

pub const Stats = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    /// Latest conversational call's rate, unknown without input and cache counts.
    cache_hit_rate: ?f64 = null,

    pub fn addSpend(self: *Stats, spend: Stats) void {
        self.input +|= spend.input;
        self.output +|= spend.output;
        self.cache_read +|= spend.cache_read;
        self.cache_write +|= spend.cache_write;
        self.total_tokens +|= spend.total_tokens;
        self.reasoning_tokens +|= spend.reasoning_tokens;
    }
};

pub fn normalize(raw: Value) ?Counts {
    if (raw != .object) return null;
    const details = j.get(raw, "input_tokens_details");
    const cache_read = j.number(j.get(details, "cached_tokens"));
    const cache_write = j.number(j.get(details, "cache_write_tokens"));
    return .{
        .input = j.number(j.get(raw, "input_tokens")) -| (cache_read +| cache_write),
        .output = j.number(j.get(raw, "output_tokens")),
        .cache_read = cache_read,
        .cache_write = cache_write,
    };
}

/// Add one response's raw usage. `latest` updates the cache-hit rate from this
/// response; callers that scan newest first pass it only for the first response.
pub fn add(stats: *Stats, raw: Value, latest: bool) void {
    if (latest) stats.cache_hit_rate = null;
    const counts = normalize(raw) orelse return;
    stats.input +|= counts.input;
    stats.output +|= counts.output;
    stats.cache_read +|= counts.cache_read;
    stats.cache_write +|= counts.cache_write;
    stats.total_tokens +|= if (j.get(raw, "total_tokens") == .integer) j.number(j.get(raw, "total_tokens")) else j.number(j.get(raw, "input_tokens")) +| counts.output;
    stats.reasoning_tokens +|= j.number(j.get(j.get(raw, "output_tokens_details"), "reasoning_tokens"));
    if (latest) {
        const usage: @import("agent").openai.Usage = .{
            .input_tokens = optionalCount(raw, "input_tokens"),
            .cache_read_tokens = optionalCount(j.get(raw, "input_tokens_details"), "cached_tokens"),
        };
        stats.cache_hit_rate = usage.cacheHitRate();
    }
}

fn optionalCount(raw: Value, key: []const u8) ?u64 {
    const value = j.get(raw, key);
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else null;
}

/// Fold committed application history newest first, independently of the selected path.
pub fn addEntry(stats: *Stats, entry: Value, latest: *bool) void {
    const response = j.equal(j.get(entry, "kind"), "response");
    const model_result = j.equal(j.get(entry, "kind"), "model_result");
    if (!response and !model_result) {
        if (j.equal(j.get(entry, "kind"), "checkpoint") or j.equal(j.get(entry, "kind"), "branch_summary"))
            add(stats, j.get(entry, "summary_usage"), false);
        return;
    }
    const conversational = response or j.equal(j.get(entry, "purpose"), "conversation");
    const newest = conversational and latest.*;
    if (conversational) latest.* = false;
    if (newest) stats.cache_hit_rate = null;
    const raw = j.get(entry, "usage");
    if (!j.equal(j.get(entry, "usage_format"), "openai.Result")) {
        add(stats, raw, newest);
        return;
    }
    addModelResult(stats, raw, newest);
}

fn addModelResult(stats: *Stats, raw: Value, newest: bool) void {
    if (raw != .object) return;
    const usage: @import("agent").openai.Usage = .{
        .input_tokens = optionalCount(raw, "input_tokens"),
        .output_tokens = optionalCount(raw, "output_tokens"),
        .total_tokens = optionalCount(raw, "total_tokens"),
        .cache_read_tokens = optionalCount(raw, "cache_read_tokens"),
        .cache_write_tokens = optionalCount(raw, "cache_write_tokens"),
        .reasoning_tokens = optionalCount(raw, "reasoning_tokens"),
    };
    stats.input +|= usage.uncachedInputTokens() orelse 0;
    stats.output +|= usage.output_tokens orelse 0;
    stats.cache_read +|= usage.cache_read_tokens orelse 0;
    stats.cache_write +|= usage.cache_write_tokens orelse 0;
    stats.total_tokens +|= usage.total_tokens orelse ((usage.input_tokens orelse 0) +| (usage.output_tokens orelse 0));
    stats.reasoning_tokens +|= usage.reasoning_tokens orelse 0;
    if (newest) stats.cache_hit_rate = usage.cacheHitRate();
}

/// The source journal already counts its detached provider results. A fork
/// carries only successful summary usage through the copied checkpoint.
pub fn forkedCompactionUsage(a: std.mem.Allocator, parts: Value) !?Value {
    if (parts != .object) return null;
    var stats: Stats = .{};
    for (parts.object.values()) |part| addModelResult(&stats, part, false);
    return try encodeSpend(a, stats);
}

pub fn encodeSpend(a: std.mem.Allocator, stats: Stats) !Value {
    return j.value(a, .{
        .input_tokens = stats.input +| stats.cache_read +| stats.cache_write,
        .output_tokens = stats.output,
        .total_tokens = stats.total_tokens,
        .input_tokens_details = .{ .cached_tokens = stats.cache_read, .cache_write_tokens = stats.cache_write },
        .output_tokens_details = .{ .reasoning_tokens = stats.reasoning_tokens },
    });
}

/// Pi's compact token formatting for footer statistics.
pub fn formatTokens(a: std.mem.Allocator, count: u64) ![]const u8 {
    if (count < 1000) return std.fmt.allocPrint(a, "{d}", .{count});
    if (count < 10000) return std.fmt.allocPrint(a, "{d:.1}k", .{@as(f64, @floatFromInt(count)) / 1000});
    if (count < 1000000) return std.fmt.allocPrint(a, "{d}k", .{(count + 500) / 1000});
    if (count < 10000000) return std.fmt.allocPrint(a, "{d:.1}M", .{@as(f64, @floatFromInt(count)) / 1000000});
    return std.fmt.allocPrint(a, "{d}M", .{(count + 500000) / 1000000});
}

/// Compact used/window counts for the context segment, e.g. `24.7K` and `1M`.
pub fn formatCompact(a: std.mem.Allocator, count: u64) ![]const u8 {
    if (count < 1000) return std.fmt.allocPrint(a, "{d}", .{count});
    if (count < 1000000) {
        if (count % 1000 == 0) return std.fmt.allocPrint(a, "{d}K", .{count / 1000});
        if (count < 100000) return std.fmt.allocPrint(a, "{d:.1}K", .{@as(f64, @floatFromInt(count)) / 1000});
        return std.fmt.allocPrint(a, "{d}K", .{(count + 500) / 1000});
    }
    if (count % 1000000 == 0) return std.fmt.allocPrint(a, "{d}M", .{count / 1000000});
    if (count < 10000000) return std.fmt.allocPrint(a, "{d:.1}M", .{@as(f64, @floatFromInt(count)) / 1000000});
    return std.fmt.allocPrint(a, "{d}M", .{(count + 500000) / 1000000});
}

/// The native Pi stats segment: input, output, cache read/write, and the
/// newest cache-hit rate. Parts with no usage are omitted.
pub fn summary(a: std.mem.Allocator, stats: Stats) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (stats.input > 0) {
        const tokens = try formatTokens(a, stats.input);
        defer a.free(tokens);
        try out.writer.print("↑{s}", .{tokens});
    }
    if (stats.output > 0) {
        if (out.written().len > 0) try out.writer.writeByte(' ');
        const tokens = try formatTokens(a, stats.output);
        defer a.free(tokens);
        try out.writer.print("↓{s}", .{tokens});
    }
    if (stats.cache_read > 0) {
        if (out.written().len > 0) try out.writer.writeByte(' ');
        const tokens = try formatTokens(a, stats.cache_read);
        defer a.free(tokens);
        try out.writer.print("R{s}", .{tokens});
    }
    if (stats.cache_write > 0) {
        if (out.written().len > 0) try out.writer.writeByte(' ');
        const tokens = try formatTokens(a, stats.cache_write);
        defer a.free(tokens);
        try out.writer.print("W{s}", .{tokens});
    }
    if ((stats.cache_read > 0 or stats.cache_write > 0) and stats.cache_hit_rate != null) {
        if (out.written().len > 0) try out.writer.writeByte(' ');
        try out.writer.print("CH{d:.1}%", .{stats.cache_hit_rate.?});
    }
    return out.toOwnedSlice();
}
