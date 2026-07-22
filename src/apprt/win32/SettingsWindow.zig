//! Native settings window (yuurei), custom-drawn to match the command
//! palette / search bar: a theme-aware (light/dark) dialog with rounded
//! "pill" dropdowns (each opening a styled list popup), a custom
//! checkbox, and rounded buttons, under a dark native title bar. Pure
//! GDI — no DirectComposition, swapchain, or GL — so unlike the parked
//! acrylic work it carries no compositor-hang risk.
//!
//! It operates on the config FILE as text: current values are read to
//! pre-select the controls, and a change rewrites the relevant
//! `key = value` line (preserving comments and every other line) then
//! triggers a normal config reload, so edits apply live. The file stays
//! the source of truth; "Open config file" is the escape hatch.
const SettingsWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");
const configpkg = @import("../../config.zig");
const global_state = &@import("../../global.zig").state;

const log = std.log.scoped(.win32);

/// Registered once by App (along with DropdownPopup.class_name).
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-settings");

const font_sizes = [_][]const u8{
    "8", "9", "10", "11", "12", "13", "14", "16", "18", "20", "24",
};
const cursor_styles = [_][]const u8{ "block", "bar", "underline" };
const opacities = [_][]const u8{
    "1.0", "0.95", "0.9", "0.85", "0.8", "0.75", "0.7", "0.65", "0.6",
};

/// The dropdown rows, in display order.
const Field = enum { theme, font_family, font_size, cursor, opacity };

const Palette = struct {
    bg: u32,
    card: u32,
    card_hover: u32,
    border: u32,
    fg: u32,
    fg_dim: u32,
    accent: u32,
    sel: u32,

    fn current(window: *const Window) Palette {
        return if (window.isLight()) .{
            .bg = 0x00F3F3F3,
            .card = 0x00FFFFFF,
            .card_hover = 0x00ECECEC,
            .border = 0x00C8C8C8,
            .fg = 0x00202020,
            .fg_dim = 0x00606060,
            .accent = 0x00C57A3C,
            .sel = 0x00EAD9C8,
        } else .{
            .bg = 0x001C1C1C,
            .card = 0x002A2A2A,
            .card_hover = 0x00343434,
            .border = 0x00454545,
            .fg = 0x00F0F0F0,
            .fg_dim = 0x009A9A9A,
            .accent = 0x00D08A4C,
            .sel = 0x00403524,
        };
    }
};

/// Hover targets for highlight.
const Hot = enum { none, theme, font_family, font_size, cursor, opacity, blink, blur, open, close };

app: *App,
window: *Window,
hwnd: winapi.HWND,
font: ?*anyopaque = null,

arena: std.heap.ArenaAllocator,
themes: [][]const u8 = &.{},
fonts: [][]const u8 = &.{},

theme_idx: ?usize = null,
font_family_idx: ?usize = null,
font_idx: ?usize = null,
cursor_idx: ?usize = null,
opacity_idx: ?usize = null,
blink: bool = false,
blur: bool = false,

hot: Hot = .none,
tracking: bool = false,
dropdown: ?*DropdownPopup = null,

// Layout rects in client coords, filled by computeLayout().
client_w: i32 = 0,
pills: [5]winapi.RECT = undefined,
blink_rect: winapi.RECT = undefined,
blur_rect: winapi.RECT = undefined,
open_rect: winapi.RECT = undefined,
close_rect: winapi.RECT = undefined,

pub fn create(alloc: Allocator, window: *Window) !*SettingsWindow {
    const app = window.app;
    const self = try alloc.create(SettingsWindow);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .window = window,
        .hwnd = undefined,
        .arena = .init(alloc),
    };
    errdefer self.arena.deinit();

    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("yuurei Settings"),
        winapi.WS_CAPTION | winapi.WS_SYSMENU,
        winapi.CW_USEDEFAULT,
        winapi.CW_USEDEFAULT,
        window.scale(400),
        window.scale(400),
        window.hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);
    self.hwnd = hwnd;

    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    // Dark caption to match the dark client area (Win11 22H2+).
    const dark: winapi.BOOL = if (window.isLight()) winapi.FALSE else winapi.TRUE;
    _ = winapi.DwmSetWindowAttribute(
        hwnd,
        winapi.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(winapi.BOOL),
    );

    self.font = winapi.CreateFontW(
        -window.scale(14),
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

    self.collectThemes();
    self.collectFonts();
    self.loadCurrentValues();

    // Lay out at the desired client width, then resize the window so the
    // client area exactly fits the content and center it on the parent.
    self.computeLayout(window.scale(400));
    self.fitAndCenter();

    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);
    _ = winapi.SetFocus(hwnd);
    return self;
}

