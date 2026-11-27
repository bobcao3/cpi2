const std = @import("std");
const effects = @import("agent").provider;
const provider = @import("agent").provider;
const services = @import("services");
test {
    _ = @import("responses_transport_tests.zig");
}

fn providerEnv(allocator: std.mem.Allocator, base: ?[]const u8, key: ?[]const u8, model: ?[]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    if (base) |value| try env.put("OPENAI_BASE_URL", value);
    if (key) |value| try env.put("OPENAI_API_KEY", value);
    if (model) |value| try env.put("OPENAI_MODEL", value);
    return env;
}

test "provider defaults derive the responses endpoint and keep the key out of model config" {
    const a = std.testing.allocator;
    var env = try providerEnv(a, null, "dummy-key", "test-model");
    defer env.deinit();
    var settings = try provider.Provider.init(a, &env);
    defer settings.deinit();
    try std.testing.expectEqualStrings("https://api.openai.com/v1", settings.base_url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", settings.responses_url);
    try std.testing.expectEqualStrings("test-model", settings.model);
    const model = settings.modelConfig("instructions");
    try std.testing.expectEqualStrings(provider.credential_label, model.credential);
    try std.testing.expectEqualStrings(settings.base_url, model.base_url);
    try std.testing.expectEqualStrings("test-model", model.model);
    try std.testing.expect(!std.mem.eql(u8, model.credential, settings.api_key));
}

test "typed DeepSeek settings have native identity and credential scope independent of endpoint overrides" {
    const a = std.testing.allocator;
    var native = try provider.Provider.initOptions(a, .{ .kind = .deepseek, .base_url = "http://127.0.0.1:1/v1", .model = "fixture", .api_key = "deepseek-only" });
    defer native.deinit();
    try std.testing.expectEqualStrings("deepseek", native.name());
    try std.testing.expectEqualStrings("deepseek", native.modelConfig("").credential);
    try std.testing.expectEqual(.responses, native.protocol);
    try std.testing.expectEqual(.http, native.transport);
    try std.testing.expect(native.account_id == null);
    try std.testing.expectError(error.InvalidProtocol, provider.Provider.initOptions(a, .{ .kind = .deepseek, .base_url = "https://api.deepseek.com", .model = "fixture", .api_key = "deepseek-only", .protocol = .codex, .transport = .websocket }));
}

test "provider validates schemes authorities ports and endpoint normalization" {
    const a = std.testing.allocator;
    const cases = [_]struct { base: []const u8, responses: ?[]const u8 }{
        .{ .base = "http://127.0.0.1:8080/v1/", .responses = "http://127.0.0.1:8080/v1/responses" },
        .{ .base = "http://[::1]:8080/v1", .responses = "http://[::1]:8080/v1/responses" },
        .{ .base = "https://api.example.com/openai/v1/", .responses = "https://api.example.com/openai/v1/responses" },
        .{ .base = "https://api.example.com/v1/responses", .responses = "https://api.example.com/v1/responses" },
        .{ .base = "", .responses = null },
        .{ .base = "http://localhost:1/v1", .responses = null },
        .{ .base = "http://10.0.0.1/v1", .responses = null },
        .{ .base = "http://127.0.0.1:0/v1", .responses = null },
        .{ .base = "https://user@example.com/v1", .responses = null },
        .{ .base = "https://example.com/v1?x=1", .responses = null },
        .{ .base = "https://example.com/v1#f", .responses = null },
        .{ .base = "ftp://example.com/v1", .responses = null },
        .{ .base = "https://api.example.com/v1\\evil", .responses = null },
        .{ .base = "https://exa%6dple.com/v1", .responses = null },
        .{ .base = "https:///v1", .responses = null },
    };
    for (cases) |case| {
        var env = try providerEnv(a, case.base, "dummy-key", "test-model");
        defer env.deinit();
        if (case.responses) |expected| {
            var settings = try provider.Provider.init(a, &env);
            defer settings.deinit();
            try std.testing.expectEqualStrings(expected, settings.responses_url);
        } else {
            try std.testing.expectError(error.InvalidBaseUrl, provider.Provider.init(a, &env));
        }
    }
    var missing_key = try providerEnv(a, "http://127.0.0.1:1/v1", null, "test-model");
    defer missing_key.deinit();
    try std.testing.expectError(error.MissingCredential, provider.Provider.init(a, &missing_key));
    var missing_model = try providerEnv(a, "http://127.0.0.1:1/v1", "dummy-key", null);
    defer missing_model.deinit();
    try std.testing.expectError(error.MissingModel, provider.Provider.init(a, &missing_model));
}

test "registered provider service rejects unconfigured endpoint and credential labels" {
    const a = std.testing.allocator;
    var env = try providerEnv(a, "http://127.0.0.1:1/v1", "dummy-key", "test-model");
    defer env.deinit();
    var settings = try provider.Provider.init(a, &env);
    defer settings.deinit();
    const world = effects.Effects.initLive(".", &settings);
    var service: effects.Service = .{ .routes = &.{.{ .base_url = settings.base_url, .credential = settings.modelConfig("").credential, .transport = world }} };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]struct { packet: []const u8 }{
        .{ .packet = "{\"url\":\"http://127.0.0.1:1/v1/responses\",\"credential\":\"deepseek\",\"body\":{}}" },
        .{ .packet = "{\"url\":\"http://127.0.0.1:2/v1/responses\",\"credential\":\"openai-compatible\",\"body\":{}}" },
        .{ .packet = "{\"url\":\"http://127.0.0.1:1/v1/responses/\",\"credential\":\"openai-compatible\",\"body\":{}}" },
    }) |case| {
        try std.testing.expectError(error.UnregisteredProvider, registry.dispatch(.{ .allocator = arena.allocator(), .io = std.testing.io }, "model.request", try services.json.parse(arena.allocator(), case.packet)));
    }
}

