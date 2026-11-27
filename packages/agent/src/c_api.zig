const std = @import("std");
const api = @import("abi");
const W = @import("Foreign.zig");
const j = @import("json.zig");
const types = @import("config.zig");
const gpa = std.heap.c_allocator;
const vm = @import("vm");
const bytes = W.slice;
const MemoryBudget = vm.MemoryBudget;

const Registry = struct {
    gpa: std.mem.Allocator,
    budget: *MemoryBudget,
    arena: std.heap.ArenaAllocator,
    capabilities: j.Value,
    longest_name: usize = 0,
};

fn worker(handle: *api.cpi_agent) *W {
    return @ptrCast(@alignCast(handle));
}

fn registry(handle: *api.cpi_agent_registry) *Registry {
    return @ptrCast(@alignCast(handle));
}

fn status(err: anyerror) api.cpi_agent_status {
    return switch (err) {
        error.OutOfMemory => api.CPI_AGENT_OUT_OF_MEMORY,
        error.InvalidArgument => api.CPI_AGENT_INVALID_ARGUMENT,
        error.InvalidState => api.CPI_AGENT_INVALID_STATE,
        error.RequestConflict => api.CPI_AGENT_REQUEST_CONFLICT,
        error.LimitExceeded, error.EventBackpressure, error.JournalRecordTooLarge, error.JournalStateTooLarge, error.JournalCapacityExceeded, error.JournalReplayLimitExceeded, error.SequenceExhausted => api.CPI_AGENT_LIMIT_EXCEEDED,
        error.StaleOperation => api.CPI_AGENT_STALE_OPERATION,
        error.StaleEvent => api.CPI_AGENT_STALE_EVENT,
        error.InvalidExtension => api.CPI_AGENT_INVALID_EXTENSION,
        error.JournalLocked => api.CPI_AGENT_JOURNAL_LOCKED,
        error.InvalidJournal, error.JournalReadFailed, error.JournalCommitUncertain, error.MissingExtensionContract, error.MissingRenderer, error.JournalLinkedFile, error.InputOutput, error.NoSpaceLeft, error.DiskQuota, error.DirectorySyncFailed => api.CPI_AGENT_STORAGE_ERROR,
        error.ConcurrencyUnavailable => api.CPI_AGENT_CONCURRENCY_UNAVAILABLE,
        else => api.CPI_AGENT_INVALID_JSON,
    };
}

export fn cpi_agent_abi_version() u32 {
    return api.CPI_AGENT_ABI_VERSION;
}

