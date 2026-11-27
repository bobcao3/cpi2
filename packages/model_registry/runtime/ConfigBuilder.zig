const std = @import("std");
const c = @import("registry_bridge");
const types = @import("../model.zig");

const Allocator = std.mem.Allocator;
const Config = types.Config;
const Provider = types.Provider;
const Model = types.Model;
const Pricing = types.Pricing;
const ImageResize = types.ImageResize;

const Field = enum {
    version,
    providers,
    id,
    name,
    base_url,
    api_key_env,
    api,
    source_url,
    retrieved_at,
    models,
    context_window,
    max_output_tokens,
    pricing,
    image_resize,
    max_width,
    max_height,
    max_bytes,
    jpeg_quality,
    transports,
    reasoning_efforts,
    input,
    output,
    cache_read,
    cache_write,
};

const ConfigFrame = struct {
    version: ?u32 = null,
    providers: std.ArrayListUnmanaged(Provider) = .empty,
    pending: ?Field = null,
};

const ProviderFrame = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    api: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    retrieved_at: ?[]const u8 = null,
    models: []const Model = &.{},
    pending: ?Field = null,
};

const ModelFrame = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    api: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    context_window: ?u64 = null,
    max_output_tokens: ?u32 = null,
    pricing: Pricing = .{},
    image_resize: ?ImageResize = null,
    transports: []const []const u8 = &.{},
    transports_set: bool = false,
    reasoning_efforts: []const []const u8 = &.{},
    pending: ?Field = null,
};

const ModelsFrame = struct {
    items: std.ArrayListUnmanaged(Model) = .empty,
    legacy_api: ?[]const u8 = null,
};

const PricingFrame = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
    pending: ?Field = null,
};

const ImageResizeFrame = struct {
    limits: ImageResize = .{},
    pending: ?Field = null,
};

const Frame = union(enum) {
    config: ConfigFrame,
    providers: std.ArrayListUnmanaged(Provider),
    provider: ProviderFrame,
    models: ModelsFrame,
    model: ModelFrame,
    strings: std.ArrayListUnmanaged([]const u8),
    pricing: PricingFrame,
    image_resize: ImageResizeFrame,
};

a: Allocator,
version: u32 = 0,
frames: std.ArrayListUnmanaged(Frame) = .empty,
result: ?Config = null,
failure: ?anyerror = null,

/// Called by C only inside its protected Lua frame. This never calls back into
/// Lua; a failure returns to C, which raises the Lua error afterwards.
pub fn emit(raw: ?*anyopaque, event: c_int, bytes: [*c]const u8, length: usize, number: f64) callconv(.c) c_int {
    const self: *@This() = @ptrCast(@alignCast(raw.?));
    self.accept(event, if (length == 0) "" else bytes[0..length], number) catch |err| {
        self.failure = err;
        return if (err == error.OutOfMemory) 1 else 6;
    };
    return 0;
}

fn accept(self: *@This(), event: c_int, bytes: []const u8, number: f64) !void {
    switch (event) {
        c.CPI_OBJECT => try self.openObject(),
        c.CPI_ARRAY => try self.openArray(),
        c.CPI_END => {
            const frame = self.frames.pop() orelse return error.InvalidRegistryShape;
            try self.finish(frame);
        },
        c.CPI_KEY => try self.key(bytes),
        c.CPI_STRING => try self.string(bytes),
        c.CPI_NUMBER => try self.numeric(number),
        c.CPI_BOOL, c.CPI_NULL => return error.InvalidRegistryShape,
        else => unreachable,
    }
}

fn openObject(self: *@This()) !void {
    if (self.frames.items.len == 0) {
        try self.frames.append(self.a, .{ .config = .{} });
        return;
    }
    const parent = &self.frames.items[self.frames.items.len - 1];
    const frame: Frame = switch (parent.*) {
        .providers => .{ .provider = .{} },
        .models => .{ .model = .{} },
        .model => |current| switch (current.pending orelse return error.InvalidRegistryShape) {
            .pricing => .{ .pricing = .{} },
            .image_resize => .{ .image_resize = .{} },
            else => return error.InvalidRegistryShape,
        },
        else => return error.InvalidRegistryShape,
    };
    try self.frames.append(self.a, frame);
}

fn openArray(self: *@This()) !void {
    const parent = &self.frames.items[self.frames.items.len - 1];
    const frame: Frame = switch (parent.*) {
        .config => |current| blk: {
            if (current.pending != .providers) return error.InvalidRegistryShape;
            const version = current.version orelse return error.InvalidRegistryShape;
            if (version != 1 and version != 2) return error.UnsupportedRegistryVersion;
            self.version = version;
            break :blk .{ .providers = .empty };
        },
        .provider => |current| blk: {
            if (current.pending != .models) return error.InvalidRegistryShape;
            break :blk .{ .models = .{ .legacy_api = current.api } };
        },
        .model => |current| switch (current.pending orelse return error.InvalidRegistryShape) {
            .transports, .reasoning_efforts => .{ .strings = .empty },
            else => return error.InvalidRegistryShape,
        },
        else => return error.InvalidRegistryShape,
    };
    try self.frames.append(self.a, frame);
}

