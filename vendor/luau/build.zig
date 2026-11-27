const std = @import("std");
const sources = @import("sources.zig");

const Component = enum {
    common,
    ast,
    bytecode,
    compiler,
    vm,

    fn directory(component: Component) []const u8 {
        return switch (component) {
            .common => "Common",
            .ast => "Ast",
            .bytecode => "Bytecode",
            .compiler => "Compiler",
            .vm => "VM",
        };
    }

    fn includes(component: Component) []const []const u8 {
        return switch (component) {
            .common => &.{"Common"},
            .ast => &.{ "Ast", "Common" },
            .bytecode => &.{ "Bytecode", "Common" },
            .compiler => &.{ "Compiler", "Ast", "Bytecode", "Common" },
            .vm => &.{ "VM", "Common" },
        };
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{});

    const diagnostics = b.addExecutable(.{
        .name = "luau-call-diagnostics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/call_diagnostics.zig"),
            .target = b.graph.host,
        }),
    });
    const common = addLibrary(b, upstream, target, optimize, .common, diagnostics);
    const ast = addLibrary(b, upstream, target, optimize, .ast, diagnostics);
    const bytecode = addLibrary(b, upstream, target, optimize, .bytecode, diagnostics);
    const compiler = addLibrary(b, upstream, target, optimize, .compiler, diagnostics);
    const vm = addLibrary(b, upstream, target, optimize, .vm, diagnostics);

    ast.root_module.linkLibrary(common);
    bytecode.root_module.linkLibrary(common);
    compiler.root_module.linkLibrary(ast);
    compiler.root_module.linkLibrary(bytecode);
    vm.root_module.linkLibrary(common);
    vm.installHeader(b.path("include/luau.h"), "luau.h");

    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("include/luau.h"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(upstream.path("VM/include"));
    bindings.addIncludePath(upstream.path("Compiler/include"));
    const module = b.addModule("luau", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{.{ .name = "bindings", .module = bindings.createModule() }},
    });
    module.linkLibrary(vm);
    module.linkLibrary(compiler);

    for ([_]*std.Build.Step.Compile{ common, ast, bytecode, compiler, vm }) |library| {
        b.installArtifact(library);
    }
    for ([_][]const u8{ "LICENSE.txt", "lua_LICENSE.txt" }) |file| {
        const install = b.addInstallFile(upstream.path(file), b.fmt("share/licenses/luau/{s}", .{file}));
        b.getInstallStep().dependOn(&install.step);
    }

    const repl = b.addExecutable(.{
        .name = "luau-repl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("repl_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "luau", .module = module }},
        }),
    });
    const native_extensions = switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };
    repl.rdynamic = native_extensions;
    if (target.result.os.tag == .linux) repl.root_module.linkSystemLibrary("dl", .{});
    b.installArtifact(repl);
    const run_repl = b.addRunArtifact(repl);
    run_repl.stdio = .inherit;
    run_repl.has_side_effects = true;
    b.step("repl", "Run the embedded Luau REPL").dependOn(&run_repl.step);

    const test_step = b.step("test", "Test C, C++, and Zig embedding");
    const repl_test = b.addSystemCommand(&.{"python3"});
    repl_test.addFileArg(b.path("tests/repl.py"));
    repl_test.addArtifactArg(repl);
    if (native_extensions) {
        const posix = addExtension(b, upstream, target, optimize, "repl_posix", "examples/posix.c");
        const failing = addExtension(b, upstream, target, optimize, "repl_failing", "tests/failing_extension.c");
        b.installArtifact(posix);
        repl_test.addArtifactArg(posix);
        repl_test.addArtifactArg(failing);
    }
    test_step.dependOn(&repl_test.step);
    for ([_][]const u8{ "embed.c", "cpp.cpp" }) |file| {
        const executable = b.addExecutable(.{
            .name = b.fmt("luau-{s}", .{file}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        executable.root_module.linkLibrary(vm);
        executable.root_module.linkLibrary(compiler);
        executable.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("tests/{s}", .{file})),
            .flags = &.{ "-Wall", "-Wextra", "-Werror" },
        });
        test_step.dependOn(&b.addRunArtifact(executable).step);
    }

    const zig_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/import.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "luau", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zig_tests).step);
}

fn addLibrary(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    comptime component: Component,
    diagnostics: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    for (component.includes()) |directory| {
        module.addIncludePath(upstream.path(b.fmt("{s}/include", .{directory})));
    }
    if (optimize != .debug) module.addCMacro("NDEBUG", "1");
    if (target.result.os.tag == .windows) module.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
    if (component == .vm) {
        module.addCMacro("LUA_API", "extern \"C\"");
        module.addCMacro("LUA_USE_LONGJMP", "1");
    }
    if (component == .compiler) module.addCMacro("LUACODE_API", "extern \"C\"");

    const flags: []const []const u8 = switch (component) {
        .vm => &.{
            "-std=c++17",
            "-Wall",
            "-Wimplicit-fallthrough",
            "-Wsign-compare",
            "-fno-math-errno",
        },
        .ast => &.{ "-std=c++17", "-Wall", "-Wimplicit-fallthrough", "-Wsign-compare" },
        else => &.{"-std=c++17"},
    };
    if (component == .compiler or component == .vm)
        module.addIncludePath(upstream.path(b.fmt("{s}/src", .{component.directory()})));
    for (@field(sources, @tagName(component))) |source| {
        const upstream_file = upstream.path(source);
        const base = std.fs.path.basename(source);
        const file = if (std.mem.eql(u8, base, "Compiler.cpp") or
            std.mem.eql(u8, base, "lvmexecute.cpp") or std.mem.eql(u8, base, "lvmutils.cpp"))
        file: {
            const patch = b.addRunArtifact(diagnostics);
            patch.addArg(base);
            patch.addFileArg(upstream_file);
            break :file patch.addOutputFileArg(base);
        } else upstream_file;
        module.addCSourceFile(.{ .file = file, .flags = flags });
    }
    const library = b.addLibrary(.{
        .name = b.fmt("Luau.{s}", .{component.directory()}),
        .linkage = .static,
        .root_module = module,
    });
    for (component.includes()) |directory| {
        library.installHeadersDirectory(
            upstream.path(b.fmt("{s}/include", .{directory})),
            "",
            .{},
        );
    }
    return library;
}

fn addExtension(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    module.addIncludePath(b.path("include"));
    module.addIncludePath(upstream.path("VM/include"));
    module.addIncludePath(upstream.path("Compiler/include"));
    module.addCSourceFile(.{
        .file = b.path(source),
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" },
    });
    const extension = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = module,
    });
    extension.linker_allow_shlib_undefined = true;
    return extension;
}
