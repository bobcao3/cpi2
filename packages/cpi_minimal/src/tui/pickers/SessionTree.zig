const std = @import("std");
const kit = @import("kit");
const tui = kit.tui;
const ComposerView = @import("../composer.zig").ComposerView;
const md = @import("../transcript.zig").markdown;
const j = @import("../../json.zig");
const ToolView = @import("../transcript.zig").ToolView;
const Theme = @import("../style.zig").Theme;
const Presentation = @import("../UiPresentation.zig");
const Frame = Presentation.Frame;
const Controller = @import("../../session.zig").Controller;
const Entry = Controller.TreeEntry;
const Key = kit.terminal.keys.Key;
const Allocator = std.mem.Allocator;
const Self = @This();

const Filter = Presentation.TreeFilter;
const SummaryChoice = Presentation.SummaryChoice;
const summary_choices = std.enums.values(SummaryChoice);

const Links = struct {
    parent: ?usize = null,
    first: ?usize = null,
    next: ?usize = null,
    children: usize = 0,

    fn prepend(self: *Links, index: usize, links: []Links) void {
        links[index].next = self.first;
        self.first = index;
        self.children += 1;
    }
};

const State = struct {
    on_path: bool = false,
    folded: bool = false,
    hidden_by_fold: bool = false,
    visible: ?usize = null,
};

const Row = struct {
    index: usize,
    indent: usize,
    connector: bool,
    last: bool,
    gutter: ?usize = null,
};

pub const Action = enum { none, close, choose, reopen, navigate, summarize, save_label, copy, external };
const Stage = enum { tree, confirm, label, custom_prompt };

arena: std.heap.ArenaAllocator,
entries: []Entry,
head: ?usize,
order: []usize,
links: []Links,
visible: []Links,
visible_roots: Links = .{},
states: []State,
rows: std.ArrayList(Row) = .empty,
selected: usize = 0,
last_selected: ?usize,
query: std.ArrayList(u8) = .empty,
filter: Filter = .default,
timestamps: bool = false,
stage: Stage = .tree,
choice: usize = 0,
input: tui.Editor,
page_size: usize = 5,

pub fn create(a: Allocator, controller: *Controller, height: usize, selected_id: ?[]const u8) !*Self {
    const self = try a.create(Self);
    errdefer a.destroy(self);
    self.arena = .init(a);
    errdefer self.arena.deinit();
    const arena = self.arena.allocator();
    const snapshot = try controller.sessionTree(arena);
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    defer ids.deinit(a);
    const links = try arena.alloc(Links, snapshot.entries.len);
    @memset(links, .{});
    for (snapshot.entries, links, 0..) |entry, *link, i| {
        link.parent = ids.get(entry.parent);
        try ids.put(a, entry.id, i);
    }
    const head = if (snapshot.head) |id| ids.get(id) else null;
    const order = try arena.alloc(usize, snapshot.entries.len);
    const visible = try arena.alloc(Links, snapshot.entries.len);
    const states = try arena.alloc(State, snapshot.entries.len);
    self.* = .{
        .arena = self.arena,
        .entries = snapshot.entries,
        .head = head,
        .order = order,
        .links = links,
        .visible = visible,
        .states = states,
        .last_selected = (if (selected_id) |id| ids.get(id) else null) orelse head,
        .page_size = @max(5, height / 2),
        .input = .init(a),
    };
    errdefer self.input.deinit();
    @memset(self.states, .{});
    var parent = head;
    while (parent) |i| : (parent = links[i].parent) self.states[i].on_path = true;

    var roots: Links = .{};
    for ([_]bool{ false, true }) |active| {
        var i = links.len;
        while (i > 0) {
            i -= 1;
            if (self.states[i].on_path != active) continue;
            const siblings = if (links[i].parent) |p| &links[p] else &roots;
            siblings.prepend(i, links);
        }
    }
    var next = roots.first;
    for (self.order) |*i| {
        i.* = next.?;
        next = self.nextNode(i.*);
    }
    try self.rows.ensureTotalCapacity(self.arena.allocator(), links.len);
    try self.refilter(false);
    return self;
}

