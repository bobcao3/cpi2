const std = @import("std");
const protocol = @import("session_protocol");
const j = @import("../json.zig");
const SessionName = @import("SessionName.zig");
const Action = protocol.frames.Action;
const Value = j.Value;
const Allocator = std.mem.Allocator;

pub const namespace = "cpi-minimal.inbox";
pub const contract: protocol.Extensions.Contract = .{
    .version = .{ .id = namespace, .version = "1" },
    .initial_state = initial,
    .validate = validate,
    .reduce = reduce,
    .validate_transaction = validateTransaction,
    .validate_state = validateState,
    .reduce_transaction = reduceTransaction,
};
pub const Kind = enum { prompt, steer, compact, register_tools, continue_turn, reset, write };
const paused_key = "@paused";
const compaction_wait_key = "@compaction_wait";
const holds_restored_key = "@input-holds-restored";
const restore_holds = "restore_holds";
const request_prefix = "request/";
const final_batch = "@final";
const post_tools_batch = "@post-tools";

pub const Disposition = enum { pending, claimed, consumed, discarded, rejected };
pub const RunStatus = enum { running, answered, unanswered };
pub const Withdrawal = enum { withdrawn, already_placed, settled, unknown };
pub const Receipt = struct {
    disposition: ?Disposition = null,
    run: ?Run = null,
    entry: ?[]const u8 = null,
    reason: ?[]const u8 = null,

    pub const Run = struct {
        status: RunStatus,
        input_entry: []const u8,
        answer_entry: ?[]const u8 = null,
        reason: ?[]const u8 = null,
    };
};

pub const InputEntry = struct { kind: []const u8, data: Value = .null };
pub const InputPolicy = struct {
    when_busy: enum { follow_up, steer, reject } = .follow_up,
    when_idle: enum { start, reject } = .start,
};
const ScopedPolicy = struct { conversation: []const u8, policy: InputPolicy };

fn validateInputEntry(entry: Value) !void {
    const kind = j.text(j.get(entry, "kind"));
    if (entry != .object or kind.len == 0 or std.mem.startsWith(u8, kind, "pi.")) return error.InvalidEntryKind;
    for (entry.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "kind") and !std.mem.eql(u8, key, "data")) return error.InvalidDatagram;
    }
}

pub fn promptBody(a: Allocator, text: []const u8, original: []const u8, entry: ?InputEntry, user_content: Value) !Value {
    var body = try j.value(a, .{ .text = text, .original = original });
    if (entry) |draft| {
        const value = try j.value(a, draft);
        try validateInputEntry(value);
        try j.put(a, &body, "entry", value);
    }
    if (user_content != .null) {
        try validateUserContent(user_content);
        try j.put(a, &body, "user_content", try j.copy(a, user_content));
    }
    return body;
}

fn promptHash(a: Allocator, body: Value) ![64]u8 {
    const original = j.text(j.get(body, "original"));
    const entry = j.get(body, "entry");
    const user_content = j.get(body, "user_content");
    if (entry == .null and user_content == .null) return inputHash(original);
    var identity = j.object();
    defer identity.object.deinit(a);
    try identity.object.put(a, "original", j.string(original));
    if (entry != .null) try identity.object.put(a, "entry", entry);
    if (user_content != .null) try identity.object.put(a, "user_content", user_content);
    return protocol.Canonical.hash(a, identity);
}

pub fn promptRecord(a: Allocator, body: Value, has_request_id: bool) !Value {
    var record = j.object();
    try record.object.put(a, "kind", j.string(@tagName(Kind.prompt)));
    try record.object.put(a, "input", body);
    if (has_request_id) {
        const digest = try promptHash(a, body);
        try j.put(a, &record, "sha256", j.string(try a.dupe(u8, &digest)));
    }
    return record;
}

pub const prompt_task_kind = "cpi-minimal.foreground";

pub fn promptTaskHash(a: Allocator, conversation: []const u8, submission: []const u8) ![64]u8 {
    return protocol.Canonical.hash(a, try j.value(a, .{ .kind = prompt_task_kind, .conversation = conversation, .id = submission }));
}

pub fn promptAdmission(a: Allocator, conversation: []const u8, submission: []const u8, body: Value, model_selection: Value) !agent.ExtensionWrite {
    return promptAdmissionWithPolicy(a, conversation, submission, body, model_selection, .{});
}

pub fn promptAdmissionWithPolicy(a: Allocator, conversation: []const u8, submission: []const u8, body: Value, model_selection: Value, policy: InputPolicy) !agent.ExtensionWrite {
    var records = j.object();
    var record = try promptRecord(a, body, true);
    if (model_selection != .null) {
        try record.object.put(a, "own_model", .{ .bool = true });
        try record.object.put(a, "model_selection", model_selection);
    }
    if (policy.when_busy != .follow_up or policy.when_idle != .start) {
        const scoped: ScopedPolicy = .{ .conversation = conversation, .policy = policy };
        try record.object.put(a, "admission_policy", try j.value(a, scoped));
    }
    try records.object.put(a, submission, record);
    return .{ .namespace = try scopeNamespace(a, conversation), .action = "enqueue", .input = .{ .contract = contract.version, .value = records } };
}

pub const EntryDraft = struct {
    kind: []const u8,
    data: Value = .null,
    model: ?[]const Message = null,
    head: ?[]const u8 = null,
    edits: ?[]const Edit = null,

    pub const Message = struct {
        role: enum { user, assistant, system, developer },
        content: Value,
    };
    pub const Edit = struct {
        target: []const u8,
        action: enum { omit, replace },
        messages: ?[]const Message = null,
    };
};

fn validateWrite(draft: EntryDraft) !void {
    if (draft.kind.len == 0) return error.InvalidEntryKind;
    if (draft.head) |head| if (head.len == 0) return error.InvalidEntryHead;
    if (std.mem.eql(u8, draft.kind, "pi.compaction")) {
        const head = draft.head orelse return error.InvalidEntryHead;
        if (std.mem.eql(u8, head, "self") or draft.model != null or draft.edits != null or
            j.text(j.get(draft.data, "summary")).len == 0 or j.get(draft.data, "metadata") != .object)
            return error.InvalidEntryContent;
    }
    if (draft.model) |messages| try validateMessages(messages);
    if (draft.edits) |edits| for (edits) |edit| {
        if (edit.target.len == 0 or (edit.action == .replace) != (edit.messages != null)) return error.InvalidContextEdit;
        if (edit.messages) |messages| try validateMessages(messages);
    };
}

fn validateMessages(messages: []const EntryDraft.Message) !void {
    for (messages) |message| switch (message.content) {
        .string => {},
        .array => |content| {
            for (content.items) |part| {
                const input_text = message.role != .assistant and j.equal(j.get(part, "type"), "input_text") and j.get(part, "text") == .string;
                const output_text = message.role == .assistant and j.equal(j.get(part, "type"), "output_text") and j.get(part, "text") == .string;
                const image = message.role == .user and j.equal(j.get(part, "type"), "input_image") and j.get(part, "image_url") == .string;
                if (!input_text and !output_text and !image) return error.InvalidEntryContent;
            }
        },
        else => return error.InvalidEntryContent,
    };
}

pub fn validateUserContent(content: Value) !void {
    try validateMessages(&.{.{ .role = .user, .content = content }});
}

pub const WriteActivation = enum { normal, passive };

