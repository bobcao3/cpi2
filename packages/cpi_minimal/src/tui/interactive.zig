const std = @import("std");
const effort = @import("agent").thinking;
const builtin = @import("builtin");
const kit = @import("kit");
const tui = kit.tui;
const Controller = @import("../session.zig").Controller;
const AssistantContent = @import("../session.zig").AssistantContent;
const j = @import("../json.zig");
const Editor = @import("kit").tui.Editor;
const Input = @import("Input.zig");
const Auth = @import("../providers.zig").Auth;
const Dialogs = @import("pickers.zig").Dialogs;
const UiPresentation = @import("UiPresentation.zig");
const Completion = @import("composer.zig").Completion;
const Settings = @import("../config.zig").Settings;
const ModelChoices = @import("../providers.zig").ModelChoices;
const ModelRoutes = @import("../providers.zig").ModelRoutes;
const registry = @import("model_registry");
const UiWake = @import("UiWake.zig");
const SessionName = @import("../session.zig").SessionName;
const FooterView = @import("FooterView.zig");
const SessionExport = @import("../session.zig").SessionExport;
const WorkspaceBranch = @import("WorkspaceBranch.zig");
const WorkspaceSession = @import("../session.zig").WorkspaceSession;
const md = @import("transcript.zig").markdown;
const ToolView = @import("transcript.zig").ToolView;
const Theme = @import("style.zig").Theme;
const ThemePicker = @import("pickers.zig").ThemePicker;
const terminal_colors = kit.terminal.colors;
const SessionTree = @import("pickers.zig").SessionTree;
const ForkSelector = @import("pickers.zig").ForkSelector;
const SessionSelector = @import("pickers.zig").SessionSelector;

const MissingWorkspace = struct {
    arena: std.heap.ArenaAllocator,
    replacement: Controller.SessionReplacement,
    prompt: WorkspacePrompt,

    fn deinit(self: *MissingWorkspace) void {
        self.replacement.deinit();
        self.arena.deinit();
    }
};

pub const WorkspaceChoice = enum { proceed, fork, cancel };

const WorkspacePrompt = struct {
    missing: []const u8,
    current: []const u8,
    selected: usize = 0,

    fn key(self: *WorkspacePrompt, input: kit.terminal.keys.Key) ?WorkspaceChoice {
        if (input.mods.alt or input.mods.shift or input.mods.super or input.mods.hyper or input.mods.meta) return null;
        if (input.mods.ctrl) {
            if (input.code == .char and input.code.char == 'c') return .cancel;
            if (input.code == .char and input.code.char == 'j') return @fromBackingInt(@intCast(self.selected));
            return null;
        }
        switch (input.code) {
            .up => self.selected -|= 1,
            .down => self.selected = @min(self.selected + 1, 2),
            .char => |c| switch (c) {
                'k' => self.selected -|= 1,
                'j' => self.selected = @min(self.selected + 1, 2),
                else => {},
            },
            .enter => return @fromBackingInt(@intCast(self.selected)),
            .escape => return .cancel,
            else => {},
        }
        return null;
    }

    fn draw(self: *const WorkspacePrompt, a: std.mem.Allocator, nodes: *std.ArrayList(tui.Node), columns: u16, palette: *const Theme.Palette, labels: *const UiPresentation.WorkspacePrompt) !void {
        const rule = palette.text(.border, try md.horizontalRule(a, columns));
        const missing = try md.clean(a, self.missing);
        const current = try md.clean(a, self.current);
        const title = try std.mem.concat(a, u8, &.{ labels.title_prefix, missing });
        var style = palette.style(.accent);
        style.bold = true;
        const choices = [_][]const u8{
            try std.mem.concat(a, u8, &.{ labels.proceed[0], current, labels.proceed[1] }),
            try std.mem.concat(a, u8, &.{ labels.fork[0], current, labels.fork[1] }),
            labels.cancel,
        };
        const content = try a.alloc(tui.Node, 9);
        content[0..3].* = .{ .{ .spacer = 1 }, .{ .text = .{ .bytes = title, .style = style } }, .{ .spacer = 1 } };
        for (choices, 0.., content[3..6]) |choice, i, *row| {
            const selected = i == self.selected;
            const line = try std.fmt.allocPrint(a, "{s}{s}", .{ if (selected) "→ " else "  ", choice });
            row.* = palette.text(if (selected) .accent else .text, line);
        }
        content[6..9].* = .{ .{ .spacer = 1 }, palette.text(.muted, labels.hint), .{ .spacer = 1 } };
        const padding = @min(1, (columns -| 1) / 2);
        try nodes.appendSlice(a, &.{ rule, .{ .box = .{ .padding = .{ .left = padding, .right = padding }, .children = content } }, rule });
    }
};
const Syntax = @import("style.zig").Syntax;
const ToolImages = @import("transcript.zig").ToolImages;
const TranscriptSelection = @import("transcript.zig").TranscriptSelection;
const FindInTranscript = @import("transcript.zig").FindInTranscript;
const Clipboard = @import("composer.zig").Clipboard;
const EditPreview = @import("transcript.zig").EditPreview;
const ExternalEditor = @import("composer.zig").ExternalEditor;
const ShellInput = @import("transcript.zig").ShellInput;
const ComposerView = @import("composer.zig").ComposerView;
const StartupView = @import("StartupView.zig");
const QuietStartup = @import("../config.zig").QuietStartup;
const job_control = kit.terminal.job_control;
const Io = std.Io;
const Event = Controller.Event;
const Timings = @import("Timings.zig");
const Stamp = kit.timing.Timestamp;

fn promptHistory(raw: ?*anyopaque, a: std.mem.Allocator, index: usize) !?[]const u8 {
    const controller: *Controller = @ptrCast(@alignCast(raw.?));
    return controller.promptHistory(a, index);
}

const Owned = struct {
    arena: std.heap.ArenaAllocator,
    event: Event,
    emitted: ?Stamp,
    fn destroy(self: *Owned, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
const Mailbox = struct {
    a: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    wake: *UiWake,
    timed: bool,
    pending: std.ArrayList(*Owned) = .empty,
    fn emit(context: ?*anyopaque, event: Event) anyerror!void {
        const self: *Mailbox = @ptrCast(@alignCast(context.?));
        const emitted = if (self.timed and event.kind == .text_delta and event.text.len != 0) Stamp.now() else null;
        const owned = try self.a.create(Owned);
        owned.* = .{ .arena = .init(self.a), .event = event, .emitted = emitted };
        errdefer owned.destroy(self.a);
        const a = owned.arena.allocator();
        owned.event.text = try a.dupe(u8, event.text);
        owned.event.name = try a.dupe(u8, event.name);
        owned.event.call_id = try a.dupe(u8, event.call_id);
        owned.event.entry_id = try a.dupe(u8, event.entry_id);
        owned.event.tool_delivery = try a.dupe(u8, event.tool_delivery);
        owned.event.data = try j.value(a, event.data);
        owned.event.arguments = try j.copy(a, event.arguments);
        owned.event.images = try Controller.ToolImage.copy(a, event.images);
        owned.event.reply = try event.reply.copy(a);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.pending.append(self.a, owned);
        }
        self.wake.notify();
    }
    fn take(self: *Mailbox) std.ArrayList(*Owned) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pending = self.pending;
        self.pending = .empty;
        return pending;
    }
};
const Job = struct {
    const Branch = struct { id: []const u8, focus: []const u8 };
    controller: *Controller,
    io: Io,
    wake: *UiWake,
    allocator: std.mem.Allocator,
    action: union(enum) { prompt: Controller.Prepared, continue_turn: []const u8, reset: []const u8, compact: []const u8, branch_summary: Branch, recover },
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    failure: ?anyerror = null,
    compaction_result: ?Controller.ManualCompactionResult = null,
    branch_result: ?Controller.TreeNavigation = null,

    fn destroy(self: *Job) void {
        if (self.branch_result) |result| if (result == .navigated) {
            if (result.navigated) |draft| self.allocator.free(draft);
        };
        self.allocator.destroy(self);
    }
    fn work(self: *Job) void {
        switch (self.action) {
            .continue_turn => |id| self.controller.continueQueued(id) catch |err| {
                self.failure = err;
            },
            .reset => |id| self.controller.resetQueued(id) catch |err| {
                self.failure = err;
            },
            .compact => |id| {
                if (self.controller.waitManualCompaction(id)) |result| {
                    self.compaction_result = result;
                } else |err| self.failure = err;
            },
            .branch_summary => |branch| {
                if (self.controller.summarizeTree(self.allocator, branch.id, branch.focus)) |result| {
                    self.branch_result = result;
                } else |err| self.failure = err;
            },
            .prompt => |input| self.controller.runPrepared(input) catch |err| {
                self.failure = err;
            },
            .recover => self.controller.resumeInterrupted() catch |err| {
                self.failure = err;
            },
        }
        self.done.set(self.io);
        self.wake.notify();
    }
};
const Arguments = struct {
    call_id: []const u8,
    name: []const u8,
    text: std.ArrayList(u8) = .empty,
    slot: usize,
    edit_preview: ?*EditPreview = null,
    write_highlight: Syntax.WriteCache = .{},
    expansion_override: bool = false,
    script_calls: std.ArrayList(@import("agent").JsonDocument) = .empty,

    fn clearScriptCalls(self: *Arguments, a: std.mem.Allocator) void {
        for (self.script_calls.items) |*call| call.deinit();
        self.script_calls.clearAndFree(a);
    }

    fn deinit(self: *Arguments, a: std.mem.Allocator) void {
        if (self.edit_preview) |preview| preview.destroy(a);
        self.write_highlight.deinit();
        self.clearScriptCalls(a);
        self.text.deinit(a);
        a.free(self.call_id);
        a.free(self.name);
    }
};
const PointerTarget = struct {
    kind: enum { tool, running_tool, thinking, link },
    id: []const u8,
    thinking_run: ?ThinkingRun = null,
    column: u32 = 0,
    row: u32 = 0,
};

const PointerPress = struct {
    target: PointerTarget,
    column: u32,
    row: u32,
};

const ThinkingRun = struct {
    slot: usize,
    ordinal: usize,

    fn order(left: ThinkingRun, right: ThinkingRun) std.math.Order {
        if (left.slot != right.slot) return std.math.order(left.slot, right.slot);
        return std.math.order(left.ordinal, right.ordinal);
    }

    fn mouseKey(self: ThinkingRun) ?u64 {
        const slot = std.math.cast(u32, self.slot + 1) orelse return null;
        const ordinal = std.math.cast(u32, self.ordinal + 1) orelse return null;
        const key = (@as(u64, ordinal) << 32) | slot;
        return if (key < completion_mouse_key) key else null;
    }
};

const status_notice = "status";
const session_info_notice = "session-info";
const error_notice = "error";
const name_notice = "session-name";
const name_warning = "session-name-warning";
const composer_mouse_key = std.math.maxInt(u64);
const settings_mouse_key = composer_mouse_key - 1;
const completion_mouse_key = composer_mouse_key - 2;

const ClipboardFocus = struct {
    component: enum { composer, settings, session, tree, search, dialog },
    lifetime: u64 = 0,
    page: u8 = 0,
};

