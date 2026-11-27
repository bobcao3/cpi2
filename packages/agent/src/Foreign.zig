const std = @import("std");
const api = @import("abi");
const Runtime = @import("Runtime.zig");
const j = @import("json.zig");
const event_types = @import("events.zig");
const types = @import("config.zig");
const port = @import("port.zig");
const Foreign = @This();
const backing = std.heap.c_allocator;
const MemoryBudget = @import("vm").MemoryBudget;

const Operation = struct {
    id: u64,
    done: std.Io.Event = .unset,
    terminal: bool = false,
    cancelled: bool = false,
    kind: u32 = api.CPI_AGENT_IO_DONE,
    data: std.ArrayList(u8) = .empty,
    meta: ?j.Document = null,
    result: []u8 = &.{},
};

gpa: std.mem.Allocator,
budget: *MemoryBudget,
backend: std.Io.Threaded,
io: std.Io,
runtime: *Runtime,
mutex: std.Io.Mutex = .init,
events: std.ArrayList(*event_types.Event) = .empty,
operations: std.ArrayList(*Operation) = .empty,
next_lease: u64 = 1,
next_operation: u64 = 1,

pub fn slice(bytes: api.cpi_agent_bytes) ![]const u8 {
    if (bytes.len == 0) return "";
    if (bytes.ptr == null) return error.InvalidArgument;
    return bytes.ptr[0..bytes.len];
}
fn span(bytes: []const u8) api.cpi_agent_bytes {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

fn obsolete(name: []const u8) bool {
    inline for (.{ "max_record_bytes", "max_journal_bytes", "max_records", "max_ctx_bytes", "max_response_bytes", "max_vm_bytes", "max_vm_input_bytes", "max_program_bytes" }) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}
fn hasObsolete(value: j.Value) bool {
    switch (value) {
        .object => |object| {
            var entries = object.iterator();
            while (entries.next()) |entry| {
                if (obsolete(entry.key_ptr.*) or hasObsolete(entry.value_ptr.*)) return true;
            }
        },
        .array => |array| for (array.items) |item| if (hasObsolete(item)) return true,
        else => {},
    }
    return false;
}
fn memoryBytes(options: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const parsed = try j.parse(arena.allocator(), options);
    if (hasObsolete(parsed)) return error.InvalidArgument;
    const resource = try budgetValue(j.get(j.get(parsed, "resources"), "memory_bytes"));
    const limit = try budgetValue(j.get(j.get(parsed, "limits"), "memory_bytes"));
    if (resource != null and limit != null and resource.? != limit.?) return error.InvalidArgument;
    return resource orelse limit orelse types.default_memory_bytes;
}
fn budgetValue(value: j.Value) !?usize {
    if (value == .null) return null;
    if (value != .integer or value.integer <= 0) return error.InvalidArgument;
    const bytes = std.math.cast(usize, value.integer) orelse return error.InvalidArgument;
    if (bytes == 0) return error.InvalidArgument;
    return bytes;
}

pub fn init(config: *const api.cpi_agent_config, seed: j.Value) !*Foreign {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const id = try slice(config.session_id);
    const workspace = try slice(config.workspace);
    const uri = try slice(config.journal_uri);
    if (std.Uri.parse(uri)) |parsed| {
        if (!std.mem.eql(u8, parsed.scheme, "file")) return error.InvalidArgument;
    } else |_| {}
    const options = try slice(config.options_json);
    const budget = try MemoryBudget.createAdvisory(backing, try memoryBytes(options));
    errdefer budget.release();
    const charged = budget.allocator();
    const self = try charged.create(Foreign);
    errdefer charged.destroy(self);
    self.* = .{ .gpa = charged, .budget = budget, .backend = .init(charged, .{}), .io = undefined, .runtime = undefined };
    self.io = self.backend.io();
    errdefer self.backend.deinit();
    errdefer {
        for (self.events.items) |event| event.deinit(charged);
        self.events.deinit(charged);
        self.operations.deinit(charged);
    }
    const path = if (std.mem.startsWith(u8, uri, "file:")) blk: {
        const parsed = std.Uri.parse(uri) catch return error.InvalidArgument;
        if (!std.mem.eql(u8, parsed.scheme, "file") or parsed.query != null or parsed.fragment != null) return error.InvalidArgument;
        if (parsed.host) |host| if (!std.mem.eql(u8, host.toRawMaybeAlloc(arena.allocator()) catch return error.InvalidArgument, "localhost")) return error.InvalidArgument;
        break :blk try parsed.path.toRawMaybeAlloc(arena.allocator());
    } else uri;
    self.runtime = try Runtime.openRaw(charged, self.io, id, workspace, path, options, seed, .{
        .context = self,
        .exchange = exchange,
        .journal_size_warnings = .{ .context = self, .notify = journalWarning },
        .application_size_warnings = .{ .context = self, .notify = applicationWarning },
    });
    return self;
}

fn notify(context: ?*anyopaque, notice: types.Notice) !void {
    const self: *Foreign = @ptrCast(@alignCast(context.?));
    var document = try j.Document.init(self.gpa, notice.json);
    defer document.deinit();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.budget.takeWarning()) |warning| self.sizeWarning("memory", "allocated bytes", warning.actual, warning.threshold, notice.request_id);
    try self.emit(@backingInt(notice.kind), 0, notice.sequence, notice.request_id, "", document.value);
}

