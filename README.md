# baker

A single-binary static site bundler and HTTP server. Point it at a directory of HTML/CSS/JS, get back one bundle file the runtime memory-maps and serves with a single `write()` syscall per request — zero allocations on the hot path, zero filesystem I/O after boot.

> Status: pre-alpha. Linux first; macOS/BSD soon. License: Apache-2.0 with NOTICE — forks must propagate the NOTICE file (see [`NOTICE`](./NOTICE)).

## Why

For small static sites (portfolio, marketing page, docs under a few MB), the natural deploy target is S3 + CloudFront. baker is for the next case: you want **one binary you can `scp` to a $5 VPS** that beats nginx serving the same files from disk, with a content-update workflow that doesn't involve recompiling anything.

You don't write any Zig. You don't set up a build system. You install one binary and run it.

## Install

baker isn't published yet, so build from source:

```bash
git clone <baker-repo> ~/workspace/baker
cd ~/workspace/baker
zig build -Doptimize=ReleaseFast
# binary lives at ./zig-out/bin/baker
```

(Requires Zig 0.15.2, libbrotlienc, and zlib headers — `pacman -S brotli zlib` on Arch.)

Optional: drop a shell alias so you can type `baker` from anywhere without polluting your `$PATH`:

```bash
alias baker="$HOME/workspace/baker/zig-out/bin/baker"
```

## Quickstart — no config, no setup

The simplest possible workflow. Put your site in `src/` (or `site/`, `public/`, `dist/` — baker auto-detects), then:

```bash
cd my-website
baker run
# baker: no config — baking src/ → baked.bin with default settings
# baker: serving http://0.0.0.0:8000
```

That's it. Brotli + gzip pre-compressed, minified, ETags, 304s, hot reload — all on by defaults tuned to the smallest possible payload. Open `http://localhost:8000`.

To bake and serve as separate steps (e.g. bake in CI, ship `baker` + `baked.bin` to a server):

```bash
baker bake     # writes baked.bin
baker serve    # serves it
```

Edit content, rebake, hot-reload without dropping connections:

```bash
baker bake
kill -HUP $(pgrep -f 'baker serve')
```

## Subcommands

```
baker bake        produce baked.bin from your site directory
baker serve       run the HTTP server
baker run         bake then serve (one command for dev)
baker init [DIR]  scaffold a starter project (default: .)
baker help        show usage
```

Per-subcommand flags:

```
baker bake [--in DIR] [--out PATH] [--config FILE]
           [--minify | --no-minify]            toggle source minification
           [--gzip   | --no-gzip]              toggle the gzip variant
           [--brotli | --no-brotli]            toggle the brotli variant
           [--no-compress | --no-zip]          shorthand for --no-gzip --no-brotli
           [--minifier auto|builtin|esbuild]   override minifier choice
           [--min-size N]                      skip compression for files < N bytes
baker serve       [--config FILE]
baker run         [--config FILE]
```

