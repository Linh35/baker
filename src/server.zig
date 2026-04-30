// server.zig — baker runtime. Loads `baked.bin` via mmap at startup; serves
// requests with zero per-request allocations.
//
// Topology: one listener per CPU via SO_REUSEPORT. TCP_NODELAY. HTTP/1.1
// keep-alive with pipelining and 5s idle timeout. Content negotiation on
// Accept-Encoding (br > gz > identity).
//
// Hot reload: SIGHUP triggers re-mmap of the bundle file. The atomic
// pointer swap is single-instruction; in-flight requests finish on the
// old mapping.

const std = @import("std");
const bundle = @import("bundle.zig");
const config_mod = @import("config.zig");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

pub const Encoding = enum { identity, gzip, brotli };

pub const RunOptions = struct {
    bundle_path: []const u8,
    port: u16 = 8000,
    bind: []const u8 = "0.0.0.0",
};

const Bundle = struct {
    base: []align(std.heap.page_size_min) const u8,
    header: *const bundle.Header,
    toc: []const bundle.TocEntry,
    string_pool: []const u8,
    data: []const u8,
    not_found: ?[]const u8,

    fn pathOf(self: Bundle, e: bundle.TocEntry) []const u8 {
        return self.string_pool[e.path_offset .. e.path_offset + e.path_len];
    }
    fn identity(self: Bundle, e: bundle.TocEntry) []const u8 {
        return self.data[e.identity_offset .. e.identity_offset + e.identity_len];
    }
    fn gzip(self: Bundle, e: bundle.TocEntry) ?[]const u8 {
        if (e.flags & bundle.Flags.HAS_GZIP == 0) return null;
        return self.data[e.gzip_offset .. e.gzip_offset + e.gzip_len];
    }
    fn brotli(self: Bundle, e: bundle.TocEntry) ?[]const u8 {
        if (e.flags & bundle.Flags.HAS_BROTLI == 0) return null;
        return self.data[e.brotli_offset .. e.brotli_offset + e.brotli_len];
    }
};

var current_bundle: Atomic(?*const Bundle) = .init(null);

fn loadBundle(allocator: mem.Allocator, path: []const u8) !*Bundle {
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

    if (size < @sizeOf(bundle.Header)) return error.BundleTooSmall;
    const header: *const bundle.Header = @ptrCast(@alignCast(mapped.ptr));
    if (!mem.eql(u8, &header.magic, &bundle.MAGIC)) return error.InvalidMagic;
    if (header.version != bundle.VERSION) return error.UnsupportedVersion;

    const toc_ptr: [*]const bundle.TocEntry = @ptrCast(@alignCast(mapped.ptr + header.toc_offset));
    const data_slice = mapped[header.data_offset..][0..header.data_size];
    const b = try allocator.create(Bundle);
    b.* = .{
        .base = mapped,
        .header = header,
        .toc = toc_ptr[0..header.count],
        .string_pool = mapped[header.string_pool_offset..][0..header.string_pool_size],
        .data = data_slice,
        .not_found = if (header.not_found_len > 0)
            data_slice[header.not_found_offset..][0..header.not_found_len]
        else
            null,
    };
    return b;
}

fn pickEncoding(accept: []const u8) Encoding {
    if (mem.indexOf(u8, accept, "br") != null) return .brotli;
    if (mem.indexOf(u8, accept, "gzip") != null) return .gzip;
    return .identity;
}

fn lookup(b: *const Bundle, path: []const u8, accept: []const u8) ?[]const u8 {
    for (b.toc) |e| {
        if (!mem.eql(u8, b.pathOf(e), path)) continue;
        return switch (pickEncoding(accept)) {
            .brotli => b.brotli(e) orelse b.gzip(e) orelse b.identity(e),
            .gzip => b.gzip(e) orelse b.identity(e),
            .identity => b.identity(e),
        };
    }
    return null;
}

const not_found_resp: []const u8 =
    "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 14\r\nConnection: keep-alive\r\n\r\n404 not found\n";
const bad_request_resp: []const u8 =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 4\r\nConnection: close\r\n\r\n400\n";

const not_modified_prefix: []const u8 =
    "HTTP/1.1 304 Not Modified\r\nETag: ";
const not_modified_suffix: []const u8 =
    "\r\nVary: Accept-Encoding\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\n\r\n";

/// Find the ETag value (without surrounding quotes) inside a baked response,
/// or null if absent. Looks for the canonical line we emit.
fn etagInResponse(resp: []const u8) ?[]const u8 {
    const head_end = mem.indexOf(u8, resp, "\r\n\r\n") orelse return null;
    const headers = resp[0..head_end];
    const k = mem.indexOf(u8, headers, "ETag: \"") orelse return null;
    const start = k + "ETag: \"".len;
    const end_rel = mem.indexOfScalar(u8, headers[start..], '"') orelse return null;
    return headers[start .. start + end_rel];
}

fn ifNoneMatchValue(request_headers: []const u8) ?[]const u8 {
    const k = mem.indexOf(u8, request_headers, "If-None-Match:") orelse
        mem.indexOf(u8, request_headers, "if-none-match:") orelse return null;
    var i = k + "If-None-Match:".len;
    while (i < request_headers.len and (request_headers[i] == ' ' or request_headers[i] == '\t')) i += 1;
    if (i >= request_headers.len or request_headers[i] != '"') return null;
    i += 1;
    const end = mem.indexOfScalar(u8, request_headers[i..], '"') orelse return null;
    return request_headers[i .. i + end];
}

fn setReadTimeout(fd: posix.socket_t, secs: i64) void {
    const tv = posix.timeval{ .sec = secs, .usec = 0 };
    _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, mem.asBytes(&tv)) catch {};
}

