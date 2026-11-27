//! Read-only adapters for Minimal's directory and search tools.
const std = @import("std");
const services = @import("services");
const unicode = @import("kit").unicode;
const j = @import("../json.zig");
const Io = std.Io;
const A = std.mem.Allocator;
const Self = @This();
const max_bytes = 50 * 1024;

environment: *const std.process.Environ.Map,

const ListArgs = struct { path: []const u8, limit: ?f64 = null };
const FindArgs = struct { path: []const u8, pattern: []const u8, limit: ?f64 = null };
const GrepArgs = struct {
    path: []const u8,
    pattern: []const u8,
    glob: ?[]const u8 = null,
    ignoreCase: bool = false,
    literal: bool = false,
    context: ?f64 = null,
    limit: ?f64 = null,
};

const Truncation = struct {
    content: []const u8,
    truncated: bool = true,
    truncatedBy: []const u8 = "bytes",
    totalLines: usize,
    totalBytes: usize,
    outputLines: usize,
    outputBytes: usize,
    lastLinePartial: bool = false,
    firstLineExceedsLimit: bool,
    maxLines: u64 = 9007199254740991,
    maxBytes: usize = max_bytes,
};
const Details = struct {
    truncation: ?Truncation = null,
    entryLimitReached: ?u64 = null,
    resultLimitReached: ?u64 = null,
    matchLimitReached: ?u64 = null,
    linesTruncated: ?bool = null,
};
const Result = struct {
    text: []const u8,
    is_error: bool = false,
    details: ?Details = null,

    fn fail(text: []const u8) Result {
        return .{ .text = text, .is_error = true };
    }
};

const budgets: services.Operation.Limits = .{ .arguments = 128 * 1024, .result = 512 * 1024 };
const ls_op = services.Operation.define("workspace.ls", Self, ListArgs, Result, budgets, .read_only, list);
const find_op = services.Operation.define("workspace.find", Self, FindArgs, Result, budgets, .read_only, find);
const grep_op = services.Operation.define("workspace.grep", Self, GrepArgs, Result, budgets, .read_only, grep);

pub fn service(self: *Self) services.Service {
    return .{ .context = self, .operations = &.{ &ls_op, &find_op, &grep_op } };
}

const Output = struct {
    retained: std.ArrayList(u8) = .empty,
    count: usize = 0,
    bytes: usize = 0,
    retained_lines: usize = 0,

    fn line(self: *Output, a: A, text: []const u8) !void {
        self.bytes += text.len + @intFromBool(self.count > 0);
        self.count += 1;
        if (self.bytes > max_bytes) return;
        if (self.retained_lines > 0) try self.retained.append(a, '\n');
        try self.retained.appendSlice(a, text);
        self.retained_lines += 1;
    }

    fn finish(self: Output, a: A, details: Details, notice: ?[]const u8) !Result {
        var out_details = details;
        const text = self.retained.items;
        if (self.bytes > max_bytes) out_details.truncation = .{
            .content = text,
            .totalLines = self.count,
            .totalBytes = self.bytes,
            .outputLines = self.retained_lines,
            .outputBytes = text.len,
            .firstLineExceedsLimit = self.retained_lines == 0,
        };
        var notices: std.ArrayList([]const u8) = .empty;
        if (notice) |part| try notices.append(a, part);
        if (out_details.truncation != null) try notices.append(a, "50.0KB limit reached");
        if (out_details.linesTruncated == true) try notices.append(a, "Some lines truncated to 500 chars. Use read tool to see full lines");
        if (notices.items.len == 0) return .{ .text = text };
        return .{
            .text = try std.fmt.allocPrint(a, "{s}\n\n[{s}]", .{ text, try std.mem.join(a, ". ", notices.items) }),
            .details = out_details,
        };
    }
};

fn clamp(value: ?f64, fallback: u64, minimum: u64) u64 {
    const number = value orelse return fallback;
    if (std.math.isNan(number)) return fallback;
    return @max(minimum, if (number <= 0) 0 else @as(u64, @intFromFloat(@min(number, 9007199254740991))));
}

