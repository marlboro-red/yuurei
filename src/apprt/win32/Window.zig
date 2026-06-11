/// Win32 apprt Window: one top-level window owning the custom frame,
/// the title strip (tab bar + caption buttons), and input routing.
/// Each tab is an apprt Surface (Surface.zig) rendering into its own
/// GL host child window; switching tabs toggles child visibility.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty");

/// The app we're part of.
app: *App,

/// The top-level window.
hwnd: winapi.HWND,

/// The tabs in visual order. Never empty after create() succeeds,
/// except transiently during teardown.
tabs: std.ArrayList(*Surface) = .empty,

/// Index of the active (visible) tab.
active_tab: usize = 0,

/// Flagged by WM_CLOSE or the close button; the App run loop performs
/// the actual teardown outside the window procedure.
should_close: bool = false,

/// What the mouse hovers in the title strip, for hover painting.
hover: Hover = .none,

/// The key event from the last WM_KEYDOWN that the core did not
/// consume; WM_CHAR completes it with the layout-cooked text.
pending_key_event: ?input.KeyEvent = null,

/// Buffer backing pending_key_event.utf8 across the KEYDOWN→CHAR pair.
utf8_buf: [4]u8 = undefined,

/// Pending high surrogate from WM_CHAR, awaiting its low half.
high_surrogate: ?u16 = null,

const Hover = union(enum) {
    none,
    caption: CaptionButton,
    tab: usize,
    tab_close: usize,
    new_tab,
};

const CaptionButton = enum { minimize, maximize, close };

/// Logical (96-dpi) metrics, scaled by the window DPI at use.
const titlebar_height_logical: i32 = 36;
const caption_button_width_logical: i32 = 46;
const tab_width_logical: i32 = 190;
const new_tab_width_logical: i32 = 36;
const modal_tick_timer_id: usize = 1;

/// Create a window with one tab, show it, and return it.
pub fn create(alloc: Allocator, app: *App) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

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

    self.* = .{ .app = app, .hwnd = hwnd };

    // Wire the window procedure. Handlers tolerate an empty tab list,
    // so this is safe before the first tab exists.
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    // The initial frame was computed before the window procedure was
    // wired; force a recalc so WM_NCCALCSIZE removes the title bar.
    _ = winapi.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        winapi.SWP_NOMOVE | winapi.SWP_NOSIZE | winapi.SWP_NOZORDER |
            winapi.SWP_NOACTIVATE | winapi.SWP_FRAMECHANGED,
    );

    _ = try self.newTab();
    errdefer self.closeAllTabs();

    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);

    // Report the OS theme so window-theme=auto and light/dark
    // conditional config work; also sets the DWM dark caption.
    self.notifyColorScheme();

    return self;
}

/// Destroy the window and any remaining tabs. Must not be called from
/// inside the window procedure.
pub fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    self.closeAllTabs();
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    self.tabs.deinit(alloc);
    alloc.destroy(self);
}

fn closeAllTabs(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    while (self.tabs.pop()) |tab| {
        tab.deinit();
        alloc.destroy(tab);
    }
}

/// Create and activate a new tab.
pub fn newTab(self: *Window) !*Surface {
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);

    try surface.init(self.app, self);
    errdefer surface.deinit();

    try self.tabs.append(alloc, surface);
    self.activateTab(self.tabs.items.len - 1);
    return surface;
}

/// Remove a tab (deinitializing it). When the last tab goes, the
/// window flags itself for close; the App run loop destroys it.
pub fn removeTab(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const idx = for (self.tabs.items, 0..) |tab, i| {
        if (tab == surface) break i;
    } else return;

    _ = self.tabs.orderedRemove(idx);
    surface.deinit();
    alloc.destroy(surface);

    if (self.tabs.items.len == 0) {
        self.should_close = true;
        return;
    }
    self.activateTab(@min(idx, self.tabs.items.len - 1));
}

