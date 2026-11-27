//! Interactive preferences shared by cpi-minimal sessions.
const std = @import("std");
const kit = @import("kit");
const Config = @import("Config.zig");
const Controller = @import("../session.zig").Controller;
const List = kit.tui.SettingsList;

const Settings = @This();
const Io = std.Io;

pub const ImageWidth = enum { @"60", @"80", @"120" };
pub const EditorPadding = enum { @"0", @"1", @"2", @"3" };
pub const OutputPadding = enum { @"0", @"1" };
pub const CompletionLimit = enum { @"3", @"5", @"7", @"10", @"15", @"20" };
pub const QuietStartup = enum { true, header, false };
pub const DoubleEscape = enum { tree, fork, none };
pub const Scrollbar = enum { auto, always, hidden };
pub const TuiMode = enum {
    regular,
    fullscreen,

    pub fn screenMode(mode: TuiMode) kit.tui.Tui.Mode {
        return switch (mode) {
            .regular => .main_screen_rerender,
            .fullscreen => .fullscreen,
        };
    }
};
pub const ExitOutput = enum { transcript, @"resume-hint" };
pub const Wheel = enum { auto, @"1", @"2", @"3", @"5", @"10" };
pub const Transport = enum { sse, websocket, @"websocket-cached", auto };

auto_compact: ?bool = null,
show_images: ?bool = null,
image_width: ?ImageWidth = null,
auto_resize_images: ?bool = null,
block_images: ?bool = null,
skill_commands: ?bool = null,
show_hardware_cursor: ?bool = null,
editor_padding: ?EditorPadding = null,
output_padding: ?OutputPadding = null,
autocomplete_max_items: ?CompletionLimit = null,
clear_on_shrink: ?bool = null,
terminal_progress: ?bool = null,
steering_mode: ?Controller.QueueMode = null,
follow_up_mode: ?Controller.QueueMode = null,
transport: ?Transport = null,
hide_thinking: ?bool = null,
quiet_startup: ?QuietStartup = null,
double_escape: ?DoubleEscape = null,
tui_mode: ?TuiMode = null,
fullscreen_exit_output: ?ExitOutput = null,
fullscreen_scrollbar: ?Scrollbar = null,
fullscreen_copy_on_select: ?bool = null,
fullscreen_wheel: ?Wheel = null,
theme: ?[]const u8 = null,

pub const Item = std.meta.FieldEnum(Settings);

pub const MenuEntry = struct {
    id: Item,
    label: []const u8,
    description: []const u8,
    requires_images: bool = false,
};

pub const Items = struct {
    ids: [std.enums.values(Item).len]Item = undefined,
    rows: [std.enums.values(Item).len]List.Item = undefined,
    count: usize = 0,
};

pub fn items(self: Settings, menu: []const MenuEntry, supports_images: bool, skill_commands: bool, quiet_startup: Config.QuietStartup, runtime: Controller.RunPolicy) Items {
    var result: Items = .{};
    for (menu) |entry| {
        if (entry.requires_images and !supports_images) continue;
        result.ids[result.count] = entry.id;
        result.rows[result.count] = .{
            .label = entry.label,
            .value = switch (entry.id) {
                inline else => |id| displayValue(self.effective(id, skill_commands, quiet_startup, runtime)),
            },
            .description = entry.description,
        };
        result.count += 1;
    }
    return result;
}

fn effective(self: Settings, comptime item: Item, skill_commands: bool, quiet_startup: Config.QuietStartup, runtime: Controller.RunPolicy) @typeInfo(@FieldType(Settings, @tagName(item))).optional.child {
    return switch (item) {
        .auto_compact => runtime.auto_compact,
        .show_images => self.show_images orelse true,
        .image_width => self.image_width orelse .@"60",
        .auto_resize_images => runtime.auto_resize_images,
        .block_images => runtime.block_images,
        .skill_commands => self.skill_commands orelse skill_commands,
        .show_hardware_cursor => self.show_hardware_cursor orelse false,
        .editor_padding => self.editor_padding orelse .@"0",
        .output_padding => self.output_padding orelse .@"1",
        .autocomplete_max_items => self.autocomplete_max_items orelse .@"5",
        .clear_on_shrink => self.clear_on_shrink orelse false,
        .terminal_progress => self.terminal_progress orelse false,
        .steering_mode => runtime.queue.steering,
        .follow_up_mode => runtime.queue.follow_up,
        .transport => self.transport orelse .auto,
        .hide_thinking => self.hide_thinking orelse false,
        .quiet_startup => self.quiet_startup orelse quietValue(quiet_startup),
        .double_escape => self.double_escape orelse .tree,
        .tui_mode => self.tui_mode orelse .fullscreen,
        .fullscreen_exit_output => self.fullscreen_exit_output orelse .transcript,
        .fullscreen_scrollbar => self.fullscreen_scrollbar orelse .auto,
        .fullscreen_copy_on_select => self.fullscreen_copy_on_select orelse true,
        .fullscreen_wheel => self.fullscreen_wheel orelse .auto,
        .theme => self.theme orelse "system",
    };
}

pub fn cycle(self: Settings, item: Item, skill_commands: bool, quiet_startup: Config.QuietStartup, runtime: Controller.RunPolicy) Settings {
    var updated = self;
    switch (item) {
        .theme => unreachable,
        inline else => |id| {
            const value = self.effective(id, skill_commands, quiet_startup, runtime);
            @field(updated, @tagName(id)) = if (@TypeOf(value) == bool) !value else next(value);
        },
    }
    return updated;
}