const RetryLoopback = struct {
    server: std.Io.net.Server,
    failures: usize,
    failure_status: std.http.Status = .internal_server_error,
    requests: std.atomic.Value(usize) = .init(0),
    const good = "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[]}";
    const failure = "{\"error\":{\"code\":\"server_error\"}}";

    fn run(self: *RetryLoopback, io: std.Io) void {
        while (true) {
            const connection = self.server.accept(io) catch return;
            defer connection.close(io);
            var read_buffer: [16384]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            var writer = connection.writer(io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http.receiveHead() catch return;
            const number = self.requests.fetchAdd(1, .acq_rel) + 1;
            const failed = number <= self.failures;
            request.respond(if (failed) failure else good, .{
                .status = if (failed) self.failure_status else .ok,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
        }
    }
};

test "provider routes retry transient status failures within their attempt budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: RetryLoopback = .{ .server = try address.listen(io, .{}), .failures = 2 };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(RetryLoopback.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{fixture.server.socket.address.getPort()});
    const world = try effects.Effects.initFixture(a, ".", base);
    const retry: provider.Retry = .{ .max_attempts = 3, .initial_delay_ms = 0, .max_delay_ms = 0 };
    try retry.validate();
    var service: provider.Service = .{ .routes = &.{.{ .base_url = base, .transport = world, .retry = retry }} };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    const packet = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"credential\":\"\",\"body\":{{\"model\":\"fixture\",\"input\":[]}}}}", .{base}));
    const result = try registry.dispatch(.{ .allocator = a, .io = io }, "model.request", packet);
    try std.testing.expectEqual(200, result.object.get("status").?.integer);
    try std.testing.expectEqual(3, fixture.requests.load(.acquire));
}

const PrepareRecorder = struct {
    calls: usize = 0,
    forced: usize = 0,
    fn prepare(raw: ?*anyopaque, _: std.Io, force: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (force) self.forced += 1;
    }
};

