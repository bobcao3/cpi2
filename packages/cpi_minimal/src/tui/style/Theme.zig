const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit");
const j = @import("../../json.zig");

const tui = kit.tui;
const terminal = kit.terminal.colors;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const registry = @import("model_registry");

const bundle = @embedFile("theme_colors.luau") ++ "\n" ++ @embedFile("system_theme.luau");

const role_names = names: {
    const roles = std.enums.values(Role);
    var names: [roles.len][]const u8 = undefined;
    for (roles, &names) |role, *slot| slot.* = @tagName(role);
    break :names names;
};

pub const Role = enum {
    accent,
    border,
    borderAccent,
    borderMuted,
    success,
    @"error",
    warning,
    muted,
    dim,
    text,
    thinkingText,
    selectedBg,
    scrollbarTrack,
    scrollbarThumb,
    searchMatchBg,
    searchMatchText,
    userMessageBg,
    userMessageText,
    customMessageBg,
    customMessageText,
    customMessageLabel,
    toolPendingBg,
    toolSuccessBg,
    toolErrorBg,
    toolTitle,
    toolOutput,
    mdHeading,
    mdLink,
    mdLinkUrl,
    mdCode,
    mdCodeBlock,
    mdCodeBlockBorder,
    mdQuote,
    mdQuoteBorder,
    mdHr,
    mdListBullet,
    toolDiffAdded,
    toolDiffRemoved,
    toolDiffContext,
    syntaxComment,
    syntaxKeyword,
    syntaxFunction,
    syntaxVariable,
    syntaxString,
    syntaxNumber,
    syntaxType,
    syntaxOperator,
    syntaxPunctuation,
    thinkingOff,
    thinkingMinimal,
    thinkingLow,
    thinkingMedium,
    thinkingHigh,
    thinkingXhigh,
    thinkingMax,
    bashMode,
};

const Paint = struct { color: ?tui.Color = null, faint: bool = false };

pub const Palette = struct {
    appearance: terminal.Scheme = .dark,
    colors: std.EnumArray(Role, Paint) = .initFill(.{}),

    pub fn color(self: *const Palette, role: Role) ?tui.Color {
        return self.colors.get(role).color;
    }

    pub fn style(self: *const Palette, role: Role) tui.Style {
        const paint = self.colors.get(role);
        return .{ .foreground = paint.color, .faint = paint.faint };
    }

    pub fn text(self: *const Palette, role: Role, bytes: []const u8) tui.Node {
        return .{ .text = .{ .bytes = bytes, .style = self.style(role) } };
    }

    pub fn settingsStyles(self: *const Palette) tui.SettingsList.Styles {
        return .{ .selected = self.style(.accent), .value = self.style(.muted), .description = self.style(.dim), .hint = self.style(.dim) };
    }

    pub fn effort(self: *const Palette, level: ?@import("agent").thinking.Level) tui.Style {
        return self.style(switch (level orelse .off) {
            .off => .thinkingOff,
            .minimal => .thinkingMinimal,
            .low => .thinkingLow,
            .medium => .thinkingMedium,
            .high => .thinkingHigh,
            .xhigh => .thinkingXhigh,
            .max, .ultra => .thinkingMax,
        });
    }
};

pub const system_name = "system";

const Source = union(enum) {
    system,
    fixed: struct { palette: Palette, appearance: ?terminal.Scheme },
};

const Id = enum(usize) { system, _ };

pub const Choice = union(enum) {
    single: Id,
    paired: struct { light: Id, dark: Id },

    pub fn followsTerminal(self: Choice) bool {
        return self == .paired or self.single == .system;
    }

    fn active(self: Choice, appearance: terminal.Scheme) Id {
        return switch (self) {
            .single => |theme| theme,
            .paired => |pair| if (appearance == .light) pair.light else pair.dark,
        };
    }

    fn remap(self: Choice, old: []const Entry, next: []const Entry) Choice {
        return switch (self) {
            .single => |id| .{ .single = entryId(next, entryName(old, id)) },
            .paired => |pair| .{ .paired = .{
                .light = entryId(next, entryName(old, pair.light)),
                .dark = entryId(next, entryName(old, pair.dark)),
            } },
        };
    }
};

pub const Pair = struct { light: []const u8, dark: []const u8 };

