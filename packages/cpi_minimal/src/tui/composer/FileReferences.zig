const std = @import("std");
const kit = @import("kit");
const Allocator = std.mem.Allocator;
const Item = kit.tui.select_list.Item;

fn separator(cp: u21) bool {
    if (cp < 0x80) return cp == ' ' or (cp >= 0x09 and cp <= 0x0d);
    return switch (cp) {
        0xfeff,
        '，',
        '．',
        '：',
        '；',
        '！',
        '？',
        '（',
        '）',
        '［',
        '］',
        '｛',
        '｝',
        '“',
        '”',
        '‘',
        '’',
        '…',
        '—',
        => true,
        else => switch (kit.unicode.generalCategory(cp)) {
            .separator_space, .separator_line, .separator_paragraph => true,
            else => |category| ((cp >= 0x3000 and cp <= 0x30ff) or (cp >= 0xfe10 and cp <= 0xfe4f) or
                (cp >= 0xff61 and cp <= 0xff65)) and std.mem.startsWith(u8, @tagName(category), "punctuation_"),
        },
    };
}

fn delimiter(cp: u21) bool {
    return cp == '"' or cp == '\'' or cp == '=' or separator(cp);
}

fn closer(byte: u8) ?u8 {
    return switch (byte) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        '`' => '`',
        else => null,
    };
}

fn unquotedStart(line: []const u8) usize {
    var start: usize = 0;
    var i: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(line[i..])) |decoded| {
        i += decoded.len;
        if (delimiter(decoded.codepoint)) start = i;
    }
    while (start < line.len) : (start += 1) {
        const close = closer(line[start]) orelse break;
        if (std.mem.indexOfScalar(u8, line[start + 1 ..], close) != null) break;
    }
    return start;
}

fn quotedStart(line: []const u8) ?usize {
    var quote: ?usize = null;
    for (line, 0..) |byte, i| {
        if (byte == '"') quote = if (quote == null) i else null;
    }
    const i = quote orelse return null;
    const start = if (i > 0 and line[i - 1] == '@') i - 1 else i;
    var boundary = start;
    while (boundary > 0 and closer(line[boundary - 1]) != null) boundary -= 1;
    if (boundary == 0) return start;
    var prev = boundary - 1;
    while (prev > 0 and line[prev] & 0xc0 == 0x80) prev -= 1;
    const decoded = kit.unicode.decodeUtf8Lossy(line[prev..boundary]) orelse return null;
    return if (delimiter(decoded.codepoint)) start else null;
}

pub fn referenceStart(line: []const u8) ?usize {
    if (quotedStart(line)) |start| {
        if (line[start] == '@') return start;
    }
    const start = unquotedStart(line);
    return if (start < line.len and line[start] == '@') start else null;
}

pub fn pathStart(line: []const u8) usize {
    return quotedStart(line) orelse unquotedStart(line);
}

pub fn needsQuotes(path: []const u8) bool {
    var offset: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(path[offset..])) |decoded| {
        if (separator(decoded.codepoint)) return true;
        offset += decoded.len;
    }
    return false;
}

pub fn canInsert(a: Allocator, path: []const u8) !bool {
    if (std.mem.indexOfAny(u8, path, "\n\"") != null) return false;
    const normalized = try kit.tui.Editor.normalize(a, path);
    defer a.free(normalized);
    return std.mem.eql(u8, path, normalized);
}

const Search = struct {
    directory: []const u8,
    query: []const u8,
    display_prefix: []const u8 = "",
};

fn searchLocation(a: Allocator, io: std.Io, cwd: []const u8, home: []const u8, query: []const u8) !Search {
    const search: Search = .{ .directory = cwd, .query = query };
    const slash = std.mem.lastIndexOfScalar(u8, query, '/') orelse return search;
    const prefix = query[0 .. slash + 1];
    const directory = if (std.mem.startsWith(u8, prefix, "~/"))
        try std.fs.path.join(a, &.{ home, prefix[2..] })
    else if (std.fs.path.isAbsolute(prefix))
        prefix
    else
        try std.fs.path.join(a, &.{ cwd, prefix });
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return search,
    };
    dir.close(io);
    return .{ .directory = directory, .query = query[slash + 1 ..], .display_prefix = prefix };
}

fn regex(a: Allocator, query: []const u8) ![]const u8 {
    var pattern: std.ArrayList(u8) = .empty;
    for (query) |byte| {
        if (std.mem.indexOfScalar(u8, ".*+?^${}()|[]\\", byte) != null) try pattern.append(a, '\\');
        try pattern.append(a, byte);
    }
    return pattern.items;
}

