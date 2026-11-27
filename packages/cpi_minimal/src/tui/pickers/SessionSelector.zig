const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const Theme = @import("../style.zig").Theme;
const Index = @import("../../session.zig").SessionIndex;
const Controller = @import("../../session.zig").Controller;
const Query = @import("SessionSearch.zig");
const trim = @import("../../session.zig").SessionName.trimWhitespace;
const md = @import("../transcript.zig").markdown;
const Presentation = @import("../UiPresentation.zig");
const Frame = Presentation.Frame;
const ComposerView = @import("../composer.zig").ComposerView;
const Notification = @import("../UiWake.zig").Notification;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Key = kit.terminal.keys.Key;
const Self = @This();
const page = 10;
const measure = kit.terminal.span_display_width.measure;

a: Allocator,
io: Io,
notification: Notification,
source: Index.Source,
loads: std.EnumArray(Index.Scope, ?*Load) = .initFill(null),
scope: Index.Scope = .current,
sort: Sort = .threaded,
named: bool = false,
show_path: bool = false,
allow_rename: bool = true,
editor: tui.Editor,
rename_editor: tui.Editor,
mode: Mode = .list,
mutation: ?*Mutation = null,
status: ?Status = null,
path_arena: std.heap.ArenaAllocator,
row_arena: std.heap.ArenaAllocator,
rows: []const Row = &.{},
selected: usize = 0,
selection_touched: bool = false,
pending_selection: ?[]const u8 = null,
reload_selection: ?[]u8 = null,

const Sort = enum { threaded, recent, fuzzy };
const Row = struct {
    session: *const Index.Session,
    score: i64 = 0,
    parent: ?usize = null,
    last: bool = true,
};
const Mode = union(enum) {
    list,
    rename: *const Index.Session,
    confirm_delete: *const Index.Session,
};
const Status = struct {
    text: []u8,
    role: Theme.Role,
    until: Io.Timestamp,
};
pub const Rename = struct { session: *const Index.Session, name: []const u8 };
pub const Action = union(enum) {
    none,
    cancel,
    select: *const Index.Session,
    rename: Rename,
    delete: *const Index.Session,
};

const Mutation = struct {
    a: Allocator,
    io: Io,
    notification: Notification,
    target: Controller.SavedSession,
    name: ?[]const u8,
    arena: std.heap.ArenaAllocator,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    result: anyerror!Outcome = undefined,

    const Outcome = enum { renamed, trash, unlink };

    fn start(a: Allocator, io: Io, target: Controller.SavedSession, name: ?[]const u8, notification: Notification) !*Mutation {
        const mutation = try a.create(Mutation);
        errdefer a.destroy(mutation);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const own = arena.allocator();
        mutation.* = .{
            .a = a,
            .io = io,
            .notification = notification,
            .target = .{ .path = try own.dupe(u8, target.path), .id = try own.dupe(u8, target.id), .inode = target.inode },
            .name = if (name) |value| try own.dupe(u8, value) else null,
            .arena = arena,
        };
        mutation.future = try io.concurrent(run, .{mutation});
        return mutation;
    }

    fn run(self: *Mutation) void {
        self.result = self.perform();
        self.done.set(self.io);
        self.notification.signal();
    }

    fn perform(self: *Mutation) !Outcome {
        if (self.name) |name| {
            try Controller.renameSavedSession(self.a, self.io, self.target, name);
            return .renamed;
        }
        return switch (try Controller.deleteSavedSession(self.a, self.io, self.target)) {
            .trash => .trash,
            .unlink => .unlink,
        };
    }

    fn destroy(self: *Mutation) void {
        self.future.cancel(self.io);
        self.arena.deinit();
        self.a.destroy(self);
    }
};
const Load = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    io: Io,
    source: Index.Source,
    scope: Index.Scope,
    notification: Notification,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    loaded: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*const Index.Session) = .empty,
    result: anyerror!void = {},
    applied: ?usize = null,
    applied_done: bool = false,

    fn start(a: Allocator, io: Io, source: Index.Source, scope: Index.Scope, notify: Notification) !*Load {
        const load = try a.create(Load);
        errdefer a.destroy(load);
        load.* = .{ .arena = .init(a), .gpa = a, .io = io, .source = source, .scope = scope, .notification = notify };
        errdefer load.arena.deinit();
        load.future = try io.concurrent(run, .{load});
        return load;
    }

    fn destroy(load: *Load) void {
        load.future.cancel(load.io);
        load.arena.deinit();
        load.gpa.destroy(load);
    }

    fn run(load: *Load) void {
        load.result = Index.load(load.arena.allocator(), load.gpa, load.io, load.source, load.scope, load);
        load.done.set(load.io);
        load.notification.signal();
    }

    pub fn add(load: *Load, session: *const Index.Session) !void {
        try load.mutex.lock(load.io);
        defer load.mutex.unlock(load.io);
        try load.sessions.append(load.arena.allocator(), session);
    }

    fn snapshot(load: *Load, a: Allocator) ![]*const Index.Session {
        load.mutex.lockUncancelable(load.io);
        defer load.mutex.unlock(load.io);
        return a.dupe(*const Index.Session, load.sessions.items);
    }

    pub fn update(load: *Load, loaded: usize, total: usize) void {
        if (loaded == 0) load.total.store(total, .release);
        load.loaded.store(loaded, .release);
        if (loaded <= 1 or loaded % 8 == 0) load.notification.signal();
    }
};

