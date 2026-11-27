const std = @import("std");
const json = @import("json_tree");
const j = @import("../json.zig");
const AssistantContent = @import("AssistantContent.zig");
const Controller = @import("Controller.zig");
const A = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Info = struct {
    id: []const u8,
    name: ?[]const u8,
    workspace: []const u8,
    timestamp_ms: i64,
};

pub fn resolve(a: A, io: std.Io, home: []const u8, arg: []const u8, default_name: []const u8) ![]const u8 {
    const path = if (arg.len == 0) default_name else if (arg[0] == '"' or arg[0] == '\'') quoted: {
        const end = std.mem.indexOfScalar(u8, arg[1..], arg[0]) orelse return error.UnclosedPathQuote;
        break :quoted arg[1..][0..end];
    } else arg[0 .. std.mem.indexOfAny(u8, arg, " \t\r\n") orelse arg.len];
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidExportPath;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    if (home.len != 0 and std.mem.startsWith(u8, path, "~/")) return std.fs.path.resolve(a, &.{ home, path[2..] });
    return std.fs.path.resolve(a, &.{ cwd, path });
}

pub fn write(a: A, io: std.Io, path: []const u8, source: ?[]const u8, info: Info, branch: j.Value) !void {
    const dir = std.Io.Dir.cwd();
    if (source) |journal| if (dir.statFile(io, path, .{})) |destination| {
        const active = try dir.statFile(io, journal, .{});
        if (destination.inode == active.inode) return error.ExportWouldReplaceSession;
    } else |err| if (err != error.FileNotFound) return err;
    var file = try dir.createFileAtomic(io, path, .{ .replace = true, .make_path = true, .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    var buffer: [8192]u8 = undefined;
    var output = file.file.writer(io, &buffer);
    try render(a, &output.interface, info, branch, std.mem.endsWith(u8, path, ".jsonl"));
    try output.interface.flush();
    try file.file.sync(io);
    try file.replace(io);
}

fn isoTime(buffer: *[32]u8, ms: i64) ![]const u8 {
    const bounded = std.math.clamp(ms, 0, 253402300799999);
    const stamp: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(bounded, 1000)) };
    const year = stamp.getEpochDay().calculateYearDay();
    const day = year.calculateMonthDay();
    const clock = stamp.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year.year, day.month.numeric(), day.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(), @mod(bounded, 1000),
    });
}

