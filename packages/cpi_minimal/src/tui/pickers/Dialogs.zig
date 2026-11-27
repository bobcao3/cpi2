const std = @import("std");
const kit = @import("kit");
const Auth = @import("../../providers.zig").Auth;
const Editor = @import("kit").tui.Editor;
const Controller = @import("../../session.zig").Controller;
const md = @import("../transcript.zig").markdown;
const Presentation = @import("../UiPresentation.zig");
const Self = @This();
const tui = kit.tui;

pub const Step = Presentation.DialogStep;
pub const Action = union(enum) {
    none,
    cancel,
    device,
    login_models,
    select_model: []const u8,
    select_custom: []const u8,
    forget: Auth.Kind,
};
const ProviderChoice = struct { kind: Auth.Kind, text: []const u8 };
const field_warning_bytes = 8192;
a: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
editor: Editor,
step: Step,
selected: usize = 0,
record: Auth.Record = .{ .kind = .compatible, .base_url = "", .model = "", .token = "" },
models: []const []const u8 = &.{},
model_view: std.heap.ArenaAllocator,
providers: []const ProviderChoice = &.{},
message: []const u8 = "",
filter: []const u8 = "",
custom_endpoint: []const u8 = "",
custom_account: []const u8 = "",
authorization_saved: bool = false,
key_login: bool = false,
forget_kind: ?Auth.Kind = null,

pub fn create(a: std.mem.Allocator, step: Step) !*Self {
    const self = try a.create(Self);
    self.* = .{ .a = a, .arena = .init(a), .model_view = .init(a), .editor = .init(a), .step = step };
    return self;
}

pub fn providerPicker(a: std.mem.Allocator, auth: *const Auth.Store, labels: *const Presentation.DialogLabels, saved_only: bool) !?*Self {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var snapshot = auth.*;
    if (saved_only) {
        snapshot.a = scratch.allocator();
        try snapshot.reload();
        if (snapshot.document.profiles.len == 0) return null;
    }
    const self = try create(a, if (saved_only) .logout else .providers);
    errdefer self.destroy();
    const owned = self.arena.allocator();
    const kinds = std.enums.values(Auth.Kind);
    const choices = try owned.alloc(ProviderChoice, kinds.len);
    var length_choices: usize = 0;
    for (kinds) |kind| {
        const saved = snapshot.find(kind) != null;
        if (saved_only and !saved) continue;
        const text = labels.provider(kind).label;
        choices[length_choices] = .{ .kind = kind, .text = if (saved_only) text else try std.fmt.allocPrint(owned, "{s} · {s}", .{ text, if (saved) "saved; authorize again" else "not saved" }) };
        length_choices += 1;
    }
    self.providers = choices[0..length_choices];
    return self;
}

pub fn destroy(self: *Self) void {
    self.clearSecret();
    self.editor.deinit();
    self.model_view.deinit();
    self.arena.deinit();
    self.a.destroy(self);
}
fn clearSecret(self: *Self) void {
    if (self.record.token.len > 0) std.crypto.secureZero(u8, @constCast(self.record.token));
    self.record.token = "";
    if (self.record.refresh) |refresh| std.crypto.secureZero(u8, @constCast(refresh));
    self.record.refresh = null;
    self.editor.wipe();
}
pub fn copy(self: *Self, text: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, text);
}
pub fn copyRecord(self: *Self, record: Auth.Record) !void {
    const next = try Auth.cloneRecord(self.arena.allocator(), record);
    self.clearSecret();
    self.record = next;
}
fn validateRecord(self: *Self, record: Auth.Record) !void {
    const candidate = try Auth.provider(self.a, record);
    defer self.a.destroy(candidate);
    defer candidate.deinit();
    defer std.crypto.secureZero(u8, candidate.api_key);
}

