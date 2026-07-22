/// Find-in-terminal UI: a small borderless popup docked to the top
/// right of the terminal area. We own only the text entry and the
/// match-count display; the core owns matching, highlighting, and
/// navigation (`search`, `navigate_search`, `end_search` binding
/// actions in; `search_total`/`search_selected` apprt actions out).
const SearchBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The search bar window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-search");

/// The window the bar is docked to.
window: *Window,

/// The surface being searched. Pinned at open; the surface closes the
/// bar in its deinit so this never dangles.
surface: *Surface,

/// The popup window.
hwnd: winapi.HWND,

/// The typed needle, as WM_CHAR delivered it (UTF-16).
needle: std.ArrayList(u16) = .empty,

/// Match state reported by the core (1-based selected).
total: ?usize = null,
selected: ?usize = null,

const width_logical: i32 = 360;
const height_logical: i32 = 40;

/// Hard cap on needle length in UTF-16 units. updateSearch converts
/// into a fixed [1024]u8 and utf16LeToUtf8 does not bounds-check its
/// destination; 3 output bytes per unit is the worst case.
const needle_max_units: usize = 1024 / 3;

pub fn create(alloc: Allocator, surface: *Surface) !*SearchBar {
    const window = surface.window;
    const self = try alloc.create(SearchBar);
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

    self.* = .{ .window = window, .surface = surface, .hwnd = hwnd };
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    self.layout();
    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOW);
    _ = winapi.SetFocus(hwnd);
    return self;
}

/// Tear down the UI. Called from the `end_search` apprt action (the
/// core owns search lifecycle; Escape etc. send the binding action and
/// the close loops back through here) and from surface teardown.
pub fn destroy(self: *SearchBar) void {
    const alloc = self.window.app.core_app.alloc;
    const window = self.window;
    window.search = null;
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    self.needle.deinit(alloc);
    alloc.destroy(self);
    _ = winapi.SetFocus(window.hwnd);
}

