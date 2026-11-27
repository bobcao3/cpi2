const std = @import("std");
const builtin = @import("builtin");
const unicode = @import("kit").unicode;
const ClipboardX11 = @import("ClipboardX11.zig");
const ImageCodecs = @import("../../images.zig").ImageCodecs;
const ImageMime = @import("../../images.zig").ImageMime;
const UiWake = @import("../UiWake.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ.Map;

pub fn hasNative(env: *const Environ) bool {
    return builtin.os.tag == .macos or builtin.os.tag == .windows or
        present(env, "TERMUX_VERSION") or present(env, "WAYLAND_DISPLAY") or present(env, "DISPLAY");
}

pub fn useOsc52(env: *const Environ, copied: bool) bool {
    return present(env, "SSH_CONNECTION") or present(env, "SSH_CLIENT") or present(env, "MOSH_CONNECTION") or
        std.mem.eql(u8, env.get("PI_CLIPBOARD_OSC52") orelse "", "1") or
        (!copied and builtin.os.tag == .linux and !hasNative(env));
}

/// False when the terminal's encoded payload limit would be exceeded.
pub fn writeOsc52(a: std.mem.Allocator, writer: *Io.Writer, text: []const u8) !bool {
    if (text.len > 75_000) return false;
    const encoder = std.base64.standard.Encoder;
    const storage = try a.alloc(u8, encoder.calcSize(text.len));
    defer a.free(storage);
    try writer.writeAll("\x1b]52;c;");
    try writer.writeAll(encoder.encode(storage, text));
    try writer.writeAll("\x07");
    try writer.flush();
    return true;
}

pub fn unavailable(env: *const Environ) []const u8 {
    if (present(env, "TERMUX_VERSION")) return "Clipboard unavailable: install the Termux:API app and `termux-api` package";
    if (builtin.os.tag == .linux and present(env, "WAYLAND_DISPLAY")) return "Clipboard unavailable: install `wl-clipboard` (`wl-copy`) or check Wayland access";
    if (builtin.os.tag == .linux and present(env, "DISPLAY")) return "Clipboard unavailable: install `xclip` or `xsel`, or check X11 access";
    return "Clipboard unavailable";
}

fn present(env: *const Environ, name: []const u8) bool {
    const value = env.get(name) orelse return false;
    return value.len != 0;
}

pub const Job = struct {
    a: std.mem.Allocator,
    io: Io,
    wake: *UiWake,
    environ: *const Environ,
    text: []u8,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    copied: bool = false,

    /// The caller transfers ownership of text on success.
    pub fn start(a: std.mem.Allocator, io: Io, wake: *UiWake, env: *const Environ, text: []u8) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .io = io, .wake = wake, .environ = env, .text = text };
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    pub fn destroy(self: *Job) void {
        self.future.cancel(self.io);
        self.a.free(self.text);
        self.a.destroy(self);
    }

    fn run(self: *Job) void {
        self.copied = self.nativeCopy() catch false;
        self.done.set(self.io);
        self.wake.notify();
    }

    fn nativeCopy(self: *const Job) Io.Cancelable!bool {
        if (builtin.os.tag == .macos) return self.tryCommand(&.{"pbcopy"});
        if (builtin.os.tag == .windows) return self.tryCommand(&.{"clip"});
        if (present(self.environ, "TERMUX_VERSION") and try self.tryCommand(&.{"termux-clipboard-set"})) return true;
        if (present(self.environ, "WAYLAND_DISPLAY") and try self.tryCommand(&.{ "wl-copy", "-t", "text/plain" })) return true;
        if (present(self.environ, "DISPLAY")) {
            if (try self.tryCommand(&.{ "xclip", "-selection", "clipboard" })) return true;
            return self.tryCommand(&.{ "xsel", "--clipboard", "--input" });
        }
        return false;
    }

    fn tryCommand(self: *const Job, argv: []const []const u8) Io.Cancelable!bool {
        const Result = union(enum) { copy: Io.Cancelable!bool, timeout: Io.Cancelable!void };
        var results: [2]Result = undefined;
        var choice = Io.Select(Result).init(self.io, &results);
        defer while (choice.cancel()) |_| {};
        choice.concurrent(.copy, command, .{ self, argv }) catch return false;
        choice.concurrent(.timeout, Io.sleep, .{ self.io, Io.Duration.fromSeconds(5), .awake }) catch return false;
        return switch (try choice.await()) {
            .copy => |result| result,
            .timeout => false,
        };
    }

    fn command(self: *const Job, argv: []const []const u8) Io.Cancelable!bool {
        const io = self.io;
        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = self.environ,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer child.kill(io);
        {
            const input = child.stdin.?;
            child.stdin = null;
            defer input.close(io);
            input.writeStreamingAll(io, self.text) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return false,
            };
        }
        const result = child.wait(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        return result == .exited and result.exited == 0;
    }
};

