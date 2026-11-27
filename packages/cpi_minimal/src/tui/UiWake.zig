//! Coalesce background notifications without interrupting a terminal read.
const std = @import("std");
const Input = @import("Input.zig");
const Io = std.Io;
const Self = @This();
const Terminal = anyerror!?@import("kit").terminal.keys.Event;

pub const Signal = union(enum) { timeout, changed, suspension, terminal: Terminal };

pub const Notification = struct {
    wake: ?*Self = null,

    pub fn signal(self: Notification) void {
        if (self.wake) |wake| wake.notify();
    }
};

pub fn notification(self: *Self) Notification {
    return .{ .wake = self };
}

pub fn notifyContext(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.notify();
}

io: Io,
mutex: Io.Mutex = .init,
ready: Io.Condition = .init,
changed: bool = false,
terminal: ?Terminal = null,

pub fn notify(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.changed = true;
    self.ready.signal(self.io);
}

/// Only one read is outstanding. Borrowed paste bytes remain valid until the
/// consumer dispatches the event and starts the next read.
pub fn read(self: *Self, input: *Input) void {
    const event = input.next(self.io, null);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.terminal = event;
    self.ready.signal(self.io);
}

/// Used after joining a reader during suspension. Preserve any event that
/// raced with cancellation, including a paste borrowing the input buffer.
pub fn discardCanceledRead(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.terminal) |event| {
        _ = event catch |err| {
            if (err == error.Canceled) self.terminal = null;
            return;
        };
    }
}

pub fn hasTerminal(self: *Self) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.terminal != null;
}

pub fn wait(self: *Self, deadline: ?Io.Timestamp) !Signal {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const timeout: Io.Timeout = if (deadline) |due| .{ .deadline = due.withClock(.awake) } else .none;
    while (!self.changed and self.terminal == null) {
        self.ready.waitTimeout(self.io, &self.mutex, timeout) catch |err| switch (err) {
            error.Timeout => break,
            error.Canceled => return err,
        };
    }
    const signal: Signal = if (self.terminal) |event|
        .{ .terminal = event }
    else if (self.changed)
        .changed
    else
        .timeout;
    self.terminal = null;
    self.changed = false;
    return signal;
}
