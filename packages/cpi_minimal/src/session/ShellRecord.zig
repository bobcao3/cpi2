const std = @import("std");
const services = @import("services");
const ShellOutput = @import("ShellOutput.zig");

pub const kind = "pi.user_shell";
pub const Result = struct {
    output: []const u8 = "",
    exit_code: ?u32 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
};
const Self = @This();

command: []const u8,
excluded: bool,
result: Result,

pub fn preview(a: std.mem.Allocator, command: []const u8, excluded: bool, raw: []const u8) !Self {
    return .{ .command = command, .excluded = excluded, .result = .{ .output = (try ShellOutput.preview(a, raw)).text } };
}

pub fn fromCapture(a: std.mem.Allocator, io: std.Io, command: []const u8, excluded: bool, capture: services.Exec.InteractiveResult) !Self {
    const tail = if (capture.truncated and capture.full_output_path != null)
        ShellOutput.read(a, io, capture.full_output_path.?, capture.output_bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => ShellOutput.Tail{ .text = (try ShellOutput.preview(a, capture.output)).text, .truncated = true },
        }
    else
        try ShellOutput.preview(a, capture.output);
    return .{
        .command = command,
        .excluded = excluded,
        .result = .{
            .output = tail.text,
            .exit_code = capture.exit_code,
            .cancelled = capture.cancelled,
            .truncated = tail.truncated,
            .full_output_path = if (tail.truncated) capture.full_output_path else null,
        },
    };
}

pub fn truncationNote(self: Self, a: std.mem.Allocator) ![]const u8 {
    if (self.result.full_output_path) |path| return std.fmt.allocPrint(a, "Output truncated. Full output: {s}", .{path});
    return "Output truncated";
}

pub fn modelText(self: Self, a: std.mem.Allocator) ![]const u8 {
    var bytes: std.Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    try bytes.writer.print("Ran `{s}`\n", .{self.command});
    if (self.result.output.len != 0) {
        try bytes.writer.print("```\n{s}\n```", .{self.result.output});
    } else try bytes.writer.writeAll("(no output)");
    if (self.result.cancelled) {
        try bytes.writer.writeAll("\n\n(command cancelled)");
    } else if (self.result.exit_code) |code| {
        if (code != 0) try bytes.writer.print("\n\nCommand exited with code {d}", .{code});
    }
    if (self.result.truncated) {
        const note = try self.truncationNote(a);
        defer if (self.result.full_output_path != null) a.free(note);
        try bytes.writer.print("\n\n[{s}]", .{note});
    }
    return bytes.toOwnedSlice();
}