/// Make the given tab visible and focused.
pub fn activateTab(self: *Window, idx: usize) void {
    if (self.tabs.items.len == 0) return;
    const new_idx = @min(idx, self.tabs.items.len - 1);

    for (self.tabs.items, 0..) |tab, i| {
        const active = i == new_idx;
        tab.setVisible(active);
        if (!active) tab.core_surface.focusCallback(false) catch {};
    }
    self.active_tab = new_idx;

    const tab = self.tabs.items[new_idx];
    tab.core_surface.focusCallback(true) catch {};
    self.syncTitle();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

pub fn activeTab(self: *Window) ?*Surface {
    if (self.tabs.items.len == 0) return null;
    return self.tabs.items[@min(self.active_tab, self.tabs.items.len - 1)];
}

pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) void {
    const n = self.tabs.items.len;
    if (n == 0) return;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab == 0) n - 1 else self.active_tab - 1,
        .next => (self.active_tab + 1) % n,
        .last => n - 1,
        _ => idx: {
            // Positive values are 1-based tab indices.
            const raw = @intFromEnum(target);
            if (raw < 1) return;
            break :idx @min(@as(usize, @intCast(raw)) - 1, n - 1);
        },
    };
    self.activateTab(idx);
}

/// Update the OS-level window title (taskbar/alt-tab) from the active
/// tab and repaint the strip.
pub fn syncTitle(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const title = tab.title_text orelse "Ghostty";
    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], title) catch return;
    buf[len] = 0;
    _ = winapi.SetWindowTextW(self.hwnd, buf[0..len :0]);
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// Read the OS theme: forward to all tabs and set the DWM caption.
pub fn notifyColorScheme(self: *Window) void {
    const light = winapi.appsUseLightTheme();

    const dark_titlebar: winapi.BOOL = if (light) winapi.FALSE else winapi.TRUE;
    _ = winapi.DwmSetWindowAttribute(
        self.hwnd,
        winapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark_titlebar,
        @sizeOf(winapi.BOOL),
    );

    const scheme: apprt.ColorScheme = if (light) .light else .dark;
    for (self.tabs.items) |tab| {
        tab.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error in color scheme callback err={}", .{err});
        };
    }

    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

// ---------------------------------------------------------------------
// Geometry

fn scale(self: *const Window, logical: i32) i32 {
    const dpi: i32 = @intCast(winapi.GetDpiForWindow(self.hwnd));
    return @divTrunc(logical * dpi, 96);
}

/// The title strip height in physical pixels.
pub fn titlebarHeight(self: *const Window) i32 {
    return self.scale(titlebar_height_logical);
}

fn clientWidth(self: *const Window) i32 {
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    return client.right - client.left;
}

fn captionButtonRect(self: *const Window, button: CaptionButton) winapi.RECT {
    const w = self.scale(caption_button_width_logical);
    const index: i32 = switch (button) {
        .close => 1,
        .maximize => 2,
        .minimize => 3,
    };
    const right = self.clientWidth();
    return .{
        .left = right - index * w,
        .top = 0,
        .right = right - (index - 1) * w,
        .bottom = self.titlebarHeight(),
    };
}

/// Width of one tab, shrinking when they no longer fit.
fn tabWidth(self: *const Window) i32 {
    const avail = self.clientWidth() -
        3 * self.scale(caption_button_width_logical) -
        self.scale(new_tab_width_logical);
    const n: i32 = @intCast(@max(1, self.tabs.items.len));
    return @max(self.scale(60), @min(self.scale(tab_width_logical), @divTrunc(avail, n)));
}

fn tabRect(self: *const Window, idx: usize) winapi.RECT {
    const w = self.tabWidth();
    const i: i32 = @intCast(idx);
    return .{
        .left = i * w,
        .top = 0,
        .right = (i + 1) * w,
        .bottom = self.titlebarHeight(),
    };
}

