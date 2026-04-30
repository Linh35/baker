// server_darwin.zig — macOS runtime backend.
//
// Differences from Linux that drove this file's shape:
//   - mmap: no MAP_POPULATE on Darwin (the kernel rejects unknown flags).
//     madvise(WILLNEED, SEQUENTIAL) is honoured; that's enough for our purposes.
//   - SO_REUSEPORT exists, but it does not load-balance accept() across
//     listeners the way Linux's does. So we run one listener fd and a thread
//     pool that contend on accept() — the kernel serializes correctly.
//   - TCP_DEFER_ACCEPT does not exist. We skip it; the cost is one extra
//     wakeup on cold connections.
//   - sched_setaffinity has been deprecated for a long while. We don't pin.
//   - signalfd does not exist. We use POSIX `sigwait` on a dedicated reload
//     thread; SIGHUP is blocked everywhere else so it can never reach a
//     handler. Same atomic swap into core.current_bundle as on Linux.

const std = @import("std");
const core = @import("server_core.zig");
const config_mod = @import("config.zig");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const c = std.c;

pub const RunOptions = core.RunOptions;

fn loadBundle(allocator: mem.Allocator, path: []const u8) !*core.Bundle {
    const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd);
    const stat = try posix.fstat(fd);
    const size: usize = @intCast(stat.size);
    const mapped = try posix.mmap(
        null,
        size,
        posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    errdefer posix.munmap(mapped);
    posix.madvise(mapped.ptr, size, posix.MADV.WILLNEED) catch {};
    posix.madvise(mapped.ptr, size, posix.MADV.SEQUENTIAL) catch {};
    return try core.parseBundle(allocator, mapped);
}

fn createListener(addr: net.Address) !posix.socket_t {
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    const yes: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, mem.asBytes(&yes));
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 4096);
    return fd;
}

const WorkerCtx = struct { listen_fd: posix.socket_t };

fn workerLoop(ctx: WorkerCtx) void {
    blockSigHup();
    while (true) {
        const child = posix.accept(ctx.listen_fd, null, null, posix.SOCK.CLOEXEC) catch continue;
        const stream = net.Stream{ .handle = child };
        core.handleConn(stream);
        stream.close();
    }
}

/// Block SIGHUP on the calling thread. The reload thread will drain it via sigwait.
fn blockSigHup() void {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, posix.SIG.HUP);
    var old: c.sigset_t = undefined;
    _ = c.pthread_sigmask(c.SIG.BLOCK, &set, &old);
}

fn ignoreSigpipe() void {
    var act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

const ReloadCtx = struct { bundle_path: []const u8, allocator: mem.Allocator };

fn reloadLoop(ctx: ReloadCtx) void {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, posix.SIG.HUP);
    while (true) {
        var sig: c_int = undefined;
        const rc = c.sigwait(&set, &sig);
        if (rc != 0) {
            std.debug.print("baker: sigwait failed (rc={d})\n", .{rc});
            continue;
        }
        const new_b = loadBundle(ctx.allocator, ctx.bundle_path) catch |err| {
            std.debug.print("baker: SIGHUP reload failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const old = core.current_bundle.swap(new_b, .acq_rel);
        std.debug.print("baker: SIGHUP reload — {d} routes\n", .{new_b.toc.len});
        _ = old; // v0.1: leak the old mapping. Same trade as Linux.
    }
}

pub fn run(opts: core.RunOptions) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    blockSigHup();
    ignoreSigpipe();

    const b = loadBundle(allocator, opts.bundle_path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "baker: bundle '{s}' not found — run `baker bake` first, or `baker run` to do both at once\n",
                .{opts.bundle_path},
            );
            return err;
        },
        else => return err,
    };
    core.current_bundle.store(b, .release);

    const addr = try net.Address.parseIp(opts.bind, opts.port);
    const listen_fd = try createListener(addr);

    const n_threads = @max(1, std.Thread.getCpuCount() catch 1);
    std.debug.print("baker: loaded {d} routes from {s}{s}\n", .{
        b.toc.len,
        opts.bundle_path,
        if (b.not_found != null) " (custom 404 active)" else "",
    });
    std.debug.print("baker: serving http://{s}:{d}  ({d} workers, single listener)\n", .{ opts.bind, opts.port, n_threads });
    std.debug.print("baker: SIGHUP triggers re-mmap of {s}\n", .{opts.bundle_path});

    const reload_t = try Thread.spawn(.{}, reloadLoop, .{ReloadCtx{
        .bundle_path = opts.bundle_path,
        .allocator = allocator,
    }});
    reload_t.detach();

    var i: usize = 1;
    while (i < n_threads) : (i += 1) {
        const t = try Thread.spawn(.{}, workerLoop, .{WorkerCtx{ .listen_fd = listen_fd }});
        t.detach();
    }
    workerLoop(.{ .listen_fd = listen_fd });
}

pub fn runFromConfig(config_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cfg: config_mod.Config = .{};
    var loaded_path: ?[]const u8 = null;

    if (config_path) |p| {
        cfg = try config_mod.loadFromFile(allocator, p);
        loaded_path = p;
    } else {
        for ([_][]const u8{ "baker.config.zon", "baker.zon" }) |p| {
            cfg = config_mod.loadFromFile(allocator, p) catch continue;
            loaded_path = p;
            break;
        }
    }
    if (loaded_path) |p| std.debug.print("baker: loaded config from {s}\n", .{p});

    try run(.{
        .bundle_path = cfg.bundle_path,
        .port = cfg.port,
        .bind = cfg.bind,
    });
}
