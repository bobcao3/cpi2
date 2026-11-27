const std = @import("std");
const uppercase_scalar = @import("kit").unicode.uppercaseScalar;

/// Matches one gitignore rule body against a relative path or a basename.
/// The caller removes the negation marker, the leading and trailing slash
/// anchors, and the trailing directory marker, and passes the basename when
/// the original rule contained no slash.
pub fn matches(a: std.mem.Allocator, pattern: []const u8, text: []const u8, has_slash: bool) bool {
    const units = encode(a, pattern) catch return false;
    defer a.free(units);
    const subject = encode(a, text) catch return false;
    defer a.free(subject);

    var write: usize = 0;
    var read: usize = 0;
    while (read < units.len) {
        if (units[read] == '\\' and read + 1 < units.len and units[read + 1] == '/') {
            units[write] = '/';
            read += 2;
        } else {
            units[write] = units[read];
            read += 1;
        }
        write += 1;
    }

    var start: usize = 0;
    var end = write;
    if (start < end and units[start] == 0xfeff) start += 1;
    while (end > start and (units[end - 1] == '\r' or units[end - 1] == '\n')) end -= 1;
    if (start == end) return false;
    if (invalidTrailingBackslash(units[start..end])) return false;
    return matchFrom(units[start..end], 0, subject, 0, has_slash);
}

fn encode(a: std.mem.Allocator, bytes: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        if (len == 0 or i + len > bytes.len) {
            try out.append(a, 0xfffd);
            i += 1;
            continue;
        }
        const codepoint = std.unicode.wtf8Decode(bytes[i..][0..len]) catch {
            try out.append(a, 0xfffd);
            i += 1;
            continue;
        };
        if (codepoint <= 0xffff) {
            try out.append(a, @intCast(codepoint));
        } else {
            const v = codepoint - 0x10000;
            try out.append(a, @intCast(0xd800 + (v >> 10)));
            try out.append(a, @intCast(0xdc00 + (v & 0x3ff)));
        }
        i += len;
    }
    return out.toOwnedSlice(a);
}

fn invalidTrailingBackslash(pattern: []const u16) bool {
    const n = pattern.len;
    if (n == 0 or pattern[n - 1] != '\\') return false;
    return n == 1 or pattern[n - 2] != '\\';
}

fn canonical(unit: u16) u16 {
    if (unit >= 0xd800 and unit <= 0xdfff) return unit;
    const mapped = uppercase_scalar(@intCast(unit)) orelse return unit;
    if (mapped == @as(u21, unit) or mapped > 0xffff) return unit;
    const upper: u16 = @intCast(mapped);
    if (upper < 0x80 and unit >= 0x80) return unit;
    return upper;
}

fn literalMatches(member: u16, unit: u16) bool {
    return canonical(member) == canonical(unit);
}

fn rangeMatches(low: u16, high: u16, unit: u16) bool {
    if (unit == '/') return false;
    const target = canonical(unit);
    if (unit >= low and unit <= high) return true;
    if (target >= low and target <= high) return true;
    var member: u32 = low;
    while (member <= high) : (member += 1) {
        if (canonical(@intCast(member)) == target) return true;
    }
    return false;
}

const Range = struct { low: u16, high: u16 };
const PosixClass = struct {
    name: []const u8,
    ranges: []const Range = &.{},
    singles: []const u16 = &.{},
};

