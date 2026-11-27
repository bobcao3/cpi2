const std = @import("std");
const agent = @import("config.zig");
const responses = @import("responses.zig");
const services = @import("services");

pub const max_body = 4 * 1024 * 1024;
pub const max_response = 2 * 1024 * 1024;
pub const connect_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

pub const PayloadHook = struct {
    pub const Input = struct {
        model: []const u8,
        dialect: responses.Dialect,
        transport: enum { http, websocket, deferred },
        payload: std.json.Value,
    };

    context: ?*anyopaque = null,
    transform: *const fn (?*anyopaque, std.mem.Allocator, std.Io, Input) anyerror!?std.json.Value,

    pub fn apply(hooks: []const PayloadHook, a: std.mem.Allocator, io: std.Io, input: Input) !std.json.Value {
        var current = input;
        for (hooks) |hook| current.payload = try hook.transformOne(a, io, current, input.payload);
        return current.payload;
    }

    fn transformOne(self: PayloadHook, a: std.mem.Allocator, io: std.Io, input: Input, admitted: std.json.Value) !std.json.Value {
        try io.checkCancel();
        var isolated = input;
        isolated.payload = try @import("json.zig").copy(a, input.payload);
        const result = self.transform(self.context, a, io, isolated) catch |err| {
            if (err == error.OutOfMemory) return err;
            try io.checkCancel();
            std.log.warn("beforeProviderRequest skipped ({s})", .{@errorName(err)});
            return input.payload;
        };
        try io.checkCancel();
        const replacement = result orelse return input.payload;
        const limit = field(admitted, "max_output_tokens");
        const replacement_limit = field(replacement, "max_output_tokens");
        if (replacement != .object or !sameOptionalText(field(admitted, "model"), field(replacement, "model")) or
            !sameOptionalText(field(field(admitted, "reasoning"), "effort"), field(field(replacement, "reasoning"), "effort")) or
            (limit == .integer and (replacement_limit != .integer or replacement_limit.integer <= 0 or replacement_limit.integer > limit.integer)))
        {
            std.log.warn("beforeProviderRequest returned an invalid payload or changed the admitted model settings", .{});
            return input.payload;
        }
        @import("session_protocol").json.validate(a, replacement, null) catch |err| {
            if (err == error.OutOfMemory) return err;
            std.log.warn("beforeProviderRequest returned invalid JSON ({s})", .{@errorName(err)});
            return input.payload;
        };
        return replacement;
    }

    fn sameOptionalText(left: std.json.Value, right: std.json.Value) bool {
        return (left == .null and right == .null) or (left == .string and right == .string and std.mem.eql(u8, left.string, right.string));
    }
};

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}

pub const Request = struct {
    url: []const u8,
    body: std.json.Value,
    headers: []const std.http.Header,
    preview: ?responses.Preview,
    id: []const u8,
    dialect: responses.Dialect = .responses,
    /// Owned by the admitted service operation, never by a connection.
    resume_decoder: ?*@import("responses_http.zig").Decoder = null,
    poll_response_id: ?[]const u8 = null,
    cancel_response_id: ?[]const u8 = null,
    timeout: std.Io.Clock.Duration,
    size_context: ?services.Context = null,
    payload_hooks: []const PayloadHook = &.{},
    codex_session: ?@import("CodexSessions.zig").Session = null,
    codex_cached_context: bool = false,
    /// Post-hook full WebSocket payload borrowed by an SSE recovery attempt.
    prepared_codex_payload: ?std.json.ObjectMap = null,

    pub fn preparePayload(self: Request, a: std.mem.Allocator, io: std.Io, kind: @FieldType(PayloadHook.Input, "transport"), payload: std.json.Value) !std.json.Value {
        if (self.payload_hooks.len == 0) return payload;
        const model = field(self.body, "model");
        return PayloadHook.apply(self.payload_hooks, a, io, .{ .model = if (model == .string) model.string else "", .dialect = self.dialect, .transport = kind, .payload = payload });
    }

    pub fn warnSize(self: Request, measurement: []const u8, actual: u64, threshold: u64) void {
        if (actual <= threshold) return;
        if (self.size_context) |context| {
            context.warnSize("model.request", measurement, actual, threshold);
        } else {
            services.logSizeWarning(.{ .operation = "model.request", .measurement = measurement, .actual = actual, .threshold = threshold, .request_id = self.id, .principal = 0 });
        }
    }
};

