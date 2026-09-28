//! One cancellable workspace discovery or attachment preparation task.
const Self = @This();
const std = @import("std");
const session = @import("session.zig");
const Mux = @import("../../termio/Mux.zig");
const global = @import("../../global.zig");
const w = @import("winapi.zig");
pub const alloc = std.heap.c_allocator;
pub const ready_message = 0x8000 + 92;
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) w.BOOL;

hwnd: w.HWND,
// Terminal snapshot storage moves into a Surface; use that Surface's allocator
// so Debug builds can safely free it (the job's own bookkeeping uses libc).
backend_alloc: std.mem.Allocator = alloc,
generation: u64 = 0,
thread: ?std.Thread = null,
done: std.atomic.Value(bool) = .init(false),
cancelled: std.atomic.Value(bool) = .init(false),
mutex: std.Io.Mutex = .init,
active: ?*Mux = null,
failure: ?anyerror = null,
entries: ?[]session.catalog.Entry = null,
target: ?[]const u8 = null,
source_name: ?[]const u8 = null,
source_path: ?[]const u8 = null,
source_data: ?[]const u8 = null,
prepared: ?session.PreparedWorkspace = null,
muxes: std.ArrayList(?*Mux) = .empty,

pub fn create(hwnd: w.HWND) !*Self {
    const self = try alloc.create(Self);
    self.* = .{ .hwnd = hwnd };
    return self;
}
pub fn start(self: *Self) !void {
    self.thread = try std.Thread.spawn(@import("../../os/windows.zig").worker_thread_config, run, .{self});
}
pub fn cancel(self: *Self) void {
    self.cancelled.store(true, .release);
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.active) |mux| _ = SetEvent(mux.stop);
}
pub fn destroy(self: *Self) void {
    self.cancel();
    if (self.thread) |thread| thread.join();
    for (self.muxes.items) |item| if (item) |mux| mux.deinit();
    self.muxes.deinit(alloc);
    if (self.prepared) |*prepared| prepared.deinit();
    if (self.entries) |entries| session.catalog.deinit(alloc, entries);
    if (self.target) |value| alloc.free(value);
    if (self.source_name) |value| alloc.free(value);
    if (self.source_path) |value| alloc.free(value);
    if (self.source_data) |value| alloc.free(value);
    alloc.destroy(self);
}
fn run(self: *Self) void {
    self.work() catch |err| {
        self.failure = err;
    };
    self.done.store(true, .release);
    _ = w.PostMessageW(self.hwnd, ready_message, 0, 0);
}
fn work(self: *Self) !void {
    const target = self.target orelse {
        self.entries = try session.listSaved(alloc);
        return;
    };
    const parsed = try std.json.parseFromSlice(@import("../../mux/Workspace.zig").State, alloc, self.source_data.?, .{});
    defer parsed.deinit();
    var ids: [64][]const u8 = undefined;
    var count: usize = 0;
    for (parsed.value.windows) |window| for (window.tabs) |tab| {
        for (tab.nodes) |node| switch (node) {
            .leaf => |pane| {
                if (count == ids.len) return error.WorkspaceTooLarge;
                ids[count] = pane.session orelse return error.NonPersistentWorkspace;
                count += 1;
            },
            .split => {},
        };
    };
    self.prepared = try session.prepareSwitch(alloc, target, ids[0..count]);
    try self.muxes.ensureTotalCapacity(alloc, 64);
    for (self.prepared.?.layout.value.windows) |window| for (window.tabs) |tab| {
        for (tab.nodes) |node| switch (node) {
            .leaf => |pane| {
                if (self.cancelled.load(.acquire)) return error.Cancelled;
                const mux = try Mux.createUnconnected(self.backend_alloc, pane.session.?);
                self.muxes.appendAssumeCapacity(mux);
                self.mutex.lockUncancelable(global.io());
                self.active = mux;
                if (self.cancelled.load(.acquire)) _ = SetEvent(mux.stop);
                self.mutex.unlock(global.io());
                defer {
                    self.mutex.lockUncancelable(global.io());
                    self.active = null;
                    self.mutex.unlock(global.io());
                }
                try mux.connectExisting();
            },
            .split => {},
        };
    };
    if (self.cancelled.load(.acquire)) return error.Cancelled;
    try session.writeSaved(alloc, self.source_path.?, self.source_name.?, self.source_data.?);
}