pub fn destroy(self: *Self, a: Allocator) void {
    self.input.deinit();
    self.arena.deinit();
    a.destroy(self);
}

fn nextNode(self: *const Self, index: usize) ?usize {
    if (self.links[index].first) |child| return child;
    var i = index;
    while (true) {
        if (self.links[i].next) |sibling| return sibling;
        i = self.links[i].parent orelse return null;
    }
}

pub fn target(self: *const Self) ?*const Entry {
    if (self.rows.items.len == 0) return null;
    return &self.entries[self.rows.items[self.selected].index];
}

pub fn label(self: *const Self) []const u8 {
    return std.mem.trim(u8, self.input.text(), " \t\r\n");
}

pub fn summaryFocus(self: *const Self) []const u8 {
    return if (self.stage == .custom_prompt) self.input.text() else "";
}

pub fn applyLabel(self: *Self, text: []const u8, now_ms: i64) !void {
    const entry = &self.entries[self.rows.items[self.selected].index];
    const a = self.arena.allocator();
    const owned = try a.dupe(u8, text);
    a.free(entry.label);
    entry.label = owned;
    entry.label_time = now_ms;
    self.stage = .tree;
    try self.refilter(false);
}

fn foldable(self: *const Self, i: usize) bool {
    return self.visible[i].children > 0 and
        (if (self.visible[i].parent) |p| self.visible[p].children > 1 else true);
}

fn role(kind: Entry.Kind) []const u8 {
    return switch (kind) {
        .tool => "toolResult",
        .bash => "bashExecution",
        .branch_summary => "branch summary",
        .context => "context edit",
        .codemode_store => "custom",
        else => @tagName(kind),
    };
}

fn foldedText(a: Allocator, bytes: []const u8, split_words: bool) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var view = (std.unicode.Utf8View.init(bytes) catch return bytes).iterator();
    while (view.nextCodepoint()) |cp| {
        var scalar: [4]u8 = undefined;
        const lower = if (split_words and kit.unicode.isEcmaWhitespace(cp)) ' ' else kit.unicode.foldCaseSimple(cp);
        const len = std.unicode.utf8Encode(lower, &scalar) catch continue;
        try result.appendSlice(a, scalar[0..len]);
    }
    return result.items;
}

fn matches(self: *const Self, a: Allocator, i: usize, tokens: []const u8) !bool {
    const entry = self.entries[i];
    if (entry.kind == .assistant and self.head != i and !tui.Editor.hasText(entry.text) and
        entry.diagnostic.len == 0 and !interrupted(entry) and !std.mem.eql(u8, entry.status, "failed")) return false;
    const show = switch (self.filter) {
        .default => switch (entry.kind) {
            .model, .thinking, .context, .title, .label, .codemode_store, .internal => false,
            else => true,
        },
        .no_tools => switch (entry.kind) {
            .tool, .model, .thinking, .context, .title, .label, .codemode_store, .internal => false,
            else => true,
        },
        .user => entry.kind == .user,
        .labeled => entry.label.len != 0,
        .all => entry.kind != .internal,
    };
    if (!show) return false;
    if (tokens.len == 0) return true;
    const phrase = try std.mem.join(a, " ", &.{
        entry.label, role(entry.kind), entry.name,
        switch (entry.kind) {
            .compaction => "",
            .title => entry.text,
            else => excerpt(entry.text, 200),
        },
    });
    const haystack = try foldedText(a, phrase, false);
    var words = std.mem.tokenizeAny(u8, tokens, " \t\r\n");
    while (words.next()) |word| if (std.mem.indexOf(u8, haystack, word) == null) return false;
    return true;
}

