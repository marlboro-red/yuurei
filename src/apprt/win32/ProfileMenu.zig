//! The profile dropdown: a custom-drawn popup anchored under the tab
//! strip's new-tab chevron listing shell profiles (profiles.zig).
//! Styled to match the command palette (theme-aware, Segoe UI, hover
//! rows, Win11 rounded corners) rather than a stock Win32 menu.

const ProfileMenu = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const winapi = @import("winapi.zig");
const profiles = @import("profiles.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-profiles");

window: *Window,
hwnd: winapi.HWND,
selected: ?usize = null,

/// Cached fonts, recreated when the DPI changes.
font_name: ?*anyopaque = null,
font_hint: ?*anyopaque = null,
font_dpi: u32 = 0,

/// Logical (96-dpi) metrics.
const width_logical: i32 = 300;
const row_height_logical: i32 = 40;
const pad_logical: i32 = 6;
const sep_height_logical: i32 = 9;
const max_rows: usize = 20;

/// Create and show the menu with its top-left corner at (anchor_x,
/// anchor_y) in screen coordinates (bottom-left of the new-tab
/// button, WT-style), clamped to the work area.
pub fn create(
    alloc: Allocator,
    window: *Window,
    anchor_x: i32,
    anchor_y: i32,
) !*ProfileMenu {
    const profile_list = window.app.ensureProfiles();
    if (profile_list.items.len == 0) return error.NoProfiles;

    const self = try alloc.create(ProfileMenu);
    errdefer alloc.destroy(self);

    const hwnd = winapi.CreateWindowExW(
        winapi.WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_POPUP,
        0,
        0,
        1,
        1,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);

    self.* = .{ .window = window, .hwnd = hwnd };
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    // Win11 rounded corners; harmless no-op on Win10.
    const corner: u32 = winapi.DWMWCP_ROUNDSMALL;
    _ = winapi.DwmSetWindowAttribute(
        hwnd,
        winapi.DWMWA_WINDOW_CORNER_PREFERENCE,
        &corner,
        @sizeOf(u32),
    );

    // Size to content, then clamp into the monitor work area so the
    // menu never dangles off-screen.
    const w = window.scale(width_logical);
    const h = self.contentHeight();
    var x = anchor_x;
    var y = anchor_y;
    const mon = winapi.MonitorFromWindow(window.hwnd, winapi.MONITOR_DEFAULTTONEAREST);
    var mi: winapi.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(winapi.MONITORINFO);
    if (winapi.GetMonitorInfoW(mon, &mi) != 0) {
        x = @max(mi.rcWork.left, @min(x, mi.rcWork.right - w));
        y = @max(mi.rcWork.top, @min(y, mi.rcWork.bottom - h));
    }
    _ = winapi.SetWindowPos(
        hwnd,
        null,
        x,
        y,
        w,
        h,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
    );

    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOW);
    return self;
}

