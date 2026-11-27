//! Native login credentials.
//!
//! The store uses `$XDG_DATA_HOME/cpi-minimal/auth.conf` with a flat
//! `key = value` format. It contains plaintext secrets, so reads reject
//! group/world permissions and writes are locked, private, and atomic.
const std = @import("std");
const json_text = @import("json_tree").text;
const HttpResponseReader = @import("services").HttpResponseReader;
const Paths = @import("../config.zig").Paths;
const Provider = @import("agent").provider.Provider;
const registry = @import("model_registry");
const j = @import("../json.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const SizeSink = @import("session_protocol").Transaction.SizeSink;
const expected_file_bytes = 1024 * 1024;
const expected_response_bytes = 1024 * 1024;

pub const Kind = enum { openai, deepseek, compatible };
pub const Record = struct {
    kind: Kind,
    base_url: []const u8,
    model: []const u8,
    token: []const u8,
    refresh: ?[]const u8 = null,
    expires: i64 = 0,
    account_id: ?[]const u8 = null,
};
const Document = struct { version: u32 = 1, active: ?Kind = null, profiles: []const Record = &.{}, forgotten: std.EnumSet(Kind) = .{} };

pub const Store = struct {
    a: Allocator,
    io: Io,
    path: []const u8,
    document: Document = .{},
    legacy_path: ?[]const u8 = null,
    configured: bool = false,
    environment: ?*const std.process.Environ.Map = null,
    environment_provider_id: ?[]const u8 = null,
    environment_route: ?Record = null,
    base_url_override: ?[]const u8 = null,
    size_warnings: SizeSink = .{},

    pub fn init(a: Allocator, io: Io, env: *const std.process.Environ.Map, size_warnings: SizeSink) !Store {
        const paths = try Paths.init(a, env);
        var self: Store = .{ .a = a, .io = io, .path = try paths.authPath(), .legacy_path = try paths.legacyAuthPath(env), .size_warnings = size_warnings };
        try self.readDocument();
        return self;
    }

    fn readDocument(self: *Store) !void {
        const current = try self.readPrivateFile(self.path);
        self.document = if (current) |bytes| try parseDocument(self.a, bytes) else .{};
        if (self.legacy_path) |path| {
            const bytes = (try self.readPrivateFile(path)) orelse return;
            const legacy = json_text.parseFromSliceLeaky(Document, self.a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidCredentialFile;
            try validateLegacyDocument(self.a, legacy);
            var merged: std.ArrayList(Record) = .empty;
            try merged.appendSlice(self.a, self.document.profiles);
            for (legacy.profiles) |record| {
                if (!self.document.forgotten.contains(record.kind) and self.find(record.kind) == null) try merged.append(self.a, record);
            }
            self.document.profiles = merged.items;
            if (current == null) self.document.active = legacy.active;
        }
    }

    fn readPrivateFile(self: *Store, path: []const u8) !?[]const u8 {
        const a = self.a;
        const io = self.io;
        const file = Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidCredentialFile;
        if (@import("builtin").os.tag != .windows and stat.permissions.toMode() & 0o077 != 0) return error.InsecureCredentialFile;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const bytes = try reader.interface.allocRemaining(a, .unlimited);
        self.size_warnings.report("credential file bytes", bytes.len, expected_file_bytes);
        return bytes;
    }

    pub fn find(self: *const Store, kind: Kind) ?Record {
        for (self.document.profiles) |record| if (record.kind == kind) return record;
        return null;
    }

    pub fn active(self: *const Store) ?Record {
        return self.find(self.document.active orelse return null);
    }

    pub fn reload(self: *Store) !void {
        try self.readDocument();
    }

    /// Persist a successful login without selecting its route or model.
    pub fn remember(self: *Store, record: Record) !void {
        try self.put(record, false);
    }

    pub fn save(self: *Store, record: Record) !void {
        try self.put(record, true);
    }

    pub fn forget(self: *Store, kind: Kind) !void {
        try self.update(null, false, kind);
    }

    fn put(self: *Store, record: Record, activate: bool) !void {
        try self.update(record, activate, null);
    }

    fn update(self: *Store, record: ?Record, activate: bool, forgotten: ?Kind) !void {
        if (record) |value| {
            _ = try provider(self.a, value);
            try safeLine(value.refresh orelse "");
        }
        const parent = std.fs.path.dirname(self.path) orelse return error.InvalidCredentialPath;
        _ = try Io.Dir.cwd().createDirPathStatus(self.io, parent, .fromMode(0o700));
        const lock_path = try std.fmt.allocPrint(self.a, "{s}.lock", .{self.path});
        const lock = Io.Dir.cwd().createFile(self.io, lock_path, .{ .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.PathAlreadyExists => try Io.Dir.cwd().openFile(self.io, lock_path, .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true }),
            else => return err,
        };
        defer lock.close(self.io);
        var latest: Store = .{ .a = self.a, .io = self.io, .path = self.path, .legacy_path = self.legacy_path, .size_warnings = self.size_warnings };
        try latest.readDocument();
        const kind = if (record) |value| value.kind else forgotten.?;
        var records: std.ArrayList(Record) = .empty;
        for (latest.document.profiles) |previous| if (previous.kind != kind) try records.append(self.a, previous);
        var suppressed = latest.document.forgotten;
        if (record) |value| {
            var remembered = value;
            if (!activate and std.mem.eql(u8, value.model, "unconfigured")) {
                if (latest.find(kind)) |previous| remembered.model = previous.model;
            }
            try records.append(self.a, try cloneRecord(self.a, remembered));
            suppressed.remove(kind);
        } else suppressed.insert(kind);
        const active_kind = if (activate) kind else if (forgotten != null and latest.document.active == kind) null else latest.document.active;
        const document: Document = .{ .active = active_kind, .profiles = records.items, .forgotten = suppressed };
        const bytes = try writeDocument(self.a, document);
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        const temporary = try std.fmt.allocPrint(self.a, "{s}.{s}.tmp", .{ self.path, std.fmt.bytesToHex(nonce, .lower) });
        defer Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
        const file = try Io.Dir.cwd().createFile(self.io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        try file.setPermissions(self.io, .fromMode(0o600));
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        try Io.Dir.renameAbsolute(temporary, self.path, self.io);
        self.document = document;
        if (activate) self.configured = true;
    }
};

fn validateLegacyDocument(a: Allocator, document: Document) !void {
    if (document.version != 1) return error.InvalidCredentialFile;
    var seen: std.EnumSet(Kind) = .{};
    for (document.profiles) |record| {
        if (seen.contains(record.kind)) return error.InvalidCredentialFile;
        seen.insert(record.kind);
        _ = try provider(a, record);
        try safeLine(record.refresh orelse "");
    }
}

const Builder = struct {
    kind: Kind,
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    token: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires: ?i64 = null,
    account_id: ?[]const u8 = null,
};

fn parseKind(text: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, text);
}

fn safeLine(text: []const u8) !void {
    if (text.len == 0) return;
    if (!std.mem.eql(u8, text, std.mem.trim(u8, text, " \t\r\n"))) return error.InvalidCredential;
    for (text) |byte| if (byte == '\r' or byte == '\n') return error.InvalidCredential;
}

fn parseDocument(a: Allocator, data: []const u8) !Document {
    var active: ?Kind = null;
    var version: u32 = 1;
    var builders: std.ArrayList(Builder) = .empty;
    var forgotten: std.EnumSet(Kind) = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidCredentialFile;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidCredentialFile;
        if (std.mem.eql(u8, key, "version")) {
            version = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCredentialFile;
            if (version != 1) return error.InvalidCredentialFile;
            continue;
        }
        if (std.mem.eql(u8, key, "active")) {
            active = parseKind(value) orelse return error.InvalidCredentialFile;
            continue;
        }
        if (std.mem.startsWith(u8, key, "forgotten.")) {
            if (!std.mem.eql(u8, value, "true")) return error.InvalidCredentialFile;
            forgotten.insert(parseKind(key["forgotten.".len..]) orelse return error.InvalidCredentialFile);
            continue;
        }
        const prefix = "profile.";
        if (!std.mem.startsWith(u8, key, prefix)) return error.InvalidCredentialFile;
        const rest = key[prefix.len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidCredentialFile;
        const kind = parseKind(rest[0..dot]) orelse return error.InvalidCredentialFile;
        const field = rest[dot + 1 ..];
        var index: ?usize = null;
        for (builders.items, 0..) |builder, i| if (builder.kind == kind) {
            index = i;
            break;
        };
        if (index == null) {
            try builders.append(a, .{ .kind = kind });
            index = builders.items.len - 1;
        }
        const builder = &builders.items[index.?];
        if (std.mem.eql(u8, field, "base_url")) {
            if (builder.base_url != null) return error.InvalidCredentialFile;
            builder.base_url = value;
        } else if (std.mem.eql(u8, field, "model")) {
            if (builder.model != null) return error.InvalidCredentialFile;
            builder.model = value;
        } else if (std.mem.eql(u8, field, "token")) {
            if (builder.token != null) return error.InvalidCredentialFile;
            builder.token = value;
        } else if (std.mem.eql(u8, field, "refresh")) {
            if (builder.refresh != null) return error.InvalidCredentialFile;
            builder.refresh = value;
        } else if (std.mem.eql(u8, field, "expires")) {
            if (builder.expires != null) return error.InvalidCredentialFile;
            builder.expires = std.fmt.parseInt(i64, value, 10) catch return error.InvalidCredentialFile;
        } else if (std.mem.eql(u8, field, "account_id")) {
            if (builder.account_id != null) return error.InvalidCredentialFile;
            builder.account_id = value;
        } else return error.InvalidCredentialFile;
    }
    var records: std.ArrayList(Record) = .empty;
    for (builders.items) |builder| {
        const record: Record = .{
            .kind = builder.kind,
            .base_url = builder.base_url orelse return error.InvalidCredentialFile,
            .model = builder.model orelse return error.InvalidCredentialFile,
            .token = builder.token orelse return error.InvalidCredentialFile,
            .refresh = builder.refresh,
            .expires = builder.expires orelse 0,
            .account_id = builder.account_id,
        };
        _ = try provider(a, record);
        try safeLine(record.refresh orelse "");
        try records.append(a, record);
    }
    return .{ .version = version, .active = active, .profiles = records.items, .forgotten = forgotten };
}

fn writeDocument(a: Allocator, document: Document) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.print("version = {d}\n", .{document.version});
    if (document.active) |kind| try out.writer.print("active = {s}\n", .{@tagName(kind)});
    for (std.enums.values(Kind)) |kind| {
        if (document.forgotten.contains(kind)) try out.writer.print("forgotten.{s} = true\n", .{@tagName(kind)});
    }
    for (document.profiles) |record| {
        const kind = @tagName(record.kind);
        try out.writer.print("profile.{s}.base_url = {s}\n", .{ kind, record.base_url });
        try out.writer.print("profile.{s}.model = {s}\n", .{ kind, record.model });
        try out.writer.print("profile.{s}.token = {s}\n", .{ kind, record.token });
        if (record.refresh) |value| try out.writer.print("profile.{s}.refresh = {s}\n", .{ kind, value });
        if (record.expires != 0) try out.writer.print("profile.{s}.expires = {d}\n", .{ kind, record.expires });
        if (record.account_id) |account| try out.writer.print("profile.{s}.account_id = {s}\n", .{ kind, account });
    }
    return out.toOwnedSlice();
}

pub fn cloneRecord(a: Allocator, record: Record) !Record {
    return .{
        .kind = record.kind,
        .base_url = try a.dupe(u8, record.base_url),
        .model = try a.dupe(u8, record.model),
        .token = try a.dupe(u8, record.token),
        .refresh = if (record.refresh) |value| try a.dupe(u8, value) else null,
        .expires = record.expires,
        .account_id = if (record.account_id) |value| try a.dupe(u8, value) else null,
    };
}

pub fn kindFor(provider_value: *const Provider) Kind {
    return switch (provider_value.kind) {
        .deepseek => .deepseek,
        .openai_subscription => .openai,
        .compatible => .compatible,
    };
}

pub fn providerOptions(record: Record) Provider.Options {
    return .{
        .kind = switch (record.kind) {
            .deepseek => .deepseek,
            .openai => .openai_subscription,
            .compatible => .compatible,
        },
        .base_url = record.base_url,
        .model = record.model,
        .api_key = record.token,
        .account_id = record.account_id,
        .protocol = if (record.kind == .openai) .codex else .responses,
        .transport = if (record.kind == .openai) .@"websocket-cached" else .http,
    };
}

pub fn provider(a: Allocator, record: Record) !*Provider {
    if (record.kind == .deepseek and !std.mem.eql(u8, std.mem.trimEnd(u8, record.base_url, "/"), registry.selection.deepseek.base_url)) return error.InvalidBaseUrl;
    return providerWithEndpointOverride(a, record);
}

/// Only host-resolved routes with explicit endpoint overrides use this path.
/// Saved login validation continues to require the first-party endpoint.
pub fn providerWithEndpointOverride(a: Allocator, record: Record) !*Provider {
    const result = try a.create(Provider);
    errdefer a.destroy(result);
    result.* = try Provider.initOptions(a, providerOptions(record));
    return result;
}

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const auth_origin = "https://auth.openai.com";
pub const verification_uri = "https://auth.openai.com/codex/device";

const HttpResult = struct { status: u16, body: j.Value, retry_after_ms: u32 = 0 };
const Deadline = struct {
    event: Io.Event = .unset,
    fn run(self: *Deadline, io: Io, connection: *std.http.Client.Connection) void {
        self.event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } }) catch |err| {
            if (err == error.Timeout) connection.stream_reader.stream.shutdown(io, .both) catch {};
        };
    }
};

