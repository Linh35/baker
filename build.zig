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
    // Cross-target test builds (e.g. -Dtarget=aarch64-macos) compile fine but
    // can't be executed on the host. Skipping the foreign run turns the build
    // into a pure compile check, which is exactly what we want for verifying
    // the per-OS backends still build.
    run_tests.skip_foreign_checks = true;
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ---- runtime-only cross-target check ----
    // The full `baker` exe links libbrotli + zlib for the bake path, which
    // isn't available when cross-compiling to a different OS without that
    // sysroot. The runtime path (root.zig → server.zig → server_<os>.zig)
    // doesn't need either, so we compile it as a standalone object for any
    // target the user names. Catches per-OS backend regressions on a Linux
    // dev box.
    //
    //   zig build check-runtime -Dtarget=aarch64-macos
    //   zig build check-runtime -Dtarget=x86_64-windows
    const baker_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_exe = b.addExecutable(.{
        .name = "baker-runtime-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check_runtime.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "baker", .module = baker_mod }},
        }),
    });
    const check_step = b.step("check-runtime", "Type-check the runtime for the selected target (no bake-time deps)");
    check_step.dependOn(&check_exe.step);
}
