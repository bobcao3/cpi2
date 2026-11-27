//! Small dotenv loader with no process-environment mutation.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const File = struct {
    path: []const u8,
    required: bool = true,
};

pub const Limits = struct {
    max_files: usize = 64,
    max_file_bytes: usize = 1024 * 1024,
    max_total_bytes: usize = 4 * 1024 * 1024,
    max_assignments: usize = 16384,
};

pub const Diagnostic = struct {
    file_index: ?usize = null,
    line: usize = 0,
    column: usize = 0,
};

pub const SizeSink = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, []const u8, usize, usize) void,
};

pub const Options = struct {
    /// Defaults to the process working directory.
    dir: ?Io.Dir = null,
    files: []const File = &.{},
    limits: Limits = .{},
    /// Receives threshold warnings. With no sink they go to the standard log.
    size_warnings: ?SizeSink = null,
    diagnostic: ?*Diagnostic = null,

    fn warnSize(self: Options, measurement: []const u8, actual: usize, threshold: usize) void {
        if (actual <= threshold) return;
        if (self.size_warnings) |sink| {
            sink.notify(sink.context, measurement, actual, threshold);
        } else {
            std.log.warn("{s} is {d}, above the expected {d}", .{ measurement, actual, threshold });
        }
    }
};

pub const Error = error{
    InvalidPath,
    FileNotFound,
    FileUnavailable,
    NotRegularFile,
    InvalidSyntax,
    InvalidEncoding,
};

/// Returns a fully owned map. Later files override earlier files. Process
/// variables override every file value, including empty values. On error no
/// map is returned and all allocations made here are freed.
pub fn load(
    allocator: Allocator,
    io: Io,
    process_environment: *const std.process.Environ.Map,
    options: Options,
) (Error || Allocator.Error)!std.process.Environ.Map {
    const diagnostic = options.diagnostic;
    if (diagnostic) |out| out.* = .{};
    const limits = options.limits;
    options.warnSize("dotenv files", options.files.len, limits.max_files);
    const dir = options.dir orelse Io.Dir.cwd();
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var total: usize = 0;
    var assignments: usize = 0;
    for (options.files, 0..) |file, index| {
        if (diagnostic) |out| out.* = .{ .file_index = index };
        const bytes = readFile(allocator, io, dir, file.path) catch |err| switch (err) {
            error.FileNotFound => {
                if (file.required) return error.FileNotFound;
                continue;
            },
            else => return err,
        };
        defer allocator.free(bytes);
        options.warnSize("dotenv file bytes", bytes.len, limits.max_file_bytes);
        total +|= bytes.len;
        var content = bytes;
        if (std.mem.startsWith(u8, content, "\xef\xbb\xbf")) content = content[3..];
        if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidEncoding;
        if (std.mem.findScalar(u8, content, 0) != null) return error.InvalidEncoding;
        try parse(allocator, &map, content, &assignments, diagnostic);
    }
    options.warnSize("dotenv total bytes", total, limits.max_total_bytes);
    options.warnSize("dotenv assignments", assignments, limits.max_assignments);
    try map.putAll(process_environment);
    if (diagnostic) |out| out.* = .{};
    return map;
}

fn readFile(allocator: Allocator, io: Io, dir: Io.Dir, path: []const u8) (Error || Allocator.Error)![]u8 {
    if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
    const handle: Io.File = if (builtin.os.tag == .windows)
        dir.openFile(io, path, .{ .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.IsDir => return error.NotRegularFile,
            else => return error.FileUnavailable,
        }
    else blk: {
        const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true };
        const fd = std.posix.openat(dir.handle, path, flags, 0) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.FileUnavailable,
        };
        break :blk .{ .handle = fd, .flags = .{ .nonblocking = true } };
    };
    defer handle.close(io);
    const stat = handle.stat(io) catch return error.FileUnavailable;
    if (stat.kind != .file) return error.NotRegularFile;
    var buffer: [4096]u8 = undefined;
    var reader = handle.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.StreamTooLong => error.OutOfMemory,
        error.ReadFailed => error.FileUnavailable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn parse(
    allocator: Allocator,
    map: *std.process.Environ.Map,
    content: []const u8,
    assignments: *usize,
    diagnostic: ?*Diagnostic,
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        parseLine(allocator, map, line, assignments, diagnostic) catch |err| {
            if (diagnostic) |out| {
                out.line = line_number;
                if (out.column == 0) out.column = 1;
            }
            return err;
        };
    }
}

