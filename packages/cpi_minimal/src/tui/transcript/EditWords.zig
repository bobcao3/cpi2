const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { keep, remove, add };
pub const Change = struct { kind: Kind, text: []const u8 };

const Token = struct { start: usize, end: usize, word: []const u8 };
const Run = struct { kind: Kind, count: usize, previous: ?usize };
const Path = struct { old: isize = 0, tail: ?usize = null };

fn codepoint(text: []const u8, at: usize) struct { value: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .value = text[at], .len = 1 };
    if (len > text.len - at) return .{ .value = text[at], .len = 1 };
    const cp = std.unicode.utf8Decode(text[at..][0..len]) catch return .{ .value = text[at], .len = 1 };
    return .{ .value = cp, .len = len };
}

fn whitespace(cp: u21) bool {
    // ECMAScript whitespace, including the line terminators and BOM.
    return switch (cp) {
        9...13, ' ', 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn word(cp: u21) bool {
    // Pi uses jsdiff 8.0.4 without an Intl.Segmenter. Non-Latin code points
    // are individual tokens, as are most punctuation and symbols.
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', 0xad, 0xc0...0xd6, 0xd8...0xf6, 0xf8...0x2c6, 0x2c8...0x2d7, 0x2de...0x2ff, 0x1e00...0x1eff => true,
        else => false,
    };
}

pub fn leadingWhitespace(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len) {
        const cp = codepoint(text, i);
        if (!whitespace(cp.value)) break;
        i += cp.len;
    }
    return text[0..i];
}

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn trailingWhitespace(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        var at = end - 1;
        while (at > 0 and continuation(text[at])) at -= 1;
        if (!whitespace(codepoint(text, at).value)) break;
        end = at;
    }
    return text[end..];
}

fn tokenize(a: Allocator, text: []const u8) ![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var start: usize = 0;
    var at = leadingWhitespace(text).len;
    if (at > 0 and at == text.len) try tokens.append(a, .{ .start = 0, .end = at, .word = "" });
    while (at < text.len) {
        const word_start = at;
        const first = codepoint(text, at);
        at += first.len;
        if (word(first.value)) while (at < text.len) {
            const cp = codepoint(text, at);
            if (!word(cp.value)) break;
            at += cp.len;
        };
        const word_end = at;
        at += leadingWhitespace(text[at..]).len;
        try tokens.append(a, .{ .start = start, .end = at, .word = text[word_start..word_end] });
        start = word_end;
    }
    return tokens.items;
}

fn push(a: Allocator, runs: *std.ArrayList(Run), path: *Path, kind: Kind, count: usize) !void {
    if (count == 0) return;
    var next: Run = .{ .kind = kind, .count = count, .previous = path.tail };
    if (path.tail) |tail| {
        const prior = runs.items[tail];
        if (prior.kind == kind) {
            next.count += prior.count;
            next.previous = prior.previous;
        }
    }
    path.tail = runs.items.len;
    try runs.append(a, next);
}

fn keepCommon(a: Allocator, runs: *std.ArrayList(Run), path: *Path, old: []const Token, new: []const Token, diagonal: isize, budget: *usize) !?isize {
    var x: usize = @intCast(path.old);
    var y: usize = @intCast(path.old - diagonal);
    const start = x;
    while (x < old.len and y < new.len) {
        if (budget.* == 0) return null;
        budget.* -= 1;
        if (!std.mem.eql(u8, old[x].word, new[y].word)) break;
        x += 1;
        y += 1;
    }
    try push(a, runs, path, .keep, x - start);
    path.old = @intCast(x);
    return @intCast(y);
}

// Myers shortest edit path. Use the same preference for removal on a tied
// frontier as Pi, so repeated tokens select the same unchanged runs.
fn editPath(a: Allocator, runs: *std.ArrayList(Run), old: []const Token, new: []const Token, budget: *usize) !?Path {
    const old_len: isize = @intCast(old.len);
    const new_len: isize = @intCast(new.len);
    const frontier = try a.alloc(?Path, old.len + new.len + 3);
    @memset(frontier, null);
    var initial: Path = .{};
    const first_y = (try keepCommon(a, runs, &initial, old, new, 0, budget)) orelse return null;
    if (initial.old == old_len and first_y == new_len) return initial;
    const center = new_len + 1;
    frontier[@intCast(center)] = initial;
    var low = -new_len;
    var high = old_len;
    var distance: isize = 1;
    while (distance <= old_len + new_len) : (distance += 1) {
        var diagonal = @max(-distance, low);
        if (@mod(distance - diagonal, 2) != 0) diagonal += 1;
        while (diagonal <= @min(distance, high)) : (diagonal += 2) {
            if (budget.* == 0) return null;
            budget.* -= 1;
            const at: usize = @intCast(center + diagonal);
            const remove = frontier[at - 1];
            const add = frontier[at + 1];
            frontier[at - 1] = null;
            const can_remove = if (remove) |p| p.old < old_len else false;
            const can_add = if (add) |p| p.old - diagonal > 0 and p.old - diagonal <= new_len else false;
            if (!can_remove and !can_add) {
                frontier[at] = null;
                continue;
            }
            var path: Path = undefined;
            if (!can_remove or (can_add and remove.?.old < add.?.old)) {
                path = add.?;
                try push(a, runs, &path, .add, 1);
            } else {
                path = remove.?;
                path.old += 1;
                try push(a, runs, &path, .remove, 1);
            }
            const y = (try keepCommon(a, runs, &path, old, new, diagonal, budget)) orelse return null;
            if (path.old == old_len and y == new_len) return path;
            frontier[at] = path;
            if (path.old == old_len) high = @min(high, diagonal - 1);
            if (y == new_len) low = @max(low, diagonal + 1);
        }
    }
    return null;
}

