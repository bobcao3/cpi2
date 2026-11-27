const std = @import("std");
const tree = @import("json_tree");
const Frame = @import("SessionFrame.zig");
const Transaction = @import("SessionTransaction.zig");
const Value = Frame.Value;
const Allocator = std.mem.Allocator;
const Store = @This();

pub const Contract = struct {
    version: Frame.Version,
    initial_state: *const fn (Allocator) anyerror!Value,
    validate: *const fn (Value, []const u8, Value) anyerror!void,
    reduce: *const fn (Allocator, Value, []const u8, Value) anyerror!Value,
    validate_transaction: ?*const fn (Allocator, Frame.Frame, *const Transaction) anyerror!void = null,
    /// Check an action against the extensions at the transaction's start.
    /// The frame's namespace value includes any earlier actions in this transaction.
    validate_state: ?*const fn (Allocator, *const Store, Value, Frame.Frame) anyerror!void = null,
    reduce_transaction: ?*const fn (Allocator, Value, Frame.Frame, *const Transaction) anyerror!Value = null,
    /// Reduce a map of encoded JSON strings into a fresh, immutable map header.
    /// Keys and values must come from the replay pool or the previous map.
    replay_strings: ?*const fn (*ReplayStorage, Allocator, Allocator, Value, Value) anyerror!Value = null,
    replay_typed: ?TypedReplay = null,
};
/// An unpublished builder may mutate across actions. Its returned JSON snapshots
/// are immutable, including the subtrees they share with earlier snapshots.
pub const TypedReplay = struct {
    init: *const fn (Allocator, Value) anyerror!*anyopaque,
    step: *const fn (*anyopaque, Allocator, Allocator, Allocator, Value, Value) anyerror!Value,
};
pub const Entry = struct { head: u64, contract: Frame.Version, value: Value, owner: *Owned };
const Owned = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    references: usize = 1,
    value: Value,
    contract: Frame.Version,
    borrows_replay_strings: bool = false,
    typed_builder: ?*anyopaque = null,
    replay: ?*ReplayStorage = null,

    fn create(gpa: Allocator, replay: ?*ReplayStorage) !*Owned {
        if (replay) |pool| if (pool.free_values.pop()) |self| {
            self.references = 1;
            self.borrows_replay_strings = false;
            self.typed_builder = null;
            return self;
        };
        const self = try gpa.create(Owned);
        self.* = .{ .gpa = gpa, .arena = .init(gpa), .value = undefined, .contract = undefined, .replay = replay };
        return self;
    }

    fn init(gpa: Allocator, version: Frame.Version, value: Value) !*Owned {
        const self = try create(gpa, null);
        errdefer self.release();
        self.contract = try ownVersion(self.arena.allocator(), version);
        self.value = try tree.copy(self.arena.allocator(), value);
        return self;
    }
    fn release(self: *Owned) void {
        self.references -= 1;
        if (self.references != 0) return;
        if (self.replay) |pool| {
            if (pool.free_values.items.len < pool.free_values.capacity) {
                _ = self.arena.reset(.{ .retain_with_limit = 64 * 1024 });
                pool.free_values.appendAssumeCapacity(self);
                return;
            }
        }
        self.destroy();
    }

    fn destroy(self: *Owned) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The pool lives through private replay. Final state is compacted once before
