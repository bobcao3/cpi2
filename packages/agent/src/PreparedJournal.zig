//! Native ownership transfer from launch inspection to an unpublished Worker.
const std = @import("std");
const Journal = @import("SessionJournal.zig");
const Persistence = @import("LuauJournal.zig");
const Codec = @import("LuauContextJournal.zig").Codec;
const SizeSink = @import("session_protocol").Transaction.SizeSink;
const Action = @import("session_protocol").frames.Action;
const ExtensionWrite = @import("Session.zig").ExtensionWrite;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Prepared = @This();

journal: ?Journal,
path: []const u8,
codec: Codec,
warnings: std.ArrayList(Warning),

const Warning = struct { measurement: []const u8, actual: usize, threshold: usize };
const ReplayWarnings = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    values: std.ArrayList(Warning) = .empty,

    fn collect(raw: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
        const self: *ReplayWarnings = @ptrCast(@alignCast(raw.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.values.append(self.allocator, .{ .measurement = measurement, .actual = actual, .threshold = threshold }) catch {
            (SizeSink{}).report(measurement, actual, threshold);
        };
    }
};

fn reportWarnings(warnings: *std.ArrayList(Warning), allocator: Allocator, sink: SizeSink) void {
    for (warnings.items) |warning| sink.report(warning.measurement, warning.actual, warning.threshold);
    warnings.deinit(allocator);
    warnings.* = .empty;
}

pub fn open(a: Allocator, io: std.Io, path: []const u8, id: []const u8, codec: Codec) !Prepared {
    if (std.mem.eql(u8, path, "memory:")) return error.InvalidArgument;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var options = try Persistence.options(scratch.allocator(), codec);
    var warnings: ReplayWarnings = .{ .allocator = a, .io = io };
    errdefer reportWarnings(&warnings.values, a, .{});
    options.size_warnings = .{ .context = &warnings, .notify = ReplayWarnings.collect };
    options.pipeline_replay = @import("memory_budget").fromAllocator(a) != null;
    var journal = try Journal.prepareWriter(a, io, path, id, options);
    errdefer journal.deinit();
    // All replay tasks are joined before their temporary observer goes away.
    journal.options.size_warnings = .{};
    return .{ .path = try journal.metadata.allocator().dupe(u8, path), .codec = codec, .journal = journal, .warnings = warnings.values };
}

pub const ForkPublication = enum { immediate, on_dialogue };

pub fn createApplicationFork(gpa: Allocator, io: std.Io, path: ?[]const u8, id: []const u8, codec: Codec, entries: []const Value, context: Value, extra: []const @FieldType(Action, "control.extension"), publication: ForkPublication) !Prepared {
    return createApplicationCopy(gpa, io, path, id, codec, .{ .branch = entries }, context, extra, publication);
}

/// The original lease stays with the caller. Copy committed application history into a new identity.
pub fn forkApplicationArchive(self: *const Prepared, path: []const u8, id: []const u8, context: Value, extra: []const @FieldType(Action, "control.extension"), projection: ?ArchiveProjection) !Prepared {
    const source = if (self.journal) |*journal| journal else return error.InvalidPreparedJournal;
    return createApplicationCopy(source.gpa, source.io, path, id, self.codec, .{ .archive = .{ .source = source, .projection = projection } }, context, extra, .immediate);
}

pub const ArchiveProjection = Persistence.ArchiveProjection;

const ApplicationCopy = union(enum) {
    branch: []const Value,
    archive: struct { source: *const Journal, projection: ?ArchiveProjection },

    fn seed(copy: ApplicationCopy, journal: *Journal, codec: Codec, context: Value, extra: []const @FieldType(Action, "control.extension")) !void {
        switch (copy) {
            .branch => |entries| try Persistence.seedApplicationBranch(journal, codec, entries, context, extra),
            .archive => |archive| try Persistence.seedApplicationArchive(journal, archive.source, codec, context, extra, archive.projection),
        }
    }
};

fn createApplicationCopy(gpa: Allocator, io: std.Io, path: ?[]const u8, id: []const u8, codec: Codec, copy: ApplicationCopy, context: Value, extra: []const @FieldType(Action, "control.extension"), publication: ForkPublication) !Prepared {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const options = try Persistence.options(a, codec);
    if (path == null or publication == .on_dialogue) {
        var journal = try Journal.open(gpa, io, "memory:", id, options);
        errdefer journal.deinit();
        try copy.seed(&journal, codec, context, extra);
        if (path) |destination| try journal.deferPublication(destination, Persistence.hasApplicationDialogue);
        return .{ .path = journal.residentPath().?, .codec = codec, .journal = journal, .warnings = .empty };
    }
    const destination = path.?;
    const cwd = std.Io.Dir.cwd();
    const parent = std.fs.path.dirname(destination) orelse ".";
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const staging = try std.fmt.allocPrint(a, "{s}/.fork-{s}", .{ parent, std.fmt.bytesToHex(nonce, .lower) });
    try cwd.createDir(io, staging, .fromMode(0o700));
    defer cwd.deleteTree(io, staging) catch {};
    const candidate = try std.fs.path.join(a, &.{ staging, std.fs.path.basename(destination) });
    {
        var journal = try Journal.open(gpa, io, candidate, id, options);
        defer journal.deinit();
        try copy.seed(&journal, codec, context, extra);
    }
    try cwd.renamePreserve(candidate, cwd, destination, io);
    return open(gpa, io, destination, id, codec);
}

pub fn snapshotResident(journal: *const Journal, codec: Codec) !?Prepared {
    const resident = (try journal.cloneResident()) orelse return null;
    return .{ .path = resident.residentPath().?, .codec = codec, .journal = resident, .warnings = .empty };
}

pub fn deinit(self: *Prepared) void {
    if (self.journal) |*journal| {
        reportWarnings(&self.warnings, journal.gpa, .{});
        journal.deinit();
    }
    self.journal = null;
}

pub fn sessionId(self: *const Prepared) ![]const u8 {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    return journal.state.extensions.session_id;
}

pub fn contextDocument(self: *const Prepared, a: Allocator, field: []const u8) !Value {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    const state = journal.state.extensions.get(self.codec.namespace) orelse return .null;
    if (self.codec.view_documents) |project| return @import("json.zig").get(try project(a, state.value), field);
    return @import("json.zig").get(try self.codec.materialize(a, state.value), field);
}

pub fn extensionDocument(self: *const Prepared, a: Allocator, namespace: []const u8) !Value {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    if (journal.state.extensions.get(namespace)) |entry| return @import("json.zig").copy(a, entry.value);
    return .null;
}

pub fn lastOwnedApplicationTip(self: *const Prepared, a: Allocator, scope: []const u8) !?Persistence.ApplicationTip {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    return Persistence.lastOwnedApplicationTip(journal, a, scope);
}

/// Check that the path still names the selected, exclusively locked journal.
pub fn requireFile(self: *const Prepared, expected_inode: u64) !void {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    if (journal.lock == null or journal.inode != expected_inode) return error.JournalReplaced;
    const stat = try std.Io.Dir.cwd().statFile(journal.io, self.path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.nlink != 1 or stat.inode != expected_inode) return error.JournalReplaced;
}

pub fn revalidateFile(self: *const Prepared) !void {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    try self.requireFile(journal.inode orelse return error.InvalidPreparedJournal);
}

pub fn applicationContext(self: *const Prepared, a: Allocator, scope: []const u8) !Value {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    return Persistence.applicationContext(journal, self.codec, a, scope);
}

pub fn syncParent(self: *const Prepared) !void {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    const io = journal.io;
    const directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(self.path) orelse ".", .{ .iterate = true });
    defer directory.close(io);
    try @import("journal_platform.zig").syncDirectory(io, directory);
}

