//! Resizable native settings with staged, validated config transactions.
const SettingsWindow = @This();
const std = @import("std");
const global = @import("../../global.zig");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");
const ui = @import("settings_controls.zig");
const model = @import("settings_model.zig");
const configpkg = @import("../../config.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32);
pub const class_name = L("ghostty-settings");
const count = model.fields.len;
const id_search = 10;
const id_save = 11;
const id_revert = 12;
const id_open = 13;
const id_prev = 14;
const id_next = 15;
const id_update = 16;
const id_category = 20;
const id_field = 100;
const id_reset = 200;
const id_search_label = 400;

const Palette = struct {
    bg: u32,
    sidebar: u32,
    card: u32,
    border: u32,
    text: u32,
    muted: u32,
    accent: u32,
    selected: u32,
    error_color: u32,
    fn current(light: bool) Palette {
        return if (light) .{
            .bg = 0x00F9F8F6,
            .sidebar = 0x00F0EDE9,
            .card = 0x00FFFFFF,
            .border = 0x00E0DAD3,
            .text = 0x00372E26,
            .muted = 0x007E7167,
            .accent = 0x00814835,
            .selected = 0x00EAE0D6,
            .error_color = 0x003535AF,
        } else .{
            .bg = 0x00211C19,
            .sidebar = 0x0028201C,
            .card = 0x002D2621,
            .border = 0x00443931,
            .text = 0x00F5EDE5,
            .muted = 0x00B8A496,
            .accent = 0x00E6B997,
            .selected = 0x004B392C,
            .error_color = 0x0099A4FF,
        };
    }
};

app: *App,
window: *Window,
hwnd: winapi.HWND,
arena: std.heap.ArenaAllocator,
snapshot: std.heap.ArenaAllocator,
path: [:0]const u8 = "",
baseline: []const u8 = "",
original: [count][]const u8 = @splat(""),
defaults: [count][]const u8 = @splat(""),
controls: [count]?winapi.HWND = @splat(null),
labels: [count]?winapi.HWND = @splat(null),
resets: [count]?winapi.HWND = @splat(null),
reset: [count]bool = @splat(false),
dirty: [count]bool = @splat(false),
rows: [count]?winapi.RECT = @splat(null),
nav: [model.categories.len]?winapi.HWND = @splat(null),
search: ?winapi.HWND = null,
search_label: ?winapi.HWND = null,
save_button: ?winapi.HWND = null,
revert_button: ?winapi.HWND = null,
open_button: ?winapi.HWND = null,
prev_button: ?winapi.HWND = null,
next_button: ?winapi.HWND = null,
update_button: ?winapi.HWND = null,
font: ?*anyopaque = null,
heading_font: ?*anyopaque = null,
small_font: ?*anyopaque = null,
brush: ?winapi.HBRUSH = null,
input_brush: ?winapi.HBRUSH = null,
combo_procs: [count]?winapi.WNDPROC = @splat(null),
themes: [][]const u8 = &.{},
fonts: [][]const u8 = &.{},
palette: Palette = Palette.current(false),
category: usize = 0,
offset: usize = 0,
visible_count: usize = 0,
matched_count: usize = 0,
query: [256]u8 = @splat(0),
query_len: usize = 0,
loading: bool = true,
ready: bool = false,
status: [256]u8 = @splat(0),
status_len: usize = 0,
status_error: bool = false,
width: i32 = 0,
height: i32 = 0,

pub fn create(alloc: Allocator, window: *Window) !*SettingsWindow {
    const self = try alloc.create(SettingsWindow);
    self.* = .{ .app = window.app, .window = window, .hwnd = undefined, .arena = .init(alloc), .snapshot = .init(alloc) };
    errdefer {
        self.snapshot.deinit();
        self.arena.deinit();
        alloc.destroy(self);
    }
    self.path = try configpkg.edit.openPath(self.arena.allocator());
    self.hwnd = winapi.CreateWindowExW(0x00010000, class_name, L("Settings - yuurei"), winapi.WS_OVERLAPPEDWINDOW | winapi.WS_CLIPCHILDREN, winapi.CW_USEDEFAULT, winapi.CW_USEDEFAULT, window.scale(1000), window.scale(780), window.hwnd, null, self.app.hinstance, null) orelse return error.CreateWindowFailed;
    // Before initialization succeeds, WM_DESTROY must not free self twice.
    errdefer {
        _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
        _ = winapi.DestroyWindow(self.hwnd);
        self.deleteResources();
    }
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.refreshStyle();
    self.collectThemes();
    self.collectFonts();
    self.search_label = try self.child(L("STATIC"), "Search settings", 0, id_search_label);
    self.search = try self.child(L("EDIT"), "", 0x0080, id_search);
    _ = winapi.SendMessageW(self.search.?, 0x1501, 1, @bitCast(@intFromPtr(L("Search settings  (Ctrl+F)"))));
    _ = winapi.SendMessageW(self.search.?, 0x00C5, 180, 0);
    for (model.categories, 0..) |name, i| self.nav[i] = try self.button(name, id_category + i);
    self.save_button = try self.button("Save changes", id_save);
    self.revert_button = try self.button("Revert", id_revert);
    self.open_button = try self.button("Open config file", id_open);
    self.prev_button = try self.button("Previous", id_prev);
    self.next_button = try self.button("Next", id_next);
    self.update_button = try self.button("Check for updates", id_update);
    for (model.fields, 0..) |field, i| {
        // Real labels precede controls for native accessibility.
        self.labels[i] = try self.child(L("STATIC"), field.title, 0, 300 + i);
        const style: u32 = switch (field.kind) {
            .text => 0x0080,
            .toggle => winapi.BS_AUTOCHECKBOX,
            else => 0x0002 | winapi.CBS_HASSTRINGS | winapi.WS_VSCROLL,
        };
        self.controls[i] = try self.child(switch (field.kind) {
            .text => L("EDIT"),
            .toggle => L("BUTTON"),
            else => L("COMBOBOX"),
        }, if (field.kind == .toggle) field.title else "", style, id_field + i);
        if (field.kind == .text) _ = winapi.SendMessageW(self.controls[i].?, 0x00C5, 8192, 0);
        if (field.kind == .theme or field.kind == .font or field.kind == .choice) {
            const choices = switch (field.kind) {
                .theme => self.themes,
                .font => self.fonts,
                else => field.choices,
            };
            for (choices) |choice| {
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.arena.allocator(), if (field.kind == .choice) model.choiceLabel(i, choice) else choice);
                _ = winapi.SendMessageW(self.controls[i].?, winapi.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide.ptr)));
            }
            _ = winapi.SendMessageW(self.controls[i].?, 0x0141, 8192, 0);
            _ = winapi.SendMessageW(self.controls[i].?, 0x0153, 0, self.s(30));
            _ = winapi.SendMessageW(self.controls[i].?, 0x0153, @as(usize, @bitCast(@as(isize, -1))), self.s(26));
            _ = winapi.SetWindowLongPtrW(self.controls[i].?, winapi.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            const previous = winapi.SetWindowLongPtrW(self.controls[i].?, -4, @bitCast(@intFromPtr(&comboProc)));
            self.combo_procs[i] = @ptrFromInt(@as(usize, @bitCast(previous)));
        }
        if (field.kind == .toggle) {
            _ = winapi.SetWindowLongPtrW(self.controls[i].?, winapi.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            const previous = winapi.SetWindowLongPtrW(self.controls[i].?, -4, @bitCast(@intFromPtr(&comboProc)));
            self.combo_procs[i] = @ptrFromInt(@as(usize, @bitCast(previous)));
        }
        self.resets[i] = try self.button(try std.fmt.allocPrint(self.arena.allocator(), "Reset {s}", .{field.title}), id_reset + i);
    }
    try self.load();
    self.ready = true;
    self.layout();
    self.refreshUpdates();
    _ = winapi.ShowWindow(self.hwnd, winapi.SW_SHOWDEFAULT);
    _ = winapi.SetFocus(self.search.?);
    return self;
}