test "credential preparation is admitted once per attempt and one 401 refresh recovers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: RetryLoopback = .{ .server = try address.listen(io, .{}), .failures = 1, .failure_status = .unauthorized };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(RetryLoopback.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{fixture.server.socket.address.getPort()});
    var prepared: PrepareRecorder = .{};
    var service: provider.Service = .{ .routes = &.{.{ .base_url = base, .transport = try effects.Effects.initFixture(a, ".", base), .retry = .{ .max_attempts = 3, .initial_delay_ms = 0, .max_delay_ms = 0 }, .prepare = .{ .context = &prepared, .call = PrepareRecorder.prepare } }} };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    const denied = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"credential\":\"denied\",\"body\":{{}}}}", .{base}));
    try std.testing.expectError(error.UnregisteredProvider, registry.dispatch(.{ .allocator = a, .io = io }, "model.request", denied));
    try std.testing.expectEqual(@as(usize, 0), prepared.calls);
    const packet = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"body\":{{\"model\":\"fixture\",\"input\":[]}}}}", .{base}));
    const result = try registry.dispatch(.{ .allocator = a, .io = io }, "model.request", packet);
    try std.testing.expectEqual(200, result.object.get("status").?.integer);
    try std.testing.expectEqual(@as(usize, 2), prepared.calls);
    try std.testing.expectEqual(@as(usize, 1), prepared.forced);
    try std.testing.expectEqual(@as(usize, 2), fixture.requests.load(.acquire));
}

test "retry backoff is cancellable without another provider request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var fixture: RetryLoopback = .{ .server = try address.listen(io, .{}), .failures = 100 };
    defer fixture.server.deinit(io);
    var server = try io.concurrent(RetryLoopback.run, .{ &fixture, io });
    defer server.cancel(io);
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{fixture.server.socket.address.getPort()});
    var service: provider.Service = .{ .routes = &.{.{ .base_url = base, .transport = try effects.Effects.initFixture(a, ".", base), .retry = .{ .max_attempts = 3, .initial_delay_ms = 1000, .max_delay_ms = 1000 } }} };
    var registry = services.Registry.init(a);
    defer registry.deinit();
    try registry.add(service.service());
    const packet = try services.json.parse(a, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/responses\",\"body\":{{\"model\":\"fixture\",\"input\":[]}}}}", .{base}));
    var call = try io.concurrent(services.Registry.dispatch, .{ &registry, services.Context{ .allocator = a, .io = io }, "model.request", packet });
    var joined = false;
    defer if (!joined) {
        _ = call.cancel(io) catch {};
    };
    for (0..200) |_| {
        if (fixture.requests.load(.acquire) != 0) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.requests.load(.acquire));
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, call.cancel(io));
    joined = true;
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 800);
    try std.testing.expectEqual(@as(usize, 1), fixture.requests.load(.acquire));
}

