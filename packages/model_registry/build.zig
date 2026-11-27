const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agent = b.dependency("agent", .{ .target = target, .optimize = optimize });
    const luau = b.dependency("luau", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    b.installFile("data/models.lua", "share/cpi/models.lua");
    const bridge = b.addTranslateC(.{
        .root_source_file = b.path("runtime/bridge.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    const module = b.addModule("model_registry", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "luau", .module = luau.module("luau") },
            .{ .name = "registry_bridge", .module = bridge },
            .{ .name = "agent", .module = agent.module("agent") },
            .{ .name = "services", .module = services.module("services") },
        },
    });
    const host_agent = b.dependency("agent", .{ .target = b.graph.host, .optimize = optimize });
    const compiler = b.addExecutable(.{ .name = "compile-model-catalog", .root_module = b.createModule(.{
        .root_source_file = b.path("compile_catalog.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = host_agent.module("agent") }},
    }) });
    const compile_catalog = b.addRunArtifact(compiler);
    compile_catalog.addFileArg(b.path("data/models.lua"));
    module.addAnonymousImport("bundled_bytecode", .{ .root_source_file = compile_catalog.addOutputFileArg("models.luac") });
    module.linkLibrary(luau.artifact("Luau.VM"));
    module.linkLibrary(luau.artifact("Luau.Compiler"));
    module.addCSourceFile(.{ .file = b.path("runtime/bridge.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const evaluator = b.addExecutable(.{
        .name = "cpi-model-registry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("evaluator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "model_registry", .module = module }},
        }),
    });
    const install_evaluator = b.addInstallArtifact(evaluator, .{});
    b.getInstallStep().dependOn(&install_evaluator.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model_registry", .module = module }, .{ .name = "agent", .module = agent.module("agent") } },
    }) });
    const check = b.step("test", "Test registry loading and public catalog tooling");
    check.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    const scripts = b.addSystemCommand(&.{"env"});
    scripts.addArtifactArg2(evaluator, .{ .prefix = "CPI_MODEL_REGISTRY_EVALUATOR=" });
    scripts.addArgs(&.{ "python3", "-B" });
    scripts.addFileArg(b.path("scripts/test_model_registry.py"));
    scripts.addFileInput(b.path("scripts/model_registry.py"));
    scripts.addFileInput(b.path("scripts/first_party.py"));
    scripts.addFileInput(b.path("data/first_party_sources.json"));
    scripts.addFileInput(b.path("data/codex_client_version.txt"));
    scripts.addFileInput(b.path("data/models.lua"));
    scripts.addFileInput(b.path("data/api_overrides.json"));
    check.dependOn(&scripts.step);
}