pub fn open(a: Allocator, io: Io, source: Index.Source, notification: Notification) !Self {
    var self: Self = .{
        .a = a,
        .io = io,
        .notification = notification,
        .source = source,
        .editor = .initWithEditingHistory(a),
        .rename_editor = .initWithEditingHistory(a),
        .path_arena = .init(a),
        .row_arena = .init(a),
    };
    errdefer self.deinit();
    if (self.source.current) |path| self.source.current = Io.Dir.cwd().realPathFileAlloc(io, path, self.path_arena.allocator()) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => path,
    };
    try self.begin();
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.mutation) |job| job.destroy();
    self.clearStatus();
    self.rename_editor.deinit();
    if (self.reload_selection) |path| self.a.free(path);
    for (self.loads.values) |job| if (job) |load| load.destroy();
    self.path_arena.deinit();
    self.row_arena.deinit();
    self.editor.deinit();
}

fn begin(self: *Self) !void {
    const slot = self.loads.getPtr(self.scope);
    if (slot.* == null) slot.* = try Load.start(self.a, self.io, self.source, self.scope, self.notification);
}

pub fn advance(self: *Self) !void {
    if (self.status) |status| {
        if (Io.Timestamp.now(self.io, .awake).compare(.gte, status.until)) self.clearStatus();
    }
    if (self.mutation) |job| if (job.done.isSet()) {
        const result = job.result;
        const rename = job.name != null;
        self.mutation = null;
        defer job.destroy();
        self.mode = .list;
        if (result) |outcome| {
            switch (outcome) {
                .renamed => {},
                .trash => try self.setStatus("Session moved to trash", .accent, 2),
                .unlink => try self.setStatus("Session deleted", .accent, 2),
            }
            try self.reload(if (outcome == .renamed) null else job.target.path);
        } else |err| try self.reportMutationError(if (rename) "rename" else "delete", err);
    };
    const load = self.loads.get(self.scope) orelse return;
    const count = load.loaded.load(.acquire);
    const done = load.done.isSet();
    if (load.applied == count and load.applied_done == done) return;
    try self.refilter(.update);
    load.applied = count;
    load.applied_done = done;
}

fn clearStatus(self: *Self) void {
    if (self.status) |previous| self.a.free(previous.text);
    self.status = null;
}

fn setStatus(self: *Self, text: []const u8, role: Theme.Role, seconds: i64) !void {
    const owned = try self.a.dupe(u8, text);
    self.clearStatus();
    self.status = .{
        .text = owned,
        .role = role,
        .until = Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(seconds)),
    };
}

pub fn deadline(self: *const Self) ?Io.Timestamp {
    return if (self.status) |status| status.until else null;
}