fn missing(a: A, path: []const u8) !Result {
    return .fail(try std.fmt.allocPrint(a, "Path not found: {s}", .{path}));
}

fn stat(c: services.Context, path: []const u8) !?Io.File.Stat {
    return Io.Dir.cwd().statFile(c.io, path, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
}

fn list(_: *Self, c: services.Context, args: ListArgs) !Result {
    const a = c.allocator;
    const info = (try stat(c, args.path)) orelse return missing(a, args.path);
    if (info.kind != .directory) return .fail(try std.fmt.allocPrint(a, "Not a directory: {s}", .{args.path}));
    var dir = Io.Dir.cwd().openDir(c.io, args.path, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return .fail(try std.fmt.allocPrint(a, "Cannot read directory: {s}", .{@errorName(err)})),
    };
    defer dir.close(c.io);
    var entries: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(c.io)) |entry| try entries.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, entries.items, {}, lessName);
    var out: Output = .{};
    const limit = clamp(args.limit, 500, 1);
    var hit = false;
    for (entries.items) |name| {
        try c.io.checkCancel();
        if (out.count >= limit) {
            hit = true;
            break;
        }
        const info_entry = dir.statFile(c.io, name, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        const clean = try validText(a, name);
        try out.line(a, if (info_entry.kind == .directory) try std.mem.concat(a, u8, &.{ clean, "/" }) else clean);
    }
    if (out.count == 0) return .{ .text = "(empty directory)" };
    return out.finish(a, .{ .entryLimitReached = if (hit) limit else null }, if (hit)
        try std.fmt.allocPrint(a, "{d} entries limit reached. Use limit={d} for more", .{ limit, limit * 2 })
    else
        null);
}

fn lessName(_: void, left: []const u8, right: []const u8) bool {
    return std.ascii.orderIgnoreCase(left, right) == .lt;
}

fn find(self: *Self, c: services.Context, args: FindArgs) !Result {
    const a = c.allocator;
    const limit = clamp(args.limit, 1000, 1);
    const pattern = stripDot(args.pattern);
    const full_path = std.mem.indexOfScalar(u8, pattern, '/') != null;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "fd", "--color=never", "--hidden" });
    if (!try insideGit(c, args.path)) try argv.append(a, "--no-require-git");
    try argv.appendSlice(a, &.{ "--glob", "--max-results", try std.fmt.allocPrint(a, "{d}", .{limit + 1}) });
    if (full_path) try argv.append(a, "--full-path");
    var glob = pattern;
    if (full_path and !std.fs.path.isAbsolute(pattern)) {
        glob = try anchoredGlob(a, args.path, pattern);
        if (lowercase(pattern)) try argv.append(a, "--ignore-case");
    }
    try argv.appendSlice(a, &.{ "--", glob, args.path });
    var found: Find = .{ .root = args.path, .limit = limit };
    const outcome: SearchResult = self.search(c, argv.items, null, &found) catch |err| switch (err) {
        error.FileNotFound => .{ .failure = "fd is not available" },
        else => return err,
    };
    if (found.output.count == 0) return if (outcome.failure) |error_text| .fail(error_text) else .{ .text = "No files found matching pattern" };
    return found.output.finish(a, .{ .resultLimitReached = if (found.hit) limit else null }, if (found.hit)
        try std.fmt.allocPrint(a, "{d} results limit reached. Use limit={d} for more, or refine pattern", .{ limit, limit * 2 })
    else
        null);
}

fn insideGit(c: services.Context, path: []const u8) !bool {
    var current: ?[]const u8 = path;
    while (current) |dir| : (current = std.fs.path.dirname(dir)) {
        const candidate = try std.fs.path.join(c.allocator, &.{ dir, ".git" });
        if (try stat(c, candidate) != null) return true;
    }
    return false;
}

fn anchoredGlob(a: A, root: []const u8, pattern: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trimEnd(u8, root, "/")) |byte| {
        if (std.mem.indexOfScalar(u8, "\\*?[]{}", byte) != null) try out.append(a, '\\');
        try out.append(a, byte);
    }
    try out.append(a, '/');
    try out.appendSlice(a, pattern);
    return out.items;
}

