//! Process-local Codex transport state keyed by the host's session ID.
const std = @import("std");
const Link = @import("responses_websocket.zig").Link;
const Sessions = @This();

allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
sse_sessions: std.StringHashMapUnmanaged(void) = .empty,
sockets: std.AutoHashMapUnmanaged(Key, *Slot) = .empty,
idle_changed: std.Io.Condition = .init,
reaper: std.Io.Group = .init,
reaper_started: bool = false,

const idle_limit: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(5 * 60) };
const age_limit: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(45 * 60) };
const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;
const Key = struct { session: Digest, upgrade: Digest };
const Idle = struct { link: *Link, expires: std.Io.Clock.Timestamp };
const Slot = struct {
    idle: ?Idle = null,
    // Used only after removing an idle slot from the cache.
    closing_next: ?*Slot = null,
};
const Expiry = struct { key: Key, idle: Idle };

pub fn deinit(self: *Sessions) void {
    self.reaper.cancel(self.io);
    var slots = self.sockets.valueIterator();
    while (slots.next()) |slot| {
        slot.*.idle.?.link.destroy();
        self.allocator.destroy(slot.*);
    }
    self.sockets.deinit(self.allocator);
    var keys = self.sse_sessions.keyIterator();
    while (keys.next()) |key| self.allocator.free(key.*);
    self.sse_sessions.deinit(self.allocator);
}

/// Call after the retiring worker's admitted operations have joined.
pub fn closeSockets(self: *Sessions, session_id: []const u8) void {
    const session = sessionDigest(session_id);
    var closing: ?*Slot = null;
    self.mutex.lockUncancelable(self.io);
    while (true) switch (self.removeSessionSlotLocked(session)) {
        .absent => break,
        .leased => {}, // The unlinked slot stays owned by its admitted request.
        .idle => |slot| {
            slot.closing_next = closing;
            closing = slot;
        },
    };
    self.idle_changed.signal(self.io);
    self.mutex.unlock(self.io);
    while (closing) |slot| {
        closing = slot.closing_next;
        slot.idle.?.link.destroy();
        self.allocator.destroy(slot);
    }
}

fn removeSessionSlotLocked(self: *Sessions, session: Digest) union(enum) { absent, leased, idle: *Slot } {
    var it = self.sockets.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, &entry.key_ptr.session, &session)) {
            const key = entry.key_ptr.*;
            const slot = self.sockets.fetchRemove(key).?.value;
            return if (slot.idle == null) .leased else .{ .idle = slot };
        }
    }
    return .absent;
}

fn reapIdle(self: *Sessions) void {
    const io = self.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    while (true) {
        io.checkCancel() catch return;
        if (self.nextExpiryLocked()) |entry| {
            const now: std.Io.Clock.Timestamp = .now(io, .awake);
            if (entry.idle.expires.raw.nanoseconds <= now.raw.nanoseconds) {
                const slot = self.sockets.fetchRemove(entry.key).?.value;
                self.mutex.unlock(io);
                entry.idle.link.destroy();
                self.allocator.destroy(slot);
                self.mutex.lockUncancelable(io);
                continue;
            }
            self.idle_changed.waitTimeout(io, &self.mutex, .{ .deadline = entry.idle.expires }) catch |err| switch (err) {
                error.Canceled => return,
                error.Timeout => {},
            };
        } else {
            self.idle_changed.wait(io, &self.mutex) catch return;
        }
    }
}

fn startReaperLocked(self: *Sessions) bool {
    if (self.reaper_started) return true;
    self.reaper.concurrent(self.io, reapIdle, .{self}) catch |err| {
        std.log.debug("Codex WebSocket idle timer unavailable ({s})", .{@errorName(err)});
        return false;
    };
    self.reaper_started = true;
    return true;
}

fn nextExpiryLocked(self: *Sessions) ?Expiry {
    var next: ?Expiry = null;
    var it = self.sockets.iterator();
    while (it.next()) |entry| {
        const idle = entry.value_ptr.*.idle orelse continue;
        if (next == null or idle.expires.raw.nanoseconds < next.?.idle.expires.raw.nanoseconds)
            next = .{ .key = entry.key_ptr.*, .idle = idle };
    }
    return next;
}

