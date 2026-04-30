// bundle.zig — on-disk format for `baked.bin`. Shared between `baker-bake` (writer)
// and the runtime (reader). Little-endian fixed-size extern structs, mmap-friendly.
//
// Layout:
//   [Header]              fixed 64 bytes at offset 0
//   [string pool]         path strings, no separators
//   [ToC]                 fixed-size entries (one per route)
//   [data section]        full HTTP responses (header + body, pre-built)
//
// Each ToC entry references slices of the string pool (path) and the data
// section (one slice per encoding). The runtime mmap()s the file once at
// startup and walks the ToC in-place — no parsing into a heap structure.
//
// Two programs that will never share a process agree, in absentia, on the
// shape of these bytes. Change a field here and you change the contract on
// both sides at once; the comptime asserts below are the only witnesses.

const std = @import("std");

pub const MAGIC: [8]u8 = "BAKERV01".*;
pub const VERSION: u32 = 1;

pub const Flags = struct {
    pub const HAS_GZIP: u32 = 1 << 0;
    pub const HAS_BROTLI: u32 = 1 << 1;
};

pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    count: u32,
    string_pool_offset: u64,
    string_pool_size: u64,
    toc_offset: u64,
    toc_size: u64,
    data_offset: u64,
    data_size: u64,
    /// Optional pre-built 404 response (status 404). Lives in the data section.
    /// `len == 0` means no custom 404 — the runtime falls back to a plaintext default.
    not_found_offset: u64,
    not_found_len: u64,
};

pub const TocEntry = extern struct {
    path_offset: u32,
    path_len: u32,
    flags: u32,
    _pad: u32,
    identity_offset: u64,
    identity_len: u64,
    gzip_offset: u64,
    gzip_len: u64,
    brotli_offset: u64,
    brotli_len: u64,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 80);
    std.debug.assert(@sizeOf(TocEntry) == 64);
}
