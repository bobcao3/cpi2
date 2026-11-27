const std = @import("std");
const root = @import("root.zig");
const j = root.json;
const Self = @This();

workspace: []const u8,
confined_read_only: bool = false,
read_size_limit: ?u64 = null,
inline_images: ?ImageProcessor = null,
mutex: std.Io.Mutex = .init,
pub const max_bytes = 8 * 1024 * 1024;
// One-indexed lines include the empty line after a final LF.
pub const Lines = struct { offset: usize = 1, limit: ?usize = null };
pub const LineContent = struct {
    total: usize,
    offset: usize,
    selected: usize,
    first_line_bytes: usize,
    truncation: ?root.output.Result = null,
};

pub const Read = struct {
    path: []const u8,
    offset: u64 = 0,
    limit: ?usize = null,
    lossy_text: bool = false,
    // Line selection and byte ranges are mutually exclusive. Images retain binary reads.
    lines: ?Lines = null,
    inline_image: bool = false,
    pub fn validate(self: Read) !void {
        if (self.path.len == 0 or std.mem.indexOfScalar(u8, self.path, 0) != null or self.limit == 0) return error.InvalidArguments;
        if (self.lines) |range| if (range.offset == 0 or self.offset != 0 or (self.limit != null and self.limit != max_bytes)) return error.InvalidArguments;
        if (self.inline_image and (self.offset != 0 or self.limit != null)) return error.InvalidArguments;
    }
};
pub const InlineImage = struct { mime_type: []const u8, base64: []const u8, note: []const u8 };
pub const ImageProcessor = struct {
    context: *anyopaque,
    classify: *const fn ([]const u8) ?[]const u8,
    process: *const fn (*anyopaque, root.Context, []const u8, []const u8) anyerror!InlineImage,
};
pub const Content = struct { text: ?[]const u8, base64: []const u8, mime_type: ?[]const u8, sha256: []const u8, total_bytes: u64, offset: u64, eof: bool, lines: ?LineContent = null, image_note: ?[]const u8 = null };
pub const Write = struct {
    path: []const u8,
    content: []const u8,
    expected_sha256: ?[]const u8 = null,
    create_parents: bool = true,
    pub fn validate(self: Write) !void {
        try (Read{ .path = self.path }).validate();
        if (self.expected_sha256) |hash| {
            if (hash.len != 64) return error.InvalidArguments;
            for (hash) |byte| if (!std.ascii.isHex(byte)) return error.InvalidArguments;
        }
    }
};
pub const Written = struct { bytes: usize, sha256: []const u8 };
pub const Normalize = struct {
    text: []const u8,
    pub fn validate(self: Normalize) !void {
        if (!std.unicode.utf8ValidateSlice(self.text)) return error.InvalidArguments;
    }
};
pub const Normalized = struct { text: []const u8 };
pub const normalize_operation = root.Operation.define("text.normalize_nfkc", Self, Normalize, Normalized, .{ .arguments = 16 * 1024 * 1024, .result = @import("text_normalize.zig").max_result_json_bytes }, .read_only, normalize);
pub const read_operation = root.Operation.define("files.read", Self, Read, Content, .{ .arguments = 8192, .result = 24 * 1024 * 1024 }, .read_only, read);
pub const write_operation = root.Operation.define("files.write", Self, Write, Written, .{ .arguments = 16 * 1024 * 1024, .result = 1024 }, .never, write);

pub fn service(self: *Self) root.Service {
    return .{ .context = self, .operations = &.{ &read_operation, &write_operation, &normalize_operation } };
}

fn normalize(_: *Self, c: root.Context, args: Normalize) !Normalized {
    c.warnSize("text.normalize_nfkc", "input bytes", args.text.len, max_bytes);
    return .{ .text = try @import("text_normalize.zig").nfkc(c, args.text) };
}

fn resolve(self: *Self, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(self.workspace)) return error.InvalidConfiguration;
    return std.fs.path.resolve(a, &.{ self.workspace, path });
}