fn sessionDigest(id: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(id, &digest, .{});
    return digest;
}

fn addPart(hash: *Sha256, part: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, part.len, .big);
    hash.update(&length);
    hash.update(part);
}

/// Only an exclusive lease can access a stream. Overlapping requests use a
/// temporary connection, and an unlinked lease cannot republish its socket.
pub const Lease = struct {
    link: ?*Link = null,
    reservation: ?Reservation = null,

    const Reservation = struct {
        session: Session,
        key: Key,
        slot: *Slot,
    };

    pub fn release(self: *Lease, keep: bool) void {
        const link = self.link;
        defer self.* = .{};
        if (self.reservation) |reservation| {
            const sessions = reservation.session.sessions;
            const io = sessions.io;
            sessions.mutex.lockUncancelable(io);
            if (sessions.sockets.get(reservation.key) == reservation.slot) {
                if (keep and link != null and !sessions.sse_sessions.contains(reservation.session.id) and sessions.startReaperLocked()) {
                    const now: std.Io.Clock.Timestamp = .now(io, .awake);
                    reservation.slot.idle = .{ .link = link.?, .expires = now.addDuration(idle_limit) };
                    sessions.idle_changed.signal(io);
                    sessions.mutex.unlock(io);
                    return;
                }
                _ = sessions.sockets.remove(reservation.key);
            }
            sessions.mutex.unlock(io);
            sessions.allocator.destroy(reservation.slot);
        }
        if (link) |socket| socket.destroy();
    }
};

/// Borrows the session ID for the duration of an admitted request.
pub const Session = struct {
    sessions: *Sessions,
    id: []const u8,

    pub const Route = union(enum) { sse, websocket: Lease };

    pub fn acquire(self: Session, url: []const u8, headers: []const std.http.Header) !Route {
        var hash: Sha256 = .init(.{});
        addPart(&hash, url);
        for (headers) |header| {
            addPart(&hash, header.name);
            addPart(&hash, header.value);
        }
        const key: Key = .{ .session = sessionDigest(self.id), .upgrade = hash.finalResult() };
        const sessions = self.sessions;
        const io = sessions.io;
        var stale: ?*Link = null;
        defer if (stale) |link| link.destroy();
        sessions.mutex.lockUncancelable(io);
        defer sessions.mutex.unlock(io);
        if (sessions.sse_sessions.contains(self.id)) return .sse;
        if (sessions.sockets.get(key)) |slot| {
            const idle = slot.idle orelse return .{ .websocket = .{} };
            slot.idle = null;
            const now: std.Io.Clock.Timestamp = .now(io, .awake);
            const age = idle.link.created_at.durationTo(now);
            const expired = now.raw.nanoseconds >= idle.expires.raw.nanoseconds or age.raw.nanoseconds >= age_limit.raw.nanoseconds;
            if (expired) stale = idle.link;
            return .{ .websocket = .{
                .link = if (expired) null else idle.link,
                .reservation = .{ .session = self, .key = key, .slot = slot },
            } };
        }
        const slot = try sessions.allocator.create(Slot);
        errdefer sessions.allocator.destroy(slot);
        slot.* = .{};
        try sessions.sockets.putNoClobber(sessions.allocator, key, slot);
        return .{ .websocket = .{ .reservation = .{ .session = self, .key = key, .slot = slot } } };
    }

    pub fn preferSse(self: Session) !void {
        const sessions = self.sessions;
        const io = sessions.io;
        var changed = false;
        defer if (changed) sessions.closeSockets(self.id);
        sessions.mutex.lockUncancelable(io);
        defer sessions.mutex.unlock(io);
        if (sessions.sse_sessions.contains(self.id)) return;
        const key = try sessions.allocator.dupe(u8, self.id);
        errdefer sessions.allocator.free(key);
        try sessions.sse_sessions.putNoClobber(sessions.allocator, key, {});
        changed = true;
    }
};