fn runFd(a: Allocator, io: std.Io, directory: []const u8, pattern: []const u8, shallow: bool, full_path: bool) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{
        "fd",        "--base-directory", directory,  "--max-results", "100",
        "--type",    "f",                "--type",   "d",             "--follow",
        "--hidden",  "--exclude",        ".git",     "--exclude",     ".git/*",
        "--exclude", ".git/**",          "--print0",
    });
    if (shallow) try argv.appendSlice(a, &.{ "--max-depth", "1" });
    if (full_path) try argv.append(a, "--full-path");
    try argv.appendSlice(a, &.{ "--", pattern });
    for ([_][]const u8{ "fd", "fdfind" }) |command| {
        argv.items[0] = command;
        const result = std.process.run(a, io, .{
            .argv = argv.items,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.Canceled, error.OutOfMemory => return err,
            else => return "",
        };
        return if (result.term == .exited and result.term.exited == 0) result.stdout else "";
    }
    return "";
}

const RankedPath = struct {
    path: []const u8,
    rank: u8,
    depth: usize,

    fn less(_: void, left: RankedPath, right: RankedPath) bool {
        if (left.rank != right.rank) return left.rank > right.rank;
        if (left.depth != right.depth) return left.depth < right.depth;
        if (left.path.len != right.path.len) return left.path.len < right.path.len;
        return std.ascii.orderIgnoreCase(left.path, right.path) == .lt;
    }
};

fn score(path: []const u8, name: []const u8, query: []const u8, directory: bool) u8 {
    if (query.len == 0) return 1;
    const rank: u8 = if (std.ascii.eqlIgnoreCase(name, query))
        100
    else if (std.ascii.startsWithIgnoreCase(name, query))
        80
    else if (std.ascii.findIgnoreCase(name, query) != null)
        50
    else if (std.ascii.findIgnoreCase(path, query) != null)
        30
    else
        return 0;
    return rank + (if (directory) @as(u8, 10) else 0);
}

pub fn suggestions(a: Allocator, io: std.Io, cwd: []const u8, home: []const u8, prefix: []const u8) ![]const Item {
    const quoted = std.mem.startsWith(u8, prefix, "@\"");
    const query = try a.dupe(u8, prefix[if (quoted) 2 else 1..]);
    std.mem.replaceScalar(u8, query, '\\', '/');
    const location = try searchLocation(a, io, cwd, home, query);
    const pattern = try regex(a, location.query);
    const full_path = std.mem.indexOfScalar(u8, location.query, '/') != null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var ranked: std.ArrayList(RankedPath) = .empty;
    for ([_]bool{ true, false }) |shallow| {
        const output = try runFd(a, io, location.directory, pattern, shallow, full_path);
        var entries = std.mem.tokenizeScalar(u8, output, 0);
        while (entries.next()) |entry| {
            const path = if (std.mem.startsWith(u8, entry, "./")) entry[2..] else entry;
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, '\\') != null or !try canInsert(a, path)) continue;
            const normalized = std.mem.trimEnd(u8, path, "/");
            if (normalized.len == 0) continue;
            var segments = std.mem.splitScalar(u8, normalized, '/');
            while (segments.next()) |segment| {
                if (std.mem.eql(u8, segment, ".git")) break;
            } else {
                const rank = score(path, std.fs.path.basename(normalized), location.query, normalized.len != path.len);
                if (rank != 0 and !(try seen.getOrPut(a, path)).found_existing)
                    try ranked.append(a, .{ .path = path, .rank = rank, .depth = std.mem.count(u8, normalized, "/") });
            }
        }
    }
    std.mem.sort(RankedPath, ranked.items, {}, RankedPath.less);
    const items = try a.alloc(Item, @min(ranked.items.len, 20));
    for (items, ranked.items[0..items.len]) |*item, entry| {
        const path = try std.fmt.allocPrint(a, "{s}{s}", .{ location.display_prefix, entry.path });
        const q = if (quoted or needsQuotes(path)) "\"" else "";
        const normalized = std.mem.trimEnd(u8, entry.path, "/");
        const name = std.fs.path.basename(normalized);
        item.* = .{
            .value = try std.fmt.allocPrint(a, "@{s}{s}{s}", .{ q, path, q }),
            .label = if (normalized.len == entry.path.len) name else try std.fmt.allocPrint(a, "{s}/", .{name}),
            .description = std.mem.trimEnd(u8, path, "/"),
        };
    }
    return items;
}
