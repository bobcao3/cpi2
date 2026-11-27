const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const json_tree = b.dependency("json_tree", .{ .target = target, .optimize = optimize });
    const module = b.addModule("services", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "json_tree", .module = json_tree.module("json_tree") }},
    });
    const executable = b.addExecutable(.{
        .name = "cpi-services",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "services", .module = module }},
        }),
    });
    b.installArtifact(executable);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test service registration").dependOn(&b.addRunArtifact(tests).step);
}
