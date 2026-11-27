const std = @import("std");
const kit = @import("kit");
const UiPresentation = @import("../UiPresentation.zig");
const Skills = @import("../../skills.zig");
const FileReferences = @import("FileReferences.zig");
const Notification = @import("../UiWake.zig").Notification;
const Item = kit.tui.select_list.Item;
const List = kit.tui.select_list.List;
const A = std.mem.Allocator;
const Self = @This();

arena: std.heap.ArenaAllocator,
match: Match,
list: List,

pub const Match = struct {
    start: usize,
    query: []const u8,
    kind: union(enum) { command, argument: UiPresentation.Command.ArgumentCompletion, path, reference },
};

fn trimLeadingSpace(line: []const u8) []const u8 {
    var remaining = line;
    while (kit.unicode.decodeUtf8Lossy(remaining)) |scalar| {
        if (!kit.unicode.isEcmaWhitespace(scalar.codepoint)) break;
        remaining = remaining[scalar.len..];
    }
    return remaining;
}

/// Automatic opening is driven by the character that was typed. An open
/// picker refreshes on other edits as well.
pub fn triggered(presentation: *const UiPresentation, before_cursor: []const u8, cp: u21) ?Match {
    if (cp < 128) {
        const byte: u8 = @intCast(cp);
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "/@.-_", byte) == null) return null;
    } else if (!kit.unicode.isCjk(cp)) return null;
    const m = context(presentation, before_cursor, false) orelse return null;
    if (cp == '/' and (m.kind != .command or m.query.len != 0)) return null;
    if (cp == '@' and m.kind != .reference) return null;
    return m;
}

pub fn context(presentation: *const UiPresentation, before_cursor: []const u8, tab: bool) ?Match {
    const line_start = if (std.mem.lastIndexOfScalar(u8, before_cursor, '\n')) |offset| offset + 1 else 0;
    const line = before_cursor[line_start..];
    if (FileReferences.referenceStart(line)) |start|
        return .{ .start = line_start + start, .query = line[start..], .kind = .reference };
    const trimmed = trimLeadingSpace(line);
    if (std.mem.startsWith(u8, trimmed, "/")) {
        const start = line_start + line.len - trimmed.len;
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space| {
            const argument = trimmed[space + 1 ..];
            if (!tab) {
                if (line_start != 0) return null;
                const command = presentation.command(trimmed[0..space]) orelse return null;
                const completion = command.completion orelse return null;
                return .{ .start = start + space + 1, .query = argument, .kind = .{ .argument = completion } };
            }
            if (trimLeadingSpace(argument).len == 0) return null;
        } else return if (line_start == 0) .{ .start = start, .query = trimmed[1..], .kind = .command } else null;
    }
    if (!tab) return null;
    const start = FileReferences.pathStart(line);
    return .{ .start = line_start + start, .query = line[start..], .kind = .path };
}

const Ranked = struct {
    item: Item,
    group: u1,
    score: i64,
    order: usize,

    fn less(_: void, left: Ranked, right: Ranked) bool {
        if (left.group != right.group) return left.group < right.group;
        if (left.score != right.score) return left.score < right.score;
        return left.order < right.order;
    }

    fn pathLess(_: void, left: Ranked, right: Ranked) bool {
        const left_dir = std.mem.endsWith(u8, left.item.label, "/");
        const right_dir = std.mem.endsWith(u8, right.item.label, "/");
        if (left_dir != right_dir) return left_dir;
        return std.ascii.orderIgnoreCase(left.item.label, right.item.label) == .lt;
    }
};

pub const Candidates = struct {
    a: A,
    query: []const u8,
    ranked: std.ArrayList(Ranked) = .empty,

    /// Values and labels must stay alive for the resulting menu. The search
    /// fields are consumed immediately, and descriptions are normalized here.
    pub fn add(self: *Candidates, item: Item, search: []const u8, alternate: ?[]const u8) !void {
        const primary = kit.tui.fuzzy.score(self.query, search);
        const score = primary orelse if (alternate) |text| kit.tui.fuzzy.score(self.query, text) orelse return else return;
        try self.ranked.append(self.a, .{
            .item = .{
                .value = item.value,
                .label = item.label,
                .description = if (item.description.len == 0) "" else try singleLine(self.a, item.description),
            },
            .group = @intFromBool(primary == null),
            .score = score,
            .order = self.ranked.items.len,
        });
    }

    pub fn finish(self: *Candidates, m: Match) !List {
        if (m.kind == .path) std.mem.sort(Ranked, self.ranked.items, {}, Ranked.pathLess) else std.mem.sort(Ranked, self.ranked.items, {}, Ranked.less);
        const items = try self.a.alloc(Item, self.ranked.items.len);
        for (self.ranked.items, items) |entry, *item| item.* = entry.item;
        return select(items, m);
    }
};

fn select(items: []const Item, m: Match) List {
    var selected: ?usize = null;
    if (m.kind != .command) for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.value, m.query)) {
            selected = i;
            break;
        }
        if (selected == null and std.mem.startsWith(u8, item.value, m.query)) selected = i;
    };
    const slash_prefix = m.kind == .command or std.mem.startsWith(u8, m.query, "/");
    return .{ .items = items, .selected = selected orelse 0, .min_primary = if (slash_prefix) 12 else 32 };
}

