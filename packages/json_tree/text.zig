//! Complete-input JSON parsing with Kit tokens and Zig's typed deserializer.
const std = @import("std");
const Tokenizer = @import("kit").json.Tokenizer;
const Allocator = std.mem.Allocator;
const Token = std.json.Token;
const ParseOptions = std.json.ParseOptions;

pub fn parseFromSlice(comptime T: type, a: Allocator, input: []const u8, options: ParseOptions) ParseError!std.json.Parsed(T) {
    const arena = try a.create(std.heap.ArenaAllocator);
    errdefer a.destroy(arena);
    arena.* = .init(a);
    errdefer arena.deinit();
    return .{ .arena = arena, .value = try parseFromSliceLeaky(T, arena.allocator(), input, options) };
}

pub fn parseFromSliceLeaky(comptime T: type, a: Allocator, input: []const u8, options: ParseOptions) ParseError!T {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, a);
    var window: Source.Window = .{};
    var source = Source.init(input, &window, scratch.allocator());
    defer source.deinit();
    return parseFromSourceLeaky(T, a, &source, options);
}

pub const ParseError = std.json.ParseError(Source);

/// Check the same grammar and decoded-key uniqueness as the default Value
/// decoder while borrowing text and discarding scalar tokens.
pub fn validate(a: Allocator, input: []const u8) ParseError!void {
    const Object = struct {
        first: ?[]const u8 = null,
        rest: std.StringHashMapUnmanaged(void) = .empty,
    };
    var buffer: [2048]u8 = undefined;
    var local = std.heap.BufferFirstAllocator.init(&buffer, a);
    const scratch = local.allocator();
    var keys: std.heap.ArenaAllocator = .init(scratch);
    defer keys.deinit();
    var objects: std.ArrayList(Object) = .empty;
    defer {
        for (objects.items) |*object| object.rest.deinit(scratch);
        objects.deinit(scratch);
    }
    var window: Source.Window = .{};
    var source = Source.init(input, &window, scratch);
    defer source.deinit();
    while (try source.take()) |token| switch (token.tag) {
        .object_begin => try objects.append(scratch, .{}),
        .object_end => {
            var object = objects.pop().?;
            object.rest.deinit(scratch);
        },
        .string, .escaped_string => {
            const span = input[token.start..token.end];
            if (source.state != .object_colon) {
                if (token.tag == .escaped_string) try validateSurrogates(span);
                continue;
            }
            const key = if (token.tag == .string) span else blk: {
                const decoded = try keys.allocator().alloc(u8, span.len);
                break :blk decoded[0..try unescape(span, decoded)];
            };
            const object = &objects.items[objects.items.len - 1];
            if (object.first) |first| {
                if (std.mem.eql(u8, first, key) or (try object.rest.getOrPut(scratch, key)).found_existing) return error.DuplicateField;
            } else object.first = key;
        },
        else => {},
    };
}

pub fn parseFromSourceLeaky(comptime T: type, a: Allocator, source: *Source, options: ParseOptions) ParseError!T {
    var resolved = options;
    resolved.allocate = options.allocate orelse .alloc_if_needed;
    resolved.max_value_len = options.max_value_len orelse source.input.len;
    const value = try std.json.innerParse(T, a, source, resolved);
    if (try source.peekNextTokenType() != .end_of_document) return error.SyntaxError;
    return value;
}