/// Append a display entry and its companion extension atomically while the
/// prepared writer owns the file. This never opens a Worker.
pub fn appendApplicationDisplay(self: *Prepared, expected_inode: u64, id: []const u8, scope: []const u8, entry: Value, context: ?Value, companion: ExtensionWrite) !void {
    try self.requireFile(expected_inode);
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    try journal.finishWriterOpen(self.path);
    try Persistence.appendApplicationDisplay(journal, self.codec, id, scope, entry, context, companion);
}

pub fn take(self: *Prepared, a: Allocator, io: std.Io, path: []const u8, id: []const u8, codec: Codec, warnings: ?SizeSink) !Journal {
    const journal = if (self.journal) |*saved| saved else return error.InvalidPreparedJournal;
    if (!std.mem.eql(u8, self.path, path) or !std.mem.eql(u8, try self.sessionId(), id) or
        !std.meta.eql(self.codec, codec) or !std.meta.eql(journal.gpa, a) or !std.meta.eql(journal.io, io))
        return error.InvalidPreparedJournal;
    if (journal.file != null) try journal.finishWriterOpen(path);
    if (warnings) |reporter| journal.options.size_warnings = reporter;
    reportWarnings(&self.warnings, a, journal.options.size_warnings orelse .{});
    const result = journal.*;
    self.journal = null;
    return result;
}
