const std = @import("std");
const json_text = @import("json_tree").text;
const skill_ignore = @import("skill_ignore.zig");

pub const Diagnostic = struct {
    kind: union(enum) { warning, collision: []const u8, err },
    message: []const u8,
    path: []const u8,
};

pub const Options = struct {
    cwd: []const u8,
    home: []const u8,
    agent_dir: []const u8,
    user_paths: []const []const u8 = &.{},
    explicit_paths: []const []const u8 = &.{},
    no_skills: bool = false,
    enable_skill_commands: ?bool = null,
};

pub const Result = struct {
    resources: []const Resource,
    diagnostics: []const Diagnostic,
    enable_skill_commands: bool = true,
};

pub const Scope = enum { project, user, temporary };

pub const Source = struct {
    scope: Scope,
    origin: union(enum) { local, auto, package: []const u8 } = .local,
};

pub const Resource = struct {
    path: []const u8,
    source: Source,
    enabled: bool = true,
};

pub const Mode = enum { pi, agents, explicit };

const PathList = std.ArrayList([]const u8);
const ResourceList = std.ArrayList(Resource);

fn resourceIndex(items: []const Resource, path: []const u8) ?usize {
    for (items, 0..) |item, i| if (eq(item.path, path)) return i;
    return null;
}

fn addResource(out: *ResourceList, a: std.mem.Allocator, resource: Resource) !void {
    if (resourceIndex(out.items, resource.path) != null) return;
    try out.append(a, resource);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn starts(a: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, a, prefix);
}

fn ends(a: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, a, suffix);
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "/";
}

fn addUnique(list: *PathList, a: std.mem.Allocator, path: []const u8) !void {
    for (list.items) |item| if (eq(item, path)) return;
    try list.append(a, path);
}

fn appendAll(list: *PathList, a: std.mem.Allocator, items: []const []const u8) !void {
    for (items) |item| try addUnique(list, a, item);
}

fn normalizeAbs(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (eq(part, ".")) continue;
        if (eq(part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(a, part);
    }
    if (parts.items.len == 0) return "/";
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '/');
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    return out.toOwnedSlice(a);
}

fn baseDir(a: std.mem.Allocator, current: []const u8, home: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(current)) return normalizeAbs(a, current);
    const combined = try std.fs.path.join(a, &.{ home, current });
    return normalizeAbs(a, combined);
}

pub fn resolve(a: std.mem.Allocator, cwd: []const u8, home: []const u8, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var expanded = try expandHome(a, home, trimmed);
    if (starts(expanded, "file://")) expanded = try fileUrlPath(a, expanded);
    if (std.fs.path.isAbsolute(expanded)) return normalizeAbs(a, expanded);
    const base = if (std.fs.path.isAbsolute(cwd)) try normalizeAbs(a, cwd) else try baseDir(a, cwd, home);
    return normalizeAbs(a, try std.fs.path.join(a, &.{ base, expanded }));
}

fn expandHome(a: std.mem.Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (eq(path, "~")) return home;
    if (starts(path, "~/")) return std.fs.path.join(a, &.{ home, path[2..] });
    return path;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn percentDecode(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) return input;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            if (i + 2 >= input.len) return error.InvalidFileUrl;
            const hi = hexValue(input[i + 1]) orelse return error.InvalidFileUrl;
            const lo = hexValue(input[i + 2]) orelse return error.InvalidFileUrl;
            const decoded = (hi << 4) | lo;
            if (decoded == '/' or decoded == '\\') return error.InvalidFileUrl;
            try out.append(a, decoded);
            i += 3;
            continue;
        }
        try out.append(a, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn fileUrlPath(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const rest = raw["file://".len..];
    var path: []const u8 = undefined;
    if (starts(rest, "/")) {
        path = rest;
    } else {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidFileUrl;
        if (!eq(rest[0..slash], "localhost")) return error.InvalidFileUrl;
        path = rest[slash..];
    }
    return percentDecode(a, path);
}

fn relativePath(a: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const b = try normalizeAbs(a, base);
    const t = try normalizeAbs(a, target);
    if (eq(b, t)) return "";
    var bparts: std.ArrayList([]const u8) = .empty;
    var tparts: std.ArrayList([]const u8) = .empty;
    var bit = std.mem.tokenizeScalar(u8, b, '/');
    while (bit.next()) |part| try bparts.append(a, part);
    var tit = std.mem.tokenizeScalar(u8, t, '/');
    while (tit.next()) |part| try tparts.append(a, part);
    var common: usize = 0;
    while (common < bparts.items.len and common < tparts.items.len and
        eq(bparts.items[common], tparts.items[common])) : (common += 1)
    {}
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var i = common;
    while (i < bparts.items.len) : (i += 1) {
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, "..");
        first = false;
    }
    i = common;
    while (i < tparts.items.len) : (i += 1) {
        if (!first) try out.append(a, '/');
        try out.appendSlice(a, tparts.items[i]);
        first = false;
    }
    return out.toOwnedSlice(a);
}

const kit_unicode = @import("kit").unicode;

const MatchUnit = struct { cp: u21, len: usize };

