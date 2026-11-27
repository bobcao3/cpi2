const std = @import("std");
const json_text = @import("json_tree").text;
const agent = @import("config.zig");
const provider = @import("provider_settings.zig");
pub const Provider = provider.Provider;
pub const Transport = provider.Transport;
pub const CodexTransportPreference = enum(u8) {
    configured,
    http,
    websocket,
    @"websocket-cached",

    pub fn fromTransport(value: Transport) CodexTransportPreference {
        return switch (value) {
            .http => .http,
            .websocket => .websocket,
            .@"websocket-cached" => .@"websocket-cached",
        };
    }

    fn override(self: CodexTransportPreference, mode: Mode) ?Transport {
        if (mode != .live or mode.live.protocol != .codex) return null;
        return switch (self) {
            .configured => null,
            .http => .http,
            .websocket => .websocket,
            .@"websocket-cached" => .@"websocket-cached",
        };
    }
};
pub const Protocol = provider.Protocol;
pub const default_base_url = provider.default_base_url;
pub const codex_base_url = provider.codex_base_url;
pub const credential_label = provider.credential_label;
const responses = @import("responses.zig");
const services = @import("services");

/// Bounded retry policy for one provider route. `max_attempts` counts the
/// initial request, so 1 disables retries. Delays grow exponentially from
/// `initial_delay_ms` and never exceed `max_delay_ms`.
pub const Retry = struct {
    max_attempts: u8 = 1,
    initial_delay_ms: u32 = 250,
    max_delay_ms: u32 = 4000,

    pub fn validate(self: Retry) !void {
        if (self.max_attempts == 0 or self.max_attempts > 8 or
            self.initial_delay_ms > self.max_delay_ms or self.max_delay_ms > 5 * 60 * 1000)
            return error.InvalidRetryPolicy;
    }

    /// Jitter the backoff without undershooting the server's Retry-After.
    /// Server hints are independently bounded to five minutes.
    pub fn delay(self: Retry, io: std.Io, index: u8, hint: u32) u32 {
        const base: u32 = @intCast(self.delayMilliseconds(index));
        var random: [1]u8 = undefined;
        io.random(&random);
        const jitter: u32 = @intCast(@as(u64, base) * random[0] / 1020);
        return @min(300000, @max(@min(self.max_delay_ms, base +| jitter), hint));
    }

    /// `retry_index` is one-based: 1 is the delay before the second attempt.
    pub fn delayMilliseconds(self: Retry, retry_index: u8) i64 {
        if (retry_index == 0) return 0;
        var wait_ms: i64 = self.initial_delay_ms;
        var index: u8 = 1;
        while (index < retry_index) : (index += 1) {
            if (wait_ms >= self.max_delay_ms) return self.max_delay_ms;
            wait_ms = @min(wait_ms * 2, @as(i64, self.max_delay_ms));
        }
        return @min(wait_ms, @as(i64, self.max_delay_ms));
    }
};

pub const Prepare = struct {
    context: ?*anyopaque,
    /// Called only after admission/route validation. `force` is one provider
    /// 401 refresh opportunity, never permission to change provider/account.
    call: *const fn (?*anyopaque, std.Io, bool) anyerror!void,
    can_refresh: ?*const fn (?*anyopaque) bool = null,
};
pub const PayloadHook = @import("responses_transport.zig").PayloadHook;
pub const CodexSessions = @import("CodexSessions.zig");

/// A route may start a job and return an opaque JSON reference to it. The
/// reference must be durable, non-secret, and usable after process restart.
pub const DeferredAdapter = struct {
    id: []const u8,
    context: ?*anyopaque = null,
    start: *const fn (?*anyopaque, Call) anyerror!Reply,
    poll: *const fn (?*anyopaque, Call, Value) anyerror!Reply,
    cancel: *const fn (?*anyopaque, Cancel) anyerror!BackgroundCancellation,

    pub const Call = struct {
        host: services.Context,
        request: Service.Args,
        provider: ?*const Provider,
        payload_hooks: []const PayloadHook = &.{},

        pub fn preparePayload(self: Call, payload: Value) !Value {
            if (self.payload_hooks.len == 0) return payload;
            const model = objectField(self.request.body, "model") orelse .null;
            return PayloadHook.apply(self.payload_hooks, self.host.allocator, self.host.io, .{
                .model = if (model == .string) model.string else "",
                .dialect = if (self.provider) |settings| settings.protocol else .responses,
                .transport = .deferred,
                .payload = payload,
            });
        }
    };
    pub const Cancel = struct { allocator: std.mem.Allocator, io: Io, provider: *const Provider, handle: Value };
    pub const Reply = union(enum) {
        /// Use the model service's normalized response envelope.
        complete: Service.Result,
        pending: struct { handle: Value, poll_after_ms: ?u32 = null },
        retry: u32,
        /// The job is definitively unavailable. The harness may start fresh.
        lost,
    };
};

