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
const SearchBar = @import("SearchBar.zig");
const winapi = @import("winapi.zig");
const perf = @import("../../perf.zig");

const log = std.log.scoped(.win32);

/// The split tree type for one tab's surfaces.
pub const Tree = datastruct.SplitTree(Surface);

/// One tab: a split tree of surfaces and which of them has focus.
pub const Tab = struct {
    tree: Tree,
    focused: *Surface,
    /// A manual rename (right-click -> Rename), owned by the app
    /// allocator; overrides the surface's auto-title when set.
    custom_title: ?[]const u8 = null,

    /// The title to display: manual rename, else the focused surface's
    /// title, else a default.
    pub fn title(self: *const Tab) []const u8 {
        return self.custom_title orelse (self.focused.title_text orelse "Ghostty");
    }
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

/// Press point (parent-client px) of a pending tab drag, and whether
/// the pointer has since moved past the system drag threshold. Below
/// it, a press+release is a plain click: the tab doesn't reorder and
/// (critically) doesn't tear off on a small cursor slip.
tab_drag_origin: winapi.POINT = .{ .x = 0, .y = 0 },
tab_drag_engaged: bool = false,

/// Horizontal scroll offset (px) of the tab strip, for when the tabs
/// plus the new-tab button overflow the strip width. Clamped to
/// [0, maxTabScroll]; the wheel over the strip and tab activation
/// adjust it. Zero whenever everything fits.
tab_scroll: i32 = 0,

/// In-strip tab rename: when active, the tab `rename_tab` shows an
/// editable text field backed by `rename_buf` (UTF-16, like the search
/// bar's needle). Keys are captured by the window proc while active.
rename_active: bool = false,
rename_tab: usize = 0,
rename_buf: std.ArrayList(u16) = .empty,
/// True until the first keystroke of a rename, so the pre-filled title
/// behaves like a selection (the first key replaces it).
rename_fresh: bool = false,

/// Last divider-drag relayout instant, for throttling: every layout
/// runs the full resize pipeline (ConPTY resize + renderer resize per
/// split), so high-rate mouse moves are coalesced to ~60Hz with a
/// final exact layout on release.
divider_layout_ms: i64 = 0,

/// Whether the window is currently minimized (renderer occlusion).
minimized: bool = false,

/// Inside an interactive move/size modal loop (WM_ENTERSIZEMOVE).
in_size_move: bool = false,

/// Remaining deferred post-resize repaint ticks (see WM_TIMER). The
/// terminal grid resizes synchronously, but the shell's reflowed
/// prompt arrives over the next few frames via ConPTY; these ticks
/// keep refreshing until it has been drawn.
resize_repaint_left: u8 = 0,

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

/// The search bar while a search is active.
search: ?*SearchBar = null,

/// Whether window-level transparency is currently applied; toggled by
/// toggle_background_opacity on windows that start transparent.
transparent: bool = false,

/// Borderless-fullscreen state. While true the title strip is hidden
/// (titlebarHeight returns 0) and the window fills the monitor; the
/// saved placement/style restore the exact prior windowed geometry.
fullscreen: bool = false,
saved_placement: winapi.WINDOWPLACEMENT = undefined,
saved_style: isize = 0,

/// The key event from the last WM_KEYDOWN that the core did not
/// consume; WM_CHAR completes it with the layout-cooked text.
pending_key_event: ?input.KeyEvent = null,

/// Buffer backing pending_key_event.utf8 across the KEYDOWN→CHAR pair.
utf8_buf: [4]u8 = undefined,

/// Pending high surrogate from WM_CHAR, awaiting its low half.
high_surrogate: ?u16 = null,

/// Whether the ctrl currently reported down by GetKeyState is the one
/// Windows injects for AltGr (see keyEvent): while true, ctrl+alt are
/// stripped from key event mods so AltGr chords report clean.
altgr_down: bool = false,

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
/// The scrollbar column each leaf reserves beside its GL host; also
/// used by setInitialWindowSize to compute the client width a given
/// grid size needs.
pub const scrollbar_width_logical: i32 = 12;
const tab_width_logical: i32 = 190;
const new_tab_width_logical: i32 = 36;
/// Default window size in logical (96-dpi) pixels, scaled to the
/// monitor DPI at creation so the window isn't tiny on high-DPI
/// displays (window-width/height config overrides via initial_size).
const default_window_width_logical: i32 = 800;
const default_window_height_logical: i32 = 600;
const modal_tick_timer_id: usize = 1;
const resize_repaint_timer_id: usize = 2;
/// How many deferred repaint ticks fire after a resize. ConPTY reflows
/// asynchronously, so the prompt the shell repaints lands a few frames
/// after our grid resize; a single immediate render would miss it.
const resize_repaint_ticks: u8 = 6;

pub const CreateOptions = struct {
    quick: bool = false,
    /// Create the window with no tabs and leave it hidden. Used by
    /// tab tear-off, which moves an existing tab in and then shows the
    /// window at the cursor.
    no_initial_tab: bool = false,
};

/// The docked geometry for a quick terminal on the primary monitor,
/// honoring quick-terminal-position and -size. Delegates the size to
/// the shared QuickTerminalSize.calculate so the primary/secondary
/// axis and per-position defaults match the other apprts.
fn quickTerminalGeometry(app: *App) struct { x: i32, y: i32, w: i32, h: i32 } {
    const pos = app.config.@"quick-terminal-position";
    const sw: i32 = @max(1, winapi.GetSystemMetrics(winapi.SM_CXSCREEN));
    const sh: i32 = @max(1, winapi.GetSystemMetrics(winapi.SM_CYSCREEN));

    const dims = app.config.@"quick-terminal-size".calculate(pos, .{
        .width = @intCast(sw),
        .height = @intCast(sh),
    });
    const w: i32 = @intCast(dims.width);
    const h: i32 = @intCast(dims.height);
    const x: i32, const y: i32 = switch (pos) {
        .top => .{ @divTrunc(sw - w, 2), 0 },
        .bottom => .{ @divTrunc(sw - w, 2), sh - h },
        .left => .{ 0, @divTrunc(sh - h, 2) },
        .right => .{ sw - w, @divTrunc(sh - h, 2) },
        .center => .{ @divTrunc(sw - w, 2), @divTrunc(sh - h, 2) },
    };
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// Create a window with one tab, show it, and return it.
pub fn create(alloc: Allocator, app: *App, opts: CreateOptions) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    // Quick terminals are topmost tool windows docked per the config's
    // quick-terminal-position / -size on the primary monitor.
    const qt = quickTerminalGeometry(app);

    const hwnd = winapi.CreateWindowExW(
        if (opts.quick) winapi.WS_EX_TOOLWINDOW | winapi.WS_EX_TOPMOST else 0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        // CLIPCHILDREN so painting the split gaps can't stomp the GL
        // host children.
        winapi.WS_OVERLAPPEDWINDOW | winapi.WS_CLIPCHILDREN,
        if (opts.quick) qt.x else winapi.CW_USEDEFAULT,
        if (opts.quick) qt.y else winapi.CW_USEDEFAULT,
        if (opts.quick) qt.w else 800,
        if (opts.quick) qt.h else 600,
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

    // DPI-scale the default window size BEFORE the first tab exists.
    // The window was created at a fixed 800x600 physical size (tiny on
    // a high-DPI monitor); growing it here — while the client is still
    // empty — means newTab() creates the ConPTY/shell at the final grid
    // instead of starting small and reflowing on a later resize, which
    // scrolls the shell banner. maximize/fullscreen override the size,
    // so skip it for those.
    if (!opts.no_initial_tab and !opts.quick and
        !app.config.maximize and app.config.fullscreen == .false)
    {
        _ = winapi.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            self.scale(default_window_width_logical),
            self.scale(default_window_height_logical),
            winapi.SWP_NOMOVE | winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
        );
    }

    if (!opts.no_initial_tab) _ = try self.newTab();
    errdefer self.closeAllTabs();

    // Files dropped on the window paste their (quoted) paths.
    winapi.DragAcceptFiles(hwnd, winapi.TRUE);

    // Window-level alpha is the pragmatic background-opacity for a
    // GL-in-DWM window (per-pixel GL alpha needs DirectComposition).
    if (app.config.@"background-opacity" < 1.0) self.setOpacity(
        app.config.@"background-opacity",
    );

    // background-blur: frost the desktop behind the (translucent) window
    // via the DWM accent policy. Pure compositor effect — no GL interop.
    self.applyBlur();

    // Startup geometry from config, for a normal (non-quick, non-
    // tear-off) window: a DPI-scaled default size, an explicit
    // position, then maximized or the default placement.
    if (!opts.no_initial_tab and !opts.quick) {
        // Position is honored only when BOTH coordinates are set, per
        // the documented behavior. (The DPI-scaled default size was
        // already applied above, before the first tab, so the shell
        // never sees a startup reflow.)
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                _ = winapi.SetWindowPos(
                    hwnd,
                    null,
                    px,
                    py,
                    0,
                    0,
                    winapi.SWP_NOZORDER | winapi.SWP_NOSIZE | winapi.SWP_NOACTIVATE,
                );
            }
        }
        const show: i32 = if (app.config.maximize)
            winapi.SW_MAXIMIZE
        else
            winapi.SW_SHOWDEFAULT;
        _ = winapi.ShowWindow(hwnd, show);
        // Borderless fullscreen at startup (any non-false value).
        if (app.config.fullscreen != .false) self.toggleFullscreen();
    } else if (!opts.no_initial_tab) {
        _ = winapi.ShowWindow(hwnd, winapi.SW_SHOWDEFAULT);
    }

    // Report the OS theme so window-theme=auto and light/dark
    // conditional config work; also sets the DWM dark caption.
    self.notifyColorScheme();

    return self;
}

