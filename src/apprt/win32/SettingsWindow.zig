//! Native settings window (yuurei): a small dialog exposing the
//! most-changed config options as real Win32 controls — dropdowns, a
//! checkbox, and buttons. It is deliberately *not* a GPU surface: there
//! is no DirectComposition, swapchain, or GL involvement here, just
//! user32/gdi32 controls, so it cannot affect the compositor.
//!
//! It operates on the config FILE as text: current values are read from
//! it to populate the controls, and a change rewrites the relevant
//! `key = value` line (preserving comments and every other line) and
//! triggers Ghostty's normal config reload, so edits apply live. The
//! file stays the source of truth; "Open config file" is the escape
//! hatch for everything not surfaced here.
const SettingsWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");
const configpkg = @import("../../config.zig");
const global_state = &@import("../../global.zig").state;

const log = std.log.scoped(.win32);

/// Registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-settings");

// Child control identifiers (passed as the hMenu of each control).
const id_theme: usize = 1;
const id_font_size: usize = 2;
const id_cursor: usize = 3;
const id_opacity: usize = 4;
const id_blink: usize = 5;
const id_open_config: usize = 100;
const id_close: usize = 101;

// Static option lists (index maps directly to the written value; no
// CBS_SORT, so combobox order matches these).
const font_sizes = [_][]const u8{
    "8", "9", "10", "11", "12", "13", "14", "16", "18", "20", "24",
};
const cursor_styles = [_][]const u8{ "block", "bar", "underline" };
const opacities = [_][]const u8{
    "1.0", "0.95", "0.9", "0.85", "0.8", "0.75", "0.7", "0.65", "0.6",
};

app: *App,
window: *Window,
hwnd: winapi.HWND,
font: ?*anyopaque = null,

/// Owns the enumerated theme name strings referenced by `themes`.
arena: std.heap.ArenaAllocator,
themes: [][]const u8 = &.{},

theme_combo: winapi.HWND = undefined,
font_size_combo: winapi.HWND = undefined,
cursor_combo: winapi.HWND = undefined,
opacity_combo: winapi.HWND = undefined,
blink_check: winapi.HWND = undefined,

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

    // Size the dialog from the parent window's DPI (it opens on the
    // same monitor). AdjustWindowRect is skipped; the layout leaves
    // slack so non-client chrome doesn't crowd the controls.
    const w = window.scale(460);
    const h = window.scale(360);

    // Center on the parent.
    var pr: winapi.RECT = undefined;
    _ = winapi.GetWindowRect(window.hwnd, &pr);
    const x = pr.left + @divTrunc((pr.right - pr.left) - w, 2);
    const y = pr.top + @divTrunc((pr.bottom - pr.top) - h, 2);

    const hwnd = winapi.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("yuurei Settings"),
        winapi.WS_CAPTION | winapi.WS_SYSMENU,
        x,
        y,
        w,
        h,
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
    self.buildControls();
    self.loadCurrentValues();

    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);
    _ = winapi.SetFocus(hwnd);
    return self;
}

/// Close the window. Teardown happens in WM_DESTROY (see cleanup) so
/// the same path also covers the owner window being destroyed while
/// we're open.
pub fn destroy(self: *SettingsWindow) void {
    _ = winapi.DestroyWindow(self.hwnd);
}

/// Free our state. Runs on WM_DESTROY (from destroy() or the owner
/// window closing). Clears GWLP_USERDATA first so the trailing
/// WM_NCDESTROY can't dispatch into freed memory.
fn cleanup(self: *SettingsWindow) void {
    const alloc = self.app.core_app.alloc;
    self.app.settings = null;
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    if (self.font) |f| _ = winapi.DeleteObject(f);
    self.arena.deinit();
    alloc.destroy(self);
}

/// Enumerate theme files (best effort) from the resources themes dir.
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

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    self.themes = names.toOwnedSlice(arena) catch &.{};
}