export fn cpi_agent_registry_create(version: u32, output: ?*?*api.cpi_agent_registry) api.cpi_agent_status {
    const out = output orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    out.* = null;
    if (version != api.CPI_AGENT_ABI_VERSION) return api.CPI_AGENT_ABI_MISMATCH;
    const budget = MemoryBudget.createAdvisory(gpa, types.default_memory_bytes) catch |err| return status(err);
    const charged = budget.allocator();
    const value = charged.create(Registry) catch |err| {
        budget.release();
        return status(err);
    };
    value.* = .{ .gpa = charged, .budget = budget, .arena = .init(charged), .capabilities = undefined };
    value.capabilities = j.array(value.arena.allocator());
    out.* = @ptrCast(value);
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_registry_add_lua(handle: ?*api.cpi_agent_registry, source_name: api.cpi_agent_bytes, source: api.cpi_agent_bytes) api.cpi_agent_status {
    const r = registry(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    defer if (r.budget.takeWarning()) |warning| {
        std.log.warn("capability registry allocated bytes is {d}, above the expected {d}", .{ warning.actual, warning.threshold });
    };
    const name_bytes = bytes(source_name) catch |err| return status(err);
    const source_bytes = bytes(source) catch |err| return status(err);
    if (source_bytes.len == 0) return api.CPI_AGENT_INVALID_EXTENSION;
    const metadata = vm.describe(r.gpa, source_bytes) catch |err| return if (err == error.OutOfMemory) status(err) else api.CPI_AGENT_INVALID_EXTENSION;
    defer r.gpa.free(metadata);
    var parsed = j.Document.init(r.gpa, metadata) catch |err| return status(err);
    defer parsed.deinit();
    const descriptor = parsed.value;
    const name = j.text(j.get(descriptor, "name"));
    if (name.len == 0) return api.CPI_AGENT_INVALID_EXTENSION;
    for (r.capabilities.array.items) |capability| if (std.mem.eql(u8, j.text(j.get(capability, "name")), name)) return api.CPI_AGENT_DUPLICATE_CAPABILITY;
    const a = r.arena.allocator();
    var entry = j.object();
    j.put(a, &entry, "name", j.string(a.dupe(u8, name) catch return api.CPI_AGENT_OUT_OF_MEMORY)) catch |err| return status(err);
    j.put(a, &entry, "source", j.string(a.dupe(u8, source_bytes) catch return api.CPI_AGENT_OUT_OF_MEMORY)) catch |err| return status(err);
    j.put(a, &entry, "source_name", j.string(a.dupe(u8, name_bytes) catch return api.CPI_AGENT_OUT_OF_MEMORY)) catch |err| return status(err);
    j.put(a, &entry, "descriptor", j.copy(a, descriptor) catch |err| return status(err)) catch |err| return status(err);
    const hash = j.sourceHash(source_bytes);
    j.put(a, &entry, "source_hash", j.string(a.dupe(u8, &hash) catch return api.CPI_AGENT_OUT_OF_MEMORY)) catch |err| return status(err);
    r.capabilities.array.append(entry) catch |err| return status(err);
    r.longest_name = @max(r.longest_name, name.len);
    if (name.len > types.expected_capability_name_bytes) {
        std.log.warn("capability name bytes is {d}, above the expected {d}", .{ name.len, types.expected_capability_name_bytes });
    }
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_registry_destroy(handle: ?*api.cpi_agent_registry) void {
    if (handle) |pointer| {
        const r = registry(pointer);
        r.arena.deinit();
        const budget = r.budget;
        const charged = budget.allocator();
        charged.destroy(r);
        budget.release();
    }
}

export fn cpi_agent_open(initial: ?*const api.cpi_agent_registry, config: ?*const api.cpi_agent_config, output: ?*?*api.cpi_agent) api.cpi_agent_status {
    const out = output orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    out.* = null;
    const options = config orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    if (options.abi_version != api.CPI_AGENT_ABI_VERSION or options.struct_size != @sizeOf(api.cpi_agent_config)) return api.CPI_AGENT_ABI_MISMATCH;
    var empty = j.array(gpa);
    defer empty.array.deinit();
    const builder = if (initial) |pointer| registry(@constCast(pointer)) else null;
    const seed = if (builder) |r| r.capabilities else empty;
    const value = W.init(options, seed) catch |err| return status(err);
    if (builder) |r| value.registryWarnings(r.budget.usage(), r.longest_name);
    out.* = @ptrCast(value);
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_send(handle: ?*api.cpi_agent, command: ?*const api.cpi_agent_command) api.cpi_agent_status {
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    const value = command orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    if (value.struct_size != @sizeOf(api.cpi_agent_command) or value.kind < 1 or value.kind > 5) return api.CPI_AGENT_INVALID_ARGUMENT;
    self.admit(bytes(value.request_id) catch |err| return status(err), value.kind, bytes(value.payload_json) catch |err| return status(err)) catch |err| return status(err);
    return api.CPI_AGENT_OK;
}

fn dynamic(handle: ?*api.cpi_agent, id: api.cpi_agent_bytes, kind: u32, source_name: api.cpi_agent_bytes, source: api.cpi_agent_bytes) api.cpi_agent_status {
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    const request_id = bytes(id) catch |err| return status(err);
    const name = bytes(source_name) catch |err| return status(err);
    const code = bytes(source) catch |err| return status(err);
    if (request_id.len == 0 or !std.unicode.utf8ValidateSlice(request_id)) return api.CPI_AGENT_INVALID_ARGUMENT;
    const payload = if (kind == 6)
        j.encode(self.gpa, .{ .source_name = name, .source = code }) catch |err| return status(err)
    else
        j.encode(self.gpa, .{ .name = name }) catch |err| return status(err);
    defer self.gpa.free(payload);
    self.admit(request_id, kind, payload) catch |err| return status(err);
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_register_lua(handle: ?*api.cpi_agent, id: api.cpi_agent_bytes, source_name: api.cpi_agent_bytes, source: api.cpi_agent_bytes) api.cpi_agent_status {
    return dynamic(handle, id, 6, source_name, source);
}

export fn cpi_agent_unregister_capability(handle: ?*api.cpi_agent, id: api.cpi_agent_bytes, name: api.cpi_agent_bytes) api.cpi_agent_status {
    return dynamic(handle, id, 7, name, .{ .ptr = null, .len = 0 });
}

export fn cpi_agent_run(handle: ?*api.cpi_agent, now_unix_ms: u64, transitions: u32, instructions: u32, output: ?*api.cpi_agent_schedule) api.cpi_agent_status {
    _ = now_unix_ms;
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    const out = output orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    if (out.struct_size != @sizeOf(api.cpi_agent_schedule)) return api.CPI_AGENT_INVALID_ARGUMENT;
    self.run(transitions, instructions, out) catch |err| {
        if (err == error.InvalidArgument) return api.CPI_AGENT_INVALID_ARGUMENT;
        out.* = .{ .struct_size = @sizeOf(api.cpi_agent_schedule), .disposition = api.CPI_AGENT_FAILED, .wake_at_unix_ms = 0 };
    };
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_next_event(handle: ?*api.cpi_agent, output: ?*api.cpi_agent_event) api.cpi_agent_status {
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    const out = output orelse return api.CPI_AGENT_INVALID_ARGUMENT;
    if (out.struct_size != @sizeOf(api.cpi_agent_event)) return api.CPI_AGENT_INVALID_ARGUMENT;
    return @intCast(self.nextEvent(out));
}

export fn cpi_agent_event_release(handle: ?*api.cpi_agent, lease: u64) api.cpi_agent_status {
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    self.release(lease) catch |err| return status(err);
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_io_feed(handle: ?*api.cpi_agent, operation: u64, kind: u32, data: api.cpi_agent_bytes) api.cpi_agent_status {
    const self = worker(handle orelse return api.CPI_AGENT_INVALID_ARGUMENT);
    self.feed(operation, kind, bytes(data) catch |err| return status(err)) catch |err| return status(err);
    return api.CPI_AGENT_OK;
}

export fn cpi_agent_destroy(handle: ?*api.cpi_agent) void {
    if (handle) |pointer| worker(pointer).deinit();
}