fn validateWriteActivation(a: Allocator, draft: EntryDraft, activation: WriteActivation) !void {
    const ShellRecord = @import("ShellRecord.zig");
    const shell = std.mem.eql(u8, draft.kind, ShellRecord.kind);
    if (std.mem.eql(u8, draft.kind, SessionName.entry_kind)) {
        if (activation != .passive or draft.model != null or draft.head != null or draft.edits != null) return error.InvalidDatagram;
        return SessionName.validateName(draft.data);
    }
    if (activation == .normal) {
        if (shell) return error.InvalidDatagram;
        return;
    }
    if (std.mem.eql(u8, draft.kind, "pi.compaction")) return;
    if (!shell or draft.head != null or draft.edits != null) return error.InvalidDatagram;
    const record = try std.json.parseFromValueLeaky(ShellRecord, a, draft.data, .{});
    if (record.command.len == 0) return error.InvalidEntryContent;
    if (record.excluded) {
        if (draft.model != null) return error.InvalidEntryContent;
    } else {
        const messages = draft.model orelse return error.InvalidEntryContent;
        if (messages.len != 1 or messages[0].role != .user or messages[0].content != .string or
            !std.mem.eql(u8, messages[0].content.string, try record.modelText(a))) return error.InvalidEntryContent;
    }
}

pub fn writeDraft(a: Allocator, conversation: []const u8, submission: []const u8, draft: EntryDraft, activation: WriteActivation) !agent.ExtensionWrite {
    try validateWrite(draft);
    try validateWriteActivation(a, draft, activation);
    const serialized = try protocol.Canonical.encode(a, try j.value(a, draft));
    var records = j.object();
    var record = try j.value(a, .{ .kind = Kind.write, .input = .{ .json = serialized }, .sha256 = &inputHash(serialized), .conversation = conversation });
    if (activation == .passive) try record.object.put(a, "passive_write", .{ .bool = true });
    try records.object.put(a, submission, record);
    return .{ .namespace = try scopeNamespace(a, conversation), .action = "enqueue", .input = .{ .contract = contract.version, .value = records } };
}

const agent = @import("agent");
const ContextJournal = @import("ContextJournal.zig");
const Frame = protocol.frames;

pub fn restoreLegacyHolds(a: Allocator, journal: *const agent.SessionJournal) ![]const Action {
    const extensions = &journal.state.extensions;
    const source = journal.source();
    var actions: std.ArrayList(Action) = .empty;
    for (journal.state.contexts.keys()) |conversation| {
        const scoped = try scopeNamespace(a, conversation);
        const inbox = extensions.get(scoped) orelse continue;
        if (j.flag(j.get(inbox.value, holds_restored_key))) continue;
        const context_ns = try agent.applicationScopeNamespace(a, ContextJournal.namespace, conversation);
        const context = extensions.get(context_ns) orelse continue;
        if (j.get(context.value, "inbox_hold") == .null or j.get(context.value, "inbox_hold_schema") != .null or
            j.equal(j.get(context.value, "inbox_failed_policy"), "\"withdraw\"")) continue;

        var admissions: std.StringArrayHashMapUnmanaged(u64) = .empty;
        for (inbox.value.object.keys(), inbox.value.object.values()) |id, item| {
            if (prompt(item) and disposition(item) == .pending and !held(item)) try admissions.put(a, id, 0);
        }
        if (admissions.count() == 0) continue;
        const cutoff = try lastHold(source, context_ns, context.head) orelse continue;
        var held_ids = j.object();
        if (try readLegacyAdmissions(source, scoped, inbox.head, cutoff, &admissions)) {
            for (admissions.keys(), admissions.values()) |id, admitted| {
                if (admitted != 0 and admitted < cutoff) try held_ids.object.put(a, id, .null);
            }
        }
        try actions.append(a, action(scoped, inbox.head, restore_holds, held_ids));
    }
    return actions.items;
}

fn lastHold(source: protocol.State.Source, namespace_id: []const u8, head: u64) !?u64 {
    var ref = head;
    while (ref != 0) {
        const tail = try source.get(ref);
        const previous = tail.action.@"control.extension".expected_head;
        const first = ref - tail.tx.index;
        while (ref >= first) : (ref -= 1) {
            const frame = try source.get(ref);
            if (frame.action != .@"control.extension") continue;
            const change = frame.action.@"control.extension";
            if (!std.mem.eql(u8, change.namespace, namespace_id)) continue;
            for (j.items(j.get(change.input.value, "assign"))) |assignment| {
                if (j.equal(j.get(assignment, "name"), "inbox_hold")) return first;
            }
        }
        ref = previous;
    }
    return null;
}

fn readLegacyAdmissions(source: protocol.State.Source, scoped: []const u8, head: u64, cutoff: u64, admissions: *std.StringArrayHashMapUnmanaged(u64)) !bool {
    var ref = head;
    while (ref != 0) {
        const tail = try source.get(ref);
        const previous = tail.action.@"control.extension".expected_head;
        const first = ref - tail.tx.index;
        while (ref >= first) : (ref -= 1) {
            const frame = try source.get(ref);
            if (frame.action != .@"control.extension") continue;
            const change = frame.action.@"control.extension";
            if (!std.mem.eql(u8, change.namespace, scoped)) continue;
            const input = change.input.value;
            if (ref > cutoff and (std.mem.eql(u8, change.action, "resume_inputs") or
                (std.mem.eql(u8, change.action, "pause") and input == .bool and !input.bool))) return false;
            if (!std.mem.eql(u8, change.action, "enqueue")) continue;
            for (input.object.keys()) |id| {
                const admission = admissions.getPtr(id) orelse continue;
                if (admission.* == 0 or keyed(id)) admission.* = ref;
            }
        }
        ref = previous;
    }
    return true;
}

fn displayId(a: Allocator, conversation: []const u8, submission: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}display/{s}", .{ try agent.applicationEntryPrefix(a, conversation), &inputHash(submission) });
}

fn entryDraft(a: Allocator, record: Value) !Value {
    return j.parse(a, j.text(j.get(j.get(record, "input"), "json")));
}

fn displayOnly(draft: Value) bool {
    return j.get(draft, "model") == .null and j.get(draft, "head") == .null and j.get(draft, "edits") == .null;
}

fn resetRecord(a: Allocator, record: Value) !bool {
    if (j.equal(j.get(record, "kind"), "reset")) return true;
    return j.equal(j.get(record, "kind"), "write") and j.equal(j.get(try entryDraft(a, record), "head"), "self");
}

fn queuedReset(a: Allocator, state: Value) !bool {
    if (state == .object) for (state.object.values()) |record| {
        const status = disposition(record);
        if ((status == .pending or status == .claimed) and try resetRecord(a, record)) return true;
    };
    return false;
}

fn introducesReset(a: Allocator, scoped: []const u8, actions: []const Action) !bool {
    for (actions) |operation| {
        if (operation != .@"control.extension") continue;
        const change = operation.@"control.extension";
        if (!std.mem.eql(u8, change.namespace, scoped) or !std.mem.eql(u8, change.action, "enqueue")) continue;
        if (try queuedReset(a, change.input.value)) return true;
    }
    return false;
}

fn displayContext(a: Allocator, journal: *const agent.SessionJournal, scope: []const u8, actions: []const Action) ![]const []const u8 {
    if (journal.state.contexts.get(scope)) |context| return context.ids.items;
    for (actions) |operation| {
        if (operation != .@"control.context.create") continue;
        const created = operation.@"control.context.create";
        if (!std.mem.eql(u8, created.id, scope)) continue;
        const base = created.base orelse return &.{};
        const ids = try journal.state.contextAt(a, journal.source(), base.context, base.at);
        const through = base.through orelse return ids;
        for (ids, 0..) |id, index| if (std.mem.eql(u8, id, through)) return ids[0 .. index + 1];
        return error.UnselectedAnchor;
    }
    return error.UnknownContext;
}

