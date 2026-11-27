//! Private artifacts for code-mode output. Callers choose a media type, not a path.
const std = @import("std");
const services = @import("services");
const j = @import("../json.zig");

const Args = struct { mime_type: []const u8, data: []const u8 };
const Result = struct { path: []const u8, bytes: usize };
const operation = services.Operation.defineJson("script.output", Args, Result, .{ .arguments = 32 * 1024 * 1024, .result = 16 * 1024 }, .never, dispatch);

pub fn service(exec: *services.Exec) services.Service {
    return .{ .context = exec, .operations = &.{&operation} };
}

fn dispatch(raw: *anyopaque, c: services.Context, _: []const u8, args: j.Value) !j.Value {
    const exec: *const services.Exec = @ptrCast(@alignCast(raw));
    const kind = j.text(j.get(args, "mime_type"));
    const data = j.text(j.get(args, "data"));
    const extension: []const u8 = if (std.mem.eql(u8, kind, "text/plain")) ".txt" else if (std.mem.eql(u8, kind, "image/png")) ".png" else if (std.mem.eql(u8, kind, "image/jpeg")) ".jpg" else if (std.mem.eql(u8, kind, "image/gif")) ".gif" else if (std.mem.eql(u8, kind, "image/webp")) ".webp" else if (std.mem.eql(u8, kind, "image/bmp")) ".bmp" else return error.UnsupportedArtifactType;
    const bytes = if (std.mem.eql(u8, extension, ".txt")) data else blk: {
        const decoder = std.base64.standard.Decoder;
        const decoded = try c.allocator.alloc(u8, try decoder.calcSizeForSlice(data));
        try decoder.decode(decoded, data);
        break :blk decoded;
    };
    var nonce: [16]u8 = undefined;
    c.io.random(&nonce);
    const cwd = std.Io.Dir.cwd();
    const directory = try cwd.realPathFileAlloc(c.io, exec.directory, c.allocator);
    const path = try std.fmt.allocPrint(c.allocator, "{s}/pi-codemode-{s}{s}", .{ directory, &std.fmt.bytesToHex(nonce, .lower), extension });
    const file = try cwd.createFile(c.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(c.io);
    errdefer cwd.deleteFile(c.io, path) catch {};
    try file.writeStreamingAll(c.io, bytes);
    return j.value(c.allocator, Result{ .path = path, .bytes = bytes.len });
}