/// publication so obsolete journal values and validation entries can be freed.
pub const ReplayStorage = struct {
    const capacity = 12 * 1024 * 1024;
    const EncodedMap = std.HashMapUnmanaged([]const u8, void, EncodedKey, std.hash_map.default_max_load_percentage);
    const EncodedKey = struct {
        pub fn hash(_: @This(), bytes: []const u8) u64 {
            return std.hash_map.hashString(bytes);
        }

        pub fn eql(_: @This(), left: []const u8, right: []const u8) bool {
            return tree.equalBytes(left, right);
        }
    };

    gpa: Allocator,
    buffer: ?std.heap.FixedBufferAllocator = null,
    keys: std.StringHashMapUnmanaged(void) = .empty,
    values: EncodedMap = .empty,
    typed: [2]?std.heap.FixedBufferAllocator = @splat(null),
    typed_index: u1 = 0,
    compact_failed: bool = false,
    value_slots: [8]*Owned = undefined,
    free_values: std.ArrayList(*Owned) = .empty,
    store_slots: [2]*std.heap.ArenaAllocator = undefined,
    free_stores: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    timing: ?Timing = null,

    pub const Timing = struct {
        io: std.Io,
        strings_ns: i96 = 0,
        strings_actions: usize = 0,
        typed_ns: i96 = 0,
        typed_actions: usize = 0,
        other_ns: i96 = 0,
        other_actions: usize = 0,
        intern_lookup_ns: i96 = 0,
        validate_json_ns: i96 = 0,
        unique_values: usize = 0,
    };

    pub fn report(self: *const ReplayStorage) void {
        const timing = self.timing orelse return;
        std.debug.print("journal extension reducers: strings_ns={d} strings_actions={d} typed_ns={d} typed_actions={d} other_ns={d} other_actions={d}\n", .{ timing.strings_ns, timing.strings_actions, timing.typed_ns, timing.typed_actions, timing.other_ns, timing.other_actions });
        std.debug.print("journal extension strings: lookup_ns={d} validate_ns={d} unique_values={d}\n", .{ timing.intern_lookup_ns, timing.validate_json_ns, timing.unique_values });
    }

    pub fn deinit(self: *ReplayStorage) void {
        for (self.free_values.items) |value| value.destroy();
        for (self.free_stores.items) |store| {
            store.deinit();
            self.gpa.destroy(store);
        }
        if (self.buffer) |buffer| self.gpa.free(buffer.buffer);
        for (self.typed) |maybe| if (maybe) |buffer| self.gpa.free(buffer.buffer);
    }

    pub fn init(gpa: Allocator) ReplayStorage {
        return .{ .gpa = gpa };
    }

    // Initialize the list headers only after the storage has a stable address.
    pub fn start(self: *ReplayStorage) void {
        self.free_values = .initBuffer(&self.value_slots);
        self.free_stores = .initBuffer(&self.store_slots);
    }

    fn typedAllocator(self: *ReplayStorage) !Allocator {
        if (self.typed[self.typed_index] == null) {
            self.typed[self.typed_index] = .init(try self.gpa.alloc(u8, typed_capacity));
        }
        return self.typed[self.typed_index].?.allocator();
    }

    const typed_capacity = 8 * 1024 * 1024;

    fn allocator(self: *ReplayStorage) !Allocator {
        if (self.buffer == null) self.buffer = .init(self.gpa.alloc(u8, capacity) catch return error.ReplayStringPoolFull);
        return self.buffer.?.allocator();
    }

    pub fn put(self: *ReplayStorage, output: *Value, retained: Allocator, scratch: Allocator, key: []const u8, json: []const u8) !void {
        const a = try self.allocator();
        const stats = if (self.timing) |*timing| timing else null;
        const started = if (stats) |timing| std.Io.Timestamp.now(timing.io, .awake) else null;
        const known = self.values.getKey(json);
        if (stats) |timing| timing.intern_lookup_ns += started.?.durationTo(.now(timing.io, .awake)).nanoseconds;
        const encoded = known orelse blk: {
            const validation = if (stats) |timing| std.Io.Timestamp.now(timing.io, .awake) else null;
            // Match the ordinary reducers' JSON grammar and duplicate policy.
            try tree.text.validate(scratch, json);
            if (stats) |timing| {
                timing.validate_json_ns += validation.?.durationTo(.now(timing.io, .awake)).nanoseconds;
                timing.unique_values += 1;
            }
            break :blk try intern(a, &self.values, json);
        };
        if (output.object.getPtr(key)) |stored| {
            stored.* = .{ .string = encoded };
        } else {
            const name = self.keys.getKey(key) orelse try intern(a, &self.keys, key);
            try output.object.put(retained, name, .{ .string = encoded });
        }
    }

    fn intern(a: Allocator, map: anytype, string: []const u8) ![]const u8 {
        const owned = a.dupe(u8, string) catch return error.ReplayStringPoolFull;
        errdefer a.free(owned);
        map.putNoClobber(a, owned, {}) catch return error.ReplayStringPoolFull;
        return owned;
    }
};

