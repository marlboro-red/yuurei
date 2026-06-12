/// Win32 apprt Window: one top-level window owning the custom frame,
/// the title strip (tab bar + caption buttons), and input routing.
/// Each tab is an apprt Surface (Surface.zig) rendering into its own
/// GL host child window; switching tabs toggles child visibility.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const datastruct = @import("../../datastruct/main.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const CommandPalette = @import("CommandPalette.zig");
const winapi = @import("winapi.zig");
const perf = @import("../../perf.zig");

const log = std.log.scoped(.win32);

/// The split tree type for one tab's surfaces.
pub const Tree = datastruct.SplitTree(Surface);

/// One tab: a split tree of surfaces and which of them has focus.
pub const Tab = struct {
    tree: Tree,
    focused: *Surface,
};

/// The window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty");

/// The app we're part of.
app: *App,

/// The top-level window.
hwnd: winapi.HWND,

/// The tabs in visual order. Never empty after create() succeeds,
/// except transiently during teardown.
tabs: std.ArrayList(Tab) = .empty,

/// Index of the active (visible) tab.
active_tab: usize = 0,

/// Flagged by WM_CLOSE or the close button; the App run loop performs
/// the actual teardown outside the window procedure.
should_close: bool = false,

/// Quick-terminal mode: a topmost tool window docked to the top of the
/// primary monitor that hides on focus loss instead of stacking like a
/// normal window.
quick: bool = false,

/// What the mouse hovers in the title strip, for hover painting.
hover: Hover = .none,

/// Active split-divider drag, if any.
divider_drag: ?DividerHit = null,

/// Index of the tab being drag-reordered, if any.
tab_drag: ?usize = null,

/// Last divider-drag relayout instant, for throttling: every layout
/// runs the full resize pipeline (ConPTY resize + renderer resize per
/// split), so high-rate mouse moves are coalesced to ~60Hz with a
/// final exact layout on release.
divider_layout_ms: i64 = 0,

/// Whether the window is currently minimized (renderer occlusion).
minimized: bool = false,

/// Inside an interactive move/size modal loop (WM_ENTERSIZEMOVE).
in_size_move: bool = false,

/// Cached strip fonts, recreated when the DPI changes. The strip
/// repaints on every hover change; re-creating fonts each paint was
/// measurable GDI churn.
fonts: ?StripFonts = null,

/// Tooltip control showing full tab titles on hover, with one tool
/// per tab slot (kept in sync by paintTitlebar).
tooltip: ?winapi.HWND = null,

/// How many tab tools are currently registered with the tooltip.
tooltip_tools: usize = 0,

/// Fingerprint of the last synced tooltip state (tab count, width,
/// titles); strip paints skip the re-sync when nothing changed.
tooltip_hash: u64 = 0,

/// The command palette popup while it is open.
palette: ?*CommandPalette = null,

/// Whether window-level transparency is currently applied; toggled by
/// toggle_background_opacity on windows that start transparent.
transparent: bool = false,

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

const StripFonts = struct {
    dpi: u32,
    text: ?*anyopaque,
    glyph: ?*anyopaque,
};

const CaptionButton = enum { minimize, maximize, close };

/// A split divider under the mouse: which split node, its layout, and
/// the split's extent in parent client pixels (for ratio math).
const DividerHit = struct {
    handle: Tree.Node.Handle,
    layout: Tree.Split.Layout,
    rect: winapi.RECT,
};

/// Logical (96-dpi) metrics, scaled by the window DPI at use.
const titlebar_height_logical: i32 = 36;
const caption_button_width_logical: i32 = 46;
const tab_width_logical: i32 = 190;
const new_tab_width_logical: i32 = 36;
const modal_tick_timer_id: usize = 1;

pub const CreateOptions = struct {
    quick: bool = false,
};

/// Create a window with one tab, show it, and return it.
pub fn create(alloc: Allocator, app: *App, opts: CreateOptions) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    // Quick terminals dock to the top of the primary monitor: topmost,
    // no taskbar button, full width, ~40% height.
    const quick_w = winapi.GetSystemMetrics(winapi.SM_CXSCREEN);
    const quick_h = @divTrunc(winapi.GetSystemMetrics(winapi.SM_CYSCREEN) * 2, 5);

    const hwnd = winapi.CreateWindowExW(
        if (opts.quick) winapi.WS_EX_TOOLWINDOW | winapi.WS_EX_TOPMOST else 0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        // CLIPCHILDREN so painting the split gaps can't stomp the GL
        // host children.
        winapi.WS_OVERLAPPEDWINDOW | winapi.WS_CLIPCHILDREN,
        if (opts.quick) 0 else winapi.CW_USEDEFAULT,
        if (opts.quick) 0 else winapi.CW_USEDEFAULT,
        if (opts.quick) quick_w else 800,
        if (opts.quick) quick_h else 600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);

    self.* = .{ .app = app, .hwnd = hwnd, .quick = opts.quick };

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

    // Tooltips for truncated tab titles. Failure is cosmetic-only.
    self.tooltip = winapi.CreateWindowExW(
        0,
        winapi.tooltips_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        winapi.WS_POPUP | winapi.TTS_ALWAYSTIP | winapi.TTS_NOPREFIX,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    );

    _ = try self.newTab();
    errdefer self.closeAllTabs();

    // Files dropped on the window paste their (quoted) paths.
    winapi.DragAcceptFiles(hwnd, winapi.TRUE);

    // Window-level alpha is the pragmatic background-opacity for a
    // GL-in-DWM window (per-pixel GL alpha needs DirectComposition).
    if (app.config.@"background-opacity" < 1.0) self.setOpacity(
        app.config.@"background-opacity",
    );

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
    if (self.palette) |palette| palette.destroy();
    if (self.fonts) |f| {
        if (f.text) |t| _ = winapi.DeleteObject(t);
        if (f.glyph) |g| _ = winapi.DeleteObject(g);
    }
    self.closeAllTabs();
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    self.tabs.deinit(alloc);
    alloc.destroy(self);
}