/// The close glyph region within a tab.
fn tabCloseRect(self: *const Window, idx: usize) winapi.RECT {
    const r = self.tabRect(idx);
    const size = self.scale(24);
    const margin = self.scale(6);
    const top = @divTrunc(self.titlebarHeight() - size, 2);
    return .{
        .left = r.right - margin - size,
        .top = top,
        .right = r.right - margin,
        .bottom = top + size,
    };
}

fn newTabRect(self: *const Window) winapi.RECT {
    const w = self.tabWidth();
    const n: i32 = @intCast(self.tabs.items.len);
    return .{
        .left = n * w,
        .top = 0,
        .right = n * w + self.scale(new_tab_width_logical),
        .bottom = self.titlebarHeight(),
    };
}

fn inRect(x: i32, y: i32, r: winapi.RECT) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

/// What lives at the given strip-area client coordinate.
fn hitTestStrip(self: *const Window, x: i32, y: i32) Hover {
    inline for (.{ .minimize, .maximize, .close }) |button| {
        if (inRect(x, y, self.captionButtonRect(button)))
            return .{ .caption = button };
    }
    for (self.tabs.items, 0..) |_, i| {
        if (inRect(x, y, self.tabCloseRect(i))) return .{ .tab_close = i };
        if (inRect(x, y, self.tabRect(i))) return .{ .tab = i };
    }
    if (inRect(x, y, self.newTabRect())) return .new_tab;
    return .none;
}

// ---------------------------------------------------------------------
// Painting

