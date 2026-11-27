const std = @import("std");
const types = @import("config.zig");

pub const Request = struct {
    request_id: []const u8,
    operation_id: u64,
    method: enum { model, host },
    json: []const u8,
    model_progress: ?@import("services").ModelProgressSink = null,
};
pub const Response = struct { json: []u8, failed: bool = false };
pub const Event = union(enum) { request: Request, notice: types.Notice };
pub const Port = struct {
    context: *anyopaque,
    journal_size_warnings: ?@import("session_protocol").Transaction.SizeSink = null,
    application_size_warnings: ?@import("session_protocol").Transaction.SizeSink = null,
    validate_tool: ?*const fn (*anyopaque, *const @import("vm").RegisteredTool) anyerror!void = null,
    startup_command: ?*const fn (*anyopaque, []const u8, types.Command, ?*const @import("vm").RegisteredTool) anyerror!void = null,
    startup_check: ?*const fn (*anyopaque) anyerror!void = null,
    exchange: *const fn (*anyopaque, std.mem.Allocator, std.Io, Event) anyerror!?Response,
};
