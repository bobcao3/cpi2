const std = @import("std");

const Grammar = struct {
    name: []const u8,
    sources: []const []const u8 = &.{"src/parser.c"},
    license: []const u8 = "LICENSE",
};

const grammars = [_]Grammar{
    .{ .name = "zig" },
    .{ .name = "python", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "javascript", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "typescript", .sources = &.{ "typescript/src/parser.c", "typescript/src/scanner.c", "tsx/src/parser.c", "tsx/src/scanner.c" } },
    .{ .name = "rust", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "go" },
    .{ .name = "c" },
    .{ .name = "cpp", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "bash", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "lua", .sources = &.{ "src/parser.c", "src/scanner.c" }, .license = "LICENSE.md" },
    .{ .name = "json" },
    .{ .name = "yaml", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "toml", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "css", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "html", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "java" },
    .{ .name = "ruby", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "nix", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "c_sharp", .sources = &.{ "src/parser.c", "src/scanner.c" } },
    .{ .name = "php", .sources = &.{ "php/src/parser.c", "php/src/scanner.c" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{}).path("");
    const engine = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    const native = engine.root_module;
    const include = upstream.path(b, "include");
    native.addIncludePath(include);
    native.addIncludePath(upstream.path(b, "src"));
    native.addCSourceFile(.{ .file = upstream.path(b, "src/lib.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-D_POSIX_C_SOURCE=200809L" } });

    const bindings = b.addTranslateC(.{ .root_source_file = include.path(b, "tree_sitter/api.h"), .target = target, .optimize = optimize });
    const module = b.addModule("tree_sitter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "api", .module = bindings.createModule() }},
    });
    module.linkLibrary(engine);
    engine.installHeader(include.path(b, "tree_sitter/api.h"), "tree_sitter/api.h");
    b.installArtifact(engine);
    const licenses = b.addNamedWriteFiles("licenses");
    _ = licenses.addCopyFile(b.path("LICENSE"), "tree-sitter/LICENSE");
    _ = licenses.addCopyFile(upstream.path(b, "src/unicode/LICENSE"), "tree-sitter/ICU-LICENSE");
    inline for (grammars) |grammar| {
        const source = b.dependency(grammar.name, .{}).path("");
        for (grammar.sources, 0..) |file, index| {
            const unit = b.addObject(.{
                .name = b.fmt("tree-sitter-{s}-{d}", .{ grammar.name, index }),
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .pic = true,
                }),
            });
            unit.root_module.addIncludePath(source.path(b, std.fs.path.dirname(file).?));
            unit.root_module.addCSourceFile(.{ .file = source.path(b, file), .flags = &.{"-std=c11"} });
            native.addObject(unit);
        }
        module.addAnonymousImport(grammar.name, .{ .root_source_file = source.path(b, "queries/highlights.scm") });
        _ = licenses.addCopyFile(source.path(b, grammar.license), b.fmt("tree-sitter-{s}/LICENSE", .{grammar.name}));
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = licenses.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/licenses",
    }).step);
}
