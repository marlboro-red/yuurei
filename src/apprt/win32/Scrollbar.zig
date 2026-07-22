/// A custom-drawn scrollbar in the column beside each GL host: a slim
/// rounded thumb on an invisible track (the terminal background),
/// brighter on hover and during drags, and absent entirely when there
/// is no scrollback — the Windows Terminal/VS Code look, replacing the
/// classic Win32 SCROLLBAR control. Fed by the core's `scrollbar`
/// action; thumb drags and track clicks send `scroll_to_row`.
const Scrollbar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The scrollbar window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-scroll");

/// The surface this scrollbar scrolls. The surface owns us.
surface: *Surface,

/// Our window (a sibling of the GL host).
hwnd: winapi.HWND,

/// Scroll state in rows, from the core's `scrollbar` action.
total: usize = 0,
offset: usize = 0,
len: usize = 0,

/// Mouse state for painting and dragging.
hover: bool = false,
tracking: bool = false,

/// While dragging: the y offset of the grab point within the thumb.
drag_grab: ?i32 = null,

pub fn create(alloc: Allocator, surface: *Surface) !*Scrollbar {
    const self = try alloc.create(Scrollbar);
    errdefer alloc.destroy(self);

    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD,
        0,
        0,
        0,
        0,
        surface.window.hwnd,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    self.* = .{ .surface = surface, .hwnd = hwnd };
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );
    return self;
}

pub fn destroy(self: *Scrollbar, alloc: Allocator) void {
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// Feed core scroll state (rows).
pub fn update(self: *Scrollbar, total: usize, offset: usize, len: usize) void {
    if (self.total == total and self.offset == offset and self.len == len)
        return;
    self.total = total;
    self.offset = offset;
    self.len = len;
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// Whether there is anything to scroll (otherwise nothing is drawn).
fn scrollable(self: *const Scrollbar) bool {
    return self.total > self.len and self.len > 0;
}

/// The thumb rect in client coordinates, if scrollable.
fn thumbRect(self: *const Scrollbar) ?winapi.RECT {
    if (!self.scrollable()) return null;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const h: f64 = @floatFromInt(@max(1, client.bottom - client.top));
    const w = client.right - client.left;

    const min_thumb: f64 = @floatFromInt(self.surface.window.scale(24));
    const thumb_h = @max(min_thumb, h * @as(f64, @floatFromInt(self.len)) /
        @as(f64, @floatFromInt(self.total)));
    const range = h - thumb_h;
    const denom: f64 = @floatFromInt(self.total - self.len);
    const y = range * @as(f64, @floatFromInt(self.offset)) / @max(1.0, denom);

    // The thumb is a slim pill horizontally centered in the column.
    const thumb_w = self.surface.window.scale(6);
    const inset = @divTrunc(w - thumb_w, 2);
    return .{
        .left = inset,
        .top = @intFromFloat(y),
        .right = inset + thumb_w,
        .bottom = @intFromFloat(y + thumb_h),
    };
}

/// Scroll so the thumb's top sits at the given client y (drag math).
fn scrollToThumbY(self: *Scrollbar, y: i32) void {
    if (!self.scrollable()) return;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const h: f64 = @floatFromInt(@max(1, client.bottom - client.top));

    const min_thumb: f64 = @floatFromInt(self.surface.window.scale(24));
    const thumb_h = @max(min_thumb, h * @as(f64, @floatFromInt(self.len)) /
        @as(f64, @floatFromInt(self.total)));
    const range = @max(1.0, h - thumb_h);

    const frac = std.math.clamp(@as(f64, @floatFromInt(y)) / range, 0.0, 1.0);
    const row: usize = @intFromFloat(frac *
        @as(f64, @floatFromInt(self.total - self.len)));
    _ = self.surface.core_surface.performBindingAction(
        .{ .scroll_to_row = row },
    ) catch |err| {
        log.err("error in scroll_to_row err={}", .{err});
    };
}

fn paint(self: *Scrollbar, hdc: winapi.HDC) void {
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    // Track: the configured terminal background, so the column reads
    // as part of the terminal rather than a separate widget. Matching
    // the real background keeps the column invisible when there is
    // nothing to scroll (no thumb), instead of a stray dark strip.
    // Known limitation: this is the config value, so a runtime change
    // (OSC 11, theme light/dark flip) can still leave a mismatch.
    const bg = self.surface.app.config.background;
    const track: u32 = @as(u32, bg.b) << 16 | @as(u32, bg.g) << 8 | bg.r;
    if (winapi.CreateSolidBrush(track)) |b| {
        defer _ = winapi.DeleteObject(b);
        _ = winapi.FillRect(hdc, &client, b);
    }

    const thumb = self.thumbRect() orelse return;
    const active = self.hover or self.drag_grab != null;
    const color: u32 = if (active) 0x00808080 else 0x004A4A4A;

    const brush = winapi.CreateSolidBrush(color) orelse return;
    defer _ = winapi.DeleteObject(brush);
    const pen = winapi.CreatePen(winapi.PS_NULL, 0, 0);
    defer if (pen) |p| {
        _ = winapi.DeleteObject(p);
    };

    const old_brush = winapi.SelectObject(hdc, brush);
    defer if (old_brush) |o| {
        _ = winapi.SelectObject(hdc, o);
    };
    const old_pen = if (pen) |p| winapi.SelectObject(hdc, p) else null;
    defer if (old_pen) |o| {
        _ = winapi.SelectObject(hdc, o);
    };

    const radius = thumb.right - thumb.left;
    _ = winapi.RoundRect(
        hdc,
        thumb.left,
        thumb.top,
        thumb.right + 1,
        thumb.bottom + 1,
        radius,
        radius,
    );
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
    const self: *Scrollbar = @ptrFromInt(@as(usize, @bitCast(ptr)));

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

        winapi.WM_MOUSEMOVE => {
            const y = lparamY(lparam);

            if (self.drag_grab) |grab| {
                self.scrollToThumbY(y - grab);
                return 0;
            }

            if (!self.hover) {
                self.hover = true;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            if (!self.tracking) {
                var tme: winapi.TRACKMOUSEEVENT = .{
                    .dwFlags = winapi.TME_LEAVE,
                    .hwndTrack = hwnd,
                };
                if (winapi.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },

        winapi.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hover) {
                self.hover = false;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            const y = lparamY(lparam);
            const thumb = self.thumbRect() orelse return 0;

            if (y >= thumb.top and y < thumb.bottom) {
                // Grab the thumb where the cursor sits.
                self.drag_grab = y - thumb.top;
            } else {
                // Track click: jump the thumb's center to the cursor,
                // then keep dragging from its middle.
                const half = @divTrunc(thumb.bottom - thumb.top, 2);
                self.scrollToThumbY(y - half);
                self.drag_grab = half;
            }
            _ = winapi.SetCapture(hwnd);
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            return 0;
        },

        winapi.WM_LBUTTONUP => {
            if (self.drag_grab != null) {
                self.drag_grab = null;
                _ = winapi.ReleaseCapture();
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}