pub fn parsePair(value: []const u8) ?Pair {
    const light, const dark = std.mem.cutScalar(u8, value, '/') orelse return null;
    const light_name = std.mem.trim(u8, light, " \t\r\n");
    const dark_name = std.mem.trim(u8, dark, " \t\r\n");
    if (light_name.len == 0 or dark_name.len == 0 or std.mem.indexOfScalar(u8, dark_name, '/') != null) return null;
    return .{ .light = light_name, .dark = dark_name };
}

pub const Entry = struct {
    name: []const u8,
    source: Source,

    fn less(_: void, a: Entry, b: Entry) bool {
        return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
    }
};

pub const Resources = struct {
    directory: ?[]const u8 = null,
    explicit: []const []const u8 = &.{},
};

pub const CatalogReload = enum { replace, keep_watched };

fn entryId(entries: []const Entry, name: []const u8) Id {
    for (entries, 0..) |entry, index| if (std.mem.eql(u8, name, entry.name)) return @fromBackingInt(@intCast(index));
    return .system;
}

fn entryName(entries: []const Entry, id: Id) []const u8 {
    return if (id == .system) system_name else entries[@backingInt(id)].name;
}

const FileVersion = struct {
    inode: Io.File.INode,
    size: u64,
    modified: Io.Timestamp,
    metadata_changed: Io.Timestamp,

    fn read(io: Io, path: []const u8) ?FileVersion {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        if (stat.kind != .file) return null;
        return .{ .inode = stat.inode, .size = stat.size, .modified = stat.mtime, .metadata_changed = stat.ctime };
    }
};

const watch_interval: Io.Duration = .fromMilliseconds(100);
const theme_debounce: Io.Duration = .fromMilliseconds(100);

const Watch = struct {
    path: []const u8,
    version: ?FileVersion,
    next_poll: Io.Timestamp,
    reload_at: ?Io.Timestamp = null,
};