const windows = builtin.os.tag == .windows;
const macos = builtin.os.tag == .macos;
const max_clipboard_bytes = 50 * 1024 * 1024;
const desktop_command_cwd: std.process.Child.Cwd = .{ .path = "/" };

const formats = [_]struct { mime: []const u8, extension: []const u8 }{
    .{ .mime = "image/png", .extension = "png" },
    .{ .mime = "image/jpeg", .extension = "jpg" },
    .{ .mime = "image/webp", .extension = "webp" },
    .{ .mime = "image/gif", .extension = "gif" },
};

const Image = struct {
    bytes: []const u8,
    extension: []const u8,
};

pub const ReadJob = struct {
    pub const Mode = enum { composer, text };
    pub const Result = union(enum) { empty, files: [][]const u8, image: Image, text: []const u8 };

    a: Allocator,
    scratch: std.heap.ArenaAllocator,
    io: Io,
    wake: *UiWake,
    environ: *const Environ,
    mode: Mode,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    result: anyerror!Result = undefined,

    pub fn start(a: Allocator, wake: *UiWake, environ: *const Environ, mode: Mode) !*ReadJob {
        const self = try a.create(ReadJob);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .scratch = .init(a), .io = wake.io, .wake = wake, .environ = environ, .mode = mode };
        self.future = try self.io.concurrent(run, .{self});
        return self;
    }

    pub fn destroy(self: *ReadJob) void {
        self.future.cancel(self.io);
        self.scratch.deinit();
        self.a.destroy(self);
    }

    fn run(self: *ReadJob) void {
        self.result = self.read();
        self.done.set(self.io);
        self.wake.notify();
    }

    fn read(self: *ReadJob) !Result {
        if (self.mode == .composer) {
            if (macos) {
                if (try self.macFiles()) |paths| return .{ .files = paths };
            }
            if (try self.readImage()) |image| return .{ .image = image };
        }
        if (try self.readText()) |value| {
            if (value.len != 0) return .{ .text = value };
        }
        return .empty;
    }

    fn readText(self: *ReadJob) !?[]const u8 {
        if (present(self.environ, "TERMUX_VERSION")) {
            if (try self.command(&.{"termux-clipboard-get"}, 5)) |value| return value;
        }
        if (builtin.os.tag == .linux) {
            if (present(self.environ, "WAYLAND_DISPLAY")) {
                if (try self.command(&.{ "wl-paste", "--no-newline", "--type", "text" }, 5)) |value| return value;
            }
            if (present(self.environ, "DISPLAY")) {
                if (try self.command(&.{ "xclip", "-selection", "clipboard", "-out" }, 5)) |value| return value;
                if (try self.command(&.{ "xsel", "--clipboard", "--output" }, 5)) |value| return value;
                return self.nativeX11(.text);
            }
        }
        if (macos) return self.command(&.{"pbpaste"}, 5);
        if (windows) return self.base64Command(&.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", windows_text });
        return null;
    }

    const ClipboardBytes = struct { bytes: []const u8, mime: []const u8 };
    const ImageProbe = union(enum) { unavailable, empty, data: ClipboardBytes };

    fn readImage(self: *ReadJob) !?Image {
        if (present(self.environ, "TERMUX_VERSION")) return null;
        if (builtin.os.tag == .linux) {
            const wsl = try self.isWsl();
            const wayland = present(self.environ, "WAYLAND_DISPLAY") or
                std.mem.eql(u8, self.environ.get("XDG_SESSION_TYPE") orelse "", "wayland");
            var probe: ImageProbe = .unavailable;
            if (wayland or wsl) probe = try self.desktopImage(.wayland);
            if (probe == .unavailable) probe = try self.desktopImage(.x11);
            if (probe == .data) return self.prepareImage(probe.data);
            if (wsl) {
                const bytes = try self.base64Command(&.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", windows_image });
                if (bytes) |value| return self.prepareNativeImage(value);
            }
            if (probe == .empty or !present(self.environ, "DISPLAY")) return null;
            const bytes = (try self.nativeX11(.image)) orelse return null;
            return self.prepareNativeImage(bytes);
        }
        const bytes = if (macos)
            try self.base64Command(&.{ "osascript", "-l", "JavaScript", "-e", mac_image })
        else if (windows)
            try self.base64Command(&.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", windows_image })
        else
            null;
        return if (bytes) |value| self.prepareNativeImage(value) else null;
    }

    fn nativeX11(self: *ReadJob, mode: ClipboardX11.Mode) !?[]const u8 {
        // STRING properties can grow when the helper converts Latin-1 to UTF-8.
        const limit: usize = if (mode == .text) 2 * ClipboardX11.max_bytes else ClipboardX11.max_bytes;
        const result = (try self.commandWithLimit(&.{ "/proc/self/exe", ClipboardX11.argument, @tagName(mode) }, 3, limit + 1, .inherit)) orelse return null;
        if (result.len == 0) return null;
        if (result[0] == @backingInt(ClipboardX11.Reply.data)) return result[1..];
        if (result[0] == @backingInt(ClipboardX11.Reply.failed) and mode == .image) return error.X11ClipboardReadFailed;
        return null;
    }

    fn prepareNativeImage(self: *ReadJob, bytes: []const u8) !?Image {
        return self.prepareImage(.{ .bytes = bytes, .mime = ImageMime.detect(bytes) orelse "" });
    }

    fn prepareImage(self: *ReadJob, data: ClipboardBytes) !?Image {
        if (data.bytes.len == 0) return null;
        if (formatRank(data.mime)) |rank| return .{ .bytes = data.bytes, .extension = formats[rank].extension };
        const allocator = self.scratch.allocator();
        const image = ImageCodecs.decode(allocator, self.io, data.bytes) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return null,
        };
        defer image.deinit(allocator);
        const png = ImageCodecs.encodePng(allocator, self.io, image) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return null,
        };
        return .{ .bytes = png, .extension = "png" };
    }

    fn desktopImage(self: *ReadJob, desktop: enum { wayland, x11 }) !ImageProbe {
        const query: []const []const u8 = switch (desktop) {
            .wayland => &.{ "wl-paste", "--list-types" },
            .x11 => &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
        };
        const types = (try self.command(query, 1)) orelse return .unavailable;
        const target = preferredType(types) orelse return .empty;
        const args: []const []const u8 = switch (desktop) {
            .wayland => &.{ "wl-paste", "--type", target, "--no-newline" },
            .x11 => &.{ "xclip", "-selection", "clipboard", "-t", target, "-o" },
        };
        const bytes = (try self.command(args, 3)) orelse return .unavailable;
        if (bytes.len == 0) return .empty;
        return .{ .data = .{ .bytes = bytes, .mime = baseMime(target) } };
    }

    fn isWsl(self: *ReadJob) !bool {
        if (present(self.environ, "WSL_DISTRO_NAME") or present(self.environ, "WSLENV")) return true;
        const allocator = self.scratch.allocator();
        const release = Io.Dir.cwd().readFileAlloc(self.io, "/proc/version", allocator, .limited(4096)) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return false,
        };
        return std.ascii.findIgnoreCase(release, "microsoft") != null or std.ascii.findIgnoreCase(release, "wsl") != null;
    }

    fn macFiles(self: *ReadJob) !?[][]const u8 {
        const bytes = (try self.command(&.{ "osascript", "-l", "JavaScript", "-e", mac_files }, 5)) orelse return null;
        const paths = try std.json.parseFromSliceLeaky([][]const u8, self.scratch.allocator(), bytes, .{});
        return if (paths.len == 0) null else paths;
    }

    fn base64Command(self: *ReadJob, argv: []const []const u8) !?[]const u8 {
        const limit = std.base64.standard.Encoder.calcSize(max_clipboard_bytes) + 2;
        const text = (try self.commandWithLimit(argv, 5, limit, desktop_command_cwd)) orelse return null;
        const base64 = std.mem.trim(u8, text, " \r\n\t");
        if (base64.len == 0) return null;
        const decoder = std.base64.standard.Decoder;
        const size = try decoder.calcSizeForSlice(base64);
        if (size > max_clipboard_bytes) return null;
        const value = try self.scratch.allocator().alloc(u8, size);
        try decoder.decode(value, base64);
        return value;
    }

    fn command(self: *ReadJob, argv: []const []const u8, seconds: i64) !?[]const u8 {
        return self.commandWithLimit(argv, seconds, max_clipboard_bytes, desktop_command_cwd);
    }

    fn commandWithLimit(self: *ReadJob, argv: []const []const u8, seconds: i64, limit: usize, cwd: std.process.Child.Cwd) !?[]const u8 {
        const Outcome = union(enum) { value: anyerror!?[]const u8, timeout: Io.Cancelable!void };
        var events: [2]Outcome = undefined;
        var race = Io.Select(Outcome).init(self.io, &events);
        defer while (race.cancel()) |_| {};
        try race.concurrent(.value, runCommand, .{ self, argv, limit, cwd });
        try race.concurrent(.timeout, Io.sleep, .{ self.io, Io.Duration.fromSeconds(seconds), .awake });
        return switch (try race.await()) {
            .value => |value| value,
            .timeout => null,
        };
    }

    fn runCommand(self: *ReadJob, argv: []const []const u8, limit: usize, cwd: std.process.Child.Cwd) anyerror!?[]const u8 {
        const io = self.io;
        const allocator = self.scratch.allocator();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd,
            .environ_map = self.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            // POSIX Ctrl+Z suspends the foreground group, while a clipboard read can finish.
            .pgid = if (windows) null else 0,
            .create_no_window = true,
        }) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return null,
        };
        defer child.kill(io);
        var buffer: [8192]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buffer);
        const bytes = reader.interface.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ReadFailed => {
                if (reader.err) |cause| {
                    if (cause == error.Canceled) return error.Canceled;
                }
                return null;
            },
            error.StreamTooLong => return null,
        };
        const term = child.wait(io) catch |err| switch (err) {
            error.Canceled => return err,
            else => return null,
        };
        if (term.success()) return bytes;
        allocator.free(bytes);
        return null;
    }
};

