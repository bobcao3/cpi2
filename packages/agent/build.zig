const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const luau = b.dependency("luau", .{ .target = target, .optimize = optimize });
    const zstd = b.dependency("zstd", .{ .target = target, .optimize = optimize }).module("zstd");
    const kit = b.dependency("kit", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    const json_tree = b.dependency("json_tree", .{ .target = target, .optimize = optimize });
    const session_protocol = b.addModule("session_protocol", .{
        .root_source_file = b.path("src/session_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_tree", .module = json_tree.module("json_tree") }},
    });
    const memory_budget = b.addModule("memory_budget", .{
        .root_source_file = b.path("src/MemoryBudget.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("include/cpi/agent.h"),
        .target = target,
        .optimize = optimize,
    });
    const vm = b.addModule("vm", .{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
        .imports = &.{ .{ .name = "luau", .module = luau.module("luau") }, .{ .name = "memory_budget", .module = memory_budget } },
    });
    vm.linkLibrary(luau.artifact("Luau.VM"));
    vm.linkLibrary(luau.artifact("Luau.Compiler"));
    vm.addIncludePath(b.path("src/vm"));
    vm.addCSourceFile(.{ .file = b.path("src/vm/bridge.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    vm.addCSourceFile(.{ .file = b.path("src/vm/compile.cpp"), .flags = &.{"-std=c++17"} });
    const root = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
        .imports = &.{
            .{ .name = "vm", .module = vm },
            .{ .name = "kit", .module = kit.module("kit") },
            .{ .name = "services", .module = services.module("services") },
        },
    });
    root.addImport("session_protocol", session_protocol);
    const library = b.addLibrary(.{
        .name = "cpi_agent",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
            .imports = &.{ .{ .name = "abi", .module = bindings.createModule() }, .{ .name = "vm", .module = vm }, .{ .name = "kit", .module = kit.module("kit") }, .{ .name = "services", .module = services.module("services") } },
        }),
    });
    library.installHeader(b.path("include/cpi/agent.h"), "cpi/agent.h");
    b.installArtifact(library);
    const executable = b.addExecutable(.{ .name = "cpi-agent", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = root }},
    }) });
    b.installArtifact(executable);
    const adapter_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/provider_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "agent", .module = root }, .{ .name = "services", .module = services.module("services") } },
    }) });
    const check_adapters = b.addRunArtifact(adapter_tests);
    b.step("test-provider", "Test provider configuration and service routing").dependOn(&check_adapters.step);
    const engine_api = b.createModule(.{
        .root_source_file = b.path("src/engine_tests_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "vm", .module = vm }, .{ .name = "kit", .module = kit.module("kit") }, .{ .name = "services", .module = services.module("services") } },
    });
    const contract_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/contract_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = engine_api }},
    }) });
    const check_contracts = b.addRunArtifact(contract_tests);
    b.step("test-contracts", "Test pending steering and registry revision contracts").dependOn(&check_contracts.step);
    const native_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/native_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = engine_api }},
    }) });
    native_tests.root_module.addImport("json_tree", json_tree.module("json_tree"));
    const check_native = b.addRunArtifact(native_tests);
    const check_executable = b.addSystemCommand(&.{"python3"});
    check_executable.addFileArg(b.path("scripts/test_native.py"));
    check_executable.addFileInput(b.path("scripts/session_reference.py"));
    check_executable.addArtifactArg(executable);
    const check_framing = b.addSystemCommand(&.{"python3"});
    check_framing.addFileArg(b.path("scripts/test_framing.py"));
    check_framing.addFileInput(b.path("scripts/session_reference.py"));
    check_framing.addArtifactArg(executable);
    const native = b.step("test-native", "Test native worker actor and executable");
    native.dependOn(&check_native.step);
    native.dependOn(&check_executable.step);
    native.dependOn(&check_framing.step);

    const tests = b.step("test", "Test the native worker, executable, framing, and provider");
    const frame_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/session_frame_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_protocol", .module = session_protocol }},
    }) });
    frame_tests.root_module.addAnonymousImport("session_frame_examples", .{ .root_source_file = b.path("docs/session-frame-examples.md") });
    const check_frames = b.addRunArtifact(frame_tests);
    const semantic_journal_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/SessionJournal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "session_protocol", .module = session_protocol }, .{ .name = "kit", .module = kit.module("kit") }, .{ .name = "zstd", .module = zstd } },
    }) });
    const run_semantic_journal = b.addRunArtifact(semantic_journal_tests);
    b.step("test-session-journal", "Test semantic gzip transaction durability and replay").dependOn(&run_semantic_journal.step);
    tests.dependOn(&run_semantic_journal.step);
    const protocol_tests = b.addTest(.{ .root_module = session_protocol });
    const check_protocol = b.addRunArtifact(protocol_tests);
    const frame_step = b.step("test-session-frames", "Validate semantic session frame types and documented histories");
    frame_step.dependOn(&check_frames.step);
    frame_step.dependOn(&check_protocol.step);
    tests.dependOn(frame_step);
    const domain_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/domain_ops_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "vm", .module = vm }, .{ .name = "kit", .module = kit.module("kit") } },
    }) });
    const run_domain = b.addRunArtifact(domain_tests);
    b.step("test-domain", "Test execution context growth, suspension, and ownership").dependOn(&run_domain.step);
    tests.dependOn(&run_domain.step);
    const controller_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/controller_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{ .{ .name = "vm", .module = vm }, .{ .name = "kit", .module = kit.module("kit") }, .{ .name = "services", .module = services.module("services") } },
    }) });
    const check_controller = b.addRunArtifact(controller_tests);
    b.step("test-controller", "Test controller admission, programs and service ownership").dependOn(&check_controller.step);
    tests.dependOn(&check_controller.step);
    const semantic_domain = b.addTest(.{ .name = "agent-domain-check", .root_module = domain_tests.root_module });
    const semantic_controller = b.addTest(.{ .name = "agent-controller-check", .root_module = controller_tests.root_module });
    const semantic = b.step("check", "Compile agent domain and controller checks without running them");
    semantic.dependOn(&semantic_domain.step);
    semantic.dependOn(&semantic_controller.step);
    const check_abi = b.addSystemCommand(&.{"python3"});
    check_abi.addFileArg(b.path("scripts/test_abi.py"));
    check_abi.addFileInput(b.path("scripts/session_reference.py"));
    check_abi.addArtifactArg(library);
    tests.dependOn(&check_abi.step);
    b.step("test-abi", "Test C ABI ownership and crash recovery").dependOn(&check_abi.step);
    tests.dependOn(&check_adapters.step);
    tests.dependOn(&check_contracts.step);
    tests.dependOn(&check_native.step);
    tests.dependOn(&check_executable.step);
    tests.dependOn(&check_framing.step);
    b.step("test-journal", "Test semantic session transactions").dependOn(&run_semantic_journal.step);
    for ([_]*std.Build.Module{ root, library.root_module, engine_api, domain_tests.root_module, controller_tests.root_module }) |module| {
        module.addImport("session_protocol", session_protocol);
        module.addImport("memory_budget", memory_budget);
        module.addImport("json_tree", json_tree.module("json_tree"));
        module.addImport("zstd", zstd);
    }
    const smoke = b.createModule(.{
        .root_source_file = b.path("src/vm/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "vm", .module = vm }, .{ .name = "json_tree", .module = json_tree.module("json_tree") } },
    });
    smoke.addAnonymousImport("read_source", .{ .root_source_file = b.path("extensions/read.lua") });
    smoke.addAnonymousImport("bash_source", .{ .root_source_file = b.path("extensions/bash.lua") });
    const vm_tests = b.addTest(.{ .root_module = smoke });
    const vm_check = b.step("test-vm", "Test VM allocation and lifetime boundaries");
    vm_check.dependOn(&b.addRunArtifact(vm_tests).step);
    const memory_tests = b.addTest(.{ .root_module = memory_budget });
    vm_check.dependOn(&b.addRunArtifact(memory_tests).step);
    tests.dependOn(vm_check);
}