pub fn reportMutationError(self: *Self, operation: []const u8, err: anyerror) !void {
    const details: []const u8 = switch (err) {
        error.JournalLocked => "Session is open in another process",
        error.JournalReplaced => "Session file changed after selection",
        error.FileNotFound => "Session file no longer exists",
        else => @errorName(err),
    };
    const text = try std.fmt.allocPrint(self.a, "Failed to {s}: {s}", .{ operation, details });
    defer self.a.free(text);
    try self.setStatus(text, .@"error", 3);
    self.mode = .list;
}

fn currentRow(self: *const Self) ?*const Index.Session {
    return if (self.selected < self.rows.len) self.rows[self.selected].session else null;
}

pub fn isCurrent(self: *const Self, path: []const u8) bool {
    return if (self.source.current) |current| std.mem.eql(u8, current, path) else false;
}

pub fn reload(self: *Self, removed: ?[]const u8) !void {
    var previous = self.pending_selection orelse if (self.currentRow()) |row| row.path else null;
    if (removed) |path| {
        if (previous != null and std.mem.eql(u8, previous.?, path)) {
            previous = if (self.selected + 1 < self.rows.len)
                self.rows[self.selected + 1].session.path
            else if (self.selected != 0 and self.selected <= self.rows.len)
                self.rows[self.selected - 1].session.path
            else
                null;
        }
    }
    const retained = if (previous) |path| try self.a.dupe(u8, path) else null;
    if (self.reload_selection) |path| self.a.free(path);
    self.reload_selection = retained;
    self.pending_selection = retained;
    self.mode = .list;
    self.rows = &.{};
    for (&self.loads.values) |*slot| {
        if (slot.*) |job| job.destroy();
        slot.* = null;
    }
    try self.begin();
}

pub fn mutate(self: *Self, session: *const Index.Session, name: ?[]const u8) !void {
    self.mutation = try Mutation.start(self.a, self.io, session.target(), name, self.notification);
    if (name == null) self.mode = .list;
}

fn confirmDelete(self: *Self) !void {
    const session = self.currentRow() orelse return;
    if (self.isCurrent(session.path)) {
        try self.setStatus("Cannot delete the currently active session", .@"error", 3);
        return;
    }
    self.mode = .{ .confirm_delete = session };
}

pub fn paste(self: *Self, a: Allocator, bytes: []const u8) !void {
    if (self.mutation != null or self.mode == .confirm_delete) return;
    const clean = try singleLine(a, bytes);
    if (self.mode == .rename) return self.rename_editor.insert(clean);
    try self.editor.insert(clean);
    try self.refilter(.query);
}

fn inputKey(editor: *tui.Editor, k: Key) !void {
    if (try editor.editKey(k) or k.code != .char or k.mods.ctrl or k.mods.alt) return;
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(k.code.char, &bytes);
    try editor.typeText(bytes[0..length]);
}