fn closeAllTabs(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = alloc;
    while (self.tabs.pop()) |tab| {
        var tree = tab.tree;
        tree.deinit();
    }
}

/// Create a new surface (with its GL host) owned by a fresh
/// single-leaf tree. The tree holds the only reference on return.
fn newSurfaceTree(self: *Window) !Tree {
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);

    try surface.init(self.app, self);
    errdefer surface.deinit();

    const tree = try Tree.init(alloc, surface);
    // Tree.init took its own reference; release our creation one.
    surface.refs -= 1;
    return tree;
}

/// Create and activate a new tab.
pub fn newTab(self: *Window) !*Surface {
    const alloc = self.app.core_app.alloc;
    var tree = try self.newSurfaceTree();
    errdefer tree.deinit();

    const surface = tree.nodes[0].leaf;
    try self.tabs.append(alloc, .{ .tree = tree, .focused = surface });
    self.activateTab(self.tabs.items.len - 1);
    return surface;
}

/// Inform the active tab's surfaces about full-window occlusion
/// (minimize, quick-terminal hide) so renderers idle while hidden.
pub fn setOccluded(self: *Window, occluded: bool) void {
    const tab = self.activeTab() orelse return;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        entry.view.core_surface.occlusionCallback(!occluded) catch {};
    }
}

/// Move the active tab by the given offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    const n = self.tabs.items.len;
    if (n <= 1) return;
    const target: usize = @intCast(@mod(
        @as(isize, @intCast(self.active_tab)) + amount,
        @as(isize, @intCast(n)),
    ));
    if (target == self.active_tab) return;
    const tab = self.tabs.orderedRemove(self.active_tab);
    self.tabs.insertAssumeCapacity(target, tab);
    self.active_tab = target;
    self.invalidateStrip();
}

/// Apply (or remove, at >= 1.0) window-level opacity.
fn setOpacity(self: *Window, opacity: f64) void {
    const ex = winapi.GetWindowLongPtrW(self.hwnd, winapi.GWL_EXSTYLE);
    if (opacity >= 1.0) {
        _ = winapi.SetWindowLongPtrW(
            self.hwnd,
            winapi.GWL_EXSTYLE,
            ex & ~@as(isize, winapi.WS_EX_LAYERED),
        );
        self.transparent = false;
        return;
    }
    _ = winapi.SetWindowLongPtrW(
        self.hwnd,
        winapi.GWL_EXSTYLE,
        ex | winapi.WS_EX_LAYERED,
    );
    const alpha: u8 = @intFromFloat(std.math.clamp(opacity, 0.0, 1.0) * 255.0);
    _ = winapi.SetLayeredWindowAttributes(self.hwnd, 0, alpha, winapi.LWA_ALPHA);
    self.transparent = true;
}

/// Toggle between the configured background opacity and opaque; only
/// meaningful for windows whose config starts them transparent.
pub fn toggleOpacity(self: *Window) void {
    const configured = self.app.config.@"background-opacity";
    if (configured >= 1.0) return;
    self.setOpacity(if (self.transparent) 1.0 else configured);
}

/// Toggle the command palette popup.
pub fn togglePalette(self: *Window) !void {
    if (self.palette) |palette| {
        palette.destroy();
        _ = winapi.SetFocus(self.hwnd);
        return;
    }
    self.palette = try CommandPalette.create(self.app.core_app.alloc, self);
}

/// Remove a surface from whichever tab contains it, collapsing its
/// split; an empty tab is removed. When the last tab goes, the window
/// flags itself for close; the App run loop destroys it.
pub fn removeSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab_idx = self.tabOf(surface) orelse return;
    const tab = &self.tabs.items[tab_idx];

    const handle = handleOf(&tab.tree, surface) orelse return;
    var new_tree = tab.tree.remove(alloc, handle) catch |err| {
        log.err("error removing split err={}", .{err});
        return;
    };
    var old_tree = tab.tree;
    tab.tree = new_tree;
    old_tree.deinit();

    if (tab.tree.isEmpty()) {
        new_tree.deinit();
        _ = self.tabs.orderedRemove(tab_idx);
        if (self.tabs.items.len == 0) {
            self.should_close = true;
            return;
        }
        self.activateTab(@min(tab_idx, self.tabs.items.len - 1));
        return;
    }

    // Focus moves to the first remaining surface of the tab.
    if (tab.focused == surface) {
        tab.focused = tab.tree.nodes[tab.tree.deepest(.left, .root).idx()].leaf;
        if (tab_idx == self.active_tab) {
            tab.focused.core_surface.focusCallback(true) catch {};
        }
    }
    self.layoutActiveTab();
    self.syncTitle();
}

/// Flag every surface in the tab containing the given surface for
/// close (the close_tab action).
pub fn closeTabContaining(self: *Window, surface: *Surface) void {
    const idx = self.tabOf(surface) orelse return;
    var it = self.tabs.items[idx].tree.iterator();
    while (it.next()) |entry| entry.view.should_close = true;
    self.app.wakeup();
}