fn buildControls(self: *SettingsWindow) void {
    const win = self.window;
    const label_x = win.scale(20);
    const ctrl_x = win.scale(180);
    const ctrl_w = win.scale(250);
    const row_h = win.scale(44);
    const combo_h = win.scale(240); // includes dropdown room
    var y = win.scale(16);

    self.theme_combo = self.makeCombo(id_theme, ctrl_x, y, ctrl_w, combo_h);
    y += row_h;
    self.font_size_combo = self.makeCombo(id_font_size, ctrl_x, y, ctrl_w, combo_h);
    y += row_h;
    self.cursor_combo = self.makeCombo(id_cursor, ctrl_x, y, ctrl_w, combo_h);
    y += row_h;
    self.opacity_combo = self.makeCombo(id_opacity, ctrl_x, y, ctrl_w, combo_h);
    y += row_h;

    // Checkbox spans the row (its own label text).
    self.blink_check = winapi.CreateWindowExW(
        0,
        winapi.button_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Blink the cursor"),
        winapi.WS_CHILD | winapi.WS_VISIBLE | winapi.WS_TABSTOP | winapi.BS_AUTOCHECKBOX,
        label_x,
        y + win.scale(4),
        ctrl_w,
        win.scale(24),
        self.hwnd,
        @ptrFromInt(id_blink),
        self.app.hinstance,
        null,
    ) orelse undefined;
    self.applyFont(self.blink_check);
    y += row_h + win.scale(8);

    // Buttons.
    const btn_w = win.scale(150);
    const btn_h = win.scale(30);
    _ = self.makeButton(id_open_config, "Open config file\u{2026}", label_x, y, btn_w, btn_h);
    _ = self.makeButton(id_close, "Close", ctrl_x + ctrl_w - btn_w, y, btn_w, btn_h);

    // Combobox option lists.
    for (font_sizes) |v| self.comboAdd(self.font_size_combo, v);
    for (cursor_styles) |v| self.comboAdd(self.cursor_combo, v);
    for (opacities) |v| self.comboAdd(self.opacity_combo, v);
    for (self.themes) |v| self.comboAdd(self.theme_combo, v);
}

fn makeCombo(self: *SettingsWindow, id: usize, x: i32, y: i32, w: i32, h: i32) winapi.HWND {
    const hwnd = winapi.CreateWindowExW(
        0,
        winapi.combobox_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_CHILD | winapi.WS_VISIBLE | winapi.WS_TABSTOP |
            winapi.WS_VSCROLL | winapi.CBS_DROPDOWNLIST | winapi.CBS_HASSTRINGS,
        x,
        y,
        w,
        h,
        self.hwnd,
        @ptrFromInt(id),
        self.app.hinstance,
        null,
    ) orelse return undefined;
    self.applyFont(hwnd);
    return hwnd;
}

fn makeButton(self: *SettingsWindow, id: usize, text: []const u8, x: i32, y: i32, w: i32, h: i32) winapi.HWND {
    var buf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
    buf[n] = 0;
    const hwnd = winapi.CreateWindowExW(
        0,
        winapi.button_class,
        buf[0..n :0],
        winapi.WS_CHILD | winapi.WS_VISIBLE | winapi.WS_TABSTOP,
        x,
        y,
        w,
        h,
        self.hwnd,
        @ptrFromInt(id),
        self.app.hinstance,
        null,
    ) orelse return undefined;
    self.applyFont(hwnd);
    return hwnd;
}

fn applyFont(self: *SettingsWindow, ctrl: winapi.HWND) void {
    if (self.font) |f| _ = winapi.SendMessageW(
        ctrl,
        winapi.WM_SETFONT,
        @intFromPtr(f),
        1,
    );
}

fn comboAdd(self: *SettingsWindow, combo: winapi.HWND, utf8: []const u8) void {
    _ = self;
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], utf8) catch return;
    buf[n] = 0;
    _ = winapi.SendMessageW(
        combo,
        winapi.CB_ADDSTRING,
        0,
        @bitCast(@intFromPtr(&buf)),
    );
}

/// Read current values from the config file and reflect them in the
/// controls. Missing keys leave the control unselected (Ghostty default
/// applies until the user picks something).
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

    if (configValue(text, "theme")) |v| selectMatch(self.theme_combo, self.themes, v);
    if (configValue(text, "font-size")) |v| selectMatch(self.font_size_combo, &font_sizes, v);
    if (configValue(text, "cursor-style")) |v| selectMatch(self.cursor_combo, &cursor_styles, v);
    if (configValue(text, "background-opacity")) |v| selectMatch(self.opacity_combo, &opacities, v);
    if (configValue(text, "cursor-style-blink")) |v| {
        const on = std.ascii.eqlIgnoreCase(v, "true");
        _ = winapi.SendMessageW(
            self.blink_check,
            winapi.BM_SETCHECK,
            if (on) winapi.BST_CHECKED else 0,
            0,
        );
    }
}