pub fn validDeferredAdapterId(id: []const u8) bool {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

pub const Route = struct {
    base_url: []const u8,
    credential: []const u8 = "",
    transport: Effects,
    retry: Retry = .{},
    retry_mode: enum { automatic, resume_only } = .automatic,
    prepare: ?Prepare = null,
    deferred: ?DeferredAdapter = null,
};
/// Resolve a host selection using request-owned memory. Neither the route
/// nor any transport credential may borrow a shorter-lived allocation.
pub const ResolveRoute = struct {
    context: ?*anyopaque,
    call: *const fn (?*anyopaque, services.Context, Value) anyerror!?Route,
};

pub const Service = struct {
    resolve_route: ?ResolveRoute = null,
    routes: []const Route,
    preview: ?Preview = null,
    payload_hooks: []const PayloadHook = &.{},
    codex_sessions: ?*CodexSessions = null,
    codex_transport_preference: ?*const std.atomic.Value(CodexTransportPreference) = null,
    pub const Args = struct {
        url: []const u8,
        credential: []const u8 = "",
        body: Value,
        before_send: ?bool = null,
        pub fn validate(self: Args) !void {
            if (self.body != .object) return error.InvalidArguments;
        }
    };
    pub const Result = struct {
        status: u16,
        body: Value,
        retryable: ?bool = null,
        retry_after_ms: u32 = 0,
        next_poll_ms: ?u64 = null,
    };
    pub const operation = services.Operation.define("model.request", Service, Args, Result, .{ .arguments = max_body + 16384, .result = max_response + 16384 }, .never, request);
    pub fn service(self: *Service) services.Service {
        return .{ .context = self, .operations = &.{&operation} };
    }
    pub fn matches(self: *const Service, model: agent.Model) bool {
        for (self.routes) |route| if (std.mem.eql(u8, route.base_url, model.base_url) and std.mem.eql(u8, route.credential, model.credential)) return true;
        return false;
    }
    fn request(self: *Service, c: services.Context, args: Args) !Result {
        if (c.model_selection) |selection| {
            const resolve = self.resolve_route orelse return error.PermissionDenied;
            const resolved = resolve.call(resolve.context, c, selection) catch |err| {
                if (!transientError(err)) return err;
                return waitForRoute(c, @errorName(err), 0);
            };
            const route = resolved orelse return waitForRoute(c, "model_credentials_unavailable", 0);
            if (!try routeMatches(c.allocator, route, args)) return error.PermissionDenied;
            return self.requestRoute(c, args, route);
        }
        for (self.routes) |route| {
            if (try routeMatches(c.allocator, route, args)) return self.requestRoute(c, args, route);
        }
        return error.UnregisteredProvider;
    }

    fn routeMatches(a: std.mem.Allocator, route: Route, args: Args) !bool {
        const url = try @import("responses.zig").url(a, .{ .base_url = route.base_url });
        defer a.free(url);
        return std.mem.eql(u8, args.url, url) and std.mem.eql(u8, args.credential, route.credential);
    }

    fn requestRoute(self: *Service, c: services.Context, args: Args, route: Route) !Result {
        if (route.transport.mode == .live) {
            const settings = route.transport.mode.live;
            c.warnSize("provider configuration", "URL bytes", settings.base_url.len, 4096);
            if (objectField(args.body, "model")) |model| {
                if (model == .string) c.warnSize("provider configuration", "model bytes", model.string.len, 512);
            }
            c.warnSize("provider configuration", "credential bytes", settings.api_key.len, 8192);
            if (settings.account_id) |account| c.warnSize("provider configuration", "account identifier bytes", account.len, 256);
        }
        var scoped: ScopedPreview = .{ .target = self.preview, .scope = c.scope, .principal = c.principal };
        try route.retry.validate();
        const attempts = route.retry.max_attempts;
        const harness_retries = route.retry_mode == .resume_only;
        const id = if (c.request_id.len > 0) c.request_id else c.idempotency_key;
        const native_resume = switch (route.transport.mode) {
            .live => |settings| settings.supportsNativeResume(),
            .fixture => false,
        };
        if (c.model_resume) |saved| {
            const same_route = std.mem.eql(u8, std.mem.trimEnd(u8, saved.route, "/"), std.mem.trimEnd(u8, route.base_url, "/")) and
                std.mem.eql(u8, saved.credential, route.credential);
            if (saved.progress.deferred) |deferred| {
                const adapter = route.deferred orelse return waitForRoute(c, "deferred_adapter_unavailable", 0);
                if (!same_route or !std.mem.eql(u8, deferred.adapter, adapter.id)) return waitForRoute(c, "deferred_adapter_unavailable", 0);
                return requestDeferred(c, args, route, adapter, saved.progress, &.{});
            }
            if (!native_resume or !same_route) return harnessFailure(c.allocator, "model_resume_unavailable", true);
            const packet = try services.json.encode(c.allocator, args);
            if (c.defer_model_poll and saved.progress.reattach == .stream) return resumeStream(c, route, id, packet, saved.progress, &scoped);
            return poll(c, route, id, packet, saved.progress);
        }
        const payload_hooks = if (args.before_send == true) self.payload_hooks else &.{};
        if (!c.immediate_model) if (route.deferred) |adapter| return requestDeferred(c, args, route, adapter, null, payload_hooks);
        const preference = if (self.codex_transport_preference) |value| value.load(.monotonic).override(route.transport.mode) else null;
        const packet = try services.json.encode(c.allocator, args);
        var recovery: Decoder = .{
            .allocator = c.allocator,
            .preview = if (self.preview == null) null else .{ .context = &scoped, .notify = ScopedPreview.notify },
            .request_id = id,
            .native_resume = native_resume,
            .progress = c.model_progress,
        };
        defer recovery.deinit();
        var attempt: u8 = 0;
        var force_refresh = false;
        var refreshed_rejection = false;
        while (attempt < attempts) : (attempt += 1) {
            try c.io.checkCancel();
            const resuming = recovery.canResume();
            if (route.prepare) |prepare| prepare.call(prepare.context, c.io, force_refresh) catch |err| {
                try c.io.checkCancel();
                if (harness_retries and transientError(err) and (!resuming or attempt + 1 >= attempts)) {
                    return harnessFailure(c.allocator, @errorName(err), true);
                }
                if (!transientError(err) or attempt + 1 >= attempts) return err;
                try backoff(c, &scoped, id, route.retry, attempt + 1, 0, &recovery);
                continue;
            };
            force_refresh = false;
            var transport = route.transport;
            transport.codex_transport_override = preference;
            if (self.codex_sessions) |sessions| {
                if (c.model_session_id) |session_id| transport.codex_session = .{ .sessions = sessions, .id = session_id };
            }
            transport.size_context = c;
            transport.payload_hooks = payload_hooks;
            transport.preview = if (self.preview == null) null else .{ .context = &scoped, .notify = ScopedPreview.notify };
            transport.resume_state = if (native_resume) &recovery else null;
            scoped.failed = false;
            const response = transportCall(&transport, c.allocator, c.io, .{ .request_id = id, .json = packet }) catch |err| {
                try c.io.checkCancel();
                if (recovery.progress_failure != null) return err;
                if (c.defer_model_poll and !scoped.failed and transientError(err) and recovery.canResume()) {
                    return scheduleStream(c, route.retry, attempt + 1, 0, &recovery);
                }
                if (harness_retries and !scoped.failed and transientError(err) and
                    (!recovery.canResume() or attempt + 1 >= attempts))
                {
                    return harnessFailure(c.allocator, @errorName(err), true);
                }
                if (scoped.failed or err == error.Canceled or err == error.OutOfMemory or !transientError(err)) return err;
                std.log.debug("provider transport attempt {d}/{d} failed: {s}", .{ attempt + 1, attempts, @errorName(err) });
                if (attempt + 1 >= attempts) return err;
                try backoff(c, &scoped, id, route.retry, attempt + 1, 0, &recovery);
                continue;
            };
            defer c.allocator.free(response.json);
            try c.io.checkCancel();
            const refresh_allowed = if (route.prepare) |prepare| (if (prepare.can_refresh) |allowed| allowed(prepare.context) else true) else false;
            const renew = refresh_allowed and !refreshed_rejection and try authenticationRejected(c.allocator, response.json);
            const retryable = !scoped.failed and !recovery.completed() and
                (renew or (if (response.failed) try retryableFailure(c.allocator, response.json) else try retryableEnvelope(c.allocator, response.json)));
            if (c.defer_model_poll and retryable and recovery.canResume()) {
                return scheduleStream(c, route.retry, attempt + 1, try retryHint(c.allocator, response.json), &recovery);
            }
            if (retryable and attempt + 1 < attempts and (!harness_retries or renew or recovery.canResume())) {
                if (renew) {
                    force_refresh = true;
                    refreshed_rejection = true;
                }
                const hint = try retryHint(c.allocator, response.json);
                try backoff(c, &scoped, id, route.retry, attempt + 1, hint, &recovery);
                continue;
            }
            if (harness_retries) {
                const hint = try retryHint(c.allocator, response.json);
                if (response.failed) {
                    const failure = try json_text.parseFromSliceLeaky(Value, c.allocator, response.json, .{ .allocate = .alloc_always });
                    return .{
                        .status = 502,
                        .body = try services.json.value(c.allocator, .{ .@"error" = failure }),
                        .retryable = try retryableFailure(c.allocator, response.json),
                        .retry_after_ms = hint,
                    };
                }
                var result = try json_text.parseFromSliceLeaky(Result, c.allocator, response.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
                result.retryable = (try retryableEnvelope(c.allocator, response.json)) or
                    (resuming and (result.status == 404 or result.status == 410));
                result.retry_after_ms = hint;
                return result;
            }
            if (response.failed) return error.ProviderTransport;
            return json_text.parseFromSliceLeaky(Result, c.allocator, response.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        }
        return error.ProviderTransport;
    }
};

fn requestDeferred(c: services.Context, args: Service.Args, route: Route, adapter: DeferredAdapter, saved: ?services.ModelProgress, payload_hooks: []const PayloadHook) !Service.Result {
    const sink = c.model_progress orelse return error.DeferredProviderRequiresJournal;
    if (!c.defer_model_poll or c.model_attempt_key.len == 0) return error.DeferredProviderRequiresJournal;
    if (!validDeferredAdapterId(adapter.id)) return error.InvalidDeferredAdapter;
    try c.io.checkCancel();
    if (saved) |progress| if (progress.next_poll_ms) |wake| {
        if (wake > realMilliseconds(c.io)) return pendingPoll(wake);
    };
    const call: DeferredAdapter.Call = .{
        .host = c,
        .request = args,
        .provider = if (route.transport.mode == .live) route.transport.mode.live else null,
        .payload_hooks = payload_hooks,
    };
    if (route.prepare) |prepare| prepare.call(prepare.context, c.io, false) catch |err| {
        try c.io.checkCancel();
        if (!transientError(err)) return err;
        return waitForRoute(c, @errorName(err), 0);
    };
    const response = if (saved) |progress| adapter.poll(adapter.context, call, progress.deferred.?.handle) else adapter.start(adapter.context, call);
    const reply = response catch |err| {
        try c.io.checkCancel();
        if (!transientError(err)) return err;
        return retryDeferred(c, sink, route.retry, saved, @errorName(err), 0);
    };
    return switch (reply) {
        .complete => |result| if (result.next_poll_ms == null) result else error.InvalidDeferredResult,
        .pending => |pending| blk: {
            const cursor = if (saved) |progress| try std.math.add(u64, progress.cursor, 1) else 0;
            break :blk saveDeferred(c, sink, .{
                .cursor = cursor,
                .deferred = .{ .adapter = adapter.id, .handle = pending.handle },
            }, saved, pending.poll_after_ms orelse 5000);
        },
        .retry => |hint| retryDeferred(c, sink, route.retry, saved, "deferred_provider_retry", hint),
        .lost => harnessFailure(c.allocator, "deferred_job_unavailable", true),
    };
}

fn retryDeferred(c: services.Context, sink: services.ModelProgressSink, retry: Retry, saved: ?services.ModelProgress, code: []const u8, hint: u32) !Service.Result {
    if (saved) |current| {
        var progress = current;
        const count = (progress.poll_failures orelse 0) +| 1;
        progress.poll_failures = count;
        return saveDeferred(c, sink, progress, saved, @max(500, retry.delay(c.io, count, hint)));
    }
    var result = try harnessFailure(c.allocator, code, true);
    result.retry_after_ms = hint;
    return result;
}

fn saveDeferred(c: services.Context, sink: services.ModelProgressSink, record: services.ModelProgress, previous: ?services.ModelProgress, delay_ms: u32) !Service.Result {
    var progress = record;
    const last = if (previous) |saved| saved.next_poll_ms orelse 0 else 0;
    const wake = @max(last, realMilliseconds(c.io)) +| @max(1, delay_ms);
    progress.next_poll_ms = wake;
    try sink.write(sink.context, progress);
    return pendingPoll(wake);
}

fn pendingPoll(wake: u64) Service.Result {
    return .{ .status = 202, .body = .null, .next_poll_ms = wake };
}

fn waitForRoute(c: services.Context, code: []const u8, hint: u32) !Service.Result {
    try c.io.checkCancel();
    if (c.defer_model_poll) if (c.model_resume) |saved| {
        const now = realMilliseconds(c.io);
        var progress = saved.progress;
        if (progress.next_poll_ms) |wake| if (wake > now) return pendingPoll(wake);
        progress.next_poll_ms = now +| @max(30000, hint);
        const sink = c.model_progress orelse return error.MissingModelProgressSink;
        try sink.write(sink.context, progress);
        return pendingPoll(progress.next_poll_ms.?);
    };
    var failure = try harnessFailure(c.allocator, code, true);
    failure.retry_after_ms = hint;
    return failure;
}

fn scheduleStream(c: services.Context, retry: Retry, attempt: u8, hint: u32, recovery: *Decoder) !Service.Result {
    try c.io.checkCancel();
    const wake = realMilliseconds(c.io) +| retry.delay(c.io, attempt, hint);
    try recovery.checkpoint(wake, true);
    return pendingPoll(wake);
}

fn resumeStream(c: services.Context, route: Route, id: []const u8, packet: []const u8, saved: services.ModelProgress, preview: *ScopedPreview) !Service.Result {
    try c.io.checkCancel();
    if (saved.next_poll_ms) |wake| if (wake > realMilliseconds(c.io)) return pendingPoll(wake);
    const cursor = std.math.cast(i64, saved.cursor) orelse return error.InvalidResumeCursor;
    var decoder: Decoder = .{
        .allocator = c.allocator,
        .preview = if (preview.target != null) .{ .context = preview, .notify = ScopedPreview.notify } else null,
        .request_id = id,
        .native_resume = true,
        .response_id = try c.allocator.dupe(u8, saved.response_id),
        .sequence_number = cursor,
        .progress = c.model_progress,
    };
    defer decoder.deinit();
    var transport = route.transport;
    transport.size_context = c;
    transport.resume_state = &decoder;
    transport.preview = decoder.preview;
    const outcome = pollAttempt(c.io, c.allocator, route, &transport, id, packet, false);
    var hint: u32 = 0;
    if (outcome) |response| {
        defer c.allocator.free(response.json);
        try c.io.checkCancel();
        if (preview.failed) return error.NotificationDeliveryFailed;
        if (!response.failed) {
            var terminal = try json_text.parseFromSliceLeaky(Service.Result, c.allocator, response.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
            if (decoder.completed() or responses.rejection(terminal.status, terminal.body) != null) {
                terminal.retryable = responses.retryableResponse(terminal.status, terminal.body);
                return terminal;
            }
        }
        hint = try retryHint(c.allocator, response.json);
    } else |err| {
        try c.io.checkCancel();
        if (preview.failed or decoder.progress_failure != null or !transientError(err)) return err;
        if (err == error.CredentialRefreshUnavailable) return waitForRoute(c, @errorName(err), 0);
    }

    // Some endpoints can retrieve a response even when stream replay fails.
    // Journal the change before releasing the attempt so recovery uses retrieval.
    const wake = realMilliseconds(c.io) +| route.retry.delay(c.io, 1, hint);
    try decoder.checkpoint(wake, false);
    return pendingPoll(wake);
}

fn poll(c: services.Context, route: Route, id: []const u8, packet: []const u8, saved: services.ModelProgress) !Service.Result {
    var transport = route.transport;
    transport.size_context = c;
    transport.poll_response_id = saved.response_id;
    var deadline = saved.next_poll_ms;
    var failures: u8 = saved.poll_failures orelse 0;
    var force_refresh = false;
    var refreshed_rejection = false;
    while (true) {
        try c.io.checkCancel();
        if (deadline) |wake| {
            const now = realMilliseconds(c.io);
            if (wake > now) {
                if (c.defer_model_poll) return pendingPoll(wake);
                try Io.sleep(c.io, .fromMilliseconds(@intCast(wake - now)), .awake);
            }
        }
        var iteration = std.heap.ArenaAllocator.init(c.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();
        const outcome = pollAttempt(c.io, a, route, &transport, id, packet, force_refresh);
        force_refresh = false;
        var hint: u32 = 0;
        if (outcome) |response| {
            try c.io.checkCancel();
            hint = try retryHint(a, response.json);
            const refresh_allowed = if (route.prepare) |prepare| (if (prepare.can_refresh) |allowed| allowed(prepare.context) else true) else false;
            if (try authenticationRejected(a, response.json)) {
                if (!refreshed_rejection and refresh_allowed) {
                    refreshed_rejection = true;
                    force_refresh = true;
                    deadline = null;
                    continue;
                }
            }
            if (response.failed) {
                if (!try retryableFailure(a, response.json)) {
                    const failure = try json_text.parseFromSliceLeaky(Value, c.allocator, response.json, .{ .allocate = .alloc_always });
                    return .{ .status = 502, .body = try services.json.value(c.allocator, .{ .@"error" = failure }), .retryable = false };
                }
                failures +|= 1;
            } else {
                const result = try json_text.parseFromSliceLeaky(Service.Result, a, response.json, .{ .ignore_unknown_fields = true });
                if (result.status >= 200 and result.status < 300) {
                    const identity = objectField(result.body, "id") orelse Value.null;
                    if (identity != .string or !std.mem.eql(u8, identity.string, saved.response_id))
                        return harnessFailure(c.allocator, "resume_generation_mismatch", true);
                    const status = objectField(result.body, "status") orelse Value.null;
                    if (status != .string or (!std.mem.eql(u8, status.string, "queued") and !std.mem.eql(u8, status.string, "in_progress"))) {
                        var terminal = try json_text.parseFromSliceLeaky(Service.Result, c.allocator, response.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
                        terminal.retryable = responses.retryableBody(result.body);
                        return terminal;
                    }
                    failures = 0;
                } else if (responses.retryableResponse(result.status, result.body)) {
                    failures +|= 1;
                } else {
                    var terminal = try json_text.parseFromSliceLeaky(Service.Result, c.allocator, response.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
                    terminal.retryable = result.status == 404 or result.status == 405 or result.status == 410;
                    terminal.retry_after_ms = hint;
                    return terminal;
                }
            }
        } else |err| {
            if (!transientError(err)) return err;
            if (c.defer_model_poll and err == error.CredentialRefreshUnavailable) return waitForRoute(c, @errorName(err), 0);
            failures +|= 1;
        }
        if (failures >= route.retry.max_attempts) {
            var exhausted = try harnessFailure(c.allocator, "model_resume_exhausted", true);
            exhausted.retry_after_ms = hint;
            return exhausted;
        }
        const delay = @max(500, route.retry.delay(c.io, failures, hint));
        const wake = realMilliseconds(c.io) +| delay;
        if (c.model_progress) |sink| try sink.write(sink.context, .{
            .response_id = saved.response_id,
            .cursor = saved.cursor,
            .next_poll_ms = wake,
            .poll_failures = if (c.defer_model_poll and failures != 0) failures else null,
        });
        if (c.defer_model_poll) return pendingPoll(wake);
        deadline = wake;
    }
}

fn pollAttempt(io: Io, a: std.mem.Allocator, route: Route, transport: *Effects, id: []const u8, packet: []const u8, force_refresh: bool) !agent.AdapterResponse {
    if (route.prepare) |prepare| try prepare.call(prepare.context, io, force_refresh);
    return transportCall(transport, a, io, .{ .request_id = id, .json = packet });
}

fn realMilliseconds(io: Io) u64 {
    return @intCast(@max(0, Io.Clock.real.now(io).toMilliseconds()));
}

fn harnessFailure(a: std.mem.Allocator, code: []const u8, retryable: bool) !Service.Result {
    return .{ .status = 502, .body = try services.json.value(a, .{ .@"error" = .{ .code = code } }), .retryable = retryable };
}
pub const Preview = responses.Preview;
/// The SSE decoder of a Responses stream. A transport that reads event streams
/// outside `Effects` uses it to reach the same preview vocabulary.
pub const Decoder = @import("responses_http.zig").Decoder;
const ScopedPreview = struct {
    target: ?Preview,
    scope: u64,
    principal: u64,
    failed: bool = false,

    fn notify(raw: ?*anyopaque, request_id: []const u8, update: Preview.Update) !void {
        const self: *ScopedPreview = @ptrCast(@alignCast(raw.?));
        const target = self.target.?;
        errdefer self.failed = true;
        if (target.notify_scoped) |notify_scoped| return notify_scoped(target.context, self.scope, self.principal, request_id, update);
        return target.notify(target.context, request_id, update);
    }
};

fn backoff(c: services.Context, preview: *ScopedPreview, id: []const u8, retry: Retry, index: u8, hint: u32, recovery: *Decoder) !void {
    try c.io.checkCancel();
    const delay = retry.delay(c.io, index, hint);
    const resuming = recovery.canResume();
    if (resuming and recovery.progress != null) {
        try recovery.checkpoint(realMilliseconds(c.io) +| delay, false);
    }
    if (preview.target != null) try ScopedPreview.notify(preview, id, .{ .retrying = .{ .attempt = index + 1, .max_attempts = retry.max_attempts, .delay_ms = delay, .resuming = resuming } });
    if (delay != 0) try Io.sleep(c.io, .fromMilliseconds(delay), .awake);
}

pub const transientError = @import("responses_transport.zig").transientError;
pub const retryAfterMilliseconds = @import("responses_transport.zig").retryAfterMilliseconds;

fn responseFields(comptime Field: type, a: std.mem.Allocator, json: []const u8) !std.EnumArray(Field, ?json_text.Cursor.Raw) {
    var local: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&local, a);
    var window: json_text.Cursor.Window = undefined;
    var cursor = json_text.Cursor.init(json, &window, scratch.allocator());
    defer cursor.deinit();
    return cursor.select(Field) catch |err| switch (err) {
        // A non-object response has no named fields. Still check its syntax.
        error.UnexpectedToken => blk: {
            try cursor.skip();
            try cursor.finish();
            break :blk .initFill(null);
        },
        else => return err,
    };
}

fn authenticationRejected(a: std.mem.Allocator, json: []const u8) !bool {
    const fields = responseFields(enum { status, http_status }, a, json) catch return false;
    const status = fields.get(.status) orelse fields.get(.http_status) orelse return false;
    return status.integer() == 401;
}

fn retryHint(a: std.mem.Allocator, json: []const u8) !u32 {
    const fields = responseFields(enum { retry_after_ms }, a, json) catch return 0;
    const hint = (fields.get(.retry_after_ms) orelse return 0).integer() orelse return 0;
    return @intCast(std.math.clamp(hint, 0, 300000));
}

fn retryableFailure(allocator: std.mem.Allocator, json: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fields = try responseFields(enum { code }, allocator, json);
    const code = try (fields.get(.code) orelse return false).string(arena.allocator());
    return responses.retryableFailureCode(code orelse return false);
}

fn retryableEnvelope(allocator: std.mem.Allocator, json: []const u8) !bool {
    const fields = responseFields(enum { status, body }, allocator, json) catch return false;
    const status = (fields.get(.status) orelse return false).integer() orelse return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // The body participates in rejection classification; decode it only when
    // we have a usable status, and leave unrelated envelope values unparsed.
    const body = if (fields.get(.body)) |raw| raw.parse(Value, arena.allocator(), .{}) catch return false else .null;
    return responses.retryableResponse(status, body);
}

const Io = std.Io;
const Value = std.json.Value;

pub const max_body = @import("responses_transport.zig").max_body;
pub const max_response = @import("responses_transport.zig").max_response;
const fixture_deadline: Io.Clock.Duration = .{ .raw = .fromSeconds(10), .clock = .awake };
const live_deadline: Io.Clock.Duration = .{ .raw = .fromSeconds(60), .clock = .awake };

pub const Mode = union(enum) {
    live: *const provider.Provider,
    fixture: Fixture,
};

pub const Fixture = struct {
    host: []const u8,
    port: u16,
};

pub const Effects = struct {
    workspace: []const u8,
    mode: Mode,
    preview: ?Preview = null,
    request_reasoning_summary: bool = false,
    codex_sse_fallback: bool = false,
    codex_session: ?CodexSessions.Session = null,
    codex_transport_override: ?Transport = null,
    credential_override: ?[]const u8 = null,
    fixture_transport: provider.Transport = .http,
    resume_state: ?*Decoder = null,
    poll_response_id: ?[]const u8 = null,
    cancel_response_id: ?[]const u8 = null,
    size_context: ?services.Context = null,
    payload_hooks: []const PayloadHook = &.{},

    fn transportKind(self: *const Effects) provider.Transport {
        return switch (self.mode) {
            .live => |settings| if (settings.protocol == .codex) self.codex_transport_override orelse settings.transport else settings.transport,
            .fixture => self.fixture_transport,
        };
    }

    pub fn initLive(workspace: []const u8, settings: *const provider.Provider) Effects {
        return .{ .workspace = workspace, .mode = .{ .live = settings } };
    }

    pub fn initFixture(allocator: std.mem.Allocator, workspace: []const u8, url: []const u8) !Effects {
        const fixture = try parseFixture(allocator, url);
        return .{ .workspace = workspace, .mode = .{ .fixture = fixture } };
    }
};

pub const BackgroundCancellation = struct {
    status: enum { settled, retry, unauthorized, unavailable, rejected },
    retry_after_ms: u32 = 0,
};

pub fn cancelDeferred(adapter: DeferredAdapter, call: DeferredAdapter.Cancel) !BackgroundCancellation {
    try call.io.checkCancel();
    return adapter.cancel(adapter.context, call) catch |err| {
        if (transientError(err)) return .{ .status = .retry };
        return err;
    };
}

/// Cancel a known provider job through the same configured first-party route
/// and credential checks used for generation. The endpoint is idempotent.
pub fn cancelBackground(a: std.mem.Allocator, io: Io, settings: *const Provider, id: []const u8) !BackgroundCancellation {
    if (!settings.supportsNativeResume()) return error.InvalidResume;
    var effects = Effects.initLive("", settings);
    effects.cancel_response_id = id;
    const packet = try services.json.encode(a, .{ .url = settings.responses_url, .credential = settings.credentialLabel(), .body = std.json.Value{ .object = .empty } });
    defer a.free(packet);
    const response = transportCall(&effects, a, io, .{ .request_id = id, .json = packet }) catch |err| {
        if (transientError(err)) return .{ .status = .retry };
        return err;
    };
    defer a.free(response.json);
    if (response.failed) return .{ .status = if (try retryableFailure(a, response.json)) .retry else .rejected };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const result = try json_text.parseFromSliceLeaky(Service.Result, arena.allocator(), response.json, .{ .ignore_unknown_fields = true });
    const retry: BackgroundCancellation = .{ .status = .retry, .retry_after_ms = result.retry_after_ms };
    if (responses.retryableResponse(result.status, result.body)) return retry;
    if (result.status == 401) return .{ .status = .unauthorized };
    if (result.status == 404 or result.status == 410) return .{ .status = .unavailable };
    if (result.status < 200 or result.status >= 300) return .{ .status = .rejected };
    const returned = objectField(result.body, "id") orelse return .{ .status = .rejected };
    const status = objectField(result.body, "status") orelse return .{ .status = .rejected };
    if (returned != .string or !std.mem.eql(u8, returned.string, id) or status != .string) return .{ .status = .rejected };
    for ([_][]const u8{ "cancelled", "completed", "failed", "incomplete" }) |terminal| {
        if (std.mem.eql(u8, status.string, terminal)) return .{ .status = .settled };
    }
    return retry;
}

fn parseFixture(allocator: std.mem.Allocator, url: []const u8) !Fixture {
    const uri = std.Uri.parse(url) catch return error.InvalidFixtureUrl;
    if (!std.mem.eql(u8, uri.scheme, "http")) return error.InvalidFixtureUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidFixtureUrl;
    if (uri.host == null or uri.port == null) return error.InvalidFixtureUrl;
    const host = switch (uri.host.?) {
        .raw, .percent_encoded => |text| text,
    };
    if (std.mem.findScalar(u8, host, '%') != null) return error.InvalidFixtureUrl;
    const bare = if (host.len > 1 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (!isLoopback(bare)) return error.InvalidFixtureUrl;
    return .{
        .host = try allocator.dupe(u8, bare),
        .port = uri.port.?,
    };
}

fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "::1")) return true;
    const address = std.Io.net.Ip4Address.parse(host, 0) catch return false;
    return std.mem.eql(u8, &address.bytes, &.{ 127, 0, 0, 1 });
}

fn hostText(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    const text = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    if (std.mem.findScalar(u8, text, '%') != null) return null;
    if (text.len > 1 and text[0] == '[' and text[text.len - 1] == ']') return text[1 .. text.len - 1];
    return text;
}

const errorResponse = @import("responses_transport.zig").errorResponse;

fn objectField(value: Value, name: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn transportCall(context: ?*anyopaque, allocator: std.mem.Allocator, io: Io, request: agent.AdapterRequest) !agent.AdapterResponse {
    const self: *Effects = @ptrCast(@alignCast(context.?));
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const packet = json_text.parseFromSlice(Value, arena, request.json, .{ .allocate = .alloc_if_needed }) catch
        return errorResponse(allocator, "invalid_request", "Adapter packet is not JSON.");
    const url = switch (objectField(packet.value, "url") orelse return errorResponse(allocator, "invalid_request", "Missing URL.")) {
        .string => |text| text,
        else => return errorResponse(allocator, "invalid_request", "URL must be a string."),
    };
    const credential = switch (objectField(packet.value, "credential") orelse Value.null) {
        .string => |text| text,
        .null => "",
        else => return errorResponse(allocator, "permission_denied", "Unknown credential label."),
    };
    var body_value = objectField(packet.value, "body") orelse
        return errorResponse(allocator, "invalid_request", "Missing request body.");
    if (body_value != .object) return errorResponse(allocator, "invalid_request", "Request body must be an object.");

    const uri = std.Uri.parse(url) catch return errorResponse(allocator, "invalid_request", "Invalid HTTP URL.");
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return errorResponse(allocator, "permission_denied", "HTTP URL is not permitted.");
    const host = hostText(uri) orelse return errorResponse(allocator, "permission_denied", "HTTP URL is not permitted.");

    var headers: [2]std.http.Header = undefined;
    var count: usize = 0;
    switch (self.mode) {
        .live => |settings| {
            if (!std.mem.eql(u8, url, settings.responses_url) or
                !std.mem.eql(u8, credential, self.credential_override orelse settings.credentialLabel()))
                return errorResponse(allocator, "permission_denied", "Credential endpoint is not the configured provider.");
            if (!std.mem.eql(u8, uri.scheme, "https") and
                !(std.mem.eql(u8, uri.scheme, "http") and isLoopback(host)))
                return errorResponse(allocator, "permission_denied", "Credential endpoint is not the configured provider.");
            headers[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{settings.api_key}) };
            count = 1;
            if (settings.account_id) |account_id| {
                headers[1] = .{ .name = "ChatGPT-Account-Id", .value = account_id };
                count = 2;
            }
            const supports_summary = settings.kind == .openai_subscription or
                (settings.kind == .compatible and std.ascii.eqlIgnoreCase(host, "api.openai.com"));
            if (self.request_reasoning_summary and supports_summary) {
                if (body_value.object.getPtr("reasoning")) |reasoning| {
                    const effort = objectField(reasoning.*, "effort") orelse .null;
                    if (effort == .string and !std.mem.eql(u8, effort.string, "none") and !reasoning.object.contains("summary")) {
                        try reasoning.object.put(arena, "summary", .{ .string = "auto" });
                    }
                }
            }
        },
        .fixture => |fixture| {
            if (credential.len != 0) return errorResponse(allocator, "permission_denied", "Fixture requests carry no credential.");
            if (!std.mem.eql(u8, uri.scheme, "http") or uri.port == null or uri.port.? != fixture.port or
                !std.mem.eql(u8, host, fixture.host))
                return errorResponse(allocator, "permission_denied", "HTTP origin is not the configured fixture.");
        },
    }

    const kind = self.transportKind();
    const transport_request: @import("responses_transport.zig").Request = .{
        .url = url,
        .body = body_value,
        .headers = headers[0..count],
        .preview = self.preview,
        .id = request.request_id,
        .dialect = switch (self.mode) {
            .live => |settings| settings.protocol,
            .fixture => .responses,
        },
        .resume_decoder = self.resume_state,
        .poll_response_id = self.poll_response_id,
        .cancel_response_id = self.cancel_response_id,
        .size_context = self.size_context,
        .payload_hooks = self.payload_hooks,
        .codex_session = self.codex_session,
        .codex_cached_context = kind == .@"websocket-cached",
        .timeout = switch (self.mode) {
            .live => live_deadline,
            .fixture => fixture_deadline,
        },
    };
    return switch (kind) {
        .http => @import("responses_http.zig").call(allocator, io, transport_request),
        .websocket, .@"websocket-cached" => if (self.codex_sse_fallback and transport_request.dialect == .codex)
            @import("responses_websocket.zig").callCodexWithSseFallback(allocator, io, transport_request)
        else
            @import("responses_websocket.zig").call(allocator, io, transport_request),
    };
}
