// config.zig — ZON config schema. One file drives both the build-time bake
// and the runtime server. Bake-time fields (`site`, `out`, `compress`,
// `headers`) are read by `baker-bake`; runtime fields (`port`, `bind`,
// `bundle_path`) are read by the runtime. Unknown fields are ignored so a
// single config can carry future additions without breaking older binaries.
//
// Auto-discovered as `baker.config.zon` or `baker.zon` in the working dir.
// `--config PATH` (bake) and `runFromConfig(path)` (runtime) accept explicit paths.

const std = @import("std");

/// Choice of source minifier. The bake auto-detects esbuild on PATH and uses
/// it for js/mjs/css/json when available; HTML/SVG always go through baker's
/// builtin minifier (esbuild has no loader for them). Override via config:
///   .auto    — use esbuild if it's on PATH, else builtin (default)
///   .builtin — always use the builtin pass (zero external deps)
///   .esbuild — require esbuild; the bake errors out if it's not on PATH
pub const Minifier = enum { auto, builtin, esbuild };

// Each of these toggles exists because someone, at some point, wanted it
// not to. The defaults are the most generous interpretation of "ship the
// smallest payload"; the booleans are escape valves for the days that
// generosity is the wrong instinct.
pub const Compress = struct {
    gzip: bool = true,
    brotli: bool = true,
    /// Skip compression for files smaller than this. Default 0 = always try;
    /// the bake then only emits a compressed variant if it's actually smaller
    /// than identity. Raise this to skip the compression cost on tiny files.
    min_size: u32 = 0,
    /// Master switch: false ships unminified source bytes regardless of `minifier`.
    obfuscate: bool = true,
    minifier: Minifier = .auto,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    site: ?[]const u8 = null,
    out: ?[]const u8 = null,
    port: u16 = 8000,
    bind: []const u8 = "0.0.0.0",
    bundle_path: []const u8 = "baked.bin",
    not_found_path: ?[]const u8 = null,
    /// Glob patterns matched against each file's path relative to `site`.
    /// Supported forms: `*suffix`, `prefix*`, `*contains*`, exact. A directory
    /// is excluded by listing `dir/*`. Files matching any pattern are skipped
    /// at bake time.
    exclude: []const []const u8 = &.{},
    compress: Compress = .{},
    headers: []const Header = &.{},
};

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAllocOptions(allocator, 1 << 20, null, .of(u8), 0);
    defer allocator.free(data);
    return try std.zon.parse.fromSlice(
        Config,
        allocator,
        data,
        null,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn freeConfig(allocator: std.mem.Allocator, value: Config) void {
    std.zon.parse.free(allocator, value);
}

// Tests use an arena: std.zon.parse.free walks every slice field on the
// struct and calls gpa.free even on the comptime `&.{}` defaults that the
// parser never allocated. The testing allocator rejects those frees. An
// arena's free is a no-op, so the call sequence is safe and leak-free.

test "default config parses minimal zon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 = ".{}";
    const cfg = try std.zon.parse.fromSlice(Config, arena.allocator(), src, null, .{});
    try std.testing.expectEqual(@as(u16, 8000), cfg.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.bind);
    try std.testing.expectEqual(true, cfg.compress.brotli);
    try std.testing.expectEqual(@as(usize, 0), cfg.exclude.len);
}

test "config parses headers and overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .site = "public",
        \\    .port = 9000,
        \\    .headers = .{
        \\        .{ .name = "Cache-Control", .value = "public, max-age=3600" },
        \\        .{ .name = "X-Frame-Options", .value = "DENY" },
        \\    },
        \\}
    ;
    const cfg = try std.zon.parse.fromSlice(Config, arena.allocator(), src, null, .{});
    try std.testing.expectEqualStrings("public", cfg.site.?);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
    try std.testing.expectEqual(@as(usize, 2), cfg.headers.len);
    try std.testing.expectEqualStrings("Cache-Control", cfg.headers[0].name);
}

test "config parses exclude patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: [:0]const u8 =
        \\.{
        \\    .exclude = .{ "*.md", ".claude/*", "serve" },
        \\}
    ;
    const cfg = try std.zon.parse.fromSlice(Config, arena.allocator(), src, null, .{});
    try std.testing.expectEqual(@as(usize, 3), cfg.exclude.len);
    try std.testing.expectEqualStrings("*.md", cfg.exclude[0]);
    try std.testing.expectEqualStrings(".claude/*", cfg.exclude[1]);
}
