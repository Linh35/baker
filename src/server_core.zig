// server_core.zig — OS-neutral runtime bits shared by every backend.
//
// What lives here: the on-the-wire shape of the server (parsing requests,
// picking encodings, answering conditional GETs, building 304s) and the
// in-memory shape of the bundle. What does not: anything that touches an
// `mmap`/`CreateFileMapping`, signals, listeners, or thread affinity. Those
// belong to the per-OS backend in `server_{linux,darwin,windows}.zig`.
//
// The split is by syscall family, not by language nicety. Two ports on two
// kernels will agree on what an HTTP/1.1 200 response looks like; they will
// not agree on how a process is asked to reload.

const std = @import("std");
const bundle = @import("bundle.zig");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Atomic = std.atomic.Value;

pub const Encoding = enum { identity, gzip, brotli };

pub const RunOptions = struct {
    bundle_path: []const u8,
    port: u16 = 8000,
    bind: []const u8 = "0.0.0.0",
};

pub const Bundle = struct {
    /// The full mapped region. Platform code owns the mapping; core just borrows.
    base: []align(std.heap.page_size_min) const u8,
    header: *const bundle.Header,
    toc: []const bundle.TocEntry,
    string_pool: []const u8,
    data: []const u8,
    not_found: ?[]const u8,

    pub fn pathOf(self: Bundle, e: bundle.TocEntry) []const u8 {
        return self.string_pool[e.path_offset .. e.path_offset + e.path_len];
    }
    pub fn identity(self: Bundle, e: bundle.TocEntry) []const u8 {
        return self.data[e.identity_offset .. e.identity_offset + e.identity_len];
    }
    pub fn gzip(self: Bundle, e: bundle.TocEntry) ?[]const u8 {
        if (e.flags & bundle.Flags.HAS_GZIP == 0) return null;
        return self.data[e.gzip_offset .. e.gzip_offset + e.gzip_len];
    }
    pub fn brotli(self: Bundle, e: bundle.TocEntry) ?[]const u8 {
        if (e.flags & bundle.Flags.HAS_BROTLI == 0) return null;
        return self.data[e.brotli_offset .. e.brotli_offset + e.brotli_len];
    }
};

