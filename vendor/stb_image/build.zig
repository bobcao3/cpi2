const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{}).path("");
    const library = b.addLibrary(.{
        .name = "stb_image",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    const mod = library.root_module;
    mod.addIncludePath(upstream);
    mod.addCMacro("STBI_ONLY_GIF", "1");
    mod.addCMacro("STBI_ONLY_BMP", "1");
    mod.addCMacro("STBI_NO_STDIO", "1");
    mod.addCSourceFile(.{ .file = b.path("src/implementation.c"), .flags = &.{"-std=c99"} });
    library.installHeader(b.path("src/stb_image_gif_bmp.h"), "stb_image_gif_bmp.h");
    b.installArtifact(library);
    const licenses = b.addNamedWriteFiles("licenses");
    _ = licenses.addCopyFile(upstream.path(b, "LICENSE"), "stb_image/LICENSE");
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = licenses.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/licenses",
    }).step);
}
