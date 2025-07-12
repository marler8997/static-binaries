pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cpython_dep = b.dependency("cpython", .{
        .target = target,
        .optimize = optimize,
    });
    const install = b.addInstallArtifact(cpython_dep.artifact("cpython"), .{});
    b.getInstallStep().dependOn(&install.step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = cpython_dep.path("Lib"),
        .install_dir = .lib,
        .install_subdir = "python3.11",
    }).step);
}

const std = @import("std");