fn http(a: Allocator, io: Io, method: std.http.Method, url: []const u8, body: ?[]const u8, headers: []const std.http.Header, form: bool, size_warnings: SizeSink) !HttpResult {
    const policy: @import("agent").provider.Retry = .{ .max_attempts = 4, .initial_delay_ms = 500, .max_delay_ms = 4000 };
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        try io.checkCancel();
        const response = httpOnce(a, io, method, url, body, headers, form, size_warnings) catch |err| {
            try io.checkCancel();
            if (!@import("agent").provider.transientError(err) or attempt + 1 >= policy.max_attempts) return err;
            try Io.sleep(io, .fromMilliseconds(policy.delay(io, attempt + 1, 0)), .awake);
            continue;
        };
        if (!@import("agent").responses.retryableStatus(response.status) or attempt + 1 >= policy.max_attempts) return response;
        try Io.sleep(io, .fromMilliseconds(policy.delay(io, attempt + 1, response.retry_after_ms)), .awake);
    }
}

fn httpOnce(a: Allocator, io: Io, method: std.http.Method, url: []const u8, body: ?[]const u8, headers: []const std.http.Header, form: bool, size_warnings: SizeSink) !HttpResult {
    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidAuthUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidAuthUrl;
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    if (protocol == .tls) {
        const now = Io.Clock.real.now(io);
        try client.ca_bundle.rescan(a, io, now);
        client.now = now;
    }
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try std.Io.net.HostName.fromUri(uri, &host_buffer);
    if (protocol == .plain and !std.mem.eql(u8, host.bytes, "127.0.0.1") and !std.mem.eql(u8, host.bytes, "::1")) return error.InvalidAuthUrl;
    const connection = try client.connectTcpOptions(.{ .host = host, .port = uri.port orelse if (protocol == .tls) @as(u16, 443) else 80, .protocol = protocol, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    var response_input: HttpResponseReader = .{ .allocator = a };
    defer response_input.deinit();
    var request = try client.request(method, uri, .{ .connection = connection, .keep_alive = false, .redirect_behavior = .unhandled, .headers = .{ .content_type = .{ .override = if (form) "application/x-www-form-urlencoded" else "application/json" }, .accept_encoding = .omit }, .extra_headers = headers });
    defer {
        request.reader.state = .ready;
        connection.closing = true;
        request.deinit();
    }
    var deadline: Deadline = .{};
    var watchdog = try io.concurrent(Deadline.run, .{ &deadline, io, connection });
    defer {
        deadline.event.set(io);
        watchdog.await(io);
    }
    if (body) |bytes| try request.sendBodyComplete(@constCast(bytes)) else try request.sendBodiless();
    var response = response_input.receiveHead(&request) catch |err| {
        if (err == error.ReadFailed) return connection.getReadError() orelse err;
        return err;
    };
    size_warnings.report("authorization response head bytes", response.head.bytes.len, HttpResponseReader.expected_bytes);
    if (response.head.status.class() == .redirect) return error.AuthRedirectDenied;
    const status: u16 = @intCast(@backingInt(response.head.status));
    var retry_after_ms: u32 = 0;
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) retry_after_ms = @import("agent").provider.retryAfterMilliseconds(header.value, Io.Timestamp.now(io, .real).toSeconds()) orelse 0;
    }
    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);
    const bytes = reader.allocRemaining(a, .unlimited) catch |err| {
        if (response_input.failure) |failure| return failure;
        if (connection.stream_reader.err) |failure| {
            if (failure == error.Canceled) return error.Canceled;
        }
        return err;
    };
    size_warnings.report("authorization response trailer bytes", request.reader.trailers.len, HttpResponseReader.expected_bytes);
    size_warnings.report("response bytes", bytes.len, expected_response_bytes);
    const value = j.parse(a, bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (@import("agent").responses.retryableStatus(status)) return .{ .status = status, .body = .null, .retry_after_ms = retry_after_ms };
        return error.InvalidAuthResponse;
    };
    return .{ .status = status, .body = value, .retry_after_ms = retry_after_ms };
}

