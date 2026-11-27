const std = @import("std");
const j = @import("json.zig");

pub const EntryId = []const u8;
pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
};
pub const Call = struct { id: []const u8, name: []const u8, arguments: j.Value };
pub const Observation = struct { name: []const u8, endpoint: []const u8, arguments: j.Value, result: j.Value, failed: bool };
pub const Entry = struct {
    id: EntryId,
    parent: ?EntryId,
    kind: enum { input, response, program, checkpoint, branch },
    text: []const u8 = "",
    thinking: []const u8 = "",
    model: []const u8 = "",
    usage: ?Usage = null,
    summary_usage: []const Usage = &.{},
    summary_model: []const u8 = "",
    calls: []const Call = &.{},
    observations: []const Observation = &.{},
    result: j.Value = .null,
    metadata: j.Value = .null,
    first_kept: ?EntryId = null,
    failed: bool = false,
};
pub const Snapshot = struct {
    document: j.Document,
    revision: u64,
    head: ?EntryId,
    entries: []const Entry,
    path: []const EntryId,
    checkpoint: ?EntryId,
    context_tokens: u64,
    suspended: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Snapshot {
        return fromDocument(try j.Document.init(gpa, bytes));
    }
    pub fn fromDocument(owned: j.Document) !Snapshot {
        var document = owned;
        errdefer document.deinit();
        const a = document.allocator();
        const value = document.value;
        const records = j.get(value, "entries").array.items;
        const entries = try a.alloc(Entry, records.len);
        for (records, entries) |record, *entry| {
            entry.* = .{
                .id = j.text(j.get(record, "id")),
                .parent = optionalText(j.get(record, "parent")),
                .kind = std.meta.stringToEnum(@FieldType(Entry, "kind"), j.text(j.get(record, "kind"))) orelse return error.InvalidConversation,
                .text = j.text(j.get(record, "text")),
                .thinking = j.text(j.get(record, "thinking")),
                .model = j.text(j.get(record, "model")),
                .summary_model = j.text(j.get(record, "summary_model")),
                .result = j.get(record, "result"),
                .metadata = j.get(record, "metadata"),
                .first_kept = optionalText(j.get(record, "first_kept")),
                .failed = j.flag(j.get(record, "failed")),
            };
            const usage = j.get(record, "usage");
            if (usage == .object) entry.usage = .{ .input_tokens = count(usage, "input_tokens"), .output_tokens = count(usage, "output_tokens"), .total_tokens = count(usage, "total_tokens") };
            const summary_usage = j.get(record, "summary_usage");
            if (summary_usage == .array) {
                const measures = try a.alloc(Usage, summary_usage.array.items.len);
                for (summary_usage.array.items, measures) |measure, *target| target.* = .{ .input_tokens = count(measure, "input_tokens"), .output_tokens = count(measure, "output_tokens"), .total_tokens = count(measure, "total_tokens") };
                entry.summary_usage = measures;
            }
            const calls = j.get(record, "calls");
            if (calls == .array) {
                const out = try a.alloc(Call, calls.array.items.len);
                for (calls.array.items, out) |call, *target| target.* = .{ .id = j.text(j.get(call, "id")), .name = j.text(j.get(call, "name")), .arguments = j.get(call, "arguments") };
                entry.calls = out;
            }
            const effects = j.get(record, "observations");
            if (effects == .array) {
                const out = try a.alloc(Observation, effects.array.items.len);
                for (effects.array.items, out) |effect, *target| target.* = .{ .name = j.text(j.get(effect, "tool_name")), .endpoint = j.text(j.get(effect, "endpoint")), .arguments = j.get(effect, "arguments"), .result = j.get(effect, "result"), .failed = j.flag(j.get(effect, "failed")) };
                entry.observations = out;
            }
        }
        const ids = j.get(value, "path").array.items;
        const path = try a.alloc(EntryId, ids.len);
        for (ids, path) |id, *target| target.* = j.text(id);
        return .{ .document = document, .revision = j.number(j.get(value, "revision")), .head = optionalText(j.get(value, "head")), .entries = entries, .path = path, .checkpoint = optionalText(j.get(value, "checkpoint")), .context_tokens = j.number(j.get(j.get(value, "context_estimate"), "tokens")), .suspended = optionalText(j.get(value, "suspended")) };
    }
    pub fn find(self: Snapshot, id: EntryId) ?*const Entry {
        for (self.entries) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn deinit(self: *Snapshot) void {
        self.document.deinit();
        self.* = undefined;
    }
};
fn optionalText(value: j.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn count(value: j.Value, key: []const u8) ?u64 {
    const n = j.get(value, key);
    return if (n == .integer and n.integer >= 0) @intCast(n.integer) else null;
}

pub const Run = struct {
    input: union(enum) { text: []const u8, continuation: []const u8 },
    model: @import("config.zig").Model = .{},
    context_ceiling: ?u64 = null,
};
pub const SummaryPart = union(enum) { literal: []const u8, generate: struct { instructions: []const u8, input: []const u8 } };
pub const Compact = struct { expected_revision: u64, first_kept: EntryId, parts: []const SummaryPart, model: @import("config.zig").Model, metadata: j.Value = .null };
pub const Branch = struct { expected_revision: u64, at: EntryId };
pub const Boundary = struct { continuation: []const u8, cause: enum { ceiling, provider_overflow }, context_tokens: u64 };

pub const ImportEntry = struct {
    id: EntryId,
    parent: ?EntryId,
    kind: @FieldType(Entry, "kind"),
    text: []const u8 = "",
    model: []const u8 = "",
    usage: j.Value = .null,
    continuation: ?*const @import("provider_continuation.zig").Capsule = null,
    result: j.Value = .null,
    observations: j.Value = .null,
    first_kept: ?EntryId = null,
    metadata: j.Value = .null,
};
pub const Import = struct { entries: []const ImportEntry, head: ?EntryId };

pub fn parseEntryId(text: []const u8) !EntryId {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidEntryId;
    return text;
}
pub fn formatEntryId(a: std.mem.Allocator, id: EntryId) ![]u8 {
    return a.dupe(u8, try parseEntryId(id));
}
