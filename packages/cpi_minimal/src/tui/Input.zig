const std = @import("std");
const keys = @import("kit").terminal.keys;
const Input = @This();
const Io = std.Io;

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8) = .empty,
head: usize = 0,
paste: enum { none, collecting, discarding } = .none,
paste_scan: usize = 0,
escape_since: ?Io.Timestamp = null,

pub const paste_warning_bytes = 8 * 1024 * 1024;
const paste_begin = "\x1b[200~";
const paste_end = "\x1b[201~";
const escape_delay: Io.Duration = .fromMilliseconds(25);

pub fn init(allocator: std.mem.Allocator) Input {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Input) void {
    self.buffer.deinit(self.allocator);
    self.* = undefined;
}

/// The caller owns terminal mode and protocols and must provide exclusive stdin access.
/// Returned event bytes borrow storage until the next call or deinit.
/// A null timeout waits indefinitely; a finite timeout bounds the entire call.
/// Escape and the ambiguous Alt+] prefix expire. Partial reports and pastes survive timeouts.
pub fn next(self: *Input, io: Io, timeout: ?Io.Duration) !?keys.Event {
    self.compact();
    const deadline = if (timeout) |duration| Io.Timestamp.now(io, .awake).addDuration(duration) else null;
    while (true) {
        const now = Io.Timestamp.now(io, .awake);
        const bytes = self.buffer.items[self.head..];
        const lone_escape = self.paste == .none and (std.mem.eql(u8, bytes, "\x1b") or std.mem.eql(u8, bytes, "\x1b]"));
        if (lone_escape) {
            if (self.escape_since == null) self.escape_since = now;
        } else self.escape_since = null;
        const escape_deadline = if (self.escape_since) |since| since.addDuration(escape_delay) else null;
        const resolve_escape = if (escape_deadline) |end| now.compare(.gte, end) else false;
        const event = self.decodeBuffered(resolve_escape);
        if (event) |value| return value;
        if (deadline) |end| if (now.compare(.gte, end)) return null;

        var until = deadline;
        if (escape_deadline) |end| {
            if (until == null or end.compare(.lt, until.?)) until = end;
        }
        const received = self.read(io, until) catch |err| {
            if (err == error.OutOfMemory and self.paste != .none) {
                self.discardPaste();
            }
            return err;
        };
        if (!received) {
            if (escape_deadline) |end| {
                if (Io.Timestamp.now(io, .awake).compare(.gte, end)) continue;
            }
            return null;
        }
    }
}

fn compact(self: *Input) void {
    if (self.head == self.buffer.items.len) {
        if (self.paste == .none and self.buffer.capacity > 65536) self.buffer.clearAndFree(self.allocator) else self.buffer.clearRetainingCapacity();
        self.head = 0;
    } else if (self.head >= 4096 and self.head >= self.buffer.items.len / 2) {
        const remaining = self.buffer.items.len - self.head;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.head..]);
        self.buffer.items.len = remaining;
        self.head = 0;
    }
}

fn read(self: *Input, io: Io, deadline: ?Io.Timestamp) !bool {
    if (self.paste != .discarding) try self.buffer.ensureUnusedCapacity(self.allocator, 4096);
    const unused = self.buffer.unusedCapacitySlice();
    const target = unused[0..@min(unused.len, 4096)];
    std.debug.assert(target.len != 0);
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, .{ .file_read_streaming = .{ .file = .stdin(), .data = &.{target} } });
    const timeout: Io.Timeout = if (deadline) |end| .{ .deadline = end.withClock(.awake) } else .none;
    var canceled = false;
    batch.awaitConcurrent(io, timeout) catch |err| switch (err) {
        error.Timeout => batch.cancel(io),
        error.Canceled => {
            canceled = true;
            batch.cancel(io);
        },
        else => return err,
    };
    // Cancellation can race with a successful read; retain every completed byte.
    const completion = batch.next() orelse {
        if (canceled) return error.Canceled;
        // Some I/O backends round read timeouts down to whole milliseconds.
        if (deadline) |end| try (Io.Timeout{ .deadline = end.withClock(.awake) }).sleep(io);
        return false;
    };
    const count = try completion.result.file_read_streaming;
    if (count == 0) return error.EndOfStream;
    self.buffer.items.len += count;
    if (canceled) return error.Canceled;
    return true;
}

fn discardPaste(self: *Input) void {
    const bytes = self.buffer.items[self.head..];
    const keep = @min(bytes.len, paste_end.len - 1);
    std.mem.copyForwards(u8, self.buffer.items[0..keep], bytes[bytes.len - keep ..]);
    if (self.buffer.items.len > 8192) self.buffer.shrinkAndFree(self.allocator, 8192);
    self.buffer.items.len = keep;
    self.head = 0;
    self.paste = .discarding;
    self.paste_scan = 0;
}

fn decodeBuffered(self: *Input, resolve_escape: bool) ?keys.Event {
    while (true) {
        const bytes = self.buffer.items[self.head..];
        if (self.paste != .none) {
            if (std.mem.indexOfPos(u8, bytes, self.paste_scan, paste_end)) |end| {
                const payload = bytes[0..end];
                const discarded = self.paste == .discarding;
                self.head += end + paste_end.len;
                self.paste = .none;
                self.paste_scan = 0;
                if (discarded) return .ignore;
                return .{ .paste = payload };
            }
            if (self.paste == .discarding) {
                self.discardPaste();
            } else self.paste_scan = bytes.len -| (paste_end.len - 1);
            return null;
        }
        if (bytes.len == 0) return null;
        if (std.mem.startsWith(u8, bytes, paste_begin)) {
            self.head += paste_begin.len;
            self.paste = .collecting;
            self.paste_scan = 0;
            continue;
        }
        if (modifiedKey(bytes)) |decoded| {
            self.head += decoded.len;
            return decoded.event;
        }
        const decoded = keys.decode(bytes, .{ .escape = if (resolve_escape) .resolve else .wait }) orelse return null;
        std.debug.assert(decoded.len > 0 and decoded.len <= bytes.len);
        self.head += decoded.len;
        return decoded.event;
    }
}

fn modifiedKey(bytes: []const u8) ?keys.Decoded {
    if (!std.mem.startsWith(u8, bytes, "\x1b[")) return null;
    const final = for (bytes[2..], 2..) |byte, index| {
        if (byte >= 0x40 and byte <= 0x7e) break index;
    } else return null;
    if (bytes[final] != '~') return null;
    const parameters = bytes[2..final];
    var fields = std.mem.splitScalar(u8, parameters, ';');
    const first = fields.next() orelse return null;
    const modifier = fields.next() orelse return null;
    const codepoint = if (std.mem.eql(u8, first, "27"))
        fields.next() orelse return null
    else if (std.mem.eql(u8, first, "13"))
        "13"
    else
        return null;
    if (fields.next() != null) return null;
    const mods = std.fmt.parseInt(u16, modifier, 10) catch return null;
    const cp = std.fmt.parseInt(u21, codepoint, 10) catch return null;
    if (mods == 0 or mods > 256 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return null;
    var storage: [32]u8 = undefined;
    const csi_u = std.fmt.bufPrint(&storage, "\x1b[{d};{d}u", .{ cp, mods }) catch unreachable;
    const decoded = keys.decode(csi_u, .{}) orelse return null;
    if (decoded.event != .key) return null;
    return .{ .len = final + 1, .event = decoded.event };
}
