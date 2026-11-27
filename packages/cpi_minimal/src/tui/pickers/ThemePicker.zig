const std = @import("std");
const kit = @import("kit");
const Theme = @import("../style.zig").Theme;
const Presentation = @import("../UiPresentation.zig");

const Picker = @This();
const tui = kit.tui;
const Allocator = std.mem.Allocator;
const Key = kit.terminal.keys.Key;
const automatic = "/";

pub const Selection = union(enum) {
    single: []const u8,
    paired: Theme.Pair,

    pub fn format(self: Selection, a: Allocator) ![]const u8 {
        return switch (self) {
            .single => |name| name,
            .paired => |pair| try std.fmt.allocPrint(a, "{s}/{s}", .{ pair.light, pair.dark }),
        };
    }
};

pub const Action = union(enum) { none, preview: Theme.Choice, apply: Selection, cancel };

stage: Presentation.ThemeStage = .single,
single: []const u8,
pair: Theme.Pair,
choice_index: usize = 0,
automatic_list: tui.SettingsList,

pub fn init(a: Allocator, theme: *const Theme.Session, value: []const u8) Picker {
    const selected = theme.knownName(value);
    var picker: Picker = .{
        .single = selected,
        .pair = .{ .light = selected, .dark = selected },
        .automatic_list = .init(a),
    };
    picker.automatic_list.searchable = false;
    if (Theme.parsePair(value)) |names| {
        picker.stage = .automatic;
        picker.pair = .{ .light = theme.knownName(names.light), .dark = theme.knownName(names.dark) };
    } else picker.selectIndex(theme, selected);
    return picker;
}

pub fn deinit(self: *Picker) void {
    self.automatic_list.deinit();
}

fn selectIndex(self: *Picker, theme: *const Theme.Session, name: []const u8) void {
    self.choice_index = 0;
    for (theme.entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, name, entry.name)) continue;
        self.choice_index = index + @as(usize, @intFromBool(self.stage == .single and index != 0));
        return;
    }
}

fn previewPair(self: *const Picker, theme: *const Theme.Session) Action {
    return .{ .preview = theme.resolvePair(self.pair) };
}

fn current(self: *const Picker) []const u8 {
    return switch (self.stage) {
        .single => self.single,
        .light => self.pair.light,
        .dark => self.pair.dark,
        .automatic => unreachable,
    };
}

fn active(self: *const Picker, theme: *const Theme.Session) []const u8 {
    return if (theme.system_palette.appearance == .light) self.pair.light else self.pair.dark;
}

fn itemName(self: *const Picker, theme: *const Theme.Session, index: usize) []const u8 {
    if (self.stage == .single and index == 1) return automatic;
    return theme.entries[index - @as(usize, @intFromBool(self.stage == .single and index > 1))].name;
}

fn rows(self: *const Picker) [4]tui.SettingsList.Item {
    return .{
        .{ .label = "Light theme", .value = self.pair.light, .description = "Theme to use in automatic mode when the terminal is light" },
        .{ .label = "Dark theme", .value = self.pair.dark, .description = "Theme to use in automatic mode when the terminal is dark" },
        .{ .label = "Apply", .value = "save and go back", .description = "Save and go back" },
        .{ .label = "Change mode", .value = "switch to single theme", .description = "Switch to one theme for light and dark" },
    };
}

pub fn key(self: *Picker, a: Allocator, theme: *const Theme.Session, input: Key) !Action {
    if (self.stage == .automatic) {
        const actions = self.rows();
        return switch (try self.automatic_list.key(a, &actions, input)) {
            .none => .none,
            .cancel => .cancel,
            .activate => |index| switch (index) {
                0, 1 => result: {
                    self.stage = if (index == 0) .light else .dark;
                    self.selectIndex(theme, self.current());
                    break :result .none;
                },
                2 => .{ .apply = .{ .paired = self.pair } },
                3 => result: {
                    self.stage = .single;
                    self.single = self.active(theme);
                    self.selectIndex(theme, self.single);
                    break :result .{ .preview = theme.resolve(self.single) };
                },
                else => unreachable,
            },
        };
    }

    const action = tui.select_list.List.keySelection(&self.choice_index, self.choiceCount(theme), 10, input);
    const name = self.itemName(theme, self.choice_index);
    switch (action) {
        .none => return .none,
        .cancel => {
            if (self.stage == .single) return .cancel;
            self.stage = .automatic;
            return self.previewPair(theme);
        },
        .highlight => return if (std.mem.eql(u8, name, automatic)) self.previewPair(theme) else .{ .preview = theme.resolve(name) },
        .activate => switch (self.stage) {
            .single => {
                if (!std.mem.eql(u8, name, automatic)) return .{ .apply = .{ .single = name } };
                self.stage = .automatic;
                self.automatic_list.selected = 0;
                return self.previewPair(theme);
            },
            .light, .dark => {
                if (self.stage == .light) self.pair.light = name else self.pair.dark = name;
                self.stage = .automatic;
                return self.previewPair(theme);
            },
            .automatic => unreachable,
        },
    }
}

fn choiceCount(self: *const Picker, theme: *const Theme.Session) usize {
    return theme.entries.len + @as(usize, @intFromBool(self.stage == .single));
}

pub fn render(self: *const Picker, a: Allocator, theme: *const Theme.Session, columns: u16, frames: *const Presentation.ThemeFrames) !tui.Node {
    const palette = &theme.palette;
    const frame = switch (self.stage) {
        inline else => |stage| @field(frames, @tagName(stage)),
    };
    var children: std.ArrayList(tui.Node) = .empty;
    try Presentation.Frame.append(a, &children, frame.before, columns, palette);
    if (self.stage == .automatic) {
        const items = self.rows();
        try children.append(a, try self.automatic_list.render(a, &items, columns, palette.settingsStyles()));
    } else {
        const items = try a.alloc(tui.select_list.Item, self.choiceCount(theme));
        for (items, 0..) |*item, index| {
            const name = self.itemName(theme, index);
            item.* = if (std.mem.eql(u8, name, automatic))
                .{ .value = name, .label = "  automatic", .description = "Use separate themes for light and dark terminal appearance" }
            else
                .{
                    .value = name,
                    .label = try std.mem.concat(a, u8, &.{ if (std.mem.eql(u8, name, self.current())) "✓ " else "  ", name }),
                    .description = if (std.mem.eql(u8, name, Theme.system_name)) "Theme created from your terminal's colors" else "",
                };
        }
        const list: tui.select_list.List = .{ .items = items, .selected = self.choice_index, .capacity = 10, .min_primary = 12 };
        try children.append(a, try list.render(a, columns, .{
            .selected = palette.color(.accent),
            .description = palette.color(.muted),
            .description_faint = palette.style(.muted).faint,
            .scroll = palette.color(.dim),
            .scroll_faint = palette.style(.dim).faint,
        }));
    }
    try Presentation.Frame.append(a, &children, frame.after, columns, palette);
    return .{ .stack = .{ .children = children.items } };
}