/// Destroy the window and any remaining tabs. Must not be called from
/// inside the window procedure.
pub fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    self.rename_buf.deinit(alloc);
    if (self.palette) |palette| palette.destroy();
    if (self.search) |search| search.destroy();
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
    while (self.tabs.pop()) |tab| {
        if (tab.custom_title) |t| alloc.free(t);
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

/// Detach tab `idx` into a fresh top-level window at the cursor,
/// leaving the rest of this window's tabs behind. Called when a tab
/// drag is released outside the strip; a no-op for the only tab (there
/// would be nothing to leave behind). The tab keeps its surfaces, split
/// tree, and GL contexts intact — only the host windows are reparented.
fn tearOffTab(self: *Window, idx: usize) !void {
    if (self.tabs.items.len <= 1 or idx >= self.tabs.items.len) return;
    const app = self.app;
    const alloc = app.core_app.alloc;

    // Everything that can fail happens before the tab is moved, so a
    // failure leaves this window untouched and frees the empty window.
    const window = try Window.create(alloc, app, .{ .no_initial_tab = true });
    errdefer window.destroy();
    try window.tabs.ensureTotalCapacity(alloc, 1);
    try app.windows.append(alloc, window);

    // The point of no return: hand the tab to the new window and
    // reparent its surfaces. No fallible step may follow.
    const tab = self.tabs.orderedRemove(idx);
    window.tabs.appendAssumeCapacity(tab);
    var it = window.tabs.items[0].tree.iterator();
    while (it.next()) |entry| {
        const surface = entry.view;

        // A search bar pinned to a surface in this tab belongs to the
        // source window; close it rather than leave it targeting a
        // surface that now lives elsewhere. (destroy clears self.search.)
        if (self.search) |search| {
            if (search.surface == surface) search.destroy();
        }

        surface.window = window;
        _ = winapi.SetParent(surface.host, window.hwnd);
        if (surface.scrollbar) |sb| _ = winapi.SetParent(sb.hwnd, window.hwnd);
    }

    // The source keeps a valid active tab.
    self.activateTab(@min(idx, self.tabs.items.len - 1));

    // Size the new window like the source and drop it at the cursor so
    // the torn-off tab appears under the pointer, then reveal it.
    var wr: winapi.RECT = undefined;
    _ = winapi.GetWindowRect(self.hwnd, &wr);
    var cur: winapi.POINT = undefined;
    _ = winapi.GetCursorPos(&cur);
    const w = wr.right - wr.left;
    const h = wr.bottom - wr.top;

    // Keep the title strip reachable on the drop monitor. Virtual-screen
    // coordinates can be negative (monitors above/left of the primary),
    // so clamp against that monitor's work area, not 0.
    var y = cur.y - window.titlebarHeight();
    const mon = winapi.MonitorFromPoint(cur, winapi.MONITOR_DEFAULTTONEAREST);
    var mi: winapi.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(winapi.MONITORINFO);
    if (winapi.GetMonitorInfoW(mon, &mi) != 0) y = @max(mi.rcWork.top, y);

    _ = winapi.SetWindowPos(
        window.hwnd,
        null,
        cur.x - @divTrunc(w, 2),
        y,
        w,
        h,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
    );
    _ = winapi.ShowWindow(window.hwnd, winapi.SW_SHOW);
    window.activateTab(0);
    _ = winapi.SetForegroundWindow(window.hwnd);
}

/// Re-apply window-level transparency and blur from the current config.
/// Called on config reload so changing background-opacity/background-blur
/// (e.g. from the settings window) takes effect live, not just on the
/// next launch.
pub fn reapplyTransparency(self: *Window) void {
    self.setOpacity(self.app.config.@"background-opacity");
    self.applyBlur();
}

/// Frost the desktop behind the window when `background-blur` is set.
/// Uses the DWM accent policy (a compositor effect), so it only shows
/// where the window is translucent — i.e. it pairs with
/// `background-opacity` < 1. Whole-window, so text is frosted too; the
/// crisp per-pixel variant needs the DirectComposition path. No GL/D3D
/// interop here, so this cannot affect the GPU the way that path can.
fn applyBlur(self: *Window) void {
    const enabled = self.app.config.@"background-blur".enabled();
    const light = self.isLight();
    // A faint tint over the blur for legibility (0xAABBGGRR).
    const tint: u32 = if (light) 0x14FFFFFF else 0x14000000;
    var accent: winapi.ACCENT_POLICY = .{
        .AccentState = if (enabled)
            winapi.ACCENT_ENABLE_ACRYLICBLURBEHIND
        else
            winapi.ACCENT_DISABLED,
        .GradientColor = tint,
    };
    var data: winapi.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = winapi.WCA_ACCENT_POLICY,
        .pvData = &accent,
        .cbData = @sizeOf(winapi.ACCENT_POLICY),
    };
    _ = winapi.SetWindowCompositionAttribute(self.hwnd, &data);
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
    // Assign before focusing: the focus switch sends WM_KILLFOCUS to
    // this window synchronously, and a quick terminal checks state to
    // decide whether it may hide.
    const palette = try CommandPalette.create(self.app.core_app.alloc, self);
    self.palette = palette;
    _ = winapi.SetFocus(palette.hwnd);
}

