//! X11 selection reader. Minimal runs this in a child process so a blocked X11 connection can be canceled.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const argument = "--internal-x11-clipboard";
pub const max_bytes = 50 * 1024 * 1024;
pub const Mode = enum { text, image };
pub const Reply = enum(u8) { data = 1, failed = 2 };

const text_targets = [_][]const u8{
    "text/plain;charset=utf-8", "text/plain;charset=UTF-8", "UTF8_STRING", "text/plain", "STRING",
};
const image_targets = [_][]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/tiff" };

const Atom = u32;
const Window = u32;
const atom_atom: Atom = 4;
const atom_string: Atom = 31;
const property_notify = 28;
const selection_notify = 31;
const property_new_value = 0;
const event_mask_property_change: u32 = 1 << 22;
const cw_event_mask: u32 = 1 << 11;
const input_output = 1;

// libxcb's public X11 protocol ABI. Screen and reply declarations include the fields we access.
const Connection = opaque {};
const Setup = opaque {};
const Screen = extern struct { root: Window };
const ScreenIterator = extern struct { data: ?*const Screen, remaining: c_int, index: c_int };
const Cookie = extern struct { sequence: c_uint };
const Event = extern struct { response_type: u8 };
const AtomReply = extern struct { response_type: u8, pad: u8, sequence: u16, length: u32, atom: Atom };
const PropertyReply = extern struct {
    response_type: u8,
    format: u8,
    sequence: u16,
    length: u32,
    type: Atom,
    bytes_after: u32,
    value_len: u32,
};
const SelectionNotify = extern struct {
    response_type: u8,
    pad: u8,
    sequence: u16,
    time: u32,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
};
const PropertyNotify = extern struct {
    response_type: u8,
    pad: u8,
    sequence: u16,
    window: Window,
    atom: Atom,
    time: u32,
    state: u8,
};

const Api = struct {
    connect: *const fn (?[*:0]const u8, *c_int) callconv(.c) ?*Connection,
    disconnect: *const fn (*Connection) callconv(.c) void,
    connection_has_error: *const fn (*Connection) callconv(.c) c_int,
    get_setup: *const fn (*Connection) callconv(.c) ?*const Setup,
    setup_roots_iterator: *const fn (*const Setup) callconv(.c) ScreenIterator,
    screen_next: *const fn (*ScreenIterator) callconv(.c) void,
    generate_id: *const fn (*Connection) callconv(.c) u32,
    create_window: *const fn (*Connection, u8, Window, Window, i16, i16, u16, u16, u16, u16, u32, u32, *const u32) callconv(.c) Cookie,
    intern_atom: *const fn (*Connection, u8, u16, [*]const u8) callconv(.c) Cookie,
    convert_selection: *const fn (*Connection, Window, Atom, Atom, Atom, u32) callconv(.c) Cookie,
    get_property: *const fn (*Connection, u8, Window, Atom, Atom, u32, u32) callconv(.c) Cookie,
    get_property_value: *const fn (*const PropertyReply) callconv(.c) ?[*]const u8,
    poll_for_reply: *const fn (*Connection, c_uint, *?*anyopaque, *?*anyopaque) callconv(.c) c_int,
    discard_reply: *const fn (*Connection, c_uint) callconv(.c) void,
    poll_for_event: *const fn (*Connection) callconv(.c) ?*Event,
    get_file_descriptor: *const fn (*Connection) callconv(.c) c_int,
    flush: *const fn (*Connection) callconv(.c) c_int,

    fn load(lib: *std.DynLib) !Api {
        var api: Api = undefined;
        const fields = @typeInfo(Api).@"struct";
        inline for (fields.field_names, fields.field_types) |name, T| {
            @field(api, name) = lib.lookup(T, "xcb_" ++ name) orelse return error.X11Unavailable;
        }
        return api;
    }
};

const Property = struct {
    type: Atom,
    format: u8,
    bytes: std.ArrayList(u8) = .empty,

    fn append(self: *Property, a: Allocator, value: []const u8) !void {
        if (value.len > max_bytes - self.bytes.items.len) return error.ClipboardTooLarge;
        try self.bytes.appendSlice(a, value);
    }
};

