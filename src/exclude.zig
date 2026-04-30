// exclude.zig — file-path glob matching for the bake-time exclude list.
// Pattern shapes: `*suffix`, `prefix*`, `*contains*`, exact, and bare `*`.

const std = @import("std");
const mem = std.mem;

pub fn match(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return false;
    const starts_star = pattern[0] == '*';
    const ends_star = pattern[pattern.len - 1] == '*';
    if (starts_star and ends_star) {
        if (pattern.len <= 2) return true;
        return mem.indexOf(u8, path, pattern[1 .. pattern.len - 1]) != null;
    }
    if (starts_star) return mem.endsWith(u8, path, pattern[1..]);
    if (ends_star) return mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
    return mem.eql(u8, pattern, path);
}

pub fn any(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| if (match(p, path)) return true;
    return false;
}

test "suffix matches at any depth" {
    try std.testing.expect(match("*.md", "README.md"));
    try std.testing.expect(match("*.md", "docs/foo.md"));
    try std.testing.expect(!match("*.md", "README.markdown"));
}

test "prefix matches a directory" {
    try std.testing.expect(match(".claude/*", ".claude/settings.json"));
    try std.testing.expect(!match(".claude/*", "claude/foo"));
}

test "contains matches anywhere" {
    try std.testing.expect(match("*node_modules*", "a/node_modules/b"));
    try std.testing.expect(!match("*node_modules*", "src/index.js"));
}

test "exact and wildcard" {
    try std.testing.expect(match("serve", "serve"));
    try std.testing.expect(!match("serve", "serve.js"));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("**", "anything"));
}

test "any() is or-of-patterns" {
    const pats = &[_][]const u8{ "*.md", ".claude/*" };
    try std.testing.expect(any(pats, "README.md"));
    try std.testing.expect(any(pats, ".claude/x"));
    try std.testing.expect(!any(pats, "src/main.zig"));
}
