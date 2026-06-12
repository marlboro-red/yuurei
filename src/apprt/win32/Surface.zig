/// Win32 apprt Surface: one terminal tab. Owns the GL host child
/// window, the WGL context, and the core surface; the containing
/// Window (Window.zig) owns the top-level window, chrome, and input
/// routing.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The class for the GL host child window. The terminal renders into
/// this child rather than the top-level window so the parent can own
/// GDI-painted chrome (tab strip, caption buttons) that the GL swap
/// chain can't stomp.
pub const host_class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-host");

/// Window procedure for the GL host child. It renders nothing itself
/// (the renderer thread owns its pixels) and, being disabled, passes
/// mouse input through to the parent.
pub fn hostWndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    switch (msg) {
        winapi.WM_ERASEBKGND => return 1,
        winapi.WM_PAINT => {
            _ = winapi.ValidateRect(hwnd, null);
            return 0;
        },
        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The app we're part of.
app: *App,

/// The window (tab container) we belong to.
window: *Window,

/// The core surface backing this tab.
core_surface: CoreSurface,

/// The GL host child and its GL state.
host: winapi.HWND,
hdc: winapi.HDC,
gl_context: winapi.HGLRC,

/// Native vertical scrollbar beside the host, fed by the core's
/// `scrollbar` action; WM_VSCROLL on the parent scrolls the terminal.
scrollbar: ?winapi.HWND = null,

/// Flagged for close; the App run loop performs the actual teardown.
should_close: bool = false,

/// Title storage; doubles as the tab label.
title_text: ?[:0]const u8 = null,

/// The terminal-area cursor, set by the mouse_shape action and applied
/// by the Window on WM_SETCURSOR. System cursors are shared objects
/// and are never destroyed.
cursor: ?winapi.HCURSOR = null,

/// The inspector window for this surface while one is open. It is
/// owned by us: closed (and the core inspector deactivated) on deinit.
inspector: ?*InspectorWindow = null,

/// Reference count, owned by the split trees that contain this
/// surface (and transiently by tree operations). The surface
/// deinitializes and frees itself when it reaches zero.
refs: u32 = 1,

/// Increase the reference count (SplitTree view contract).
pub fn ref(self: *Self) *Self {
    self.refs += 1;
    return self;
}

/// Decrease the reference count, destroying the surface at zero
/// (SplitTree view contract).
pub fn unref(self: *Self, alloc: Allocator) void {
    self.refs -= 1;
    if (self.refs == 0) {
        self.deinit();
        alloc.destroy(self);
    }
}

pub fn init(self: *Self, app: *App, window: *Window) !void {
    // The GL host child fills the client area below the title strip.
    // It is created hidden; activateTab shows the active one.
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(window.hwnd, &client);
    const strip = window.titlebarHeight();
    const host = winapi.CreateWindowExW(
        0,
        host_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD | winapi.WS_DISABLED,
        0,
        strip,
        client.right - client.left,
        @max(0, client.bottom - client.top - strip),
        window.hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(host);

    // CS_OWNDC on the class means this DC is ours for the window's
    // lifetime and is what WGL renders into.
    const hdc = winapi.GetDC(host) orelse return error.GetDCFailed;

    // A boring double-buffered RGBA format. No depth/stencil: the
    // renderer draws textured quads back-to-front.
    const pfd: winapi.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = winapi.PFD_DRAW_TO_WINDOW |
            winapi.PFD_SUPPORT_OPENGL |
            winapi.PFD_DOUBLEBUFFER,
        .iPixelType = winapi.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
    };
    const format = winapi.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return error.ChoosePixelFormatFailed;
    if (winapi.SetPixelFormat(hdc, format, &pfd) == 0)
        return error.SetPixelFormatFailed;

    // Legacy context creation: gives us the highest compatibility
    // profile the driver supports, which comfortably covers our GL 4.3
    // requirement on the drivers we care about. TODO: windows: use
    // wglCreateContextAttribsARB for an explicit core profile.
    const gl_context = winapi.wglCreateContext(hdc) orelse
        return error.CreateGLContextFailed;
    errdefer _ = winapi.wglDeleteContext(gl_context);

    // The scrollbar is a sibling of the host (the host is disabled, so
    // it can't parent interactive children). Created hidden like the
    // host; setVisible and layoutActiveTab manage it. Failure is
    // cosmetic-only.
    const scrollbar = winapi.CreateWindowExW(
        0,
        winapi.scrollbar_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD | winapi.SBS_VERT,
        0,
        0,
        0,
        0,
        window.hwnd,
        null,
        app.hinstance,
        null,
    );

    self.* = .{
        .app = app,
        .window = window,
        .core_surface = undefined,
        .host = host,
        .hdc = hdc,
        .gl_context = gl_context,
        .scrollbar = scrollbar,
    };

    // Add ourselves to the list of surfaces on the app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Get our new surface config
    var config = try apprt.surface.newConfig(
        app.core_app,
        &app.config,
        .window,
    );
    defer config.deinit();

    // Initialize our surface now that we have the stable pointer.
    try self.core_surface.init(
        app.core_app.alloc,
        &config,
        app.core_app,
        app,
        self,
    );
    errdefer self.core_surface.deinit();
}

pub fn deinit(self: *Self) void {
    // The inspector window deactivates the core inspector, so it must
    // go before the core surface does.
    if (self.inspector) |inspector| inspector.destroy();

    if (self.title_text) |t| self.core_surface.alloc.free(t);

    // Remove ourselves from the list of known surfaces in the app.
    self.app.core_app.deleteSurface(self);

    // Clean up our core surface so that all the rendering and IO stop.
    // This must happen before the GL context is destroyed because the
    // renderer thread holds it current.
    self.core_surface.deinit();

    _ = winapi.wglDeleteContext(self.gl_context);
    _ = winapi.ReleaseDC(self.host, self.hdc);
    _ = winapi.DestroyWindow(self.host);
    if (self.scrollbar) |sb| _ = winapi.DestroyWindow(sb);
}

pub fn core(self: *Self) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Self) *App {
    return self.app;
}