fn matchUnit(text: []const u8, pos: usize) MatchUnit {
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (pos + len > text.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.wtf8Decode(text[pos..][0..len]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = len };
}

const ClassCursor = struct {
    pattern: []const u8,
    pos: usize,
    unicode: bool,
    low: ?u21 = null,

    fn next(self: *ClassCursor) ?u21 {
        if (self.low) |low| {
            self.low = null;
            return low;
        }
        if (self.pos >= self.pattern.len) return null;
        const unit = matchUnit(self.pattern, self.pos);
        self.pos += unit.len;
        if (unit.cp <= 0xffff or self.unicode) return unit.cp;
        const value = unit.cp - 0x10000;
        self.low = 0xdc00 + (value & 0x3ff);
        return 0xd800 + (value >> 10);
    }

    fn peek(self: ClassCursor) ?u21 {
        var copy = self;
        return copy.next();
    }
};

const ClassEmission = struct {
    ch: u21,
    unicode: bool,
    high: ?u21 = null,
    atom: ?u21 = null,
    range: ?u21 = null,
    matched: bool = false,
    present: bool = false,
    valid: bool = true,

    fn emitAtom(self: *ClassEmission, cp: u21) void {
        self.present = true;
        if (self.range) |lo| {
            self.valid = self.valid and lo <= cp;
            self.matched = self.matched or (self.ch >= lo and self.ch <= cp);
            self.range = null;
        } else {
            if (self.atom) |atom| self.matched = self.matched or self.ch == atom;
            self.atom = cp;
        }
    }

    fn literal(self: *ClassEmission, cp: u21) void {
        if (self.high) |high| {
            self.high = null;
            if (cp >= 0xdc00 and cp <= 0xdfff) {
                self.emitAtom(0x10000 + ((high - 0xd800) << 10) + cp - 0xdc00);
                return;
            }
            self.emitAtom(high);
        }
        if (self.unicode and cp >= 0xd800 and cp <= 0xdbff) self.high = cp else self.emitAtom(cp);
    }

    fn flushHigh(self: *ClassEmission) void {
        if (self.high) |high| self.emitAtom(high);
        self.high = null;
    }

    fn dash(self: *ClassEmission) void {
        self.flushHigh();
        self.range = self.atom;
        self.atom = null;
    }

    fn flush(self: *ClassEmission) void {
        self.flushHigh();
        if (self.atom) |atom| self.matched = self.matched or self.ch == atom;
        self.atom = null;
    }
};

const ClassMatch = struct { end: usize, matched: bool, unicode: bool };

fn matchClass(pattern: []const u8, start: usize, ch: u21, unicode_mode: bool) ?ClassMatch {
    var cursor: ClassCursor = .{ .pattern = pattern, .pos = start + 1, .unicode = unicode_mode };
    var negated = false;
    if (cursor.peek() == '!' or cursor.peek() == '^') {
        negated = true;
        _ = cursor.next();
    }
    var emission: ClassEmission = .{ .ch = ch, .unicode = unicode_mode };
    var graph = false;
    var unicode = false;
    var first = true;
    var escaping = false;
    var range_start: ?u21 = null;
    while (true) {
        const byte_pos = cursor.pos;
        const was_low = cursor.low != null;
        const c = cursor.next() orelse return null;
        if (c == ']' and !first and !escaping) {
            emission.flush();
            const positive = emission.present and (emission.matched != negated);
            const negative = graph and (posixClass("graph", ch) != negated);
            return .{ .end = cursor.pos, .matched = emission.valid and (positive or negative), .unicode = unicode };
        }
        first = false;
        if (c == '\\' and !escaping) {
            escaping = true;
            continue;
        }
        if (c == '[' and !escaping and !was_low and starts(pattern[byte_pos..], "[:")) {
            if (std.mem.indexOf(u8, pattern[byte_pos + 2 ..], ":]")) |rel| {
                const close = byte_pos + 2 + rel;
                const name = pattern[byte_pos + 2 .. close];
                if (knownPosixClass(name)) {
                    if (range_start != null) return .{ .end = pattern.len, .matched = false, .unicode = false };
                    unicode = unicode or (!eq(name, "ascii") and !eq(name, "xdigit"));
                    if (eq(name, "graph")) graph = true else {
                        emission.flush();
                        emission.present = true;
                        emission.matched = emission.matched or posixClass(name, ch);
                    }
                    cursor.pos = close + 2;
                    continue;
                }
            }
        }
        escaping = false;
        if (range_start) |lo| {
            if (c > lo) {
                emission.literal(lo);
                emission.dash();
                emission.literal(c);
            } else if (c == lo) emission.literal(c);
            range_start = null;
            continue;
        }
        if (cursor.peek() == '-') {
            _ = cursor.next();
            if (cursor.peek() == ']') {
                emission.literal(c);
                emission.literal('-');
            } else range_start = c;
            continue;
        }
        emission.literal(c);
    }
}

fn knownPosixClass(name: []const u8) bool {
    inline for (.{ "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "word", "xdigit" }) |known| {
        if (eq(name, known)) return true;
    }
    return false;
}

fn posixClass(name: []const u8, ch: u21) bool {
    const category = kit_unicode.generalCategory(ch);
    const letter = switch (category) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other, .number_letter => true,
        else => false,
    };
    const separator = switch (category) {
        .separator_space, .separator_line, .separator_paragraph => true,
        else => false,
    };
    const other = switch (category) {
        .other_control, .other_format, .other_surrogate, .other_private_use, .other_not_assigned => true,
        else => false,
    };
    if (eq(name, "alnum")) return letter or category == .number_decimal_digit;
    if (eq(name, "alpha")) return letter;
    if (eq(name, "ascii")) return ch < 128;
    if (eq(name, "blank")) return category == .separator_space or ch == '\t';
    if (eq(name, "cntrl")) return category == .other_control;
    if (eq(name, "digit")) return category == .number_decimal_digit;
    if (eq(name, "graph")) return !separator and !other;
    if (eq(name, "lower")) return category == .letter_lowercase;
    if (eq(name, "print")) return !other;
    if (eq(name, "punct")) return switch (category) {
        .punctuation_connector, .punctuation_dash, .punctuation_open, .punctuation_close, .punctuation_initial_quote, .punctuation_final_quote, .punctuation_other => true,
        .symbol_math, .symbol_currency, .symbol_modifier, .symbol_other => true,
        else => false,
    };
    if (eq(name, "space")) return separator or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
    if (eq(name, "upper")) return category == .letter_uppercase;
    if (eq(name, "word")) return letter or category == .number_decimal_digit or category == .punctuation_connector;
    if (eq(name, "xdigit")) return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
    return false;
}

fn matchSegment(pattern: []const u8, text: []const u8, dot: bool) bool {
    if (dot and text.len > 0 and text[0] == '.') {
        const literal_dot = pattern.len > 0 and pattern[0] == '.';
        if (!literal_dot and !extglobAllowsDot(pattern)) return false;
    }
    return segmentFrom(pattern, 0, text, 0, true);
}

fn extglobAllowsDot(pattern: []const u8) bool {
    if (pattern.len < 2 or pattern[1] != '(') return false;
    var i: usize = 2;
    var depth: usize = 0;
    var at_start = true;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            if (at_start and i + 1 < pattern.len and pattern[i + 1] == '.') return true;
            i += 1;
            at_start = false;
            continue;
        }
        if (c == '(') {
            depth += 1;
            at_start = false;
            continue;
        }
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
            continue;
        }
        if (c == '|' and depth == 0) {
            at_start = true;
            continue;
        }
        if (at_start) {
            if (c == '.') return true;
            at_start = false;
        }
    }
    return false;
}

fn extglobClose(pattern: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '(') depth += 1 else if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn altMatches(body: []const u8, text: []const u8, unicode_mode: bool) bool {
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end) {
            const c = body[i];
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
        }
        if (at_end or (body[i] == '|' and depth == 0)) {
            if (segmentFrom(body[start..i], 0, text, 0, unicode_mode)) return true;
            start = i + 1;
        }
    }
    return false;
}

fn extRepeat(body: []const u8, text: []const u8, pos: usize, rest: []const u8, rest_pi: usize, min: usize, max: isize, count: usize, unicode_mode: bool) bool {
    if (count >= min and segmentFrom(rest, rest_pi, text, pos, unicode_mode)) return true;
    if (max >= 0 and count >= @as(usize, @intCast(max))) return false;
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end) {
            const c = body[i];
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
        }
        if (at_end or (body[i] == '|' and depth == 0)) {
            const alt = body[start..i];
            var end = pos;
            while (end < text.len) {
                end += matchUnit(text, end).len;
                if (segmentFrom(alt, 0, text[pos..end], 0, unicode_mode)) {
                    if (extRepeat(body, text, end, rest, rest_pi, min, max, count + 1, unicode_mode)) return true;
                }
            }
            start = i + 1;
        }
    }
    return false;
}

