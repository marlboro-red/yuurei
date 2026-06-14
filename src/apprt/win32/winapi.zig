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
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_DISABLED: DWORD = 0x08000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_VSCROLL: DWORD = 0x00200000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_CAPTION: DWORD = 0x00C00000;

pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const FALSE = std.os.windows.FALSE;
pub const TRUE = std.os.windows.TRUE;

// Class styles
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;
pub const CS_DROPSHADOW: UINT = 0x00020000;

// ShowWindow
pub const SW_SHOWDEFAULT: i32 = 10;

// PeekMessage
pub const PM_REMOVE: UINT = 0x0001;

// GetWindowLongPtr offsets
pub const GWLP_USERDATA: i32 = -21;

// SetWindowPos flags
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;

// MapVirtualKeyW translation types
pub const MAPVK_VK_TO_CHAR: UINT = 2;

// Messages
pub const WM_NULL: UINT = 0x0000;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
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
pub const WM_TIMER: UINT = 0x0113;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_SETFONT: UINT = 0x0030;

// Child controls (settings window). All are user32 classes, so no
// comctl32 / common-controls init is required.
pub const combobox_class = std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX");
pub const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
pub const CBS_DROPDOWNLIST: DWORD = 0x0003;
pub const CBS_HASSTRINGS: DWORD = 0x0200;
pub const CBS_SORT: DWORD = 0x0100;
pub const BS_AUTOCHECKBOX: DWORD = 0x0003;
pub const CB_ADDSTRING: UINT = 0x0143;
pub const CB_SETCURSEL: UINT = 0x014E;
pub const CB_GETCURSEL: UINT = 0x0147;
pub const BM_GETCHECK: UINT = 0x00F0;
pub const BM_SETCHECK: UINT = 0x00F1;
pub const BST_CHECKED: usize = 1;
/// HIWORD(wParam) notification codes delivered via WM_COMMAND.
pub const CBN_SELCHANGE: u16 = 1;
pub const BN_CLICKED: u16 = 0;

// System cursor ids for LoadCursorW(null, id)
pub const IDC_ARROW: u16 = 32512;
pub const IDC_IBEAM: u16 = 32513;
pub const IDC_WAIT: u16 = 32514;
pub const IDC_CROSS: u16 = 32515;
pub const IDC_SIZENWSE: u16 = 32642;
pub const IDC_SIZENESW: u16 = 32643;
pub const IDC_SIZEWE: u16 = 32644;
pub const IDC_SIZENS: u16 = 32645;
pub const IDC_SIZEALL: u16 = 32646;
pub const IDC_NO: u16 = 32648;
pub const IDC_HAND: u16 = 32649;
pub const IDC_APPSTARTING: u16 = 32650;
pub const IDC_HELP: u16 = 32651;

/// LoadCursorW for a system cursor id (MAKEINTRESOURCEW).
pub fn loadSystemCursor(id: u16) ?HCURSOR {
    return LoadCursorW(null, @ptrFromInt(@as(usize, id)));
}

/// Whether Windows is in light mode for apps, from the personalization
/// registry key. Defaults to dark when the value is missing (pre-1809
/// builds had no light mode).
pub fn appsUseLightTheme() bool {
    const key = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

    var data: DWORD = 0;
    var size: DWORD = @sizeOf(DWORD);
    const status = RegGetValueW(
        HKEY_CURRENT_USER,
        key,
        value,
        RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    if (status != 0) return false;
    return data != 0;
}

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;
pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) i32;