/// Close the window. Teardown happens in WM_DESTROY (cleanup) so the
/// same path covers the owner window being destroyed while we're open.
pub fn destroy(self: *SettingsWindow) void {
    _ = winapi.DestroyWindow(self.hwnd);
}

fn cleanup(self: *SettingsWindow) void {
    const alloc = self.app.core_app.alloc;
    if (self.dropdown) |d| d.destroy();
    self.app.settings = null;
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    if (self.font) |f| _ = winapi.DeleteObject(f);
    self.arena.deinit();
    alloc.destroy(self);
}

// ---------------------------------------------------------------------
// Layout

fn computeLayout(self: *SettingsWindow, client_w: i32) void {
    const win = self.window;
    self.client_w = client_w;
    const pad = win.scale(22);
    const pill_x = win.scale(168);
    const pill_w = client_w - pill_x - pad;
    const pill_h = win.scale(36);
    const pitch = win.scale(52);
    var y = win.scale(20);

    for (&self.pills) |*r| {
        r.* = .{ .left = pill_x, .top = y, .right = pill_x + pill_w, .bottom = y + pill_h };
        y += pitch;
    }

    self.blink_rect = .{
        .left = pad,
        .top = y,
        .right = pad + win.scale(220),
        .bottom = y + win.scale(28),
    };
    y += win.scale(40);

    self.blur_rect = .{
        .left = pad,
        .top = y,
        .right = pad + win.scale(220),
        .bottom = y + win.scale(28),
    };
    y += pitch;

    const btn_w = win.scale(150);
    const btn_h = win.scale(38);
    self.open_rect = .{ .left = pad, .top = y, .right = pad + btn_w, .bottom = y + btn_h };
    self.close_rect = .{ .left = client_w - pad - btn_w, .top = y, .right = client_w - pad, .bottom = y + btn_h };
}

fn contentHeight(self: *const SettingsWindow) i32 {
    return self.close_rect.bottom + self.window.scale(22);
}

/// Resize the window so its client area matches the computed content,
/// then center it on the parent.
fn fitAndCenter(self: *SettingsWindow) void {
    var wr: winapi.RECT = undefined;
    var cr: winapi.RECT = undefined;
    _ = winapi.GetWindowRect(self.hwnd, &wr);
    _ = winapi.GetClientRect(self.hwnd, &cr);
    const nc_w = (wr.right - wr.left) - (cr.right - cr.left);
    const nc_h = (wr.bottom - wr.top) - (cr.bottom - cr.top);
    const w = self.client_w + nc_w;
    const h = self.contentHeight() + nc_h;

    var pr: winapi.RECT = undefined;
    _ = winapi.GetWindowRect(self.window.hwnd, &pr);
    const x = pr.left + @divTrunc((pr.right - pr.left) - w, 2);
    const y = pr.top + @divTrunc((pr.bottom - pr.top) - h, 2);
    _ = winapi.SetWindowPos(self.hwnd, null, x, y, w, h, winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE);
}

// ---------------------------------------------------------------------
// Config plumbing

fn collectThemes(self: *SettingsWindow) void {
    const arena = self.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;

    const res = global_state.resources_dir.app() orelse return;
    const dir_path = std.fs.path.join(arena, &.{ res, "themes" }) catch return;
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
        log.info("settings: no themes dir at {s}", .{dir_path});
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = arena.dupe(u8, entry.name) catch continue;
        names.append(arena, name) catch continue;
    }

    std.mem.sort([]const u8, names.items, {}, lessThanName);
    self.themes = names.toOwnedSlice(arena) catch &.{};
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Collector for EnumFontFamiliesExW (the C callback can't capture).
const FontCollector = struct {
    alloc: Allocator,
    list: *std.ArrayList([]const u8),
};

fn fontEnumProc(
    lf: *const winapi.LOGFONTW,
    tm: *const anyopaque,
    font_type: winapi.DWORD,
    lparam: winapi.LPARAM,
) callconv(.winapi) i32 {
    _ = tm;
    _ = font_type;
    const c: *FontCollector = @ptrFromInt(@as(usize, @bitCast(lparam)));
    // Monospace only (terminal use), and skip '@'-prefixed vertical fonts.
    if ((lf.lfPitchAndFamily & 0x03) != winapi.FIXED_PITCH) return 1;
    if (lf.lfFaceName[0] == 0 or lf.lfFaceName[0] == '@') return 1;
    var n: usize = 0;
    while (n < lf.lfFaceName.len and lf.lfFaceName[n] != 0) : (n += 1) {}
    var buf: [128]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, lf.lfFaceName[0..n]) catch return 1;
    const name = c.alloc.dupe(u8, buf[0..len]) catch return 1;
    c.list.append(c.alloc, name) catch return 1;
    return 1; // continue enumeration
}

