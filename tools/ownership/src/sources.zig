const std = @import("std");

pub fn collect(a: std.mem.Allocator, io: std.Io, root: []const u8) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "packages", "tools" }) |sub| {
        const directory = try std.fs.path.join(a, &.{ root, sub });
        const dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory and skippedDirectory(entry.basename)) {
                walker.leave(io);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.eql(u8, entry.basename, "tests.zig") or std.mem.endsWith(u8, entry.basename, "_tests.zig") or std.mem.startsWith(u8, entry.basename, "test_")) continue;
            try paths.append(a, try std.fs.path.join(a, &.{ sub, entry.path }));
        }
    }
    return paths.toOwnedSlice(a);
}

fn skippedDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, "vendor") or std.mem.eql(u8, name, "fixtures") or
        std.mem.eql(u8, name, "tests") or std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg");
}