pub const Lookup = struct {
    io: std.Io,
    notification: Notification,
    future: std.Io.Future(anyerror!void) = undefined,
    done: std.Io.Event = .unset,
    menu: Self,
    draft: []const u8,
    cursor: usize,
    workspace: []const u8,
    home: []const u8,
    explicit_tab: bool,
    pending_keys: std.ArrayList(kit.terminal.keys.Key) = .empty,

    pub fn start(a: A, io: std.Io, notification: Notification, m: Match, draft: []const u8, cursor: usize, workspace: []const u8, home: []const u8, explicit_tab: bool) !*Lookup {
        const lookup = try a.create(Lookup);
        errdefer a.destroy(lookup);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const own = arena.allocator();
        const snapshot = try own.dupe(u8, draft);
        const owned_workspace = try own.dupe(u8, workspace);
        const owned_home = try own.dupe(u8, home);
        lookup.* = .{
            .io = io,
            .notification = notification,
            .menu = .{ .arena = arena, .match = .{ .start = m.start, .query = snapshot[m.start..cursor], .kind = m.kind }, .list = .{ .items = &.{} } },
            .draft = snapshot,
            .cursor = cursor,
            .workspace = owned_workspace,
            .home = owned_home,
            .explicit_tab = explicit_tab,
        };
        lookup.future = try io.concurrent(run, .{lookup});
        return lookup;
    }

    pub fn destroy(self: *Lookup, a: A) void {
        self.future.cancel(self.io) catch {};
        self.menu.arena.deinit();
        self.pending_keys.deinit(a);
        a.destroy(self);
    }

    fn run(self: *Lookup) anyerror!void {
        defer {
            self.done.set(self.io);
            self.notification.signal();
        }
        const a = self.menu.arena.allocator();
        const m = self.menu.match;
        if (m.kind == .path) {
            var items: Candidates = .{ .a = a, .query = m.query };
            try paths(&items, self.io, self.workspace, self.home);
            self.menu.list = try items.finish(m);
        } else {
            if (!self.explicit_tab) try std.Io.sleep(self.io, .fromMilliseconds(20), .awake);
            const matches = try FileReferences.suggestions(a, self.io, self.workspace, self.home, m.query);
            self.menu.list = select(matches, m);
        }
    }
};

fn singleLine(a: A, bytes: []const u8) ![]const u8 {
    const copy = try kit.tui.Editor.normalize(a, bytes);
    for (copy) |*b| if (b.* == '\n') {
        b.* = ' ';
    };
    return std.mem.trim(u8, copy, " ");
}

pub fn commands(presentation: *const UiPresentation, items: *Candidates, skills: *const Skills, enable_skill_commands: bool) !void {
    for (presentation.commands) |entry| {
        const name = entry.name[1..];
        try items.add(.{ .value = name, .label = name, .description = entry.description }, name, null);
    }
    if (!enable_skill_commands) return;
    for (skills.skills) |skill| {
        const name = try std.fmt.allocPrint(items.a, "skill:{s}", .{skill.name});
        const scope = switch (skill.source.scope) {
            .project => "p",
            .user => "u",
            .temporary => "t",
        };
        const desc = try std.fmt.allocPrint(items.a, "[{s}] {s}", .{ scope, skill.description });
        try items.add(.{ .value = name, .label = name, .description = desc }, skill.name, name);
    }
}

fn paths(items: *Candidates, io: std.Io, cwd: []const u8, home: []const u8) !void {
    const quoted = std.mem.startsWith(u8, items.query, "\"");
    const raw = if (quoted) items.query[1..] else items.query;
    const slash = if (std.mem.lastIndexOfScalar(u8, raw, '/')) |index| index + 1 else 0;
    const prefix = if (std.mem.eql(u8, raw, "~")) "~/" else raw[0..slash];
    const fragment = if (std.mem.eql(u8, raw, "~")) "" else raw[slash..];
    const directory = if (std.mem.startsWith(u8, prefix, "~/"))
        try std.fs.path.join(items.a, &.{ home, prefix[2..] })
    else if (std.fs.path.isAbsolute(prefix)) prefix else try std.fs.path.join(items.a, &.{ cwd, prefix });
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    items.query = "";
    while (iterator.next(io) catch |err| switch (err) {
        error.Canceled => return err,
        else => null,
    }) |entry| {
        if (!std.ascii.startsWithIgnoreCase(entry.name, fragment) or !try FileReferences.canInsert(items.a, entry.name)) continue;
        const is_dir = entry.kind == .directory or (entry.kind == .sym_link and blk: {
            const stat = dir.statFile(io, entry.name, .{}) catch break :blk false;
            break :blk stat.kind == .directory;
        });
        const label = try std.fmt.allocPrint(items.a, "{s}{s}", .{ entry.name, if (is_dir) "/" else "" });
        const q = if (quoted or FileReferences.needsQuotes(label)) "\"" else "";
        const value = try std.fmt.allocPrint(items.a, "{s}{s}{s}{s}", .{ q, prefix, label, q });
        try items.add(.{ .value = value, .label = label }, "", null);
    }
}