fn displayValue(value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (value) "true" else "false",
        .@"enum" => if (@TypeOf(value) == Controller.QueueMode and value == .one_at_a_time) "one-at-a-time" else @tagName(value),
        .pointer => value,
        else => unreachable,
    };
}

pub fn runPolicy(self: Settings, defaults: Controller.RunPolicy) Controller.RunPolicy {
    return .{
        .auto_compact = self.auto_compact orelse defaults.auto_compact,
        .block_images = self.block_images orelse defaults.block_images,
        .auto_resize_images = self.auto_resize_images orelse defaults.auto_resize_images,
        .queue = .{
            .steering = self.steering_mode orelse defaults.queue.steering,
            .follow_up = self.follow_up_mode orelse defaults.queue.follow_up,
        },
    };
}

pub fn codexTransportPreference(self: Settings) Controller.CodexTransportPreference {
    return switch (self.transport orelse return .configured) {
        .sse => .http,
        .websocket => .websocket,
        .@"websocket-cached", .auto => .@"websocket-cached",
    };
}

pub fn withTerminalDefaults(self: Settings, env: *const std.process.Environ.Map) Settings {
    var settings = self;
    settings.show_hardware_cursor = self.show_hardware_cursor orelse std.mem.eql(u8, env.get("PI_HARDWARE_CURSOR") orelse "", "1");
    settings.clear_on_shrink = self.clear_on_shrink orelse std.mem.eql(u8, env.get("PI_CLEAR_ON_SHRINK") orelse "", "1");
    return settings;
}

fn next(value: anytype) @TypeOf(value) {
    const values = std.enums.values(@TypeOf(value));
    return values[(@backingInt(value) +% 1) % values.len];
}

fn quietValue(value: Config.QuietStartup) QuietStartup {
    return switch (value) {
        .full => .false,
        .header => .header,
        .hidden => .true,
    };
}

pub fn startup(self: Settings, fallback: Config.QuietStartup) Config.QuietStartup {
    return switch (self.quiet_startup orelse return fallback) {
        .false => .full,
        .header => .header,
        .true => .hidden,
    };
}

pub fn editorPadding(self: Settings) u16 {
    return @backingInt(self.editor_padding orelse .@"0");
}

pub fn outputPadding(self: Settings) u16 {
    return @backingInt(self.output_padding orelse .@"1");
}

pub fn completionLimit(self: Settings) usize {
    return std.fmt.parseInt(usize, @tagName(self.autocomplete_max_items orelse .@"5"), 10) catch unreachable;
}

pub fn imageWidth(self: Settings) u16 {
    return std.fmt.parseInt(u16, @tagName(self.image_width orelse .@"60"), 10) catch unreachable;
}

pub fn wheelLines(self: Settings) ?i64 {
    const value = self.fullscreen_wheel orelse .auto;
    return if (value == .auto) null else std.fmt.parseInt(i64, @tagName(value), 10) catch unreachable;
}

fn read(a: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub const Loaded = struct {
    preferences: Settings = .{},
    default_tools: ?[]const []const u8 = null,
};

pub fn load(a: std.mem.Allocator, io: Io, path: []const u8) !Loaded {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const bytes = try read(scratch, io, path) orelse return .{};
    const document = try std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{});
    if (document != .object) return error.InvalidSettings;
    const parsed = try std.json.parseFromValueLeaky(Settings, scratch, document, .{ .ignore_unknown_fields = true });
    var defaults: ?[]const []const u8 = null;
    if (document.object.get("defaultTools")) |value| {
        var names: std.ArrayList([]const u8) = .empty;
        if (value == .array) for (value.array.items) |item| {
            if (item == .string) try names.append(a, try a.dupe(u8, item.string));
        };
        defaults = try names.toOwnedSlice(a);
    }
    return .{ .preferences = try parsed.ownTheme(a), .default_tools = defaults };
}

pub fn ownTheme(self: Settings, a: std.mem.Allocator) !Settings {
    var copy = self;
    if (self.theme) |name| copy.theme = try a.dupe(u8, name);
    return copy;
}

pub fn save(self: Settings, a: std.mem.Allocator, io: Io, path: []const u8, item: Item) !Settings {
    const dir = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const lock_path = try std.mem.concat(a, u8, &.{ path, ".lock" });
    defer a.free(lock_path);
    const lock = try dir.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    var storage: std.heap.ArenaAllocator = .init(a);
    defer storage.deinit();
    const scratch = storage.allocator();
    var document = if (try read(scratch, io, path)) |bytes|
        try std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{})
    else
        std.json.Value{ .object = .{} };
    if (document != .object) return error.InvalidSettings;
    switch (item) {
        inline else => |field| {
            const name = @tagName(field);
            if (@field(self, name)) |value| {
                const json_value: std.json.Value = switch (@typeInfo(@TypeOf(value))) {
                    .bool => .{ .bool = value },
                    .@"enum" => .{ .string = @tagName(value) },
                    .pointer => .{ .string = value },
                    else => unreachable,
                };
                try document.object.put(scratch, name, json_value);
            } else _ = document.object.orderedRemove(name);
        },
    }
    const parsed = try std.json.parseFromValueLeaky(Settings, scratch, document, .{ .ignore_unknown_fields = true });
    const settings = try parsed.ownTheme(a);
    errdefer if (settings.theme) |name| a.free(name);
    const json = try std.json.Stringify.valueAlloc(scratch, document, .{ .whitespace = .indent_2 });
    var write = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer write.deinit(io);
    try write.file.writeStreamingAll(io, json);
    try write.file.writeStreamingAll(io, "\n");
    try write.file.sync(io);
    try write.replace(io);
    return settings;
}