fn read(self: *Self, c: root.Context, args: Read) !Content {
    const path = try self.resolve(c.allocator, args.path);
    const bytes = try self.readBytes(c, args.path, path);
    const inline_processor = if (args.inline_image) self.inline_images else null;
    const kind = if (inline_processor) |processor| processor.classify(bytes) else mime(bytes);
    if (args.lines) |range| if (kind == null) return readLines(c, bytes, range, args.lossy_text);
    if (kind) |image_mime| if (inline_processor) |processor| {
        const image = try processor.process(processor.context, c, bytes, image_mime);
        return .{
            .text = null,
            .base64 = image.base64,
            .mime_type = image.mime_type,
            .image_note = image.note,
            .sha256 = try c.allocator.dupe(u8, &j.hash(bytes)),
            .total_bytes = bytes.len,
            .offset = 0,
            .eof = true,
        };
    };
    if (args.offset > bytes.len) return error.InvalidOffset;
    const offset: usize = @intCast(args.offset);
    const available = bytes.len - offset;
    const selected = bytes[offset..][0..@min(available, args.limit orelse available)];
    const text = if (std.unicode.utf8ValidateSlice(selected)) selected else if (args.lossy_text and kind == null) try lossy(c.allocator, selected) else null;
    const encoded = if (text != null and kind == null) "" else blk: {
        const buffer = try c.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(selected.len));
        if (kind != null) c.warnSize("files.read", "image base64 bytes", buffer.len, max_bytes);
        break :blk std.base64.standard.Encoder.encode(buffer, selected);
    };
    return .{
        .text = text,
        .base64 = encoded,
        .mime_type = kind,
        .sha256 = try c.allocator.dupe(u8, &j.hash(bytes)),
        .total_bytes = bytes.len,
        .offset = args.offset,
        .eof = offset + selected.len == bytes.len,
    };
}

fn readBytes(self: *Self, c: root.Context, requested: []const u8, resolved: []const u8) ![]u8 {
    self.mutex.lockUncancelable(c.io);
    defer self.mutex.unlock(c.io);
    const file = if (self.confined_read_only) try self.openConfined(c.io, requested) else std.Io.File{ .handle = try std.posix.openat(std.posix.AT.FDCWD, resolved, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
    defer file.close(c.io);
    const stat = try file.stat(c.io);
    if (stat.kind != .file) return error.InvalidArguments;
    if (self.read_size_limit) |limit| if (stat.size > limit) return error.FileTooBig;
    c.warnSize("files.read", "file bytes", stat.size, max_bytes);
    const bytes = try c.allocator.alloc(u8, std.math.cast(usize, stat.size) orelse return error.Overflow);
    var count: usize = 0;
    while (count < bytes.len) {
        const n = try file.readPositional(c.io, &.{bytes[count..]}, count);
        if (n == 0) return error.FileChanged;
        count += n;
    }
    return bytes;
}

fn readLines(c: root.Context, bytes: []const u8, range: Lines, decode_lossy: bool) !Content {
    const valid_utf8 = std.unicode.utf8ValidateSlice(bytes);
    const text = if (valid_utf8) bytes else if (decode_lossy) try lossy(c.allocator, bytes) else return error.InvalidUtf8;
    const total = std.mem.count(u8, text, "\n") + 1;
    var start: usize = 0;
    var line: usize = 1;
    if (range.offset <= total) {
        while (line < range.offset) : (line += 1) start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse unreachable) + 1;
    } else start = text.len;
    var end = start;
    var selected: usize = 0;
    const available = if (range.offset <= total) total - range.offset + 1 else 0;
    const count = @min(range.limit orelse available, available);
    while (selected < count) {
        end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
        selected += 1;
        if (selected < count) end += 1;
    }
    const content = text[start..end];
    c.warnSize("files.read", "selected text bytes", content.len, root.output.expected_bytes);
    c.warnSize("files.read", "selected lines", selected, root.output.expected_lines);
    return .{
        .text = content,
        .base64 = "",
        .mime_type = null,
        .sha256 = try c.allocator.dupe(u8, &j.hash(bytes)),
        .total_bytes = bytes.len,
        .offset = if (valid_utf8) start else try originalOffset(c.io, bytes, start),
        .eof = range.offset <= total and end == text.len,
        .lines = .{ .total = total, .offset = range.offset, .selected = selected, .first_line_bytes = if (selected == 0) 0 else (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len) - start },
    };
}

fn originalOffset(io: std.Io, bytes: []const u8, target: usize) !usize {
    var raw: usize = 0;
    var decoded: usize = 0;
    while (decoded < target) {
        try io.checkCancel();
        const len = std.unicode.utf8ByteSequenceLength(bytes[raw]) catch 0;
        if (len > 0 and raw + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[raw..][0..len])) {
            raw += len;
            decoded += len;
        } else {
            raw += 1;
            decoded += 3;
        }
    }
    return raw;
}

