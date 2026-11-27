const std = @import("std");
const kit = @import("kit");
const Session = @import("../../session.zig").SessionIndex.Session;
const trim = @import("../../session.zig").SessionName.trimWhitespace;
const Allocator = std.mem.Allocator;
const fzf = @import("fzf.zig");
const Query = @This();

const Token = struct { phrase: bool, text: []const u8, points: []const u21 };

tokens: []const Token = &.{},

pub fn init(a: Allocator, raw: []const u8) !Query {
    const query = trim(raw);
    const quoted = std.mem.count(u8, query, "\"") % 2 == 0;
    var tokens: std.ArrayList(Token) = .empty;
    var phrase = false;
    var start: usize = 0;
    var index: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(query[index..])) |scalar| {
        const quote = quoted and scalar.codepoint == '"';
        if (quote or (!phrase and kit.unicode.isEcmaWhitespace(scalar.codepoint))) {
            try add(a, &tokens, query[start..index], phrase);
            start = index + scalar.len;
            if (quote) phrase = !phrase;
        }
        index += scalar.len;
    }
    try add(a, &tokens, query[start..], phrase);
    return .{ .tokens = tokens.items };
}

fn add(a: Allocator, tokens: *std.ArrayList(Token), raw: []const u8, phrase: bool) !void {
    const text = trim(raw);
    if (text.len == 0) return;
    const folded = try fold(a, text, phrase);
    var points: std.ArrayList(u21) = .empty;
    var remaining = folded;
    while (kit.unicode.decodeUtf8Lossy(remaining)) |scalar| {
        remaining = remaining[scalar.len..];
        try points.append(a, scalar.codepoint);
    }
    try tokens.append(a, .{ .text = folded, .phrase = phrase, .points = points.items });
}

fn fold(a: Allocator, text: []const u8, phrase: bool) ![]const u8 {
    var lowered: std.ArrayList(u8) = try .initCapacity(a, text.len);
    var pending_space = false;
    var rest = text;
    while (kit.unicode.decodeUtf8Lossy(rest)) |scalar| {
        rest = rest[scalar.len..];
        if (phrase and kit.unicode.isEcmaWhitespace(scalar.codepoint)) {
            pending_space = lowered.items.len != 0;
            continue;
        }
        if (pending_space) {
            try lowered.append(a, ' ');
            pending_space = false;
        }
        var bytes: [4]u8 = undefined;
        const count = try std.unicode.utf8Encode(kit.unicode.foldCaseSimple(scalar.codepoint), &bytes);
        try lowered.appendSlice(a, bytes[0..count]);
    }
    return lowered.items;
}

pub fn score(self: Query, a: Allocator, session: *const Session) !?i64 {
    const fields = [_][]const u8{ session.name, session.id, session.messages, session.workspace };
    var candidates: [fields.len]?[]const fzf.Unit = @splat(null);
    var phrases: [fields.len]?[]const u8 = @splat(null);
    var total: i64 = 0;
    for (self.tokens) |token| {
        var best: ?i64 = null;
        for (fields, &candidates, &phrases, 0..) |field, *units, *phrase, index| {
            const score_value = if (token.phrase) exact: {
                const text = phrase.* orelse cached: {
                    const folded = try fold(a, field, true);
                    phrase.* = folded;
                    break :cached folded;
                };
                const offset = std.mem.indexOf(u8, text, token.text) orelse continue;
                break :exact -@as(i64, @intCast(offset));
            } else fuzzy: {
                const text = units.* orelse cached: {
                    const decoded = try fzf.candidate(a, field);
                    units.* = decoded;
                    break :cached decoded;
                };
                const rank = try fzf.score(a, token.points, text) orelse continue;
                break :fuzzy rank;
            };
            // Prefer a title match to a match in the message excerpt, ID, or workspace.
            const rank = score_value + if (index == 0) @as(i64, 1_000_000) else 0;
            best = @max(best orelse rank, rank);
        }
        total -|= best orelse return null;
    }
    return total;
}
