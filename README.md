# baker

A static-site bundler and an HTTP server, both compiled into one small binary. You give it a directory of files. It hands you back a flat bundle and a process that serves that bundle without ever again touching the disk.

## Use it

Put the site in `src/` — or `site/`, `public/`, `dist/`; it will look for any of them — and run:

```bash
baker run        # bake, then serve on :8000
```

That is the whole of it. Brotli and gzip, source minified, ETags, conditional GETs, hot reload: all on, and on by default. The defaults assume you wanted the smallest payload and didn't want to be asked.

Bake and serve can be split, which is what you want for a CI build. The bake produces `baked.bin`; you ship it alongside the binary.

```bash
baker bake
baker serve
```

To swap in a fresh bundle without dropping a connection, signal the running process. On Linux and macOS:

```bash
baker bake && kill -HUP $(pgrep -f 'baker serve')
```

On Windows there is no `SIGHUP`. The server polls the bundle file's mtime once a second; rewriting the file is the reload.

Subcommands:

```
baker bake        produce baked.bin from your site directory
baker serve       run the HTTP server
baker run         bake then serve (one command for development)
baker init [DIR]  scaffold a starter project (default: .)
```

Bake-time flags. Each shadows a `compress` field in the config; the flag wins.

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

The bake walks the input directory, minifies what can be minified, compresses each compressible file twice (brotli at q=11, gzip at level 9), and writes one flat file: a header, then the path strings, a table of contents, and a data section of pre-built HTTP responses — status line, headers, body — exactly as they will go out on the wire.

The runtime maps that file once at startup. Each request is a parse of the request line in a stack buffer, a linear walk of the table of contents, a choice of encoding, and a single `write()` of the matching slice. The response bytes are slices into the mapped region; nothing is copied, nothing is allocated, nothing is read from disk after boot.

- **Routing** — literal paths. `/` is an alias for `/index.html`, and `/foo/` for `/foo/index.html`; both are produced at bake time, not resolved at request time. GET and HEAD only.
- **Encoding** — brotli is preferred over gzip, gzip over identity, governed by `Accept-Encoding`. A compressed variant is dropped at bake time if it is not strictly smaller than the identity body, since shipping a larger payload to a client that asked for compression is the wrong kind of helpful.
- **ETag** — FNV-1a 64 of the identity body, sixteen hex characters, shared across encodings. `If-None-Match` returns a 304 in a single write.
- **Hot reload** — a fresh bundle is mapped and the pointer is swapped atomically. In-flight requests finish on the old mapping. v0.1 leaks the old mapping; a future version will track in-flight requests and `munmap` after a grace period.

## Platforms

baker runs on three operating systems. The HTTP itself is identical everywhere; what differs is how each kernel is asked to do the work.

| | Linux | macOS | Windows |
|---|---|---|---|
| Bundle | `mmap` with `MAP_POPULATE`, sequential `madvise` | `mmap` with sequential `madvise` | page-aligned heap read |
| Listeners | `SO_REUSEPORT`, one per CPU | one listener, threads contend on `accept` | one listener, threads contend on `accept` |
| Thread pinning | `sched_setaffinity` | none (deprecated on Darwin) | none |
| Cold-connection wakeup | `TCP_DEFER_ACCEPT` | unavailable; one extra wakeup is paid | unavailable |
| Reload trigger | `SIGHUP` via `signalfd` | `SIGHUP` via `sigwait` on a dedicated thread | mtime polled once a second |
| `SIGPIPE` | ignored process-wide | ignored process-wide | not applicable |

The Linux path is the most aggressively tuned, because Linux gives you the most levers. The macOS and Windows backends do less and ask for less; they will not match Linux on a benchmark, but they will run.

## Install

Zig 0.15.2 is required, plus libbrotlienc and zlib for the bake. On Arch:

```bash
pacman -S brotli zlib
```

Then:

```bash
git clone <baker-repo> && cd baker
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/baker
```

Cross-compilation of the runtime alone — without the bake-time C dependencies — is supported as a sanity check on a Linux dev box:

```bash
zig build check-runtime -Dtarget=aarch64-macos
zig build check-runtime -Dtarget=x86_64-windows
```

## Configuration

Optional. The bake and the runtime both auto-discover `baker.config.zon` (or `baker.zon`) in the working directory. Every field has a default, and the defaults are tuned for the smallest payload.

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
        .obfuscate = true,    // run the minifier
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

`.minifier = .auto` uses esbuild for js/mjs/css/json when esbuild is on `PATH`, and falls through to baker's builtin pass otherwise. HTML and SVG always go through the builtin pass; esbuild has no loader for them. `.builtin` keeps the bake free of external dependencies; `.esbuild` is the strict form, and the bake will refuse to start if esbuild is missing.

`baker init [DIR]` writes the file above, plus `site/index.html` and `site/404.html`, into a fresh directory.

## Limits

- HTTP/1.1 only. No TLS, no HTTP/2, no range requests, no language negotiation. Put Caddy or nginx in front for any of that.
- The bundle must fit in the process's address space.
- The reload mechanism on Windows is mtime polling, which is honest but not instant; a write-then-rename will be picked up on the next tick.

## License

[Apache-2.0](./LICENSE) with [`NOTICE`](./NOTICE) — propagate the NOTICE file in any redistribution.

> Status: pre-alpha.
