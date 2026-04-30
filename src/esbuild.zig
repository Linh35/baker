// esbuild.zig — optional bake-time wrapper around an externally-installed
// `esbuild` binary. Used when `compress.minifier` resolves to .esbuild.
// We never link against it — just spawn it, feed bytes via stdin, read
// minified bytes via stdout. One process per file is fine at our scale
// (typical static site = tens of files; spawn cost ~5–20 ms each).

const std = @import("std");
const mem = std.mem;

/// Returns true if `esbuild --version` exits 0.
pub fn available(allocator: mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "esbuild", "--version" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Map a path's extension to an esbuild loader, or null if esbuild has no
/// suitable loader (HTML/SVG/markdown/etc fall back to the builtin minifier).
pub fn loaderFor(path: []const u8) ?[]const u8 {
    const ends = std.ascii.endsWithIgnoreCase;
    if (ends(path, ".js") or ends(path, ".mjs")) return "js";
    if (ends(path, ".css")) return "css";
    if (ends(path, ".json")) return "json";
    return null;
}

/// Pipe `input` through `esbuild --minify --loader=<loader>` and return the
/// minified bytes. Caller frees. On any failure (spawn, non-zero exit, OOM)
/// returns an error so the caller can fall back to the builtin pass.
pub fn minify(allocator: mem.Allocator, loader: []const u8, input: []const u8) ![]u8 {
    const loader_arg = try std.fmt.allocPrint(allocator, "--loader={s}", .{loader});
    defer allocator.free(loader_arg);

    var child = std.process.Child.init(
        &.{ "esbuild", "--minify", loader_arg },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Write all input to stdin, then close it so esbuild can finish.
    // Don't wait on it before reading stdout — esbuild streams output.
    try child.stdin.?.writeAll(input);
    child.stdin.?.close();
    child.stdin = null;

    // Read stdout to completion. Bound at 64 MiB — same ceiling as
    // readFileAlloc in the bake walker.
    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(allocator);
    var read_buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&read_buf);
        if (n == 0) break;
        try stdout_buf.appendSlice(allocator, read_buf[0..n]);
        if (stdout_buf.items.len > 64 * 1024 * 1024) return error.EsbuildOutputTooLarge;
    }

    // Drain stderr so the child can exit cleanly. We surface it on failure only.
    var stderr_buf: std.ArrayList(u8) = .{};
    defer stderr_buf.deinit(allocator);
    while (true) {
        const n = try child.stderr.?.read(&read_buf);
        if (n == 0) break;
        try stderr_buf.appendSlice(allocator, read_buf[0..n]);
    }

    const term = try child.wait();
    const exited_ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        if (stderr_buf.items.len > 0) {
            std.debug.print("esbuild: {s}\n", .{stderr_buf.items});
        }
        return error.EsbuildFailed;
    }
    return try stdout_buf.toOwnedSlice(allocator);
}
