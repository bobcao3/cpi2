const std = @import("std");
const protocol = @import("session_protocol");
const tracing = @import("kit").tracing;
const platform = @import("journal_platform.zig");
const gzip = @import("journal_gzip.zig");
const zstd = @import("journal_zstd.zig");
const members = @import("journal_members.zig");
const MessageCache = @import("journal_message_cache.zig");
const Pipeline = @import("journal_replay_pipeline.zig");
const F = protocol.frames;
const State = protocol.State;
const Transaction = protocol.Transaction;
const Journal = @This();
const Allocator = std.mem.Allocator;
const ReadBoundary = struct { end: u64, sequence: ?u64 = null };
const OpenMode = enum { writer, prepared_writer, offline_reader, viewer };
const ReplayMode = enum { unpublished, published };
const publication_magic = "CPIVIEW1";
const Publication = [64]u8;
const Published = struct { boundary: ReadBoundary, slot: u1 };

const ReplayProfile = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    members: usize = 0,
    frames: usize = 0,
    bytes: u64 = 0,
    decode_ns: i96 = 0,
    parse_ns: i96 = 0,
    prepare_ns: i96 = 0,
    phases: State.ReplayTiming,
    reloads: usize = 0,
    reload_bytes: u64 = 0,
    reload_ns: i96 = 0,
    pipeline_chunks: usize = 0,

    fn elapsed(start: std.Io.Timestamp, io: std.Io) i96 {
        return start.durationTo(.now(io, .awake)).nanoseconds;
    }

    fn report(self: ReplayProfile) void {
        std.debug.print(
            "journal replay: members={d} frames={d} bytes={d} total_ns={d} decode_ns={d} parse_ns={d} prepare_ns={d} reloads={d} reload_bytes={d} reload_ns={d} pipeline_chunks={d}\n",
            .{ self.members, self.frames, self.bytes, elapsed(self.start, self.io), self.decode_ns, self.parse_ns, self.prepare_ns, self.reloads, self.reload_bytes, self.reload_ns, self.pipeline_chunks },
        );
        std.debug.print("journal prepare: extensions_ns={d} projection_ns={d} render_ns={d} hash_ns={d}\n", .{ self.phases.extensions, self.phases.projection, self.phases.render, self.phases.hash });
    }
};

test {
    _ = @import("SessionJournal_tests.zig");
}

const Stored = struct {
    id: []const u8,
    first: u64,
    last: u64,
    offset: u64,
    length: u64,
    resident: ?Transaction = null,
};

pub const Options = struct {
    contracts: []const protocol.Extensions.Contract = &.{},
    renderers: []const State.Renderer = &.{State.standard_renderer},
    limits: Transaction.Limits = .{},
    size_warnings: ?Transaction.SizeSink = .{},
    /// The allocator and size warning sink must support calls from replay tasks.
    pipeline_replay: bool = false,
};

pub const PublicationTrigger = *const fn (Allocator, *const Transaction) anyerror!bool;
const DeferredPublication = struct { path: []const u8, trigger: PublicationTrigger };
gpa: Allocator,
io: std.Io,
file: ?std.Io.File = null,
format: members.Format = .zstandard,
zstd_decoder: ?zstd.Decoder = null,
zstd_encoder: ?zstd.Encoder = null,
lock: ?std.Io.File = null,
metadata: *std.heap.ArenaAllocator,
options: Options,
state: State,
sequence: u64 = 0,
offset: u64 = 0,
pending_repair: bool = false,
poisoned: bool = false,
transactions: std.ArrayList(Stored) = .empty,
cache_index: ?usize = null,
cache: ?Transaction = null,
transaction_ids: std.StringHashMapUnmanaged(usize) = .empty,
pending: ?*const Transaction = null,
replay_profile: ?*ReplayProfile = null,
history_cache: ?*MessageCache = null,
replay_projections: ?*State.ProjectionCache = null,
extension_replay: ?*protocol.Extensions.ReplayStorage = null,
inode: ?u64 = null,
view_lock_path: ?[]const u8 = null,
next_publication: u1 = 0,
deferred_publication: ?DeferredPublication = null,

pub fn open(gpa: Allocator, io: std.Io, path: []const u8, session: []const u8, options: Options) !Journal {
    return openMode(gpa, io, path, session, options, .writer);
}

pub fn deferPublication(self: *Journal, path: []const u8, trigger: PublicationTrigger) !void {
    if (self.file != null or self.deferred_publication != null or path.len == 0 or std.mem.eql(u8, path, "memory:")) return error.InvalidArgument;
    self.deferred_publication = .{ .path = try self.metadata.allocator().dupe(u8, path), .trigger = trigger };
    self.format = if (std.mem.endsWith(u8, path, ".gz")) .gzip else .zstandard;
}

