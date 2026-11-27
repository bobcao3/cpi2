const std = @import("std");
const tui = @import("kit").tui;
const Geometry = tui.Selection;

const State = @This();
const Timestamp = std.Io.Timestamp;
const Click = struct { row: u32, span: Geometry.Span, time: Timestamp, count: u2 };
const Granularity = enum { character, word, line };

anchor: ?Geometry.Point = null,
focus: ?Geometry.Point = null,
active: bool = false,
copy_pending: bool = false,
initial: ?Geometry.Range = null,
granularity: Granularity = .character,
last_click: ?Click = null,
scroll_at: ?Timestamp = null,
scroll_direction: i8 = 0,
column: u32 = 0,

pub fn clear(self: *State) void {
    const last_click = self.last_click;
    self.* = .{ .last_click = last_click };
}

pub fn blur(self: *State) void {
    self.last_click = null;
    if (self.active) self.clear();
}

pub fn range(self: *const State) ?Geometry.Range {
    return Geometry.Range.between(self.anchor orelse return null, self.focus orelse return null);
}

pub fn press(self: *State, point: Geometry.Point, span: ?Geometry.Span, width: u16, now: Timestamp) void {
    self.clear();
    self.active = true;
    self.anchor = point;
    self.focus = point;
    const word = span orelse {
        self.last_click = null;
        return;
    };
    const count: u2 = if (self.last_click) |last|
        if (last.row == point.row and last.span.start == word.start and last.span.end == word.end and
            last.time.durationTo(now).toMilliseconds() <= 500) last.count % 3 + 1 else 1
    else
        1;
    self.last_click = .{ .row = point.row, .span = word, .time = now, .count = count };
    if (count == 1) return;
    self.granularity = if (count == 2) .word else .line;
    const selected = rowRange(point.row, if (count == 2) word else .{ .start = 0, .end = width });
    self.initial = selected;
    self.anchor = selected.start;
    self.focus = selected.end;
}

pub fn move(self: *State, point: Geometry.Point, word: ?Geometry.Span, width: u16) void {
    if (self.initial) |initial| {
        const span: Geometry.Span = switch (self.granularity) {
            .word => word orelse return,
            .line => .{ .start = 0, .end = width },
            .character => unreachable,
        };
        const selected = rowRange(point.row, span);
        if (selected.start.before(initial.start)) {
            self.anchor = initial.end;
            self.focus = selected.start;
        } else {
            self.anchor = initial.start;
            self.focus = selected.end;
        }
    } else self.focus = point;
}

pub fn drag(self: *State, point: Geometry.Point, word: ?Geometry.Span, width: u16, direction: i8, now: Timestamp) void {
    self.last_click = null;
    self.move(point, word, width);
    self.column = point.column;
    self.scroll_direction = direction;
    self.scroll_at = if (direction == 0) null else self.scroll_at orelse now.addDuration(.fromMilliseconds(50));
}

pub fn finish(self: *State, point: Geometry.Point, word: ?Geometry.Span, width: u16) void {
    self.move(point, word, width);
    self.active = false;
    self.scroll_at = null;
    self.copy_pending = self.range() != null;
}

fn rowRange(row: u32, span: Geometry.Span) Geometry.Range {
    return .{
        .start = .{ .row = row, .column = span.start },
        .end = .{ .row = row, .column = span.end, .boundary = true },
    };
}