/// Remove a surface from whichever tab contains it, collapsing its
/// split; an empty tab is removed. When the last tab goes, the window
/// flags itself for close; the App run loop destroys it.
pub fn removeSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab_idx = self.tabOf(surface) orelse return;
    const tab = &self.tabs.items[tab_idx];

    // The tree (and possibly the tab list) is about to be rebuilt; an
    // in-progress divider drag holds a handle into the old tree. This
    // can happen mid-drag: a background shell exiting runs this from
    // the app-loop sweep. Release the capture the drag was holding too,
    // or it leaks until the next unrelated press/release.
    if (self.divider_drag != null) {
        self.divider_drag = null;
        _ = winapi.ReleaseCapture();
    }

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
        if (tab.custom_title) |t| alloc.free(t);
        _ = self.tabs.orderedRemove(tab_idx);

        // Fix up everything that indexes the tab list, including an
        // in-progress drag or rename of a shifted (or removed) tab.
        if (self.tab_drag) |d| {
            if (d == tab_idx) {
                self.tab_drag = null;
                _ = winapi.ReleaseCapture();
            } else if (d > tab_idx) self.tab_drag = d - 1;
        }
        if (self.rename_active) {
            if (self.rename_tab == tab_idx) {
                self.rename_active = false;
            } else if (self.rename_tab > tab_idx) self.rename_tab -= 1;
        }

        if (self.tabs.items.len == 0) {
            self.should_close = true;
            return;
        }

        // Closing a background tab must not steal the view: only
        // re-activate when the removed tab was the active one.
        if (tab_idx == self.active_tab) {
            self.activateTab(@min(tab_idx, self.tabs.items.len - 1));
        } else {
            if (tab_idx < self.active_tab) self.active_tab -= 1;
            self.invalidateStrip();
        }
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

/// Strip context menu. With a tab index: tab actions (rename/close)
/// plus the general actions; on the empty strip / new-tab button: just
/// the general actions. This is the fork's main discovery surface for
/// users who don't know the keybinds — a lightweight substitute for a
/// menu bar (macOS/GTK expose these elsewhere).
fn showStripMenu(self: *Window, idx: ?usize) void {
    if (idx) |i| if (i >= self.tabs.items.len) return;
    const menu = winapi.CreatePopupMenu() orelse return;
    defer _ = winapi.DestroyMenu(menu);
    const S = std.unicode.utf8ToUtf16LeStringLiteral;
    if (idx != null) {
        _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 1, S("Rename\u{2026}"));
        _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 2, S("Close Tab"));
        if (self.tabs.items.len > 1)
            _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 3, S("Close Other Tabs"));
        _ = winapi.AppendMenuW(menu, winapi.MF_SEPARATOR, 0, null);
    }
    _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 10, S("New Tab"));
    _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 11, S("New Split Right"));
    _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 12, S("New Split Down"));
    _ = winapi.AppendMenuW(menu, winapi.MF_SEPARATOR, 0, null);
    _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 13, S("Command Palette\u{2026}"));
    _ = winapi.AppendMenuW(menu, winapi.MF_STRING, 14, S("Settings\u{2026}"));

    var pt: winapi.POINT = .{ .x = 0, .y = 0 };
    _ = winapi.GetCursorPos(&pt);
    const cmd = winapi.TrackPopupMenu(
        menu,
        winapi.TPM_RIGHTBUTTON | winapi.TPM_RETURNCMD,
        pt.x,
        pt.y,
        0,
        self.hwnd,
        null,
    );
    switch (cmd) {
        // Defer rename until the menu's modal loop has fully exited and
        // focus has settled, else the new EDIT gets an immediate
        // WM_KILLFOCUS and commits empty.
        1 => if (idx) |i| {
            _ = winapi.PostMessageW(self.hwnd, winapi.WM_APP_RENAME, i, 0);
        },
        2 => if (idx) |i| self.closeTabsFrom(.this, i),
        3 => if (idx) |i| self.closeTabsFrom(.other, i),
        10 => _ = self.newTab() catch |err| log.err("menu new tab err={}", .{err}),
        11 => _ = self.newSplit(.right) catch |err| log.err("menu split err={}", .{err}),
        12 => _ = self.newSplit(.down) catch |err| log.err("menu split err={}", .{err}),
        13 => self.togglePalette() catch |err| log.err("menu palette err={}", .{err}),
        14 => _ = self.app.performAction(.app, .open_config, {}) catch |err|
            log.err("menu settings err={}", .{err}),
        else => {},
    }
}

/// Begin an in-strip rename of tab `idx`: the tab becomes an editable
/// field pre-filled with the current title. The window proc captures
/// keys while active (Enter commits, Escape cancels, Backspace edits).
fn startRenameTab(self: *Window, idx: usize) void {
    if (self.rename_active) self.commitRename(false);
    if (idx >= self.tabs.items.len) return;
    const alloc = self.app.core_app.alloc;

    self.rename_buf.clearRetainingCapacity();
    var buf: [512]u16 = undefined;
    const title = utf8Capped(self.tabs.items[idx].title(), buf.len);
    const n = std.unicode.utf8ToUtf16Le(&buf, title) catch 0;
    self.rename_buf.appendSlice(alloc, buf[0..n]) catch {};

    self.rename_active = true;
    self.rename_fresh = true;
    self.rename_tab = idx;
    _ = winapi.SetFocus(self.hwnd); // route keys to the window proc
    self.invalidateStrip();
}

/// Commit (save=true) or cancel the in-progress rename.
fn commitRename(self: *Window, save: bool) void {
    if (!self.rename_active) return;
    self.rename_active = false;

    if (save and self.rename_tab < self.tabs.items.len and self.rename_buf.items.len > 0) {
        var u8buf: [1024]u8 = undefined;
        // utf16LeToUtf8 doesn't bounds-check its destination either;
        // 3 output bytes per unit is the worst case. Don't split a
        // surrogate pair at the cap.
        var units = self.rename_buf.items;
        if (units.len > u8buf.len / 3) {
            var end = u8buf.len / 3;
            if (units[end - 1] >= 0xD800 and units[end - 1] <= 0xDBFF) end -= 1;
            units = units[0..end];
        }
        const len = std.unicode.utf16LeToUtf8(&u8buf, units) catch 0;
        if (len > 0) {
            const alloc = self.app.core_app.alloc;
            const tab = &self.tabs.items[self.rename_tab];
            if (tab.custom_title) |prev| alloc.free(prev);
            tab.custom_title = alloc.dupe(u8, u8buf[0..len]) catch null;
        }
    }

    self.rename_buf.clearRetainingCapacity();
    self.invalidateStrip();
    self.syncTitle();
    if (self.activeSurface()) |s| self.focusSurface(s);
}

/// Handle a typed character during a rename. Returns true if consumed.
fn renameChar(self: *Window, ch: u16) bool {
    if (!self.rename_active) return false;
    // Esc/Enter/Tab are handled as keys, not text.
    if (ch == 0x1B or ch == 0x0D or ch == 0x09) return true;
    const alloc = self.app.core_app.alloc;
    // First edit replaces the pre-filled title (select-all behavior).
    if (self.rename_fresh) {
        self.rename_buf.clearRetainingCapacity();
        self.rename_fresh = false;
    }
    if (ch == 0x08) {
        // Backspace: drop one codepoint (both surrogate halves).
        if (self.rename_buf.pop()) |unit| {
            if (unit >= 0xDC00 and unit <= 0xDFFF) _ = self.rename_buf.pop();
        }
    } else if (ch >= 0x20 and ch != 0x7F) {
        self.rename_buf.append(alloc, ch) catch {};
    }
    self.invalidateStrip();
    return true;
}