const Reader = struct {
    api: *const Api,
    connection: *Connection,
    io: Io,
    deadline: Io.Timestamp,
    window: Window,
    clipboard: Atom,
    property: Atom,
    targets: Atom,
    incr: Atom,

    fn init(api: *const Api, connection: *Connection, screen: c_int, io: Io, deadline: Io.Timestamp) !Reader {
        var roots = api.setup_roots_iterator(api.get_setup(connection) orelse return error.X11Unavailable);
        var index = screen;
        while (index > 0 and roots.remaining > 0) : (index -= 1) api.screen_next(&roots);
        if (roots.remaining <= 0) return error.X11Unavailable;
        const root = roots.data orelse return error.X11Unavailable;
        const window = api.generate_id(connection);
        if (window == 0 or window == std.math.maxInt(Window)) return error.X11Unavailable;
        _ = api.create_window(connection, 0, window, root.root, 0, 0, 1, 1, 0, input_output, 0, cw_event_mask, &event_mask_property_change);
        var self: Reader = .{
            .api = api,
            .connection = connection,
            .window = window,
            .io = io,
            .deadline = deadline,
            .clipboard = 0,
            .property = 0,
            .targets = 0,
            .incr = 0,
        };
        self.clipboard = try self.atom("CLIPBOARD");
        self.property = try self.atom("CPI_CLIPBOARD");
        self.targets = try self.atom("TARGETS");
        self.incr = try self.atom("INCR");
        return self;
    }

    fn reply(self: *const Reader, cookie: Cookie) !*anyopaque {
        if (self.api.flush(self.connection) > 0) {
            while (self.beforeDeadline()) {
                var response: ?*anyopaque = null;
                var failure: ?*anyopaque = null;
                if (self.api.poll_for_reply(self.connection, cookie.sequence, &response, &failure) != 0) {
                    std.c.free(failure);
                    return response orelse error.X11ReadFailed;
                }
                if (!self.waitForInput()) break;
            }
        }
        self.api.discard_reply(self.connection, cookie.sequence);
        return error.X11ReadFailed;
    }

    fn beforeDeadline(self: *const Reader) bool {
        return Io.Timestamp.now(self.io, .awake).compare(.lt, self.deadline);
    }

    fn waitForInput(self: *const Reader) bool {
        const remaining = Io.Timestamp.now(self.io, .awake).durationTo(self.deadline).toMilliseconds();
        if (remaining <= 0 or self.api.connection_has_error(self.connection) != 0) return false;
        var fds = [_]std.posix.pollfd{.{ .fd = self.api.get_file_descriptor(self.connection), .events = std.posix.POLL.IN, .revents = 0 }};
        return (std.posix.poll(&fds, @intCast(remaining)) catch 0) > 0 and fds[0].revents & std.posix.POLL.IN != 0;
    }

    fn nextEvent(self: *const Reader) ?*Event {
        while (self.beforeDeadline()) {
            if (self.api.poll_for_event(self.connection)) |event| return event;
            if (!self.waitForInput()) break;
        }
        return null;
    }

    fn atom(self: *const Reader, name: []const u8) !Atom {
        const raw = try self.reply(self.api.intern_atom(self.connection, 0, @intCast(name.len), name.ptr));
        defer std.c.free(raw);
        const response: *const AtomReply = @ptrCast(@alignCast(raw));
        return if (response.atom != 0) response.atom else error.X11ReadFailed;
    }

    fn readProperty(self: *const Reader) !*const PropertyReply {
        const raw = try self.reply(self.api.get_property(self.connection, 1, self.window, self.property, 0, 0, max_bytes / 4));
        const response: *const PropertyReply = @ptrCast(@alignCast(raw));
        errdefer std.c.free(raw);
        if (response.bytes_after != 0 or response.type == 0 or switch (response.format) {
            8, 16, 32 => false,
            else => true,
        }) return error.InvalidX11Property;
        const length = @as(u64, response.value_len) * (response.format / 8);
        if (length > max_bytes or length > @as(u64, response.length) * 4) return error.InvalidX11Property;
        return response;
    }

    fn propertyBytes(self: *const Reader, response: *const PropertyReply) ![]const u8 {
        if (response.value_len == 0) return "";
        const value = self.api.get_property_value(response) orelse return error.InvalidX11Property;
        return value[0 .. @as(usize, response.value_len) * (response.format / 8)];
    }

    fn convert(self: *const Reader, target: Atom) !bool {
        _ = self.api.convert_selection(self.connection, self.window, self.clipboard, target, self.property, 0);
        if (self.api.flush(self.connection) <= 0) return error.X11ReadFailed;
        while (self.nextEvent()) |event| {
            defer std.c.free(event);
            if (event.response_type & 0x7f != selection_notify) continue;
            const notice: *const SelectionNotify = @ptrCast(@alignCast(event));
            if (notice.requestor == self.window and notice.selection == self.clipboard and notice.target == target) {
                return notice.property == self.property;
            }
        }
        return error.X11ReadFailed;
    }

    fn waitForChunk(self: *const Reader) !void {
        while (self.nextEvent()) |event| {
            defer std.c.free(event);
            if (event.response_type & 0x7f != property_notify) continue;
            const notice: *const PropertyNotify = @ptrCast(@alignCast(event));
            if (notice.window == self.window and notice.atom == self.property and notice.state == property_new_value) return;
        }
        return error.X11ReadFailed;
    }

    fn selection(self: *const Reader, a: Allocator, target: Atom) !?Property {
        if (!try self.convert(target)) return null;
        const initial = try self.readProperty();
        defer std.c.free(@constCast(initial));
        var result: Property = .{ .type = initial.type, .format = initial.format };
        errdefer result.bytes.deinit(a);
        if (initial.type != self.incr) {
            try result.append(a, try self.propertyBytes(initial));
            return result;
        }

        // Deleting each property acknowledges it to the owner. A zero-length chunk ends the transfer.
        result.type = 0;
        while (true) {
            try self.waitForChunk();
            const chunk = try self.readProperty();
            defer std.c.free(@constCast(chunk));
            if (result.type == 0) {
                result.type = chunk.type;
                result.format = chunk.format;
            } else if (result.type != chunk.type or result.format != chunk.format) {
                return error.InvalidX11Property;
            }
            try result.append(a, try self.propertyBytes(chunk));
            if (chunk.value_len == 0) return result;
        }
    }

    fn preferred(self: *const Reader, a: Allocator, mode: Mode) !?Atom {
        var offered = (try self.selection(a, self.targets)) orelse {
            return if (mode == .text) try self.atom("UTF8_STRING") else null;
        };
        defer offered.bytes.deinit(a);
        if (offered.type != atom_atom or offered.format != 32) return error.InvalidX11Property;
        const candidates: []const []const u8 = switch (mode) {
            .text => &text_targets,
            .image => &image_targets,
        };
        for (candidates) |name| {
            const wanted = try self.atom(name);
            var entries = std.mem.window(u8, offered.bytes.items, 4, 4);
            while (entries.next()) |entry| {
                if (std.mem.readInt(Atom, entry[0..4], @import("builtin").cpu.arch.endian()) == wanted) return wanted;
            }
        }
        return null;
    }

    fn read(self: *const Reader, a: Allocator, mode: Mode) !?Property {
        const target = (try self.preferred(a, mode)) orelse return null;
        var property = (try self.selection(a, target)) orelse return null;
        errdefer property.bytes.deinit(a);
        if (property.format != 8) return error.InvalidX11Property;
        return property;
    }
};

