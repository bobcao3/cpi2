const std = @import("std");
const builtin = @import("builtin");
const registry = @import("model_registry");
const kit = @import("kit");
const keys = kit.terminal.keys;
const tui = kit.tui;
const Settings = @import("../config.zig").Settings;
const Auth = @import("../providers.zig").Auth;
const Syntax = @import("style.zig").Syntax;
const Theme = @import("style.zig").Theme;
const md = @import("transcript.zig").markdown;
const j = @import("../json.zig");
const Self = @This();

startup: struct { compact: []const Row, header: []const Row, expanded: []const Row },
commands: []Command,
settings: []const Settings.MenuEntry,
search: SearchCards,
tools: ToolCards,
syntax: Syntax.ScopeStyles = .{},
shortcuts: std.enums.EnumFieldStruct(Shortcut, Chord, null),
pending_hint: []const u8,
queue_labels: struct { steering: []const u8, follow_up: []const u8 },
footer: []const FooterRow = &.{},
shell: struct { collapsed_rows: usize },
transcript: struct { hidden_thinking_label: []const u8 },
session_info: struct { in_memory: []const u8, rows: []const Frame.Decoration = &.{} },
session_export: struct { filename_prefix: []const u8, success: []const u8, failure: []const u8 },
pickers: Pickers,
help: []const u8,
hotkeys: []const u8,

pub const FooterRow = enum { location, status };

pub const Row = struct {
    mark: enum { none, title, hints } = .none,
    spans: []const struct {
        role: enum { dim, muted, version },
        text: []const u8,
    } = &.{},
};

pub const ThemeStage = enum { single, automatic, light, dark };
pub const DialogStep = enum { providers, logout, endpoint, key, models, custom, confirm, waiting };
pub const ThemeFrames = std.enums.EnumFieldStruct(ThemeStage, Frame, null);
pub const TreeFilter = enum { default, no_tools, user, labeled, all };
pub const SummaryChoice = enum { navigate, summarize, custom_prompt };
pub const TreeFrames = struct {
    list: Frame,
    confirm: Frame,
    custom_prompt: Frame,
    label: Frame,
    help: []const []const u8 = &.{},
    search_prompt: []const u8,
    filter_suffix: std.enums.EnumFieldStruct(TreeFilter, []const u8, null),
    summary_choices: std.enums.EnumFieldStruct(SummaryChoice, []const u8, null),
};
pub const Pickers = struct {
    fork: Frame,
    thinking: Frame,
    theme: ThemeFrames,
    tree: TreeFrames,
    resume_picker: ResumePicker,
    rename_session: Frame,
    workspace: WorkspacePrompt,
    dialog: DialogLabels,
};

pub const ResumePicker = struct {
    pub const Scope = struct { title: []const u8, empty: []const u8, empty_named: []const u8 };
    frame: Frame,
    current: Scope,
    all: Scope,
    search_hint: []const u8,
    bindings: []const u8,
    path_hint: [2][]const u8,
    rename_hint: []const u8,
    delete_confirmation: []const u8,
};

pub const WorkspacePrompt = struct {
    title_prefix: []const u8,
    proceed: [2][]const u8,
    fork: [2][]const u8,
    cancel: []const u8,
    hint: []const u8,
};

pub const DialogLabels = struct {
    pub const Provider = struct {
        label: []const u8,
        auth_type: enum { oauth, api_key },
        type_label: []const u8,
    };
    pub const Widget = struct {
        component: enum { title, destination, account, message, choices, input, hint, text, gap },
        text: []const u8 = "",
        look: tui.Look = .plain,
    };

    title: std.enums.EnumFieldStruct(DialogStep, []const u8, null),
    hint: []const u8,
    rows: []const Widget = &.{},
    providers: std.enums.EnumFieldStruct(Auth.Kind, Provider, null),
    no_saved_providers: []const u8,

    pub fn provider(self: *const DialogLabels, kind: Auth.Kind) Provider {
        return switch (kind) {
            inline else => |id| @field(self.providers, @tagName(id)),
        };
    }
};

