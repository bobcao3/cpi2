const std = @import("std");
const json_text = @import("json_tree").text;
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const SizeSink = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, []const u8, usize, usize) void = logWarning,

    pub fn report(self: SizeSink, measurement: []const u8, actual: usize, threshold: usize) void {
        if (actual > threshold) self.notify(self.context, measurement, actual, threshold);
    }

    fn logWarning(_: ?*anyopaque, measurement: []const u8, actual: usize, threshold: usize) void {
        std.log.warn("session {s} is {d}, above the expected {d}", .{ measurement, actual, threshold });
    }
};

pub const max_sequence: u64 = 9007199254740991;
pub const max_frame_bytes: usize = 8 * 1024 * 1024;

pub const Class = enum { capability, control, document };
pub const Role = enum { system, developer, user, assistant, tool };
pub const Status = enum { completed, failed, cancelled, interrupted };
pub const Recovery = enum { never, retry_safe, reconcile };
pub const EffectStatus = enum { completed, failed, cancelled, indeterminate };
pub const Version = struct { id: []const u8, version: []const u8 };
pub const HarnessValue = struct { contract: Version, value: Value };
pub const Endpoint = struct { name: []const u8, binding: u64 };
pub const Placement = struct { context: []const u8, after: ?[]const u8 };
pub const ContextBase = struct {
    context: []const u8,
    at: u64,
    through: ?[]const u8 = null,
    /// Exact historical selection and its logical parent, which can itself
    /// have inherited the entry from the context that wrote it.
    fork: ?struct { parent: []const u8, anchor: u64, selected: []const []const u8 } = null,
};
pub const Provenance = struct { source: []const u8, sha256: []const u8 };
pub const ToolCall = struct { id: []const u8, name: []const u8, arguments: Value };
pub const ContentPart = Value;
pub const Message = struct {
    id: []const u8,
    role: Role,
    content: []const ContentPart,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};
