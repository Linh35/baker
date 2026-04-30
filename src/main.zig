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

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next(); // skip program name

    const sub = args.next() orelse {
        try printHelp();
        std.process.exit(2);
    };

    if (eq(sub, "bake")) {
        try bake_mod.run(allocator, &args);
    } else if (eq(sub, "serve")) {
        const cfg_path = try parseConfigFlag(&args);
        try server.runFromConfig(cfg_path);
    } else if (eq(sub, "run")) {
        // bake first; if it fails, don't start the server.
        try bake_mod.run(allocator, &args);
        const cfg_path = try parseConfigFlag(&args);
        try server.runFromConfig(cfg_path);
    } else if (eq(sub, "init")) {
        const dir = args.next() orelse ".";
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

fn parseConfigFlag(args: *std.process.ArgIterator) !?[]const u8 {
    while (args.next()) |arg| {
        if (eq(arg, "--config")) return args.next() orelse return error.MissingConfigPath;
        std.debug.print("baker: unknown flag '{s}'\n", .{arg});
        return error.UnknownFlag;
    }
    return null;
}

fn printHelp() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    try stderr.interface.writeAll(HELP);
    try stderr.interface.flush();
}
