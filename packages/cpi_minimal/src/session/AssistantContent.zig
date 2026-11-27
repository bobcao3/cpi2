const std = @import("std");
const j = @import("../json.zig");
const Allocator = std.mem.Allocator;
const Self = @This();

pub const Kind = enum { prose, reasoning };
const Run = struct { kind: Kind, end: usize };

bytes: []const u8 = "",
runs: []const Run = &.{},

pub const Iterator = struct {
    content: Self,
    index: usize = 0,
    start: usize = 0,

    pub fn next(self: *Iterator) ?struct { kind: Kind, text: []const u8 } {
        if (self.index == self.content.runs.len) return null;
        const run = self.content.runs[self.index];
        const text = self.content.bytes[self.start..run.end];
        self.index += 1;
        self.start = run.end;
        return .{ .kind = run.kind, .text = text };
    }
};

pub fn iterator(self: Self) Iterator {
    return .{ .content = self };
}

pub fn copy(self: Self, a: Allocator) !Self {
    const bytes = try a.dupe(u8, self.bytes);
    errdefer a.free(bytes);
    return .{ .bytes = bytes, .runs = try a.dupe(Run, self.runs) };
}

pub fn hasReasoning(self: Self) bool {
    var blocks = self.iterator();
    while (blocks.next()) |block| {
        if (block.kind == .reasoning and trim(block.text).len != 0) return true;
    }
    return false;
}

pub fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

pub const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,

    pub fn append(self: *Builder, a: Allocator, kind: Kind, text: []const u8) !void {
        if (text.len == 0) return;
        const last = self.runs.items.len;
        const join = last != 0 and self.runs.items[last - 1].kind == kind;
        if (!join) try self.runs.ensureUnusedCapacity(a, 1);
        try self.bytes.appendSlice(a, text);
        if (join) self.runs.items[last - 1].end = self.bytes.items.len else self.runs.appendAssumeCapacity(.{ .kind = kind, .end = self.bytes.items.len });
    }

    fn appendReasoning(self: *Builder, a: Allocator, raw: []const u8) !void {
        const text = trim(raw);
        if (text.len == 0) return;
        if (self.runs.getLastOrNull()) |run| {
            if (run.kind == .reasoning) try self.append(a, .reasoning, "\n\n");
        }
        try self.append(a, .reasoning, text);
    }

    pub fn view(self: *const Builder) Self {
        return .{ .bytes = self.bytes.items, .runs = self.runs.items };
    }

    pub fn clear(self: *Builder) void {
        self.bytes.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
    }

    pub fn deinit(self: *Builder, a: Allocator) void {
        self.bytes.clearAndFree(a);
        self.runs.clearAndFree(a);
    }
};

pub fn fromLegacy(a: Allocator, prose: []const u8, reasoning: []const u8) !Self {
    var out: Builder = .{};
    errdefer out.deinit(a);
    try out.appendReasoning(a, reasoning);
    try out.append(a, .prose, prose);
    return out.view();
}

pub fn fromJournal(a: Allocator, entry: j.Value) !Self {
    var out: Builder = .{};
    errdefer out.deinit(a);
    for (j.items(j.get(entry, "output"))) |item| {
        const kind = j.get(item, "type");
        const content = j.get(item, "content");
        if (j.equal(kind, "message")) {
            if (content == .string) try out.append(a, .prose, content.string) else for (j.items(content)) |part| try out.append(a, .prose, j.text(j.get(part, "text")));
        } else if (j.equal(kind, "reasoning")) {
            const before = out.bytes.items.len;
            for (j.items(j.get(item, "summary"))) |part| {
                if (j.equal(j.get(part, "type"), "summary_text")) try out.appendReasoning(a, j.text(j.get(part, "text")));
            }
            if (out.bytes.items.len == before) for (j.items(content)) |part| {
                if (j.equal(j.get(part, "type"), "reasoning_text")) try out.appendReasoning(a, j.text(j.get(part, "text")));
            };
        }
    }
    const legacy = j.text(j.get(entry, "thinking"));
    if (trim(legacy).len != 0 and !out.view().hasReasoning()) {
        const reply = try fromLegacy(a, out.bytes.items, legacy);
        out.deinit(a);
        return reply;
    }
    return out.view();
}

// Some providers stream a summary but omit it from the completed response.
pub fn withPreviewReasoning(self: Self, a: Allocator, preview: Self) !Self {
    if (self.hasReasoning() or !preview.hasReasoning()) return self;
    var out: Builder = .{};
    errdefer out.deinit(a);
    var remaining = self.bytes;
    var blocks = preview.iterator();
    while (blocks.next()) |block| {
        if (block.kind == .prose) remaining = if (std.mem.startsWith(u8, remaining, block.text)) remaining[block.text.len..] else break;
    } else if (remaining.len == 0) return preview.copy(a);
    blocks = preview.iterator();
    while (blocks.next()) |block| {
        if (block.kind == .reasoning) try out.appendReasoning(a, block.text);
    }
    blocks = self.iterator();
    while (blocks.next()) |block| try out.append(a, block.kind, block.text);
    return out.view();
}