fn line(w: *Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

fn render(a: A, w: *Writer, info: Info, branch: j.Value, jsonl: bool) !void {
    if (jsonl) {
        var stamp: [32]u8 = undefined;
        const started = try isoTime(&stamp, info.timestamp_ms);
        try line(w, .{ .type = "session", .version = 3, .id = info.id, .timestamp = started, .cwd = info.workspace });
    } else try w.print("# {s}\n\n", .{info.name orelse "Session transcript"});
    var provider: []const u8 = "cpi";
    var previous: j.Value = .null;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    for (j.items(branch)) |row| {
        _ = scratch.reset(.{ .retain_with_limit = 32 * 1024 });
        const temp = scratch.allocator();
        const entry = j.get(row, "entry");
        const id = j.text(j.get(entry, "id"));
        const clock = j.get(entry, "message_at_ms");
        const millis = if (clock == .integer and clock.integer >= 0) clock.integer else info.timestamp_ms;
        const body = (try project(temp, entry, millis, &provider)) orelse continue;
        if (!jsonl) {
            try writeMarkdown(temp, w, body);
            continue;
        }
        var timestamp: [32]u8 = undefined;
        var record = j.object();
        try record.object.put(temp, "id", j.string(id));
        try record.object.put(temp, "parentId", previous);
        try record.object.put(temp, "timestamp", j.string(try isoTime(&timestamp, millis)));
        for (body.object.keys(), body.object.values()) |key, value| try record.object.put(temp, key, value);
        try line(w, record);
        previous = j.string(id);
    }
}

fn prose(w: *Writer, text: []const u8) !void {
    if (text.len == 0) return;
    try w.writeAll(text);
    if (!std.mem.endsWith(u8, text, "\n")) try w.writeByte('\n');
    try w.writeByte('\n');
}

fn fenced(w: *Writer, language: []const u8, text: []const u8) !void {
    if (text.len == 0) return;
    var length: usize = 3;
    var run: usize = 0;
    for (text) |byte| {
        run = if (byte == '`') run + 1 else 0;
        length = @max(length, run + 1);
    }
    try w.splatByteAll('`', length);
    try w.writeAll(language);
    try w.writeByte('\n');
    try w.writeAll(text);
    if (!std.mem.endsWith(u8, text, "\n")) try w.writeByte('\n');
    try w.splatByteAll('`', length);
    try w.writeAll("\n\n");
}

fn writeMarkdown(a: A, w: *Writer, entry: j.Value) !void {
    const tag = j.get(entry, "type");
    if (j.equal(tag, "compaction") or j.equal(tag, "branch_summary")) {
        try w.writeAll(if (j.equal(tag, "compaction")) "## Compaction summary\n\n" else "## Branch summary\n\n");
        return prose(w, j.text(j.get(entry, "summary")));
    }
    if (!j.equal(tag, "message")) return;
    const value = j.get(entry, "message");
    const role = j.get(value, "role");
    const tool = j.equal(role, "toolResult");
    if (tool) {
        try w.print("### Tool result · {s}{s}\n\n", .{ j.text(j.get(value, "toolName")), if (j.flag(j.get(value, "isError"))) " (error)" else "" });
    } else if (j.equal(role, "bashExecution")) {
        try w.writeAll("## Bash\n\n");
        try fenced(w, "bash", j.text(j.get(value, "command")));
        return fenced(w, "", j.text(j.get(value, "output")));
    } else {
        try w.writeAll(if (j.equal(role, "user")) "## User\n\n" else "## Assistant\n\n");
    }
    const content = j.get(value, "content");
    if (content == .string) try prose(w, content.string);
    for (j.items(content)) |part| {
        const kind = j.get(part, "type");
        if (j.equal(kind, "text")) {
            const text = j.text(j.get(part, "text"));
            if (tool) try fenced(w, "", text) else try prose(w, text);
        } else if (j.equal(kind, "thinking")) {
            try w.writeAll("### Thinking\n\n");
            try prose(w, j.text(j.get(part, "thinking")));
        } else if (j.equal(kind, "toolCall")) {
            try w.print("### Tool call · {s}\n\n", .{j.text(j.get(part, "name"))});
            try fenced(w, "json", try std.json.Stringify.valueAlloc(a, j.get(part, "arguments"), .{ .whitespace = .indent_2 }));
        } else if (j.equal(kind, "image")) {
            try w.print("Attached image ({s})\n\n", .{j.text(j.get(part, "mimeType"))});
        }
    }
}

fn message(a: A, value: anytype) !j.Value {
    return json.fromAny(a, .{ .type = "message", .message = value });
}

fn textPart(a: A, parts: *j.Value, text: []const u8) !void {
    try parts.array.append(try json.fromAny(a, .{ .type = "text", .text = text }));
}

fn imagePart(a: A, parts: *j.Value, mime: []const u8, payload: []const u8) !void {
    try parts.array.append(try json.fromAny(a, .{ .type = "image", .mimeType = mime, .data = payload }));
}

fn project(a: A, entry: j.Value, stamp: i64, provider: *[]const u8) !?j.Value {
    const tag = j.get(entry, "kind");
    const data = j.get(entry, "data");
    const kind = j.text(j.get(entry, "event_kind"));
    if (j.equal(tag, "input")) {
        var parts = j.array(a);
        for (j.items(j.get(entry, "user_content"))) |part| {
            if (j.equal(j.get(part, "type"), "input_text")) {
                try textPart(a, &parts, j.text(j.get(part, "text")));
            } else if (j.equal(j.get(part, "type"), "input_image")) {
                const uri = j.text(j.get(part, "image_url"));
                const sep = std.mem.indexOf(u8, uri, ";base64,") orelse continue;
                if (sep < 5 or !std.mem.startsWith(u8, uri, "data:")) continue;
                try imagePart(a, &parts, uri[5..sep], uri[sep + ";base64,".len ..]);
            }
        }
        const content = if (parts.array.items.len == 0) j.get(entry, "text") else parts;
        return try message(a, .{ .role = "user", .content = content, .timestamp = stamp });
    }
    if (j.equal(tag, "response")) return try assistant(a, entry, stamp, provider.*);
    if (j.equal(tag, "program")) {
        const raw = j.get(entry, "result");
        const result = if (raw == .null) raw else try Controller.toolResult(a, raw);
        const normalized_images = j.flag(j.get(entry, "normalized_images"));
        var parts = j.array(a);
        for (j.items(j.get(result, "content"))) |part| {
            if (j.equal(j.get(part, "type"), "text")) try parts.array.append(part);
            if (!normalized_images and j.equal(j.get(part, "type"), "image")) try parts.array.append(part);
        }
        if (parts.array.items.len == 0) for (j.items(j.get(entry, "output"))) |item| {
            const output = j.get(item, "output");
            if (output == .string) try textPart(a, &parts, output.string);
        };
        for (j.items(j.get(entry, "images"))) |image| {
            const note = j.text(j.get(image, "note"));
            if (note.len != 0) try textPart(a, &parts, note);
            const payload = j.text(j.get(image, "data_base64"));
            if (payload.len != 0) try imagePart(a, &parts, j.text(j.get(image, "mime_type")), payload);
        }
        return try message(a, .{ .role = "toolResult", .toolCallId = j.get(entry, "call_id"), .toolName = j.get(entry, "name"), .content = parts, .isError = j.flag(j.get(entry, "failed")) or j.flag(j.get(result, "isError")), .timestamp = stamp });
    }
    if (j.equal(tag, "checkpoint")) return try json.fromAny(a, .{ .type = "compaction", .summary = j.get(entry, "summary"), .firstKeptEntryId = j.get(entry, "first_kept"), .tokensBefore = j.number(j.get(j.get(entry, "metadata"), "tokensBefore")) });
    if (j.equal(tag, "branch_summary")) return try json.fromAny(a, .{ .type = "branch_summary", .summary = j.get(entry, "summary"), .fromId = j.get(j.get(entry, "metadata"), "from") });
    if (std.mem.eql(u8, kind, @import("SessionName.zig").entry_kind)) return try json.fromAny(a, .{ .type = "session_info", .name = data });
    if (std.mem.eql(u8, kind, @import("ShellRecord.zig").kind)) {
        const result = j.get(data, "result");
        return try message(a, .{ .role = "bashExecution", .command = j.text(j.get(data, "command")), .output = j.text(j.get(result, "output")), .exitCode = j.get(result, "exit_code"), .cancelled = j.flag(j.get(result, "cancelled")), .truncated = j.flag(j.get(result, "truncated")), .excludeFromContext = j.flag(j.get(data, "excluded")), .timestamp = stamp });
    }
    if (j.equal(j.get(entry, "session_setting"), "model")) {
        const saved = j.text(j.get(data, "provider"));
        if (saved.len != 0) provider.* = saved;
        return try json.fromAny(a, .{ .type = "model_change", .provider = provider.*, .modelId = j.get(data, "model") });
    }
    if (j.equal(j.get(entry, "session_setting"), "thinking")) return try json.fromAny(a, .{ .type = "thinking_level_change", .thinkingLevel = data });
    return null;
}

fn assistant(a: A, entry: j.Value, stamp: i64, provider: []const u8) !j.Value {
    var parts = j.array(a);
    var content = (try AssistantContent.fromJournal(a, entry)).iterator();
    while (content.next()) |part| switch (part.kind) {
        .prose => try textPart(a, &parts, part.text),
        .reasoning => try parts.array.append(try json.fromAny(a, .{ .type = "thinking", .thinking = part.text })),
    };
    if (parts.array.items.len == 0 and j.get(entry, "text") == .string)
        try textPart(a, &parts, j.get(entry, "text").string);
    const calls = j.items(j.get(entry, "calls"));
    for (calls) |call| {
        const raw = j.get(call, "arguments");
        const decoded = if (raw == .string) j.parse(a, raw.string) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => j.object(),
        } else raw;
        try parts.array.append(try json.fromAny(a, .{ .type = "toolCall", .id = j.get(call, "call_id"), .name = j.get(call, "name"), .arguments = if (decoded == .object) decoded else j.object() }));
    }
    const usage = j.get(entry, "usage");
    const provider_usage: @import("Usage.zig").Counts = @import("Usage.zig").normalize(usage) orelse .{};
    const input = j.number(j.get(usage, "input_tokens"));
    const cache_read = if (j.get(usage, "cache_read_tokens") == .integer) j.number(j.get(usage, "cache_read_tokens")) else provider_usage.cache_read;
    const cache_write = if (j.get(usage, "cache_write_tokens") == .integer) j.number(j.get(usage, "cache_write_tokens")) else provider_usage.cache_write;
    const output = j.number(j.get(usage, "output_tokens"));
    const stop = j.get(entry, "stop_reason");
    const reason = if (j.equal(stop, "length")) "length" else if (j.get(entry, "error") == .object) "error" else if (calls.len != 0) "toolUse" else "stop";
    return message(a, .{ .role = "assistant", .content = parts, .model = j.get(entry, "model"), .provider = provider, .api = if (std.mem.eql(u8, provider, "openai-codex")) "openai-codex-responses" else "openai-responses", .usage = .{ .input = input -| (cache_read +| cache_write), .output = output, .cacheRead = cache_read, .cacheWrite = cache_write, .totalTokens = input +| output, .cost = .{ .input = 0, .output = 0, .cacheRead = 0, .cacheWrite = 0, .total = 0 } }, .stopReason = reason, .timestamp = stamp });
}
