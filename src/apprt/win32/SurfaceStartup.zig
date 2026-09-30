//! Prepare one new persistent tab or split without blocking the Win32 message loop.
//! No HWND, Window, Surface or renderer is accessed by the worker. The UI owns
//! the request and publishes its prepared backend only after `done` is acquired.
const Self = @This();
const std = @import("std");
const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const Config = @import("../../config.zig").Config;
const Exec = @import("../../termio/Exec.zig");
const Mux = @import("../../termio/Mux.zig");
const Window = @import("Window.zig");
const w = @import("winapi.zig");
pub const Destination = union(enum) {
    tab,
    split: struct {
        // Never retain a UI pointer or SplitTree handle across preparation.
        surface_id: u64,
        direction: @import("../../apprt.zig").action.SplitDirection,
    },
};

const perf = @import("../../perf.zig");
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) w.BOOL;

alloc: std.mem.Allocator,
config: Config,
profile_name: ?[]const u8,
font_size: ?@import("../../font/main.zig").face.DesiredSize,
surface_id: u64,
destination: Destination,
thread_id: u32,
mux: ?*Mux,
exec: ?Exec,
thread: ?std.Thread = null,
done: std.atomic.Value(bool) = .init(false),

/// Takes ownership of config only on success. Config/profile/env/cwd are owned
/// snapshots: focus changes, config reloads and profile rescans cannot retarget
/// a pending request or invalidate anything the worker reads.
pub fn create(window: *Window, destination: Destination, config: Config, profile: ?[]const u8, font_size: ?@import("../../font/main.zig").face.DesiredSize) !*Self {
    const alloc = window.app.core_app.alloc;
    const id = CoreSurface.newId();
    const name = try std.fmt.allocPrint(alloc, "pane-{x}", .{id});
    defer alloc.free(name);
    const mux = try Mux.createUnconnected(alloc, name);
    errdefer mux.deinit();
    var env = if (window.launch_environment) |*environment| try environment.clone(alloc) else try global.environMap();
    var env_owned = true;
    errdefer if (env_owned) env.deinit();
    _ = env.orderedRemove("GHOSTTY_LOG");
    var id_buffer: [18]u8 = undefined;
    try env.put("GHOSTTY_SURFACE_ID", try std.fmt.bufPrint(&id_buffer, "0x{x:0>16}", .{id}));
    var exec = try Exec.init(alloc, .{
        .command = config.command,
        .env = env,
        .env_override = config.env,
        .shell_integration = config.@"shell-integration",
        .shell_integration_features = config.@"shell-integration-features",
        .cursor_blink = config.@"cursor-style-blink",
        .working_directory = if (config.@"working-directory") |directory| directory.value() else null,
        .resources_dir = global.resourcesDir().host(),
        .term = config.term,
        .rt_pre_exec_info = .init(&config),
        .rt_post_fork_info = .init(&config),
    });
    env_owned = false;
    errdefer exec.deinit();
    const label = if (profile) |value| try alloc.dupe(u8, value) else null;
    errdefer if (label) |value| alloc.free(value);
    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .config = config,
        .profile_name = label,
        .font_size = font_size,
        .surface_id = id,
        .destination = destination,
        .thread_id = window.app.thread_id,
        .mux = mux,
        .exec = exec,
    };
    return self;
}

/// A direct-shell request behind earlier work still participates in FIFO.
/// No broker or worker is needed; publication owns the config until its turn.
pub fn createDirect(window: *Window, destination: Destination, config: Config, profile: ?[]const u8, font_size: ?@import("../../font/main.zig").face.DesiredSize) !*Self {
    const alloc = window.app.core_app.alloc;
    const label = if (profile) |value| try alloc.dupe(u8, value) else null;
    errdefer if (label) |value| alloc.free(value);
    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .config = config,
        .profile_name = label,
        .font_size = font_size,
        .surface_id = CoreSurface.newId(),
        .destination = destination,
        .thread_id = window.app.thread_id,
        .mux = null,
        .exec = null,
        .done = .init(true),
    };
    return self;
}

/// Keep the session identity on every timing event so concurrent requests can
/// be matched without treating another pane's readiness as this one's result.
pub fn mark(self: *const Self, comptime phase: enum { queued, returned, prepared, published }, name: []const u8) void {
    const label = switch (self.destination) {
        .tab => switch (phase) {
            .queued => "mux-tab-queued",
            .returned => "new-tab-request-returned",
            .prepared => "mux-tab-prepared",
            .published => "mux-tab-published",
        },
        .split => switch (phase) {
            .queued => "mux-split-queued",
            .returned => "new-split-request-returned",
            .prepared => "mux-split-prepared",
            .published => "mux-split-published",
        },
    };
    perf.markContext(label, name);
}

pub fn start(self: *Self) !void {
    if (self.mux == null) return;
    self.thread = try std.Thread.spawn(@import("../../os/windows.zig").worker_thread_config, run, .{self});
}

pub fn cancel(self: *Self) void {
    if (self.mux) |mux| _ = SetEvent(mux.stop);
}

pub fn destroy(self: *Self) void {
    self.cancel();
    if (self.thread) |thread| thread.join();
    if (self.exec) |*exec| exec.deinit();
    if (self.mux) |mux| mux.deinit();
    self.config.deinit();
    if (self.profile_name) |name| self.alloc.free(name);
    self.alloc.destroy(self);
}

/// UI only, after observing done; Surface.init takes ownership on every path.
pub fn takeMux(self: *Self) ?*Mux {
    std.debug.assert(self.done.load(.acquire));
    const mux = self.mux;
    self.mux = null;
    return mux;
}

fn run(self: *Self) void {
    const mux = self.mux.?;
    mux.connectNew(&self.exec.?) catch |err| {
        mux.init_error = err;
        mux.disconnected.store(true, .release);
    };
    self.exec.?.deinit();
    self.exec = null;
    self.mark(.prepared, mux.name);
    self.done.store(true, .release);
    // Post a thread wakeup, never a pointer-bearing message to an HWND which
    // could have been destroyed/reused. Window destruction joins this worker.
    _ = w.PostThreadMessageW(self.thread_id, w.WM_NULL, 0, 0);
}