fn refilter(self: *Self, reset_folds: bool) !void {
    if (self.rows.items.len != 0) self.last_selected = self.rows.items[self.selected].index;
    var scratch: std.heap.ArenaAllocator = .init(self.input.allocator);
    defer scratch.deinit();
    const query = try foldedText(scratch.allocator(), self.query.items, true);
    var per_row: std.heap.ArenaAllocator = .init(self.input.allocator);
    defer per_row.deinit();
    const passes = try scratch.allocator().alloc(bool, self.states.len);
    for (self.order) |i| {
        _ = per_row.reset(.retain_capacity);
        passes[i] = try self.matches(per_row.allocator(), i, query);
    }
    @memset(self.visible, .{});
    self.visible_roots = .{};
    self.rows.clearRetainingCapacity();
    for (self.order) |i| {
        const state = &self.states[i];
        const parent = self.links[i].parent;
        state.visible = null;
        if (reset_folds) state.folded = false;
        state.hidden_by_fold = if (parent) |p| self.states[p].folded or self.states[p].hidden_by_fold else false;
        self.visible[i].parent = if (parent) |p| if (self.states[p].visible != null) p else self.visible[p].parent else null;
        if (state.hidden_by_fold or !passes[i]) continue;
        state.visible = self.rows.items.len;
        self.rows.appendAssumeCapacity(.{ .index = i, .indent = 0, .connector = false, .last = false });
    }

    var rows = std.mem.reverseIterator(self.rows.items);
    while (rows.next()) |row| {
        const i = row.index;
        const siblings = if (self.visible[i].parent) |p| &self.visible[p] else &self.visible_roots;
        siblings.prepend(i, self.visible);
    }
    const multiple_roots = self.visible_roots.children > 1;
    for (self.rows.items) |*row| {
        const link = self.visible[row.index];
        row.last = link.next == null;
        if (link.parent) |p| {
            const ancestor = self.rows.items[self.states[p].visible.?];
            row.connector = self.visible[p].children > 1;
            const grouping = ancestor.connector or (self.visible[p].parent == null and multiple_roots);
            row.indent = ancestor.indent + @intFromBool(row.connector or grouping);
            row.gutter = if (ancestor.connector) self.states[p].visible else ancestor.gutter;
        }
    }

    self.selected = self.rows.items.len -| 1;
    var nearest = self.last_selected;
    while (nearest) |i| : (nearest = self.links[i].parent) {
        if (self.states[i].visible) |row| {
            self.selected = row;
            break;
        }
    }
}

fn branch(self: *Self, down: bool) !void {
    if (self.rows.items.len == 0) return;
    var i = self.rows.items[self.selected].index;
    if ((down and self.states[i].folded) or (!down and !self.states[i].folded and self.foldable(i))) {
        self.states[i].folded = !down;
        return self.refilter(false);
    }
    if (down) {
        while (self.visible[i].first) |child| {
            const branches = self.visible[i].children > 1;
            i = child;
            if (branches) break;
        }
    } else {
        while (self.visible[i].parent) |parent| {
            if (self.visible[parent].children > 1 and self.states[i].visible.? < self.selected) break;
            i = parent;
        }
    }
    self.selected = self.states[i].visible.?;
}

fn switchFilter(self: *Self, mode: Filter) !void {
    self.filter = if (self.filter == mode) .default else mode;
    try self.refilter(true);
}

pub fn paste(self: *Self, bytes: []const u8) !void {
    switch (self.stage) {
        .label => {
            const len = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
            try self.input.insert(bytes[0..len]);
        },
        .custom_prompt => try self.input.insert(bytes),
        .confirm => {},
        .tree => {
            for (bytes) |byte| if (byte < 32 or byte == 127) return;
            try self.query.appendSlice(self.arena.allocator(), bytes);
            try self.refilter(true);
        },
    }
}

