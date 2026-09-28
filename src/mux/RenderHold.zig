//! Presentation-only synchronized-output deadline. No polling when inactive.
const RenderHold = @This();
const std = @import("std");
deadline: ?u64 = null,

pub fn set(self: *RenderHold, held: bool, now: u64) void {
    self.deadline = if (held) now +| 1000 else null;
}

pub fn wait(self: RenderHold, now: u64) u32 {
    return if (self.deadline) |deadline| @intCast(@min(deadline -| now, 1000)) else std.math.maxInt(u32);
}

pub fn expire(self: *RenderHold, now: u64) bool {
    const deadline = self.deadline orelse return false;
    if (now < deadline) return false;
    self.deadline = null;
    return true;
}

test "mux render hold wakes idle views and recovers missing reset" {
    const t = std.testing;
    var hold: RenderHold = .{};
    try t.expectEqual(std.math.maxInt(u32), hold.wait(0));
    hold.set(true, 100);
    try t.expectEqual(1000, hold.wait(100));
    try t.expect(!hold.expire(1099));
    try t.expectEqual(1, hold.wait(1099));
    try t.expect(hold.expire(1100));
    try t.expect(!hold.expire(1200));
    try t.expectEqual(std.math.maxInt(u32), hold.wait(1200));
    hold.set(true, 1300);
    hold.set(false, 1400);
    try t.expect(!hold.expire(2400));
}