fn paintTitlebar(self: *Window, hdc: winapi.HDC) void {
    const height = self.titlebarHeight();
    var strip: winapi.RECT = .{
        .left = 0,
        .top = 0,
        .right = self.clientWidth(),
        .bottom = height,
    };

    const light = winapi.appsUseLightTheme();
    const bg: u32 = if (light) 0x00E8E8E8 else 0x00181818;
    const tab_active_bg: u32 = if (light) 0x00F8F8F8 else 0x002C2C2C;
    const tab_hover_bg: u32 = if (light) 0x00F0F0F0 else 0x00222222;
    const fg: u32 = if (light) 0x00000000 else 0x00FFFFFF;
    const fg_dim: u32 = if (light) 0x00505050 else 0x00B0B0B0;

    const bg_brush = winapi.CreateSolidBrush(bg) orelse return;
    defer _ = winapi.DeleteObject(bg_brush);
    _ = winapi.FillRect(hdc, &strip, bg_brush);

    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);

    const text_font = winapi.CreateFontW(
        -self.scale(12),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        5, // CLEARTYPE_QUALITY
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    const glyph_font = winapi.CreateFontW(
        -self.scale(10),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        5,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
    );
    defer if (text_font) |f| {
        _ = winapi.DeleteObject(f);
    };
    defer if (glyph_font) |f| {
        _ = winapi.DeleteObject(f);
    };

    // Tabs
    for (self.tabs.items, 0..) |tab, i| {
        var rect = self.tabRect(i);
        const active = i == self.active_tab;
        const hovered = switch (self.hover) {
            .tab => |h| h == i,
            .tab_close => |h| h == i,
            else => false,
        };

        if (active or hovered) {
            const brush = winapi.CreateSolidBrush(
                if (active) tab_active_bg else tab_hover_bg,
            );
            if (brush) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &rect, b);
            }
        }

        // Tab title
        if (text_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, if (active) fg else fg_dim);

            const title = tab.title_text orelse "Ghostty";
            var buf: [512]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(
                buf[0 .. buf.len - 1],
                title,
            ) catch 0;
            if (len > 0) {
                buf[len] = 0;
                var text_rect: winapi.RECT = .{
                    .left = rect.left + self.scale(10),
                    .top = rect.top,
                    .right = self.tabCloseRect(i).left - self.scale(4),
                    .bottom = rect.bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..len :0],
                    @intCast(len),
                    &text_rect,
                    winapi.DT_LEFT | winapi.DT_VCENTER |
                        winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
        }

        // Tab close glyph (shown on active or hovered tabs)
        if ((active or hovered) and glyph_font != null) {
            const old = winapi.SelectObject(hdc, glyph_font.?);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            var close_rect = self.tabCloseRect(i);
            const close_hovered = switch (self.hover) {
                .tab_close => |h| h == i,
                else => false,
            };
            if (close_hovered) {
                const brush = winapi.CreateSolidBrush(
                    if (light) 0x00C8C8C8 else 0x00404040,
                );
                if (brush) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &close_rect, b);
                }
            }
            _ = winapi.SetTextColor(hdc, if (active) fg else fg_dim);
            var glyph: [2:0]u16 = .{ 0xE8BB, 0 };
            _ = winapi.DrawTextW(
                hdc,
                &glyph,
                1,
                &close_rect,
                winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
        }
    }

    // New tab "+" button
    if (glyph_font) |f| {
        const old = winapi.SelectObject(hdc, f);
        defer if (old) |o| {
            _ = winapi.SelectObject(hdc, o);
        };
        var plus_rect = self.newTabRect();
        if (self.hover == .new_tab) {
            const brush = winapi.CreateSolidBrush(tab_hover_bg);
            if (brush) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &plus_rect, b);
            }
        }
        _ = winapi.SetTextColor(hdc, fg_dim);
        var glyph: [2:0]u16 = .{ 0xE710, 0 }; // Add
        _ = winapi.DrawTextW(
            hdc,
            &glyph,
            1,
            &plus_rect,
            winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
        );
    }

    // Caption buttons
    if (glyph_font) |f| {
        const old = winapi.SelectObject(hdc, f);
        defer if (old) |o| {
            _ = winapi.SelectObject(hdc, o);
        };

        inline for (.{ .minimize, .maximize, .close }) |button| {
            var rect = self.captionButtonRect(button);
            const hovered = switch (self.hover) {
                .caption => |h| h == @as(CaptionButton, button),
                else => false,
            };

            if (hovered) {
                const hover_bg: u32 = if (button == .close)
                    0x002311E8 // red; COLORREF is BGR
                else if (light)
                    0x00DADADA
                else
                    0x002D2D2D;
                const brush = winapi.CreateSolidBrush(hover_bg);
                if (brush) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &rect, b);
                }
                _ = winapi.SetTextColor(
                    hdc,
                    if (button == .close) 0x00FFFFFF else fg,
                );
            } else {
                _ = winapi.SetTextColor(hdc, fg);
            }

            const cp: u16 = switch (@as(CaptionButton, button)) {
                .minimize => 0xE921,
                .maximize => if (winapi.IsZoomed(self.hwnd) != 0) 0xE923 else 0xE922,
                .close => 0xE8BB,
            };
            var glyph: [2:0]u16 = .{ cp, 0 };
            _ = winapi.DrawTextW(
                hdc,
                &glyph,
                1,
                &rect,
                winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
        }
    }
}

fn captionButtonClick(self: *Window, button: CaptionButton) void {
    switch (button) {
        .minimize => _ = winapi.ShowWindow(self.hwnd, winapi.SW_MINIMIZE),
        .maximize => _ = winapi.ShowWindow(
            self.hwnd,
            if (winapi.IsZoomed(self.hwnd) != 0)
                winapi.SW_RESTORE
            else
                winapi.SW_MAXIMIZE,
        ),
        .close => self.should_close = true,
    }
}

// ---------------------------------------------------------------------
// IME

fn imePositionWindow(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    // imePoint is relative to the terminal surface (the GL host); the
    // composition window position is relative to the top-level window.
    const pos = tab.core_surface.imePoint();
    _ = winapi.ImmSetCompositionWindow(himc, &.{
        .dwStyle = winapi.CFS_POINT,
        .ptCurrentPos = .{
            .x = @intFromFloat(@max(0, pos.x)),
            .y = @as(i32, @intFromFloat(@max(0, pos.y))) + self.titlebarHeight(),
        },
        .rcArea = std.mem.zeroes(winapi.RECT),
    });
}