pub fn key(self: *Self, k: Key, external_editor: bool) !Action {
    const mods = k.mods;
    if (mods.hyper or mods.meta or mods.super) return .none;
    const cancel = k.code == .escape or (k.code == .char and mods.ctrl and k.code.char == 'c');
    switch (self.stage) {
        .confirm => {
            if (cancel) return .reopen;
            switch (k.code) {
                .up => self.choice -|= 1,
                .down => self.choice = @min(summary_choices.len - 1, self.choice + 1),
                .enter => switch (summary_choices[self.choice]) {
                    .navigate => return .navigate,
                    .summarize => return .summarize,
                    .custom_prompt => {
                        self.input.clear();
                        self.stage = .custom_prompt;
                    },
                },
                .char => |cp| if (!mods.ctrl and !mods.alt) {
                    if (cp == 'j') self.choice = @min(summary_choices.len - 1, self.choice + 1);
                    if (cp == 'k') self.choice -|= 1;
                },
                else => {},
            }
            return .none;
        },
        .label, .custom_prompt => {
            const label_entry = self.stage == .label;
            if (cancel) {
                self.stage = if (label_entry) .tree else .confirm;
            } else if (!label_entry and external_editor) {
                return .external;
            } else if (k.code == .enter and !mods.shift) {
                return if (label_entry) .save_label else .summarize;
            } else if (k.code == .enter) {
                if (!label_entry) try self.input.insert("\n");
            } else if (!label_entry and !mods.ctrl and !mods.alt and (k.code == .up or k.code == .down)) {
                try self.input.move(if (k.code == .up) .up else .down);
            } else if (!try self.input.editKey(k) and k.code == .char and !mods.ctrl and !mods.alt) {
                var bytes: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(k.code.char, &bytes);
                try self.input.typeText(bytes[0..len]);
            }
            return .none;
        },
        .tree => {},
    }
    if (cancel) {
        if (self.query.items.len == 0) return .close;
        self.query.clearRetainingCapacity();
        try self.refilter(true);
        return .none;
    }
    const is_branch = mods.ctrl or mods.alt;
    const count = self.rows.items.len;
    switch (k.code) {
        .up => if (count > 0 and !is_branch) {
            self.selected = (self.selected + count - 1) % count;
        },
        .down => if (count > 0 and !is_branch) {
            self.selected = (self.selected + 1) % count;
        },
        .page_up, .left => if (k.code == .left and is_branch) try self.branch(false) else {
            self.selected -|= self.page_size;
        },
        .page_down, .right => if (k.code == .right and is_branch) try self.branch(true) else {
            self.selected = @min(count -| 1, self.selected + self.page_size);
        },
        .enter => if (count != 0) return .choose,
        .backspace => if (self.query.items.len != 0) {
            var last = self.query.items.len - 1;
            while (last > 0 and self.query.items[last] & 0xc0 == 0x80) last -= 1;
            self.query.shrinkRetainingCapacity(last);
            try self.refilter(true);
        },
        .char => |cp| if (mods.ctrl and !mods.alt) {
            switch (std.ascii.toLower(@intCast(@min(cp, 127)))) {
                'd' => try self.switchFilter(.default),
                't' => try self.switchFilter(.no_tools),
                'u' => try self.switchFilter(.user),
                'l' => try self.switchFilter(.labeled),
                'a' => try self.switchFilter(.all),
                'x' => if (count != 0) return .copy,
                'o' => try self.switchFilter(@fromBackingInt(@intCast((@backingInt(self.filter) + @as(usize, if (mods.shift) 4 else 1)) % 5))),
                else => {},
            }
        } else if (!mods.alt) {
            const upper = if (mods.shift and cp <= 127) std.ascii.toUpper(@intCast(cp)) else cp;
            switch (upper) {
                'L' => if (self.target()) |entry| {
                    try self.input.set(entry.label);
                    self.stage = .label;
                },
                'T' => self.timestamps = !self.timestamps,
                else => {
                    var bytes: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp, &bytes);
                    try self.paste(bytes[0..len]);
                },
            }
        },
        else => {},
    }
    return .none;
}

pub fn confirm(self: *Self) void {
    self.stage = .confirm;
    self.choice = 0;
}

