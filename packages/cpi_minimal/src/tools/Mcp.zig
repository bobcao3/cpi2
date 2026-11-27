const std = @import("std");
const services = @import("services");
const mcp = @import("mcp");
const j = @import("../json.zig");

const Value = j.Value;

pub fn service(gateway: *mcp.Gateway) services.Service {
    return .{
        .context = gateway,
        .operations = &.{
            &servers_operation,
            &tools_operation,
            &describe_server_operation,
            &describe_tool_operation,
            &call_operation,
            &resources_operation,
            &read_resource_operation,
        },
    };
}

fn dispatch(raw: ?*anyopaque, c: services.Context, endpoint: []const u8, args: Value) !Value {
    const gateway: *mcp.Gateway = @ptrCast(@alignCast(raw.?));
    try c.io.checkCancel();
    if (std.mem.eql(u8, endpoint, "mcp.servers")) return gateway.status(c.allocator);
    if (std.mem.eql(u8, endpoint, "mcp.tools")) {
        const refresh = j.get(args, "refresh");
        return gateway.toolCatalog(c.allocator, c.io, j.text(j.get(args, "server")), refresh == .bool and refresh.bool);
    }
    if (std.mem.eql(u8, endpoint, "mcp.describe_server")) return gateway.describeServer(c.allocator, c.io, j.text(j.get(args, "server")));
    if (std.mem.eql(u8, endpoint, "mcp.describe_tool")) return gateway.describeTool(c.allocator, c.io, j.text(j.get(args, "server")), j.text(j.get(args, "tool")));
    if (std.mem.eql(u8, endpoint, "mcp.call")) {
        const arguments = j.get(args, "arguments");
        return gateway.call(c.allocator, c.io, j.text(j.get(args, "server")), j.text(j.get(args, "tool")), if (arguments == .null) j.object() else arguments);
    }
    if (std.mem.eql(u8, endpoint, "mcp.resources.list")) return gateway.listResources(c.allocator, c.io, j.text(j.get(args, "server")), j.text(j.get(args, "cursor")));
    if (std.mem.eql(u8, endpoint, "mcp.resources.read")) return gateway.readResource(c.allocator, c.io, j.text(j.get(args, "server")), j.text(j.get(args, "uri")));
    return error.UnsupportedEndpoint;
}

const limits_small: services.Operation.Limits = .{ .arguments = 1024 * 1024, .result = 4 * 1024 * 1024 };
const limits_call: services.Operation.Limits = .{ .arguments = 16 * 1024 * 1024, .result = 32 * 1024 * 1024 };

const servers_operation = services.Operation.defineJson("mcp.servers", j.Value, j.Value, limits_small, .read_only, dispatch);
const tools_operation = services.Operation.defineJson("mcp.tools", j.Value, j.Value, limits_small, .read_only, dispatch);
const describe_server_operation = services.Operation.defineJson("mcp.describe_server", j.Value, j.Value, limits_small, .read_only, dispatch);
const describe_tool_operation = services.Operation.defineJson("mcp.describe_tool", j.Value, j.Value, limits_small, .read_only, dispatch);
const call_operation = services.Operation.defineJson("mcp.call", j.Value, j.Value, limits_call, .never, dispatch);
const resources_operation = services.Operation.defineJson("mcp.resources.list", j.Value, j.Value, limits_small, .read_only, dispatch);
const read_resource_operation = services.Operation.defineJson("mcp.resources.read", j.Value, j.Value, limits_small, .read_only, dispatch);