fn extNegative(body: []const u8, text: []const u8, pos: usize, rest: []const u8, rest_pi: usize, unicode_mode: bool) bool {
    if (segmentFrom(rest, rest_pi, text, pos, unicode_mode)) return true;
    var end = pos;
    while (end < text.len) {
        end += matchUnit(text, end).len;
        if (!altMatches(body, text[pos..end], unicode_mode)) {
            if (segmentFrom(rest, rest_pi, text, end, unicode_mode)) return true;
        }
    }
    return false;
}

fn segmentFrom(pattern: []const u8, pi_start: usize, text: []const u8, ti_start: usize, unicode_mode: bool) bool {
    var pi = pi_start;
    var ti = ti_start;
    while (pi < pattern.len) {
        const p = pattern[pi];
        if ((p == '@' or p == '+' or p == '?' or p == '*' or p == '!') and pi + 1 < pattern.len and pattern[pi + 1] == '(') {
            const close = extglobClose(pattern, pi + 1) orelse return false;
            const body = pattern[pi + 2 .. close];
            const rest_pi = close + 1;
            const matched = switch (p) {
                '@' => extRepeat(body, text, ti, pattern, rest_pi, 1, 1, 0, unicode_mode),
                '+' => extRepeat(body, text, ti, pattern, rest_pi, 1, -1, 0, unicode_mode),
                '*' => extRepeat(body, text, ti, pattern, rest_pi, 0, -1, 0, unicode_mode),
                '?' => extRepeat(body, text, ti, pattern, rest_pi, 0, 1, 0, unicode_mode),
                '!' => extNegative(body, text, ti, pattern, rest_pi, unicode_mode),
                else => false,
            };
            if (matched) return true;
            return false;
        }
        if (p == '*') {
            while (pi < pattern.len and pattern[pi] == '*') pi += 1;
            if (pi == pattern.len) return true;
            var k = ti;
            while (k <= text.len) {
                if (segmentFrom(pattern, pi, text, k, unicode_mode)) return true;
                if (k == text.len) break;
                k += matchUnit(text, k).len;
            }
            return false;
        }
        if (p == '?') {
            if (ti >= text.len) return false;
            pi += 1;
            ti += matchUnit(text, ti).len;
            continue;
        }
        if (p == '[') {
            if (ti >= text.len) return false;
            const unit = matchUnit(text, ti);
            if (matchClass(pattern, pi, unit.cp, unicode_mode)) |class| {
                if (!class.matched) return false;
                pi = class.end;
                ti += unit.len;
                continue;
            }
            return false;
        }
        if (p == '\\' and pi + 1 < pattern.len) pi += 1;
        if (ti >= text.len) return false;
        const literal = matchUnit(pattern, pi);
        const unit = matchUnit(text, ti);
        if (literal.cp != unit.cp) return false;
        pi += literal.len;
        ti += unit.len;
    }
    return ti == text.len;
}

fn firstSegment(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |i| return path[0..i];
    return path;
}

fn restAfter(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return "";
}

fn allVisible(path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return false;
    }
    return true;
}

fn pathFrom(pattern: []const u8, text: []const u8, dot: bool) bool {
    if (pattern.len == 0) return text.len == 0;
    const pseg = firstSegment(pattern);
    const prest = restAfter(pattern);
    if (eq(pseg, "**")) {
        if (prest.len == 0) {
            if (text.len == 0) return false;
            return if (dot) allVisible(text) else true;
        }
        if (pathFrom(prest, text, dot)) return true;
        var cur = text;
        while (cur.len > 0) {
            const tseg = firstSegment(cur);
            if (dot and tseg.len > 0 and tseg[0] == '.') return false;
            cur = restAfter(cur);
            if (pathFrom(prest, cur, dot)) return true;
        }
        return false;
    }
    if (text.len == 0) {
        if (!matchSegment(pseg, "", dot)) return false;
        return pathFrom(prest, "", dot);
    }
    const tseg = firstSegment(text);
    if (!matchSegment(pseg, tseg, dot)) return false;
    return pathFrom(prest, restAfter(text), dot);
}

fn rangeMatch(a: std.mem.Allocator, prefix: []const u8, alt: []const u8, suffix: []const u8, text: []const u8, dot: bool) bool {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitSequence(u8, alt, "..");
    while (iterator.next()) |part| {
        if (count < parts.len) parts[count] = part;
        count += 1;
    }
    if (count < 2 or count > 3) return false;
    const start_number = std.fmt.parseInt(i64, parts[0], 10) catch null;
    const end_number = std.fmt.parseInt(i64, parts[1], 10) catch null;
    if (start_number != null and end_number != null) {
        var step = if (count == 3) std.fmt.parseInt(i64, parts[2], 10) catch 1 else 1;
        if (step < 0) step = -step;
        if (step == 0) step = 1;
        const low = @min(start_number.?, end_number.?);
        const high = @max(start_number.?, end_number.?);
        const padded = (parts[0].len > 1 and parts[0][0] == '0') or (parts[1].len > 1 and parts[1][0] == '0');
        const width = @max(parts[0].len, parts[1].len);
        var value = low;
        while (true) {
            var digits_buffer: [64]u8 = undefined;
            const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{value}) catch return false;
            var padded_buffer: [64]u8 = undefined;
            var rendered: []const u8 = digits;
            if (padded and value >= 0 and digits.len < width) {
                if (width > padded_buffer.len) return false;
                var used: usize = 0;
                while (used < width - digits.len) : (used += 1) padded_buffer[used] = '0';
                @memcpy(padded_buffer[used .. used + digits.len], digits);
                rendered = padded_buffer[0 .. used + digits.len];
            }
            const expanded = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, rendered, suffix }) catch return false;
            if (braceMatch(a, expanded, text, dot)) return true;
            value = std.math.add(i64, value, step) catch break;
            if (value > high) break;
        }
        return false;
    }
    if (parts[0].len == 1 and parts[1].len == 1) {
        var step: u8 = 1;
        if (count == 3) step = std.fmt.parseInt(u8, parts[2], 10) catch 1;
        if (step == 0) step = 1;
        const low = @min(parts[0][0], parts[1][0]);
        const high = @max(parts[0][0], parts[1][0]);
        var value = low;
        while (true) {
            var char_buffer: [1]u8 = .{value};
            const expanded = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, char_buffer[0..], suffix }) catch return false;
            if (braceMatch(a, expanded, text, dot)) return true;
            value = std.math.add(u8, value, step) catch break;
            if (value > high) break;
        }
        return false;
    }
    return false;
}

