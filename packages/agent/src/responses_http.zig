const std = @import("std");
const json_text = @import("json_tree").text;
const HttpResponseReader = @import("services").HttpResponseReader;
const Io = std.Io;
const Value = std.json.Value;
const agent = @import("config.zig");
const transport = @import("responses_transport.zig");
pub const Request = transport.Request;
const errorResponse = transport.errorResponse;
const max_response = transport.max_response;
const connect_timeout = transport.connect_timeout;
const responses = @import("responses.zig");

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    preview: ?responses.Preview,
    request_id: []const u8,
    dialect: responses.Dialect = .responses,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    skip_lf: bool = false,
    first_line: bool = true,
    events: ?responses.Decoder = null,
    size_context: ?@import("services").Context = null,
    native_resume: bool = false,
    response_id: ?[]u8 = null,
    sequence_number: ?i64 = null,
    received: usize = 0,
    progress: ?@import("services").ModelProgressSink = null,
    progress_failure: ?anyerror = null,

    pub fn canResume(self: *const Decoder) bool {
        return self.response_id != null and self.sequence_number != null and !self.completed();
    }

    pub fn completed(self: *const Decoder) bool {
        return if (self.events) |events| events.result != null else false;
    }

    pub fn checkpoint(self: *Decoder, next_poll_ms: ?u64, reattach_stream: bool) !void {
        const sink = self.progress orelse return;
        const id = self.response_id orelse return;
        const sequence = self.sequence_number orelse return;
        sink.write(sink.context, .{
            .response_id = id,
            .cursor = @intCast(sequence),
            .next_poll_ms = next_poll_ms,
            .reattach = if (reattach_stream) .stream else null,
        }) catch |err| {
            self.progress_failure = err;
            return err;
        };
    }

    /// A new attachment starts at an event boundary, not a partial SSE line.
    pub fn resetFraming(self: *Decoder) void {
        self.line.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.skip_lf = false;
        self.first_line = true;
    }

    pub fn deinit(self: *Decoder) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        if (self.events) |*events| events.deinit();
        if (self.response_id) |id| self.allocator.free(id);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.native_resume) self.received +|= bytes.len;
        for (bytes) |byte| {
            if (self.skip_lf) {
                self.skip_lf = false;
                if (byte == '\n') continue;
            }
            if (byte == '\r' or byte == '\n') {
                try self.endLine();
                self.skip_lf = byte == '\r';
            } else {
                try self.line.append(self.allocator, byte);
            }
        }
    }

    pub fn finish(self: *Decoder) ![]const u8 {
        if (self.line.items.len != 0 or self.data.items.len != 0) return error.TruncatedStream;
        if (self.events) |*events| return events.finish();
        return error.MissingCompletedResponse;
    }

    fn endLine(self: *Decoder) !void {
        var line = self.line.items;
        defer self.line.clearRetainingCapacity();
        if (self.first_line) {
            self.first_line = false;
            if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        }
        if (line.len == 0) {
            if (self.data.items.len != 0) try self.dispatch();
            self.data.clearRetainingCapacity();
        } else if (std.mem.eql(u8, line, "data") or std.mem.startsWith(u8, line, "data:")) {
            var value = if (line.len == 4) "" else line[5..];
            if (std.mem.startsWith(u8, value, " ")) value = value[1..];
            try self.data.appendSlice(self.allocator, value);
            try self.data.append(self.allocator, '\n');
        }
    }

    fn dispatch(self: *Decoder) !void {
        if (self.events == null) self.events = .{
            .allocator = self.allocator,
            .preview = self.preview,
            .request_id = self.request_id,
            .dialect = self.dialect,
            .start_on_event = self.dialect == .codex,
            .size_context = self.size_context,
        };
        const data = self.data.items[0 .. self.data.items.len - 1];
        if (!self.native_resume or std.mem.eql(u8, data, "[DONE]")) return self.events.?.event(data);
        const parsed = try json_text.parseFromSlice(Value, self.allocator, data, .{});
        defer parsed.deinit();
        const event = parsed.value;
        const kind = responsesField(event, "type") orelse return error.InvalidStreamEvent;
        if (kind != .string) return error.InvalidStreamEvent;
        // Keepalive counters are connection-local, not stored-event cursors.
        if (std.mem.eql(u8, kind.string, "keepalive")) return;
        const sequence = responsesField(event, "sequence_number") orelse return error.InvalidResumeCursor;
        if (sequence != .integer or sequence.integer < 0) return error.InvalidResumeCursor;
        if (self.sequence_number == null and (sequence.integer != 0 or !std.mem.eql(u8, kind.string, "response.created"))) return error.InvalidResumeCursor;
        if (responsesField(event, "response")) |response| {
            const id = responsesField(response, "id") orelse return error.InvalidResumeCursor;
            if (id != .string or !@import("session_protocol").frames.validProviderResponseId(id.string)) return error.InvalidResumeCursor;
            if (self.response_id) |previous| {
                if (!std.mem.eql(u8, previous, id.string)) return error.ResumeGenerationMismatch;
            } else self.response_id = try self.allocator.dupe(u8, id.string);
        }
        if (self.response_id == null) return error.InvalidResumeCursor;
        if (self.sequence_number) |previous| {
            if (sequence.integer <= previous) return; // Native event replay, not text deduplication.
            if (sequence.integer - previous != 1) return error.ResumeSequenceGap;
        }
        try self.events.?.event(data);
        self.sequence_number = sequence.integer;
        if (@rem(sequence.integer, 64) == 0 or self.completed()) try self.checkpoint(null, false);
    }
};

