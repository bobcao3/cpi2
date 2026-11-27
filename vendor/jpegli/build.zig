const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{}).path("");
    const highway = b.dependency("highway", .{}).path("");
    const libjpeg = b.dependency("libjpeg_turbo", .{}).path("");
    const library = b.addLibrary(.{
        .name = "jpegli",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .pic = true,
        }),
    });
    const mod = library.root_module;
    const config = b.addWriteFiles();
    // Match jpegli upstream's 8-bit libjpeg v6b ABI.
    const jconfig = config.add("jconfig.h",
        \\#ifndef CPI_JPEGLI_JCONFIG_H
        \\#define CPI_JPEGLI_JCONFIG_H
        \\#define JPEG_LIB_VERSION 62
        \\#define LIBJPEG_TURBO_VERSION 2.1.5.1
        \\#define LIBJPEG_TURBO_VERSION_NUMBER 2001005
        \\#define BITS_IN_JSAMPLE 8
        \\#define MEM_SRCDST_SUPPORTED 1
        \\#endif
        \\
    );
    mod.addIncludePath(jconfig.dirname());
    mod.addIncludePath(libjpeg);
    mod.addIncludePath(upstream);
    mod.addIncludePath(highway);
    mod.addCMacro("HWY_STATIC_DEFINE", "1");
    mod.addCSourceFiles(.{
        .root = highway,
        .files = &.{
            "hwy/abort.cc",
            "hwy/aligned_allocator.cc",
            "hwy/nanobenchmark.cc",
            "hwy/per_target.cc",
            "hwy/perf_counters.cc",
            "hwy/print.cc",
            "hwy/profiler.cc",
            "hwy/targets.cc",
            "hwy/timer.cc",
        },
        .flags = &.{"-std=c++17"},
    });
    mod.addCSourceFiles(.{
        .root = upstream.path(b, "lib"),
        .files = &.{
            // JPEGLI_INTERNAL_JPEGLI_SOURCES from the pinned upstream.
            "jpegli/adaptive_quantization.cc",
            "jpegli/bit_writer.cc",
            "jpegli/bitstream.cc",
            "jpegli/color_quantize.cc",
            "jpegli/color_transform.cc",
            "jpegli/common.cc",
            "jpegli/decode.cc",
            "jpegli/decode_marker.cc",
            "jpegli/decode_scan.cc",
            "jpegli/destination_manager.cc",
            "jpegli/downsample.cc",
            "jpegli/encode.cc",
            "jpegli/encode_finish.cc",
            "jpegli/encode_streaming.cc",
            "jpegli/entropy_coding.cc",
            "jpegli/error.cc",
            "jpegli/huffman.cc",
            "jpegli/idct.cc",
            "jpegli/input.cc",
            "jpegli/memory_manager.cc",
            "jpegli/quant.cc",
            "jpegli/render.cc",
            "jpegli/simd.cc",
            "jpegli/source_manager.cc",
            "jpegli/upsample.cc",
        },
        .flags = &.{"-std=c++17"},
    });
    library.installHeader(jconfig, "jconfig.h");
    for ([_][]const u8{ "jpeglib.h", "jmorecfg.h" }) |path| {
        library.installHeader(libjpeg.path(b, path), path);
    }
    for ([_][]const u8{ "lib/base/include_jpeglib.h", "lib/jpegli/common.h", "lib/jpegli/decode.h", "lib/jpegli/encode.h", "lib/jpegli/types.h" }) |path| {
        library.installHeader(upstream.path(b, path), path);
    }
    b.installArtifact(library);
    const licenses = b.addNamedWriteFiles("licenses");
    _ = licenses.addCopyFile(upstream.path(b, "LICENSE"), "jpegli/LICENSE");
    _ = licenses.addCopyFile(upstream.path(b, "PATENTS"), "jpegli/PATENTS");
    _ = licenses.addCopyFile(highway.path(b, "LICENSE"), "highway/LICENSE");
    _ = licenses.addCopyFile(libjpeg.path(b, "LICENSE.md"), "libjpeg-turbo/LICENSE.md");
    _ = licenses.addCopyFile(libjpeg.path(b, "README.ijg"), "libjpeg-turbo/README.ijg");
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = licenses.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "share/licenses",
    }).step);
}