fn baseMime(mime: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(mime, ';'), " \t\r");
}

fn formatRank(mime: []const u8) ?usize {
    for (formats, 0..) |format, rank| {
        if (std.ascii.eqlIgnoreCase(mime, format.mime)) return rank;
    }
    return null;
}

fn preferredType(types: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_rank = formats.len + 1;
    var lines = std.mem.splitScalar(u8, types, '\n');
    while (lines.next()) |line| {
        const target = std.mem.trim(u8, line, " \t\r");
        const base = baseMime(target);
        if (!std.ascii.startsWithIgnoreCase(base, "image/")) continue;
        const rank = formatRank(base) orelse formats.len;
        if (rank < best_rank) {
            best = target;
            best_rank = rank;
        }
    }
    return best;
}

pub fn filePathsText(a: Allocator, paths: []const []const u8, draft: []const u8, cursor: usize, shell: bool) ![]u8 {
    var result: Io.Writer.Allocating = .init(a);
    errdefer result.deinit();
    const writer = &result.writer;
    if (cursor > 0) {
        var before = cursor - 1;
        while (before > 0 and draft[before] & 0xc0 == 0x80) before -= 1;
        if (!unicode.onlyEcmaWhitespace(draft[before..cursor])) try writer.writeByte(' ');
    }
    for (paths, 0..) |path, index| {
        var remaining = path;
        while (unicode.decodeUtf8Lossy(remaining)) |scalar| {
            if (unicode.generalCategory(scalar.codepoint) == .other_control) return error.ClipboardPathContainsControls;
            remaining = remaining[scalar.len..];
        }
        if (index > 0) try writer.writeByte(if (shell) ' ' else '\n');
        if (shell) try writeShellPath(writer, path) else try writer.writeAll(path);
    }
    if (unicode.decodeUtf8Lossy(draft[cursor..])) |after| {
        if (!unicode.isEcmaWhitespace(after.codepoint)) try writer.writeByte(' ');
    }
    return result.toOwnedSlice();
}