pub const Frame = struct {
    before: []const Decoration = &.{},
    after: []const Decoration = &.{},

    pub const Decoration = struct {
        kind: enum { text, gap, rule } = .text,
        text: []const u8 = "",
        field: ?[]const u8 = null,
        role: ?Theme.Role = null,
        bold: bool = false,
        clip: bool = false,
    };

    pub fn append(a: std.mem.Allocator, nodes: *std.ArrayList(tui.Node), rows: []const Decoration, columns: u16, palette: *const Theme.Palette) !void {
        return appendBound(a, nodes, rows, columns, palette, .null);
    }

    pub fn appendBound(a: std.mem.Allocator, nodes: *std.ArrayList(tui.Node), rows: []const Decoration, columns: u16, palette: *const Theme.Palette, data: j.Value) !void {
        for (rows) |row| {
            var style = if (row.role) |role| palette.style(role) else tui.Style{};
            style.bold = row.bold;
            const text = if (row.kind == .rule)
                try md.horizontalRule(a, columns)
            else if (row.field) |key| bound: {
                const value = j.text(j.get(data, key));
                if (value.len == 0) continue;
                if (row.text.len == 0) break :bound value;
                var color: [96]u8 = undefined;
                const line = try std.mem.concat(a, u8, &.{ style.sgr(&color), row.text, "\x1b[0m ", value });
                style = .{};
                break :bound line;
            } else row.text;
            try nodes.append(a, if (row.kind == .gap) .{ .spacer = 1 } else .{ .text = .{
                .bytes = text,
                .style = style,
                .overflow = if (row.clip) .clip else .wrap,
            } });
        }
    }
};

pub const Command = struct {
    pub const Action = enum { settings, quit, copy, help, hotkeys, name, session, export_session, draft, queue, outcome, reset, fork, clone, compact, new, @"resume", tree, forget, login, logout, model, @"continue", reload, thinking, select, send, unknown };
    pub const ArgumentCompletion = union(enum) {
        model,
        thinking,
        login,
        choices: []const []const u8,

        pub fn jsonParseFromValue(a: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) !ArgumentCompletion {
            return switch (value) {
                .string => switch (std.meta.stringToEnum(enum { model, thinking, login }, value.string) orelse return error.InvalidEnumTag) {
                    inline else => |source| @unionInit(ArgumentCompletion, @tagName(source), {}),
                },
                .array => .{ .choices = try std.json.parseFromValueLeaky([]const []const u8, a, value, options) },
                .object => if (value.object.count() == 0) .{ .choices = &.{} } else error.UnexpectedToken,
                else => error.UnexpectedToken,
            };
        }
    };

    name: []const u8,
    action: Action = .unknown,
    description: []const u8,
    arguments: enum { any, none, exact } = .any,
    completion: ?ArgumentCompletion = null,
};

pub const SearchCard = struct {
    heading: enum { regex, pattern, file },
    collapsed_rows: usize,
    limit: [2][]const u8,
    warning_field: []const u8,
    warning_unit: []const u8,
};

pub const SearchCards = struct {
    grep: SearchCard,
    find: SearchCard,
    ls: SearchCard,
    byte_warning: []const u8,
    line_warning: []const u8,
};

pub const Tool = enum { read, write, edit, bash, grep, find, ls, execute_lua, other };
pub const ToolCards = std.enums.EnumFieldStruct(Tool, []const ToolSection, &.{});
pub const ToolSection = struct {
    component: enum { result, content, error_message, read_limit, image_warning, diff, tail, shell_warning, duration, script_source, script_calls, script_output, search_warning },
    when: enum { always, complete, expanded_or_failed, failed } = .always,
    collapsed_rows: ?usize = null,
    highlight: bool = false,
    show_total: bool = false,
};

pub const Shortcut = enum { expand_tools, toggle_thinking, cycle_thinking, select_model, external_editor, follow_up, restore_queued };
const Chord = struct {
    label: []const u8,
    code: keys.Code,
    mods: keys.Modifiers,

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Chord {
        if (value != .string) return error.UnexpectedToken;
        const label = value.string;
        if (std.mem.eql(u8, label, "shift+tab")) return .{ .label = label, .code = .tab, .mods = .{ .shift = true } };
        if (std.mem.eql(u8, label, "alt+enter")) return .{ .label = label, .code = .enter, .mods = .{ .alt = true } };
        if (std.mem.eql(u8, label, "alt+up")) return .{ .label = label, .code = .up, .mods = .{ .alt = true } };
        var parts = std.mem.splitScalar(u8, label, '+');
        var mods: keys.Modifiers = .{};
        while (parts.next()) |part| {
            if (parts.index == null and part.len == 1 and std.ascii.isLower(part[0]) and (mods.ctrl or mods.alt)) {
                if ((mods.ctrl and std.mem.indexOfScalar(u8, "cdjvxz", part[0]) != null) or (mods.alt and part[0] == 'v'))
                    return error.InvalidCharacter;
                return .{ .label = label, .code = .{ .char = part[0] }, .mods = mods };
            }
            if (std.mem.eql(u8, part, "ctrl") and !mods.ctrl) mods.ctrl = true else if (std.mem.eql(u8, part, "alt") and !mods.alt)
                mods.alt = true
            else if (std.mem.eql(u8, part, "shift") and !mods.shift)
                mods.shift = true
            else
                return error.InvalidCharacter;
        }
        return error.InvalidCharacter;
    }

    fn matches(self: Chord, code: keys.Code, mods: keys.Modifiers) bool {
        return std.meta.eql(self.code, code) and self.mods == mods;
    }
};