/// Paste clipboard text into the active rename field.
fn renamePaste(self: *Window) void {
    if (!self.rename_active) return;
    const alloc = self.app.core_app.alloc;
    // First edit replaces the pre-filled title (select-all behavior).
    if (self.rename_fresh) {
        self.rename_buf.clearRetainingCapacity();
        self.rename_fresh = false;
    }
    var buf: [512]u16 = undefined;
    const room = 511 -| self.rename_buf.items.len;
    if (room == 0) return;
    const n = winapi.clipboardTextUtf16(self.hwnd, buf[0..@min(room, buf.len)]);
    if (n == 0) return;
    self.rename_buf.appendSlice(alloc, buf[0..n]) catch {};
    self.invalidateStrip();
}

/// Whether the tab at `idx` should be closed under a CloseTabMode
/// relative to the active/target tab index.
fn tabInCloseMode(mode: apprt.action.CloseTabMode, i: usize, idx: usize) bool {
    return switch (mode) {
        .this => i == idx,
        .other => i != idx,
        .right => i > idx,
    };
}

/// Modal yes/no shown before closing surfaces with a running process
/// (confirm-close-surface). Returns true to proceed.
fn confirmClose(self: *Window) bool {
    return winapi.MessageBoxW(
        self.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "A process is still running. Close anyway?",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        winapi.MB_YESNO | winapi.MB_ICONWARNING | winapi.MB_DEFBUTTON2,
    ) == winapi.IDYES;
}

/// Close tabs relative to the one containing `surface`, per the
/// keybind's CloseTabMode: just this tab, all others, or all to the
/// right. Previously every mode closed only the current tab.
pub fn closeTabs(
    self: *Window,
    mode: apprt.action.CloseTabMode,
    surface: *Surface,
) void {
    const idx = self.tabOf(surface) orelse return;
    self.closeTabsFrom(mode, idx);
}

/// Close tabs relative to tab `idx` per the mode, asking first if any
/// affected surface has a running process (confirm-close-surface). All
/// mouse/menu/keybind tab-close paths funnel through here so they share
/// the confirmation the surface-close keybind already had.
pub fn closeTabsFrom(
    self: *Window,
    mode: apprt.action.CloseTabMode,
    idx: usize,
) void {
    if (idx >= self.tabs.items.len) return;

    var needs = false;
    for (self.tabs.items, 0..) |*tab, i| {
        if (!tabInCloseMode(mode, i, idx)) continue;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core_surface.needsConfirmQuit()) {
                needs = true;
                break;
            }
        }
        if (needs) break;
    }
    if (needs and !self.confirmClose()) return;

    for (self.tabs.items, 0..) |*tab, i| {
        if (!tabInCloseMode(mode, i, idx)) continue;
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.should_close = true;
    }
    self.app.wakeup();
}

/// Flag the whole window for close, asking first if any surface has a
/// running process. Used by the caption ✕, WM_CLOSE / Alt+F4, and the
/// close_window keybind.
pub fn requestCloseWindow(self: *Window) void {
    var needs = false;
    outer: for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core_surface.needsConfirmQuit()) {
                needs = true;
                break :outer;
            }
        }
    }
    if (needs and !self.confirmClose()) return;
    self.should_close = true;
    self.app.wakeup();
}

/// Set or toggle always-on-top (float_window keybind).
pub fn setFloat(self: *Window, mode: apprt.action.FloatWindow) void {
    const exstyle = winapi.GetWindowLongPtrW(self.hwnd, winapi.GWL_EXSTYLE);
    const is_topmost = (exstyle & @as(isize, winapi.WS_EX_TOPMOST)) != 0;
    const want = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !is_topmost,
    };
    _ = winapi.SetWindowPos(
        self.hwnd,
        if (want) winapi.HWND_TOPMOST else winapi.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        winapi.SWP_NOMOVE | winapi.SWP_NOSIZE | winapi.SWP_NOACTIVATE,
    );
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
    self.scrollTabIntoView(new_idx);
    self.layoutActiveTab();
    self.syncTitle();

    self.syncSearchVisibility();

    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// The search bar is pinned to one surface: show it only while that
/// surface is the active one, and hide it otherwise (a different split
/// focused, or a different tab), so it never floats over — and appears
/// to query — an unrelated split/tab.
fn syncSearchVisibility(self: *Window) void {
    const search = self.search orelse return;
    if (self.activeSurface() == search.surface) {
        search.layout();
        _ = winapi.ShowWindow(search.hwnd, winapi.SW_SHOWNA);
    } else {
        _ = winapi.ShowWindow(search.hwnd, winapi.SW_HIDE);
    }
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
    // A search bar bound to the previously focused split must not stay
    // visible over the newly focused one.
    self.syncSearchVisibility();
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

    // Each leaf reserves a slim custom scrollbar column on its right
    // edge (Scrollbar.zig; the thumb is invisible without scrollback).
    const sbw: i32 = self.scale(scrollbar_width_logical);

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
                    sb.hwnd,
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

/// Queue a render on every surface of the active tab. Used after a
/// resize: an idle (unfocused, output-less) surface presents no frame
/// on its own, so newly exposed regions would keep stale pixels.
fn refreshActiveTab(self: *Window) void {
    const tab = self.activeTab() orelse return;
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        entry.view.core_surface.refreshCallback() catch |err| {
            log.err("error refreshing surface after resize err={}", .{err});
        };
    }
}

/// Arm the deferred post-resize repaint. The grid is resized
/// synchronously by layoutActiveTab, but the shell repaints its prompt
/// only after ConPTY reflows, which lands a few frames later; keep
/// refreshing for a short window so that repaint is not missed.
fn scheduleResizeRepaint(self: *Window) void {
    self.resize_repaint_left = resize_repaint_ticks;
    _ = winapi.SetTimer(self.hwnd, resize_repaint_timer_id, 32, null);
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

/// Cap `s` to at most `max` bytes without splitting a UTF-8 sequence.
/// The std UTF conversions do not bounds-check their destination, so
/// every fixed-buffer caller must cap its input first (a UTF-16
/// conversion never needs more units than the UTF-8 byte count).
pub fn utf8Capped(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    // Back off while the first EXCLUDED byte is a UTF-8 continuation
    // byte, i.e. the cut lands inside a multi-byte sequence. Testing
    // s[end-1] (the last included byte) instead would leave a dangling
    // lead byte and make the whole conversion fail. s[max] is in range
    // because s.len > max.
    var end = max;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// Update the OS-level window title (taskbar/alt-tab) from the active
/// tab and repaint the strip.
pub fn syncTitle(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const title = utf8Capped(tab.title(), 511);
    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], title) catch return;
    buf[len] = 0;
    _ = winapi.SetWindowTextW(self.hwnd, buf[0..len :0]);
    self.invalidateStrip();
}