fn braceMatch(a: std.mem.Allocator, pattern: []const u8, text: []const u8, dot: bool) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
            continue;
        }
        if (pattern[i] != '{') continue;
        var depth: usize = 0;
        var close: ?usize = null;
        var j = i;
        while (j < pattern.len) : (j += 1) {
            if (pattern[j] == '\\') {
                j += 1;
                continue;
            }
            if (pattern[j] == '{') depth += 1;
            if (pattern[j] == '}') {
                depth -= 1;
                if (depth == 0) {
                    close = j;
                    break;
                }
            }
        }
        const end = close orelse break;
        var part_start = i + 1;
        var d: usize = 0;
        var had_comma = false;
        var k = i + 1;
        while (k <= end) : (k += 1) {
            if (k < end and pattern[k] == '\\') {
                k += 1;
                continue;
            }
            if (k < end and pattern[k] == '{') d += 1;
            if (k < end and pattern[k] == '}') d -= 1;
            if ((k == end or (pattern[k] == ',' and d == 0))) {
                if (k < end) had_comma = true;
                const alt = pattern[part_start..k];
                const expanded = std.fmt.allocPrint(a, "{s}{s}{s}", .{ pattern[0..i], alt, pattern[end + 1 ..] }) catch return false;
                if (braceMatch(a, expanded, text, dot)) return true;
                part_start = k + 1;
            }
        }
        if (!had_comma and rangeMatch(a, pattern[0..i], pattern[i + 1 .. end], pattern[end + 1 ..], text, dot)) return true;
        return false;
    }
    return pathFrom(pattern, text, dot);
}

fn globMatch(a: std.mem.Allocator, pattern: []const u8, text: []const u8, dot: bool) bool {
    return braceMatch(a, pattern, text, dot);
}

fn normalizePattern(a: std.mem.Allocator, pattern: []const u8, home: []const u8) ![]const u8 {
    var p = try expandHome(a, home, pattern);
    if (starts(p, "file://")) p = try fileUrlPath(a, p);
    if (starts(p, "./")) p = p[2..];
    if (starts(p, ".\\")) p = p[2..];
    if (std.fs.path.isAbsolute(p)) return normalizeAbs(a, p);
    return p;
}

fn matchesAnyPattern(a: std.mem.Allocator, file_path: []const u8, patterns: []const []const u8, base: []const u8, home: []const u8) !bool {
    const rel = try relativePath(a, base, file_path);
    const name = basename(file_path);
    const is_skill = eq(name, "SKILL.md");
    const parent = if (is_skill) dirname(file_path) else "";
    const parent_rel = if (is_skill) try relativePath(a, base, parent) else "";
    const parent_name = if (is_skill) basename(parent) else "";
    for (patterns) |raw| {
        const pattern = normalizePattern(a, raw, home) catch continue;
        if (globMatch(a, pattern, rel, true)) return true;
        if (globMatch(a, pattern, name, true)) return true;
        if (globMatch(a, pattern, file_path, true)) return true;
        if (is_skill) {
            if (globMatch(a, pattern, parent_rel, true)) return true;
            if (globMatch(a, pattern, parent_name, true)) return true;
            if (globMatch(a, pattern, parent, true)) return true;
        }
    }
    return false;
}

fn matchesAnyExactPattern(a: std.mem.Allocator, file_path: []const u8, patterns: []const []const u8, base: []const u8, home: []const u8) !bool {
    if (patterns.len == 0) return false;
    const rel = try relativePath(a, base, file_path);
    const name = basename(file_path);
    const is_skill = eq(name, "SKILL.md");
    const parent = if (is_skill) dirname(file_path) else "";
    const parent_rel = if (is_skill) try relativePath(a, base, parent) else "";
    for (patterns) |raw| {
        const normalized = normalizePattern(a, raw, home) catch continue;
        if (eq(normalized, rel) or eq(normalized, file_path)) return true;
        if (is_skill and (eq(normalized, parent_rel) or eq(normalized, parent))) return true;
    }
    return false;
}

fn splitLists(a: std.mem.Allocator, entries: []const []const u8) !struct {
    plain: []const []const u8,
    patterns: []const []const u8,
} {
    var plain: PathList = .empty;
    var patterns: PathList = .empty;
    for (entries) |entry| {
        if (starts(entry, "!") or starts(entry, "+") or starts(entry, "-") or
            std.mem.indexOfScalar(u8, entry, '*') != null or std.mem.indexOfScalar(u8, entry, '?') != null)
        {
            try patterns.append(a, entry);
        } else {
            try plain.append(a, entry);
        }
    }
    return .{ .plain = try plain.toOwnedSlice(a), .patterns = try patterns.toOwnedSlice(a) };
}

fn applyPatterns(a: std.mem.Allocator, all: []const []const u8, patterns: []const []const u8, base: []const u8, home: []const u8) ![]const []const u8 {
    var includes: PathList = .empty;
    var excludes: PathList = .empty;
    var force_includes: PathList = .empty;
    var force_excludes: PathList = .empty;
    for (patterns) |p| {
        if (starts(p, "+")) try force_includes.append(a, p[1..]) else if (starts(p, "-")) try force_excludes.append(a, p[1..]) else if (starts(p, "!")) try excludes.append(a, p[1..]) else try includes.append(a, p);
    }
    var result: PathList = .empty;
    if (includes.items.len == 0) {
        try result.appendSlice(a, all);
    } else {
        for (all) |f| {
            if (try matchesAnyPattern(a, f, includes.items, base, home)) try result.append(a, f);
        }
    }
    if (excludes.items.len > 0) {
        var kept: PathList = .empty;
        for (result.items) |f| {
            if (!try matchesAnyPattern(a, f, excludes.items, base, home)) try kept.append(a, f);
        }
        result = kept;
    }
    if (force_includes.items.len > 0) {
        for (all) |f| {
            var present = false;
            for (result.items) |r| if (eq(r, f)) {
                present = true;
                break;
            };
            if (!present and try matchesAnyExactPattern(a, f, force_includes.items, base, home)) try result.append(a, f);
        }
    }
    if (force_excludes.items.len > 0) {
        var kept: PathList = .empty;
        for (result.items) |f| {
            if (!try matchesAnyExactPattern(a, f, force_excludes.items, base, home)) try kept.append(a, f);
        }
        result = kept;
    }
    return result.toOwnedSlice(a);
}

fn collectOverrides(a: std.mem.Allocator, entries: []const []const u8) ![]const []const u8 {
    var out: PathList = .empty;
    for (entries) |entry| if (starts(entry, "!") or starts(entry, "+") or starts(entry, "-")) try out.append(a, entry);
    return out.toOwnedSlice(a);
}

fn isEnabledByOverrides(a: std.mem.Allocator, file_path: []const u8, entries: []const []const u8, base: []const u8, home: []const u8) !bool {
    const overrides = try collectOverrides(a, entries);
    var excludes: PathList = .empty;
    var force_includes: PathList = .empty;
    var force_excludes: PathList = .empty;
    for (overrides) |p| {
        if (starts(p, "!")) try excludes.append(a, p[1..]) else if (starts(p, "+")) try force_includes.append(a, p[1..]) else if (starts(p, "-")) try force_excludes.append(a, p[1..]);
    }
    var enabled = true;
    if (excludes.items.len > 0) {
        if (try matchesAnyPattern(a, file_path, excludes.items, base, home)) enabled = false;
    }
    if (force_includes.items.len > 0) {
        if (try matchesAnyExactPattern(a, file_path, force_includes.items, base, home)) enabled = true;
    }
    if (force_excludes.items.len > 0) {
        if (try matchesAnyExactPattern(a, file_path, force_excludes.items, base, home)) enabled = false;
    }
    return enabled;
}

const Rule = struct {
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    has_slash: bool,
};