// Virtual keys (only those we map; see Surface.vkToKey)
pub const VK_BACK: u8 = 0x08;
pub const VK_TAB: u8 = 0x09;
pub const VK_PAUSE: u8 = 0x13;
pub const VK_CAPITAL: u8 = 0x14;
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
pub const VK_SNAPSHOT: u8 = 0x2C;
pub const VK_INSERT: u8 = 0x2D;
pub const VK_DELETE: u8 = 0x2E;
pub const VK_LWIN: u8 = 0x5B;
pub const VK_RWIN: u8 = 0x5C;
pub const VK_APPS: u8 = 0x5D;
pub const VK_NUMPAD0: u8 = 0x60;
pub const VK_MULTIPLY: u8 = 0x6A;
pub const VK_ADD: u8 = 0x6B;
pub const VK_SUBTRACT: u8 = 0x6D;
pub const VK_DECIMAL: u8 = 0x6E;
pub const VK_DIVIDE: u8 = 0x6F;
pub const VK_F1: u8 = 0x70;
pub const VK_NUMLOCK: u8 = 0x90;
pub const VK_SCROLL: u8 = 0x91;
pub const VK_OEM_1: u8 = 0xBA;
pub const VK_OEM_PLUS: u8 = 0xBB;
pub const VK_OEM_COMMA: u8 = 0xBC;
pub const VK_OEM_MINUS: u8 = 0xBD;
pub const VK_OEM_PERIOD: u8 = 0xBE;
pub const VK_OEM_2: u8 = 0xBF;
pub const VK_OEM_3: u8 = 0xC0;
pub const VK_OEM_4: u8 = 0xDB;
pub const VK_OEM_5: u8 = 0xDC;
pub const VK_OEM_6: u8 = 0xDD;
pub const VK_OEM_7: u8 = 0xDE;

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
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
// The name parameter is untyped because MAKEINTRESOURCE ids are
// deliberately invalid (often odd-valued) pointers; a u16 pointer type
// would trip alignment checks.
pub extern "user32" fn LoadCursorW(?HINSTANCE, ?*align(1) const anyopaque) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(?HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;

// Global hotkeys
pub const WM_HOTKEY: UINT = 0x0312;
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
pub const MOD_NOREPEAT: UINT = 0x4000;
pub extern "user32" fn RegisterHotKey(?HWND, i32, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(?HWND, i32) callconv(.winapi) BOOL;

// Quick terminal window styling/placement
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;

// Custom scrollbar (Scrollbar.zig)
pub extern "gdi32" fn RoundRect(HDC, i32, i32, i32, i32, i32, i32) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreatePen(i32, i32, u32) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn Polyline(HDC, [*]const POINT, i32) callconv(.winapi) BOOL;
pub const PS_NULL: i32 = 5;
pub const PS_SOLID: i32 = 0;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: DWORD = 0,
};
pub const TME_LEAVE: DWORD = 0x02;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;

// Tooltips (comctl32)
pub const tooltips_class = std.unicode.utf8ToUtf16LeStringLiteral("tooltips_class32");
pub const TTS_ALWAYSTIP: DWORD = 0x01;
pub const TTS_NOPREFIX: DWORD = 0x02;
pub const TTF_SUBCLASS: UINT = 0x0010;
pub const TTM_RELAYEVENT: UINT = 0x0400 + 7;
pub const TTM_ADDTOOLW: UINT = 0x0400 + 50;
pub const TTM_DELTOOLW: UINT = 0x0400 + 51;
pub const TTM_NEWTOOLRECTW: UINT = 0x0400 + 52;
pub const TTM_UPDATETIPTEXTW: UINT = 0x0400 + 57;
pub const TOOLINFOW = extern struct {
    cbSize: UINT = @sizeOf(TOOLINFOW),
    uFlags: UINT = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    hinst: ?HINSTANCE = null,
    lpszText: ?[*:0]const u16 = null,
    lParam: LPARAM = 0,
    lpReserved: ?*anyopaque = null,
};
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
// Importing anything from comctl32 makes the loader bring it in so
// the tooltips window class exists.
pub extern "comctl32" fn InitCommonControls() callconv(.winapi) void;

// File drag and drop
pub const WM_DROPFILES: UINT = 0x0233;
pub const HDROP = *opaque {};
pub extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(.winapi) void;
pub extern "shell32" fn DragQueryFileW(HDROP, UINT, ?[*]u16, UINT) callconv(.winapi) UINT;
pub extern "shell32" fn DragFinish(HDROP) callconv(.winapi) void;

// Tray icon + balloon notifications (rendered as toasts on Win 10/11)
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    uTimeoutOrVersion: UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?HICON = null,
};
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};
pub const NIM_ADD: DWORD = 0;
pub const NIM_MODIFY: DWORD = 1;
pub const NIM_DELETE: DWORD = 2;
pub const NIF_MESSAGE: UINT = 0x01;
pub const NIF_ICON: UINT = 0x02;
pub const NIF_TIP: UINT = 0x04;
pub const NIF_INFO: UINT = 0x10;
pub const NIF_SHOWTIP: UINT = 0x80;
pub const NIIF_INFO: DWORD = 0x01;
pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub const IDI_APPLICATION: u16 = 32512;
pub extern "user32" fn LoadIconW(?HINSTANCE, ?*align(1) const anyopaque) callconv(.winapi) ?HICON;

// Window-level transparency (background-opacity)
pub const GWL_EXSTYLE: i32 = -20;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const LWA_ALPHA: DWORD = 0x00000002;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, u32, u8, DWORD) callconv(.winapi) BOOL;
pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;