fn s(self: *const SettingsWindow, v: i32) i32 {
    return @intCast(@divTrunc(@as(i64, v) * winapi.GetDpiForWindow(self.hwnd), 96));
}

pub fn refreshUpdates(self: *SettingsWindow) void {
    const updater = &self.app.updater;
    const enabled = self.app.config.@"windows-auto-update";
    self.setText(self.update_button.?, updater.buttonLabel(enabled));
    _ = ui.EnableWindow(self.update_button.?, if (updater.buttonEnabled(enabled)) 1 else 0);
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
    _ = winapi.InvalidateRect(self.update_button.?, null, 0);
}
fn child(self: *SettingsWindow, class: [*:0]const u16, title: []const u8, style: u32, id: usize) !winapi.HWND {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.arena.allocator(), title);
    const hwnd = winapi.CreateWindowExW(0, class, wide.ptr, winapi.WS_CHILD | (if (id >= 300) @as(u32, 0) else winapi.WS_TABSTOP) | style, 0, 0, 1, 1, self.hwnd, @ptrFromInt(id), self.app.hinstance, null) orelse return error.CreateControlFailed;
    _ = winapi.SendMessageW(hwnd, winapi.WM_SETFONT, @intFromPtr(self.font), 0);
    return hwnd;
}
fn button(self: *SettingsWindow, title: []const u8, id: usize) !winapi.HWND {
    return self.child(L("BUTTON"), title, 0x000B, id);
}
fn deleteResources(self: *SettingsWindow) void {
    if (self.font) |f| _ = winapi.DeleteObject(f);
    if (self.heading_font) |f| _ = winapi.DeleteObject(f);
    if (self.small_font) |f| _ = winapi.DeleteObject(f);
    if (self.brush) |b| _ = winapi.DeleteObject(b);
    if (self.input_brush) |b| _ = winapi.DeleteObject(b);
}
fn refreshStyle(self: *SettingsWindow) void {
    self.deleteResources();
    self.palette = Palette.current(self.window.isLight());
    self.brush = winapi.CreateSolidBrush(self.palette.card);
    self.input_brush = winapi.CreateSolidBrush(self.palette.bg);
    self.font = winapi.CreateFontW(-self.s(14), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    self.small_font = winapi.CreateFontW(-self.s(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    self.heading_font = winapi.CreateFontW(-self.s(28), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    for (self.controls ++ self.labels ++ self.resets ++ self.nav ++ [_]?winapi.HWND{ self.search, self.search_label, self.save_button, self.revert_button, self.open_button, self.prev_button, self.next_button }) |maybe| {
        if (maybe) |h| _ = winapi.SendMessageW(h, winapi.WM_SETFONT, @intFromPtr(self.font), 1);
    }
    const dark: winapi.BOOL = if (self.window.isLight()) 0 else 1;
    _ = winapi.DwmSetWindowAttribute(self.hwnd, winapi.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(winapi.BOOL));
}
pub fn destroy(self: *SettingsWindow) void {
    _ = winapi.DestroyWindow(self.hwnd);
}
fn cleanup(self: *SettingsWindow) void {
    const alloc = self.app.core_app.alloc;
    self.app.settings = null;
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    self.deleteResources();
    self.snapshot.deinit();
    self.arena.deinit();
    alloc.destroy(self);
}
fn setText(self: *SettingsWindow, h: winapi.HWND, value: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
    defer alloc.free(wide);
    _ = winapi.SetWindowTextW(h, wide.ptr);
}
fn getText(alloc: Allocator, h: winapi.HWND) ![]u8 {
    const len: usize = @intCast(@max(0, ui.GetWindowTextLengthW(h)));
    const wide = try alloc.alloc(u16, len + 1);
    defer alloc.free(wide);
    const got = ui.GetWindowTextW(h, wide.ptr, @intCast(wide.len));
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..@intCast(@max(0, got))]);
}
fn controlValue(self: *SettingsWindow, alloc: Allocator, i: usize) ![]const u8 {
    if (model.fields[i].kind == .toggle) return alloc.dupe(u8, if (winapi.SendMessageW(self.controls[i].?, winapi.BM_GETCHECK, 0, 0) == winapi.BST_CHECKED) "true" else "false");
    if (model.fields[i].kind == .choice) {
        const label = try getText(alloc, self.controls[i].?);
        defer alloc.free(label);
        return alloc.dupe(u8, model.choiceValue(i, label));
    }
    return getText(alloc, self.controls[i].?);
}
fn setValue(self: *SettingsWindow, i: usize, value: []const u8) void {
    if (model.fields[i].kind == .toggle) {
        _ = winapi.SendMessageW(self.controls[i].?, winapi.BM_SETCHECK, if (std.mem.eql(u8, value, "true")) winapi.BST_CHECKED else 0, 0);
    } else self.setText(self.controls[i].?, if (model.fields[i].kind == .choice) model.choiceLabel(i, value) else value);
    if (self.combo_procs[i] != null and model.fields[i].kind != .toggle) _ = winapi.SendMessageW(self.controls[i].?, 0x0142, 0, 0); // CB_SETEDITSEL
}
fn load(self: *SettingsWindow) !void {
    var snapshot: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    errdefer snapshot.deinit();
    const a = snapshot.allocator();
    const baseline = try model.read(a, self.path);
    var defaults = try configpkg.Config.default(a);
    defer defaults.deinit();
    // Refresh effective values too: an external edit may have removed a key.
    var current = try configpkg.Config.load(a);
    defer current.deinit();
    var original: [count][]const u8 = undefined;
    var default_values: [count][]const u8 = undefined;
    for (model.fields, 0..) |field, i| {
        original[i] = if (model.value(baseline, field.key)) |v| try a.dupe(u8, v) else try model.effective(a, &current, i);
        default_values[i] = try model.effective(a, &defaults, i);
    }
    self.loading = true;
    defer self.loading = false;
    self.snapshot.deinit();
    self.snapshot = snapshot;
    self.baseline = baseline;
    self.original = original;
    self.defaults = default_values;
    self.dirty = @splat(false);
    self.reset = @splat(false);
    for (original, 0..) |v, i| self.setValue(i, v);
    self.updateButtons();
}
fn anyDirty(self: *const SettingsWindow) bool {
    return std.mem.indexOfScalar(bool, &self.dirty, true) != null;
}
fn updateButtons(self: *SettingsWindow) void {
    if (self.save_button) |h| _ = ui.EnableWindow(h, if (self.anyDirty()) 1 else 0);
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}
fn message(self: *SettingsWindow, value: []const u8, is_error: bool) void {
    self.status_len = @min(value.len, self.status.len);
    @memcpy(self.status[0..self.status_len], value[0..self.status_len]);
    self.status_error = is_error;
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}
fn changed(self: *SettingsWindow, i: usize) void {
    if (self.loading) return;
    const a = self.app.core_app.alloc;
    const v = self.controlValue(a, i) catch return;
    defer a.free(v);
    self.reset[i] = false;
    self.dirty[i] = !std.mem.eql(u8, v, self.original[i]);
    self.status_len = 0;
    self.updateButtons();
}
fn save(self: *SettingsWindow) void {
    if (!self.anyDirty()) return;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var changes: std.ArrayList(model.Change) = .empty;
    var restart = false;
    for (model.fields, 0..) |field, i| {
        if (!self.dirty[i]) continue;
        const raw = self.controlValue(a, i) catch {
            self.message("Could not read settings.", true);
            return;
        };
        const v = std.mem.trim(u8, raw, " \t");
        const reset = self.reset[i] or v.len == 0;
        if (!reset) model.validate(a, i, v) catch {
            self.category = @intFromEnum(field.category);
            self.query_len = 0;
            self.setText(self.search.?, "");
            self.offset = 0;
            self.layout();
            while (self.rows[i] == null and self.offset + self.visible_count < self.matched_count) {
                self.offset += 1;
                self.layout();
            }
            _ = winapi.SetFocus(self.controls[i].?);
            var buf: [256]u8 = undefined;
            const explanation: []const u8 = switch (i) {
                0 => "Theme could not be loaded. Choose a listed theme or check the theme path.",
                2 => "Font size must be a number between 4 and 96 points.",
                3 => "Opacity must be a number between 0 and 1.",
                else => std.fmt.bufPrint(&buf, "Check {s}. Enter a valid value before saving.", .{field.title}) catch "Check the highlighted setting.",
            };
            self.message(explanation, true);
            return;
        };
        changes.append(a, .{ .index = i, .value = if (reset) null else v }) catch {
            self.message("Not enough memory to save settings.", true);
            return;
        };
        restart = restart or field.restart;
    }
    model.save(a, self.path, self.baseline, changes.items) catch |err| {
        self.message(if (err == error.ConfigChanged) "Config changed externally. Revert to reload it before editing." else "Could not save the config file. Changes remain unsaved.", true);
        return;
    };
    _ = self.app.performAction(.app, .reload_config, .{}) catch {
        self.message("Saved to disk, but reload failed. Reopen yuurei to apply.", true);
        return;
    };
    self.load() catch {
        self.message("Saved, but could not refresh settings. Reopen this window.", true);
        return;
    };
    self.refreshStyle();
    self.layout();
    self.message(if (restart) "Saved. Shell and input changes apply to new terminals." else "Settings saved.", false);
    self.refreshUpdates();
}
fn confirmDiscard(self: *SettingsWindow) bool {
    if (!self.anyDirty()) return true;
    return winapi.MessageBoxW(self.hwnd, L("Discard unsaved settings changes?"), L("Unsaved changes"), 0x00000004 | 0x00000020 | 0x00000100) == 6;
}
fn move(self: *SettingsWindow, h: ?winapi.HWND, x: i32, y: i32, w: i32, height: i32, show: bool) void {
    _ = self;
    if (h) |hwnd| {
        _ = winapi.SetWindowPos(hwnd, null, x, y, @max(1, w), @max(1, height), winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE);
        _ = winapi.ShowWindow(hwnd, if (show) winapi.SW_SHOW else winapi.SW_HIDE);
    }
}
fn layout(self: *SettingsWindow) void {
    if (!self.ready) return;
    const focused = ui.GetFocus();
    var r: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &r);
    self.width = r.right;
    self.height = r.bottom;
    const side = self.s(218);
    const pad = self.s(28);
    self.move(self.search_label, side + pad, self.s(12), self.s(180), self.s(18), true);
    self.move(self.search, side + pad + self.s(12), self.s(40), self.width - side - 2 * pad - self.s(24), self.s(24), true);
    for (self.nav, 0..) |h, i| {
        self.move(h, self.s(16), self.s(114 + @as(i32, @intCast(i)) * 48), side - self.s(32), self.s(40), true);
        // Selection depends on category/search state, not native button state.
        // Repainting the parent does not invalidate these child windows.
        if (h) |button_hwnd| _ = winapi.InvalidateRect(button_hwnd, null, 0);
    }
    self.move(self.open_button, self.s(16), self.height - self.s(64), side - self.s(32), self.s(36), true);
    self.move(self.save_button, self.width - self.s(166), self.height - self.s(57), self.s(138), self.s(36), true);
    self.move(self.revert_button, self.width - self.s(262), self.height - self.s(57), self.s(84), self.s(36), true);
    self.move(self.prev_button, side + pad, self.height - self.s(108), self.s(88), self.s(28), true);
    self.move(self.next_button, side + pad + self.s(98), self.height - self.s(108), self.s(72), self.s(28), true);
    self.move(self.update_button, side + pad + self.s(16), self.s(368), self.s(174), self.s(36), self.query_len == 0 and self.category == @intFromEnum(model.Category.updates));
    var matching: [count]usize = undefined;
    var n: usize = 0;
    for (model.fields, 0..) |field, i| {
        self.rows[i] = null;
        self.move(self.controls[i], 0, 0, 1, 1, false);
        self.move(self.labels[i], 0, 0, 1, 1, false);
        self.move(self.resets[i], 0, 0, 1, 1, false);
        if ((self.query_len == 0 and @intFromEnum(field.category) == self.category) or
            (self.query_len > 0 and model.matches(field, self.query[0..self.query_len])))
        {
            matching[n] = i;
            n += 1;
        }
    }
    const capacity: usize = @intCast(@max(1, @divTrunc(self.height - self.s(280), self.s(100))));
    self.offset = @min(self.offset, n -| capacity);
    self.matched_count = n;
    self.visible_count = @min(capacity, n - self.offset);
    for (matching[self.offset..][0..self.visible_count], 0..) |i, row| {
        const y = self.s(156 + @as(i32, @intCast(row)) * 100);
        const x = side + pad;
        const w = self.width - x - pad;
        self.rows[i] = .{ .left = x, .top = y, .right = x + w, .bottom = y + self.s(88) };
        const control_w = @min(self.s(270), @divTrunc(w * 42, 100));
        self.move(self.labels[i], x + self.s(16), y + self.s(12), w - self.s(32), self.s(22), true);
        self.move(self.controls[i], x + w - control_w - self.s(90), y + self.s(42), control_w, if (model.fields[i].kind == .theme or model.fields[i].kind == .font or model.fields[i].kind == .choice) self.s(300) else self.s(28), true);
        self.move(self.resets[i], x + w - self.s(78), y + self.s(42), self.s(66), self.s(28), true);
        const editing = if (focused) |h| h == self.controls[i] or ui.IsChild(self.controls[i].?, h) != 0 else false;
        if (!editing and self.combo_procs[i] != null and model.fields[i].kind != .toggle) {
            _ = winapi.SendMessageW(self.controls[i].?, 0x0142, 0, 0);
        }
    }
    _ = ui.EnableWindow(self.prev_button.?, if (self.offset > 0) 1 else 0);
    _ = ui.EnableWindow(self.next_button.?, if (self.offset + self.visible_count < n) 1 else 0);
    // Native Tab order follows child Z order. Put the fields before actions.
    self.tabOrder(self.search_label);
    self.tabOrder(self.search);
    for (self.nav) |h| self.tabOrder(h);
    for (matching[self.offset..][0..self.visible_count]) |i| {
        self.tabOrder(self.labels[i]);
        self.tabOrder(self.controls[i]);
        self.tabOrder(self.resets[i]);
    }
    for ([_]?winapi.HWND{ self.update_button, self.prev_button, self.next_button, self.revert_button, self.save_button, self.open_button }) |h| self.tabOrder(h);
    if (focused) |h| {
        if (ui.IsChild(self.hwnd, h) != 0) {
            _ = winapi.SetFocus(if (winapi.IsWindowVisible(h) != 0 and ui.IsWindowEnabled(h) != 0) h else self.search.?);
        }
    }
    _ = winapi.InvalidateRect(self.hwnd, null, 1);
}
fn tabOrder(self: *SettingsWindow, hwnd: ?winapi.HWND) void {
    _ = self;
    if (hwnd) |h| _ = winapi.SetWindowPos(h, @ptrFromInt(1), 0, 0, 0, 0, 0x0001 | 0x0002 | winapi.SWP_NOACTIVATE);
}
fn page(self: *SettingsWindow, forward: bool) void {
    if (forward) {
        if (self.offset + self.visible_count >= self.matched_count) return;
        self.offset += 1;
    } else self.offset -|= 1;
    self.layout();
}
fn fill(hdc: winapi.HDC, r: winapi.RECT, color: u32) void {
    const brush = winapi.CreateSolidBrush(color) orelse return;
    defer _ = winapi.DeleteObject(brush);
    _ = winapi.FillRect(hdc, &r, brush);
}
fn box(hdc: winapi.HDC, r: winapi.RECT, color: u32, border: u32) void {
    const brush = winapi.CreateSolidBrush(color) orelse return;
    defer _ = winapi.DeleteObject(brush);
    const pen = winapi.CreatePen(winapi.PS_SOLID, 1, border) orelse return;
    defer _ = winapi.DeleteObject(pen);
    const old_brush = winapi.SelectObject(hdc, brush);
    defer {
        if (old_brush) |b| _ = winapi.SelectObject(hdc, b);
    }
    const old_pen = winapi.SelectObject(hdc, pen);
    defer {
        if (old_pen) |p| _ = winapi.SelectObject(hdc, p);
    }
    _ = winapi.RoundRect(hdc, r.left, r.top, r.right, r.bottom, 12, 12);
}
fn text(self: *SettingsWindow, hdc: winapi.HDC, value: []const u8, r: winapi.RECT, color: u32, font: ?*anyopaque, flags: u32) void {
    const a = self.app.core_app.alloc;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, value) catch return;
    defer a.free(wide);
    const old = if (font) |f| winapi.SelectObject(hdc, f) else null;
    defer {
        if (old) |f| _ = winapi.SelectObject(hdc, f);
    }
    _ = winapi.SetTextColor(hdc, color);
    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);
    var r2 = r;
    const saved = winapi.SaveDC(hdc);
    defer _ = winapi.RestoreDC(hdc, saved);
    _ = winapi.IntersectClipRect(hdc, r.left, r.top, r.right, r.bottom);
    _ = winapi.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &r2, flags | winapi.DT_NOPREFIX | winapi.DT_END_ELLIPSIS);
}
fn rect(self: *SettingsWindow, x: i32, y: i32, w: i32, h: i32) winapi.RECT {
    return .{ .left = self.s(x), .top = self.s(y), .right = self.s(x + w), .bottom = self.s(y + h) };
}
fn paint(self: *SettingsWindow, hdc: winapi.HDC) void {
    const p = self.palette;
    fill(hdc, .{ .left = 0, .top = 0, .right = self.width, .bottom = self.height }, p.bg);
    fill(hdc, .{ .left = 0, .top = 0, .right = self.s(218), .bottom = self.height }, p.sidebar);
    self.text(hdc, "yuurei", self.rect(28, 26, 162, 38), p.text, self.heading_font, 0);
    self.text(hdc, "SETTINGS", self.rect(29, 72, 162, 20), p.muted, self.small_font, 0);
    box(hdc, .{ .left = self.s(246), .top = self.s(33), .right = self.width - self.s(28), .bottom = self.s(71) }, p.bg, p.border);
    self.text(hdc, if (self.query_len > 0) "Search results" else model.categories[self.category], .{ .left = self.s(246), .top = self.s(79), .right = self.width - self.s(28), .bottom = self.s(119) }, p.text, self.heading_font, 0);
    self.text(hdc, if (self.query_len > 0) "Matching settings across every category." else model.descriptions[self.category], .{ .left = self.s(247), .top = self.s(125), .right = self.width - self.s(28), .bottom = self.s(146) }, p.muted, self.font, 0);
    for (self.rows, 0..) |maybe, i| {
        const row = maybe orelse continue;
        const focused = if (ui.GetFocus()) |h| h == self.controls[i] or ui.IsChild(self.controls[i].?, h) != 0 else false;
        box(hdc, row, p.card, if (self.dirty[i] or focused) p.accent else p.border);
        if (model.fields[i].kind == .text) {
            const cw = @min(self.s(270), @divTrunc((row.right - row.left) * 42, 100));
            box(hdc, .{ .left = row.right - cw - self.s(94), .top = row.top + self.s(38), .right = row.right - self.s(86), .bottom = row.top + self.s(74) }, p.bg, p.border);
        }
        var desc = row;
        desc.left += self.s(16);
        desc.top += self.s(40);
        desc.right = row.right - @min(self.s(270), @divTrunc((row.right - row.left) * 42, 100)) - self.s(106);
        desc.bottom -= self.s(8);
        self.text(hdc, if (self.reset[i]) "Remove override on save" else model.fields[i].description, desc, if (self.reset[i]) p.accent else p.muted, self.small_font, 0x10);
    }
    if (self.matched_count == 0) {
        self.text(hdc, "No settings found", self.rect(270, 195, 400, 36), p.text, self.heading_font, 0);
        self.text(hdc, "Search by setting name, description, or config key.", self.rect(270, 240, 520, 30), p.muted, self.font, 0);
    }
    if (self.query_len == 0 and self.category == @intFromEnum(model.Category.updates)) {
        box(hdc, .{ .left = self.s(246), .top = self.s(268), .right = self.width - self.s(28), .bottom = self.s(422) }, p.card, p.border);
        const version = @import("Updater.zig").releaseTag(@import("../../build_config.zig").version_string) orelse "Development build";
        self.text(hdc, version, self.rect(262, 282, 450, 24), p.text, self.font, 0);
        self.text(hdc, self.app.updater.message(), .{ .left = self.s(262), .top = self.s(316), .right = self.width - self.s(44), .bottom = self.s(362) }, p.muted, self.font, 0x10);
    }
    self.text(hdc, "BASE CONFIGURATION", self.rect(28, 362, 168, 24), p.accent, self.small_font, 0);
    self.text(hdc, "Applies across yuurei.\nProfiles keep their own overrides.", self.rect(28, 390, 162, 74), p.muted, self.font, 0x10);
    if (self.height >= self.s(700)) {
        self.preview(hdc);
        self.text(hdc, "Ctrl+F  Search    Ctrl+S  Save", self.rect(28, 617, 170, 30), p.muted, self.small_font, 0);
    } else self.text(hdc, "Ctrl+F  Search\nCtrl+S  Save\nTab       Next control", self.rect(28, 474, 162, 76), p.muted, self.small_font, 0x10);
    var buf: [80]u8 = undefined;
    const range = std.fmt.bufPrint(&buf, "{d}-{d} of {d} settings", .{ if (self.matched_count == 0) @as(usize, 0) else self.offset + 1, self.offset + self.visible_count, self.matched_count }) catch "";
    self.text(hdc, range, .{ .left = self.s(430), .top = self.height - self.s(105), .right = self.width - self.s(28), .bottom = self.height - self.s(78) }, p.muted, self.small_font, winapi.DT_VCENTER | winapi.DT_SINGLELINE);
    const status = if (self.status_len > 0) self.status[0..self.status_len] else if (self.anyDirty()) "Unsaved changes" else "All changes saved";
    self.text(hdc, status, .{ .left = self.s(246), .top = self.height - self.s(60), .right = self.width - self.s(278), .bottom = self.height - self.s(14) }, if (self.status_len > 0 and self.status_error) p.error_color else p.muted, self.small_font, 0x10);
}
fn drawButton(self: *SettingsWindow, item: *const ui.DrawItem) void {
    const p = self.palette;
    const disabled = item.state & 4 != 0;
    const selected = item.id >= id_category and item.id < id_category + model.categories.len and self.category == item.id - id_category and self.query_len == 0;
    const primary = item.id == id_save and !disabled;
    const bg = if (primary) p.accent else if (selected or item.state & 1 != 0) p.selected else if (item.id < id_category) p.card else p.sidebar;
    fill(item.hdc, item.rect, if (item.id >= id_reset) p.card else if (item.id >= id_category) p.sidebar else p.bg);
    box(item.hdc, item.rect, bg, if (selected) p.accent else bg);
    const a = self.app.core_app.alloc;
    const title = getText(a, item.hwnd) catch return;
    defer a.free(title);
    var r = item.rect;
    r.left += self.s(if (item.id >= id_reset) @as(i32, 4) else 12);
    r.right -= self.s(if (item.id >= id_reset) @as(i32, 4) else 8);
    self.text(item.hdc, if (item.id >= id_reset) "Reset" else title, r, if (disabled) p.muted else if (primary) p.bg else p.text, self.font, winapi.DT_VCENTER | winapi.DT_SINGLELINE | (if (item.id >= id_category and item.id < id_category + 4) @as(u32, 0) else winapi.DT_CENTER));
    if (item.state & 0x10 != 0) {
        r = item.rect;
        r.left += 3;
        r.top += 3;
        r.right -= 3;
        r.bottom -= 3;
        _ = ui.DrawFocusRect(item.hdc, &r);
    }
}

