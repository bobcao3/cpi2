const std = @import("std");
const Theme = @import("Theme.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const tree_sitter = @import("tree_sitter");
const ts = tree_sitter.api;
const Grammar = tree_sitter.Grammar;
const Digest = [32]u8;
const CacheEntry = struct { key: Digest, text: []const u8 };
const max_input_bytes = 1024 * 1024;
const max_cache_entry_bytes = 128 * 1024;

/// The parser and queries belong to the interactive display. Results returned by paint are
/// owned by the caller's frame arena, independent of cache eviction.
pub const Engine = struct {
    allocator: Allocator,
    styles: ScopeStyles,
    parser: ?*ts.TSParser = null,
    cursor: ?*ts.TSQueryCursor = null,
    queries: std.EnumSet(Grammar) = .{},
    programs: [std.enums.values(Grammar).len]?*ts.TSQuery = @splat(null),
    palette: *const Theme.Palette = &.{},
    cache: [24]?CacheEntry = @splat(null),
    next_slot: usize = 0,

    pub fn deinit(self: *Engine) void {
        self.clearCache();
        if (self.cursor) |cursor| ts.ts_query_cursor_delete(cursor);
        if (self.parser) |parser| ts.ts_parser_delete(parser);
        for (self.programs) |program| if (program) |value| ts.ts_query_delete(value);
    }

    pub fn clearCache(self: *Engine) void {
        for (&self.cache) |*item| {
            if (item.*) |saved| self.allocator.free(saved.text);
            item.* = null;
        }
        self.next_slot = 0;
    }

    pub fn paint(self: *Engine, a: Allocator, code: []const u8, language: ?[]const u8) ![]const u8 {
        if (code.len == 0) return "";
        const lang = language orelse return plain(a, self.palette, code);
        if (lang.len == 0 or lang.len > 128 or code.len > max_input_bytes) return plain(a, self.palette, code);
        const grammar = resolveLanguage(lang) orelse return plain(a, self.palette, code);
        const key = digest(code, @tagName(grammar));
        for (self.cache) |item| if (item) |saved| {
            if (std.mem.eql(u8, &saved.key, &key)) return a.dupe(u8, saved.text);
        };
        const styled = try self.paintUncached(a, code, grammar);
        if (styled.len <= max_cache_entry_bytes) {
            if (self.allocator.dupe(u8, styled)) |copy| {
                const slot = &self.cache[self.next_slot];
                if (slot.*) |saved| self.allocator.free(saved.text);
                slot.* = .{ .key = key, .text = copy };
                self.next_slot = (self.next_slot + 1) % self.cache.len;
            } else |_| {}
        }
        return styled;
    }

    fn paintUncached(self: *Engine, a: Allocator, code: []const u8, grammar: Grammar) ![]const u8 {
        const program = self.query(grammar) orelse return plain(a, self.palette, code);
        const parser = self.parser orelse created: {
            const value = ts.ts_parser_new() orelse return error.OutOfMemory;
            ts.ts_parser_set_timeout_micros(value, 35_000);
            self.parser = value;
            break :created value;
        };
        if (!ts.ts_parser_set_language(parser, grammar.language())) return plain(a, self.palette, code);
        ts.ts_parser_reset(parser);
        const tree = ts.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return plain(a, self.palette, code);
        defer ts.ts_tree_delete(tree);

        const cursor = self.cursor orelse created: {
            const value = ts.ts_query_cursor_new() orelse return error.OutOfMemory;
            ts.ts_query_cursor_set_timeout_micros(value, 35_000);
            ts.ts_query_cursor_set_match_limit(value, 2048);
            self.cursor = value;
            break :created value;
        };
        ts.ts_query_cursor_exec(cursor, program, ts.ts_tree_root_node(tree));
        return paintCaptures(a, self, program, cursor, code);
    }

    fn query(self: *Engine, grammar: Grammar) ?*ts.TSQuery {
        const index = @backingInt(grammar);
        if (self.queries.contains(grammar)) return self.programs[index];
        self.queries.insert(grammar);
        const rules = grammar.highlights();
        var offset: u32 = 0;
        var reason: ts.TSQueryError = undefined;
        self.programs[index] = ts.ts_query_new(grammar.language(), rules.ptr, @intCast(rules.len), &offset, &reason);
        return self.programs[index];
    }
};

fn digest(code: []const u8, language: []const u8) Digest {
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(&.{@intCast(language.len)});
    hash.update(language);
    hash.update(code);
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

pub const ScopeStyles = std.json.ArrayHashMap(Style);

const Style = enum {
    text,
    muted,
    syntaxKeyword,
    syntaxNumber,
    syntaxString,
    syntaxFunction,
    syntaxVariable,
    syntaxComment,
    syntaxType,
    syntaxOperator,
    syntaxPunctuation,
    toolDiffAdded,
    toolDiffRemoved,
    mdCodeBlock,
    italic,
    bold,
    underline,

    fn sgr(self: Style, palette: *const Theme.Palette, bytes: *[96]u8) []const u8 {
        const style = switch (self) {
            .italic => @import("kit").tui.Style{ .italic = true },
            .bold => @import("kit").tui.Style{ .bold = true },
            .underline => @import("kit").tui.Style{ .underline = true },
            inline else => |role| palette.style(@field(Theme.Role, @tagName(role))),
        };
        return style.sgr(bytes);
    }
};

fn scopeStyle(styles: ScopeStyles, scope: []const u8) ?Style {
    if (styles.map.get(scope)) |style| return style;
    if (std.mem.indexOfScalar(u8, scope, '.')) |at| if (styles.map.get(scope[0..at])) |style| return style;
    if (std.mem.indexOfScalar(u8, scope, '-')) |at| return styles.map.get(scope[0..at]);
    return null;
}

const Span = struct {
    first: u32,
    last: u32,
    pattern: u16,
    style: Style,

    fn startBefore(_: void, x: Span, y: Span) bool {
        return x.first < y.first;
    }

    fn rank(_: void, x: Span, y: Span) std.math.Order {
        const length = std.math.order(x.last - x.first, y.last - y.first);
        return if (length == .eq) std.math.order(y.pattern, x.pattern) else length;
    }
};

fn paintCaptures(a: Allocator, engine: *const Engine, query: *ts.TSQuery, cursor: *ts.TSQueryCursor, source: []const u8) ![]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    const capture_styles = try temp.alloc(?Style, ts.ts_query_capture_count(query));
    for (capture_styles, 0..) |*style, i| {
        var length: u32 = 0;
        const name = ts.ts_query_capture_name_for_id(query, @intCast(i), &length);
        style.* = scopeStyle(engine.styles, name[0..length]);
    }

    var captured: std.ArrayList(Span) = .empty;
    var match: ts.TSQueryMatch = undefined;
    while (ts.ts_query_cursor_next_match(cursor, &match) and captured.items.len < 200_000) {
        if (!accepts(query, match, source)) continue;
        for (match.captures[0..match.capture_count]) |capture| {
            const first = ts.ts_node_start_byte(capture.node);
            const last = ts.ts_node_end_byte(capture.node);
            if (first == last or last > source.len) continue;
            const style = capture_styles[capture.index] orelse continue;
            try captured.append(temp, .{ .first = first, .last = last, .pattern = match.pattern_index, .style = style });
        }
    }
    if (captured.items.len == 0) return plain(a, engine.palette, source);
    std.mem.sort(Span, captured.items, {}, Span.startBefore);

    var active: std.PriorityQueue(Span, void, Span.rank) = .empty;
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    var offset: u32 = 0;
    var index: usize = 0;
    while (offset < source.len) {
        while (active.peek()) |span| {
            if (span.last > offset) break;
            _ = active.pop();
        }
        while (index < captured.items.len and captured.items[index].first == offset) : (index += 1)
            try active.push(temp, captured.items[index]);
        const next_start = if (index < captured.items.len) captured.items[index].first else @as(u32, @intCast(source.len));
        const span = active.peek() orelse Span{ .first = 0, .last = next_start, .pattern = 0, .style = .text };
        const end = @min(span.last, next_start);
        try appendLines(&output.writer, engine.palette, source[offset..end], span.style);
        offset = end;
    }
    return output.toOwnedSlice();
}

fn literal(query: *ts.TSQuery, step: ts.TSQueryPredicateStep) []const u8 {
    var length: u32 = 0;
    const value = ts.ts_query_string_value_for_id(query, step.value_id, &length);
    return value[0..length];
}

fn capturedText(match: ts.TSQueryMatch, step: ts.TSQueryPredicateStep, source: []const u8) ?[]const u8 {
    for (match.captures[0..match.capture_count]) |capture| if (capture.index == step.value_id) {
        const first = ts.ts_node_start_byte(capture.node);
        const last = ts.ts_node_end_byte(capture.node);
        return if (last <= source.len) source[first..last] else null;
    };
    return null;
}

fn accepts(query: *ts.TSQuery, match: ts.TSQueryMatch, source: []const u8) bool {
    var length: u32 = 0;
    const raw = ts.ts_query_predicates_for_pattern(query, match.pattern_index, &length);
    if (length == 0) return true;
    var predicates = raw[0..length];
    while (predicates.len != 0) {
        const end = for (predicates, 0..) |step, i| {
            if (step.type == ts.TSQueryPredicateStepTypeDone) break i;
        } else return false;
        const args = predicates[0..end];
        predicates = predicates[end + 1 ..];
        if (args.len == 0 or args[0].type != ts.TSQueryPredicateStepTypeString) return false;
        const op = literal(query, args[0]);
        // Viewport highlighting is lexical. Query metadata does not execute code.
        if (oneOf(op, &.{ "set!", "is-not?" })) continue;
        if (args.len < 3 or args[1].type != ts.TSQueryPredicateStepTypeCapture) return false;
        const left = capturedText(match, args[1], source) orelse return false;
        if (std.mem.eql(u8, op, "any-of?")) {
            for (args[2..]) |value| {
                if (value.type == ts.TSQueryPredicateStepTypeString and std.mem.eql(u8, left, literal(query, value))) break;
            } else return false;
            continue;
        }
        const right = if (args[2].type == ts.TSQueryPredicateStepTypeString) literal(query, args[2]) else capturedText(match, args[2], source) orelse return false;
        if (std.mem.eql(u8, op, "eq?")) {
            if (!std.mem.eql(u8, left, right)) return false;
        } else if (oneOf(op, &.{ "match?", "lua-match?" })) {
            if (!matchesPattern(right, left)) return false;
        } else return false;
    }
    return true;
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

// The bundled upstream queries use anchored ASCII classes and literal alternatives.
// Reject other pattern forms rather than treating a conditional capture as unconditional.
fn matchesPattern(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0 or pattern[0] != '^') return false;
    const body = pattern[1..];
    if (std.mem.indexOfScalar(u8, body, '(')) |open| {
        const end = std.mem.indexOfScalarPos(u8, body, open + 1, ')') orelse return false;
        if (!std.mem.startsWith(u8, text, body[0..open])) return false;
        var options = std.mem.splitScalar(u8, body[open + 1 .. end], '|');
        while (options.next()) |option| {
            const rest = text[open..];
            if (std.mem.startsWith(u8, rest, option) and matchesAtoms(body[end + 1 ..], rest[option.len..])) return true;
        }
        return false;
    }
    return matchesAtoms(body, text);
}

fn matchesAtoms(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[0] == '$') return text.len == 0 and pattern.len == 1;

    const end = if (pattern[0] == '[')
        (std.mem.indexOfScalar(u8, pattern, ']') orelse return false) + 1
    else
        1;
    const atom = pattern[0..end];
    if (end == pattern.len or !oneOf(pattern[end .. end + 1], &.{ "*", "+", "?" }))
        return text.len > 0 and matchesAtom(atom, text[0]) and matchesAtoms(pattern[end..], text[1..]);

    const quantifier = pattern[end];
    var count: usize = 0;
    while (count < text.len and matchesAtom(atom, text[count]) and (quantifier != '?' or count == 0)) : (count += 1) {}
    const minimum: usize = @intFromBool(quantifier == '+');
    while (count >= minimum) {
        if (matchesAtoms(pattern[end + 1 ..], text[count..])) return true;
        if (count == minimum) break;
        count -= 1;
    }
    return false;
}