/// Enumerate installed monospace font families for the Font dropdown.
fn collectFonts(self: *SettingsWindow) void {
    const arena = self.arena.allocator();
    const hdc = winapi.GetDC(null) orelse return;
    defer _ = winapi.ReleaseDC(null, hdc);

    var names: std.ArrayList([]const u8) = .empty;
    var collector: FontCollector = .{ .alloc = arena, .list = &names };
    var lf: winapi.LOGFONTW = .{ .lfCharSet = winapi.DEFAULT_CHARSET };
    _ = winapi.EnumFontFamiliesExW(
        hdc,
        &lf,
        fontEnumProc,
        @bitCast(@intFromPtr(&collector)),
        0,
    );

    std.mem.sort([]const u8, names.items, {}, lessThanName);
    // EnumFontFamiliesEx can repeat a family per charset; dedup adjacent.
    var deduped: std.ArrayList([]const u8) = .empty;
    for (names.items, 0..) |name, i| {
        if (i > 0 and std.mem.eql(u8, name, names.items[i - 1])) continue;
        deduped.append(arena, name) catch continue;
    }
    self.fonts = deduped.toOwnedSlice(arena) catch &.{};
}

fn loadCurrentValues(self: *SettingsWindow) void {
    const alloc = self.app.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch return;
    defer alloc.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    const text = file.readToEndAlloc(alloc, 4 << 20) catch {
        file.close();
        return;
    };
    file.close();
    defer alloc.free(text);

    if (configValue(text, "theme")) |v| self.theme_idx = indexOf(self.themes, v);
    if (configValue(text, "font-family")) |v| self.font_family_idx = indexOf(self.fonts, v);
    if (configValue(text, "font-size")) |v| self.font_idx = indexOf(&font_sizes, v);
    if (configValue(text, "cursor-style")) |v| self.cursor_idx = indexOf(&cursor_styles, v);
    if (configValue(text, "background-opacity")) |v| self.opacity_idx = indexOf(&opacities, v);
    if (configValue(text, "cursor-style-blink")) |v| self.blink = std.ascii.eqlIgnoreCase(v, "true");
    if (configValue(text, "background-blur")) |v| {
        self.blur = !std.ascii.eqlIgnoreCase(v, "false") and !std.mem.eql(u8, v, "0");
    }
}

fn indexOf(values: []const []const u8, current: []const u8) ?usize {
    for (values, 0..) |v, i| if (std.mem.eql(u8, v, current)) return i;
    return null;
}

fn configValue(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, k, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

/// Rewrite `key = value` in the config file (first active occurrence,
/// else appended), preserving every other line, then reload.
fn setValue(self: *SettingsWindow, key: []const u8, value: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("settings: cannot resolve config path err={}", .{err});
        return;
    };
    defer alloc.free(path);

    const text: []u8 = if (std.fs.openFileAbsolute(path, .{})) |file| blk: {
        defer file.close();
        break :blk file.readToEndAlloc(alloc, 4 << 20) catch &.{};
    } else |_| &.{};
    defer if (text.len > 0) alloc.free(text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var replaced = false;
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (!first) out.append(alloc, '\n') catch return;
        first = false;
        if (!replaced) {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] != '#') {
                if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                    const k = std.mem.trim(u8, line[0..eq], " \t");
                    if (std.mem.eql(u8, k, key)) {
                        out.appendSlice(alloc, key) catch return;
                        out.appendSlice(alloc, " = ") catch return;
                        out.appendSlice(alloc, value) catch return;
                        replaced = true;
                        continue;
                    }
                }
            }
        }
        out.appendSlice(alloc, raw) catch return;
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n')
            out.append(alloc, '\n') catch return;
        out.appendSlice(alloc, key) catch return;
        out.appendSlice(alloc, " = ") catch return;
        out.appendSlice(alloc, value) catch return;
        out.append(alloc, '\n') catch return;
    }

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        log.warn("settings: open config for write failed err={}", .{err});
        return;
    };
    defer file.close();
    file.writeAll(out.items) catch |err| {
        log.warn("settings: write config failed err={}", .{err});
        return;
    };

    if (self.app.performAction(.app, .reload_config, .{})) |_| {} else |err| {
        log.warn("settings: reload failed err={}", .{err});
    }
}

