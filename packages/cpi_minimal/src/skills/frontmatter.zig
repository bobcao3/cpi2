const std = @import("std");
const Event = extern struct { type: c_int, plain: c_int, minor: c_int, anchor: [*c]const u8, tag: [*c]const u8, value: [*c]const u8, length: usize };
extern fn cpi_yaml_create([*]const u8, usize) ?*anyopaque;
extern fn cpi_yaml_destroy(*anyopaque) void;
extern fn cpi_yaml_next(*anyopaque, *Event) c_int;

pub const Parsed = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    disable_model_invocation: bool = false,
    body: []const u8,
};
const Kind = enum { string, boolean, number, nil, sequence, mapping, other, merge };
const Node = struct {
    kind: Kind,
    text: []const u8 = "",
    number: f64 = 0,
    boolean: bool = false,
    alias: bool = false,
    target: ?*Node = null,
    tag: []const u8 = "",
    anchored: bool = false,
    converted: bool = false,
    references: f64 = 0,
    alias_weight: f64 = 0,
    items: std.ArrayList(*Node) = .empty,
};

pub fn parse(a: std.mem.Allocator, raw: []const u8) !Parsed {
    const decoded = try decodeFile(a, raw);
    const input = if (std.mem.startsWith(u8, decoded, "\xef\xbb\xbf")) decoded[3..] else decoded;
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(a);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        try normalized.append(a, if (input[i] == '\r') '\n' else input[i]);
        if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') i += 1;
    }
    const text = try normalized.toOwnedSlice(a);
    var result: Parsed = .{ .body = text };
    if (!std.mem.startsWith(u8, text, "---")) return result;
    const end = std.mem.indexOfPos(u8, text, 3, "\n---") orelse return result;
    result.body = trimJs(text[end + 4 ..]);
    const yaml = text[@min(4, end)..end];
    if (yaml.len == 0) return result;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const terminated = if (std.mem.endsWith(u8, yaml, "\n")) yaml else try std.mem.concat(arena.allocator(), u8, &.{ yaml, "\n" });
    const root = try document(arena.allocator(), terminated) orelse return result;
    try checkAliases(arena.allocator(), root);
    if (try field(root, "name", arena.allocator())) |n| if (n.kind == .string) {
        result.name = try a.dupe(u8, n.text);
    };
    if (try field(root, "description", arena.allocator())) |n| if (n.kind == .string) {
        result.description = try a.dupe(u8, n.text);
    };
    if (try field(root, "disable-model-invocation", arena.allocator())) |n| {
        result.disable_model_invocation = n.kind == .boolean and n.boolean;
    }
    return result;
}

fn decodeFile(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const first = bytes[i];
        if (first < 0x80) {
            try out.append(a, first);
            i += 1;
            continue;
        }
        const width: usize = if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else 0;
        var accepted: usize = 1;
        while (accepted < width and i + accepted < bytes.len) {
            const byte = bytes[i + accepted];
            if (byte < 0x80 or byte > 0xbf) break;
            if (accepted == 1 and ((first == 0xe0 and byte < 0xa0) or (first == 0xed and byte > 0x9f) or (first == 0xf0 and byte < 0x90) or (first == 0xf4 and byte > 0x8f))) break;
            accepted += 1;
        }
        if (width > 0 and accepted == width) {
            try out.appendSlice(a, bytes[i..][0..width]);
        } else try out.appendSlice(a, "\xef\xbf\xbd");
        i += accepted;
    }
    return out.toOwnedSlice(a);
}

