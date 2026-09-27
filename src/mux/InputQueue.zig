//! On-demand paste storage. Wire requests stay small and the allocation is
//! released once drained, so idle panes do not retain a large paste buffer.
const std = @import("std");
const Queue = @This();
pub const limit = 16 * 1024 * 1024;
bytes: std.ArrayList(u8) = .empty,
offset: usize = 0,

pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
    self.bytes.deinit(alloc);
    self.* = .{};
}

pub fn pending(self: *const Queue) []const u8 {
    return self.bytes.items[self.offset..];
}

pub fn append(self: *Queue, alloc: std.mem.Allocator, data: []const u8, linefeed: bool) !void {
    const extra = if (linefeed) std.mem.count(u8, data, "\r") else 0;
    const remaining = limit - self.pending().len;
    if (data.len > remaining or extra > remaining - data.len) return error.InputQueueFull;
    if (self.offset > 0) {
        const len = self.pending().len;
        std.mem.copyForwards(u8, self.bytes.items[0..len], self.pending());
        self.bytes.items.len = len;
        self.offset = 0;
    }
    try self.bytes.ensureUnusedCapacity(alloc, data.len + extra);
    if (!linefeed) return self.bytes.appendSliceAssumeCapacity(data);
    for (data) |byte| {
        self.bytes.appendAssumeCapacity(byte);
        if (byte == '\r') self.bytes.appendAssumeCapacity('\n');
    }
}

pub fn consume(self: *Queue, alloc: std.mem.Allocator, count: usize) void {
    std.debug.assert(count <= self.pending().len);
    self.offset += count;
    if (self.offset == self.bytes.items.len) self.deinit(alloc);
}

test "mux input preserves chunk ordering expansion and releases drained storage" {
    const t = std.testing;
    var queue: Queue = .{};
    defer queue.deinit(t.allocator);
    const data = try t.allocator.alloc(u8, 200000);
    defer t.allocator.free(data);
    @memset(data, 'x');
    try queue.append(t.allocator, data, false);
    queue.consume(t.allocator, 65536);
    try queue.append(t.allocator, "\rEND", true);
    try t.expectEqual(@as(usize, 200000 - 65536 + 5), queue.pending().len);
    try t.expect(std.mem.endsWith(u8, queue.pending(), "\r\nEND"));
    while (queue.pending().len > 0) queue.consume(t.allocator, @min(65536, queue.pending().len));
    try t.expectEqual(@as(usize, 0), queue.bytes.capacity);
}

test "mux input rejects overflow atomically including linefeed expansion" {
    const t = std.testing;
    var queue: Queue = .{};
    defer queue.deinit(t.allocator);
    const data = try t.allocator.alloc(u8, limit);
    defer t.allocator.free(data);
    @memset(data, 'x');
    try queue.append(t.allocator, data[0 .. limit - 1], false);
    try t.expectError(error.InputQueueFull, queue.append(t.allocator, "\r", true));
    try t.expectEqual(@as(usize, limit - 1), queue.pending().len);
    try queue.append(t.allocator, "z", false);
    try t.expectError(error.InputQueueFull, queue.append(t.allocator, "a", false));
}