fn imeComposition(self: *Window, lparam: winapi.LPARAM) void {
    const tab = self.activeTab() orelse return;
    const flags: winapi.DWORD = @truncate(@as(usize, @bitCast(lparam)));
    const himc = winapi.ImmGetContext(self.hwnd) orelse return;
    defer _ = winapi.ImmReleaseContext(self.hwnd, himc);

    const alloc = tab.core_surface.alloc;

    if (flags & winapi.GCS_RESULTSTR != 0) result: {
        const text = imeGetString(alloc, himc, winapi.GCS_RESULTSTR) orelse
            break :result;
        defer alloc.free(text);

        tab.core_surface.preeditCallback(null) catch {};

        const key_event: input.KeyEvent = .{
            .action = .press,
            .key = .unidentified,
            .utf8 = text,
        };
        _ = tab.core_surface.keyCallback(key_event) catch |err| {
            log.err("error in key callback err={}", .{err});
        };
    }

    if (flags & winapi.GCS_COMPSTR != 0) comp: {
        const text = imeGetString(alloc, himc, winapi.GCS_COMPSTR) orelse
            break :comp;
        defer alloc.free(text);

        tab.core_surface.preeditCallback(
            if (text.len > 0) text else null,
        ) catch |err| {
            log.err("error in preedit callback err={}", .{err});
        };
    }

    self.imePositionWindow();
}

fn imeGetString(
    alloc: Allocator,
    himc: winapi.HIMC,
    index: winapi.DWORD,
) ?[]const u8 {
    const bytes = winapi.ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;

    const wide = alloc.alloc(u16, @intCast(@divExact(bytes, 2))) catch return null;
    defer alloc.free(wide);
    _ = winapi.ImmGetCompositionStringW(himc, index, wide.ptr, @intCast(bytes));

    return std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch null;
}