pub const MessageAppend = struct {
    message: Message,
    placement: ?Placement,
    request: ?[]const u8 = null,
    source: ?u64 = null,
    provenance: ?Provenance = null,
    display_only: ?bool = null,
};
pub const Edit = union(enum) {
    drop: []const []const u8,
    insert: struct { after: ?[]const u8, ids: []const []const u8 },

    const Drop = struct { op: enum { drop }, ids: []const []const u8 };
    const Insert = struct { op: enum { insert }, after: ?[]const u8, ids: []const []const u8 };

    fn check(value: Value) anyerror!void {
        if (value != .object) return error.InvalidMutation;
        const op = value.object.get("op") orelse return error.MissingField;
        if (op != .string) return error.InvalidMutation;
        if (std.mem.eql(u8, op.string, "drop")) return shape(Drop, value);
        if (std.mem.eql(u8, op.string, "insert")) return shape(Insert, value);
        return error.InvalidMutation;
    }

    pub fn jsonParseFromValue(a: Allocator, value: Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Edit {
        check(value) catch return error.UnexpectedToken;
        if (std.mem.eql(u8, value.object.get("op").?.string, "drop")) {
            const drop = try std.json.parseFromValueLeaky(Drop, a, value, options);
            return .{ .drop = drop.ids };
        }
        const insert = try std.json.parseFromValueLeaky(Insert, a, value, options);
        return .{ .insert = .{ .after = insert.after, .ids = insert.ids } };
    }
};
pub const Action = union(enum) {
    @"capability.bind": struct { name: []const u8, service: Version, config: Value },
    @"capability.unbind": struct { name: []const u8, binding: u64 },
    @"control.set_model": struct { provider: []const u8, model: []const u8, route: []const u8, credential_ref: ?[]const u8, adapter: Version, kwargs: Value, selection: ?Value = null },
    @"control.provider_tool.register": struct { name: []const u8, definition: Value, handler: ?HarnessValue },
    @"control.provider_tool.deregister": struct { name: []const u8, registration: u64 },
    @"control.extension": struct { namespace: []const u8, expected_head: u64, action: []const u8, input: HarnessValue },
    @"document.message.append": MessageAppend,
    @"control.context.create": struct { id: []const u8, base: ?ContextBase },
    @"control.context.select": struct { context: []const u8 },
    @"control.document_mutation": struct { context: []const u8, expected_head: u64, edits: []const Edit },
    @"control.model.request": struct { request_id: []const u8, input_at: u64, context: []const u8, conversation: ?[]const u8 = null, model_frame: u64, renderer: Version, kwargs: Value, instructions_sha256: []const u8, messages_sha256: []const u8, tools_sha256: []const u8 },
    @"control.model.progress": struct {
        request_id: []const u8,
        response_id: []const u8,
        cursor: u64,
        next_poll_ms: ?u64 = null,
        poll_failures: ?u8 = null,
        reattach: ?enum { stream } = null,
        deferred: ?struct { adapter: []const u8, handle: Value } = null,
    },
    @"control.model.finish": struct { request_id: []const u8, status: Status, usage: Value, diagnostic: Value },
    @"control.effect.intent": struct { effect_id: []const u8, endpoint: Endpoint, arguments: Value, source_message: ?[]const u8, key: []const u8, recovery: Recovery },
    @"control.effect.result": struct { effect_id: []const u8, status: EffectStatus, result: Value },
    @"control.cancel": struct { target: u64, reason: []const u8 },

    pub fn class(self: Action) Class {
        const name = @tagName(self);
        if (std.mem.startsWith(u8, name, "capability.")) return .capability;
        if (std.mem.startsWith(u8, name, "document.")) return .document;
        return .control;
    }
};
pub const Transaction = struct { id: []const u8, index: u64, count: u64 };
pub const Actor = struct { kind: enum { host, user, agent, service }, id: []const u8 };
const Envelope = struct { v: u8, session_id: []const u8, seq: u64, tx: Transaction, class: Class, op: []const u8, actor: Actor, cause: ?u64, data: Value };
const EnvelopeField = std.meta.FieldEnum(Envelope);
const Cursor = json_text.Cursor;
pub const Frame = struct {
    session_id: []const u8,
    seq: u64,
    tx: Transaction,
    actor: Actor,
    cause: ?u64,
    action: Action,
};

/// The transaction owns its arena and any input referenced by this frame.
pub const Decoded = struct {
    frame: Frame,
    data: Value,
    order: [@typeInfo(EnvelopeField).@"enum".field_names.len]EnvelopeField,

    pub fn decode(a: Allocator, scratch: Allocator, bytes: []const u8, sink: ?SizeSink) !Decoded {
        return decodeEnvelope(false, a, scratch, bytes, sink);
    }

    /// Strings can reference the line, with escapes decoded into consumed bytes.
    pub fn decodeInPlace(a: Allocator, scratch: Allocator, bytes: []u8, sink: ?SizeSink) !Decoded {
        return decodeEnvelope(true, a, scratch, bytes, sink);
    }

    fn decodeEnvelope(comptime in_place: bool, a: Allocator, scratch: Allocator, bytes: if (in_place) []u8 else []const u8, sink: ?SizeSink) !Decoded {
        var window: Cursor.Window = undefined;
        var cursor = Cursor.init(bytes, &window, scratch);
        defer cursor.deinit();
        var order: @FieldType(Decoded, "order") = undefined;
        const wire = try readRecord(Envelope, in_place, a, scratch, &cursor, bytes, &order);
        try cursor.finish();
        return .{ .frame = try decodeFrame(a, wire, sink), .data = wire.data, .order = order };
    }

    fn readRecord(comptime T: type, comptime in_place: bool, a: Allocator, scratch: Allocator, cursor: *Cursor, bytes: if (in_place) []u8 else []const u8, order: ?[]std.meta.FieldEnum(T)) anyerror!T {
        const Field = std.meta.FieldEnum(T);
        cursor.beginObject() catch |err| return if (err == error.UnexpectedToken) error.InvalidPayload else err;
        var wire: T = undefined;
        var seen: std.EnumSet(Field) = .empty;
        var count: usize = 0;
        while (try cursor.nextField()) |key| {
            const field = std.meta.stringToEnum(Field, key) orelse return error.UnknownField;
            if (seen.contains(field)) return error.DuplicateField;
            seen.insert(field);
            if (order) |fields| fields[count] = field;
            count += 1;
            switch (field) {
                inline else => |f| {
                    const name = @tagName(f);
                    const Child = @FieldType(T, name);
                    @field(wire, name) = if (Child == Transaction or Child == Actor) blk: {
                        break :blk try readRecord(Child, in_place, a, scratch, cursor, bytes, null);
                    } else blk: {
                        const value = if (in_place)
                            try parseValueInPlace(a, scratch, cursor, bytes)
                        else
                            try cursor.read(Value, a, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
                        if (!in_place) try validateValue(scratch, value);
                        try shape(Child, value);
                        break :blk try borrowed(Child, a, value);
                    };
                },
            }
        }
        if (count != @typeInfo(Field).@"enum".field_names.len) return error.MissingField;
        return wire;
    }

    /// The accepted envelope has a fixed schema. Rebuild its JSON wrapper only
    /// for callers that need a complete document; the original payload remains
    /// intact (including explicit defaults and numeric kinds).
    pub fn documentValue(self: Decoded, a: Allocator) !Value {
        const frame = self.frame;
        const wire: Envelope = .{
            .v = 1,
            .session_id = frame.session_id,
            .seq = frame.seq,
            .tx = frame.tx,
            .class = frame.action.class(),
            .op = @tagName(frame.action),
            .actor = frame.actor,
            .cause = frame.cause,
            .data = self.data,
        };
        var fields: std.json.ObjectMap = .empty;
        try fields.ensureTotalCapacity(a, self.order.len);
        for (self.order) |field| switch (field) {
            inline else => |f| {
                const name = @tagName(f);
                fields.putAssumeCapacityNoClobber(name, try @import("json_tree").fromAny(a, @field(wire, name)));
            },
        };
        return .{ .object = fields };
    }
};

pub const Owned = struct {
    document: std.json.Parsed(Value),
    frame: Frame,

    pub fn parse(gpa: Allocator, bytes: []const u8, max_bytes: usize) !Owned {
        if (bytes.len > max_bytes) std.log.warn("session frame bytes is {d}, above the expected {d}", .{ bytes.len, max_bytes });
        return decode(gpa, bytes);
    }

    pub fn decode(gpa: Allocator, bytes: []const u8) !Owned {
        return decodeObserved(gpa, bytes, .{});
    }

    pub fn decodeObserved(gpa: Allocator, bytes: []const u8, sink: ?SizeSink) !Owned {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        var buffer: [4096]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, gpa);
        const result = try Decoded.decode(arena.allocator(), scratch.allocator(), bytes, sink);
        return .{ .document = .{ .arena = arena, .value = try result.documentValue(arena.allocator()) }, .frame = result.frame };
    }

    pub fn deinit(self: *Owned) void {
        self.document.deinit();
        self.* = undefined;
    }
};

fn decodeFrame(a: Allocator, wire: Envelope, sink: ?SizeSink) !Frame {
    if (wire.v != 1) return error.UnsupportedFrameVersion;
    try id(sink, wire.session_id);
    try id(sink, wire.tx.id);
    try id(sink, wire.actor.id);
    try reference(wire.seq);
    if (wire.tx.count == 0 or wire.tx.index >= wire.tx.count) return error.InvalidTransaction;
    if (wire.cause) |cause| if (cause == 0 or cause >= wire.seq) return error.InvalidReference;
    const action = try decodeAction(a, wire.op, wire.data);
    if (action.class() != wire.class) return error.InvalidFrameClass;
    try validate(sink, action);
    return .{
        .session_id = wire.session_id,
        .seq = wire.seq,
        .tx = wire.tx,
        .actor = wire.actor,
        .cause = wire.cause,
        .action = action,
    };
}

const ParseContainer = struct {
    value: Value,
    key: ?[]const u8 = null,
};

fn parseValueInPlace(a: Allocator, scratch: Allocator, cursor: *Cursor, bytes: []u8) !Value {
    var stack: std.ArrayList(ParseContainer) = .empty;
    defer stack.deinit(scratch);
    while (true) {
        const token = try cursor.nextInPlace(bytes);
        if (token == .string and stack.items.len != 0) {
            const parent = &stack.items[stack.items.len - 1];
            if (parent.value == .object and parent.key == null) {
                parent.key = token.string;
                continue;
            }
        }
        const value: Value = switch (token) {
            .string => |text| .{ .string = text },
            .object_begin, .array_begin => {
                try stack.append(scratch, .{ .value = if (token == .object_begin) .{ .object = .empty } else .{ .array = .init(a) } });
                continue;
            },
            .object_end, .array_end => stack.pop().?.value,
            .number => |encoded| try parseNumber(encoded),
            .null => .null,
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .end_of_document => return error.UnexpectedEndOfInput,
            else => unreachable,
        };
        if (stack.items.len == 0) return value;
        const parent = &stack.items[stack.items.len - 1];
        switch (parent.value) {
            .array => try parent.value.array.append(value),
            .object => {
                const entry = try parent.value.object.getOrPut(a, parent.key.?);
                if (entry.found_existing) return error.DuplicateField;
                entry.value_ptr.* = value;
                parent.key = null;
            },
            else => unreachable,
        }
    }
}

fn parseNumber(bytes: []const u8) !Value {
    const value = Value.parseFromNumberSlice(bytes);
    switch (value) {
        .integer => |number| if (number < -@as(i64, max_sequence) or number > max_sequence) return error.InvalidJsonDomain,
        .float => |number| if (!std.math.isFinite(number)) return error.InvalidJsonDomain,
        .number_string => return error.InvalidJsonDomain,
        else => unreachable,
    }
    return value;
}

/// Copies protocol values into the caller's lifetime, including opaque JSON.
pub fn copy(comptime T: type, a: Allocator, value: T) Allocator.Error!T {
    if (T == Value) return @import("json_tree").copy(a, value);
    return switch (@typeInfo(T)) {
        .optional => |info| if (value) |item| try copy(info.child, a, item) else null,
        .pointer => |info| blk: {
            const result = try a.alloc(info.child, value.len);
            for (value, result) |item, *target| target.* = try copy(info.child, a, item);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| @field(result, name) = try copy(Field, a, @field(value, name));
            break :blk result;
        },
        .@"union" => |info| blk: {
            inline for (info.field_names, info.field_types) |name, Field| if (@backingInt(value) == @backingInt(@field(info.tag_type.?, name))) break :blk @unionInit(T, name, try copy(Field, a, @field(value, name)));
            unreachable;
        },
        else => value,
    };
}

fn decodeAction(a: Allocator, name: []const u8, value: Value) !Action {
    const info = @typeInfo(Action).@"union";
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (std.mem.eql(u8, name, field_name)) {
            try shape(Field, value);
            const payload = try borrowed(Field, a, value);
            return @unionInit(Action, field_name, payload);
        }
    }
    return error.UnknownAction;
}