pub fn destroy(self: *ProfileMenu) void {
    const alloc = self.window.app.core_app.alloc;
    self.window.profile_menu = null;
    if (self.font_name) |f| _ = winapi.DeleteObject(f);
    if (self.font_hint) |f| _ = winapi.DeleteObject(f);
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

fn dismiss(self: *ProfileMenu) void {
    const window = self.window;
    self.destroy();
    _ = winapi.SetFocus(window.hwnd);
}

fn list(self: *const ProfileMenu) *const profiles.List {
    // ensureProfiles was called in create; the cache lives on the App
    // and outlives the menu (invalidation closes it via config reload
    // destroying windows' transient popups on focus change).
    return &self.window.app.profiles_list.?;
}

fn rowCount(self: *const ProfileMenu) usize {
    return @min(self.list().items.len, max_rows);
}

/// Whether the separator sits above this row index.
fn sepAbove(self: *const ProfileMenu, row: usize) bool {
    const l = self.list();
    return l.detected_start > 0 and
        l.detected_start < l.items.len and
        row == l.detected_start;
}

fn contentHeight(self: *const ProfileMenu) i32 {
    const window = self.window;
    const n: i32 = @intCast(self.rowCount());
    var h = n * window.scale(row_height_logical) + 2 * window.scale(pad_logical);
    const l = self.list();
    if (l.detected_start > 0 and l.detected_start < l.items.len)
        h += window.scale(sep_height_logical);
    return h;
}

/// Top y of a row in client coordinates.
fn rowTop(self: *const ProfileMenu, row: usize) i32 {
    const window = self.window;
    var y = window.scale(pad_logical) +
        @as(i32, @intCast(row)) * window.scale(row_height_logical);
    const l = self.list();
    if (l.detected_start > 0 and row >= l.detected_start and
        l.detected_start < l.items.len)
        y += window.scale(sep_height_logical);
    return y;
}

fn rowAt(self: *const ProfileMenu, y: i32) ?usize {
    const window = self.window;
    const row_h = window.scale(row_height_logical);
    var row: usize = 0;
    while (row < self.rowCount()) : (row += 1) {
        const top = self.rowTop(row);
        if (y >= top and y < top + row_h) return row;
    }
    return null;
}

fn execute(self: *ProfileMenu) void {
    const row = self.selected orelse return self.dismiss();
    const window = self.window;
    const l = self.list();
    if (row >= l.items.len) return self.dismiss();
    const profile = &l.items[row];
    self.dismiss();
    _ = window.newTabWithProfile(profile) catch |err| {
        log.err("error opening profile tab err={}", .{err});
    };
}

fn ensureFonts(self: *ProfileMenu) void {
    const dpi = winapi.GetDpiForWindow(self.hwnd);
    if (self.font_dpi == dpi and self.font_name != null) return;
    if (self.font_name) |f| _ = winapi.DeleteObject(f);
    if (self.font_hint) |f| _ = winapi.DeleteObject(f);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.font_name = winapi.CreateFontW(-self.window.scale(13), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_hint = winapi.CreateFontW(-self.window.scale(10), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_dpi = dpi;
}

fn paint(self: *ProfileMenu, hdc: winapi.HDC) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    // The command palette's theme-aware palette, for visual kinship.
    const light = window.isLight();
    const bg: u32 = if (light) 0x00F5F5F5 else 0x001F1F1F;
    const select_bg: u32 = if (light) 0x00DDDDDD else 0x00383838;
    const border: u32 = if (light) 0x00B0B0B0 else 0x00484848;
    const fg: u32 = if (light) 0x00000000 else 0x00FFFFFF;
    const fg_dim: u32 = if (light) 0x00505050 else 0x00A0A0A0;

    const bg_brush = winapi.CreateSolidBrush(bg) orelse return;
    defer _ = winapi.DeleteObject(bg_brush);
    _ = winapi.FillRect(hdc, &client, bg_brush);
    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);

    self.ensureFonts();

    const margin = window.scale(12);
    const row_h = window.scale(row_height_logical);
    const l = self.list();

    var row: usize = 0;
    while (row < self.rowCount()) : (row += 1) {
        const profile = &l.items[row];
        const top = self.rowTop(row);

        // Separator between user overlays and detected shells.
        if (self.sepAbove(row)) {
            const sep_y = top - @divTrunc(window.scale(sep_height_logical), 2);
            const sep: winapi.RECT = .{
                .left = margin,
                .top = sep_y,
                .right = client.right - margin,
                .bottom = sep_y + 1,
            };
            if (winapi.CreateSolidBrush(border)) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &sep, b);
            }
        }

        // Hover/selection: an inset highlight bar, like the palette.
        if (self.selected == row) {
            const hl: winapi.RECT = .{
                .left = window.scale(pad_logical),
                .top = top,
                .right = client.right - window.scale(pad_logical),
                .bottom = top + row_h,
            };
            if (winapi.CreateSolidBrush(select_bg)) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &hl, b);
            }
        }

        // Name (left, primary) and hint (right, dim, ellipsized). The
        // hint is capped to ~45% width so long commands never crowd
        // the name.
        var name_buf: [256:0]u16 = undefined;
        const name_len = toUtf16(profile.name, &name_buf);
        var name_rect: winapi.RECT = .{
            .left = margin,
            .top = top,
            .right = client.right - margin -
                @divTrunc((client.right - 2 * margin) * 45, 100) - window.scale(8),
            .bottom = top + row_h,
        };
        if (self.font_name) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, fg);
            _ = winapi.DrawTextW(
                hdc,
                name_buf[0..name_len :0],
                @intCast(name_len),
                &name_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE |
                    winapi.DT_END_ELLIPSIS | winapi.DT_NOPREFIX,
            );
        }

        var hint_buf: [256:0]u16 = undefined;
        const hint_len = toUtf16(profile.hint, &hint_buf);
        var hint_rect: winapi.RECT = .{
            .left = name_rect.right + window.scale(8),
            .top = top,
            .right = client.right - margin,
            .bottom = top + row_h,
        };
        if (self.font_hint) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, fg_dim);
            _ = winapi.DrawTextW(
                hdc,
                hint_buf[0..hint_len :0],
                @intCast(hint_len),
                &hint_rect,
                winapi.DT_RIGHT | winapi.DT_VCENTER | winapi.DT_SINGLELINE |
                    winapi.DT_END_ELLIPSIS | winapi.DT_NOPREFIX,
            );
        }
    }

    // 1px border framing the popup.
    if (winapi.CreateSolidBrush(border)) |b| {
        defer _ = winapi.DeleteObject(b);
        var edge = client;
        edge.bottom = 1;
        _ = winapi.FillRect(hdc, &edge, b);
        edge = client;
        edge.top = client.bottom - 1;
        _ = winapi.FillRect(hdc, &edge, b);
        edge = client;
        edge.right = 1;
        _ = winapi.FillRect(hdc, &edge, b);
        edge = client;
        edge.left = client.right - 1;
        _ = winapi.FillRect(hdc, &edge, b);
    }
}