pub const Session = struct {
    palette: Palette = .{},
    system_palette: Palette = .{},
    choice: Choice = .{ .single = .system },
    preview: ?Choice = null,
    catalog_arena: ?std.heap.ArenaAllocator = null,
    entries: []Entry = &.{},
    watch_directory: ?[]const u8 = null,
    watch_target: Id = .system,
    watch: ?Watch = null,
    colors: terminal.Colors = .{},
    query: terminal.Query = .{},
    reported: ?terminal.Scheme = null,
    env: terminal.Scheme,
    truecolor: bool,
    deadline: ?Io.Timestamp = null,
    receiving: bool = false,
    initialized: bool = false,

    pub fn init(env: *const std.process.Environ.Map) Session {
        return .{ .env = colorFgBg(env.get("COLORFGBG")) orelse .dark, .truecolor = usesTruecolor(env) };
    }

    pub fn deinit(self: *Session, a: Allocator) void {
        self.clearWatch(a);
        if (self.catalog_arena) |*arena| arena.deinit();
    }

    pub fn knownName(self: *const Session, name: []const u8) []const u8 {
        return entryName(self.entries, entryId(self.entries, name));
    }

    pub fn resolve(self: *const Session, value: []const u8) Choice {
        if (parsePair(value)) |names| return self.resolvePair(names);
        return .{ .single = entryId(self.entries, value) };
    }

    pub fn resolvePair(self: *const Session, names: Pair) Choice {
        return .{ .paired = .{
            .light = entryId(self.entries, names.light),
            .dark = entryId(self.entries, names.dark),
        } };
    }

    pub fn select(self: *Session, value: []const u8) bool {
        self.choice = self.resolve(value);
        return self.compose();
    }

    pub fn showPreview(self: *Session, choice: ?Choice) bool {
        self.preview = choice;
        return self.compose();
    }

    fn activeTheme(self: *const Session) Id {
        return (self.preview orelse self.choice).active(self.system_palette.appearance);
    }

    fn compose(self: *Session) bool {
        const id = self.activeTheme();
        var next = self.system_palette;
        if (id != .system) switch (self.entries[@backingInt(id)].source) {
            .system => unreachable,
            .fixed => |fixed| {
                next = fixed.palette;
                next.appearance = fixed.appearance orelse self.system_palette.appearance;
            },
        };
        const changed = !std.meta.eql(self.palette, next);
        self.palette = next;
        return changed;
    }

    pub fn loadCatalog(self: *Session, a: Allocator, io: Io, resources: Resources, reload: CatalogReload) !void {
        var next: std.heap.ArenaAllocator = .init(a);
        errdefer next.deinit();
        const owned = next.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        try entries.append(owned, .{ .name = system_name, .source = .system });
        const keep = if (reload == .keep_watched and self.watch != null and self.activeTheme() == self.watch_target)
            self.watch_target
        else
            .system;
        if (keep != .system) {
            const entry = self.entries[@backingInt(keep)];
            try entries.append(owned, .{ .name = try owned.dupe(u8, entry.name), .source = entry.source });
        }
        for (resources.explicit) |path| {
            const cwd = Io.Dir.cwd();
            const stat = cwd.statFile(io, path, .{}) catch continue;
            if (stat.kind == .directory) {
                try self.loadDirectory(a, owned, io, path, &entries);
            } else if (stat.kind == .file) try self.loadFile(a, owned, io, cwd, path, &entries);
        }
        for ([_][]const u8{ @embedFile("pi_dark_theme"), @embedFile("pi_light_theme") }) |bytes| {
            try addEntry(owned, &entries, try self.compileEntry(a, owned, bytes));
        }
        if (resources.directory) |path| try self.loadDirectory(a, owned, io, path, &entries);
        std.mem.sort(Entry, entries.items[1..], {}, Entry.less);
        self.choice = self.choice.remap(self.entries, entries.items);
        if (self.preview) |preview| self.preview = preview.remap(self.entries, entries.items);
        if (keep == .system) self.clearWatch(a) else self.watch_target = entryId(entries.items, entryName(self.entries, keep));
        self.watch_directory = resources.directory;
        if (self.catalog_arena) |*arena| arena.deinit();
        self.catalog_arena = next;
        self.entries = entries.items;
    }

    fn loadDirectory(self: *Session, a: Allocator, owned: Allocator, io: Io, path: []const u8, entries: *std.ArrayList(Entry)) !void {
        const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iter = dir.iterate();
        while (iter.next(io) catch null) |file| {
            if (!std.mem.endsWith(u8, file.name, ".json") or (file.kind != .file and file.kind != .sym_link)) continue;
            try self.loadFile(a, owned, io, dir, file.name, entries);
        }
    }

    fn loadFile(self: *Session, a: Allocator, owned: Allocator, io: Io, dir: Io.Dir, name: []const u8, entries: *std.ArrayList(Entry)) !void {
        if (try self.readFile(a, owned, io, dir, name)) |entry| try addEntry(owned, entries, entry);
    }

    fn readFile(self: *Session, a: Allocator, owned: Allocator, io: Io, dir: Io.Dir, name: []const u8) !?Entry {
        const bytes = dir.readFileAlloc(io, name, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        defer a.free(bytes);
        return self.compileEntry(a, owned, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    }

    fn clearWatch(self: *Session, a: Allocator) void {
        if (self.watch) |watch| a.free(watch.path);
        self.watch = null;
        self.watch_target = .system;
    }

    pub fn bindWatch(self: *Session, a: Allocator, io: Io, now: Io.Timestamp) !void {
        const target = self.activeTheme();
        if (target == self.watch_target) return;
        self.clearWatch(a);
        if (target == .system) return;
        self.watch_target = target;
        const directory = self.watch_directory orelse return;
        const name = entryName(self.entries, target);
        if (std.mem.eql(u8, name, "dark") or std.mem.eql(u8, name, "light")) return;
        const filename = try std.mem.concat(a, u8, &.{ name, ".json" });
        defer a.free(filename);
        if (!std.mem.eql(u8, std.fs.path.basename(filename), filename)) return;
        const path = try std.fs.path.join(a, &.{ directory, filename });
        const version = FileVersion.read(io, path) orelse {
            a.free(path);
            return;
        };
        self.watch = .{ .path = path, .version = version, .next_poll = now.addDuration(watch_interval) };
    }

    pub fn watchDeadline(self: *const Session) ?Io.Timestamp {
        const watch = self.watch orelse return null;
        const due = watch.reload_at orelse return watch.next_poll;
        return if (due.compare(.lt, watch.next_poll)) due else watch.next_poll;
    }

    pub fn pollWatch(self: *Session, a: Allocator, io: Io, now: Io.Timestamp) !bool {
        const watch = if (self.watch) |*watch| watch else return false;
        if (now.compare(.gte, watch.next_poll)) {
            watch.next_poll = now.addDuration(watch_interval);
            const version = FileVersion.read(io, watch.path);
            if (!std.meta.eql(watch.version, version)) {
                watch.version = version;
                watch.reload_at = if (version != null) now.addDuration(theme_debounce) else null;
            }
        }
        const due = watch.reload_at orelse return false;
        if (now.compare(.lt, due)) return false;
        watch.reload_at = null;
        const entry = try self.readFile(a, a, io, .cwd(), watch.path) orelse return false;
        defer a.free(entry.name);
        // Pi keeps the watched registry name when the file changes its declared name.
        self.entries[@backingInt(self.watch_target)].source = entry.source;
        return self.compose();
    }

    fn addEntry(a: Allocator, entries: *std.ArrayList(Entry), entry: Entry) !void {
        for (entries.items) |other| {
            if (std.mem.eql(u8, other.name, entry.name)) {
                a.free(entry.name);
                return;
            }
        }
        try entries.append(a, entry);
    }

    fn compileEntry(self: *Session, a: Allocator, owned: Allocator, bytes: []const u8) !Entry {
        var scratch: std.heap.ArenaAllocator = .init(a);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const doc = try j.parse(temp, if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes);
        const name = j.text(j.get(doc, "name"));
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, '/') != null or
            !std.mem.eql(u8, name, std.mem.trim(u8, name, " \t\r\n"))) return error.InvalidTheme;
        for (name) |byte| if (std.ascii.isControl(byte)) return error.InvalidTheme;
        const declared = j.get(doc, "appearance");
        const appearance = if (declared == .null) null else std.meta.stringToEnum(terminal.Scheme, j.text(declared)) orelse return error.InvalidTheme;
        const colors = j.get(doc, "colors");
        if (colors != .object) return error.InvalidTheme;
        const input = try j.value(temp, .{
            .definition = .{ .colors = colors, .vars = j.get(doc, "vars"), .appearance = declared },
            .tokens = role_names,
            .appearance = self.env,
            .truecolor = self.truecolor,
        });
        const resolved = try decodePalette(temp, input);
        return .{ .name = try owned.dupe(u8, name), .source = .{ .fixed = .{ .palette = resolved, .appearance = appearance } } };
    }

    pub fn request(self: *Session, writer: *Io.Writer, now: Io.Timestamp) !void {
        self.query = .{};
        self.deadline = now.addDuration(.fromMilliseconds(100));
        self.receiving = true;
        try writer.writeAll(if (self.choice.followsTerminal()) terminal.notifications_on else terminal.notifications_off);
        try writer.writeAll(terminal.query);
        try writer.flush();
    }

    pub fn apply(self: *Session, a: Allocator, pending: bool) !bool {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const input = try j.value(temp, .{
            .foreground = self.colors.foreground,
            .background = self.colors.background,
            .palette = self.colors.palette,
            .appearance = self.reported orelse self.env,
            .truecolor = self.truecolor,
            .pending = pending,
            .tokens = role_names,
        });
        self.system_palette = try decodePalette(temp, input);
        if (!pending) self.initialized = true;
        return self.compose();
    }

    pub fn finish(self: *Session, a: Allocator, complete: bool) !bool {
        if (!self.receiving) return false;
        self.deadline = null;
        self.receiving = !complete;
        const reply = self.query.colors;
        self.colors.foreground = reply.foreground orelse self.colors.foreground;
        self.colors.background = reply.background orelse self.colors.background;
        self.colors.palette = reply.palette orelse self.colors.palette;
        return self.apply(a, false);
    }
};