fn enableNoDelay(fd: posix.socket_t) void {
    const yes: c_int = 1;
    _ = posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, mem.asBytes(&yes)) catch {};
}

fn serveOne(stream: net.Stream, req: []const u8) bool {
    const b = current_bundle.load(.acquire) orelse {
        _ = stream.writeAll(not_found_resp) catch {};
        return false;
    };

    const line_end = mem.indexOf(u8, req, "\r\n") orelse {
        _ = stream.writeAll(bad_request_resp) catch {};
        return false;
    };
    const line = req[0..line_end];
    const sp1 = mem.indexOfScalar(u8, line, ' ') orelse return false;
    const method = line[0..sp1];
    const is_head = mem.eql(u8, method, "HEAD");
    const after = line[sp1 + 1 ..];
    const sp2 = mem.indexOfScalar(u8, after, ' ') orelse return false;
    const target = after[0..sp2];
    const q = mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;

    const headers = req[line_end..];
    const accept_idx = mem.indexOf(u8, headers, "Accept-Encoding:") orelse
        mem.indexOf(u8, headers, "accept-encoding:");
    const accept_slice = if (accept_idx) |i| blk: {
        const eol = mem.indexOf(u8, headers[i..], "\r\n") orelse break :blk "";
        break :blk headers[i .. i + eol];
    } else "";

    const resp = lookup(b, path, accept_slice) orelse (b.not_found orelse not_found_resp);

    // Conditional GET: if the client's If-None-Match matches our response's
    // ETag, send 304 Not Modified with no body. Three-piece writev — the
    // ETag value is a slice into the baked response (in .rodata-equivalent
    // mapped memory), no copies.
    if (ifNoneMatchValue(headers)) |inm| {
        if (etagInResponse(resp)) |tag| {
            if (mem.eql(u8, inm, tag)) {
                const iov = [_]posix.iovec_const{
                    .{ .base = not_modified_prefix.ptr, .len = not_modified_prefix.len },
                    .{ .base = @as([*]const u8, @ptrCast("\"")), .len = 1 },
                    .{ .base = tag.ptr, .len = tag.len },
                    .{ .base = @as([*]const u8, @ptrCast("\"")), .len = 1 },
                    .{ .base = not_modified_suffix.ptr, .len = not_modified_suffix.len },
                };
                _ = posix.writev(stream.handle, &iov) catch return false;
                const close = mem.indexOf(u8, line, "HTTP/1.0") != null or
                    mem.indexOf(u8, headers, "Connection: close") != null or
                    mem.indexOf(u8, headers, "connection: close") != null;
                return !close;
            }
        }
    }

    if (is_head) {
        // HEAD: write only the response headers + blank line, no body.
        const head_end = (mem.indexOf(u8, resp, "\r\n\r\n") orelse return false) + 4;
        _ = stream.writeAll(resp[0..head_end]) catch return false;
    } else {
        _ = stream.writeAll(resp) catch return false;
    }

    // HTTP/1.1 default is keep-alive; only close on explicit "Connection: close"
    // or HTTP/1.0. Single substring scan covers both case variations cheaply
    // since modern clients almost never send the close header — fast path is one miss.
    // The two-step search (find "lose", then look back for "onnection: c") is
    // ugly and worth the ugliness: the common case never reads the second line.
    if (mem.indexOf(u8, line, "HTTP/1.0") != null) return false;
    if (mem.indexOf(u8, headers, "lose")) |i| {
        const start = if (i >= 16) i - 16 else 0;
        if (mem.indexOf(u8, headers[start..i], "onnection: c") != null) return false;
    }
    return true;
}

fn handleConn(stream: net.Stream) void {
    setReadTimeout(stream.handle, 5);
    enableNoDelay(stream.handle);
    var buf: [16384]u8 = undefined;
    var have: usize = 0;
    while (true) {
        const n = stream.read(buf[have..]) catch return;
        if (n == 0) return;
        have += n;
        while (true) {
            const end = mem.indexOf(u8, buf[0..have], "\r\n\r\n") orelse break;
            const req_len = end + 4;
            if (!serveOne(stream, buf[0..req_len])) return;
            const left = have - req_len;
            if (left > 0) std.mem.copyForwards(u8, buf[0..left], buf[req_len..have]);
            have = left;
        }
        if (have == buf.len) return;
    }
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
        handleConn(stream);
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
        const old = current_bundle.swap(new_b, .acq_rel);
        std.debug.print("baker: SIGHUP reload — {d} routes\n", .{new_b.toc.len});
        // v0.1: leak old bundle. v0.2 will track in-flight requests + munmap after grace.
        // The cost is whatever the bundle weighs, paid once per reload, and forgiven
        // by every restart. A future version will be tidier; this one is honest.
        _ = old;
    }
}

pub fn run(opts: RunOptions) !void {
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
    current_bundle.store(b, .release);

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

test "pickEncoding prefers br over gzip over identity" {
    try std.testing.expectEqual(Encoding.brotli, pickEncoding("gzip, br"));
    try std.testing.expectEqual(Encoding.gzip, pickEncoding("gzip, deflate"));
    try std.testing.expectEqual(Encoding.identity, pickEncoding(""));
    try std.testing.expectEqual(Encoding.identity, pickEncoding("deflate"));
}

// Pull tests from sibling files into the test binary. (`@import` alone doesn't
// trigger test discovery — the reference inside `test {}` does.)
test {
    _ = @import("config.zig");
    _ = @import("minify.zig");
    _ = @import("exclude.zig");
}