fn matchesAtom(atom: []const u8, byte: u8) bool {
    if (atom[0] != '[') return byte == atom[0];
    var set = atom[1 .. atom.len - 1];
    while (set.len != 0) {
        if (set.len >= 2 and set[0] == '\\' and set[1] == 'd') {
            if (std.ascii.isDigit(byte)) return true;
            set = set[2..];
        } else if (set.len >= 3 and set[1] == '-') {
            if (set[0] <= byte and byte <= set[2]) return true;
            set = set[3..];
        } else {
            if (set[0] == byte) return true;
            set = set[1..];
        }
    }
    return false;
}

fn plain(a: Allocator, palette: *const Theme.Palette, code: []const u8) ![]const u8 {
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    try appendLines(&output.writer, palette, code, .mdCodeBlock);
    return output.toOwnedSlice();
}

fn appendLines(writer: *Writer, palette: *const Theme.Palette, text: []const u8, style: Style) !void {
    var buffer: [96]u8 = undefined;
    const sgr = style.sgr(palette, &buffer);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) {
            if (sgr.len != 0) try writer.writeAll(sgr);
            try writer.writeAll(line);
            if (sgr.len != 0) try writer.writeAll("\x1b[0m");
        }
        if (lines.index != null) try writer.writeByte('\n');
    }
}

