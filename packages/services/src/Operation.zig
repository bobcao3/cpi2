const std = @import("std");
const root = @import("root.zig");
const j = root.json;
const Operation = @This();

pub const Limits = struct { arguments: usize, result: usize };
pub const Recovery = enum { read_only, receipt, never };

name: []const u8,
limits: Limits,
recovery: Recovery,
validate_arguments: *const fn (std.mem.Allocator, j.Value) anyerror!void,
validate_result: *const fn (std.mem.Allocator, j.Value) anyerror!void,
arguments_schema: *const fn (std.mem.Allocator) anyerror!j.Value,
result_schema: *const fn (std.mem.Allocator) anyerror!j.Value,
call: *const fn (*anyopaque, root.Context, j.Value) anyerror!j.Value,

pub fn define(comptime name: []const u8, comptime Owner: type, comptime Args: type, comptime Result: type, comptime limits: Limits, comptime recovery: Recovery, comptime implementation: fn (*Owner, root.Context, Args) anyerror!Result) Operation {
    const Bridge = struct {
        fn call(pointer: *anyopaque, context: root.Context, value: j.Value) !j.Value {
            const args = try std.json.parseFromValueLeaky(Args, context.allocator, value, .{ .allocate = .alloc_always });
            const result = try implementation(@ptrCast(@alignCast(pointer)), context, args);
            return j.value(context.allocator, result);
        }
    };
    return declaration(name, Args, Result, limits, recovery, Bridge.call);
}

pub fn defineJson(comptime name: []const u8, comptime Args: type, comptime Result: type, comptime limits: Limits, comptime recovery: Recovery, comptime implementation: fn (*anyopaque, root.Context, []const u8, j.Value) anyerror!j.Value) Operation {
    const Bridge = struct {
        fn call(pointer: *anyopaque, context: root.Context, value: j.Value) !j.Value {
            return implementation(pointer, context, name, value);
        }
    };
    return declaration(name, Args, Result, limits, recovery, Bridge.call);
}

fn declaration(comptime name: []const u8, comptime Args: type, comptime Result: type, comptime limits: Limits, comptime recovery: Recovery, comptime call: *const fn (*anyopaque, root.Context, j.Value) anyerror!j.Value) Operation {
    const Contract = struct {
        fn arguments(a: std.mem.Allocator, value: j.Value) !void {
            try validate(Args, a, value);
        }
        fn result(a: std.mem.Allocator, value: j.Value) !void {
            try validate(Result, a, value);
        }
        fn argsSchema(a: std.mem.Allocator) !j.Value {
            return schema(Args, a);
        }
        fn resultSchema(a: std.mem.Allocator) !j.Value {
            return schema(Result, a);
        }
    };
    return .{ .name = name, .limits = limits, .recovery = recovery, .validate_arguments = Contract.arguments, .validate_result = Contract.result, .arguments_schema = Contract.argsSchema, .result_schema = Contract.resultSchema, .call = call };
}

fn validate(comptime T: type, a: std.mem.Allocator, value: j.Value) anyerror!void {
    try shape(T, value);
    const parsed = std.json.parseFromValueLeaky(T, a, value, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.InvalidSchema;
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) try parsed.validate();
}

fn shape(comptime T: type, value: j.Value) anyerror!void {
    if (T == j.Value) return;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (value != .object) return error.InvalidSchema;
            var fields = value.object.iterator();
            while (fields.next()) |field| {
                var known = false;
                inline for (info.field_names, info.field_types) |name, Field| if (std.mem.eql(u8, name, field.key_ptr.*)) {
                    known = true;
                    try shape(Field, field.value_ptr.*);
                };
                if (!known) return error.InvalidSchema;
            }
        },
        .optional => |info| if (value != .null) {
            try shape(info.child, value);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("operation contracts require slices");
            if (info.child == u8) {
                if (value != .string) return error.InvalidSchema;
            } else {
                if (value != .array) return error.InvalidSchema;
                for (value.array.items) |item| try shape(info.child, item);
            }
        },
        .bool => if (value != .bool) return error.InvalidSchema,
        .int => if (value != .integer) return error.InvalidSchema,
        .float => if (value != .float and value != .integer) return error.InvalidSchema,
        .@"enum" => if (value != .string) return error.InvalidSchema,
        else => @compileError("unsupported operation contract type: " ++ @typeName(T)),
    }
}

fn schema(comptime T: type, a: std.mem.Allocator) anyerror!j.Value {
    if (T == j.Value) return .{ .object = .empty };
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var properties: j.Value = .{ .object = .empty };
            var required: j.Value = .{ .array = std.json.Array.init(a) };
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                try j.put(a, &properties, name, try schema(Field, a));
                if (attrs.default_value_ptr == null) try required.array.append(.{ .string = name });
            }
            break :blk j.value(a, .{ .type = "object", .properties = properties, .required = required, .additionalProperties = false });
        },
        .optional => |info| j.value(a, .{ .anyOf = .{ try schema(info.child, a), try j.value(a, .{ .type = "null" }) } }),
        .pointer => |info| if (info.child == u8) j.value(a, .{ .type = "string" }) else j.value(a, .{ .type = "array", .items = try schema(info.child, a) }),
        .bool => j.value(a, .{ .type = "boolean" }),
        .int => j.value(a, .{ .type = "integer" }),
        .float => j.value(a, .{ .type = "number" }),
        .@"enum" => |info| blk: {
            var values: j.Value = .{ .array = std.json.Array.init(a) };
            inline for (info.field_names) |name| try values.array.append(.{ .string = name });
            break :blk j.value(a, .{ .type = "string", .@"enum" = values });
        },
        else => @compileError("unsupported operation contract type"),
    };
}