pub fn residentPath(self: *const Journal) ?[]const u8 {
    if (self.file != null) return null;
    return if (self.deferred_publication) |deferred| deferred.path else "memory:";
}

/// Snapshot resident history on its owner, before changing the surrounding services.
pub fn cloneResident(self: *const Journal) !?Journal {
    if (self.file != null) return null;
    if (self.poisoned) return error.JournalCommitUncertain;
    var result = try open(self.gpa, self.io, "memory:", self.state.extensions.session_id, self.options);
    errdefer result.deinit();
    result.options.size_warnings = .{};
    for (self.transactions.items) |stored| {
        var transaction = try stored.resident.?.clone(self.gpa);
        errdefer transaction.deinit();
        _ = try result.append(&transaction);
    }
    if (self.deferred_publication) |deferred| try result.deferPublication(deferred.path, deferred.trigger);
    return result;
}

/// Recover an existing journal under the writer locks. The caller must
/// finish opening it before startup can use it as a published writer.
pub fn prepareWriter(gpa: Allocator, io: std.Io, path: []const u8, session: []const u8, options: Options) !Journal {
    return openMode(gpa, io, path, session, options, .prepared_writer);
}

pub fn openExisting(gpa: Allocator, io: std.Io, path: []const u8, session: []const u8, options: Options) !Journal {
    return openMode(gpa, io, path, session, options, .offline_reader);
}

/// Follow an existing journal without reserving its writer lock or repairing it.
pub fn openViewer(gpa: Allocator, io: std.Io, path: []const u8, session: []const u8, options: Options) !Journal {
    return openMode(gpa, io, path, session, options, .viewer);
}

fn openMode(gpa: Allocator, io: std.Io, path: []const u8, session: []const u8, options: Options, mode: OpenMode) !Journal {
    if (path.len == 0 or session.len == 0 or !std.unicode.utf8ValidateSlice(session) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    for (session) |byte| if (byte < 32 or byte == 127) return error.InvalidArgument;
    const metadata = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(metadata);
    metadata.* = .init(gpa);
    errdefer metadata.deinit();
    const a = metadata.allocator();
    var owned = options;
    if (owned.size_warnings == null) owned.size_warnings = .{ .context = null, .notify = logSizeWarning };
    const contracts = try a.dupe(protocol.Extensions.Contract, options.contracts);
    for (contracts) |*c| c.version = .{ .id = try a.dupe(u8, c.version.id), .version = try a.dupe(u8, c.version.version) };
    owned.contracts = contracts;
    const renderers = try a.dupe(State.Renderer, options.renderers);
    for (renderers) |*r| r.version = .{ .id = try a.dupe(u8, r.version.id), .version = try a.dupe(u8, r.version.version) };
    owned.renderers = renderers;
    var self: Journal = .{ .gpa = gpa, .io = io, .metadata = metadata, .options = owned, .state = try State.init(gpa, session) };
    errdefer self.release();
    if (std.mem.endsWith(u8, path, ".gz")) self.format = .gzip;
    if (mode == .offline_reader or mode == .viewer) {
        self.file = try platform.openRead(path);
        const stat = try self.file.?.stat(io);
        if (stat.kind != .file or stat.nlink != 1) return error.JournalLinkedFile;
        self.inode = @intCast(stat.inode);
        if (mode == .viewer) {
            self.view_lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
            const boundary = (try self.viewBoundary(true)) orelse return error.JournalPublicationUnavailable;
            try self.readBoundary(boundary, .unpublished);
        } else {
            if (!try self.file.?.tryLock(io, .shared)) return error.JournalLocked;
            try self.recover((try self.file.?.stat(io)).size, .unpublished);
        }
        return self;
    }
    if (std.mem.eql(u8, path, "memory:")) return self;
    const parent = std.fs.path.dirname(path) orelse ".";
    if (mode == .writer) try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    self.lock = try platform.open(lock_path);
    const lock_stat = try self.lock.?.stat(io);
    if (lock_stat.kind != .file or lock_stat.nlink != 1) return error.JournalLinkedFile;
    if (!try self.lock.?.tryLock(io, .exclusive)) return error.JournalLocked;
    self.file = if (mode == .prepared_writer) try platform.openExistingWriter(path) else try platform.open(path);
    const stat = try self.file.?.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.JournalLinkedFile;
    self.inode = @intCast(stat.inode);
    if (!try self.file.?.tryLock(io, .exclusive)) return error.JournalLocked;
    try self.recover(stat.size, .unpublished);
    if (mode == .writer) try self.finishWriterOpen(path);
    return self;
}

pub fn finishWriterOpen(self: *Journal, path: []const u8) !void {
    const io = self.io;
    var directory = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{ .iterate = true });
    defer directory.close(io);
    try platform.syncDirectory(io, directory);
    const published = self.readPublication(self.lock.?) catch null;
    if (published) |record| self.next_publication = ~record.slot;
    if (published == null or published.?.boundary.end != self.offset) {
        // An older writer or an interrupted append can leave a complete
        // prefix that has never been published. Sync it before advertising it.
        if (self.offset != 0) self.file.?.sync(io) catch |err| {
            std.log.warn("recovered session prefix could not be published ({s})", .{@errorName(err)});
            return;
        };
        self.publishBoundary();
        if (published == null) self.lock.?.sync(io) catch |err| {
            std.log.warn("initial session view boundary could not be synchronized ({s})", .{@errorName(err)});
        };
    }
}