fn key(self: *@This(), bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRegistryShape;
    const top = &self.frames.items[self.frames.items.len - 1];
    switch (top.*) {
        .config => |*current| current.pending = if (equal(bytes, "version")) .version else if (equal(bytes, "providers")) .providers else return error.UnknownField,
        .provider => |*current| current.pending = providerField(bytes) orelse return error.UnknownField,
        .model => |*current| current.pending = modelField(bytes) orelse return error.UnknownField,
        .pricing => |*current| current.pending = pricingField(bytes) orelse return error.UnknownField,
        .image_resize => |*current| current.pending = imageResizeField(bytes) orelse return error.UnknownField,
        else => return error.InvalidRegistryShape,
    }
}

fn string(self: *@This(), bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRegistryShape;
    const top = &self.frames.items[self.frames.items.len - 1];
    switch (top.*) {
        .strings => |*list| try list.append(self.a, try self.a.dupe(u8, bytes)),
        .provider => |*current| {
            const field = current.pending orelse return error.InvalidRegistryShape;
            const owned = try self.a.dupe(u8, bytes);
            switch (field) {
                .id => current.id = owned,
                .name => current.name = owned,
                .base_url => current.base_url = owned,
                .api_key_env => current.api_key_env = owned,
                .api => current.api = owned,
                .source_url => current.source_url = owned,
                .retrieved_at => current.retrieved_at = owned,
                else => return error.InvalidRegistryShape,
            }
            current.pending = null;
        },
        .model => |*current| {
            const field = current.pending orelse return error.InvalidRegistryShape;
            const owned = try self.a.dupe(u8, bytes);
            switch (field) {
                .id => current.id = owned,
                .name => current.name = owned,
                .api => current.api = owned,
                .source_url => current.source_url = owned,
                else => return error.InvalidRegistryShape,
            }
            current.pending = null;
        },
        else => return error.InvalidRegistryShape,
    }
}

fn numeric(self: *@This(), value: f64) !void {
    if (!std.math.isFinite(value)) return error.InvalidRegistryNumber;
    const top = &self.frames.items[self.frames.items.len - 1];
    switch (top.*) {
        .config => |*current| {
            if (current.pending != .version) return error.InvalidRegistryShape;
            if (value < 0 or value != @trunc(value) or value > 4294967295.0) return error.InvalidRegistryNumber;
            current.version = @intFromFloat(value);
            current.pending = null;
        },
        .model => |*current| {
            const field = current.pending orelse return error.InvalidRegistryShape;
            switch (field) {
                .context_window => {
                    if (value < 0 or value != @trunc(value) or value > 9007199254740991.0) return error.InvalidRegistryNumber;
                    current.context_window = @intFromFloat(value);
                },
                .max_output_tokens => {
                    if (value < 0 or value != @trunc(value) or value > 4294967295.0) return error.InvalidRegistryNumber;
                    current.max_output_tokens = @intFromFloat(value);
                },
                else => return error.InvalidRegistryShape,
            }
            current.pending = null;
        },
        .pricing => |*current| {
            const field = current.pending orelse return error.InvalidRegistryShape;
            switch (field) {
                .input => current.input = value,
                .output => current.output = value,
                .cache_read => current.cache_read = value,
                .cache_write => current.cache_write = value,
                else => return error.InvalidRegistryShape,
            }
            current.pending = null;
        },
        .image_resize => |*current| {
            const field = current.pending orelse return error.InvalidRegistryShape;
            if (value <= 0 or value != @trunc(value)) return error.InvalidRegistryNumber;
            switch (field) {
                .max_width, .max_height => {
                    if (value > 4294967295.0) return error.InvalidRegistryNumber;
                    if (field == .max_width) current.limits.max_width = @intFromFloat(value) else current.limits.max_height = @intFromFloat(value);
                },
                .max_bytes => {
                    if (value > 9007199254740991.0) return error.InvalidRegistryNumber;
                    current.limits.max_bytes = @intFromFloat(value);
                },
                .jpeg_quality => {
                    if (value > 100) return error.InvalidRegistryNumber;
                    current.limits.jpeg_quality = @intFromFloat(value);
                },
                else => return error.InvalidRegistryShape,
            }
            current.pending = null;
        },
        else => return error.InvalidRegistryShape,
    }
}

