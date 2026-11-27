const std = @import("std");
const unicode = @import("kit").unicode;
const protocol = @import("session_protocol");
const j = @import("../json.zig");
const Allocator = std.mem.Allocator;

pub const namespace = "cpi-minimal.session-name";
pub const entry_kind = "pi.session_info";
const set_name = "set_name";
pub const contract: protocol.Extensions.Contract = .{
    .version = .{ .id = namespace, .version = "1" },
    .initial_state = initial,
    .validate = validate,
    .reduce = reduce,
};

fn initial(_: Allocator) !j.Value {
    return .null;
}

fn validate(_: j.Value, action_name: []const u8, value: j.Value) !void {
    if (!std.mem.eql(u8, action_name, set_name)) return error.UnknownSessionNameAction;
    try validateName(value);
}

pub fn displayEntry(entry: j.Value) bool {
    return j.equal(j.get(entry, "event_kind"), entry_kind);
}

pub fn validateName(value: j.Value) !void {
    if (value != .string or value.string.len == 0 or !std.unicode.utf8ValidateSlice(value.string) or
        std.mem.indexOfAny(u8, value.string, "\r\n") != null) return error.InvalidSessionName;
}

fn reduce(a: Allocator, _: j.Value, _: []const u8, input: j.Value) !j.Value {
    return j.copy(a, input);
}

pub fn admission(name: []const u8) @import("agent").ExtensionWrite {
    return .{
        .namespace = namespace,
        .action = set_name,
        .input = .{ .contract = contract.version, .value = j.string(name) },
    };
}

pub fn trimWhitespace(name: []const u8) []const u8 {
    var first: ?usize = null;
    var end: usize = 0;
    const view = std.unicode.Utf8View.init(name) catch return name;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (unicode.isEcmaWhitespace(codepoint)) continue;
        if (first == null) first = it.i - (std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable);
        end = it.i;
    }
    return name[first orelse end .. end];
}

pub fn normalize(a: Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var line_break = false;
    for (trimWhitespace(input)) |byte| {
        if (byte == '\r' or byte == '\n') {
            if (!line_break) try out.writer.writeByte(' ');
            line_break = true;
        } else {
            try out.writer.writeByte(byte);
            line_break = false;
        }
    }
    return out.toOwnedSlice();
}