fn borrowed(comptime T: type, a: Allocator, value: Value) anyerror!T {
    if (T == Value) return value;
    if (T == Edit) {
        if (std.mem.eql(u8, value.object.get("op").?.string, "drop")) return .{ .drop = try borrowed([]const []const u8, a, value.object.get("ids").?) };
        return .{ .insert = .{ .after = try borrowed(?[]const u8, a, value.object.get("after").?), .ids = try borrowed([]const []const u8, a, value.object.get("ids").?) } };
    }
    return switch (@typeInfo(T)) {
        .optional => |info| if (value == .null) null else try borrowed(info.child, a, value),
        .bool => value.bool,
        .int => std.math.cast(T, value.integer) orelse return error.InvalidNumber,
        .@"enum" => std.meta.stringToEnum(T, value.string) orelse return error.InvalidPayload,
        .pointer => |info| if (info.child == u8) value.string else blk: {
            const result = try a.alloc(info.child, value.array.items.len);
            for (value.array.items, result) |item, *slot| slot.* = try borrowed(info.child, a, item);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (value.object.get(name)) |item| @field(result, name) = try borrowed(Field, a, item) else if (attrs.default_value_ptr) |pointer| @field(result, name) = @as(*const Field, @ptrCast(@alignCast(pointer))).* else return error.MissingField;
            }
            break :blk result;
        },
        else => @compileError("unsupported frame field"),
    };
}