/// Adds document grammar to Kit's lexical tokens. Only container return states
/// need stack space. Text spans borrow the complete input.
pub const Source = struct {
    pub const Window = Tokenizer.Window;
    pub const NextError = Allocator.Error || error{ SyntaxError, UnexpectedEndOfInput, UnexpectedToken, JsonDepthLimit };
    pub const PeekError = NextError;
    pub const AllocError = NextError || error{ValueTooLong};

    const State = enum {
        value,
        done,
        array_first,
        array_after,
        object_first,
        object_key,
        object_colon,
        object_after,
    };

    input: []const u8,
    tokenizer: Tokenizer,
    scratch: Allocator,
    stack: std.ArrayList(State) = .empty,
    state: State = .value,
    after_value: State = .done,
    lookahead: ?Tokenizer.Token = null,
    max_depth: ?usize = null,
    peak_depth: usize = 0,

    pub fn init(input: []const u8, window: *Window, scratch: Allocator) Source {
        return .{ .input = input, .tokenizer = Tokenizer.init(input, window), .scratch = scratch };
    }

    pub fn deinit(self: *Source) void {
        self.stack.deinit(self.scratch);
    }

    fn read(self: *Source) NextError!?Tokenizer.Token {
        while (true) {
            const token = (self.tokenizer.next() catch |err| return switch (err) {
                error.UnterminatedString => error.UnexpectedEndOfInput,
                else => error.SyntaxError,
            }) orelse {
                if (self.state == .done) return null;
                return error.UnexpectedEndOfInput;
            };
            switch (self.state) {
                .done => return error.SyntaxError,
                .array_after => {
                    if (token.tag == .array_end) return self.close(token);
                    if (token.tag != .comma) return error.SyntaxError;
                    self.state = .value;
                    self.after_value = .array_after;
                    continue;
                },
                .object_after => {
                    if (token.tag == .object_end) return self.close(token);
                    if (token.tag != .comma) return error.SyntaxError;
                    self.state = .object_key;
                    continue;
                },
                .object_first, .object_key => {
                    if (self.state == .object_first and token.tag == .object_end) return self.close(token);
                    if (!isString(token)) return error.SyntaxError;
                    self.state = .object_colon;
                    return token;
                },
                .object_colon => {
                    if (token.tag != .colon) return error.SyntaxError;
                    self.state = .value;
                    self.after_value = .object_after;
                    continue;
                },
                .array_first => {
                    if (token.tag == .array_end) return self.close(token);
                    self.after_value = .array_after;
                },
                .value => {},
            }

            switch (token.tag) {
                .object_begin, .array_begin => {
                    if (self.max_depth) |limit| {
                        if (self.stack.items.len >= limit) return error.JsonDepthLimit;
                    }
                    try self.stack.append(self.scratch, self.after_value);
                    self.peak_depth = @max(self.peak_depth, self.stack.items.len);
                    self.state = if (token.tag == .object_begin) .object_first else .array_first;
                },
                .object_end, .array_end, .colon, .comma => return error.SyntaxError,
                else => self.state = self.after_value,
            }
            return token;
        }
    }

    fn close(self: *Source, token: Tokenizer.Token) Tokenizer.Token {
        self.state = self.stack.pop().?;
        return token;
    }

    fn take(self: *Source) NextError!?Tokenizer.Token {
        if (self.lookahead) |token| {
            self.lookahead = null;
            return token;
        }
        return self.read();
    }

    fn isString(token: Tokenizer.Token) bool {
        return token.tag == .string or token.tag == .escaped_string;
    }

    fn asToken(self: *Source, token: Tokenizer.Token) Token {
        return switch (token.tag) {
            .object_begin => .object_begin,
            .object_end => .object_end,
            .array_begin => .array_begin,
            .array_end => .array_end,
            .true => .true,
            .false => .false,
            .null => .null,
            .string => .{ .string = self.input[token.start..token.end] },
            .number => .{ .number = self.input[token.start..token.end] },
            .escaped_string, .colon, .comma => unreachable,
        };
    }

    pub fn peekNextTokenType(self: *Source) PeekError!std.json.TokenType {
        if (self.lookahead == null) self.lookahead = try self.read();
        const token = self.lookahead orelse return .end_of_document;
        return switch (token.tag) {
            .string, .escaped_string => .string,
            .number => .number,
            .true => .true,
            .false => .false,
            .null => .null,
            .object_begin => .object_begin,
            .object_end => .object_end,
            .array_begin => .array_begin,
            .array_end => .array_end,
            .colon, .comma => unreachable,
        };
    }

    pub fn next(self: *Source) NextError!Token {
        const token = (try self.take()) orelse return .end_of_document;
        // Typed deserialization uses nextAllocMax for decoded strings.
        if (token.tag == .escaped_string) return error.UnexpectedToken;
        return self.asToken(token);
    }

    /// The caller supplies the same input with exclusive write access. Escapes
    /// shrink into the consumed span and the returned string borrows that span.
    pub fn nextInPlace(self: *Source, input: []u8) NextError!Token {
        const token = (try self.take()) orelse return .end_of_document;
        if (token.tag != .escaped_string) return self.asToken(token);
        const span = input[token.start..token.end];
        return .{ .string = span[0..try unescape(span, span)] };
    }

    pub fn nextAllocMax(self: *Source, a: Allocator, when: std.json.AllocWhen, max_len: usize) AllocError!Token {
        const token = (try self.take()) orelse return .end_of_document;
        const span = self.input[token.start..token.end];
        if (token.tag == .escaped_string) {
            const output = try a.alloc(u8, span.len);
            errdefer a.free(output);
            const len = try unescape(span, output);
            if (len > max_len) return error.ValueTooLong;
            return .{ .allocated_string = try a.realloc(output, len) };
        }
        if (token.tag != .string and token.tag != .number) return self.asToken(token);
        if (when == .alloc_if_needed) return self.asToken(token);
        if (span.len > max_len) return error.ValueTooLong;
        const owned = try a.dupe(u8, span);
        return if (token.tag == .string) .{ .allocated_string = owned } else .{ .allocated_number = owned };
    }

    pub fn allocNextIntoArrayListMax(self: *Source, list: *std.array_list.Managed(u8), when: std.json.AllocWhen, max_len: usize) AllocError!?[]const u8 {
        switch (try self.nextAllocMax(list.allocator, when, max_len)) {
            .string, .number => |span| return span,
            .allocated_string, .allocated_number => |span| {
                defer list.allocator.free(span);
                try list.appendSlice(span);
                return null;
            },
            else => unreachable,
        }
    }

    /// Validate a complete value without allocating a tree or decoding strings.
    pub fn skipValue(self: *Source) NextError!void {
        _ = try self.scanValue();
    }

    fn scanValue(self: *Source) NextError!usize {
        var token = (try self.take()) orelse return error.UnexpectedEndOfInput;
        var depth: usize = 0;
        while (true) {
            switch (token.tag) {
                .object_begin, .array_begin => depth += 1,
                .object_end, .array_end => {
                    if (depth == 0) return error.SyntaxError;
                    depth -= 1;
                },
                .escaped_string => try validateSurrogates(self.input[token.start..token.end]),
                else => {},
            }
            if (depth == 0) return token.end + @as(usize, @intFromBool(isString(token)));
            token = (try self.take()) orelse return error.UnexpectedEndOfInput;
        }
    }
};

