//! Prepare Pi-style positional @file arguments for the first launch prompt.
const std = @import("std");
const kit = @import("kit");
const Controller = @import("Controller.zig");
const ImageProcessing = @import("../images.zig").ImageProcessing;
const paths = @import("../tools.zig").paths;
const j = @import("../json.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Files = struct {
    text: []const u8 = "",
    images: []const ImageProcessing.Image = &.{},

    fn userContent(a: Allocator, images: []const ImageProcessing.Image, text: []const u8) !j.Value {
        if (images.len == 0) return .null;
        var content = j.array(a);
        try content.array.append(try j.value(a, .{ .type = "input_text", .text = text }));
        for (images) |image| {
            const uri = try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ image.mime_type, image.data_base64 });
            var part = j.object();
            try part.object.put(a, "type", j.string("input_image"));
            try part.object.put(a, "detail", j.string("auto"));
            try part.object.put(a, "image_url", j.string(uri));
            try content.array.append(part);
        }
        return content;
    }

    fn attach(self: Files, a: Allocator, controller: *Controller, conversation: ?[]const u8, prepared: *Controller.Prepared) !void {
        const images = if (controller.runPolicy().auto_resize_images)
            try self.resize(a, controller, conversation, prepared)
        else
            self.images;
        prepared.user_content = try userContent(a, images, prepared.text);
    }

    fn resize(self: Files, a: Allocator, controller: *Controller, conversation: ?[]const u8, prepared: *Controller.Prepared) ![]const ImageProcessing.Image {
        if (self.images.len == 0) return self.images;
        const limits = try controller.inputImageLimits(conversation);
        var notes: Io.Writer.Allocating = .init(controller.gpa);
        defer notes.deinit();
        var images: std.ArrayList(ImageProcessing.Image) = .empty;
        for (self.images) |source| {
            const result = try ImageProcessing.processEncoded(a, controller.gpa, controller.io, source, true, limits);
            const note = switch (result) {
                .omitted => |reason| reason,
                .image => |image| blk: {
                    try images.append(a, image);
                    break :blk image.note;
                },
            };
            if (note.len == 0) continue;
            if (notes.written().len != 0) try notes.writer.writeByte('\n');
            try notes.writer.writeAll(note);
        }
        if (notes.written().len > 0) {
            prepared.text = try std.mem.concat(a, u8, &.{ prepared.text, "\n\n", notes.written() });
            prepared.original = try std.mem.concat(a, u8, &.{ prepared.original, "\n\n", notes.written() });
        }
        return images.items;
    }
};

pub const Inputs = struct {
    prompts: []const []const u8,
    files: Files,
    stdin_text: []const u8,

    pub fn prepare(self: Inputs, a: Allocator, controller: *Controller, conversation: ?[]const u8) ![]Controller.Prepared {
        const prompts = self.prompts;
        const files = self.files;
        const stdin_text = self.stdin_text;
        const prefix = files.text.len != 0 or stdin_text.len != 0;
        const offset: usize = @intFromBool(prefix);
        const inputs = try a.alloc(Controller.Prepared, @max(prompts.len, offset));
        if (prefix) {
            const prompt = if (prompts.len == 0) "" else prompts[0];
            const initial = try std.mem.concat(a, u8, &.{ stdin_text, files.text, prompt });
            var prepared = try controller.prepare(a, initial);
            try files.attach(a, controller, conversation, &prepared);
            inputs[0] = prepared;
        }
        for (if (prefix and prompts.len != 0) prompts[1..] else prompts, offset..) |prompt, index| {
            inputs[index] = try controller.prepare(a, prompt);
        }
        return inputs;
    }
};

pub fn load(a: Allocator, scratch_parent: Allocator, io: Io, location: paths.Location, arguments: []const []const u8) !Files {
    var files: Io.Writer.Allocating = .init(a);
    defer files.deinit();
    var images: std.ArrayList(ImageProcessing.Image) = .empty;
    for (arguments) |argument| {
        var scratch = std.heap.ArenaAllocator.init(scratch_parent);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const absolute = try paths.resolveRead(temporary, location, argument);
        const bytes = read(temporary, io, absolute) catch |err| {
            switch (err) {
                error.FileNotFound => std.debug.print("Error: File not found: {s}\n", .{absolute}),
                error.Canceled, error.OutOfMemory => {},
                else => std.debug.print("Error: Could not read file {s}: {s}\n", .{ absolute, @errorName(err) }),
            }
            return err;
        };
        if (bytes.len == 0) continue;
        try files.writer.print("<file name=\"{s}\">", .{absolute});
        if (ImageProcessing.detect(bytes)) |mime| {
            switch (try ImageProcessing.process(a, io, bytes, mime, false, .{})) {
                .omitted => |note| try files.writer.writeAll(note),
                .image => |image| {
                    try files.writer.writeAll(image.note);
                    try images.append(a, image);
                },
            }
        } else {
            const text = try decodeText(temporary, bytes);
            try files.writer.writeByte('\n');
            try files.writer.writeAll(if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text);
            try files.writer.writeByte('\n');
        }
        try files.writer.writeAll("</file>\n");
    }
    return .{ .text = try files.toOwnedSlice(), .images = images.items };
}

fn read(a: Allocator, io: Io, absolute: []const u8) ![]const u8 {
    const file = try Io.Dir.openFileAbsolute(io, absolute, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, .unlimited);
}

pub fn pipedText(a: Allocator, io: Io) ![]const u8 {
    var buffer: [8192]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    const text = try decodeText(a, try reader.interface.allocRemaining(a, .unlimited));
    var first = text.len;
    var last: usize = 0;
    var offset: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(text[offset..])) |decoded| {
        if (!trimWhitespace(decoded.codepoint)) {
            first = @min(first, offset);
            last = offset + decoded.len;
        }
        offset += decoded.len;
    }
    return if (last == 0) "" else text[first..last];
}

fn trimWhitespace(cp: u21) bool {
    return switch (cp) {
        9...13, 32, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn decodeText(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var text: Io.Writer.Allocating = .init(a);
    defer text.deinit();
    var offset: usize = 0;
    while (kit.unicode.decodeUtf8Lossy(bytes[offset..])) |decoded| {
        if (decoded.valid) {
            try text.writer.writeAll(bytes[offset..][0..decoded.len]);
            offset += decoded.len;
        } else {
            try text.writer.writeAll("\xef\xbf\xbd");
            offset += invalidPrefix(bytes[offset..]);
        }
    }
    return text.toOwnedSlice();
}

// Node's UTF-8 decoder substitutes one replacement for an incomplete prefix
// of a valid sequence, and then reconsiders the first invalid continuation.
fn invalidPrefix(bytes: []const u8) usize {
    const lead = bytes[0];
    if (lead < 0xc2 or lead > 0xf4 or bytes.len < 2) return 1;
    const second = bytes[1];
    if (second < 0x80 or second > 0xbf or
        (lead == 0xe0 and second < 0xa0) or (lead == 0xed and second > 0x9f) or
        (lead == 0xf0 and second < 0x90) or (lead == 0xf4 and second > 0x8f)) return 1;
    const limit = std.unicode.utf8ByteSequenceLength(lead) catch unreachable;
    var len: usize = 2;
    while (len < @min(bytes.len, limit) and bytes[len] >= 0x80 and bytes[len] <= 0xbf) : (len += 1) {}
    return len;
}