fn shape(comptime T: type, value: Value) anyerror!void {
    if (T == Value) return;
    if (T == Edit) return Edit.check(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (value != .object) return error.InvalidPayload;
            for (value.object.keys()) |key| {
                var known = false;
                inline for (info.field_names) |name| if (std.mem.eql(u8, key, name)) {
                    known = true;
                };
                if (!known) return error.UnknownField;
            }
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (value.object.get(name)) |item| {
                    if (attrs.default_value_ptr != null and item == .null) return error.InvalidPayload;
                    try shape(Field, item);
                } else if (attrs.default_value_ptr == null) return error.MissingField;
            }
        },
        .optional => |info| if (value != .null) {
            try shape(info.child, value);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("frame payloads must not contain runtime pointers");
            if (info.child == u8) {
                if (value != .string) return error.InvalidPayload;
            } else {
                if (value != .array) return error.InvalidPayload;
                for (value.array.items) |item| try shape(info.child, item);
            }
        },
        .int => {
            if (value != .integer or value.integer < 0 or value.integer > max_sequence) return error.InvalidPayload;
        },
        .bool => if (value != .bool) return error.InvalidPayload,
        .@"enum" => if (value != .string) return error.InvalidPayload,
        else => @compileError("unsupported frame payload type"),
    }
}

