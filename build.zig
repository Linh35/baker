// build.zig — baker package build script.
//
// Produces a single executable, `baker`, with these subcommands:
//   baker bake | serve | run | init | help
//
// Also exposes the `baker` Zig module for advanced consumers that want to
// embed the runtime in their own executable (rare — most users just call
// the binary). Links libbrotli + zlib for the bake path; the runtime path
// inside the same binary doesn't use them, but they're statically present.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from release binaries") orelse false;

    // ---- baker: unified CLI ----
    const baker_exe = b.addExecutable(.{
        .name = "baker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    baker_exe.linkSystemLibrary("brotlienc");
    baker_exe.linkSystemLibrary("z");
    baker_exe.linkLibC();
    b.installArtifact(baker_exe);

    // ---- runtime library: still exposed for embedders. Most users won't need it. ----
    _ = b.addModule("baker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- tests ----
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
