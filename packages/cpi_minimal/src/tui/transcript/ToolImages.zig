const std = @import("std");
const kit = @import("kit");
const j = @import("../../json.zig");
const Controller = @import("../../session.zig").Controller;
const ImageProcessing = @import("../../images.zig").ImageProcessing;
const HistoryRecord = @import("agent").HistoryRecord;
const UiWake = @import("../UiWake.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dimensions = kit.media.image_dimensions.Dimensions;

const Cache = @This();

pub const Protocol = enum { kitty, iterm2 };
pub const Preview = struct { bytes: []u8, identity: u64, dimensions: Dimensions };
const Preparation = enum { original, png, converted };

const Entry = struct {
    images: []?Preview,
    needs_conversion: bool,
    used: bool = true,
};

entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
pending: ?*Job = null,
protocol: ?Protocol = null,

pub fn get(self: *Cache, a: Allocator, controller: *Controller, wake: UiWake.Notification, event: Controller.Event, protocol: Protocol) ![]const ?Preview {
    if (event.entry_id.len == 0 or event.images.len == 0) return &.{};
    if (self.protocol != protocol) {
        self.clear(a);
        self.protocol = protocol;
    }
    const cached = self.entries.getPtr(event.entry_id);
    if (cached) |entry| {
        entry.used = true;
        if (!entry.needs_conversion or self.pending != null) return entry.images;
    }

    const convert = protocol == .kitty and controller.settings.image_processing and needsConversion(event.images);
    if (convert and self.pending != null and !hasPng(event.images)) return &.{};
    var record = (controller.toolImageEntry(a, event.entry_id) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |failure| return failure,
        else => null,
    }) orelse return if (cached) |entry| entry.images else &.{};
    var transferred = false;
    defer if (!transferred) record.deinit();
    const source = j.items(j.get(record.value, "images"));
    if (source.len != event.images.len) return if (cached) |entry| entry.images else &.{};
    const images = if (cached) |entry| entry.images else try self.add(a, controller.io, event.entry_id, source, protocol, convert);
    if (convert and self.pending == null) {
        self.pending = Job.start(a, controller.io, wake, event.entry_id, record) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return images,
            else => return err,
        };
        transferred = true;
    }
    return images;
}

fn add(self: *Cache, a: Allocator, io: Io, id: []const u8, source: []const std.json.Value, protocol: Protocol, convert: bool) ![]?Preview {
    const images = try prepare(a, io, if (protocol == .kitty) .png else .original, source);
    errdefer freeImages(a, images);
    const key = try a.dupe(u8, id);
    errdefer a.free(key);
    try self.entries.putNoClobber(a, key, .{ .images = images, .needs_conversion = convert });
    return images;
}

pub fn settle(self: *Cache, a: Allocator, io: Io) !void {
    const job = self.pending orelse return;
    if (!job.done.isSet()) return;
    self.pending = null;
    defer a.destroy(job);
    defer job.record.deinit();
    defer a.free(job.id);
    const images = job.future.await(io) catch |err| {
        if (job.obsolete) return;
        return err;
    };
    defer freeImages(a, images);
    if (job.obsolete) return;
    const entry = self.entries.getPtr(job.id) orelse return;
    if (entry.images.len != images.len) return;
    for (entry.images, images) |*current, *converted| {
        if (current.* == null and converted.* != null) {
            current.* = converted.*;
            converted.* = null;
        }
    }
    entry.needs_conversion = false;
}

pub fn endFrame(self: *Cache, a: Allocator) void {
    var index: usize = 0;
    while (index < self.entries.count()) {
        const entry = &self.entries.values()[index];
        if (entry.used) {
            entry.used = false;
            index += 1;
        } else {
            const id = self.entries.keys()[index];
            if (self.pending) |job| {
                if (std.mem.eql(u8, job.id, id)) job.obsolete = true;
            }
            a.free(id);
            freeImages(a, entry.images);
            self.entries.swapRemoveAt(index);
        }
    }
}