pub fn validateValue(a: Allocator, root: Value) !void {
    var pending: std.ArrayList([]const Value) = .empty;
    defer pending.deinit(a);
    var next = root;
    while (true) {
        const children: []const Value = switch (next) {
            .object => |fields| blk: {
                for (fields.keys()) |key| if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidJsonDomain;
                break :blk fields.values();
            },
            .array => |array| array.items,
            .string => |bytes| if (std.unicode.utf8ValidateSlice(bytes)) &.{} else return error.InvalidJsonDomain,
            .integer => |number| if (number >= -@as(i64, max_sequence) and number <= max_sequence) &.{} else return error.InvalidJsonDomain,
            .float => |number| if (std.math.isFinite(number)) &.{} else return error.InvalidJsonDomain,
            .number_string => return error.InvalidJsonDomain,
            .null, .bool => &.{},
        };
        if (children.len != 0) {
            if (children.len > 1) try pending.append(a, children[1..]);
            next = children[0];
        } else {
            const siblings = pending.pop() orelse return;
            if (siblings.len > 1) pending.appendAssumeCapacity(siblings[1..]);
            next = siblings[0];
        }
    }
}

fn id(sink: ?SizeSink, bytes: []const u8) !void {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidId;
    for (bytes) |byte| if (byte < 32 or byte == 127) return error.InvalidId;
    if (sink) |reporter| reporter.report("identifier bytes", bytes.len, 256);
}
pub fn validProviderResponseId(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}
fn reference(seq: u64) !void {
    if (seq == 0 or seq > max_sequence) return error.InvalidReference;
}
fn version(sink: ?SizeSink, value: Version) !void {
    try id(sink, value.id);
}
fn hash(bytes: []const u8) !void {
    if (bytes.len != 64) return error.InvalidHash;
    for (bytes) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidHash;
}
fn object(value: Value) !void {
    if (value != .object) return error.InvalidPayload;
}
fn nullableObject(value: Value) !void {
    if (value != .null) try object(value);
}
fn harness(sink: ?SizeSink, value: HarnessValue) !void {
    try version(sink, value.contract);
}
fn validate(sink: ?SizeSink, action: Action) !void {
    switch (action) {
        .@"capability.bind" => |value| {
            try id(sink, value.name);
            try version(sink, value.service);
            try object(value.config);
        },
        .@"capability.unbind" => |value| {
            try id(sink, value.name);
            try reference(value.binding);
        },
        .@"control.set_model" => |value| {
            try id(sink, value.provider);
            try id(sink, value.model);
            try id(sink, value.route);
            if (value.credential_ref) |credential| try id(sink, credential);
            try version(sink, value.adapter);
            try object(value.kwargs);
            if (value.selection) |selection| try object(selection);
        },
        .@"control.provider_tool.register" => |value| {
            try id(sink, value.name);
            try object(value.definition);
            if (value.handler) |handler| try harness(sink, handler);
        },
        .@"control.provider_tool.deregister" => |value| {
            try id(sink, value.name);
            try reference(value.registration);
        },
        .@"control.extension" => |value| {
            try id(sink, value.namespace);
            try id(sink, value.action);
            try harness(sink, value.input);
        },
        .@"document.message.append" => |value| {
            const message = value.message;
            try id(sink, message.id);
            if (value.display_only) |display| {
                if (!display or message.role != .system or message.tool_calls != null or value.request != null or value.placement == null) return error.InvalidMessage;
            }
            if (message.tool_calls) |calls| {
                if (message.role != .assistant) return error.InvalidMessage;
                if (calls.len > 0 and value.request == null) return error.InvalidMessage;
                for (calls) |call| {
                    try id(sink, call.id);
                    try id(sink, call.name);
                }
            }
            if (message.role == .tool) {
                try id(sink, message.tool_call_id orelse return error.InvalidMessage);
            } else if (message.tool_call_id != null) return error.InvalidMessage;
            if (value.request) |request| try id(sink, request);
            if (value.source) |source| try reference(source);
            if (value.placement) |placement| {
                try id(sink, placement.context);
                if (placement.after) |after| try id(sink, after);
            }
            if (value.provenance) |provenance| {
                try hash(provenance.sha256);
            }
            for (message.content) |part| try content(sink, part);
        },
        .@"control.context.create" => |value| {
            try id(sink, value.id);
            if (value.base) |base| {
                try id(sink, base.context);
                if (base.through) |entry| try id(sink, entry);
                if (base.fork) |fork| {
                    if (base.through != null or fork.anchor > base.at) return error.InvalidReference;
                    try id(sink, fork.parent);
                    try reference(fork.anchor);
                    for (fork.selected) |entry| try id(sink, entry);
                }
            }
        },
        .@"control.context.select" => |value| try id(sink, value.context),
        .@"control.document_mutation" => |value| {
            try id(sink, value.context);
            if (value.edits.len == 0) return error.InvalidMutation;
            for (value.edits) |edit| {
                const ids = switch (edit) {
                    .drop => |ids| ids,
                    .insert => |insert| insert.ids,
                };
                if (ids.len == 0) return error.InvalidMutation;
                for (ids) |name| try id(sink, name);
                if (edit == .insert) if (edit.insert.after) |after| try id(sink, after);
            }
        },
        .@"control.model.request" => |value| {
            try id(sink, value.request_id);
            try id(sink, value.context);
            if (value.conversation) |scope| try id(sink, scope);
            try reference(value.model_frame);
            try version(sink, value.renderer);
            try object(value.kwargs);
            try hash(value.instructions_sha256);
            try hash(value.messages_sha256);
            try hash(value.tools_sha256);
        },
        .@"control.model.progress" => |value| {
            try id(sink, value.request_id);
            if (value.deferred) |deferred| {
                try id(sink, deferred.adapter);
                if (value.response_id.len != 0 or value.reattach != null or deferred.handle == .null or (value.next_poll_ms orelse 0) == 0) return error.InvalidProviderProgress;
            } else {
                if (!validProviderResponseId(value.response_id)) return error.InvalidProviderResponseId;
                if (sink) |reporter| reporter.report("provider response identifier bytes", value.response_id.len, 256);
            }
            if (value.cursor > max_sequence or (value.next_poll_ms orelse 0) > max_sequence) return error.InvalidProviderProgress;
        },
        .@"control.model.finish" => |value| {
            try id(sink, value.request_id);
            try nullableObject(value.usage);
            try nullableObject(value.diagnostic);
        },
        .@"control.effect.intent" => |value| {
            try id(sink, value.effect_id);
            try id(sink, value.endpoint.name);
            try reference(value.endpoint.binding);
            try id(sink, value.key);
            if (value.source_message) |message| try id(sink, message);
        },
        .@"control.effect.result" => |value| try id(sink, value.effect_id),
        .@"control.cancel" => |value| try reference(value.target),
    }
}

