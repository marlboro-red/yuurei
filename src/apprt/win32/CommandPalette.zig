/// A native command palette: a borderless popup over the parent window
/// with a typed filter and a selectable list of commands from the
/// `command-palette-entry` config (defaults to every named binding
/// action). Enter or click performs the selected command on the
/// window's focused surface; Escape or focus loss dismisses.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The palette window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-palette");

/// The window the palette is summoned over.
window: *Window,

/// The popup window.
hwnd: winapi.HWND,

/// The typed filter, as WM_CHAR delivered it (UTF-16).
filter: std.ArrayList(u16) = .empty,

/// Indices into commands() matching the filter, in command order.
matches: std.ArrayList(usize) = .empty,

/// Index into matches of the highlighted row.
selected: usize = 0,

/// Index into matches of the first visible row.
scroll: usize = 0,

/// Cached fonts, recreated on DPI change. The palette repaints on every
/// keystroke; re-creating fonts each paint is measurable GDI churn.
font_title: ?*anyopaque = null,
font_desc: ?*anyopaque = null,
font_dpi: u32 = 0,

/// Logical (96-dpi) metrics, scaled by the parent window DPI.
const width_logical: i32 = 560;
const input_height_logical: i32 = 40;
const row_height_logical: i32 = 44;
const max_visible_rows: usize = 8;

/// Hard cap on filter length in UTF-16 units. refilter converts into a
/// fixed [512]u8 and utf16LeToUtf8 does not bounds-check its
/// destination; 3 output bytes per unit is the worst case.
const filter_max_units: usize = 512 / 3;

pub fn create(alloc: Allocator, window: *Window) !*CommandPalette {
    const self = try alloc.create(CommandPalette);
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

    self.refilter();
    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOW);
    // No SetFocus here: the caller assigns window.palette first, then
    // focuses, so the parent's WM_KILLFOCUS sees consistent state.
    return self;
}

/// Dismiss the palette without giving focus back to the parent (the
/// focus-loss path, and the tail of every other path).
pub fn destroy(self: *CommandPalette) void {
    const alloc = self.window.app.core_app.alloc;
    self.window.palette = null;
    if (self.font_title) |f| _ = winapi.DeleteObject(f);
    if (self.font_desc) |f| _ = winapi.DeleteObject(f);
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    self.filter.deinit(alloc);
    self.matches.deinit(alloc);
    alloc.destroy(self);
}

/// Dismiss the palette and return focus to the parent window.
fn dismiss(self: *CommandPalette) void {
    const window = self.window;
    self.destroy();
    _ = winapi.SetFocus(window.hwnd);
}

/// Perform the selected entry: a core command on the focused surface,
/// or a profile spawn for the appended profile rows.
fn execute(self: *CommandPalette) void {
    const window = self.window;
    if (self.matches.items.len == 0) return self.dismiss();
    const idx = self.matches.items[self.selected];
    const cmds = self.commands();

    if (idx >= cmds.len) {
        const pi = idx - cmds.len;
        self.dismiss();
        const list = window.app.ensureProfiles();
        if (pi < list.items.len) {
            _ = window.newTabWithProfile(&list.items[pi]) catch |err| {
                log.err("error opening profile tab err={}", .{err});
            };
        }
        return;
    }

    const action = cmds[idx].action;
    self.dismiss();
    const surface = window.activeSurface() orelse return;
    _ = surface.core_surface.performBindingAction(action) catch |err| {
        log.err("error performing palette action err={}", .{err});
    };
}

fn commands(self: *const CommandPalette) []const input.Command {
    return self.window.app.config.@"command-palette-entry".value.items;
}

/// A resolved palette row: core commands first, then one "New Tab:"
/// row per profile.
const EntryRef = struct {
    title: []const u8,
    description: []const u8,
    action: ?input.Binding.Action,
    /// Shortcut label override for profile rows (core rows resolve
    /// theirs from the keybind set).
    label: ?[]const u8,
};

fn entryCount(self: *const CommandPalette) usize {
    return self.commands().len +
        self.window.app.ensureProfiles().items.len;
}

fn entryAt(
    self: *const CommandPalette,
    i: usize,
    title_buf: []u8,
    label_buf: []u8,
) EntryRef {
    const cmds = self.commands();
    if (i < cmds.len) return .{
        .title = cmds[i].title,
        .description = cmds[i].description,
        .action = cmds[i].action,
        .label = null,
    };
    const list = self.window.app.ensureProfiles();
    const pi = i - cmds.len;
    const p = &list.items[pi];
    return .{
        .title = std.fmt.bufPrint(title_buf, "New Tab: {s}", .{p.name}) catch
            p.name,
        .description = p.hint,
        .action = null,
        .label = if (pi < 9)
            std.fmt.bufPrint(label_buf, "ctrl+shift+{d}", .{pi + 1}) catch null
        else
            null,
    };
}

