// check_runtime.zig — cross-target compile-check entry point.
//
// Why: the full `baker` exe links libbrotli + zlib for the bake path, which
// aren't available without the target's sysroot when cross-compiling. The
// runtime path doesn't need them, but `addObject` of root.zig leaves
// unreferenced decls unanalysed, so backend regressions still slip through.
// This file forces analysis by referencing every public runtime symbol.
//
// Build via: zig build check-runtime -Dtarget=aarch64-macos
// Not shipped, not part of normal builds — only the check-runtime step uses it.

const baker = @import("baker");

pub fn main() !void {
    const opts: baker.RunOptions = .{ .bundle_path = "" };
    _ = opts;
    _ = &baker.run;
    _ = &baker.runFromConfig;
    _ = baker.Encoding.identity;
    _ = &baker.loadConfig;
    _ = &baker.freeConfig;
}
