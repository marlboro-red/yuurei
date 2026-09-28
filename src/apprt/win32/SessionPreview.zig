//! An on-demand, read-only broker preview. Only exists while the picker is open.
const Self = @This();
const std = @import("std");
const w = @import("winapi.zig");
const Client = @import("../../mux/Client.zig");
const global = @import("../../global.zig");
const alloc = std.heap.c_allocator;
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const w.HANDLE, w.BOOL, u32) callconv(.winapi) u32;

pub const ready_message = 0x8000 + 91;
pub const capacity = 64 * 1024;
hwnd: w.HWND,
stop: w.HANDLE,
wake: w.HANDLE,
thread: ?std.Thread = null,
mutex: std.Io.Mutex = .init,
generation: u64 = 0,
completed: u64 = 0,
name: [128]u8 = undefined,
name_len: usize = 0,
text: [capacity]u16 = undefined,
text_len: usize = 0,

pub fn create(hwnd: w.HWND) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const stop = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(stop);
    const wake = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(wake);
    self.* = .{ .hwnd = hwnd, .stop = stop, .wake = wake };
    self.thread = try std.Thread.spawn(@import("../../os/windows.zig").worker_thread_config, run, .{self});
    return self;
}

pub fn destroy(self: *Self) void {
    _ = SetEvent(self.stop);
    self.thread.?.join();
    _ = w.CloseHandle(self.wake);
    _ = w.CloseHandle(self.stop);
    alloc.destroy(self);
}

/// Invalidates an in-flight result immediately, before the UI debounce timer.
pub fn select(self: *Self, name: []const u8) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.generation +%= 1;
    self.name_len = @min(name.len, self.name.len);
    @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
    self.text_len = 0;
}

pub fn request(self: *Self) void {
    _ = SetEvent(self.wake);
}

pub fn copy(self: *Self, output: []u16) []const u16 {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const value = if (self.completed != self.generation)
        std.unicode.utf8ToUtf16LeStringLiteral("Loading preview…")
    else if (self.text_len == 0)
        std.unicode.utf8ToUtf16LeStringLiteral("Empty screen")
    else
        self.text[0..self.text_len];
    const n = @min(value.len, output.len);
    @memcpy(output[0..n], value[0..n]);
    return output[0..n];
}

fn run(self: *Self) void {
    const handles = [_]w.HANDLE{ self.stop, self.wake };
    var bytes: [capacity]u8 = undefined;
    var wide: [capacity]u16 = undefined;
    while (WaitForMultipleObjects(2, &handles, 0, w.INFINITE) == 1) {
        self.mutex.lockUncancelable(global.io());
        const generation = self.generation;
        const name = self.name;
        const len = self.name_len;
        self.mutex.unlock(global.io());
        if (len == 0) continue;
        const result = fetch(name[0..len], self.stop, &bytes) catch |err| switch (err) {
            error.IncompatibleBuild => "Preview unavailable: different build.",
            error.SessionNotFound => "Session ended.",
            else => "Preview unavailable. Press F5 to retry.",
        };
        const n = std.unicode.utf8ToUtf16Le(&wide, result) catch 0;
        self.mutex.lockUncancelable(global.io());
        if (self.generation == generation) {
            @memcpy(self.text[0..n], wide[0..n]);
            self.text_len = n;
            self.completed = generation;
        }
        self.mutex.unlock(global.io());
        _ = w.PostMessageW(self.hwnd, ready_message, 0, 0);
    }
}

fn fetch(name: []const u8, stop: w.HANDLE, bytes: []u8) ![]const u8 {
    var client = try Client.initControl(name, stop);
    defer client.deinit();
    const reply = try client.request(.preview, "", 0, bytes);
    return bytes[0..reply.length];
}