/// Called by the dropdown popup when an item is chosen.
fn onDropdownResult(self: *SettingsWindow, field: Field, idx: usize) void {
    switch (field) {
        .theme => {
            if (idx >= self.themes.len) return;
            self.theme_idx = idx;
            self.setValue("theme", self.themes[idx]);
        },
        .font_family => {
            if (idx >= self.fonts.len) return;
            self.font_family_idx = idx;
            self.setValue("font-family", self.fonts[idx]);
        },
        .font_size => {
            self.font_idx = idx;
            self.setValue("font-size", font_sizes[idx]);
        },
        .cursor => {
            self.cursor_idx = idx;
            self.setValue("cursor-style", cursor_styles[idx]);
        },
        .opacity => {
            self.opacity_idx = idx;
            self.setValue("background-opacity", opacities[idx]);
        },
    }
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn fieldItems(self: *const SettingsWindow, field: Field) []const []const u8 {
    return switch (field) {
        .theme => self.themes,
        .font_family => self.fonts,
        .font_size => &font_sizes,
        .cursor => &cursor_styles,
        .opacity => &opacities,
    };
}

fn fieldIndex(self: *const SettingsWindow, field: Field) ?usize {
    return switch (field) {
        .theme => self.theme_idx,
        .font_family => self.font_family_idx,
        .font_size => self.font_idx,
        .cursor => self.cursor_idx,
        .opacity => self.opacity_idx,
    };
}

// ---------------------------------------------------------------------
// Painting

const labels = [_][]const u8{ "Theme", "Font", "Font size", "Cursor style", "Background opacity" };

fn paint(self: *SettingsWindow, hdc: winapi.HDC) void {
    const win = self.window;
    const p = Palette.current(win);
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    fillRect(hdc, client, p.bg);
    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);
    const old_font = if (self.font) |f| winapi.SelectObject(hdc, f) else null;
    defer if (old_font) |o| {
        _ = winapi.SelectObject(hdc, o);
    };

    const pad = win.scale(22);

    // Dropdown rows: label on the left, value pill on the right.
    inline for (0..5) |i| {
        const field: Field = @enumFromInt(i);
        var lr: winapi.RECT = .{
            .left = pad,
            .top = self.pills[i].top,
            .right = self.pills[i].left - win.scale(8),
            .bottom = self.pills[i].bottom,
        };
        drawText(hdc, labels[i], &lr, p.fg, winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE);

        const hovered = self.hot == hotForField(field);
        roundRect(hdc, self.pills[i], if (hovered) p.card_hover else p.card, p.border, win.scale(7));

        const val: []const u8 = if (self.fieldIndex(field)) |idx|
            self.fieldItems(field)[idx]
        else
            "default";
        var vr: winapi.RECT = .{
            .left = self.pills[i].left + win.scale(12),
            .top = self.pills[i].top,
            .right = self.pills[i].right - win.scale(28),
            .bottom = self.pills[i].bottom,
        };
        drawText(
            hdc,
            val,
            &vr,
            if (self.fieldIndex(field) == null) p.fg_dim else p.fg,
            winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
        );

        // Chevron.
        const cx = self.pills[i].right - win.scale(16);
        const cy = @divTrunc(self.pills[i].top + self.pills[i].bottom, 2);
        const d = win.scale(4);
        const chevron = [_]winapi.POINT{
            .{ .x = cx - d, .y = cy - @divTrunc(d, 2) },
            .{ .x = cx, .y = cy + @divTrunc(d, 2) },
            .{ .x = cx + d, .y = cy - @divTrunc(d, 2) },
        };
        polyline(hdc, &chevron, p.fg_dim, win.scale(2));
    }

    // Checkbox rows.
    self.paintCheckbox(hdc, self.blink_rect, self.blink, self.hot == .blink, "Blink the cursor", p);
    self.paintCheckbox(hdc, self.blur_rect, self.blur, self.hot == .blur, "Background blur", p);

    // Buttons.
    self.paintButton(hdc, self.open_rect, "Open config file\u{2026}", self.hot == .open, p);
    self.paintButton(hdc, self.close_rect, "Close", self.hot == .close, p);
}