/// Load newly published transactions from the current inode. The caller
/// owns the viewer and serializes refresh with reads of its state.
pub fn refreshViewer(self: *Journal) !bool {
    if (self.view_lock_path == null) return error.NotJournalViewer;
    const boundary = (try self.viewBoundary(false)) orelse return false;
    if (boundary.end <= self.offset) return false;
    try self.readBoundary(boundary, .published);
    return true;
}

fn publicationDigest(self: *const Journal, fields: *const [32]u8) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(fields);
    digest.update(self.state.extensions.session_id);
    return digest.finalResult();
}

fn publishBoundary(self: *Journal) void {
    const lock = self.lock orelse return;
    var bytes: Publication = undefined;
    bytes[0..8].* = publication_magic.*;
    std.mem.writeInt(u64, bytes[8..16], self.inode.?, .little);
    std.mem.writeInt(u64, bytes[16..24], self.offset, .little);
    std.mem.writeInt(u64, bytes[24..32], self.sequence, .little);
    bytes[32..64].* = self.publicationDigest(bytes[0..32]);
    lock.writePositionalAll(self.io, &bytes, @as(u64, self.next_publication) * bytes.len) catch |err| {
        std.log.warn("session view publication unavailable ({s})", .{@errorName(err)});
        return;
    };
    self.next_publication = ~self.next_publication;
}

fn readPublication(self: *const Journal, input: std.Io.File) !?Published {
    var best: ?Published = null;
    inline for (0..2) |slot| {
        var bytes: Publication = undefined;
        if (try input.readPositionalAll(self.io, &bytes, slot * bytes.len) == bytes.len and
            std.mem.eql(u8, bytes[0..8], publication_magic) and
            std.mem.readInt(u64, bytes[8..16], .little) == self.inode.?)
        {
            const digest = self.publicationDigest(bytes[0..32]);
            const end = std.mem.readInt(u64, bytes[16..24], .little);
            if (std.mem.eql(u8, bytes[32..64], &digest) and (best == null or end > best.?.boundary.end)) {
                best = .{ .slot = slot, .boundary = .{ .end = end, .sequence = std.mem.readInt(u64, bytes[24..32], .little) } };
            }
        }
    }
    return best;
}

fn viewPublication(self: *const Journal) !struct { record: ?Published = null, has_bytes: bool = false } {
    const input = platform.openRead(self.view_lock_path.?) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer input.close(self.io);
    const stat = try input.stat(self.io);
    if (stat.kind != .file or stat.nlink != 1) return error.JournalLinkedFile;
    return .{ .record = try self.readPublication(input), .has_bytes = stat.size != 0 };
}

fn viewBoundary(self: *const Journal, legacy_snapshot: bool) !?ReadBoundary {
    const file = self.file.?;
    const published = try self.viewPublication();
    const stat = try file.stat(self.io);
    if (stat.kind != .file or stat.nlink != 1 or stat.size < self.offset) return error.JournalReplaced;
    if (published.record) |record| if (record.boundary.end <= stat.size) return record.boundary;
    if (!legacy_snapshot or published.has_bytes or !try file.tryLock(self.io, .shared)) return null;
    // Legacy journals have no publication. Sample while holding a shared
    // lock, then release it before decoding. A writer may have just closed.
    defer file.unlock(self.io);
    const after_lock = try self.viewPublication();
    const size = (try file.stat(self.io)).size;
    if (after_lock.record) |record| if (record.boundary.end <= size) return record.boundary;
    return if (after_lock.has_bytes) null else .{ .end = size };
}

fn readBoundary(self: *Journal, boundary: ReadBoundary, mode: ReplayMode) !void {
    self.pending_repair = false;
    try self.recover(boundary.end, mode);
    if (boundary.sequence) |seq| if (self.sequence != seq or self.offset != boundary.end) return error.InvalidJournalPublication;
}

fn logSizeWarning(_: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    std.log.warn("session journal {s} is {d}, above the expected {d}", .{ measurement, actual, threshold });
}

