const std = @import("std");
const sources = @import("src/sources.zig");

pub const Checks = struct {
    lint: *std.Build.Step,
    tests: *std.Build.Step,
    cli: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const checks = add(b, ".");
    b.step("check", "Check repository JSON ownership").dependOn(checks.lint);
    const tests = b.step("test", "Test ownership analysis and scan the repository");
    tests.dependOn(checks.lint);
    tests.dependOn(checks.tests);
    b.step("run", "Run ownership lint with optional paths and --json").dependOn(checks.cli);
}

pub fn add(b: *std.Build, tool_path: []const u8) Checks {
    const tool = b.path(tool_path);
    const repository = b.pathJoin(&.{ tool_path, "../.." });
    const analyzer = b.createModule(.{
        .root_source_file = tool.path(b, "src/analysis.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const executable = b.addExecutable(.{ .name = "ownership-lint", .root_module = b.createModule(.{
        .root_source_file = tool.path(b, "src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "ownership_analysis", .module = analyzer }},
    }) });
    const lint = b.addRunArtifact(executable);
    lint.setCwd(b.path(repository));
    lint.enableProtocolMode();
    const root = b.root.joinString(b.allocator, repository) catch @panic("OOM");
    const paths = sources.collect(b.allocator, b.graph.io, root) catch |err| std.debug.panic("ownership source inventory failed: {s}", .{@errorName(err)});
    for (paths) |path| lint.addFileInput(b.path(b.pathJoin(&.{ repository, path })));

    const cli = b.addRunArtifact(executable);
    cli.setCwd(b.path(repository));
    cli.addPassthruArgs();

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = tool.path(b, "tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(repository));
    return .{ .lint = &lint.step, .tests = &run_tests.step, .cli = &cli.step };
}