fn commonPrefix(left: []const u8, right: []const u8) usize {
    var n: usize = 0;
    while (n < @min(left.len, right.len) and left[n] == right[n]) n += 1;
    while (n > 0 and n < left.len and continuation(left[n])) n -= 1;
    return n;
}

fn commonSuffix(left: []const u8, right: []const u8) usize {
    var n: usize = 0;
    while (n < @min(left.len, right.len) and left[left.len - 1 - n] == right[right.len - 1 - n]) n += 1;
    while (n > 0 and continuation(left[left.len - n])) n -= 1;
    return n;
}

fn overlap(a: Allocator, left: []const u8, right: []const u8) !usize {
    const width = @min(left.len, right.len);
    if (width == 0) return 0;
    const prefix = try a.alloc(usize, width);
    prefix[0] = 0;
    var length: usize = 0;
    for (right[1..width], 1..) |b, i| {
        while (length > 0 and b != right[length]) length = prefix[length - 1];
        if (b == right[length]) length += 1;
        prefix[i] = length;
    }
    length = 0;
    for (left[left.len - width ..]) |b| {
        while (length > 0 and b != right[length]) length = prefix[length - 1];
        if (b == right[length]) length += 1;
    }
    while (length > 0 and length < right.len and continuation(right[length])) length = prefix[length - 1];
    return length;
}

// Adjacent tokens share their intervening whitespace. Reconcile it between
// runs to recover the display text selected by Pi's word diff.
fn reconcile(a: Allocator, left: ?*Change, removed: ?*Change, added: ?*Change, right: ?*Change) !void {
    if (added) |insert| {
        if (removed) |delete| {
            if (left) |keep| {
                const whitespace_in_new = leadingWhitespace(insert.text);
                const common = commonPrefix(leadingWhitespace(delete.text), whitespace_in_new);
                keep.text = keep.text[0 .. keep.text.len - (whitespace_in_new.len - common)];
                delete.text = delete.text[common..];
                insert.text = insert.text[common..];
            }
            if (right) |keep| {
                const whitespace_in_new = trailingWhitespace(insert.text);
                const common = commonSuffix(trailingWhitespace(delete.text), whitespace_in_new);
                keep.text = keep.text[whitespace_in_new.len - common ..];
                delete.text = delete.text[0 .. delete.text.len - common];
                insert.text = insert.text[0 .. insert.text.len - common];
            }
        } else {
            if (left != null) insert.text = insert.text[leadingWhitespace(insert.text).len..];
            if (right) |keep| keep.text = keep.text[leadingWhitespace(keep.text).len..];
        }
    } else if (removed) |delete| {
        if (left) |before| {
            if (right) |after| {
                const between = leadingWhitespace(after.text);
                const lead = commonPrefix(leadingWhitespace(delete.text), between);
                const tail = commonSuffix(trailingWhitespace(delete.text[lead..]), between[lead..]);
                before.text = before.text[0 .. before.text.len - tail];
                delete.text = delete.text[lead .. delete.text.len - tail];
                after.text = after.text[between.len - tail ..];
            } else {
                const lead = try overlap(a, trailingWhitespace(before.text), leadingWhitespace(delete.text));
                delete.text = delete.text[lead..];
            }
        } else if (right) |keep| {
            const tail = try overlap(a, trailingWhitespace(delete.text), leadingWhitespace(keep.text));
            delete.text = delete.text[0 .. delete.text.len - tail];
        }
    }
}

pub fn diff(a: Allocator, old_text: []const u8, new_text: []const u8, budget: *usize) !?[]Change {
    const old = try tokenize(a, old_text);
    const new = try tokenize(a, new_text);
    var runs: std.ArrayList(Run) = .empty;
    const path = (try editPath(a, &runs, old, new, budget)) orelse return null;
    var count: usize = 0;
    var link = path.tail;
    while (link) |i| : (link = runs.items[i].previous) count += 1;
    const changes = try a.alloc(Change, count);
    // Build each run from a slice of its source. Kept runs use the new text.
    link = path.tail;
    var old_end = old.len;
    var new_end = new.len;
    var i = count;
    while (link) |at| : (link = runs.items[at].previous) {
        const run = runs.items[at];
        i -= 1;
        const text: []const u8 = if (run.kind == .remove)
            old_text[old[old_end - run.count].start..old[old_end - 1].end]
        else
            new_text[new[new_end - run.count].start..new[new_end - 1].end];
        changes[i] = .{ .kind = run.kind, .text = text };
        if (run.kind != .remove) new_end -= run.count;
        if (run.kind != .add) old_end -= run.count;
    }
    var left: ?*Change = null;
    var removed: ?*Change = null;
    var added: ?*Change = null;
    for (changes) |*change| switch (change.kind) {
        .remove => removed = change,
        .add => added = change,
        .keep => {
            try reconcile(a, left, removed, added, change);
            left = change;
            removed = null;
            added = null;
        },
    };
    try reconcile(a, left, removed, added, null);
    return changes;
}
