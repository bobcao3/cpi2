const std = @import("std");
pub const json = @import("json.zig");
pub const Operation = @import("Operation.zig");
pub const Process = @import("process.zig");
pub const Files = @import("Files.zig");
pub const HttpResponseReader = @import("HttpResponseReader.zig");
pub const output = @import("output.zig");
pub const SizeWarning = struct {
    operation: []const u8,
    measurement: []const u8,
    actual: u64,
    threshold: u64,
    request_id: []const u8,
    principal: u64,
};
pub const ModelDeferred = struct { adapter: []const u8, handle: std.json.Value };
pub const ModelProgress = struct {
    response_id: []const u8 = "",
    cursor: u64,
    next_poll_ms: ?u64 = null,
    poll_failures: ?u8 = null,
    reattach: ?enum { stream } = null,
    deferred: ?ModelDeferred = null,
};
pub const ModelResume = struct {
    route: []const u8,
    credential: []const u8,
    progress: ModelProgress,
};
pub const ModelProgressSink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, ModelProgress) anyerror!void,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    idempotency_key: []const u8 = "",
    principal: u64 = 0,
    scope: u64 = 0,
    request_id: []const u8 = "",
    effect_id: u64 = 0,
    /// Host-supplied model session identity borrowed for the admitted call.
    model_session_id: ?[]const u8 = null,
    model_progress: ?ModelProgressSink = null,
    model_resume: ?ModelResume = null,
    immediate_model: bool = false,
    model_attempt_key: []const u8 = "",
    model_selection: ?std.json.Value = null,
    defer_model_poll: bool = false,
    size_warnings: ?struct {
        context: *anyopaque,
        notify: *const fn (*anyopaque, SizeWarning) void,
    } = null,

    pub fn warnSize(self: Context, operation: []const u8, measurement: []const u8, actual: u64, threshold: u64) void {
        if (actual <= threshold) return;
        const event: SizeWarning = .{ .operation = operation, .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = self.request_id, .principal = self.principal };
        if (self.size_warnings) |sink| sink.notify(sink.context, event) else logSizeWarning(event);
    }
};