pub fn begin(self: *Self, kind: Auth.Kind, controller: *Controller) !Action {
    self.clearSecret();
    self.editor.clear();
    self.record = .{ .kind = kind, .base_url = "", .model = "", .token = "" };
    self.selected = 0;
    self.key_login = kind != .openai;
    if (kind == .openai) {
        self.step = .waiting;
        self.message = "Requesting OpenAI device login. Esc cancels.";
        return .device;
    }
    if (kind == .deepseek) {
        self.record.base_url = "https://api.deepseek.com";
        if (controller.settings.registry) |registry| {
            for (registry.providers()) |entry| {
                if (!std.mem.eql(u8, entry.base_url, self.record.base_url)) continue;
                for (entry.models) |model| {
                    if (!model.supports("openai-responses")) continue;
                    self.record.model = model.id;
                    break;
                }
            }
        }
        self.step = .key;
    } else {
        self.step = .endpoint;
        try self.editor.insert("https://");
    }
    self.message = "Local validation only; the first model request tests server authorization.";
    return .none;
}
pub fn setModels(self: *Self, models: []const []const u8) !void {
    var next: std.heap.ArenaAllocator = .init(self.a);
    errdefer next.deinit();
    const a = next.allocator();
    const focused = if (self.step == .models) if (self.selection()) |index| self.models[index] else null else null;
    const owned = try a.alloc([]const u8, models.len);
    var visible: usize = 0;
    var selected: usize = 0;
    for (models, owned) |text, *out| {
        out.* = try a.dupe(u8, text);
        if (self.matches(text)) {
            if (focused) |old| if (std.mem.eql(u8, old, text)) {
                selected = visible;
            };
            visible += 1;
        }
    }
    self.model_view.deinit();
    self.model_view = next;
    self.models = owned;
    self.selected = selected;
}
fn length(self: *Self) usize {
    return switch (self.step) {
        .providers, .logout => self.providers.len,
        .models => self.models.len,
        else => 0,
    };
}
fn label(self: *Self, index: usize) []const u8 {
    return switch (self.step) {
        .providers, .logout => self.providers[index].text,
        .models => self.models[index],
        else => "",
    };
}
pub fn matches(self: *Self, text: []const u8) bool {
    const query = self.editor.text();
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(text[offset..][0..query.len], query)) return true;
    }
    return false;
}
fn matchesIndex(self: *Self, index: usize) bool {
    return self.matches(self.label(index));
}
pub fn count(self: *Self) usize {
    var total: usize = 0;
    for (0..self.length()) |index| if (self.matchesIndex(index)) {
        total += 1;
    };
    return total;
}
fn selection(self: *Self) ?usize {
    var visible: usize = 0;
    for (0..self.length()) |index| {
        if (!self.matchesIndex(index)) continue;
        if (visible == self.selected) return index;
        visible += 1;
    }
    return null;
}
pub fn paste(self: *Self, bytes: []const u8, controller: *Controller) !void {
    if (self.step == .waiting or self.step == .confirm) {
        self.message = "Close this dialog before pasting.";
        return;
    }
    const field = std.mem.trim(u8, bytes, "\r\n");
    if (std.mem.indexOfAny(u8, field, "\r\n\x1b") != null) return error.SingleLineRequired;
    const previous_length = self.editor.text().len;
    try self.editor.insert(field);
    if (previous_length <= field_warning_bytes) {
        controller.warnSize("dialog input", "bytes", self.editor.text().len, field_warning_bytes);
    }
    self.selected = 0;
}
fn back(self: *Self) !void {
    self.selected = 0;
    self.message = "";
    switch (self.step) {
        .custom => {
            self.step = .models;
            try self.editor.set(self.filter);
        },
        .models => if (self.key_login) {
            self.clearSecret();
            self.editor.clear();
            self.step = .key;
        },
        .key => {
            self.clearSecret();
            self.editor.clear();
            if (self.record.kind == .compatible) {
                self.step = .endpoint;
                try self.editor.insert(self.record.base_url);
            } else self.step = .providers;
        },
        .endpoint => {
            self.editor.clear();
            self.step = .providers;
        },
        else => {},
    }
}
pub fn key(self: *Self, k: kit.terminal.keys.Key, controller: *Controller) !Action {
    if (k.code == .escape or (k.code == .char and k.mods.ctrl and (k.code.char == 'c' or k.code.char == 'd'))) return .cancel;
    if (self.step == .waiting) return .none;
    if (k.code == .char and k.mods.ctrl and k.code.char == 'b') {
        try self.back();
        return .none;
    }
    if (k.code == .char and k.mods.ctrl and k.code.char == 'n' and self.step == .models) {
        self.filter = try self.copy(self.editor.text());
        self.step = .custom;
        self.editor.clear();
        try self.editor.insert(self.filter);
        return .none;
    }
    const picker = self.length() > 0 or self.step == .models;
    if (picker and (k.code == .up or k.code == .down or k.code == .tab)) {
        const n = self.count();
        if (n != 0) self.selected = if (k.code == .up or (k.code == .tab and k.mods.shift)) (self.selected + n - 1) % n else (self.selected + 1) % n;
        return .none;
    }
    if (k.code == .enter) {
        const text = std.mem.trim(u8, self.editor.text(), " \t\r\n");
        switch (self.step) {
            .providers, .logout => {
                const choice = self.providers[self.selection() orelse return .none];
                return if (self.step == .logout) .{ .forget = choice.kind } else self.begin(choice.kind, controller);
            },
            .endpoint => {
                var check = self.record;
                check.base_url = text;
                check.model = "check";
                check.token = "check";
                try self.validateRecord(check);
                self.record.base_url = try self.copy(text);
                self.editor.clear();
                self.step = .key;
            },
            .key => {
                if (text.len == 0) return error.MissingCredential;
                var check = self.record;
                check.token = text;
                check.model = "check";
                try self.validateRecord(check);
                const token = try self.copy(text);
                self.clearSecret();
                self.record.token = token;
                self.editor.clear();
                self.step = .models;
                self.custom_endpoint = self.record.base_url;
                return .login_models;
            },
            .models => {
                const index = self.selection() orelse {
                    self.message = "No matching models. Ctrl+N enters a custom ID explicitly.";
                    return .none;
                };
                return .{ .select_model = try self.copy(self.models[index]) };
            },
            .custom => {
                if (text.len == 0) return error.MissingModel;
                return .{ .select_custom = try self.copy(text) };
            },
            .confirm => return .{ .forget = self.forget_kind.? },
            .waiting => unreachable,
        }
        return .none;
    }
    if (self.step == .confirm) return .none;
    const before = std.hash.Wyhash.hash(0, self.editor.text());
    if (Editor.keyMotion(k)) |motion| {
        try self.editor.move(motion);
    } else if (k.code == .char and !k.mods.ctrl) {
        var bytes: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(k.code.char, &bytes);
        try self.paste(bytes[0..n], controller);
    }
    if (before != std.hash.Wyhash.hash(0, self.editor.text())) self.selected = 0;
    return .none;
}
pub fn draw(self: *Self, a: std.mem.Allocator, children: *std.ArrayList(tui.Node), layout: *const Presentation.DialogLabels) !void {
    for (layout.rows) |row| {
        const value = switch (row.component) {
            .title => switch (self.step) {
                inline else => |step| @field(layout.title, @tagName(step)),
            },
            .hint => layout.hint,
            .text => "",
            .destination => if (self.step == .custom) try md.clean(a, self.custom_endpoint) else continue,
            .account => account: {
                if (self.step != .custom) continue;
                const account = self.record.account_id orelse self.custom_account;
                if (account.len == 0) continue;
                break :account try md.clean(a, account);
            },
            .message => if (self.message.len != 0) try md.clean(a, self.message) else continue,
            .gap => {
                try children.append(a, .{ .spacer = 1 });
                continue;
            },
            .choices => {
                try self.drawChoices(a, children, row);
                continue;
            },
            .input => {
                if (self.step == .waiting or self.step == .confirm) continue;
                const secret = self.step == .key;
                const text = self.editor.text();
                const shown = if (!secret) try md.clean(a, text) else if (text.len == 0) "" else "********";
                const before = if (secret) shown else try md.clean(a, text[0..self.editor.cursor]);
                var input = tui.text(try std.mem.concat(a, u8, &.{ row.text, shown }), row.look);
                const measure = kit.terminal.span_display_width.measure;
                input.text.cursor_column = std.math.cast(u16, measure(row.text) + measure(before));
                try children.append(a, input);
                continue;
            },
        };
        const text = if (row.text.len == 0) value else try std.mem.concat(a, u8, &.{ row.text, value });
        try children.append(a, tui.text(text, row.look));
    }
}

fn drawChoices(self: *Self, a: std.mem.Allocator, children: *std.ArrayList(tui.Node), row: Presentation.DialogLabels.Widget) !void {
    const choice_count = self.length();
    if (choice_count == 0 and self.step != .models) return;
    var visible: usize = 0;
    const first = self.selected -| 4;
    for (0..choice_count) |index| {
        if (!self.matchesIndex(index)) continue;
        defer visible += 1;
        if (visible < first) continue;
        if (visible == first + 8) break;
        const selected = visible == self.selected;
        const text = try std.mem.concat(a, u8, &.{ if (selected) "> " else "  ", try md.clean(a, self.label(index)) });
        try children.append(a, tui.text(text, if (selected) .accent else row.look));
    }
    if (visible == 0 and row.text.len != 0) try children.append(a, tui.text(row.text, row.look));
}
