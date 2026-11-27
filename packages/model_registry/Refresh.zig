//! Account-scoped refresh cache. The caller owns scheduling and publication;
//! workers own request memory and only signal completion. The catalog is read-only.
const std = @import("std");
const registry = @import("root.zig");
const discovery = registry.discovery;
const Self = @This();
const Io = std.Io;
const Allocator = std.mem.Allocator;

a: Allocator,
io: Io,
wake: Notification,
policy: Policy,
loader: Loader = .{},
targets: []const discovery.Target = &.{},
entries: []Entry = &.{},

pub const Policy = struct {
    fresh_for: Io.Duration,
    retry_after: Io.Duration,
    parallelism: usize,
};

/// Optional harness adapter for additional provider protocols. Runs off-thread;
/// returned models must remain valid until the supplied scratch arena is reset.
pub const Loader = struct {
    context: ?*anyopaque = null,
    list: *const fn (?*anyopaque, Allocator, Io, discovery.Target, registry.SizeSink) anyerror!discovery.Listing = defaultList,

    fn defaultList(_: ?*anyopaque, a: Allocator, io: Io, target: discovery.Target, warnings: registry.SizeSink) !discovery.Listing {
        return discovery.discover(a, io, target.route, target.reference, warnings);
    }
};

pub const Notification = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque) void,
};

const Key = [32]u8;
fn key(target: discovery.Target) Key {
    const record = target.route;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&.{@backingInt(record.kind)});
    for ([_][]const u8{ std.mem.trimEnd(u8, record.base_url, "/"), record.account_id orelse "", record.token }) |part| {
        hash.update(std.mem.asBytes(&part.len));
        hash.update(part);
    }
    return hash.finalResult();
}

const Entry = struct {
    key: ?Key,
    due: ?Io.Timestamp = null,
    start_failure: ?anyerror = null,
    pending: ?*Job = null,
    result: ?*Job = null,

    fn deinit(self: Entry, a: Allocator, io: Io) void {
        if (self.pending) |job| job.destroy(a, io);
        if (self.result) |job| job.destroy(a, io);
    }
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    listing: registry.discovery.Listing = .{ .models = &.{} },

    fn start(self: *Self, target: discovery.Target, warnings: registry.SizeSink) !*Job {
        const job = try self.a.create(Job);
        errdefer self.a.destroy(job);
        job.* = .{ .arena = .init(self.a) };
        const a = job.arena.allocator();
        errdefer job.arena.deinit();
        const record = target.route;
        // Copy only the credential fields required by GET /models. This job
        // can outlive its dialog, the auth document, or the current session.
        const owned: discovery.Route = .{
            .kind = record.kind,
            .base_url = try a.dupe(u8, record.base_url),
            .token = try a.dupe(u8, record.token),
            .account_id = if (record.account_id) |id| try a.dupe(u8, id) else null,
        };
        errdefer std.crypto.secureZero(u8, @constCast(owned.token));
        job.future = try self.io.concurrent(run, .{ job, self.io, discovery.Target{ .route = owned, .reference = target.reference }, self.wake, warnings, self.loader });
        return job;
    }

    fn run(self: *Job, io: Io, target: discovery.Target, wake: Notification, warnings: registry.SizeSink, loader: Loader) void {
        defer wake.notify(wake.context);
        defer self.done.set(io);
        defer std.crypto.secureZero(u8, @constCast(target.route.token));
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const listing = loader.list(loader.context, scratch.allocator(), io, target, warnings) catch |err| {
            self.listing.fallback_reason = err;
            return;
        };
        if (listing.fallback_reason) |err| {
            self.listing.fallback_reason = err;
            return;
        }
        self.listing.models = self.ownModels(listing.models) catch |err| {
            self.listing.fallback_reason = err;
            return;
        };
    }

    fn ownModels(self: *Job, models: []const registry.Model) ![]const registry.Model {
        const a = self.arena.allocator();
        const owned = try a.alloc(registry.Model, models.len);
        for (models, owned) |model, *out| out.* = try registry.cloneModel(a, model);
        return owned;
    }

    fn destroy(self: *Job, a: Allocator, io: Io) void {
        self.future.cancel(io);
        self.arena.deinit();
        a.destroy(self);
    }
};

pub fn deinit(self: *Self) void {
    for (self.entries) |entry| entry.deinit(self.a, self.io);
    self.a.free(self.entries);
    self.entries = &.{};
    self.targets = &.{};
}

/// Transfer in-flight work and cache entries only for unchanged credentials and
/// reference data. Borrow the immutable target array and providers until the
/// next successful reconciliation or deinit. Workers copy their route strings.
pub fn reconcile(self: *Self, targets: []const discovery.Target) !void {
    const next = try self.a.alloc(Entry, targets.len);
    for (targets, next) |target, *entry| {
        const identity = key(target);
        entry.* = .{ .key = identity };
        for (self.entries, self.targets) |*old, previous| {
            const previous_key = old.key orelse continue;
            if (previous.reference == target.reference and std.mem.eql(u8, &previous_key, &identity)) {
                entry.* = old.*;
                old.* = .{ .key = null };
                break;
            }
        }
    }
    self.deinit();
    self.targets = targets;
    self.entries = next;
}

pub const Update = struct { changed: bool = false, deadline: ?Io.Timestamp = null };

/// Harvest notification-driven results, then fill free slots from due routes.
/// A healthy empty list gets the same lifetime as any other successful result.
pub fn advance(self: *Self, warnings: registry.SizeSink) Update {
    const now = Io.Timestamp.now(self.io, .awake);
    var update: Update = .{};
    var running: usize = 0;
    for (self.entries) |*entry| {
        const job = entry.pending orelse continue;
        if (!job.done.isSet()) {
            running += 1;
            continue;
        }
        job.future.await(self.io);
        if (entry.result) |previous| previous.destroy(self.a, self.io);
        entry.result = job;
        entry.pending = null;
        entry.start_failure = null;
        entry.due = now.addDuration(if (job.listing.fallback_reason == null) self.policy.fresh_for else self.policy.retry_after);
        update.changed = true;
    }
    while (running < @max(1, self.policy.parallelism)) {
        const index = self.nextDue() orelse break;
        const entry = &self.entries[index];
        if (entry.due) |due| {
            if (now.compare(.lt, due)) {
                update.deadline = due;
                break;
            }
        }
        entry.pending = Job.start(self, self.targets[index], warnings) catch |err| {
            if (entry.result) |previous| previous.destroy(self.a, self.io);
            entry.result = null;
            entry.start_failure = err;
            entry.due = now.addDuration(self.policy.retry_after);
            update.changed = true;
            // Wait for capacity rather than spinning on a failed launch.
            update.deadline = entry.due;
            break;
        };
        running += 1;
    }
    return update;
}

fn nextDue(self: *const Self) ?usize {
    var best: ?usize = null;
    for (self.entries, 0..) |entry, index| {
        if (entry.pending != null) continue;
        const due = entry.due orelse return index;
        if (best == null or due.compare(.lt, self.entries[best.?].due.?)) best = index;
    }
    return best;
}

/// A listing borrows data until the next advance, reconcile, or deinit.
/// Null means no result yet; a successful empty list is not null.
pub fn offer(self: *const Self, index: usize) ?discovery.Listing {
    const entry = self.entries[index];
    const listing: discovery.Listing = if (entry.result) |job| job.listing else .{ .models = &.{}, .fallback_reason = entry.start_failure };
    if (listing.fallback_reason) |err| {
        return .{ .models = if (self.targets[index].reference) |p| p.models else &.{}, .fallback_reason = err };
    }
    return if (entry.result != null) listing else null;
}