fn document(a: std.mem.Allocator, text: []const u8) !?*Node {
    const parser = cpi_yaml_create(text.ptr, text.len) orelse return error.OutOfMemory;
    defer cpi_yaml_destroy(parser);
    var stack: std.ArrayList(*Node) = .empty;
    var anchors: std.StringHashMapUnmanaged(*Node) = .empty;
    var root: ?*Node = null;
    var documents: usize = 0;
    var legacy = false;
    while (true) {
        var event: Event = undefined;
        const status = cpi_yaml_next(parser, &event);
        if (status != 1) return if (status == -1) error.OutOfMemory else error.InvalidYaml;
        var node: ?*Node = null;
        var anchor: [*c]const u8 = null;
        switch (event.type) {
            2 => return root,
            3 => {
                documents += 1;
                if (documents > 1) return error.InvalidYaml;
                legacy = event.minor == 1;
            },
            6 => {
                const s = event;
                const n = try a.create(Node);
                n.* = try scalar(a, s.value[0..s.length], tagText(s.tag), s.plain != 0, legacy);
                node = n;
                anchor = s.anchor;
            },
            9, 7 => {
                const mapping = event.type == 9;
                const n = try a.create(Node);
                n.* = .{ .kind = if (mapping) .mapping else .sequence, .tag = try a.dupe(u8, tagText(event.tag)) };
                node = n;
                anchor = event.anchor;
            },
            5 => {
                const target = anchors.get(std.mem.span(event.anchor)) orelse return error.InvalidYaml;
                const n = try a.create(Node);
                n.* = target.*;
                n.alias = true;
                n.target = target;
                node = n;
            },
            10, 8 => {
                const n = stack.pop() orelse return error.InvalidYaml;
                try validateCollection(n);
                if (n.kind == .mapping) {
                    if (n.items.items.len % 2 != 0) return error.InvalidYaml;
                    var k: usize = 0;
                    while (k < n.items.items.len) : (k += 2) {
                        var j: usize = 0;
                        while (j < k) : (j += 2) if (sameKey(n.items.items[j], n.items.items[k])) return error.InvalidYaml;
                    }
                }
            },
            else => {},
        }
        if (node) |n| {
            if (anchor != null) {
                n.anchored = true;
                try anchors.put(a, try a.dupe(u8, std.mem.span(anchor)), n);
            }
            if (stack.items.len == 0) {
                root = n;
            } else try stack.items[stack.items.len - 1].items.append(a, n);
            if (event.type == 9 or event.type == 7) try stack.append(a, n);
        }
    }
}
fn tagText(tag: [*c]const u8) []const u8 {
    return if (tag == null) "" else std.mem.span(tag);
}
fn checkAliases(a: std.mem.Allocator, root: *Node) !void {
    const Task = struct { node: *Node, mode: enum { visit, direct, alias_after, leave } = .visit };
    var tasks: std.ArrayList(Task) = .empty;
    var active: std.AutoHashMapUnmanaged(*Node, void) = .empty;
    try tasks.append(a, .{ .node = root });
    while (tasks.pop()) |task| {
        const n = task.node;
        if (task.mode == .leave) {
            _ = active.remove(n);
            continue;
        }
        if (n.alias) {
            const source = n.target.?;
            if (!source.converted) {
                try tasks.append(a, .{ .node = n, .mode = .alias_after });
                try tasks.append(a, .{ .node = source });
                continue;
            }
            source.references += 1;
            if (source.alias_weight == 0) source.alias_weight = try aliasWeight(a, source);
            if (source.references * source.alias_weight > 100) return error.InvalidYaml;
            continue;
        }
        if (task.mode == .visit and n.anchored) {
            n.converted = true;
            n.references = 1;
            n.alias_weight = 0;
        }
        if (n.kind != .mapping and n.kind != .sequence) continue;
        if (active.contains(n)) return error.InvalidYaml;
        try active.put(a, n, {});
        try tasks.append(a, .{ .node = n, .mode = .leave });
        var i = n.items.items.len;
        if (n.kind == .sequence) {
            while (i > 0) {
                i -= 1;
                try tasks.append(a, .{ .node = n.items.items[i] });
            }
        } else while (i > 0) {
            i -= 2;
            const key = n.items.items[i];
            const value = n.items.items[i + 1];
            if (key.kind == .merge and !key.alias) {
                const source = value.target orelse value;
                if (source.kind == .mapping) {
                    try tasks.append(a, .{ .node = source, .mode = .direct });
                } else {
                    var j = source.items.items.len;
                    while (j > 0) {
                        j -= 1;
                        const item = source.items.items[j];
                        try tasks.append(a, .{ .node = item.target orelse item, .mode = .direct });
                    }
                }
            } else {
                if (!std.mem.eql(u8, n.tag, "tag:yaml.org,2002:set")) try tasks.append(a, .{ .node = value });
                try tasks.append(a, .{ .node = key });
            }
        }
    }
}
fn aliasWeight(a: std.mem.Allocator, root: *Node) !f64 {
    var pending: std.ArrayList(*Node) = .empty;
    try pending.append(a, root);
    var result: f64 = 0;
    while (pending.pop()) |n| {
        if (n.alias) {
            const source = n.target.?;
            if (source.converted) result = @max(result, source.references * source.alias_weight);
        } else if (n.kind == .mapping or n.kind == .sequence) {
            try pending.appendSlice(a, n.items.items);
        } else result = @max(result, 1);
    }
    return result;
}
fn validateCollection(n: *Node) !void {
    if (n.kind == .mapping) {
        var i: usize = 0;
        while (i + 1 < n.items.items.len) : (i += 2) {
            const value = n.items.items[i + 1].target orelse n.items.items[i + 1];
            if (std.mem.eql(u8, n.tag, "tag:yaml.org,2002:set") and value.kind != .nil) return error.InvalidYaml;
            if (n.items.items[i].kind == .merge) {
                if (value.kind == .sequence) {
                    for (value.items.items) |item| if ((item.target orelse item).kind != .mapping) return error.InvalidYaml;
                } else if (value.kind != .mapping) return error.InvalidYaml;
            }
        }
    }
    if (n.kind == .sequence and oneOf(n.tag, &.{ "tag:yaml.org,2002:pairs", "tag:yaml.org,2002:omap" })) {
        for (n.items.items, 0..) |item, i| {
            if (item.kind == .mapping and item.items.items.len > 2) return error.InvalidYaml;
            if (std.mem.eql(u8, n.tag, "tag:yaml.org,2002:omap")) {
                const key = if (item.kind == .mapping and item.items.items.len > 0) item.items.items[0] else item;
                for (n.items.items[0..i]) |previous| {
                    const old = if (previous.kind == .mapping and previous.items.items.len > 0) previous.items.items[0] else previous;
                    if (sameKey(old, key) or (old.kind == .number and key.kind == .number and std.math.isNan(old.number) and std.math.isNan(key.number))) return error.InvalidYaml;
                }
            }
        }
    }
}
fn timestamp(s: []const u8) bool {
    var i: usize = 0;
    if (!dateDigits(s, &i, 4, 4) or !take(s, &i, '-') or !dateDigits(s, &i, 1, 2) or !take(s, &i, '-') or !dateDigits(s, &i, 1, 2)) return false;
    if (i == s.len) return true;
    if (s[i] == 't' or s[i] == 'T') {
        i += 1;
    } else {
        const start = i;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i == start) return false;
    }
    if (!dateDigits(s, &i, 1, 2) or !take(s, &i, ':') or !dateDigits(s, &i, 1, 2) or !take(s, &i, ':') or !dateDigits(s, &i, 1, 2)) return false;
    if (take(s, &i, '.') and !dateDigits(s, &i, 1, s.len)) return false;
    if (i == s.len) return true;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (take(s, &i, 'Z')) return i == s.len;
    if (!take(s, &i, '+') and !take(s, &i, '-')) return false;
    const start = i;
    if (!dateDigits(s, &i, 1, 2)) return false;
    if (i - start == 2 and s[start] > '2') return false;
    if (take(s, &i, ':') and !dateDigits(s, &i, 2, 2)) return false;
    return i == s.len;
}
fn dateDigits(s: []const u8, i: *usize, min: usize, max: usize) bool {
    const start = i.*;
    while (i.* < s.len and i.* - start < max and std.ascii.isDigit(s[i.*])) : (i.* += 1) {}
    return i.* - start >= min;
}
fn take(s: []const u8, i: *usize, char: u8) bool {
    if (i.* == s.len or s[i.*] != char) return false;
    i.* += 1;
    return true;
}
fn sameKey(x: *Node, y: *Node) bool {
    if (x.alias or y.alias or x.kind != y.kind) return false;
    return switch (x.kind) {
        .string => std.mem.eql(u8, x.text, y.text),
        .boolean => x.boolean == y.boolean,
        .number => x.number == y.number,
        .nil => true,
        else => false,
    };
}
fn field(root: *Node, key: []const u8, a: std.mem.Allocator) !?*Node {
    var pending: std.ArrayList(*Node) = .empty;
    var seen: std.AutoHashMapUnmanaged(*Node, void) = .empty;
    try pending.append(a, root);
    while (pending.pop()) |n| {
        const resolved = n.target orelse n;
        if (resolved != n) {
            try pending.append(a, resolved);
            continue;
        }
        if (seen.contains(n)) continue;
        try seen.put(a, n, {});
        if (n.kind != .mapping or std.mem.eql(u8, n.tag, "tag:yaml.org,2002:set")) continue;
        var i = n.items.items.len;
        while (i > 0) {
            i -= 2;
            const k = n.items.items[i].target orelse n.items.items[i];
            if (k.kind == .string and std.mem.eql(u8, k.text, key)) return n.items.items[i + 1].target orelse n.items.items[i + 1];
        }
        i = n.items.items.len;
        while (i > 0) {
            i -= 2;
            if (n.items.items[i].kind != .merge) continue;
            const m = n.items.items[i + 1].target orelse n.items.items[i + 1];
            if (m.kind == .mapping) {
                try pending.append(a, m);
            } else if (m.kind == .sequence) {
                var j = m.items.items.len;
                while (j > 0) {
                    j -= 1;
                    if (m.items.items[j].kind != .mapping) return error.InvalidYaml;
                    try pending.append(a, m.items.items[j]);
                }
            } else return error.InvalidYaml;
        }
    }
    return null;
}
fn oneOf(s: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, s, choice)) return true;
    return false;
}
fn scalar(a: std.mem.Allocator, s: []const u8, tag: []const u8, plain: bool, legacy: bool) !Node {
    var n: Node = .{ .kind = .string, .text = try a.dupe(u8, s) };
    const explicit = tag.len != 0;
    const prefix = "tag:yaml.org,2002:";
    const t = if (std.mem.startsWith(u8, tag, prefix)) tag[prefix.len..] else tag;
    if ((!plain and !explicit) or oneOf(t, &.{ "!", "str" })) return n;
    if (explicit and !oneOf(t, &.{ "bool", "int", "float", "null", "merge", "timestamp", "binary" })) return n;
    if ((!explicit or std.mem.eql(u8, t, "null")) and oneOf(s, &.{ "", "~", "null", "Null", "NULL" })) {
        n.kind = .nil;
        return n;
    }
    const yes = oneOf(s, &.{ "true", "True", "TRUE" }) or (legacy and oneOf(s, &.{ "y", "Y", "yes", "Yes", "YES", "on", "On", "ON" }));
    const no = oneOf(s, &.{ "false", "False", "FALSE" }) or (legacy and oneOf(s, &.{ "n", "N", "no", "No", "NO", "off", "Off", "OFF" }));
    if ((!explicit or std.mem.eql(u8, t, "bool")) and (yes or no)) {
        n.kind = .boolean;
        n.boolean = yes;
        return n;
    }
    if ((legacy and !explicit and std.mem.eql(u8, s, "<<")) or std.mem.eql(u8, t, "merge")) {
        n.kind = .merge;
        return n;
    }
    if (!explicit or oneOf(t, &.{ "int", "float" })) {
        if (try number(a, s, legacy, if (explicit) t else "")) |v| {
            n.kind = .number;
            n.number = v;
            return n;
        }
    }
    if (std.mem.eql(u8, t, "binary")) {
        n.kind = .other;
        return n;
    }
    if (std.mem.eql(u8, t, "timestamp")) {
        if (!timestamp(s)) return error.InvalidYaml;
        n.kind = .other;
    } else if (legacy and timestamp(s)) n.kind = .other;
    return n;
}
fn digits(s: []const u8, base: u8, underscore: bool) bool {
    if (s.len == 0) return false;
    for (s) |v| {
        if (v == '_' and underscore) continue;
        const d = std.fmt.charToDigit(v, base) catch return false;
        _ = d;
    }
    return true;
}
fn number(a: std.mem.Allocator, raw: []const u8, legacy: bool, tag: []const u8) !?f64 {
    if (raw.len == 0) return null;
    const sign: f64 = if (raw[0] == '-') -1 else 1;
    const s = if (raw[0] == '-' or raw[0] == '+') raw[1..] else raw;
    if (!std.mem.eql(u8, tag, "int")) {
        if (oneOf(s, &.{ ".inf", ".Inf", ".INF" })) return sign * std.math.inf(f64);
        if (oneOf(raw, &.{ ".nan", ".NaN", ".NAN" })) return std.math.nan(f64);
    }
    var base: u8 = 10;
    var offset: usize = 0;
    if (std.mem.startsWith(u8, s, "0x") and (legacy or s.len == raw.len)) {
        base = 16;
        offset = 2;
    }
    if (std.mem.startsWith(u8, s, "0o") and !legacy and s.len == raw.len) {
        base = 8;
        offset = 2;
    }
    if (legacy and std.mem.startsWith(u8, s, "0b")) {
        base = 2;
        offset = 2;
    }
    if (legacy and s.len > 1 and s[0] == '0' and digits(s[1..], 8, true)) {
        base = 8;
        offset = 1;
    }
    if (!std.mem.eql(u8, tag, "float") and digits(s[offset..], base, legacy)) {
        var value: f64 = 0;
        for (s[offset..]) |v| {
            if (v == '_') continue;
            value = value * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(std.fmt.charToDigit(v, base) catch unreachable));
        }
        return sign * value;
    }
    if (base != 10 or std.mem.eql(u8, tag, "int")) return null;
    var clean: std.ArrayList(u8) = .empty;
    for (raw) |v| {
        if (v == '_' and legacy) continue;
        try clean.append(a, v);
    }
    const f = clean.items;
    var i: usize = if (f.len > 0 and (f[0] == '-' or f[0] == '+')) 1 else 0;
    const start = i;
    while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) {}
    var count = i - start;
    var dot = false;
    if (i < f.len and f[i] == '.') {
        dot = true;
        i += 1;
        const begin = i;
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) {}
        count += i - begin;
    }
    var exp = false;
    if (i < f.len and (f[i] == 'e' or f[i] == 'E')) {
        exp = true;
        i += 1;
        if (i < f.len and (f[i] == '-' or f[i] == '+')) i += 1;
        const begin = i;
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) {}
        if (begin == i) return null;
    }
    if (i != f.len or (!dot and !exp) or (count == 0 and !legacy)) return null;
    return std.fmt.parseFloat(f64, f) catch std.math.nan(f64);
}
fn trimJs(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end) {
        const len = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + len > end) break;
        const cp = std.unicode.utf8Decode(s[start..][0..len]) catch break;
        if (!jsSpace(cp)) break;
        start += len;
    }
    while (end > start) {
        var pos = end - 1;
        while (pos > start and s[pos] & 0xc0 == 0x80) : (pos -= 1) {}
        const cp = std.unicode.utf8Decode(s[pos..end]) catch break;
        if (!jsSpace(cp)) break;
        end = pos;
    }
    return s[start..end];
}
fn jsSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}
