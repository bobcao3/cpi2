//! Decode argument prefixes for built-in tool cards. Execution and replay get
//! their authoritative arguments from the session, independently of this view.

const std = @import("std");
const j = @import("../../json.zig");

const recoverable = error{ BufferUnderrun, SyntaxError, UnexpectedEndOfInput };

pub fn preview(a: j.Allocator, bytes: []const u8) error{OutOfMemory}!j.Value {
    var input = std.json.Scanner.initStreaming(a);
    defer input.deinit();
    // Pi's partial JSON repair trims whitespace at the physical end of input.
    input.feedInput(std.mem.trimEnd(u8, bytes, " \t\r\n"));
    var args = j.object();
    readObject(a, &input, &args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BufferUnderrun, error.SyntaxError, error.UnexpectedEndOfInput => {},
    };
    return args;
}

fn readObject(a: j.Allocator, input: *std.json.Scanner, args: *j.Value) (recoverable || error{OutOfMemory})!void {
    if (try input.next() != .object_begin) return;
    while (try input.peekNextTokenType() == .string) {
        var key: std.array_list.Managed(u8) = .init(a);
        const borrowed_key = input.allocNextIntoArrayListMax(&key, .alloc_if_needed, std.math.maxInt(usize)) catch |err| switch (err) {
            error.ValueTooLong => unreachable,
            else => |failure| return failure,
        };
        const name = borrowed_key orelse key.items;
        const field = std.meta.stringToEnum(Field, name);
        if (field) |known| {
            if (try readValue(a, input, true)) |value| try args.object.put(a, @tagName(known), value);
        } else {
            _ = try readValue(a, input, false);
        }
    }
}

const Field = enum { path, file_path, content, command, offset, limit, timeout, pattern, glob, source };

fn readValue(a: j.Allocator, input: *std.json.Scanner, keep: bool) (recoverable || error{OutOfMemory})!?j.Value {
    const kind = try input.peekNextTokenType();
    switch (kind) {
        .object_begin, .array_begin => {
            const depth = input.stackHeight();
            _ = try input.next();
            input.skipUntilStackHeight(depth) catch |err| switch (err) {
                error.BufferUnderrun => {},
                else => |failure| return failure,
            };
            return if (kind == .object_begin) j.object() else j.array(a);
        },
        .true, .false, .null => {
            _ = input.next() catch |err| switch (err) {
                error.BufferUnderrun => {},
                else => |failure| return failure,
            };
            return if (kind == .null) .null else .{ .bool = kind == .true };
        },
        .string, .number => {
            if (!keep) {
                while (true) {
                    switch (try input.next()) {
                        .string, .number => return null,
                        else => {},
                    }
                }
            }
            var collected: std.array_list.Managed(u8) = .init(a);
            const borrowed = input.allocNextIntoArrayListMax(&collected, .alloc_if_needed, std.math.maxInt(usize)) catch |err| switch (err) {
                error.BufferUnderrun => null,
                error.ValueTooLong => unreachable,
                else => |failure| return failure,
            };
            const literal = borrowed orelse collected.items;
            if (kind == .string) return j.string(completeUtf8(literal));
            // A trailing decimal or exponent marker can still be completed by the next delta.
            const number = std.mem.trimEnd(u8, literal, ".eE+-");
            if (number.len == 0) return null;
            if (std.fmt.parseInt(i64, number, 10)) |integer| return j.integer(integer) else |_| {}
            return .{ .float = std.fmt.parseFloat(f64, number) catch return null };
        },
        else => return null,
    }
}

fn completeUtf8(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;
    var start = bytes.len - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    const size = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes[0..start];
    return if (bytes.len - start < size) bytes[0..start] else bytes;
}
