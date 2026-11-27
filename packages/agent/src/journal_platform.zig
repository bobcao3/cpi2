const std = @import("std");
const builtin = @import("builtin");

pub fn open(path: []const u8) !std.Io.File {
    return openFlags(path, true, false);
}

pub fn openExistingWriter(path: []const u8) !std.Io.File {
    return openFlags(path, false, false);
}

pub fn createExclusive(path: []const u8) !std.Io.File {
    return openFlags(path, true, true);
}

pub fn openRead(path: []const u8) !std.Io.File {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0);
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

fn openFlags(path: []const u8, create: bool, exclusive: bool) !std.Io.File {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .CREAT = create,
        .EXCL = exclusive,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0o600);
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

pub fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = true } };
    try file.sync(io);
}