const alnum_ranges = [_]Range{ .{ .low = '0', .high = '9' }, .{ .low = 'A', .high = 'Z' }, .{ .low = 'a', .high = 'z' } };
const alpha_ranges = [_]Range{ .{ .low = 'A', .high = 'Z' }, .{ .low = 'a', .high = 'z' } };
const blank_singles = [_]u16{ ' ', '\t' };
const cntrl_ranges = [_]Range{ .{ .low = 0, .high = 0x1f }, .{ .low = 0x7f, .high = 0x7f } };
const digit_ranges = [_]Range{.{ .low = '0', .high = '9' }};
const graph_ranges = [_]Range{ .{ .low = '!', .high = '.' }, .{ .low = '0', .high = '~' } };
const lower_ranges = [_]Range{.{ .low = 'a', .high = 'z' }};
const print_ranges = [_]Range{ .{ .low = ' ', .high = '.' }, .{ .low = '0', .high = '~' } };
const punct_ranges = [_]Range{
    .{ .low = '!', .high = '.' },
    .{ .low = ':', .high = '@' },
    .{ .low = '[', .high = '`' },
    .{ .low = '{', .high = '~' },
};
const space_singles = [_]u16{ ' ', '\t', '\n', '\r' };
const upper_ranges = [_]Range{.{ .low = 'A', .high = 'Z' }};
const xdigit_ranges = [_]Range{ .{ .low = '0', .high = '9' }, .{ .low = 'A', .high = 'F' }, .{ .low = 'a', .high = 'f' } };

const posix_classes = [_]PosixClass{
    .{ .name = "alnum", .ranges = &alnum_ranges },
    .{ .name = "alpha", .ranges = &alpha_ranges },
    .{ .name = "blank", .singles = &blank_singles },
    .{ .name = "cntrl", .ranges = &cntrl_ranges },
    .{ .name = "digit", .ranges = &digit_ranges },
    .{ .name = "graph", .ranges = &graph_ranges },
    .{ .name = "lower", .ranges = &lower_ranges },
    .{ .name = "print", .ranges = &print_ranges },
    .{ .name = "punct", .ranges = &punct_ranges },
    .{ .name = "space", .singles = &space_singles },
    .{ .name = "upper", .ranges = &upper_ranges },
    .{ .name = "xdigit", .ranges = &xdigit_ranges },
};

fn eqlAscii(name: []const u16, text: []const u8) bool {
    if (name.len != text.len) return false;
    for (name, text) |unit, byte| {
        if (unit != byte) return false;
    }
    return true;
}

fn posixMatches(name: []const u16, unit: u16) ?bool {
    for (posix_classes) |class| {
        if (!eqlAscii(name, class.name)) continue;
        for (class.singles) |member| {
            if (literalMatches(member, unit)) return true;
        }
        for (class.ranges) |range| {
            if (rangeMatches(range.low, range.high, unit)) return true;
        }
        return false;
    }
    return null;
}

const ClassMatch = struct { end: usize, matched: bool };

fn scanClass(pattern: []const u16, start: usize, unit: ?u16) ?ClassMatch {
    var index = start + 1;
    var negated = false;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) {
        negated = true;
        index += 1;
    }
    const slash = unit != null and unit.? == '/';
    const subject: ?u16 = if (slash) null else unit;
    var matched = false;
    var prev: ?u16 = null;
    while (true) {
        if (index >= pattern.len) return null;
        const char = pattern[index];
        if (char == '\\') {
            if (index + 1 >= pattern.len) return null;
            const member = pattern[index + 1];
            if (subject) |value| {
                if (literalMatches(member, value)) matched = true;
            }
            prev = member;
            index += 2;
        } else if (char == '-' and prev != null and index + 1 < pattern.len and pattern[index + 1] != ']') {
            index += 1;
            var high = pattern[index];
            if (high == '\\') {
                index += 1;
                if (index >= pattern.len) return null;
                high = pattern[index];
            }
            if (prev.? <= high) {
                if (subject) |value| {
                    if (rangeMatches(prev.?, high, value)) matched = true;
                }
            }
            prev = null;
            index += 1;
        } else if (char == '[' and index + 1 < pattern.len and pattern[index + 1] == ':') {
            const name_start = index + 2;
            var close = name_start;
            while (close < pattern.len and pattern[close] != ']') : (close += 1) {}
            if (close >= pattern.len) return null;
            if (close > name_start and pattern[close - 1] == ':') {
                const name = pattern[name_start .. close - 1];
                if (subject) |value| {
                    if (posixMatches(name, value) orelse return null) matched = true;
                } else {
                    _ = posixMatches(name, 0) orelse return null;
                }
                prev = null;
                index = close + 1;
            } else {
                if (subject) |value| {
                    if (literalMatches('[', value)) matched = true;
                }
                prev = '[';
                index += 1;
            }
        } else {
            if (subject) |value| {
                if (literalMatches(char, value)) matched = true;
            }
            prev = char;
            index += 1;
        }
        if (index < pattern.len and pattern[index] == ']') {
            return .{ .end = index + 1, .matched = if (slash) false else if (negated) !matched else matched };
        }
    }
}