fn excerpt(bytes: []const u8, max: usize) []const u8 {
    if (bytes.len <= max) return bytes;
    var view = (std.unicode.Utf8View.init(bytes) catch return bytes[0..max]).iterator();
    var units: usize = 0;
    var end: usize = 0;
    while (view.nextCodepoint()) |cp| {
        units += if (cp > 0xffff) @as(usize, 2) else 1;
        if (units > max) break;
        end = view.i;
    }
    return bytes[0..end];
}

fn interrupted(entry: Entry) bool {
    return std.mem.eql(u8, entry.status, "cancelled") or std.mem.eql(u8, entry.status, "aborted");
}

fn oneLine(a: Allocator, bytes: []const u8) ![]const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    for (try md.clean(a, bytes)) |c| try normalized.append(a, if (c == '\n' or c == '\t') ' ' else c);
    return std.mem.trim(u8, normalized.items, " \t\r\n");
}

fn formatTool(a: Allocator, entry: Entry, home: []const u8) ![]const u8 {
    const args = entry.arguments;
    if (entry.name.len == 0) return "[tool]";
    if (args != .object) return std.fmt.allocPrint(a, "[{s}]", .{entry.name});
    var path = j.text(j.get(args, "path"));
    if (path.len == 0) path = j.text(j.get(args, "file_path"));
    if (home.len != 0 and (std.mem.eql(u8, path, home) or
        (std.mem.startsWith(u8, path, home) and path[home.len] == '/')))
        path = try std.fmt.allocPrint(a, "~{s}", .{path[home.len..]});
    const name = entry.name;
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit")) {
        const range = if (std.mem.eql(u8, name, "read")) try ToolView.readRange(a, args) else "";
        return std.fmt.allocPrint(a, "[{s}: {s}{s}]", .{ name, try oneLine(a, path), range });
    }
    if (std.mem.eql(u8, name, "bash")) {
        const command = j.text(j.get(args, "command"));
        return std.fmt.allocPrint(a, "[bash: {s}{s}]", .{ excerpt(try oneLine(a, command), 50), if (excerpt(command, 50).len < command.len) "..." else "" });
    }
    if (std.mem.eql(u8, name, "ls")) return std.fmt.allocPrint(a, "[ls: {s}]", .{if (path.len == 0) "." else try oneLine(a, path)});
    if (std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "find")) {
        const grep = std.mem.eql(u8, name, "grep");
        return std.fmt.allocPrint(a, "[{s}: {s}{s}{s} in {s}]", .{
            name,                                             if (grep) "/" else "", try oneLine(a, j.text(j.get(args, "pattern"))), if (grep) "/" else "",
            if (path.len == 0) "." else try oneLine(a, path),
        });
    }
    const payload = try j.encode(a, args);
    const short = excerpt(payload, 40);
    return std.fmt.allocPrint(a, "[{s}: {s}{s}]", .{ try oneLine(a, name), short, if (short.len < payload.len) "..." else "" });
}

const measure = kit.terminal.span_display_width.measure;

fn line(text: []const u8, base: ?tui.Style, bold: bool) tui.Node {
    var style = base orelse tui.Style{};
    style.bold = style.bold or bold;
    return .{ .text = .{ .bytes = text, .style = style, .overflow = .clip } };
}

fn styled(writer: *std.Io.Writer, text: []const u8, style: tui.Style) !void {
    if (text.len == 0) return;
    var sgr: [96]u8 = undefined;
    try writer.writeAll(style.sgr(&sgr));
    try writer.writeAll(text);
    try writer.writeAll("\x1b[0m");
}

const Span = struct { text: []const u8, style: ?tui.Style = null, inverse: bool = false };

fn drawSpans(a: Allocator, spans: []const Span, width: usize, skip: usize, selected: ?tui.Color, bold: bool) !tui.Node {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var column: usize = 0;
    for (spans) |span| {
        var iter = kit.unicode.grapheme.Iterator.init(span.text) catch continue;
        var start: ?usize = null;
        var offset: usize = 0;
        var end: usize = 0;
        while (iter.next()) |cluster| {
            const right = column + cluster.width;
            if (right > skip + width) break;
            if (column >= skip) {
                if (start == null) start = offset;
                end = offset + cluster.bytes.len;
            }
            offset += cluster.bytes.len;
            column = right;
        }
        if (start) |left| {
            var style = span.style orelse tui.Style{};
            style.background = selected;
            style.bold = bold;
            style.inverse = span.inverse;
            try styled(&out.writer, span.text[left..end], style);
        }
        if (offset < span.text.len) break;
    }
    return line(try out.toOwnedSlice(), null, false);
}