fn finish(self: *@This(), frame: Frame) !void {
    if (self.frames.items.len == 0) {
        switch (frame) {
            .config => |current| {
                _ = current.version orelse return error.InvalidRegistryShape;
                self.result = .{ .version = 2, .providers = current.providers.items };
            },
            else => return error.InvalidRegistryShape,
        }
        return;
    }
    const parent = &self.frames.items[self.frames.items.len - 1];
    switch (frame) {
        .config => return error.InvalidRegistryShape,
        .providers => |list| switch (parent.*) {
            .config => |*current| {
                current.providers = list;
                current.pending = null;
            },
            else => return error.InvalidRegistryShape,
        },
        .provider => |current| switch (parent.*) {
            .providers => |*list| try list.append(self.a, try self.finishProvider(current)),
            else => return error.InvalidRegistryShape,
        },
        .models => |list| switch (parent.*) {
            .provider => |*current| {
                current.models = list.items.items;
                current.pending = null;
            },
            else => return error.InvalidRegistryShape,
        },
        .model => |current| switch (parent.*) {
            .models => |*list| try list.items.append(self.a, try self.finishModel(current, list.legacy_api)),
            else => return error.InvalidRegistryShape,
        },
        .strings => |list| switch (parent.*) {
            .model => |*current| {
                const field = current.pending orelse return error.InvalidRegistryShape;
                switch (field) {
                    .transports => {
                        current.transports = list.items;
                        current.transports_set = true;
                    },
                    .reasoning_efforts => current.reasoning_efforts = list.items,
                    else => return error.InvalidRegistryShape,
                }
                current.pending = null;
            },
            else => return error.InvalidRegistryShape,
        },
        .pricing => |current| switch (parent.*) {
            .model => |*target| {
                if (target.pending != .pricing) return error.InvalidRegistryShape;
                target.pricing = .{ .input = current.input, .output = current.output, .cache_read = current.cache_read, .cache_write = current.cache_write };
                target.pending = null;
            },
            else => return error.InvalidRegistryShape,
        },
        .image_resize => |current| switch (parent.*) {
            .model => |*target| {
                if (target.pending != .image_resize) return error.InvalidRegistryShape;
                target.image_resize = current.limits;
                target.pending = null;
            },
            else => return error.InvalidRegistryShape,
        },
    }
}

fn finishProvider(self: *@This(), current: ProviderFrame) !Provider {
    if (current.pending != null) return error.InvalidRegistryShape;
    if (self.version == 1) {
        const api = current.api orelse return error.InvalidRegistryShape;
        if (!validToken(api)) return error.InvalidProvider;
    } else if (current.api != null) return error.UnknownField;
    return .{
        .id = current.id orelse return error.InvalidRegistryShape,
        .name = current.name orelse return error.InvalidRegistryShape,
        .base_url = current.base_url orelse return error.InvalidRegistryShape,
        .api_key_env = current.api_key_env orelse return error.InvalidRegistryShape,
        .source_url = current.source_url,
        .retrieved_at = current.retrieved_at,
        .models = current.models,
    };
}

fn finishModel(self: *@This(), current: ModelFrame, legacy_api: ?[]const u8) !Model {
    if (current.pending != null) return error.InvalidRegistryShape;
    var transports = current.transports;
    if (self.version == 1) {
        if (current.transports_set) return error.UnknownField;
        const effective = current.api orelse legacy_api orelse return error.InvalidRegistryShape;
        if (!validToken(effective)) return error.InvalidModelApi;
        if (std.mem.eql(u8, effective, "unknown")) {
            transports = &.{};
        } else {
            const list = try self.a.alloc([]const u8, 1);
            list[0] = effective;
            transports = list;
        }
    } else if (current.api != null) return error.UnknownField;
    return .{
        .id = current.id orelse return error.InvalidRegistryShape,
        .name = current.name orelse return error.InvalidRegistryShape,
        .transports = transports,
        .reasoning_efforts = current.reasoning_efforts,
        .context_window = current.context_window,
        .max_output_tokens = current.max_output_tokens,
        .pricing = current.pricing,
        .image_resize = current.image_resize,
        .source_url = current.source_url,
    };
}

fn providerField(bytes: []const u8) ?Field {
    if (equal(bytes, "id")) return .id;
    if (equal(bytes, "name")) return .name;
    if (equal(bytes, "base_url")) return .base_url;
    if (equal(bytes, "api_key_env")) return .api_key_env;
    if (equal(bytes, "api")) return .api;
    if (equal(bytes, "source_url")) return .source_url;
    if (equal(bytes, "retrieved_at")) return .retrieved_at;
    if (equal(bytes, "models")) return .models;
    return null;
}

fn modelField(bytes: []const u8) ?Field {
    if (equal(bytes, "id")) return .id;
    if (equal(bytes, "name")) return .name;
    if (equal(bytes, "api")) return .api;
    if (equal(bytes, "context_window")) return .context_window;
    if (equal(bytes, "max_output_tokens")) return .max_output_tokens;
    if (equal(bytes, "pricing")) return .pricing;
    if (equal(bytes, "image_resize")) return .image_resize;
    if (equal(bytes, "source_url")) return .source_url;
    if (equal(bytes, "transports")) return .transports;
    if (equal(bytes, "reasoning_efforts")) return .reasoning_efforts;
    return null;
}

fn pricingField(bytes: []const u8) ?Field {
    if (equal(bytes, "input")) return .input;
    if (equal(bytes, "output")) return .output;
    if (equal(bytes, "cache_read")) return .cache_read;
    if (equal(bytes, "cache_write")) return .cache_write;
    return null;
}

fn imageResizeField(bytes: []const u8) ?Field {
    if (equal(bytes, "max_width")) return .max_width;
    if (equal(bytes, "max_height")) return .max_height;
    if (equal(bytes, "max_bytes")) return .max_bytes;
    if (equal(bytes, "jpeg_quality")) return .jpeg_quality;
    return null;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn validToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}