test "retry hints and classification are bounded and reject permanent failures" {
    try std.testing.expectEqual(@as(?u32, 2000), provider.retryAfterMilliseconds("2", 0));
    try std.testing.expectEqual(@as(?u32, 300000), provider.retryAfterMilliseconds("999999999", 0));
    try std.testing.expectEqual(@as(?u32, 1000), provider.retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:01 GMT", 0));
    try std.testing.expectEqual(@as(?u32, 0), provider.retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:01 GMT", 2));
    try std.testing.expectEqual(@as(?u32, null), provider.retryAfterMilliseconds("invalid", 0));
    try std.testing.expectEqual(@as(?u32, null), provider.retryAfterMilliseconds("Thu, 31 Feb 2028 00:00:01 GMT", 0));
    try std.testing.expect(provider.transientError(error.ConnectionResetByPeer));
    try std.testing.expect(provider.transientError(error.TlsInitializationFailed));
    try std.testing.expect(!provider.transientError(error.CertificateExpired));
    try std.testing.expect(!provider.transientError(error.Canceled));
    try std.testing.expect(!provider.transientError(error.OutOfMemory));
    try std.testing.expect(!provider.transientError(error.InvalidUpgrade));
}

test "provider retry delays grow exponentially and stay bounded" {
    const retry: provider.Retry = .{ .max_attempts = 5, .initial_delay_ms = 100, .max_delay_ms = 350 };
    try retry.validate();
    try std.testing.expectEqual(0, retry.delayMilliseconds(0));
    try std.testing.expectEqual(100, retry.delayMilliseconds(1));
    try std.testing.expectEqual(200, retry.delayMilliseconds(2));
    try std.testing.expectEqual(350, retry.delayMilliseconds(3));
    try std.testing.expectEqual(350, retry.delayMilliseconds(4));
    try std.testing.expectError(error.InvalidRetryPolicy, (provider.Retry{ .max_attempts = 0 }).validate());
    try std.testing.expectError(error.InvalidRetryPolicy, (provider.Retry{ .initial_delay_ms = 500, .max_delay_ms = 100 }).validate());
}

/// Copies every preview, because the decoder borrows its slices only for the
/// duration of one callback.
const Recorder = struct {
    a: std.mem.Allocator,
    updates: std.ArrayList(Record) = .empty,
    const Record = union(enum) {
        started,
        retrying: provider.Preview.Retry,
        delta: []u8,
        reasoning_delta: []u8,
        tool_start: struct { call_id: []u8, name: []u8 },
        tool_delta: struct { call_id: []u8, delta: []u8 },
        tool_end: struct { call_id: []u8, arguments: []u8 },
    };
    fn emit(raw: ?*anyopaque, request_id: []const u8, update: provider.Preview.Update) !void {
        try std.testing.expectEqualStrings("run", request_id);
        const self: *Recorder = @ptrCast(@alignCast(raw.?));
        const a = self.a;
        try self.updates.append(a, switch (update) {
            .started => .started,
            .retrying => |retry| .{ .retrying = retry },
            .delta => |text| .{ .delta = try a.dupe(u8, text) },
            .reasoning_delta => |text| .{ .reasoning_delta = try a.dupe(u8, text) },
            .tool_start => |call| .{ .tool_start = .{ .call_id = try a.dupe(u8, call.call_id), .name = try a.dupe(u8, call.name) } },
            .tool_delta => |arguments| .{ .tool_delta = .{ .call_id = try a.dupe(u8, arguments.call_id), .delta = try a.dupe(u8, arguments.delta) } },
            .tool_end => |complete| .{ .tool_end = .{ .call_id = try a.dupe(u8, complete.call_id), .arguments = try a.dupe(u8, complete.arguments) } },
        });
    }
    fn deinit(self: *Recorder) void {
        for (self.updates.items) |record| switch (record) {
            .started, .retrying => {},
            .delta, .reasoning_delta => |text| self.a.free(text),
            .tool_start => |call| {
                self.a.free(call.call_id);
                self.a.free(call.name);
            },
            .tool_delta => |arguments| {
                self.a.free(arguments.call_id);
                self.a.free(arguments.delta);
            },
            .tool_end => |complete| {
                self.a.free(complete.call_id);
                self.a.free(complete.arguments);
            },
        };
        self.updates.deinit(self.a);
    }
};

fn decodePreview(recorder: *Recorder, wire: []const u8) !void {
    const preview: provider.Preview = .{ .context = recorder, .notify = Recorder.emit };
    var decoder: provider.Decoder = .{ .allocator = recorder.a, .preview = preview, .request_id = "run" };
    defer decoder.deinit();
    try decoder.feed(wire);
    _ = try decoder.finish();
}

test "stream decoder reports streamed tool-call arguments without parsing them" {
    const a = std.testing.allocator;
    var recorder: Recorder = .{ .a = a };
    defer recorder.deinit();
    try decodePreview(&recorder, "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"read\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":1,\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n");
    try std.testing.expectEqual(4, recorder.updates.items.len);
    try std.testing.expectEqualStrings("call-1", recorder.updates.items[0].tool_start.call_id);
    try std.testing.expectEqualStrings("read", recorder.updates.items[0].tool_start.name);
    try std.testing.expectEqualStrings("{\"path\":", recorder.updates.items[1].tool_delta.delta);
    try std.testing.expectEqualStrings("\"README.md\"}", recorder.updates.items[2].tool_delta.delta);
    try std.testing.expectEqualStrings("call-1", recorder.updates.items[2].tool_delta.call_id);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", recorder.updates.items[3].tool_end.arguments);
}

test "stream decoder closes tool calls at the completed response and on item done" {
    const a = std.testing.allocator;
    var recorder: Recorder = .{ .a = a };
    defer recorder.deinit();
    try decodePreview(&recorder, "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-a\",\"name\":\"bash\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-a\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-b\",\"name\":\"write\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n");
    try std.testing.expectEqual(5, recorder.updates.items.len);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", recorder.updates.items[2].tool_end.arguments);
    try std.testing.expectEqualStrings("call-b", recorder.updates.items[4].tool_end.call_id);
    try std.testing.expectEqualStrings("", recorder.updates.items[4].tool_end.arguments);
}

test "stream decoder forwards text previews without creating call events" {
    const a = std.testing.allocator;
    var recorder: Recorder = .{ .a = a };
    defer recorder.deinit();
    try decodePreview(&recorder, "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n");
    try std.testing.expectEqual(1, recorder.updates.items.len);
    try std.testing.expectEqualStrings("hello", recorder.updates.items[0].delta);
}

test "stream decoder takes final arguments from the completed response" {
    const a = std.testing.allocator;
    var recorder: Recorder = .{ .a = a };
    defer recorder.deinit();
    try decodePreview(&recorder, "data: {\"type\":\"response.output_item.added\",\"output_index\":3,\"item\":{\"type\":\"function_call\",\"call_id\":\"call-z\",\"name\":\"write\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-z\",\"name\":\"write\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]}}\n\n");
    try std.testing.expectEqual(2, recorder.updates.items.len);
    try std.testing.expectEqualStrings("call-z", recorder.updates.items[0].tool_start.call_id);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", recorder.updates.items[1].tool_end.arguments);
}

test "Responses interpretation rejects the entire response before exposing any calls" {
    const responses = @import("agent").responses;
    const j = services.json;
    const cases = [_]struct { body: []const u8, failure: anyerror }{
        .{ .body = "{\"status\":\"completed\"}", .failure = error.InvalidResponse },
        .{ .body = "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\"}", .failure = error.InvalidOutput },
        .{ .body = "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"write\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"write\",\"arguments\":\"{}\"}]}", .failure = error.DuplicateCallId },
        .{ .body = "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"valid\",\"name\":\"write\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"invalid\",\"name\":\"write\",\"arguments\":\"[]\"}]}", .failure = error.InvalidFunctionArguments },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try j.parse(a, case.body);
        try std.testing.expectError(case.failure, responses.parse(a, body));
        const result = try responses.interpret(a, try j.value(a, .{ .status = 200, .body = body }), false);
        try std.testing.expectEqual(.invalid_response, result.status);
        try std.testing.expectEqual(@as(usize, 0), result.calls.len);
        try std.testing.expectEqual(@as(usize, 0), result.output.array.items.len);
        try std.testing.expectEqualStrings(@errorName(case.failure), try j.text(j.get(result.@"error", "code")));
    }
}

test "Result exposes model usage cache metrics and reasoning summaries" {
    const agent = @import("agent");
    const j = services.json;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try j.parse(a,
        \\{"object":"response","status":"completed","model":"fixture",
        \\ "usage":{"input_tokens":1000,"output_tokens":40,"total_tokens":1040,
        \\   "input_tokens_details":{"cached_tokens":800,"cache_write_tokens":50},
        \\   "output_tokens_details":{"reasoning_tokens":15}},
        \\ "output":[
        \\   {"type":"reasoning","summary":[{"type":"summary_text","text":"First. "},{"type":"summary_text","text":"Second. "}],"encrypted_content":"opaque"},
        \\   {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]},
        \\   {"type":"reasoning","summary":[{"type":"summary_text","text":"Third."}]},
        \\   {"type":"function_call","call_id":"call-1","name":"read","arguments":"{\"path\":\"a.txt\"}"}]}
    );
    const result: agent.openai.Result = try agent.responses.interpret(a, try j.value(a, .{ .status = 200, .body = body }), false);
    try std.testing.expectEqual(.completed, result.status);
    try std.testing.expectEqualStrings("fixture", result.model);
    try std.testing.expectEqualStrings("Answer", result.text);
    try std.testing.expectEqualStrings("First. Second. Third.", result.thinking);
    const usage = result.usage.?;
    try std.testing.expectEqual(@as(?u64, 1000), usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 40), usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1040), usage.total_tokens);
    try std.testing.expectEqual(@as(?u64, 800), usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 50), usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 15), usage.reasoning_tokens);
    try std.testing.expectEqual(@as(?u64, 150), usage.uncachedInputTokens());
    try std.testing.expectApproxEqAbs(@as(f64, 80), usage.cacheHitRate().?, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("a.txt", try j.text(j.get(result.calls[0].arguments, "path")));
    try std.testing.expectEqualStrings("opaque", try j.text(j.get(j.get(result.raw, "output").array.items[0], "encrypted_content")));
    const serialized = try j.parse(a, try j.encode(a, result));
    try std.testing.expectEqual(@as(i64, 800), j.get(j.get(serialized, "usage"), "cache_read_tokens").integer);
    try std.testing.expectEqualStrings("First. Second. Third.", try j.text(j.get(serialized, "thinking")));
    const wire = try std.fmt.allocPrint(a, "data: {s}\n\ndata: [DONE]\n\n", .{try j.encode(a, try j.value(a, .{ .type = "response.completed", .response = body }))});
    var decoder: provider.Decoder = .{ .allocator = std.testing.allocator, .preview = null, .request_id = "metrics" };
    defer decoder.deinit();
    for (wire) |byte| try decoder.feed(&.{byte});
    const streamed = try j.parse(a, try decoder.finish());
    const streamed_result = try agent.responses.interpret(a, try j.value(a, .{ .status = 200, .body = streamed }), false);
    try std.testing.expectEqualStrings(try j.encode(a, result), try j.encode(a, streamed_result));
}

