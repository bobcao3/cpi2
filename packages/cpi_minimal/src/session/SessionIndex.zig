//! Session picker data read from published journals without launching a Worker.
const std = @import("std");
const agent = @import("agent");
const Controller = @import("Controller.zig");
const SessionName = @import("SessionName.zig");
const ShellRecord = @import("ShellRecord.zig");
const j = @import("../json.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Scope = enum { current, all };

pub const Source = struct {
    directory: []const u8,
    root: ?[]const u8,
    workspace: []const u8,
    current: ?[]const u8,
};

pub const Session = struct {
    path: []const u8,
    id: []const u8,
    inode: u64,
    parent: ?[]const u8,
    workspace: []const u8,
    name: []const u8,
    first_message: []const u8,
    messages: []const u8,
    message_count: usize,
    modified_ms: i64,

    pub fn target(self: Session) Controller.SavedSession {
        return .{ .path = self.path, .id = self.id, .inode = self.inode };
    }
};

const Candidate = struct { path: []const u8, in_current: bool };

fn collect(a: Allocator, io: Io, path: []const u8, workspace_dir: []const u8, files: *std.StringHashMapUnmanaged(Candidate)) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !Controller.isSessionName(entry.name)) continue;
        try addCandidate(a, io, try std.fs.path.join(a, &.{ path, entry.name }), std.mem.eql(u8, path, workspace_dir), files);
    }
}

fn addCandidate(a: Allocator, io: Io, path: []const u8, current: bool, files: *std.StringHashMapUnmanaged(Candidate)) !void {
    const canonical = Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return,
    };
    const result = try files.getOrPut(a, canonical);
    if (result.found_existing) {
        result.value_ptr.in_current = result.value_ptr.in_current or current;
    } else result.value_ptr.* = .{ .path = canonical, .in_current = current };
}

pub fn load(a: Allocator, gpa: Allocator, io: Io, source: Source, scope: Scope, progress: anytype) !void {
    var temporary: std.heap.ArenaAllocator = .init(gpa);
    defer temporary.deinit();
    const tmp = temporary.allocator();
    var files: std.StringHashMapUnmanaged(Candidate) = .empty;
    try collect(tmp, io, source.directory, source.directory, &files);
    if (source.current) |path| try addCandidate(tmp, io, path, true, &files);
    if (scope == .all) if (source.root) |root| {
        if (Io.Dir.cwd().openDir(io, root, .{ .iterate = true })) |directory| {
            defer directory.close(io);
            var iterator = directory.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
                const path = try std.fs.path.join(tmp, &.{ root, entry.name });
                try collect(tmp, io, path, source.directory, &files);
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    };

    var iterator = files.valueIterator();
    var loaded: usize = 0;
    progress.update(loaded, files.count());
    while (iterator.next()) |candidate| {
        try io.checkCancel();
        const session = inspect(a, gpa, io, candidate.*, source.workspace, scope) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            // Candidates may disappear or be owned by an incompatible journal.
            else => null,
        };
        if (session) |entry| {
            const owned = try a.create(Session);
            owned.* = entry;
            try progress.add(owned);
        }
        loaded += 1;
        progress.update(loaded, files.count());
    }
}

pub fn newer(_: void, left: *const Session, right: *const Session) bool {
    if (left.modified_ms != right.modified_ms) return left.modified_ms > right.modified_ms;
    return std.mem.order(u8, left.path, right.path) == .lt;
}

pub const Match = struct {
    target: Controller.SavedSession,
    workspace: []const u8,
    global: bool,
};

const Lookup = struct {
    id: []const u8,
    exact: ?*const Session = null,
    prefix: ?*const Session = null,

    fn add(self: *Lookup, session: *const Session) !void {
        if (std.mem.eql(u8, session.id, self.id)) {
            if (self.exact == null or newer({}, session, self.exact.?)) self.exact = session;
        } else if (std.mem.startsWith(u8, session.id, self.id)) {
            if (self.prefix == null or newer({}, session, self.prefix.?)) self.prefix = session;
        }
    }

    fn update(_: *Lookup, _: usize, _: usize) void {}
};

/// Resolve an ID or prefix in the current workspace first.
pub fn lookup(a: Allocator, gpa: Allocator, io: Io, source: Source, id: []const u8) !?Match {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for ([_]Scope{ .current, .all }) |scope| {
        const allocator = scratch.allocator();
        var matches: Lookup = .{ .id = id };
        try load(allocator, gpa, io, source, scope, &matches);
        const session = matches.exact orelse matches.prefix orelse {
            _ = scratch.reset(.free_all);
            continue;
        };
        return .{
            .target = .{ .path = try a.dupe(u8, session.path), .id = try a.dupe(u8, session.id), .inode = session.inode },
            .workspace = try a.dupe(u8, session.workspace),
            .global = scope == .all,
        };
    }
    return null;
}

const Recent = struct {
    path: []const u8,
    modified: i128,

    fn newerThan(_: void, left: Recent, right: Recent) bool {
        if (left.modified != right.modified) return left.modified > right.modified;
        return std.mem.order(u8, left.path, right.path) == .lt;
    }
};

