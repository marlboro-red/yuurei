//! UI-owned pending startup requests. Workers may finish in any order; tabs and splits
//! publish in request order. Cancellation signals every worker before joining.
const std = @import("std");

pub fn Queue(comptime Request: type) type {
    return struct {
        const Self = @This();
        pub const limit = 16;
        pending: std.ArrayList(*Request) = .empty,

        pub fn append(self: *Self, alloc: std.mem.Allocator, request: *Request) !void {
            if (self.pending.items.len >= limit) return error.TooManyPendingSurfaces;
            try self.pending.append(alloc, request);
        }

        pub fn popReady(self: *Self) ?*Request {
            if (self.pending.items.len == 0) return null;
            const first = self.pending.items[0];
            if (!first.done.load(.acquire)) return null;
            return self.pending.orderedRemove(0);
        }

        /// Remove requests whose captured destination is no longer live. The
        /// predicate must stay stable while cancellation/destruction runs.
        /// Signal every matching worker first; surviving requests keep FIFO.
        pub fn cancelMatching(self: *Self, context: anytype, comptime matches: fn (@TypeOf(context), *Request) bool) void {
            for (self.pending.items) |request| {
                if (matches(context, request)) request.cancel();
            }
            var index: usize = 0;
            while (index < self.pending.items.len) {
                const request = self.pending.items[index];
                if (matches(context, request)) {
                    _ = self.pending.orderedRemove(index);
                    request.destroy();
                } else index += 1;
            }
        }

        pub fn cancelAll(self: *Self) void {
            for (self.pending.items) |request| request.cancel();
            for (self.pending.items) |request| request.destroy();
            self.pending.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.cancelAll();
            self.pending.deinit(alloc);
        }
    };
}

const Fixture = struct {
    done: std.atomic.Value(bool) = .init(false),
    cancellations: *usize,
    destructions: *usize,
    expected_cancelled_before_destroy: usize,
    cancelled: bool = false,
    destroyed: bool = false,

    fn cancel(self: *@This()) void {
        std.debug.assert(!self.cancelled);
        self.cancelled = true;
        self.cancellations.* += 1;
    }
    fn destroy(self: *@This()) void {
        std.debug.assert(self.cancelled and !self.destroyed);
        std.debug.assert(self.cancellations.* == self.expected_cancelled_before_destroy);
        self.destroyed = true;
        self.destructions.* += 1;
    }
};

test "mux startup FIFO waits for oldest worker and transfers ownership once" {
    const t = std.testing;
    var cancelled: usize = 0;
    var destroyed: usize = 0;
    var first: Fixture = .{ .cancellations = &cancelled, .destructions = &destroyed, .expected_cancelled_before_destroy = 0 };
    var second = first;
    var queue: Queue(Fixture) = .{};
    defer queue.deinit(t.allocator);
    try queue.append(t.allocator, &first);
    try queue.append(t.allocator, &second);
    second.done.store(true, .release);
    try t.expect(queue.popReady() == null);
    first.done.store(true, .release);
    try t.expect(queue.popReady().? == &first);
    try t.expect(queue.popReady().? == &second);
    try t.expect(queue.popReady() == null);
    try t.expectEqual(@as(usize, 0), cancelled);
    try t.expectEqual(@as(usize, 0), destroyed);
}

test "mux startup cancellation signals all workers before waiting and never publishes them" {
    const t = std.testing;
    var cancelled: usize = 0;
    var destroyed: usize = 0;
    var first: Fixture = .{ .cancellations = &cancelled, .destructions = &destroyed, .expected_cancelled_before_destroy = 2 };
    var second = first;
    second.done.store(true, .release);
    var queue: Queue(Fixture) = .{};
    defer queue.deinit(t.allocator);
    try queue.append(t.allocator, &first);
    try queue.append(t.allocator, &second);
    queue.cancelAll();
    try t.expectEqual(@as(usize, 2), cancelled);
    try t.expectEqual(@as(usize, 2), destroyed);
    first.done.store(true, .release);
    try t.expect(queue.popReady() == null);
    queue.cancelAll();
    try t.expectEqual(@as(usize, 2), destroyed);
}

test "mux startup pending limit leaves rejected request with caller" {
    const t = std.testing;
    var cancelled: usize = 0;
    var destroyed: usize = 0;
    var requests: [17]Fixture = undefined;
    var queue: Queue(Fixture) = .{};
    defer queue.deinit(t.allocator);
    for (&requests) |*request| request.* = .{ .cancellations = &cancelled, .destructions = &destroyed, .expected_cancelled_before_destroy = 16 };
    for (requests[0..16]) |*request| try queue.append(t.allocator, request);
    try t.expectError(error.TooManyPendingSurfaces, queue.append(t.allocator, &requests[16]));
    queue.cancelAll();
    try t.expectEqual(@as(usize, 16), destroyed);
    try t.expect(!requests[16].cancelled and !requests[16].destroyed);
}

test "mux startup closed split targets cancel promptly without blocking mixed request FIFO" {
    const t = std.testing;
    const Request = struct {
        lifecycle: Fixture,
        done: std.atomic.Value(bool) = .init(false),
        target: ?u64,
        direction: enum { right, down } = .right,
        fn cancel(self: *@This()) void {
            self.lifecycle.cancel();
        }
        fn destroy(self: *@This()) void {
            self.lifecycle.destroy();
        }
        fn closed(id: u64, self: *@This()) bool {
            return self.target != null and self.target.? == id;
        }
    };
    var cancelled: usize = 0;
    var destroyed: usize = 0;
    const lifecycle: Fixture = .{ .cancellations = &cancelled, .destructions = &destroyed, .expected_cancelled_before_destroy = 2 };
    var slow_closed: Request = .{ .lifecycle = lifecycle, .target = 7 };
    var tab: Request = .{ .lifecycle = lifecycle, .target = null };
    var ready_closed: Request = .{ .lifecycle = lifecycle, .target = 7, .direction = .down };
    var split: Request = .{ .lifecycle = lifecycle, .target = 9, .direction = .down };
    var queue: Queue(Request) = .{};
    defer queue.deinit(t.allocator);
    try queue.append(t.allocator, &slow_closed);
    try queue.append(t.allocator, &tab);
    try queue.append(t.allocator, &ready_closed);
    try queue.append(t.allocator, &split);
    ready_closed.done.store(true, .release);
    split.done.store(true, .release);
    queue.cancelMatching(@as(u64, 7), Request.closed);
    try t.expectEqual(@as(usize, 2), destroyed);
    try t.expect(!tab.lifecycle.cancelled and !split.lifecycle.cancelled);
    try t.expect(queue.popReady() == null);
    tab.done.store(true, .release);
    try t.expect(queue.popReady().? == &tab);
    const published = queue.popReady().?;
    try t.expect(published == &split);
    try t.expectEqual(@as(?u64, 9), published.target);
    try t.expectEqual(.down, published.direction);
    slow_closed.done.store(true, .release);
    try t.expect(queue.popReady() == null);
}
