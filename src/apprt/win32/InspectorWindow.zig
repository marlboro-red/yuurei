/// A top-level window hosting the Ghostty inspector (Dear ImGui) for
/// one surface, with its own WGL context rendered on the main thread
/// at ~30fps. Mirrors the GTK ImguiWidget/InspectorWidget pair.
const InspectorWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const gl = @import("opengl");
const Inspector = @import("../../inspector/Inspector.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The inspector window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-inspector");

/// ~30fps render timer.
const render_timer_id: usize = 1;

/// The surface being inspected. The surface owns us: it closes the
/// inspector window in its deinit, so this never dangles.
surface: *Surface,

/// Our window and GL state.
hwnd: winapi.HWND,
hdc: winapi.HDC,
gl_context: winapi.HGLRC,

/// Our Dear ImGui context (one per window, like GTK's per-widget).
ig_context: *cimgui.c.ImGuiContext,

/// Previous frame instant for ImGui's DeltaTime.
instant: ?std.time.Instant = null,

pub fn create(alloc: Allocator, surface: *Surface) !*InspectorWindow {
    const app = surface.app;

    // Activate the core inspector first; everything else is display.
    try surface.core_surface.activateInspector();
    errdefer surface.core_surface.deactivateInspector();

    const self = try alloc.create(InspectorWindow);
    errdefer alloc.destroy(self);

    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Inspector"),
        winapi.WS_OVERLAPPEDWINDOW,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        1000,
        700,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);

    // CS_OWNDC: the DC is ours for the window's lifetime.
    const hdc = winapi.GetDC(hwnd) orelse return error.GetDCFailed;

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

    const gl_context = winapi.wglCreateContext(hdc) orelse
        return error.CreateGLContextFailed;
    errdefer _ = winapi.wglDeleteContext(gl_context);

    if (winapi.wglMakeCurrent(hdc, gl_context) == 0)
        return error.MakeCurrentFailed;
    defer _ = winapi.wglMakeCurrent(null, null);

    const ig_context = cimgui.c.ImGui_CreateContext(null) orelse
        return error.ImguiContextFailed;
    errdefer cimgui.c.ImGui_DestroyContext(ig_context);
    cimgui.c.ImGui_SetCurrentContext(ig_context);

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.BackendPlatformName = "ghostty_win32";

    if (!cimgui.ImGui_ImplOpenGL3_Init(null))
        return error.ImguiBackendFailed;

    Inspector.setup();

    self.* = .{
        .surface = surface,
        .hwnd = hwnd,
        .hdc = hdc,
        .gl_context = gl_context,
        .ig_context = ig_context,
    };
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    self.updateDisplaySize();
    _ = winapi.SetTimer(hwnd, render_timer_id, 33, null);
    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);
    return self;
}

pub fn destroy(self: *InspectorWindow) void {
    const alloc = self.surface.app.core_app.alloc;
    self.surface.inspector = null;
    self.surface.core_surface.deactivateInspector();

    _ = winapi.KillTimer(self.hwnd, render_timer_id);
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);

    if (winapi.wglMakeCurrent(self.hdc, self.gl_context) != 0) {
        cimgui.c.ImGui_SetCurrentContext(self.ig_context);
        cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
        _ = winapi.wglMakeCurrent(null, null);
    }
    cimgui.c.ImGui_DestroyContext(self.ig_context);

    _ = winapi.wglDeleteContext(self.gl_context);
    _ = winapi.ReleaseDC(self.hwnd, self.hdc);
    _ = winapi.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// Set io.DisplaySize from the client rect and scale the style to the
/// window DPI.
fn updateDisplaySize(self: *InspectorWindow) void {
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    io.DisplaySize = .{
        .x = @floatFromInt(client.right - client.left),
        .y = @floatFromInt(client.bottom - client.top),
    };
    io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

    const dpi: f32 = @floatFromInt(winapi.GetDpiForWindow(self.hwnd));
    var style: cimgui.c.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(&style, dpi / 96.0);
    const active_style = cimgui.c.ImGui_GetStyle();
    active_style.* = style;

    // Scale the font as well so text tracks the DPI, not just chrome.
    io.FontGlobalScale = dpi / 96.0;
}

fn render(self: *InspectorWindow) void {
    if (winapi.wglMakeCurrent(self.hdc, self.gl_context) == 0) return;
    defer _ = winapi.wglMakeCurrent(null, null);
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

    // Render twice: some ImGui behaviors (docking) take two frames to
    // settle. Same workaround as the GTK widget.
    for (0..2) |_| {
        cimgui.ImGui_ImplOpenGL3_NewFrame();

        const now = std.time.Instant.now() catch unreachable;
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(now.since(prev));
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            break :delta @max(0.00001, @as(f32, @floatCast(since_ns / ns_per_s)));
        } else (1.0 / 60.0);
        self.instant = now;

        cimgui.c.ImGui_NewFrame();
        if (self.surface.core_surface.inspector) |inspector| {
            inspector.render(&self.surface.core_surface);
        }
        cimgui.c.ImGui_Render();
    }

    // The imgui GL3 backend leaves GL_SCISSOR_TEST enabled after
    // rendering, which would confine this clear to the last clip rect.
    gl.disable(gl.c.GL_SCISSOR_TEST) catch {};
    // Float division: 0x28 / 0xFF was comptime *integer* division
    // (== 0), which cleared to black instead of the intended #282C34.
    gl.clearColor(40.0 / 255.0, 44.0 / 255.0, 52.0 / 255.0, 1.0);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());

    _ = winapi.SwapBuffers(self.hdc);
}

