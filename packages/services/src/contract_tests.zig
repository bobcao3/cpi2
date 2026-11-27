const std = @import("std");
const root = @import("root.zig");
const j = root.json;

test "declared grants and strict contracts guard actual file and process effects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var files: root.Files = .{ .workspace = path };
    var exec: root.Exec = .{ .directory = try std.fs.path.join(a, &.{ path, "output" }), .environment = &env };
    defer exec.deinit(io, .terminate);
    var registry = root.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(files.service());
    try registry.add(exec.service());
    registry.freeze();
    const c: root.Context = .{ .allocator = a, .io = io, .idempotency_key = "fixture" };
    const write = try j.value(a, .{ .path = "written", .content = "first\r\n" });
    try std.testing.expectError(error.PermissionDenied, registry.dispatchGranted(c, &.{&root.Files.read_operation}, "files.write", write));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "written", .{}));
    _ = try registry.dispatchGranted(c, &.{&root.Files.write_operation}, "files.write", write);
    try std.testing.expectEqualStrings("first\r\n", try tmp.dir.readFileAlloc(io, "written", a, .limited(1024)));
    const read = try registry.dispatch(c, "files.read", try j.value(a, .{ .path = "written" }));
    try std.testing.expectEqualStrings("first\r\n", (try j.text(j.get(read, "text"))));
    const conflict = try j.value(a, .{ .path = "written", .content = "second", .expected_sha256 = &j.hash("different") });
    try std.testing.expectError(error.PreconditionFailed, registry.dispatch(c, "files.write", conflict));
    try std.testing.expectEqualStrings("first\r\n", try tmp.dir.readFileAlloc(io, "written", a, .limited(1024)));
    const spawn = try j.value(a, .{ .argv = .{ "/bin/sh", "-c", "printf ran > spawned; printf stdout; printf stderr >&2" }, .cwd = path });
    try std.testing.expectError(error.PermissionDenied, registry.dispatchGranted(c, &.{}, "process.exec", spawn));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "spawned", .{}));
    var old_contract = spawn;
    try j.put(a, &old_contract, "max_output_bytes", .{ .integer = 65536 });
    try std.testing.expectError(error.InvalidSchema, registry.dispatch(c, "process.exec", old_contract));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "spawned", .{}));
    _ = old_contract.object.swapRemove("max_output_bytes");
    const result = try registry.dispatchGranted(c, &.{&root.Exec.operation}, "process.exec", spawn);
    try std.testing.expectEqualStrings("ran", try tmp.dir.readFileAlloc(io, "spawned", a, .limited(100)));
    try std.testing.expectEqualStrings("stdoutstderr", try j.text(j.get(j.get(result, "output"), "content")));
    try std.testing.expectError(error.UnsupportedEndpoint, registry.dispatch(c, "missing", .{ .object = .empty }));
    try std.testing.expectError(error.InvalidSchema, registry.dispatch(c, "files.write", try j.value(a, .{ .path = "written", .content = 42 })));
}

const Invalid = struct {
    const operation = root.Operation.defineJson("fixture.invalid", struct {}, struct { count: u32 }, .{ .arguments = 100, .result = 100 }, .read_only, call);
    fn call(_: *anyopaque, c: root.Context, _: []const u8, _: j.Value) !j.Value {
        return j.value(c.allocator, .{ .count = "not a number" });
    }
};
test "service result contract is checked independently of implementation" {
    var invalid: Invalid = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = root.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(.{ .context = &invalid, .operations = &.{&Invalid.operation} });
    try std.testing.expectError(error.InvalidServiceResult, registry.dispatch(.{ .allocator = arena.allocator(), .io = std.testing.io }, "fixture.invalid", .{ .object = .empty }));
}

const WriteFault = struct {
    fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
        return error.InputOutput;
    }
    fn rename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
        return error.AccessDenied;
    }
};

test "failed file publication preserves old bytes and removes staging files" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |fail_rename| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "original" });
        var files: root.Files = .{ .workspace = try tmp.dir.realPathFileAlloc(io, ".", a) };
        var registry = root.Registry.init(std.testing.allocator);
        defer registry.deinit();
        try registry.add(files.service());
        var vtable = io.vtable.*;
        if (fail_rename) vtable.dirRename = WriteFault.rename else vtable.fileSync = WriteFault.sync;
        const faulty: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        const request = try j.value(a, .{ .path = "target", .content = "replacement" });
        try std.testing.expectError(if (fail_rename) error.AccessDenied else error.InputOutput, registry.dispatch(.{ .allocator = a, .io = faulty }, "files.write", request));
        try std.testing.expectEqualStrings("original", try tmp.dir.readFileAlloc(io, "target", a, .limited(100)));
        var iterator = tmp.dir.iterate();
        var count: usize = 0;
        while (try iterator.next(io)) |entry| {
            count += 1;
            try std.testing.expectEqualStrings("target", entry.name);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        _ = try registry.dispatch(.{ .allocator = a, .io = io }, "files.write", request);
        try std.testing.expectEqualStrings("replacement", try tmp.dir.readFileAlloc(io, "target", a, .limited(100)));
    }
}

test "atomic file replacement preserves permissions and follows existing symlinks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "original" });
    try tmp.dir.setFilePermissions(io, "target", .fromMode(0o751), .{});
    try tmp.dir.symLink(io, "target", "link", .{});
    var files: root.Files = .{ .workspace = try tmp.dir.realPathFileAlloc(io, ".", a) };
    var registry = root.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(files.service());
    const c: root.Context = .{ .allocator = a, .io = io };
    _ = try registry.dispatch(c, "files.write", try j.value(a, .{ .path = "link", .content = "replacement", .expected_sha256 = &j.hash("original") }));
    try std.testing.expectEqualStrings("replacement", try tmp.dir.readFileAlloc(io, "target", a, .limited(100)));
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "link", .{ .follow_symlinks = false })).kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o751), (try tmp.dir.statFile(io, "target", .{})).permissions.toMode() & 0o7777);
    try std.testing.expectError(error.PreconditionFailed, registry.dispatch(c, "files.write", try j.value(a, .{ .path = "link", .content = "stale", .expected_sha256 = &j.hash("original") })));
    try std.testing.expectEqualStrings("replacement", try tmp.dir.readFileAlloc(io, "target", a, .limited(100)));
    try tmp.dir.symLink(io, "absent", "dangling", .{});
    try std.testing.expectError(error.FileNotFound, registry.dispatch(c, "files.write", try j.value(a, .{ .path = "dangling", .content = "replacement" })));
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "dangling", .{ .follow_symlinks = false })).kind);
}