/// The tab index containing the given surface, if any.
fn tabOf(self: *const Window, surface: *const Surface) ?usize {
    for (self.tabs.items, 0..) |*tab, i| {
        if (handleOf(&tab.tree, surface) != null) return i;
    }
    return null;
}

/// The tree handle of a surface's leaf within a tree.
fn handleOf(tree: *const Tree, surface: *const Surface) ?Tree.Node.Handle {
    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |leaf| if (leaf == surface) return @enumFromInt(i),
        .split => {},
    };
    return null;
}

/// Make the given tab visible and focused.
pub fn activateTab(self: *Window, idx: usize) void {
    if (self.tabs.items.len == 0) return;
    const new_idx = @min(idx, self.tabs.items.len - 1);

    for (self.tabs.items, 0..) |*tab, i| {
        const active = i == new_idx;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(active);
        }
        if (!active) tab.focused.core_surface.focusCallback(false) catch {};
    }
    self.active_tab = new_idx;

    const tab = &self.tabs.items[new_idx];
    tab.focused.core_surface.focusCallback(true) catch {};
    self.layoutActiveTab();
    self.syncTitle();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

pub fn activeTab(self: *Window) ?*Tab {
    if (self.tabs.items.len == 0) return null;
    return &self.tabs.items[@min(self.active_tab, self.tabs.items.len - 1)];
}

/// The focused surface of the active tab.
pub fn activeSurface(self: *Window) ?*Surface {
    const tab = self.activeTab() orelse return null;
    return tab.focused;
}

/// Move focus within the active tab to the given surface.
pub fn focusSurface(self: *Window, surface: *Surface) void {
    const tab = self.activeTab() orelse return;
    if (tab.focused == surface) return;
    if (handleOf(&tab.tree, surface) == null) return;

    tab.focused.core_surface.focusCallback(false) catch {};
    tab.focused = surface;
    surface.core_surface.focusCallback(true) catch {};
    self.syncTitle();
}

/// Position every GL host of the active tab according to the split
/// tree's spatial layout within the terminal area (below the strip).
pub fn layoutActiveTab(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const alloc = self.app.core_app.alloc;

    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const strip = self.titlebarHeight();
    const area_w: f32 = @floatFromInt(@max(0, client.right - client.left));
    const area_h: f32 = @floatFromInt(@max(0, client.bottom - client.top - strip));

    var sp = tab.tree.spatial(alloc) catch |err| {
        log.err("error computing split layout err={}", .{err});
        return;
    };
    defer sp.deinit(alloc);

    // Each leaf reserves a native scrollbar column on its right edge.
    const sbw: i32 = winapi.GetSystemMetricsForDpi(
        winapi.SM_CXVSCROLL,
        winapi.GetDpiForWindow(self.hwnd),
    );

    // The spatial slots parallel the node list; only leaves matter.
    // A 2px gap separates splits (painted by the parent background).
    for (tab.tree.nodes, sp.slots) |node, slot| switch (node) {
        .split => {},
        .leaf => |surface| {
            const x: i32 = @intFromFloat(@as(f32, @floatCast(slot.x)) * area_w);
            const y: i32 = @intFromFloat(@as(f32, @floatCast(slot.y)) * area_h);
            const w: i32 = @intFromFloat(@as(f32, @floatCast(slot.width)) * area_w);
            const h: i32 = @intFromFloat(@as(f32, @floatCast(slot.height)) * area_h);
            _ = winapi.SetWindowPos(
                surface.host,
                null,
                x,
                strip + y,
                @max(0, w - 2 - sbw),
                @max(0, h - 2),
                winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
            );
            if (surface.scrollbar) |sb| {
                _ = winapi.SetWindowPos(
                    sb,
                    null,
                    x + @max(0, w - 2 - sbw),
                    strip + y,
                    sbw,
                    @max(0, h - 2),
                    winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
                );
            }
            const size = surface.getSize() catch continue;
            surface.core_surface.sizeCallback(size) catch |err| {
                log.err("error in size callback err={}", .{err});
            };
            // An idle (unfocused, output-less) surface won't present a
            // frame on its own after a resize, leaving stale pixels in
            // any newly exposed region; queue a render explicitly.
            surface.core_surface.refreshCallback() catch {};
        },
    };

    // Repaint the parent so regions the hosts vacated (divider drags,
    // collapses) get the background fill instead of stale frames.
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// The split divider at the given parent-client point, if any. The
/// divider zone is the gap between a split's children, widened to a
/// comfortable grab target.
fn dividerAt(self: *Window, x: i32, y: i32) ?DividerHit {
    const tab = self.activeTab() orelse return null;
    if (!tab.tree.isSplit()) return null;
    if (tab.tree.zoomed != null) return null;
    const alloc = self.app.core_app.alloc;

    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const strip = self.titlebarHeight();
    const area_w: f32 = @floatFromInt(@max(1, client.right - client.left));
    const area_h: f32 = @floatFromInt(@max(1, client.bottom - client.top - strip));
    const grab = self.scale(4);

    var sp = tab.tree.spatial(alloc) catch return null;
    defer sp.deinit(alloc);

    for (tab.tree.nodes, sp.slots, 0..) |node, slot, i| switch (node) {
        .leaf => {},
        .split => |s| {
            const px: winapi.RECT = .{
                .left = @intFromFloat(@as(f32, @floatCast(slot.x)) * area_w),
                .top = strip + @as(i32, @intFromFloat(@as(f32, @floatCast(slot.y)) * area_h)),
                .right = @intFromFloat(@as(f32, @floatCast(slot.x + slot.width)) * area_w),
                .bottom = strip + @as(i32, @intFromFloat(@as(f32, @floatCast(slot.y + slot.height)) * area_h)),
            };
            switch (s.layout) {
                .horizontal => {
                    const div_x = px.left + @as(i32, @intFromFloat(
                        @as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(px.right - px.left)),
                    ));
                    if (x >= div_x - grab and x <= div_x + grab and
                        y >= px.top and y < px.bottom)
                    {
                        return .{
                            .handle = @enumFromInt(i),
                            .layout = s.layout,
                            .rect = px,
                        };
                    }
                },
                .vertical => {
                    const div_y = px.top + @as(i32, @intFromFloat(
                        @as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(px.bottom - px.top)),
                    ));
                    if (y >= div_y - grab and y <= div_y + grab and
                        x >= px.left and x < px.right)
                    {
                        return .{
                            .handle = @enumFromInt(i),
                            .layout = s.layout,
                            .rect = px,
                        };
                    }
                },
            }
        },
    };
    return null;
}