fn paintCheckbox(self: *SettingsWindow, hdc: winapi.HDC, row: winapi.RECT, checked: bool, hovered: bool, label: []const u8, p: Palette) void {
    const win = self.window;
    const box = win.scale(20);
    const by = @divTrunc(row.top + row.bottom - box, 2);
    const br: winapi.RECT = .{ .left = row.left, .top = by, .right = row.left + box, .bottom = by + box };
    roundRect(
        hdc,
        br,
        if (checked) p.accent else (if (hovered) p.card_hover else p.card),
        if (checked) p.accent else p.border,
        win.scale(5),
    );
    if (checked) {
        const mark = [_]winapi.POINT{
            .{ .x = br.left + win.scale(5), .y = by + @divTrunc(box, 2) },
            .{ .x = br.left + win.scale(9), .y = br.bottom - win.scale(6) },
            .{ .x = br.right - win.scale(5), .y = by + win.scale(5) },
        };
        polyline(hdc, &mark, 0x00FFFFFF, win.scale(2));
    }
    var tr: winapi.RECT = .{
        .left = br.right + win.scale(10),
        .top = row.top,
        .right = row.right + win.scale(120),
        .bottom = row.bottom,
    };
    drawText(hdc, label, &tr, p.fg, winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE);
}

fn paintButton(self: *SettingsWindow, hdc: winapi.HDC, r: winapi.RECT, text: []const u8, hovered: bool, p: Palette) void {
    roundRect(hdc, r, if (hovered) p.card_hover else p.card, p.border, self.window.scale(7));
    var tr = r;
    drawText(hdc, text, &tr, p.fg, winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE);
}

fn hotForField(field: Field) Hot {
    return switch (field) {
        .theme => .theme,
        .font_family => .font_family,
        .font_size => .font_size,
        .cursor => .cursor,
        .opacity => .opacity,
    };
}

// Small GDI helpers.

fn fillRect(hdc: winapi.HDC, r: winapi.RECT, color: u32) void {
    const b = winapi.CreateSolidBrush(color) orelse return;
    defer _ = winapi.DeleteObject(b);
    var rr = r;
    _ = winapi.FillRect(hdc, &rr, b);
}

