/// Win32 apprt App: window class registration, the message loop, and
/// core-app action dispatch. Modeled on the deleted GLFW apprt's App
/// (fb9c52ecf~1), the historical minimal runtime.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The core app instance we're connected to.
core_app: *CoreApp,

/// Loaded configuration; surfaces snapshot from this at creation.
config: Config,

/// Module handle, used as the window class's hInstance.
hinstance: winapi.HINSTANCE,

/// The main (message loop) thread id, the wakeup target.
thread_id: winapi.DWORD,

/// Flips to true to quit on the next event loop tick.
quit: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but unused here.
    opts: struct {},
) !void {
    _ = opts;

    const module = std.os.windows.kernel32.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;
    const hinstance: winapi.HINSTANCE = @ptrCast(module);

    // One window class for all surfaces. CS_OWNDC gives every window a
    // private DC, which WGL requires for a long-lived rendering DC.
    const class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW | winapi.CS_OWNDC,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = hinstance,
        // Null background brush: the GL surface covers the client area
        // and a brush would only add flicker (WM_ERASEBKGND returns 1).
        .hbrBackground = null,
        .lpszClassName = Surface.class_name,
    };
    if (winapi.RegisterClassExW(&class) == 0) return error.RegisterClassFailed;

    // Load our configuration
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    // If we had configuration errors, then log them.
    if (!config._diagnostics.empty()) {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (config._diagnostics.items()) |diag| {
            writer.end = 0;
            diag.format(&writer) catch continue;
            log.warn("configuration error: {s}", .{writer.buffered()});
        }

        // If we have any CLI errors, exit.
        if (config._diagnostics.containsLocation(.cli)) {
            log.warn("CLI errors detected, exiting", .{});
            _ = core_app.mailbox.push(.{ .quit = {} }, .{ .forever = {} });
        }
    }

    // Queue a single new window that starts on launch.
    // Note: above we may send a quit so this may never happen.
    _ = core_app.mailbox.push(.{ .new_window = .{} }, .{ .forever = {} });

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .thread_id = std.os.windows.kernel32.GetCurrentThreadId(),
    };

    // Make sure the loop processes the queued message immediately.
    self.wakeup();
}

pub fn terminate(self: *App) void {
    self.config.deinit();
}

/// Run the event loop. This doesn't return until the app exits.
pub fn run(self: *App) !void {
    while (true) {
        // Block until at least one message arrives. wakeup() posts a
        // WM_NULL thread message so cross-thread ticks land here too.
        var msg: winapi.MSG = undefined;
        const result = winapi.GetMessageW(&msg, null, 0, 0);
        if (result == -1) return error.GetMessageFailed;
        if (result == 0) self.quit = true else {
            _ = winapi.TranslateMessage(&msg);
            _ = winapi.DispatchMessageW(&msg);
        }

        // Drain whatever else is queued before ticking so one tick
        // covers a burst of input.
        while (winapi.PeekMessageW(&msg, null, 0, 0, winapi.PM_REMOVE) != 0) {
            if (msg.message == winapi.WM_QUIT) {
                self.quit = true;
                continue;
            }
            _ = winapi.TranslateMessage(&msg);
            _ = winapi.DispatchMessageW(&msg);
        }

        // Tick the terminal app
        try self.core_app.tick(self);

        // Close any surfaces that WM_CLOSE flagged. This is done here,
        // not in the window procedure, so the surface memory isn't
        // freed while one of its own messages is on the stack.
        var i: usize = 0;
        while (i < self.core_app.surfaces.items.len) {
            const surface = self.core_app.surfaces.items[i];
            if (surface.should_close) surface.close(false) else i += 1;
        }

        // If the tick caused us to quit, then we're done. Close from
        // the front since each close removes the surface from the list.
        if (self.quit or self.core_app.surfaces.items.len == 0) {
            while (self.core_app.surfaces.items.len > 0) {
                self.core_app.surfaces.items[0].close(false);
            }
            return;
        }
    }
}

/// Wakeup the event loop. Callable from any thread.
pub fn wakeup(self: *const App) void {
    if (winapi.PostThreadMessageW(self.thread_id, winapi.WM_NULL, 0, 0) == 0) {
        // Benign: the queue can be full, in which case a tick is
        // already guaranteed to happen.
        log.debug("PostThreadMessageW for wakeup failed", .{});
    }
}

/// Perform a given action. Returns `true` if the action was able to be
/// performed, `false` otherwise.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit = true;
            self.wakeup();
        },

        .new_window => _ = try self.newSurface(switch (target) {
            .app => null,
            .surface => |v| v,
        }),

        .set_title => switch (target) {
            .app => {},
            .surface => |surface| try surface.rt_surface.setTitle(value.title),
        },

        .mouse_shape => switch (target) {
            .app => {},
            .surface => |surface| try surface.rt_surface.setMouseShape(value),
        },

        .initial_size => switch (target) {
            .app => {},
            .surface => |surface| try surface.rt_surface.setInitialWindowSize(
                value.width,
                value.height,
            ),
        },

        .reload_config => try self.reloadConfig(target, value),

        // Everything else is honestly unimplemented for the skeleton:
        // report "not performed" so the core can fall back or ignore.
        else => {
            log.info("unimplemented action={s}", .{@tagName(action)});
            return false;
        },
    }

    return true;
}

/// Reload the configuration; see the GLFW reference implementation.
fn reloadConfig(
    self: *App,
    target: apprt.action.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    if (opts.soft) {
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core_surface| try core_surface.updateConfig(
                &self.config,
            ),
        }
        return;
    }

    // Load our configuration
    var config = try Config.load(self.core_app.alloc);
    errdefer config.deinit();

    // Call into our app to update
    switch (target) {
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core_surface| try core_surface.updateConfig(&config),
    }

    // Update the existing config, be sure to clean up the old one.
    self.config.deinit();
    self.config = config;
}

fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
    // Grab a surface allocation because we're going to need it.
    var surface = try self.core_app.alloc.create(Surface);
    errdefer self.core_app.alloc.destroy(surface);

    // Create the surface -- because windows are surfaces for this apprt.
    try surface.init(self);
    errdefer surface.deinit();

    // If we have a parent, inherit some properties
    if (self.config.@"window-inherit-font-size") {
        if (parent_) |parent| {
            try surface.core_surface.setFontSize(parent.font_size);
        }
    }

    return surface;
}

/// Send the given IPC to a running Ghostty. There is no IPC mechanism
/// for the win32 apprt yet, so this reports "not performed".
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}