pub fn run(a: Allocator, io: Io, mode: Mode) !void {
    var lib = std.DynLib.open("libxcb.so.1") catch return;
    defer lib.close();
    const api = Api.load(&lib) catch return;
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(2));
    var screen: c_int = 0;
    const connection = api.connect(null, &screen) orelse return;
    defer api.disconnect(connection);
    if (api.connection_has_error(connection) != 0) return;
    const reader = Reader.init(&api, connection, screen, io, deadline) catch return;
    var selection = (reader.read(a, mode) catch {
        return Io.File.stdout().writeStreamingAll(io, &.{@backingInt(Reply.failed)});
    }) orelse return;
    defer selection.bytes.deinit(a);
    const stdout = Io.File.stdout();
    try stdout.writeStreamingAll(io, &.{@backingInt(Reply.data)});
    if (mode == .text and selection.type == atom_string) {
        var buffer: [8192]u8 = undefined;
        var output = stdout.writerStreaming(io, &buffer);
        for (selection.bytes.items) |byte| {
            if (byte < 0x80) {
                try output.interface.writeByte(byte);
            } else {
                try output.interface.writeAll(&.{ 0xc0 | (byte >> 6), 0x80 | (byte & 0x3f) });
            }
        }
        try output.interface.flush();
    } else {
        try stdout.writeStreamingAll(io, selection.bytes.items);
    }
}