/// The surface of the active tab whose GL host contains the given
/// parent-client point, if any.
fn surfaceAt(self: *Window, x: i32, y: i32) ?*Surface {
    const tab = self.activeTab() orelse return null;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const surface = entry.view;
        var rect: winapi.RECT = undefined;
        _ = winapi.GetWindowRect(surface.host, &rect);
        var tl: winapi.POINT = .{ .x = rect.left, .y = rect.top };
        var br: winapi.POINT = .{ .x = rect.right, .y = rect.bottom };
        _ = winapi.ScreenToClient(self.hwnd, &tl);
        _ = winapi.ScreenToClient(self.hwnd, &br);
        if (x >= tl.x and x < br.x and y >= tl.y and y < br.y) return surface;
    }
    return null;
}

/// Translate a parent-client point into the given surface's host
/// coordinates.
fn pointToSurface(self: *Window, surface: *const Surface, x: i32, y: i32) winapi.POINT {
    var rect: winapi.RECT = undefined;
    _ = winapi.GetWindowRect(surface.host, &rect);
    var tl: winapi.POINT = .{ .x = rect.left, .y = rect.top };
    _ = winapi.ScreenToClient(self.hwnd, &tl);
    return .{ .x = x - tl.x, .y = y - tl.y };
}

/// Split the focused surface of the active tab in the given direction.
pub fn newSplit(self: *Window, direction: apprt.action.SplitDirection) !*Surface {
    const alloc = self.app.core_app.alloc;
    const tab = self.activeTab() orelse return error.NoActiveTab;
    const handle = handleOf(&tab.tree, tab.focused) orelse return error.NoFocusedSurface;

    var insert = try self.newSurfaceTree();
    defer insert.deinit();
    const surface = insert.nodes[0].leaf;

    const tree_direction: Tree.Split.Direction = switch (direction) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };

    var new_tree = try tab.tree.split(alloc, handle, tree_direction, 0.5, &insert);
    errdefer new_tree.deinit();
    var old_tree = tab.tree;
    tab.tree = new_tree;
    old_tree.deinit();

    surface.setVisible(true);
    self.layoutActiveTab();
    self.focusSurface(surface);
    return surface;
}

/// Move split focus within the active tab.
pub fn gotoSplit(self: *Window, target: apprt.action.GotoSplit) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.activeTab() orelse return;
    const from = handleOf(&tab.tree, tab.focused) orelse return;

    const goto: Tree.Goto = switch (target) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const to = tab.tree.goto(alloc, from, goto) catch |err| {
        log.err("error in split goto err={}", .{err});
        return;
    } orelse return;
    self.focusSurface(tab.tree.nodes[to.idx()].leaf);
}

/// Make all splits of the active tab equal size.
pub fn equalizeSplits(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.activeTab() orelse return;
    var new_tree = tab.tree.equalize(alloc) catch |err| {
        log.err("error equalizing splits err={}", .{err});
        return;
    };
    var old_tree = tab.tree;
    tab.tree = new_tree;
    old_tree.deinit();
    _ = &new_tree;
    self.layoutActiveTab();
}

/// Toggle zoom of the focused split (zoomed = takes the whole tab).
pub fn toggleSplitZoom(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const handle = handleOf(&tab.tree, tab.focused) orelse return;
    tab.tree.zoom(if (tab.tree.zoomed == null) handle else null);
    // A zoomed surface covers the terminal area; others hide.
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        entry.view.setVisible(tab.tree.zoomed == null or entry.view == tab.focused);
    }
    if (tab.tree.zoomed != null) zoomed: {
        var client: winapi.RECT = undefined;
        _ = winapi.GetClientRect(self.hwnd, &client);
        const strip = self.titlebarHeight();
        _ = winapi.SetWindowPos(
            tab.focused.host,
            null,
            0,
            strip,
            client.right - client.left,
            @max(0, client.bottom - client.top - strip),
            winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
        );
        const size = tab.focused.getSize() catch break :zoomed;
        tab.focused.core_surface.sizeCallback(size) catch {};
    } else self.layoutActiveTab();
}

