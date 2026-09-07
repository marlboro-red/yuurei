//! This structure caches the shaped cells for a given text run.
//!
//! At one point, shaping was the most expensive part of rendering text
//! (accounting for 96% of frame time on my machine). To speed it up, this
//! was introduced so that shaping results can be cached depending on the
//! run.
//!
//! The cache key is the text run. The text run builds its own hash value
//! based on the font, style, codepoint, etc. This just utilizes the hash that
//! the text run provides.
pub const Cache = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const CacheTable = @import("../../datastruct/main.zig").CacheTable;

const log = std.log.scoped(.font_shaper_cache);

/// Context for cache table.
const CellCacheTableContext = struct {
    pub fn hash(self: *const CellCacheTableContext, key: u64) u64 {
        _ = self;
        return key;
    }
    pub fn eql(self: *const CellCacheTableContext, a: u64, b: u64) bool {
        _ = self;
        return a == b;
    }
};

/// Cache table for run hash -> shaped cells.
const CellCacheTable = CacheTable(
    u64,
    []font.shape.Cell,
    CellCacheTableContext,

    // Capacity is slightly arbitrary. These numbers are guesses.
    //
    // I'd expect then an average of 256 frequently cached runs is a
    // safe guess most terminal screens.
    256,
    // 8 items per bucket to give decent resiliency to important runs.
    8,
);

/// The cache table of shaped cells.
map: CellCacheTable,
tracing: bool = false,
hits: u64 = 0,
misses: u64 = 0,
evictions: u64 = 0,

pub fn init() Cache {
    return .{ .map = .{ .context = .{} }, .tracing = @import("../../perf.zig").isEnabled() };
}

pub fn deinit(self: *Cache, alloc: Allocator) void {
    if (self.tracing) self.report();
    self.clear(alloc);
}

/// Get the shaped cells for the given text run,
/// or null if they are not in the cache.
pub fn get(self: *Cache, run: font.shape.TextRun) ?[]const font.shape.Cell {
    const result = self.map.get(run.hash);
    if (self.tracing) {
        if (result != null) self.hits += 1 else self.misses += 1;
        if ((self.hits + self.misses) % 4096 == 0) self.report();
    }
    return result;
}

fn report(self: *const Cache) void {
    log.info("perf: shaping-cache hits={d} misses={d} evictions={d}", .{ self.hits, self.misses, self.evictions });
}

/// Insert the shaped cells for the given text run into the cache.
///
/// The cells will be duplicated.
pub fn put(
    self: *Cache,
    alloc: Allocator,
    run: font.shape.TextRun,
    cells: []const font.shape.Cell,
) Allocator.Error!void {
    const copy = try alloc.dupe(font.shape.Cell, cells);
    const evicted = self.map.put(run.hash, copy);
    if (evicted) |kv| {
        if (self.tracing) self.evictions += 1;
        alloc.free(kv.value);
    }
}

fn clear(self: *Cache, alloc: Allocator) void {
    for (self.map.buckets, self.map.lengths) |b, l| {
        for (b[0..l]) |kv| {
            alloc.free(kv.value);
        }
    }
    self.map.clear();
}

test Cache {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = Cache.init();
    defer c.deinit(alloc);

    var run: font.shape.TextRun = undefined;
    run.hash = 1;
    try testing.expect(c.get(run) == null);
    try c.put(alloc, run, &.{
        .{ .x = 0, .glyph_index = 0 },
        .{ .x = 1, .glyph_index = 1 },
    });

    const actual = c.get(run).?;
    try testing.expect(actual.len == 2);
}
