const std = @import("std");
const analysis = @import("ownership_analysis");
const sources = @import("sources.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Diagnostic = struct {
    path: []const u8,
    rule: []const u8,
    message: []const u8,
    line: u32,
    column: u32,
    start: u32,
    end: u32,
    source_line: []const u8,
};

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        const message = std.fmt.allocPrint(init.arena.allocator(), "ownership-lint: {s}\n", .{@errorName(err)}) catch return;
        Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(2);
    };
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--listen=-")) return serve(a, init.io);
    const diagnostics = try scan(a, init.io, args[1..], null);
    var as_json = false;
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--json")) {
        as_json = true;
    };
    if (as_json) {
        const bytes = try std.json.Stringify.valueAlloc(a, diagnostics, .{});
        try Io.File.stdout().writeStreamingAll(init.io, bytes);
        try Io.File.stdout().writeStreamingAll(init.io, "\n");
    } else if (diagnostics.len > 0) {
        var bundle = try errorBundle(a, diagnostics);
        defer bundle.deinit(a);
        try bundle.renderToStderr(init.io, .{}, .off);
    } else {
        try Io.File.stdout().writeStreamingAll(init.io, "Ownership checks passed.\n");
    }
    if (diagnostics.len > 0) std.process.exit(1);
}

fn scan(a: Allocator, io: Io, args: []const []const u8, server: ?*std.zig.Server) ![]Diagnostic {
    var root: []const u8 = ".";
    var paths: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index == args.len) return error.MissingRoot;
            root = args[index];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else try paths.append(a, arg);
    }
    root = try std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(io, a), root });
    if (paths.items.len == 0) {
        try paths.appendSlice(a, try sources.collect(a, io, root));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    for (paths.items) |path| {
        const absolute = try std.fs.path.resolve(a, &.{ root, path });
        const relative = try std.fs.path.relativeAlloc(a, root, null, root, absolute);
        const source = try Io.Dir.cwd().readFileAllocOptions(io, absolute, a, .limited(4 * 1024 * 1024), .of(u8), 0);
        if (server) |protocol| {
            const cwd = try std.process.currentPathAlloc(io, a);
            const input = try std.fs.path.relativeAlloc(a, cwd, null, cwd, absolute);
            try protocol.serveMessageHeader(.{ .tag = .discovered_inputs, .bytes_len = @intCast(input.len + 5) });
            try protocol.out.writeInt(u32, 0, .little);
            try protocol.out.writeAll(input);
            try protocol.out.writeByte(0);
            try protocol.out.flush();
        }
        var tree = try std.zig.Ast.parse(a, source, .{});
        defer tree.deinit(a);
        if (tree.errors.len > 0) {
            for (tree.errors) |err| {
                var message: Io.Writer.Allocating = .init(a);
                try tree.renderError(err, &message.writer);
                try diagnostics.append(a, diagnostic(&tree, absolute, "PARSE", message.written(), err.token));
            }
            continue;
        }
        const findings = try analysis.analyze(a, &tree, relative);
        for (findings) |finding| try diagnostics.append(a, diagnostic(&tree, absolute, finding.rule, finding.message, finding.token));
    }
    return diagnostics.toOwnedSlice(a);
}

fn diagnostic(tree: *const std.zig.Ast, path: []const u8, rule: []const u8, message: []const u8, token: std.zig.Ast.TokenIndex) Diagnostic {
    const location = tree.tokenLocation(0, token);
    const start = tree.tokenStart(token);
    return .{
        .path = path,
        .rule = rule,
        .message = message,
        .line = @intCast(location.line + 1),
        .column = @intCast(location.column + 1),
        .start = start,
        .end = start + @as(u32, @intCast(tree.tokenSlice(token).len)),
        .source_line = tree.source[location.line_start..location.line_end],
    };
}

fn errorBundle(a: Allocator, diagnostics: []const Diagnostic) !std.zig.ErrorBundle {
    var bundle = try std.zig.ErrorBundle.Wip.init(a);
    defer bundle.deinit();
    for (diagnostics) |item| {
        const location = try bundle.addSourceLocation(.{
            .src_path = try bundle.addString(item.path),
            .line = item.line - 1,
            .column = item.column - 1,
            .span_start = item.start,
            .span_main = item.start,
            .span_end = item.end,
            .source_line = try bundle.addString(item.source_line),
        });
        try bundle.addRootErrorMessage(.{
            .msg = try bundle.addString(try std.fmt.allocPrint(a, "{s}: {s}", .{ item.rule, item.message })),
            .src_loc = location,
        });
    }
    return bundle.toOwnedBundle("");
}

fn serve(a: Allocator, io: Io) !void {
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(io, &input_buffer);
    var output = Io.File.stdout().writerStreaming(io, &output_buffer);
    var server: std.zig.Server = .{ .in = &input.interface, .out = &output.interface };
    var args: std.ArrayList([]const u8) = .empty;
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => return,
            .args => {
                const body = try a.dupe(u8, try server.in.take(header.bytes_len));
                var reader: Io.Reader = .fixed(body);
                while (reader.seek < body.len) {
                    const kind = try reader.takeEnum(std.zig.Client.Message.Arg, .little);
                    if (kind != .string) return error.UnsupportedProtocolArgument;
                    try args.append(a, try reader.takeSentinel(0));
                }
            },
            .query_test_metadata => try server.serveTestMetadata(.{
                .names = &.{1},
                .expected_panic_msgs = &.{0},
                .string_bytes = "\x00ownership-lint\x00",
            }),
            .run_test => {
                const index = try server.receiveBody_u32();
                if (index != 0) return error.UnknownCheck;
                try server.serveBodylessMessage(.test_started);
                const diagnostics = try scan(a, io, args.items, &server);
                var bundle = try errorBundle(a, diagnostics);
                defer bundle.deinit(a);
                try server.serveErrorBundle(.error_bundle, bundle);
                try server.serveTestResults(.{ .index = 0, .flags = .{
                    .status = if (diagnostics.len == 0) .pass else .fail,
                    .fuzz = false,
                    .log_err_count = 0,
                    .leak_count = 0,
                } });
            },
            else => return error.UnsupportedProtocolMessage,
        }
    }
}