/// Resize the focused split by the given amount (in pixels).
pub fn resizeSplit(self: *Window, value: apprt.action.ResizeSplit) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.activeTab() orelse return;
    const from = handleOf(&tab.tree, tab.focused) orelse return;

    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    const strip = self.titlebarHeight();

    const layout: Tree.Split.Layout, const sign: f32 = switch (value.direction) {
        .left => .{ .horizontal, -1 },
        .right => .{ .horizontal, 1 },
        .up => .{ .vertical, -1 },
        .down => .{ .vertical, 1 },
    };
    const span: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(1, client.right - client.left)),
        .vertical => @floatFromInt(@max(1, client.bottom - client.top - strip)),
    };
    const ratio: f16 = @floatCast(sign * @as(f32, @floatFromInt(value.amount)) / span);

    var new_tree = tab.tree.resize(alloc, from, layout, ratio) catch |err| {
        log.err("error resizing split err={}", .{err});
        return;
    };
    var old_tree = tab.tree;
    tab.tree = new_tree;
    old_tree.deinit();
    _ = &new_tree;
    self.layoutActiveTab();
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
    const title = tab.focused.title_text orelse "Ghostty";
    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], title) catch return;
    buf[len] = 0;
    _ = winapi.SetWindowTextW(self.hwnd, buf[0..len :0]);
    self.invalidateStrip();
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
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.core_surface.colorSchemeCallback(scheme) catch |err| {
                log.err("error in color scheme callback err={}", .{err});
            };
        }
    }

    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

// ---------------------------------------------------------------------
// Geometry

pub fn scale(self: *const Window, logical: i32) i32 {
    const dpi: i32 = @intCast(winapi.GetDpiForWindow(self.hwnd));
    return @divTrunc(logical * dpi, 96);
}

/// The title strip height in physical pixels.
pub fn titlebarHeight(self: *const Window) i32 {
    return self.scale(titlebar_height_logical);
}

/// Invalidate only the strip. Hover changes repaint constantly while
/// the mouse crosses the strip; invalidating the whole window made
/// every one of those also refresh the terminal renderer.
fn invalidateStrip(self: *const Window) void {
    var rect: winapi.RECT = .{
        .left = 0,
        .top = 0,
        .right = self.clientWidth(),
        .bottom = self.titlebarHeight(),
    };
    _ = winapi.InvalidateRect(self.hwnd, &rect, winapi.FALSE);
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

/// Keep one tooltip tool per tab slot with the full title as its text
/// (tab labels ellipsize). Called from paintTitlebar because every tab
/// change — create/close/reorder/retitle/resize — repaints the strip.
fn syncTabTooltips(self: *Window) void {
    const tooltip = self.tooltip orelse return;
    const n = self.tabs.items.len;

    // Skip the SendMessage churn when nothing the tools depend on
    // changed (the strip repaints on every hover change).
    const hash = hash: {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&n));
        const w = self.tabWidth();
        hasher.update(std.mem.asBytes(&w));
        for (self.tabs.items) |*tab| {
            hasher.update(tab.focused.title_text orelse "Ghostty");
            hasher.update(&.{0});
        }
        break :hash hasher.final();
    };
    if (hash == self.tooltip_hash) return;
    self.tooltip_hash = hash;

    // Drop tools for slots that no longer exist.
    while (self.tooltip_tools > n) {
        self.tooltip_tools -= 1;
        var ti: winapi.TOOLINFOW = .{
            .hwnd = self.hwnd,
            .uId = self.tooltip_tools,
        };
        _ = winapi.SendMessageW(
            tooltip,
            winapi.TTM_DELTOOLW,
            0,
            @bitCast(@intFromPtr(&ti)),
        );
    }

    for (self.tabs.items, 0..) |*tab, i| {
        const title = title: {
            const title = tab.focused.title_text orelse "Ghostty";
            // Truncate at a codepoint boundary so the UTF-16 buffer
            // below is always large enough.
            var end = @min(title.len, 255);
            while (end > 0 and title[end - 1] & 0xC0 == 0x80) end -= 1;
            break :title title[0..end];
        };
        var text: [256:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(text[0..255], title) catch 0;
        text[len] = 0;

        // No TTF_SUBCLASS: mouse messages are relayed explicitly from
        // the window procedure (relayToTooltip), which is deterministic
        // where comctl32's subclassing is not.
        var ti: winapi.TOOLINFOW = .{
            .hwnd = self.hwnd,
            .uId = i,
            .rect = self.tabRect(i),
            .lpszText = &text,
        };
        if (i < self.tooltip_tools) {
            _ = winapi.SendMessageW(
                tooltip,
                winapi.TTM_NEWTOOLRECTW,
                0,
                @bitCast(@intFromPtr(&ti)),
            );
            _ = winapi.SendMessageW(
                tooltip,
                winapi.TTM_UPDATETIPTEXTW,
                0,
                @bitCast(@intFromPtr(&ti)),
            );
        } else {
            _ = winapi.SendMessageW(
                tooltip,
                winapi.TTM_ADDTOOLW,
                0,
                @bitCast(@intFromPtr(&ti)),
            );
        }
    }
    self.tooltip_tools = n;
}

