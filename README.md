# baker

A single-binary static site bundler and HTTP server.

## Use it

Put your site in `src/` (or `site/`, `public/`, `dist/` — auto-detected) and run:

```bash
baker run        # bake then serve on :8000
```

That's it. Brotli + gzip, minified, ETags, 304s, hot reload — all on by default.

Bake and serve separately (e.g. bake in CI, ship `baker` + `baked.bin`):

```bash
baker bake
baker serve
```

Hot reload after a rebake, no dropped connections:

```bash
baker bake && kill -HUP $(pgrep -f 'baker serve')
```

Subcommands:

```
baker bake        produce baked.bin from your site directory
baker serve       run the HTTP server
baker run         bake then serve
baker init [DIR]  scaffold a starter project
```

Bake-time flags (each mirrors a `compress` field in config; flag wins):

```
baker bake [--in DIR] [--out PATH] [--config FILE]
           [--minify | --no-minify]
           [--gzip   | --no-gzip]
           [--brotli | --no-brotli]
           [--no-compress | --no-zip]          shorthand for both off
           [--minifier auto|builtin|esbuild]
           [--min-size N]                      skip compression for files < N bytes
```

## How it works

The bake tool walks the input directory, minifies, compresses each file with brotli and gzip, and writes a flat bundle: header + path strings + ToC + pre-built HTTP responses (status line, headers, body). The runtime `mmap`s it once, walks the ToC per request, and `write()`s the matching slice. All response bytes are slices into the mapped region — zero allocations on the hot path, zero filesystem I/O after boot.

- **Routing**: literal paths; `/` aliases `/index.html`, `/foo/` aliases `/foo/index.html` (resolved at bake time). GET/HEAD only.
- **Encoding**: serves br > gz > identity based on `Accept-Encoding`. A compressed variant is dropped if it's not strictly smaller than identity.
- **ETag**: FNV-1a 64 over the identity body, shared across encodings. `If-None-Match` → 304 in one `writev`.
- **Hot reload**: `SIGHUP` re-`mmap`s the bundle and atomically swaps. v0.1 leaks the old mapping; v0.2 will `munmap` after a grace period.
- **Networking**: one `SO_REUSEPORT` listener per CPU, threads pinned via `sched_setaffinity`, `TCP_DEFER_ACCEPT`, HTTP/1.1 keep-alive + pipelining.

## Install

Requires Zig 0.15.2, libbrotlienc, and zlib (`pacman -S brotli zlib` on Arch).

```bash
git clone <baker-repo> && cd baker
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/baker
```

## Configuration

Optional. Auto-discovers `baker.config.zon` (or `baker.zon`) in the current directory. Defaults are tuned for the smallest payload.

```zig
.{
    .site = "src",
    .out  = "baked.bin",
    .not_found_path = "/404.html",
    .exclude = .{ "*.md", ".git/*" },  // *suffix | prefix* | *contains* | exact

    .compress = .{
        .gzip      = true,    // zlib level 9
        .brotli    = true,    // libbrotli q=11, MODE_TEXT
        .min_size  = 0,       // skip compression below this size
        .obfuscate = true,    // run minifier
        .minifier  = .auto,   // .auto | .builtin | .esbuild
    },

    .headers = .{
        .{ .name = "Cache-Control", .value = "public, max-age=3600" },
    },

    .port = 8000,
    .bind = "0.0.0.0",
    .bundle_path = "baked.bin",
}
```

`baker init [DIR]` scaffolds this plus `site/index.html` and `site/404.html`.

## Limits

- Linux-only for now (macOS/BSD planned).
- HTTP/1.1 only, no TLS, no range requests. Put Caddy or nginx in front for HTTPS, HTTP/2, or HTTP/3.
- Bundle must fit in process address space.

## License

[Apache-2.0](./LICENSE) with [`NOTICE`](./NOTICE) — propagate the NOTICE file in any redistribution.

> Status: pre-alpha.