pub fn clear(self: *Cache, a: Allocator) void {
    if (self.pending) |job| job.obsolete = true;
    for (self.entries.keys(), self.entries.values()) |key, entry| {
        a.free(key);
        freeImages(a, entry.images);
    }
    self.entries.clearRetainingCapacity();
}

pub fn deinit(self: *Cache, a: Allocator, io: Io) void {
    self.clear(a);
    if (self.pending) |job| {
        if (job.future.cancel(io)) |images| freeImages(a, images) else |_| {}
        job.record.deinit();
        a.free(job.id);
        a.destroy(job);
        self.pending = null;
    }
    self.entries.deinit(a);
}

const Job = struct {
    a: Allocator,
    io: Io,
    wake: UiWake.Notification,
    id: []u8,
    record: HistoryRecord,
    future: Io.Future(anyerror![]?Preview) = undefined,
    done: Io.Event = .unset,
    // The terminal alone reads and writes this flag. A job owns its record
    // independently of the displayed conversation.
    obsolete: bool = false,

    fn start(a: Allocator, io: Io, wake: UiWake.Notification, id: []const u8, record: HistoryRecord) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        const key = try a.dupe(u8, id);
        errdefer a.free(key);
        job.* = .{ .a = a, .io = io, .wake = wake, .id = key, .record = record };
        job.future = try io.concurrent(run, .{job});
        return job;
    }

    fn run(job: *Job) anyerror![]?Preview {
        defer {
            job.done.set(job.io);
            job.wake.signal();
        }
        return prepare(job.a, job.io, .converted, j.items(j.get(job.record.value, "images")));
    }
};

fn needsConversion(images: []const Controller.ToolImage) bool {
    for (images) |image| {
        if (!std.mem.eql(u8, image.mime_type, "image/png")) return true;
    }
    return false;
}

fn hasPng(images: []const Controller.ToolImage) bool {
    for (images) |image| {
        if (std.mem.eql(u8, image.mime_type, "image/png")) return true;
    }
    return false;
}

fn prepare(a: Allocator, io: Io, preparation: Preparation, source: []const std.json.Value) ![]?Preview {
    const images = try a.alloc(?Preview, source.len);
    @memset(images, null);
    errdefer freeImages(a, images);
    for (source, images) |item, *image| {
        try io.checkCancel();
        const mime = j.text(j.get(item, "mime_type"));
        const encoded = j.text(j.get(item, "data_base64"));
        const is_png = std.mem.eql(u8, mime, "image/png");
        if (preparation == .original or (is_png and preparation == .png)) {
            const size = kit.media.image_dimensions.fromBase64(encoded, mime) orelse if (preparation == .original)
                Dimensions{ .width = 800, .height = 600 }
            else
                continue;
            if (size.width == 0 or size.height == 0) continue;
            const bytes = (try decode(a, encoded)) orelse continue;
            image.* = preview(bytes, size);
        } else if (preparation == .converted and !is_png) {
            const bytes = (try decode(a, encoded)) orelse continue;
            defer a.free(bytes);
            const png = (try ImageProcessing.displayPng(a, io, bytes)) orelse continue;
            image.* = preview(png.bytes, .{ .width = png.width, .height = png.height });
        }
    }
    return images;
}

fn preview(bytes: []u8, dimensions: Dimensions) Preview {
    return .{ .bytes = bytes, .identity = std.hash.Wyhash.hash(0, bytes), .dimensions = dimensions };
}

fn freeImages(a: Allocator, images: []?Preview) void {
    for (images) |image| if (image) |item| a.free(item.bytes);
    a.free(images);
}

fn decode(a: Allocator, base64: []const u8) !?[]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64) catch return null;
    const bytes = try a.alloc(u8, size);
    decoder.decode(bytes, base64) catch {
        a.free(bytes);
        return null;
    };
    return bytes;
}
