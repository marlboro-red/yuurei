//! Hand-written Win32 declarations used by the win32 apprt.
//!
//! These are deliberately hand-written rather than pulled from generated
//! bindings (zigwin32): everything here is a plain extern function with
//! scalar/struct arguments, which is safe to write by hand. The port plan's
//! decision to use generated bindings is about COM interfaces (vtables,
//! IIDs) — when DirectWrite/TSF/etc. arrive, that dependency gets added;
//! this file should never grow COM machinery.
const std = @import("std");
const windows = std.os.windows;

pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HICON = windows.HICON;
pub const HCURSOR = windows.HCURSOR;
pub const HBRUSH = windows.HBRUSH;
pub const HMENU = windows.HMENU;
pub const HANDLE = windows.HANDLE;
pub const HMODULE = windows.HMODULE;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LRESULT;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = windows.UINT;
pub const ATOM = windows.ATOM;
pub const RECT = windows.RECT;
pub const POINT = windows.POINT;

pub const HGLRC = *opaque {};

pub const WNDPROC = *const fn (
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: DWORD = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

// Window styles
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// Class styles
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

// ShowWindow
pub const SW_SHOWDEFAULT: i32 = 10;

// PeekMessage
pub const PM_REMOVE: UINT = 0x0001;

// GetWindowLongPtr offsets
pub const GWLP_USERDATA: i32 = -21;

// Messages
pub const WM_NULL: UINT = 0x0000;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_MOUSEWHEEL: UINT = 0x020A;

// Virtual keys (only those we map; see Surface.vkToKey)
pub const VK_BACK: u8 = 0x08;
pub const VK_TAB: u8 = 0x09;
pub const VK_RETURN: u8 = 0x0D;
pub const VK_SHIFT: u8 = 0x10;
pub const VK_CONTROL: u8 = 0x11;
pub const VK_MENU: u8 = 0x12;
pub const VK_ESCAPE: u8 = 0x1B;
pub const VK_SPACE: u8 = 0x20;
pub const VK_PRIOR: u8 = 0x21;
pub const VK_NEXT: u8 = 0x22;
pub const VK_END: u8 = 0x23;
pub const VK_HOME: u8 = 0x24;
pub const VK_LEFT: u8 = 0x25;
pub const VK_UP: u8 = 0x26;
pub const VK_RIGHT: u8 = 0x27;
pub const VK_DOWN: u8 = 0x28;
pub const VK_INSERT: u8 = 0x2D;
pub const VK_DELETE: u8 = 0x2E;
pub const VK_LWIN: u8 = 0x5B;
pub const VK_RWIN: u8 = 0x5C;
pub const VK_NUMPAD0: u8 = 0x60;
pub const VK_F1: u8 = 0x70;

// Clipboard
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// PIXELFORMATDESCRIPTOR flags
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_TYPE_RGBA: u8 = 0;

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) i32;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostThreadMessageW(DWORD, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) i32;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn WindowFromDC(HDC) callconv(.winapi) ?HWND;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "user32" fn ValidateRect(?HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;

pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
pub extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;

pub const GlProc = *const fn () callconv(.c) void;
pub extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?GlProc;
pub extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) ?HDC;

/// GL loader suitable for glad: wglGetProcAddress only resolves extension
/// and GL>1.1 functions; GL 1.0/1.1 entry points come from opengl32.dll
/// itself. wglGetProcAddress is also documented to return the sentinel
/// values 1, 2, 3 and -1 on failure on some drivers, not just null.
pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?GlProc {
    if (wglGetProcAddress(name)) |proc| {
        const v = @intFromPtr(proc);
        if (v > 3 and v != @as(usize, @bitCast(@as(isize, -1)))) return proc;
    }

    const module = std.os.windows.kernel32.GetModuleHandleW(
        std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"),
    ) orelse return null;
    const farproc = std.os.windows.kernel32.GetProcAddress(module, name) orelse return null;
    return @ptrCast(farproc);
}