/// Relay a mouse message to the tooltip control so it can run its
/// hover show/hide logic against the tab tools.
fn relayToTooltip(
    self: *Window,
    msg: winapi.UINT,
    wparam: winapi.WPARAM,
    lparam: winapi.LPARAM,
) void {
    const tooltip = self.tooltip orelse return;
    var m: winapi.MSG = .{
        .hwnd = self.hwnd,
        .message = msg,
        .wParam = wparam,
        .lParam = lparam,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    _ = winapi.SendMessageW(
        tooltip,
        winapi.TTM_RELAYEVENT,
        0,
        @bitCast(@intFromPtr(&m)),
    );
}

/// The cached strip fonts for the current DPI, (re)creating on first
/// use and DPI changes.
fn stripFonts(self: *Window) StripFonts {
    const dpi = winapi.GetDpiForWindow(self.hwnd);
    if (self.fonts) |f| {
        if (f.dpi == dpi) return f;
        if (f.text) |t| _ = winapi.DeleteObject(t);
        if (f.glyph) |g| _ = winapi.DeleteObject(g);
    }
    const f: StripFonts = .{
        .dpi = dpi,
        .text = winapi.CreateFontW(
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
        ),
        .glyph = winapi.CreateFontW(
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
        ),
    };
    self.fonts = f;
    return f;
}

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

    const fonts = self.stripFonts();
    const text_font = fonts.text;
    const glyph_font = fonts.glyph;

    // Tabs
    for (self.tabs.items, 0..) |*tab, i| {
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

            const title = tab.focused.title_text orelse "Ghostty";
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

    self.syncTabTooltips();
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
    const tab = self.activeSurface() orelse return;
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
    const tab = self.activeSurface() orelse return;
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
                // The maximize button reports HTMAXBUTTON so Windows 11
                // shows the snap-layouts flyout on hover; its input
                // arrives as NC messages handled below. Other strip
                // elements get normal client clicks; the rest of the
                // strip drags the window.
                switch (self.hitTestStrip(pt.x, pt.y)) {
                    .none => return winapi.HTCAPTION,
                    .caption => |button| if (button == .maximize)
                        return winapi.HTMAXBUTTON,
                    else => {},
                }
                return winapi.HTCLIENT;
            }

            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // NC mouse handling for the HTMAXBUTTON region (snap layouts).
        winapi.WM_NCMOUSEMOVE => {
            var pt: winapi.POINT = .{
                .x = lparamX(lparam),
                .y = lparamY(lparam),
            };
            _ = winapi.ScreenToClient(hwnd, &pt);
            const hover: Hover = if (pt.y >= 0 and pt.y < self.titlebarHeight())
                self.hitTestStrip(pt.x, pt.y)
            else
                .none;
            if (!std.meta.eql(hover, self.hover)) {
                self.hover = hover;
                self.invalidateStrip();
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_NCMOUSELEAVE => {
            if (!std.meta.eql(self.hover, Hover.none)) {
                self.hover = .none;
                self.invalidateStrip();
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_NCLBUTTONDOWN => {
            // Swallow presses on the maximize button so DefWindowProc
            // doesn't start a move/size loop; the action happens on up.
            if (wparam == @as(usize, @intCast(winapi.HTMAXBUTTON))) return 0;
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_NCLBUTTONUP => {
            if (wparam == @as(usize, @intCast(winapi.HTMAXBUTTON))) {
                self.captionButtonClick(.maximize);
                return 0;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // From a per-split scrollbar control (lparam = its handle).
        winapi.WM_VSCROLL => {
            if (lparam == 0) return 0;
            const sb: winapi.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const tab = self.activeTab() orelse return 0;
            var it = tab.tree.iterator();
            const surface = while (it.next()) |entry| {
                if (entry.view.scrollbar == sb) break entry.view;
            } else return 0;

            const code: u16 = @truncate(wparam);

            // Clicking the scrollbar focuses it; hand focus back when
            // the interaction ends so keys keep going to the terminal.
            if (code == winapi.SB_ENDSCROLL) {
                _ = winapi.SetFocus(hwnd);
                return 0;
            }

            var si: winapi.SCROLLINFO = .{
                .fMask = winapi.SIF_RANGE | winapi.SIF_PAGE |
                    winapi.SIF_POS | winapi.SIF_TRACKPOS,
            };
            if (winapi.GetScrollInfo(sb, winapi.SB_CTL, &si) == 0) return 0;
            const page: i32 = @intCast(@max(1, si.nPage));
            const pos: i32 = switch (code) {
                winapi.SB_LINEUP => si.nPos - 1,
                winapi.SB_LINEDOWN => si.nPos + 1,
                winapi.SB_PAGEUP => si.nPos - page,
                winapi.SB_PAGEDOWN => si.nPos + page,
                winapi.SB_THUMBPOSITION, winapi.SB_THUMBTRACK => si.nTrackPos,
                winapi.SB_TOP => si.nMin,
                winapi.SB_BOTTOM => si.nMax,
                else => return 0,
            };
            const max_pos: i32 = @max(0, si.nMax - page + 1);
            const row: usize = @intCast(std.math.clamp(pos, 0, max_pos));
            _ = surface.core_surface.performBindingAction(
                .{ .scroll_to_row = row },
            ) catch |err| {
                log.err("error in scroll_to_row err={}", .{err});
            };
            return 0;
        },

        winapi.WM_PAINT => {
            var ps: winapi.PAINTSTRUCT = undefined;
            var below_strip = false;
            if (winapi.BeginPaint(hwnd, &ps)) |hdc| {
                const strip_h = self.titlebarHeight();
                below_strip = ps.rcPaint.bottom > strip_h;

                if (ps.rcPaint.top < strip_h) self.paintTitlebar(hdc);

                // Fill the terminal area background: visible only in
                // the gaps between splits (children are clipped).
                if (below_strip) {
                    var client: winapi.RECT = undefined;
                    _ = winapi.GetClientRect(hwnd, &client);
                    var area: winapi.RECT = .{
                        .left = 0,
                        .top = strip_h,
                        .right = client.right,
                        .bottom = client.bottom,
                    };
                    if (winapi.CreateSolidBrush(0x00101010)) |brush| {
                        defer _ = winapi.DeleteObject(brush);
                        _ = winapi.FillRect(hdc, &area, brush);
                    }
                }

                _ = winapi.EndPaint(hwnd, &ps);
            }

            // Strip-only paints (hover highlights) must not redraw the
            // terminal; refresh only when the GL area was invalidated.
            if (below_strip) {
                if (self.activeSurface()) |surface| {
                    surface.core_surface.refreshCallback() catch |err| {
                        log.err("error in refresh callback err={}", .{err});
                    };
                }
            }
            return 0;
        },

        winapi.WM_SIZE => {
            // Minimize fully occludes every surface: tell the
            // renderers so they stop rebuilding cells and drawing
            // until restore. (wparam: 1 = minimized.)
            const minimized = wparam == 1;
            if (minimized != self.minimized) {
                self.minimized = minimized;
                self.setOccluded(minimized);
            }
            if (minimized) return 0;

            // Interactive border drags deliver WM_SIZE per mouse move;
            // each layout runs a full per-split resize pipeline, so
            // coalesce to ~60Hz (WM_EXITSIZEMOVE does a final layout).
            if (self.in_size_move) {
                const now = std.time.milliTimestamp();
                if (now - self.divider_layout_ms < 16) return 0;
                self.divider_layout_ms = now;
            }

            self.layoutActiveTab();
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            return 0;
        },

        // Dropped files paste their paths into the focused surface,
        // double-quoted when cmd/pwsh would split them.
        winapi.WM_DROPFILES => {
            const hdrop: winapi.HDROP = @ptrFromInt(wparam);
            defer winapi.DragFinish(hdrop);
            const surface = self.activeSurface() orelse return 0;
            const alloc = self.app.core_app.alloc;

            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(alloc);

            const count = winapi.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var path_w: [4096]u16 = undefined;
                const wlen = winapi.DragQueryFileW(hdrop, i, &path_w, path_w.len);
                if (wlen == 0 or wlen >= path_w.len) continue;

                var path8: [path_w.len * 3]u8 = undefined;
                const len = std.unicode.utf16LeToUtf8(
                    &path8,
                    path_w[0..wlen],
                ) catch continue;
                const path = path8[0..len];

                drop: {
                    if (text.items.len > 0) text.append(alloc, ' ') catch break :drop;
                    // Paths can't contain double quotes on Windows, so
                    // plain wrapping is a complete escape.
                    const quote = std.mem.indexOfAny(u8, path, " \t&^=;,'`(){}[]!") != null;
                    if (quote) text.append(alloc, '"') catch break :drop;
                    text.appendSlice(alloc, path) catch break :drop;
                    if (quote) text.append(alloc, '"') catch break :drop;
                }
            }

            if (text.items.len > 0) {
                const z = text.toOwnedSliceSentinel(alloc, 0) catch return 0;
                defer alloc.free(z);
                surface.pasteText(z);
            }
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
            for (self.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    entry.view.core_surface.contentScaleCallback(content_scale) catch |err| {
                        log.err("error in content scale callback err={}", .{err});
                    };
                }
            }
            return 0;
        },

        winapi.WM_SETFOCUS, winapi.WM_KILLFOCUS => {
            if (self.activeSurface()) |surface| {
                surface.core_surface.focusCallback(msg == winapi.WM_SETFOCUS) catch |err| {
                    log.err("error in focus callback err={}", .{err});
                };
            }

            // Quick terminals hide when they lose focus — except to
            // their own command palette.
            if (self.quick and msg == winapi.WM_KILLFOCUS and
                self.palette == null)
            {
                _ = winapi.ShowWindow(hwnd, winapi.SW_HIDE);
                self.setOccluded(true);
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

                // Resize cursor over (or while dragging) a divider.
                const divider: ?DividerHit = self.divider_drag orelse
                    self.dividerAt(pt.x, pt.y);
                if (divider) |div| {
                    const id: u16 = switch (div.layout) {
                        .horizontal => winapi.IDC_SIZEWE,
                        .vertical => winapi.IDC_SIZENS,
                    };
                    if (winapi.loadSystemCursor(id)) |c| {
                        _ = winapi.SetCursor(c);
                        return 1;
                    }
                }

                const surface = self.surfaceAt(pt.x, pt.y) orelse
                    self.activeSurface() orelse break :cursor;
                const cursor = surface.cursor orelse break :cursor;
                _ = winapi.SetCursor(cursor);
                return 1;
            }
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_ENTERSIZEMOVE => {
            self.in_size_move = true;
            _ = winapi.SetTimer(hwnd, modal_tick_timer_id, 16, null);
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_EXITSIZEMOVE => {
            self.in_size_move = false;
            _ = winapi.KillTimer(hwnd, modal_tick_timer_id);
            // Final exact layout for whatever the throttle skipped.
            self.layoutActiveTab();
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
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
            if (self.activeSurface()) |surface| {
                surface.core_surface.preeditCallback(null) catch |err| {
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
            // Wheel scrolls the surface under the cursor (lparam here
            // is in screen coordinates).
            var pt: winapi.POINT = .{
                .x = lparamX(lparam),
                .y = lparamY(lparam),
            };
            _ = winapi.ScreenToClient(hwnd, &pt);
            const surface = self.surfaceAt(pt.x, pt.y) orelse
                self.activeSurface() orelse return 0;
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
            surface.core_surface.scrollCallback(0, yoff * 3, .{}) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            const x = lparamX(lparam);
            const y = lparamY(lparam);

            // Live divider drag: update the split ratio in place.
            if (self.divider_drag) |drag| {
                const tab = self.activeTab() orelse return 0;
                const ratio: f32 = switch (drag.layout) {
                    .horizontal => @as(f32, @floatFromInt(x - drag.rect.left)) /
                        @as(f32, @floatFromInt(@max(1, drag.rect.right - drag.rect.left))),
                    .vertical => @as(f32, @floatFromInt(y - drag.rect.top)) /
                        @as(f32, @floatFromInt(@max(1, drag.rect.bottom - drag.rect.top))),
                };
                tab.tree.resizeInPlace(
                    drag.handle,
                    @floatCast(std.math.clamp(ratio, 0.05, 0.95)),
                );
                const now = std.time.milliTimestamp();
                if (now - self.divider_layout_ms >= 16) {
                    self.divider_layout_ms = now;
                    self.layoutActiveTab();
                }
                return 0;
            }

            // Live tab drag: reorder when the cursor crosses into
            // another tab's slot.
            if (self.tab_drag) |from| {
                const n = self.tabs.items.len;
                const target: usize = @intCast(std.math.clamp(
                    @divTrunc(@as(i32, x), @max(1, self.tabWidth())),
                    0,
                    @as(i32, @intCast(n - 1)),
                ));
                if (target != from) {
                    const tab = self.tabs.orderedRemove(from);
                    self.tabs.insertAssumeCapacity(target, tab);
                    self.active_tab = target;
                    self.tab_drag = target;
                    self.invalidateStrip();
                }
                return 0;
            }

            self.relayToTooltip(msg, wparam, lparam);

            const hover: Hover = if (y < self.titlebarHeight())
                self.hitTestStrip(x, y)
            else
                .none;
            if (!std.meta.eql(hover, self.hover)) {
                self.hover = hover;
                self.invalidateStrip();
            }

            const surface = self.surfaceAt(x, y) orelse
                self.activeSurface() orelse return 0;
            const pt = self.pointToSurface(surface, x, y);
            surface.core_surface.cursorPosCallback(.{
                .x = @floatFromInt(pt.x),
                .y = @floatFromInt(pt.y),
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
            // Button presses dismiss any showing tab tooltip.
            self.relayToTooltip(msg, wparam, lparam);

            // A tab drag in progress ends on release wherever it is.
            if (self.tab_drag != null and msg == winapi.WM_LBUTTONUP) {
                self.tab_drag = null;
                _ = winapi.ReleaseCapture();
                return 0;
            }

            // Clicks in the strip operate tabs/buttons, never the
            // terminal.
            const cy = lparamY(lparam);
            if (cy >= 0 and cy < self.titlebarHeight()) {
                // Tabs activate on press, like native tab strips, and
                // the press begins a possible drag-reorder.
                if (msg == winapi.WM_LBUTTONDOWN) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .tab => |i| {
                            self.activateTab(i);
                            self.tab_drag = i;
                            _ = winapi.SetCapture(hwnd);
                        },
                        else => {},
                    }
                    return 0;
                }
                if (msg == winapi.WM_LBUTTONUP) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .none => {},
                        .caption => |button| self.captionButtonClick(button),
                        // Activation happened on the press.
                        .tab => {},
                        // Closing a tab closes every split in it.
                        .tab_close => |i| {
                            var it = self.tabs.items[i].tree.iterator();
                            while (it.next()) |entry| {
                                entry.view.should_close = true;
                            }
                        },
                        .new_tab => _ = self.newTab() catch |err| {
                            log.err("error creating tab err={}", .{err});
                        },
                    }
                }
                return 0;
            }

            const x = lparamX(lparam);

            // Divider drags begin on press in a gap and end on release.
            if (msg == winapi.WM_LBUTTONDOWN) {
                if (self.dividerAt(x, cy)) |hit| {
                    self.divider_drag = hit;
                    _ = winapi.SetCapture(hwnd);
                    return 0;
                }
            }
            if (self.divider_drag != null and msg == winapi.WM_LBUTTONUP) {
                self.divider_drag = null;
                _ = winapi.ReleaseCapture();
                // Final exact layout for whatever the throttle skipped.
                self.layoutActiveTab();
                return 0;
            }

            // Clicking a split focuses it before the press is
            // delivered.
            const surface = self.surfaceAt(x, cy) orelse
                self.activeSurface() orelse return 0;
            if (msg == winapi.WM_LBUTTONDOWN or
                msg == winapi.WM_RBUTTONDOWN or
                msg == winapi.WM_MBUTTONDOWN)
            {
                self.focusSurface(surface);
            }

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

            _ = surface.core_surface.mouseButtonCallback(
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
    const tab = self.activeSurface() orelse return;
    const vk: u8 = @truncate(wparam);
    const released = msg == winapi.WM_KEYUP or msg == winapi.WM_SYSKEYUP;
    const was_down = (lparam & (1 << 30)) != 0;

    const action: input.Action = if (released)
        .release
    else if (was_down)
        .repeat
    else
        .press;

    // Key-to-present latency tracing (GHOSTTY_PERF_TRACE).
    if (action == .press) perf.keyPress();

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
    const tab = self.activeSurface() orelse return;

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
