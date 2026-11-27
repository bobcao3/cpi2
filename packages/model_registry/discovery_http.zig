//! Default HTTP adapter for credential-bound model discovery. No redirects or
//! retries: the caller owns cancellation and decides when to refresh again.
const std = @import("std");
const json_text = @import("agent").session_protocol.json.text;
const Io = std.Io;
const registry = @import("root.zig");
const HttpResponseReader = @import("services").HttpResponseReader;

const Response = struct { status: u16, body: std.json.Value = .null };
fn deadline(io: Io) Io.Cancelable!void {
    try Io.sleep(io, .fromSeconds(25), .awake);
}

pub fn get(a: std.mem.Allocator, io: Io, url: []const u8, headers: []const std.http.Header, warnings: registry.SizeSink) !Response {
    // Bound the entire exchange, including DNS and TLS, not just reads after
    // connect. Join before the caller can free headers or the request arena.
    const Event = union(enum) { response: anyerror!Response, deadline: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.deadline, deadline, .{io});
    try select.concurrent(.response, getOnce, .{ a, io, url, headers, warnings });
    return switch (try select.await()) {
        .response => |response| response,
        .deadline => |result| blk: {
            try result;
            break :blk error.ModelDiscoveryTimedOut;
        },
    };
}

fn getOnce(a: std.mem.Allocator, io: Io, url: []const u8, headers: []const std.http.Header, warnings: registry.SizeSink) anyerror!Response {
    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidDiscoveryUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidDiscoveryUrl;
    var hostname: [Io.net.HostName.max_len]u8 = undefined;
    const host = try Io.net.HostName.fromUri(uri, &hostname);
    if (protocol == .plain and !std.mem.eql(u8, host.bytes, "127.0.0.1") and !std.mem.eql(u8, host.bytes, "::1")) return error.InvalidDiscoveryUrl;

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var input: HttpResponseReader = .{ .allocator = a };
    defer input.deinit();
    var request = try client.request(.GET, uri, .{ .keep_alive = false, .redirect_behavior = .unhandled, .headers = .{ .accept_encoding = .omit }, .extra_headers = headers });
    const connection = request.connection.?;
    defer {
        request.reader.state = .ready;
        connection.closing = true;
        request.deinit();
    }
    try request.sendBodiless();
    var response = input.receiveHead(&request) catch |err| {
        if (err == error.ReadFailed) return connection.getReadError() orelse err;
        return err;
    };
    warnings.report("model discovery response head bytes", response.head.bytes.len, HttpResponseReader.expected_bytes);
    const status: u16 = @intCast(@backingInt(response.head.status));
    if (status != 200) return .{ .status = status };
    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);
    const bytes = reader.allocRemaining(a, .unlimited) catch |err| {
        try io.checkCancel();
        if (input.failure) |failure| return failure;
        if (connection.getReadError()) |failure| return failure;
        return err;
    };
    warnings.report("model discovery response trailer bytes", request.reader.trailers.len, HttpResponseReader.expected_bytes);
    warnings.report("model discovery response bytes", bytes.len, 1024 * 1024);
    return .{ .status = status, .body = try json_text.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_if_needed }) };
}
