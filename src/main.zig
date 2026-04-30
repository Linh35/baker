// main.zig — unified `baker` CLI. Dispatches subcommands to the bake / serve
// implementations. The whole program shares one arena allocator: bake completes
// and the process exits, so per-allocation cleanup is busywork; serve never
// returns from the worker loop, so the same is true there.
//
// Two programs, one binary, one allocator — the symmetry is mostly an accident
// of how short-lived each path is, but it has spared the code a great deal.
//
// Subcommands:
//   baker bake        produce baked.bin from site/ (config-driven)
//   baker serve       serve baked.bin
//   baker run         bake then serve (the npm-style dev workflow)
//   baker init [DIR]  scaffold a starter project (default: .)
//   baker help        print usage
//
// Auto-discovers baker.config.zon (or baker.zon) in the working directory.

const std = @import("std");
const bake_mod = @import("bake.zig");
const server = @import("server.zig");

const HELP =
    \\baker — single-binary static site bundler + server
    \\
    \\Usage:
    \\  baker bake        produce baked.bin from your site directory
    \\  baker serve       run the HTTP server
    \\  baker run         bake then serve (one command for dev)
    \\  baker init [DIR]  scaffold a starter project (default: .)
    \\  baker help        show this help
    \\
    \\Flags (per subcommand):
    \\  baker bake [--in DIR] [--out PATH] [--config FILE]
    \\             [--minify | --no-minify]          toggle source minification
    \\             [--gzip   | --no-gzip]            toggle gzip variant
    \\             [--brotli | --no-brotli]          toggle brotli variant
    \\             [--no-compress | --no-zip]        disable both gzip and brotli
    \\             [--minifier auto|builtin|esbuild] override minifier choice
    \\             [--min-size N]                    skip compression for files < N bytes
    \\  baker serve       [--config FILE]
    \\  baker run         [--config FILE]
    \\
    \\Auto-discovers baker.config.zon (or baker.zon) in the working directory.
    \\CLI flags override config-file values.
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect argv into a slice once, so subcommands can scan it more than
    // once. (`baker run` needs both bake-time *and* runtime to honour the
    // same --config flag — the previous iterator-based version dropped the
    // second pass on the floor.)
    var raw = try std.process.argsWithAllocator(allocator);
    defer raw.deinit();
    var argv: std.ArrayList([]const u8) = .{};
    while (raw.next()) |a| try argv.append(allocator, a);
    if (argv.items.len < 2) {
        try printHelp();
        std.process.exit(2);
    }
    const sub = argv.items[1];
    const rest = argv.items[2..];

    if (eq(sub, "bake")) {
        try bake_mod.run(allocator, rest);
    } else if (eq(sub, "serve")) {
        const cfg_path = try parseConfigFlag(rest);
        try server.runFromConfig(cfg_path);
    } else if (eq(sub, "run")) {
        // bake first; if it fails, don't start the server. Both halves see
        // the same args slice, so a single --config governs both.
        try bake_mod.run(allocator, rest);
        const cfg_path = configFromArgs(rest);
        try server.runFromConfig(cfg_path);
    } else if (eq(sub, "init")) {
        const dir = if (rest.len > 0) rest[0] else ".";
        try bake_mod.doInit(dir);
    } else if (eq(sub, "help") or eq(sub, "--help") or eq(sub, "-h")) {
        try printHelp();
    } else {
        std.debug.print("baker: unknown command '{s}'\n\n", .{sub});
        try printHelp();
        std.process.exit(2);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `serve` mode: only --config is recognised; anything else is an error.
fn parseConfigFlag(args: []const []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            return args[i];
        }
        std.debug.print("baker: unknown flag '{s}'\n", .{args[i]});
        return error.UnknownFlag;
    }
    return null;
}

/// `run` mode: bake has already consumed the args; we just want the
/// --config value (if any) so the server uses the same file. Unknown flags
/// here would have been rejected by bake; we silently skip everything else.
fn configFromArgs(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--config") and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn printHelp() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    try stderr.interface.writeAll(HELP);
    try stderr.interface.flush();
}