fn content(sink: ?SizeSink, part: Value) !void {
    if (part != .object) return error.InvalidContent;
    const kind = part.object.get("type") orelse return error.MissingField;
    if (kind != .string) return error.InvalidContent;
    const allowed: []const []const u8 = if (std.mem.eql(u8, kind.string, "text")) &.{ "type", "text" } else if (std.mem.eql(u8, kind.string, "json")) &.{ "type", "value" } else if (std.mem.eql(u8, kind.string, "binary")) &.{ "type", "media_type", "base64", "sha256" } else if (std.mem.eql(u8, kind.string, "provider_state")) &.{ "type", "provider", "format", "base64", "sha256" } else return error.InvalidContent;
    if (part.object.count() != allowed.len) return error.InvalidContent;
    for (allowed) |key| {
        const value = part.object.get(key) orelse return error.MissingField;
        if (!std.mem.eql(u8, key, "value") and value != .string) return error.InvalidContent;
    }
    if (part.object.get("provider")) |value| try id(sink, value.string);
    if (part.object.get("sha256")) |value| {
        try hash(value.string);
        try validateContentHash(part.object.get("base64").?.string, value.string);
    }
}

fn validateContentHash(encoded: []const u8, expected: []const u8) !void {
    const decoder = std.base64.standard.Decoder;
    const encoder = std.base64.standard.Encoder;
    _ = decoder.calcSizeForSlice(encoded) catch return error.InvalidContent;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var sha = Sha256.init(.{});
    var buffer: [3072]u8 = undefined;
    const chunk_size = encoder.calcSize(buffer.len);
    var offset: usize = 0;
    while (encoded.len - offset > chunk_size) : (offset += chunk_size) {
        const chunk = encoded[offset..][0..chunk_size];
        if (chunk[chunk_size - 1] == '=') return error.InvalidContent;
        decoder.decode(&buffer, chunk) catch return error.InvalidContent;
        sha.update(&buffer);
    }
    const last = encoded[offset..];
    const size = decoder.calcSizeForSlice(last) catch return error.InvalidContent;
    const decoded = buffer[0..size];
    decoder.decode(decoded, last) catch return error.InvalidContent;
    sha.update(decoded);
    const hex = std.fmt.bytesToHex(sha.finalResult(), .lower);
    if (!std.mem.eql(u8, &hex, expected)) return error.InvalidHash;

    // Complete four-character groups have a unique encoding. Check only
    // the last group, which may contain padding bits.
    if (last.len != 0) {
        const final_group_length = (decoded.len - 1) % 3 + 1;
        var canonical: [4]u8 = undefined;
        if (!std.mem.eql(u8, encoder.encode(&canonical, decoded[decoded.len - final_group_length ..]), last[last.len - 4 ..])) return error.InvalidContent;
    }
}