fn decodePalette(a: Allocator, input: j.Value) !Palette {
    var source: Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll(bundle ++ "\nreturn palette(");
    try emitData(&source.writer, input, 12);
    try source.writer.writeByte(')');
    const document = try registry.parseLuaValue(a, source.written());
    defer document.deinit();
    const colors = j.get(document.value, "colors");
    if (colors != .object) return error.InvalidTerminalTheme;
    const appearance = std.meta.stringToEnum(terminal.Scheme, j.text(j.get(document.value, "appearance"))) orelse return error.InvalidTerminalTheme;
    var result: Palette = .{ .appearance = appearance };
    for (std.enums.values(Role)) |role| {
        const entry = j.get(colors, @tagName(role));
        result.colors.set(role, .{ .color = try parseColor(j.get(entry, "color")), .faint = j.flag(j.get(entry, "faint")) });
    }
    return result;
}

// Theme files supply data only. Encode string bytes as Luau literals even when a theme
// contains quotes, backslashes, Unicode, or characters with a meaning in Luau source.
fn emitString(writer: *Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"', '\\' => try writer.writeAll(&.{ '\\', byte }),
        0...31, 127...255 => try writer.print("\\{d:0>3}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn emitData(writer: *Io.Writer, input: j.Value, depth: u8) !void {
    if (depth == 0) return error.InvalidTheme;
    switch (input) {
        .null => try writer.writeAll("nil"),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .integer => |value| try writer.print("{d}", .{value}),
        .float => |value| {
            if (!std.math.isFinite(value)) return error.InvalidTheme;
            try writer.print("{e}", .{value});
        },
        .string => |value| try emitString(writer, value),
        .array => |list| {
            try writer.writeByte('{');
            for (list.items) |value| {
                try emitData(writer, value, depth - 1);
                try writer.writeByte(',');
            }
            try writer.writeByte('}');
        },
        .object => |object| {
            try writer.writeByte('{');
            for (object.keys(), object.values()) |key, value| {
                try writer.writeByte('[');
                try emitString(writer, key);
                try writer.writeAll("]=");
                try emitData(writer, value, depth - 1);
                try writer.writeByte(',');
            }
            try writer.writeByte('}');
        },
        .number_string => return error.InvalidTheme,
    }
}

fn parseColor(value: j.Value) !?tui.Color {
    return switch (value) {
        .null => null,
        .integer => .{ .indexed = std.math.cast(u8, value.integer) orelse return error.InvalidTerminalTheme },
        .array => |array| color: {
            if (array.items.len != 3) return error.InvalidTerminalTheme;
            var rgb: [3]u8 = undefined;
            for (&rgb, array.items) |*channel, component| {
                if (component != .integer) return error.InvalidTerminalTheme;
                channel.* = std.math.cast(u8, component.integer) orelse return error.InvalidTerminalTheme;
            }
            break :color .{ .rgb = rgb };
        },
        else => error.InvalidTerminalTheme,
    };
}

fn colorFgBg(raw: ?[]const u8) ?terminal.Scheme {
    const value = raw orelse return null;
    const last = if (std.mem.lastIndexOfScalar(u8, value, ';')) |at| value[at + 1 ..] else value;
    if (last.len == 0 or last.len > 2) return null;
    for (last) |c| if (!std.ascii.isDigit(c)) return null;
    const index = std.fmt.parseUnsigned(u8, last, 10) catch return null;
    if (index > 15) return null;
    return if (index <= 6 or index == 8) .dark else .light;
}

fn usesTruecolor(env: *const std.process.Environ.Map) bool {
    const term = env.get("TERM") orelse "";
    const program = env.get("TERM_PROGRAM") orelse "";
    const hint = env.get("COLORTERM") orelse "";
    const advertised = std.ascii.eqlIgnoreCase(hint, "truecolor") or std.ascii.eqlIgnoreCase(hint, "24bit") or std.ascii.endsWithIgnoreCase(term, "-direct");
    if (env.contains("TMUX") or std.ascii.startsWithIgnoreCase(term, "tmux") or
        std.ascii.startsWithIgnoreCase(term, "screen") or std.ascii.eqlIgnoreCase(program, "herdr")) return advertised;
    if (advertised or builtin.os.tag == .windows) return true;
    for ([_][]const u8{ "rex", "kitty", "ghostty", "wezterm", "warpterminal", "iterm.app", "alacritty", "vscode", "zed" }) |known| {
        if (std.ascii.eqlIgnoreCase(program, known)) return true;
    }
    for ([_][]const u8{ "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "WEZTERM_PANE", "WARP_SESSION_ID", "WARP_TERMINAL_SESSION_UUID", "ITERM_SESSION_ID", "WT_SESSION", "ALACRITTY_WINDOW_ID" }) |name| {
        if (env.get(name)) |value| {
            if (value.len != 0) return true;
        }
    }
    for (0..term.len) |start| {
        if (std.ascii.startsWithIgnoreCase(term[start..], "ghostty")) return true;
    }
    return std.ascii.startsWithIgnoreCase(term, "alacritty") or
        std.ascii.eqlIgnoreCase(env.get("TERMINAL_EMULATOR") orelse "", "jetbrains-jediterm") or
        (std.ascii.eqlIgnoreCase(program, "orca") and std.mem.eql(u8, env.get("ORCA_IMAGE_PROTOCOL") orelse "", "kitty"));
}