fn release(self: *Journal) void {
    self.state.deinit();
    if (self.history_cache) |cache| {
        cache.deinit();
        self.gpa.destroy(cache);
    }
    if (self.zstd_decoder) |decoder| decoder.deinit();
    if (self.zstd_encoder) |encoder| encoder.deinit();
    if (self.cache) |*cache| cache.deinit();
    for (self.transactions.items) |*stored| {
        if (stored.resident) |*t| t.deinit();
        self.gpa.free(stored.id);
    }
    self.transactions.deinit(self.gpa);
    self.transaction_ids.deinit(self.gpa);
    if (self.file) |file| file.close(self.io);
    if (self.lock) |lock| lock.close(self.io);
}
pub fn deinit(self: *Journal) void {
    self.release();
    self.metadata.deinit();
    self.gpa.destroy(self.metadata);
    self.* = undefined;
}

pub fn source(self: *const Journal) State.Source {
    return .{
        .context = self,
        .frame = readFrame,
        .transaction = readTransaction,
        .borrow_message = if (self.history_cache != null) getCachedMessage else null,
        .borrow_frame = if (self.history_cache != null) getCachedFrame else null,
        .projection_cache = self.replay_projections,
        .extension_replay = self.extension_replay,
        .replay_timing = if (self.replay_profile) |profile| &profile.phases else null,
    };
}

fn getCachedMessage(raw: *const anyopaque, ref: u64) ?F.Message {
    const self: *const Journal = @ptrCast(@alignCast(raw));
    const cache = self.history_cache orelse return null;
    return cache.getMessage(ref);
}

fn getCachedFrame(raw: *const anyopaque, ref: u64) ?*const F.Frame {
    const self: *const Journal = @ptrCast(@alignCast(raw));
    const cache = self.history_cache orelse return null;
    return cache.getFrame(ref);
}

pub fn transactionRange(self: *const Journal, id: []const u8) ?struct { first: u64, last: u64 } {
    const index = self.transaction_ids.get(id) orelse return null;
    const stored = self.transactions.items[index];
    return .{ .first = stored.first, .last = stored.last };
}

/// The returned frame belongs to the caller's allocator, not the read cache.
pub fn frame(self: *const Journal, allocator: Allocator, ref: u64) !*const F.Frame {
    const result = try allocator.create(F.Frame);
    result.* = try F.copy(F.Frame, allocator, (try self.source().get(ref)).*);
    return result;
}
fn storedIndex(self: *const Journal, ref: u64) !usize {
    if (ref == 0 or ref > self.sequence) return error.InvalidReference;
    var low: usize = 0;
    var high = self.transactions.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const stored = self.transactions.items[mid];
        if (ref < stored.first) high = mid else if (ref > stored.last) low = mid + 1 else return mid;
    }
    return error.InvalidReference;
}
fn load(self: *const Journal, allocator: Allocator, index: usize) !Transaction {
    const stored = &self.transactions.items[index];
    if (stored.resident) |*t| return t.clone(allocator);
    const start = if (self.replay_profile != null) std.Io.Timestamp.now(self.io, .awake) else null;
    defer if (start) |at| {
        self.replay_profile.?.reload_ns += ReplayProfile.elapsed(at, self.io);
    };
    const bound = stored.offset + stored.length;
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.Reader.initSize(self.file.?, self.io, &buffer, bound);
    var reader = self.memberReader(bound);
    reader.gpa = allocator;
    const member = reader.read(&input, stored.offset) catch |err| return input.err orelse err;
    if (member.length != stored.length) {
        allocator.free(member.bytes);
        return error.InvalidJournal;
    }
    if (self.replay_profile) |profile| {
        profile.reloads += 1;
        profile.reload_bytes += member.bytes.len;
    }
    return Transaction.parseOwnedObserved(allocator, self.state.extensions.session_id, stored.first, member.bytes, self.options.limits, null);
}
fn readFrame(raw: *const anyopaque, ref: u64) !*const F.Frame {
    const self: *Journal = @constCast(@as(*const Journal, @ptrCast(@alignCast(raw))));
    if (self.pending) |t| {
        const first = t.frames[0].frame.seq;
        if (ref >= first and ref <= t.lastSequence()) return &t.frames[@intCast(ref - first)].frame;
    }
    if (self.history_cache) |cache| if (cache.getFrame(ref)) |saved| return saved;
    const index = try self.storedIndex(ref);
    const stored = &self.transactions.items[index];
    if (stored.resident) |*t| return &t.frames[@intCast(ref - stored.first)].frame;
    if (self.cache_index != index) {
        if (self.cache) |*old| old.deinit();
        self.cache = null;
        self.cache_index = null;
        self.cache = try self.load(self.gpa, index);
        self.cache_index = index;
    }
    return &self.cache.?.frames[@intCast(ref - stored.first)].frame;
}
fn readTransaction(raw: *const anyopaque, allocator: Allocator, ref: u64) !Transaction {
    const self: *const Journal = @ptrCast(@alignCast(raw));
    if (ref > self.sequence) {
        const t = self.pending orelse return error.InvalidReference;
        if (ref < t.frames[0].frame.seq or ref > t.lastSequence()) return error.InvalidReference;
        return t.clone(allocator);
    }
    return self.load(allocator, try self.storedIndex(ref));
}

