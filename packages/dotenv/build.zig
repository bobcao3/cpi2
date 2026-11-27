const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("dotenv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/dotenv_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dotenv", .module = module }},
    }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Test the dotenv package").dependOn(&run.step);
}
