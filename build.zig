const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("kernels/ijk.c"), .flags = &.{"-std=c11"} });
    const exe = b.addExecutable(.{ .name = "bench", .root_module = mod });
    b.installArtifact(exe);
}