/// Keep the native combo's editing, list, keyboard, and accessibility behavior;
/// replace only its bright non-editable frame and arrow after native painting.
fn comboProc(hwnd: winapi.HWND, msg: winapi.UINT, wp: winapi.WPARAM, lp: winapi.LPARAM) callconv(.winapi) winapi.LRESULT {
    const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
    if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wp, lp);
    const self: *SettingsWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));
    const index = for (self.controls, 0..) |h, i| {
        if (h == hwnd) break i;
    } else return winapi.DefWindowProcW(hwnd, msg, wp, lp);
    const previous = self.combo_procs[index] orelse return winapi.DefWindowProcW(hwnd, msg, wp, lp);
    const result = ui.CallWindowProcW(previous, hwnd, msg, wp, lp);
    if (model.fields[index].kind == .toggle and (msg == winapi.WM_LBUTTONUP or msg == winapi.WM_SETFOCUS or msg == winapi.WM_KILLFOCUS or msg == winapi.BM_SETCHECK)) _ = winapi.InvalidateRect(hwnd, null, 0);
    if (msg == winapi.WM_PAINT) {
        const hdc = winapi.GetDC(hwnd) orelse return result;
        defer _ = winapi.ReleaseDC(hwnd, hdc);
        var r: winapi.RECT = undefined;
        _ = winapi.GetClientRect(hwnd, &r);
        const p = self.palette;
        if (model.fields[index].kind == .toggle) {
            fill(hdc, r, p.card);
            const checked = winapi.SendMessageW(hwnd, winapi.BM_GETCHECK, 0, 0) == winapi.BST_CHECKED;
            const track = self.rect(0, 2, 42, 23);
            box(hdc, track, if (checked) p.accent else p.border, if (checked) p.accent else p.border);
            box(hdc, self.rect(if (checked) 23 else 3, 5, 16, 17), if (checked) p.bg else p.text, if (checked) p.bg else p.text);
            var label = r;
            label.left += self.s(54);
            self.text(hdc, if (checked) "On" else "Off", label, p.text, self.font, winapi.DT_VCENTER | winapi.DT_SINGLELINE);
            if (ui.GetFocus() == hwnd) _ = ui.DrawFocusRect(hdc, &r);
            return result;
        }
        // The edit child occupies the interior; these strips do not cover it.
        const edge = self.s(3);
        fill(hdc, .{ .left = 0, .top = 0, .right = r.right, .bottom = edge }, p.bg);
        fill(hdc, .{ .left = 0, .top = r.bottom - edge, .right = r.right, .bottom = r.bottom }, p.bg);
        fill(hdc, .{ .left = 0, .top = 0, .right = edge, .bottom = r.bottom }, p.bg);
        const brush = winapi.CreateSolidBrush(p.border);
        if (brush) |b| {
            defer _ = winapi.DeleteObject(b);
            _ = winapi.FrameRect(hdc, &r, b);
        }
        var arrow = r;
        arrow.left = r.right - self.s(19);
        arrow.top += 1;
        arrow.right -= 1;
        arrow.bottom -= 1;
        fill(hdc, arrow, p.bg);
        self.text(hdc, "⌄", arrow, p.muted, self.font, winapi.DT_CENTER | winapi.DT_VCENTER | winapi.DT_SINGLELINE);
    }
    return result;
}