const path_languages = std.StaticStringMap([]const u8).initComptime(.{
    .{ "ts", "typescript" },         .{ "tsx", "tsx" },
    .{ "js", "javascript" },         .{ "jsx", "javascript" },
    .{ "mjs", "javascript" },        .{ "cjs", "javascript" },
    .{ "py", "python" },             .{ "rb", "ruby" },
    .{ "rs", "rust" },               .{ "go", "go" },
    .{ "java", "java" },             .{ "kt", "kotlin" },
    .{ "swift", "swift" },           .{ "dart", "dart" },
    .{ "groovy", "groovy" },         .{ "gradle", "groovy" },
    .{ "nix", "nix" },               .{ "c", "c" },
    .{ "h", "c" },                   .{ "cpp", "cpp" },
    .{ "cc", "cpp" },                .{ "cxx", "cpp" },
    .{ "hpp", "cpp" },               .{ "cs", "csharp" },
    .{ "php", "php" },               .{ "sh", "bash" },
    .{ "bash", "bash" },             .{ "zsh", "bash" },
    .{ "fish", "fish" },             .{ "ps1", "powershell" },
    .{ "sql", "sql" },               .{ "html", "html" },
    .{ "htm", "html" },              .{ "css", "css" },
    .{ "scss", "scss" },             .{ "sass", "sass" },
    .{ "less", "less" },             .{ "json", "json" },
    .{ "yaml", "yaml" },             .{ "yml", "yaml" },
    .{ "toml", "toml" },             .{ "xml", "xml" },
    .{ "md", "markdown" },           .{ "markdown", "markdown" },
    .{ "dockerfile", "dockerfile" }, .{ "makefile", "makefile" },
    .{ "cmake", "cmake" },           .{ "lua", "lua" },
    .{ "luau", "lua" },              .{ "zig", "zig" },
    .{ "perl", "perl" },             .{ "r", "r" },
    .{ "scala", "scala" },           .{ "clj", "clojure" },
    .{ "ex", "elixir" },             .{ "exs", "elixir" },
    .{ "erl", "erlang" },            .{ "hs", "haskell" },
    .{ "ml", "ocaml" },              .{ "vim", "vim" },
    .{ "graphql", "graphql" },       .{ "proto", "protobuf" },
    .{ "tf", "hcl" },                .{ "hcl", "hcl" },
});