fn responsesField(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}

pub fn call(allocator: std.mem.Allocator, io: Io, request: transport.Request) !agent.AdapterResponse {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const codex = request.dialect == .codex;
    if (request.resume_decoder != null and request.dialect != .responses) return error.InvalidResume;
    const resuming = if (request.resume_decoder) |state| state.canResume() else false;
    if (request.poll_response_id) |id| {
        if (request.dialect != .responses or request.resume_decoder != null or !@import("session_protocol").frames.validProviderResponseId(id)) return error.InvalidResume;
    }
    if (request.cancel_response_id) |id| {
        if (request.dialect != .responses or request.resume_decoder != null or request.poll_response_id != null or
            !@import("session_protocol").frames.validProviderResponseId(id)) return error.InvalidProviderResponseId;
    }
    const url = if (request.cancel_response_id) |id|
        try std.fmt.allocPrint(arena, "{s}/{s}/cancel", .{ request.url, id })
    else if (request.poll_response_id) |id|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ request.url, id })
    else if (resuming)
        try std.fmt.allocPrint(arena, "{s}/{s}?stream=true&starting_after={d}", .{ request.url, request.resume_decoder.?.response_id.?, request.resume_decoder.?.sequence_number.? })
    else
        request.url;
    const uri = try std.Uri.parse(url);
    const body: ?[]u8 = if (resuming or request.poll_response_id != null) null else blk: {
        if (request.body != .object) return errorResponse(allocator, "invalid_request", "Request body must be an object.");
        const payload = if (if (codex) request.prepared_codex_payload else null) |prepared| reused: {
            var fields = try prepared.clone(arena);
            _ = fields.orderedRemove("type");
            break :reused Value{ .object = fields };
        } else original: {
            const wire = if (codex) try responses.codexHttpValue(arena, request.body) else public: {
                var fields: std.json.ObjectMap = .empty;
                var iterator = request.body.object.iterator();
                while (iterator.next()) |entry| try fields.put(arena, entry.key_ptr.*, entry.value_ptr.*);
                if (request.preview != null or request.resume_decoder != null) try fields.put(arena, "stream", .{ .bool = true });
                if (request.resume_decoder != null) {
                    try fields.put(arena, "background", .{ .bool = true });
                    try fields.put(arena, "store", .{ .bool = false });
                }
                break :public Value{ .object = fields };
            };
            break :original if (request.cancel_response_id == null) try request.preparePayload(arena, io, .http, wire) else wire;
        };
        const encoded = try std.json.Stringify.valueAlloc(arena, payload, .{});
        request.warnSize("HTTP request bytes", encoded.len, transport.max_body);
        break :blk encoded;
    };
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse
        return errorResponse(allocator, "invalid_request", "Unsupported HTTP scheme.");
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = std.Io.net.HostName.fromUri(uri, &host_buffer) catch
        return errorResponse(allocator, "invalid_request", "Invalid HTTP host.");
    if (protocol == .tls) {
        const now = Io.Clock.real.now(io);
        client.ca_bundle.rescan(allocator, io, now) catch
            return errorResponse(allocator, "configuration_error", "HTTP certificate bundle could not load.");
        client.now = now;
    }
    const connection = client.connectTcpOptions(.{
        .host = host_name,
        .port = uri.port orelse if (protocol == .tls) 443 else 80,
        .protocol = protocol,
        .timeout = .{ .duration = connect_timeout },
    }) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        error.Timeout => return errorResponse(allocator, "timeout", "Connection timed out."),
        else => return errorResponse(allocator, if (transport.transientError(err)) "http_error" else "connection_failed", @errorName(err)),
    };
    var response_input: HttpResponseReader = .{ .allocator = allocator };
    defer response_input.deinit();
    const headers = if (codex) try std.mem.concat(arena, std.http.Header, &.{ request.headers, &.{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
        .{ .name = "originator", .value = "cpi" },
    } }) else request.headers;
    var http_request = client.request(if (body == null) .GET else .POST, uri, .{
        .connection = connection,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
        .extra_headers = headers,
    }) catch return errorResponse(allocator, "http_error", "HTTP request could not start.");
    defer {
        // One-shot exchanges close rather than drain an unfinished response during cleanup.
        http_request.reader.state = .ready;
        connection.closing = true;
        http_request.deinit();
    }
    var deadline: transport.Deadline = .{};
    var watchdog = try io.concurrent(transport.Deadline.run, .{ &deadline, io, connection, request.timeout });
    defer {
        deadline.stop.set(io);
        watchdog.await(io);
    }
    const expired = &deadline.expired;
    if (body) |encoded| {
        http_request.sendBodyComplete(encoded) catch
            return errorResponse(allocator, if (expired.load(.acquire)) "timeout" else "http_error", "HTTP request failed.");
    } else {
        http_request.sendBodiless() catch
            return errorResponse(allocator, if (expired.load(.acquire)) "timeout" else "http_error", "Resume request failed.");
    }
    var response = response_input.receiveHead(&http_request) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (expired.load(.acquire)) return errorResponse(allocator, "timeout", "HTTP request timed out.");
        // HTTP parsing wraps socket cancellation in Reader's ReadFailed.
        if (err == error.ReadFailed and (connection.getReadError() orelse error.Unexpected) == error.Canceled) return error.Canceled;
        return errorResponse(allocator, "http_error", @errorName(err));
    };
    request.warnSize("HTTP response head bytes", response.head.bytes.len, HttpResponseReader.expected_bytes);
    if (response.head.status.class() == .redirect) {
        return errorResponse(allocator, "redirect_denied", "Redirects are not permitted.");
    }
    const content_type = response.head.content_type orelse "application/json";
    const status = response.head.status;
    // Codex always requests streaming. Like OpenAI's Codex client, send a
    // successful response directly to the SSE decoder, regardless of its MIME label.
    const is_sse = status.class() == .success and (codex or std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t"), "text/event-stream"));
    var retry_after_ms: u32 = 0;
    var header_iterator = response.head.iterateHeaders();
    while (header_iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) retry_after_ms = transport.retryAfterMilliseconds(header.value, std.Io.Timestamp.now(io, .real).toSeconds()) orelse 0;
    }
    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);
    var local_decoder: Decoder = .{ .allocator = allocator, .preview = request.preview, .request_id = request.id, .dialect = request.dialect };
    defer local_decoder.deinit();
    const decoder = request.resume_decoder orelse &local_decoder;
    decoder.size_context = request.size_context;
    decoder.resetFraming();
    if (request.resume_decoder != null and status.class() == .success and !is_sse)
        return errorResponse(allocator, "invalid_response", "Native resume requires an event stream.");
    var json_body: std.ArrayList(u8) = .empty;
    defer json_body.deinit(allocator);
    if (!codex and !resuming and request.poll_response_id == null) if (request.preview) |preview| try preview.notify(preview.context, request.id, .started);
    var received: usize = 0;
    while (true) {
        const bytes = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                if (response_input.failure) |failure| return failure;
                if (expired.load(.acquire)) return errorResponse(allocator, "timeout", "HTTP response body failed.");
                if (response.bodyErr() == null and (connection.getReadError() orelse error.Unexpected) == error.Canceled) return error.Canceled;
                return errorResponse(allocator, "http_error", "HTTP response body failed.");
            },
        };
        const previous = if (decoder.native_resume and is_sse) decoder.received else received;
        if (previous <= max_response) request.warnSize("HTTP response bytes", previous +| bytes.len, max_response);
        received +|= bytes.len;
        if (is_sse) {
            decoder.feed(bytes) catch |err| {
                if (decoder.progress_failure) |failure| return failure;
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                return errorResponse(allocator, "invalid_response", @errorName(err));
            };
            if ((codex or request.resume_decoder != null) and decoder.completed()) break;
        } else {
            try json_body.appendSlice(allocator, bytes);
        }
        reader.toss(bytes.len);
    }
    request.warnSize("HTTP response trailer bytes", http_request.reader.trailers.len, HttpResponseReader.expected_bytes);
    if (expired.load(.acquire)) return errorResponse(allocator, "timeout", "HTTP request timed out.");
    const response_body = if ((codex or request.resume_decoder != null) and decoder.completed())
        try decoder.events.?.finish()
    else if (is_sse)
        decoder.finish() catch |err| return errorResponse(allocator, if (transport.transientError(err)) "stream_disconnected" else "invalid_response", @errorName(err))
    else
        json_body.items;
    const parsed = json_text.parseFromSlice(Value, arena, response_body, .{ .allocate = .alloc_if_needed }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (status.class() == .success) return errorResponse(allocator, if (err == error.UnexpectedEndOfInput) "stream_disconnected" else "invalid_response", "HTTP response is not complete JSON.");
        // Rate-limit and gateway responses are often HTML/plain text. Preserve
        // their status and backoff hint instead of misclassifying malformed JSON.
        return transport.remoteResponse(allocator, "http", @backingInt(status), .null, retry_after_ms);
    };
    if (status.class() == .success and parsed.value != .object) return errorResponse(allocator, "invalid_response", "HTTP response must be an object.");
    return transport.remoteResponse(allocator, if (is_sse) "sse" else "http", @backingInt(status), parsed.value, retry_after_ms);
}