/// Close this tab. The App run loop performs the actual teardown.
pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    self.should_close = true;
    self.app.wakeup();
}

/// Show or hide the GL host (tab activation).
pub fn setVisible(self: *Self, visible: bool) void {
    _ = winapi.ShowWindow(self.host, if (visible) 5 else 0); // SW_SHOW/SW_HIDE
    if (self.scrollbar) |sb| _ = winapi.ShowWindow(sb, if (visible) 5 else 0);
}

/// Feed core scrollbar state (rows) into the native control.
pub fn updateScrollbar(self: *Self, sb: terminal.Scrollbar) void {
    const hwnd = self.scrollbar orelse return;
    const si: winapi.SCROLLINFO = .{
        .fMask = winapi.SIF_RANGE | winapi.SIF_PAGE | winapi.SIF_POS,
        .nMin = 0,
        .nMax = @intCast(@max(1, sb.total) - 1),
        .nPage = @intCast(sb.len),
        .nPos = @intCast(sb.offset),
    };
    _ = winapi.SetScrollInfo(hwnd, winapi.SB_CTL, &si, winapi.TRUE);
}

// ---------------------------------------------------------------------
// GL context plumbing for renderer/OpenGL.zig's .win32 arms.

pub fn glMakeCurrent(self: *const Self) !void {
    if (winapi.wglMakeCurrent(self.hdc, self.gl_context) == 0)
        return error.MakeCurrentFailed;
}

pub fn glReleaseCurrent() void {
    _ = winapi.wglMakeCurrent(null, null);
}

// ---------------------------------------------------------------------
// apprt interface

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.title_text;
}

pub fn setTitle(self: *Self, slice: [:0]const u8) !void {
    const alloc = self.core_surface.alloc;
    if (self.title_text) |t| alloc.free(t);
    self.title_text = try alloc.dupeZ(u8, slice);

    // The strip repaints the tab label; the OS title follows the
    // active tab.
    if (self.window.activeSurface() == self) self.window.syncTitle();
    _ = winapi.InvalidateRect(self.window.hwnd, null, winapi.FALSE);
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.window.hwnd));
    const s = dpi / 96.0;
    return .{ .x = s, .y = s };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    // The terminal's surface is the GL host child, not the full client
    // area (the title strip is above it).
    var rect: winapi.RECT = undefined;
    if (winapi.GetClientRect(self.host, &rect) == 0) return error.GetClientRectFailed;
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    var pt: winapi.POINT = undefined;
    if (winapi.GetCursorPos(&pt) == 0) return error.GetCursorPosFailed;
    if (winapi.ScreenToClient(self.host, &pt) == 0) return error.ScreenToClientFailed;
    return .{
        .x = @floatFromInt(pt.x),
        .y = @floatFromInt(pt.y),
    };
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
) !bool {
    switch (clipboard_type) {
        .standard => {},
        // Windows has no selection clipboard; we said so in
        // supportsClipboard so this should not be reachable.
        .selection, .primary => return false,
    }

    // Read CF_UNICODETEXT and complete the request synchronously,
    // like the GLFW apprt did.
    const alloc = self.core_surface.alloc;
    const text: [:0]const u8 = text: {
        if (winapi.OpenClipboard(self.window.hwnd) == 0) break :text "";
        defer _ = winapi.CloseClipboard();

        const handle = winapi.GetClipboardData(winapi.CF_UNICODETEXT) orelse break :text "";
        const ptr = winapi.GlobalLock(handle) orelse break :text "";
        defer _ = winapi.GlobalUnlock(handle);

        const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        break :text std.unicode.utf16LeToUtf8AllocZ(
            alloc,
            std.mem.span(wide),
        ) catch break :text "";
    };
    defer if (text.len > 0) alloc.free(text);

    // First attempt unconfirmed: the core rejects content it considers
    // unsafe (control characters in a paste, OSC 52 reads needing
    // authorization) and we ask the user with a native dialog.
    self.core_surface.completeClipboardRequest(state, text, false) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const allowed = switch (err) {
                error.UnsafePaste => confirmDialog(
                    self.window.hwnd,
                    "The clipboard contains text that may be unsafe to " ++
                        "paste (it includes control characters that could " ++
                        "run commands). Paste anyway?",
                ),
                else => confirmDialog(
                    self.window.hwnd,
                    "The running program is requesting to read the " ++
                        "clipboard. Allow it?",
                ),
            };
            if (!allowed) return true;
            try self.core_surface.completeClipboardRequest(state, text, true);
        },

        else => return err,
    };
    return true;
}

