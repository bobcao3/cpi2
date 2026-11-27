const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agent = b.dependency("agent", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    const ghostmux = b.dependency("ghostmux", .{ .target = target, .optimize = optimize });
    const context_journal = b.addModule("context_journal", .{
        .root_source_file = b.path("src/ContextJournal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_protocol", .module = agent.module("session_protocol") }},
    });
    const context_tests = b.addTest(.{ .root_module = context_journal });
    const run_context_tests = b.addRunArtifact(context_tests);
    b.step("test-context-journal", "Test harness-owned private context journal format").dependOn(&run_context_tests.step);
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "session_protocol", .module = agent.module("session_protocol") },
        .{ .name = "agent", .module = agent.module("agent") },
        .{ .name = "services", .module = services.module("services") },
    };

    const cli = b.addExecutable(.{
        .name = "cpi-terminus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(cli);

    const worker_driver = b.addExecutable(.{
        .name = "terminus-worker-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/worker_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const boundary_probe = b.addExecutable(.{
        .name = "terminus-boundary-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/worker_boundary_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const install_probe = b.addInstallArtifact(boundary_probe, .{});
    b.step("build-boundary-probe", "Build the Worker boundary diagnostic").dependOn(&install_probe.step);
    const probe_test = b.addRunArtifact(boundary_probe);
    probe_test.addDirectoryArg(b.path(".zig-cache"));
    b.step("test-boundary", "Verify real Worker isolation and denied file effects").dependOn(&probe_test.step);
    const cli_tests = b.addSystemCommand(&.{ "python3", "-B" });
    cli_tests.addFileArg(b.path("tests/test_cli.py"));
    cli_tests.addFileInput(b.path("tests/test_support.py"));
    cli_tests.addArtifactArg(cli);
    cli_tests.addArtifactArg(ghostmux.artifact("ghostmux"));

    const worker_tests = b.addSystemCommand(&.{ "python3", "-B" });
    const metadata_tests = b.addSystemCommand(&.{ "python3", "-B" });
    const cancellation_tests = b.addSystemCommand(&.{ "python3", "-B" });
    cancellation_tests.addFileArg(b.path("tests/test_worker.py"));
    cancellation_tests.addFileInput(b.path("tests/test_support.py"));
    metadata_tests.addFileArg(b.path("tests/test_worker.py"));
    metadata_tests.addFileInput(b.path("tests/test_support.py"));
    metadata_tests.addFileInput(b.path("tests/parser_expected.json"));
    worker_tests.addFileArg(b.path("tests/test_worker.py"));
    worker_tests.addFileInput(b.path("tests/test_support.py"));
    worker_tests.addFileInput(b.path("tests/parser_expected.json"));
    for ([_][]const u8{
        "access.luau",
        "common.luau",
        "echo.luau",
        "ghostmux-router.sh",
        "once.luau",
        "parser.luau",
        "parser_driver.luau",
        "probe.luau",
        "probe_child.luau",
        "prompts.luau",
        "terminus.luau",
    }) |file| {
        worker_tests.addFileInput(b.path(b.fmt("src/guest/{s}", .{file})));
        metadata_tests.addFileInput(b.path(b.fmt("src/guest/{s}", .{file})));
        cancellation_tests.addFileInput(b.path(b.fmt("src/guest/{s}", .{file})));
    }
    worker_tests.addArtifactArg(worker_driver);
    worker_tests.addArtifactArg(ghostmux.artifact("ghostmux"));
    metadata_tests.addArtifactArg(worker_driver);
    metadata_tests.addArtifactArg(ghostmux.artifact("ghostmux"));
    metadata_tests.addArg("--metadata-only");
    cancellation_tests.addArtifactArg(worker_driver);
    cancellation_tests.addArtifactArg(ghostmux.artifact("ghostmux"));
    cancellation_tests.addArg("--cancellation-only");
    b.step("test-cancellation", "Repeat stalled-provider cancellation and require joined driver exit").dependOn(&cancellation_tests.step);
    b.step("test-metadata", "Verify context authority, provider denial and joined cancellation").dependOn(&metadata_tests.step);
    const tests = b.step("test", "Test the Terminus CLI and Worker runtime with local fixtures");
    tests.dependOn(&run_context_tests.step);
    tests.dependOn(&worker_tests.step);
    tests.dependOn(&cancellation_tests.step);
    tests.dependOn(&cli_tests.step);
    tests.dependOn(&probe_test.step);
    b.step("test-worker", "Test Worker programs with local fixtures").dependOn(&worker_tests.step);

    b.step("test-large-output", "Run CLI checks including bounded large-output observations").dependOn(&cli_tests.step);
}
