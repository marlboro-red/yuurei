/// Win32 apprt App. Skeleton: satisfies the comptime apprt interface
/// (see gtk/App.zig for the reference shape); the actual message loop,
/// window class registration, and action handling land with Phase 2
/// of WINDOWS_PORT_PLAN.md.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");

const log = std.log.scoped(.win32);

/// The core app instance we're connected to.
core_app: *CoreApp,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but unused here.
    opts: struct {},
) !void {
    _ = opts;
    self.* = .{ .core_app = core_app };
}

pub fn run(self: *App) !void {
    _ = self;
    @panic("TODO: windows: win32 apprt message loop");
}

pub fn terminate(self: *App) void {
    _ = self;
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(self: *App) void {
    _ = self;
    @panic("TODO: windows: PostThreadMessageW wakeup");
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;
    log.warn("unimplemented action={s}", .{@tagName(action)});
    @panic("TODO: windows: performAction");
}

/// Send the given IPC to a running Ghostty. There is no IPC mechanism
/// for the win32 apprt yet, so this reports "not performed" — the same
/// honest non-answer the `none` runtime gives.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}