const Matcher = struct {
    rules: std.ArrayList(Rule) = .empty,
};

fn readWholeFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch null;
}

fn processTrailingSpaces(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') end -= 1;
    if (end == line.len) return line;
    var backslashes: usize = 0;
    var k = end;
    while (k > 0 and line[k - 1] == '\\') : (k -= 1) backslashes += 1;
    const keep_backslashes = backslashes - (backslashes % 2);
    const keep_space: usize = backslashes % 2;
    if (keep_space == 0) return line[0..end];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, line[0 .. end - backslashes]);
    var i: usize = 0;
    while (i < keep_backslashes) : (i += 1) try out.append(a, '\\');
    try out.append(a, ' ');
    return out.toOwnedSlice(a);
}

fn addIgnoreFile(a: std.mem.Allocator, io: std.Io, matcher: *Matcher, dir: []const u8, prefix: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ dir, name });
    const content = readWholeFile(a, io, path) orelse return;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (first_line and starts(line, "\xEF\xBB\xBF")) line = line[3..];
        first_line = false;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (starts(trimmed, "#") and !starts(trimmed, "\\#")) continue;
        line = try processTrailingSpaces(a, line);
        var pattern = line;
        var negated = false;
        if (starts(pattern, "!")) {
            negated = true;
            pattern = pattern[1..];
        } else if (starts(pattern, "\\!")) {
            pattern = pattern[1..];
        }
        if (starts(pattern, "/")) pattern = pattern[1..];
        if (pattern.len == 0) continue;
        const prefixed = if (prefix.len > 0)
            try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, pattern })
        else
            try a.dupe(u8, pattern);
        var body = prefixed;
        var dir_only = false;
        if (ends(body, "/")) {
            dir_only = true;
            body = body[0 .. body.len - 1];
            while (ends(body, "/")) body = body[0 .. body.len - 1];
        }
        if (body.len == 0) continue;
        try matcher.rules.append(a, .{
            .pattern = body,
            .negated = negated,
            .dir_only = dir_only,
            .has_slash = std.mem.indexOfScalar(u8, body, '/') != null,
        });
    }
}

fn addIgnoreRules(a: std.mem.Allocator, io: std.Io, matcher: *Matcher, dir: []const u8, root: []const u8) !void {
    const rel = try relativePath(a, root, dir);
    const prefix = if (rel.len > 0) try std.fmt.allocPrint(a, "{s}/", .{rel}) else "";
    try addIgnoreFile(a, io, matcher, dir, prefix, ".gitignore");
    try addIgnoreFile(a, io, matcher, dir, prefix, ".ignore");
    try addIgnoreFile(a, io, matcher, dir, prefix, ".fdignore");
}

fn ruleMatches(a: std.mem.Allocator, rule: Rule, rel: []const u8, is_dir: bool) bool {
    if (rule.dir_only and !is_dir) return false;
    const subject = if (rule.has_slash) rel else basename(rel);
    return skill_ignore.matches(a, rule.pattern, subject, rule.has_slash);
}

fn isIgnored(a: std.mem.Allocator, matcher: *Matcher, rel: []const u8, is_dir: bool) bool {
    var ignored = false;
    for (matcher.rules.items) |rule| {
        if (ruleMatches(a, rule, rel, is_dir)) ignored = !rule.negated;
    }
    return ignored;
}

const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

fn entryLess(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn statKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return stat.kind;
}

fn collectDir(
    a: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    root: []const u8,
    mode: Mode,
    matcher: *Matcher,
    out: *PathList,
) !void {
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    try addIgnoreRules(a, io, matcher, dir, root);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| a.free(entry.name);
        entries.deinit(a);
    }
    var iterator = handle.iterate();
    while (try iterator.next(io)) |entry| {
        try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(Entry, entries.items, {}, entryLess);

    for (entries.items) |entry| {
        if (!eq(entry.name, "SKILL.md")) continue;
        const full = try std.fs.path.join(a, &.{ dir, entry.name });
        var kind = entry.kind;
        if (kind == .sym_link) kind = statKind(io, full) orelse continue;
        if (kind != .file) continue;
        const rel = try relativePath(a, root, full);
        if (!isIgnored(a, matcher, rel, false)) {
            try addUnique(out, a, full);
            return;
        }
    }

    const is_root = eq(dir, root);
    for (entries.items) |entry| {
        if (starts(entry.name, ".")) continue;
        if (eq(entry.name, "node_modules")) continue;
        const full = try std.fs.path.join(a, &.{ dir, entry.name });
        var kind = entry.kind;
        if (kind == .sym_link) kind = statKind(io, full) orelse continue;
        const is_dir = kind == .directory;
        const is_file = kind == .file;
        const rel = try relativePath(a, root, full);
        if (is_dir) {
            if (isIgnored(a, matcher, rel, true)) continue;
            try collectDir(a, io, full, root, mode, matcher, out);
            continue;
        }
        if (!is_file or !ends(entry.name, ".md")) continue;
        const include = (mode != .agents and is_root) or (mode == .agents and !is_root);
        if (!include) continue;
        if (isIgnored(a, matcher, rel, false)) continue;
        try addUnique(out, a, full);
    }
}

pub fn collect(a: std.mem.Allocator, io: std.Io, dir: []const u8, mode: Mode) ![]const []const u8 {
    const root = if (std.fs.path.isAbsolute(dir)) try normalizeAbs(a, dir) else blk: {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch return &.{};
        break :blk try normalizeAbs(a, try std.fs.path.join(a, &.{ cwd, dir }));
    };
    var out: PathList = .empty;
    var matcher: Matcher = .{};
    try collectDir(a, io, root, root, mode, &matcher, &out);
    return out.toOwnedSlice(a);
}

const PackageScope = enum { project, user };

const PackageFilter = struct {
    source: []const u8,
    skills: ?[]const []const u8 = null,
    autoload: bool = true,
    has_filter: bool = false,
    scope: PackageScope,
    base: []const u8,
    home: []const u8,
};

const DeltaEntry = struct {
    path: []const u8,
    enabled: bool,
};

const PackageAccumulator = struct {
    entries: ResourceList = .empty,

    fn add(self: *PackageAccumulator, a: std.mem.Allocator, path: []const u8, source: Source, enabled: bool) !void {
        try addResource(&self.entries, a, .{ .path = path, .source = source, .enabled = enabled });
    }
};

const Settings = struct {
    skills: ?[]const []const u8 = null,
    enable_skill_commands: ?bool = null,
    packages: []const PackageFilter = &.{},
};

fn stringArray(a: std.mem.Allocator, value: std.json.Value) !?[]const []const u8 {
    switch (value) {
        .array => |array| {
            var out: PathList = .empty;
            for (array.items) |item| switch (item) {
                .string => |s| try out.append(a, s),
                else => {},
            };
            return try out.toOwnedSlice(a);
        },
        else => return null,
    }
}

