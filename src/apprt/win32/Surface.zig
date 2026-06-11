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
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty");

/// The app we're part of.
app: *App,

/// The core surface backing this one.
core_surface: CoreSurface,

/// Win32 window and GL state.
hwnd: winapi.HWND,
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

    // CS_OWNDC on the class means this DC is ours for the window's
    // lifetime and is what WGL renders into.
    const hdc = winapi.GetDC(hwnd) orelse return error.GetDCFailed;

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
    _ = winapi.ReleaseDC(self.hwnd, self.hdc);

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

        // TODO: windows: mouse buttons/motion (selection), WM_DPICHANGED,
        // WM_IME_* (imm32), drag and drop. Phase 3 with the REVIEW.md
        // regression checklist.

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
    const mods: input.Mods = .{
        .shift = winapi.GetKeyState(winapi.VK_SHIFT) < 0,
        .ctrl = winapi.GetKeyState(winapi.VK_CONTROL) < 0,
        .alt = winapi.GetKeyState(winapi.VK_MENU) < 0,
        .super = winapi.GetKeyState(winapi.VK_LWIN) < 0 or
            winapi.GetKeyState(winapi.VK_RWIN) < 0,
    };

    const key_event: input.KeyEvent = .{
        .action = action,
        .key = vkToKey(vk),
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = "",
        .unshifted_codepoint = 0,
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
    if (codepoint < 0x80 and !key_event.mods.shift) {
        key_event.unshifted_codepoint = codepoint;
    }

    _ = self.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
    };
}

/// Crude US-centric VK→Key map for the skeleton: enough for keybinds on
/// the keys that matter. Layout-aware matching happens via the UTF-8
/// text, which comes from WM_CHAR and is always correct.
fn vkToKey(vk: u8) input.Key {
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
        winapi.VK_RETURN => .enter,
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
        winapi.VK_SHIFT => .shift_left,
        winapi.VK_CONTROL => .control_left,
        winapi.VK_MENU => .alt_left,
        winapi.VK_LWIN => .meta_left,
        winapi.VK_RWIN => .meta_right,
        else => .unidentified,
    };
}