gpa: Allocator,
arena: *std.heap.ArenaAllocator,
replay: ?*ReplayStorage = null,
session_id: []const u8,
sequence: u64 = 0,
entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,

pub fn init(gpa: Allocator, session_id: []const u8) !Store {
    return initWithReplay(gpa, session_id, null);
}

fn initWithReplay(gpa: Allocator, session_id: []const u8, replay: ?*ReplayStorage) !Store {
    const recycled = if (replay) |pool| pool.free_stores.pop() else null;
    const arena = recycled orelse new: {
        const fresh = try gpa.create(std.heap.ArenaAllocator);
        fresh.* = .init(gpa);
        break :new fresh;
    };
    var result: Store = .{ .gpa = gpa, .arena = arena, .replay = replay, .session_id = undefined };
    errdefer result.releaseArena();
    result.session_id = try arena.allocator().dupe(u8, session_id);
    return result;
}

pub fn deinit(self: *Store) void {
    for (self.entries.values()) |entry| entry.owner.release();
    self.releaseArena();
    self.* = undefined;
}

fn releaseArena(self: *Store) void {
    if (self.replay) |pool| {
        if (pool.free_stores.items.len < pool.free_stores.capacity) {
            _ = self.arena.reset(.{ .retain_with_limit = 16 * 1024 });
            pool.free_stores.appendAssumeCapacity(self.arena);
            return;
        }
    }
    self.arena.deinit();
    self.gpa.destroy(self.arena);
}

/// Borrowed immutable data. Harnesses materialize a separate mutable execution ctx.
pub fn get(self: *const Store, namespace: []const u8) ?Entry {
    return self.entries.get(namespace);
}

/// Namespace values are immutable leases. Reducer scratch never becomes published state.
/// Publish the candidate only after the journal syncs.
pub fn prepare(self: *const Store, transaction: *const Transaction, contracts: []const Contract) !Store {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.prepareWithScratch(transaction, contracts, &scratch);
}

pub fn prepareWithScratch(self: *const Store, transaction: *const Transaction, contracts: []const Contract, scratch: *std.heap.ArenaAllocator) !Store {
    return self.prepareWithReplay(transaction, contracts, scratch, null);
}