/// A modal yes/no warning dialog. Returns true when the user accepts.
fn confirmDialog(hwnd: winapi.HWND, comptime message: []const u8) bool {
    return winapi.MessageBoxW(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(message),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        winapi.MB_YESNO | winapi.MB_ICONWARNING | winapi.MB_DEFBUTTON2,
    ) == winapi.IDYES;
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    switch (clipboard_type) {
        .standard => {},
        .selection, .primary => return,
    }

    // OSC 52 writes from the running program ask for confirmation.
    if (confirm and !confirmDialog(
        self.window.hwnd,
        "The running program wants to write to the clipboard. Allow it?",
    )) return;

    // We only support plain text on the clipboard.
    const text: [:0]const u8 = text: {
        for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain"))
                break :text content.data;
        }
        return;
    };

    // CF_UNICODETEXT wants UTF-16 in a GMEM_MOVEABLE global owned by
    // the clipboard after SetClipboardData succeeds.
    const alloc = self.core_surface.alloc;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(wide);

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const handle = winapi.GlobalAlloc(winapi.GMEM_MOVEABLE, bytes) orelse
        return error.OutOfMemory;
    copy: {
        const ptr = winapi.GlobalLock(handle) orelse break :copy;
        defer _ = winapi.GlobalUnlock(handle);
        const dst: [*]u16 = @ptrCast(@alignCast(ptr));
        @memcpy(dst[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);

        if (winapi.OpenClipboard(self.window.hwnd) == 0) break :copy;
        defer _ = winapi.CloseClipboard();
        _ = winapi.EmptyClipboard();
        if (winapi.SetClipboardData(winapi.CF_UNICODETEXT, handle) != null) {
            // Ownership transferred to the clipboard.
            return;
        }
    }

    _ = winapi.GlobalFree(handle);
    return error.SetClipboardFailed;
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    return try internal_os.getEnvMap(self.app.core_app.alloc);
}

/// Set the initial window size from config (window-width/height). The
/// values are a client-area size in grid-derived pixels; convert to a
/// full window size including the frame for the current DPI.
pub fn setInitialWindowSize(self: *const Self, width: u32, height: u32) !void {
    var rect: winapi.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @intCast(height),
    };
    _ = winapi.AdjustWindowRectExForDpi(
        &rect,
        winapi.WS_OVERLAPPEDWINDOW,
        winapi.FALSE,
        0,
        winapi.GetDpiForWindow(self.window.hwnd),
    );
    _ = winapi.SetWindowPos(
        self.window.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top + self.window.titlebarHeight(),
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE | winapi.SWP_NOMOVE,
    );
}

/// Set the mouse cursor shape for the terminal area. Unmapped shapes
/// keep the current cursor (the spec set is larger than the stock
/// Windows cursor set).
pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) !void {
    const id: u16 = switch (shape) {
        .default => winapi.IDC_ARROW,
        .text, .vertical_text => winapi.IDC_IBEAM,
        .crosshair, .cell => winapi.IDC_CROSS,
        .pointer => winapi.IDC_HAND,
        .help => winapi.IDC_HELP,
        .wait => winapi.IDC_WAIT,
        .progress => winapi.IDC_APPSTARTING,
        .ew_resize, .e_resize, .w_resize, .col_resize => winapi.IDC_SIZEWE,
        .ns_resize, .n_resize, .s_resize, .row_resize => winapi.IDC_SIZENS,
        .nwse_resize, .nw_resize, .se_resize => winapi.IDC_SIZENWSE,
        .nesw_resize, .ne_resize, .sw_resize => winapi.IDC_SIZENESW,
        .all_scroll, .move => winapi.IDC_SIZEALL,
        .not_allowed, .no_drop => winapi.IDC_NO,
        else => return,
    };

    const cursor = winapi.loadSystemCursor(id) orelse return;
    self.cursor = cursor;
    // Apply immediately when we're the active tab; otherwise it takes
    // effect on the next WM_SETCURSOR.
    if (self.window.activeSurface() == self) _ = winapi.SetCursor(cursor);
}