fn writeShellPath(writer: *Io.Writer, path: []const u8) !void {
    const safe = for (path) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_-./~:@", byte) == null) break false;
    } else path.len != 0;
    if (safe) return writer.writeAll(path);
    try writer.writeByte('\'');
    var parts = std.mem.splitScalar(u8, path, '\'');
    try writer.writeAll(parts.first());
    while (parts.next()) |part| {
        try writer.writeAll("'\\''");
        try writer.writeAll(part);
    }
    try writer.writeByte('\'');
}

/// The caller keeps the file once the composer has accepted its path.
pub fn saveImage(a: Allocator, io: Io, env: *const Environ, image: Image) ![]u8 {
    const names: []const []const u8 = if (windows) &.{ "TEMP", "TMP" } else &.{ "TMPDIR", "TMP", "TEMP" };
    const base = for (names) |name| {
        if (present(env, name)) break env.get(name).?;
    } else if (windows) "C:\\Windows\\Temp" else "/tmp";
    const dir = Io.Dir.cwd();
    const permissions: Io.File.Permissions = if (windows) .default_file else .fromMode(0o600);
    while (true) {
        var uuid: [16]u8 = undefined;
        try io.randomSecure(&uuid);
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(uuid, .lower);
        const name = try std.fmt.allocPrint(a, "pi-clipboard-{s}-{s}-{s}-{s}-{s}.{s}", .{
            hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32], image.extension,
        });
        defer a.free(name);
        const path = try std.fs.path.join(a, &.{ base, name });
        errdefer a.free(path);
        const file = dir.createFile(io, path, .{ .exclusive = true, .permissions = permissions }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                a.free(path);
                continue;
            },
            else => return err,
        };
        errdefer dir.deleteFile(io, path) catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, image.bytes);
        return path;
    }
}