pub fn stateAt(self: *const Journal, allocator: Allocator, position: u64) !State {
    if (position > self.sequence) return error.FutureReference;
    try self.source().cut(position);
    var state = try State.init(allocator, self.state.extensions.session_id);
    errdefer state.deinit();
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    for (self.transactions.items, 0..) |stored, index| {
        if (stored.last > position) break;
        var t = try self.load(allocator, index);
        defer t.deinit();
        try state.replayUnpublished(self.source(), &t, self.options.contracts, self.options.renderers, &scratch);
    }
    return state;
}

pub fn commit(self: *Journal, id: []const u8, actor: F.Actor, actions: []const F.Action) !u64 {
    if (self.file != null and self.lock == null) return error.ReadOnlyJournal;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const first = if (self.transaction_ids.get(id)) |index| self.transactions.items[index].first else self.sequence + 1;
    const bytes = try protocol.Encoding.transaction(scratch.allocator(), self.state.extensions.session_id, id, first, actor, actions);
    var t = try Transaction.parseObserved(self.gpa, self.state.extensions.session_id, first, bytes, self.options.limits, self.options.size_warnings);
    errdefer t.deinit();
    return self.appendDecoded(&t, bytes);
}

/// Consumes the transaction on success. No candidate escapes an uncertain sync.
pub fn append(self: *Journal, transaction: *Transaction) !u64 {
    return self.appendDecoded(transaction, null);
}