fn strictStringArray(a: std.mem.Allocator, value: std.json.Value) !?[]const []const u8 {
    switch (value) {
        .array => |array| {
            var out: PathList = .empty;
            for (array.items) |item| switch (item) {
                .string => |s| try out.append(a, s),
                else => return null,
            };
            return try out.toOwnedSlice(a);
        },
        else => return null,
    }
}

fn readJson(a: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.Value {
    const data = readWholeFile(a, io, path) orelse return null;
    return json_text.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch null;
}

fn readSettings(a: std.mem.Allocator, io: std.Io, config_root: []const u8, scope: PackageScope, home: []const u8) Settings {
    var settings = Settings{};
    const path = std.fs.path.join(a, &.{ config_root, "settings.json" }) catch return settings;
    const root = readJson(a, io, path) orelse return settings;
    switch (root) {
        .object => |object| {
            if (object.get("enableSkillCommands")) |value| switch (value) {
                .bool => |b| settings.enable_skill_commands = b,
                else => {},
            };
            if (object.get("skills")) |value| switch (value) {
                .array => settings.skills = stringArray(a, value) catch null,
                .object => |legacy| {
                    if (settings.enable_skill_commands == null) {
                        if (legacy.get("enableSkillCommands")) |flag| switch (flag) {
                            .bool => |b| settings.enable_skill_commands = b,
                            else => {},
                        };
                    }
                    if (legacy.get("customDirectories")) |dirs| switch (dirs) {
                        .array => {
                            const list = (stringArray(a, dirs) catch null) orelse &.{};
                            if (list.len > 0) settings.skills = list;
                        },
                        else => {},
                    };
                },
                else => {},
            };
            if (object.get("packages")) |value| switch (value) {
                .array => |array| {
                    var packages: std.ArrayList(PackageFilter) = .empty;
                    for (array.items) |item| {
                        switch (item) {
                            .string => |source| packages.append(a, .{
                                .source = source,
                                .scope = scope,
                                .base = config_root,
                                .home = home,
                            }) catch {},
                            .object => |filter_object| {
                                const source = switch (filter_object.get("source") orelse continue) {
                                    .string => |s| s,
                                    else => continue,
                                };
                                var filter = PackageFilter{ .source = source, .scope = scope, .base = config_root, .home = home, .has_filter = true };
                                if (filter_object.get("autoload")) |flag| switch (flag) {
                                    .bool => |b| filter.autoload = b,
                                    else => {},
                                };
                                if (filter_object.get("skills")) |skills| filter.skills = stringArray(a, skills) catch null;
                                packages.append(a, filter) catch {};
                            },
                            else => {},
                        }
                    }
                    settings.packages = packages.toOwnedSlice(a) catch &.{};
                },
                else => {},
            };
        },
        else => {},
    }
    return settings;
}

const Manifest = struct {
    has_fields: bool = false,
    skills: ?[]const []const u8 = null,
};

fn readManifest(a: std.mem.Allocator, io: std.Io, package_root: []const u8) Manifest {
    var manifest = Manifest{};
    const path = std.fs.path.join(a, &.{ package_root, "package.json" }) catch return manifest;
    const root = readJson(a, io, path) orelse return manifest;
    const object = switch (root) {
        .object => |o| o,
        else => return manifest,
    };
    const pi = switch (object.get("pi") orelse return manifest) {
        .object => |o| o,
        else => return manifest,
    };
    const fields = [_][]const u8{ "extensions", "skills", "prompts", "themes" };
    for (fields) |field| {
        const value = pi.get(field) orelse continue;
        const list = (strictStringArray(a, value) catch null) orelse continue;
        manifest.has_fields = true;
        if (eq(field, "skills")) manifest.skills = list;
    }
    return manifest;
}

fn collectFilesFromPaths(
    a: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    out: *PathList,
) !void {
    for (paths) |path| {
        const kind = statKind(io, path) orelse continue;
        if (kind == .file) {
            try addUnique(out, a, path);
        } else if (kind == .directory) {
            const found = try collect(a, io, path, .pi);
            try appendAll(out, a, found);
        }
    }
}

fn segmentHasGlob(segment: []const u8) bool {
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '*' or c == '?' or c == '[' or c == '{') return true;
        if ((c == '@' or c == '+' or c == '!') and i + 1 < segment.len and segment[i + 1] == '(') return true;
    }
    return false;
}

fn globStaticPrefix(pattern: []const u8) []const u8 {
    var i: usize = 0;
    var end: usize = 0;
    while (i < pattern.len) {
        const rest = pattern[i..];
        const len = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (segmentHasGlob(rest[0..len])) break;
        i += len;
        if (i < pattern.len) i += 1;
        end = i;
    }
    return pattern[0..end];
}

fn globVisible(a: std.mem.Allocator, root: []const u8, full: []const u8) !bool {
    const rel = try relativePath(a, root, full);
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (eq(part, "..")) continue;
        if (part.len > 0 and part[0] == '.') return false;
    }
    return true;
}

fn collectGlob(
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    pattern: []const u8,
    out: *PathList,
) !void {
    const absolute = std.fs.path.isAbsolute(pattern);
    const prefix = globStaticPrefix(pattern);
    const start = if (absolute)
        try normalizeAbs(a, if (prefix.len == 0) "/" else prefix)
    else if (prefix.len == 0)
        root
    else
        try normalizeAbs(a, try std.fs.path.join(a, &.{ root, prefix }));
    try collectGlobDir(a, io, start, root, pattern, absolute, out);
}

fn collectGlobDir(
    a: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    root: []const u8,
    pattern: []const u8,
    absolute: bool,
    out: *PathList,
) !void {
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| a.free(entry.name);
        entries.deinit(a);
    }
    var iterator = handle.iterate();
    while (try iterator.next(io)) |entry| {
        try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(Entry, entries.items, {}, entryLess);
    for (entries.items) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const full = try std.fs.path.join(a, &.{ dir, entry.name });
        const candidate = if (absolute) full else try relativePath(a, root, full);
        if (globMatch(a, pattern, candidate, true) and try globVisible(a, root, full)) try addUnique(out, a, full);
        if (entry.kind == .directory) try collectGlobDir(a, io, full, root, pattern, absolute, out);
    }
}

fn sourceEntries(a: std.mem.Allocator, entries: []const []const u8) ![]const []const u8 {
    var out: PathList = .empty;
    for (entries) |entry| if (!starts(entry, "!") and !starts(entry, "+") and !starts(entry, "-")) try out.append(a, entry);
    return out.toOwnedSlice(a);
}

fn collectManifestEntries(
    a: std.mem.Allocator,
    io: std.Io,
    entries: []const []const u8,
    root: []const u8,
    home: []const u8,
) ![]const []const u8 {
    var resolved: PathList = .empty;
    const sources = try sourceEntries(a, entries);
    for (sources) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '*') != null or std.mem.indexOfScalar(u8, entry, '?') != null) {
            const pattern = try normalizePattern(a, entry, home);
            var matches: PathList = .empty;
            try collectGlob(a, io, root, pattern, &matches);
            const slice = try matches.toOwnedSlice(a);
            std.mem.sort([]const u8, slice, {}, struct {
                fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.less);
            try appendAll(&resolved, a, slice);
        } else {
            const full = if (std.fs.path.isAbsolute(entry)) try normalizeAbs(a, entry) else try normalizeAbs(a, try std.fs.path.join(a, &.{ root, entry }));
            try addUnique(&resolved, a, full);
        }
    }
    var files: PathList = .empty;
    try collectFilesFromPaths(a, io, resolved.items, &files);
    return files.toOwnedSlice(a);
}