// ---------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: winapi.HWND,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) callconv(.winapi) winapi.LRESULT {
    const self: *Window = self: {
        const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
        if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :self @ptrFromInt(@as(usize, @bitCast(ptr)));
    };

    switch (msg) {
        winapi.WM_CLOSE => {
            self.should_close = true;
            return 0;
        },

        winapi.WM_ERASEBKGND => return 1,

        // Custom frame: remove the standard title bar but keep the
        // left/right/bottom resize borders DefWindowProc computes.
        winapi.WM_NCCALCSIZE => {
            if (wparam == 0) return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
            const params: *winapi.NCCALCSIZE_PARAMS = @ptrFromInt(
                @as(usize, @bitCast(lparam)),
            );
            const original_top = params.rgrc[0].top;
            const result = winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (result != 0) return result;
            params.rgrc[0].top = original_top;

            // When maximized the window extends past the monitor edge
            // by the frame size; inset so the strip stays visible.
            if (winapi.IsZoomed(hwnd) != 0) {
                const dpi = winapi.GetDpiForWindow(hwnd);
                params.rgrc[0].top += winapi.GetSystemMetricsForDpi(
                    winapi.SM_CYSIZEFRAME,
                    dpi,
                ) + winapi.GetSystemMetricsForDpi(
                    winapi.SM_CXPADDEDBORDER,
                    dpi,
                );
            }
            return 0;
        },

        winapi.WM_NCHITTEST => {
            var pt: winapi.POINT = .{
                .x = lparamX(lparam),
                .y = lparamY(lparam),
            };
            _ = winapi.ScreenToClient(hwnd, &pt);

            // Top resize border (the standard one left with the caption).
            if (winapi.IsZoomed(hwnd) == 0) {
                const dpi = winapi.GetDpiForWindow(hwnd);
                const frame_y = winapi.GetSystemMetricsForDpi(
                    winapi.SM_CYSIZEFRAME,
                    dpi,
                ) + winapi.GetSystemMetricsForDpi(
                    winapi.SM_CXPADDEDBORDER,
                    dpi,
                );
                if (pt.y >= 0 and pt.y < frame_y)
                    return winapi.HTTOP;
            }

            if (pt.y >= 0 and pt.y < self.titlebarHeight()) {
                // Interactive strip elements get client clicks; the
                // rest of the strip drags the window.
                if (self.hitTestStrip(pt.x, pt.y) != .none)
                    return 1; // HTCLIENT
                return winapi.HTCAPTION;
            }

            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_PAINT => {
            var ps: winapi.PAINTSTRUCT = undefined;
            if (winapi.BeginPaint(hwnd, &ps)) |hdc| {
                self.paintTitlebar(hdc);
                _ = winapi.EndPaint(hwnd, &ps);
            }
            if (self.activeTab()) |tab| {
                tab.core_surface.refreshCallback() catch |err| {
                    log.err("error in refresh callback err={}", .{err});
                };
            }
            return 0;
        },

        winapi.WM_SIZE => {
            // All tab hosts share the terminal rect below the strip.
            var client: winapi.RECT = undefined;
            _ = winapi.GetClientRect(hwnd, &client);
            const strip = self.titlebarHeight();
            const w = client.right - client.left;
            const h = @max(0, client.bottom - client.top - strip);
            for (self.tabs.items) |tab| {
                _ = winapi.SetWindowPos(
                    tab.host,
                    null,
                    0,
                    strip,
                    w,
                    h,
                    winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
                );
                const size = tab.getSize() catch continue;
                tab.core_surface.sizeCallback(size) catch |err| {
                    log.err("error in size callback err={}", .{err});
                };
            }
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

            const dpi: f32 = @floatFromInt(wparam & 0xFFFF);
            const content_scale: apprt.ContentScale = .{
                .x = dpi / 96.0,
                .y = dpi / 96.0,
            };
            for (self.tabs.items) |tab| {
                tab.core_surface.contentScaleCallback(content_scale) catch |err| {
                    log.err("error in content scale callback err={}", .{err});
                };
            }
            return 0;
        },

        winapi.WM_SETFOCUS, winapi.WM_KILLFOCUS => {
            if (self.activeTab()) |tab| {
                tab.core_surface.focusCallback(msg == winapi.WM_SETFOCUS) catch |err| {
                    log.err("error in focus callback err={}", .{err});
                };
            }
            return 0;
        },

        winapi.WM_SETCURSOR => {
            const hit: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (hit == winapi.HTCLIENT) cursor: {
                // Only the terminal area uses the surface cursor; strip
                // elements keep the arrow.
                var pt: winapi.POINT = undefined;
                if (winapi.GetCursorPos(&pt) == 0) break :cursor;
                _ = winapi.ScreenToClient(hwnd, &pt);
                if (pt.y < self.titlebarHeight()) break :cursor;
                const tab = self.activeTab() orelse break :cursor;
                const cursor = tab.cursor orelse break :cursor;
                _ = winapi.SetCursor(cursor);
                return 1;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_ENTERSIZEMOVE => {
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
            self.notifyColorScheme();
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_IME_STARTCOMPOSITION => {
            self.imePositionWindow();
            return 0;
        },

        winapi.WM_IME_COMPOSITION => {
            self.imeComposition(lparam);
            return 0;
        },

        winapi.WM_IME_ENDCOMPOSITION => {
            if (self.activeTab()) |tab| {
                tab.core_surface.preeditCallback(null) catch |err| {
                    log.err("error in preedit callback err={}", .{err});
                };
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_KEYDOWN,
        winapi.WM_KEYUP,
        winapi.WM_SYSKEYDOWN,
        winapi.WM_SYSKEYUP,
        => {
            self.keyEvent(msg, wparam, lparam);
            if (msg == winapi.WM_SYSKEYDOWN or msg == winapi.WM_SYSKEYUP)
                return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

        winapi.WM_CHAR => {
            self.charEvent(@truncate(wparam));
            return 0;
        },

        winapi.WM_MOUSEWHEEL => {
            const tab = self.activeTab() orelse return 0;
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
            tab.core_surface.scrollCallback(0, yoff * 3, .{}) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            const x = lparamX(lparam);
            const y = lparamY(lparam);

            const hover: Hover = if (y < self.titlebarHeight())
                self.hitTestStrip(x, y)
            else
                .none;
            if (!std.meta.eql(hover, self.hover)) {
                self.hover = hover;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }

            const tab = self.activeTab() orelse return 0;
            tab.core_surface.cursorPosCallback(.{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y - self.titlebarHeight()),
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
            // Clicks in the strip operate tabs/buttons, never the
            // terminal.
            const cy = lparamY(lparam);
            if (cy >= 0 and cy < self.titlebarHeight()) {
                if (msg == winapi.WM_LBUTTONUP) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .none => {},
                        .caption => |button| self.captionButtonClick(button),
                        .tab => |i| self.activateTab(i),
                        .tab_close => |i| self.tabs.items[i].should_close = true,
                        .new_tab => _ = self.newTab() catch |err| {
                            log.err("error creating tab err={}", .{err});
                        },
                    }
                }
                return 0;
            }

            const tab = self.activeTab() orelse return 0;
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

            switch (state) {
                .press => _ = winapi.SetCapture(hwnd),
                .release => _ = winapi.ReleaseCapture(),
            }

            _ = tab.core_surface.mouseButtonCallback(
                state,
                button,
                currentMods(),
            ) catch |err| {
                log.err("error in mouse button callback err={}", .{err});
            };
            return 0;
        },

        else => {},
    }

    return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------
// Keyboard

fn keyEvent(
    self: *Window,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) void {
    const tab = self.activeTab() orelse return;
    const vk: u8 = @truncate(wparam);
    const released = msg == winapi.WM_KEYUP or msg == winapi.WM_SYSKEYUP;
    const was_down = (lparam & (1 << 30)) != 0;

    const action: input.Action = if (released)
        .release
    else if (was_down)
        .repeat
    else
        .press;

    // TODO: windows: AltGr discrimination (lParam bit 24 + scancode).
    const mods = currentMods();

    // Keybind triggers match on the unshifted codepoint; derive it from
    // the layout. The high bit of VK_TO_CHAR flags a dead key.
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

    const effect = tab.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
        return;
    };

    if (effect == .closed) return;

    // If unconsumed, stash so the queued WM_CHAR can complete it with
    // text; consumed keydowns swallow their WM_CHAR via the null stash.
    self.pending_key_event = null;
    if (effect == .ignored and (action == .press or action == .repeat)) {
        self.pending_key_event = key_event;
    }
}

fn charEvent(self: *Window, unit: u16) void {
    const tab = self.activeTab() orelse return;

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
    if (key_event.unshifted_codepoint == 0 and
        codepoint < 0x80 and !key_event.mods.shift)
    {
        key_event.unshifted_codepoint = codepoint;
    }

    _ = tab.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
    };
}

fn currentMods() input.Mods {
    return .{
        .shift = winapi.GetKeyState(winapi.VK_SHIFT) < 0,
        .ctrl = winapi.GetKeyState(winapi.VK_CONTROL) < 0,
        .alt = winapi.GetKeyState(winapi.VK_MENU) < 0,
        .super = winapi.GetKeyState(winapi.VK_LWIN) < 0 or
            winapi.GetKeyState(winapi.VK_RWIN) < 0,
    };
}

fn lparamX(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}

/// US-centric VK→Key map; layout-aware matching happens via UTF-8 text
/// from WM_CHAR. Left/right modifiers discriminate by the extended-key
/// bit and the right-shift scancode.
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