/// Parse a freshly-mapped bundle file into a Bundle struct. The platform
/// backend is responsible for the mapping itself; this function only walks
/// the header and slices the regions. Allocates the Bundle wrapper.
pub fn parseBundle(allocator: mem.Allocator, mapped: []align(std.heap.page_size_min) const u8) !*Bundle {
    if (mapped.len < @sizeOf(bundle.Header)) return error.BundleTooSmall;
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

/// Atomically published current bundle. Backends store after load and after
/// reload; core reads on every request. The pointer swap is the whole story
/// of how baker reloads — a single instruction the kernel cannot interrupt.
pub var current_bundle: Atomic(?*const Bundle) = .init(null);

/// Pick the best supported encoding the client says it accepts. `value` is
/// the bare Accept-Encoding header value (no "Accept-Encoding:" prefix).
/// Honours `q=0` rejections — a substring search would happily serve `br`
/// to a client that explicitly refused it.
pub fn pickEncoding(value: []const u8) Encoding {
    if (encodingAccepted(value, "br")) return .brotli;
    if (encodingAccepted(value, "gzip")) return .gzip;
    return .identity;
}

fn encodingAccepted(value: []const u8, name: []const u8) bool {
    var rest = value;
    while (rest.len > 0) {
        const end = mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const token = mem.trim(u8, rest[0..end], " \t");
        rest = if (end == rest.len) "" else rest[end + 1 ..];

        const semi = mem.indexOfScalar(u8, token, ';');
        const tname = mem.trim(u8, if (semi) |s| token[0..s] else token, " \t");
        if (!mem.eql(u8, tname, name)) continue;

        // Bare token implies q=1.
        if (semi == null) return true;
        const params = token[semi.? + 1 ..];
        const q_idx = mem.indexOf(u8, params, "q=") orelse return true;
        const q_str = mem.trim(u8, params[q_idx + 2 ..], " \t");
        return !isQZero(q_str);
    }
    return false;
}

/// "0", "0.", "0.0", "0.00" — all q=0. Anything with a non-zero digit
/// anywhere is non-zero quality.
fn isQZero(q: []const u8) bool {
    if (q.len == 0 or q[0] != '0') return false;
    for (q) |c| if (c != '0' and c != '.') return false;
    return true;
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

pub const not_found_resp: []const u8 =
    "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 14\r\nConnection: keep-alive\r\n\r\n404 not found\n";
pub const bad_request_resp: []const u8 =
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

/// Build a 304 response into a stack buffer. Small, deterministic, one write.
/// The original Linux path used writev for a true zero-copy emit; the saving
/// is some dozen bytes copied per 304, paid into L1 cache. Not worth a
/// per-platform abstraction.
fn write304(stream: net.Stream, etag: []const u8) !void {
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    @memcpy(buf[i..][0..not_modified_prefix.len], not_modified_prefix);
    i += not_modified_prefix.len;
    buf[i] = '"';
    i += 1;
    @memcpy(buf[i..][0..etag.len], etag);
    i += etag.len;
    buf[i] = '"';
    i += 1;
    @memcpy(buf[i..][0..not_modified_suffix.len], not_modified_suffix);
    i += not_modified_suffix.len;
    try stream.writeAll(buf[0..i]);
}

/// Serve one HTTP request. Returns true if the connection should be kept
/// alive for another request, false to close.
pub fn serveOne(stream: net.Stream, req: []const u8) bool {
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
        const line_end_off = mem.indexOf(u8, headers[i..], "\r\n") orelse break :blk "";
        const line_only = headers[i .. i + line_end_off];
        const colon = mem.indexOfScalar(u8, line_only, ':') orelse break :blk "";
        break :blk mem.trim(u8, line_only[colon + 1 ..], " \t");
    } else "";

    const resp = lookup(b, path, accept_slice) orelse (b.not_found orelse not_found_resp);

    // Conditional GET: if the client's If-None-Match matches the response's
    // ETag, send 304. The match is exact-bytes — we never normalised either side.
    if (ifNoneMatchValue(headers)) |inm| {
        if (etagInResponse(resp)) |tag| {
            if (mem.eql(u8, inm, tag)) {
                write304(stream, tag) catch return false;
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

/// Drive one accepted connection: read into a 16 KB stack buffer, dispatch
/// each complete request, slide leftover bytes to the front, repeat.
pub fn handleConn(stream: net.Stream) void {
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

fn setReadTimeout(fd: posix.socket_t, secs: i64) void {
    // posix.timeval.sec is i32 on Windows (DWORD-shaped) and i64 on Linux/Darwin.
    // @intCast keeps the call portable; our actual values are tiny (single-digit seconds).
    const tv = posix.timeval{ .sec = @intCast(secs), .usec = 0 };
    _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, mem.asBytes(&tv)) catch {};
}

fn enableNoDelay(fd: posix.socket_t) void {
    const yes: c_int = 1;
    _ = posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, mem.asBytes(&yes)) catch {};
}

test "pickEncoding prefers br over gzip over identity" {
    try std.testing.expectEqual(Encoding.brotli, pickEncoding("gzip, br"));
    try std.testing.expectEqual(Encoding.gzip, pickEncoding("gzip, deflate"));
    try std.testing.expectEqual(Encoding.identity, pickEncoding(""));
    try std.testing.expectEqual(Encoding.identity, pickEncoding("deflate"));
}

test "pickEncoding honours q=0 rejection" {
    try std.testing.expectEqual(Encoding.gzip, pickEncoding("br;q=0, gzip"));
    try std.testing.expectEqual(Encoding.gzip, pickEncoding("br; q=0.0, gzip"));
    try std.testing.expectEqual(Encoding.identity, pickEncoding("br;q=0, gzip;q=0"));
    try std.testing.expectEqual(Encoding.brotli, pickEncoding("br;q=0.5, gzip;q=1"));
    try std.testing.expectEqual(Encoding.brotli, pickEncoding("br;q=0.001"));
}
