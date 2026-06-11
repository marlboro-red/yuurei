/// Win32 apprt Surface: one top-level window per surface, hosting the
/// OpenGL renderer through a WGL context. Modeled on the deleted GLFW
/// apprt (the historical minimal runtime; see fb9c52ecf~1) adapted to
/// raw Win32. Phase 2 of WINDOWS_PORT_PLAN.md: deliberately crude where
/// crude is honest — no IME, no AltGr discrimination, no dead keys, no
/// custom frame yet. Those land in Phase 3 with the regression checklist.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty");

/// The class for the GL host child window. The terminal renders into
/// this child rather than the top-level window so the parent can later
/// own GDI-painted chrome (tab strip, caption buttons) that the GL
/// swap chain can't stomp.
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

/// The core surface backing this one.
core_surface: CoreSurface,

/// Win32 window and GL state. `hwnd` is the top-level window; `host`
/// is the disabled child the OpenGL context renders into (see
/// host_class_name for why), and `hdc` is the host's DC.
hwnd: winapi.HWND,
host: winapi.HWND,
hdc: winapi.HDC,
gl_context: winapi.HGLRC,

/// Flagged by WM_CLOSE; the App run loop performs the actual close
/// outside of the window procedure to avoid freeing the surface while
/// a message for it is still on the stack.
should_close: bool = false,

/// Title storage so getTitle can return stable memory.
title_text: ?[:0]const u8 = null,

/// The key event from the last WM_KEYDOWN that the core did not consume.
/// WM_CHAR (which TranslateMessage posts right after) completes it with
/// the layout-cooked UTF-8 text and resubmits. Mirrors the GLFW apprt's
/// key/char callback pairing.
pending_key_event: ?input.KeyEvent = null,

/// Buffer backing pending_key_event.utf8 across the KEYDOWN→CHAR pair.
utf8_buf: [4]u8 = undefined,

/// Pending high surrogate from WM_CHAR, awaiting its low half.
high_surrogate: ?u16 = null,

/// The cursor for the client area, set by the core's mouse_shape
/// action and applied on WM_SETCURSOR. System cursors are shared
/// objects and are never destroyed.
cursor: ?winapi.HCURSOR = null,

/// Timer id used to keep the core app ticking while the window is in
/// a DefWindowProc modal loop (interactive move/resize), during which
/// App.run's message loop never regains control.
const modal_tick_timer_id: usize = 1;

pub fn init(self: *Self, app: *App) !void {
    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        winapi.WS_OVERLAPPEDWINDOW,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);

    // The GL host child fills the client area. Destroying the parent
    // destroys it, so no errdefer of its own.
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(hwnd, &client);
    const host = winapi.CreateWindowExW(
        0,
        host_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD | winapi.WS_VISIBLE | winapi.WS_DISABLED,
        0,
        0,
        client.right - client.left,
        client.bottom - client.top,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

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

    self.* = .{
        .app = app,
        .core_surface = undefined,
        .hwnd = hwnd,
        .host = host,
        .hdc = hdc,
        .gl_context = gl_context,
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

    // Only now wire the window procedure to us and show the window:
    // ShowWindow synchronously dispatches messages (WM_SETFOCUS,
    // WM_SIZE, ...) that call into core_surface, which must be
    // initialized first.
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );
    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);

    // Report the OS theme so `window-theme = auto` and conditional
    // config (light/dark) work. Changes arrive via WM_SETTINGCHANGE.
    self.notifyColorScheme();
}

/// Move the IME composition point to the terminal cursor cell so
/// candidate windows pop up next to where text is being typed.
fn imePositionWindow(self: *Self) void {
    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    const pos = self.core_surface.imePoint();
    _ = winapi.ImmSetCompositionWindow(himc, &.{
        .dwStyle = winapi.CFS_POINT,
        .ptCurrentPos = .{
            .x = @intFromFloat(@max(0, pos.x)),
            .y = @intFromFloat(@max(0, pos.y)),
        },
        .rcArea = std.mem.zeroes(winapi.RECT),
    });
}