pub fn shortcut(self: *const Self, input: keys.Key) ?Shortcut {
    var mods = input.mods;
    mods.caps_lock = false;
    mods.num_lock = false;
    const code: keys.Code = if (input.code == .char and input.code.char < 128)
        .{ .char = std.ascii.toLower(@intCast(input.code.char)) }
    else
        input.code;
    inline for (std.enums.values(Shortcut)) |action| {
        if (@field(self.shortcuts, @tagName(action)).matches(code, mods)) return action;
    }
    return null;
}

pub fn usesWindowsBindings(env: *const std.process.Environ.Map) bool {
    const distro: []const u8 = env.get("WSL_DISTRO_NAME") orelse "";
    const interop: []const u8 = env.get("WSL_INTEROP") orelse "";
    return builtin.os.tag == .windows or (builtin.os.tag == .linux and (distro.len != 0 or interop.len != 0));
}

pub const Launch = struct {
    a: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    config_dir: ?[]const u8,
    document: ?std.json.Parsed(Self) = null,
    warning: ?anyerror = null,

    pub fn get(self: *Launch) !*const Self {
        if (self.document) |*document| return &document.value;
        self.document = load(self.a, self.io, self.config_dir, self.environ) catch |err| fallback: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            self.warning = err;
            break :fallback try load(self.a, self.io, null, self.environ);
        };
        return &self.document.?.value;
    }

    pub fn deinit(self: *Launch) void {
        if (self.document) |document| document.deinit();
    }
};

fn load(a: std.mem.Allocator, io: std.Io, config_dir: ?[]const u8, environ: *const std.process.Environ.Map) !std.json.Parsed(Self) {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const customization = if (config_dir) |directory| custom: {
        const path = try std.fs.path.join(temporary, &.{ directory, "ui.luau" });
        break :custom std.Io.Dir.cwd().readFileAlloc(io, path, temporary, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    } else null;
    const source = try std.mem.concat(temporary, u8, &.{
        try std.fmt.allocPrint(temporary, "local jobControl, windowsKeys, macKeys = {}, {}, {}\n", .{ kit.terminal.job_control.supported, usesWindowsBindings(environ), builtin.os.tag == .macos }),
        @embedFile("ui_presentation.luau"),
        if (customization != null) "\nlocal function customize(ui)\n" else "",
        customization orelse "",
        if (customization != null) "\nend\ncustomize(ui)\n" else "",
        "\nreturn finish()\n",
    });
    var document = try registry.parseLuaValue(a, source);
    errdefer document.deinit();
    if (customization != null) try validateText(document.value, 32);
    const value = try std.json.parseFromValueLeaky(Self, document.arena.allocator(), document.value, .{});
    const actions = std.enums.values(Shortcut);
    inline for (actions, 0..) |action, index| {
        const chord = @field(value.shortcuts, @tagName(action));
        inline for (actions[0..index]) |other| {
            if (@field(value.shortcuts, @tagName(other)).matches(chord.code, chord.mods)) return error.DuplicateShortcut;
        }
    }
    var command_names: std.StringHashMapUnmanaged(void) = .empty;
    for (value.commands) |*entry| {
        if (entry.name.len < 2 or entry.name[0] != '/' or std.mem.indexOfAny(u8, entry.name, " \t\n") != null)
            return error.InvalidCommandName;
        if ((try command_names.getOrPut(temporary, entry.name)).found_existing) return error.DuplicateCommand;
        if (entry.action == .unknown) entry.action = std.meta.stringToEnum(Command.Action, entry.name[1..]) orelse .unknown;
    }
    var settings: std.EnumSet(Settings.Item) = .{};
    for (value.settings) |entry| {
        if (settings.contains(entry.id)) return error.DuplicateSetting;
        settings.insert(entry.id);
    }
    return .{ .arena = document.arena, .value = value };
}

fn validateText(value: std.json.Value, remaining: u8) error{ InvalidPresentationText, PresentationTooDeep }!void {
    if (remaining == 0) return error.PresentationTooDeep;
    switch (value) {
        .string => |bytes| {
            const utf8 = std.unicode.Utf8View.init(bytes) catch return error.InvalidPresentationText;
            var it = utf8.iterator();
            while (it.nextCodepoint()) |cp| {
                if ((cp < 32 and cp != '\n' and cp != '\t') or (cp >= 127 and cp <= 159))
                    return error.InvalidPresentationText;
            }
        },
        .array => |list| for (list.items) |item| try validateText(item, remaining - 1),
        .object => |object| for (object.values()) |item| try validateText(item, remaining - 1),
        else => {},
    }
}

pub fn command(self: *const Self, name: []const u8) ?Command {
    for (self.commands) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}
