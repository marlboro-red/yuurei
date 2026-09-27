//! Opt-in Windows multiplexer architecture prototype. No GUI resources.
const std = @import("std");
const global = @import("global.zig");
const mux = @import("mux/host.zig");
comptime {
    _ = @import("quirks_memset.zig");
}

pub fn main(init: std.process.Init.Minimal) !void {
    try global.init(.{ .tool = init });
    var args = try init.args.iterateAllocator(std.heap.c_allocator);
    defer args.deinit();
    _ = args.next();
    const operation = args.next() orelse return error.ExpectedOperation;
    const name = args.next() orelse return error.ExpectedSessionName;
    try mux.run(operation, name, &args);
}

test {
    _ = @import("mux/protocol.zig");
    _ = @import("mux/snapshot_test.zig");
}