fn resolveLanguage(name: []const u8) ?Grammar {
    var buffer: [128]u8 = undefined;
    const lower = std.ascii.lowerString(&buffer, name);
    const language = path_languages.get(lower) orelse lower;
    return std.meta.stringToEnum(Grammar, language) orelse
        (if (std.mem.eql(u8, language, "csharp") or std.mem.eql(u8, language, "cs")) .c_sharp else null);
}

pub fn languageForPath(path: []const u8) ?[]const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| dot + 1 else 0;
    const extension = path[start..];
    var buffer: [16]u8 = undefined;
    if (extension.len > buffer.len) return null;
    return path_languages.get(std.ascii.lowerString(&buffer, extension));
}

/// Pi re-lexes the first 50 lines together while arguments are arriving.
/// Beyond that prefix, only the changed final line and newly received lines
/// are re-lexed, each on its own. The finished arguments are painted in full.
pub const WriteCache = struct {
    entry: ?Entry = null,

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        path: []const u8,
        raw: []const u8,
        source: []const u8,
        styled: []const u8,
    };

    pub fn deinit(self: *WriteCache) void {
        if (self.entry) |*entry| entry.arena.deinit();
        self.entry = null;
    }

    pub fn paint(self: *WriteCache, engine: *Engine, a: Allocator, path: []const u8, language: []const u8, raw: []const u8, source: []const u8) ![]const u8 {
        if (raw.len > max_input_bytes or source.len > max_input_bytes) return engine.paint(a, source, language);
        const styled = styled: {
            if (self.entry) |*old| {
                if (std.mem.eql(u8, old.path, path) and std.mem.startsWith(u8, raw, old.raw) and std.mem.startsWith(u8, source, old.source)) {
                    if (raw.len == old.raw.len) return a.dupe(u8, old.styled);
                    break :styled try paintAppend(engine, a, language, source, old.source, old.styled);
                }
            }
            break :styled try engine.paint(a, source, language);
        };
        var arena: std.heap.ArenaAllocator = .init(engine.allocator);
        errdefer arena.deinit();
        const keep = arena.allocator();
        const saved_path = try keep.dupe(u8, path);
        const saved_raw = try keep.dupe(u8, raw);
        const saved_source = try keep.dupe(u8, source);
        const saved_styled = try keep.dupe(u8, styled);
        self.deinit();
        self.entry = .{ .arena = arena, .path = saved_path, .raw = saved_raw, .source = saved_source, .styled = saved_styled };
        return styled;
    }

    fn paintAppend(engine: *Engine, a: Allocator, language: []const u8, source: []const u8, old_source: []const u8, old_styled: []const u8) ![]const u8 {
        var input_lines = std.mem.splitScalar(u8, source, '\n');
        var old_lines = std.mem.splitScalar(u8, old_styled, '\n');
        var prefix_count: usize = 0;
        while (prefix_count < 50 and input_lines.next() != null) : (prefix_count += 1) _ = old_lines.next();
        const prefix_end = if (input_lines.index) |next| next - 1 else source.len;
        const prefix = try engine.paint(a, source[0..prefix_end], language);
        if (input_lines.index == null) return prefix;

        const old_stable_rows = std.mem.count(u8, old_source, "\n");
        var result: Writer.Allocating = .init(a);
        defer result.deinit();
        try result.writer.writeAll(prefix);
        var index = prefix_count;
        while (input_lines.next()) |line| : (index += 1) {
            try result.writer.writeByte('\n');
            const display = if (index < old_stable_rows)
                old_lines.next() orelse return engine.paint(a, source, language)
            else
                try engine.paint(a, line, language);
            try result.writer.writeAll(display);
        }
        return result.toOwnedSlice();
    }
};