/// A forward-only reader over one complete input. Consume each field's value
/// before calling `nextField` again. `capture` and `skip` check grammar and
/// string escapes, but don't detect duplicate keys inside unconsumed objects
/// or convert their numbers. Call `finish` before acting on a whole document.
pub const Cursor = struct {
    pub const Window = Source.Window;
    pub const SelectError = Source.NextError || error{DuplicateField};
    pub const Raw = struct {
        bytes: []const u8,
        kind: std.json.TokenType,
        escaped: bool,

        pub fn parse(self: Raw, comptime T: type, a: Allocator, options: ParseOptions) ParseError!T {
            return parseFromSliceLeaky(T, a, self.bytes, options);
        }

        /// Plain strings borrow the input; escaped strings use `a`.
        pub fn string(self: Raw, a: Allocator) (Allocator.Error || error{SyntaxError})!?[]const u8 {
            if (self.kind != .string) return null;
            const raw = self.bytes[1 .. self.bytes.len - 1];
            if (!self.escaped) return raw;
            const out = try a.alloc(u8, raw.len);
            errdefer a.free(out);
            const len = try unescape(raw, out);
            return try a.realloc(out, len);
        }

        pub fn integer(self: Raw) ?i64 {
            if (self.kind != .number or std.mem.eql(u8, self.bytes, "-0")) return null;
            return std.fmt.parseInt(i64, self.bytes, 10) catch null;
        }
    };

    source: Source,
    key: ?[]u8 = null,

    pub fn init(input: []const u8, window: *Window, scratch: Allocator) Cursor {
        return .{ .source = Source.init(input, window, scratch) };
    }

    pub fn deinit(self: *Cursor) void {
        if (self.key) |key| self.source.scratch.free(key);
        self.source.deinit();
    }

    pub fn setMaxDepth(self: *Cursor, max_depth: ?usize) void {
        self.source.max_depth = max_depth;
    }

    pub fn depth(self: *const Cursor) usize {
        return self.source.peak_depth;
    }

    pub fn beginObject(self: *Cursor) Source.NextError!void {
        try self.begin(.object_begin);
    }

    pub fn beginArray(self: *Cursor) Source.NextError!void {
        try self.begin(.array_begin);
    }

    fn begin(self: *Cursor, kind: std.json.TokenType) Source.NextError!void {
        if (try self.source.peekNextTokenType() != kind) return error.UnexpectedToken;
        _ = try self.source.take();
    }

    /// Returns false after consuming the closing bracket. If true, consume
    /// one value (or enter its container) before requesting the next element.
    pub fn nextElement(self: *Cursor) Source.NextError!bool {
        if (self.source.state != .array_first and self.source.state != .array_after) return error.UnexpectedToken;
        if (try self.source.peekNextTokenType() != .array_end) return true;
        _ = try self.source.take();
        return false;
    }

    /// The decoded key is valid until the next `nextField` or `deinit`.
    pub fn nextField(self: *Cursor) Source.NextError!?[]const u8 {
        if (self.key) |key| self.source.scratch.free(key);
        self.key = null;
        if (self.source.state != .object_first and self.source.state != .object_after) return error.UnexpectedToken;
        const token = (try self.source.take()) orelse return error.UnexpectedEndOfInput;
        if (token.tag == .object_end) return null;
        const raw = self.source.input[token.start..token.end];
        if (token.tag == .string) return raw;
        const key = try self.source.scratch.alloc(u8, raw.len);
        self.key = key;
        return key[0..try unescape(raw, key)];
    }

    /// Capture an exact value span borrowing the input (including any quotes).
    pub fn capture(self: *Cursor) Source.NextError!Raw {
        const kind = try self.source.peekNextTokenType();
        const first = self.source.lookahead orelse return error.UnexpectedEndOfInput;
        const end = try self.source.scanValue();
        return .{ .bytes = self.source.input[first.start - @intFromBool(Source.isString(first)) .. end], .kind = kind, .escaped = first.tag == .escaped_string };
    }

    pub fn skip(self: *Cursor) Source.NextError!void {
        try self.source.skipValue();
    }

    /// Decode directly from the cursor without rescanning a captured span.
    pub fn read(self: *Cursor, comptime T: type, a: Allocator, options: ParseOptions) ParseError!T {
        var resolved = options;
        resolved.allocate = options.allocate orelse .alloc_if_needed;
        resolved.max_value_len = options.max_value_len orelse self.source.input.len;
        return std.json.innerParse(T, a, &self.source, resolved);
    }

    /// Like `Source.nextInPlace`; `input` must be the same buffer, exclusively owned.
    pub fn nextInPlace(self: *Cursor, input: []u8) Source.NextError!Token {
        return self.source.nextInPlace(input);
    }

    pub fn finish(self: *Cursor) Source.NextError!void {
        if (try self.source.peekNextTokenType() != .end_of_document) return error.SyntaxError;
    }

    /// Collect spans for named root fields, rejecting duplicate selected keys
    /// (including escape-equivalent spellings). Unknown fields are skipped.
    pub fn select(self: *Cursor, comptime Field: type) SelectError!std.EnumArray(Field, ?Raw) {
        var fields = std.EnumArray(Field, ?Raw).initFill(null);
        try self.beginObject();
        while (try self.nextField()) |key| {
            const field = std.meta.stringToEnum(Field, key) orelse {
                try self.skip();
                continue;
            };
            const slot = fields.getPtr(field);
            if (slot.* != null) return error.DuplicateField;
            slot.* = try self.capture();
        }
        try self.finish();
        return fields;
    }
};

