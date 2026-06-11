/// Win32 apprt Surface. Skeleton: satisfies the comptime apprt interface
/// (see gtk/Surface.zig for the reference shape). The real HWND, WGL
/// context hosting, input, and clipboard land with Phases 2–3 of
/// WINDOWS_PORT_PLAN.md.
const Self = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");

/// The app we're part of.
app: *App,

/// The core surface backing this one.
core_surface: *CoreSurface,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface;
}

pub fn rtApp(self: *Self) *App {
    return self.app;
}

pub fn close(self: *Self, process_active: bool) void {
    _ = self;
    _ = process_active;
    @panic("TODO: windows: surface close");
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    _ = self;
    @panic("TODO: windows: window title");
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    _ = self;
    @panic("TODO: windows: GetDpiForWindow content scale");
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    _ = self;
    @panic("TODO: windows: client rect size");
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    _ = self;
    @panic("TODO: windows: cursor pos");
}

pub fn supportsClipboard(
    self: *const Self,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = state;
    @panic("TODO: windows: clipboard read");
}

pub fn setClipboard(
    self: *Self,
    val: apprt.ClipboardContent,
    clipboard_type: apprt.Clipboard,
    confirmed: bool,
) !void {
    _ = self;
    _ = val;
    _ = clipboard_type;
    _ = confirmed;
    @panic("TODO: windows: clipboard write");
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    _ = self;
    @panic("TODO: windows: default termio env");
}