fn journalWarning(context: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    const self: *Foreign = @ptrCast(@alignCast(context.?));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.sizeWarning("session journal", measurement, actual, threshold, "");
}

fn applicationWarning(context: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
    const self: *Foreign = @ptrCast(@alignCast(context.?));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.sizeWarning("harness application", measurement, actual, threshold, "");
}

pub fn registryWarnings(self: *Foreign, memory: MemoryBudget.Usage, longest_name: usize) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (memory.peak > memory.limit) self.sizeWarning("capability registry", "allocated bytes", memory.peak, memory.limit, "");
    if (longest_name > types.expected_capability_name_bytes) {
        self.sizeWarning("capability registry", "capability name bytes", longest_name, types.expected_capability_name_bytes, "");
    }
}

fn sizeWarning(self: *Foreign, operation: []const u8, measurement: []const u8, actual: usize, threshold: usize, request_id: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const value = j.project(arena.allocator(), .{ .kind = "size_warning", .operation = operation, .measurement = measurement, .actual = actual, .threshold = threshold }) catch {
        std.log.warn("{s} {s} is {d}, above the expected {d}", .{ operation, measurement, actual, threshold });
        return;
    };
    self.emit(api.CPI_AGENT_EVENT_PROGRESS, 0, 0, request_id, "", value) catch {
        std.log.warn("{s} {s} is {d}, above the expected {d}", .{ operation, measurement, actual, threshold });
    };
}

fn emit(self: *Foreign, kind: u32, operation: u64, sequence: u64, request: []const u8, method: []const u8, value: j.Value) !void {
    const event = try event_types.Event.init(self.gpa, self.next_lease, kind, operation, sequence, request, method, value);
    errdefer event.deinit(self.gpa);
    try self.events.append(self.gpa, event);
    self.next_lease += 1;
}

fn exchange(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, event: port.Event) !?port.Response {
    return switch (event) {
        .notice => |notice| blk: {
            try notify(context, notice);
            break :blk null;
        },
        .request => |request| try call(@ptrCast(@alignCast(context)), allocator, io, if (request.method == .model) "http.request" else "rpc.call", .{ .request_id = request.request_id, .json = request.json }),
    };
}

