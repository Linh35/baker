// minify.zig — pre-compression source minification. Run before brotli/gzip
// to shrink the input and improve final compression ratio.
//
// Strategy per type:
//   HTML — strip `<!-- ... -->` comments; collapse runs of inter-tag whitespace
//          to a single space; preserve content of <pre>, <textarea>, <script>,
//          <style> blocks verbatim.
//   CSS  — strip `/* ... */` comments; collapse runs of whitespace to a single
//          space; strip whitespace around `{ } ; : ,`.
//   JS   — conservative: strip whitespace-only lines, leave the rest. Real JS
//          identifier obfuscation needs a parser; out of scope for now.
//
// All routines allocate the output buffer via the caller's allocator. They
// never fail except on OOM. Bytes only — no character-set decoding.

const std = @import("std");
const mem = std.mem;

fn matchVerbatimBlock(input: []const u8, i: usize) ?struct { len: usize, advance: usize } {
    if (input[i] != '<' or i + 1 >= input.len) return null;
    const tags = [_][]const u8{ "pre", "textarea", "script", "style" };
    inline for (tags) |tag| {
        const open = "<" ++ tag;
        if (i + open.len <= input.len and mem.eql(u8, input[i .. i + open.len], open)) {
            const next = if (i + open.len < input.len) input[i + open.len] else 0;
            if (next == '>' or next == ' ' or next == '\t' or next == '\n' or i + open.len == input.len) {
                const close = "</" ++ tag ++ ">";
                const end = mem.indexOf(u8, input[i..], close) orelse return null;
                return .{ .len = end + close.len, .advance = end + close.len };
            }
        }
    }
    return null;
}

/// Returns the minified bytes; caller frees.
pub fn html(allocator: mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, input.len);
    defer out.deinit(allocator);
    var i: usize = 0;
    var last_was_space = true; // suppress leading whitespace
    while (i < input.len) {
        // Strip <!-- ... -->
        if (i + 4 <= input.len and mem.eql(u8, input[i .. i + 4], "<!--")) {
            const end = mem.indexOf(u8, input[i..], "-->") orelse break;
            i += end + 3;
            continue;
        }
        // Preserve verbatim blocks: <pre>, <textarea>, <script>, <style>
        if (matchVerbatimBlock(input, i)) |vb| {
            try out.appendSlice(allocator, input[i .. i + vb.len]);
            i += vb.advance;
            last_was_space = false;
            continue;
        }
        const c = input[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_was_space) try out.append(allocator, ' ');
            last_was_space = true;
            i += 1;
            continue;
        }
        // Strip whitespace adjacent to < and >
        if (c == '<' and out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
        }
        try out.append(allocator, c);
        last_was_space = (c == '>'); // collapse space after a tag close
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Returns the minified bytes; caller frees.
pub fn css(allocator: mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, input.len);
    defer out.deinit(allocator);
    var i: usize = 0;
    var last_was_space = true;
    while (i < input.len) {
        // Strip /* ... */
        if (i + 2 <= input.len and input[i] == '/' and input[i + 1] == '*') {
            const end = mem.indexOf(u8, input[i + 2 ..], "*/") orelse break;
            i += end + 4;
            continue;
        }
        const c = input[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_was_space) try out.append(allocator, ' ');
            last_was_space = true;
            i += 1;
            continue;
        }
        // Strip whitespace adjacent to special chars
        if ((c == '{' or c == '}' or c == ';' or c == ':' or c == ',') and
            out.items.len > 0 and out.items[out.items.len - 1] == ' ')
        {
            out.items.len -= 1;
        }
        try out.append(allocator, c);
        last_was_space = (c == '{' or c == '}' or c == ';' or c == ':' or c == ',');
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Returns the minified bytes; caller frees. Conservative: only collapses
/// whitespace-only lines. Does not parse JS — string literals stay intact.
pub fn js(allocator: mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, input.len);
    defer out.deinit(allocator);
    var i: usize = 0;
    var prev_newline = true;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\n') {
            // collapse multi-blank lines
            if (!prev_newline) try out.append(allocator, '\n');
            prev_newline = true;
            continue;
        }
        if (prev_newline and (c == ' ' or c == '\t')) {
            // strip leading whitespace
            continue;
        }
        try out.append(allocator, c);
        prev_newline = false;
    }
    return out.toOwnedSlice(allocator);
}

pub fn forPath(allocator: mem.Allocator, path: []const u8, input: []const u8) !?[]u8 {
    const ends = std.ascii.endsWithIgnoreCase;
    if (ends(path, ".html") or ends(path, ".htm")) return try html(allocator, input);
    if (ends(path, ".css")) return try css(allocator, input);
    if (ends(path, ".js") or ends(path, ".mjs")) return try js(allocator, input);
    return null;
}

test "html strips comments and collapses whitespace" {
    const input =
        \\<!doctype html>
        \\<html>
        \\  <!-- a comment -->
        \\  <body>
        \\    <h1>Hi</h1>
        \\  </body>
        \\</html>
    ;
    const out = try html(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(mem.indexOf(u8, out, "comment") == null);
    try std.testing.expect(out.len < input.len);
}

test "css strips comments and collapses" {
    const input = "/* hi */\nbody {\n  color: red;\n  /* x */ padding: 0;\n}\n";
    const out = try css(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(mem.indexOf(u8, out, "hi") == null);
    try std.testing.expect(out.len < input.len);
}