fn unescape(raw: []const u8, output: []u8) error{SyntaxError}!usize {
    var read: usize = 0;
    var written: usize = 0;
    while (read < raw.len) {
        const escape = std.mem.indexOfScalarPos(u8, raw, read, '\\') orelse raw.len;
        const count = escape - read;
        if (output.ptr != raw.ptr or written != read) @memmove(output[written..][0..count], raw[read..escape]);
        written += count;
        if (escape == raw.len) break;
        if (escape + 1 >= raw.len) return error.SyntaxError;
        const kind = raw[escape + 1];
        read = escape + 2;
        if (kind == 'u') {
            written += std.unicode.utf8Encode(try readCodepoint(raw, &read), output[written..]) catch return error.SyntaxError;
            continue;
        }
        const byte: u8 = switch (kind) {
            '"', '\\', '/' => kind,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.SyntaxError,
        };
        output[written] = byte;
        written += 1;
    }
    return written;
}

/// Kit validates escape syntax. Only UTF-16 surrogate pairing needs a second
/// look when the caller does not need to decode the string.
fn validateSurrogates(raw: []const u8) error{SyntaxError}!void {
    var read: usize = 0;
    while (nextUnicodeEscape(raw, read)) |escape| {
        var start = escape;
        while (start > read and raw[start - 1] == '\\') start -= 1;
        read = escape + 2;
        if ((escape - start) % 2 == 0) _ = try readCodepoint(raw, &read);
    }
}

