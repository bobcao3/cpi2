const std = @import("std");
const analysis = @import("src/analysis.zig");
const a = std.testing.allocator;

const Case = struct {
    name: []const u8,
    source: [:0]const u8,
    rule: ?[]const u8 = null,
    at: []const u8 = "",
    path: []const u8 = "packages/agent/src/example.zig",
};

const cases = [_]Case{
    .{ .name = "borrow mutation then parent observation", .source =
    \\fn f() !void { var run = j.get(doc.value, "active"); try j.put(a, &run, "continuation", token); _ = estimate(doc.value); }
    , .rule = "OWN001", .at = "put(a, &run" },
    .{ .name = "borrow assignment and nested scope", .source =
    \\fn f() !void { var run = j.get(doc.value, "active"); var alias = run; { var other = alias; try j.put(a, &other, "extra", token); } _ = estimate(doc.value); }
    , .rule = "OWN001", .at = "put(a, &other" },
    .{ .name = "nested try orelse wrappers", .source =
    \\fn f() !void { var run = try (try doc.value.object.get("active") orelse return); try run.object.put(a, "extra", token); _ = estimate(doc.value); }
    , .rule = "OWN001", .at = "put(a, \"extra\"" },
    .{ .name = "borrow publication without restoring source field", .source =
    \\fn f() !void { var run = j.get(doc.value, "active"); try j.put(a, &run, "extra", token); try j.put(a, &out, "other", run); }
    , .rule = "OWN001", .at = "put(a, &run" },
    .{ .name = "wrong writeback key", .source =
    \\fn f() !void { var history = j.get(state, "history"); try history.array.append(item); try j.put(a, &state, "view", history); _ = encode(state); }
    , .rule = "OWN001", .at = "append(item)" },
    .{ .name = "owner alias observation", .source =
    \\fn f() !void { var owner = doc.value; var run = j.get(owner, "active"); try j.put(a, &run, "extra", token); _ = encode(doc.value); }
    , .rule = "OWN001", .at = "put(a, &run" },
    .{ .name = "read only borrowed header", .source =
    \\fn f() !void { var run = j.get(doc.value, "active"); _ = j.get(run, "id"); _ = estimate(doc.value); }
    },
    .{ .name = "consumed borrowed body", .source =
    \\fn f() !void { var body = packet.value.object.get("body") orelse return; try body.object.put(a, "stream", yes); const wire = encode(body); send(wire); }
    },
    .{ .name = "return local borrow consumes its updated header", .source =
    \\fn f() !V { var body = j.get(packet, "body"); try j.put(a, &body, "stream", yes); return body; }
    },
    .{ .name = "matching array writebacks", .source =
    \\fn f() !void { var state = load(); var history = j.get(state, "history"); var view = j.get(state, "view"); for (messages) |message| { try history.array.append(message); try view.array.append(id); } _ = j.get(state, "version"); try j.put(a, &state, "history", history); try j.put(a, &state, "view", view); _ = encode(state); }
    },
    .{ .name = "writeback through alias", .source =
    \\fn f() !void { var history = j.get(state, "history"); var alias = history; try alias.array.append(item); try j.put(a, &state, "history", alias); _ = encode(state); }
    },
    .{ .name = "fresh builders", .source =
    \\fn f() !void { var tool = j.object(); try j.put(a, &tool, "name", name); var tools = j.array(a); try tools.array.append(tool); _ = encode(tools); }
    },
    .{ .name = "explicit copy independence", .source =
    \\fn f() !void { var run = try j.copy(a, j.get(doc.value, "active")); try j.put(a, &run, "extra", token); _ = estimate(doc.value); }
    },
    .{ .name = "owner pointer mutation", .source =
    \\fn f() !void { const run = j.ptr(&doc.value, "active"); try j.put(a, run, "extra", token); _ = estimate(doc.value); }
    },
    .{ .name = "same spelling in comments and strings", .source =
    \\fn f() !void {
    \\    // var run = j.get(doc.value, "active"); try j.put(a, &run, "x", item); _ = encode(doc.value);
    \\    const text = "try j.put(a, &doc.value, \"active\", x)";
    \\    use(text);
    \\}
    },
    .{ .name = "shadowed local does not inherit borrow", .source =
    \\fn f() !void { var run = j.get(doc.value, "active"); { var run = j.object(); try j.put(a, &run, "extra", token); } _ = estimate(doc.value); }
    },
    .{ .name = "fresh put publication then alias mutation", .source =
    \\fn f() !void { var tool = j.object(); try j.put(a, &owner, "tool", tool); var result = tool; try j.put(a, &result, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, &result" },
    .{ .name = "array publication and assignment alias", .source =
    \\fn f() !void { var tool = j.object(); var result: V = .null; try tools.array.append(tool); result = tool; try result.object.put(a, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, \"revision\"" },
    .{ .name = "stored pointer assignment publishes", .source =
    \\fn f() !void { var tool = j.object(); const slot = j.ptr(&doc.value, "tool"); slot.* = tool; try j.put(a, &tool, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, &tool" },
    .{ .name = "array element assignment publishes", .source =
    \\fn f() !void { var tool = j.object(); tools.array.items[0] = tool; try j.put(a, &tool, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, &tool" },
    .{ .name = "publication through preexisting alias", .source =
    \\fn f() !void { var tool = j.object(); var alias = tool; try tools.array.append(alias); try tool.object.put(a, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, \"revision\"" },
    .{ .name = "registry conditional response alias", .source =
    \\fn f() !void { var result: V = .null; switch (kind) { 6 => { var tool = j.object(); try tools.array.append(tool); result = tool; }, else => {} } if (changed) { if (result == .null) result = j.object(); try j.put(a, &result, "revision", revision); } }
    , .rule = "OWN002", .at = "put(a, &result" },
    .{ .name = "fresh response projection", .source =
    \\fn f() !void { var tool = j.object(); try tools.array.append(tool); var result = j.object(); try j.put(a, &result, "name", j.get(tool, "name")); try j.put(a, &result, "revision", revision); }
    },
    .{ .name = "post-publication read only alias", .source =
    \\fn f() !void { var tool = j.object(); try tools.array.append(tool); const alias = tool; _ = encode(alias); }
    },
    .{ .name = "reassigned fresh header", .source =
    \\fn f() !void { var tool = j.object(); try tools.array.append(tool); tool = j.object(); try j.put(a, &tool, "revision", revision); }
    },
    .{ .name = "root put", .source =
    \\fn f() !void { try j.put(a, &doc.value, "active", run); }
    , .rule = "OWN004", .at = "put(a, &doc" },
    .{ .name = "root object put", .source =
    \\fn f() !void { try doc.value.object.put(a, "suspended", run); }
    , .rule = "OWN004", .at = "put(a, \"suspended\"" },
    .{ .name = "root aliases", .source =
    \\fn f() !void { var root = &doc.value; try j.put(a, root, "active", run); }
    , .rule = "OWN004", .at = "put(a, root" },
    .{ .name = "root slot ptr overwrite", .source =
    \\fn f() !void { const slot = j.ptr(&doc.value, "active"); var alias = slot; alias.* = run; }
    , .rule = "OWN004", .at = "= run" },
    .{ .name = "root slot getPtr overwrite", .source =
    \\fn f() !void { const slot = doc.value.object.getPtr("suspended").?; slot.* = run; }
    , .rule = "OWN004", .at = "= run" },
    .{ .name = "nested child pointer writes remain legal", .source =
    \\fn f() !void { const active = j.ptr(&doc.value, "active"); const model = j.ptr(active, "model"); model.* = value; try j.put(a, active, "stop", yes); }
    },
    .{ .name = "snapshot result suspended is not a run slot", .source =
    \\fn f() !void { var result = j.object(); try j.put(a, &result, "suspended", snapshot); }
    },
    .{ .name = "exact authorized module", .source =
    \\fn f() !void { try j.put(a, &doc.value, "active", run); }
    , .path = "packages/agent/src/RunState.zig" },
    .{ .name = "basename impostor", .source =
    \\fn f() !void { try j.put(a, &doc.value, "active", run); }
    , .path = "packages/other/src/RunState.zig", .rule = "OWN004", .at = "put(a, &doc" },
    .{ .name = "JSON import alias", .source =
    \\const json = @import("json.zig"); fn f() !void { var run = json.get(doc.value, "active"); try json.put(a, &run, "extra", token); _ = estimate(doc.value); }
    , .rule = "OWN001", .at = "put(a, &run" },
    .{ .name = "writeback of stale pre-mutation copy is not restoration", .source =
    \\fn f() !void { var history = j.get(state, "history"); var alias = history; try alias.array.append(item); try j.put(a, &state, "history", history); _ = encode(state); }
    , .rule = "OWN001", .at = "append(item)" },
    .{ .name = "copy after mutation can restore updated header", .source =
    \\fn f() !void { var history = j.get(state, "history"); try history.array.append(item); var alias = history; try j.put(a, &state, "history", alias); _ = encode(state); }
    },
    .{ .name = "writeback on only one branch is insufficient", .source =
    \\fn f() !void { var history = j.get(state, "history"); try history.array.append(item); if (restore) try j.put(a, &state, "history", history); _ = encode(state); }
    , .rule = "OWN001", .at = "append(item)" },
    .{ .name = "mutate and restore within one branch", .source =
    \\fn f() !void { var history = j.get(state, "history"); if (update) { try history.array.append(item); try j.put(a, &state, "history", history); } _ = encode(state); }
    },
    .{ .name = "publication on terminated branch does not freeze surviving builder", .source =
    \\fn f() !void { var tool = j.object(); if (publish) { try tools.array.append(tool); return; } try j.put(a, &tool, "revision", revision); }
    },
    .{ .name = "publication in nested loop body", .source =
    \\fn f() !void { var tool = j.object(); for (tools.array.items) |*old| { old.* = tool; } try j.put(a, &tool, "revision", revision); }
    , .rule = "OWN002", .at = "put(a, &tool" },
    .{ .name = "publication on terminated switch branch", .source =
    \\fn f() !void { var tool = j.object(); switch (kind) { 1 => { try tools.array.append(tool); return; }, else => {} } try j.put(a, &tool, "revision", revision); }
    },
    .{ .name = "direct root pointer child remains legal", .source =
    \\fn f() !void { const slot = doc.value.object.getPtr("active").?; try slot.object.put(a, "stop", yes); }
    },
    .{ .name = "same basename under additional path cannot bypass exact owner", .source =
    \\fn f() !void { try j.put(a, &doc.value, "active", run); }
    , .path = "other/packages/agent/src/RunState.zig", .rule = "OWN004", .at = "put(a, &doc" },
};

fn parse(source: [:0]const u8) !std.zig.Ast {
    var tree = try std.zig.Ast.parse(a, source, .{});
    errdefer tree.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    return tree;
}

test "ownership rules and safe controls report exact source tokens" {
    for (cases) |case| {
        var tree = try parse(case.source);
        defer tree.deinit(a);
        const findings = try analysis.analyze(a, &tree, case.path);
        defer a.free(findings);
        if (case.rule) |rule| {
            const offset = std.mem.indexOf(u8, case.source, case.at).?;
            var found = false;
            for (findings) |f| {
                if (std.mem.eql(u8, f.rule, rule) and tree.tokenStart(f.token) == offset) found = true;
            }
            if (!found) std.debug.print("case {s} expected {s} at byte {d}; got {any}\n", .{ case.name, rule, offset, findings });
            try std.testing.expect(found);
            try std.testing.expectEqual(@as(usize, 1), findings.len);
        } else {
            if (findings.len != 0) std.debug.print("safe case {s}: {any}\n", .{ case.name, findings });
            try std.testing.expectEqual(@as(usize, 0), findings.len);
        }
    }
}

const prior_sources = [_][:0]const u8{
    @embedFile("fixtures/prior/domain_ops.zig"),
    @embedFile("fixtures/prior/logic.zig"),
};

test "live consumed body and ContextStore writeback controls remain legal" {
    const paths = [_][]const u8{
        "packages/agent/src/provider.zig",
        "packages/cpi_example_terminus/src/ContextStore.zig",
    };
    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1024 * 1024));
        defer a.free(bytes);
        const source = try a.dupeSentinel(u8, bytes, 0);
        defer a.free(source);
        var tree = try parse(source);
        defer tree.deinit(a);
        const findings = try analysis.analyze(a, &tree, path);
        defer a.free(findings);
        for (findings) |f| {
            const location = tree.tokenLocation(0, f.token);
            std.debug.print("safe live source {s}:{d}:{d} {s}\n", .{ path, location.line + 1, location.column + 1, f.rule });
        }
        try std.testing.expectEqual(@as(usize, 0), findings.len);
    }
}
const Manifest = struct {
    revision: []const u8,
    files: []const struct {
        fixture: []const u8,
        source: []const u8,
        sha256: []const u8,
        expected: []const struct { rule: []const u8, line: usize, column: usize },
    },
};
const prior_manifest: Manifest = @import("fixtures/prior/manifest.zon");

test "verbatim historical controls have valid Zig syntax and pinned hashes" {
    try std.testing.expectEqualStrings("01ca874da1e0f2eb8415e1b2b51f8975231d47da", prior_manifest.revision);
    try std.testing.expectEqual(prior_sources.len, prior_manifest.files.len);
    for (prior_sources, prior_manifest.files) |source, record| {
        var tree = try parse(source);
        defer tree.deinit(a);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
        try std.testing.expectEqualStrings(record.sha256, &std.fmt.bytesToHex(hash, .lower));
    }
}

test "historical yieldContext and registry alias fail their intended ownership rules" {
    for (prior_sources, prior_manifest.files) |source, record| {
        var tree = try parse(source);
        defer tree.deinit(a);
        const findings = try analysis.analyze(a, &tree, record.source);
        defer a.free(findings);
        for (record.expected) |expected| {
            var found = false;
            for (findings) |f| {
                const location = tree.tokenLocation(0, f.token);
                if (std.mem.eql(u8, f.rule, expected.rule) and location.line + 1 == expected.line and location.column + 1 == expected.column) found = true;
            }
            if (!found) {
                for (findings) |f| {
                    const location = tree.tokenLocation(0, f.token);
                    std.debug.print("{s}:{d}:{d} {s}\n", .{ record.source, location.line + 1, location.column + 1, f.rule });
                }
            }
            try std.testing.expect(found);
        }
    }
}
