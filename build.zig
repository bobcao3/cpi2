const std = @import("std");
const ownership_build = @import("tools/ownership/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (b.pkg_hash.len == 0 and (b.graph.release_mode == .off or b.graph.release_mode == .any)) b.graph.release_mode = .safe;
    const optimize = b.standardOptimizeOption(.{});
    const json_tree = b.dependency("json_tree", .{ .target = target, .optimize = optimize });
    const luau = b.dependency("luau", .{ .target = target, .optimize = optimize });
    const agent = b.dependency("agent", .{ .target = target, .optimize = optimize });
    const dotenv = b.dependency("dotenv", .{ .target = target, .optimize = optimize });
    const registry = b.dependency("model_registry", .{ .target = target, .optimize = optimize });
    const mcp = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const ghostmux = b.dependency("ghostmux", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    const terminus = b.dependency("cpi_example_terminus", .{ .target = target, .optimize = optimize });
    const minimal = b.dependency("cpi_minimal", .{ .target = target, .optimize = optimize });
    const ownership = ownership_build.add(b, "tools/ownership");
    b.step("lint-ownership", "Check JSON ownership and run-slot boundaries").dependOn(ownership.lint);
    b.step("ownership-lint", "Run ownership lint with optional paths and --json").dependOn(ownership.cli);
    const ownership_tests = b.step("test-ownership", "Verify ownership rules against safe cases and prior defects");
    ownership_tests.dependOn(ownership.lint);
    ownership_tests.dependOn(ownership.tests);
    const check = b.step("check", "Check ownership rules and agent semantics without running tools");
    check.dependOn(ownership.lint);
    check.dependOn(&agent.builder.top_level_steps.get("check").?.step);

    b.getInstallStep().dependOn(luau.builder.getInstallStep());
    b.installArtifact(agent.artifact("cpi_agent"));
    b.installArtifact(agent.artifact("cpi-agent"));
    b.getInstallStep().dependOn(ghostmux.builder.getInstallStep());
    b.installArtifact(services.artifact("cpi-services"));
    b.installArtifact(terminus.artifact("cpi-terminus"));
    const install_minimal = b.addInstallArtifact(minimal.artifact("cpi-minimal"), .{});
    b.getInstallStep().dependOn(&install_minimal.step);
    const build_minimal = b.step("build-minimal", "Build the Minimal executable");
    build_minimal.dependOn(&install_minimal.step);
    const licenses = b.addInstallDirectory(.{
        .source_dir = minimal.namedWriteFiles("licenses").getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/cpi/licenses",
    });
    b.getInstallStep().dependOn(&licenses.step);
    build_minimal.dependOn(&licenses.step);
    b.installArtifact(registry.artifact("cpi-model-registry"));
    const install_models = b.addInstallFile(b.path("packages/model_registry/data/models.lua"), "share/cpi/models.lua");
    b.getInstallStep().dependOn(&install_models.step);
    build_minimal.dependOn(&install_models.step);
    const tests = b.step("test", "Test Luau and all cpi2 packages");
    tests.dependOn(&json_tree.builder.top_level_steps.get("test").?.step);
    b.step("test-json-tree", "Test structural JSON conversion").dependOn(&json_tree.builder.top_level_steps.get("test").?.step);
    const session_prototype = b.step("test-session-prototype", "Exercise Worker application isolation, cancellation, and Terminus persistence");
    const terminus_prototype = b.addSystemCommand(&.{ "python3", "-B" });
    terminus_prototype.addFileArg(b.path("packages/cpi_example_terminus/tests/prove-session-terminus.py"));
    terminus_prototype.addArtifactArg(terminus.artifact("cpi-terminus"));
    terminus_prototype.addArtifactArg(ghostmux.artifact("ghostmux"));
    terminus_prototype.has_side_effects = true;
    session_prototype.dependOn(&terminus_prototype.step);
    session_prototype.dependOn(&agent.builder.top_level_steps.get("test-controller").?.step);
    tests.dependOn(ownership_tests);
    tests.dependOn(&luau.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&agent.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&dotenv.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&registry.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&mcp.builder.top_level_steps.get("test").?.step);
    b.step("test-mcp", "Test the reusable MCP protocol package").dependOn(&mcp.builder.top_level_steps.get("test").?.step);
    b.step("test-model-registry", "Test the reusable model registry and catalog scripts").dependOn(&registry.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&ghostmux.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&services.builder.top_level_steps.get("test").?.step);
    tests.dependOn(&terminus.builder.top_level_steps.get("test").?.step);
    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("packages/services/scripts/test.py"));
    integration.addArtifactArg(services.artifact("cpi-services"));
    integration.addArtifactArg(ghostmux.artifact("ghostmux"));
    integration.addArtifactArg(agent.artifact("cpi_agent"));
    tests.dependOn(&integration.step);
    const service_tests = b.step("test-services", "Test native services through RPC and agent tools");
    service_tests.dependOn(&integration.step);
    service_tests.dependOn(&services.builder.top_level_steps.get("test").?.step);
    b.step("test-terminus", "Test the Terminus agent example").dependOn(&terminus.builder.top_level_steps.get("test").?.step);
    b.step("test-terminus-metadata", "Test Terminus context authority and provider denial").dependOn(&terminus.builder.top_level_steps.get("test-metadata").?.step);
    b.step("test-terminus-cancellation", "Test joined Terminus cancellation").dependOn(&terminus.builder.top_level_steps.get("test-cancellation").?.step);
    b.step("test-terminus-large-output", "Test large Terminus terminal output").dependOn(&terminus.builder.top_level_steps.get("test-large-output").?.step);
    b.step("test-ghostmux", "Test the native ghostmux package").dependOn(&ghostmux.builder.top_level_steps.get("test").?.step);
    b.step("test-agent-domain", "Test execution context growth, suspension, and ownership").dependOn(&agent.builder.top_level_steps.get("test-domain").?.step);
    b.step("test-agent", "Test native agent, C ABI, and provider").dependOn(
        &agent.builder.top_level_steps.get("test").?.step,
    );
    b.step("test-vm", "Test vm boundaries").dependOn(&agent.builder.top_level_steps.get("test-vm").?.step);
    b.step("test-journal", "Test journal boundaries").dependOn(&agent.builder.top_level_steps.get("test-journal").?.step);
    b.step("test-session-frames", "Test the semantic session action model").dependOn(&agent.builder.top_level_steps.get("test-session-frames").?.step);
    b.step("test-session-journal", "Test semantic session journal storage").dependOn(&agent.builder.top_level_steps.get("test-session-journal").?.step);
    const context_journals = b.step("test-session-contexts", "Test harness-owned context journal formats");
    context_journals.dependOn(&terminus.builder.top_level_steps.get("test-context-journal").?.step);
    const context_contract_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/agent/src/context_journal_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_protocol", .module = agent.module("session_protocol") },
            .{ .name = "terminus_context_journal", .module = terminus.module("context_journal") },
        },
    }) });
    context_journals.dependOn(&b.addRunArtifact(context_contract_tests).step);
    tests.dependOn(context_journals);
    b.step("test-abi", "Test the native C ABI and crash recovery").dependOn(&agent.builder.top_level_steps.get("test-abi").?.step);
    b.step("test-native", "Test native worker persistence").dependOn(&agent.builder.top_level_steps.get("test-native").?.step);
    b.step("test-controller", "Test controller policy and service scheduling").dependOn(&agent.builder.top_level_steps.get("test-controller").?.step);
    const process_owner = b.addExecutable(.{ .name = "controller-process-owner-test", .root_module = b.createModule(.{
        .root_source_file = b.path("packages/agent/src/process_owner_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent.module("agent") }, .{ .name = "services", .module = services.module("services") } },
    }) });
    const check_process_owner = b.addSystemCommand(&.{ "python3", "-B" });
    check_process_owner.addFileArg(b.path("packages/agent/scripts/test_process_owner.py"));
    check_process_owner.addArtifactArg(process_owner);
    check_process_owner.addArtifactArg(ghostmux.artifact("ghostmux"));
    tests.dependOn(&check_process_owner.step);
    service_tests.dependOn(&check_process_owner.step);
    b.top_level_steps.get("test-controller").?.step.dependOn(&check_process_owner.step);
    b.top_level_steps.get("test-agent").?.step.dependOn(ownership_tests);
    b.step("test-dotenv", "Test the reusable dotenv package").dependOn(
        &dotenv.builder.top_level_steps.get("test").?.step,
    );
    b.step("test-provider", "Test provider configuration and service routing").dependOn(
        &agent.builder.top_level_steps.get("test-provider").?.step,
    );
    b.step("repl", "Run the embedded Luau REPL").dependOn(
        &luau.builder.top_level_steps.get("repl").?.step,
    );
}