pub fn key(self: *Self, k: Key) !Action {
    const mods = k.mods;
    if (mods.meta or mods.super or mods.hyper or self.mutation != null) return .none;
    const plain = !mods.ctrl and !mods.alt and !mods.shift;
    const cancel = (plain and k.code == .escape) or (mods.ctrl and !mods.alt and !mods.shift and k.code == .char and k.code.char == 'c');
    switch (self.mode) {
        .rename => |session| {
            if (cancel) {
                self.mode = .list;
            } else if (plain and k.code == .enter) {
                const name = trim(self.rename_editor.text());
                if (name.len != 0) return .{ .rename = .{ .session = session, .name = name } };
            } else try inputKey(&self.rename_editor, k);
            return .none;
        },
        .confirm_delete => |session| {
            if (cancel) self.mode = .list;
            if (plain and k.code == .enter) return .{ .delete = session };
            return .none;
        },
        .list => {},
    }
    if (!mods.ctrl and !mods.alt and !mods.shift) switch (k.code) {
        .escape => return .cancel,
        .enter => return if (self.currentRow()) |session| .{ .select = session } else .none,
        .tab => {
            self.scope = if (self.scope == .current) .all else .current;
            try self.begin();
            try self.refilter(.update);
            return .none;
        },
        .up, .down, .page_up, .page_down => {
            self.selection_touched = true;
            self.pending_selection = null;
            const delta: usize = if (k.code == .page_up or k.code == .page_down) page else 1;
            self.selected = if (k.code == .up or k.code == .page_up) self.selected -| delta else @min(self.selected + delta, self.rows.len -| 1);
            return .none;
        },
        else => {},
    };
    if (k.code == .char and mods.ctrl and !mods.alt and !mods.shift) switch (k.code.char) {
        'c' => return .cancel,
        'd' => {
            try self.confirmDelete();
            return .none;
        },
        'r' => {
            if (!self.allow_rename) return .none;
            const load = self.loads.get(self.scope) orelse return .none;
            if (!load.done.isSet()) return .none;
            if (self.currentRow()) |session| {
                const old_cursor = self.rename_editor.cursor;
                try self.rename_editor.set(session.name);
                var cursor: usize = 0;
                while (cursor < self.rename_editor.text().len) {
                    const next = self.rename_editor.following(cursor);
                    if (next > old_cursor) break;
                    cursor = next;
                }
                self.rename_editor.cursor = cursor;
                self.mode = .{ .rename = session };
            }
            return .none;
        },
        's' => {
            self.sort = switch (self.sort) {
                .threaded => .recent,
                .recent => .fuzzy,
                .fuzzy => .threaded,
            };
            try self.refilter(.options);
            return .none;
        },
        'n' => {
            self.named = !self.named;
            try self.refilter(.options);
            return .none;
        },
        'p' => {
            self.show_path = !self.show_path;
            return .none;
        },
        else => {},
    };
    if (k.code == .backspace and mods.ctrl and !mods.alt and !mods.shift) {
        if (self.editor.text().len == 0) try self.confirmDelete();
        return .none;
    }
    const previous = self.editor.revision;
    try inputKey(&self.editor, k);
    if (self.editor.revision != previous) try self.refilter(.query);
    return .none;
}

fn refilter(self: *Self, source: enum { query, options, update }) !void {
    var next: std.heap.ArenaAllocator = .init(self.a);
    errdefer next.deinit();
    const a = next.allocator();
    var temporary: std.heap.ArenaAllocator = .init(self.a);
    defer temporary.deinit();
    const load = self.loads.get(self.scope);
    const index: []*const Index.Session = if (load) |job| try job.snapshot(temporary.allocator()) else &.{};
    std.mem.sort(*const Index.Session, index, {}, Index.newer);
    const old_selected = if (self.selected < self.rows.len) self.rows[self.selected].session.path else null;
    const pattern = trim(self.editor.text());
    const rows = if (self.sort == .threaded and pattern.len == 0)
        try threaded(self.a, a, index, self.named)
    else
        try filtered(self.a, a, index, pattern, self.named, self.sort != .recent);
    self.row_arena.deinit();
    self.row_arena = next;
    self.rows = rows;
    self.selected = @min(self.selected, rows.len -| 1);
    if (source == .query and pattern.len != 0) {
        self.selected = 0;
        self.selection_touched = false;
        self.pending_selection = null;
    } else if (source == .update) {
        if (!self.selection_touched) {
            self.selected = 0;
        } else if (self.pending_selection orelse old_selected) |previous| {
            self.pending_selection = null;
            for (rows, 0..) |row, i| {
                if (!std.mem.eql(u8, row.session.path, previous)) continue;
                self.selected = i;
                break;
            } else if (load) |job| {
                if (!job.done.isSet()) self.pending_selection = previous;
            }
        }
    }
}

fn filtered(gpa: Allocator, a: Allocator, sessions: []const *const Index.Session, pattern: []const u8, named: bool, relevance: bool) ![]Row {
    var temporary: std.heap.ArenaAllocator = .init(gpa);
    defer temporary.deinit();
    const query = try Query.init(temporary.allocator(), pattern);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var rows: std.ArrayList(Row) = .empty;
    for (sessions) |session| {
        if (named and session.name.len == 0) continue;
        _ = scratch.reset(.{ .retain_with_limit = 64 * 1024 });
        if (try query.score(scratch.allocator(), session)) |score| try rows.append(a, .{ .session = session, .score = score });
    }
    if (relevance and pattern.len != 0) std.mem.sort(Row, rows.items, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            if (left.score != right.score) return left.score < right.score;
            return left.session.modified_ms > right.session.modified_ms;
        }
    }.less);
    return rows.items;
}