/// Map a virtual key to the ImGui key, for the keys the inspector UI
/// meaningfully uses (text editing and navigation).
fn vkToImguiKey(vk: usize) ?c_int {
    return switch (vk) {
        winapi.VK_TAB => cimgui.c.ImGuiKey_Tab,
        winapi.VK_LEFT => cimgui.c.ImGuiKey_LeftArrow,
        winapi.VK_RIGHT => cimgui.c.ImGuiKey_RightArrow,
        winapi.VK_UP => cimgui.c.ImGuiKey_UpArrow,
        winapi.VK_DOWN => cimgui.c.ImGuiKey_DownArrow,
        winapi.VK_PRIOR => cimgui.c.ImGuiKey_PageUp,
        winapi.VK_NEXT => cimgui.c.ImGuiKey_PageDown,
        winapi.VK_HOME => cimgui.c.ImGuiKey_Home,
        winapi.VK_END => cimgui.c.ImGuiKey_End,
        winapi.VK_INSERT => cimgui.c.ImGuiKey_Insert,
        winapi.VK_DELETE => cimgui.c.ImGuiKey_Delete,
        winapi.VK_BACK => cimgui.c.ImGuiKey_Backspace,
        winapi.VK_SPACE => cimgui.c.ImGuiKey_Space,
        winapi.VK_RETURN => cimgui.c.ImGuiKey_Enter,
        winapi.VK_ESCAPE => cimgui.c.ImGuiKey_Escape,
        'A'...'Z' => @intCast(cimgui.c.ImGuiKey_A + (vk - 'A')),
        '0'...'9' => @intCast(cimgui.c.ImGuiKey_0 + (vk - '0')),
        else => null,
    };
}

// ---------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
    if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *InspectorWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        winapi.WM_ERASEBKGND => return 1,

        winapi.WM_PAINT => {
            _ = winapi.ValidateRect(hwnd, null);
            self.render();
            return 0;
        },

        winapi.WM_TIMER => {
            if (wparam == render_timer_id)
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            return 0;
        },

        winapi.WM_SIZE => {
            self.updateDisplaySize();
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            return 0;
        },

        winapi.WM_DPICHANGED => {
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
            self.updateDisplaySize();
            return 0;
        },

        winapi.WM_CLOSE => {
            self.destroy();
            return 0;
        },

        winapi.WM_SETFOCUS, winapi.WM_KILLFOCUS => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            cimgui.c.ImGuiIO_AddFocusEvent(io, msg == winapi.WM_SETFOCUS);
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            cimgui.c.ImGuiIO_AddMousePosEvent(
                io,
                @floatFromInt(lparamX(lparam)),
                @floatFromInt(lparamY(lparam)),
            );
            return 0;
        },

        winapi.WM_LBUTTONDOWN,
        winapi.WM_LBUTTONUP,
        winapi.WM_RBUTTONDOWN,
        winapi.WM_RBUTTONUP,
        winapi.WM_MBUTTONDOWN,
        winapi.WM_MBUTTONUP,
        => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            const button: c_int = switch (msg) {
                winapi.WM_LBUTTONDOWN, winapi.WM_LBUTTONUP => cimgui.c.ImGuiMouseButton_Left,
                winapi.WM_RBUTTONDOWN, winapi.WM_RBUTTONUP => cimgui.c.ImGuiMouseButton_Right,
                else => cimgui.c.ImGuiMouseButton_Middle,
            };
            const down = msg == winapi.WM_LBUTTONDOWN or
                msg == winapi.WM_RBUTTONDOWN or
                msg == winapi.WM_MBUTTONDOWN;
            // Capture so drags (scrollbars, splitters) keep working
            // when the cursor leaves the window.
            if (down) _ = winapi.SetCapture(hwnd) else _ = winapi.ReleaseCapture();
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, down);
            return 0;
        },

        winapi.WM_MOUSEWHEEL => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            cimgui.c.ImGuiIO_AddMouseWheelEvent(
                io,
                0,
                @as(f32, @floatFromInt(delta)) / 120.0,
            );
            return 0;
        },

        winapi.WM_KEYDOWN, winapi.WM_KEYUP => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            const down = msg == winapi.WM_KEYDOWN;
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                cimgui.c.ImGuiKey_LeftShift,
                winapi.GetKeyState(winapi.VK_SHIFT) < 0,
            );
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                cimgui.c.ImGuiKey_LeftCtrl,
                winapi.GetKeyState(winapi.VK_CONTROL) < 0,
            );
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                cimgui.c.ImGuiKey_LeftAlt,
                winapi.GetKeyState(winapi.VK_MENU) < 0,
            );
            if (vkToImguiKey(wparam)) |key| {
                cimgui.c.ImGuiIO_AddKeyEvent(io, key, down);
            }
            return 0;
        },

        winapi.WM_CHAR => {
            cimgui.c.ImGui_SetCurrentContext(self.ig_context);
            const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            const ch: u16 = @truncate(wparam);
            if (ch >= 0x20 and ch != 0x7F and
                !(ch >= 0xD800 and ch <= 0xDFFF))
            {
                var utf8: [4:0]u8 = .{ 0, 0, 0, 0 };
                const n = std.unicode.utf8Encode(ch, &utf8) catch 0;
                if (n > 0) {
                    utf8[n] = 0;
                    cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, &utf8);
                }
            }
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn lparamX(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}