fn stripDot(text: []const u8) []const u8 {
    var rest = text;
    while (std.mem.startsWith(u8, rest, "./")) rest = rest[2..];
    return rest;
}

fn lowercase(text: []const u8) bool {
    for (text) |byte| if (std.ascii.isUpper(byte)) return false;
    return true;
}

fn grep(self: *Self, c: services.Context, args: GrepArgs) !Result {
    const a = c.allocator;
    const info = (try stat(c, args.path)) orelse return missing(a, args.path);
    const directory = info.kind == .directory;
    const limit = clamp(args.limit, 100, 1);
    const context = clamp(args.context, 0, 0);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "rg", "--no-config", "--json", "--line-number", "--color=never", "--hidden" });
    if (args.ignoreCase) try argv.append(a, "--ignore-case");
    if (args.literal) try argv.append(a, "--fixed-strings");
    if (args.glob) |glob| if (glob.len != 0) {
        const cleaned = if (glob[0] == '!') try std.mem.concat(a, u8, &.{ "!", stripDot(glob[1..]) }) else stripDot(glob);
        try argv.appendSlice(a, &.{ "--glob", cleaned });
    };
    if (context > 0) try argv.appendSlice(a, &.{ "--context", try std.fmt.allocPrint(a, "{d}", .{context}) });
    try argv.appendSlice(a, &.{ "--", args.pattern, if (directory) "." else args.path });
    var found: Grep = .{ .directory = directory, .limit = limit, .context = context };
    const outcome: SearchResult = self.search(c, argv.items, if (directory) args.path else null, &found) catch |err| switch (err) {
        error.FileNotFound => .{ .failure = "ripgrep (rg) is not available" },
        else => return err,
    };
    if (outcome.failure) |error_text| return .fail(error_text);
    if (found.matches == 0) return .{ .text = "No matches found" };
    return found.output.finish(a, .{
        .matchLimitReached = if (found.hit) limit else null,
        .linesTruncated = if (found.lines_truncated) true else null,
    }, if (found.hit)
        try std.fmt.allocPrint(a, "{d} matches limit reached. Use limit={d} for more, or refine pattern", .{ limit, limit * 2 })
    else
        null);
}

const Find = struct {
    root: []const u8,
    limit: u64,
    output: Output = .{},
    hit: bool = false,
    const no_match_status: u32 = 0;

    fn line(self: *Find, a: A, scratch: A, raw: []const u8) !bool {
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) return false;
        if (self.output.count == self.limit) {
            self.hit = true;
            return true;
        }
        const path = if (std.fs.path.isAbsolute(text)) try std.fs.path.relativeAlloc(scratch, self.root, null, self.root, text) else text;
        const format = if (std.mem.endsWith(u8, text, "/") and !std.mem.endsWith(u8, path, "/")) try std.mem.concat(scratch, u8, &.{ path, "/" }) else path;
        try self.output.line(a, try validText(scratch, format));
        return false;
    }
};