test "standard messages and opaque hosted tools need no runtime contract" {
    const a = std.testing.allocator;
    var message = try Owned.parse(a,
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"document","op":"document.message.append","actor":{"kind":"user","id":"operator"},"cause":null,"data":{"message":{"id":"m1","role":"user","content":[{"type":"text","text":"hello"}]},"placement":{"context":"main","after":null}}}
    , 8192);
    defer message.deinit();
    try std.testing.expectEqual(Role.user, message.frame.action.@"document.message.append".message.role);
    var hosted = try Owned.parse(a,
        \\{"v":1,"session_id":"test","seq":2,"tx":{"id":"t2","index":0,"count":1},"class":"control","op":"control.provider_tool.register","actor":{"kind":"host","id":"host"},"cause":1,"data":{"name":"search","definition":{"type":"web_search"},"handler":null}}
    , 8192);
    defer hosted.deinit();
    try std.testing.expect(hosted.frame.action.@"control.provider_tool.register".handler == null);
}

test "missing nullable fields, unknown lifecycle actions and role misuse reject" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownAction, Owned.parse(a,
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"control","op":"control.session.open","actor":{"kind":"host","id":"host"},"cause":null,"data":{}}
    , 8192));
    try std.testing.expectError(error.MissingField, Owned.parse(a,
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"document","op":"document.message.append","actor":{"kind":"host","id":"host"},"cause":null,"data":{"message":{"id":"m1","role":"user","content":[]}}}
    , 8192));
    try std.testing.expectError(error.InvalidMessage, Owned.parse(a,
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"document","op":"document.message.append","actor":{"kind":"host","id":"host"},"cause":null,"data":{"message":{"id":"m1","role":"user","content":[],"tool_calls":[]},"placement":null}}
    , 8192));
}