/// Resolve the effective theme (config, falling back to the OS):
/// forward to all tabs and set the DWM caption. Called on OS theme
/// changes and on config reload, since `window-theme` can force either.
pub fn notifyColorScheme(self: *Window) void {
    const light = self.isLight();

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

/// Resolve whether the window chrome should render light, honoring the
/// `window-theme` config: dark/light force the value, auto/system/ghostty
/// defer to the OS app theme. (`ghostty` upstream means "match the
/// terminal background"; the OS theme is a fallback until that's
/// implemented.) Also used by the other chrome windows (palette,
/// search bar, settings) so a forced theme applies consistently.
pub fn isLight(self: *const Window) bool {
    return switch (self.app.config.@"window-theme") {
        .dark => false,
        .light => true,
        .auto, .system, .ghostty => winapi.appsUseLightTheme(),
    };
}

/// The title strip height in physical pixels.
pub fn titlebarHeight(self: *const Window) i32 {
    // Fullscreen hides the strip so the terminal owns the whole monitor.
    if (self.fullscreen) return 0;
    return self.scale(titlebar_height_logical);
}

/// Toggle borderless fullscreen on the window's current monitor.
pub fn toggleFullscreen(self: *Window) void {
    // The quick terminal is a docked, topmost tool window, not a normal
    // top-level window; fullscreen would wreck its dropdown geometry.
    if (self.quick) return;

    if (!self.fullscreen) {
        // Remember exactly where we were so exit restores it.
        self.saved_placement.length = @sizeOf(winapi.WINDOWPLACEMENT);
        _ = winapi.GetWindowPlacement(self.hwnd, &self.saved_placement);
        self.saved_style = winapi.GetWindowLongPtrW(self.hwnd, winapi.GWL_STYLE);

        const mon = winapi.MonitorFromWindow(
            self.hwnd,
            winapi.MONITOR_DEFAULTTONEAREST,
        );
        var mi: winapi.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(winapi.MONITORINFO);
        if (winapi.GetMonitorInfoW(mon, &mi) == 0) return;

        // Strip the caption/border bits and fill the monitor. Setting
        // fullscreen before SetWindowPos makes the relayout it triggers
        // (via titlebarHeight) drop the strip.
        _ = winapi.SetWindowLongPtrW(
            self.hwnd,
            winapi.GWL_STYLE,
            self.saved_style & ~@as(isize, winapi.WS_OVERLAPPEDWINDOW),
        );
        self.fullscreen = true;
        _ = winapi.SetWindowPos(
            self.hwnd,
            null,
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            winapi.SWP_NOZORDER | winapi.SWP_FRAMECHANGED,
        );
    } else {
        self.fullscreen = false;
        _ = winapi.SetWindowLongPtrW(
            self.hwnd,
            winapi.GWL_STYLE,
            self.saved_style,
        );
        _ = winapi.SetWindowPlacement(self.hwnd, &self.saved_placement);
        _ = winapi.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            winapi.SWP_NOMOVE | winapi.SWP_NOSIZE |
                winapi.SWP_NOZORDER | winapi.SWP_FRAMECHANGED,
        );
    }
    self.layoutActiveTab();
}

/// Toggle the maximized/restored state (the toggle_maximize action;
/// mirrors the caption maximize button).
pub fn toggleMaximize(self: *Window) void {
    // Maximize is meaningless for the docked quick terminal, and toggling
    // it while fullscreen would desync the saved placement/style, so
    // ignore it in those modes.
    if (self.quick or self.fullscreen) return;
    self.captionButtonClick(.maximize);
}