Every flag corresponds to a field under `compress` in the config file; the flag wins when both are present. Useful for one-off bakes (`baker bake --no-minify` to inspect what's being shipped) without editing config.

If you don't pass `--in` and there's no config, baker looks for the first existing of `src/`, `site/`, `public/`, `dist/` in the current directory.

## Configuration (optional)

baker auto-discovers `baker.config.zon` (or `baker.zon`) in the current directory. Everything is optional — the defaults are the most aggressive size-reducing settings baker can offer.

```zig
.{
    // Bake-time
    .site = "src",                  // input directory
    .out  = "baked.bin",            // bundle output
    .not_found_path = "/404.html",  // optional — bakes a 404 from this file
    .exclude = .{ "*.md", ".git/*" },  // glob patterns: *suffix | prefix* | *contains* | exact

    .compress = .{
        .gzip      = true,          // emit Content-Encoding: gzip variants (zlib, level 9)
        .brotli    = true,          // emit Content-Encoding: br variants (q=11, mode=text)
        .min_size  = 0,             // 0 = always try; baker drops the variant if it's not smaller than identity
        .obfuscate = true,          // run minifier
        .minifier  = .auto,         // .auto picks esbuild if it's on PATH, else builtin
    },

    .headers = .{
        .{ .name = "Cache-Control", .value = "public, max-age=3600" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    },

    // Runtime
    .port = 8000,
    .bind = "0.0.0.0",
    .bundle_path = "baked.bin",
}
```

`baker init [DIR]` scaffolds this file plus `site/index.html` and `site/404.html`.

### Defaults at a glance

The zero-config defaults are tuned for smallest payload:

- brotli quality 11 + gzip level 9
- brotli `MODE_TEXT` for HTML/CSS/JS/JSON/SVG/MD/XML/TXT (uses brotli's static text dictionary)
- esbuild auto-detected for `.js`, `.mjs`, `.css`, `.json` (~18% better than the builtin minifier on JS-heavy sites); falls back to a built-in HTML/CSS/JS minifier if esbuild isn't on `PATH`
- builtin HTML/SVG minifier (esbuild has no loader for them)
- ETag (FNV-1a 64) on every 200; conditional GET → 304 with no body
- skip-if-bigger: a compressed variant is dropped if it's not strictly smaller than identity, so a client never receives a payload larger than the identity it would have gotten

## Routing

- **Literal**: `/about.html` resolves to that file.
- **Implicit index**: `/` is aliased to `/index.html`; `/foo/` to `/foo/index.html`. Aliases are produced at bake time.
- **404**: if `not_found_path` is configured (typically `/404.html`), baker serves that body for unknown paths. Otherwise a plaintext default.
- **Method**: GET and HEAD only.
- **Trailing slashes**: `/foo` and `/foo/` are distinct, no redirect.

## Compression and minification

Compressible MIME types (`text/*`, JavaScript, JSON, SVG, markdown) go through three steps at bake time:

1. **Minify** — esbuild for js/mjs/css/json when on `PATH`, otherwise the builtin pass (HTML/CSS comment + whitespace strip; conservative JS line-strip). Toggle via `compress.obfuscate`; pick a specific minifier via `compress.minifier`.
2. **brotli** at quality 11 (best, via libbrotli, `MODE_TEXT`).
3. **gzip** at level 9 (best, via zlib).

The runtime stores all three variants — identity (the minified original), brotli, gzip — and serves whichever the client's `Accept-Encoding` prefers (br > gz > identity). `Vary: Accept-Encoding` is set on every response. Binary formats (PNG, JPEG, WOFF2) skip compression — they're already compressed.

Real numbers from a small portfolio site (66 KB of HTML/CSS/JS):

```
source 66758 B  →  identity 48830 B (74%)  gzip 17942 B (27%)  brotli 14702 B (22%)
```

## Conditional GETs (ETag / 304)

Every compressed response is baked with `Vary: Accept-Encoding` and `ETag: "<hash>"`. The hash is FNV-1a 64-bit of the response body (16 hex chars). All three encoding variants of the same route share the same ETag — it's a property of the resource, not the encoding.

When a client sends `If-None-Match: "<hash>"` with the cached ETag, the runtime replies with `304 Not Modified` and no body — three slices `writev`'d in one syscall, zero copies. Returning visitors with a warm browser cache see sub-100-byte responses per page reload.

## Hot reload

Replace `baked.bin` and send `SIGHUP`:

```bash
baker bake && kill -HUP $(pgrep -f 'baker serve')
```

A dedicated reload thread (consuming the signal via `signalfd`; workers have `SIGHUP` masked) re-`mmap`s the new file and atomically swaps the active bundle pointer. In-flight requests finish on the old mapping; new requests see the new content immediately.

> v0.1 leaks the old bundle's mapping after swap. v0.2 will track in-flight requests and `munmap` after a grace period.

## Performance

ReleaseFast on a 16-core Linux machine, served from `mmap`-loaded bundle:

| Test | Throughput |
|---|---|
| 1 connection, sequential keep-alive | ~58K req/s |
| 16 connections, sequential keep-alive | ~89K req/s |
| 16 connections, pipelined | 250K+ req/s (client-bound) |

Beyond the bundle layout itself, the runtime has:

- one listener per CPU via `SO_REUSEPORT` (no shared accept queue)
- `TCP_DEFER_ACCEPT` to skip the wakeup-with-no-data context switch
- `TCP_NODELAY` per accepted connection
- worker threads pinned to CPUs via `sched_setaffinity` for cache locality
- `madvise(MADV_WILLNEED|MADV_SEQUENTIAL)` to pre-fault the bundle pages
- HTTP/1.1 keep-alive with pipelining
- 5-second idle read timeout via `SO_RCVTIMEO`
- single `write()` per response (header and body are contiguous bytes in `.rodata`-equivalent memory)

## Design tradeoff

The interesting decision was how to get the file bytes from the build system into the runtime's address space. There are three serious approaches; we picked the third.

### 1. Compile-time embedding (`@embedFile`)

The natural Zig approach. Each file becomes an `@embedFile` constant, the compiler emits the bytes into `.rodata`, the linker stitches everything into one binary.

**Cost**: build time scales with site size. Every byte of every file traverses the Zig compiler — IR, codegen, link. At 50 KB this is invisible; at 5 MB it adds noticeable seconds; at 50 MB the compile becomes painful and memory-hungry. And hot reload is impossible by construction.

### 2. Pre-built object file linking

Have the build tool emit native object files with bytes placed in custom `.rodata` sections, link them into the consumer's executable.

**Cost**: ELF/Mach-O/COFF are platform-specific — hundreds of pages of spec each. You either implement them (thousands of lines + ongoing maintenance) or shell out to `objcopy` (Linux-only, fragile under cross-compilation). Hot reload still impossible.

### 3. Memory-mapped bundle (what baker does)

The bake tool writes a flat data file in a custom format. The runtime opens it at startup, calls `mmap()`, walks a self-describing header to locate the table-of-contents, and serves slices directly from the mapped region.

This sidesteps both prior problems. Build time is linear in site size (just file I/O — no compiler involvement for the bytes), so a 100 MB site bakes in under a second. Cross-platform is free: `mmap` is POSIX, Windows has the same shape via `CreateFileMapping`. Hot reload becomes natural — replace the bundle file, signal the process, atomically swap mappings.

The runtime cost compared to approaches 1 and 2 is essentially zero. The kernel handles `.rodata` (an mmap-of-binary segment from `exec()`) and an explicit user-space `mmap()` of a data file the same way: file-backed read-only mappings, demand-paged from the page cache. After the bytes are paged in, every approach hands the kernel the same pointer to the same bytes for the same `write()`.

The only meaningful cost is deploy shape. Approach 3 produces two files (the executable and the bundle) instead of one. For a `scp` workflow this is mild — and it's worth it for the build-scaling and hot-reload properties.

## Bundle format

```
baked.bin
┌──────────┬─────────────────┬───────────────┬─────────────────────────────┐
│  Header  │   String pool   │   ToC entries │  Data: full HTTP responses  │
│  80 B    │   path strings  │   64 B × N    │  header+body, pre-built     │
└──────────┴─────────────────┴───────────────┴─────────────────────────────┘
```

Each ToC entry holds offsets into the string pool (path) and the data section (one offset/length triple per encoding: identity, gzip, brotli). At request time, the runtime parses the request line, walks the ToC for a matching path, picks the best variant the client accepts, and writes that slice. One syscall.

## Limits

- **Bundle in memory**: must fit in the process's address space. On 64-bit Linux this is generous, but bundles above a few hundred MB start to test the page cache and OS limits.
- **No TLS**: put Caddy or nginx in front for HTTPS, or compile in BoringSSL.
- **No range requests**: planned for a later release.
- **No content negotiation beyond `Accept-Encoding`**: language and quality negotiation are out of scope.
- **HTTP/1.1 only**: HTTP/2 and HTTP/3 are out of scope. Put a proxy in front if you need them.

## License

[Apache-2.0](./LICENSE). The accompanying [`NOTICE`](./NOTICE) must be propagated by any redistribution or derivative work — that's the attribution clause. In practice: keep the `NOTICE` file alongside the code, or reproduce its contents in your own `NOTICE`/`THIRD_PARTY` text.