/// Recover transport interruptions, not cancellation, resource limits, policy,
/// TLS validation, malformed configuration, or protocol-integrity failures.
pub fn transientError(err: anyerror) bool {
    return switch (err) {
        error.CredentialRefreshUnavailable, error.Timeout, error.ConnectionTimedOut, error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionClosed, error.BrokenPipe, error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown, error.TemporaryNameServerFailure, error.NameServerFailure, error.ReadFailed, error.WriteFailed, error.EndOfStream, error.ClosedBeforeCompletedResponse, error.TruncatedStream, error.MissingCompletedResponse, error.TlsConnectionTruncated => true,
        // std.http erases TLS handshake causes into this error, including a
        // peer disconnect. Retry without ever weakening certificate validation.
        error.TlsInitializationFailed => true,
        else => false,
    };
}

/// Retry-After delta-seconds or IMF-fixdate; malformed hints are ignored and
/// valid waits are bounded to five minutes. No allocation or locale dependency.
pub fn retryAfterMilliseconds(raw: []const u8, now_seconds: i64) ?u32 {
    const text = std.mem.trim(u8, raw, " \t");
    if (std.fmt.parseInt(u64, text, 10)) |seconds| {
        const bounded: u64 = if (seconds < 300) seconds else 300;
        return @intCast(bounded * 1000);
    } else |_| {}
    if (text.len != 29 or !std.mem.eql(u8, text[25..], " GMT") or text[3] != ',' or text[4] != ' ' or text[7] != ' ' or text[11] != ' ' or text[16] != ' ' or text[19] != ':' or text[22] != ':') return null;
    const year = std.fmt.parseInt(u64, text[12..16], 10) catch return null;
    const day = std.fmt.parseInt(u64, text[5..7], 10) catch return null;
    const hour = std.fmt.parseInt(u64, text[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u64, text[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u64, text[23..25], 10) catch return null;
    if (year < 1970 or hour > 23 or minute > 59 or second > 59 or day < 1) return null;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const lengths = [_]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var days: u64 = 365 * (year - 1970) + ((year - 1) / 4 - 1969 / 4) - ((year - 1) / 100 - 1969 / 100) + ((year - 1) / 400 - 1969 / 400);
    for (months, lengths) |month, length| {
        if (std.mem.eql(u8, month, text[8..11])) {
            if (day > length) return null;
            const epoch: i64 = @intCast((days + day - 1) * 86400 + hour * 3600 + minute * 60 + second);
            const wait: i64 = @max(0, epoch -| now_seconds);
            const bounded: i64 = if (wait < 300) wait else 300;
            return @intCast(bounded * 1000);
        }
        days += length;
    }
    return null;
}

pub const Deadline = struct {
    stop: std.Io.Event = .unset,
    expired: std.atomic.Value(bool) = .init(false),

    pub fn run(self: *Deadline, io: std.Io, connection: *std.http.Client.Connection, timeout: std.Io.Clock.Duration) void {
        self.stop.waitTimeout(io, .{ .duration = timeout }) catch |err| switch (err) {
            error.Timeout => {
                self.expired.store(true, .release);
                connection.stream_reader.stream.shutdown(io, .both) catch {};
            },
            else => {},
        };
    }
};

pub fn remoteResponse(a: std.mem.Allocator, stage: []const u8, status: u16, body: std.json.Value, hint: u32) !agent.AdapterResponse {
    const reason = responses.rejection(status, body);
    // Recognized context overflow is delivered to the application for compaction.
    if ((status >= 300 or field(body, "error") != .null) and !responses.isOverflow(body)) {
        std.log.warn("provider {s}: status={d} cause={s} retryable={} retry_after_ms={d}", .{ stage, status, if (reason) |r| @tagName(r) else if (status == 429) "rate_limit" else "provider_rejection", responses.retryableResponse(status, body), hint });
    }
    if (body != .object) {
        const message = if (reason) |r| r.message() else if (status == 429) "Provider rate limit reached." else "Provider returned an unsuccessful HTTP status without a structured error.";
        return .{ .json = try std.json.Stringify.valueAlloc(a, .{ .status = status, .body = .{ .@"error" = .{ .code = "http_status", .message = message } }, .retry_after_ms = hint }, .{}) };
    }
    return .{ .json = try std.json.Stringify.valueAlloc(a, .{ .status = status, .body = body, .retry_after_ms = hint }, .{}) };
}

pub fn errorResponse(a: std.mem.Allocator, code: []const u8, message: []const u8) !agent.AdapterResponse {
    // Transport-generated codes and messages only; never log remote payloads or headers.
    std.log.warn("provider transport: {s}: {s}", .{ code, message });
    return .{ .json = try std.json.Stringify.valueAlloc(a, .{ .code = code, .message = message }, .{}), .failed = true };
}
