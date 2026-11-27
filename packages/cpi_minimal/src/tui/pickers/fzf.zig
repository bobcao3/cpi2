//! fzf's default dynamic-programming scorer, adapted for Unicode session fields.
const std = @import("std");
const unicode = @import("kit").unicode;

const Class = enum { space, punctuation, delimiter, lower, upper, letter, number };
pub const Unit = struct { point: u21, bonus: i32 };
const Cell = struct { score: i32 = 0, run: ?i32 = null };

fn classify(point: u21) Class {
    if (unicode.isEcmaWhitespace(point)) return .space;
    switch (point) {
        '/', ':', ';', ',' => return .delimiter,
        'a'...'z' => return .lower,
        'A'...'Z' => return .upper,
        '0'...'9' => return .number,
        0...8, 14...31, 33...43, 45...46, 60...64, 91...96, 123...127 => return .punctuation,
        else => {},
    }
    return switch (unicode.generalCategory(point)) {
        .letter_lowercase => .lower,
        .letter_uppercase => .upper,
        .letter_titlecase, .letter_modifier, .letter_other => .letter,
        .number_decimal_digit, .number_letter, .number_other => .number,
        else => .punctuation,
    };
}

fn bonus(previous: Class, current: Class) i32 {
    if (@backingInt(current) >= @backingInt(Class.delimiter)) switch (previous) {
        .space => return 10,
        .delimiter => return 9,
        .punctuation => return 8,
        else => {},
    };
    if ((previous == .lower and current == .upper) or (previous != .number and current == .number)) return 7;
    return switch (current) {
        .space => 10,
        .punctuation, .delimiter => 8,
        else => 0,
    };
}

pub fn candidate(a: std.mem.Allocator, value: []const u8) ![]Unit {
    var units: std.ArrayList(Unit) = .empty;
    var previous: Class = .space;
    var remaining = value;
    while (unicode.decodeUtf8Lossy(remaining)) |scalar| {
        remaining = remaining[scalar.len..];
        const class = classify(scalar.codepoint);
        try units.append(a, .{ .point = unicode.foldCaseSimple(scalar.codepoint), .bonus = bonus(previous, class) });
        previous = class;
    }
    return units.items;
}

pub fn score(a: std.mem.Allocator, query: []const u21, text: []const Unit) !?i32 {
    if (query.len == 0) return 0;
    var matched: usize = 0;
    var end: usize = 0;
    for (text, 0..) |unit, index| {
        if (unit.point != query[matched]) continue;
        matched += 1;
        if (matched == query.len) {
            end = index + 1;
            break;
        }
    }
    if (matched != query.len) return null;
    if (query.len == 1) {
        var best: i32 = 0;
        for (text) |unit| if (unit.point == query[0]) {
            best = @max(best, 16 + 2 * unit.bonus);
        };
        return best;
    }
    if (text.len > 1_000_000 / query.len) return greedy(query, text[0..end]);

    var rows = try a.alloc(Cell, text.len * 2);
    defer a.free(rows);
    var previous = rows[0..text.len];
    var current = rows[text.len..];
    var left: i32 = 0;
    var gap = false;
    for (text, previous) |unit, *cell| {
        const matches = unit.point == query[0];
        left = if (matches) 16 + 2 * unit.bonus else @max(0, left - if (gap) @as(i32, 1) else 3);
        cell.* = .{ .score = left, .run = if (matches) unit.bonus else null };
        gap = !matches;
    }

    var first: usize = 0;
    while (text[first].point != query[0]) : (first += 1) {}
    var best: i32 = 0;
    for (query[1..]) |point| {
        first += 1;
        while (text[first].point != point) : (first += 1) {}
        left = 0;
        gap = false;
        best = 0;
        for (text[first..], current[first..], previous[first - 1 .. text.len - 1]) |unit, *cell, diagonal| {
            const skipped = left - if (gap) @as(i32, 1) else 3;
            var gained: i32 = 0;
            var run: ?i32 = null;
            if (unit.point == point) {
                const origin = diagonal.run orelse unit.bonus;
                const continues = diagonal.run != null and !(unit.bonus >= 8 and unit.bonus > origin);
                gained = diagonal.score + 16 + if (continues) @max(unit.bonus, 4, origin) else unit.bonus;
                run = if (continues) origin else unit.bonus;
                if (gained < skipped) {
                    gained = diagonal.score + 16 + unit.bonus;
                    run = null;
                }
            }
            gap = gained < skipped;
            left = @max(0, gained, skipped);
            cell.* = .{ .score = left, .run = run };
            best = @max(best, left);
        }
        std.mem.swap([]Cell, &previous, &current);
    }
    return best;
}

// Bound work for long pasted queries with fzf's forward/backward alignment.
fn greedy(query: []const u21, text: []const Unit) i32 {
    var start = text.len;
    var index = query.len;
    while (index != 0) {
        start -= 1;
        if (text[start].point == query[index - 1]) index -= 1;
    }
    var total: i32 = 0;
    var run: ?i32 = null;
    var gap = false;
    for (text[start..]) |unit| {
        if (unit.point == query[index]) {
            const origin = run orelse unit.bonus;
            const continues = run != null and !(unit.bonus >= 8 and unit.bonus > origin);
            total +|= 16 + if (index == 0) 2 * unit.bonus else if (continues) @max(unit.bonus, 4, origin) else unit.bonus;
            run = if (continues) origin else unit.bonus;
            index += 1;
            gap = false;
            if (index == query.len) break;
        } else {
            total -|= if (gap) 1 else 3;
            gap = true;
            run = null;
        }
    }
    return @max(0, total);
}
