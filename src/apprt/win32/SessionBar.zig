//! Event-driven session metadata and inline confirmation state.
const SessionBar = @This();
const std = @import("std");
const Registry = @import("../../mux/Registry.zig");

pub const Target = struct {
    id: [128]u8 = undefined,
    id_len: usize = 0,
    label: [128]u8 = undefined,
    label_len: usize = 0,

    pub fn init(id: []const u8, label: []const u8) ?Target {
        var result: Target = .{};
        if (id.len > result.id.len or label.len > result.label.len) return null;
        @memcpy(result.id[0..id.len], id);
        @memcpy(result.label[0..label.len], label);
        result.id_len = id.len;
        result.label_len = label.len;
        return result;
    }

    pub fn name(self: *const Target) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn title(self: *const Target) []const u8 {
        return self.label[0..self.label_len];
    }
};

current: Target = .{},
shell_pid: u32 = 0,
pending: ?Target = null,
failed: bool = false,
/// Suppress releases/repeats for keys captured by the confirmation even
/// after Y or Esc closes it, so they cannot leak into the shell.
captured: [256]bool = @splat(false),

pub fn refresh(self: *SessionBar, alloc: std.mem.Allocator, name: []const u8, force: bool) void {
    if (!force and std.mem.eql(u8, self.current.name(), name)) return;
    self.current = Target.init(name, name) orelse .{};
    self.shell_pid = 0;
    if (self.current.id_len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const entries = Registry.list(arena.allocator()) catch return;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        self.current = Target.init(name, if (entry.label.len > 0) entry.label else name) orelse .{};
        self.shell_pid = entry.shell_pid;
        break;
    }
}

pub fn begin(self: *SessionBar, name: []const u8, label: []const u8) void {
    self.pending = Target.init(name, label);
    self.failed = self.pending == null;
}

pub fn cancel(self: *SessionBar) void {
    self.pending = null;
    self.failed = false;
}

test "session bar confirmation owns the selected session independently of focus" {
    var bar: SessionBar = .{};
    bar.begin("backend", "Backend 日本語");
    bar.current = Target.init("frontend", "Frontend").?;
    try std.testing.expectEqualStrings("backend", bar.pending.?.name());
    try std.testing.expectEqualStrings("Backend 日本語", bar.pending.?.title());
    bar.cancel();
    try std.testing.expect(bar.pending == null);
    try std.testing.expectEqualStrings("frontend", bar.current.name());
    bar.begin(&(@as([129]u8, @splat('x'))), "Invalid session");
    try std.testing.expect(bar.pending == null and bar.failed);
}