fn selectMatch(combo: winapi.HWND, values: []const []const u8, current: []const u8) void {
    for (values, 0..) |v, i| {
        if (std.mem.eql(u8, v, current)) {
            _ = winapi.SendMessageW(combo, winapi.CB_SETCURSEL, i, 0);
            return;
        }
    }
}

/// Return the active (uncommented) value for `key`, a slice into `text`.
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

    // Reconstruct the file line by line (joining segments with '\n' so
    // we neither add nor drop a trailing newline), replacing the first
    // active occurrence of `key` and copying every other line verbatim.
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

    self.reload();
}

fn reload(self: *SettingsWindow) void {
    _ = self.app.performAction(.app, .reload_config, .{}) catch |err| {
        log.warn("settings: reload failed err={}", .{err});
    };
}

fn comboValue(combo: winapi.HWND, values: []const []const u8) ?[]const u8 {
    const idx = winapi.SendMessageW(combo, winapi.CB_GETCURSEL, 0, 0);
    if (idx < 0) return null;
    const i: usize = @intCast(idx);
    if (i >= values.len) return null;
    return values[i];
}

// ---------------------------------------------------------------------
// Painting

fn paint(self: *SettingsWindow, hdc: winapi.HDC) void {
    const win = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    // Standard light dialog background; controls use their native chrome.
    if (winapi.CreateSolidBrush(0x00F0F0F0)) |b| {
        defer _ = winapi.DeleteObject(b);
        _ = winapi.FillRect(hdc, &client, b);
    }

    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);
    _ = winapi.SetTextColor(hdc, 0x00202020);
    const old = if (self.font) |f| winapi.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = winapi.SelectObject(hdc, o);
    };

    const label_x = win.scale(20);
    const row_h = win.scale(44);
    const label_w = win.scale(150);
    const labels = [_][]const u8{ "Theme", "Font size", "Cursor style", "Background opacity" };
    var y = win.scale(16);
    for (labels) |text| {
        var buf: [64]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
        buf[n] = 0;
        var rect: winapi.RECT = .{
            .left = label_x,
            .top = y,
            .right = label_x + label_w,
            .bottom = y + win.scale(28),
        };
        _ = winapi.DrawTextW(
            hdc,
            buf[0..n :0],
            @intCast(n),
            &rect,
            winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
        );
        y += row_h;
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
    const self: *SettingsWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        winapi.WM_PAINT => {
            var ps: winapi.PAINTSTRUCT = undefined;
            if (winapi.BeginPaint(hwnd, &ps)) |hdc| {
                self.paint(hdc);
                _ = winapi.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        winapi.WM_COMMAND => {
            const id: usize = @as(u16, @truncate(wparam));
            const code: u16 = @truncate(wparam >> 16);
            self.onCommand(id, code);
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

fn onCommand(self: *SettingsWindow, id: usize, code: u16) void {
    switch (id) {
        id_theme => if (code == winapi.CBN_SELCHANGE) {
            if (comboValue(self.theme_combo, self.themes)) |v| self.setValue("theme", v);
        },
        id_font_size => if (code == winapi.CBN_SELCHANGE) {
            if (comboValue(self.font_size_combo, &font_sizes)) |v| self.setValue("font-size", v);
        },
        id_cursor => if (code == winapi.CBN_SELCHANGE) {
            if (comboValue(self.cursor_combo, &cursor_styles)) |v| self.setValue("cursor-style", v);
        },
        id_opacity => if (code == winapi.CBN_SELCHANGE) {
            if (comboValue(self.opacity_combo, &opacities)) |v| self.setValue("background-opacity", v);
        },
        id_blink => if (code == winapi.BN_CLICKED) {
            const checked = winapi.SendMessageW(self.blink_check, winapi.BM_GETCHECK, 0, 0) == 1;
            self.setValue("cursor-style-blink", if (checked) "true" else "false");
        },
        id_open_config => if (code == winapi.BN_CLICKED) {
            self.openConfigFile();
        },
        id_close => if (code == winapi.BN_CLICKED) {
            self.destroy();
        },
        else => {},
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
