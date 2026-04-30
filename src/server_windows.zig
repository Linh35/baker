// server_windows.zig — Windows runtime backend. Stub.
//
// Plan when this is filled in:
//   - File mapping: CreateFileW + CreateFileMappingW + MapViewOfFile.
//     Hold the mapping handle so the file can be replaced (FILE_SHARE_DELETE).
//     PrefetchVirtualMemory as the WILLNEED equivalent.
//   - Listener: WSAStartup, single Winsock listener, worker threads call
//     accept() under contention. No SO_REUSEPORT-equivalent that load-balances.
//     For v1 stay synchronous; IOCP is the right Windows answer but it's a
//     different program and worth its own iteration.
//   - CPU pinning: SetThreadAffinityMask if we want it; arguably skip for v1.
//   - Reload: ReadDirectoryChangesW on the bundle's directory, or a named
//     event the user signals from a shipping helper. SIGHUP doesn't exist.
//   - No SIGPIPE — Windows write() returns WSAECONNABORTED / WSAECONNRESET.
//   - serveOne and handleConn from core should work unchanged: net.Stream
//     covers the read/write surface.

const core = @import("server_core.zig");

pub const RunOptions = core.RunOptions;

pub fn run(opts: core.RunOptions) !void {
    _ = opts;
    @compileError("baker: Windows backend not yet implemented — see src/server_windows.zig");
}

pub fn runFromConfig(config_path: ?[]const u8) !void {
    _ = config_path;
    @compileError("baker: Windows backend not yet implemented — see src/server_windows.zig");
}
