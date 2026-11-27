const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;

pub const Result = union(enum) {
    edited: []const u8,
    failed: []const u8,
};

pub fn command(configured: ?[]const u8, env: *const std.process.Environ.Map) []const u8 {
    if (configured) |editor| if (!kit.unicode.onlyEcmaWhitespace(editor)) return editor;
    if (env.get("VISUAL")) |visual| if (visual.len != 0) return visual;
    if (env.get("EDITOR")) |editor| if (editor.len != 0) return editor;
    return if (windows) "notepad" else "nano";
}

/// All returned bytes and temporary allocations belong to the caller's scratch arena.
/// The caller has stopped reading stdin and released its TUI before calling this.
pub fn edit(a: Allocator, io: Io, env: *const std.process.Environ.Map, editor: []const u8, draft: []const u8) !Result {
    const temporary = try makeDirectory(a, io, env);
    defer Io.Dir.cwd().deleteTree(io, temporary) catch {};
    const path = try std.fs.path.join(a, &.{ temporary, "prompt.md" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = draft,
        .flags = .{ .exclusive = true, .permissions = if (windows) .default_file else .fromMode(0o600) },
    });
    const launch = try std.fmt.allocPrint(a, "Launching external editor: {s}\ncpi-minimal will resume when the editor exits.\n", .{editor});
    try Io.File.stdout().writeStreamingAll(io, launch);

    var args: std.ArrayList([]const u8) = .empty;
    if (windows) {
        const shell = env.get("COMSPEC") orelse "cmd.exe";
        const invocation = try std.fmt.allocPrint(a, "{s} \"{s}\"", .{ editor, path });
        try args.appendSlice(a, &.{ shell, "/d", "/s", "/c", invocation });
    } else {
        var parts = std.mem.splitScalar(u8, editor, ' ');
        while (parts.next()) |arg| try args.append(a, arg);
        try args.append(a, path);
    }
    const term = if (args.items[0].len != 0) launchEditor(io, args.items) else error.FileNotFound;
    const status = term catch |err| switch (err) {
        error.EditorWaitFailed => return err,
        else => return .{ .failed = try std.fmt.allocPrint(a, "Failed to launch external editor: {s}", .{editor}) },
    };
    if (!status.success()) {
        const reason = switch (status) {
            .exited => |code| try std.fmt.allocPrint(a, "code {d}", .{code}),
            .signal, .stopped => |sig| try std.fmt.allocPrint(a, "SIG{t}", .{sig}),
            .unknown => "unknown status",
        };
        return .{ .failed = try std.fmt.allocPrint(a, "External editor exited with {s}; prompt unchanged", .{reason}) };
    }
    var bytes: []const u8 = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const bom = "\xef\xbb\xbf";
    if (std.mem.startsWith(u8, bytes, bom)) bytes = bytes[bom.len..];
    if (std.mem.endsWith(u8, bytes, "\n")) bytes = bytes[0 .. bytes.len - 1];
    return .{ .edited = bytes };
}

fn makeDirectory(a: Allocator, io: Io, env: *const std.process.Environ.Map) ![]const u8 {
    const names: []const []const u8 = if (windows) &.{ "TEMP", "TMP" } else &.{ "TMPDIR", "TMP", "TEMP" };
    const base = for (names) |name| {
        if (env.get(name)) |value| if (value.len != 0) break value;
    } else if (windows) "C:\\Windows\\Temp" else "/tmp";
    const permissions: Io.Dir.Permissions = if (windows) .default_dir else .fromMode(0o700);
    while (true) {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const name = try std.fmt.allocPrint(a, "cpi-editor-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        const dir = try std.fs.path.join(a, &.{ base, name });
        Io.Dir.cwd().createDir(io, dir, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return dir;
    }
}

fn launchEditor(io: Io, argv: []const []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{ .argv = argv });
    defer child.kill(io);
    return child.wait(io) catch error.EditorWaitFailed;
}