pub fn formEncode(a: Allocator, fields: []const struct { []const u8, []const u8 }) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (fields, 0..) |field, index| {
        if (index != 0) try result.append(a, '&');
        for ([_][]const u8{ field[0], field[1] }, 0..) |part, position| {
            if (position != 0) try result.append(a, '=');
            for (part) |byte| {
                if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) try result.append(a, byte) else {
                    try result.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
                }
            }
        }
    }
    return result.items;
}

pub fn tokens(a: Allocator, io: Io, value: j.Value, model: []const u8) !Record {
    const access = j.text(j.get(value, "access_token"));
    const refresh_token = j.text(j.get(value, "refresh_token"));
    const expires = j.get(value, "expires_in");
    if (access.len == 0 or refresh_token.len == 0 or expires != .integer or expires.integer <= 0 or expires.integer > 366 * 24 * 3600) return error.InvalidTokenResponse;
    var parts = std.mem.splitScalar(u8, access, '.');
    _ = parts.next() orelse return error.InvalidTokenResponse;
    const encoded = parts.next() orelse return error.InvalidTokenResponse;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(decoded, encoded);
    const claims = try j.parse(a, decoded);
    const account = j.text(j.get(j.get(claims, "https://api.openai.com/auth"), "chatgpt_account_id"));
    if (account.len == 0) return error.MissingAccountId;
    const record: Record = .{ .kind = .openai, .base_url = "https://chatgpt.com/backend-api/codex", .model = model, .token = access, .refresh = refresh_token, .expires = Io.Timestamp.now(io, .real).toMilliseconds() + expires.integer * 1000, .account_id = account };
    _ = try provider(a, record);
    return record;
}