fn appendDecoded(self: *Journal, transaction: *Transaction, encoded: ?[]const u8) !u64 {
    if (self.file != null and self.lock == null) return error.ReadOnlyJournal;
    if (self.poisoned) return error.JournalCommitUncertain;
    const id = transaction.frames[0].frame.tx.id;
    if (self.transaction_ids.get(id)) |index| {
        var previous = try self.load(self.gpa, index);
        defer previous.deinit();
        if (previous.frames.len != transaction.frames.len) return error.TransactionConflict;
        for (previous.frames, transaction.frames) |old, new| {
            var temporary = std.heap.ArenaAllocator.init(self.gpa);
            defer temporary.deinit();
            const scratch = temporary.allocator();
            if (!try protocol.json.equal(self.gpa, try old.documentValue(scratch), try new.documentValue(scratch))) return error.TransactionConflict;
        }
        const end = previous.lastSequence();
        transaction.deinit();
        return end;
    }
    if (transaction.frames[0].frame.seq != self.sequence + 1) return error.InvalidSequence;
    if (self.deferred_publication) |deferred| {
        if (std.Io.Dir.cwd().statFile(self.io, deferred.path, .{})) |_| {
            return error.PathAlreadyExists;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }
    self.pending = transaction;
    defer self.pending = null;
    var candidate = try self.state.prepare(self.source(), transaction, self.options.contracts, self.options.renderers);
    var adopted = false;
    defer if (!adopted) candidate.deinit();
    const owned_id = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(owned_id);
    try self.transactions.ensureUnusedCapacity(self.gpa, 1);
    try self.transaction_ids.ensureUnusedCapacity(self.gpa, 1);
    var member: ?[]u8 = null;
    defer if (member) |bytes| self.gpa.free(bytes);
    var written: u64 = 0;
    if (self.file) |file| {
        member = try self.compress(transaction, encoded);
        if (self.pending_repair) {
            file.setLength(self.io, self.offset) catch {
                self.poisoned = true;
                return error.JournalCommitUncertain;
            };
            file.sync(self.io) catch {
                self.poisoned = true;
                return error.JournalCommitUncertain;
            };
        }
        file.writePositionalAll(self.io, member.?, self.offset) catch {
            self.poisoned = true;
            return error.JournalCommitUncertain;
        };
        file.sync(self.io) catch {
            self.poisoned = true;
            return error.JournalCommitUncertain;
        };
        written = member.?.len;
    } else if (self.deferred_publication) |deferred| {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        if (try deferred.trigger(a, transaction)) written = try self.materialize(a, deferred.path, transaction, encoded);
    }
    const end = transaction.lastSequence();
    self.adopt(transaction, candidate, owned_id, written);
    adopted = true;
    self.offset += written;
    self.pending_repair = false;
    self.publishBoundary();
    return end;
}

/// Before the rename, failures leave the resident journal intact. After it,
/// a directory sync failure poisons this writer before any service can run.
fn materialize(self: *Journal, a: Allocator, path: []const u8, transaction: *const Transaction, encoded: ?[]const u8) !u64 {
    const io = self.io;
    const cwd = std.Io.Dir.cwd();
    const parent = std.fs.path.dirname(path) orelse ".";
    var directory = try cwd.openDir(io, parent, .{ .iterate = true });
    defer directory.close(io);
    const Range = struct { offset: u64, length: u64 };
    const ranges = try a.alloc(Range, self.transactions.items.len);
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const staging = try std.fmt.allocPrint(a, "{s}/.journal-{s}", .{ parent, std.fmt.bytesToHex(nonce, .lower) });
    const file = try platform.createExclusive(staging);
    errdefer file.close(io);
    defer {
        const cleanup = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(cleanup);
        cwd.deleteFile(io, staging) catch {};
    }
    if (!try file.tryLock(io, .exclusive)) return error.JournalLocked;
    const inode = (try file.stat(io)).inode;
    if (self.format == .zstandard and self.zstd_decoder == null) self.zstd_decoder = try zstd.Decoder.init();

    var offset: u64 = 0;
    for (self.transactions.items, ranges) |*stored, *range| {
        const bytes = try self.compress(&stored.resident.?, null);
        defer self.gpa.free(bytes);
        try file.writePositionalAll(io, bytes, offset);
        range.* = .{ .offset = offset, .length = bytes.len };
        offset += bytes.len;
    }
    const bytes = try self.compress(transaction, encoded);
    defer self.gpa.free(bytes);
    try file.writePositionalAll(io, bytes, offset);
    try file.sync(io);

    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    const lock = try platform.open(lock_path);
    errdefer lock.close(io);
    const stat = try lock.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.JournalLinkedFile;
    if (!try lock.tryLock(io, .exclusive)) return error.JournalLocked;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try cwd.renamePreserve(staging, cwd, path, io);
    platform.syncDirectory(io, directory) catch {
        self.poisoned = true;
        return error.JournalCommitUncertain;
    };

    for (self.transactions.items, ranges) |*stored, range| {
        stored.offset = range.offset;
        stored.length = range.length;
    }
    self.file = file;
    self.lock = lock;
    self.inode = @intCast(inode);
    self.offset = offset;
    self.deferred_publication = null;
    return bytes.len;
}

fn adopt(self: *Journal, transaction: *Transaction, candidate: State, owned_id: []const u8, length: u64) void {
    self.remember(transaction, owned_id, length);
    self.state.deinit();
    self.state = candidate;
    self.sequence = candidate.sequence;
}

fn remember(self: *Journal, transaction: *Transaction, owned_id: []const u8, length: u64) void {
    if (self.history_cache) |cache| for (transaction.frames) |owned| cache.remember(owned.frame);
    const first = transaction.frames[0].frame.seq;
    self.transaction_ids.putAssumeCapacity(owned_id, self.transactions.items.len);
    self.transactions.appendAssumeCapacity(.{ .id = owned_id, .first = first, .last = transaction.lastSequence(), .offset = self.offset, .length = length, .resident = if (self.file == null) transaction.* else null });
    if (self.file != null) transaction.deinit() else transaction.* = undefined;
}

fn compress(self: *Journal, transaction: *const Transaction, encoded: ?[]const u8) ![]u8 {
    if (self.format == .zstandard) {
        if (self.zstd_encoder == null) self.zstd_encoder = try zstd.Encoder.init();
        if (encoded) |bytes| return self.zstd_encoder.?.compress(self.gpa, bytes);
        var plain: std.Io.Writer.Allocating = .init(self.gpa);
        defer plain.deinit();
        for (transaction.frames) |owned| {
            try self.writeFrame(&plain.writer, owned);
            try plain.writer.writeByte('\n');
        }
        return self.zstd_encoder.?.compress(self.gpa, plain.written());
    }
    var output: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 4096);
    defer output.deinit();
    const window = try self.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer self.gpa.free(window);
    var encoder: std.compress.flate.Compress = try .init(&output.writer, window, .gzip, .fastest);
    if (encoded) |bytes| try encoder.writer.writeAll(bytes) else for (transaction.frames) |owned| {
        try self.writeFrame(&encoder.writer, owned);
        try encoder.writer.writeByte('\n');
    }
    try encoder.finish();
    return gzip.frame(self.gpa, output.written());
}