pub fn prepareDisplayEntries(a: Allocator, journal: *const agent.SessionJournal, actions: []const Action, writes: []const Action) ![]const Frame.MessageAppend {
    var out: std.ArrayList(Frame.MessageAppend) = .empty;
    for (writes, 0..) |operation, index| {
        const change = operation.@"control.extension";
        if (!std.mem.eql(u8, change.input.contract.id, namespace) or !std.mem.eql(u8, change.action, "enqueue")) continue;
        const records = change.input.value;
        if (records != .object or records.object.count() != 1) continue;
        const record = records.object.values()[0];
        if (!j.equal(j.get(record, "kind"), "write")) continue;
        const scope = j.text(j.get(record, "conversation"));
        if (scope.len == 0) continue;
        if (!std.mem.eql(u8, try scopeNamespace(a, scope), change.namespace)) return error.InvalidDatagram;
        const draft = try entryDraft(a, record);
        if (!displayOnly(draft)) continue;
        const submission = records.object.keys()[0];
        const state = if (journal.state.extensions.get(change.namespace)) |inbox| inbox.value else .null;
        if (disposition(j.get(state, submission)) != null or try queuedReset(a, state) or
            try introducesReset(a, change.namespace, actions) or try introducesReset(a, change.namespace, writes[0..index])) continue;

        const ids = try displayContext(a, journal, scope, actions);
        const ctx_namespace = try agent.applicationScopeNamespace(a, ContextJournal.namespace, scope);
        const context = if (journal.state.extensions.get(ctx_namespace)) |entry| try ContextJournal.materialize(a, entry.value) else .null;
        const saved_head = j.get(j.get(context, "session"), "head");
        var anchor: ?[]const u8 = if (saved_head == .string) saved_head.string else null;
        if (context == .null) {
            var reversed = std.mem.reverseIterator(ids);
            while (reversed.next()) |id| {
                if (std.mem.startsWith(u8, id, "application/") and !journal.state.displays.contains(id)) {
                    anchor = id["application/".len..];
                    break;
                }
            }
        }
        var after: ?[]const u8 = if (ids.len == 0) null else ids[ids.len - 1];
        for (actions) |prefix| {
            if (prefix != .@"document.message.append") continue;
            const append = prefix.@"document.message.append";
            const placement = append.placement orelse continue;
            if (std.mem.eql(u8, placement.context, scope) and std.mem.eql(u8, placement.after orelse "", after orelse "")) {
                after = append.message.id;
            }
        }
        const id = try displayId(a, scope, submission);
        const message_id = try std.fmt.allocPrint(a, "application/{s}", .{id});
        var already_planned = false;
        var found_tail = false;
        var prior = std.mem.reverseIterator(out.items);
        while (prior.next()) |placed| {
            if (std.mem.eql(u8, placed.message.id, message_id)) {
                already_planned = true;
                break;
            }
            if (!found_tail and std.mem.eql(u8, placed.placement.?.context, scope)) {
                after = placed.message.id;
                found_tail = true;
            }
        }
        if (already_planned) continue;
        const entry = try j.value(a, .{ .kind = "write", .id = id, .parent = anchor, .event_kind = j.text(j.get(draft, "kind")), .data = j.get(draft, "data"), .submission = submission, .placed_at_ms = std.Io.Clock.real.now(journal.io).toMilliseconds() });
        try out.append(a, try agent.displayApplicationEntry(a, scope, after, entry));
    }
    return out.items;
}

pub fn isSteering(entry: Value) bool {
    return j.equal(j.get(entry, "kind"), "steer");
}

fn queuedSteering(entry: Value) bool {
    return isSteering(entry) or j.flag(j.get(entry, "queued_steering")) or
        j.equal(j.get(j.get(j.get(entry, "admission_policy"), "policy"), "when_busy"), "steer");
}

pub const PendingMessage = struct {
    id: []const u8,
    original: []const u8,
    kind: QueueKind,

    pub const QueueKind = enum { steering, follow_up };
    pub const Text = enum { full, first_line };
};

/// Return pending prompts in display and restoration order.
pub fn pendingMessages(a: Allocator, state: Value, dispatched: ?[]const u8, text: PendingMessage.Text) ![]PendingMessage {
    if (state != .object) return &.{};
    var items: std.ArrayList(PendingMessage) = .empty;
    for ([_]PendingMessage.QueueKind{ .steering, .follow_up }) |kind| {
        for (state.object.keys(), state.object.values()) |id, entry| {
            if (!prompt(entry) or disposition(entry) != .pending or queuedSteering(entry) != (kind == .steering)) continue;
            if (dispatched) |active| if (std.mem.eql(u8, active, id)) continue;
            const original = j.text(j.get(j.get(entry, "input"), "original"));
            const end = if (text == .first_line) std.mem.indexOfScalar(u8, original, '\n') orelse original.len else original.len;
            try items.append(a, .{
                .id = try a.dupe(u8, id),
                .original = try a.dupe(u8, original[0..end]),
                .kind = kind,
            });
        }
    }
    return items.items;
}

pub const QueueMode = enum(u1) { one_at_a_time, all };
pub const QueueModes = packed struct(u2) {
    steering: QueueMode = .one_at_a_time,
    follow_up: QueueMode = .one_at_a_time,
};

pub fn claimBoundary(a: Allocator, extensions: *const protocol.Extensions, conversation: []const u8, ctx: Value, mode: []const u8, selection: QueueModes) !?agent.BoundaryInputClaim {
    const target = j.text(j.get(ctx, "steering_boundary"));
    const resets = j.get(ctx, "reset_boundary");
    const reset_boundary = resets == .bool and resets.bool;
    const scoped = try scopeNamespace(a, conversation);
    const yielding = std.mem.eql(u8, mode, "yield_writes");
    const inbox = extensions.get(scoped) orelse return if (yielding) .{ .value = j.array(a) } else null;
    if (yielding) {
        for (inbox.value.object.values()) |entry| {
            const status = disposition(entry);
            if (status != .pending and status != .claimed) continue;
            const kind = j.get(entry, "kind");
            if (prompt(entry) or j.equal(kind, "reset")) return null;
            if (j.equal(kind, "write")) {
                const draft = try j.parse(a, j.text(j.get(j.get(entry, "input"), "json")));
                if (j.equal(j.get(draft, "head"), "self")) return null;
            }
        }
        return (try claimWrites(a, scoped, inbox, false)) orelse .{ .value = j.array(a) };
    }
    const queue: QueueScope = .{ .conversation = conversation, .namespace = scoped, .inbox = inbox, .extensions = extensions };
    if (std.mem.startsWith(u8, mode, "prompt:")) {
        const id = mode["prompt:".len..];
        const entry = j.get(inbox.value, id);
        if (!j.equal(j.get(entry, "kind"), "prompt") or j.get(entry, "continuation") != .null or held(entry)) return null;
        const status = disposition(entry);
        if (status == .claimed) return .{ .value = .{ .bool = true } };
        if (status != .pending or paused(inbox.value)) return null;
        var selected = j.object();
        try selected.object.put(a, id, .null);
        return .{ .value = .{ .bool = true }, .action = action(scoped, inbox.head, "claim", selected) };
    }
    if (std.mem.eql(u8, mode, "writes") or std.mem.eql(u8, mode, "idle_writes")) {
        return claimWrites(a, scoped, inbox, std.mem.eql(u8, mode, "idle_writes"));
    }
    if (std.mem.startsWith(u8, mode, "idle:")) {
        return claimIdlePrompt(a, queue, selection, mode["idle:".len..]);
    }
    if (std.mem.eql(u8, mode, "final")) return claimQueue(a, queue, final_batch, selection, null);
    if (std.mem.eql(u8, mode, "post_tools")) return claimQueue(a, queue, post_tools_batch, selection, null);
    if (std.mem.eql(u8, mode, "recover_final")) return claimQueue(a, queue, final_batch, null, null);
    const continuation = j.text(j.get(ctx, "continue_boundary"));
    if (continuation.len != 0) return try claimFollowups(a, queue, continuation);
    for (inbox.value.object.keys(), inbox.value.object.values()) |id, entry| {
        const reset = j.equal(j.get(entry, "kind"), "reset");
        if (reset) {
            if (!reset_boundary) continue;
        } else if (target.len == 0 or !isSteering(entry) or !j.equal(j.get(entry, "target"), target)) continue;
        const status = disposition(entry);
        if (status != .claimed and (status != .pending or (!reset and paused(inbox.value)))) continue;
        const input = j.get(entry, "input");
        var claim: ?Action = null;
        if (status == .pending) {
            var selected = j.object();
            try selected.object.put(a, id, .null);
            claim = action(scoped, inbox.head, "claim", selected);
        }
        const value = if (reset)
            try j.value(a, .{ .command = "reset", .submission = id, .note = j.text(j.get(input, "note")) })
        else
            try deliveredPrompt(a, id, input);
        return .{ .value = value, .action = claim };
    }
    return null;
}