fn preview(self: *SettingsWindow, hdc: winapi.HDC) void {
    const a = self.app.core_app.alloc;
    const family = self.controlValue(a, 1) catch return;
    defer a.free(family);
    const size_text = self.controlValue(a, 2) catch return;
    defer a.free(size_text);
    const size = std.fmt.parseFloat(f32, size_text) catch 12;
    const points = if (std.math.isFinite(size)) std.math.clamp(size, 8, 22) else 12;
    const face = std.unicode.utf8ToUtf16LeAllocZ(a, if (family.len > 0) family else "Cascadia Mono") catch return;
    defer a.free(face);
    const font = winapi.CreateFontW(-self.s(@intFromFloat(points * 96 / 72)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, face.ptr) orelse return;
    defer _ = winapi.DeleteObject(font);
    const p = self.palette;
    self.text(hdc, "FONT & CURSOR SAMPLE", self.rect(28, 463, 170, 22), p.muted, self.small_font, 0);
    box(hdc, self.rect(24, 493, 170, 100), p.bg, p.border);
    self.text(hdc, "> yuurei\nAa 012345", self.rect(36, 505, 146, 65), p.text, font, 0);
    const cursor = self.controlValue(a, 8) catch return;
    defer a.free(cursor);
    const r = self.rect(36, 568, if (std.mem.eql(u8, cursor, "bar")) @as(i32, 2) else 9, if (std.mem.eql(u8, cursor, "underline")) @as(i32, 2) else 15);
    if (std.mem.eql(u8, cursor, "block_hollow")) {
        box(hdc, r, p.bg, p.accent);
    } else fill(hdc, r, p.accent);
}

pub fn routeMessage(self: *SettingsWindow, msg: *winapi.MSG) bool {
    const hwnd = msg.hwnd orelse return false;
    if (hwnd != self.hwnd and ui.IsChild(self.hwnd, hwnd) == 0) return false;
    if (msg.message == winapi.WM_KEYDOWN) {
        const ctrl = winapi.GetKeyState(winapi.VK_CONTROL) < 0;
        if (ctrl and msg.wParam == 'F') {
            _ = winapi.SetFocus(self.search.?);
            return true;
        }
        if (ctrl and msg.wParam == 'S') {
            self.save();
            return true;
        }
        if (msg.wParam == winapi.VK_ESCAPE) {
            for (self.controls, 0..) |h, i| {
                if (model.fields[i].kind == .text or model.fields[i].kind == .toggle) continue;
                if (winapi.SendMessageW(h.?, 0x0157, 0, 0) != 0) return false;
            }
            if (self.query_len > 0) {
                self.setText(self.search.?, "");
            } else {
                _ = winapi.PostMessageW(self.hwnd, winapi.WM_CLOSE, 0, 0);
            }
            return true;
        }
    }
    return ui.IsDialogMessageW(self.hwnd, msg) != 0;
}
pub fn wndProc(hwnd: winapi.HWND, msg: winapi.UINT, wp: winapi.WPARAM, lp: winapi.LPARAM) callconv(.winapi) winapi.LRESULT {
    const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
    if (ptr == 0) return winapi.DefWindowProcW(hwnd, msg, wp, lp);
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
        winapi.WM_SIZE => {
            self.layout();
            return 0;
        },
        0x0024 => {
            const info: *ui.MinMaxInfo = @ptrFromInt(@as(usize, @bitCast(lp)));
            info.min_track = .{ .x = self.s(820), .y = self.s(650) };
            return 0;
        },
        winapi.WM_DPICHANGED => {
            const r: *const winapi.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            self.refreshStyle();
            _ = winapi.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE);
            self.layout();
            return 0;
        },
        0x002B => {
            self.drawButton(@ptrFromInt(@as(usize, @bitCast(lp))));
            return 1;
        },
        0x0133, 0x0134, 0x0135, 0x0138 => {
            const hdc: winapi.HDC = @ptrFromInt(wp);
            _ = winapi.SetTextColor(hdc, self.palette.text);
            const input = msg == 0x0133 or msg == 0x0134 or @as(usize, @bitCast(lp)) == @intFromPtr(self.search_label);
            _ = ui.SetBkColor(hdc, if (input) self.palette.bg else self.palette.card);
            return @bitCast(@intFromPtr(if (input) self.input_brush else self.brush));
        },
        winapi.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            self.page(delta < 0);
            return 0;
        },
        winapi.WM_COMMAND => {
            if (self.loading) return 0;
            const id = wp & 0xFFFF;
            const notification = (wp >> 16) & 0xFFFF;
            if (notification == 0x0100 or notification == 0x0200 or notification == 3 or notification == 4) _ = winapi.InvalidateRect(hwnd, null, 0);
            if (id == id_search and notification == 0x0300) {
                const a = self.app.core_app.alloc;
                const value = getText(a, self.search.?) catch return 0;
                defer a.free(value);
                self.query_len = @min(value.len, self.query.len);
                @memcpy(self.query[0..self.query_len], value[0..self.query_len]);
                self.offset = 0;
                self.layout();
            } else if (id >= id_category and id < id_category + model.categories.len and notification == 0) {
                self.category = id - id_category;
                self.offset = 0;
                self.setText(self.search.?, "");
                self.layout();
            } else if (id >= id_field and id < id_field + count) {
                const i = id - id_field;
                if (notification == 0x0300 or notification == 5 or notification == 0 or notification == 1) {
                    if (notification == 1 and model.fields[i].kind != .text and model.fields[i].kind != .toggle) {
                        _ = winapi.PostMessageW(hwnd, 0x8001, i, 0);
                    } else self.changed(i);
                }
            } else if (id >= id_reset and id < id_reset + count and notification == 0) {
                const i = id - id_reset;
                self.loading = true;
                self.setValue(i, self.defaults[i]);
                self.loading = false;
                self.reset[i] = true;
                self.dirty[i] = true;
                self.status_len = 0;
                self.updateButtons();
            } else if (notification == 0) switch (id) {
                id_save => self.save(),
                id_revert => {
                    if (self.confirmDiscard()) {
                        self.load() catch {
                            self.message("Could not reload the config file.", true);
                            return 0;
                        };
                        self.message("Changes reverted. Config reloaded from disk.", false);
                        self.layout();
                    }
                },
                id_prev => self.page(false),
                id_next => self.page(true),
                id_update => {
                    self.app.updater.click(self.app.core_app.alloc, self.app.config.@"windows-auto-update");
                    self.refreshUpdates();
                },
                id_open => {
                    const a = self.app.core_app.alloc;
                    const quoted = std.fmt.allocPrint(a, "\"{s}\"", .{self.path}) catch return 0;
                    defer a.free(quoted);
                    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, quoted) catch return 0;
                    defer a.free(wide);
                    _ = winapi.ShellExecuteW(hwnd, null, L("notepad.exe"), wide.ptr, null, winapi.SW_SHOWDEFAULT);
                },
                else => {},
            };
            return 0;
        },
        0x8001 => {
            if (wp < count) self.changed(wp);
            return 0;
        },
        winapi.WM_CLOSE => {
            if (self.confirmDiscard()) self.destroy();
            return 0;
        },
        0x0082 => { // WM_NCDESTROY follows child destruction (including subclasses).
            self.cleanup();
            return winapi.DefWindowProcW(hwnd, msg, wp, lp);
        },
        else => return winapi.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

test {
    _ = model;
}
fn collectThemes(self: *SettingsWindow) void {
    const arena = self.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;

    const res = global.resourcesDir().app() orelse return;
    const dir_path = std.fs.path.join(arena, &.{ res, "themes" }) catch return;
    var dir = std.Io.Dir.openDirAbsolute(global.io(), dir_path, .{ .iterate = true }) catch {
        log.info("settings: no themes dir at {s}", .{dir_path});
        return;
    };
    defer dir.close(global.io());

    var it = dir.iterate();
    while (it.next(global.io()) catch null) |entry| {
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
