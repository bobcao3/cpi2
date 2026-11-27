const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (b.pkg_hash.len == 0 and (b.graph.release_mode == .off or b.graph.release_mode == .any)) b.graph.release_mode = .safe;
    const optimize = b.standardOptimizeOption(.{});
    const agent = b.dependency("agent", .{ .target = target, .optimize = optimize });
    const kit = b.dependency("kit", .{ .target = target, .optimize = optimize });
    const dotenv = b.dependency("dotenv", .{ .target = target, .optimize = optimize });
    const json_tree = b.dependency("json_tree", .{ .target = target, .optimize = optimize });
    const registry = b.dependency("model_registry", .{ .target = target, .optimize = optimize });
    const mcp = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    _ = b.addModule("context_journal", .{
        .root_source_file = b.path("src/session/ContextJournal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_protocol", .module = agent.module("session_protocol") }},
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "session_protocol", .module = agent.module("session_protocol") },
        .{ .name = "json_tree", .module = json_tree.module("json_tree") },
        .{ .name = "services", .module = services.module("services") },
        .{ .name = "agent", .module = agent.module("agent") },
        .{ .name = "kit", .module = kit.module("kit") },
        .{ .name = "dotenv", .module = dotenv.module("dotenv") },
        .{ .name = "model_registry", .module = registry.module("model_registry") },
        .{ .name = "mcp", .module = mcp.module("mcp") },
    };
    const cli = b.addExecutable(.{ .name = "cpi-minimal", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    const Manifest = struct { version: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("Invalid cpi-minimal manifest: {s}", .{@errorName(err)});
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    cli.root_module.addOptions("build_options", build_options);
    addYaml(b, cli.root_module);
    addThemes(b, cli.root_module);
    const licenses = b.addNamedWriteFiles("licenses");
    const tree_sitter = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    cli.root_module.addImport("tree_sitter", tree_sitter.module("tree_sitter"));
    _ = licenses.addCopyDirectory(tree_sitter.namedWriteFiles("licenses").getDirectory(), "", .{});
    addImageCodecs(b, cli.root_module, target, optimize, licenses);
    b.installArtifact(cli);
    b.installArtifact(registry.artifact("cpi-model-registry"));
    for ([_][]const u8{ "LICENSE-FZF.txt", "THIRD_PARTY_NOTICES.md" }) |name| {
        _ = licenses.addCopyFile(b.path(name), name);
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = licenses.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/cpi/licenses",
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFile(registry.path("data/models.lua"), "share/cpi/models.lua").step);
    const runtime = b.addNamedWriteFiles("runtime");
    const runtime_cli = runtime.addCopyFile(cli.getEmittedBin(), "bin/cpi-minimal");
    _ = runtime.addCopyFile(registry.path("data/models.lua"), "share/cpi/models.lua");
    b.addNamedLazyPath("runtime_cli", runtime_cli);
    const run = std.Build.Step.Run.create(b, "run cpi-minimal");
    run.addFileArg(runtime_cli);
    run.addPassthruArgs();
    b.step("run", "Run cpi-minimal").dependOn(&run.step);
}

fn addImageCodecs(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, licenses: *std.Build.Step.WriteFile) void {
    const translate = b.addTranslateC(.{ .root_source_file = b.path("src/images/image_codecs.h"), .target = target, .optimize = optimize });
    inline for (.{
        .{ "libspng", "spng" },
        .{ "jpegli", "jpegli" },
        .{ "stb_image", "stb_image" },
        .{ "libwebp", "webp" },
    }) |codec| {
        const dependency = b.dependency(codec[0], .{ .target = target, .optimize = optimize });
        const library = dependency.artifact(codec[1]);
        module.linkLibrary(library);
        translate.addIncludePath(library.getEmittedIncludeTree());
        _ = licenses.addCopyDirectory(dependency.namedWriteFiles("licenses").getDirectory(), "", .{});
    }
    module.addImport("image_codecs", translate.createModule());
    module.addCSourceFile(.{ .file = b.path("src/images/image_jpeg.cpp"), .flags = &.{"-std=c++17"} });
}

fn addThemes(b: *std.Build, module: *std.Build.Module) void {
    const themes = b.dependency("pi_coding_agent", .{}).path("dist/modes/interactive/theme");
    module.addAnonymousImport("pi_dark_theme", .{ .root_source_file = themes.path(b, "dark.json") });
    module.addAnonymousImport("pi_light_theme", .{ .root_source_file = themes.path(b, "light.json") });
}

fn addYaml(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/libyaml/include"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/libyaml"),
        .files = &.{ "src/api.c", "src/reader.c", "src/scanner.c", "src/parser.c", "src/cpi_bridge.c" },
        .flags = &.{ "-DYAML_VERSION_MAJOR=0", "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5", "-DYAML_VERSION_STRING=\"0.2.5\"" },
    });
}