const mac_files =
    \\ObjC.import('AppKit');
    \\const board = $.NSPasteboard.generalPasteboard;
    \\const options = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithBool(true), $.NSPasteboardURLReadingFileURLsOnlyKey);
    \\const urls = board.readObjectsForClassesOptions([$.NSURL.class], options);
    \\const paths = [];
    \\if (!urls.isNil()) {
    \\    for (let i = 0; i < urls.count; ++i) paths.push(ObjC.unwrap(urls.objectAtIndex(i).path));
    \\}
    \\JSON.stringify(paths);
;

const mac_image =
    \\ObjC.import('AppKit');
    \\const board = $.NSPasteboard.generalPasteboard;
    \\let png = board.dataForType($.NSPasteboardTypePNG);
    \\if (png.isNil() && !board.dataForType($.NSPasteboardTypeTIFF).isNil()) {
    \\    const image = $.NSImage.alloc.initWithPasteboard(board);
    \\    const bitmap = $.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
    \\    png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
    \\}
    \\png.isNil() ? '' : ObjC.unwrap(png.base64EncodedStringWithOptions(0));
;

const windows_text =
    "Add-Type -AssemblyName System.Windows.Forms; " ++
    "$text = [System.Windows.Forms.Clipboard]::GetText(); " ++
    "[Console]::Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))";

const windows_image =
    "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; " ++
    "$image = [System.Windows.Forms.Clipboard]::GetImage(); " ++
    "if ($image) { $stream = [IO.MemoryStream]::new(); " ++
    "$image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png); " ++
    "[Console]::Write([Convert]::ToBase64String($stream.ToArray())); $stream.Dispose(); $image.Dispose() }";
