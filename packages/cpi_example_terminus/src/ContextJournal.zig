const std = @import("std");
const protocol = @import("session_protocol");
const tree = protocol.json;
const Value = protocol.frames.Value;
const Allocator = std.mem.Allocator;

pub const namespace = "cpi-terminus.ctx";
pub const action = "capture";
pub const contract: protocol.Extensions.Contract = .{
    .version = .{ .id = "cpi-terminus.ctx", .version = "1" },
    .initial_state = initial,
    .validate = validate,
    .reduce = reduce,
};

pub const binding_namespace = "cpi-terminus.binding";
pub const binding_contract: protocol.Extensions.Contract = .{
    .version = .{ .id = binding_namespace, .version = "1" },
    .initial_state = bindingInitial,
    .validate = bindingValidate,
    .reduce = bindingReduce,
};
fn bindingInitial(_: Allocator) !Value {
    return .null;
}
fn bindingValidate(previous: Value, name: []const u8, input: Value) !void {
    if (previous != .null or !std.mem.eql(u8, name, "bind") or input != .string) return error.InvalidTerminusBinding;
}
fn bindingReduce(_: Allocator, _: Value, _: []const u8, input: Value) !Value {
    return input;
}

pub const renderer: protocol.State.Renderer = .{ .version = .{ .id = "cpi-terminus.responses", .version = "1" }, .render = render };
fn render(a: Allocator, snapshot: protocol.State.Snapshot, _: Value) !protocol.State.Projection {
    var messages: Value = .{ .array = .init(a) };
    for (try snapshot.messages(a)) |message| {
        var text: std.ArrayList(u8) = .empty;
        for (message.content) |part| {
            if (part.object.get("type")) |kind| if (kind == .string and std.mem.eql(u8, kind.string, "text")) try text.appendSlice(a, part.object.get("text").?.string);
        }
        var item: Value = .{ .object = .empty };
        try item.object.put(a, "role", .{ .string = @tagName(message.role) });
        try item.object.put(a, "content", .{ .string = text.items });
        try messages.array.append(item);
    }
    const kwargs = (try snapshot.model(a)).action.@"control.set_model".kwargs;
    return .{ .instructions = kwargs.object.get("instructions") orelse .{ .string = "" }, .messages = messages, .tools = .{ .array = .init(a) } };
}

pub fn capture(a: Allocator, before: Value, after: Value) !?Value {
    if (before != .object or after != .object) return error.InvalidTerminusContext;
    if (try tree.equal(a, before, after)) return null;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    tree.write(a, &output.writer, after) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return .{ .string = try output.toOwnedSlice() };
}

pub fn materialize(a: Allocator, state: Value) !Value {
    if (state != .string) return error.InvalidTerminusContext;
    const value = try protocol.json.text.parseFromSliceLeaky(Value, a, state.string, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = state.string.len,
    });
    if (value != .object) return error.InvalidTerminusContext;
    return value;
}

fn initial(_: Allocator) !Value {
    return .{ .string = "{}" };
}
fn validate(previous: Value, name: []const u8, input: Value) !void {
    if (!std.mem.eql(u8, name, action) or previous != .string or input != .string) return error.InvalidTerminusContext;
}
fn reduce(a: Allocator, _: Value, _: []const u8, input: Value) !Value {
    _ = try materialize(a, input);
    return input;
}

test "Terminus captures private ctx as its own encoded whole-state value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try materialize(a, .{ .string = "{\"state\":{\"turn\":1,\"children\":[]}}" });
    const after = try materialize(a, .{ .string = "{\"state\":{\"turn\":2,\"children\":[\"summary-1\"]},\"helper\":\"source\"}" });
    const change = (try capture(a, before, after)).?;
    try protocol.frames.validateValue(a, change);
    try contract.validate(try initial(a), action, change);
    const state = try contract.reduce(a, try initial(a), action, change);
    try std.testing.expect(state == .string);
    try std.testing.expect(try tree.equal(a, after, try materialize(a, state)));
    try std.testing.expect((try capture(a, after, after)) == null);
}

test "Terminus rejects invalid private shapes and unknown actions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidTerminusContext, materialize(a, .{ .string = "[]" }));
    try std.testing.expectError(error.InvalidTerminusContext, contract.validate(try initial(a), "unknown", .{ .string = "{}" }));
}