fn threaded(gpa: Allocator, a: Allocator, sessions: []const *const Index.Session, named: bool) ![]Row {
    var temporary: std.heap.ArenaAllocator = .init(gpa);
    defer temporary.deinit();
    const tmp = temporary.allocator();
    const Node = struct {
        key: usize,
        activity: i64,
        parent: ?usize = null,
        outstanding: usize = 0,
        children: std.ArrayList(usize) = .empty,
    };
    var paths: std.StringHashMapUnmanaged(usize) = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    for (sessions, 0..) |session, i| {
        if (named and session.name.len == 0) continue;
        try paths.put(tmp, session.path, nodes.items.len);
        try nodes.append(tmp, .{ .key = i, .activity = session.modified_ms });
    }
    for (nodes.items) |*node| {
        const parent = paths.get(sessions[node.key].parent orelse continue) orelse continue;
        node.parent = parent;
        nodes.items[parent].outstanding += 1;
    }
    var leaves: std.ArrayList(usize) = .empty;
    for (nodes.items, 0..) |node, i| if (node.outstanding == 0) try leaves.append(tmp, i);
    while (leaves.pop()) |i| {
        const parent = &nodes.items[nodes.items[i].parent orelse continue];
        parent.activity = @max(parent.activity, nodes.items[i].activity);
        parent.outstanding -= 1;
        if (parent.outstanding == 0) try leaves.append(tmp, nodes.items[i].parent.?);
    }
    const order = try tmp.alloc(usize, nodes.items.len);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, nodes.items, struct {
        fn less(all: []const Node, left: usize, right: usize) bool {
            if (all[left].activity != all[right].activity) return all[left].activity > all[right].activity;
            return all[left].key < all[right].key;
        }
    }.less);
    const Link = struct { index: usize, parent: ?usize = null, last: bool = true };
    var pending: std.ArrayList(Link) = .empty;
    for (order) |i| {
        const node = nodes.items[i];
        // A legacy or damaged ancestry cycle must remain navigable as roots.
        if (node.outstanding == 0) if (node.parent) |parent| {
            try nodes.items[parent].children.append(tmp, i);
            continue;
        };
        try pending.append(tmp, .{ .index = i });
    }
    std.mem.reverse(Link, pending.items);
    var rows: std.ArrayList(Row) = .empty;
    while (pending.pop()) |link| {
        const parent = rows.items.len;
        const node = nodes.items[link.index];
        try rows.append(a, .{ .session = sessions[node.key], .parent = link.parent, .last = link.last });
        const children = node.children.items;
        var i = children.len;
        while (i != 0) {
            i -= 1;
            try pending.append(tmp, .{ .index = children[i], .parent = parent, .last = i + 1 == children.len });
        }
    }
    return rows.items;
}

fn singleLine(a: Allocator, raw: []const u8) ![]const u8 {
    const clean = try a.dupe(u8, try md.clean(a, raw));
    for (clean) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
    return clean;
}

fn clipped(a: Allocator, text: []const u8, width: u16) ![]const u8 {
    const part = tui.layout.clipColumns(text, width);
    if (part.len == text.len or width == 0) return part;
    return std.mem.concat(a, u8, &.{ tui.layout.clipColumns(text, width - 1), "…" });
}

fn line(bytes: []const u8, style: tui.Style) tui.Node {
    return .{ .text = .{ .bytes = bytes, .style = style, .overflow = .clip } };
}

fn styled(out: *std.Io.Writer, bytes: []const u8, style: tui.Style) !void {
    if (bytes.len == 0) return;
    var sgr: [96]u8 = undefined;
    try out.writeAll(style.sgr(&sgr));
    try out.writeAll(bytes);
    try out.writeAll("\x1b[0m");
}

const Span = struct { text: []const u8, role: Theme.Role };

fn spans(out: *Io.Writer, fields: []const Span, width: u16, theme: *const Theme.Palette) !void {
    var remaining = width;
    for (fields) |field| {
        const part = tui.layout.clipColumns(field.text, remaining);
        try styled(out, part, theme.style(field.role));
        remaining -|= @intCast(@min(remaining, measure(part)));
        if (part.len < field.text.len or remaining == 0) break;
    }
}