/// Handle WM_IME_COMPOSITION: result text commits to the terminal as a
/// key event; composition text becomes inline preedit. Both can be
/// present in one message (commit + start of the next composition).
fn imeComposition(self: *Self, lparam: winapi.LPARAM) void {
    const flags: winapi.DWORD = @truncate(@as(usize, @bitCast(lparam)));
    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    const alloc = self.core_surface.alloc;

    if (flags & winapi.GCS_RESULTSTR != 0) result: {
        const text = imeGetString(alloc, himc, winapi.GCS_RESULTSTR) orelse
            break :result;
        defer alloc.free(text);

        // Clear the preedit before committing so the committed text
        // doesn't render on top of a stale preedit.
        self.core_surface.preeditCallback(null) catch {};

        const key_event: input.KeyEvent = .{
            .action = .press,
            .key = .unidentified,
            .utf8 = text,
        };
        _ = self.core_surface.keyCallback(key_event) catch |err| {
            log.err("error in key callback err={}", .{err});
        };
    }

    if (flags & winapi.GCS_COMPSTR != 0) comp: {
        const text = imeGetString(alloc, himc, winapi.GCS_COMPSTR) orelse
            break :comp;
        defer alloc.free(text);

        self.core_surface.preeditCallback(
            if (text.len > 0) text else null,
        ) catch |err| {
            log.err("error in preedit callback err={}", .{err});
        };
    }

    // Keep the composition UI tracking the cursor as text flows.
    self.imePositionWindow();
}

/// Read an IME composition string as freshly-allocated UTF-8, or null
/// if it is empty or unavailable.
fn imeGetString(
    alloc: Allocator,
    himc: winapi.HIMC,
    index: winapi.DWORD,
) ?[]const u8 {
    const bytes = winapi.ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;

    const wide = alloc.alloc(u16, @intCast(@divExact(bytes, 2))) catch return null;
    defer alloc.free(wide);
    _ = winapi.ImmGetCompositionStringW(
        himc,
        index,
        wide.ptr,
        @intCast(bytes),
    );

    return std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch null;
}

/// Read the OS theme and forward it to the core surface. Also keeps
/// the title bar matched: DWM immersive dark mode follows the apps
/// theme rather than defaulting to a white caption.
fn notifyColorScheme(self: *Self) void {
    const light = winapi.appsUseLightTheme();

    const dark_titlebar: winapi.BOOL = if (light) winapi.FALSE else winapi.TRUE;
    _ = winapi.DwmSetWindowAttribute(
        self.hwnd,
        winapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark_titlebar,
        @sizeOf(winapi.BOOL),
    );

    const scheme: apprt.ColorScheme = if (light) .light else .dark;
    self.core_surface.colorSchemeCallback(scheme) catch |err| {
        log.err("error in color scheme callback err={}", .{err});
    };
}

pub fn deinit(self: *Self) void {
    if (self.title_text) |t| self.core_surface.alloc.free(t);

    // Remove ourselves from the list of known surfaces in the app.
    self.app.core_app.deleteSurface(self);

    // Clean up our core surface so that all the rendering and IO stop.
    // This must happen before the GL context is destroyed because the
    // renderer thread holds it current.
    self.core_surface.deinit();

    _ = winapi.wglDeleteContext(self.gl_context);
    _ = winapi.ReleaseDC(self.host, self.hdc);

    // Detach the window proc user data before destroying so any
    // stray messages during destruction don't reach freed memory.
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
}

pub fn core(self: *Self) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Self) *App {
    return self.app;
}

/// Close this surface (called by core and by the App run loop for
/// surfaces flagged by WM_CLOSE).
pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
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

    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], slice) catch return;
    buf[len] = 0;
    _ = winapi.SetWindowTextW(self.hwnd, buf[0..len :0]);
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.hwnd));
    const scale = dpi / 96.0;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    var rect: winapi.RECT = undefined;
    if (winapi.GetClientRect(self.hwnd, &rect) == 0) return error.GetClientRectFailed;
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    var pt: winapi.POINT = undefined;
    if (winapi.GetCursorPos(&pt) == 0) return error.GetCursorPosFailed;
    if (winapi.ScreenToClient(self.hwnd, &pt) == 0) return error.ScreenToClientFailed;
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
    // like the GLFW apprt did. Always "unsafe" (no confirmation UI yet).
    const alloc = self.core_surface.alloc;
    const text: [:0]const u8 = text: {
        if (winapi.OpenClipboard(self.hwnd) == 0) break :text "";
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

    try self.core_surface.completeClipboardRequest(state, text, true);
    return true;
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;
    switch (clipboard_type) {
        .standard => {},
        .selection, .primary => return,
    }

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

        if (winapi.OpenClipboard(self.hwnd) == 0) break :copy;
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
        winapi.GetDpiForWindow(self.hwnd),
    );
    _ = winapi.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE | winapi.SWP_NOMOVE,
    );
}

/// Set the mouse cursor shape for the client area. Unmapped shapes
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
    // Apply immediately; otherwise it only takes effect on the next
    // WM_SETCURSOR (i.e. next mouse move).
    _ = winapi.SetCursor(cursor);
}