/// UTF-8 -> bounded NUL-terminated UTF-16 for DrawTextW.
fn toUtf16(src: []const u8, buf: *[256:0]u16) usize {
    const n = std.unicode.utf8ToUtf16Le(buf, src) catch 0;
    const len = @min(n, buf.len - 1);
    buf[len] = 0;
    return len;
}

fn moveSelection(self: *ProfileMenu, delta: i32) void {
    const n: i32 = @intCast(self.rowCount());
    if (n == 0) return;
    const cur: i32 = if (self.selected) |s| @intCast(s) else -1;
    self.selected = @intCast(@mod(cur + delta + n, n));
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
    if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ProfileMenu = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        winapi.WM_ERASEBKGND => return 1,

        winapi.WM_PAINT => {
            var ps: winapi.PAINTSTRUCT = undefined;
            if (winapi.BeginPaint(hwnd, &ps)) |hdc| {
                self.paint(hdc);
                _ = winapi.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        winapi.WM_KEYDOWN => {
            switch (@as(u8, @truncate(wparam))) {
                winapi.VK_ESCAPE => self.dismiss(),
                winapi.VK_RETURN => self.execute(),
                winapi.VK_UP => self.moveSelection(-1),
                winapi.VK_DOWN => self.moveSelection(1),
                else => {},
            }
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            const row = self.rowAt(lparamY(lparam));
            if (row != self.selected) {
                self.selected = row;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            if (self.rowAt(lparamY(lparam))) |row| {
                self.selected = row;
                self.execute();
            } else self.dismiss();
            return 0;
        },

        winapi.WM_KILLFOCUS => {
            self.destroy();
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}