fn age(a: Allocator, elapsed: i64) ![]const u8 {
    const minute = @divFloor(@max(0, elapsed), 60_000);
    if (minute == 0) return "now";
    if (minute < 60) return std.fmt.allocPrint(a, "{d}m", .{minute});
    const hour = @divFloor(minute, 60);
    if (hour < 24) return std.fmt.allocPrint(a, "{d}h", .{hour});
    const day = @divFloor(hour, 24);
    if (day < 7) return std.fmt.allocPrint(a, "{d}d", .{day});
    if (day < 30) return std.fmt.allocPrint(a, "{d}w", .{@divFloor(day, 7)});
    if (day < 365) return std.fmt.allocPrint(a, "{d}mo", .{@divFloor(day, 30)});
    return std.fmt.allocPrint(a, "{d}y", .{@divFloor(day, 365)});
}

fn shortPath(a: Allocator, value: []const u8, home: []const u8) ![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, value, home)) return singleLine(a, value);
    if (value.len == home.len) return "~";
    if (value[home.len] != '/') return singleLine(a, value);
    return std.fmt.allocPrint(a, "~{s}", .{try singleLine(a, value[home.len..])});
}

fn drawRow(self: *const Self, a: Allocator, index: usize, width: u16, theme: *const Theme.Palette, home: []const u8, now: i64) !tui.Node {
    const row = self.rows[index];
    const session = row.session;
    const selected = index == self.selected;
    const fill = if (selected) theme.color(.selectedBg) else null;
    const current = self.isCurrent(session.path);
    const deleting = self.mode == .confirm_delete and std.mem.eql(u8, self.mode.confirm_delete.path, session.path);
    var prefix: std.ArrayList([]const u8) = .empty;
    if (row.parent) |p| {
        try prefix.append(a, if (row.last) "└─ " else "├─ ");
        var cursor = p;
        while (true) {
            const ancestor = self.rows[cursor];
            try prefix.append(a, if (ancestor.last or ancestor.parent == null) "   " else "│  ");
            cursor = ancestor.parent orelse break;
        }
        std.mem.reverse([]const u8, prefix.items);
    }
    const branch = try std.mem.concat(a, u8, prefix.items);
    var right = try std.fmt.allocPrint(a, "{d} {s}", .{ session.message_count, try age(a, now -| session.modified_ms) });
    if (self.scope == .all and session.workspace.len != 0)
        right = try std.fmt.allocPrint(a, "{s} {s}", .{ try shortPath(a, session.workspace, home), right });
    if (self.show_path)
        right = try std.fmt.allocPrint(a, "{s} {s}", .{ try shortPath(a, session.path, home), right });
    const name = trim(try singleLine(a, if (session.name.len != 0) session.name else session.first_message));
    const label = try clipped(a, name, @max(10, width -| @as(u16, @intCast(@min(65535, 4 + measure(branch) + measure(right))))));
    const spaces = @max(1, @as(usize, width) -| (2 + measure(branch) + measure(label) + measure(right)));
    var heading = if (deleting) theme.style(.@"error") else if (current) theme.style(.accent) else if (session.name.len != 0) theme.style(.warning) else tui.Style{};
    heading.bold = selected;
    heading.background = fill;
    var dim = theme.style(.dim);
    dim.background = fill;
    var accent = theme.style(.accent);
    accent.background = fill;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try styled(&out.writer, if (selected) "› " else "  ", accent);
    try styled(&out.writer, branch, dim);
    try styled(&out.writer, label, heading);
    const padding = try a.alloc(u8, spaces);
    @memset(padding, ' ');
    try styled(&out.writer, padding, dim);
    var detail = if (deleting) theme.style(.@"error") else dim;
    detail.background = fill;
    try styled(&out.writer, right, detail);
    const text = try out.toOwnedSlice();
    // The right column has the same anchor regardless of which item is selected.
    return line(text, .{});
}

const StatusView = struct { text: []const u8, role: Theme.Role };

