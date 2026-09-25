//! Documented Win32 control APIs used by the settings dialog.
const w = @import("winapi.zig");
pub extern "user32" fn GetWindowTextW(w.HWND, [*]u16, i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(w.HWND) callconv(.winapi) i32;
pub extern "user32" fn IsChild(w.HWND, w.HWND) callconv(.winapi) w.BOOL;
pub extern "user32" fn GetFocus() callconv(.winapi) ?w.HWND;
pub extern "user32" fn IsWindowEnabled(w.HWND) callconv(.winapi) w.BOOL;
pub extern "user32" fn IsDialogMessageW(w.HWND, *w.MSG) callconv(.winapi) w.BOOL;
pub extern "user32" fn EnableWindow(w.HWND, w.BOOL) callconv(.winapi) w.BOOL;
pub extern "user32" fn DrawFocusRect(w.HDC, *const w.RECT) callconv(.winapi) w.BOOL;
pub extern "user32" fn CallWindowProcW(w.WNDPROC, w.HWND, w.UINT, w.WPARAM, w.LPARAM) callconv(.winapi) w.LRESULT;
pub extern "gdi32" fn SetBkColor(w.HDC, u32) callconv(.winapi) u32;
pub const DrawItem = extern struct {
    control_type: u32,
    id: u32,
    item_id: u32,
    action: u32,
    state: u32,
    hwnd: w.HWND,
    hdc: w.HDC,
    rect: w.RECT,
    data: usize,
};
pub const MinMaxInfo = extern struct {
    reserved: w.POINT,
    max_size: w.POINT,
    max_position: w.POINT,
    min_track: w.POINT,
    max_track: w.POINT,
};