const Grep = struct {
    directory: bool,
    limit: u64,
    context: u64,
    output: Output = .{},
    matches: u64 = 0,
    last_path: std.ArrayList(u8) = .empty,
    trailing_end: u64 = 0,
    lines_truncated: bool = false,
    hit: bool = false,
    const no_match_status: u32 = 1;

    fn line(self: *Grep, a: A, scratch: A, raw: []const u8) !bool {
        const event = std.json.parseFromSliceLeaky(j.Value, scratch, raw, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        const match = j.equal(j.get(event, "type"), "match");
        if (!match and !j.equal(j.get(event, "type"), "context")) return false;
        const data = j.get(event, "data");
        const file = try eventText(scratch, j.get(data, "path"));
        const number = j.number(j.get(data, "line_number"));
        if (file.len == 0 or number == 0) return false;
        const capped = self.matches == self.limit;
        const trailing = std.mem.eql(u8, file, self.last_path.items) and number <= self.trailing_end;
        if (!capped or trailing) {
            const text = try eventText(scratch, j.get(data, "lines"));
            var trimmed = text;
            if (std.mem.endsWith(u8, trimmed, "\n")) trimmed = trimmed[0 .. trimmed.len - 1];
            if (std.mem.endsWith(u8, trimmed, "\r")) trimmed = trimmed[0 .. trimmed.len - 1];
            const head = utf16Prefix(trimmed, 500);
            self.lines_truncated = self.lines_truncated or head.len < trimmed.len;
            const label = if (self.directory) stripDot(file) else std.fs.path.basename(file);
            const separator: u8 = if (match and !capped) ':' else '-';
            try self.output.line(a, try std.fmt.allocPrint(scratch, "{s}{c}{d}{c} {s}{s}", .{
                label, separator, number, separator, head, if (head.len < trimmed.len) "... [truncated]" else "",
            }));
        }
        if (capped) {
            self.hit = self.hit or match;
            return self.hit and !(trailing and number < self.trailing_end);
        }
        if (match) {
            self.matches += 1;
            if (self.matches == self.limit) {
                try self.last_path.appendSlice(a, file);
                self.trailing_end = number +| self.context;
            }
        }
        return false;
    }
};

fn eventText(a: A, part: j.Value) ![]const u8 {
    if (j.get(part, "text") == .string) return j.text(j.get(part, "text"));
    const encoded = j.text(j.get(part, "bytes"));
    const decoder = std.base64.standard.Decoder;
    const decoded = try a.alloc(u8, decoder.calcSizeForSlice(encoded) catch return "");
    decoder.decode(decoded, encoded) catch return "";
    return validText(a, decoded);
}

fn utf16Prefix(text: []const u8, max: usize) []const u8 {
    var offset: usize = 0;
    var units: usize = 0;
    while (unicode.decodeUtf8Lossy(text[offset..])) |part| {
        units += if (part.codepoint > 0xffff) @as(usize, 2) else 1;
        if (units > max) break;
        offset += part.len;
    }
    return text[0..offset];
}

fn validText(a: A, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var text: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (unicode.decodeUtf8Lossy(bytes[offset..])) |part| {
        try text.appendSlice(a, if (part.valid) bytes[offset..][0..part.len] else "\xef\xbf\xbd");
        offset += part.len;
    }
    return text.items;
}

const SearchResult = struct { failure: ?[]const u8 = null };

fn search(self: *Self, c: services.Context, argv: [][]const u8, cwd: ?[]const u8, parser: anytype) !SearchResult {
    const a = c.allocator;
    const io = c.io;
    const args: std.process.SpawnOptions = .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = self.environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    };
    var child = std.process.spawn(io, args) catch |err| blk: {
        if (err != error.FileNotFound or !std.mem.eql(u8, argv[0], "fd")) return err;
        argv[0] = "fdfind";
        break :blk try std.process.spawn(io, args);
    };
    defer child.kill(io);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var storage: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const stdout = reader.reader(0);
    const stderr = reader.reader(1);
    var diagnostics: std.ArrayList(u8) = .empty;
    while (true) {
        const more = blk: {
            reader.fill(8192, .none) catch |err| switch (err) {
                error.EndOfStream => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        const bytes = stderr.buffered();
        try diagnostics.appendSlice(a, bytes[0..@min(bytes.len, 8192 - diagnostics.items.len)]);
        stderr.toss(bytes.len);
        while (stdout.buffered().len != 0) {
            const contents = stdout.buffered();
            const newline = std.mem.indexOfScalar(u8, contents, '\n');
            if (newline == null and more) break;
            _ = scratch.reset(.{ .retain_with_limit = 128 * 1024 });
            if (try parser.line(a, scratch.allocator(), contents[0 .. newline orelse contents.len])) return .{};
            stdout.toss(if (newline) |end| end + 1 else contents.len);
        }
        if (!more) break;
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| if (code == 0 or code == @TypeOf(parser.*).no_match_status) .{} else .{
            .failure = if (diagnostics.items.len != 0)
                try validText(a, std.mem.trim(u8, diagnostics.items, " \t\r\n"))
            else
                try std.fmt.allocPrint(a, "{s} exited with code {d}", .{ argv[0], code }),
        },
        else => .{ .failure = try std.fmt.allocPrint(a, "{s} terminated", .{argv[0]}) },
    };
}