fn nextUnicodeEscape(raw: []const u8, start: usize) ?usize {
    var at = start;
    if (std.simd.suggestVectorLength(u8)) |width| {
        const Block = @Vector(width, u8);
        const slash: Block = @splat('\\');
        const u: Block = @splat('u');
        while (at + width < raw.len) : (at += width) {
            const left: Block = raw[at..][0..width].*;
            const right: Block = raw[at + 1 ..][0..width].*;
            const candidates = @select(bool, left == slash, right == u, @as(@Vector(width, bool), @splat(false)));
            if (std.simd.firstTrue(candidates)) |index| return at + index;
        }
    }
    return std.mem.indexOfPos(u8, raw, at, "\\u");
}

fn readCodepoint(raw: []const u8, read: *usize) error{SyntaxError}!u21 {
    const first = try hexCodeUnit(raw, read);
    if (first < 0xd800 or first > 0xdfff) return first;
    if (first >= 0xdc00 or !std.mem.startsWith(u8, raw[read.*..], "\\u")) return error.SyntaxError;
    read.* += 2;
    const second = try hexCodeUnit(raw, read);
    if (second < 0xdc00 or second > 0xdfff) return error.SyntaxError;
    return 0x10000 + (@as(u21, first - 0xd800) << 10) + (second - 0xdc00);
}

fn hexCodeUnit(raw: []const u8, read: *usize) error{SyntaxError}!u16 {
    if (raw.len - read.* < 4) return error.SyntaxError;
    var code: u16 = 0;
    for (raw[read.*..][0..4]) |digit| {
        code = (code << 4) | (std.fmt.charToDigit(digit, 16) catch return error.SyntaxError);
    }
    read.* += 4;
    return code;
}
