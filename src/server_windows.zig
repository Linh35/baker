// server_windows.zig — Windows runtime backend.
//
// Differences from the POSIX backends, in order of consequence:
//   - No mmap. We read the bundle into a page-aligned heap buffer at startup
//     and again on reload. For small static sites the resident-memory cost is
//     identical to a demand-paged mmap; for very large bundles this loses
//     cold-page laziness but stays correct.
//   - No POSIX signals. SIGHUP is gone, sigwait is gone, signalfd is gone.
//     We poll the bundle file's mtime once a second on a dedicated thread and
//     reload when it changes. ReadDirectoryChangesW would be slightly more
//     elegant; mtime polling has the merit of working everywhere unchanged.
//   - Winsock: WSAStartup must be called before any socket call. Zig's
//     std.posix wrappers do not do this for us.
//   - SO_REUSEPORT does not exist. Single listener fd, thread pool contends
//     on accept(). Same shape as the macOS backend.
//   - No CPU pinning for v1. SetThreadAffinityMask is straightforward to add
//     later if it earns its keep on Windows.
//   - No SIGPIPE on Windows; closed sockets surface as WSAECONNABORTED /
//     WSAECONNRESET, which net.Stream.write returns as an error we already
//     handle in core.handleConn.

const std = @import("std");
const core = @import("server_core.zig");
const config_mod = @import("config.zig");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const windows = std.os.windows;
const Thread = std.Thread;

pub const RunOptions = core.RunOptions;

/// Read the bundle into a page-aligned heap buffer. parseBundle requires
/// page-aligned input (Linux/macOS satisfy this trivially via mmap; here
/// the page allocator is the cleanest equivalent).
fn loadBundle(allocator: mem.Allocator, path: []const u8) !*core.Bundle {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size_u64 = try file.getEndPos();
    const size: usize = @intCast(size_u64);
    const buf = try std.heap.page_allocator.alignedAlloc(u8, std.heap.page_size_min, size);
    errdefer std.heap.page_allocator.free(buf);
    const n = try file.readAll(buf);
    if (n != size) return error.ShortRead;
    return try core.parseBundle(allocator, buf);
}

fn createListener(addr: net.Address) !posix.socket_t {
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    const yes: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, mem.asBytes(&yes));
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 4096);
    return fd;
}

const WorkerCtx = struct { listen_fd: posix.socket_t };

fn workerLoop(ctx: WorkerCtx) void {
    while (true) {
        const child = posix.accept(ctx.listen_fd, null, null, 0) catch continue;
        const stream = net.Stream{ .handle = child };
        core.handleConn(stream);
        stream.close();
    }
}

const ReloadCtx = struct { bundle_path: []const u8, allocator: mem.Allocator };

/// Watch the bundle file's mtime. Crude, portable, and predictable. On change,
/// load the new bundle and atomically swap. Old bundle is leaked, same as the
/// other backends in v0.1.
fn reloadLoop(ctx: ReloadCtx) void {
    var last_mtime: i128 = blk: {
        const stat = std.fs.cwd().statFile(ctx.bundle_path) catch break :blk 0;
        break :blk stat.mtime;
    };
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        const stat = std.fs.cwd().statFile(ctx.bundle_path) catch continue;
        if (stat.mtime == last_mtime) continue;
        last_mtime = stat.mtime;
        const new_b = loadBundle(ctx.allocator, ctx.bundle_path) catch |err| {
            std.debug.print("baker: reload failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const old = core.current_bundle.swap(new_b, .acq_rel);
        std.debug.print("baker: reload — {d} routes\n", .{new_b.toc.len});
        _ = old;
    }
}

pub fn run(opts: core.RunOptions) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Winsock must be initialized before any socket call.
    var wsa_data: windows.ws2_32.WSADATA = undefined;
    if (windows.ws2_32.WSAStartup(0x0202, &wsa_data) != 0) {
        return error.WSAStartupFailed;
    }
    defer _ = windows.ws2_32.WSACleanup();

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
    std.debug.print("baker: bundle file mtime polled for reload (1s interval)\n", .{});

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