fn addManifestEntries(
    a: std.mem.Allocator,
    io: std.Io,
    entries: ?[]const []const u8,
    root: []const u8,
    home: []const u8,
    out: *PathList,
) !void {
    const list = entries orelse return;
    const all = try collectManifestEntries(a, io, list, root, home);
    const patterns = try collectOverrides(a, list);
    const enabled = try applyPatterns(a, all, patterns, root, home);
    try appendAll(out, a, enabled);
}

fn collectManifestFiles(
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    manifest: Manifest,
    home: []const u8,
) ![]const []const u8 {
    if (manifest.skills) |entries| {
        if (entries.len > 0) {
            const all = try collectManifestEntries(a, io, entries, root, home);
            const patterns = try collectOverrides(a, entries);
            return applyPatterns(a, all, patterns, root, home);
        }
    }
    const convention = try std.fs.path.join(a, &.{ root, "skills" });
    if (statKind(io, convention) == .directory) return collect(a, io, convention, .pi);
    return &.{};
}

fn collectDefaultPackageSkills(
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    manifest: Manifest,
    home: []const u8,
    out: *PathList,
) !void {
    if (manifest.skills != null) {
        try addManifestEntries(a, io, manifest.skills, root, home, out);
        return;
    }
    const convention = try std.fs.path.join(a, &.{ root, "skills" });
    if (statKind(io, convention) == .directory) {
        const found = try collect(a, io, convention, .pi);
        try appendAll(out, a, found);
    }
}

fn collectPackageSkills(
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    f: PackageFilter,
    home: []const u8,
    acc: *PackageAccumulator,
) !void {
    const manifest = readManifest(a, io, root);
    const source: Source = .{
        .scope = if (f.scope == .project) .project else .user,
        .origin = .{ .package = f.source },
    };
    if (f.has_filter) {
        if (!f.autoload) {
            const patterns = f.skills orelse &.{};
            if (patterns.len == 0) return;
            const all = try collectManifestFiles(a, io, root, manifest, home);
            var ordered: std.ArrayList(DeltaEntry) = .empty;
            for (patterns) |pattern| {
                const body = if (starts(pattern, "+") or starts(pattern, "-") or starts(pattern, "!")) pattern[1..] else pattern;
                const exact = starts(pattern, "+") or starts(pattern, "-");
                const enabled = !starts(pattern, "-") and !starts(pattern, "!");
                for (all) |file| {
                    const hit = if (exact)
                        try matchesAnyExactPattern(a, file, &.{body}, root, home)
                    else
                        try matchesAnyPattern(a, file, &.{body}, root, home);
                    if (!hit) continue;
                    var found = false;
                    for (ordered.items) |*entry| {
                        if (eq(entry.path, file)) {
                            entry.enabled = enabled;
                            found = true;
                            break;
                        }
                    }
                    if (!found) try ordered.append(a, .{ .path = file, .enabled = enabled });
                }
            }
            for (ordered.items) |entry| try acc.add(a, entry.path, source, entry.enabled);
            return;
        }
        if (f.skills) |patterns| {
            const all = try collectManifestFiles(a, io, root, manifest, home);
            var enabled = std.StringHashMap(void).init(a);
            defer enabled.deinit();
            if (patterns.len > 0) {
                for (try applyPatterns(a, all, patterns, root, home)) |path| try enabled.put(path, {});
            }
            for (all) |path| try acc.add(a, path, source, enabled.contains(path));
            return;
        }
        var discovered: PathList = .empty;
        try collectDefaultPackageSkills(a, io, root, manifest, home, &discovered);
        for (discovered.items) |path| try acc.add(a, path, source, true);
        return;
    }
    if (manifest.has_fields) {
        var discovered: PathList = .empty;
        try addManifestEntries(a, io, manifest.skills, root, home, &discovered);
        for (discovered.items) |path| try acc.add(a, path, source, true);
        return;
    }
    var discovered: PathList = .empty;
    try collectDefaultPackageSkills(a, io, root, manifest, home, &discovered);
    for (discovered.items) |path| try acc.add(a, path, source, true);
}

fn resolvePackagePath(a: std.mem.Allocator, pkg: PackageFilter) !?[]const u8 {
    if (starts(pkg.source, "npm:") or starts(pkg.source, "git:") or starts(pkg.source, "github:") or
        starts(pkg.source, "http:") or starts(pkg.source, "https:") or starts(pkg.source, "ssh:") or
        starts(pkg.source, "builtin:") or starts(pkg.source, "git@") or ends(pkg.source, ".git"))
    {
        return null;
    }
    return try resolve(a, pkg.base, pkg.home, pkg.source);
}

fn packageIdentity(a: std.mem.Allocator, pkg: PackageFilter) ![]const u8 {
    if (try resolvePackagePath(a, pkg)) |path| return try std.fmt.allocPrint(a, "local:{s}", .{path});
    return try std.fmt.allocPrint(a, "source:{s}", .{pkg.source});
}

fn addPackageSkills(
    a: std.mem.Allocator,
    io: std.Io,
    packages: []const PackageFilter,
    home: []const u8,
    out: *ResourceList,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    var selected: std.ArrayList(PackageFilter) = .empty;
    var identities: PathList = .empty;
    for (packages) |pkg| {
        const identity = try packageIdentity(a, pkg);
        var index: ?usize = null;
        for (identities.items, 0..) |existing, i| {
            if (eq(existing, identity)) {
                index = i;
                break;
            }
        }
        if (index) |i| {
            const existing = selected.items[i];
            if (existing.scope == .project and pkg.scope == .user) {
                if (existing.has_filter and !existing.autoload) {
                    try selected.append(a, pkg);
                    try identities.append(a, identity);
                }
            } else if (pkg.scope == .project) {
                selected.items[i] = pkg;
            }
            continue;
        }
        try selected.append(a, pkg);
        try identities.append(a, identity);
    }
    var accumulator: PackageAccumulator = .{};
    for (selected.items) |pkg| {
        if (try resolvePackagePath(a, pkg)) |path| {
            const kind = statKind(io, path) orelse continue;
            if (kind != .directory) continue;
            try collectPackageSkills(a, io, path, pkg, home, &accumulator);
        } else {
            try diagnostics.append(a, .{
                .kind = .err,
                .message = "package source requires npm or git acquisition; unsupported",
                .path = pkg.source,
            });
        }
    }
    for (accumulator.entries.items) |entry| {
        // Pi registers packages first, then orders their resources after the
        // ordinary settings and auto-discovery entries. The exact path keeps
        // its package scope and filter decision.
        if (resourceIndex(out.items, entry.path)) |index| _ = out.orderedRemove(index);
        try out.append(a, entry);
    }
}