test "Result preserves absent usage and distinguishes unknown cache usage from zero" {
    const agent = @import("agent");
    const j = services.json;
    const cases = [_]struct { usage: []const u8, present: bool, cached: ?u64 = null, rate: ?f64 = null }{
        .{ .usage = "null", .present = false },
        .{ .usage = "{}", .present = true },
        .{ .usage = "{\"input_tokens_details\":null,\"output_tokens_details\":null}", .present = true },
        .{ .usage = "{\"input_tokens\":100}", .present = true },
        .{ .usage = "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":0}}", .present = true, .cached = 0, .rate = 0 },
        .{ .usage = "{\"input_tokens\":0,\"input_tokens_details\":{\"cached_tokens\":0}}", .present = true, .cached = 0 },
        .{ .usage = "{\"input_tokens_details\":{\"cached_tokens\":5}}", .present = true, .cached = 5 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var body = try j.parse(a, "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]}");
        const absent = try agent.responses.interpret(a, try j.value(a, .{ .status = 200, .body = body }), false);
        try std.testing.expect(absent.usage == null);
        try body.object.put(a, "usage", try j.parse(a, case.usage));
        const result = try agent.responses.interpret(a, try j.value(a, .{ .status = 200, .body = body }), false);
        try std.testing.expectEqual(.completed, result.status);
        try std.testing.expectEqualStrings("", result.thinking);
        try std.testing.expectEqual(case.present, result.usage != null);
        if (result.usage) |usage| {
            try std.testing.expectEqual(case.cached, usage.cache_read_tokens);
            try std.testing.expectEqual(case.rate, usage.cacheHitRate());
            try std.testing.expect(usage.output_tokens == null);
            try std.testing.expect(usage.total_tokens == null);
            try std.testing.expect(usage.cache_write_tokens == null);
            try std.testing.expect(usage.reasoning_tokens == null);
        }
    }
}

