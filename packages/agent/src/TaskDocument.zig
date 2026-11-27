//! Current task-owned documents. Their addresses and edit batches are stored
//! in the task journal and use the same lease as the enclosing transition.
const std = @import("std");
const j = @import("json.zig");
const Frame = @import("session_protocol").frames;
const delta = @import("DocumentDelta.zig");
const Value = j.Value;
const Allocator = std.mem.Allocator;

pub const Address = struct {
    kind: []const u8,
    key: ?[]const u8 = null,

    fn encode(self: Address, a: Allocator) ![]const u8 {
        if (self.kind.len == 0) return error.InvalidTaskDocument;
        return j.encode(a, .{ self.kind, self.key });
    }
};

pub const Version = struct { schema: u32 = 1, value: Value };
pub const Revision = struct { schema: u32, revision: u64 };
pub const Snapshot = struct {
    version: Revision,
    value: Value,
};

pub const Edit = struct {
    address: Address,
    change: union(enum) {
        create: Version,
        patch: struct { expected: Revision, ops: []const Value },
        base: struct { expected: Revision, value: Value },
        migrate: struct { expected: Revision, next: Version },
        retire: Revision,
    },
};

/// Borrowed view. The returned value is valid for the life of the source tree.
pub fn read(a: Allocator, documents: Value, address: Address) !?Snapshot {
    const key = try address.encode(a);
    const item = j.get(documents, key);
    if (item == .null) return null;
    return try std.json.parseFromValueLeaky(Snapshot, a, item, .{});
}

fn expect(a: Allocator, documents: Value, key: []const u8, expected: Revision) !Snapshot {
    const saved = j.get(documents, key);
    if (saved == .null) return error.UnknownTaskDocument;
    const previous = try std.json.parseFromValueLeaky(Snapshot, a, saved, .{});
    if (previous.version.schema != expected.schema or previous.version.revision != expected.revision) {
        return error.StaleTaskDocument;
    }
    return previous;
}

/// Prepare a new document map without changing the published map. The edits'
/// input values and untouched subtrees stay borrowed inside this reducer.
pub fn apply(a: Allocator, documents: *Value, clock: *u64, edits: []const Edit) !void {
    if (edits.len == 0) return;
    var next: Value = if (documents.* == .object) .{ .object = try documents.object.clone(a) } else j.object();
    var revision = clock.*;
    for (edits) |edit| {
        const key = try edit.address.encode(a);
        const version: Version = switch (edit.change) {
            .create => |initial| blk: {
                if (next.object.contains(key)) return error.TaskDocumentExists;
                break :blk initial;
            },
            .patch => |patch| blk: {
                const previous = try expect(a, next, key, patch.expected);
                if (patch.ops.len == 0) continue;
                break :blk .{ .schema = previous.version.schema, .value = try delta.apply(a, previous.value, patch.ops) };
            },
            .base => |base| blk: {
                const previous = try expect(a, next, key, base.expected);
                break :blk .{ .schema = previous.version.schema, .value = base.value };
            },
            .migrate => |migration| blk: {
                const previous = try expect(a, next, key, migration.expected);
                if (migration.next.schema <= previous.version.schema) return error.InvalidTaskDocument;
                break :blk migration.next;
            },
            .retire => |expected| {
                _ = try expect(a, next, key, expected);
                _ = next.object.orderedRemove(key);
                continue;
            },
        };
        if (version.schema == 0 or version.value != .object) return error.InvalidTaskDocument;
        if (revision >= Frame.max_sequence) return error.TaskDocumentRevisionExhausted;
        revision += 1;
        const snapshot: Snapshot = .{ .version = .{ .schema = version.schema, .revision = revision }, .value = version.value };
        try next.object.put(a, key, try j.project(a, snapshot));
    }
    documents.* = if (next.object.count() == 0) .null else next;
    clock.* = revision;
}
