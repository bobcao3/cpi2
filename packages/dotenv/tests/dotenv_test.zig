const std = @import("std");
const builtin = @import("builtin");
const dotenv = @import("dotenv");

const a = std.testing.allocator;
const io = std.testing.io;

fn loadTest(dir: std.Io.Dir, files: []const dotenv.File, limits: dotenv.Limits) !std.process.Environ.Map {
    var process = std.process.Environ.Map.init(a);
    defer process.deinit();
    return dotenv.load(a, io, &process, .{ .dir = dir, .files = files, .limits = limits });
}

test "dialect covers BOM CRLF comments export quoting escapes and duplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "sample.env",
        .data = "\xef\xbb\xbf# leading comment\r\n" ++
            "A=plain\r\n" ++
            "export B = spaced value  \r\n" ++
            "C='single # literal'\r\n" ++
            "D=\"line\\nquote\\\"tab\\t\"\r\n" ++
            "EMPTY=\r\n" ++
            "HASH=before # trailing comment\r\n" ++
            "LITERAL_HASH=a#b\r\n" ++
            "BACKSLASH=one\\two\r\n" ++
            "DUP=first\r\n" ++
            "DUP=second\r\n",
    });
    var env = try loadTest(tmp.dir, &.{.{ .path = "sample.env" }}, .{});
    defer env.deinit();
    try std.testing.expectEqualStrings("plain", env.get("A").?);
    try std.testing.expectEqualStrings("spaced value", env.get("B").?);
    try std.testing.expectEqualStrings("single # literal", env.get("C").?);
    try std.testing.expectEqualStrings("line\nquote\"tab\t", env.get("D").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expectEqualStrings("before", env.get("HASH").?);
    try std.testing.expectEqualStrings("a#b", env.get("LITERAL_HASH").?);
    try std.testing.expectEqualStrings("one\\two", env.get("BACKSLASH").?);
    try std.testing.expectEqualStrings("second", env.get("DUP").?);
}

test "process environment wins including an empty value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.env", .data = "A=file\nEMPTY=file\nONLY_FILE=yes\n" });
    var process = std.process.Environ.Map.init(a);
    defer process.deinit();
    try process.put("A", "process");
    try process.put("EMPTY", "");
    var env = try dotenv.load(a, io, &process, .{ .dir = tmp.dir, .files = &.{.{ .path = "a.env" }} });
    defer env.deinit();
    try std.testing.expectEqualStrings("process", env.get("A").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expectEqualStrings("yes", env.get("ONLY_FILE").?);
}

test "later files win and optional missing files are skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.env", .data = "A=one\nB=one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.env", .data = "A=two\n" });
    var env = try loadTest(tmp.dir, &.{
        .{ .path = "missing.env", .required = false },
        .{ .path = "one.env" },
        .{ .path = "two.env" },
    }, .{});
    defer env.deinit();
    try std.testing.expectEqualStrings("two", env.get("A").?);
    try std.testing.expectEqualStrings("one", env.get("B").?);
}

test "required missing malformed later file and diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "good.env", .data = "A=one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.env", .data = "B=one\nnot an assignment\n" });
    try std.testing.expectError(error.FileNotFound, loadTest(tmp.dir, &.{.{ .path = "missing.env" }}, .{}));
    var diagnostic: dotenv.Diagnostic = .{};
    var process = std.process.Environ.Map.init(a);
    defer process.deinit();
    try std.testing.expectError(error.InvalidSyntax, dotenv.load(a, io, &process, .{
        .dir = tmp.dir,
        .files = &.{ .{ .path = "good.env" }, .{ .path = "bad.env" } },
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.file_index);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
}

test "invalid UTF-8 NUL trailing garbage unknown escapes and multiline fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nul.env", .data = "A=\x00\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "utf8.env", .data = "A=\xff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "trailing.env", .data = "A='x' y\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "escape.env", .data = "A=\"\\q\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "multiline.env", .data = "A=\"one\ntwo\"\n" });
    try std.testing.expectError(error.InvalidEncoding, loadTest(tmp.dir, &.{.{ .path = "nul.env" }}, .{}));
    try std.testing.expectError(error.InvalidEncoding, loadTest(tmp.dir, &.{.{ .path = "utf8.env" }}, .{}));
    try std.testing.expectError(error.InvalidSyntax, loadTest(tmp.dir, &.{.{ .path = "trailing.env" }}, .{}));
    try std.testing.expectError(error.InvalidSyntax, loadTest(tmp.dir, &.{.{ .path = "escape.env" }}, .{}));
    try std.testing.expectError(error.InvalidSyntax, loadTest(tmp.dir, &.{.{ .path = "multiline.env" }}, .{}));
}

test "directory and FIFO are rejected before reading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.NotRegularFile, loadTest(tmp.dir, &.{.{ .path = "." }}, .{}));
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/pipe", .{root}, 0);
    defer a.free(path);
    if (std.os.linux.mknod(path, std.os.linux.S.IFIFO | 0o600, 0) != 0) return error.SkipZigTest;
    try std.testing.expectError(error.NotRegularFile, loadTest(tmp.dir, &.{.{ .path = "pipe" }}, .{}));
}

fn allocationCase(allocator: std.mem.Allocator, dir: std.Io.Dir, testing_io: std.Io) !void {
    var process = std.process.Environ.Map.init(allocator);
    defer process.deinit();
    try process.put("PROCESS", "value");
    var env = try dotenv.load(allocator, testing_io, &process, .{ .dir = dir, .files = &.{.{ .path = "alloc.env" }} });
    env.deinit();
}

test "allocation failure never leaks or publishes a map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alloc.env", .data = "A=one\nB=\"two\\n\"\n" });
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ tmp.dir, io });
}

test "invalid public paths return errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.env", .data = "" });
    for ([_][]const u8{ "", "bad\x00path.env" }) |path| {
        try std.testing.expectError(error.InvalidPath, loadTest(tmp.dir, &.{.{ .path = path }}, .{}));
    }
    var empty = try loadTest(tmp.dir, &.{.{ .path = "empty.env" }}, .{ .max_file_bytes = 0 });
    empty.deinit();
}