const App = struct {
    a: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    home: []const u8,
    workspace_branch: WorkspaceBranch = .{},
    session_name: ?[]const u8 = null,
    terminal_title_dirty: bool = true,
    context_usage_known: bool = true,
    hyperlinks: bool,
    controller: *Controller,
    workspace_runtime: *WorkspaceSession,
    mailbox: Mailbox,
    pending_delta: ?Stamp = null,
    scratch: *std.heap.ArenaAllocator,
    view: std.heap.ArenaAllocator,
    picker_rows: usize = 1,
    tree: ?*SessionTree = null,
    fork_selector: ?ForkSelector = null,
    session_selector: ?SessionSelector = null,
    missing_workspace: ?MissingWorkspace = null,
    transcript: std.ArrayList(Event) = .empty,
    tool_images: ToolImages = .{},
    syntax: Syntax.Engine,
    presentation: UiPresentation,
    theme: Theme.Session,
    theme_resources: Theme.Resources,
    theme_picker: ?ThemePicker = null,
    theme_sync_dirty: bool = false,
    saved_theme: ?[]const u8 = null,
    preview: AssistantContent.Builder = .{},
    preview_index: ?usize = null,
    arguments: std.ArrayList(Arguments) = .empty,
    scroll: tui.ScrollState = .{},
    scrollbar: tui.ScrollBar = .{},
    wheel: tui.WheelScroll = .{},
    follow_button: ?tui.Buffer.Rect = null,
    search: ?FindInTranscript = null,
    selection: TranscriptSelection = .{},
    screen_selection: TranscriptSelection = .{},
    composer_rows: u32 = 0,
    composer_press: ?tui.Selection.Point = null,
    clipboard_text: ?struct { text: []u8, flash: bool } = null,
    clipboard_job: ?struct { job: *Clipboard.Job, flash: bool } = null,
    clipboard_flash: ?struct { message: []const u8, until: Io.Timestamp } = null,
    clipboard_reads: std.ArrayList(struct { job: *Clipboard.ReadJob, focus: ?ClipboardFocus }) = .empty,
    clipboard_modal_lifetime: u64 = 0,
    selection_scroll_word: bool = false,
    queue: std.ArrayList(Controller.Prepared) = .empty,
    queue_preview: Controller.QueuePreview,
    compaction_inputs: std.ArrayList(Controller.CompactionMessage) = .empty,
    waiting_after_compaction: bool = false,
    queue_paused: bool = false,
    preserve_editor: bool = false,
    started: ?Io.Timestamp = null,
    auto_compacting: ?enum { threshold, overflow } = null,
    retry_display: ?struct { info: Controller.RetryProgress, started: Io.Timestamp } = null,
    outcome: ?[]u8 = null,
    outcome_visible: bool = false,
    turn_error: bool = false,
    recovery_required: bool = false,
    job: ?*Job = null,
    user_shell: ?*ShellInput.Job = null,
    completed_shells: std.ArrayList(*ShellInput.Job) = .empty,
    shell_record_retry: ?Io.Timestamp = null,
    editor: Editor,
    expanded: bool = false,
    quiet_startup: QuietStartup,
    startup_default: QuietStartup,
    settings_path: ?[]const u8,
    preferences: Settings,
    pending_mode: ?Settings = null,
    run_defaults: Controller.RunPolicy,
    settings_list: ?tui.SettingsList = null,
    supports_images: bool = false,
    composer_padding: u16 = 0,
    last_escape: ?Io.Timestamp = null,
    startup_logo: bool,
    tool_expansions: std.StringHashMapUnmanaged(void) = .empty,
    pointer_press: ?PointerPress = null,
    url_launches: Io.Group = .init,
    thinking: bool = true,
    thinking_overrides: std.ArrayList(ThinkingRun) = .empty,
    thinking_picker: ?effort.Level = null,
    auth: *Auth.Store,
    auth_revision_seen: u64 = 0,
    dialog: ?*Dialogs = null,
    auth_job: ?*Auth.DeviceJob = null,
    device_code_shown: bool = false,
    completion: ?Completion = null,
    file_lookup: ?*Completion.Lookup = null,
    completion_press: ?struct { item: usize, row: u32, column: u32 } = null,
    routes_arena: std.heap.ArenaAllocator,
    model_routes: []const ModelRoutes.Target = &.{},
    discovery: registry.Refresh,
    routes_dirty: bool = true,
    requested_model: ?[]const u8 = null,
    notice: []const u8 = "",
    model: []const u8 = "",
    path: []const u8 = "",
    quit: bool = false,
    edit_external: bool = false,
    interrupt: ?Io.Timestamp = null,

    fn resetViewport(self: *App) void {
        self.clearPointer();
        self.closeTranscriptSearch();
        self.selection = .{};
        self.screen_selection = .{};
        self.composer_rows = 0;
        self.scroll = .{};
        self.scrollbar = .{};
        self.follow_button = null;
    }

    fn scrollBy(self: *App, rows: i64, now: Io.Timestamp) void {
        const top: i64 = @intCast(self.scroll.top);
        const bottom: i64 = @intCast(self.scroll.content_rows -| self.scroll.viewport_rows);
        const destination = std.math.clamp(top + rows, 0, bottom);
        if (top == destination) {
            if (self.scroll.suppress_follow_at_end) self.scroll.scroll(rows);
            return;
        }
        self.scroll.scroll(destination - top);
        self.scrollbar.reveal(now);
    }

    fn scrollTo(self: *App, row: usize, now: Io.Timestamp) void {
        const target = @min(row, self.scroll.content_rows -| self.scroll.viewport_rows);
        if (target == self.scroll.top and self.scroll.suppress_follow_at_end) {
            self.followEnd(now);
            return;
        }
        self.scrollBy(@as(i64, @intCast(target)) - @as(i64, @intCast(self.scroll.top)), now);
    }

    fn followEnd(self: *App, now: Io.Timestamp) void {
        if (self.scroll.follow_end) return;
        self.scroll.end();
        self.scrollbar.reveal(now);
    }

    fn viewportKey(self: *App, keypress: kit.terminal.keys.Key) bool {
        if (keypress.mods.alt or keypress.mods.super) return false;
        const now = Io.Timestamp.now(self.io, .awake);
        const page: i64 = @max(1, @as(i64, self.scroll.viewport_rows) - 4);
        switch (keypress.code) {
            .page_up, .page_down => {
                if (keypress.mods.ctrl or keypress.mods.shift) return false;
                self.scrollBy(if (keypress.code == .page_up) -page else page, now);
            },
            .home, .end => {
                if (!keypress.mods.ctrl or keypress.mods.shift) return false;
                if (keypress.code == .home) self.scrollTo(0, now) else self.followEnd(now);
            },
            .up, .down => {
                if (!keypress.mods.ctrl) return false;
                const prompt_row = if (keypress.code == .up) self.scroll.previous_stop else self.scroll.next_stop;
                if (prompt_row) |row| self.scrollTo(row, now);
            },
            else => return false,
        }
        return true;
    }

    fn closeTranscriptSearch(self: *App) void {
        if (self.search) |*search| {
            search.deinit();
            self.clipboard_modal_lifetime +%= 1;
        }
        self.search = null;
    }

    fn searchKey(self: *App, k: kit.terminal.keys.Key) !bool {
        const unmodified = !k.mods.alt and !k.mods.super and !k.mods.hyper and !k.mods.meta;
        if (unmodified and k.mods.ctrl and k.mods.shift and k.code == .char and (k.code.char == 'f' or k.code.char == 'F')) {
            if (self.search != null) {
                self.closeTranscriptSearch();
            } else {
                self.clearCompletion();
                self.search = .init(self.a);
                self.clearPointer();
                if (self.selection.active) self.selection.blur();
                self.scrollbar.grab = null;
                self.scrollbar.hover(false, Io.Timestamp.now(self.io, .awake));
            }
            return true;
        }
        const search = if (self.search) |*state| state else return false;
        if (unmodified and !k.mods.ctrl and !k.mods.shift and k.code == .escape) {
            self.closeTranscriptSearch();
        } else if (unmodified and ((k.code == .enter and !k.mods.ctrl) or
            (k.code == .char and k.mods.ctrl and (k.code.char == 'g' or k.code.char == 'G'))))
        {
            search.index.navigate(if (k.mods.shift) .previous else .next);
        } else if (!self.viewportKey(k)) {
            try search.key(k, @intCast(self.scroll.top));
        }
        return true;
    }
    fn setOutcome(self: *App, text: []const u8) !void {
        const owned = try self.a.dupe(u8, text);
        if (self.outcome) |old| self.a.free(old);
        self.outcome = owned;
        self.outcome_visible = true;
    }
    fn createFork(self: *App, anchor: []const u8) !void {
        if (self.controller.session.path == null) return error.ForkRequiresSession;
        const root = @import("agent").TaskJournal.main_conversation;
        const child = try self.controller.forkConversation(self.arena, root, anchor);
        try self.setOutcome(try std.fmt.allocPrint(self.arena, "Fork created. Conversation ID {s}", .{child}));
    }
    fn reportError(self: *App, err: anyerror) void {
        if (self.recovery_required) return;
        self.notice = @errorName(err);
    }
    fn history(self: *App) !void {
        std.debug.assert(self.job == null);
        var next = std.heap.ArenaAllocator.init(self.a);
        errdefer next.deinit();
        const page = try self.controller.historyPage(next.allocator(), null, std.math.maxInt(usize));
        const title = try self.controller.sessionName(self.a);
        errdefer if (title) |label| self.a.free(label);
        self.clearCompletion();
        self.resetViewport();
        self.queue_preview.batch = null;
        try self.transcript.ensureTotalCapacity(self.a, page.events.len);
        self.thinking_overrides.clearRetainingCapacity();
        self.transcript.clearRetainingCapacity();
        self.transcript.appendSliceAssumeCapacity(page.events);
        self.context_usage_known = true;
        var older = std.mem.reverseIterator(page.events);
        while (older.next()) |event| {
            if (event.has_context_usage) break;
            if (event.kind == .compacted) {
                self.context_usage_known = false;
                break;
            }
        }
        if (title == null) {
            self.terminal_title_dirty = self.terminal_title_dirty or self.session_name != null;
        } else if (self.session_name) |old| {
            self.terminal_title_dirty = self.terminal_title_dirty or !std.mem.eql(u8, old, title.?);
        } else self.terminal_title_dirty = true;
        if (self.session_name) |old| self.a.free(old);
        self.session_name = title;
        self.view.deinit();
        self.view = next;
        self.tool_images.clear(self.a);
        self.preview_index = null;
        self.preview.deinit(self.a);
        self.clearArguments();
        self.model = self.controller.modelName();
        self.path = self.controller.sessionPath();
        self.notice = "";
    }
    fn ownEvent(self: *App, event: Event) !Event {
        const a = self.view.allocator();
        var owned = event;
        owned.text = try a.dupe(u8, event.text);
        owned.name = try a.dupe(u8, event.name);
        owned.call_id = try a.dupe(u8, event.call_id);
        owned.entry_id = try a.dupe(u8, event.entry_id);
        owned.tool_delivery = try a.dupe(u8, event.tool_delivery);
        owned.data = try j.copy(a, event.data);
        owned.arguments = try j.copy(a, event.arguments);
        owned.images = try Controller.ToolImage.copy(a, event.images);
        owned.reply = try event.reply.copy(a);
        return owned;
    }

    fn appendEvent(self: *App, event: Event) !void {
        try self.transcript.append(self.a, try self.ownEvent(event));
    }

    fn startUserShell(self: *App, prefix: ShellInput.Prefix) !void {
        if (self.user_shell != null) {
            self.notice = "A bash command is already running. Press Esc to cancel it first.";
            return;
        }
        const deferred = self.job != null and self.manualCompaction() == null;
        try self.completed_shells.ensureUnusedCapacity(self.a, 1);
        try self.editor.remember();
        var running: Event = undefined;
        if (!deferred) {
            try self.transcript.ensureUnusedCapacity(self.a, 1);
            running = try self.ownEvent(.{ .kind = .user_shell, .text = prefix.command, .name = if (prefix.excluded) "excluded" else "" });
        }
        const job = try ShellInput.Job.start(self.a, self.controller, self.mailbox.wake, prefix, deferred);
        self.user_shell = job;
        if (!deferred) {
            running.call_id = &job.id;
            self.transcript.appendAssumeCapacity(running);
        }
        self.notice = "";
        self.editor.clear();
    }

    fn collectUserShell(self: *App, cancel: bool) void {
        const job = self.user_shell orelse return;
        if (cancel) job.future.cancel(self.io) else {
            if (!job.done.isSet()) return;
            job.future.await(self.io);
        }
        self.user_shell = null;
        self.completed_shells.appendAssumeCapacity(job);
    }

    fn showUserShell(self: *App, job: *ShellInput.Job, data: j.Value) !void {
        const event = Event{ .kind = .user_shell, .text = job.prefix.command, .data = data };
        for (self.transcript.items) |*entry| {
            if (entry.kind != .user_shell or !std.mem.eql(u8, entry.call_id, &job.id)) continue;
            // The running card borrows the ID from its job until this replacement.
            entry.data = try j.copy(self.view.allocator(), data);
            entry.call_id = "";
            return;
        }
        try self.appendEvent(event);
    }

    fn placeRunningShell(self: *App) !void {
        const job = self.user_shell orelse return;
        if (!job.deferred) return;
        try self.appendEvent(.{ .kind = .user_shell, .text = job.prefix.command, .call_id = &job.id });
        job.deferred = false;
    }

    fn flushUserShells(self: *App) !void {
        var placed: usize = 0;
        defer {
            const remaining = self.completed_shells.items[placed..];
            @memmove(self.completed_shells.items[0..remaining.len], remaining);
            self.completed_shells.items.len = remaining.len;
        }
        for (self.completed_shells.items) |job| {
            var scratch: std.heap.ArenaAllocator = .init(self.a);
            defer scratch.deinit();
            const a = scratch.allocator();
            const fallback: Controller.UserShell = .{ .command = job.prefix.command, .excluded = job.prefix.excluded, .result = .{} };
            const data = data: {
                const record = job.result catch |err| {
                    self.notice = std.fmt.allocPrint(self.arena, "Bash command failed: {s}", .{@errorName(err)}) catch "Bash command failed";
                    break :data try j.value(a, fallback);
                };
                break :data try self.controller.recordUserShell(a, &job.id, record);
            };
            try self.showUserShell(job, data);
            job.destroy(self.a);
            placed += 1;
        }
    }

    fn settleUserShells(self: *App) bool {
        const now = Io.Timestamp.now(self.io, .awake);
        if (self.shell_record_retry) |due| if (now.compare(.lt, due)) return false;
        self.flushUserShells() catch |err| {
            self.shell_record_retry = now.addDuration(.fromSeconds(1));
            self.notice = std.fmt.allocPrint(self.arena, "Couldn't save bash result. Retrying ({s})", .{@errorName(err)}) catch "Couldn't save bash result. Retrying";
            return false;
        };
        if (self.shell_record_retry != null) self.notice = "";
        self.shell_record_retry = null;
        return true;
    }
    fn resetScratch(self: *App) !void {
        if (self.job != null or self.queue.items.len != 0 or self.compaction_inputs.items.len != 0 or self.dialog != null) return;
        const notice = try self.a.dupe(u8, self.notice);
        defer self.a.free(notice);
        _ = self.scratch.reset(.free_all);
        self.arena = self.scratch.allocator();
        self.notice = try self.arena.dupe(u8, notice);
        self.model = self.controller.modelName();
        self.path = self.controller.sessionPath();
    }

    fn closeTree(self: *App) void {
        if (self.tree) |tree| {
            tree.destroy(self.a);
            self.clipboard_modal_lifetime +%= 1;
        }
        self.tree = null;
    }

    fn closeFork(self: *App) void {
        if (self.fork_selector) |*selector| selector.deinit();
        self.fork_selector = null;
    }

    fn closeSessionSelector(self: *App) void {
        if (self.session_selector) |*selector| {
            selector.deinit();
            self.clipboard_modal_lifetime +%= 1;
        }
        self.session_selector = null;
    }

    fn closeMissingWorkspace(self: *App) void {
        if (self.missing_workspace) |*dialog| dialog.deinit();
        self.missing_workspace = null;
    }

    fn confirmFork(self: *App, id: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.a);
        defer scratch.deinit();
        var fork = try self.controller.prepareInteractiveBranch(scratch.allocator(), .{ .before_prompt = id });
        defer fork.replacement.deinit();
        var draft = try self.editor.prepareText(fork.draft);
        defer draft.deinit();
        self.closeFork();
        try self.installSession(&fork.replacement);
        self.editor.setPrepared(&draft);
        self.notice = "";
        try self.showStatus("Forked to new session");
    }

    fn cloneSession(self: *App) !void {
        try self.editor.remember();
        self.editor.clear();
        var scratch: std.heap.ArenaAllocator = .init(self.a);
        defer scratch.deinit();
        var branch = self.controller.prepareInteractiveBranch(scratch.allocator(), .current) catch |err| {
            if (err != error.UnsavedSession) return err;
            self.notice = "";
            return self.appendEvent(.{
                .kind = .notice,
                .name = error_notice,
                .text = "Error: This session has not been saved yet. Send a message before cloning or forking it.",
            });
        };
        defer branch.replacement.deinit();
        try self.installSession(&branch.replacement);
        self.notice = "";
        try self.showStatus("Cloned to new session");
    }

    fn showStatus(self: *App, message: []const u8) !void {
        const copy = try self.view.allocator().dupe(u8, message);
        if (self.transcript.items.len != 0) {
            const last = &self.transcript.items[self.transcript.items.len - 1];
            if (last.kind == .notice and std.mem.eql(u8, last.name, status_notice)) {
                last.text = copy;
                return;
            }
        }
        try self.transcript.append(self.a, .{ .kind = .notice, .name = status_notice, .text = copy });
    }

    fn showSessionInfo(self: *App) !void {
        if (self.presentation.session_info.rows.len == 0) return;
        const a = self.arena;
        const stats = try self.controller.sessionStats(a);
        const messages = stats.messages;
        const usage = stats.usage;
        const uncached = usage.input +| usage.cache_write;
        const prompt = uncached +| usage.cache_read;
        const show_cache = usage.cache_read != 0 or usage.cache_write != 0;
        const cache_rate = if (show_cache) @as(f64, @floatFromInt(usage.cache_read)) * 100 / @as(f64, @floatFromInt(prompt)) else 0;
        const written = if (usage.cache_write == 0) "" else try std.fmt.allocPrint(a, " ({s} written to cache)", .{try sessionTokenCount(a, usage.cache_write)});
        const data = try j.value(self.view.allocator(), .{
            .name = self.session_name,
            .file = if (self.controller.session.path) |path| try md.clean(a, path) else self.presentation.session_info.in_memory,
            .id = stats.id,
            .messages = try std.fmt.allocPrint(a, "{d}", .{messages.total()}),
            .user = try std.fmt.allocPrint(a, "{d}", .{messages.user}),
            .assistant = try std.fmt.allocPrint(a, "{d}", .{messages.assistant}),
            .tools = try std.fmt.allocPrint(a, "{d} calls, {d} results", .{ messages.tool_calls, messages.tool_results }),
            .input = try sessionTokenCount(a, prompt),
            .cached = if (show_cache) try std.fmt.allocPrint(a, "{s} ({d:.1}%)", .{ try sessionTokenCount(a, usage.cache_read), cache_rate }) else "",
            .uncached = if (show_cache) try std.mem.concat(a, u8, &.{ try sessionTokenCount(a, uncached), written }) else "",
            .output = try sessionTokenCount(a, usage.output),
            .tokens = try sessionTokenCount(a, prompt +| usage.output),
        });
        try self.transcript.append(self.a, .{ .kind = .notice, .name = session_info_notice, .data = data });
        self.notice = "";
    }

    fn exportSession(self: *App, arg: []const u8) ![]const u8 {
        const a = self.arena;
        const id = try self.controller.sessionIdentifier(a);
        const default_name = try std.fmt.allocPrint(a, "{s}{s}.md", .{ self.presentation.session_export.filename_prefix, id });
        const path = try SessionExport.resolve(a, self.io, self.home, arg, default_name);
        const info: SessionExport.Info = .{
            .id = id,
            .name = self.session_name,
            .workspace = self.controller.settings.workspace,
            .timestamp_ms = Io.Clock.real.now(self.io).toMilliseconds(),
        };
        var branch = try self.controller.transcriptSnapshot(self.a);
        defer branch.deinit();
        try SessionExport.write(a, self.io, path, self.controller.session.path, info, branch.value);
        return path;
    }

    fn openTree(self: *App, selected: ?[]const u8) !void {
        const tree = try SessionTree.create(self.a, self.controller, self.picker_rows, selected);
        self.closeTree();
        self.tree = tree;
        self.notice = "";
        self.clearPointer();
    }

    fn navigateTree(self: *App, id: []const u8, focus: ?[]const u8) !void {
        const head = try self.controller.treeHead(self.a);
        defer if (head) |owned| self.a.free(owned);
        if (head != null and std.mem.eql(u8, head.?, id)) {
            self.closeTree();
            try self.showStatus("Already at this point");
            return;
        }
        if (self.manualCompaction() != null or self.branchSummaryActive() or self.controller.summarizing.load(.acquire)) {
            self.closeTree();
            self.notice = "Wait for the current compaction or tree navigation to finish before navigating the session tree.";
            return;
        }
        if (self.job) |job| {
            if (job.done.isSet()) {
                try self.finishTurn();
            } else {
                _ = try self.restoreQueued(null);
                self.stop();
                try self.drain();
            }
        }
        self.collectUserShell(false);
        if (!self.settleUserShells()) return;
        try self.controller.waitUserShellWrites();
        if (focus) |instructions| {
            const branch: Job.Branch = .{
                .id = try self.arena.dupe(u8, id),
                .focus = try self.arena.dupe(u8, instructions),
            };
            try self.start(.{ .branch_summary = branch });
            self.closeTree();
            return;
        }
        const result = try self.controller.navigateTree(self.arena, id);
        self.closeTree();
        try self.applyTreeNavigation(result);
        if (result == .navigated) {
            try self.flushCompactionInputs();
            try self.loadInbox();
        }
    }

    fn applyTreeNavigation(self: *App, result: Controller.TreeNavigation) !void {
        switch (result) {
            .unchanged => try self.showStatus("Already at this point"),
            .navigated => |draft| {
                self.clearToolExpansions();
                try self.history();
                if (self.user_shell) |shell| {
                    shell.deferred = true;
                    try self.placeRunningShell();
                }
                if (draft) |message| {
                    if (Editor.hasText(message) and !Editor.hasText(self.editor.text())) try self.editor.set(message);
                }
                self.outcome_visible = false;
                try self.showStatus("Navigated to selected point");
            },
        }
    }

    fn treeKey(self: *App, tree: *SessionTree, k: kit.terminal.keys.Key) !void {
        switch (try tree.key(k, self.presentation.shortcut(k) == .external_editor)) {
            .none => {},
            .close => self.closeTree(),
            .choose => {
                const head = try self.controller.treeHead(self.a);
                defer if (head) |owned| self.a.free(owned);
                if (head != null and std.mem.eql(u8, head.?, tree.target().?.id)) {
                    self.closeTree();
                    try self.showStatus("Already at this point");
                } else tree.confirm();
            },
            .reopen => try self.openTree(tree.target().?.id),
            .navigate => try self.navigateTree(tree.target().?.id, null),
            .summarize => try self.navigateTree(tree.target().?.id, tree.summaryFocus()),
            .external => self.edit_external = true,
            .save_label => {
                const label = tree.label();
                self.controller.labelTree(tree.target().?.id, label) catch |err| switch (err) {
                    error.ControllerBusy => {
                        self.notice = "Wait for the current response to finish before saving a tree label.";
                        return;
                    },
                    else => return err,
                };
                self.notice = "";
                try tree.applyLabel(label, Io.Clock.real.now(self.io).toMilliseconds());
            },
            .copy => {
                const entry = tree.target().?;
                const text = switch (entry.kind) {
                    .title, .model, .thinking, .label => "",
                    else => if (entry.text.len != 0) entry.text else entry.diagnostic,
                };
                if (text.len == 0) {
                    self.notice = "Selected entry has no text to copy";
                } else {
                    self.setClipboardText(try self.a.dupe(u8, text), true);
                }
            },
        }
    }
    fn start(self: *App, action: @FieldType(Job, "action")) !void {
        std.debug.assert(self.job == null);
        const job = try self.a.create(Job);
        errdefer self.a.destroy(job);
        job.* = .{ .allocator = self.a, .controller = self.controller, .io = self.io, .wake = self.mailbox.wake, .action = action };
        job.future = try self.io.concurrent(Job.work, .{job});
        self.job = job;
        self.started = Io.Timestamp.now(self.io, .awake);
        self.retry_display = null;
        self.auto_compacting = null;
        self.turn_error = false;
        self.outcome_visible = false;
        self.notice = "";
    }
    fn stop(self: *App) void {
        self.closeDialog();
        if (self.job) |job| {
            switch (job.action) {
                .compact => |id| {
                    if (self.controller.cancelManualCompaction(id)) |_| {
                        job.future.await(self.io);
                    } else |err| {
                        std.log.warn("Could not cancel compaction ({s})", .{@errorName(err)});
                        job.future.cancel(self.io);
                    }
                },
                .branch_summary => job.future.cancel(self.io),
                else => {
                    self.controller.cancel();
                    job.future.cancel(self.io);
                },
            }
            self.job = null;
            job.destroy();
        }
    }
    fn branchSummaryActive(self: *const App) bool {
        return if (self.job) |job| job.action == .branch_summary else false;
    }
    fn manualCompaction(self: *const App) ?[]const u8 {
        const job = self.job orelse return null;
        return switch (job.action) {
            .compact => |id| id,
            else => null,
        };
    }
    fn flushCompactionInputs(self: *App) !void {
        if (self.compaction_inputs.items.len == 0) return;
        try self.controller.enqueueCompactionMessages(self.compaction_inputs.items);
        self.compaction_inputs.clearRetainingCapacity();
        self.waiting_after_compaction = false;
    }
    fn loadInbox(self: *App) !void {
        const inputs = try self.controller.pendingInputs(self.arena);
        try self.queue.ensureTotalCapacity(self.a, inputs.len);
        self.queue.clearRetainingCapacity();
        self.queue.appendSliceAssumeCapacity(inputs);
        const state = try self.controller.queueState();
        self.queue_paused = state.paused;
        self.waiting_after_compaction = state.waiting_after_compaction;
        self.auth.configured = self.controller.configured();
    }
    fn setQueuePaused(self: *App, paused: bool) !void {
        try self.controller.setQueuePaused(paused);
        self.queue_paused = paused;
    }
    fn abort(self: *App) !void {
        errdefer self.stop();
        _ = try self.restoreQueued(null);
        self.stop();
        _ = try self.controller.abortManualCompactions();
        try self.loadInbox();
        try self.setOutcome("Stopped. Completed changes remain.");
    }
    fn dispatchedInput(self: *const App) ?[]const u8 {
        const job = self.job orelse return null;
        return switch (job.action) {
            .prompt => |input| input.submission,
            else => null,
        };
    }
    fn restoreQueued(self: *App, current_text: ?[]const u8) !usize {
        const expanded = if (current_text == null) try self.editor.expanded(self.a) else null;
        defer if (expanded) |bytes| self.a.free(bytes);
        const draft = current_text orelse expanded.?;
        const include_draft = Editor.hasText(draft);
        while (true) {
            var scratch = std.heap.ArenaAllocator.init(self.a);
            defer scratch.deinit();
            const a = scratch.allocator();
            const batch = try self.controller.pendingMessages(a, self.dispatchedInput());
            const count = batch.messages.len + self.compaction_inputs.items.len;
            if (count == 0) return 0;
            var messages = try std.ArrayList([]const u8).initCapacity(a, count);
            for ([_]bool{ true, false }) |steering| {
                for (batch.messages) |message| {
                    if ((message.kind == .steering) == steering) messages.appendAssumeCapacity(message.original);
                }
                for (self.compaction_inputs.items) |message| {
                    if (message.steering == steering) messages.appendAssumeCapacity(message.input.original);
                }
            }
            const queued = try std.mem.join(a, "\n\n", messages.items);
            const replacement = if (!Editor.hasText(queued))
                if (include_draft) draft else ""
            else if (include_draft)
                try std.mem.concat(a, u8, &.{ queued, "\n\n", draft })
            else
                queued;
            var prepared = try self.editor.prepareText(replacement);
            defer prepared.deinit();
            if (batch.messages.len != 0 and !try self.controller.withdrawPendingMessages(batch)) continue;
            self.editor.setPrepared(&prepared);
            self.clearCompletion();
            self.queue.clearRetainingCapacity();
            self.compaction_inputs.clearRetainingCapacity();
            return count;
        }
    }
    fn editQueued(self: *App, current_text: ?[]const u8) !bool {
        const restored = try self.restoreQueued(current_text);
        self.notice = if (restored == 0) "No queued messages to restore" else try std.fmt.allocPrint(
            self.arena,
            "Restored {d} queued message{s} to editor",
            .{ restored, if (restored == 1) "" else "s" },
        );
        if (restored > 0) try self.loadInbox();
        return restored > 0;
    }
    fn paste(self: *App, bytes: []const u8) !void {
        if (self.theme_picker != null) return;
        if (self.settings_list) |*list| return list.paste(self.a, bytes);
        if (self.session_selector) |*selector| return selector.paste(self.arena, bytes);
        if (self.fork_selector != null or self.missing_workspace != null) return;
        if (self.tree) |tree| return tree.paste(bytes);
        if (self.search) |*search| {
            var scratch = std.heap.ArenaAllocator.init(self.a);
            defer scratch.deinit();
            return search.paste(scratch.allocator(), bytes, @intCast(self.scroll.top));
        }
        self.clearCompletion();
        self.interrupt = null;
        if (self.dialog) |dialog| return dialog.paste(bytes, self.controller);
        if (self.thinking_picker != null) {
            self.notice = "Close thinking selection before pasting.";
            return;
        }
        try self.editor.paste(bytes);
    }
    fn argumentIndex(self: *App, event: Event) ?usize {
        if (event.call_id.len > 0) {
            for (self.arguments.items, 0..) |stream, index| {
                if (std.mem.eql(u8, stream.call_id, event.call_id)) return index;
            }
            return null;
        }
        var index = self.arguments.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.arguments.items[index].name, event.name)) return index;
        }
        return if (self.arguments.items.len > 0) self.arguments.items.len - 1 else null;
    }
    fn openArguments(self: *App, event: Event) !usize {
        const slot = self.transcript.items.len;
        const call_id = try self.a.dupe(u8, event.call_id);
        errdefer self.a.free(call_id);
        const name = try self.a.dupe(u8, event.name);
        errdefer self.a.free(name);
        try self.arguments.append(self.a, .{ .call_id = call_id, .name = name, .slot = slot });
        errdefer _ = self.arguments.pop();
        try self.transcript.append(self.a, .{ .kind = .tool_arguments_start, .name = name, .call_id = call_id });
        return self.arguments.items.len - 1;
    }
    fn closeArguments(self: *App, index: usize) void {
        var stream = self.arguments.orderedRemove(index);
        if (stream.slot < self.transcript.items.len) self.transcript.items[stream.slot].text = "";
        stream.deinit(self.a);
    }
    fn removeEntry(self: *App, index: usize) void {
        _ = self.transcript.orderedRemove(index);
        const slots = &self.thinking_overrides;
        const first = std.sort.lowerBound(ThinkingRun, slots.items, ThinkingRun{ .slot = index, .ordinal = 0 }, ThinkingRun.order);
        const end = std.sort.lowerBound(ThinkingRun, slots.items, ThinkingRun{ .slot = index + 1, .ordinal = 0 }, ThinkingRun.order);
        slots.replaceRangeAssumeCapacity(first, end - first, &.{});
        for (slots.items[first..]) |*thought_run| thought_run.slot -= 1;
        if (self.pointer_press) |press| if (press.target.thinking_run) |thought_run| {
            if (thought_run.slot >= index) self.clearPointer();
        };
        for (self.arguments.items) |*stream| {
            if (stream.slot > index) stream.slot -= 1;
        }
    }
    fn clearArguments(self: *App) void {
        for (self.arguments.items) |*stream| stream.deinit(self.a);
        self.arguments.clearRetainingCapacity();
    }
    fn previewEdit(self: *App, stream: *Arguments, event: Event) void {
        if (self.job == null or !std.mem.eql(u8, event.name, "edit")) return;
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = if (event.kind == .tool_start) event.data else j.parse(a, event.text) catch .null;
        const encoded_args = if (EditPreview.accepts(args)) j.encode(a, args) catch null else null;
        if (stream.edit_preview) |preview| {
            if (encoded_args != null and std.mem.eql(u8, encoded_args.?, preview.key)) return;
            preview.destroy(self.a);
            stream.edit_preview = null;
        }
        if (encoded_args) |encoded| stream.edit_preview = EditPreview.start(
            self.a,
            self.io,
            self.mailbox.wake,
            self.controller.settings.workspace,
            self.home,
            args,
            encoded,
        ) catch null;
    }
    fn sameCall(entry: Event, event: Event) bool {
        if (entry.kind != .tool_start and entry.kind != .tool_arguments_start and entry.kind != .tool_arguments_delta and entry.kind != .tool_arguments_end) return false;
        if (event.call_id.len > 0 and entry.call_id.len > 0) return std.mem.eql(u8, event.call_id, entry.call_id);
        return std.mem.eql(u8, entry.name, event.name);
    }
    fn drain(self: *App) !void {
        var pending = self.mailbox.take();
        defer pending.deinit(self.a);
        defer for (pending.items) |owned| owned.destroy(self.a);
        if (pending.items.len != 0) if (self.search) |*search| search.index.invalidate();
        for (pending.items) |owned| {
            const event = owned.event;
            switch (event.kind) {
                .notice => {
                    if (event.data != .null and (j.get(event.data, "status") != .null or j.get(event.data, "error") != .null or j.get(event.data, "message") != .null)) {
                        const detail = j.get(event.data, "error");
                        const nested_message = j.text(j.get(detail, "message"));
                        const message = if (nested_message.len != 0) nested_message else j.text(j.get(event.data, "message"));
                        const code = j.text(j.get(detail, "code"));
                        const status = j.text(j.get(event.data, "status"));
                        try self.setOutcome(try std.fmt.allocPrint(self.arena, "Request failed: {s}", .{if (message.len != 0) message else if (code.len != 0) code else if (status.len != 0) status else "execution failed"}));
                        self.turn_error = true;
                        self.notice = "";
                    } else try self.appendEvent(event);
                },
                .provider_retry => {
                    if (event.retry) |retry| {
                        self.retry_display = .{ .info = retry, .started = Io.Timestamp.now(self.io, .awake) };
                    } else self.notice = try self.arena.dupe(u8, event.text);
                    if (event.resuming) continue;
                    self.resetPreview();
                    var index = self.arguments.items.len;
                    while (index > 0) {
                        index -= 1;
                        const slot = self.arguments.items[index].slot;
                        if (self.transcript.items[slot].kind == .tool_start) continue;
                        self.closeArguments(index);
                        self.removeEntry(slot);
                    }
                },
                .assistant_start => {
                    self.retry_display = null;
                    self.resetPreview();
                },
                .compacting => {
                    self.retry_display = null;
                    self.started = Io.Timestamp.now(self.io, .awake);
                    self.auto_compacting = if (j.equal(event.data, "overflow")) .overflow else .threshold;
                },
                .text_delta, .reasoning_delta => {
                    if (event.text.len == 0) continue;
                    self.retry_display = null;
                    if (self.preview_index == null) {
                        const slot = self.transcript.items.len;
                        self.preview.clear();
                        try self.transcript.append(self.a, .{ .kind = .assistant });
                        self.preview_index = slot;
                    }
                    const slot = &self.transcript.items[self.preview_index.?];
                    defer slot.reply = self.preview.view();
                    try self.preview.append(self.a, if (event.kind == .reasoning_delta) .reasoning else .prose, event.text);
                    if (owned.emitted) |stamp| {
                        if (self.pending_delta == null or stamp.ticks < self.pending_delta.?.ticks) self.pending_delta = stamp;
                    }
                },
                .tool_arguments_start => {
                    self.retry_display = null;
                    if (self.argumentIndex(event)) |index| {
                        const stream = &self.arguments.items[index];
                        if (stream.edit_preview) |preview| preview.destroy(self.a);
                        stream.edit_preview = null;
                        stream.clearScriptCalls(self.a);
                        stream.text.clearRetainingCapacity();
                        self.transcript.items[stream.slot] = .{ .kind = .tool_arguments_start, .name = stream.name, .call_id = stream.call_id };
                    } else _ = try self.openArguments(event);
                },
                .tool_arguments_delta => {
                    const index = self.argumentIndex(event) orelse try self.openArguments(event);
                    const stream = &self.arguments.items[index];
                    try stream.text.appendSlice(self.a, event.text);
                    self.transcript.items[stream.slot].text = stream.text.items;
                },
                .tool_arguments_end => {
                    const index = self.argumentIndex(event) orelse try self.openArguments(event);
                    const stream = &self.arguments.items[index];
                    stream.text.clearRetainingCapacity();
                    try stream.text.appendSlice(self.a, event.text);
                    self.transcript.items[stream.slot] = .{ .kind = .tool_arguments_end, .name = stream.name, .call_id = stream.call_id, .text = stream.text.items };
                },
                .tool_start => {
                    const index = self.argumentIndex(event) orelse try self.openArguments(event);
                    const stream = &self.arguments.items[index];
                    stream.text.clearAndFree(self.a);
                    self.transcript.items[stream.slot] = try self.ownEvent(event);
                    self.transcript.items[stream.slot].tool_started = Io.Timestamp.now(self.io, .awake);
                    self.previewEdit(stream, event);
                },
                .tool_update => {
                    if (event.call_id.len == 0) continue;
                    const index = self.argumentIndex(event) orelse continue;
                    const stream = &self.arguments.items[index];
                    if (!ToolView.isScript(stream.name) or self.transcript.items[stream.slot].kind != .tool_start) continue;
                    const position = std.math.cast(usize, j.number(j.get(event.data, "index"))) orelse continue;
                    const call = j.get(event.data, "call");
                    const calls = &stream.script_calls;
                    if (call != .object or position == 0 or position - 1 > calls.items.len) continue;
                    var owned_call = try @import("agent").JsonDocument.initValue(self.a, call);
                    errdefer owned_call.deinit();
                    if (position - 1 == calls.items.len) {
                        try calls.append(self.a, owned_call);
                    } else {
                        calls.items[position - 1].deinit();
                        calls.items[position - 1] = owned_call;
                    }
                },
                .assistant => {
                    self.retry_display = null;
                    if (event.has_context_usage) self.context_usage_known = true;
                    if (self.preview_index) |slot| {
                        const streamed = self.transcript.items[slot].reply;
                        if (event.reply.bytes.len == 0 and !streamed.hasReasoning()) {
                            self.removeEntry(slot);
                        } else {
                            var finished = try self.ownEvent(event);
                            finished.reply = try finished.reply.withPreviewReasoning(self.view.allocator(), streamed);
                            self.transcript.items[slot] = finished;
                        }
                    } else if (event.reply.bytes.len != 0) try self.appendEvent(event);
                    self.preview_index = null;
                    for (self.arguments.items) |*stream| {
                        const entry = self.transcript.items[stream.slot];
                        if (entry.kind == .tool_arguments_end) self.previewEdit(stream, entry);
                    }
                },
                .compacted, .compaction_declined, .compaction_failed => {
                    self.retry_display = null;
                    self.auto_compacting = null;
                    if (event.kind == .compacted) {
                        self.context_usage_known = false;
                        try self.appendEvent(event);
                    }
                },
                .tool_end => {
                    var at = self.transcript.items.len;
                    while (at > 0) {
                        at -= 1;
                        if (sameCall(self.transcript.items[at], event)) break;
                    }
                    if (at < self.transcript.items.len and sameCall(self.transcript.items[at], event)) {
                        var finished = event;
                        if (self.transcript.items[at].tool_started) |started| {
                            finished.tool_duration_ms = started.durationTo(Io.Timestamp.now(self.io, .awake)).toMilliseconds();
                        }
                        if (finished.arguments == .null and self.transcript.items[at].kind == .tool_start) {
                            finished.arguments = self.transcript.items[at].data;
                        }
                        if (self.argumentIndex(event)) |index| {
                            if (self.arguments.items[index].expansion_override and finished.entry_id.len != 0)
                                try self.toggleToolExpansion(finished.entry_id);
                            self.closeArguments(index);
                        }
                        if (self.pointer_press) |*press| {
                            if (press.target.kind == .running_tool and finished.entry_id.len != 0 and
                                std.mem.eql(u8, finished.call_id, press.target.id))
                            {
                                const next = try self.a.dupe(u8, finished.entry_id);
                                self.a.free(press.target.id);
                                press.target.id = next;
                                press.target.kind = .tool;
                            }
                        }
                        self.transcript.items[at] = try self.ownEvent(finished);
                    } else try self.appendEvent(event);
                },
                else => try self.appendEvent(event),
            }
        }
        if (self.job == null) {
            const a = self.view.allocator();
            for (self.transcript.items) |*event| switch (event.kind) {
                .compacting => event.* = .{ .kind = .notice, .text = "Compaction interrupted." },
                .tool_start => event.* = .{ .kind = .notice, .text = try std.fmt.allocPrint(a, "Tool updates interrupted ({s}).", .{event.name}) },
                .tool_arguments_start, .tool_arguments_delta, .tool_arguments_end => event.* = .{ .kind = .notice, .text = try std.fmt.allocPrint(a, "Tool call interrupted ({s}).", .{event.name}) },
                else => {},
            };
            self.clearArguments();
            if (self.preview_index) |slot| self.transcript.items[slot] = try self.ownEvent(self.transcript.items[slot]);
            self.preview_index = null;
        }
    }
    fn resetPreview(self: *App) void {
        if (self.preview_index) |slot| self.removeEntry(slot);
        self.preview_index = null;
        self.preview.clear();
    }
    fn finishTurn(self: *App) !void {
        if (self.job) |job| {
            if (!job.done.isSet()) return;
            job.future.await(self.io);
            defer job.destroy();
            const failure = job.failure;
            const compacted = job.action == .compact;
            const compaction_result = job.compaction_result;
            self.job = null;
            try self.drain();
            self.preview_index = null;
            if (job.action == .branch_summary) {
                if (job.branch_result) |result| {
                    self.closeTree();
                    try self.applyTreeNavigation(result);
                    if (result == .navigated) try self.flushCompactionInputs();
                } else if ((failure orelse error.BranchSummaryFailed) == error.Canceled) {
                    try self.openTree(job.action.branch_summary.id);
                    try self.showStatus("Branch summarization cancelled");
                } else {
                    self.notice = switch (failure orelse error.BranchSummaryFailed) {
                        error.ModelUnavailable => "No model available for summarization",
                        error.BranchSummaryToolCall => "Branch summarization attempted to call a tool",
                        error.StaleTreeSelection => "The conversation changed while summarizing the branch",
                        else => "Branch summarization failed",
                    };
                }
                try self.loadInbox();
                return;
            }
            if (compacted) {
                const result_notice = if (failure) |err|
                    if (err == error.Canceled) "Compaction cancelled" else @errorName(err)
                else switch (compaction_result orelse .finished) {
                    .nothing_to_compact => "Nothing to compact (session too small)",
                    .declined => "Compaction cancelled",
                    .finished => "",
                };
                if (result_notice.len != 0) try self.transcript.append(self.a, .{ .kind = .notice, .text = result_notice });
                self.notice = "";
                self.flushCompactionInputs() catch |err| {
                    self.notice = try std.fmt.allocPrint(self.arena, "Failed to send queued messages: {s}", .{@errorName(err)});
                };
            }
            try self.loadInbox();
            self.routes_dirty = true;
            if (!compacted) self.notice = if (failure) |err| switch (err) {
                error.ApplicationFailed, error.WorkerCommandFailed => "This turn failed. You can retry or send another message.",
                error.ContextOverflow => "Context is full. Use /compact or /new to continue.",
                error.Canceled => "Stopped. You can keep working.",
                else => @errorName(err),
            } else "";
            if (!compacted) if (failure) |err| {
                if (err != error.ApplicationFailed and err != error.ContextOverflow and self.queue.items.len != 0) try self.setQueuePaused(true);
                if (!self.turn_error) try self.setOutcome(self.notice);
                self.notice = "";
            };
        }
    }
    fn settle(self: *App) !void {
        try self.finishTurn();
        if (self.job != null) return;
        if (!self.settleUserShells()) return;
        try self.placeRunningShell();
        self.syncAuth() catch |err| self.reportError(err);
        if (self.auth.configured and self.dialog == null and self.controller.recovery_available.load(.acquire)) {
            try self.start(.recover);
            return;
        }
        if (self.dialog == null and !self.queue_paused and !self.waiting_after_compaction and self.auth.configured) if (Controller.Prepared.firstReady(self.queue.items)) |index| {
            try self.start(.{ .prompt = self.queue.items[index] });
            _ = self.queue.orderedRemove(index);
        };
        try self.resetScratch();
    }
    fn submit(self: *App, follow_up: bool) !void {
        const expanded = try self.editor.expanded(self.a);
        defer self.a.free(expanded);
        const raw = std.mem.trim(u8, expanded, " \t\r\n");
        const command_end = if (std.mem.startsWith(u8, raw, "/")) std.mem.indexOfAny(u8, raw, " \t\r\n") orelse raw.len else 0;
        const name = raw[0..command_end];
        const command_entry = if (name.len != 0) self.presentation.command(name) else null;
        const literal = command_end < raw.len and (raw[command_end] == ' ' or raw[command_end] == '\n') and
            (std.mem.eql(u8, name, "/send") or (command_entry != null and command_entry.?.action == .send));
        const text = if (literal) std.mem.trimStart(u8, raw[command_end + 1 ..], " \t\r\n") else raw;
        if (text.len == 0) return;
        if (!literal and (!follow_up or self.job == null)) {
            if (ShellInput.Prefix.parse(text)) |prefix| if (prefix.command.len != 0) return self.startUserShell(prefix);
        }
        self.preserve_editor = false;
        const local_command = if (command_entry) |entry|
            if (!literal and (entry.arguments != .exact or command_end == text.len)) entry else null
        else
            null;
        if (local_command) |entry| {
            const arg = std.mem.trim(u8, text[command_end..], " \t\r\n");
            if (entry.arguments == .none and arg.len != 0) {
                self.notice = "Unexpected argument. Draft preserved. Use /send TEXT to send literally.";
                return;
            }
            if (!try self.command(entry.action, arg)) return;
        } else {
            try self.syncAuth();
            if (!self.auth.configured) {
                self.notice = if (self.auth.document.profiles.len > 0) "Use /model to select a saved provider and model before sending a message." else "Use /login to configure a provider before sending a message.";
                return;
            }
            const original = try self.arena.dupe(u8, text);
            var copies = [1]Controller.Prepared{if (literal) .{ .text = original, .original = original } else try self.controller.prepare(self.arena, original)};
            if (self.manualCompaction() != null or self.branchSummaryActive()) {
                try self.compaction_inputs.append(self.a, .{ .input = copies[0], .steering = !follow_up });
                self.notice = "Queued message for after compaction";
            } else {
                try self.queue.ensureUnusedCapacity(self.a, 1);
                const steered = !self.queue_paused and self.job != null and !follow_up and try self.controller.steer(copies[0]);
                if (!steered) {
                    copies[0].compaction_seed = self.job == null and self.waiting_after_compaction;
                    try self.controller.enqueueInputs(self.arena, &copies);
                    self.queue.appendAssumeCapacity(copies[0]);
                    if (copies[0].compaction_seed) self.waiting_after_compaction = false;
                }
                self.notice = if (self.queue_paused) "Input retained in paused queue. /queue continue starts pending work." else "";
            }
        }
        if (!self.preserve_editor) {
            try self.editor.remember();
            self.editor.clear();
        }
    }
    fn nameSession(self: *App, input: []const u8) !void {
        const name = try SessionName.normalize(self.a, input);
        if (name.len == 0) {
            self.a.free(name);
            if (self.session_name) |title| {
                try self.appendEvent(.{ .kind = .notice, .name = name_notice, .text = try std.fmt.allocPrint(self.arena, "Session name: {s}", .{title}) });
                self.notice = "";
            } else {
                try self.appendEvent(.{ .kind = .notice, .name = name_warning, .text = "Warning: Usage: /name <name>" });
                self.notice = "";
            }
            return;
        }
        {
            errdefer self.a.free(name);
            try self.saveActiveTitle(name);
        }
        const original = SessionName.trimWhitespace(input);
        if (!std.mem.eql(u8, original, name)) {
            try self.appendEvent(.{
                .kind = .notice,
                .name = name_warning,
                .text = try std.fmt.allocPrint(self.arena, "Warning: Session name was normalized from {s} to {s}", .{
                    try j.encode(self.arena, j.string(original)), try j.encode(self.arena, j.string(name)),
                }),
            });
        }
        try self.appendEvent(.{ .kind = .notice, .name = name_notice, .text = try std.fmt.allocPrint(self.arena, "Session name set: {s}", .{name}) });
        self.notice = "";
    }

    fn saveActiveTitle(self: *App, name: []const u8) !void {
        try self.controller.setSessionName(name);
        if (self.session_name) |old| self.a.free(old);
        self.session_name = name;
        self.terminal_title_dirty = true;
    }

    fn renamePickerSession(self: *App, selector: *SessionSelector, rename: SessionSelector.Rename) !void {
        if (!selector.isCurrent(rename.session.path)) {
            selector.mutate(rename.session, rename.name) catch |err| return selector.reportMutationError("rename", err);
            return;
        }
        const name = try self.a.dupe(u8, rename.name);
        self.saveActiveTitle(name) catch |err| {
            self.a.free(name);
            return selector.reportMutationError("rename", err);
        };
        try selector.reload(null);
    }

    fn command(self: *App, action: UiPresentation.Command.Action, arg: []const u8) !bool {
        const needs_idle = switch (action) {
            .forget, .login, .logout, .model, .@"continue", .reload, .thinking, .select, .send, .unknown => true,
            else => false,
        };
        if (needs_idle and self.job != null) {
            self.notice = "Working. Esc interrupts and restores queued messages to the editor.";
            return false;
        }
        switch (action) {
            .settings => {
                self.clearCompletion();
                self.clearPointer();
                self.screen_selection.clear();
                self.selection.clear();
                self.closeTranscriptSearch();
                self.notice = "";
                self.settings_list = .init(self.a);
                self.settings_list.?.minimum_label_width = "Default thinking level per model".len;
            },
            .quit => self.quit = true,
            .copy => try self.copyLastAssistant(false),
            .help, .hotkeys => self.notice = if (action == .help) self.presentation.help else self.presentation.hotkeys,
            .name => try self.nameSession(arg),
            .session => try self.showSessionInfo(),
            .export_session => {
                const labels = self.presentation.session_export;
                const path = self.exportSession(arg) catch |err| {
                    self.notice = try std.mem.concat(self.arena, u8, &.{ labels.failure, @errorName(err) });
                    return false;
                };
                self.notice = "";
                try self.showStatus(try std.mem.concat(self.arena, u8, &.{ labels.success, path }));
            },
            .draft => {
                self.editor.clear();
                self.preserve_editor = self.editor.restoreDraft();
                self.notice = if (self.preserve_editor) "Displaced draft restored." else "No displaced draft.";
            },
            .outcome => {
                if (std.mem.eql(u8, arg, "dismiss")) {
                    if (self.recovery_required) {
                        self.notice = "Restart required; this recovery outcome cannot be dismissed.";
                        return false;
                    }
                    if (self.outcome) |outcome| self.a.free(outcome);
                    self.outcome = null;
                    self.outcome_visible = false;
                    self.notice = "";
                } else if (arg.len == 0) {
                    self.outcome_visible = true;
                    self.notice = if (self.outcome == null) "No previous outcome." else "";
                } else {
                    self.notice = "Use /outcome or /outcome dismiss.";
                    return false;
                }
            },
            .reset => {
                const id = try self.controller.enqueueReset(self.arena, arg);
                if (self.job == null) {
                    try self.start(.{ .reset = id });
                } else self.notice = "Reset queued for the turn boundary.";
            },
            .fork => {
                if (arg.len == 0) {
                    self.fork_selector = try ForkSelector.open(self.a, self.controller);
                    if (self.fork_selector == null) try self.showStatus("No messages to fork from");
                } else try self.createFork(arg);
            },
            .clone => try self.cloneSession(),
            .compact => {
                if (self.branchSummaryActive()) {
                    self.notice = "Wait for the current compaction or tree navigation to finish before compacting.";
                    return false;
                }
                if (self.job != null and self.manualCompaction() == null) try self.controller.preserveSteeringForCompaction();
                self.stop();
                try self.drain();
                const id = try self.controller.enqueueTerminalCompaction(self.arena, arg);
                self.waiting_after_compaction = true;
                errdefer {
                    self.controller.cancelManualCompaction(id) catch {};
                    self.controller.compactQueued(id) catch {};
                }
                try self.start(.{ .compact = id });
            },
            .new => try self.replaceSession(.new),
            .@"resume" => {
                if (arg.len == 0) {
                    self.session_selector = try SessionSelector.open(self.a, self.io, .{
                        .directory = self.controller.settings.session_directory,
                        .root = self.controller.settings.session_root,
                        .workspace = self.controller.settings.workspace,
                        .current = self.controller.session.path,
                    }, self.notification());
                    self.notice = "";
                } else try self.replaceSession(.{ .existing = .{ .path = arg } });
            },
            .tree => {
                if (arg.len == 0) {
                    try self.openTree(null);
                    return true;
                }
                const before = try std.fmt.parseInt(u64, arg, 10);
                const page = try self.controller.treePage(self.arena, before, self.picker_rows);
                self.notice = if (page.next) |next|
                    try std.fmt.allocPrint(self.arena, "{s}Run /tree {d} for earlier entries.", .{ page.text, next })
                else
                    page.text;
            },
            .forget => {
                const kind = std.meta.stringToEnum(Auth.Kind, arg) orelse {
                    self.notice = "Use /forget openai, /forget deepseek, or /forget compatible.";
                    return false;
                };
                self.dialog = try Dialogs.create(self.a, .confirm);
                self.dialog.?.forget_kind = kind;
                self.dialog.?.message = try self.dialog.?.copy(try std.fmt.allocPrint(self.arena, "Forget saved {s} credentials in auth.conf? Legacy auth.json remains on disk but will not be re-imported. No remote revocation. Other providers remain saved. The in-process route and environment keys remain until changed or restarted. Enter confirms; Esc cancels.", .{@tagName(kind)}));
            },
            .login, .logout => {
                const labels = &self.presentation.pickers.dialog;
                self.dialog = try Dialogs.providerPicker(self.a, self.auth, labels, action == .logout);
                if (self.dialog == null) {
                    try self.showStatus(labels.no_saved_providers);
                    return true;
                }
                if (arg.len > 0) {
                    const kind = std.meta.stringToEnum(Auth.Kind, arg) orelse {
                        self.closeDialog();
                        return error.UnknownLoginProvider;
                    };
                    try self.applyAction(try self.dialog.?.begin(kind, self.controller));
                }
            },
            .model => try self.openModels(if (arg.len == 0) null else arg),
            .@"continue" => {
                if (!self.auth.configured) {
                    self.notice = "Select a configured model before continuing.";
                    return false;
                }
                try self.start(.{ .continue_turn = try self.controller.enqueueContinuation(self.arena) });
            },
            .reload => {
                try self.controller.reloadSkills();
                try self.reloadThemes(.replace);
                self.notice = "Skills and themes reloaded.";
            },
            .thinking => {
                const profile = (try self.controller.thinkingProfile()) orelse {
                    self.notice = if (self.path.len != 0) try std.fmt.allocPrint(self.arena, "Thinking capabilities unknown. Copy any unsent draft, then restart with --thinking-levels off,low,high and --session PATH, where PATH is: {s}. Declare only levels your endpoint supports.", .{self.path}) else "Thinking capabilities unknown. Restart with --thinking-levels off,low,high, declaring only levels your endpoint supports. This memory-only session and unsent draft cannot be resumed; copy them first.";
                    return false;
                };
                if (arg.len == 0) {
                    self.thinking_picker = self.controller.selected_effort orelse try profile.cycle(null);
                    self.notice = "";
                } else {
                    const level = effort.parse(arg) catch return self.unsupportedThinking(profile);
                    if (!profile.supports(level)) return self.unsupportedThinking(profile);
                    try self.controller.setThinking(level);
                    try self.showThinkingLevel();
                }
            },
            .select => {
                if (self.queue.items.len != 0 or self.compaction_inputs.items.len != 0) {
                    self.notice = "Pending input: /queue edit or /queue discard before changing session/branch.";
                    return false;
                }
                if (arg.len == 0) return error.MissingArgument;
                if (!self.settleUserShells()) return false;
                try self.controller.waitUserShellWrites();
                try self.controller.select(arg);
                self.clearToolExpansions();
                try self.history();
                if (self.user_shell) |shell| {
                    shell.deferred = true;
                    try self.placeRunningShell();
                }
                try self.setOutcome("Conversation context changed.");
            },
            .queue => return self.queueCommand(arg),
            .send, .unknown => {
                self.notice = "Unknown command or missing argument. Use /help, or /send TEXT to send literally.";
                return false;
            },
        }
        return true;
    }
    fn queueCommand(self: *App, arg: []const u8) !bool {
        if (arg.len == 0) {
            const waiting = self.queue.items.len != 0 and (self.waiting_after_compaction or Controller.Prepared.firstReady(self.queue.items) == null);
            const state = if (self.queue_paused) "paused" else if (waiting) "waiting for new input" else "running";
            self.notice = try std.fmt.allocPrint(self.arena, "Queue {s}: {d} follow-ups. /queue pause · /queue continue · /queue edit · /queue discard. Unconsumed steering is shown separately.", .{ state, self.queue.items.len });
        } else if (std.mem.eql(u8, arg, "pause")) {
            try self.setQueuePaused(true);
            self.notice = "Pending execution paused.";
        } else if (std.mem.eql(u8, arg, "continue")) {
            if (self.job != null or !self.auth.configured) {
                self.notice = "Wait for idle and choose a configured model before continuing.";
                return false;
            }
            try self.flushCompactionInputs();
            try self.controller.resumeQueue();
            self.waiting_after_compaction = false;
            try self.loadInbox();
            self.routes_dirty = true;
            self.notice = "Pending execution resumed.";
        } else if (std.mem.eql(u8, arg, "discard")) {
            try self.controller.discardPendingInputs();
            self.queue.clearRetainingCapacity();
            self.compaction_inputs.clearRetainingCapacity();
            try self.setQueuePaused(false);
            self.notice = "Pending input discarded. Active work was not rolled back.";
        } else if (std.mem.eql(u8, arg, "edit")) {
            self.preserve_editor = try self.editQueued("");
        } else {
            self.notice = "Use /queue pause, /queue continue, /queue edit, or /queue discard.";
            return false;
        }
        return true;
    }
    fn unsupportedThinking(self: *App, profile: effort.Profile) !bool {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.arena, "Unsupported thinking level. Supported:");
        for (effort.levels) |level| if (profile.supports(level)) {
            try text.appendSlice(self.arena, " ");
            try text.appendSlice(self.arena, @tagName(level));
        };
        self.notice = text.items;
        return false;
    }
    fn cycleThinking(self: *App) !void {
        if (self.job != null) {
            self.notice = "Working. Esc interrupts and restores queued messages to the editor.";
            return;
        }
        const profile = try self.controller.thinkingProfile();
        if (profile) |known| for (effort.levels[1..]) |level| {
            if (!known.supports(level)) continue;
            try self.controller.cycleThinking();
            return self.showThinkingLevel();
        };
        self.notice = "";
        try self.showStatus("Current model does not support thinking");
    }
    fn showThinkingLevel(self: *App) !void {
        self.notice = "";
        try self.showStatus(try std.fmt.allocPrint(self.arena, "Thinking level: {s}", .{self.controller.effortLabel()}));
    }
    fn clearCompletion(self: *App) void {
        if (self.file_lookup) |lookup| lookup.destroy(self.a);
        self.file_lookup = null;
        if (self.completion) |*menu| menu.arena.deinit();
        self.completion = null;
        self.completion_press = null;
    }
    fn syncAuth(self: *App) !void {
        if (self.controller.settings.auth_path == null) return;
        const revision = self.controller.auth_revision.load(.acquire);
        if (revision == self.auth_revision_seen) return;
        try self.auth.reload();
        self.auth_revision_seen = revision;
        self.routes_dirty = true;
    }
    fn replaceSession(self: *App, target: Controller.SessionTarget) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.a);
        defer scratch.deinit();
        var replacement = (try self.controller.prepareSessionReplacement(scratch.allocator(), target)) orelse return;
        defer replacement.deinit();
        if (replacement.missing_workspace) |missing| {
            self.clearCompletion();
            self.missing_workspace = .{
                .arena = scratch,
                .replacement = replacement,
                .prompt = .{ .missing = missing, .current = self.controller.settings.workspace },
            };
            scratch = .init(self.a);
            replacement.recovered = null;
            return;
        }
        try self.installSession(&replacement);
        if (target == .new) {
            try self.appendEvent(.{ .kind = .notice, .text = "✓ New session started" });
        } else {
            self.notice = "";
            try self.showStatus("Resumed session");
        }
    }

    fn answerMissingWorkspace(self: *App, answer: WorkspaceChoice) !void {
        var dialog = self.missing_workspace.?;
        self.missing_workspace = null;
        defer dialog.deinit();
        if (answer == .cancel) return self.showStatus("Resume cancelled");
        const selected = &dialog.replacement.recovered.?;
        const a = dialog.arena.allocator();
        const cwd = self.controller.settings.workspace;
        const message = switch (answer) {
            .proceed => proceed: {
                try selected.revalidateFile();
                const status = try std.fmt.allocPrint(a, "Resumed session in {s}", .{cwd});
                dialog.replacement.workspace = cwd;
                try self.installSession(&dialog.replacement);
                break :proceed status;
            },
            .fork => fork: {
                var child = try Controller.forkSessionArchive(a, self.controller.gpa, self.io, selected, cwd, self.controller.settings.session_directory);
                defer child.deinit();
                const status = try std.fmt.allocPrint(a, "Forked into new session {s} in {s}", .{ try child.recovered.?.sessionId(), cwd });
                try self.installSession(&child);
                break :fork status;
            },
            .cancel => unreachable,
        };
        self.notice = "";
        try self.showStatus(message);
    }

    fn installSession(self: *App, replacement: *Controller.SessionReplacement) !void {
        self.stop();
        _ = try self.controller.abortManualCompactions();
        try self.controller.discardPendingInputs();
        self.compaction_inputs.clearRetainingCapacity();
        self.collectUserShell(true);
        try self.flushUserShells();
        try self.controller.waitUserShellWrites();
        self.shell_record_retry = null;

        self.controller.setSink(null);
        defer self.controller.setSink(.{ .context = &self.mailbox, .emit = Mailbox.emit });
        try self.drain();
        if (replacement.workspace != null) {
            var candidate = try self.workspace_runtime.build(replacement);
            defer candidate.deinit();
            self.closeDialog();
            self.clearCompletion();
            self.discovery.deinit();
            self.discovery = newDiscovery(self.a, self.io, self.mailbox.wake);
            self.auth.size_warnings = candidate.controller.authSizeSink();
            self.workspace_runtime.install(&candidate);
            self.controller = self.workspace_runtime.current;
            self.editor.history_source = .{ .context = self.controller, .readOwned = promptHistory };
            self.workspace_branch.deinit(self.a);
            self.auth_revision_seen = 0;
            self.terminal_title_dirty = true;
            self.model = self.controller.modelName();
            self.path = self.controller.sessionPath();
        } else {
            try self.controller.changeSession(replacement);
        }
        self.auth.configured = self.controller.configured();
        self.clearToolExpansions();
        if (self.outcome) |outcome| self.a.free(outcome);
        self.outcome = null;
        self.outcome_visible = false;
        self.routes_dirty = true;
        try self.loadInbox();
        try self.history();
    }
    fn syncRoutes(self: *App) !bool {
        if (!self.routes_dirty) return false;
        var next: std.heap.ArenaAllocator = .init(self.a);
        errdefer next.deinit();
        const a = next.allocator();
        const active = if (self.auth.configured) try self.currentRecord(a) else null;
        const catalog = self.controller.settings.registry;
        const configured = try ModelRoutes.collect(a, catalog, self.auth, active, null);
        var routes: std.ArrayList(ModelRoutes.Target) = .empty;
        try routes.appendSlice(a, configured);
        if (self.dialog) |dialog| if (dialog.record.token.len != 0 and (dialog.step == .models or dialog.step == .custom)) {
            const pending = try Auth.cloneRecord(a, dialog.record);
            const target: ModelRoutes.Target = .{ .record = pending, .source = .pending, .reference = if (catalog) |c| c.endpoint(pending.base_url) else null };
            for (routes.items) |*route| {
                if (!ModelRoutes.same(route.record, pending)) continue;
                route.record = pending;
                route.source = .pending;
                break;
            } else try routes.append(a, target);
        };
        const targets = try a.alloc(registry.discovery.Target, routes.items.len);
        for (routes.items, targets) |route, *target| target.* = route.discovery();
        try self.discovery.reconcile(targets);
        self.routes_arena.deinit();
        self.routes_arena = next;
        self.model_routes = routes.items;
        self.routes_dirty = false;
        return true;
    }
    fn updateDiscovery(self: *App) !?Io.Timestamp {
        const routes_changed = try self.syncRoutes();
        const update = self.discovery.advance(self.controller.authSizeSink());
        if (routes_changed or update.changed) self.updateModelDialog() catch |err| self.reportError(err);
        if (update.changed) if (self.completion) |menu| {
            if (menu.match.kind == .argument and menu.match.kind.argument == .model)
                self.refreshCompletion(false, false) catch |err| self.reportError(err);
        };
        return update.deadline;
    }
    fn updateModelDialog(self: *App) !void {
        const dialog = self.dialog orelse return;
        if (dialog.step != .models and dialog.step != .custom) return;
        const pending_only = dialog.record.token.len != 0;
        for (self.model_routes, 0..) |route, i| {
            if ((route.source == .pending) != pending_only) continue;
            if (self.discovery.offer(i) == null) {
                try dialog.setModels(&.{});
                dialog.message = "Fetching provider model lists. Esc closes picker.";
                return;
            }
        }
        var scratch: std.heap.ArenaAllocator = .init(self.a);
        defer scratch.deinit();
        const a = scratch.allocator();
        const choices = try ModelChoices.project(a, self.model_routes, &self.discovery, pending_only);
        const labels = try a.alloc([]const u8, choices.len);
        for (choices, labels) |choice, *label| label.* = choice.label;
        try dialog.setModels(labels);
        dialog.message = if (labels.len == 0) "No listed models. Ctrl+N enters a custom ID." else "Select provider / model. Type to filter.";
        for (self.model_routes, 0..) |route, i| {
            if ((route.source == .pending) != pending_only) continue;
            if (self.discovery.offer(i).?.fallback_reason != null) {
                dialog.message = "Discovery unavailable for some routes; showing local fallback choices.";
                break;
            }
        }
        if (self.requested_model) |name| {
            self.requested_model = null;
            if (try ModelChoices.lookup(choices, name)) |choice| {
                try self.acceptChoice(choice);
            } else dialog.message = "Model not listed. Select a listed model or use Ctrl+N for a custom ID.";
        }
    }
    fn refreshCompletion(self: *App, force_paths: bool, explicit_tab: bool) !void {
        return self.showCompletion(Completion.context(&self.presentation, self.editor.text()[0..self.editor.cursor], force_paths), explicit_tab);
    }

    fn completionMatch(self: *const App) ?Completion.Match {
        if (self.completion) |menu| return menu.match;
        if (self.file_lookup) |lookup| return lookup.menu.match;
        return null;
    }

    fn composerOwnsCompletion(self: *const App) bool {
        return self.dialog == null and self.thinking_picker == null and self.settings_list == null and self.search == null and
            self.tree == null and self.fork_selector == null and self.session_selector == null and self.missing_workspace == null;
    }

    fn showCompletion(self: *App, candidate: ?Completion.Match, explicit_tab: bool) !void {
        errdefer self.clearCompletion();
        const m = candidate orelse {
            self.clearCompletion();
            return;
        };
        if (m.kind == .path or m.kind == .reference) {
            self.clearCompletion();
            self.file_lookup = try Completion.Lookup.start(
                self.a,
                self.io,
                self.mailbox.wake.notification(),
                m,
                self.editor.text(),
                self.editor.cursor,
                self.controller.settings.workspace,
                self.home,
                explicit_tab,
            );
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        var items: Completion.Candidates = .{ .a = a, .query = m.query };
        switch (m.kind) {
            .command => try Completion.commands(&self.presentation, &items, &self.controller.skills, self.skillCommands()),
            .argument => |source| switch (source) {
                .model => {
                    try self.syncAuth();
                    _ = try self.syncRoutes();
                    const choices = try ModelChoices.project(a, self.model_routes, &self.discovery, false);
                    for (choices) |choice| {
                        const search = try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s} {s}", .{
                            choice.model_id,
                            choice.provider_id,
                            choice.key,
                            choice.provider_id,
                            choice.model_id,
                            choice.model_name,
                        });
                        try items.add(.{ .value = choice.key, .label = choice.model_id, .description = choice.provider_id }, search, null);
                    }
                },
                .thinking => if (try self.controller.thinkingProfile()) |profile| {
                    for (effort.levels) |level| {
                        if (!profile.supports(level)) continue;
                        const name = @tagName(level);
                        try items.add(.{ .value = name, .label = name }, name, null);
                    }
                },
                .login => {
                    // Alphabetical provider names, with fuzzy ranking over the ID,
                    // name, authentication type, and displayed type.
                    for ([_]Auth.Kind{ .deepseek, .openai, .compatible }) |kind| {
                        const provider = self.presentation.pickers.dialog.provider(kind);
                        const name = @tagName(kind);
                        const desc = try std.fmt.allocPrint(a, "{s} · {s}", .{ provider.label, provider.type_label });
                        const search = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ name, provider.label, @tagName(provider.auth_type), provider.type_label });
                        try items.add(.{ .value = name, .label = name, .description = desc }, search, null);
                    }
                },
                .choices => |choices| for (choices) |choice| {
                    try items.add(.{ .value = choice, .label = choice }, choice, null);
                },
            },
            .path, .reference => unreachable,
        }
        var list = try items.finish(m);
        list.capacity = self.preferences.completionLimit();
        self.clearCompletion();
        if (list.items.len == 0) return;
        var owned_match = m;
        owned_match.query = try a.dupe(u8, m.query);
        self.completion = .{ .arena = arena, .match = owned_match, .list = list };
        arena = .init(self.a);
    }

    fn settleFileCompletion(self: *App, mode: tui.Tui.Mode) !void {
        const lookup = self.file_lookup orelse return;
        if (!lookup.done.isSet()) return;
        self.file_lookup = null;
        defer lookup.destroy(self.a);
        try lookup.future.await(self.io);
        if (!self.composerOwnsCompletion() or self.editor.cursor != lookup.cursor or
            !std.mem.eql(u8, self.editor.text(), lookup.draft)) return;
        if (lookup.menu.list.items.len != 0) {
            self.completion = lookup.menu;
            self.completion.?.list.capacity = self.preferences.completionLimit();
            lookup.menu.arena = .init(self.a);
            if (lookup.explicit_tab and self.completion.?.list.items.len == 1) try self.acceptCompletion(false);
        }
        for (lookup.pending_keys.items) |input| try self.key(input, mode);
    }

    fn acceptCompletion(self: *App, enter: bool) !void {
        const menu = if (self.completion) |*value| value else return;
        const cursor = self.editor.cursor;
        const current = Completion.context(&self.presentation, self.editor.text()[0..cursor], menu.match.kind == .path);
        if (current == null or !std.meta.eql(current.?.kind, menu.match.kind) or current.?.start != menu.match.start or
            !std.mem.eql(u8, current.?.query, menu.match.query))
        {
            self.clearCompletion();
            return;
        }
        const item = menu.list.items[menu.list.selected];
        const is_command = menu.match.kind == .command;
        const is_reference = menu.match.kind == .reference;
        const is_directory = std.mem.endsWith(u8, item.label, "/");
        const value = if (is_command or (is_reference and !is_directory))
            try std.fmt.allocPrint(menu.arena.allocator(), "{s}{s} ", .{ if (is_command) "/" else "", item.value })
        else
            item.value;
        const quoted = std.mem.startsWith(u8, menu.match.query, "\"") or std.mem.startsWith(u8, menu.match.query, "@\"");
        const closing_quote = std.mem.endsWith(u8, item.value, "\"");
        if ((menu.match.kind == .path or is_reference) and quoted and
            closing_quote and cursor < self.editor.text().len and
            self.editor.text()[cursor] == '"')
        {
            self.editor.cursor += 1;
        }
        self.editor.replaceToCursor(menu.match.start, value) catch |err| {
            self.editor.cursor = cursor;
            return err;
        };
        if ((menu.match.kind == .path or is_reference) and is_directory and closing_quote) {
            try self.editor.move(.left);
        }
        self.clearCompletion();
        if (enter and is_command) try self.submit(false);
    }

    fn closeDialog(self: *App) void {
        if (self.auth_job) |job| job.destroy(self.a);
        self.auth_job = null;
        if (self.dialog) |dialog| {
            dialog.destroy();
            self.clipboard_modal_lifetime +%= 1;
        }
        self.dialog = null;
        self.requested_model = null;
        self.routes_dirty = true;
    }
    fn currentRecord(self: *App, a: std.mem.Allocator) !Auth.Record {
        const provider = try self.controller.providerSnapshot(a);
        return .{ .kind = Auth.kindFor(&provider), .base_url = provider.base_url, .model = provider.model, .token = provider.api_key, .account_id = provider.account_id };
    }
    fn selectChoice(self: *App, choice: ModelChoices.Choice) !bool {
        if (choice.source == .saved or choice.source == .pending) {
            try self.finishLogin(choice.record, choice.observed);
            return true;
        }
        var scratch: std.heap.ArenaAllocator = .init(self.a);
        defer scratch.deinit();
        if (ModelRoutes.same(try self.currentRecord(scratch.allocator()), choice.record) and !self.controller.settings.refresh_saved_auth) return self.commitModel(choice.model_id, choice.observed);
        const next = try Auth.providerWithEndpointOverride(self.controller.a, choice.record);
        try self.controller.setProvider(next, .environment, choice.observed);
        self.outcome_visible = false;
        self.auth.configured = true;
        self.closeDialog();
        try self.history();
        return true;
    }
    fn commitModel(self: *App, name: []const u8, observed: ?registry.Model) !bool {
        try self.controller.setModel(name, observed);
        self.outcome_visible = false;
        if (self.auth.active()) |saved| {
            var scratch: std.heap.ArenaAllocator = .init(self.a);
            defer scratch.deinit();
            if (ModelRoutes.same(saved, try self.currentRecord(scratch.allocator()))) {
                var selected = saved;
                selected.model = self.controller.modelName();
                self.auth.save(selected) catch return false;
            }
        }
        return true;
    }
    fn finishLogin(self: *App, credential: Auth.Record, observed: ?registry.Model) !void {
        const next = try Auth.provider(self.controller.a, credential);
        try self.auth.remember(credential);
        try self.controller.setProvider(next, .saved, observed);
        const remembered_default = if (self.auth.save(credential)) |_| true else |_| false;
        self.auth.configured = true;
        self.outcome_visible = false;
        self.closeDialog();
        try self.history();
        self.notice = try std.fmt.allocPrint(self.arena, "Configured {s} · {s}. The first model request tests server authorization.", .{ self.controller.provider.base_url, self.controller.modelName() });
        if (!remembered_default) try self.setOutcome("Provider selected for this session. Could not save the default for new sessions.");
    }
    fn acceptChoice(self: *App, choice: ModelChoices.Choice) !void {
        const persisted = try self.selectChoice(choice);
        self.closeDialog();
        self.model = self.controller.modelName();
        self.notice = if (persisted) "" else "Model selected for this session. Could not save preference.";
        try self.showStatus(try std.fmt.allocPrint(self.arena, "Model: {s}", .{self.model}));
        if (!persisted) try self.setOutcome(self.notice);
    }
    fn applyAction(self: *App, value: Dialogs.Action) !void {
        switch (value) {
            .none => {},
            .cancel => {
                const remembered = if (self.dialog) |dialog| dialog.authorization_saved else false;
                self.closeDialog();
                self.notice = if (remembered) "Authorization saved. Model unchanged." else "";
            },
            .login_models => self.routes_dirty = true,
            .select_custom => |name| {
                const owned = try self.arena.dupe(u8, name);
                if (self.dialog.?.record.token.len != 0) {
                    var credential = self.dialog.?.record;
                    credential.model = owned;
                    try self.finishLogin(credential, null);
                } else {
                    if (!self.auth.configured) return error.LoginRequired;
                    const persisted = try self.commitModel(owned, null);
                    self.closeDialog();
                    self.model = self.controller.modelName();
                    self.notice = if (persisted) "" else "Model selected for this session. Could not save preference.";
                    try self.showStatus(try std.fmt.allocPrint(self.arena, "Model: {s}", .{self.model}));
                    if (!persisted) try self.setOutcome(self.notice);
                }
            },
            .forget => |kind| {
                const logout = self.dialog.?.step == .logout;
                try self.auth.forget(kind);
                if (kind == .openai) self.controller.settings.refresh_saved_auth = false;
                self.closeDialog();
                self.routes_dirty = true;
                if (logout) {
                    const provider = self.presentation.pickers.dialog.provider(kind);
                    try self.showStatus(try std.fmt.allocPrint(self.arena, "Removed saved credentials for {s}.", .{provider.label}));
                } else try self.setOutcome("Saved credentials removed from auth.conf; legacy import suppressed. Legacy auth.json remains on disk. No remote revocation. Other profiles preserved. In-process route and environment credentials remain until changed or restarted.");
            },
            .device => {
                self.device_code_shown = false;
                self.auth_job = try Auth.DeviceJob.start(self.a, self.io, self.auth, self.controller.authSizeSink(), self.notification());
            },
            .select_model => |name| {
                var scratch: std.heap.ArenaAllocator = .init(self.a);
                defer scratch.deinit();
                const choices = try ModelChoices.project(scratch.allocator(), self.model_routes, &self.discovery, self.dialog.?.record.token.len != 0);
                const choice = (try ModelChoices.lookup(choices, name)) orelse return error.UnknownRegistryModel;
                try self.acceptChoice(choice);
            },
        }
    }
    fn notification(self: *App) UiWake.Notification {
        return self.mailbox.wake.notification();
    }
    fn settleAuth(self: *App) void {
        self.settleAuthInner() catch |err| {
            self.reportError(err);
            self.closeDialog();
        };
    }
    fn settleAuthInner(self: *App) !void {
        const job = self.auth_job orelse return;
        if (!job.done.isSet()) return;
        job.future.await(self.io);
        self.auth_job = null;
        defer job.destroy(self.a);
        const dialog = self.dialog orelse return;
        if (job.failure) |err| {
            dialog.message = @errorName(err);
            dialog.step = .providers;
            dialog.editor.clear();
            return;
        }
        try self.auth.reload();
        try dialog.copyRecord(job.result.?);
        dialog.step = .models;
        dialog.authorization_saved = true;
        dialog.custom_endpoint = dialog.record.base_url;
        self.routes_dirty = true;
    }
    fn openModels(self: *App, requested: ?[]const u8) !void {
        try self.syncAuth();
        self.routes_dirty = true;
        _ = try self.syncRoutes();
        if (self.model_routes.len == 0) {
            self.notice = "Use /login to configure a provider before selecting a model.";
            return;
        }
        self.dialog = try Dialogs.create(self.a, .models);
        errdefer self.closeDialog();
        self.requested_model = if (requested) |name| try self.dialog.?.copy(name) else null;
        self.dialog.?.custom_endpoint = try self.dialog.?.copy(self.controller.provider.base_url);
        self.dialog.?.custom_account = try self.dialog.?.copy(self.controller.provider.account_id orelse "");
        // Resolve on the event loop after command submission has finished.
        self.routes_dirty = true;
    }
    fn skillCommands(self: *const App) bool {
        return self.preferences.skill_commands orelse self.controller.skills.enable_commands;
    }

    fn settingsItems(self: *const App) Settings.Items {
        return self.preferences.items(self.presentation.settings, self.supports_images, self.skillCommands(), self.startup_default, self.controller.runPolicy());
    }

    fn closeSettings(self: *App) void {
        self.closeThemePicker();
        if (self.settings_list) |*list| {
            list.deinit();
            self.clipboard_modal_lifetime +%= 1;
        }
        self.settings_list = null;
    }

    fn applyPreference(self: *App, updated: Settings, item: Settings.Item) !bool {
        const previous_mode = self.preferences.tui_mode;
        const saved = if (self.settings_path) |path|
            updated.save(self.a, self.io, path, item) catch |err| {
                self.notice = try std.fmt.allocPrint(self.arena, "Failed to save settings: {s}", .{@errorName(err)});
                return false;
            }
        else
            try updated.ownTheme(self.a);
        const theme_changed = !std.mem.eql(u8, self.preferences.theme orelse Theme.system_name, saved.theme orelse Theme.system_name);
        if (self.saved_theme) |old| self.a.free(old);
        self.saved_theme = saved.theme;
        self.preferences = saved.withTerminalDefaults(self.workspace_runtime.environment);
        if (theme_changed) {
            if (self.theme.select(self.preferences.theme orelse Theme.system_name)) self.themeChanged();
            self.theme_sync_dirty = true;
        }
        if (item != .tui_mode) self.preferences.tui_mode = previous_mode;
        self.controller.setRunPolicy(self.preferences.runPolicy(self.run_defaults));
        self.controller.setCodexTransportPreference(self.preferences.codexTransportPreference());
        const show_thinking = !(self.preferences.hide_thinking orelse false);
        if (self.thinking != show_thinking) {
            self.thinking = show_thinking;
            self.thinking_overrides.clearRetainingCapacity();
            self.clearPointer();
            self.selection.clear();
            if (self.search) |*search| search.index.invalidate();
        }
        if (self.preferences.fullscreen_scrollbar == .hidden) self.scrollbar = .{};
        self.notice = "";
        return true;
    }

    fn settingsAction(self: *App, entries: *const Settings.Items, action: tui.SettingsList.Action) !void {
        switch (action) {
            .none => {},
            .cancel => self.closeSettings(),
            .activate => |index| {
                const item = entries.ids[index];
                if (item == .theme) {
                    try self.reloadThemes(.keep_watched);
                    self.theme_picker = .init(self.a, &self.theme, self.preferences.theme orelse Theme.system_name);
                    return;
                }
                const updated = self.preferences.cycle(item, self.skillCommands(), self.startup_default, self.controller.runPolicy());
                if (item == .tui_mode) self.pending_mode = updated else _ = try self.applyPreference(updated, item);
            },
        }
    }

    fn reloadThemes(self: *App, mode: Theme.CatalogReload) !void {
        const was_following = self.theme.choice.followsTerminal();
        try self.theme.loadCatalog(self.a, self.io, self.theme_resources, mode);
        if (self.theme.select(self.preferences.theme orelse Theme.system_name)) self.themeChanged();
        if (self.theme.choice.followsTerminal() != was_following) self.theme_sync_dirty = true;
    }

    fn closeThemePicker(self: *App) void {
        if (self.theme_picker) |*picker| picker.deinit();
        self.theme_picker = null;
        if (self.theme.showPreview(null)) self.themeChanged();
    }

    fn themeAction(self: *App, action: ThemePicker.Action) !void {
        switch (action) {
            .none => {},
            .cancel => self.closeThemePicker(),
            .preview => |choice| if (self.theme.showPreview(choice)) self.themeChanged(),
            .apply => |selection| {
                var scratch: std.heap.ArenaAllocator = .init(self.a);
                defer scratch.deinit();
                var updated = self.preferences;
                updated.theme = try selection.format(scratch.allocator());
                if (try self.applyPreference(updated, .theme)) self.closeThemePicker();
            },
        }
    }

    fn idleEscape(self: *App) !void {
        if (try self.controller.abortManualCompactions()) {
            self.notice = "Compaction stopped.";
            return;
        }
        self.notice = "";
        if (self.editor.text().len != 0) return;
        const now = Io.Timestamp.now(self.io, .awake);
        if (self.last_escape) |last| {
            if (last.durationTo(now).toMilliseconds() < 500) {
                self.last_escape = null;
                return switch (self.preferences.double_escape orelse .tree) {
                    .tree => self.openTree(null),
                    .fork => _ = try self.command(.fork, ""),
                    .none => {},
                };
            }
        }
        self.last_escape = now;
    }

    fn key(self: *App, k: kit.terminal.keys.Key, mode: tui.Tui.Mode) !void {
        if (k.kind == .release) return;
        if (!(k.code == .char and k.mods.ctrl and k.code.char == 'c')) self.interrupt = null;
        if (k.code != .escape) self.last_escape = null;
        if (self.theme_picker) |*picker| return self.themeAction(try picker.key(self.a, &self.theme, k));
        if (self.settings_list) |*list| {
            const entries = self.settingsItems();
            return self.settingsAction(&entries, try list.key(self.a, entries.rows[0..entries.count], k));
        }
        if (self.session_selector) |*selector| {
            switch (try selector.key(k)) {
                .cancel => self.closeSessionSelector(),
                .none => {},
                .rename => |rename| try self.renamePickerSession(selector, rename),
                .delete => |session| selector.mutate(session, null) catch |err| try selector.reportMutationError("delete", err),
                .select => |session| {
                    const path = try self.arena.dupe(u8, session.path);
                    const existing = Controller.SessionTarget{ .existing = .{ .path = path, .inode = session.inode, .legacy_workspace_known = session.workspace.len != 0 } };
                    self.closeSessionSelector();
                    try self.replaceSession(existing);
                },
            }
            return;
        }
        if (self.missing_workspace) |*dialog| {
            if (self.presentation.shortcut(k) == .expand_tools) return self.toggleTools();
            if (dialog.prompt.key(k)) |answer| try self.answerMissingWorkspace(answer);
            return;
        }
        if (self.tree) |tree| return self.treeKey(tree, k);
        if (self.fork_selector) |*selector| {
            switch (selector.key(k)) {
                .confirm => try self.confirmFork(selector.messages[selector.selected].id),
                .cancel => self.closeFork(),
                .none => {},
            }
            return;
        }
        if (mode == .fullscreen and try self.searchKey(k)) return;
        if (self.dialog) |dialog| {
            self.interrupt = null;
            const pending = dialog.record.token.len != 0;
            try self.applyAction(try dialog.key(k, self.controller));
            if (self.dialog == dialog and pending != (dialog.record.token.len != 0)) self.routes_dirty = true;
            return;
        }
        if (self.thinking_picker) |selected| {
            if (k.code == .escape or (k.code == .char and k.mods.ctrl and (k.code.char == 'c' or k.code.char == 'd'))) {
                self.thinking_picker = null;
                self.interrupt = null;
                return;
            }
            const profile = (try self.controller.thinkingProfile()).?;
            switch (k.code) {
                .escape => unreachable,
                .enter => {
                    try self.controller.setThinking(selected);
                    self.thinking_picker = null;
                    try self.showThinkingLevel();
                },
                .down => self.thinking_picker = try profile.cycle(selected),
                .tab => {
                    if (!k.mods.shift) {
                        self.thinking_picker = try profile.cycle(selected);
                    } else {
                        var previous = selected;
                        var next = try profile.cycle(selected);
                        while (next != selected) {
                            previous = next;
                            next = try profile.cycle(next);
                        }
                        self.thinking_picker = previous;
                    }
                },
                .up => {
                    var previous = selected;
                    var next = try profile.cycle(selected);
                    while (next != selected) {
                        previous = next;
                        next = try profile.cycle(next);
                    }
                    self.thinking_picker = previous;
                },
                else => {},
            }
            return;
        }
        if (k.code == .char and k.code.char == 'v' and !k.mods.shift and !k.mods.super and !k.mods.hyper and !k.mods.meta and
            ((k.mods.ctrl and !k.mods.alt) or (k.mods.alt and !k.mods.ctrl and UiPresentation.usesWindowsBindings(self.environ))))
        {
            self.startClipboardRead(null) catch |err| try self.clipboardReadError(err);
            return;
        }
        const prior = self.completionMatch();
        const force_paths = prior != null and prior.?.kind == .path;
        if (mode == .fullscreen and self.completion == null and !force_paths and self.viewportKey(k)) return;
        if (job_control.supported and k.code == .char and k.code.char == 'z' and k.mods.ctrl and
            !k.mods.shift and !k.mods.alt and !k.mods.super and !k.mods.hyper and !k.mods.meta)
        {
            job_control.requestSuspend();
            return;
        }
        if (self.presentation.shortcut(k)) |action| return switch (action) {
            .expand_tools => self.toggleTools(),
            .toggle_thinking => {
                const updated = self.preferences.cycle(.hide_thinking, self.skillCommands(), self.startup_default, self.controller.runPolicy());
                if (try self.applyPreference(updated, .hide_thinking))
                    try self.showStatus(if (self.thinking) "Thinking blocks: visible" else "Thinking blocks: hidden");
            },
            .cycle_thinking => self.cycleThinking(),
            .select_model => {
                self.clearCompletion();
                try self.openModels(null);
            },
            .external_editor => self.edit_external = true,
            .follow_up => {
                self.clearCompletion();
                try self.submit(true);
            },
            .restore_queued => _ = try self.editQueued(null),
        };
        // Application shortcuts bypass Pi's editor, including Escape when no menu owns it.
        const app_key = switch (k.code) {
            .escape => self.completion == null and self.file_lookup == null,
            .char => |cp| k.mods.ctrl and switch (cp) {
                'c', 'x' => true,
                'd' => self.editor.text().len == 0,
                else => false,
            },
            else => false,
        };
        if (!app_key and self.editor.jumpKey(k)) return;
        if (k.code == .escape and (self.completion != null or self.file_lookup != null)) {
            self.clearCompletion();
            return;
        }
        if (!k.mods.alt and !k.mods.shift and !k.mods.ctrl and !k.mods.super and !k.mods.hyper and !k.mods.meta) switch (k.code) {
            .up, .down, .page_up, .page_down, .tab, .enter => {
                if (self.completion) |*menu| {
                    if (k.code == .tab or k.code == .enter) return self.acceptCompletion(k.code == .enter);
                    menu.list.advance(k.code == .up or k.code == .page_up, k.code == .page_up or k.code == .page_down);
                    return;
                }
                if (self.file_lookup) |lookup| if (lookup.menu.match.kind == .path) {
                    try lookup.pending_keys.append(self.a, k);
                    return;
                };
            },
            else => {},
        };
        const quit_or_delete = k.code == .char and k.mods.ctrl and k.code.char == 'd';
        if (!quit_or_delete and try self.editor.editKey(k)) {
            const motion = Editor.keyMotion(k);
            const reopens = motion == .backspace or motion == .delete;
            if (prior != null or reopens) try self.refreshCompletion(force_paths, false);
            return;
        }
        if (k.code == .char and k.mods.ctrl) {
            switch (k.code.char) {
                'c' => {
                    const now = Io.Timestamp.now(self.io, .awake);
                    if (self.interrupt) |last| if (last.durationTo(now).toMilliseconds() <= 500) {
                        self.quit = true;
                        return;
                    };
                    self.interrupt = now;
                    self.clearCompletion();
                    try self.editor.clearForEdit();
                },
                'd' => {
                    if (self.editor.text().len == 0) self.quit = true else try self.editor.move(.delete);
                },
                'x' => if (self.screen_selection.range() != null) {
                    self.screen_selection.copy_pending = true;
                } else if (self.selection.range() != null) {
                    self.selection.copy_pending = true;
                } else try self.copyLastAssistant(true),
                'j' => try self.editor.insert("\n"),
                else => {},
            }
            if (k.code.char == 'j') self.clearCompletion();
            if (k.code.char == 'd' and !self.quit) try self.refreshCompletion(force_paths, false);
            return;
        }
        self.interrupt = null;
        switch (k.code) {
            .enter => {
                if (k.mods.alt and !k.mods.shift) return;
                self.clearCompletion();
                if (k.mods.shift) {
                    try self.editor.insert("\n");
                } else if (self.editor.cursor > 0 and self.editor.text()[self.editor.cursor - 1] == '\\') {
                    try self.editor.replaceToCursor(self.editor.cursor - 1, "\n");
                } else try self.submit(false);
            },
            .escape => if (self.manualCompaction()) |id| {
                try self.controller.cancelManualCompaction(id);
            } else if (self.branchSummaryActive()) {
                self.job.?.future.cancel(self.io);
                try self.finishTurn();
            } else if (self.job != null) {
                try self.abort();
                self.notice = "";
            } else if (self.user_shell != null) {
                self.collectUserShell(true);
            } else if (ShellInput.Prefix.parse(self.editor.text()) != null) {
                self.editor.clear();
            } else try self.idleEscape(),
            .up, .down => {
                if (k.code == .up and k.mods.alt) return;
                self.clearCompletion();
                try self.editor.move(if (k.code == .up) .up else .down);
            },
            .page_up, .page_down => {},
            .left, .right, .home, .end, .backspace, .delete => return,
            .tab => if (!k.mods.shift) try self.refreshCompletion(true, true),
            .char => |cp| {
                if (k.mods.alt or k.mods.super or k.mods.meta or k.mods.hyper) return;
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &bytes) catch return;
                try self.editor.typeText(bytes[0..len]);
                if (prior != null) return self.refreshCompletion(force_paths, false);
                if (Completion.triggered(&self.presentation, self.editor.text()[0..self.editor.cursor], cp)) |match|
                    try self.showCompletion(match, false);
            },
        }
    }
    fn shellJobCard(self: *App, a: std.mem.Allocator, job: *const ShellInput.Job, display: ShellInput.Display, running: bool) !tui.Node {
        if (!running) return ShellInput.render(a, job.result catch .{ .command = job.prefix.command, .excluded = job.prefix.excluded, .result = .{} }, display, null);
        const record = try job.preview(a);
        const elapsed = job.started.durationTo(Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        const spinner = working_frames[@intCast(@mod(@divFloor(elapsed, 80), working_frames.len))];
        return ShellInput.render(a, record, display, spinner);
    }

    fn shellCard(self: *App, a: std.mem.Allocator, event: Event, display: ShellInput.Display) !tui.Node {
        if (event.data == .null) {
            if (self.user_shell) |job| if (std.mem.eql(u8, &job.id, event.call_id)) return self.shellJobCard(a, job, display, true);
            for (self.completed_shells.items) |job| {
                if (std.mem.eql(u8, &job.id, event.call_id)) return self.shellJobCard(a, job, display, false);
            }
        }
        const record: Controller.UserShell = if (event.data == .null)
            .{ .command = event.text, .excluded = std.mem.eql(u8, event.name, "excluded"), .result = .{} }
        else
            try std.json.parseFromValueLeaky(Controller.UserShell, a, event.data, .{});
        return ShellInput.render(a, record, display, null);
    }

    fn updateTerminalTitle(self: *App, screen: *tui.Tui) !void {
        if (!self.terminal_title_dirty or !screen.interactive) return;
        const directory = std.fs.path.basename(self.controller.settings.workspace);
        const title = if (self.session_name) |name|
            try std.fmt.allocPrint(self.a, "cpi-minimal - {s} - {s}", .{ name, directory })
        else
            try std.fmt.allocPrint(self.a, "cpi-minimal - {s}", .{directory});
        defer self.a.free(title);
        const writer = screen.writer();
        try kit.terminal.title.write(writer, title);
        try writer.flush();
        self.terminal_title_dirty = false;
    }

    fn themeChanged(self: *App) void {
        self.syntax.clearCache();
        for (self.arguments.items) |*entry| entry.write_highlight.deinit();
        if (self.search) |*search| search.index.invalidate();
    }

    fn composerStatus(self: *const App, a: std.mem.Allocator, border: tui.Style) !?ComposerView.Status {
        if (self.job == null) return null;
        const now = Io.Timestamp.now(self.io, .awake);
        const palette = &self.theme.palette;
        var started = self.started orelse now;
        var status: ComposerView.Status = .{
            .spinner = "",
            .message = "Working",
            .spinner_style = border,
            .message_style = border,
        };
        if (self.retry_display) |retry| {
            started = retry.started;
            const elapsed = @max(0, started.durationTo(now).toMilliseconds());
            const seconds = (retry.info.delay_ms -| @as(u64, @intCast(elapsed)) +| 999) / 1000;
            status.message = if (retry.info.max_attempts) |limit|
                try std.fmt.allocPrint(a, "Retrying ({d}/{d}) in {d}s... (escape to cancel)", .{ retry.info.attempt, limit, seconds })
            else
                try std.fmt.allocPrint(a, "Retrying ({d}) in {d}s... (escape to cancel)", .{ retry.info.attempt, seconds });
            status.spinner_style = palette.style(.warning);
            status.message_style = palette.style(.muted);
        } else if (self.branchSummaryActive()) {
            status.message = "Summarizing branch... (escape to cancel)";
            status.spinner_style = palette.style(.accent);
            status.message_style = palette.style(.muted);
        } else if (self.manualCompaction() != null) {
            status.message = "Compacting context... (escape to cancel)";
        } else if (self.auto_compacting) |reason| {
            status.message = if (reason == .overflow)
                "Context overflow detected, Auto-compacting... (escape to cancel)"
            else
                "Auto-compacting... (escape to cancel)";
        }
        const elapsed = started.durationTo(now).toMilliseconds();
        status.spinner = working_frames[@intCast(@mod(@divFloor(elapsed, 80), working_frames.len))];
        return status;
    }

    fn replyCard(self: *App, a: std.mem.Allocator, reply: AssistantContent, slot: usize, columns: u16, padding: u16, exiting: bool, fullscreen: bool) !?tui.Node {
        if (reply.runs.len == 0) return null;
        const width = @max(1, columns -| (2 * padding));
        const palette = &self.theme.palette;
        const label = self.presentation.transcript.hidden_thinking_label;
        var nodes: std.ArrayList(tui.Node) = .initBuffer(try a.alloc(tui.Node, reply.runs.len * 2 - 1));
        var blocks = reply.iterator();
        var thought_run: ThinkingRun = .{ .slot = slot, .ordinal = 0 };
        var gap = false;
        while (blocks.next()) |block| {
            const text = AssistantContent.trim(block.text);
            if (text.len == 0) continue;
            const node = if (block.kind == .prose)
                try md.assistantBlock(a, &self.syntax, palette, text, width, .prose)
            else reasoning: {
                defer thought_run.ordinal += 1;
                const inverted = !exiting and std.sort.binarySearch(ThinkingRun, self.thinking_overrides.items, thought_run, ThinkingRun.order) != null;
                const hidden = self.thinking == inverted;
                if (hidden and kit.unicode.onlyEcmaWhitespace(label)) continue;
                const summary = try md.assistantBlock(a, &self.syntax, palette, if (hidden) label else text, width, if (hidden) .placeholder else .reasoning);
                const mouse_key = if (!exiting and fullscreen) thought_run.mouseKey() else null;
                break :reasoning if (mouse_key) |id| try md.mouseRegion(a, id, summary) else summary;
            };
            if (gap) nodes.appendAssumeCapacity(.{ .spacer = 1 });
            nodes.appendAssumeCapacity(node);
            gap = block.kind == .reasoning;
        }
        if (nodes.items.len == 0) return null;
        return .{ .box = .{ .padding = .{ .left = padding, .right = padding }, .children = nodes.items } };
    }

    fn toolPreview(self: *App, a: std.mem.Allocator, event: Event, tool: UiPresentation.Tool, active: ?*Arguments) ToolView.Live {
        const stream = active orelse return .none;
        if (tool == .write and (event.kind == .tool_arguments_start or event.kind == .tool_arguments_delta))
            return .{ .write = &stream.write_highlight };
        if (self.job == null) return .none;
        if (tool == .edit and (event.kind == .tool_arguments_end or event.kind == .tool_start)) {
            if (stream.edit_preview) |job| if (job.result()) |body| return .{ .edit = body };
        }
        if (event.kind != .tool_start or (tool != .bash and tool != .execute_lua)) return .none;
        const started = event.tool_started orelse return .none;
        const elapsed = started.durationTo(Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        if (tool == .execute_lua) return .{ .script = .{ .calls = stream.script_calls.items, .elapsed_ms = elapsed } };
        const progress = self.controller.processProgress(a, event.tool_delivery) catch null;
        return .{ .shell = .{ .output = if (progress) |process| process.output else "", .elapsed_ms = elapsed } };
    }

    fn draw(self: *App, screen: *tui.Tui, exiting: bool) !void {
        try self.tool_images.settle(self.a, self.io);
        const a = screen.arena;
        const columns = screen.size.col;
        const output_padding = self.preferences.outputPadding();
        const expand_key = self.presentation.shortcuts.expand_tools.label;
        const palette = &self.theme.palette;
        const pickers = &self.presentation.pickers;
        const shell_display: ShellInput.Display = .{
            .columns = columns,
            .padding = output_padding,
            .expanded = self.expanded,
            .palette = palette,
            .expand_key = expand_key,
            .collapsed_rows = self.presentation.shell.collapsed_rows,
        };
        const hardware = !exiting and self.thinking_picker == null and (self.preferences.show_hardware_cursor orelse false);
        screen.show_hardware_cursor = hardware;
        const image_protocol: ?ToolImages.Protocol = switch (screen.options.media) {
            .pixels => .kitty,
            .iterm2 => .iterm2,
            .cells, .none => null,
        };
        self.supports_images = image_protocol != null;
        const inline_images = self.supports_images and (!exiting or image_protocol == .iterm2) and (self.preferences.show_images orelse true);
        var copied: tui.Selection.Copy = .{ .allocator = self.a };
        defer if (copied.text) |text| self.a.free(text);
        defer self.tool_images.endFrame(self.a);
        var document: std.ArrayList(tui.Node) = .empty;
        var children: std.ArrayList(tui.Node) = .empty;
        if (self.theme.initialized) {
            const rows = switch (self.quiet_startup) {
                .hidden => &.{},
                .header => if (self.expanded) self.presentation.startup.expanded else self.presentation.startup.header,
                .full => if (self.expanded) self.presentation.startup.expanded else self.presentation.startup.compact,
            };
            try StartupView.appendHeader(a, &document, rows, self.theme.truecolor, self.startup_logo, palette);
            try StartupView.appendSkills(a, &document, &self.controller.skills, self.home, palette, self.quiet_startup == .full, self.expanded);
        }
        const events = if (exiting)
            if (self.controller.historyPage(a, null, std.math.maxInt(usize))) |page| page.events else |_| self.transcript.items
        else
            self.transcript.items;
        var has_chat = false;
        // Opening and removing streams preserves transcript slot order.
        var streams: []Arguments = if (exiting) &.{} else self.arguments.items;
        for (events, 0..) |event, slot| {
            const active = if (streams.len != 0 and streams[0].slot == slot) &streams[0] else null;
            if (active != null) streams = streams[1..];
            const card = switch (event.kind) {
                .user_shell => try self.shellCard(a, event, shell_display),
                .assistant => try self.replyCard(a, event.reply, slot, columns, output_padding, exiting, screen.mode == .fullscreen) orelse continue,
                .compacted, .branch_summary => blk: {
                    const kind: md.Summary = if (event.kind == .compacted) .{ .compacted = event.compaction_tokens_before } else .branch;
                    const expanded = self.expanded != self.tool_expansions.contains(event.entry_id);
                    const summary = try md.summary(a, &self.syntax, palette, kind, event.text, columns, output_padding, expanded, expand_key);
                    break :blk if (exiting) summary else try md.mouseRegion(a, slot + 1, summary);
                },
                .tool_start, .tool_end, .tool_arguments_start, .tool_arguments_delta, .tool_arguments_end => tool_card: {
                    const tool = std.meta.stringToEnum(UiPresentation.Tool, event.name) orelse .other;
                    const live = self.toolPreview(a, event, tool, active);
                    const local = if (event.kind == .tool_end) self.tool_expansions.contains(event.entry_id) else if (active) |stream| stream.expansion_override else false;
                    break :tool_card try ToolView.render(a, event, tool, .{
                        .columns = columns,
                        .output_padding = output_padding,
                        .expanded = self.expanded != local,
                        .mouse_key = if (exiting) null else slot + 1,
                        .theme = palette,
                        .location = .{ .cwd = self.controller.settings.workspace, .home = self.home, .hyperlinks = self.hyperlinks },
                        .syntax = &self.syntax,
                        .presentation = &self.presentation,
                        .images = if (inline_images and event.images.len != 0) .{
                            .previews = try self.tool_images.get(self.a, self.controller, self.mailbox.wake.notification(), event, image_protocol.?),
                            .protocol = image_protocol.?,
                            .cell_width = screen.options.cell_width,
                            .cell_height = screen.options.cell_height,
                            .preferred_width = self.preferences.imageWidth(),
                        } else null,
                    }, live);
                },
                .notice => blk: {
                    if (std.mem.eql(u8, event.name, session_info_notice) and event.data == .object) {
                        var rows: std.ArrayList(tui.Node) = .empty;
                        try UiPresentation.Frame.appendBound(a, &rows, self.presentation.session_info.rows, columns -| (2 * output_padding), palette, event.data);
                        break :blk tui.Node{ .box = .{ .padding = .{ .left = output_padding, .right = output_padding }, .children = rows.items } };
                    }
                    const role: Theme.Role = if (std.mem.eql(u8, event.name, name_warning))
                        .warning
                    else if (std.mem.eql(u8, event.name, error_notice))
                        .@"error"
                    else if (std.mem.eql(u8, event.name, status_notice) or std.mem.eql(u8, event.name, name_notice))
                        .dim
                    else
                        break :blk try md.event(a, &self.syntax, event.kind, event.text, self.expanded, columns, output_padding, palette, expand_key);
                    break :blk tui.Node{ .box = .{
                        .padding = .{ .left = output_padding, .right = output_padding },
                        .children = try a.dupe(tui.Node, &.{palette.text(role, try md.clean(a, event.text))}),
                    } };
                },
                else => try md.event(a, &self.syntax, event.kind, event.text, self.expanded, columns, output_padding, palette, expand_key),
            };
            const leading = switch (event.kind) {
                .user => has_chat,
                .user_shell => false,
                else => true,
            };
            try document.append(a, .{ .stack = .{
                .children = if (leading) try a.dupe(tui.Node, &.{ .{ .spacer = 1 }, card }) else try a.dupe(tui.Node, &.{card}),
                .scroll_stop = event.kind == .user,
            } });
            has_chat = true;
        }
        for (self.completed_shells.items) |job| {
            if (job.deferred) try children.append(a, try self.shellJobCard(a, job, shell_display, false));
        }
        if (self.user_shell) |job| {
            if (job.deferred) try children.append(a, try self.shellJobCard(a, job, shell_display, true));
        }
        if (self.queue_paused and self.queue.items.len != 0) try children.append(a, tui.text(try std.fmt.allocPrint(a, "[ QUEUE PAUSED ] {d} pending · /queue continue · /queue edit · /queue discard", .{self.queue.items.len}), .strong));
        try self.queue_preview.refresh(self.controller);
        const active_submission = self.dispatchedInput();
        var has_pending = false;
        for ([_]bool{ true, false }) |steering| {
            const labels = self.presentation.queue_labels;
            const label = if (steering) labels.steering else labels.follow_up;
            for (self.queue_preview.messages()) |message| {
                if ((message.kind == .steering) != steering) continue;
                if (active_submission) |id| if (std.mem.eql(u8, message.id, id)) continue;
                try pendingMessageLine(a, &children, &has_pending, label, message.original, columns, output_padding, palette);
            }
            for (self.compaction_inputs.items) |message| {
                if (message.steering != steering) continue;
                try pendingMessageLine(a, &children, &has_pending, label, message.input.original, columns, output_padding, palette);
            }
        }
        if (has_pending) try children.append(a, try pendingLine(a, self.presentation.pending_hint, columns, output_padding, palette));
        if (self.dialog == null and (self.outcome_visible or self.recovery_required)) {
            if (self.outcome) |outcome| try children.append(a, tui.text(try md.clean(a, outcome), .strong));
        }
        if (self.notice.len > 0) try children.append(a, palette.text(.muted, try md.clean(a, self.notice)));
        if (self.thinking_picker) |selected| {
            try UiPresentation.Frame.append(a, &children, pickers.thinking.before, columns, palette);
            const profile = (try self.controller.thinkingProfile()).?;
            for (effort.levels) |level| if (profile.supports(level)) {
                try children.append(a, tui.text(try std.fmt.allocPrint(a, "{s} {s}", .{ if (selected == level) ">" else " ", @tagName(level) }), if (selected == level) .accent else .muted));
            };
            try UiPresentation.Frame.append(a, &children, pickers.thinking.after, columns, palette);
        }
        try children.append(a, .{ .spacer = 1 });
        self.composer_padding = @min(self.preferences.editorPadding(), (columns -| 1) / 2);
        self.composer_rows = 0;
        if (self.dialog) |dialog| {
            if (self.auth_job) |job| {
                job.mutex.lockUncancelable(self.io);
                defer job.mutex.unlock(self.io);
                if (job.code.len != 0 and !self.device_code_shown) {
                    dialog.message = try dialog.copy(try std.fmt.allocPrint(a, "Open {s}\nCode {s}\nComplete sign-in in your browser. Esc cancels.", .{ Auth.verification_uri, try md.clean(a, job.code) }));
                    self.device_code_shown = true;
                }
            }
            try dialog.draw(a, &children, &pickers.dialog);
        } else if (!exiting and self.session_selector != null) {
            try self.session_selector.?.draw(a, &children, columns, palette, self.home, Io.Clock.real.now(self.io).toMilliseconds(), hardware, pickers);
        } else if (!exiting and self.missing_workspace != null) {
            try self.missing_workspace.?.prompt.draw(a, &children, columns, palette, &pickers.workspace);
        } else if (!exiting and self.fork_selector != null) {
            try self.fork_selector.?.draw(a, &children, columns, palette, pickers.fork);
        } else if (!exiting and self.tree != null) {
            try self.tree.?.draw(a, &children, columns, screen.size.row, palette, self.home, Io.Clock.real.now(self.io).toMilliseconds(), hardware, &pickers.tree);
        } else if (!exiting and self.settings_list != null) {
            const rule = try md.horizontalRule(a, columns);
            try children.append(a, palette.text(.border, rule));
            if (self.theme_picker) |*picker| {
                try children.append(a, try picker.render(a, &self.theme, columns, &pickers.theme));
            } else {
                const entries = self.settingsItems();
                const menu = try a.create(tui.Node);
                menu.* = try self.settings_list.?.render(a, entries.rows[0..entries.count], columns, palette.settingsStyles());
                try children.append(a, .{ .mouse_region = .{ .key = settings_mouse_key, .child = menu } });
            }
            try children.append(a, palette.text(.border, rule));
        } else {
            const border = if (ShellInput.Prefix.parse(self.editor.text()) != null) palette.style(.bashMode) else palette.effort(self.controller.selected_effort);
            const status = if (exiting) null else try self.composerStatus(a, border);
            const frame = try ComposerView.render(a, &self.editor, columns, self.composer_padding, @max(5, @as(u32, screen.size.row) * 3 / 10), border, status, hardware);
            self.composer_rows = frame.editable_rows;
            try children.append(a, try md.mouseRegion(a, composer_mouse_key, frame.node));
        }
        if (!exiting and self.composerOwnsCompletion()) {
            if (self.completion) |*menu| {
                const padding = self.composer_padding;
                const list = try menu.list.render(a, columns -| (2 * padding), .{
                    .selected = palette.color(.accent),
                    .description = palette.color(.muted),
                    .description_faint = palette.style(.muted).faint,
                    .scroll = palette.color(.dim),
                    .scroll_faint = palette.style(.dim).faint,
                });
                const node: tui.Node = if (padding == 0) list else .{ .box = .{
                    .padding = .{ .left = padding, .right = padding },
                    .children = try a.dupe(tui.Node, &.{list}),
                } };
                try children.append(a, try md.mouseRegion(a, completion_mouse_key, node));
            }
        }
        try self.appendFooter(a, &children, columns);
        if (screen.mode == .fullscreen) {
            const transcript = try a.create(tui.Node);
            transcript.* = .{ .stack = .{ .children = document.items } };
            const selection_render: ?tui.Selection.Render = if (self.selection.range()) |range| .{
                .range = range,
                .copy = if (self.selection.copy_pending) &copied else null,
            } else null;
            const screen_range: ?tui.Selection.Render = if (self.screen_selection.range()) |range| .{
                .range = range,
                .copy = if (self.screen_selection.copy_pending) &copied else null,
            } else null;
            const scroll_now = Io.Timestamp.now(self.io, .awake);
            self.follow_button = null;
            var overlays: std.ArrayList(tui.layout.Overlay) = .empty;
            const search_paint: ?tui.layout.SearchPaint = if (self.search) |*search| paint: {
                if (self.job != null) search.index.invalidate();
                if (search.overlay(columns, screen.size.row, hardware)) |search_overlay| try overlays.append(a, search_overlay);
                const foreground = palette.color(.searchMatchText);
                const background = palette.color(.searchMatchBg);
                break :paint .{
                    .index = &search.index,
                    .matching = .{ .foreground = foreground, .background = background, .underline = true },
                    .current = .{ .foreground = foreground, .background = background, .bold = true, .inverse = true },
                };
            } else null;
            if (self.clipboard_flash) |flash| {
                const message = try std.fmt.allocPrint(a, " {s} ", .{flash.message});
                const width: u16 = @intCast(@min(columns, kit.terminal.span_display_width.measure(message)));
                try overlays.append(a, .{
                    .node = .{ .text = .{ .bytes = message, .style = .{ .inverse = true }, .overflow = .clip } },
                    .column = columns - width,
                    .row = 0,
                    .width = width,
                    .height = 1,
                });
            }
            try screen.presentWithDecorations(.{ .axis = .{
                .direction = .vertical,
                .children = &.{
                    .{ .grow = 1, .min = 1, .node = .{ .scroll = .{
                        .child = transcript,
                        .state = &self.scroll,
                        .scrollbar = false,
                        .selection = selection_render,
                        .search = search_paint,
                        .auto_scrollbar = if (self.preferences.fullscreen_scrollbar == .hidden) null else .{
                            .state = &self.scrollbar,
                            .now = scroll_now,
                            .track = palette.color(.scrollbarTrack),
                            .thumb = palette.color(.scrollbarThumb),
                            .always_visible = self.preferences.fullscreen_scrollbar == .always,
                        },
                        .follow_button = .{
                            .label = " ↓ Jump to latest message · Ctrl+End ",
                            .style = .{
                                .background = palette.color(.selectedBg),
                                .foreground = palette.color(.text),
                            },
                            .bounds = &self.follow_button,
                        },
                    } } },
                    .{ .node = .{ .stack = .{ .children = children.items } } },
                },
            } }, .{}, .{ .overlays = overlays.items, .selection = screen_range });
        } else {
            try document.appendSlice(a, children.items);
            try screen.present(.{ .stack = .{ .children = document.items } }, .{
                .clear_on_shrink = self.preferences.clear_on_shrink orelse false,
            });
        }
        self.selection.copy_pending = false;
        self.screen_selection.copy_pending = false;
        if (copied.text) |text| {
            if (text.len != 0) {
                self.setClipboardText(text, true);
                copied.text = null;
            }
        }
    }

    fn toggleToolExpansion(self: *App, id: []const u8) !void {
        if (self.search) |*search| search.index.invalidate();
        if (self.tool_expansions.fetchRemove(id)) |previous| {
            self.a.free(previous.key);
            return;
        }
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        try self.tool_expansions.put(self.a, owned_id, {});
    }

    fn toggleTools(self: *App) !void {
        self.selection = .{};
        self.expanded = !self.expanded;
        self.clearToolExpansions();
        for (self.arguments.items) |*stream| stream.expansion_override = false;
        self.clearPointer();
        try self.showStatus(if (self.expanded) "Tool output: expanded" else "Tool output: collapsed");
    }

    fn clearToolExpansions(self: *App) void {
        var keys = self.tool_expansions.keyIterator();
        while (keys.next()) |id| self.a.free(id.*);
        self.tool_expansions.clearRetainingCapacity();
    }

    fn blurTerminal(self: *App) void {
        self.clearPointer();
        self.completion_press = null;
        if (self.settings_list) |*list| list.pressed = null;
        self.selection.blur();
        self.screen_selection.blur();
        self.scrollbar.grab = null;
        self.scrollbar.hover(false, Io.Timestamp.now(self.io, .awake));
        if (self.search) |*search| search.hovered = null;
    }

    fn clearPointer(self: *App) void {
        if (self.pointer_press) |press| self.a.free(press.target.id);
        self.pointer_press = null;
        self.composer_press = null;
    }

    fn pointerTarget(self: *App, screen: *const tui.Tui, event: kit.terminal.keys.Mouse) ?PointerTarget {
        if (self.dialog != null or self.thinking_picker != null or event.row >= self.scroll.viewport_rows) return null;
        if (screen.hyperlinkAt(event.column, event.row)) |url| {
            if (std.mem.startsWith(u8, url, "file:///")) return .{
                .kind = .link,
                .id = url,
                .column = event.column,
                .row = @intCast(self.scroll.top + event.row),
            };
        }
        const hit = screen.mouseHit(event.column, event.row) orelse return null;
        if (hit.key == 0 or hit.key >= completion_mouse_key) return null;
        const slot_key: u32 = @truncate(hit.key);
        const ordinal = hit.key >> 32;
        if (slot_key == 0) return null;
        const index = slot_key - 1;
        const entries = self.transcript.items;
        if (index >= entries.len) return null;
        const entry = entries[index];
        if (ordinal != 0) {
            if (entry.kind != .assistant) return null;
            return .{ .kind = .thinking, .id = "", .thinking_run = .{ .slot = index, .ordinal = @intCast(ordinal - 1) }, .column = hit.column, .row = hit.row };
        }
        const complete = entry.kind == .tool_end or entry.kind == .branch_summary or entry.kind == .compacted;
        const id = if (complete) entry.entry_id else entry.call_id;
        if (id.len == 0) return null;
        return .{ .kind = if (complete) .tool else .running_tool, .id = id, .column = hit.column, .row = hit.row };
    }

    fn transcriptMouse(self: *App, screen: *const tui.Tui, event: kit.terminal.keys.Mouse) !void {
        switch (event.kind) {
            .press => {
                self.clearPointer();
                if (event.button != .left) return;
                var target = self.pointerTarget(screen, event) orelse return;
                target.id = try self.a.dupe(u8, target.id);
                self.pointer_press = .{ .target = target, .column = event.column, .row = event.row };
            },
            .release => {
                const press = self.pointer_press orelse return;
                defer self.clearPointer();
                if (press.column != event.column or press.row != event.row) return;
                const target = self.pointerTarget(screen, event) orelse return;
                if (target.kind != press.target.kind or target.column != press.target.column or target.row != press.target.row or
                    !std.meta.eql(target.thinking_run, press.target.thinking_run) or !std.mem.eql(u8, target.id, press.target.id)) return;
                if (target.kind == .link) {
                    if (event.button != .left and event.button != .none) return;
                    const url = try self.a.dupe(u8, target.id);
                    self.url_launches.concurrent(self.io, openToolUrl, .{ self.a, self.io, url }) catch self.a.free(url);
                    self.selection.clear();
                    return;
                }
                if (event.button != .left) return;
                self.selection.clear();
                if (target.kind == .tool) {
                    try self.toggleToolExpansion(target.id);
                } else if (target.thinking_run) |thought_run| {
                    const slots = &self.thinking_overrides;
                    const at = std.sort.lowerBound(ThinkingRun, slots.items, thought_run, ThinkingRun.order);
                    if (at < slots.items.len and std.meta.eql(slots.items[at], thought_run)) {
                        _ = slots.orderedRemove(at);
                    } else try slots.insert(self.a, at, thought_run);
                    if (self.search) |*search| search.index.invalidate();
                } else {
                    for (self.arguments.items) |*stream| {
                        if (std.mem.eql(u8, stream.call_id, target.id)) {
                            stream.expansion_override = !stream.expansion_override;
                            break;
                        }
                    }
                }
            },
            .motion => {
                if (self.pointer_press) |press| {
                    if (event.button == .left or press.column != event.column or press.row != event.row) self.clearPointer();
                }
            },
            .scroll => self.clearPointer(),
        }
    }

    fn selectionPoint(self: *const App, column: u32, row: u32, width: u16) ?tui.Selection.Point {
        if (self.scroll.viewport_rows == 0 or self.scroll.content_rows == 0 or width == 0) return null;
        return .{
            .row = @intCast(@min(self.scroll.content_rows - 1, self.scroll.top + @min(row, self.scroll.viewport_rows - 1))),
            .column = @min(column, width - 1),
        };
    }

    fn updateSelectionScroll(self: *App, width: u16, now: Io.Timestamp) void {
        const due = self.selection.scroll_at orelse return;
        if (!self.selection.active or now.compare(.lt, due)) return;
        const bottom = self.scroll.content_rows -| self.scroll.viewport_rows;
        const next = if (self.selection.scroll_direction < 0) self.scroll.top -| 1 else @min(self.scroll.top + 1, bottom);
        if (next == self.scroll.top) {
            self.selection.scroll_at = null;
            return;
        }
        const row = if (self.selection.scroll_direction < 0) next else @min(self.scroll.content_rows - 1, next + self.scroll.viewport_rows - 1);
        self.selection.move(.{ .row = @intCast(row), .column = self.selection.column }, null, width);
        self.selection_scroll_word = self.selection.granularity == .word;
        self.scrollBy(if (next < self.scroll.top) -1 else 1, now);
        self.selection.scroll_at = now.addDuration(.fromMilliseconds(50));
    }

    fn resolveScrolledWord(self: *App, screen: *const tui.Tui) void {
        if (!self.selection_scroll_word) return;
        self.selection_scroll_word = false;
        const row = if (self.selection.scroll_direction < 0) 0 else self.scroll.viewport_rows -| 1;
        const point = self.selectionPoint(self.selection.column, row, screen.size.col) orelse return;
        const word = screen.selectionWord(point.column, row) orelse return;
        self.selection.move(point, word, screen.size.col);
        self.mailbox.wake.notify();
    }

    fn setClipboardText(self: *App, owned: []u8, flash: bool) void {
        if (self.clipboard_text) |previous| self.a.free(previous.text);
        self.clipboard_text = .{ .text = owned, .flash = flash };
    }

    fn copyLastAssistant(self: *App, flash: bool) !void {
        if (try self.controller.lastAssistantText(self.a)) |text|
            self.setClipboardText(text, flash)
        else
            self.notice = "No agent messages to copy yet.";
    }

    fn startClipboardRead(self: *App, focus: ?ClipboardFocus) !void {
        try self.clipboard_reads.ensureUnusedCapacity(self.a, 1);
        const job = try Clipboard.ReadJob.start(self.a, self.mailbox.wake, self.environ, if (focus == null) .composer else .text);
        self.clipboard_reads.appendAssumeCapacity(.{ .job = job, .focus = focus });
    }

    fn clipboardFocus(self: *const App) ?ClipboardFocus {
        const lifetime = self.clipboard_modal_lifetime;
        if (self.theme_picker != null) return null;
        if (self.settings_list != null) return .{ .component = .settings, .lifetime = lifetime };
        if (self.session_selector) |*selector| return .{ .component = .session, .lifetime = lifetime, .page = @backingInt(std.meta.activeTag(selector.mode)) };
        if (self.fork_selector != null or self.missing_workspace != null) return null;
        if (self.tree) |tree| return .{ .component = .tree, .lifetime = lifetime, .page = @backingInt(tree.stage) };
        if (self.search != null) return .{ .component = .search, .lifetime = lifetime };
        if (self.dialog) |dialog| return .{ .component = .dialog, .lifetime = lifetime, .page = @backingInt(dialog.step) };
        if (self.thinking_picker != null) return null;
        return .{ .component = .composer };
    }

    fn clipboardReadError(self: *App, err: anyerror) !void {
        if (err == error.Canceled) return;
        const reason = switch (err) {
            error.ClipboardPathContainsControls => "Clipboard file path contains control characters",
            error.X11ClipboardReadFailed => "Could not read X11 clipboard",
            else => @errorName(err),
        };
        const message = try std.fmt.allocPrint(self.a, "Error: Failed to paste from clipboard: {s}", .{reason});
        defer self.a.free(message);
        try self.appendEvent(.{ .kind = .notice, .name = error_notice, .text = message });
    }

    fn settleClipboardReads(self: *App, mode: tui.Tui.Mode) !void {
        var index: usize = 0;
        while (index < self.clipboard_reads.items.len) {
            if (!self.clipboard_reads.items[index].job.done.isSet()) {
                index += 1;
                continue;
            }
            const read = self.clipboard_reads.orderedRemove(index);
            defer read.job.destroy();
            if (read.focus) |focus| {
                if (mode != .fullscreen or !std.meta.eql(self.clipboardFocus(), @as(?ClipboardFocus, focus))) continue;
                const result = read.job.result catch continue;
                if (result == .text) self.paste(result.text) catch {};
            } else {
                self.finishComposerPaste(read.job.result) catch |err| try self.clipboardReadError(err);
            }
        }
    }

    fn finishComposerPaste(self: *App, result: anyerror!Clipboard.ReadJob.Result) !void {
        switch (try result) {
            .empty => {},
            .text => |bytes| try self.insertClipboardText(bytes),
            .files => |paths| {
                const draft = self.editor.text();
                const text = try Clipboard.filePathsText(self.a, paths, draft, self.editor.cursor, ShellInput.Prefix.parse(draft) != null);
                defer self.a.free(text);
                try self.insertClipboardText(text);
            },
            .image => |image| {
                const path = try Clipboard.saveImage(self.a, self.io, self.environ, image);
                defer self.a.free(path);
                errdefer Io.Dir.cwd().deleteFile(self.io, path) catch {};
                try self.insertClipboardText(path);
            },
        }
    }

    fn insertClipboardText(self: *App, text: []const u8) !void {
        self.clearCompletion();
        try self.editor.insert(text);
    }

    fn settleClipboard(self: *App, screen: *tui.Tui, env: *const std.process.Environ.Map) !void {
        try self.settleClipboardReads(screen.mode);
        const now = Io.Timestamp.now(self.io, .awake);
        if (self.clipboard_flash) |flash| {
            if (!now.compare(.lt, flash.until)) self.clipboard_flash = null;
        }
        if (self.clipboard_job) |active| {
            if (!active.job.done.isSet()) return;
            self.clipboard_job = null;
            defer active.job.destroy();
            try self.finishClipboard(screen, env, active.job.text, active.job.copied, active.flash);
        }
        if (self.clipboard_text) |next| {
            if (Clipboard.hasNative(env)) {
                const job = Clipboard.Job.start(self.a, self.io, self.mailbox.wake, env, next.text) catch {
                    self.clipboard_text = null;
                    defer self.a.free(next.text);
                    return self.finishClipboard(screen, env, next.text, false, next.flash);
                };
                self.clipboard_text = null;
                self.clipboard_job = .{ .job = job, .flash = next.flash };
            } else {
                self.clipboard_text = null;
                defer self.a.free(next.text);
                try self.finishClipboard(screen, env, next.text, false, next.flash);
            }
        }
    }

    fn finishClipboard(self: *App, screen: *tui.Tui, env: *const std.process.Environ.Map, text: []const u8, native_success: bool, flash: bool) !void {
        const osc52 = Clipboard.useOsc52(env, native_success);
        const terminal_success = osc52 and try Clipboard.writeOsc52(self.a, screen.writer(), text);
        const success = native_success or terminal_success;
        const message = if (success) "Copied!" else if (osc52)
            "Clipboard unavailable: text exceeds the OSC 52 size limit"
        else
            Clipboard.unavailable(env);
        if (flash) {
            self.clipboard_flash = .{
                .message = message,
                .until = Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(if (success) 1000 else 5000)),
            };
        } else self.notice = if (success) "Copied last agent message to clipboard" else message;
    }

    fn viewportMouse(self: *App, width: u16, event: kit.terminal.keys.Mouse) bool {
        const now = Io.Timestamp.now(self.io, .awake);
        const geometry = tui.ScrollBar.Geometry.init(
            self.scroll.viewport_rows,
            @intCast(self.scroll.content_rows),
            @intCast(self.scroll.top),
        );
        const over_track = self.preferences.fullscreen_scrollbar != .hidden and geometry != null and width != 0 and event.column == width - 1 and event.row < self.scroll.viewport_rows;
        if (event.kind == .scroll) {
            const direction: tui.WheelScroll.Direction = switch (event.button) {
                .wheel_up => .up,
                .wheel_down => .down,
                else => return false,
            };
            self.clearPointer();
            const amount = (self.preferences.wheelLines() orelse self.wheel.next(direction, now)) * (if (event.mods.alt) @as(i64, 5) else 1);
            self.scrollBy(if (direction == .up) -amount else amount, now);
            self.scrollbar.hover(over_track, now);
            return true;
        }
        if (self.scrollbar.grab) |grab| {
            if (event.kind == .release or geometry == null) {
                self.scrollbar.grab = null;
                self.scrollbar.hover(over_track, now);
                self.scrollbar.reveal(now);
            } else if (event.kind == .motion) {
                self.scrollTo(geometry.?.scrollTop(event.row, grab), now);
            }
            return true;
        }
        if (event.kind == .press and event.button == .left) {
            if (self.follow_button) |hit| {
                if (hit.contains(event.column, event.row)) {
                    self.clearPointer();
                    self.followEnd(now);
                    return true;
                }
            }
            if (over_track and (self.preferences.fullscreen_scrollbar == .always or self.scrollbar.visible(now))) {
                const track = geometry.?;
                self.clearPointer();
                self.selection = .{};
                self.scrollbar.hover(true, now);
                const on_thumb = track.containsThumb(event.row);
                const grab = if (on_thumb) event.row - track.thumb_top else track.thumb_height / 2;
                self.scrollbar.grab = grab;
                if (!on_thumb) self.scrollTo(track.scrollTop(event.row, grab), now);
                return true;
            }
        }
        self.scrollbar.hover(over_track, now);
        return false;
    }

    fn composerMouse(self: *App, screen: *const tui.Tui, event: kit.terminal.keys.Mouse) !bool {
        if (event.kind == .scroll) return false;
        const point: tui.Selection.Point = .{
            .row = @min(event.row, screen.size.row -| 1),
            .column = @min(event.column, screen.size.col -| 1),
        };
        const word = screen.selectionWord(point.column, point.row);
        const hit = screen.mouseHit(event.column, event.row);
        if (event.kind == .press) {
            if (event.button != .left) return false;
            if (self.dialog != null or self.thinking_picker != null or self.search != null or
                hit == null or hit.?.key != composer_mouse_key)
            {
                self.screen_selection = .{};
                return false;
            }
            self.clearPointer();
            self.selection = .{};
            self.screen_selection.press(point, word, screen.size.col, Io.Timestamp.now(self.io, .awake));
            if (self.screen_selection.initial == null) self.composer_press = point;
            return true;
        }
        if (!self.screen_selection.active) return false;
        if (event.kind == .motion and event.button == .left) {
            self.composer_press = null;
            self.screen_selection.drag(point, word, screen.size.col, 0, Io.Timestamp.now(self.io, .awake));
        } else if (event.kind == .release and (event.button == .left or event.button == .none)) {
            const press = self.composer_press;
            self.composer_press = null;
            self.screen_selection.finish(point, word, screen.size.col);
            if (self.preferences.fullscreen_copy_on_select == false) self.screen_selection.copy_pending = false;
            if (press != null and press.?.column == event.column and press.?.row == event.row and
                hit != null and hit.?.key == composer_mouse_key)
            {
                self.screen_selection.clear();
                if (hit.?.row != 0 and try self.editor.clickVisual(self.a, hit.?.row - 1, hit.?.column -| self.composer_padding, self.composer_rows)) {
                    if (self.completionMatch()) |active| try self.refreshCompletion(active.kind == .path, false);
                }
            }
        }
        return true;
    }

    fn mouse(self: *App, screen: *const tui.Tui, event: kit.terminal.keys.Mouse) !void {
        if (builtin.os.tag == .windows and event.kind == .press and event.button == .right and @as(u8, @bitCast(event.mods)) == 0) {
            const terminal = self.environ.get("TERM_PROGRAM") orelse "";
            if (!std.ascii.eqlIgnoreCase(terminal, "vscode") and !std.ascii.eqlIgnoreCase(terminal, "tabby")) {
                if (self.clipboardFocus()) |focus| self.startClipboardRead(focus) catch {};
                return;
            }
        }
        if (self.theme_picker != null) return;
        if (self.settings_list) |*list| {
            const hit = screen.mouseHit(event.column, event.row);
            if (hit == null or hit.?.key != settings_mouse_key) {
                list.pressed = null;
                return;
            }
            const entries = self.settingsItems();
            return self.settingsAction(&entries, try list.mouse(self.a, entries.rows[0..entries.count], event, hit.?.row, hit.?.column, screen.size.col));
        }
        if (self.session_selector != null or self.missing_workspace != null) return;
        if (self.screen_selection.active and event.kind != .press and event.kind != .scroll) {
            _ = try self.composerMouse(screen, event);
            return;
        }
        if (self.search) |*search| {
            if (search.mouse(event)) {
                if (event.kind == .press) self.clearPointer();
                return;
            }
        }
        if (self.completion) |*menu| {
            const hit = screen.mouseHit(event.column, event.row);
            if (hit != null and hit.?.key == completion_mouse_key) {
                self.clearPointer();
                self.selection.clear();
                const offset = hit.?.row;
                if (event.kind == .scroll) {
                    self.completion_press = null;
                    switch (event.button) {
                        .wheel_up => menu.list.selected -|= 1,
                        .wheel_down => menu.list.selected = @min(menu.list.selected + 1, menu.list.items.len - 1),
                        else => {},
                    }
                } else switch (event.kind) {
                    .press => if (event.button == .left and offset < menu.list.visible()) {
                        const item = menu.list.first() + offset;
                        self.completion_press = .{ .item = item, .row = event.row, .column = event.column };
                        menu.list.selected = item;
                    },
                    .release => if (self.completion_press) |press| {
                        self.completion_press = null;
                        if (press.row == event.row and press.column == event.column and
                            (event.button == .left or event.button == .none))
                        {
                            menu.list.selected = press.item;
                            try self.acceptCompletion(false);
                        }
                    },
                    .motion => if (self.completion_press) |press| {
                        if (press.row != event.row or press.column != event.column) self.completion_press = null;
                    },
                    else => {},
                }
                return;
            }
            if (event.kind != .scroll) self.completion_press = null;
        }
        const width = screen.size.col;
        if (self.viewportMouse(width, event)) return;
        if (try self.composerMouse(screen, event)) return;
        const word = if (self.scroll.viewport_rows != 0) screen.selectionWord(@min(event.column, width -| 1), @min(event.row, self.scroll.viewport_rows - 1)) else null;
        if (event.kind == .press and event.button == .left) {
            if (self.dialog == null and self.thinking_picker == null and event.row < self.scroll.viewport_rows) {
                if (self.selectionPoint(event.column, event.row, width)) |point| {
                    self.selection.press(point, word, width, Io.Timestamp.now(self.io, .awake));
                    if (self.selection.initial != null) {
                        self.clearPointer();
                        return;
                    }
                }
            } else self.selection.clear();
        }
        try self.transcriptMouse(screen, event);
        if (self.selection.active) {
            if (self.selectionPoint(event.column, event.row, width)) |point| {
                if (event.kind == .motion and event.button == .left) {
                    const direction: i8 = if (event.row == 0) -1 else if (event.row >= self.scroll.viewport_rows - 1) 1 else 0;
                    self.selection.drag(point, word, width, direction, Io.Timestamp.now(self.io, .awake));
                } else if (event.kind == .release and (event.button == .left or event.button == .none)) {
                    self.selection.finish(point, word, width);
                    if (self.preferences.fullscreen_copy_on_select == false) self.selection.copy_pending = false;
                }
            }
        }
    }

    fn appendFooter(self: *App, a: std.mem.Allocator, nodes: *std.ArrayList(tui.Node), columns: u16) !void {
        if (self.presentation.footer.len == 0) return;
        const usage = self.controller.footerUsage();
        const provider = self.controller.footerProvider();
        return FooterView.append(a, nodes, self.presentation.footer, columns, &self.theme.palette, .{
            .workspace = self.controller.settings.workspace,
            .home = self.home,
            .branch = self.workspace_branch.name,
            .title = self.session_name,
            .stats = usage.stats,
            .context_tokens = if (!self.context_usage_known) null else if (usage.stats.total_tokens == 0) 0 else usage.context_tokens,
            .context_window = if (self.auth.configured) self.controller.settings.context_window else 0,
            .auto_compact = self.controller.runPolicy().auto_compact,
            .model = if (self.auth.configured) self.model else "no-model",
            .provider = if (self.auth.configured and ModelChoices.hasMultipleProviders(self.model_routes, &self.discovery)) provider.id else null,
            .thinking = self.controller.selected_effort,
            .subscription = self.auth.configured and provider.subscription,
        });
    }
};