/// The keybinding bound to `action`, formatted (e.g. "ctrl+shift+p"),
/// or null if unbound. Uses the config's reverse action→trigger map.
fn keybindLabel(
    self: *const CommandPalette,
    action: input.Binding.Action,
    buf: []u8,
) ?[]const u8 {
    const trigger = self.window.app.config.keybind.set.reverse.get(action) orelse
        return null;
    return std.fmt.bufPrint(buf, "{f}", .{trigger}) catch null;
}

/// Recompute matches for the current filter (case-insensitive substring
/// of the title or description) and fit the popup to them.
/// Paste clipboard text into the filter at the cap, then re-filter.
fn paste(self: *CommandPalette) void {
    const alloc = self.window.app.core_app.alloc;
    var buf: [filter_max_units]u16 = undefined;
    const room = filter_max_units -| self.filter.items.len;
    if (room == 0) return;
    const n = winapi.clipboardTextUtf16(self.hwnd, buf[0..@min(room, buf.len)]);
    if (n == 0) return;
    self.filter.appendSlice(alloc, buf[0..n]) catch return;
    self.refilter();
}

/// Fuzzy subsequence score of `needle` within `haystack` (ASCII
/// case-insensitive). null if not a subsequence at all. Higher is
/// better: bonuses for consecutive matches and matches at word starts,
/// so "nt" ranks "New Tab" above an incidental "n...t..." match.
fn fuzzyScore(needle: []const u8, haystack: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    var score: i32 = 0;
    var ni: usize = 0;
    var prev_match = false;
    var prev_char: u8 = ' ';
    for (haystack) |hc| {
        if (ni >= needle.len) break;
        if (std.ascii.toLower(needle[ni]) == std.ascii.toLower(hc)) {
            score += 1;
            if (prev_match) score += 3;
            if (prev_char == ' ' or prev_char == '-' or
                prev_char == '_' or prev_char == ':') score += 6;
            ni += 1;
            prev_match = true;
        } else prev_match = false;
        prev_char = hc;
    }
    if (ni < needle.len) return null;
    // Slight preference for tighter (shorter) matches.
    return score - @as(i32, @intCast(@min(haystack.len / 4, 16)));
}

const Scored = struct { i: usize, score: i32 };

fn scoreLessThan(_: void, a: Scored, b: Scored) bool {
    // Higher score first; stable by original index on ties.
    if (a.score != b.score) return a.score > b.score;
    return a.i < b.i;
}

fn refilter(self: *CommandPalette) void {
    const alloc = self.window.app.core_app.alloc;
    self.matches.clearRetainingCapacity();

    var buf: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, self.filter.items) catch 0;
    const needle = buf[0..len];

    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);

    var title_buf: [256]u8 = undefined;
    var label_buf: [32]u8 = undefined;
    for (0..self.entryCount()) |i| {
        const entry = self.entryAt(i, &title_buf, &label_buf);
        if (needle.len == 0) {
            scored.append(alloc, .{ .i = i, .score = 0 }) catch return;
            continue;
        }
        // Best of title (preferred) and description (penalized).
        var best: ?i32 = fuzzyScore(needle, entry.title);
        if (fuzzyScore(needle, entry.description)) |d| {
            const dp = d - 8;
            if (best == null or dp > best.?) best = dp;
        }
        if (best) |s| scored.append(alloc, .{ .i = i, .score = s }) catch return;
    }

    if (needle.len > 0) std.mem.sort(Scored, scored.items, {}, scoreLessThan);
    for (scored.items) |s| self.matches.append(alloc, s.i) catch return;

    self.selected = 0;
    self.scroll = 0;
    self.layout();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn visibleRows(self: *const CommandPalette) usize {
    return @min(self.matches.items.len, max_visible_rows);
}

/// Size and position the popup over the parent: centered horizontally,
/// just below the title strip, shrinking with the match count.
fn layout(self: *CommandPalette) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(window.hwnd, &client);
    var origin: winapi.POINT = .{ .x = 0, .y = 0 };
    _ = winapi.ClientToScreen(window.hwnd, &origin);

    const client_w = client.right - client.left;
    const w = @min(window.scale(width_logical), client_w - window.scale(40));
    const h = window.scale(input_height_logical) +
        @as(i32, @intCast(self.visibleRows())) * window.scale(row_height_logical);

    _ = winapi.SetWindowPos(
        self.hwnd,
        null,
        origin.x + @divTrunc(client_w - w, 2),
        origin.y + window.titlebarHeight() + window.scale(4),
        w,
        h,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
    );
}