fn writeFrame(self: *Journal, writer: *std.Io.Writer, owned: F.Decoded) !void {
    var temporary = std.heap.ArenaAllocator.init(self.gpa);
    defer temporary.deinit();
    protocol.json.write(self.gpa, writer, try owned.documentValue(temporary.allocator())) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

/// Read a Zstandard journal's declared identity from its first complete frame.
/// Full sequence, transaction and semantic validation still occurs at open.
pub fn zstdSessionId(gpa: Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const file = platform.openRead(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.JournalLinkedFile;
    if (try members.Format.detect(file, io, stat.size) != .zstandard) return null;
    const decoder = try zstd.Decoder.init();
    defer decoder.deinit();
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.Reader.initSize(file, io, &buffer, stat.size);
    const reader: members.Reader = .{ .gpa = gpa, .io = io, .file = file, .format = .zstandard, .decoder = decoder, .end = stat.size };
    const first = reader.read(&input, 0) catch |err| {
        if (input.err) |failure| return failure;
        if (err == error.IncompleteJournal) return null;
        return err;
    };
    defer gpa.free(first.bytes);
    const newline = std.mem.findScalar(u8, first.bytes, '\n') orelse return error.InvalidJournal;
    var owned = try F.Owned.decodeObserved(gpa, first.bytes[0..newline], null);
    defer owned.deinit();
    return try gpa.dupe(u8, owned.frame.session_id);
}

fn memberReader(self: *const Journal, size: u64) members.Reader {
    return .{
        .gpa = self.gpa,
        .io = self.io,
        .file = self.file.?,
        .format = self.format,
        .decoder = self.zstd_decoder,
        .end = size,
        .offset = self.offset,
    };
}

fn parseOptions(self: *const Journal) Pipeline.ParseOptions {
    return .{
        .session_id = self.state.extensions.session_id,
        .first_sequence = self.sequence + 1,
        .limits = self.options.limits,
        .size_warnings = self.options.size_warnings,
    };
}

const ColdReplay = struct {
    journal: *Journal,
    scratch: *std.heap.ArenaAllocator,

    fn consume(self: ColdReplay, transaction: *Transaction, length: u64) anyerror!void {
        try self.journal.recoverTransaction(transaction, length, .unpublished, self.scratch);
    }
};

fn recoverPipelined(self: *Journal, size: u64, scratch: *std.heap.ArenaAllocator) !bool {
    var options = self.parseOptions();
    // Publishing the next private state can destroy the previous extension arena.
    const session_id = try self.gpa.dupe(u8, options.session_id);
    defer self.gpa.free(session_id);
    options.session_id = session_id;
    const context: ColdReplay = .{ .journal = self, .scratch = scratch };
    const result = (try Pipeline.run(self.memberReader(size), options, self.replay_profile != null, context, ColdReplay.consume)) orelse return false;
    self.pending_repair = result.decode.incomplete;
    if (self.replay_profile) |profile| {
        profile.bytes = result.decode.bytes;
        profile.frames = result.parse.frames;
        profile.decode_ns = result.decode.ns;
        profile.parse_ns = result.parse.ns;
        profile.pipeline_chunks = result.decode.chunks;
    }
    return true;
}

fn recover(self: *Journal, size: u64, mode: ReplayMode) !void {
    const scope = tracing.beginEvent("cpi.journal.recover");
    defer tracing.endEvent(scope);
    var profile: ReplayProfile = undefined;
    if (scope != tracing.Buffer.no_trace) {
        profile = .{ .io = self.io, .start = .now(self.io, .awake), .phases = .{ .io = self.io } };
        self.replay_profile = &profile;
    }
    defer if (self.replay_profile) |observed| {
        self.replay_profile = null;
        observed.report();
    };
    if (self.offset == 0) self.format = (try members.Format.detect(self.file.?, self.io, size)) orelse self.format;
    if (self.format == .zstandard and self.zstd_decoder == null) self.zstd_decoder = try zstd.Decoder.init();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var projections: State.ProjectionCache = .{ .gpa = self.gpa };
    var strings = protocol.Extensions.ReplayStorage.init(self.gpa);
    if (mode == .unpublished) {
        strings.start();
        if (self.replay_profile != null) strings.timing = .{ .io = self.io };
        if (self.history_cache == null) {
            if (self.gpa.create(MessageCache)) |cache| {
                cache.* = MessageCache.init(self.gpa);
                self.history_cache = cache;
            } else |_| {}
        }
        self.replay_projections = &projections;
        self.extension_replay = &strings;
    }
    defer {
        const finishing = if (mode == .unpublished and self.replay_profile != null)
            std.Io.Timestamp.now(self.io, .awake)
        else
            null;
        if (mode == .unpublished) self.state.extensions.detachReplay();
        self.replay_projections = null;
        self.extension_replay = null;
        strings.deinit();
        projections.deinit();
        if (finishing) |at| self.replay_profile.?.prepare_ns += ReplayProfile.elapsed(at, self.io);
        strings.report();
    }

    if (mode == .unpublished and self.options.pipeline_replay and size >= 256 * 1024 and
        try self.recoverPipelined(size, &scratch))
    {
        try self.finishReplay();
        return;
    }

    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.Reader.initSize(self.file.?, self.io, &buffer, size);
    var reader = self.memberReader(size);
    while (self.offset < size) {
        const decode_start = if (self.replay_profile != null) std.Io.Timestamp.now(self.io, .awake) else null;
        const member = (try reader.next(&input)) orelse break;
        if (decode_start) |at| {
            profile.decode_ns += ReplayProfile.elapsed(at, self.io);
            profile.bytes += member.bytes.len;
        }
        const parse_start = if (decode_start != null) std.Io.Timestamp.now(self.io, .awake) else null;
        const options = self.parseOptions();
        var t = try Pipeline.parseMember(self.gpa, options, options.first_sequence, member.bytes);
        var adopted = false;
        defer if (!adopted) t.deinit();
        if (parse_start) |at| {
            profile.parse_ns += ReplayProfile.elapsed(at, self.io);
            profile.frames += t.frames.len;
        }
        try self.recoverTransaction(&t, member.length, mode, &scratch);
        adopted = true;
    }
    self.pending_repair = reader.incomplete;
    if (mode == .unpublished) try self.finishReplay();
}

fn finishReplay(self: *Journal) !void {
    const start = if (self.replay_profile != null) std.Io.Timestamp.now(self.io, .awake) else null;
    try self.state.extensions.ownReplayValues();
    if (start) |at| {
        const elapsed = ReplayProfile.elapsed(at, self.io);
        self.replay_profile.?.prepare_ns += elapsed;
        self.replay_profile.?.phases.extensions += elapsed;
    }
}

fn recoverTransaction(self: *Journal, t: *Transaction, length: u64, mode: ReplayMode, scratch: *std.heap.ArenaAllocator) !void {
    if (self.transaction_ids.contains(t.id())) return error.TransactionConflict;
    const owned_id = try self.gpa.dupe(u8, t.id());
    errdefer self.gpa.free(owned_id);
    try self.transactions.ensureUnusedCapacity(self.gpa, 1);
    try self.transaction_ids.ensureUnusedCapacity(self.gpa, 1);
    self.pending = t;
    defer self.pending = null;
    const start = if (self.replay_profile != null) std.Io.Timestamp.now(self.io, .awake) else null;
    self.replayMember(t, owned_id, length, mode, scratch) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled, error.MissingExtensionContract, error.MissingRenderer => return err,
        else => return error.InvalidJournal,
    };
    self.offset += length;
    if (start) |at| {
        self.replay_profile.?.prepare_ns += ReplayProfile.elapsed(at, self.io);
        self.replay_profile.?.members += 1;
    }
}

fn replayMember(self: *Journal, t: *Transaction, id: []const u8, length: u64, mode: ReplayMode, scratch: *std.heap.ArenaAllocator) !void {
    if (mode == .unpublished) {
        try self.state.replayUnpublished(self.source(), t, self.options.contracts, self.options.renderers, scratch);
        try self.state.extensions.compactReplay(self.extension_replay.?, self.options.contracts);
        self.remember(t, id, length);
        self.sequence = self.state.sequence;
    } else {
        const candidate = try self.state.prepare(self.source(), t, self.options.contracts, self.options.renderers);
        self.adopt(t, candidate, id, length);
    }
}

test "semantic gzip transactions reopen and repair only an incomplete suffix on commit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.jsonl.gz" });
    defer a.free(path);
    const empty: F.Value = .{ .object = .empty };
    {
        var journal = try open(a, io, path, "test", .{});
        defer journal.deinit();
        _ = try journal.commit("first", .{ .kind = .host, .id = "host" }, &.{.{ .@"capability.bind" = .{ .name = "files", .service = .{ .id = "files", .version = "1" }, .config = empty } }});
        try std.testing.expectError(error.JournalLocked, open(a, io, path, "test", .{}));
    }
    {
        var journal = try open(a, io, path, "test", .{});
        defer journal.deinit();
        try std.testing.expectEqual(@as(u64, 1), journal.sequence);
        try std.testing.expectEqual(@as(u64, 1), journal.state.bindings.get("files").?);
        var state = try journal.stateAt(a, 0);
        defer state.deinit();
        try std.testing.expectEqual(@as(usize, 0), state.bindings.count());
        const file = journal.file.?;
        try file.writePositionalAll(io, &.{ 0x1f, 0x8b }, journal.offset);
        try file.sync(io);
    }
    {
        var journal = try open(a, io, path, "test", .{});
        defer journal.deinit();
        try std.testing.expect(journal.pending_repair);
        try std.testing.expectEqual(journal.offset + 2, (try journal.file.?.stat(io)).size);
        _ = try journal.commit("second", .{ .kind = .host, .id = "host" }, &.{.{ .@"capability.unbind" = .{ .name = "files", .binding = 1 } }});
        try std.testing.expectEqual(journal.offset, (try journal.file.?.stat(io)).size);
    }
}