pub fn held(entry: Value) bool {
    return j.flag(j.get(entry, "held"));
}

fn activatesQueue(entry: Value, draft: Value) bool {
    return !held(entry) and !j.flag(j.get(entry, "passive_write")) and !displayOnly(draft);
}

fn newContextWrite(a: Allocator, state: Value) !bool {
    for (state.object.values()) |entry| {
        const status = disposition(entry);
        if (status != .pending and status != .claimed) continue;
        if (j.equal(j.get(entry, "kind"), "reset")) break;
        if (!j.equal(j.get(entry, "kind"), "write") or held(entry)) continue;
        const draft = try j.parse(a, j.text(j.get(j.get(entry, "input"), "json")));
        if (activatesQueue(entry, draft)) return true;
    }
    return false;
}

fn claimWrites(a: Allocator, scoped: []const u8, inbox: protocol.Extensions.Entry, idle: bool) !?agent.BoundaryInputClaim {
    const release_held = !idle or try newContextWrite(a, inbox.value);
    var selected = j.object();
    var entries = j.array(a);
    for (inbox.value.object.keys(), inbox.value.object.values()) |id, entry| {
        const status = disposition(entry);
        if (status != .pending and status != .claimed) continue;
        if (j.equal(j.get(entry, "kind"), "reset")) break;
        if (!j.equal(j.get(entry, "kind"), "write") or (!release_held and held(entry))) continue;
        const draft = try j.parse(a, j.text(j.get(j.get(entry, "input"), "json")));
        try entries.array.append(try j.value(a, .{ .submission = id, .entry = draft, .activates = activatesQueue(entry, draft) }));
        if (status == .pending) try selected.object.put(a, id, .null);
    }
    if (entries.array.items.len == 0) return null;
    return .{ .value = entries, .action = if (selected.object.count() != 0) action(scoped, inbox.head, "claim", selected) else null };
}

fn claimFollowups(a: Allocator, queue: QueueScope, continuation: []const u8) !?agent.BoundaryInputClaim {
    const inbox = queue.inbox;
    const entry = j.get(inbox.value, continuation);
    if (disposition(entry) != .pending or !j.equal(j.get(entry, "kind"), "continue_turn")) return null;
    var prompts = j.array(a);
    var selected = j.object();
    for (inbox.value.object.keys(), inbox.value.object.values()) |id, candidate| {
        if (disposition(candidate) != .claimed or !j.equal(j.get(candidate, "continuation"), continuation)) continue;
        try prompts.array.append(try queuePrompt(a, id, candidate, try queue.modelSelection(a, id, candidate)));
    }
    if (prompts.array.items.len == 0) {
        for (inbox.value.object.keys(), inbox.value.object.values()) |id, candidate| {
            if (disposition(candidate) != .pending or !j.equal(j.get(candidate, "kind"), "prompt")) continue;
            const pinned = j.flag(j.get(candidate, "own_model"));
            const chosen = if (pinned) try queue.modelSelection(a, id, candidate) else .null;
            if (pinned and (prompts.array.items.len != 0 or chosen == .null)) break;
            try selected.object.put(a, id, j.string(continuation));
            try prompts.array.append(try queuePrompt(a, id, candidate, chosen));
            if (pinned) break;
        }
    }
    var value = j.object();
    try value.object.put(a, "prompts", prompts);
    return .{
        .value = value,
        .action = if (selected.object.count() > 0) action(queue.namespace, inbox.head, "claim_followups", selected) else null,
    };
}

const QueueScope = struct {
    conversation: []const u8,
    namespace: []const u8,
    inbox: protocol.Extensions.Entry,
    extensions: *const protocol.Extensions,

    fn modelSelection(self: QueueScope, a: Allocator, id: []const u8, entry: Value) !Value {
        const saved = j.get(entry, "model_selection");
        if (saved != .null or !j.flag(j.get(entry, "own_model"))) return saved;
        const tasks = self.extensions.get(agent.TaskJournal.namespace) orelse return .null;
        const key = try promptTaskHash(a, self.conversation, id);
        const task = j.get(agent.TaskJournal.taskValues(tasks.value), &key);
        return j.get(j.get(task, "input"), "model_selection");
    }
};

fn queuePrompt(a: Allocator, id: []const u8, entry: Value, model_selection: Value) !Value {
    var input = try deliveredPrompt(a, id, j.get(entry, "input"));
    if (model_selection != .null) try input.object.put(a, "submission_selection", model_selection);
    return input;
}

fn claimIdlePrompt(a: Allocator, queue: QueueScope, selection: QueueModes, submission: []const u8) !?agent.BoundaryInputClaim {
    const inbox = queue.inbox;
    const trigger = j.get(inbox.value, submission);
    const status = disposition(trigger);
    if (!j.equal(j.get(trigger, "kind"), "prompt") or held(trigger) or (status != .pending and status != .claimed)) return null;
    if (j.flag(j.get(trigger, "compaction_seed"))) return claimQueue(a, queue, final_batch, selection, submission);
    for (inbox.value.object.keys(), inbox.value.object.values()) |id, entry| {
        if (std.mem.eql(u8, id, submission)) break;
        if (!prompt(entry)) continue;
        if (disposition(entry) == .pending or
            (disposition(entry) == .claimed and j.equal(j.get(entry, "continuation"), final_batch)))
        {
            return claimQueue(a, queue, final_batch, selection, null);
        }
    }
    return null;
}

fn claimQueue(a: Allocator, queue: QueueScope, batch: []const u8, mode: ?QueueModes, seed: ?[]const u8) !?agent.BoundaryInputClaim {
    const inbox = queue.inbox;
    var prompts = j.array(a);
    const ids = inbox.value.object.keys();
    const records = inbox.value.object.values();
    for (ids, records) |id, entry| {
        if (!j.flag(j.get(entry, "compaction_seed"))) continue;
        if (disposition(entry) == .claimed and j.equal(j.get(entry, "continuation"), batch)) {
            try prompts.array.append(try queuePrompt(a, id, entry, .null));
            break;
        }
    }
    for (ids, records) |id, entry| {
        if (disposition(entry) == .claimed and j.equal(j.get(entry, "continuation"), batch)) {
            if (prompts.array.items.len != 0 and j.equal(j.get(prompts.array.items[0], "submission"), id)) continue;
            try prompts.array.append(try queuePrompt(a, id, entry, try queue.modelSelection(a, id, entry)));
        }
    }
    if (prompts.array.items.len != 0) return .{ .value = prompts };
    const selection = mode orelse return null;
    if (paused(inbox.value)) return null;
    const final = std.mem.eql(u8, batch, final_batch);
    var steering_only = !final or seed != null;
    for (records) |entry| {
        const status = disposition(entry);
        if ((status == .pending or status == .claimed) and j.equal(j.get(entry, "kind"), "reset")) return null;
        if (status == .pending and prompt(entry) and queuedSteering(entry)) steering_only = true;
    }
    const take_all = (if (steering_only) selection.steering else selection.follow_up) == .all;
    var selected = j.object();
    if (seed) |id| {
        const entry = j.get(inbox.value, id);
        if (disposition(entry) != .pending) return null;
        try selected.object.put(a, id, j.string(batch));
        try prompts.array.append(try queuePrompt(a, id, entry, .null));
    }
    for (ids, records) |id, entry| {
        if (disposition(entry) != .pending or !prompt(entry) or
            j.flag(j.get(entry, "compaction_seed")) or queuedSteering(entry) != steering_only) continue;
        if (final and j.flag(j.get(entry, "own_model"))) {
            if (prompts.array.items.len != 0) break;
            const chosen = try queue.modelSelection(a, id, entry);
            if (chosen == .null) break;
            try selected.object.put(a, id, j.string(batch));
            try prompts.array.append(try queuePrompt(a, id, entry, chosen));
            break;
        }
        try selected.object.put(a, id, j.string(batch));
        try prompts.array.append(try queuePrompt(a, id, entry, .null));
        if (!take_all) break;
    }
    if (prompts.array.items.len == 0) return null;
    return .{ .value = prompts, .action = action(queue.namespace, inbox.head, "claim_followups", selected) };
}

