// root.zig — public entry point of the `baker` runtime module.
//
// Consumers `@import("baker")` and call into:
//   - `run(opts)`         — start the server with the manifest they imported
//   - `Manifest`          — type alias for the shape baker-bake emits
//   - `Encoding`, `etc.`  — re-exports of the public runtime types
//
// Everything else (HTTP parsing, response assembly, listener setup) is
// internal to src/server.zig and not part of the public API.

const server = @import("server.zig");
const config_mod = @import("config.zig");

pub const run = server.run;
pub const runFromConfig = server.runFromConfig;
pub const RunOptions = server.RunOptions;
pub const Encoding = server.Encoding;
pub const Config = config_mod.Config;
pub const loadConfig = config_mod.loadFromFile;
pub const freeConfig = config_mod.freeConfig;
