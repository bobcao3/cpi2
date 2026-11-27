const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kit = b.dependency("kit", .{ .target = target, .optimize = optimize });
    const module = b.addModule("json_tree", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kit", .module = kit.module("kit") }},
    });
    b.step("test", "Test structural JSON projection and ownership").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}