// ---------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    const self: *Self = self: {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :self @ptrFromInt(@as(usize, @bitCast(ptr)));
    };

    switch (msg) {
        winapi.WM_CLOSE => {
            // Defer the actual close to the App run loop: destroying
            // ourselves while our own message is being dispatched would
            // free memory still on the stack.
            self.should_close = true;
            return 0;
        },

        winapi.WM_ERASEBKGND => return 1,

        winapi.WM_SETCURSOR => {
            const hit: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (hit == winapi.HTCLIENT) {
                if (self.cursor) |cursor| {
                    _ = winapi.SetCursor(cursor);
                    return 1;
                }
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_PAINT => {
            _ = winapi.ValidateRect(hwnd, null);
            self.core_surface.refreshCallback() catch |err| {
                log.err("error in refresh callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_SIZE => {
            const size = self.getSize() catch |err| {
                log.err("error querying window size err={}", .{err});
                return 0;
            };

            // Keep the GL host child covering the client area.
            _ = winapi.SetWindowPos(
                self.host,
                null,
                0,
                0,
                @intCast(size.width),
                @intCast(size.height),
                winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
            );

            self.core_surface.sizeCallback(size) catch |err| {
                log.err("error in size callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_SETFOCUS, winapi.WM_KILLFOCUS => {
            self.core_surface.focusCallback(msg == winapi.WM_SETFOCUS) catch |err| {
                log.err("error in focus callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_KEYDOWN,
        winapi.WM_KEYUP,
        winapi.WM_SYSKEYDOWN,
        winapi.WM_SYSKEYUP,
        => {
            self.keyEvent(msg, wparam, lparam);
            // Returning 0 for handled keys; we still let DefWindowProc
            // see syskeys so alt+f4 and friends keep working.
            if (msg == winapi.WM_SYSKEYDOWN or msg == winapi.WM_SYSKEYUP)
                return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

        winapi.WM_CHAR => {
            self.charEvent(@truncate(wparam));
            return 0;
        },

        winapi.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
            self.core_surface.scrollCallback(0, yoff * 3, .{}) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            self.core_surface.cursorPosCallback(.{
                .x = @floatFromInt(lparamX(lparam)),
                .y = @floatFromInt(lparamY(lparam)),
            }, currentMods()) catch |err| {
                log.err("error in cursor pos callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_LBUTTONDOWN,
        winapi.WM_LBUTTONUP,
        winapi.WM_RBUTTONDOWN,
        winapi.WM_RBUTTONUP,
        winapi.WM_MBUTTONDOWN,
        winapi.WM_MBUTTONUP,
        => {
            const button: input.MouseButton = switch (msg) {
                winapi.WM_LBUTTONDOWN, winapi.WM_LBUTTONUP => .left,
                winapi.WM_RBUTTONDOWN, winapi.WM_RBUTTONUP => .right,
                else => .middle,
            };
            const state: input.MouseButtonState = switch (msg) {
                winapi.WM_LBUTTONDOWN,
                winapi.WM_RBUTTONDOWN,
                winapi.WM_MBUTTONDOWN,
                => .press,
                else => .release,
            };

            // Capture the mouse while a button is held so drag-selection
            // keeps receiving WM_MOUSEMOVE outside the client area.
            switch (state) {
                .press => _ = winapi.SetCapture(hwnd),
                .release => _ = winapi.ReleaseCapture(),
            }

            _ = self.core_surface.mouseButtonCallback(
                state,
                button,
                currentMods(),
            ) catch |err| {
                log.err("error in mouse button callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_DPICHANGED => {
            // wParam carries the new DPI; lParam points at the suggested
            // new window rect, which we must apply ourselves (PMv2).
            const suggested: *const winapi.RECT = @ptrFromInt(
                @as(usize, @bitCast(lparam)),
            );
            _ = winapi.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
            );

            const dpi: f32 = @floatFromInt(wparam & 0xFFFF);
            const scale = dpi / 96.0;
            self.core_surface.contentScaleCallback(.{
                .x = scale,
                .y = scale,
            }) catch |err| {
                log.err("error in content scale callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_ENTERSIZEMOVE => {
            // Interactive move/resize runs a modal loop inside
            // DefWindowProc; tick the core app from a timer so
            // actions and IO keep flowing during the drag.
            _ = winapi.SetTimer(hwnd, modal_tick_timer_id, 16, null);
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_EXITSIZEMOVE => {
            _ = winapi.KillTimer(hwnd, modal_tick_timer_id);
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_TIMER => {
            if (wparam == modal_tick_timer_id) {
                self.app.core_app.tick(self.app) catch |err| {
                    log.err("error ticking app from modal loop err={}", .{err});
                };
                return 0;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_SETTINGCHANGE => {
            // Fires for many settings; re-reading the theme is cheap
            // and colorSchemeCallback de-dupes unchanged values.
            self.notifyColorScheme();
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_IME_STARTCOMPOSITION => {
            // Position the (suppressed) composition/candidate UI at the
            // terminal cursor cell. Returning without DefWindowProc
            // keeps the IME's own composition window hidden; preedit
            // renders inline via preeditCallback instead.
            self.imePositionWindow();
            return 0;
        },

        winapi.WM_IME_COMPOSITION => {
            self.imeComposition(lparam);
            return 0;
        },

        winapi.WM_IME_ENDCOMPOSITION => {
            self.core_surface.preeditCallback(null) catch |err| {
                log.err("error in preedit callback err={}", .{err});
            };
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // TODO: windows: TSF escalation if imm32 has CJK edge cases,
        // drag and drop. Phase 3 with the REVIEW.md regression checklist.

        else => {},
    }

    return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Handle WM_KEYDOWN/WM_KEYUP/WM_SYSKEYDOWN/WM_SYSKEYUP. Submits a key
/// event without text; if the core leaves it unconsumed we stash it so
/// the WM_CHAR that TranslateMessage queued right behind us can complete
/// it with the layout-cooked text. This mirrors the GLFW apprt pairing
/// and is the documented TranslateMessage-ordering trap from the plan.
fn keyEvent(
    self: *Self,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) void {
    const vk: u8 = @truncate(wparam);
    const released = msg == winapi.WM_KEYUP or msg == winapi.WM_SYSKEYUP;
    const was_down = (lparam & (1 << 30)) != 0;

    const action: input.Action = if (released)
        .release
    else if (was_down)
        .repeat
    else
        .press;

    // TODO: windows: AltGr discrimination (lParam bit 24 + scancode);
    // for now AltGr reports as ctrl+alt which over-triggers keybinds on
    // some European layouts. Honest known limitation for the skeleton.
    const mods = currentMods();

    // The unshifted codepoint of the key in the current layout. Keybind
    // triggers match on this (e.g. ctrl+shift+c), so without it only
    // physical-key triggers would ever fire. The high bit of the result
    // flags a dead key; VK_TO_CHAR reports letters uppercase.
    const unshifted: u21 = unshifted: {
        const raw = winapi.MapVirtualKeyW(vk, winapi.MAPVK_VK_TO_CHAR);
        if (raw == 0 or (raw & 0x80000000) != 0) break :unshifted 0;
        const cp: u21 = @intCast(raw & 0x001FFFFF);
        break :unshifted if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
    };

    const key_event: input.KeyEvent = .{
        .action = action,
        .key = vkToKey(vk, lparam),
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = "",
        .unshifted_codepoint = unshifted,
    };

    const effect = self.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };

    // Surface closed.
    if (effect == .closed) return;

    // If it wasn't consumed, stash it so WM_CHAR can complete it with
    // text. If it WAS consumed we must swallow the queued WM_CHAR —
    // pending_key_event == null does exactly that in charEvent.
    self.pending_key_event = null;
    if (effect == .ignored and (action == .press or action == .repeat)) {
        self.pending_key_event = key_event;
    }
}

/// Handle WM_CHAR: complete the pending key event with cooked text.
fn charEvent(self: *Self, unit: u16) void {
    // UTF-16 surrogate pair reassembly across two WM_CHAR messages.
    const codepoint: u21 = codepoint: {
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.high_surrogate = unit;
            return;
        }
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            const high = self.high_surrogate orelse return;
            self.high_surrogate = null;
            break :codepoint 0x10000 +
                (@as(u21, high - 0xD800) << 10) +
                (unit - 0xDC00);
        }
        self.high_surrogate = null;
        break :codepoint unit;
    };

    // A consumed keydown means this char must be swallowed (the
    // TranslateMessage trap).
    var key_event = self.pending_key_event orelse return;
    self.pending_key_event = null;

    const len = std.unicode.utf8Encode(codepoint, &self.utf8_buf) catch |err| {
        log.err("error encoding codepoint={} err={}", .{ codepoint, err });
        return;
    };
    key_event.utf8 = self.utf8_buf[0..len];
    // The keydown already derived the unshifted codepoint from the
    // layout; only fall back to the cooked char if it didn't.
    if (key_event.unshifted_codepoint == 0 and
        codepoint < 0x80 and !key_event.mods.shift)
    {
        key_event.unshifted_codepoint = codepoint;
    }

    _ = self.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
    };
}

/// The currently held modifiers. GetKeyState reflects the state as of
/// the message being processed, which is what core wants.
fn currentMods() input.Mods {
    return .{
        .shift = winapi.GetKeyState(winapi.VK_SHIFT) < 0,
        .ctrl = winapi.GetKeyState(winapi.VK_CONTROL) < 0,
        .alt = winapi.GetKeyState(winapi.VK_MENU) < 0,
        .super = winapi.GetKeyState(winapi.VK_LWIN) < 0 or
            winapi.GetKeyState(winapi.VK_RWIN) < 0,
    };
}

/// X/Y client coordinates from a mouse message lParam. These are signed:
/// with mouse capture held they go negative outside the client area.
fn lparamX(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}

/// US-centric VK→Key map: enough for keybinds on physical keys.
/// Layout-aware matching happens via the UTF-8 text, which comes from
/// WM_CHAR and is always correct. Left/right modifier discrimination
/// uses the extended-key bit (lParam bit 24) and the right-shift
/// scancode, since WM_KEYDOWN only carries the generic VK.
fn vkToKey(vk: u8, lparam: winapi.LPARAM) input.Key {
    const extended = (lparam & (1 << 24)) != 0;
    const scancode: u8 = @truncate(@as(usize, @bitCast(lparam)) >> 16);
    return switch (vk) {
        'A'...'Z' => |c| @enumFromInt(
            @intFromEnum(input.Key.key_a) + (c - 'A'),
        ),
        '0'...'9' => |c| @enumFromInt(
            @intFromEnum(input.Key.digit_0) + (c - '0'),
        ),
        winapi.VK_F1...winapi.VK_F1 + 23 => |c| @enumFromInt(
            @intFromEnum(input.Key.f1) + (c - winapi.VK_F1),
        ),
        winapi.VK_NUMPAD0...winapi.VK_NUMPAD0 + 9 => |c| @enumFromInt(
            @intFromEnum(input.Key.numpad_0) + (c - winapi.VK_NUMPAD0),
        ),
        winapi.VK_RETURN => if (extended) .numpad_enter else .enter,
        winapi.VK_BACK => .backspace,
        winapi.VK_TAB => .tab,
        winapi.VK_ESCAPE => .escape,
        winapi.VK_SPACE => .space,
        winapi.VK_PRIOR => .page_up,
        winapi.VK_NEXT => .page_down,
        winapi.VK_END => .end,
        winapi.VK_HOME => .home,
        winapi.VK_LEFT => .arrow_left,
        winapi.VK_UP => .arrow_up,
        winapi.VK_RIGHT => .arrow_right,
        winapi.VK_DOWN => .arrow_down,
        winapi.VK_INSERT => .insert,
        winapi.VK_DELETE => .delete,
        // Right shift has scancode 0x36; the extended bit is not set
        // for shift so the scancode is the only discriminator.
        winapi.VK_SHIFT => if (scancode == 0x36) .shift_right else .shift_left,
        winapi.VK_CONTROL => if (extended) .control_right else .control_left,
        winapi.VK_MENU => if (extended) .alt_right else .alt_left,
        winapi.VK_LWIN => .meta_left,
        winapi.VK_RWIN => .meta_right,
        winapi.VK_APPS => .context_menu,
        winapi.VK_CAPITAL => .caps_lock,
        winapi.VK_NUMLOCK => .num_lock,
        winapi.VK_SCROLL => .scroll_lock,
        winapi.VK_SNAPSHOT => .print_screen,
        winapi.VK_PAUSE => .pause,
        winapi.VK_MULTIPLY => .numpad_multiply,
        winapi.VK_ADD => .numpad_add,
        winapi.VK_SUBTRACT => .numpad_subtract,
        winapi.VK_DECIMAL => .numpad_decimal,
        winapi.VK_DIVIDE => .numpad_divide,
        winapi.VK_OEM_1 => .semicolon,
        winapi.VK_OEM_PLUS => .equal,
        winapi.VK_OEM_COMMA => .comma,
        winapi.VK_OEM_MINUS => .minus,
        winapi.VK_OEM_PERIOD => .period,
        winapi.VK_OEM_2 => .slash,
        winapi.VK_OEM_3 => .backquote,
        winapi.VK_OEM_4 => .bracket_left,
        winapi.VK_OEM_5 => .backslash,
        winapi.VK_OEM_6 => .bracket_right,
        winapi.VK_OEM_7 => .quote,
        else => .unidentified,
    };
}