/// Invalidate only the strip. Hover changes repaint constantly while
/// the mouse crosses the strip; invalidating the whole window made
/// every one of those also refresh the terminal renderer.
pub fn invalidateStrip(self: *const Window) void {
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

/// Width of one tab, shrinking when they no longer fit. Below a floor
/// the tabs stop shrinking and the strip scrolls instead (tabScroll).
fn tabWidth(self: *const Window) i32 {
    const avail = self.tabsRegionRight() - self.scale(new_tab_width_logical);
    const n: i32 = @intCast(@max(1, self.tabs.items.len));
    return @max(self.scale(60), @min(self.scale(tab_width_logical), @divTrunc(avail, n)));
}

/// Right edge of the region tabs and the new-tab button live in: the
/// client width minus the three caption buttons. Tabs never render
/// past this into the caption buttons.
fn tabsRegionRight(self: *const Window) i32 {
    return self.clientWidth() - 3 * self.scale(caption_button_width_logical);
}

/// Total width of all tabs plus the new-tab button, unscrolled.
fn tabsContentWidth(self: *const Window) i32 {
    const n: i32 = @intCast(self.tabs.items.len);
    return n * self.tabWidth() + self.scale(new_tab_width_logical);
}

/// Maximum horizontal scroll: how far the content overflows the region.
fn maxTabScroll(self: *const Window) i32 {
    return @max(0, self.tabsContentWidth() - self.tabsRegionRight());
}

/// Clamp tab_scroll into range (content shrank, window widened, etc.).
fn clampTabScroll(self: *Window) void {
    self.tab_scroll = std.math.clamp(self.tab_scroll, 0, self.maxTabScroll());
}

fn tabRect(self: *const Window, idx: usize) winapi.RECT {
    const w = self.tabWidth();
    const i: i32 = @intCast(idx);
    return .{
        .left = i * w - self.tab_scroll,
        .top = 0,
        .right = (i + 1) * w - self.tab_scroll,
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
        .left = n * w - self.tab_scroll,
        .top = 0,
        .right = n * w + self.scale(new_tab_width_logical) - self.tab_scroll,
        .bottom = self.titlebarHeight(),
    };
}

/// Adjust tab_scroll so tab `idx` is fully visible in the strip region
/// (called on activation so switching to an off-screen tab reveals it).
fn scrollTabIntoView(self: *Window, idx: usize) void {
    self.clampTabScroll();
    const w = self.tabWidth();
    const i: i32 = @intCast(idx);
    const left = i * w;
    const right = (i + 1) * w;
    const region = self.tabsRegionRight();
    if (left - self.tab_scroll < 0) {
        self.tab_scroll = left;
    } else if (right - self.tab_scroll > region) {
        self.tab_scroll = right - region;
    }
    self.clampTabScroll();
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
        // Tooltip tool rects follow the scrolled tab positions.
        hasher.update(std.mem.asBytes(&self.tab_scroll));
        for (self.tabs.items) |*tab| {
            hasher.update(tab.title());
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
        // Truncate at a codepoint boundary so the UTF-16 buffer below
        // is always large enough.
        const title = utf8Capped(tab.title(), 255);
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

    const light = self.isLight();
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

    // Clip the tabs and new-tab button to the region left of the
    // caption buttons, so an overflowed/scrolled strip can't paint over
    // them. Restored before the caption buttons are drawn.
    self.clampTabScroll();
    const clip_saved = winapi.SaveDC(hdc);
    _ = winapi.IntersectClipRect(hdc, 0, 0, self.tabsRegionRight(), height);

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

        // Tab title (or the editable rename buffer + caret).
        if (text_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, if (active) fg else fg_dim);

            const renaming = self.rename_active and i == self.rename_tab;
            var buf: [512]u16 = undefined;
            var len: usize = 0;
            if (renaming) {
                len = @min(self.rename_buf.items.len, buf.len - 1);
                @memcpy(buf[0..len], self.rename_buf.items[0..len]);
            } else {
                len = std.unicode.utf8ToUtf16Le(
                    buf[0 .. buf.len - 1],
                    utf8Capped(tab.title(), buf.len - 1),
                ) catch 0;
            }
            buf[len] = 0;
            const text_left = rect.left + self.scale(10);
            var text_rect: winapi.RECT = .{
                .left = text_left,
                .top = rect.top,
                .right = self.tabCloseRect(i).left - self.scale(4),
                .bottom = rect.bottom,
            };
            if (len > 0) {
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..len :0],
                    @intCast(len),
                    &text_rect,
                    winapi.DT_LEFT | winapi.DT_VCENTER |
                        winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
            if (renaming) {
                // Draw a caret after the text to signal edit mode.
                var extent: winapi.SIZE = .{ .cx = 0, .cy = 0 };
                if (len > 0) _ = winapi.GetTextExtentPoint32W(hdc, &buf, @intCast(len), &extent);
                const cx = text_left + extent.cx + self.scale(1);
                const mid = @divTrunc(rect.top + rect.bottom, 2);
                var caret: winapi.RECT = .{
                    .left = cx,
                    .top = mid - self.scale(8),
                    .right = cx + self.scale(2),
                    .bottom = mid + self.scale(8),
                };
                if (winapi.CreateSolidBrush(fg)) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &caret, b);
                }
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

    // Drop the tab clip before the caption buttons.
    if (clip_saved != 0) _ = winapi.RestoreDC(hdc, clip_saved);

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
        .close => self.requestCloseWindow(),
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
    // Splits place hosts at arbitrary offsets, so map the host origin
    // back rather than assuming the top-left surface.
    const pos = tab.core_surface.imePoint();
    var origin: winapi.POINT = .{ .x = 0, .y = 0 };
    _ = winapi.ClientToScreen(tab.host, &origin);
    _ = winapi.ScreenToClient(self.hwnd, &origin);
    _ = winapi.ImmSetCompositionWindow(himc, &.{
        .dwStyle = winapi.CFS_POINT,
        .ptCurrentPos = .{
            .x = origin.x + @as(i32, @intFromFloat(@max(0, pos.x))),
            .y = origin.y + @as(i32, @intFromFloat(@max(0, pos.y))),
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
            self.requestCloseWindow();
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
            // by the frame size; inset so the strip stays visible. In
            // fullscreen we fill the monitor deliberately and the strip
            // is hidden, so skip the inset (the window may still carry
            // the maximized flag if fullscreen was entered while zoomed).
            if (!self.fullscreen and winapi.IsZoomed(hwnd) != 0) {
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
            // Skip it in fullscreen: there is no border to grab.
            if (!self.fullscreen and winapi.IsZoomed(hwnd) == 0) {
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
                    // Use the configured terminal background so split
                    // gaps blend in, matching the scrollbar track,
                    // instead of a hardcoded near-black scar on light
                    // or non-black themes.
                    const bg = self.app.config.background;
                    const fill: u32 = @as(u32, bg.b) << 16 |
                        @as(u32, bg.g) << 8 | bg.r;
                    if (winapi.CreateSolidBrush(fill)) |brush| {
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
            if (self.search) |search| search.layout();
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            self.scheduleResizeRepaint();
            return 0;
        },

        // The search bar is a popup in screen coordinates; keep it
        // docked when the window moves.
        winapi.WM_MOVE => {
            if (self.search) |search| search.layout();
            return 0;
        },

        // Deferred tab rename (posted from the context menu).
        winapi.WM_APP_RENAME => {
            self.startRenameTab(@truncate(wparam));
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

            // Quick terminals hide when they lose focus — except to one
            // of their own popups (command palette, search bar,
            // settings, dropdowns), which all trace back to this window
            // through the owner chain. wParam names the window gaining
            // focus.
            if (self.quick and msg == winapi.WM_KILLFOCUS) hide: {
                if (wparam != 0) {
                    const gaining: winapi.HWND = @ptrFromInt(wparam);
                    if (winapi.GetAncestor(gaining, winapi.GA_ROOTOWNER) == hwnd)
                        break :hide;
                }
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
                if (pt.y < self.titlebarHeight()) {
                    // Keep a normal arrow over the strip; otherwise the
                    // terminal's I-beam lingers there.
                    if (winapi.loadSystemCursor(winapi.IDC_ARROW)) |c| {
                        _ = winapi.SetCursor(c);
                        return 1;
                    }
                    break :cursor;
                }

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
            self.scheduleResizeRepaint();
            return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        winapi.WM_TIMER => {
            if (wparam == modal_tick_timer_id) {
                self.app.core_app.tick(self.app) catch |err| {
                    log.err("error ticking app from modal loop err={}", .{err});
                };
                return 0;
            }
            if (wparam == resize_repaint_timer_id) {
                self.refreshActiveTab();
                if (self.resize_repaint_left > 0) self.resize_repaint_left -= 1;
                if (self.resize_repaint_left == 0)
                    _ = winapi.KillTimer(hwnd, resize_repaint_timer_id);
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
            // While renaming a tab, the window captures Enter/Escape.
            if (self.rename_active and msg == winapi.WM_KEYDOWN) {
                switch (@as(u8, @truncate(wparam))) {
                    winapi.VK_RETURN => {
                        self.commitRename(true);
                        return 0;
                    },
                    winapi.VK_ESCAPE => {
                        self.commitRename(false);
                        return 0;
                    },
                    'V' => {
                        if (winapi.GetKeyState(winapi.VK_CONTROL) < 0)
                            self.renamePaste();
                        return 0;
                    },
                    else => return 0,
                }
            }
            self.keyEvent(msg, wparam, lparam);
            if (msg == winapi.WM_SYSKEYDOWN or msg == winapi.WM_SYSKEYUP)
                return winapi.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

        winapi.WM_CHAR => {
            if (self.renameChar(@truncate(wparam))) return 0;
            self.charEvent(@truncate(wparam));
            return 0;
        },

        // Dead keys: keyEvent already reported the composing keydown;
        // the accent codepoint itself must not reach the terminal.
        winapi.WM_DEADCHAR, winapi.WM_SYSDEADCHAR => return 0,

        winapi.WM_MOUSEWHEEL, winapi.WM_MOUSEHWHEEL => {
            // Wheel scrolls the surface under the cursor (lparam here
            // is in screen coordinates).
            var pt: winapi.POINT = .{
                .x = lparamX(lparam),
                .y = lparamY(lparam),
            };
            _ = winapi.ScreenToClient(hwnd, &pt);
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));

            // Wheel over the strip scrolls the tab strip when it
            // overflows (up/left reveals earlier tabs).
            if (pt.y >= 0 and pt.y < self.titlebarHeight() and
                self.maxTabScroll() > 0)
            {
                const step = @divTrunc(self.tabWidth(), 2);
                self.tab_scroll += if (delta > 0) -step else step;
                self.clampTabScroll();
                self.invalidateStrip();
                return 0;
            }

            const surface = self.surfaceAt(pt.x, pt.y) orelse
                self.activeSurface() orelse return 0;
            const ticks: f64 = @as(f64, @floatFromInt(delta)) / 120.0;

            // Ctrl + vertical wheel adjusts the font size, matching
            // Windows Terminal and editors. Ghostty binds zoom to the
            // keyboard by default; this is a win32 convenience.
            if (msg == winapi.WM_MOUSEWHEEL and
                winapi.GetKeyState(winapi.VK_CONTROL) < 0)
            {
                const action: input.Binding.Action = if (ticks > 0)
                    .{ .increase_font_size = 1 }
                else
                    .{ .decrease_font_size = 1 };
                _ = surface.core_surface.performBindingAction(action) catch |err| {
                    log.err("error adjusting font size err={}", .{err});
                };
                return 0;
            }

            // Honor the system per-notch scroll amount instead of a
            // hardcoded 3 (default is 3, so feel is unchanged unless the
            // user customized it).
            const units = wheelScrollUnits(msg == winapi.WM_MOUSEHWHEEL);
            if (msg == winapi.WM_MOUSEHWHEEL) {
                surface.core_surface.scrollCallback(ticks * units, 0, .{}) catch |err| {
                    log.err("error in scroll callback err={}", .{err});
                };
            } else {
                surface.core_surface.scrollCallback(0, ticks * units, .{}) catch |err| {
                    log.err("error in scroll callback err={}", .{err});
                };
            }
            return 0;
        },

        // Mouse back/forward buttons go straight to the surface (never
        // the strip); apps in mouse-reporting mode can act on them.
        winapi.WM_XBUTTONDOWN, winapi.WM_XBUTTONUP => {
            const which = (wparam >> 16) & 0xFFFF;
            const button: input.MouseButton = switch (which) {
                1 => .four,
                2 => .five,
                else => return 1,
            };
            const cy = lparamY(lparam);
            if (cy >= 0 and cy < self.titlebarHeight()) return 1;
            const surface = self.surfaceAt(lparamX(lparam), cy) orelse
                self.activeSurface() orelse return 1;
            const state: input.MouseButtonState =
                if (msg == winapi.WM_XBUTTONDOWN) .press else .release;
            _ = surface.core_surface.mouseButtonCallback(
                state,
                button,
                currentMods(),
            ) catch |err| {
                log.err("error in mouse button callback err={}", .{err});
            };
            return 1;
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
                // Don't treat a press as a drag until the pointer has
                // moved past the system drag threshold; otherwise a
                // click with a small slip reorders or tears off.
                if (!self.tab_drag_engaged) {
                    const dpi = winapi.GetDpiForWindow(self.hwnd);
                    const cx = winapi.GetSystemMetricsForDpi(winapi.SM_CXDRAG, dpi);
                    const cy2 = winapi.GetSystemMetricsForDpi(winapi.SM_CYDRAG, dpi);
                    if (@abs(@as(i32, x) - self.tab_drag_origin.x) < cx and
                        @abs(@as(i32, y) - self.tab_drag_origin.y) < cy2)
                        return 0;
                    self.tab_drag_engaged = true;
                }
                const n = self.tabs.items.len;
                const target: usize = @intCast(std.math.clamp(
                    @divTrunc(@as(i32, x) + self.tab_scroll, @max(1, self.tabWidth())),
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

        // Capture was taken from us (e.g. a modal dialog opening
        // mid-drag). Abandon any in-progress drag so its handle/index
        // into now-possibly-stale state is dropped; the release that
        // would normally end it will land elsewhere.
        winapi.WM_CAPTURECHANGED => {
            self.tab_drag = null;
            self.tab_drag_engaged = false;
            self.divider_drag = null;
            return 0;
        },

        winapi.WM_LBUTTONDOWN,
        winapi.WM_LBUTTONUP,
        winapi.WM_RBUTTONDOWN,
        winapi.WM_RBUTTONUP,
        winapi.WM_MBUTTONDOWN,
        winapi.WM_MBUTTONUP,
        => {
            // A click anywhere commits an in-progress tab rename.
            if (self.rename_active and (msg == winapi.WM_LBUTTONDOWN or
                msg == winapi.WM_RBUTTONDOWN or msg == winapi.WM_MBUTTONDOWN))
            {
                self.commitRename(true);
            }

            // Button presses dismiss any showing tab tooltip.
            self.relayToTooltip(msg, wparam, lparam);

            // A tab drag in progress ends on release. Dropping outside
            // the strip tears the tab off into its own window (like
            // other terminals); dropping within it just commits the
            // reorder already applied live by WM_MOUSEMOVE.
            if (self.tab_drag) |idx| {
                if (msg == winapi.WM_LBUTTONUP) {
                    const engaged = self.tab_drag_engaged;
                    self.tab_drag = null;
                    self.tab_drag_engaged = false;
                    _ = winapi.ReleaseCapture();
                    // Only tear off if a real drag happened; a plain
                    // click that never crossed the threshold just
                    // released capture above.
                    if (engaged) {
                        const ux = lparamX(lparam);
                        const uy = lparamY(lparam);
                        const outside = uy < 0 or uy >= self.titlebarHeight() or
                            ux < 0 or ux >= self.clientWidth();
                        if (outside) self.tearOffTab(idx) catch |err| {
                            log.err("error tearing off tab err={}", .{err});
                        };
                    }
                    return 0;
                }
            }

            // A divider drag ends on release wherever the pointer is —
            // including over the strip, which must not swallow it.
            if (self.divider_drag != null and msg == winapi.WM_LBUTTONUP) {
                self.divider_drag = null;
                _ = winapi.ReleaseCapture();
                // Final exact layout for whatever the throttle skipped.
                self.layoutActiveTab();
                return 0;
            }

            // A release that still holds our capture pairs with an
            // earlier surface press (the tab and divider drags returned
            // above and dropped their capture): route it to the terminal
            // even over the strip, so a selection drag ending there
            // doesn't operate strip buttons or leak the capture. Capture
            // is OS state, so it can't drift the way a manual counter
            // would if a release were ever lost.
            const surface_release = switch (msg) {
                winapi.WM_LBUTTONUP,
                winapi.WM_RBUTTONUP,
                winapi.WM_MBUTTONUP,
                => winapi.GetCapture() == hwnd,
                else => false,
            };

            // Clicks in the strip operate tabs/buttons, never the
            // terminal.
            const cy = lparamY(lparam);
            if (!surface_release and cy >= 0 and cy < self.titlebarHeight()) {
                // Tabs activate on press, like native tab strips, and
                // the press begins a possible drag-reorder.
                if (msg == winapi.WM_LBUTTONDOWN) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .tab => |i| {
                            self.activateTab(i);
                            self.tab_drag = i;
                            self.tab_drag_origin = .{ .x = lparamX(lparam), .y = cy };
                            self.tab_drag_engaged = false;
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
                        .tab_close => |i| self.closeTabsFrom(.this, i),
                        .new_tab => _ = self.newTab() catch |err| {
                            log.err("error creating tab err={}", .{err});
                        },
                    }
                }
                // Right-click a tab for its context menu (Rename / Close).
                if (msg == winapi.WM_RBUTTONUP) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .tab => |i| self.showStripMenu(i),
                        // Right-click on the empty strip or the new-tab
                        // button shows the general menu.
                        .none, .new_tab => self.showStripMenu(null),
                        else => {},
                    }
                }
                // Middle-click a tab closes it (closes every split in it).
                if (msg == winapi.WM_MBUTTONUP) {
                    switch (self.hitTestStrip(lparamX(lparam), cy)) {
                        .tab => |i| self.closeTabsFrom(.this, i),
                        else => {},
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

    // AltGr discrimination. On layouts with AltGr, Windows injects a
    // left-ctrl keydown immediately before right-alt's keydown, sharing
    // its message timestamp -- that pairing is the discriminator (the
    // same technique Chromium uses). Swallow the injected ctrl events
    // and strip ctrl+alt from mods while AltGr is held, so text-less
    // AltGr chords don't trigger ctrl+alt keybinds or report dirty
    // modifiers under the kitty keyboard protocol.
    const extended = (lparam & (1 << 24)) != 0;
    if (vk == winapi.VK_CONTROL and !extended) {
        if (!released) {
            if (self.altGrInjectedCtrl()) {
                self.altgr_down = true;
                return;
            }
            // An autorepeat of the injected ctrl can arrive without its
            // paired right-alt repeat already queued; it is still not a
            // genuine ctrl press.
            if (self.altgr_down and was_down) return;
            self.altgr_down = false;
        } else if (self.altgr_down) {
            // The paired injected release right before right-alt's up.
            return;
        }
    }
    if (vk == winapi.VK_MENU and extended and released)
        self.altgr_down = false;

    var mods = currentMods();
    if (self.altgr_down) {
        mods.ctrl = false;
        mods.alt = false;
    }

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

    // A dead key: TranslateMessage queued WM_DEADCHAR, not WM_CHAR.
    // Report the keydown as composing -- the core then suppresses
    // encoding the raw key (the kitty protocol would otherwise leak a
    // spurious key event to TUIs) -- and clear any stash so the
    // eventually composed WM_CHAR completes the *next* keydown, not
    // this one. The WM_DEADCHAR itself is consumed in the wndproc.
    if ((action == .press or action == .repeat) and self.deadCharQueued()) {
        var composing = key_event;
        composing.composing = true;
        _ = tab.core_surface.keyCallback(composing) catch |err| {
            log.err("error in key callback err={}", .{err});
        };
        self.pending_key_event = null;
        return;
    }

    // TranslateMessage has already queued the layout-cooked WM_CHAR(s)
    // for character-producing keys behind this keydown. When that text is
    // printable, defer to charEvent so the core sees a single event WITH
    // text (and with Shift/AltGr marked consumed). Encoding the text-less
    // keydown here would, under the Kitty keyboard protocol, emit a CSI-u
    // "shift+key" sequence and consume the keydown -- swallowing the
    // WM_CHAR -- so shifted text (capitals, symbols) never reaches apps
    // that enable the protocol (e.g. the Copilot TUI). Control chars
    // (ctrl+key) are left to the encoder via the unshifted codepoint, so
    // we only defer when a printable char is waiting.
    if ((action == .press or action == .repeat) and
        vk != winapi.VK_PROCESSKEY and
        self.printableCharQueued())
    {
        self.pending_key_event = key_event;
        return;
    }

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

/// Whether the WM_KEYDOWN being handled is the left-ctrl press Windows
/// injects for AltGr: the next queued key message is right-alt's
/// keydown carrying the same timestamp. A genuine ctrl press has no
/// such paired message.
fn altGrInjectedCtrl(self: *Window) bool {
    var msg: winapi.MSG = undefined;
    if (winapi.PeekMessageW(
        &msg,
        self.hwnd,
        winapi.WM_KEYFIRST,
        winapi.WM_KEYLAST,
        winapi.PM_NOREMOVE,
    ) == 0) return false;
    if (msg.message != winapi.WM_KEYDOWN and
        msg.message != winapi.WM_SYSKEYDOWN) return false;
    if (@as(u8, @truncate(msg.wParam)) != winapi.VK_MENU) return false;
    if ((msg.lParam & (1 << 24)) == 0) return false;
    return msg.time == @as(u32, @bitCast(winapi.GetMessageTime()));
}

/// Whether a dead-key WM_DEADCHAR is queued behind the keydown we're
/// handling (TranslateMessage posts it before this dispatch).
fn deadCharQueued(self: *Window) bool {
    var msg: winapi.MSG = undefined;
    if (winapi.PeekMessageW(
        &msg,
        self.hwnd,
        winapi.WM_DEADCHAR,
        winapi.WM_DEADCHAR,
        winapi.PM_NOREMOVE,
    ) != 0) return true;
    return winapi.PeekMessageW(
        &msg,
        self.hwnd,
        winapi.WM_SYSDEADCHAR,
        winapi.WM_SYSDEADCHAR,
        winapi.PM_NOREMOVE,
    ) != 0;
}

/// Whether a printable WM_CHAR is sitting in the queue directly behind
/// the keydown we're handling (TranslateMessage posts it before this
/// dispatch). A UTF-16 surrogate lead counts as printable; control chars
/// (< 0x20 and DEL) do not, so ctrl-combinations keep encoding from the
/// keydown rather than deferring to text.
fn printableCharQueued(self: *Window) bool {
    var msg: winapi.MSG = undefined;
    if (winapi.PeekMessageW(
        &msg,
        self.hwnd,
        winapi.WM_CHAR,
        winapi.WM_CHAR,
        winapi.PM_NOREMOVE,
    ) == 0) return false;
    const unit: u16 = @truncate(msg.wParam);
    return unit >= 0x20 and unit != 0x7F;
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

    // Record that Shift was folded into the produced text when it
    // actually changed the character (';' -> ':', 'a' -> 'A'). The core
    // negates consumed_mods to get the effective mods; without this the
    // Kitty keyboard protocol still sees Shift pressed, skips the
    // plain-text fast path, and encodes a CSI-u "shift+key" sequence
    // instead of the literal character. Apps that enable the protocol
    // (modern vim/neovim, the Copilot TUI) then never see the capital or
    // symbol. Legacy mode is unaffected, which is why the bare shell is
    // fine. consumed_mods is meaningless when utf8 is empty, so we only
    // set it here where we have text.
    if (key_event.mods.shift and codepoint != key_event.unshifted_codepoint) {
        key_event.consumed_mods.shift = true;
    }

    // AltGr. Windows synthesizes left-ctrl + right-alt for it, but when the
    // layout turns that chord into literal text (AltGr+e -> €, AltGr+q -> @
    // on German, etc.) neither modifier is semantically active. Clear them
    // so the encoder emits the text instead of a ctrl/alt sequence: the
    // legacy ctrlSeq/CSI-u paths read the raw mods (key_encode.zig ctrlSeq
    // uses all_mods, and the CSI-u block tests event.mods.ctrl), so unlike
    // Shift above marking them consumed would not be enough. A real
    // ctrl+alt chord essentially never produces a printable character (it
    // yields a control code or nothing), so requiring printable text
    // avoids false positives.
    if (codepoint >= 0x20 and key_event.mods.ctrl and key_event.mods.alt) {
        key_event.mods.ctrl = false;
        key_event.mods.alt = false;
    }

    if (key_event.unshifted_codepoint == 0 and
        codepoint < 0x80 and !key_event.mods.shift)
    {
        key_event.unshifted_codepoint = codepoint;
    }

    _ = tab.core_surface.keyCallback(key_event) catch |err| {
        log.err("error in key callback err={}", .{err});
    };
}

/// The system "lines/characters per wheel notch" setting, as a scroll
/// multiplier applied to wheel ticks. Defaults to 3 (the Windows
/// default), so behavior is unchanged unless the user customized it.
/// A page-scroll setting falls back to a larger fixed step.
fn wheelScrollUnits(horizontal: bool) f64 {
    const param: winapi.UINT = if (horizontal)
        winapi.SPI_GETWHEELSCROLLCHARS
    else
        winapi.SPI_GETWHEELSCROLLLINES;
    var value: winapi.UINT = 3;
    _ = winapi.SystemParametersInfoW(param, 0, &value, 0);
    if (value == winapi.WHEEL_PAGESCROLL) return 20;
    return @floatFromInt(value);
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
        winapi.VK_OEM_102 => .intl_backslash,
        else => .unidentified,
    };
}