fn renderHelp(a: Allocator, rows: *std.ArrayList(tui.Node), width: u16, palette: *const Theme.Palette, help: []const []const u8) !void {
    var current: []const u8 = "";
    var columns: usize = 0;
    for (help) |item| {
        const item_width = measure(item);
        if (current.len != 0 and columns + 3 + item_width <= width) {
            current = try std.fmt.allocPrint(a, "{s} · {s}", .{ current, item });
            columns += 3 + item_width;
        } else {
            if (current.len != 0) try rows.append(a, palette.text(.muted, current));
            const pad = item_width + 2 <= width;
            current = if (pad) try std.mem.concat(a, u8, &.{ "  ", item }) else item;
            columns = item_width + @as(usize, if (pad) 2 else 0);
        }
    }
    if (current.len != 0) try rows.append(a, palette.text(.muted, current));
}

fn dateTime(a: Allocator, stamp_ms: i64, now_ms: i64) ![]const u8 {
    const stamp: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(stamp_ms, 1000))) };
    const now: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(now_ms, 1000))) };
    const stamp_day = stamp.getEpochDay();
    const y = stamp_day.calculateYearDay();
    const mdays = y.calculateMonthDay();
    const clock = stamp.getDaySeconds();
    const time = try std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ clock.getHoursIntoDay(), clock.getMinutesIntoHour() });
    if (stamp_day.day == now.getEpochDay().day) return time;
    if (y.year == now.getEpochDay().calculateYearDay().year)
        return std.fmt.allocPrint(a, "{d}/{d} {s}", .{ mdays.month.numeric(), mdays.day_index + 1, time });
    return std.fmt.allocPrint(a, "{d:0>2}/{d}/{d} {s}", .{ y.year % 100, mdays.month.numeric(), mdays.day_index + 1, time });
}

fn prefix(self: *const Self, a: Allocator, row: Row) ![]const u8 {
    var columns = try a.alloc([]const u8, row.indent);
    @memset(columns, "   ");
    if (row.connector and row.indent != 0) {
        const folded = self.states[row.index].folded;
        const can_fold = self.foldable(row.index);
        columns[row.indent - 1] = if (row.last)
            (if (folded) "└⊞ " else if (can_fold) "└⊟ " else "└─ ")
        else
            (if (folded) "├⊞ " else if (can_fold) "├⊟ " else "├─ ");
    }
    var gutter = row.gutter;
    while (gutter) |index| {
        const ancestor = self.rows.items[index];
        columns[ancestor.indent - 1] = if (ancestor.last) "   " else "│  ";
        gutter = ancestor.gutter;
    }
    return std.mem.join(a, "", columns);
}