fn write(self: *Self, c: root.Context, args: Write) !Written {
    if (self.confined_read_only) return error.PermissionDenied;
    c.warnSize("files.write", "file bytes", args.content.len, max_bytes);
    const path = try self.resolve(c.allocator, args.path);
    self.mutex.lockUncancelable(c.io);
    defer self.mutex.unlock(c.io);
    const cwd = std.Io.Dir.cwd();
    if (args.create_parents) try cwd.createDirPath(c.io, std.fs.path.dirname(path) orelse ".");
    const destination = cwd.realPathFileAlloc(c.io, path, c.allocator) catch |err| switch (err) {
        error.FileNotFound => missing: {
            const stat = cwd.statFile(c.io, path, .{ .follow_symlinks = false }) catch |failure| switch (failure) {
                error.FileNotFound => break :missing path,
                else => return failure,
            };
            if (stat.kind == .sym_link) return error.FileNotFound;
            return err;
        },
        else => return err,
    };
    const permissions: ?std.Io.File.Permissions = existing: {
        const fd = std.posix.openat(std.posix.AT.FDCWD, destination, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
            error.FileNotFound => break :existing null,
            else => return err,
        };
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        defer file.close(c.io);
        const stat = try file.stat(c.io);
        if (stat.kind != .file) return error.InvalidArguments;
        break :existing stat.permissions;
    };
    const result: Written = .{ .bytes = args.content.len, .sha256 = try c.allocator.dupe(u8, &j.hash(args.content)) };
    var staged = try cwd.createFileAtomic(c.io, destination, .{ .replace = true, .permissions = permissions orelse .default_file });
    defer staged.deinit(c.io);
    try staged.file.writePositionalAll(c.io, args.content, 0);
    if (permissions) |mode| try staged.file.setPermissions(c.io, mode);
    try staged.file.sync(c.io);
    if (args.expected_sha256) |expected| {
        const old = try cwd.readFileAlloc(c.io, destination, c.allocator, .unlimited);
        if (!std.mem.eql(u8, expected, &j.hash(old))) return error.PreconditionFailed;
    }
    try c.io.checkCancel();
    try staged.replace(c.io);
    return result;
}

fn mime(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (std.mem.startsWith(u8, bytes, "BM")) return "image/bmp";
    return null;
}

fn lossy(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..len])) {
            try out.writer.writeAll(bytes[i..][0..len]);
            i += len;
        } else {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
        }
    }
    return out.written();
}

fn openConfined(self: *Self, io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) return error.PermissionDenied;
    var directory_flags: std.posix.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true };
    if (@hasField(std.posix.O, "DIRECTORY")) directory_flags.DIRECTORY = true;
    var root_fd = try std.posix.openat(std.posix.AT.FDCWD, self.workspace, directory_flags, 0);
    defer (std.Io.File{ .handle = root_fd, .flags = .{ .nonblocking = true } }).close(io);
    var components = std.mem.splitScalar(u8, path, '/');
    var component = components.next();
    while (component) |part| {
        const next = components.next();
        if (std.mem.eql(u8, part, "..")) return error.PermissionDenied;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) {
            component = next;
            continue;
        }
        if (next != null) {
            const child = try std.posix.openat(root_fd, part, directory_flags, 0);
            (std.Io.File{ .handle = root_fd, .flags = .{ .nonblocking = true } }).close(io);
            root_fd = child;
            component = next;
            continue;
        }
        const fd = try std.posix.openat(root_fd, part, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        return .{ .handle = fd, .flags = .{ .nonblocking = true } };
    }
    return error.InvalidArguments;
}

test "file text decoding is opt in and normalization is a separate operation" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bytes", .data = "ok\xc0\x80\xe2\x82\nnext" });
    var files: Self = .{ .workspace = workspace };
    var registry = root.Registry.init(t.allocator);
    defer registry.deinit();
    try registry.add(files.service());
    registry.freeze();
    const c: root.Context = .{ .allocator = a, .io = t.io };
    const original = try registry.dispatch(c, "files.read", try j.value(a, Read{ .path = "bytes" }));
    try t.expect(j.get(original, "text") == .null);
    const decoded = try registry.dispatch(c, "files.read", try j.value(a, Read{ .path = "bytes", .lossy_text = true, .lines = .{} }));
    try t.expectEqualStrings("ok\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\nnext", try j.text(j.get(decoded, "text")));
    const second = try registry.dispatch(c, "files.read", try j.value(a, Read{ .path = "bytes", .lossy_text = true, .lines = .{ .offset = 2, .limit = 1 } }));
    try t.expectEqualStrings("next", try j.text(j.get(second, "text")));
    try t.expectEqual(@as(i64, 7), j.get(second, "offset").integer);
    const normalized = try registry.dispatch(c, "text.normalize_nfkc", try j.value(a, Normalize{ .text = "Ａ ﬁ é" }));
    try t.expectEqualStrings("A fi é", try j.text(j.get(normalized, "text")));
    try t.expectError(error.InvalidArguments, (Normalize{ .text = "\xff" }).validate());
    try t.expectError(error.InvalidArguments, (Read{ .path = "bytes", .offset = 1, .lines = .{} }).validate());
}