pub fn deliveredPrompt(a: Allocator, id: []const u8, input: Value) !Value {
    var prompt_value = try j.value(a, .{ .submission = id, .text = j.text(j.get(input, "text")), .original = j.text(j.get(input, "original")) });
    const custom = j.get(input, "entry");
    if (custom != .null) try j.put(a, &prompt_value, "entry", try j.copy(a, custom));
    const user_content = j.get(input, "user_content");
    if (user_content != .null) try j.put(a, &prompt_value, "user_content", try j.copy(a, user_content));
    return prompt_value;
}

pub fn inputHash(original: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn requestId(a: Allocator, id: []const u8) ![]const u8 {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidRequestId;
    for (id) |byte| if (byte < 32 or byte == 127) return error.InvalidRequestId;
    return std.fmt.allocPrint(a, "{s}{s}", .{ request_prefix, id });
}

fn keyed(id: []const u8) bool {
    return std.mem.startsWith(u8, id, request_prefix);
}

pub fn disposition(entry: Value) ?Disposition {
    if (entry != .object) return null;
    const status = j.get(entry, "disposition");
    if (status == .string) return std.meta.stringToEnum(Disposition, status.string);
    return if (j.get(entry, "input") == .object) .pending else null;
}

pub fn receipt(a: Allocator, entry: Value) !Receipt {
    const record = j.get(entry, "run");
    const placed = j.get(entry, "entry");
    const reason = j.get(entry, "reason");
    return .{
        .disposition = disposition(entry),
        .run = if (record == .null) null else try std.json.parseFromValueLeaky(Receipt.Run, a, record, .{ .allocate = .alloc_always }),
        .entry = if (placed == .string) try a.dupe(u8, placed.string) else null,
        .reason = if (reason == .string) try a.dupe(u8, reason.string) else null,
    };
}

fn prompt(entry: Value) bool {
    return j.equal(j.get(entry, "kind"), "prompt") or isSteering(entry);
}

pub fn paused(state: Value) bool {
    const entry = j.get(state, paused_key);
    return entry == .bool and entry.bool;
}

pub fn needsResume(state: Value) bool {
    if (paused(state) or waitingAfterCompaction(state)) return true;
    if (state == .object) for (state.object.values()) |entry| {
        if (prompt(entry) and held(entry)) return true;
    };
    return false;
}

pub fn waitingAfterCompaction(state: Value) bool {
    return j.flag(j.get(state, compaction_wait_key));
}

fn initial(_: Allocator) !Value {
    return .{ .object = .empty };
}

pub fn scopeNamespace(a: Allocator, conversation: []const u8) ![]const u8 {
    return @import("agent").applicationScopeNamespace(a, namespace, conversation);
}

pub fn action(scoped: []const u8, head: u64, name: []const u8, input: Value) Action {
    return .{ .@"control.extension" = .{
        .namespace = scoped,
        .expected_head = head,
        .action = name,
        .input = .{ .contract = contract.version, .value = input },
    } };
}

fn validate(previous: Value, name: []const u8, input: Value) !void {
    if (std.mem.eql(u8, name, "resume_inputs")) {
        if (previous != .object or input != .null) return error.InvalidQueueState;
        return;
    }
    if (std.mem.eql(u8, name, "pause")) {
        if (previous != .object or input != .bool) return error.InvalidQueueState;
        return;
    }
    const restoring = std.mem.eql(u8, name, restore_holds);
    if (previous != .object or input != .object or (input.object.count() == 0 and !restoring)) return error.InvalidDatagram;
    if (restoring and j.get(previous, holds_restored_key) != .null) return error.InvalidQueueState;
    const inserting = std.mem.eql(u8, name, "enqueue");
    const consuming = std.mem.eql(u8, name, "consume");
    const rejecting = std.mem.eql(u8, name, "reject");
    const claiming = std.mem.eql(u8, name, "claim");
    const promoting = std.mem.eql(u8, name, "follow_up");
    const preserving_steering = std.mem.eql(u8, name, "preserve_steering");
    const placing = std.mem.eql(u8, name, "place");
    const finishing = std.mem.eql(u8, name, "finish_run");
    const joining = std.mem.eql(u8, name, "claim_followups");
    const releasing = std.mem.eql(u8, name, "release_followups");
    const writing = std.mem.eql(u8, name, "settle_write");
    const withdrawing = std.mem.eql(u8, name, "withdraw");
    const holding_writes = std.mem.eql(u8, name, "hold_writes");
    const holding_inputs = restoring or std.mem.eql(u8, name, "hold_inputs");
    if (!inserting and !consuming and !rejecting and !claiming and !promoting and !preserving_steering and !placing and !finishing and !joining and !releasing and !writing and !withdrawing and !holding_writes and !holding_inputs and !std.mem.eql(u8, name, "settle")) return error.InvalidDatagram;
    for (input.object.keys(), input.object.values()) |id, value| {
        if (id.len == 0 or std.mem.eql(u8, id, paused_key) or
            std.mem.eql(u8, id, compaction_wait_key) or std.mem.eql(u8, id, holds_restored_key)) return error.InvalidDatagram;
        if (!inserting) {
            const entry = j.get(previous, id);
            const status = disposition(entry);
            if (holding_writes or holding_inputs) {
                const valid_kind = if (holding_inputs) prompt(entry) else j.equal(j.get(entry, "kind"), "write");
                if ((status != .pending and status != .claimed) or !valid_kind or value != .null) return error.InvalidDatagram;
                continue;
            }
            if (withdrawing) {
                const cancelling_claim = status == .claimed and j.equal(j.get(entry, "kind"), "prompt") and
                    j.get(entry, "continuation") == .null and j.equal(value, "aborted");
                if ((status != .pending and !cancelling_claim) or !(prompt(entry) or j.equal(j.get(entry, "kind"), "write")) or
                    (!j.equal(value, "aborted") and !j.equal(value, "run_failed"))) return error.InvalidDatagram;
                continue;
            }
            if (writing) {
                if (status != .claimed or !j.equal(j.get(entry, "kind"), "write") or value != .object or value.object.count() != 1) return error.InvalidDatagram;
                if (j.text(j.get(value, "entry")).len == 0 and !j.equal(j.get(value, "reason"), "stale")) return error.InvalidDatagram;
                continue;
            }
            if (joining or releasing) {
                if (value != .string) return error.InvalidDatagram;
                const final = std.mem.eql(u8, value.string, final_batch);
                const post_tools = std.mem.eql(u8, value.string, post_tools_batch);
                if (!(if (final) prompt(entry) else if (post_tools) queuedSteering(entry) else j.equal(j.get(entry, "kind"), "prompt"))) return error.InvalidDatagram;
                if (joining) {
                    const continuation = j.get(previous, value.string);
                    if (status != .pending or (!final and !post_tools and (disposition(continuation) != .pending or !j.equal(j.get(continuation, "kind"), "continue_turn")))) return error.InvalidDatagram;
                } else if (status != .claimed or !j.equal(j.get(entry, "continuation"), value.string)) return error.InvalidDatagram;
                continue;
            }
            if (placing or finishing) {
                if (!keyed(id) or !prompt(entry) or value != .object) return error.InvalidSubmissionRun;
                const input_entry = j.text(j.get(value, "input_entry"));
                const state = j.text(j.get(value, "status"));
                if (input_entry.len == 0) return error.InvalidSubmissionRun;
                if (placing) {
                    if ((status != .pending and status != .claimed) or !std.mem.eql(u8, state, "running") or value.object.count() != 2) return error.InvalidSubmissionRun;
                } else {
                    const prior_run = j.get(entry, "run");
                    if (status != .consumed or (prior_run != .null and
                        (!j.equal(j.get(prior_run, "status"), "running") or !j.equal(j.get(prior_run, "input_entry"), input_entry)))) return error.InvalidSubmissionRun;
                    const field = if (std.mem.eql(u8, state, "answered")) "answer_entry" else if (std.mem.eql(u8, state, "unanswered")) "reason" else return error.InvalidSubmissionRun;
                    if (value.object.count() != 3 or j.text(j.get(value, field)).len == 0) return error.InvalidSubmissionRun;
                }
                continue;
            }
            if (value != .null or (status != .pending and !((consuming or promoting) and status == .claimed))) return error.UnknownDatagram;
            if (claiming and !(j.equal(j.get(entry, "kind"), "prompt") or j.equal(j.get(entry, "kind"), "reset") or j.equal(j.get(entry, "kind"), "write") or (isSteering(entry) and !paused(previous)))) return error.InvalidDatagram;
            if ((promoting or preserving_steering) and !isSteering(entry)) return error.InvalidDatagram;
            if (rejecting and !j.equal(j.get(entry, "kind"), "register_tools")) return error.InvalidDatagram;
            continue;
        }
        if (previous.object.get(id)) |prior| {
            const digest = j.get(value, "sha256");
            if (!keyed(id)) return error.DuplicateDatagram;
            if (!j.equal(j.get(prior, "kind"), j.text(j.get(value, "kind"))) or
                digest != .string or !j.equal(j.get(prior, "sha256"), digest.string) or
                j.flag(j.get(prior, "passive_write")) != j.flag(j.get(value, "passive_write"))) return error.RequestIdConflict;
        }
        const kind = std.meta.stringToEnum(Kind, j.text(j.get(value, "kind"))) orelse return error.InvalidDatagram;
        const passive_write = j.get(value, "passive_write");
        if (passive_write != .null and (kind != .write or passive_write != .bool)) return error.InvalidDatagram;
        if (j.get(value, "queued_steering") != .null) return error.InvalidDatagram;
        const body = j.get(value, "input");
        const terminal = j.get(body, "terminal");
        if (kind == .compact and terminal != .null and (terminal != .bool or !j.flag(j.get(body, "managed")))) return error.InvalidDatagram;
        const valid = switch (kind) {
            .prompt, .steer => j.get(body, "text") == .string and j.get(body, "original") == .string,
            .compact => j.get(body, "focus") == .string,
            .register_tools, .write => keyed(id) and j.get(body, "json") == .string,
            .continue_turn => !keyed(id) and body == .object and body.object.count() == 0,
            .reset => !keyed(id) and j.get(body, "note") == .string,
        };
        if (!valid) return error.InvalidDatagram;
        const custom = if (kind == .prompt or kind == .steer) j.get(body, "entry") else .null;
        if (custom != .null) try validateInputEntry(custom);
        const user_content = j.get(body, "user_content");
        if (user_content != .null) {
            if (kind != .prompt and kind != .steer) return error.InvalidDatagram;
            try validateUserContent(user_content);
        }
        const own_model = j.get(value, "own_model");
        if (own_model != .null and (kind != .prompt or own_model != .bool)) return error.InvalidDatagram;
        const model_selection = j.get(value, "model_selection");
        if (model_selection != .null and (model_selection != .object or !j.flag(own_model))) return error.InvalidDatagram;
        const compaction_seed = j.get(value, "compaction_seed");
        if (compaction_seed != .null and (compaction_seed != .bool or kind != .prompt or j.flag(own_model) or queuedSteering(value))) return error.InvalidDatagram;
        if (kind == .steer and (j.text(j.get(value, "target")).len == 0 or !j.equal(j.get(value, "boundary"), "model_or_tool"))) return error.InvalidDatagram;
        const digest = j.get(value, "sha256");
        if (keyed(id)) {
            const original = j.text(j.get(body, switch (kind) {
                .prompt, .steer => "original",
                .compact => "focus",
                .register_tools, .write => "json",
                .continue_turn, .reset => unreachable,
            }));
            if (digest != .string or (custom == .null and user_content == .null and !std.mem.eql(u8, digest.string, &inputHash(original)))) return error.InvalidDatagram;
        }
        if (j.get(value, "disposition") != .null or j.get(value, "held") != .null) return error.InvalidDatagram;
    }
}

fn validateState(a: Allocator, committed: *const protocol.Extensions, previous: Value, frame: Frame.Frame) !void {
    const change = frame.action.@"control.extension";
    if (!std.mem.eql(u8, change.action, "enqueue")) return;
    const records = change.input.value;
    for (records.object.keys(), records.object.values()) |id, record| {
        const policy_value = j.get(record, "admission_policy");
        if (policy_value == .null) continue;
        if (!keyed(id) or !j.equal(j.get(record, "kind"), "prompt")) return error.InvalidDatagram;
        const scoped = std.json.parseFromValueLeaky(ScopedPolicy, a, policy_value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidDatagram,
        };
        if (scoped.conversation.len == 0 or !std.mem.eql(u8, change.namespace, try scopeNamespace(a, scoped.conversation))) return error.InvalidDatagram;
        if (previous.object.contains(id)) continue;
        const policy = scoped.policy;
        if (policy.when_busy != .reject and policy.when_idle != .reject) continue;
        const context = try agent.applicationScopeNamespace(a, ContextJournal.namespace, scoped.conversation);
        const busy = if (committed.get(context)) |saved| try ContextJournal.hasLiveRun(a, saved.value) else false;
        if (busy and policy.when_busy == .reject) return error.ConversationBusy;
        if (!busy and policy.when_idle == .reject) return error.ConversationIdle;
    }
}

fn reduce(a: Allocator, previous: Value, name: []const u8, input: Value) !Value {
    var next: Value = .{ .object = .empty };
    if (std.mem.eql(u8, name, "resume_inputs")) {
        for (previous.object.keys(), previous.object.values()) |id, value| {
            if (std.mem.eql(u8, id, paused_key) or std.mem.eql(u8, id, compaction_wait_key)) continue;
            var entry = value;
            if (prompt(value) and held(value)) {
                entry = j.object();
                for (value.object.keys(), value.object.values()) |key, field| {
                    if (!std.mem.eql(u8, key, "held")) try entry.object.put(a, key, field);
                }
            }
            try next.object.put(a, id, entry);
        }
        return next;
    }
    if (std.mem.eql(u8, name, "pause")) {
        for (previous.object.keys(), previous.object.values()) |id, value| {
            if (!std.mem.eql(u8, id, paused_key)) try next.object.put(a, id, value);
        }
        if (input.bool) try next.object.put(a, paused_key, input);
        return next;
    }
    for (previous.object.keys(), previous.object.values()) |id, value| {
        if (!input.object.contains(id) or std.mem.eql(u8, name, "enqueue")) {
            try next.object.put(a, id, value);
        } else if (std.mem.eql(u8, name, "hold_writes") or std.mem.eql(u8, name, "hold_inputs") or std.mem.eql(u8, name, restore_holds)) {
            var changed = j.object();
            for (value.object.keys(), value.object.values()) |key, field| try changed.object.put(a, key, field);
            try changed.object.put(a, "held", .{ .bool = true });
            try next.object.put(a, id, changed);
        } else if (std.mem.eql(u8, name, "claim") or std.mem.eql(u8, name, "follow_up") or std.mem.eql(u8, name, "preserve_steering") or
            std.mem.eql(u8, name, "claim_followups") or std.mem.eql(u8, name, "release_followups"))
        {
            var changed = j.object();
            for (value.object.keys(), value.object.values()) |key, field| {
                if (!std.mem.eql(u8, key, "disposition") and !std.mem.eql(u8, key, "continuation")) try changed.object.put(a, key, field);
            }
            if (std.mem.eql(u8, name, "claim") or std.mem.eql(u8, name, "claim_followups")) {
                try changed.object.put(a, "disposition", j.string("claimed"));
                if (std.mem.eql(u8, name, "claim_followups")) try changed.object.put(a, "continuation", j.get(input, id));
            } else if (std.mem.eql(u8, name, "follow_up")) {
                try changed.object.put(a, "kind", j.string("prompt"));
            } else if (std.mem.eql(u8, name, "preserve_steering")) {
                try changed.object.put(a, "kind", j.string("prompt"));
                try changed.object.put(a, "queued_steering", .{ .bool = true });
            }
            try next.object.put(a, id, changed);
        } else if (keyed(id)) {
            const keeps_run = std.mem.eql(u8, name, "place") or std.mem.eql(u8, name, "finish_run");
            const written = if (std.mem.eql(u8, name, "settle_write")) j.get(input, id) else .null;
            var record = try j.value(a, .{
                .kind = j.text(j.get(value, "kind")),
                .sha256 = j.text(j.get(value, "sha256")),
                .disposition = if (keeps_run or std.mem.eql(u8, name, "consume") or j.get(written, "entry") != .null) Disposition.consumed else if (std.mem.eql(u8, name, "reject") or written != .null) Disposition.rejected else Disposition.discarded,
            });
            if (keeps_run) try record.object.put(a, "run", j.get(input, id));
            if (j.flag(j.get(value, "passive_write"))) try record.object.put(a, "passive_write", .{ .bool = true });
            if (written == .object) for (written.object.keys(), written.object.values()) |key, field| try record.object.put(a, key, field);
            if (std.mem.eql(u8, name, "withdraw")) try record.object.put(a, "reason", j.get(input, id));
            try next.object.put(a, id, record);
        }
    }
    if (std.mem.eql(u8, name, "enqueue")) {
        for (input.object.keys(), input.object.values()) |id, value| {
            const body = j.get(value, "input");
            if (keyed(id) and prompt(value) and (j.get(body, "entry") != .null or j.get(body, "user_content") != .null)) {
                const digest = try promptHash(a, body);
                if (!j.equal(j.get(value, "sha256"), &digest)) return error.InvalidDatagram;
            }
            if (next.object.contains(id)) continue;
            if (j.equal(j.get(value, "kind"), "write")) {
                const draft = try j.parse(a, j.text(j.get(j.get(value, "input"), "json")));
                const parsed = try std.json.parseFromValueLeaky(EntryDraft, a, draft, .{});
                try validateWrite(parsed);
                try validateWriteActivation(a, parsed, if (j.flag(j.get(value, "passive_write"))) .passive else .normal);
            }
            try next.object.put(a, id, value);
            if (j.equal(j.get(value, "kind"), "compact") and j.flag(j.get(body, "terminal"))) {
                try next.object.put(a, compaction_wait_key, .{ .bool = true });
            } else if (j.flag(j.get(value, "compaction_seed"))) {
                _ = next.object.orderedRemove(compaction_wait_key);
            }
        }
    }
    if (std.mem.eql(u8, name, restore_holds)) try next.object.put(a, holds_restored_key, .{ .bool = true });
    return next;
}

fn reduceTransaction(a: Allocator, previous: Value, frame: Frame.Frame, transaction: *const protocol.Transaction) !Value {
    const change = frame.action.@"control.extension";
    var next = try reduce(a, previous, change.action, change.input.value);
    if (!std.mem.eql(u8, change.action, "enqueue")) return next;
    for (transaction.frames[0..frame.tx.index]) |part| {
        if (part.frame.action != .@"document.message.append") continue;
        const display = part.frame.action.@"document.message.append";
        if (!(display.display_only orelse false)) continue;
        const decoded = (try agent.decodeApplicationEntry(a, display.message)) orelse continue;
        if (!std.mem.eql(u8, decoded.stream, "application") or !j.equal(j.get(decoded.value, "kind"), "write")) continue;
        const scope = (display.placement orelse return error.InvalidDisplayPlan).context;
        if (!std.mem.eql(u8, try scopeNamespace(a, scope), change.namespace)) continue;
        const entry = decoded.value;
        const submission = j.text(j.get(entry, "submission"));
        const record = j.get(change.input.value, submission);
        if (record == .null) continue;
        if (!j.equal(j.get(record, "kind"), "write") or !j.equal(j.get(record, "conversation"), scope) or
            !j.equal(j.get(entry, "id"), try displayId(a, scope, submission)) or
            !std.mem.startsWith(u8, display.message.id, "application/") or
            !j.equal(j.get(entry, "id"), display.message.id["application/".len..])) return error.InvalidDisplayPlan;
        const draft = try entryDraft(a, record);
        if (!displayOnly(draft) or !displayOnly(entry) or !j.equal(j.get(entry, "event_kind"), j.text(j.get(draft, "kind"))) or
            !try protocol.json.equal(a, j.get(entry, "data"), j.get(draft, "data"))) return error.InvalidDisplayPlan;
        const prior = j.get(previous, submission);
        const id = j.text(j.get(entry, "id"));
        if (disposition(prior) != null) {
            if (disposition(prior) == .consumed and j.equal(j.get(prior, "entry"), id)) continue;
            return error.InvalidDisplayPlan;
        }
        if (try queuedReset(a, previous)) return error.InvalidDisplayPlan;
        try next.object.put(a, submission, try j.value(a, .{ .kind = Kind.write, .sha256 = j.text(j.get(record, "sha256")), .disposition = Disposition.consumed, .entry = id }));
    }
    return next;
}

fn validateTransaction(a: Allocator, frame: protocol.frames.Frame, transaction: *const protocol.Transaction) !void {
    const change = frame.action.@"control.extension";
    if (std.mem.eql(u8, change.action, "enqueue")) {
        if (change.input.value != .object) return error.InvalidDatagram;
        for (change.input.value.object.keys(), change.input.value.object.values()) |id, record| {
            const body = j.get(record, "input");
            if (!j.equal(j.get(record, "kind"), "compact") or !j.flag(j.get(body, "managed"))) continue;
            for (transaction.frames) |part| {
                if (part.frame.action != .@"control.extension") continue;
                const tasks = part.frame.action.@"control.extension";
                if (!std.mem.eql(u8, tasks.namespace, @import("agent").TaskJournal.namespace)) continue;
                const draft = j.get(j.get(tasks.input.value, "operation"), "submit");
                if (j.equal(j.get(draft, "id"), id) and j.equal(j.get(draft, "kind"), "cpi-minimal.manual-compaction") and
                    j.equal(j.get(j.get(draft, "input"), "focus"), j.text(j.get(body, "focus"))))
                {
                    const scope = try scopeNamespace(a, j.text(j.get(draft, "conversation")));
                    if (!std.mem.eql(u8, change.namespace, scope)) return error.InvalidDatagram;
                    if (j.flag(j.get(j.get(draft, "input"), "terminal")) != j.flag(j.get(body, "terminal"))) return error.InvalidDatagram;
                    break;
                }
            } else return error.MissingCompactionTask;
        }
        return;
    }
    if (!std.mem.eql(u8, change.action, "settle_write")) return;
    var entries: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer entries.deinit(a);
    for (transaction.frames[0..frame.tx.index]) |part| {
        if (part.frame.action != .@"document.message.append") continue;
        const message = part.frame.action.@"document.message.append".message;
        for (message.content) |content| {
            const value = j.get(content, "value");
            if (!j.equal(j.get(value, "format"), "agent.luau.entry.v1") or !j.equal(j.get(value, "stream"), "application")) continue;
            const entry = try j.parse(a, j.text(j.get(value, "json")));
            if (j.equal(j.get(entry, "kind"), "write") or j.equal(j.get(entry, "kind"), "checkpoint"))
                try entries.put(a, j.text(j.get(entry, "id")), j.text(j.get(entry, "submission")));
        }
    }
    const receipts = change.input.value;
    if (receipts != .object) return error.InvalidDatagram;
    for (receipts.object.keys(), receipts.object.values()) |submission, receipt_value| {
        const id = j.get(receipt_value, "entry");
        if (id == .string and !std.mem.eql(u8, entries.get(id.string) orelse return error.MissingWriteEntry, submission)) return error.MissingWriteEntry;
    }
}

pub fn checkpoint(a: Allocator, extensions: *const protocol.Extensions, conversation: []const u8, before: Value, after: Value, actions: *std.ArrayList(Action)) !void {
    const scoped = try scopeNamespace(a, conversation);
    const inbox = extensions.get(scoped) orelse return;
    const writes = j.get(after, "write_receipts");
    if (writes == .object and !try protocol.json.equal(a, j.get(before, "write_receipts"), writes)) {
        try actions.append(a, action(scoped, inbox.head, "settle_write", writes));
    }
    if (j.number(j.get(before, "inbox_hold")) != j.number(j.get(after, "inbox_hold"))) {
        var held_writes = j.object();
        var held_inputs = j.object();
        var withdrawn = j.object();
        const withdraw = j.equal(j.get(after, "inbox_failed_policy"), "withdraw");
        for (inbox.value.object.keys(), inbox.value.object.values()) |id, entry| {
            const state = disposition(entry);
            if (state != .pending and state != .claimed) continue;
            if (j.equal(j.get(entry, "kind"), "write") and !held(entry)) {
                try held_writes.object.put(a, id, .null);
            } else if (prompt(entry)) {
                if (withdraw and state == .pending) {
                    try withdrawn.object.put(a, id, j.string("run_failed"));
                } else if (!held(entry)) {
                    try held_inputs.object.put(a, id, .null);
                }
            }
        }
        if (held_writes.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "hold_writes", held_writes));
        if (held_inputs.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "hold_inputs", held_inputs));
        if (withdrawn.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "withdraw", withdrawn));
    }
    try checkpointFollowups(a, scoped, inbox, before, after, actions);
    const reset = j.text(j.get(after, "last_reset"));
    if (reset.len != 0 and !j.equal(j.get(before, "last_reset"), reset)) {
        const entry = j.get(inbox.value, reset);
        const status = disposition(entry);
        if (j.equal(j.get(entry, "kind"), "reset") and (status == .pending or status == .claimed)) {
            var completed = j.object();
            try completed.object.put(a, reset, .null);
            try actions.append(a, action(scoped, inbox.head, "consume", completed));
        }
    }
    const outcome = j.get(after, "submission_outcome");
    const finished = j.text(j.get(outcome, "submission"));
    const existing = j.get(inbox.value, finished);
    if (keyed(finished) and prompt(existing) and disposition(existing) == .consumed and
        !try protocol.json.equal(a, j.get(before, "submission_outcome"), outcome))
    {
        var settled = j.object();
        try settled.object.put(a, finished, j.get(outcome, "run"));
        try actions.append(a, action(scoped, inbox.head, "finish_run", settled));
    }
    const registration = j.text(j.get(after, "last_registration"));
    const datagram = j.get(inbox.value, registration);
    if (registration.len != 0 and !j.equal(j.get(before, "last_registration"), registration) and
        disposition(datagram) == .pending and j.equal(j.get(datagram, "kind"), "register_tools"))
    {
        var settled: Value = .{ .object = .empty };
        try settled.object.put(a, registration, .null);
        const rejected = j.get(j.get(j.get(after, "registration_receipts"), registration), "error") == .string;
        try actions.append(a, action(scoped, inbox.head, if (rejected) "reject" else "consume", settled));
        return;
    }
    const previous = j.text(j.get(j.get(before, "session"), "last_submission"));
    const submission = j.text(j.get(j.get(after, "session"), "last_submission"));
    if (submission.len == 0 or std.mem.eql(u8, previous, submission)) return;
    if (j.get(j.get(after, "final_placements"), submission) == .string) return;
    const status = disposition(j.get(inbox.value, submission));
    if (status != .pending and status != .claimed) return;
    var settled: Value = .{ .object = .empty };
    const entry = j.get(inbox.value, submission);
    if (keyed(submission) and prompt(entry)) {
        const input_entry = j.text(j.get(j.get(j.get(after, "session"), "run"), "input_id"));
        try settled.object.put(a, submission, try j.value(a, .{ .status = RunStatus.running, .input_entry = input_entry }));
        try actions.append(a, action(scoped, inbox.head, "place", settled));
        return;
    }
    try settled.object.put(a, submission, .null);
    try actions.append(a, action(scoped, inbox.head, if (keyed(submission) or status == .claimed) "consume" else "settle", settled));
}