/// Move the highlight, keeping it visible.
fn moveSelection(self: *CommandPalette, delta: i32) void {
    const count = self.matches.items.len;
    if (count == 0) return;
    const max: i32 = @intCast(count - 1);
    self.selected = @intCast(std.math.clamp(
        @as(i32, @intCast(self.selected)) + delta,
        0,
        max,
    ));
    if (self.selected < self.scroll) self.scroll = self.selected;
    const visible = self.visibleRows();
    if (self.selected >= self.scroll + visible)
        self.scroll = self.selected - visible + 1;
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// The match row at a client y, if any.
fn rowAt(self: *const CommandPalette, y: i32) ?usize {
    const top = self.window.scale(input_height_logical);
    if (y < top) return null;
    const row = self.scroll +
        @as(usize, @intCast(@divTrunc(y - top, self.window.scale(row_height_logical))));
    if (row >= self.matches.items.len) return null;
    return row;
}

// ---------------------------------------------------------------------
// Painting

/// (Re)create the cached title/description fonts for the current DPI.
fn ensureFonts(self: *CommandPalette) void {
    const dpi = winapi.GetDpiForWindow(self.hwnd);
    if (self.font_dpi == dpi and self.font_title != null) return;
    if (self.font_title) |f| _ = winapi.DeleteObject(f);
    if (self.font_desc) |f| _ = winapi.DeleteObject(f);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.font_title = winapi.CreateFontW(-self.window.scale(13), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_desc = winapi.CreateFontW(-self.window.scale(10), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_dpi = dpi;
}

fn paint(self: *CommandPalette, hdc: winapi.HDC) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

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
    const title_font = self.font_title;
    const desc_font = self.font_desc;

    const margin = window.scale(12);
    const input_h = window.scale(input_height_logical);
    const row_h = window.scale(row_height_logical);

    // Filter row: typed text (with a caret block) or a placeholder.
    if (title_font) |f| {
        const old = winapi.SelectObject(hdc, f);
        defer if (old) |o| {
            _ = winapi.SelectObject(hdc, o);
        };

        var text_rect: winapi.RECT = .{
            .left = margin,
            .top = 0,
            .right = client.right - margin,
            .bottom = input_h,
        };
        if (self.filter.items.len > 0) {
            _ = winapi.SetTextColor(hdc, fg);
            var buf: [512:0]u16 = undefined;
            const n = @min(self.filter.items.len, buf.len - 1);
            @memcpy(buf[0..n], self.filter.items[0..n]);
            buf[n] = 0;
            _ = winapi.DrawTextW(
                hdc,
                buf[0..n :0],
                @intCast(n),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );

            // Caret after the text.
            var extent: winapi.SIZE = undefined;
            if (winapi.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &extent) != 0) {
                var caret: winapi.RECT = .{
                    .left = margin + extent.cx + window.scale(1),
                    .top = @divTrunc(input_h - extent.cy, 2),
                    .right = margin + extent.cx + window.scale(3),
                    .bottom = @divTrunc(input_h + extent.cy, 2),
                };
                if (winapi.CreateSolidBrush(fg)) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &caret, b);
                }
            }
        } else {
            _ = winapi.SetTextColor(hdc, fg_dim);
            const placeholder = std.unicode.utf8ToUtf16LeStringLiteral(
                "Type a command\u{2026}",
            );
            _ = winapi.DrawTextW(
                hdc,
                placeholder,
                @intCast(placeholder.len),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
        }
    }

    // Separator under the filter row.
    {
        var sep: winapi.RECT = .{
            .left = 0,
            .top = input_h - 1,
            .right = client.right,
            .bottom = input_h,
        };
        const sep_brush = winapi.CreateSolidBrush(border);
        if (sep_brush) |b| {
            defer _ = winapi.DeleteObject(b);
            _ = winapi.FillRect(hdc, &sep, b);
        }
    }

    // Match rows: title with the description below it, dim.
    const end = @min(self.scroll + self.visibleRows(), self.matches.items.len);
    for (self.matches.items[self.scroll..end], self.scroll..) |cmd_idx, row| {
        var title_buf: [256]u8 = undefined;
        var label_buf: [32]u8 = undefined;
        const cmd = self.entryAt(cmd_idx, &title_buf, &label_buf);
        const top = input_h + @as(i32, @intCast(row - self.scroll)) * row_h;

        if (row == self.selected) {
            var row_rect: winapi.RECT = .{
                .left = 0,
                .top = top,
                .right = client.right,
                .bottom = top + row_h,
            };
            const brush = winapi.CreateSolidBrush(select_bg);
            if (brush) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &row_rect, b);
            }
        }

        // The keybinding accelerator (right-aligned on the title line);
        // reserve room on the title's right so it doesn't overlap.
        var kb_buf: [64]u8 = undefined;
        const kb_label = cmd.label orelse if (cmd.action) |action|
            self.keybindLabel(action, &kb_buf)
        else
            null;
        const kb_reserve: i32 = if (kb_label != null) window.scale(120) else 0;
        const title_bottom = top + @divTrunc(row_h, 2) + window.scale(4);

        var buf: [512]u16 = undefined;
        if (title_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, fg);
            const n = std.unicode.utf8ToUtf16Le(
                buf[0 .. buf.len - 1],
                // Config entry titles are unbounded; cap before the
                // fixed-buffer conversion (no destination bounds check).
                Window.utf8Capped(cmd.title, buf.len - 1),
            ) catch 0;
            if (n > 0) {
                buf[n] = 0;
                var rect: winapi.RECT = .{
                    .left = margin,
                    .top = top + window.scale(4),
                    .right = client.right - margin - kb_reserve,
                    .bottom = title_bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..n :0],
                    @intCast(n),
                    &rect,
                    winapi.DT_LEFT | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
        }
        if (kb_label) |label| if (desc_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, fg_dim);
            var kbuf: [128]u16 = undefined;
            const kn = std.unicode.utf8ToUtf16Le(kbuf[0 .. kbuf.len - 1], label) catch 0;
            if (kn > 0) {
                kbuf[kn] = 0;
                var rect: winapi.RECT = .{
                    .left = client.right - margin - kb_reserve,
                    .top = top + window.scale(4),
                    .right = client.right - margin,
                    .bottom = title_bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    kbuf[0..kn :0],
                    @intCast(kn),
                    &rect,
                    winapi.DT_RIGHT | winapi.DT_SINGLELINE,
                );
            }
        };
        if (desc_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, fg_dim);
            const n = std.unicode.utf8ToUtf16Le(
                buf[0 .. buf.len - 1],
                Window.utf8Capped(cmd.description, buf.len - 1),
            ) catch 0;
            if (n > 0) {
                buf[n] = 0;
                var rect: winapi.RECT = .{
                    .left = margin,
                    .top = top + @divTrunc(row_h, 2) + window.scale(2),
                    .right = client.right - margin,
                    .bottom = top + row_h,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..n :0],
                    @intCast(n),
                    &rect,
                    winapi.DT_LEFT | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
        }
    }

    // Border.
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
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));

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
                winapi.VK_PRIOR => self.moveSelection(
                    -@as(i32, @intCast(max_visible_rows)),
                ),
                winapi.VK_NEXT => self.moveSelection(
                    @as(i32, @intCast(max_visible_rows)),
                ),
                // Ctrl+V pastes clipboard text into the filter.
                'V' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) self.paste(),
                else => {},
            }
            return 0;
        },

        winapi.WM_CHAR => {
            const alloc = self.window.app.core_app.alloc;
            const ch: u16 = @truncate(wparam);
            if (ch == 0x08) {
                // Backspace: drop one codepoint (both surrogate halves).
                if (self.filter.pop()) |unit| {
                    if (unit >= 0xDC00 and unit <= 0xDFFF) _ = self.filter.pop();
                    self.refilter();
                }
            } else if (ch >= 0x20 and ch != 0x7F) {
                // Enforce the fixed-buffer cap; a surrogate lead needs
                // room for its trail too (a trail always pairs with an
                // admitted lead, so it is never refused alone).
                const lead = ch >= 0xD800 and ch <= 0xDBFF;
                const trail = ch >= 0xDC00 and ch <= 0xDFFF;
                const need: usize = if (lead) 2 else 1;
                if (!trail and self.filter.items.len + need > filter_max_units)
                    return 0;
                self.filter.append(alloc, ch) catch return 0;
                self.refilter();
            }
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            if (self.rowAt(lparamY(lparam))) |row| {
                if (row != self.selected) {
                    self.selected = row;
                    _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
                }
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            if (self.rowAt(lparamY(lparam))) |row| {
                self.selected = row;
                self.execute();
            }
            return 0;
        },

        winapi.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const rows: i32 = if (delta > 0) -3 else 3;
            const count = self.matches.items.len;
            const visible = self.visibleRows();
            if (count > visible) {
                const max_scroll: i32 = @intCast(count - visible);
                self.scroll = @intCast(std.math.clamp(
                    @as(i32, @intCast(self.scroll)) + rows,
                    0,
                    max_scroll,
                ));
                self.selected = std.math.clamp(
                    self.selected,
                    self.scroll,
                    self.scroll + visible - 1,
                );
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
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
