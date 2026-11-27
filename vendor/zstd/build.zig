const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{});
    const library = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    const mod = library.root_module;
    const asm_enabled = target.result.cpu.arch == .x86_64 and
        (target.result.os.tag == .linux or target.result.os.tag == .macos);
    mod.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/pool.c",
            "common/threading.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",
            "decompress/zstd_decompress_block.c",
        },
        .flags = if (asm_enabled) &.{} else &.{"-DZSTD_DISABLE_ASM"},
    });
    if (asm_enabled) mod.addAssemblyFile(upstream.path("lib/decompress/huf_decompress_amd64.S"));

    const translate = b.addTranslateC(.{ .root_source_file = b.path("src/bindings.h"), .target = target, .optimize = optimize });
    translate.addIncludePath(upstream.path("lib"));
    const bindings = translate.addModule("zstd");
    bindings.linkLibrary(library);
}
