// server_linux.zig — Linux runtime backend.
//
// What this file owns: anything that names a Linux syscall by its true name.
// `mmap` with `MAP_POPULATE`, `signalfd` for reload, `SO_REUSEPORT` for
// per-CPU listeners, `sched_setaffinity` for thread pinning,
// `TCP_DEFER_ACCEPT` for the cold-connection wakeup. Everything above the
// kernel — request parsing, encoding selection, the response itself — is in
// `server_core.zig` and shared with the other backends.

const std = @import("std");
const core = @import("server_core.zig");
const bundle = @import("bundle.zig");
const config_mod = @import("config.zig");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;

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
        .{ .TYPE = .PRIVATE, .POPULATE = true },
        fd,
        0,
    );
    errdefer posix.munmap(mapped);
    // Hint the kernel: we'll touch every page (sequential); pre-fault now.
    posix.madvise(mapped.ptr, size, posix.MADV.WILLNEED) catch {};
    posix.madvise(mapped.ptr, size, posix.MADV.SEQUENTIAL) catch {};
    return try core.parseBundle(allocator, mapped);
}

fn createListener(addr: net.Address) !posix.socket_t {
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    const yes: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, mem.asBytes(&yes));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, mem.asBytes(&yes));
    // TCP_DEFER_ACCEPT: kernel buffers initial request bytes and only wakes
    // accept() when data is ready. Saves one context switch on cold connections.
    const defer_secs: c_int = 1;
    _ = posix.setsockopt(fd, posix.IPPROTO.TCP, 9, mem.asBytes(&defer_secs)) catch {}; // TCP_DEFER_ACCEPT = 9
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 4096);
    return fd;
}

/// Pin the calling thread to a specific CPU. Improves L1/L2 cache locality
/// since each worker tends to handle the same connection range repeatedly.
/// The kernel would do something reasonable on its own; we are merely insisting.
fn pinToCpu(cpu: usize) void {
    const linux = std.os.linux;
    var set: linux.cpu_set_t = @splat(0);
    const word_bits = @bitSizeOf(@TypeOf(set[0]));
    set[cpu / word_bits] |= @as(@TypeOf(set[0]), 1) << @intCast(cpu % word_bits);
    linux.sched_setaffinity(0, &set) catch {};
}

const WorkerCtx = struct { addr: *const net.Address, cpu: usize };

fn workerLoop(ctx: WorkerCtx) void {
    blockSigHup(); // defense in depth — already inherited from main, but make sure
    pinToCpu(ctx.cpu);
    const fd = createListener(ctx.addr.*) catch return;
    defer posix.close(fd);
    while (true) {
        const child = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch continue;
        const stream = net.Stream{ .handle = child };
        core.handleConn(stream);
        stream.close();
    }
}

/// Block SIGHUP in this and all subsequently-spawned threads. The dedicated
/// reload thread reads it via signalfd; workers never see it.
fn blockSigHup() void {
    var set = std.os.linux.sigemptyset();
    std.os.linux.sigaddset(&set, std.os.linux.SIG.HUP);
    const rc = std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &set, null);
    if (rc != 0) std.debug.print("baker: sigprocmask BLOCK failed (rc={d})\n", .{rc});
}

/// SIGPIPE on a write() to a closed socket would otherwise terminate the
/// process. Ignore it; write() will return EPIPE and we handle that locally.
fn ignoreSigpipe() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

fn debugSigHandler(sig: c_int) callconv(.c) void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "baker: caught signal {d}\n", .{sig}) catch return;
    _ = std.posix.write(2, msg) catch {};
    // Then re-raise default handler so we still die (just want to know which).
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@intCast(sig), &act, null);
    _ = std.os.linux.kill(std.os.linux.getpid(), @intCast(sig));
}

fn installDebugHandlers() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = debugSigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{ std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.QUIT, std.posix.SIG.USR1, std.posix.SIG.USR2 }) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
}

const ReloadCtx = struct { bundle_path: []const u8, allocator: std.mem.Allocator };

fn reloadLoop(ctx: ReloadCtx) void {
    var set = std.os.linux.sigemptyset();
    std.os.linux.sigaddset(&set, std.os.linux.SIG.HUP);
    const fd_raw = std.os.linux.signalfd(-1, &set, 0);
    const fd_signed: isize = @bitCast(fd_raw);
    if (fd_signed < 0) {
        std.debug.print("baker: signalfd creation failed (rc={d})\n", .{fd_raw});
        return;
    }
    const fd: i32 = @intCast(fd_signed);
    std.debug.print("baker: reload thread ready (signalfd={d})\n", .{fd});
    var info: std.os.linux.signalfd_siginfo = undefined;
    while (true) {
        const n = posix.read(fd, mem.asBytes(&info)) catch |err| {
            std.debug.print("baker: signalfd read failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (n != @sizeOf(@TypeOf(info))) {
            std.debug.print("baker: signalfd short read ({d} bytes)\n", .{n});
            continue;
        }
        const new_b = loadBundle(ctx.allocator, ctx.bundle_path) catch |err| {
            std.debug.print("baker: SIGHUP reload failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const old = core.current_bundle.swap(new_b, .acq_rel);
        std.debug.print("baker: SIGHUP reload — {d} routes\n", .{new_b.toc.len});
        // v0.1: leak old bundle. v0.2 will track in-flight requests + munmap after grace.
        // The cost is whatever the bundle weighs, paid once per reload, and forgiven
        // by every restart. A future version will be tidier; this one is honest.
        _ = old;
    }
}

pub fn run(opts: core.RunOptions) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    blockSigHup();
    ignoreSigpipe();
    installDebugHandlers();

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
    const n_threads = @max(1, std.Thread.getCpuCount() catch 1);

    std.debug.print("baker: loaded {d} routes from {s}{s}\n", .{
        b.toc.len,
        opts.bundle_path,
        if (b.not_found != null) " (custom 404 active)" else "",
    });
    std.debug.print("baker: serving http://{s}:{d}  ({d} reuseport listeners)\n", .{ opts.bind, opts.port, n_threads });
    std.debug.print("baker: SIGHUP triggers re-mmap of {s}\n", .{opts.bundle_path});

    const reload_ctx = ReloadCtx{
        .bundle_path = opts.bundle_path,
        .allocator = allocator,
    };
    std.debug.print("baker: spawning reload thread...\n", .{});
    const reload_t = Thread.spawn(.{}, reloadLoop, .{reload_ctx}) catch |err| {
        std.debug.print("baker: reload thread spawn failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("baker: reload thread spawned\n", .{});
    reload_t.detach();

    var i: usize = 1;
    while (i < n_threads) : (i += 1) {
        const t = try Thread.spawn(.{}, workerLoop, .{WorkerCtx{ .addr = &addr, .cpu = i }});
        t.detach();
    }
    workerLoop(.{ .addr = &addr, .cpu = 0 });
}

/// Convenience: load runtime opts from a ZON config file (or auto-discover one
/// at `baker.config.zon` / `baker.zon`) and call run() with them.
///
/// Uses an arena: the config strings live for the life of the process; the
/// server loop never returns, so freeing per-allocation would be busywork —
/// and on the error path, the GPA leak detector would otherwise spam stderr
/// with every ZON-parsed string.
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