fn body(self: *const Self, a: Allocator, row: Row, home: []const u8, palette: *const Theme.Palette, now_ms: i64) ![7]Span {
    const state = self.states[row.index];
    const entry = self.entries[row.index];
    const text = try oneLine(a, if (entry.kind == .title) entry.text else excerpt(entry.text, 200));
    const diagnostic = if (text.len == 0 and !interrupted(entry)) try oneLine(a, excerpt(entry.diagnostic, 80)) else "";
    const content: [2]Span = switch (entry.kind) {
        .system => .{ .{ .text = "[system]", .style = palette.style(.dim) }, .{ .text = "" } },
        .user => .{ .{ .text = "user: ", .style = palette.style(.accent) }, .{ .text = text } },
        .assistant => .{ .{ .text = "assistant: ", .style = palette.style(.success) }, .{
            .text = if (text.len != 0) text else if (interrupted(entry)) "(aborted)" else if (diagnostic.len != 0) diagnostic else "(no content)",
            .style = if (text.len != 0) null else if (diagnostic.len != 0) palette.style(.@"error") else palette.style(.muted),
        } },
        .tool => .{ .{ .text = try formatTool(a, entry, home), .style = palette.style(.muted) }, .{ .text = "" } },
        .bash => .{ .{ .text = "[bash]: ", .style = palette.style(.dim) }, .{ .text = text, .style = palette.style(.dim) } },
        .compaction => .{ .{ .text = try std.fmt.allocPrint(a, "[compaction: {d}k tokens]", .{(entry.tokens +| 500) / 1000}), .style = palette.style(.accent) }, .{ .text = "" } },
        .branch_summary => .{ .{ .text = "[branch summary]: ", .style = palette.style(.warning) }, .{ .text = text } },
        .model => .{ .{ .text = try std.fmt.allocPrint(a, "[model: {s}]", .{text}), .style = palette.style(.dim) }, .{ .text = "" } },
        .thinking => .{ .{ .text = try std.fmt.allocPrint(a, "[thinking: {s}]", .{text}), .style = palette.style(.dim) }, .{ .text = "" } },
        .title => .{ .{ .text = try std.fmt.allocPrint(a, "[title: {s}]", .{text}), .style = palette.style(.dim) }, .{ .text = "" } },
        .label => .{ .{ .text = try std.fmt.allocPrint(a, "[label: {s}]", .{if (text.len == 0) "(cleared)" else text}), .style = palette.style(.dim) }, .{ .text = "" } },
        .context => .{ .{ .text = "[context edit]", .style = palette.style(.dim) }, .{ .text = "" } },
        .codemode_store => .{ .{ .text = "[custom: codemode-store]", .style = palette.style(.dim) }, .{ .text = "" } },
        .custom => .{ .{ .text = try std.fmt.allocPrint(a, "[{s}]: ", .{try oneLine(a, entry.name)}), .style = palette.style(.accent) }, .{ .text = text } },
        .internal => unreachable,
    };
    return .{
        .{ .text = try self.prefix(a, row), .style = palette.style(.dim) },
        .{ .text = if (state.folded and !row.connector) "⊞ " else "", .style = palette.style(.accent) },
        .{ .text = if (state.on_path) "• " else "", .style = palette.style(.accent) },
        .{ .text = if (entry.label.len > 0) try std.fmt.allocPrint(a, "[{s}] ", .{try oneLine(a, entry.label)}) else "", .style = palette.style(.warning) },
        .{
            .text = if (self.timestamps and entry.label.len > 0)
                try std.fmt.allocPrint(a, "{s} ", .{try dateTime(a, entry.label_time, now_ms)})
            else
                "",
            .style = palette.style(.muted),
        },
        content[0],
        content[1],
    };
}

fn renderList(self: *const Self, a: Allocator, nodes: *std.ArrayList(tui.Node), width: u16, palette: *const Theme.Palette, home: []const u8, now_ms: i64, filter_suffix: []const u8) !void {
    const rows = self.rows.items;
    const first = @min(self.selected -| (self.page_size / 2), rows.len -| self.page_size);
    const page = rows[first..@min(rows.len, first + self.page_size)];
    const bodies = try a.alloc([7]Span, page.len);
    var widest: usize = 0;
    var anchor: usize = 0;
    for (page, bodies, first..) |row, *spans, i| {
        spans.* = try self.body(a, row, home, palette, now_ms);
        var size: usize = 0;
        for (spans, 0..) |span, part| {
            if (part == 3 and i == self.selected) anchor = size;
            size += measure(span.text);
        }
        widest = @max(widest, size);
    }
    const viewport: usize = width -| 2;
    const min_content = std.math.clamp(viewport / 3, 4, 20);
    const context = std.math.clamp(viewport / 4, 2, 12);
    const offset = if (anchor > viewport -| min_content) @min(widest -| viewport, anchor -| context) else 0;
    for (bodies, first..) |spans, i| {
        const selected = i == self.selected;
        const style = if (selected) palette.color(.selectedBg) else null;
        const gutter = try drawSpans(a, &.{.{ .text = if (selected) "› " else "  ", .style = palette.style(.accent) }}, 2, 0, style, false);
        const row = try drawSpans(a, &spans, viewport, offset, style, selected);
        try nodes.append(a, line(try std.mem.concat(a, u8, &.{ gutter.text.bytes, row.text.bytes }), null, false));
    }
    if (rows.len == 0) try nodes.append(a, line("  No entries found", palette.style(.muted), false));
    try nodes.append(a, line(try std.fmt.allocPrint(a, "  ({d}/{d}){s}{s}", .{
        if (rows.len == 0) 0 else self.selected + 1, rows.len, filter_suffix, if (self.timestamps) " [+label time]" else "",
    }), palette.style(.muted), false));
}

