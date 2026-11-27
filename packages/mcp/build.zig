const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const json_tree = b.dependency("json_tree", .{ .target = target, .optimize = optimize });
    const services = b.dependency("services", .{ .target = target, .optimize = optimize });
    const module = b.addModule("mcp", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "json_tree", .module = json_tree.module("json_tree") },
            .{ .name = "services", .module = services.module("services") },
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit = b.addTest(.{ .root_module = module });
    const fixture = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "mcp", .module = module }},
    }) });
    const check = b.step("test", "Test MCP configuration, protocol, transports, and gateway");
    check.dependOn(&b.addRunArtifact(unit).step);
    check.dependOn(&b.addRunArtifact(fixture).step);
}