pub fn prepareWithReplay(self: *const Store, transaction: *const Transaction, contracts: []const Contract, scratch: *std.heap.ArenaAllocator, strings: ?*ReplayStorage) !Store {
    const first = transaction.frames[0].frame;
    if (!std.mem.eql(u8, first.session_id, self.session_id)) return error.WrongSession;
    if (first.seq != self.sequence + 1) return error.InvalidSequence;
    var next = try self.clone(strings);
    errdefer next.deinit();
    const a = next.arena.allocator();
    for (transaction.frames) |owned| {
        const frame = owned.frame;
        if (frame.action != .@"control.extension") continue;
        const action = frame.action.@"control.extension";
        const old_head = if (self.get(action.namespace)) |old| old.head else 0;
        if (action.expected_head != old_head) return error.StaleExtensionHead;
        const contract = try lookup(contracts, action.input.contract);
        defer _ = scratch.reset(.{ .retain_with_limit = 1024 * 1024 });
        const temporary = scratch.allocator();
        if (contract.validate_transaction) |validate| try validate(temporary, frame, transaction);
        const old = next.get(action.namespace);
        const previous = if (old) |entry| entry.value else try contract.initial_state(temporary);
        const timing = if (strings) |pool| if (pool.timing) |*stats| stats else null else null;
        const started = if (timing) |stats| std.Io.Timestamp.now(stats.io, .awake) else null;
        const result = try self.reduceAction(strings, old, previous, action, contract, temporary, frame, transaction);
        if (timing) |stats| {
            const elapsed = started.?.durationTo(.now(stats.io, .awake)).nanoseconds;
            if (result.borrows_replay_strings) {
                stats.strings_ns += elapsed;
                stats.strings_actions += 1;
            } else if (result.typed_builder != null) {
                stats.typed_ns += elapsed;
                stats.typed_actions += 1;
            } else {
                stats.other_ns += elapsed;
                stats.other_actions += 1;
            }
        }
        const entry: Entry = .{ .head = frame.seq, .contract = result.contract, .value = result.value, .owner = result };
        if (next.entries.getPtr(action.namespace)) |stored| {
            stored.owner.release();
            stored.* = entry;
        } else {
            errdefer result.release();
            try next.entries.put(a, try a.dupe(u8, action.namespace), entry);
        }
    }
    next.sequence = transaction.lastSequence();
    return next;
}

fn reduceAction(self: *const Store, strings: ?*ReplayStorage, old: ?Entry, previous: Value, action: @FieldType(Frame.Action, "control.extension"), contract: Contract, temporary: Allocator, frame: Frame.Frame, transaction: *const Transaction) !*Owned {
    if (strings) |pool| if (contract.replay_typed) |typed| {
        if (contract.reduce_transaction == null and
            (old == null or (old.?.owner.typed_builder != null and sameVersion(old.?.contract, contract.version))))
        {
            try contract.validate(previous, action.action, action.input.value);
            if (contract.validate_state) |validate| try validate(temporary, self, previous, frame);
            if (self.reduceTyped(pool, typed, if (old) |entry| entry.owner.typed_builder else null, previous, action, temporary)) |result| {
                return result;
            } else |err| if (err != error.OutOfMemory) return err;
        }
    };
    if (strings) |pool| if (contract.replay_strings) |reduce| {
        if (contract.reduce_transaction == null and
            (old == null or (old.?.owner.borrows_replay_strings and sameVersion(old.?.contract, contract.version))))
        {
            try contract.validate(previous, action.action, action.input.value);
            if (contract.validate_state) |validate| try validate(temporary, self, previous, frame);
            if (self.reduceStrings(pool, reduce, previous, action, temporary)) |result| {
                return result;
            } else |err| if (err != error.ReplayStringPoolFull) return err;
        }
    };

    const input = try tree.copy(temporary, action.input.value);
    try contract.validate(previous, action.action, input);
    if (contract.validate_state) |validate| try validate(temporary, self, previous, frame);
    const value = if (contract.reduce_transaction) |reduce|
        try reduce(temporary, previous, frame, transaction)
    else
        try contract.reduce(temporary, previous, action.action, input);
    try Frame.validateValue(temporary, value);
    return Owned.init(self.gpa, action.input.contract, value);
}

fn reduceTyped(self: *const Store, pool: *ReplayStorage, typed: TypedReplay, builder: ?*anyopaque, previous: Value, action: @FieldType(Frame.Action, "control.extension"), temporary: Allocator) !*Owned {
    const storage = try pool.typedAllocator();
    const result = try Owned.create(self.gpa, pool);
    errdefer result.release();
    const retained = result.arena.allocator();
    result.contract = try ownVersion(retained, action.input.contract);
    const state = builder orelse try typed.init(storage, previous);
    result.value = try typed.step(state, storage, retained, temporary, previous, action.input.value);
    result.typed_builder = state;
    return result;
}