fn addProjectSettingsResources(a: std.mem.Allocator, io: std.Io, entries: []const []const u8, base: []const u8, home: []const u8, out: *ResourceList) !void {
    const split = try splitLists(a, entries);
    var resolved: PathList = .empty;
    for (split.plain) |entry| {
        const path = try resolve(a, base, home, entry);
        try addUnique(&resolved, a, path);
    }
    var files: PathList = .empty;
    try collectFilesFromPaths(a, io, resolved.items, &files);
    const enabled = try applyPatterns(a, files.items, split.patterns, base, home);
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(a);
    for (enabled) |path| try selected.put(a, path, {});
    for (files.items) |path| try addResource(out, a, .{ .path = path, .source = .{ .scope = .project }, .enabled = selected.contains(path) });
}

fn addAutoResources(
    a: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    mode: Mode,
    entries: []const []const u8,
    base: []const u8,
    home: []const u8,
    scope: Scope,
    out: *ResourceList,
) !void {
    const found = try collect(a, io, dir, mode);
    for (found) |path| {
        const enabled = try isEnabledByOverrides(a, path, entries, base, home);
        try addResource(out, a, .{ .path = path, .source = .{ .scope = scope, .origin = .auto }, .enabled = enabled });
    }
}

fn hasGitDir(io: std.Io, dir: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ dir, ".git" }) catch return false;
    defer std.heap.page_allocator.free(path);
    return statKind(io, path) != null;
}

fn addProjectAuto(
    a: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    project_skills: []const u8,
    overrides: []const []const u8,
    out: *ResourceList,
) !void {
    try addAutoResources(a, io, project_skills, .pi, overrides, dirname(project_skills), home, .project, out);

    const home_agents = try std.fs.path.join(a, &.{ home, ".agents", "skills" });
    var git_root: ?[]const u8 = null;
    var probe = cwd;
    while (true) {
        if (hasGitDir(io, probe)) {
            git_root = probe;
            break;
        }
        const parent = dirname(probe);
        if (eq(parent, probe)) break;
        probe = parent;
    }
    var dir: []const u8 = cwd;
    while (true) {
        const agents_skills = try std.fs.path.join(a, &.{ dir, ".agents", "skills" });
        if (!eq(agents_skills, home_agents)) {
            const agents_base = dirname(agents_skills);
            try addAutoResources(a, io, agents_skills, .agents, overrides, agents_base, home, .project, out);
        }
        if (git_root) |root| if (eq(dir, root)) break;
        const parent = dirname(dir);
        if (eq(parent, dir)) break;
        dir = parent;
    }
}

fn collectRequested(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) ![]const []const u8 {
    const kind = statKind(io, path) orelse {
        try diagnostics.append(a, .{ .kind = .warning, .message = "skill path does not exist", .path = path });
        return &.{};
    };
    if (kind == .directory) return collect(a, io, path, .explicit);
    if (kind == .file and ends(path, ".md")) {
        const single = try a.alloc([]const u8, 1);
        single[0] = path;
        return single;
    }
    try diagnostics.append(a, .{ .kind = .warning, .message = "skill path is not a markdown file", .path = path });
    return &.{};
}

fn isWithin(root: []const u8, path: []const u8) bool {
    return starts(path, root) and (path.len == root.len or path[root.len] == '/');
}

fn resourceKey(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => path,
    };
}

pub fn discover(a: std.mem.Allocator, io: std.Io, opt: Options) !Result {
    const cwd = if (std.fs.path.isAbsolute(opt.cwd)) try normalizeAbs(a, opt.cwd) else blk: {
        const process_cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch "/";
        break :blk try normalizeAbs(a, try std.fs.path.join(a, &.{ process_cwd, opt.cwd }));
    };
    const home = try normalizeAbs(a, opt.home);
    const agent_dir = try normalizeAbs(a, opt.agent_dir);
    const project_root = try std.fs.path.join(a, &.{ cwd, ".pi" });
    const project_skills = try std.fs.path.join(a, &.{ project_root, "skills" });
    const agent_skills = try std.fs.path.join(a, &.{ agent_dir, "skills" });

    const project = readSettings(a, io, project_root, .project, home);
    const enable_skill_commands = opt.enable_skill_commands orelse project.enable_skill_commands orelse true;

    var discovered: ResourceList = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;

    if (!opt.no_skills or opt.explicit_paths.len != 0) {
        // Also resolve the metadata for explicit paths in --no-skills mode.
        // Only the files explicitly requested below will be loaded then.
        if (project.skills) |entries| try addProjectSettingsResources(a, io, entries, project_root, home, &discovered);
        try addProjectAuto(a, io, cwd, home, project_skills, project.skills orelse &.{}, &discovered);
        for (opt.user_paths) |raw| {
            const path = try resolve(a, cwd, home, raw);
            for (try collectRequested(a, io, path, &diagnostics)) |file|
                try addResource(&discovered, a, .{ .path = file, .source = .{ .scope = .user } });
        }
        try addAutoResources(a, io, agent_skills, .pi, &.{}, agent_dir, home, .user, &discovered);
        const home_agents = try std.fs.path.join(a, &.{ home, ".agents", "skills" });
        try addAutoResources(a, io, home_agents, .agents, &.{}, dirname(home_agents), home, .user, &discovered);

        try addPackageSkills(a, io, project.packages, home, &discovered, &diagnostics);
    }

    var resources: ResourceList = .empty;
    if (opt.no_skills) diagnostics.clearRetainingCapacity();
    // The first discovered spelling of a file owns its provenance and enabled
    // state. Record exclusions before filtering so a lower-priority symlink
    // cannot auto-discover the same file again.
    var active_by_key: std.StringHashMapUnmanaged(bool) = .empty;
    defer active_by_key.deinit(a);
    var distinct: usize = 0;
    for (discovered.items) |entry| {
        const key = try resourceKey(a, io, entry.path);
        const registration = try active_by_key.getOrPut(a, key);
        if (registration.found_existing) continue;
        const active = !opt.no_skills and entry.enabled;
        registration.value_ptr.* = active;
        discovered.items[distinct] = entry;
        distinct += 1;
        if (active) try resources.append(a, entry);
    }
    discovered.items.len = distinct;
    for (opt.explicit_paths) |raw| {
        const path = try resolve(a, cwd, home, raw);
        const fallback: Scope = if (isWithin(agent_skills, path)) .user else if (isWithin(project_skills, path)) .project else .temporary;
        for (try collectRequested(a, io, path, &diagnostics)) |file| {
            const key = try resourceKey(a, io, file);
            const registration = try active_by_key.getOrPut(a, key);
            if (registration.found_existing and registration.value_ptr.*) continue;
            registration.value_ptr.* = true;
            const source = if (resourceIndex(discovered.items, file)) |index| discovered.items[index].source else Source{ .scope = fallback };
            try resources.append(a, .{ .path = file, .source = source });
        }
    }

    return .{
        .resources = try resources.toOwnedSlice(a),
        .diagnostics = try diagnostics.toOwnedSlice(a),
        .enable_skill_commands = enable_skill_commands,
    };
}