fn atEnd(text: []const u16, index: usize) bool {
    return index == text.len or (index + 1 == text.len and text[index] == '/');
}

fn leadingGlobstar(pattern: []const u16, rest: usize, text: []const u16, index: usize, has_slash: bool) bool {
    if (matchFrom(pattern, rest, text, index, has_slash)) return true;
    var cursor = index;
    while (cursor < text.len) : (cursor += 1) {
        if (text[cursor] == '/' and matchFrom(pattern, rest, text, cursor + 1, has_slash)) return true;
    }
    return false;
}

fn middleGlobstar(pattern: []const u16, slash: usize, text: []const u16, index: usize, has_slash: bool) bool {
    if (matchFrom(pattern, slash, text, index, has_slash)) return true;
    if (index < text.len and text[index] == '/') {
        var cursor = index + 1;
        while (cursor < text.len and text[cursor] != '/') : (cursor += 1) {}
        if (cursor > index + 1) return middleGlobstar(pattern, slash, text, cursor, has_slash);
    }
    return false;
}

fn matchFrom(pattern: []const u16, start: usize, text: []const u16, text_start: usize, has_slash: bool) bool {
    var pi = start;
    var ti = text_start;
    while (pi < pattern.len) {
        const char = pattern[pi];
        if (char == '\\') {
            if (pi + 1 >= pattern.len) {
                const missing_escape_replacement = "undefined";
                for (missing_escape_replacement) |unit| {
                    if (ti >= text.len or !literalMatches(unit, text[ti])) return false;
                    ti += 1;
                }
                pi += 1;
                continue;
            }
            if (ti >= text.len) return false;
            if (!literalMatches(pattern[pi + 1], text[ti])) return false;
            pi += 2;
            ti += 1;
        } else if (char == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            pi += 1;
            ti += 1;
        } else if (char == '*') {
            var run = pi;
            while (run < pattern.len and pattern[run] == '*') : (run += 1) {}
            if (has_slash and run - pi == 2) {
                if (pi == 0 and run < pattern.len and pattern[run] == '/') {
                    var rest = run + 1;
                    while (rest + 2 < pattern.len and pattern[rest] == '*' and pattern[rest + 1] == '*' and pattern[rest + 2] == '/') rest += 3;
                    return leadingGlobstar(pattern, rest, text, ti, has_slash);
                }
            }
            if (matchFrom(pattern, run, text, ti, has_slash)) return true;
            var cursor = ti;
            while (cursor < text.len and text[cursor] != '/') {
                cursor += 1;
                if (matchFrom(pattern, run, text, cursor, has_slash)) return true;
            }
            return false;
        } else if (char == '/' and has_slash and pi + 3 <= pattern.len and
            pi + 2 < pattern.len and pattern[pi + 1] == '*' and pattern[pi + 2] == '*')
        {
            if (pi + 3 == pattern.len) {
                return ti < text.len and text[ti] == '/' and ti + 1 < text.len;
            }
            if (pattern[pi + 3] == '/') return middleGlobstar(pattern, pi + 3, text, ti, has_slash);
            if (ti >= text.len or text[ti] != '/') return false;
            pi += 1;
            ti += 1;
        } else if (char == '[') {
            if (ti >= text.len) return false;
            const class = scanClass(pattern, pi, text[ti]) orelse return false;
            if (!class.matched) return false;
            pi = class.end;
            ti += 1;
        } else {
            if (ti >= text.len or !literalMatches(char, text[ti])) return false;
            pi += 1;
            ti += 1;
        }
    }
    return atEnd(text, ti);
}