/// Continue follows filesystem modification time. Picker ordering follows message activity.
pub fn latestInWorkspace(a: Allocator, gpa: Allocator, io: Io, source: Source) !?Controller.SavedSession {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var files: std.StringHashMapUnmanaged(Candidate) = .empty;
    try collect(temp, io, source.directory, source.directory, &files);
    var ordered: std.ArrayList(Recent) = .empty;
    var candidates = files.valueIterator();
    while (candidates.next()) |candidate| {
        const stat = Io.Dir.cwd().statFile(io, candidate.path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .file and stat.size != 0) try ordered.append(temp, .{ .path = candidate.path, .modified = stat.mtime.nanoseconds });
    }
    std.mem.sort(Recent, ordered.items, {}, Recent.newerThan);
    for (ordered.items) |candidate| {
        var view = Controller.openSessionView(gpa, io, candidate.path) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => continue,
        };
        defer view.deinit();
        var context = view.context(gpa, agent.TaskJournal.main_conversation) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => continue,
        };
        defer context.deinit();
        const session = j.get(context.value, "session");
        if (session != .object) continue;
        const field = j.get(j.get(session, "config"), "workspace");
        if (field != .null and field != .string) continue;
        const workspace = j.text(field);
        if (workspace.len != 0 and !std.mem.eql(u8, workspace, source.workspace)) continue;
        return .{ .path = try a.dupe(u8, candidate.path), .id = try a.dupe(u8, view.sessionId()), .inode = view.fileInode() };
    }
    return null;
}

fn inspect(a: Allocator, gpa: Allocator, io: Io, candidate: Candidate, workspace: []const u8, scope: Scope) !?Session {
    const path = candidate.path;
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size == 0) return null;
    // Keep the viewer and its replay cache outside the result arena.
    var view = try Controller.openSessionView(gpa, io, path);
    defer view.deinit();
    var context = try view.context(gpa, agent.TaskJournal.main_conversation);
    defer context.deinit();
    const stored_workspace = j.text(j.get(j.get(j.get(context.value, "session"), "config"), "workspace"));
    const cwd = if (stored_workspace.len != 0) stored_workspace else if (candidate.in_current) workspace else "";
    if (scope == .current and !std.mem.eql(u8, cwd, workspace)) return null;
    var collect_messages: Messages = .{ .a = a };
    try view.visitApplicationEntries(gpa, agent.TaskJournal.main_conversation, &collect_messages, Messages.visit);
    if (!collect_messages.dialogue) return null;
    const parent = j.text(j.get(context.value, "parent_session"));
    const canonical_parent = if (parent.len == 0) null else Io.Dir.cwd().realPathFileAlloc(io, parent, a) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => try a.dupe(u8, parent),
    };
    return .{
        .path = try a.dupe(u8, path),
        .id = try a.dupe(u8, view.sessionId()),
        .inode = view.fileInode(),
        .parent = canonical_parent,
        .workspace = try a.dupe(u8, cwd),
        .name = collect_messages.name,
        .first_message = if (collect_messages.first.len != 0) collect_messages.first else "(no messages)",
        .messages = collect_messages.joined.items,
        .message_count = collect_messages.count,
        .modified_ms = if (collect_messages.modified_ms > 0) collect_messages.modified_ms else stat.mtime.toMilliseconds(),
    };
}

const Messages = struct {
    a: Allocator,
    first: []const u8 = "",
    name: []const u8 = "",
    joined: std.ArrayList(u8) = .empty,
    count: usize = 0,
    modified_ms: i64 = 0,
    dialogue: bool = false,

    fn visit(self: *Messages, entry: std.json.Value) !void {
        const kind = j.get(entry, "kind");
        const event = j.get(entry, "event_kind");
        if (j.equal(event, SessionName.entry_kind)) {
            self.name = try self.a.dupe(u8, SessionName.trimWhitespace(j.text(j.get(entry, "data"))));
            return;
        }
        const user = j.equal(kind, "input");
        const assistant = j.equal(kind, "response");
        const system = j.flag(j.get(entry, "system_revision"));
        if (!user and !assistant and !system and !j.equal(kind, "program") and !j.equal(event, ShellRecord.kind)) return;
        self.dialogue = self.dialogue or user or assistant;
        self.count += 1;
        const recorded_time = j.number(j.get(entry, "message_at_ms"));
        if (recorded_time <= std.math.maxInt(i64)) self.modified_ms = @max(self.modified_ms, @as(i64, @intCast(recorded_time)));
        if (user) {
            const text = j.text(j.get(entry, "text"));
            if (self.first.len == 0 and text.len != 0) self.first = try self.a.dupe(u8, text);
            try self.appendText(text, "\n");
        } else if (assistant) {
            var separator: []const u8 = "\n";
            for (j.items(j.get(entry, "output"))) |item| {
                if (!j.equal(j.get(item, "type"), "message")) continue;
                for (j.items(j.get(item, "content"))) |part| {
                    const text = j.text(j.get(part, "text"));
                    if (text.len == 0) continue;
                    try self.appendText(text, separator);
                    separator = "";
                }
            }
        }
    }

    fn appendText(self: *Messages, text: []const u8, separator: []const u8) !void {
        if (text.len == 0) return;
        if (self.joined.items.len != 0) try self.joined.appendSlice(self.a, separator);
        try self.joined.appendSlice(self.a, text);
    }
};
