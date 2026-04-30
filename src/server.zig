// server.zig — runtime entry point and per-OS backend selector.
//
// The runtime is split three ways: portable bits in `server_core.zig`
// (request parsing, encoding pick, conditional GET, the response shape) and
// one platform file per supported OS (mmap/CreateFileMapping, listener
// setup, reload mechanism). This file picks the right backend at comptime
// and re-exports its surface.
//
// Backend status:
//   linux    — implemented (signalfd, SO_REUSEPORT-per-CPU, sched_setaffinity).
//   darwin   — stub. Planned: kqueue reload, single-listener thread pool.
//   windows  — stub. Planned: CreateFileMapping, named-event reload, Winsock.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("server_core.zig");

const backend = switch (builtin.os.tag) {
    .linux => @import("server_linux.zig"),
    .macos => @import("server_darwin.zig"),
    .windows => @import("server_windows.zig"),
    else => @compileError("baker: unsupported OS — supported: linux, macos (planned), windows (planned)"),
};

pub const RunOptions = core.RunOptions;
pub const run = backend.run;
pub const runFromConfig = backend.runFromConfig;

// Pull tests from sibling files into the test binary. (`@import` alone doesn't
// trigger test discovery — the reference inside `test {}` does.)
test {
    _ = @import("server_core.zig");
    _ = @import("config.zig");
    _ = @import("minify.zig");
    _ = @import("exclude.zig");
}