pub fn draw(self: *const Self, a: Allocator, out: *std.ArrayList(tui.Node), width: u16, theme: *const Theme.Palette, home: []const u8, now: i64, hardware: bool, pickers: *const Presentation.Pickers) !void {
    if (self.mode == .rename) {
        try Frame.append(a, out, pickers.rename_session.before, width, theme);
        try out.append(a, try ComposerView.inputLine(a, &self.rename_editor, "> ", width, hardware));
        try Frame.append(a, out, pickers.rename_session.after, width, theme);
        return;
    }
    const labels = &pickers.resume_picker;
    const scope = if (self.scope == .current) labels.current else labels.all;
    try Frame.append(a, out, labels.frame.before, width, theme);
    const load = self.loads.get(self.scope);
    const loading = load != null and !load.?.done.isSet();
    const load_text = if (loading) blk: {
        const total = load.?.total.load(.acquire);
        break :blk if (total == 0) "Loading ..." else try std.fmt.allocPrint(a, "Loading {d}/{d}", .{ load.?.loaded.load(.acquire), total });
    } else null;
    const local = self.scope == .current and !loading;
    const right = [_]Span{
        .{ .text = if (local) "◉ Current Folder" else "○ Current Folder", .role = if (local) .accent else .muted },
        .{ .text = " | ", .role = .muted },
        .{ .text = load_text orelse if (local) "○ All" else "◉ All", .role = if (local) .muted else .accent },
        .{ .text = "  Name: ", .role = .muted },
        .{ .text = if (self.named) "Named" else "All", .role = .accent },
        .{ .text = "  Sort: ", .role = .muted },
        .{ .text = switch (self.sort) {
            .threaded => "Threaded",
            .recent => "Recent",
            .fuzzy => "Fuzzy",
        }, .role = .accent },
    };
    var needed: usize = 0;
    for (right) |field| needed += measure(field.text);
    const right_width: u16 = @intCast(@min(width, needed));
    const title_part = tui.layout.clipColumns(scope.title, width -| right_width -| 1);
    var header: Io.Writer.Allocating = .init(a);
    defer header.deinit();
    try styled(&header.writer, title_part, .{ .bold = true });
    try header.writer.splatByteAll(' ', @as(usize, width) -| (measure(title_part) + right_width));
    try spans(&header.writer, &right, width, theme);
    try out.append(a, line(try header.toOwnedSlice(), .{}));
    const load_error: ?anyerror = if (load != null and load.?.done.isSet()) blk: {
        load.?.result catch |err| break :blk err;
        break :blk null;
    } else null;
    const hints = if (self.mode == .confirm_delete) StatusView{
        .text = labels.delete_confirmation,
        .role = .@"error",
    } else if (self.status) |status| StatusView{
        .text = status.text,
        .role = status.role,
    } else if (load_error) |err| StatusView{
        .text = try std.fmt.allocPrint(a, "Failed to load sessions: {s}", .{@errorName(err)}),
        .role = .@"error",
    } else null;
    if (hints) |hint| {
        try out.append(a, line(try clipped(a, hint.text, width), theme.style(hint.role)));
        try out.append(a, .{ .spacer = 1 });
    } else {
        try out.append(a, line(try clipped(a, labels.search_hint, width), theme.style(.muted)));
        const rename = if (self.allow_rename) labels.rename_hint else "";
        const binding = try std.mem.concat(a, u8, &.{ labels.bindings, labels.path_hint[@intFromBool(self.show_path)], rename });
        try out.append(a, line(try clipped(a, binding, width), theme.style(.muted)));
    }
    try out.appendSlice(a, &.{ .{ .spacer = 1 }, try ComposerView.inputLine(a, &self.editor, "> ", width, hardware), .{ .spacer = 1 } });
    if (self.rows.len == 0) {
        const empty = if (self.named) scope.empty_named else scope.empty;
        try out.append(a, line(try clipped(a, empty, width), theme.style(.muted)));
    } else {
        const start = @min(self.selected -| page / 2, self.rows.len -| page);
        const end = @min(start + page, self.rows.len);
        for (start..end) |i| try out.append(a, try self.drawRow(a, i, width, theme, home, now));
        if (start != 0 or end != self.rows.len)
            try out.append(a, line(try std.fmt.allocPrint(a, "  ({d}/{d})", .{ self.selected + 1, self.rows.len }), theme.style(.muted)));
    }
    try Frame.append(a, out, labels.frame.after, width, theme);
}