fn reduceStrings(self: *const Store, pool: *ReplayStorage, reduce: @typeInfo(@FieldType(Contract, "replay_strings")).optional.child, previous: Value, action: @FieldType(Frame.Action, "control.extension"), temporary: Allocator) !*Owned {
    const result = try Owned.create(self.gpa, pool);
    errdefer result.release();
    const retained = result.arena.allocator();
    result.contract = try ownVersion(retained, action.input.contract);
    result.value = try reduce(pool, retained, temporary, previous, action.input.value);
    result.borrows_replay_strings = true;
    return result;
}

pub fn ownReplayValues(self: *Store) !void {
    for (self.entries.values()) |*entry| {
        if (!entry.owner.borrows_replay_strings and entry.owner.typed_builder == null) continue;
        const result = try Owned.init(self.gpa, entry.contract, entry.value);
        entry.owner.release();
        entry.* = .{ .head = entry.head, .contract = result.contract, .value = result.value, .owner = result };
    }
}

pub fn detachReplay(self: *Store) void {
    self.replay = null;
    for (self.entries.values()) |entry| entry.owner.replay = null;
}

/// The just-applied transaction is the last reader of the old immutable
/// views. Compact the live roots before the next action uses the builder.
pub fn compactReplay(self: *Store, pool: *ReplayStorage, contracts: []const Contract) !void {
    if (pool.compact_failed) return;
    const current = pool.typed[pool.typed_index] orelse return;
    if (current.end_index < ReplayStorage.typed_capacity * 3 / 4) return;
    self.compactTyped(pool, contracts) catch |err| switch (err) {
        error.OutOfMemory => pool.compact_failed = true,
        else => return err,
    };
}

fn compactTyped(self: *Store, pool: *ReplayStorage, contracts: []const Contract) !void {
    const slot = ~pool.typed_index;
    const bytes = try pool.gpa.alloc(u8, ReplayStorage.typed_capacity);
    pool.typed[slot] = .init(bytes);
    errdefer {
        pool.gpa.free(bytes);
        pool.typed[slot] = null;
    }
    const storage = pool.typed[slot].?.allocator();
    var next = try self.clone(pool);
    errdefer next.deinit();
    for (next.entries.values()) |*entry| {
        if (entry.owner.typed_builder == null) continue;
        const typed = (try lookup(contracts, entry.contract)).replay_typed.?;
        const new = try Owned.create(self.gpa, pool);
        errdefer new.release();
        new.contract = try ownVersion(new.arena.allocator(), entry.contract);
        new.value = try tree.copy(storage, entry.value);
        new.typed_builder = try typed.init(storage, new.value);
        entry.owner.release();
        entry.* = .{ .head = entry.head, .contract = new.contract, .value = new.value, .owner = new };
    }
    self.deinit();
    self.* = next;
    pool.gpa.free(pool.typed[pool.typed_index].?.buffer);
    pool.typed[pool.typed_index] = null;
    pool.typed_index = slot;
}

fn sameVersion(left: Frame.Version, right: Frame.Version) bool {
    return std.mem.eql(u8, left.id, right.id) and std.mem.eql(u8, left.version, right.version);
}

fn clone(self: *const Store, replay: ?*ReplayStorage) !Store {
    var next = try initWithReplay(self.gpa, self.session_id, replay);
    errdefer next.deinit();
    const a = next.arena.allocator();
    for (self.entries.keys(), self.entries.values()) |key, entry| {
        try next.entries.put(a, try a.dupe(u8, key), entry);
        entry.owner.references += 1;
    }
    next.sequence = self.sequence;
    return next;
}

fn ownVersion(a: Allocator, version: Frame.Version) !Frame.Version {
    return .{ .id = try a.dupe(u8, version.id), .version = try a.dupe(u8, version.version) };
}