fn sessionTokenCount(a: std.mem.Allocator, count: u64) ![]const u8 {
    var buffer: [20]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buffer, "{d}", .{count});
    const text = try a.alloc(u8, digits.len + (digits.len - 1) / 3);
    var at: usize = 0;
    for (digits, 0..) |digit, index| {
        if (index != 0 and (digits.len - index) % 3 == 0) {
            text[at] = ',';
            at += 1;
        }
        text[at] = digit;
        at += 1;
    }
    return text;
}

fn openToolUrl(a: std.mem.Allocator, io: Io, url: []const u8) void {
    defer a.free(url);
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (builtin.os.tag == .windows) .inherit else .{ .path = "/" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    defer child.kill(io);
    _ = child.wait(io) catch return;
}

const working_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn pendingMessageLine(a: std.mem.Allocator, children: *std.ArrayList(tui.Node), has_pending: *bool, label: []const u8, text: []const u8, columns: u16, padding: u16, palette: *const Theme.Palette) !void {
    if (!has_pending.*) try children.append(a, .{ .spacer = 1 });
    has_pending.* = true;
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const message = try std.fmt.allocPrint(a, "{s}: {s}", .{ label, first });
    try children.append(a, try pendingLine(a, message, columns, padding, palette));
}

fn pendingLine(a: std.mem.Allocator, text: []const u8, columns: u16, padding: u16, palette: *const Theme.Palette) !tui.Node {
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const clean = try md.clean(a, first);
    const value = try FooterView.ellipsize(a, clean, @max(1, columns -| (2 * padding)));
    return .{ .text = .{
        .bytes = if (padding == 0) value else try std.fmt.allocPrint(a, " {s}", .{value}),
        .style = palette.style(.dim),
        .overflow = .clip,
    } };
}

fn waitForUi(wake: *UiWake, mode: tui.Tui.Mode, frame_size: std.c.winsize, deadline: ?Io.Timestamp) !UiWake.Signal {
    if (mode == .append) return wake.wait(deadline);
    while (true) {
        if (job_control.suspendRequested()) return .suspension;
        const poll_at = Io.Timestamp.now(wake.io, .awake).addDuration(.fromMilliseconds(100));
        const due = deadline orelse poll_at;
        const final_wait = deadline != null and due.compare(.lte, poll_at);
        const signal = try wake.wait(if (final_wait) due else poll_at);
        if (signal != .timeout) return signal;
        if (try kit.terminal.size.get(wake.io, .stdout())) |size| {
            if (size.row != frame_size.row or size.col != frame_size.col) return .changed;
        }
        if (final_wait) return .timeout;
    }
}

const TerminalScreen = struct {
    view: tui.Tui,
    suspend_listener: job_control.Listener,
    open: bool = true,

    fn start(a: std.mem.Allocator, io: Io, options: tui.Tui.Options) !TerminalScreen {
        const listener = job_control.Listener.init();
        errdefer listener.deinit();
        return .{ .view = try startScreen(a, io, options), .suspend_listener = listener };
    }

    fn stop(self: *TerminalScreen) void {
        if (!self.open) return;
        stopScreen(&self.view);
        self.suspend_listener.deinit();
        self.open = false;
    }
};

const StartupScreen = struct {
    a: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    terminal: TerminalScreen,
    input: Input,
    theme: Theme.Session,

    fn start(a: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, resources: Theme.Resources, selected_theme: ?[]const u8) !StartupScreen {
        if (!try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) return error.SessionPickerRequiresTerminal;
        var terminal = try openTerminal(a, io, environ);
        errdefer terminal.stop();
        var theme = Theme.Session.init(environ);
        errdefer theme.deinit(a);
        try theme.loadCatalog(a, io, resources, .replace);
        _ = theme.select(selected_theme orelse Theme.system_name);
        _ = try theme.apply(a, true);
        try theme.request(terminal.view.writer(), Io.Timestamp.now(io, .awake));
        return .{ .a = a, .io = io, .environ = environ, .terminal = terminal, .input = .init(a), .theme = theme };
    }

    fn openTerminal(a: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !TerminalScreen {
        return TerminalScreen.start(a, io, .{
            .pool = null,
            .mode = .main_screen_rerender,
            .environment = environ,
            .images = .none,
            .output = .stdout(),
            .input_file = .stdin(),
        });
    }

    fn stop(self: *StartupScreen) void {
        self.terminal.stop();
        self.theme.deinit(self.a);
        self.input.deinit();
    }

    fn width(self: *StartupScreen) !u16 {
        const size = (try kit.terminal.size.get(self.io, .stdout())) orelse self.terminal.view.size;
        return @max(1, size.col);
    }

    fn present(self: *StartupScreen, nodes: []const tui.Node) !void {
        self.terminal.view.options.light_background = self.theme.palette.appearance == .light;
        try self.terminal.view.present(.{ .stack = .{ .children = nodes } }, .{});
    }

    fn next(self: *StartupScreen) !?kit.terminal.keys.Event {
        if (job_control.suspendRequested()) {
            self.terminal.stop();
            try job_control.suspendForegroundGroup(self.io);
            self.terminal = try openTerminal(self.a, self.io, self.environ);
            try self.theme.request(self.terminal.view.writer(), Io.Timestamp.now(self.io, .awake));
        }
        if (self.theme.deadline) |due| if (Io.Timestamp.now(self.io, .awake).compare(.gte, due)) {
            _ = try self.theme.finish(self.a, false);
        };
        const now = Io.Timestamp.now(self.io, .awake);
        try self.theme.bindWatch(self.a, self.io, now);
        if (try self.theme.pollWatch(self.a, self.io, now)) return null;
        const event = self.input.next(self.io, .fromMilliseconds(100)) catch |err| switch (err) {
            error.EndOfStream => return .{ .key = .{ .code = .escape } },
            else => return err,
        };
        switch (event orelse return null) {
            .terminal_color => |report| if (self.theme.receiving) {
                self.theme.query.add(report);
                if (self.theme.query.complete()) _ = try self.theme.finish(self.a, true);
            },
            .device_attributes => _ = try self.theme.finish(self.a, true),
            .terminal_scheme => |scheme| if (self.theme.choice.followsTerminal()) {
                self.theme.reported = scheme;
                _ = try self.theme.apply(self.a, !self.theme.initialized);
                try self.theme.request(self.terminal.view.writer(), Io.Timestamp.now(self.io, .awake));
            },
            .key => |key| if (key.kind != .release) return event,
            .paste => return event,
            else => {},
        }
        return null;
    }
};

pub fn chooseStartupWorkspace(a: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, missing: []const u8, workspace: []const u8, resources: Theme.Resources, theme: ?[]const u8, labels: *const UiPresentation.WorkspacePrompt) !WorkspaceChoice {
    var startup = try StartupScreen.start(a, io, environ, resources, theme);
    defer startup.stop();
    defer startup.present(&.{}) catch {};
    var prompt: WorkspacePrompt = .{ .missing = missing, .current = workspace };
    var frame: std.heap.ArenaAllocator = .init(a);
    defer frame.deinit();
    while (true) {
        _ = frame.reset(.retain_capacity);
        var nodes: std.ArrayList(tui.Node) = .empty;
        try prompt.draw(frame.allocator(), &nodes, try startup.width(), &startup.theme.palette, labels);
        try startup.present(nodes.items);
        if (try startup.next()) |event| switch (event) {
            .key => |key| if (prompt.key(key)) |choice| return choice,
            else => {},
        };
    }
}

pub const StartupSelection = struct { session: Controller.SavedSession, workspace_known: bool };

pub fn selectStartupSession(a: std.mem.Allocator, gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, source: @import("../session.zig").SessionIndex.Source, hardware: bool, resources: Theme.Resources, theme: ?[]const u8, pickers: *const UiPresentation.Pickers) !?StartupSelection {
    var startup = try StartupScreen.start(gpa, io, environ, resources, theme);
    defer startup.stop();
    var selector = try SessionSelector.open(gpa, io, source, .{});
    defer selector.deinit();
    selector.allow_rename = false;
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();
    while (true) {
        try selector.advance();
        _ = frame.reset(.retain_capacity);
        const temp = frame.allocator();
        var nodes: std.ArrayList(tui.Node) = .empty;
        startup.terminal.view.show_hardware_cursor = hardware;
        try selector.draw(temp, &nodes, try startup.width(), &startup.theme.palette, environ.get("HOME") orelse "", Io.Clock.real.now(io).toMilliseconds(), hardware, pickers);
        try startup.present(nodes.items);
        if (try startup.next()) |event| switch (event) {
            .key => |key| switch (try selector.key(key)) {
                .cancel => return null,
                .select => |session| return .{
                    .session = .{ .path = try a.dupe(u8, session.path), .id = try a.dupe(u8, session.id), .inode = session.inode },
                    .workspace_known = session.workspace.len != 0,
                },
                .delete => |session| selector.mutate(session, null) catch |err| try selector.reportMutationError("delete", err),
                .rename => unreachable,
                .none => {},
            },
            .paste => |paste| try selector.paste(temp, paste),
            else => {},
        };
    }
}

fn startScreen(a: std.mem.Allocator, io: Io, options: tui.Tui.Options) !tui.Tui {
    var screen = try tui.Tui.init(a, io, options);
    errdefer stopScreen(&screen);
    if (builtin.os.tag != .windows) {
        var mode = try kit.terminal.mode.get(io, .stdin());
        mode.lflag.ISIG = false;
        try kit.terminal.mode.set(io, .stdin(), mode, .keep);
    }
    try screen.writer().writeAll("\x1b[?2004h\x1b[>7u\x1b[>4;2m\x1b[?2048h");
    try screen.writer().flush();
    return screen;
}

fn stopScreen(screen: *tui.Tui) void {
    if (screen.interactive and screen.input != null) screen.writer().writeAll(terminal_colors.notifications_off) catch {};
    screen.writer().writeAll("\x1b[>4;0m\x1b[<u\x1b[?2004l\x1b[?2048l") catch {};
    screen.writer().flush() catch {};
    screen.deinit();
}

fn requestTheme(app: *App, screen: *tui.Tui) !void {
    screen.options.truecolor = app.theme.truecolor;
    if (screen.interactive and screen.input != null) try app.theme.request(screen.writer(), Io.Timestamp.now(app.io, .awake));
}

fn roundTripDraft(app: *App, editor: *Editor, a: std.mem.Allocator, environ: *const std.process.Environ.Map, command: []const u8, draft: []const u8) !void {
    const result = ExternalEditor.edit(a, app.io, environ, command, draft) catch |err| {
        app.notice = try std.fmt.allocPrint(app.arena, "External editor failed: {s}; prompt unchanged", .{@errorName(err)});
        return;
    };
    switch (result) {
        .edited => |text| {
            try editor.replaceTextForEdit(text);
            app.clearCompletion();
        },
        .failed => |message| app.notice = try app.arena.dupe(u8, message),
    }
}

pub const Options = struct {
    presentation: *const UiPresentation,
    presentation_warning: ?anyerror = null,
    timings: ?*Timings = null,
    external_editor: ?[]const u8 = null,
    quiet_startup: QuietStartup = .full,
    settings_path: ?[]const u8 = null,
    theme_resources: Theme.Resources = .{},
    preferences: Settings = .{},
    settings_error: ?anyerror = null,
    run_defaults: Controller.RunPolicy = .{},
};

fn newDiscovery(a: std.mem.Allocator, io: Io, wake: *UiWake) registry.Refresh {
    return .{
        .a = a,
        .io = io,
        .wake = .{ .context = wake, .notify = UiWake.notifyContext },
        .policy = .{ .fresh_for = .fromSeconds(300), .retry_after = .fromSeconds(30), .parallelism = 4 },
    };
}

pub fn run(a: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, runtime: *WorkspaceSession, auth: *Auth.Store, initial: @import("../session.zig").StartupFiles.Inputs, options: Options) anyerror!void {
    const controller = runtime.current;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var wake: UiWake = .{ .io = io };
    const timings = options.timings;
    const editor_command = ExternalEditor.command(options.external_editor, environ);
    const hyperlink_override = environ.get("PI_HYPERLINKS") orelse "";
    const term = environ.get("TERM") orelse "";
    const multiplexer = environ.contains("TMUX") or environ.contains("ZELLIJ") or environ.contains("STY") or
        std.ascii.startsWithIgnoreCase(term, "tmux") or std.ascii.startsWithIgnoreCase(term, "screen");
    const native_wheel = builtin.os.tag == .macos and
        !environ.contains("SSH_CONNECTION") and !environ.contains("SSH_CLIENT") and !environ.contains("SSH_TTY");
    const hyperlinks = if (std.mem.eql(u8, hyperlink_override, "1"))
        true
    else if (std.mem.eql(u8, hyperlink_override, "0"))
        false
    else
        kit.terminal.hyperlink.supported(a, io, environ);
    const preferences = options.preferences;
    const presentation = options.presentation;
    var app: App = .{
        .a = a,
        .arena = arena.allocator(),
        .scratch = &arena,
        .view = .init(a),
        .queue_preview = .{ .arena = .init(a) },
        .io = io,
        .environ = environ,
        .home = environ.get("HOME") orelse "",
        .hyperlinks = hyperlinks,
        .controller = controller,
        .workspace_runtime = runtime,
        .auth = auth,
        .routes_arena = .init(a),
        .discovery = newDiscovery(a, io, &wake),
        .mailbox = .{ .a = a, .io = io, .wake = &wake, .timed = timings != null },
        .editor = .initWithEditingHistory(a),
        .syntax = .{ .allocator = a, .styles = presentation.syntax },
        .presentation = presentation.*,
        .theme = .init(environ),
        .theme_resources = options.theme_resources,
        .quiet_startup = preferences.startup(options.quiet_startup),
        .startup_default = options.quiet_startup,
        .settings_path = options.settings_path,
        .preferences = preferences,
        .run_defaults = options.run_defaults,
        .thinking = !(preferences.hide_thinking orelse false),
        .startup_logo = builtin.os.tag != .macos or !std.mem.eql(u8, environ.get("TERM_PROGRAM") orelse "", "Apple_Terminal"),
        .wheel = .{ .accelerate = !native_wheel },
    };
    app.syntax.palette = &app.theme.palette;
    app.editor.history_source = .{ .context = controller, .readOwned = promptHistory };
    defer {
        for (app.clipboard_reads.items) |read| read.job.destroy();
        app.clipboard_reads.deinit(a);
        app.closeDialog();
        app.closeTree();
        app.closeFork();
        app.closeSettings();
        app.closeSessionSelector();
        app.closeMissingWorkspace();
        app.clearCompletion();
        app.closeTranscriptSearch();
        app.discovery.deinit();
        app.routes_arena.deinit();
        app.editor.deinit();
        app.theme.deinit(a);
        if (app.saved_theme) |name| a.free(name);
        app.workspace_branch.deinit(a);
        if (app.session_name) |name| a.free(name);
        app.preview.deinit(a);
        app.thinking_overrides.deinit(a);
        app.transcript.deinit(a);
        app.tool_images.deinit(a, io);
        app.syntax.deinit();
        app.clearToolExpansions();
        app.tool_expansions.deinit(a);
        app.clearPointer();
        if (app.clipboard_text) |previous| a.free(previous.text);
        if (app.clipboard_job) |active| active.job.destroy();
        app.url_launches.cancel(io);
        app.clearArguments();
        app.arguments.deinit(a);
        app.queue.deinit(a);
        app.queue_preview.arena.deinit();
        app.compaction_inputs.deinit(a);
        for (app.completed_shells.items) |job| job.destroy(a);
        app.completed_shells.deinit(a);
        if (app.outcome) |outcome| a.free(outcome);
        app.view.deinit();
        var pending = app.mailbox.take();
        for (pending.items) |owned| owned.destroy(a);
        pending.deinit(a);
    }
    const protocol = environ.get("PI_IMAGE_PROTOCOL") orelse "";
    const image_policy: tui.Tui.ImagePolicy = if (std.ascii.eqlIgnoreCase(protocol, "kitty"))
        .pixels
    else if (std.ascii.eqlIgnoreCase(protocol, "iterm2"))
        .iterm2
    else if (std.ascii.eqlIgnoreCase(protocol, "none") or std.mem.eql(u8, protocol, "0"))
        .none
    else if (kit.terminal.kitty.advertised(environ))
        .pixels
    else if (kit.terminal.iterm2.advertised(environ))
        .iterm2
    else
        .none;
    var screen_options: tui.Tui.Options = .{
        .pool = null,
        .mode = Settings.TuiMode.screenMode(preferences.tui_mode orelse .fullscreen),
        .output = .stdout(),
        .input_file = .stdin(),
        .input = false,
        .mouse = true,
        .mouse_drag = true,
        .mouse_hover = !multiplexer,
        .images = image_policy,
        .hyperlinks = hyperlinks,
        .environment = environ,
    };
    var terminal_screen = try TerminalScreen.start(a, io, screen_options);
    defer terminal_screen.stop();
    const screen = &terminal_screen.view;
    try app.theme.loadCatalog(a, io, app.theme_resources, .replace);
    _ = app.theme.select(preferences.theme orelse Theme.system_name);
    _ = try app.theme.apply(a, screen.interactive and screen.input != null);
    try requestTheme(&app, screen);
    app.picker_rows = @max(1, screen.size.row);
    {
        const scope = kit.tracing.beginEvent("cpi.ui.history");
        defer kit.tracing.endEvent(scope);
        try app.history();
    }
    if (!auth.configured) app.notice = if (auth.document.profiles.len > 0) "Signed in. Use /model to select a provider and model." else "Not signed in. Use /login to configure a provider.";
    if (options.settings_error) |err| app.notice = try std.fmt.allocPrint(app.arena, "Failed to load settings: {s}", .{@errorName(err)});
    if (options.presentation_warning) |err| app.notice = try std.fmt.allocPrint(app.arena, "Failed to load ui.luau ({s}). Using the bundled UI.", .{@errorName(err)});
    var input: Input = .init(a);
    defer input.deinit();
    var reading: ?Io.Future(void) = null;
    defer if (reading) |*future| future.cancel(io);
    const waiting_for_paste = "Paste could not fit in memory. Waiting for the paste to finish.";
    controller.setSink(.{ .context = &app.mailbox, .emit = Mailbox.emit });
    defer {
        app.stop();
        app.collectUserShell(true);
        app.flushUserShells() catch |err| std.log.err("Couldn't save completed bash result ({s})", .{@errorName(err)});
        app.controller.setSink(null);
    }
    const submissions = try initial.prepare(app.arena, controller, null);
    if (submissions.len > 0 and (try controller.queueState()).waiting_after_compaction)
        submissions[0].compaction_seed = true;
    try controller.enqueueInputs(app.arena, submissions);
    try app.loadInbox();
    var first_draw = true;
    var pending_key: ?Stamp = null;
    while (!app.quit) {
        if (job_control.suspendRequested()) {
            if (reading) |*reader| {
                reader.cancel(io);
                reading = null;
                wake.discardCanceledRead();
            }
            app.blurTerminal();
            terminal_screen.stop();
            job_control.suspendForegroundGroup(io) catch |err| app.reportError(err);
            terminal_screen = try TerminalScreen.start(a, io, screen_options);
            app.terminal_title_dirty = true;
            try requestTheme(&app, screen);
            continue;
        }
        if (app.theme.deadline) |due| {
            if (Io.Timestamp.now(io, .awake).compare(.gte, due) and try app.theme.finish(a, false)) app.themeChanged();
        }
        if (app.theme_sync_dirty) {
            app.theme_sync_dirty = false;
            try requestTheme(&app, screen);
        }
        try app.theme.bindWatch(a, io, Io.Timestamp.now(io, .awake));
        screen.options.light_background = app.theme.palette.appearance == .light;
        try app.updateTerminalTitle(screen);
        try app.drain();
        if (app.session_selector) |*selector| try selector.advance();
        app.collectUserShell(false);
        // Replaying Enter can queue a prompt for settle to dispatch.
        app.settleFileCompletion(screen.mode) catch |err| app.reportError(err);
        try app.settle();
        app.settleAuth();
        const refresh_deadline = try app.updateDiscovery();
        var branch = try app.workspace_branch.sample(a, io, app.controller.settings.workspace);
        if (reading == null and !wake.hasTerminal()) reading = try io.concurrent(UiWake.read, .{ &wake, &input });
        const drawable = if (try kit.terminal.size.get(io, .stdout())) |size| drawable: {
            if (size.col == 0 or size.row == 0) break :drawable false;
            screen.size = size;
            break :drawable true;
        } else true;
        const frame_size = screen.size;
        try app.settleClipboard(screen, environ);
        const now = Io.Timestamp.now(io, .awake);
        const progress_deadline = try screen.activityProgress((app.preferences.terminal_progress orelse false) and app.job != null, now);
        if (app.scrollbar.hide_at) |due| if (!now.compare(.lt, due)) {
            app.scrollbar.hide_at = null;
        };
        if (drawable) {
            app.updateSelectionScroll(screen.size.col, now);
            app.picker_rows = @max(1, screen.size.row);
            const scope = if (first_draw) kit.tracing.beginEvent("cpi.ui.first_draw") else kit.tracing.Buffer.no_trace;
            defer kit.tracing.endEvent(scope);
            const before = if (timings != null) Stamp.now() else null;
            try app.draw(screen, false);
            app.resolveScrolledWord(screen);
            if (app.clipboard_text != null and app.clipboard_job == null) wake.notify();
            if (timings) |stats| {
                const end = Stamp.now().ticks;
                stats.draw.observeTicks(end -% before.?.ticks);
                if (first_draw) stats.main_to_first_present.observeTicks(end -% stats.started.ticks);
                if (pending_key) |key| stats.key_to_next_present.observeTicks(end -% key.ticks);
                if (app.pending_delta) |delta| stats.oldest_text_delta_to_next_present.observeTicks(end -% delta.ticks);
                pending_key = null;
                app.pending_delta = null;
            }
            first_draw = false;
        }
        // Sample live process and spinner output while a turn is active.
        var deadline = refresh_deadline;
        if (progress_deadline) |due| if (deadline == null or due.compare(.lt, deadline.?)) {
            deadline = due;
        };
        if (app.session_selector) |*selector| if (selector.deadline()) |due| {
            if (deadline == null or due.compare(.lt, deadline.?)) deadline = due;
        };
        if (app.theme.deadline) |due| {
            if (deadline == null or due.compare(.lt, deadline.?)) deadline = due;
        }
        if (app.scrollbar.hide_at) |due| {
            if (deadline == null or due.compare(.lt, deadline.?)) deadline = due;
        }
        if (app.selection.scroll_at) |due| {
            if (deadline == null or due.compare(.lt, deadline.?)) deadline = due;
        }
        if (app.clipboard_flash) |flash| {
            if (deadline == null or flash.until.compare(.lt, deadline.?)) deadline = flash.until;
        }
        if (app.job != null or app.user_shell != null) {
            const repaint = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(80));
            if (deadline == null or repaint.compare(.lt, deadline.?)) deadline = repaint;
        }
        if (app.shell_record_retry) |retry| {
            if (deadline == null or retry.compare(.lt, deadline.?)) deadline = retry;
        }
        const signal = while (true) {
            var due = if (deadline == null or branch.deadline.compare(.lt, deadline.?)) branch.deadline else deadline.?;
            if (app.theme.watchDeadline()) |watch_due| if (watch_due.compare(.lt, due)) {
                due = watch_due;
            };
            const event = try waitForUi(&wake, screen.mode, frame_size, due);
            if (try app.theme.pollWatch(a, io, Io.Timestamp.now(io, .awake))) {
                app.themeChanged();
                if (event == .timeout) break UiWake.Signal.changed;
            }
            if (event != .timeout or (deadline != null and !Io.Timestamp.now(io, .awake).compare(.lt, deadline.?))) break event;
            branch = try app.workspace_branch.sample(a, io, app.controller.settings.workspace);
            if (branch.changed) break UiWake.Signal.changed;
        };
        const terminal = switch (signal) {
            .terminal => |event| event,
            .changed, .timeout, .suspension => continue,
        };
        if (reading) |*reader| reader.await(io);
        reading = null;
        const event = (terminal catch |err| switch (err) {
            error.EndOfStream => break,
            error.OutOfMemory => {
                if (input.paste != .discarding) return err;
                app.notice = waiting_for_paste;
                continue;
            },
            else => return err,
        }) orelse {
            continue;
        };
        switch (event) {
            .key => |key| {
                if (timings != null and pending_key == null) pending_key = Stamp.now();
                app.key(key, screen.mode) catch |err| app.reportError(err);
                if (app.edit_external) {
                    app.edit_external = false;
                    var scratch = std.heap.ArenaAllocator.init(a);
                    defer scratch.deinit();
                    const temporary = scratch.allocator();
                    const editor = if (app.tree) |tree| &tree.input else &app.editor;
                    const draft = editor.expanded(temporary) catch |err| {
                        app.reportError(err);
                        continue;
                    };
                    app.blurTerminal();
                    // The reader was joined above. Model and service events stay in the mailbox.
                    terminal_screen.stop();
                    const input_mode = try kit.terminal.mode.get(io, .stdin());
                    const output_mode = try kit.terminal.mode.getOutput(io, .stdout());
                    roundTripDraft(&app, editor, temporary, environ, editor_command, draft) catch |err| app.reportError(err);
                    // An editor terminated in raw mode may have left the terminal in that mode.
                    try kit.terminal.mode.set(io, .stdin(), input_mode, .keep);
                    if (output_mode) |mode| try kit.terminal.mode.setOutput(io, .stdout(), mode);
                    terminal_screen = try TerminalScreen.start(a, io, screen_options);
                    app.terminal_title_dirty = true;
                    try requestTheme(&app, screen);
                }
            },
            .paste => |bytes| {
                app.controller.warnSize("terminal paste", "bytes", bytes.len, Input.paste_warning_bytes);
                app.paste(bytes) catch |err| {
                    app.notice = if (err == error.OutOfMemory) "Paste could not fit in memory. Your draft is unchanged." else @errorName(err);
                };
            },
            .mouse => |event_mouse| if (screen.mode == .fullscreen) app.mouse(screen, event_mouse) catch |err| app.reportError(err),
            .focus_out => app.blurTerminal(),
            .terminal_cell_size => |size| _ = screen.setImageCellSize(size),
            .terminal_color => |report| if (app.theme.receiving) {
                app.theme.query.add(report);
                if (app.theme.query.complete() and try app.theme.finish(a, true)) app.themeChanged();
            },
            .device_attributes => if (try app.theme.finish(a, true)) app.themeChanged(),
            .terminal_scheme => |scheme| if (app.theme.choice.followsTerminal()) {
                app.theme.reported = scheme;
                if (try app.theme.apply(a, !app.theme.initialized)) app.themeChanged();
                try requestTheme(&app, screen);
            },
            .ignore => if (input.paste == .none and std.mem.eql(u8, app.notice, waiting_for_paste)) {
                app.notice = "Paste discarded. You can continue.";
            },
            else => {},
        }
        if (app.pending_mode) |updated| {
            app.pending_mode = null;
            if (screen.mode == .append) {
                app.notice = "TUI mode requires a terminal.";
                continue;
            }
            const previous = screen.mode;
            const mode = updated.tui_mode.?;
            try screen.switchMode(mode.screenMode());
            if (try app.applyPreference(updated, .tui_mode)) {
                screen_options.mode = screen.mode;
                try screen.requestImageCellSize();
                app.resetViewport();
                try app.showStatus(try std.fmt.allocPrint(app.arena, "TUI mode: {s}", .{@tagName(mode)}));
            } else try screen.switchMode(previous);
        }
    }
    app.stop();
    app.collectUserShell(true);
    app.flushUserShells() catch |err| app.reportError(err);
    try app.drain();
    if (screen.mode == .fullscreen and app.preferences.fullscreen_exit_output != .@"resume-hint") {
        try screen.switchMode(.main_screen_rerender);
        app.resetViewport();
    }
    if (screen.mode == .main_screen_rerender) try app.draw(screen, true);
    try screen.finish();
}
