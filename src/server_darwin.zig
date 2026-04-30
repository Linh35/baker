// server_darwin.zig — macOS runtime backend. Stub.
//
// Plan when this is filled in:
//   - File mapping: posix.mmap (drop MAP_POPULATE; macOS rejects it).
//     posix.madvise(WILLNEED, SEQUENTIAL) works as on Linux.
//   - Listener: macOS SO_REUSEPORT does not load-balance the way Linux's
//     does — first listener wins. So a single listener and a thread pool
//     pulling from a shared accept loop, or one listener and worker threads
//     calling accept() on it under contention. Drop TCP_DEFER_ACCEPT.
//   - CPU pinning: skip — macOS deprecated the affinity API.
//   - Reload: kqueue with EVFILT_SIGNAL on SIGHUP, on a dedicated thread.
//     Same atomic swap into core.current_bundle as Linux.
//   - SIGPIPE: still ignore (POSIX).
//   - Allocator + run/runFromConfig orchestration: lift mostly verbatim
//     from server_linux.zig.

const core = @import("server_core.zig");

pub const RunOptions = core.RunOptions;

pub fn run(opts: core.RunOptions) !void {
    _ = opts;
    @compileError("baker: macOS backend not yet implemented — see src/server_darwin.zig");
}

pub fn runFromConfig(config_path: ?[]const u8) !void {
    _ = config_path;
    @compileError("baker: macOS backend not yet implemented — see src/server_darwin.zig");
}