fn checkpointFollowups(a: Allocator, scoped: []const u8, inbox: protocol.Extensions.Entry, before: Value, after: Value, actions: *std.ArrayList(Action)) !void {
    const old_boundary = j.text(j.get(before, "continue_boundary"));
    if (old_boundary.len != 0 and !j.equal(j.get(after, "continue_boundary"), old_boundary)) {
        const joined = j.get(j.get(j.get(after, "session"), "run"), "joined");
        try completeClaims(a, scoped, inbox, old_boundary, joined, actions);
    }
    const final = j.get(after, "final_placements");
    const post_tools = j.get(after, "post_tool_placements");
    const holding = j.number(j.get(before, "inbox_hold")) != j.number(j.get(after, "inbox_hold"));
    if (final == .object and !try protocol.json.equal(a, j.get(before, "final_placements"), final)) {
        try completeClaims(a, scoped, inbox, final_batch, final, actions);
    } else if (holding) {
        try completeClaims(a, scoped, inbox, final_batch, .null, actions);
    }
    if (post_tools == .object and !try protocol.json.equal(a, j.get(before, "post_tool_placements"), post_tools)) {
        try completeClaims(a, scoped, inbox, post_tools_batch, post_tools, actions);
    } else if (holding) {
        try completeClaims(a, scoped, inbox, post_tools_batch, .null, actions);
    }
    const outcomes = j.get(after, "joined_submission_outcomes");
    if (outcomes != .object or try protocol.json.equal(a, j.get(before, "joined_submission_outcomes"), outcomes)) return;
    var finished = j.object();
    for (outcomes.object.keys(), outcomes.object.values()) |id, run| {
        const entry = j.get(inbox.value, id);
        if (keyed(id) and prompt(entry) and disposition(entry) == .consumed) try finished.object.put(a, id, run);
    }
    if (finished.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "finish_run", finished));
}

fn completeClaims(a: Allocator, scoped: []const u8, inbox: protocol.Extensions.Entry, boundary: []const u8, joined: Value, actions: *std.ArrayList(Action)) !void {
    var release = j.object();
    var consumed = j.object();
    var placed = j.object();
    for (inbox.value.object.keys(), inbox.value.object.values()) |id, entry| {
        if (disposition(entry) != .claimed or !j.equal(j.get(entry, "continuation"), boundary)) continue;
        const input_entry = j.text(j.get(joined, id));
        if (input_entry.len == 0) {
            try release.object.put(a, id, j.string(boundary));
        } else if (keyed(id)) {
            try placed.object.put(a, id, try j.value(a, .{ .status = RunStatus.running, .input_entry = input_entry }));
        } else try consumed.object.put(a, id, .null);
    }
    if (release.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "release_followups", release));
    if (consumed.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "consume", consumed));
    if (placed.object.count() != 0) try actions.append(a, action(scoped, inbox.head, "place", placed));
}