fn call(self: *Foreign, allocator: std.mem.Allocator, io: std.Io, method: []const u8, request: types.AdapterRequest) !types.AdapterResponse {
    var document = try j.Document.init(self.gpa, request.json);
    defer document.deinit();
    const operation = try self.gpa.create(Operation);
    self.mutex.lockUncancelable(io);
    operation.* = .{ .id = self.next_operation };
    self.next_operation += 1;
    self.operations.append(self.gpa, operation) catch |err| {
        self.mutex.unlock(io);
        self.gpa.destroy(operation);
        return err;
    };
    self.emit(api.CPI_AGENT_EVENT_IO_REQUEST, operation.id, 0, request.request_id, method, document.value) catch |err| {
        _ = self.operations.pop();
        self.mutex.unlock(io);
        self.gpa.destroy(operation);
        return err;
    };
    self.mutex.unlock(io);
    defer {
        self.mutex.lockUncancelable(io);
        for (self.operations.items, 0..) |entry, index| if (entry == operation) {
            _ = self.operations.swapRemove(index);
            break;
        };
        self.mutex.unlock(io);
        operation.data.deinit(self.gpa);
        if (operation.meta) |*meta| meta.deinit();
        self.gpa.free(operation.result);
        self.gpa.destroy(operation);
    }
    operation.done.wait(io) catch |err| {
        self.mutex.lockUncancelable(io);
        operation.cancelled = true;
        self.emit(api.CPI_AGENT_EVENT_IO_CANCEL, operation.id, 0, "", "", .null) catch {};
        self.mutex.unlock(io);
        operation.done.waitUncancelable(io);
        return err;
    };
    if (operation.kind == api.CPI_AGENT_IO_CANCELLED) return error.Canceled;
    const result = if (operation.kind == api.CPI_AGENT_IO_DONE and operation.data.items.len > 0) blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const terminal = try j.parse(arena.allocator(), if (operation.result.len == 0) "{}" else operation.result);
        if (j.get(terminal, "body") != .null) break :blk try allocator.dupe(u8, operation.result);
        const body = try j.parse(arena.allocator(), operation.data.items);
        break :blk try j.encode(allocator, .{ .body = body, .status = if (operation.meta) |meta| j.get(meta.value, "status") else j.integer(200) });
    } else try allocator.dupe(u8, if (operation.result.len == 0) "{}" else operation.result);
    return .{ .json = result, .failed = operation.kind != api.CPI_AGENT_IO_DONE };
}

pub fn admit(self: *Foreign, id: []const u8, kind: u32, payload: []const u8) !void {
    const request = try self.runtime.submitRaw(id, kind, payload);
    request.deinit();
}
pub fn run(self: *Foreign, transitions: u32, instructions: u32, out: *api.cpi_agent_schedule) !void {
    if (transitions == 0 or instructions == 0) return error.InvalidArgument;
    out.* = .{ .struct_size = @sizeOf(api.cpi_agent_schedule), .disposition = self.runtime.barrier(), .wake_at_unix_ms = 0 };
}

pub fn nextEvent(self: *Foreign, out: *api.cpi_agent_event) u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.events.items) |event| {
        if (event.delivered) continue;
        event.delivered = true;
        const value = event.value;
        out.* = .{ .struct_size = @sizeOf(api.cpi_agent_event), .kind = value.kind, .lease_id = value.lease_id, .operation_id = value.operation_id, .sequence = value.sequence, .request_id = span(value.request_id), .method = span(value.method), .json = span(value.json) };
        return api.CPI_AGENT_OK;
    }
    return api.CPI_AGENT_NO_EVENT;
}
pub fn release(self: *Foreign, lease: u64) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.events.items, 0..) |event, index| {
        if (event.value.lease_id != lease or !event.delivered) continue;
        _ = self.events.orderedRemove(index);
        event.deinit(self.gpa);
        return;
    }
    return error.StaleEvent;
}

pub fn feed(self: *Foreign, id: u64, kind: u32, data: []const u8) !void {
    if (kind < 1 or kind > 5) return error.InvalidArgument;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.operations.items) |operation| {
        if (operation.id != id or operation.terminal) continue;
        if (kind == api.CPI_AGENT_IO_META) {
            var replacement = try j.Document.init(self.gpa, data);
            errdefer replacement.deinit();
            if (operation.meta) |*meta| meta.deinit();
            operation.meta = replacement;
        } else if (kind == api.CPI_AGENT_IO_DATA) {
            try operation.data.appendSlice(self.gpa, data);
        } else {
            operation.result = try self.gpa.dupe(u8, data);
            operation.kind = kind;
            operation.terminal = true;
            operation.done.set(self.io);
        }
        return;
    }
    return error.StaleOperation;
}

pub fn deinit(self: *Foreign) void {
    self.runtime.destroy();
    for (self.events.items) |event| event.deinit(self.gpa);
    self.events.deinit(self.gpa);
    self.operations.deinit(self.gpa);
    self.backend.deinit();
    const gpa = self.gpa;
    const budget = self.budget;
    gpa.destroy(self);
    budget.release();
}