fn parseLine(
    allocator: Allocator,
    map: *std.process.Environ.Map,
    line: []const u8,
    assignments: *usize,
    diagnostic: ?*Diagnostic,
) !void {
    var index: usize = 0;
    skipSpace(line, &index);
    if (index == line.len or line[index] == '#') return;
    if (std.mem.startsWith(u8, line[index..], "export") and
        index + 6 < line.len and isSpace(line[index + 6]))
    {
        index += 6;
        skipSpace(line, &index);
    }
    const key_start = index;
    if (index == line.len or !isNameStart(line[index])) return fail(diagnostic, index, error.InvalidSyntax);
    index += 1;
    while (index < line.len and isNameChar(line[index])) index += 1;
    const key = line[key_start..index];
    skipSpace(line, &index);
    if (index == line.len or line[index] != '=') return fail(diagnostic, index, error.InvalidSyntax);
    index += 1;
    skipSpace(line, &index);

    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(allocator);
    const value: []const u8 = if (index < line.len and line[index] == '\'') blk: {
        const start = index + 1;
        var end = start;
        while (end < line.len and line[end] != '\'') : (end += 1) {
            if (line[end] == 0) return fail(diagnostic, end, error.InvalidEncoding);
        }
        if (end == line.len) return fail(diagnostic, end, error.InvalidSyntax);
        index = end + 1;
        skipSpace(line, &index);
        if (index < line.len and line[index] != '#') return fail(diagnostic, index, error.InvalidSyntax);
        break :blk line[start..end];
    } else if (index < line.len and line[index] == '"') blk: {
        index += 1;
        while (index < line.len) {
            const byte = line[index];
            if (byte == '"') {
                index += 1;
                break;
            }
            if (byte == '\\') {
                index += 1;
                if (index == line.len) return fail(diagnostic, index, error.InvalidSyntax);
                const escaped: u8 = switch (line[index]) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => return fail(diagnostic, index, error.InvalidSyntax),
                };
                quoted.append(allocator, escaped) catch return error.OutOfMemory;
                index += 1;
                continue;
            }
            if (byte == 0) return fail(diagnostic, index, error.InvalidEncoding);
            quoted.append(allocator, byte) catch return error.OutOfMemory;
            index += 1;
        } else return fail(diagnostic, line.len, error.InvalidSyntax);
        skipSpace(line, &index);
        if (index < line.len and line[index] != '#') return fail(diagnostic, index, error.InvalidSyntax);
        break :blk quoted.items;
    } else blk: {
        const start = index;
        while (index < line.len) {
            if (line[index] == '#' and (index == start or isSpace(line[index - 1]))) break;
            index += 1;
        }
        break :blk std.mem.trimEnd(u8, line[start..index], " \t");
    };
    assignments.* +|= 1;
    map.put(key, value) catch return error.OutOfMemory;
}

fn fail(diagnostic: ?*Diagnostic, column: usize, err: Error) Error {
    if (diagnostic) |out| out.column = column + 1;
    return err;
}

fn skipSpace(line: []const u8, index: *usize) void {
    while (index.* < line.len and isSpace(line[index.*])) index.* += 1;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isNameStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn isNameChar(byte: u8) bool {
    return isNameStart(byte) or (byte >= '0' and byte <= '9');
}