pub fn draw(self: *Self, a: Allocator, nodes: *std.ArrayList(tui.Node), width: u16, height: u16, palette: *const Theme.Palette, home: []const u8, now_ms: i64, hardware: bool, frames: *const Presentation.TreeFrames) !void {
    self.page_size = @max(5, height / 2);
    if (self.stage == .confirm) {
        try Frame.append(a, nodes, frames.confirm.before, width, palette);
        inline for (summary_choices, 0..) |choice, i| {
            const selected = i == self.choice;
            const choice_label = @field(frames.summary_choices, @tagName(choice));
            try nodes.append(a, line(try std.mem.concat(a, u8, &.{ if (selected) " → " else "   ", choice_label }), if (selected) palette.style(.accent) else null, false));
        }
        try Frame.append(a, nodes, frames.confirm.after, width, palette);
        return;
    }
    if (self.stage == .custom_prompt) {
        try Frame.append(a, nodes, frames.custom_prompt.before, width, palette);
        try nodes.append(a, (try ComposerView.render(a, &self.input, width, 0, @max(5, @as(u32, height) * 3 / 10), palette.effort(null), null, hardware)).node);
        try Frame.append(a, nodes, frames.custom_prompt.after, width, palette);
        return;
    }
    try Frame.append(a, nodes, frames.list.before, width, palette);
    try renderHelp(a, nodes, width, palette, frames.help);
    var search: [3]Span = .{
        .{ .text = frames.search_prompt, .style = palette.style(.muted) },
        .{ .text = self.query.items, .style = palette.style(.accent) },
        .{ .text = " ", .inverse = true },
    };
    if (self.stage == .label or hardware) search[2].text = "";
    const prefix_width = measure(search[0].text);
    if (prefix_width + measure(search[1].text) + 1 > width) {
        search[1].text = try std.fmt.allocPrint(a, "{s}…", .{tui.layout.clipColumns(search[1].text, @intCast(width -| (prefix_width + 2)))});
    }
    var search_line = try drawSpans(a, &search, width, 0, null, false);
    if (self.stage != .label) search_line.text.cursor_column = std.math.cast(u16, prefix_width + measure(search[1].text));
    try nodes.append(a, search_line);
    try nodes.appendSlice(a, &.{ line(try md.horizontalRule(a, width), palette.style(.border), false), .{ .spacer = 1 } });
    if (self.stage == .label) {
        const cursor = self.input.cursor;
        const text = self.input.text();
        const end = self.input.following(cursor);
        try Frame.append(a, nodes, frames.label.before, width, palette);
        try nodes.append(a, try tui.layout.inputLine(a, "  ", text[0..cursor], text[cursor..end], text[end..], hardware));
        try Frame.append(a, nodes, frames.label.after, width, palette);
    } else {
        const suffix = switch (self.filter) {
            inline else => |filter| @field(frames.filter_suffix, @tagName(filter)),
        };
        try self.renderList(a, nodes, width, palette, home, now_ms, suffix);
    }
    try Frame.append(a, nodes, frames.list.after, width, palette);
}
