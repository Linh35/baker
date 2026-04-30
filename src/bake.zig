// bake.zig — implementation of the `baker bake` subcommand. Walks an input
// directory, minifies + compresses compressible files (brotli via libbrotli,
// gzip via zlib), and writes a single self-contained `baked.bin` the runtime
// mmaps at startup. Also exposes `doInit` for the `baker init` subcommand.
//
// Entry points are `pub fn run` and `pub fn doInit`. The unified CLI lives in
// `main.zig`; this file is invoked from there.

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const bundle = @import("bundle.zig");
const config_mod = @import("config.zig");
const minify = @import("minify.zig");
const exclude = @import("exclude.zig");
const esbuild = @import("esbuild.zig");

const brotli = @cImport({
    @cInclude("brotli/encode.h");
});

const zlib = @cImport({
    @cInclude("zlib.h");
});

const COMPRESSIBLE = [_][]const u8{
    ".html", ".htm", ".css", ".js", ".mjs", ".json",
    ".md",   ".svg", ".txt", ".xml",
};

fn isCompressible(path: []const u8) bool {
    for (COMPRESSIBLE) |ext| if (mem.endsWith(u8, path, ext)) return true;
    return false;
}

fn mimeFor(path: []const u8) []const u8 {
    if (mem.endsWith(u8, path, ".html") or mem.endsWith(u8, path, ".htm")) return "text/html; charset=utf-8";
    if (mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (mem.endsWith(u8, path, ".js") or mem.endsWith(u8, path, ".mjs")) return "text/javascript; charset=utf-8";
    if (mem.endsWith(u8, path, ".md")) return "text/markdown; charset=utf-8";
    if (mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (mem.endsWith(u8, path, ".png")) return "image/png";
    if (mem.endsWith(u8, path, ".jpg") or mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

// gzip via zlib C interop. Uses deflateInit2 with windowBits = 15 + 16 (the +16
// selects the gzip wrapper, per zlib docs) at level 9. The Zig stdlib's
// `std.compress.flate.Compress` is incomplete in 0.15.2, so we go straight to
// the system zlib — same pattern as libbrotli for brotli.
fn compressGzip(allocator: mem.Allocator, input: []const u8) ![]u8 {
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    if (zlib.deflateInit2_(
        &stream,
        zlib.Z_BEST_COMPRESSION,
        zlib.Z_DEFLATED,
        15 + 16, // windowBits + gzip wrapper
        8, // memLevel (default)
        zlib.Z_DEFAULT_STRATEGY,
        zlib.zlibVersion(),
        @sizeOf(zlib.z_stream),
    ) != zlib.Z_OK) return error.GzipInitFailed;
    defer _ = zlib.deflateEnd(&stream);

    const bound: usize = zlib.deflateBound(&stream, input.len);
    const buf = try allocator.alloc(u8, bound);
    errdefer allocator.free(buf);

    stream.next_in = @constCast(@ptrCast(input.ptr));
    stream.avail_in = @intCast(input.len);
    stream.next_out = buf.ptr;
    stream.avail_out = @intCast(buf.len);

    const rc = zlib.deflate(&stream, zlib.Z_FINISH);
    if (rc != zlib.Z_STREAM_END) return error.GzipDeflateFailed;
    const written = buf.len - @as(usize, @intCast(stream.avail_out));
    return try allocator.realloc(buf, written);
}

fn compressBrotli(allocator: mem.Allocator, input: []const u8) ![]u8 {
    var out_size: usize = brotli.BrotliEncoderMaxCompressedSize(input.len);
    const buf = try allocator.alloc(u8, out_size);
    errdefer allocator.free(buf);
    // BROTLI_MODE_TEXT is the right choice for everything in COMPRESSIBLE —
    // it enables the static text dictionary and squeezes out a few % more
    // than GENERIC on HTML/CSS/JS. ~no cost.
    const ok = brotli.BrotliEncoderCompress(
        11,
        brotli.BROTLI_DEFAULT_WINDOW,
        brotli.BROTLI_MODE_TEXT,
        input.len,
        input.ptr,
        &out_size,
        buf.ptr,
    );
    if (ok == 0) return error.BrotliEncodeFailed;
    return try allocator.realloc(buf, out_size);
}

/// FNV-1a 64-bit, 16 hex chars. Strong enough as an ETag for static-site
/// content where collisions practically never happen at this scale.
/// A cryptographer would wince; a static site of a hundred pages will not.
fn etagOf(content: []const u8) [16]u8 {
    var h: u64 = 0xcbf29ce484222325;
    for (content) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    var out: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        out[15 - i] = hex[(h >> @intCast(i * 4)) & 0xf];
    }
    return out;
}

fn buildResponse(
    allocator: mem.Allocator,
    status_line: []const u8,
    mime: []const u8,
    body: []const u8,
    encoding: ?[]const u8,
    extra_headers: []const config_mod.Header,
    etag: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("HTTP/1.1 {s}\r\n", .{status_line});
    try w.print("Content-Type: {s}\r\n", .{mime});
    try w.print("Content-Length: {d}\r\n", .{body.len});
    if (encoding) |enc| try w.print("Content-Encoding: {s}\r\n", .{enc});
    if (etag) |e| try w.print("ETag: \"{s}\"\r\n", .{e});
    try w.writeAll("Vary: Accept-Encoding\r\n");
    try w.writeAll("Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n");
    for (extra_headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    try w.writeAll("\r\n");
    try w.writeAll(body);
    return buf.toOwnedSlice(allocator);
}

const Entry = struct {
    url_path: []const u8,
    identity: []const u8,
    gzip: ?[]const u8,
    brotli: ?[]const u8,
};

pub fn doInit(dir: []const u8) !void {
    try fs.cwd().makePath(dir);
    var d = try fs.cwd().openDir(dir, .{});
    defer d.close();
    try d.makePath("site");

    try d.writeFile(.{ .sub_path = "baker.config.zon", .data = STARTER_CONFIG });
    try d.writeFile(.{ .sub_path = "site/index.html", .data = STARTER_INDEX });
    try d.writeFile(.{ .sub_path = "site/404.html", .data = STARTER_404 });
    try d.writeFile(.{ .sub_path = ".gitignore", .data = "baked.bin\n" });

    std.debug.print(
        \\baker: scaffolded a starter project in {s}
        \\
        \\Next steps:
        \\  cd {s}
        \\  baker run     # bake site/ and start the server on http://localhost:8000
        \\
    , .{ dir, dir });
}

const STARTER_CONFIG =
    \\.{
    \\    .site = "site",
    \\    .out = "baked.bin",
    \\    .port = 8000,
    \\    .bind = "0.0.0.0",
    \\    .bundle_path = "baked.bin",
    \\    .not_found_path = "/404.html",
    \\    .compress = .{
    \\        .gzip = true,
    \\        .brotli = true,
    \\        .obfuscate = true,
    \\        .min_size = 0,
    \\        .minifier = .auto,
    \\    },
    \\    .headers = .{
    \\        .{ .name = "Cache-Control", .value = "public, max-age=3600" },
    \\        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    \\    },
    \\}
    \\
;

const STARTER_INDEX =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <title>my site</title>
    \\</head>
    \\<body>
    \\  <h1>baker</h1>
    \\  <p>Edit <code>site/index.html</code>, then run <code>baker run</code>.</p>
    \\</body>
    \\</html>
    \\
;

const STARTER_404 =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <title>404 — not found</title>
    \\</head>
    \\<body>
    \\  <h1>404</h1>
    \\  <p>Nothing here. <a href="/">Home.</a></p>
    \\</body>
    \\</html>
    \\
;

/// First existing common public directory, or null if none. Used so
/// `baker bake` works in a directory with `src/`, `site/`, `public/`, or
/// `dist/` without any config file at all.
fn autodetectSiteDir() ?[]const u8 {
    for ([_][]const u8{ "src", "site", "public", "dist" }) |candidate| {
        var d = fs.cwd().openDir(candidate, .{}) catch continue;
        d.close();
        return candidate;
    }
    return null;
}

/// Run the `baker bake` subcommand. `args` is positioned past `argv[0]` and
/// the subcommand name — we just consume the remaining flags. The caller owns
/// the allocator (typically an arena rooted in main.zig).
pub fn run(allocator: mem.Allocator, args: *std.process.ArgIterator) !void {
    var cfg: config_mod.Config = .{};
    var loaded_config_path: ?[]const u8 = null;
    var in_dir: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    // 1. Auto-discover a config file in the working directory before parsing args.
    //    Looked up in order; first hit wins. CLI flags override discovered values.
    for ([_][]const u8{ "baker.config.zon", "baker.zon" }) |p| {
        cfg = config_mod.loadFromFile(allocator, p) catch continue;
        loaded_config_path = p;
        break;
    }

    // 2. Parse remaining CLI args. Flags override config-file values.
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--config")) {
            const cfg_path = args.next() orelse return error.MissingConfigPath;
            cfg = try config_mod.loadFromFile(allocator, cfg_path);
            loaded_config_path = cfg_path;
        } else if (mem.eql(u8, arg, "--in")) {
            in_dir = args.next() orelse return error.MissingIn;
        } else if (mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.MissingOut;
        } else if (mem.eql(u8, arg, "--minify")) {
            cfg.compress.obfuscate = true;
        } else if (mem.eql(u8, arg, "--no-minify")) {
            cfg.compress.obfuscate = false;
        } else if (mem.eql(u8, arg, "--gzip")) {
            cfg.compress.gzip = true;
        } else if (mem.eql(u8, arg, "--no-gzip")) {
            cfg.compress.gzip = false;
        } else if (mem.eql(u8, arg, "--brotli")) {
            cfg.compress.brotli = true;
        } else if (mem.eql(u8, arg, "--no-brotli")) {
            cfg.compress.brotli = false;
        } else if (mem.eql(u8, arg, "--no-compress") or mem.eql(u8, arg, "--no-zip")) {
            cfg.compress.gzip = false;
            cfg.compress.brotli = false;
        } else if (mem.eql(u8, arg, "--min-size")) {
            const v = args.next() orelse return error.MissingMinSize;
            cfg.compress.min_size = std.fmt.parseInt(u32, v, 10) catch {
                std.debug.print("baker bake: --min-size expects a non-negative integer, got '{s}'\n", .{v});
                return error.InvalidMinSize;
            };
        } else if (mem.eql(u8, arg, "--minifier")) {
            const v = args.next() orelse return error.MissingMinifier;
            if (mem.eql(u8, v, "auto")) {
                cfg.compress.minifier = .auto;
            } else if (mem.eql(u8, v, "builtin")) {
                cfg.compress.minifier = .builtin;
            } else if (mem.eql(u8, v, "esbuild")) {
                cfg.compress.minifier = .esbuild;
            } else {
                std.debug.print("baker bake: --minifier expects auto|builtin|esbuild, got '{s}'\n", .{v});
                return error.InvalidMinifier;
            }
        } else {
            std.debug.print("baker bake: unknown flag '{s}'\n", .{arg});
            return error.UnknownFlag;
        }
    }
    if (loaded_config_path) |p| std.debug.print("baker: using config {s}\n", .{p});
    // CLI flags > config-file fields > auto-detected default.
    // No config and no flag? Look for a common public directory.
    const in = in_dir orelse cfg.site orelse autodetectSiteDir() orelse {
        std.debug.print(
            "baker: no input directory found. Pass --in DIR, set .site in baker.config.zon,\n" ++
                "       or create one of: src/ site/ public/ dist/\n",
            .{},
        );
        return error.MissingInputDir;
    };
    const out = out_path orelse cfg.out orelse "baked.bin";
    if (loaded_config_path == null and in_dir == null) {
        std.debug.print("baker: no config — baking {s}/ → {s} with default settings\n", .{ in, out });
    }
    const min_compress = cfg.compress.min_size;
    const enable_gzip = cfg.compress.gzip;
    const enable_brotli = cfg.compress.brotli;
    const enable_obfuscate = cfg.compress.obfuscate;
    const extra_headers = cfg.headers;
    const excludes = cfg.exclude;

    // Resolve the minifier choice. .auto = use esbuild if it's on PATH.
    const use_esbuild: bool = enable_obfuscate and switch (cfg.compress.minifier) {
        .auto => esbuild.available(allocator),
        .builtin => false,
        .esbuild => blk: {
            if (!esbuild.available(allocator)) {
                std.debug.print("baker: esbuild required but not on PATH\n", .{});
                return error.EsbuildNotFound;
            }
            break :blk true;
        },
    };
    if (enable_obfuscate) {
        std.debug.print("baker: minifier = {s} (js/mjs/css/json)\n", .{
            if (use_esbuild) "esbuild" else "builtin",
        });
    }

    var bytes_in_total: usize = 0;
    var bytes_out_id: usize = 0;
    var bytes_out_gz: usize = 0;
    var bytes_out_br: usize = 0;
    var skipped: usize = 0;

    var entries: std.ArrayList(Entry) = .{};
    defer entries.deinit(allocator);

    var src = try fs.cwd().openDir(in, .{ .iterate = true });
    defer src.close();

    var walker = try src.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |w| {
        if (w.kind != .file) continue;
        if (exclude.any(excludes, w.path)) {
            skipped += 1;
            continue;
        }
        const data = try src.readFileAlloc(allocator, w.path, 64 * 1024 * 1024);
        defer allocator.free(data);

        const mime = mimeFor(w.path);
        bytes_in_total += data.len;

        // Optionally minify the source before compression. Identity body
        // serves the minified version too — clients without compression still
        // get the smaller bytes. If esbuild is enabled and has a loader for
        // the file's type, use it; on any failure fall back to the builtin.
        // The fall-through is deliberate: a bake should not fail because some
        // external binary, on this particular morning, has decided otherwise.
        const body_for_id: []const u8 = if (enable_obfuscate) blk: {
            if (use_esbuild) {
                if (esbuild.loaderFor(w.path)) |loader| {
                    if (esbuild.minify(allocator, loader, data)) |minified| {
                        break :blk minified;
                    } else |err| {
                        std.debug.print("baker: esbuild failed on {s} ({s}); using builtin\n", .{ w.path, @errorName(err) });
                    }
                }
            }
            const min_opt = try minify.forPath(allocator, w.path, data);
            break :blk min_opt orelse data;
        } else data;

        const tag = etagOf(body_for_id);
        const id_resp = try buildResponse(allocator, "200 OK", mime, body_for_id, null, extra_headers, &tag);
        bytes_out_id += body_for_id.len;
        var gz_resp: ?[]u8 = null;
        var br_resp: ?[]u8 = null;
        if (isCompressible(w.path) and body_for_id.len >= min_compress) {
            // gzip and brotli are each opt-out via cfg.compress. Drop the variant if
            // it ends up no smaller than identity — better to skip the encoding than
            // to ship a bigger payload to clients that requested it.
            if (enable_gzip) {
                const gz_body = try compressGzip(allocator, body_for_id);
                defer allocator.free(gz_body);
                if (gz_body.len < body_for_id.len) {
                    gz_resp = try buildResponse(allocator, "200 OK", mime, gz_body, "gzip", extra_headers, &tag);
                    bytes_out_gz += gz_body.len;
                } else {
                    bytes_out_gz += body_for_id.len; // would have served identity
                }
            } else {
                bytes_out_gz += body_for_id.len;
            }

            if (enable_brotli) {
                const br_body = try compressBrotli(allocator, body_for_id);
                defer allocator.free(br_body);
                if (br_body.len < body_for_id.len) {
                    br_resp = try buildResponse(allocator, "200 OK", mime, br_body, "br", extra_headers, &tag);
                    bytes_out_br += br_body.len;
                } else {
                    bytes_out_br += body_for_id.len;
                }
            }
        } else {
            bytes_out_gz += body_for_id.len;
            bytes_out_br += body_for_id.len;
        }

        const url = try std.fmt.allocPrint(allocator, "/{s}", .{w.path});
        try entries.append(allocator, .{
            .url_path = url,
            .identity = id_resp,
            .gzip = gz_resp,
            .brotli = br_resp,
        });

        // Implicit-index aliases. Match `index.html` at the root or any
        // directory boundary — never as a partial-name suffix (so `myindex.html`
        // does not mint a `/my` alias).
        const is_index = mem.eql(u8, w.path, "index.html") or
            mem.endsWith(u8, w.path, "/index.html");
        if (is_index) {
            const alias_url = if (w.path.len == "index.html".len)
                try allocator.dupe(u8, "/")
            else blk: {
                const dir_only = w.path[0 .. w.path.len - "index.html".len];
                break :blk try std.fmt.allocPrint(allocator, "/{s}", .{dir_only});
            };
            // Aliases share the same response bytes — duplicated entry, no extra storage
            // (we still write the bytes once below; the ToC will reference the same data offsets).
            try entries.append(allocator, .{
                .url_path = alias_url,
                .identity = id_resp,
                .gzip = gz_resp,
                .brotli = br_resp,
            });
        }
    }

    // Custom 404: read the file at cfg.not_found_path, build a 404-status response.
    var not_found_resp: ?[]u8 = null;
    if (cfg.not_found_path) |nfp| {
        const rel = if (mem.startsWith(u8, nfp, "/")) nfp[1..] else nfp;
        const data = src.readFileAlloc(allocator, rel, 64 * 1024 * 1024) catch |err| blk: {
            std.debug.print("baker: warning — not_found_path {s} not found ({s}); using default\n", .{ nfp, @errorName(err) });
            break :blk null;
        };
        if (data) |d| {
            not_found_resp = try buildResponse(allocator, "404 Not Found", mimeFor(rel), d, null, extra_headers, null);
        }
    }

    try writeBundle(allocator, out, entries.items, not_found_resp);
    if (skipped > 0) {
        std.debug.print("baker: wrote {s} ({d} routes, {d} excluded{s})\n", .{ out, entries.items.len, skipped, if (not_found_resp != null) ", custom 404" else "" });
    } else {
        std.debug.print("baker: wrote {s} ({d} routes{s})\n", .{ out, entries.items.len, if (not_found_resp != null) ", custom 404" else "" });
    }
    if (bytes_in_total > 0) {
        std.debug.print(
            "baker: source {d}B  →  identity {d}B ({d}%)  gzip {d}B ({d}%)  brotli {d}B ({d}%)\n",
            .{
                bytes_in_total,
                bytes_out_id,           100 * bytes_out_id / bytes_in_total,
                bytes_out_gz,           if (bytes_in_total > 0) 100 * bytes_out_gz / bytes_in_total else 0,
                bytes_out_br,           if (bytes_in_total > 0) 100 * bytes_out_br / bytes_in_total else 0,
            },
        );
    }
}

fn writeBundle(allocator: mem.Allocator, out_path: []const u8, entries: []const Entry, not_found_resp: ?[]const u8) !void {
    // Compute layout: header, string pool, ToC, data section.
    const header_size = @sizeOf(bundle.Header);
    var string_pool: std.ArrayList(u8) = .{};
    defer string_pool.deinit(allocator);
    var path_offsets = try allocator.alloc(struct { off: u32, len: u32 }, entries.len);
    defer allocator.free(path_offsets);
    for (entries, 0..) |e, i| {
        path_offsets[i] = .{
            .off = @intCast(string_pool.items.len),
            .len = @intCast(e.url_path.len),
        };
        try string_pool.appendSlice(allocator, e.url_path);
    }

    // Data section: write each unique response once. For v0.1 we don't dedup
    // aliases — keep the implementation simple.
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(allocator);
    var toc_entries = try allocator.alloc(bundle.TocEntry, entries.len);
    defer allocator.free(toc_entries);

    for (entries, 0..) |e, i| {
        var entry: bundle.TocEntry = .{
            .path_offset = path_offsets[i].off,
            .path_len = path_offsets[i].len,
            .flags = 0,
            ._pad = 0,
            .identity_offset = data.items.len,
            .identity_len = e.identity.len,
            .gzip_offset = 0,
            .gzip_len = 0,
            .brotli_offset = 0,
            .brotli_len = 0,
        };
        try data.appendSlice(allocator, e.identity);
        if (e.gzip) |g| {
            entry.flags |= bundle.Flags.HAS_GZIP;
            entry.gzip_offset = data.items.len;
            entry.gzip_len = g.len;
            try data.appendSlice(allocator, g);
        }
        if (e.brotli) |b| {
            entry.flags |= bundle.Flags.HAS_BROTLI;
            entry.brotli_offset = data.items.len;
            entry.brotli_len = b.len;
            try data.appendSlice(allocator, b);
        }
        toc_entries[i] = entry;
    }

    // Append the optional 404 response into the data section so it lives alongside the routes.
    var not_found_offset: u64 = 0;
    var not_found_len: u64 = 0;
    if (not_found_resp) |nfr| {
        not_found_offset = data.items.len;
        not_found_len = nfr.len;
        try data.appendSlice(allocator, nfr);
    }

    const string_pool_offset: u64 = header_size;
    const string_pool_size: u64 = string_pool.items.len;
    // ToC requires 8-byte alignment (extern struct with u64 fields).
    const toc_offset: u64 = mem.alignForward(u64, string_pool_offset + string_pool_size, 8);
    const toc_pad: u64 = toc_offset - (string_pool_offset + string_pool_size);
    const toc_size: u64 = toc_entries.len * @sizeOf(bundle.TocEntry);
    const data_offset: u64 = toc_offset + toc_size;
    const data_size: u64 = data.items.len;
    // ToC offsets stay relative to the start of the data section; the runtime
    // indexes Bundle.data, which is already that slice.

    const header: bundle.Header = .{
        .magic = bundle.MAGIC,
        .version = bundle.VERSION,
        .count = @intCast(entries.len),
        .string_pool_offset = string_pool_offset,
        .string_pool_size = string_pool_size,
        .toc_offset = toc_offset,
        .toc_size = toc_size,
        .data_offset = data_offset,
        .data_size = data_size,
        .not_found_offset = not_found_offset,
        .not_found_len = not_found_len,
    };

    var f = try fs.cwd().createFile(out_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(mem.asBytes(&header));
    try f.writeAll(string_pool.items);
    if (toc_pad > 0) {
        const zeros: [8]u8 = @splat(0);
        try f.writeAll(zeros[0..toc_pad]);
    }
    try f.writeAll(mem.sliceAsBytes(toc_entries));
    try f.writeAll(data.items);
}