/// Replace the needle with the given UTF-8 text (start_search with an
/// initial needle, e.g. search_selection).
pub fn setNeedle(self: *SearchBar, needle: []const u8) void {
    const alloc = self.window.app.core_app.alloc;
    self.needle.clearRetainingCapacity();

    // Truncate to the buffer at a codepoint boundary; UTF-16 never
    // needs more units than UTF-8 bytes. Only trim when actually
    // truncating — backing off continuation bytes unconditionally
    // would strip a trailing non-ASCII character from short needles.
    // When we do cut, test the first EXCLUDED byte (needle[end]); the
    // last included byte would leave a dangling lead and fail the
    // conversion.
    var buf: [needle_max_units]u16 = undefined;
    var end = needle.len;
    if (end > buf.len) {
        end = buf.len;
        while (end > 0 and needle[end] & 0xC0 == 0x80) end -= 1;
    }
    const n = std.unicode.utf8ToUtf16Le(&buf, needle[0..end]) catch 0;
    self.needle.appendSlice(alloc, buf[0..n]) catch {};
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// Update the match counts reported by the core.
pub fn setTotal(self: *SearchBar, total: ?usize) void {
    self.total = total;
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

pub fn setSelected(self: *SearchBar, selected: ?usize) void {
    self.selected = selected;
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// Focus the text entry (start_search while already open).
pub fn focus(self: *SearchBar) void {
    _ = winapi.SetFocus(self.hwnd);
}

/// Dock to the top-right of the parent's terminal area.
pub fn layout(self: *SearchBar) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(window.hwnd, &client);
    var origin: winapi.POINT = .{ .x = 0, .y = 0 };
    _ = winapi.ClientToScreen(window.hwnd, &origin);

    const w = @min(window.scale(width_logical), client.right - window.scale(20));
    const h = window.scale(height_logical);
    _ = winapi.SetWindowPos(
        self.hwnd,
        null,
        origin.x + client.right - w - window.scale(10),
        origin.y + window.titlebarHeight() + window.scale(4),
        w,
        h,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
    );
}

/// Paste clipboard text into the needle at the cap, then re-search.
fn paste(self: *SearchBar) void {
    const alloc = self.window.app.core_app.alloc;
    var buf: [needle_max_units]u16 = undefined;
    const room = needle_max_units -| self.needle.items.len;
    if (room == 0) return;
    const n = winapi.clipboardTextUtf16(self.hwnd, buf[0..@min(room, buf.len)]);
    if (n == 0) return;
    self.needle.appendSlice(alloc, buf[0..n]) catch return;
    self.updateSearch();
}

/// Push the current needle to the core search.
fn updateSearch(self: *SearchBar) void {
    var buf: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, self.needle.items) catch 0;
    _ = self.surface.core_surface.performBindingAction(
        .{ .search = buf[0..len] },
    ) catch |err| {
        log.err("error updating search err={}", .{err});
    };
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn bindingAction(self: *SearchBar, action: input.Binding.Action) void {
    _ = self.surface.core_surface.performBindingAction(action) catch |err| {
        log.err("error in search action err={}", .{err});
    };
}

// ---------------------------------------------------------------------
// Painting

fn paint(self: *SearchBar, hdc: winapi.HDC) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    const light = window.isLight();
    const bg: u32 = if (light) 0x00F5F5F5 else 0x001F1F1F;
    const border: u32 = if (light) 0x00B0B0B0 else 0x00484848;
    const fg: u32 = if (light) 0x00000000 else 0x00FFFFFF;
    const fg_dim: u32 = if (light) 0x00505050 else 0x00A0A0A0;

    const bg_brush = winapi.CreateSolidBrush(bg) orelse return;
    defer _ = winapi.DeleteObject(bg_brush);
    _ = winapi.FillRect(hdc, &client, bg_brush);

    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);

    const font = winapi.CreateFontW(
        -window.scale(12),
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
    defer if (font) |f| {
        _ = winapi.DeleteObject(f);
    };

    const margin = window.scale(10);

    if (font) |f| {
        const old = winapi.SelectObject(hdc, f);
        defer if (old) |o| {
            _ = winapi.SelectObject(hdc, o);
        };

        // Match count, right-aligned ("3/17" or "0" when no matches).
        var count_w: i32 = 0;
        {
            var buf8: [64]u8 = undefined;
            const count = count: {
                if (self.total) |total| {
                    if (self.selected) |sel| {
                        break :count std.fmt.bufPrint(&buf8, "{d}/{d}", .{ sel, total }) catch "";
                    }
                    break :count std.fmt.bufPrint(&buf8, "{d}", .{total}) catch "";
                }
                break :count "";
            };
            if (count.len > 0) {
                var buf16: [64:0]u16 = undefined;
                const n = std.unicode.utf8ToUtf16Le(buf16[0..63], count) catch 0;
                buf16[n] = 0;
                _ = winapi.SetTextColor(hdc, fg_dim);
                var rect: winapi.RECT = .{
                    .left = margin,
                    .top = 0,
                    .right = client.right - margin,
                    .bottom = client.bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf16[0..n :0],
                    @intCast(n),
                    &rect,
                    winapi.DT_RIGHT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
                );
                var extent: winapi.SIZE = undefined;
                if (winapi.GetTextExtentPoint32W(hdc, &buf16, @intCast(n), &extent) != 0) {
                    count_w = extent.cx + window.scale(8);
                }
            }
        }

        // The needle (or placeholder) with a caret block.
        var text_rect: winapi.RECT = .{
            .left = margin,
            .top = 0,
            .right = client.right - margin - count_w,
            .bottom = client.bottom,
        };
        if (self.needle.items.len > 0) {
            _ = winapi.SetTextColor(hdc, fg);
            var buf: [512:0]u16 = undefined;
            const n = @min(self.needle.items.len, buf.len - 1);
            @memcpy(buf[0..n], self.needle.items[0..n]);
            buf[n] = 0;
            _ = winapi.DrawTextW(
                hdc,
                buf[0..n :0],
                @intCast(n),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
            var extent: winapi.SIZE = undefined;
            if (winapi.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &extent) != 0) {
                var caret: winapi.RECT = .{
                    .left = margin + extent.cx + window.scale(1),
                    .top = @divTrunc(client.bottom - extent.cy, 2),
                    .right = margin + extent.cx + window.scale(3),
                    .bottom = @divTrunc(client.bottom + extent.cy, 2),
                };
                if (winapi.CreateSolidBrush(fg)) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &caret, b);
                }
            }
        } else {
            _ = winapi.SetTextColor(hdc, fg_dim);
            const placeholder = std.unicode.utf8ToUtf16LeStringLiteral("Find\u{2026}");
            _ = winapi.DrawTextW(
                hdc,
                placeholder,
                @intCast(placeholder.len),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
        }
    }

    if (winapi.CreateSolidBrush(border)) |b| {
        defer _ = winapi.DeleteObject(b);
        _ = winapi.FrameRect(hdc, &client, b);
    }
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
    const self: *SearchBar = @ptrFromInt(@as(usize, @bitCast(ptr)));

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
                // The core owns the search lifecycle: it answers with
                // the end_search apprt action, which destroys us.
                winapi.VK_ESCAPE => self.bindingAction(.end_search),
                winapi.VK_RETURN => self.bindingAction(.{
                    .navigate_search = if (winapi.GetKeyState(winapi.VK_SHIFT) < 0)
                        .previous
                    else
                        .next,
                }),
                winapi.VK_UP => self.bindingAction(.{ .navigate_search = .previous }),
                winapi.VK_DOWN => self.bindingAction(.{ .navigate_search = .next }),
                // Ctrl+V pastes clipboard text into the needle.
                'V' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) self.paste(),
                else => {},
            }
            return 0;
        },

        winapi.WM_CHAR => {
            const alloc = self.window.app.core_app.alloc;
            const ch: u16 = @truncate(wparam);
            if (ch == 0x08) {
                if (self.needle.pop()) |unit| {
                    if (unit >= 0xDC00 and unit <= 0xDFFF) _ = self.needle.pop();
                    self.updateSearch();
                }
            } else if (ch >= 0x20 and ch != 0x7F) {
                // Enforce the fixed-buffer cap; a surrogate lead needs
                // room for its trail too (a trail always pairs with an
                // admitted lead, so it is never refused alone).
                const lead = ch >= 0xD800 and ch <= 0xDBFF;
                const trail = ch >= 0xDC00 and ch <= 0xDFFF;
                const need: usize = if (lead) 2 else 1;
                if (!trail and self.needle.items.len + need > needle_max_units)
                    return 0;
                self.needle.append(alloc, ch) catch return 0;
                self.updateSearch();
            }
            return 0;
        },

        winapi.WM_KILLFOCUS => {
            // Focus moving back to the terminal keeps the search (and
            // its highlights) alive, like other terminals; only an
            // explicit end_search or surface close dismisses.
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