pub const MB_YESNO: UINT = 0x00000004;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const MB_DEFBUTTON2: UINT = 0x00000100;
pub const IDYES: i32 = 6;
pub extern "user32" fn MessageBoxW(
    hwnd: ?HWND,
    text: [*:0]const u16,
    caption: [*:0]const u16,
    flags: UINT,
) callconv(.winapi) i32;

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) ?HINSTANCE;

pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
pub extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;

// Custom frame
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;

// Hit test results
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTMAXBUTTON: LRESULT = 9;
pub const HTTOP: LRESULT = 12;

pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_NCLBUTTONUP: UINT = 0x00A2;
pub const WM_NCMOUSELEAVE: UINT = 0x02A2;

pub const SM_CYSIZEFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

pub const SW_MINIMIZE: i32 = 6;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_RESTORE: i32 = 9;

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: *anyopaque,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) i32;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(i32, UINT) callconv(.winapi) i32;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetBkMode(HDC, i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetTextColor(HDC, u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateFontW(
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: DWORD,
    underline: DWORD,
    strikeout: DWORD,
    charset: DWORD,
    out_precision: DWORD,
    clip_precision: DWORD,
    quality: DWORD,
    pitch_and_family: DWORD,
    face: ?[*:0]const u16,
) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn SelectObject(HDC, *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn GetTextExtentPoint32W(HDC, [*]const u16, i32, *SIZE) callconv(.winapi) BOOL;
pub extern "user32" fn FrameRect(HDC, *const RECT, HBRUSH) callconv(.winapi) i32;

pub const SIZE = extern struct {
    cx: i32,
    cy: i32,
};
pub extern "user32" fn DrawTextW(HDC, [*:0]const u16, i32, *RECT, UINT) callconv(.winapi) i32;

pub const TRANSPARENT_BK: i32 = 1;
pub const DT_CENTER: UINT = 0x0001;
pub const DT_RIGHT: UINT = 0x0002;
pub const DT_VCENTER: UINT = 0x0004;
pub const DT_SINGLELINE: UINT = 0x0020;
pub const DT_LEFT: UINT = 0x0000;
pub const DT_END_ELLIPSIS: UINT = 0x8000;

// DWM
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attr: DWORD,
    value: *const anyopaque,
    value_size: DWORD,
) callconv(.winapi) i32;

// IME (imm32)
pub const HIMC = *opaque {};

pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;

// WM_IME_COMPOSITION lParam flags
pub const GCS_COMPSTR: DWORD = 0x0008;
pub const GCS_RESULTSTR: DWORD = 0x0800;

// COMPOSITIONFORM styles
pub const CFS_POINT: DWORD = 0x0002;

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(
    himc: HIMC,
    index: DWORD,
    buf: ?*anyopaque,
    buf_len: DWORD,
) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(
    himc: HIMC,
    form: *const COMPOSITIONFORM,
) callconv(.winapi) BOOL;

pub const GlProc = *const fn () callconv(.c) void;
pub extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?GlProc;
pub extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) ?HDC;

/// Set the WGL swap interval (vsync) for the current context. Requires
/// a context to be current on this thread. Returns false if the
/// extension is unavailable. Without this, SwapBuffers runs unthrottled
/// and a busy renderer can spin the GPU hard enough to trip driver
/// timeouts (observed as LiveKernelEvent 141 bursts).
pub fn setSwapInterval(interval: i32) bool {
    const SwapIntervalFn = *const fn (i32) callconv(.winapi) BOOL;
    const proc = wglGetProcAddress("wglSwapIntervalEXT") orelse return false;
    const v = @intFromPtr(proc);
    if (v <= 3 or v == @as(usize, @bitCast(@as(isize, -1)))) return false;
    const swap_interval: SwapIntervalFn = @ptrCast(proc);
    return swap_interval(interval) != 0;
}

pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBeep(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;

pub const FLASHWINFO = extern struct {
    cbSize: UINT = @sizeOf(FLASHWINFO),
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
pub const FLASHW_ALL: DWORD = 0x00000003;
pub const FLASHW_TIMERNOFG: DWORD = 0x0000000C;
pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(.winapi) BOOL;

/// Flash the window's taskbar button and caption until it gains focus,
/// with an attention beep. The interim "notify the user" primitive
/// until WinRT toast notifications are wired up.
pub fn flashWindow(hwnd: HWND) void {
    _ = FlashWindowEx(&.{
        .hwnd = hwnd,
        .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
        .uCount = 0,
        .dwTimeout = 0,
    });
}

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