test "Result rejects malformed usage before exposing response output" {
    const agent = @import("agent");
    const j = services.json;
    const cases = [_][]const u8{
        "[]",
        "{\"input_tokens\":-1}",
        "{\"output_tokens\":1.5}",
        "{\"total_tokens\":\"10\"}",
        "{\"input_tokens_details\":[]}",
        "{\"output_tokens_details\":false}",
        "{\"input_tokens_details\":{\"cached_tokens\":-1}}",
        "{\"input_tokens_details\":{\"cache_write_tokens\":\"10\"}}",
        "{\"output_tokens_details\":{\"reasoning_tokens\":1.5}}",
    };
    for (cases) |usage| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var body = try j.parse(a, "{\"object\":\"response\",\"status\":\"completed\",\"model\":\"fixture\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"read\",\"arguments\":\"{}\"}]}");
        try body.object.put(a, "usage", try j.parse(a, usage));
        const result = try agent.responses.interpret(a, try j.value(a, .{ .status = 200, .body = body }), false);
        try std.testing.expectEqual(.invalid_response, result.status);
        try std.testing.expectEqualStrings("InvalidUsage", try j.text(j.get(result.@"error", "code")));
        try std.testing.expect(result.usage == null);
        try std.testing.expectEqual(@as(usize, 0), result.calls.len);
        try std.testing.expectEqual(@as(usize, 0), result.output.array.items.len);
    }
}