fn lookup(contracts: []const Contract, version: Frame.Version) !Contract {
    var found: ?Contract = null;
    for (contracts) |contract| {
        if (sameVersion(contract.version, version)) {
            if (found != null) return error.DuplicateExtensionContract;
            found = contract;
        }
    }
    return found orelse error.MissingExtensionContract;
}

const Counter = struct {
    fn initial(_: Allocator) !Value {
        return .{ .integer = 0 };
    }
    fn validate(_: Value, action: []const u8, input: Value) !void {
        if (!std.mem.eql(u8, action, "add") or input != .integer or input.integer < 0) return error.InvalidCounterAction;
    }
    fn reduce(_: Allocator, previous: Value, _: []const u8, input: Value) !Value {
        return .{ .integer = try std.math.add(i64, previous.integer, input.integer) };
    }
    const contract: Contract = .{ .version = .{ .id = "counter", .version = "1" }, .initial_state = initial, .validate = validate, .reduce = reduce };
};
const counter_frames =
    \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":2},"class":"control","op":"control.extension","actor":{"kind":"host","id":"host"},"cause":null,"data":{"namespace":"private","expected_head":0,"action":"add","input":{"contract":{"id":"counter","version":"1"},"value":1}}}
    \\{"v":1,"session_id":"test","seq":2,"tx":{"id":"t1","index":1,"count":2},"class":"control","op":"control.extension","actor":{"kind":"host","id":"host"},"cause":null,"data":{"namespace":"private","expected_head":0,"action":"add","input":{"contract":{"id":"counter","version":"1"},"value":2}}}
    \\
;

test "opaque scalar state reduces sequentially against transaction-entry heads" {
    var state = try init(std.testing.allocator, "test");
    defer state.deinit();
    var transaction = try Transaction.parse(std.testing.allocator, "test", 1, counter_frames, .{});
    defer transaction.deinit();
    var candidate = try state.prepare(&transaction, &.{Counter.contract});
    defer candidate.deinit();
    try std.testing.expect(state.get("private") == null);
    try std.testing.expectEqual(@as(u64, 0), state.sequence);
    try std.testing.expectEqual(@as(i64, 3), candidate.get("private").?.value.integer);
    try std.testing.expectEqual(@as(u64, 2), candidate.get("private").?.head);
}

test "missing contracts and failed reducers publish no state" {
    var state = try init(std.testing.allocator, "test");
    defer state.deinit();
    var transaction = try Transaction.parse(std.testing.allocator, "test", 1, counter_frames, .{});
    defer transaction.deinit();
    try std.testing.expectError(error.MissingExtensionContract, state.prepare(&transaction, &.{}));
    const Reject = struct {
        fn validate(_: Value, _: []const u8, _: Value) !void {
            return error.DeniedPrivateAction;
        }
    };
    var rejected = Counter.contract;
    rejected.validate = Reject.validate;
    try std.testing.expectError(error.DeniedPrivateAction, state.prepare(&transaction, &.{rejected}));
    const FailSecond = struct {
        fn reduce(a: Allocator, previous: Value, action: []const u8, input: Value) !Value {
            if (input.integer == 2) return error.SecondReductionFailed;
            return Counter.reduce(a, previous, action, input);
        }
    };
    rejected = Counter.contract;
    rejected.reduce = FailSecond.reduce;
    try std.testing.expectError(error.SecondReductionFailed, state.prepare(&transaction, &.{rejected}));
    try std.testing.expect(state.get("private") == null);
    try std.testing.expectEqual(@as(u64, 0), state.sequence);
}

test "allocation failures in candidate preparation preserve the base" {
    const Case = struct {
        fn run(a: Allocator) !void {
            var state = try init(a, "test");
            defer state.deinit();
            var transaction = try Transaction.parse(a, "test", 1, counter_frames, .{});
            defer transaction.deinit();
            var candidate = try state.prepare(&transaction, &.{Counter.contract});
            defer candidate.deinit();
            try std.testing.expect(state.get("private") == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