pub fn logSizeWarning(event: SizeWarning) void {
    std.log.warn("{s} {s} is {d}, above the expected {d}", .{ event.operation, event.measurement, event.actual, event.threshold });
}
pub const Service = struct {
    context: *anyopaque,
    operations: []const *const Operation,
    release: ?*const fn (*anyopaque, Context) anyerror!void = null,
};
pub const Binding = struct { context: *anyopaque, operation: *const Operation };
const expected_endpoint_name_bytes = 256;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    operations: std.StringHashMapUnmanaged(Binding) = .empty,
    frozen: bool = false,
    releases: std.ArrayList(Service) = .empty,
    /// A controller can defer reporting until its event sink is ready.
    defer_registration_warnings: bool = false,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.operations.deinit(self.allocator);
        self.releases.deinit(self.allocator);
    }

    pub fn freeze(self: *Registry) void {
        self.frozen = true;
    }

    pub fn add(self: *Registry, service: Service) !void {
        if (self.frozen) return error.RegistryFrozen;
        for (service.operations, 0..) |operation, i| {
            if (operation.name.len == 0 or operation.limits.arguments == 0 or operation.limits.result == 0) return error.InvalidOperation;
            if (self.operations.contains(operation.name)) return error.DuplicateEndpoint;
            for (service.operations[0..i]) |prior| if (std.mem.eql(u8, prior.name, operation.name)) return error.DuplicateEndpoint;
        }
        try self.operations.ensureUnusedCapacity(self.allocator, @intCast(service.operations.len));
        if (service.release) |release| {
            var found = false;
            for (self.releases.items) |existing| if (existing.context == service.context and existing.release == release) {
                found = true;
                break;
            };
            if (!found) try self.releases.append(self.allocator, service);
        }
        for (service.operations) |operation| {
            self.operations.putAssumeCapacity(operation.name, .{ .context = service.context, .operation = operation });
            if (!self.defer_registration_warnings and operation.name.len > expected_endpoint_name_bytes) {
                logSizeWarning(.{ .operation = "service registration", .measurement = "endpoint name bytes", .actual = operation.name.len, .threshold = expected_endpoint_name_bytes, .request_id = "", .principal = 0 });
            }
        }
    }

    pub fn reportRegistrationSizes(self: *const Registry, context: Context) void {
        var names = self.operations.keyIterator();
        while (names.next()) |name| context.warnSize("service registration", "endpoint name bytes", name.len, expected_endpoint_name_bytes);
    }

    pub fn remove(self: *Registry, service: Service) !void {
        if (self.frozen) return error.RegistryFrozen;
        for (service.operations) |operation| if (self.operations.get(operation.name)) |existing| {
            if (existing.context == service.context and existing.operation == operation) _ = self.operations.remove(operation.name);
        };
        var bindings = self.operations.valueIterator();
        while (bindings.next()) |binding| if (binding.context == service.context) return;
        var index: usize = 0;
        while (index < self.releases.items.len) {
            if (self.releases.items[index].context == service.context) _ = self.releases.swapRemove(index) else index += 1;
        }
    }

    pub fn releaseAll(self: *Registry, context: Context) !void {
        var failure: ?anyerror = null;
        for (self.releases.items) |service| service.release.?(service.context, context) catch |err| {
            if (failure == null) failure = err;
        };
        self.releases.clearRetainingCapacity();
        if (failure) |err| return err;
    }

    pub fn resolve(self: *const Registry, endpoint: []const u8) !*const Operation {
        return (self.operations.get(endpoint) orelse return error.UnsupportedEndpoint).operation;
    }

    pub fn validate(self: *const Registry, context: Context, endpoint: []const u8, args: json.Value) !*const Operation {
        const operation = try self.resolve(endpoint);
        try operation.validate_arguments(context.allocator, args);
        return operation;
    }

    pub fn dispatchGranted(self: *const Registry, context: Context, grants: []const *const Operation, endpoint: []const u8, args: json.Value) !json.Value {
        const operation = try self.resolve(endpoint);
        for (grants) |grant| if (grant == operation) return self.dispatch(context, endpoint, args);
        return error.PermissionDenied;
    }

    pub fn dispatch(self: *const Registry, context: Context, endpoint: []const u8, args: json.Value) !json.Value {
        try context.io.checkCancel();
        const operation = try self.validate(context, endpoint, args);
        context.warnSize(endpoint, "argument JSON nesting depth", try json.depth(context.allocator, args), json.expected_depth);
        context.warnSize(endpoint, "argument bytes", try encodedSize(context.allocator, args), operation.limits.arguments);
        const binding = self.operations.get(endpoint).?;
        const result = try operation.call(binding.context, context, args);
        operation.validate_result(context.allocator, result) catch return error.InvalidServiceResult;
        context.warnSize(endpoint, "result JSON nesting depth", try json.depth(context.allocator, result), json.expected_depth);
        context.warnSize(endpoint, "result bytes", try encodedSize(context.allocator, result), operation.limits.result);
        return result;
    }
};

fn encodedSize(a: std.mem.Allocator, value: json.Value) !u64 {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer.Discarding = .init(&buffer);
    try json.write(a, &writer.writer, value);
    return writer.fullCount();
}

test "service groups can be attached and removed without replacing another group" {
    const testing = std.testing;
    var process: Process = .{ .workspace = "/tmp", .directory = "/tmp/unused", .binary = "ghostmux", .environment = undefined };
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.add(process.service());
    try testing.expectError(error.DuplicateEndpoint, registry.add(process.service()));
    try registry.remove(process.service());
    try testing.expectError(error.UnsupportedEndpoint, registry.dispatch(.{ .allocator = testing.allocator, .io = testing.io }, "process.list", .{ .object = .empty }));
    registry.freeze();
    try testing.expectError(error.RegistryFrozen, registry.add(process.service()));
}

pub const Exec = @import("Exec.zig");
test {
    _ = Exec;
    _ = Files;
    _ = @import("contract_tests.zig");
}
