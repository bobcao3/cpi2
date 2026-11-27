const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{}).path("");
    const miniz = b.dependency("miniz", .{}).path("");
    const library = b.addLibrary(.{
        .name = "spng",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    const mod = library.root_module;
    const config = b.addWriteFiles();
    mod.addIncludePath(config.add("miniz_export.h", "#define MINIZ_EXPORT\n").dirname());
    mod.addIncludePath(miniz);
    mod.addCMacro("SPNG_STATIC", "1");
    mod.addCMacro("SPNG_USE_MINIZ", "1");
    mod.addCMacro("MINIZ_NO_ARCHIVE_APIS", "1");
    mod.addCMacro("MINIZ_NO_STDIO", "1");
    mod.addCSourceFile(.{ .file = upstream.path(b, "spng/spng.c"), .flags = &.{"-std=c99"} });
    mod.addCSourceFiles(.{
        .root = miniz,
        .files = &.{ "miniz.c", "miniz_tdef.c", "miniz_tinfl.c" },
        .flags = &.{"-std=c99"},
    });
    library.installHeader(upstream.path(b, "spng/spng.h"), "spng.h");
    b.installArtifact(library);
    const licenses = b.addNamedWriteFiles("licenses");
    _ = licenses.addCopyFile(upstream.path(b, "LICENSE"), "libspng/LICENSE");
    _ = licenses.addCopyFile(miniz.path(b, "LICENSE"), "miniz/LICENSE");
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = licenses.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/licenses",
    }).step);
}