fn roundRect(hdc: winapi.HDC, r: winapi.RECT, fill: u32, border: u32, radius: i32) void {
    const pen = winapi.CreatePen(winapi.PS_SOLID, 1, border) orelse return;
    defer _ = winapi.DeleteObject(pen);
    const brush = winapi.CreateSolidBrush(fill) orelse return;
    defer _ = winapi.DeleteObject(brush);
    const op = winapi.SelectObject(hdc, pen);
    defer if (op) |o| {
        _ = winapi.SelectObject(hdc, o);
    };
    const ob = winapi.SelectObject(hdc, brush);
    defer if (ob) |o| {
        _ = winapi.SelectObject(hdc, o);
    };
    _ = winapi.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

fn polyline(hdc: winapi.HDC, pts: []const winapi.POINT, color: u32, width: i32) void {
    const pen = winapi.CreatePen(winapi.PS_SOLID, width, color) orelse return;
    defer _ = winapi.DeleteObject(pen);
    const op = winapi.SelectObject(hdc, pen);
    defer if (op) |o| {
        _ = winapi.SelectObject(hdc, o);
    };
    _ = winapi.Polyline(hdc, pts.ptr, @intCast(pts.len));
}

fn drawText(hdc: winapi.HDC, text: []const u8, rect: *winapi.RECT, color: u32, flags: winapi.UINT) void {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return;
    buf[n] = 0;
    _ = winapi.SetTextColor(hdc, color);
    _ = winapi.DrawTextW(hdc, buf[0..n :0], @intCast(n), rect, flags);
}

// ---------------------------------------------------------------------
// Hit testing

fn inRect(r: winapi.RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

fn hitTest(self: *const SettingsWindow, x: i32, y: i32) Hot {
    inline for (0..5) |i| {
        if (inRect(self.pills[i], x, y)) return hotForField(@enumFromInt(i));
    }
    if (inRect(self.blink_rect, x, y)) return .blink;
    if (inRect(self.blur_rect, x, y)) return .blur;
    if (inRect(self.open_rect, x, y)) return .open;
    if (inRect(self.close_rect, x, y)) return .close;
    return .none;
}

fn openDropdown(self: *SettingsWindow, field: Field) void {
    if (self.dropdown != null) return;
    const i = @intFromEnum(field);
    var origin: winapi.POINT = .{ .x = self.pills[i].left, .y = self.pills[i].bottom + self.window.scale(2) };
    _ = winapi.ClientToScreen(self.hwnd, &origin);
    const w = self.pills[i].right - self.pills[i].left;
    self.dropdown = DropdownPopup.create(self, field, origin.x, origin.y, w) catch null;
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
    const self: *SettingsWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));

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
            if (!self.tracking) {
                var tme: winapi.TRACKMOUSEEVENT = .{ .dwFlags = winapi.TME_LEAVE, .hwndTrack = hwnd };
                _ = winapi.TrackMouseEvent(&tme);
                self.tracking = true;
            }
            const hot = self.hitTest(lparamX(lparam), lparamY(lparam));
            if (hot != self.hot) {
                self.hot = hot;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        winapi.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hot != .none) {
                self.hot = .none;
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            switch (self.hitTest(lparamX(lparam), lparamY(lparam))) {
                .theme => self.openDropdown(.theme),
                .font_family => self.openDropdown(.font_family),
                .font_size => self.openDropdown(.font_size),
                .cursor => self.openDropdown(.cursor),
                .opacity => self.openDropdown(.opacity),
                .blink => {
                    self.blink = !self.blink;
                    self.setValue("cursor-style-blink", if (self.blink) "true" else "false");
                    _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
                },
                .blur => {
                    self.blur = !self.blur;
                    self.setValue("background-blur", if (self.blur) "true" else "false");
                    _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
                },
                .open => self.openConfigFile(),
                .close => self.destroy(),
                .none => {},
            }
            return 0;
        },

        winapi.WM_KEYDOWN => {
            if (@as(u8, @truncate(wparam)) == winapi.VK_ESCAPE) self.destroy();
            return 0;
        },

        winapi.WM_CLOSE => {
            _ = winapi.DestroyWindow(hwnd);
            return 0;
        },

        winapi.WM_DESTROY => {
            self.cleanup();
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn openConfigFile(self: *SettingsWindow) void {
    const alloc = self.app.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch return;
    defer alloc.free(path);
    var path_w: [std.fs.max_path_bytes]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(path_w[0 .. path_w.len - 1], path) catch return;
    path_w[len] = 0;
    _ = winapi.ShellExecuteW(
        null,
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe"),
        path_w[0..len :0],
        null,
        winapi.SW_SHOWDEFAULT,
    );
}

fn lparamX(lparam: winapi.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
}
fn lparamY(lparam: winapi.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
}

// =====================================================================
// Dropdown popup: a borderless dark/light list shown below a pill.

pub const DropdownPopup = struct {
    pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-dropdown");
    const max_visible: usize = 10;

    owner: *SettingsWindow,
    field: Field,
    hwnd: winapi.HWND,
    items: []const []const u8,
    selected: usize,
    scroll: usize = 0,

    fn create(owner: *SettingsWindow, field: Field, x: i32, y: i32, w: i32) !*DropdownPopup {
        const alloc = owner.app.core_app.alloc;
        const items = owner.fieldItems(field);
        const self = try alloc.create(DropdownPopup);
        errdefer alloc.destroy(self);

        const hwnd = winapi.CreateWindowExW(
            winapi.WS_EX_TOOLWINDOW,
            DropdownPopup.class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            winapi.WS_POPUP,
            x,
            y,
            w,
            1,
            owner.hwnd,
            null,
            owner.app.hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = winapi.DestroyWindow(hwnd);

        self.* = .{
            .owner = owner,
            .field = field,
            .hwnd = hwnd,
            .items = items,
            .selected = owner.fieldIndex(field) orelse 0,
        };
        _ = winapi.SetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        // Keep the current selection visible.
        const vis = self.visibleRows();
        if (self.selected >= vis) self.scroll = self.selected - vis + 1;

        const h = @as(i32, @intCast(vis)) * owner.window.scale(34);
        _ = winapi.SetWindowPos(hwnd, null, x, y, w, h, winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE);
        _ = winapi.ShowWindow(hwnd, winapi.SW_SHOW);
        _ = winapi.SetFocus(hwnd);
        return self;
    }

    fn destroy(self: *DropdownPopup) void {
        const alloc = self.owner.app.core_app.alloc;
        self.owner.dropdown = null;
        _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
        _ = winapi.DestroyWindow(self.hwnd);
        alloc.destroy(self);
    }

    fn visibleRows(self: *const DropdownPopup) usize {
        return @min(self.items.len, max_visible);
    }

    fn rowH(self: *const DropdownPopup) i32 {
        return self.owner.window.scale(34);
    }

    fn rowAt(self: *const DropdownPopup, y: i32) ?usize {
        if (y < 0) return null;
        const row = self.scroll + @as(usize, @intCast(@divTrunc(y, self.rowH())));
        if (row >= self.items.len) return null;
        return row;
    }

    fn commit(self: *DropdownPopup) void {
        const owner = self.owner;
        const field = self.field;
        const idx = self.selected;
        self.destroy(); // clears owner.dropdown
        owner.onDropdownResult(field, idx);
        _ = winapi.SetFocus(owner.hwnd);
    }

    fn paint(self: *DropdownPopup, hdc: winapi.HDC) void {
        const win = self.owner.window;
        const p = Palette.current(win);
        var client: winapi.RECT = undefined;
        _ = winapi.GetClientRect(self.hwnd, &client);
        fillRect(hdc, client, p.card);
        _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);
        const old_font = if (self.owner.font) |f| winapi.SelectObject(hdc, f) else null;
        defer if (old_font) |o| {
            _ = winapi.SelectObject(hdc, o);
        };

        const rh = self.rowH();
        const end = @min(self.scroll + self.visibleRows(), self.items.len);
        for (self.items[self.scroll..end], self.scroll..) |item, row| {
            const top = @as(i32, @intCast(row - self.scroll)) * rh;
            if (row == self.selected) {
                fillRect(hdc, .{ .left = 0, .top = top, .right = client.right, .bottom = top + rh }, p.sel);
            }
            var tr: winapi.RECT = .{
                .left = win.scale(12),
                .top = top,
                .right = client.right - win.scale(8),
                .bottom = top + rh,
            };
            drawText(hdc, item, &tr, p.fg, winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS);
        }

        if (winapi.CreateSolidBrush(p.border)) |b| {
            defer _ = winapi.DeleteObject(b);
            _ = winapi.FrameRect(hdc, &client, b);
        }
    }

    fn moveSel(self: *DropdownPopup, delta: i32) void {
        if (self.items.len == 0) return;
        const max: i32 = @intCast(self.items.len - 1);
        self.selected = @intCast(std.math.clamp(@as(i32, @intCast(self.selected)) + delta, 0, max));
        const vis = self.visibleRows();
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + vis) self.scroll = self.selected - vis + 1;
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
        const self: *DropdownPopup = @ptrFromInt(@as(usize, @bitCast(ptr)));

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
                    self.commit();
                }
                return 0;
            },

            winapi.WM_MOUSEWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                const step: i32 = if (delta > 0) -3 else 3;
                const count = self.items.len;
                const vis = self.visibleRows();
                if (count > vis) {
                    const max_scroll: i32 = @intCast(count - vis);
                    self.scroll = @intCast(std.math.clamp(@as(i32, @intCast(self.scroll)) + step, 0, max_scroll));
                    _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
                }
                return 0;
            },

            winapi.WM_KEYDOWN => {
                switch (@as(u8, @truncate(wparam))) {
                    winapi.VK_ESCAPE => {
                        const owner = self.owner;
                        self.destroy();
                        _ = winapi.SetFocus(owner.hwnd);
                    },
                    winapi.VK_RETURN => self.commit(),
                    winapi.VK_UP => self.moveSel(-1),
                    winapi.VK_DOWN => self.moveSel(1),
                    else => {},
                }
                return 0;
            },

            winapi.WM_KILLFOCUS => {
                const owner = self.owner;
                self.destroy();
                _ = owner;
                return 0;
            },

            else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};