pub fn refresh(a: Allocator, io: Io, record: Record, size_warnings: SizeSink) !Record {
    if (record.kind != .openai or record.expires > Io.Timestamp.now(io, .real).toMilliseconds() + 60000) return record;
    const body = try formEncode(a, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", record.refresh orelse return error.LoginRequired }, .{ "client_id", client_id } });
    const result = try http(a, io, .POST, auth_origin ++ "/oauth/token", body, &.{}, true, size_warnings);
    if (result.status != 200) {
        if (@import("agent").responses.retryableStatus(result.status)) return error.CredentialRefreshUnavailable;
        return error.LoginRequired;
    }
    const renewed = try tokens(a, io, result.body, record.model);
    if (!std.mem.eql(u8, renewed.account_id.?, record.account_id orelse return error.MissingAccountId)) return error.AccountMismatch;
    return renewed;
}

pub const DeviceJob = struct {
    const expected_code_bytes = 128;

    arena: std.heap.ArenaAllocator,
    io: Io,
    future: Io.Future(void) = undefined,
    done: Io.Event = .unset,
    mutex: Io.Mutex = .init,
    code: []const u8 = "",
    result: ?Record = null,
    failure: ?anyerror = null,
    origin: []const u8 = auth_origin,
    size_warnings: SizeSink = .{},
    credential_store: ?Store = null,
    notification: @import("../tui.zig").Wake.Notification = .{},

    pub fn start(a: Allocator, io: Io, store: *const Store, size_warnings: SizeSink, notification: @import("../tui.zig").Wake.Notification) !*DeviceJob {
        const self = try a.create(DeviceJob);
        self.* = .{ .arena = .init(a), .io = io, .size_warnings = size_warnings, .notification = notification };
        errdefer {
            self.arena.deinit();
            a.destroy(self);
        }
        const owned = self.arena.allocator();
        self.credential_store = .{
            .a = owned,
            .io = io,
            .path = try owned.dupe(u8, store.path),
            .legacy_path = if (store.legacy_path) |path| try owned.dupe(u8, path) else null,
            .size_warnings = size_warnings,
        };
        self.future = try io.concurrent(run, .{self});
        return self;
    }
    pub fn destroy(self: *DeviceJob, a: Allocator) void {
        self.future.cancel(self.io);
        if (self.result) |record| std.crypto.secureZero(u8, @constCast(record.token));
        self.arena.deinit();
        a.destroy(self);
    }
    fn run(self: *DeviceJob) void {
        self.login() catch |err| {
            self.failure = err;
        };
        self.done.set(self.io);
        self.notification.signal();
    }
    pub fn login(self: *DeviceJob) !void {
        const a = self.arena.allocator();
        const response = try http(a, self.io, .POST, try std.fmt.allocPrint(a, "{s}/api/accounts/deviceauth/usercode", .{self.origin}), try j.encode(a, .{ .client_id = client_id }), &.{}, false, self.size_warnings);
        if (response.status != 200) return error.DeviceLoginUnavailable;
        const id = j.text(j.get(response.body, "device_auth_id"));
        const code = j.text(j.get(response.body, "user_code"));
        const raw_interval = j.get(response.body, "interval");
        const seconds = if (raw_interval == .integer) raw_interval.integer else if (raw_interval == .string) std.fmt.parseInt(i64, raw_interval.string, 10) catch return error.InvalidAuthResponse else return error.InvalidAuthResponse;
        if (id.len == 0 or code.len == 0 or seconds < 0 or seconds > 60) return error.InvalidAuthResponse;
        self.size_warnings.report("device code bytes", code.len, expected_code_bytes);
        self.mutex.lockUncancelable(self.io);
        self.code = code;
        self.mutex.unlock(self.io);
        self.notification.signal();
        const start_time = Io.Timestamp.now(self.io, .awake);
        var delay = @max(@as(i64, 1), seconds);
        while (start_time.durationTo(Io.Timestamp.now(self.io, .awake)).toSeconds() < 15 * 60) {
            try Io.sleep(self.io, .fromSeconds(delay), .awake);
            const polled = http(a, self.io, .POST, try std.fmt.allocPrint(a, "{s}/api/accounts/deviceauth/token", .{self.origin}), try j.encode(a, .{ .device_auth_id = id, .user_code = code }), &.{}, false, self.size_warnings) catch |err| {
                if (@import("agent").provider.transientError(err)) continue;
                return err;
            };
            if (@import("agent").responses.retryableStatus(polled.status)) continue;
            if (polled.status == 200) {
                const authorization = j.text(j.get(polled.body, "authorization_code"));
                const verifier = j.text(j.get(polled.body, "code_verifier"));
                if (authorization.len == 0 or verifier.len == 0) return error.InvalidAuthResponse;
                const body = try formEncode(a, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", client_id }, .{ "code", authorization }, .{ "code_verifier", verifier }, .{ "redirect_uri", try std.fmt.allocPrint(a, "{s}/deviceauth/callback", .{self.origin}) } });
                const exchanged = try http(a, self.io, .POST, try std.fmt.allocPrint(a, "{s}/oauth/token", .{self.origin}), body, &.{}, true, self.size_warnings);
                if (exchanged.status != 200) return error.TokenExchangeFailed;
                self.result = try tokens(a, self.io, exchanged.body, "unconfigured");
                if (self.credential_store) |*store| try store.remember(self.result.?);
                return;
            }
            const code_value = j.get(polled.body, "error");
            const problem = if (code_value == .string) code_value.string else j.text(j.get(code_value, "code"));
            if (std.mem.eql(u8, problem, "access_denied") or std.mem.eql(u8, problem, "authorization_declined")) return error.DeviceLoginDenied;
            if (std.mem.eql(u8, problem, "expired_token")) return error.DeviceLoginExpired;
            if (std.mem.eql(u8, problem, "slow_down")) {
                delay = @min(60, delay + 5);
                continue;
            }
            if (polled.status == 403 or polled.status == 404 or std.mem.eql(u8, problem, "deviceauth_authorization_pending")) continue;
            return error.DeviceLoginDenied;
        }
        return error.DeviceLoginExpired;
    }
};