test "SSE terminal responses preserve JSON status details and retry semantics" {
    const responses = @import("agent").responses;
    const j = services.json;
    const cases = [_]struct { kind: []const u8, body: []const u8, status: responses.Status, retry: bool = false }{
        .{ .kind = "response.incomplete", .body = "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}", .status = .incomplete },
        .{ .kind = "response.failed", .body = "{\"status\":\"failed\",\"error\":{\"code\":\"invalid_request\"}}", .status = .failed },
        .{ .kind = "response.failed", .body = "{\"status\":\"failed\",\"error\":{\"code\":\"server_error\"}}", .status = .failed, .retry = true },
        .{ .kind = "response.failed", .body = "{\"status\":\"failed\",\"error\":{\"code\":\"context_length_exceeded\"}}", .status = .overflow },
        .{ .kind = "response.cancelled", .body = "{\"status\":\"cancelled\"}", .status = .cancelled },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var body = try j.parse(a, case.body);
        try body.object.put(a, "model", .{ .string = "fixture" });
        try body.object.put(a, "usage", try j.parse(a, "{\"input_tokens\":100,\"output_tokens\":20,\"input_tokens_details\":{\"cached_tokens\":80}}"));
        const event = try j.value(a, .{ .type = case.kind, .response = body });
        const wire = try std.fmt.allocPrint(a, "data: {s}\n\ndata: [DONE]\n\n", .{try j.encode(a, event)});
        var decoder: provider.Decoder = .{ .allocator = std.testing.allocator, .preview = null, .request_id = "terminal" };
        defer decoder.deinit();
        for (wire) |byte| try decoder.feed(&.{byte});
        const streamed = try j.parse(a, try decoder.finish());
        try std.testing.expectEqualStrings(try j.encode(a, body), try j.encode(a, streamed));
        const result = try responses.interpret(a, try j.value(a, .{ .status = 200, .body = streamed }), false);
        try std.testing.expectEqual(case.status, result.status);
        try std.testing.expectEqual(case.retry, responses.retryableBody(streamed));
        try std.testing.expectEqualStrings("fixture", result.model);
        try std.testing.expectEqual(@as(?u64, 100), result.usage.?.input_tokens);
        try std.testing.expectEqual(@as(?u64, 20), result.usage.?.output_tokens);
        try std.testing.expectEqual(@as(?u64, 80), result.usage.?.cache_read_tokens);
        try std.testing.expectEqual(@as(usize, 0), result.calls.len);
    }
}
