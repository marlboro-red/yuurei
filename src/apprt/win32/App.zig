/// Win32 apprt App: window class registration, the message loop, and
/// core-app action dispatch. Modeled on the deleted GLFW apprt's App
/// (fb9c52ecf~1), the historical minimal runtime.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const font = @import("../../font/main.zig");
const Pty = @import("../../pty.zig").Pty;
const perf = @import("../../perf.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const CommandPalette = @import("CommandPalette.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const ProfileMenu = @import("ProfileMenu.zig");
const profiles = @import("profiles.zig");
const session = @import("session.zig");
const defterm = @import("defterm.zig");
const Scrollbar = @import("Scrollbar.zig");
const SearchBar = @import("SearchBar.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// The App receiving default-terminal handoffs. defterm's COM callback
/// is context-free (a bare fn pointer), so it finds the app here. Set
/// in init; there is only ever one App per process.
var handoff_app: ?*App = null;

/// The core app instance we're connected to.
core_app: *CoreApp,

/// Loaded configuration; surfaces snapshot from this at creation.
config: Config,

/// Module handle, used as the window class's hInstance.
hinstance: winapi.HINSTANCE,

/// The main (message loop) thread id, the wakeup target.
thread_id: winapi.DWORD,

/// All open windows (tab containers).
windows: std.ArrayList(*Window) = .empty,

/// The quick terminal window, if it has been summoned. It may be
/// hidden; toggling shows/hides it.
quick: ?*Window = null,

/// The settings window, if open. Only one at a time; open_config
/// focuses the existing one rather than spawning another.
settings: ?*SettingsWindow = null,

/// Actions for registered global hotkeys, indexed by hotkey id - 1.
/// The inner slices are owned (duped from the config at registration,
/// freed at unregistration).
hotkey_actions: std.ArrayList([]const input.Binding.Action) = .empty,

/// Hidden window owning the tray notify icon used for desktop
/// notifications (balloon tips render as toasts on Win 10/11). Created
/// lazily on the first notification.
tray_hwnd: ?winapi.HWND = null,

/// Whether flip-model presentation is available (the WGL DX-interop
/// extension exists), probed once at startup with a throwaway
/// context. GL host windows are created with
/// WS_EX_NOREDIRECTIONBITMAP only when this is true AND the config
/// enables windows-flip-model — the style is creation-only and would
/// break the (default) SwapBuffers path, so it must match the present
/// path decided before the renderer ever runs.
flip_capable: bool = false,

/// Whether the mouse cursor is currently hidden (mouse-hide-while-typing).
/// ShowCursor keeps a process-global counter, so this must be tracked
/// app-wide, not per-window, to avoid unbalanced hide/show calls.
cursor_hidden: bool = false,

/// Discovered shell profiles (profiles.zig), scanned lazily on first
/// dropdown open (the WSL probe spawns a process) and invalidated on
/// config reload so new overlay files appear without a restart.
profiles_list: ?profiles.List = null,

/// Deadline (std.time.milliTimestamp) for quitting after the last
/// window closed, when quit-after-last-window-closed-delay is set.
/// Null while windows exist or when no linger is in progress.
quit_deadline_ms: ?i64 = null,

/// Thread timer (SetTimer with a null hwnd) that wakes the run loop
/// so the quit deadline is noticed; 0 when not armed.
quit_timer_id: usize = 0,

/// The shell taskbar-list object for OSC 9;4 progress, created lazily
/// on the first progress report. null until then (or if COM/creation
/// failed).
taskbar: ?*winapi.ITaskbarList3 = null,

/// Whether our CoInitializeEx succeeded (S_OK/S_FALSE); only then may
/// terminate() call CoUninitialize (a failed init must not be balanced).
com_initialized: bool = false,

/// Flips to true to quit on the next event loop tick.
quit: bool = false,

/// Whether we've already attempted session restore. Restore fires on the
/// launch window, but `windows.len == 0` is also true during the
/// quit-after-last-window-closed linger, so without this a `global:`
/// new_window during the linger would re-open the entire session.
session_restored: bool = false,

/// Default-terminal handoffs received from the COM server but not yet
/// turned into windows. EstablishPtyHandoff enqueues here and returns
/// S_OK *immediately* — it must not build a window inline, because
/// conhost blocks inside that COM call and can't service the console
/// client (cmd) until it returns; a slow inline window+GL init stalls
/// the client's console init past its timeout (STATUS_DLL_INIT_FAILED /
/// 0xc0000142). The run loop drains this on its next iteration, after
/// S_OK has already reached conhost. Guarded by a mutex only in case a
/// future COM config delivers the call off the UI thread.
pending_handoffs: std.ArrayList(defterm.Handoff) = .empty,
handoff_mutex: std.Io.Mutex = .init,

/// Startup prewarm (see prewarmThreadMain): a background thread that
/// pre-loads the first window's font grid and pages in the ConPTY
/// stack while the UI thread does window + WGL init. The font ref is
/// held for the app's lifetime (released in terminate) so the grid
/// stays cached across window closes too.
prewarm_thread: ?std.Thread = null,
prewarm_font: ?PrewarmFont = null,

/// URLs waiting to be opened after the core action callback releases
/// renderer state locks.
pending_urls: std.ArrayList([]u8) = .empty,
url_mutex: std.Io.Mutex = .init,

const PrewarmFont = struct {
    config: font.SharedGridSet.DerivedConfig,
    size: font.face.DesiredSize,
    /// Set by the prewarm thread on success; read only after join.
    key: ?font.SharedGridSet.Key = null,
};

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but unused here.
    opts: struct {},
) !void {
    _ = opts;

    perf.mark("app-init-begin");

    const module = winapi.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;
    const hinstance: winapi.HINSTANCE = @ptrCast(module);

    // Initialize COM (STA) for the shell taskbar-progress interface.
    // S_OK and S_FALSE (already initialized) both require a matching
    // CoUninitialize; a failure such as RPC_E_CHANGED_MODE must NOT be
    // balanced, so only uninit if this succeeded.
    const com_initialized = winapi.CoInitializeEx(
        null,
        winapi.COINIT_APARTMENTTHREADED,
    ) >= 0;

    // Registers the common-control classes (tooltips for the strip).
    winapi.InitCommonControls();

    // The icon embedded by dist/windows/ghostty.rc (alt-tab, taskbar,
    // and the tray notify icon).
    const app_icon = winapi.LoadIconW(hinstance, @ptrFromInt(1));

    // One window class for all top-level windows.
    const class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW,
        .lpfnWndProc = Window.wndProc,
        .hInstance = hinstance,
        // Null background brush: the strip is painted on WM_PAINT and
        // the GL hosts cover the rest (WM_ERASEBKGND returns 1).
        .hbrBackground = null,
        .lpszClassName = Window.class_name,
        .hIcon = app_icon,
        .hIconSm = app_icon,
    };
    if (winapi.RegisterClassExW(&class) == 0) return error.RegisterClassFailed;

    // The GL host child class (see Surface.host_class_name).
    const host_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_OWNDC,
        .lpfnWndProc = Surface.hostWndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = Surface.host_class_name,
    };
    if (winapi.RegisterClassExW(&host_class) == 0) return error.RegisterClassFailed;

    // The command palette popup class.
    const palette_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW | winapi.CS_DROPSHADOW,
        .lpfnWndProc = CommandPalette.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = CommandPalette.class_name,
    };
    if (winapi.RegisterClassExW(&palette_class) == 0) return error.RegisterClassFailed;

    // The profile dropdown popup class.
    const profile_menu_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW | winapi.CS_DROPSHADOW,
        .lpfnWndProc = ProfileMenu.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = ProfileMenu.class_name,
    };
    if (winapi.RegisterClassExW(&profile_menu_class) == 0) return error.RegisterClassFailed;

    // The inspector window class (CS_OWNDC for its WGL context).
    const inspector_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_OWNDC,
        .lpfnWndProc = InspectorWindow.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = InspectorWindow.class_name,
    };
    if (winapi.RegisterClassExW(&inspector_class) == 0) return error.RegisterClassFailed;

    // The custom scrollbar class.
    const scroll_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW,
        .lpfnWndProc = Scrollbar.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = Scrollbar.class_name,
    };
    if (winapi.RegisterClassExW(&scroll_class) == 0) return error.RegisterClassFailed;

    // The search bar popup class.
    const search_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW | winapi.CS_DROPSHADOW,
        .lpfnWndProc = SearchBar.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = SearchBar.class_name,
    };
    if (winapi.RegisterClassExW(&search_class) == 0) return error.RegisterClassFailed;

    // The settings window class (a plain dialog hosting Win32 controls).
    const settings_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW,
        .lpfnWndProc = SettingsWindow.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = SettingsWindow.class_name,
    };
    if (winapi.RegisterClassExW(&settings_class) == 0) return error.RegisterClassFailed;

    // The settings window's dropdown-list popup class.
    const dropdown_class: winapi.WNDCLASSEXW = .{
        .style = winapi.CS_HREDRAW | winapi.CS_VREDRAW | winapi.CS_DROPSHADOW,
        .lpfnWndProc = SettingsWindow.DropdownPopup.wndProc,
        .hInstance = hinstance,
        .hbrBackground = null,
        .lpszClassName = SettingsWindow.DropdownPopup.class_name,
    };
    if (winapi.RegisterClassExW(&dropdown_class) == 0) return error.RegisterClassFailed;

    // Load our configuration
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    // Whether COM cold-started us as a local server: when yuurei is the
    // default terminal and no instance is running, conhost activates our
    // LocalServer32 command, which COM invokes with a trailing
    // `-Embedding`. Such an instance must NOT treat that unrecognized arg
    // as a fatal CLI error (below) nor open a shell window (further down):
    // it exists only to register the handoff class object and receive the
    // console session conhost marshals in. Gated on handoff_ready — while
    // the server is off, register() refuses, so COM never launches us this
    // way and `-Embedding` should behave like any other bad arg.
    const embedding = defterm.handoff_ready and launchedForEmbedding(core_app.alloc);

    // If we had configuration errors, then log them.
    if (!config._diagnostics.empty()) {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (config._diagnostics.items()) |diag| {
            writer.end = 0;
            diag.format(&writer) catch continue;
            log.warn("configuration error: {s}", .{writer.buffered()});
        }

        // If we have any CLI errors, exit — unless we were COM-launched,
        // where the only such "error" is -Embedding and quitting would
        // kill every cold-start console handoff.
        if (config._diagnostics.containsLocation(.cli) and !embedding) {
            log.warn("CLI errors detected, exiting", .{});
            _ = core_app.mailbox.push(global.io(), .{ .quit = {} }, .{ .forever = {} });
        }
    }

    // Probe flip-model capability only when the config opts in. The
    // probe spins up a throwaway WGL context (tens of ms on some
    // drivers), and the default SwapBuffers path never needs it, so the
    // common launch shouldn't pay for it. Consequence: enabling
    // windows-flip-model at runtime needs a restart to take effect
    // (the config doc already notes it only affects new terminals).
    const flip_capable = config.@"windows-flip-model" and
        global.environ().getWindows(
            std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_NO_FLIP"),
        ) == null and
        probeFlipCapable(hinstance);
    log.info("flip-model capable={}", .{flip_capable});

    // Queue a single new window that starts on launch (this also drives
    // session restore). Note: above we may send a quit so this may never
    // happen. A COM-launched (-Embedding) instance skips it entirely — it
    // opens a window only when conhost hands off a session, and must not
    // restore the user's whole session onto a bare console launch.
    if (!embedding) {
        _ = core_app.mailbox.push(global.io(), .{ .new_window = .{} }, .{ .forever = {} });
    }

    // Font-grid prewarm state, built on this thread (a cheap arena
    // clone) so the background thread never touches the live config.
    // The DPI is a guess (system DPI, matching a first window on the
    // primary monitor); a miss just skips the cache, costing nothing.
    const prewarm_font: ?PrewarmFont = pf: {
        const scale: f32 =
            @as(f32, @floatFromInt(winapi.GetDpiForSystem())) / 96.0;
        const dpi: f32 = scale * font.face.default_dpi;
        const font_config = font.SharedGridSet.DerivedConfig.init(
            core_app.alloc,
            &config,
        ) catch |err| {
            log.warn("font prewarm config failed err={}", .{err});
            break :pf null;
        };
        break :pf .{
            .config = font_config,
            .size = .{
                .points = config.@"font-size",
                .xdpi = @intFromFloat(dpi),
                .ydpi = @intFromFloat(dpi),
            },
        };
    };

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .thread_id = std.os.windows.GetCurrentThreadId(),
        .flip_capable = flip_capable,
        .com_initialized = com_initialized,
        .prewarm_font = prewarm_font,
    };
    handoff_app = self;

    // `self` is stable from here (there is one App per process, in
    // caller-owned memory), so the prewarm thread can hold it.
    self.prewarm_thread = std.Thread.spawn(
        .{},
        prewarmThreadMain,
        .{self},
    ) catch |err| thr: {
        log.warn("prewarm thread spawn failed err={}", .{err});
        break :thr null;
    };

    // Make sure the loop processes the queued message immediately.
    self.wakeup();

    // Register `global:` keybinds as system-wide hotkeys.
    self.registerGlobalHotkeys();

    // Default-terminal handoff: register the COM class object on this
    // (STA) thread so conhost can hand off console sessions to us. The
    // handoff callback runs on this message loop. No-op unless the
    // handoff server is enabled (defterm.handoff_ready).
    defterm.on_handoff = onHandoff;
    defterm.startServer();
}

/// Whether COM invoked our LocalServer32 command (it appends
/// `-Embedding`). Matches WT's cold-start detection; see the use in init.
fn launchedForEmbedding(alloc: std.mem.Allocator) bool {
    var it = std.process.Args.Iterator.initAllocator(global.args(), alloc) catch return false;
    defer it.deinit();
    _ = it.next(); // skip argv[0]
    while (it.next()) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "-Embedding") or
            std.ascii.eqlIgnoreCase(arg, "/Embedding")) return true;
    }
    return false;
}

/// Receive a default-terminal handoff (defterm.zig). Called from inside
/// EstablishPtyHandoff, which conhost blocks on — so this only *enqueues*
/// the handoff and returns; the run loop builds the window later, after
/// S_OK has reached conhost. Building a window inline would keep conhost
/// blocked long enough for the console client's init to time out
/// (0xc0000142). See App.pending_handoffs. Returns whether we took
/// ownership; on false, establishPtyHandoff closes the handoff and
/// declines to conhost (we must NOT close it here — no double-free).
fn onHandoff(h: defterm.Handoff) bool {
    const app = handoff_app orelse return false;
    app.handoff_mutex.lockUncancelable(global.io());
    app.pending_handoffs.append(app.core_app.alloc, h) catch {
        app.handoff_mutex.unlock(global.io());
        return false;
    };
    app.handoff_mutex.unlock(global.io());

    // Wake the run loop so it drains the queue promptly. If the call
    // arrived on the UI thread (the STA case) the loop is currently
    // blocked inside this COM call and will see the queue as soon as it
    // unwinds; the posted WM_NULL guarantees GetMessageW returns then.
    app.wakeup();
    return true;
}

/// Turn any queued handoffs into windows, in arrival order. Runs on the
/// UI thread from the run loop, after EstablishPtyHandoff has returned
/// S_OK to conhost.
fn drainHandoffs(self: *App) void {
    while (true) {
        self.handoff_mutex.lockUncancelable(global.io());
        if (self.pending_handoffs.items.len == 0) {
            self.handoff_mutex.unlock(global.io());
            return;
        }
        const h = self.pending_handoffs.orderedRemove(0);
        self.handoff_mutex.unlock(global.io());
        self.receiveHandoff(h) catch |err| {
            log.err("handoff surface creation failed err={}", .{err});
        };
    }
}

/// Max URL byte length accepted by queueUrl. drainUrls sizes its UTF-16
/// buffer to match: UTF-16 never needs more code units than UTF-8 bytes,
/// so the byte-length check at queue time guarantees the conversion fits.
const max_url_bytes = 2047;

fn queueUrl(self: *App, url: []const u8) !void {
    const alloc = self.core_app.alloc;
    const owned = try alloc.dupe(u8, url);
    errdefer alloc.free(owned);

    {
        self.url_mutex.lockUncancelable(global.io());
        defer self.url_mutex.unlock(global.io());
        try self.pending_urls.append(alloc, owned);
    }
    self.wakeup();
}

fn drainUrls(self: *App) void {
    const alloc = self.core_app.alloc;

    // Take the whole batch under one lock, then launch unlocked:
    // ShellExecuteW can pump messages back into us, so no lock may be
    // held across it (that deferral is the entire point; see queueUrl).
    self.url_mutex.lockUncancelable(global.io());
    var urls = self.pending_urls;
    self.pending_urls = .empty;
    self.url_mutex.unlock(global.io());
    defer urls.deinit(alloc);

    for (urls.items) |url| {
        defer alloc.free(url);

        var url_w: [max_url_bytes:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&url_w, url) catch {
            log.warn("invalid utf-8 in url, not opening", .{});
            continue;
        };
        url_w[len] = 0;
        _ = winapi.ShellExecuteW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("open"),
            url_w[0..len :0],
            null,
            null,
            winapi.SW_SHOWDEFAULT,
        );
    }
}

/// Decline a handoff by releasing everything it carried (pipes, client,
/// and the adopted HPCON). Used when no app can receive it or window setup
/// fails before a surface takes ownership.
const closeHandoff = defterm.closeHandoff;

/// Background startup prewarm: two independent one-time costs that
/// otherwise serialize inside the first surface's init.
///
///  - The font grid (~100ms cold: DirectWrite discovery + face
///    loading), overlapped here with window creation + WGL driver
///    init. The SharedGridSet lock makes the race with the first
///    surface benign: whoever arrives first builds the grid, the
///    other blocks briefly and then cache-hits. A wrong DPI guess
///    (first window on a non-primary-DPI monitor) just misses the
///    cache and pays the normal serial cost; the unused grid is
///    released in terminate.
///
///  - A throwaway ConPTY (~35ms cold vs ~4ms warm): creating and
///    closing one pages in conpty.dll, OpenConsole.exe, and console
///    driver state so the first surface's IO thread finds them warm.
///    Font first: it is the larger win and the surface's font-grid
///    ref happens well before its IO thread opens the real pty.
fn prewarmThreadMain(self: *App) void {
    if (self.prewarm_font) |*pf| {
        if (self.core_app.font_grid_set.ref(&pf.config, pf.size)) |r| {
            pf.key = r[0];
            perf.mark("prewarm-font-done");
        } else |err| {
            log.warn("font prewarm failed err={}", .{err});
        }
    }

    var pty = Pty.open(.{
        .ws_row = 4,
        .ws_col = 4,
        .ws_xpixel = 8,
        .ws_ypixel = 8,
    }) catch |err| {
        log.warn("conpty prewarm failed err={}", .{err});
        return;
    };
    pty.deinit();
    perf.mark("prewarm-conpty-done");
}

pub fn terminate(self: *App) void {
    // Prewarm teardown before anything it touches: join the thread,
    // then release the font-grid ref it may hold. (The grid set lives
    // on the core app and its deref takes the set's own lock, so this
    // is safe alongside surface teardown below.)
    if (self.prewarm_thread) |t| {
        t.join();
        self.prewarm_thread = null;
    }
    if (self.prewarm_font) |*pf| {
        if (pf.key) |key| self.core_app.font_grid_set.deref(key);
        pf.config.deinit();
        self.prewarm_font = null;
    }

    // Stop accepting default-terminal handoffs FIRST — revoke the COM
    // class object and detach the hooks — and only then release anything
    // still queued. The reverse order would leave a window where a newly
    // delivered handoff appends to a list we're about to free. (With the
    // current STA delivery this can't preempt us mid-terminate; the order
    // matters if delivery ever moves off the UI thread.)
    defterm.stopServer();
    defterm.on_handoff = null;
    handoff_app = null;
    for (self.pending_handoffs.items) |h| closeHandoff(h);
    self.pending_handoffs.deinit(self.core_app.alloc);
    // URLs queued in the final tick are dropped unopened: quitting wins
    // over a click still in flight.
    for (self.pending_urls.items) |url| self.core_app.alloc.free(url);
    self.pending_urls.deinit(self.core_app.alloc);

    if (self.tray_hwnd) |hwnd| {
        var nid: winapi.NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = 1 };
        _ = winapi.Shell_NotifyIconW(winapi.NIM_DELETE, &nid);
        _ = winapi.DestroyWindow(hwnd);
    }
    if (self.taskbar) |tb| _ = tb.vtable.Release(tb);
    self.unregisterGlobalHotkeys();
    self.hotkey_actions.deinit(self.core_app.alloc);
    while (self.windows.pop()) |window| window.destroy();
    self.windows.deinit(self.core_app.alloc);
    if (self.profiles_list) |*l| l.deinit();
    self.config.deinit();
    if (self.com_initialized) winapi.CoUninitialize();
}

/// Adopt a default-terminal handoff into a new surface: open a normal
/// top-level window whose one surface drives conhost's ConPTY (via the
/// SpawnOpts.handoff staged for takeHandoff) instead of spawning a shell.
/// The window looks and behaves like any other terminal window.
///
/// Ownership: until `newTabWithOpts` moves the handoff into a surface, we
/// own the handles and close them on early failure; afterwards the
/// surface owns them and frees them in its own deinit path.
fn receiveHandoff(self: *App, h: defterm.Handoff) !void {
    const alloc = self.core_app.alloc;

    const window = Window.create(alloc, self, .{ .no_initial_tab = true }) catch |err| {
        closeHandoff(h);
        return err;
    };
    errdefer window.destroy();

    self.windows.append(alloc, window) catch |err| {
        closeHandoff(h);
        return err;
    };
    errdefer _ = self.windows.pop();

    // DPI-scale the default size before the surface spawns so its pty
    // starts at the final grid.
    window.applyDefaultSize();

    // (ConptyReparentPseudoConsole was tried here to unlock resize; it
    // rejects a packed HPCON with E_HANDLE just like ResizePseudoConsole,
    // so it's not wired in. See defterm.reparent / pty.setSize.)

    // Moves the handoff into the new surface, which owns the handles from
    // here: its init/deinit path releases them on any later failure.
    const surface = try window.newTabWithOpts(.{ .handoff = h });

    // Title from conhost's startup info, if any.
    if (h.title_len > 0) set_title: {
        const t = h.title_buf[0..h.title_len];
        var buf: [512]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&buf, t) catch break :set_title;
        const z = alloc.dupeZ(u8, buf[0..n]) catch break :set_title;
        defer alloc.free(z);
        surface.setTitle(z) catch {};
    }

    window.applyStartupShow();
    _ = winapi.SetForegroundWindow(window.hwnd);
}

/// The profile list, scanned on first use. See profiles.zig.
pub fn ensureProfiles(self: *App) *const profiles.List {
    if (self.profiles_list == null)
        self.profiles_list = profiles.scan(self.core_app.alloc);
    return &self.profiles_list.?;
}

/// Build the effective configuration for a spawn override (profile
/// and/or working directory): the standard load pipeline (defaults,
/// config files, CLI args) with the overrides laid on top before
/// finalize, so they behave exactly like extra lines at the end of
/// the user's config. Everything goes through the parse machinery
/// (never direct field assignment): finalize's theme handling replays
/// the recorded config inputs over a fresh config, and only parsed
/// inputs are recorded. Caller owns the result (deinit after the
/// surface snapshot).
pub fn spawnConfig(
    self: *App,
    opts: Window.SpawnOpts,
) !Config {
    const alloc_gpa = self.core_app.alloc;
    var cfg = try Config.default(alloc_gpa);
    errdefer cfg.deinit();
    try cfg.loadDefaultFiles(alloc_gpa);
    try cfg.loadCliArgs(alloc_gpa);

    if (opts.profile) |profile| switch (profile.source) {
        .file => |path| try cfg.loadFile(alloc_gpa, path),
        .builtin => |cmdline| {
            var buf: [512]u8 = undefined;
            const arg = try std.fmt.bufPrint(&buf, "--command={s}", .{cmdline});
            var iter = @import("../../cli.zig").args.sliceIterator(&.{arg});
            try cfg.loadIter(alloc_gpa, &iter);
        },
    };

    if (opts.cwd) |cwd| {
        var buf: [1024]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buf, "--working-directory={s}", .{cwd});
        var iter = @import("../../cli.zig").args.sliceIterator(&.{arg});
        try cfg.loadIter(alloc_gpa, &iter);
    }

    try cfg.loadRecursiveFiles(alloc_gpa);
    try cfg.finalize();
    return cfg;
}

/// Register every `global:`-flagged keybind as a Win32 system hotkey.
/// Called at startup and again after config reloads.
fn registerGlobalHotkeys(self: *App) void {
    self.unregisterGlobalHotkeys();

    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |leaf| leaf.generic(),
        };
        if (!leaf.flags.global) continue;

        const vk = triggerToVk(entry.key_ptr.*) orelse {
            log.warn(
                "global keybind cannot map to a Win32 hotkey, ignoring trigger={any}",
                .{entry.key_ptr.*},
            );
            continue;
        };

        const mods = entry.key_ptr.mods;
        var win_mods: winapi.UINT = winapi.MOD_NOREPEAT;
        if (mods.ctrl) win_mods |= winapi.MOD_CONTROL;
        if (mods.alt) win_mods |= winapi.MOD_ALT;
        if (mods.shift) win_mods |= winapi.MOD_SHIFT;
        if (mods.super) win_mods |= winapi.MOD_WIN;

        const actions = self.core_app.alloc.dupe(
            input.Binding.Action,
            leaf.actionsSlice(),
        ) catch continue;
        self.hotkey_actions.append(self.core_app.alloc, actions) catch {
            self.core_app.alloc.free(actions);
            continue;
        };
        const id: i32 = @intCast(self.hotkey_actions.items.len);
        if (winapi.RegisterHotKey(null, id, win_mods, vk) == 0) {
            log.warn("RegisterHotKey failed (in use by another app?) trigger={any}", .{
                entry.key_ptr.*,
            });
            if (self.hotkey_actions.pop()) |slice| self.core_app.alloc.free(slice);
        } else {
            log.info("registered global hotkey id={} trigger={any}", .{
                id,
                entry.key_ptr.*,
            });
        }
    }
}

fn unregisterGlobalHotkeys(self: *App) void {
    var id: i32 = @intCast(self.hotkey_actions.items.len);
    while (id > 0) : (id -= 1) _ = winapi.UnregisterHotKey(null, id);
    while (self.hotkey_actions.pop()) |slice| self.core_app.alloc.free(slice);
}

/// Map a keybind trigger to a Win32 virtual key for RegisterHotKey.
fn triggerToVk(trigger: input.Binding.Trigger) ?winapi.UINT {
    return switch (trigger.key) {
        .catch_all => null,
        .unicode => |cp| switch (cp) {
            'a'...'z' => @as(winapi.UINT, cp - 'a' + 'A'),
            '0'...'9' => @as(winapi.UINT, cp),
            '`' => 0xC0, // VK_OEM_3
            ' ' => 0x20,
            else => null,
        },
        .physical => |k| switch (k) {
            .backquote => 0xC0,
            .space => 0x20,
            .escape => 0x1B,
            inline else => |key_tag| vk: {
                const name = @tagName(key_tag);
                if (name.len == 5 and std.mem.startsWith(u8, name, "key_"))
                    break :vk @as(winapi.UINT, std.ascii.toUpper(name[4]));
                if (name.len == 7 and std.mem.startsWith(u8, name, "digit_"))
                    break :vk @as(winapi.UINT, name[6]);
                if (name.len >= 2 and name[0] == 'f' and std.ascii.isDigit(name[1])) {
                    const n = std.fmt.parseInt(u8, name[1..], 10) catch break :vk null;
                    if (n >= 1 and n <= 24) break :vk winapi.VK_F1 + n - 1;
                }
                break :vk null;
            },
        },
    };
}

/// Dispatch a WM_HOTKEY by id: app-scoped actions go through the core;
/// anything else is ignored with a log (most surface-scoped actions
/// make no sense without focus).
fn handleHotkey(self: *App, id: usize) void {
    if (id == 0 or id > self.hotkey_actions.items.len) return;
    for (self.hotkey_actions.items[id - 1]) |action| {
        const scoped = action.scoped(.app) orelse {
            log.info(
                "global hotkey action is not app-scoped, ignoring action={any}",
                .{action},
            );
            continue;
        };
        self.core_app.performAction(self, scoped) catch |err| {
            log.err("error performing global hotkey action err={}", .{err});
        };
    }
}

/// Show, focus, or hide the quick terminal.
fn toggleQuickTerminal(self: *App) !void {
    if (self.quick) |quick| {
        // Window may have been closed via its tab/close button and
        // destroyed by the run loop sweep; treat a stale pointer as
        // gone by checking our list.
        for (self.windows.items) |w| {
            if (w == quick) {
                if (winapi.IsWindowVisible(quick.hwnd) != 0) {
                    _ = winapi.ShowWindow(quick.hwnd, winapi.SW_HIDE);
                    quick.setOccluded(true);
                } else {
                    _ = winapi.ShowWindow(quick.hwnd, winapi.SW_SHOW);
                    _ = winapi.SetForegroundWindow(quick.hwnd);
                    quick.setOccluded(false);
                }
                return;
            }
        }
        self.quick = null;
    }

    const window = try Window.create(self.core_app.alloc, self, .{ .quick = true });
    errdefer window.destroy();
    try self.windows.append(self.core_app.alloc, window);
    self.quick = window;
    _ = winapi.SetForegroundWindow(window.hwnd);
}

/// Run the event loop. This doesn't return until the app exits.
pub fn run(self: *App) !void {
    while (true) {
        // Block until at least one message arrives. wakeup() posts a
        // WM_NULL thread message so cross-thread ticks land here too.
        var msg: winapi.MSG = undefined;
        const result = winapi.GetMessageW(&msg, null, 0, 0);
        if (result == -1) return error.GetMessageFailed;
        if (result == 0) self.quit = true else if (msg.message == winapi.WM_HOTKEY) {
            // Hotkeys registered with a null hwnd arrive as thread
            // messages; DispatchMessage would drop them.
            self.handleHotkey(msg.wParam);
        } else {
            _ = winapi.TranslateMessage(&msg);
            _ = winapi.DispatchMessageW(&msg);
        }

        // Drain whatever else is queued before ticking so one tick
        // covers a burst of input.
        while (winapi.PeekMessageW(&msg, null, 0, 0, winapi.PM_REMOVE) != 0) {
            if (msg.message == winapi.WM_QUIT) {
                self.quit = true;
                continue;
            }
            if (msg.message == winapi.WM_HOTKEY) {
                self.handleHotkey(msg.wParam);
                continue;
            }
            _ = winapi.TranslateMessage(&msg);
            _ = winapi.DispatchMessageW(&msg);
        }

        // Build windows for any handoffs the COM server queued. Done
        // here (not inline in EstablishPtyHandoff) so that call returns
        // to conhost immediately; see App.pending_handoffs.
        self.drainHandoffs();

        self.drainUrls();

        // Tick the terminal app
        try self.core_app.tick(self);

        // Close anything flagged. This is done here, not in the window
        // procedure, so memory isn't freed while one of its own
        // messages is still on the stack.
        var wi: usize = 0;
        while (wi < self.windows.items.len) {
            const window = self.windows.items[wi];

            // A window-level close closes every surface in it.
            if (window.should_close) {
                for (window.tabs.items) |*tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| entry.view.should_close = true;
                }
            }

            // Remove flagged surfaces one at a time: each removal
            // rebuilds its tab's tree (and may drop the tab), so we
            // re-scan from the top after every removal.
            sweep: while (true) {
                const flagged: ?*Surface = flagged: {
                    for (window.tabs.items) |*tab| {
                        var it = tab.tree.iterator();
                        while (it.next()) |entry| {
                            if (entry.view.should_close) break :flagged entry.view;
                        }
                    }
                    break :flagged null;
                };
                window.removeSurface(flagged orelse break :sweep);
            }

            if (window.tabs.items.len == 0) {
                if (self.quick == window) self.quick = null;
                window.destroy();
                _ = self.windows.orderedRemove(wi);
            } else wi += 1;
        }

        // A hidden quick terminal must not keep the app alive as an
        // invisible zombie: when it's all that remains, close it too.
        if (self.windows.items.len > 0) only_quick: {
            for (self.windows.items) |window| {
                if (!window.quick) break :only_quick;
                if (winapi.IsWindowVisible(window.hwnd) != 0) break :only_quick;
            }
            for (self.windows.items) |window| window.should_close = true;
            // Post a wakeup so the next loop iteration's GetMessageW
            // returns and the sweep above actually runs; otherwise the
            // hidden window lingers until some unrelated message.
            self.wakeup();
            continue;
        }

        // If the tick caused us to quit, then we're done. Snapshot the
        // session first, while every window is still alive.
        if (self.quit) {
            session.save(self);
            while (self.windows.pop()) |window| window.destroy();
            return;
        }

        if (self.windows.items.len == 0) {
            // Honor quit-after-last-window-closed-delay: linger with
            // the message loop alive (a `global:` hotkey can still
            // summon the quick terminal) until the deadline passes.
            // Flag off or no delay set quits immediately, as before.
            const delay_ns: u64 = delay: {
                if (!self.config.@"quit-after-last-window-closed")
                    break :delay 0;
                const d = self.config.@"quit-after-last-window-closed-delay" orelse
                    break :delay 0;
                break :delay d.duration;
            };
            if (delay_ns == 0) return;

            const delay_ms: i64 = @intCast(@max(1, delay_ns / std.time.ns_per_ms));
            const now = std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
            if (self.quit_deadline_ms) |deadline| {
                if (now >= deadline) return;
            } else {
                self.quit_deadline_ms = now + delay_ms;
                // A thread timer wakes GetMessageW so the deadline is
                // noticed even with no other message traffic. Its
                // WM_TIMER (null hwnd, no callback) is dropped by
                // DispatchMessage; only the wakeup matters. A margin
                // past the deadline keeps the first firing from
                // landing a hair early and doubling the linger.
                // Clamp to the UINT the API takes: a multi-week configured
                // delay would otherwise overflow the @intCast. Windows
                // caps at USER_TIMER_MAXIMUM (~24.8 days) anyway.
                const timer_ms: u32 = ms: {
                    const m = @max(1, delay_ns / std.time.ns_per_ms) + 100;
                    break :ms @intCast(@min(m, std.math.maxInt(u32)));
                };
                self.quit_timer_id = winapi.SetTimer(
                    null,
                    0,
                    timer_ms,
                    null,
                );
            }
        } else if (self.quit_deadline_ms != null) {
            // A window appeared during the linger: cancel the pending
            // quit.
            self.quit_deadline_ms = null;
            if (self.quit_timer_id != 0) {
                _ = winapi.KillTimer(null, self.quit_timer_id);
                self.quit_timer_id = 0;
            }
        }
    }
}

/// Wakeup the event loop. Callable from any thread.
pub fn wakeup(self: *const App) void {
    if (winapi.PostThreadMessageW(self.thread_id, winapi.WM_NULL, 0, 0) == 0) {
        // Benign: the queue can be full, in which case a tick is
        // already guaranteed to happen.
        log.debug("PostThreadMessageW for wakeup failed", .{});
    }
}

/// Perform a given action. Returns `true` if the action was able to be
/// performed, `false` otherwise.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            if (!self.confirmQuit()) return true;
            self.quit = true;
            self.wakeup();
        },

        .new_window => {
            const parent: ?*CoreSurface = switch (target) {
                .app => null,
                .surface => |v| v,
            };
            // The launch window: restore the previous session when
            // configured; fall through to the default on any failure.
            // Attempted at most once (see session_restored) so a
            // new_window during the quit linger doesn't re-restore.
            if (parent == null and !self.session_restored and self.windows.items.len == 0) {
                self.session_restored = true;
                if (session.restore(self) != null) return true;
            }
            _ = try self.newSurface(parent);
        },

        .new_tab => switch (target) {
            // No focused surface: a tab in no window is a window.
            .app => _ = try self.newSurface(null),
            .surface => |parent| {
                const surface = try parent.rt_surface.window.newTab();
                if (self.config.@"window-inherit-font-size") {
                    surface.core_surface.setFontSize(parent.font_size) catch |err| {
                        log.warn("error inheriting font size err={}", .{err});
                    };
                }
            },
        },

        .goto_tab => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.gotoTab(value),
        },

        .close_tab => switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.window.closeTabs(value, surface.rt_surface);
            },
        },

        // Command palette "Change Tab Title" / the prompt-title
        // keybinds. Whether the prompt asks for the surface or tab
        // title, it's the same thing here: the tab label is the only
        // user-editable title in the win32 chrome.
        .prompt_title => switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.window.promptTitle(surface.rt_surface);
            },
        },

        // The `set_tab_title:...` keybind: set the custom tab label
        // directly (empty clears back to the shell-reported title).
        .set_tab_title => switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.window.setTabTitle(
                    surface.rt_surface,
                    value.title,
                );
            },
        },

        // Command palette "Copy Terminal Title to Clipboard".
        .copy_title_to_clipboard => switch (target) {
            .app => return false,
            .surface => |surface| {
                const title = surface.rt_surface.title_text orelse return false;
                try surface.rt_surface.setClipboard(
                    .standard,
                    &.{.{ .mime = "text/plain", .data = title }},
                    false,
                );
            },
        },

        .close_all_windows => {
            if (!self.confirmQuit()) return true;
            for (self.windows.items) |window| window.should_close = true;
            self.wakeup();
        },

        .goto_window => switch (target) {
            .app => return false,
            .surface => |surface| self.gotoWindow(value, surface.rt_surface.window),
        },

        .present_terminal => switch (target) {
            .app => return false,
            .surface => |surface| {
                const hwnd = surface.rt_surface.window.hwnd;
                if (winapi.IsIconic(hwnd) != 0)
                    _ = winapi.ShowWindow(hwnd, winapi.SW_RESTORE);
                _ = winapi.SetForegroundWindow(hwnd);
            },
        },

        .toggle_visibility => switch (target) {
            .app => return false,
            .surface => |surface| {
                const hwnd = surface.rt_surface.window.hwnd;
                _ = winapi.ShowWindow(hwnd, if (winapi.IsIconic(hwnd) != 0)
                    winapi.SW_RESTORE
                else
                    winapi.SW_MINIMIZE);
            },
        },

        .float_window => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.setFloat(value),
        },

        .mouse_visibility => switch (target) {
            .app => return false,
            .surface => {
                const hide = value == .hidden;
                if (hide and !self.cursor_hidden) {
                    _ = winapi.ShowCursor(winapi.FALSE);
                    self.cursor_hidden = true;
                } else if (!hide and self.cursor_hidden) {
                    _ = winapi.ShowCursor(winapi.TRUE);
                    self.cursor_hidden = false;
                }
            },
        },

        .new_split => switch (target) {
            .app => return false,
            .surface => |parent| {
                const surface = try parent.rt_surface.window.newSplit(value);
                if (self.config.@"window-inherit-font-size") {
                    surface.core_surface.setFontSize(parent.font_size) catch |err| {
                        log.warn("error inheriting font size err={}", .{err});
                    };
                }
            },
        },

        .goto_split => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.gotoSplit(value),
        },

        .resize_split => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.resizeSplit(value),
        },

        .equalize_splits => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.equalizeSplits(),
        },

        .toggle_split_zoom => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.toggleSplitZoom(),
        },

        .close_window => switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.window.requestCloseWindow();
            },
        },

        .set_title => switch (target) {
            .app => return false,
            .surface => |surface| try surface.rt_surface.setTitle(value.title),
        },

        .mouse_shape => switch (target) {
            .app => return false,
            .surface => |surface| try surface.rt_surface.setMouseShape(value),
        },

        .initial_size => switch (target) {
            .app => return false,
            .surface => |surface| try surface.rt_surface.setInitialWindowSize(
                value.width,
                value.height,
            ),
        },

        .reload_config => try self.reloadConfig(target, value),

        .toggle_quick_terminal => try self.toggleQuickTerminal(),

        .toggle_command_palette => switch (target) {
            .app => return false,
            .surface => |surface| try surface.rt_surface.window.togglePalette(),
        },

        .toggle_background_opacity => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.toggleOpacity(),
        },

        // We only do borderless fullscreen on Windows; the Fullscreen
        // mode value (native vs. macOS variants) doesn't apply here.
        .toggle_fullscreen => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.toggleFullscreen(),
        },

        .toggle_maximize => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.toggleMaximize(),
        },

        .move_tab => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.window.moveTab(
                value.amount,
            ),
        },

        .scrollbar => switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface.updateScrollbar(value),
        },

        // Search lifecycle: the core drives these; the bar UI follows.
        .start_search => switch (target) {
            .app => return false,
            .surface => |surface| {
                const rt_surface = surface.rt_surface;
                const window = rt_surface.window;
                // Reuse the bar only if it's already bound to THIS
                // surface; a bar left open on another split/tab would
                // otherwise update the wrong surface. Rebind by tearing
                // it down and opening a fresh one.
                if (window.search) |search| {
                    if (search.surface != rt_surface) search.destroy();
                }
                if (window.search) |search| {
                    if (value.needle.len > 0) search.setNeedle(value.needle);
                    search.focus();
                } else {
                    window.search = try SearchBar.create(
                        self.core_app.alloc,
                        rt_surface,
                    );
                    if (value.needle.len > 0) window.search.?.setNeedle(value.needle);
                }
            },
        },

        .end_search => switch (target) {
            .app => return false,
            .surface => |surface| {
                if (surface.rt_surface.window.search) |search| {
                    // Only the bound surface may close its bar.
                    if (search.surface == surface.rt_surface) search.destroy();
                }
            },
        },

        .search_total => switch (target) {
            .app => return false,
            .surface => |surface| {
                if (surface.rt_surface.window.search) |search| {
                    // Ignore counts from a surface the bar isn't bound to.
                    if (search.surface == surface.rt_surface)
                        search.setTotal(value.total);
                }
            },
        },

        .search_selected => switch (target) {
            .app => return false,
            .surface => |surface| {
                if (surface.rt_surface.window.search) |search| {
                    if (search.surface == surface.rt_surface)
                        search.setSelected(value.selected);
                }
            },
        },

        // Open a clicked/OSC8 link in the default handler. Schemes are
        // allowlisted: ShellExecuteW on an arbitrary string (a path,
        // file://...exe) would execute it, and terminal output is
        // untrusted.
        .open_url => {
            const url = value.url;
            const allowed = std.ascii.startsWithIgnoreCase(url, "http://") or
                std.ascii.startsWithIgnoreCase(url, "https://") or
                std.ascii.startsWithIgnoreCase(url, "mailto:");
            if (!allowed) {
                log.warn("refusing to open url with unsupported scheme", .{});
                return false;
            }

            if (url.len > max_url_bytes) {
                log.warn("url too long, not opening", .{});
                return false;
            }
            if (!std.unicode.utf8ValidateSlice(url)) {
                log.warn("invalid utf-8 in url, not opening", .{});
                return false;
            }
            try self.queueUrl(url);
        },

        .inspector => switch (target) {
            .app => return false,
            .surface => |surface| {
                const rt_surface = surface.rt_surface;
                switch (value) {
                    .toggle => if (rt_surface.inspector) |inspector| {
                        inspector.destroy();
                    } else {
                        rt_surface.inspector = try InspectorWindow.create(
                            self.core_app.alloc,
                            rt_surface,
                        );
                    },
                    .show => if (rt_surface.inspector == null) {
                        rt_surface.inspector = try InspectorWindow.create(
                            self.core_app.alloc,
                            rt_surface,
                        );
                    },
                    .hide => if (rt_surface.inspector) |inspector| {
                        inspector.destroy();
                    },
                }
            },
        },

        // The inspector has new data; repaint it on the next tick.
        .render_inspector => switch (target) {
            .app => return false,
            .surface => |surface| if (surface.rt_surface.inspector) |inspector| {
                _ = winapi.InvalidateRect(inspector.hwnd, null, winapi.FALSE);
            },
        },

        // Open the native settings window (yuurei): a GUI over the
        // most-changed options, with an "Open config file" button for
        // the raw-file escape hatch. Only one at a time.
        .open_config => {
            if (self.settings) |s| {
                _ = winapi.SetForegroundWindow(s.hwnd);
            } else if (self.activeWindow()) |window| {
                self.settings = SettingsWindow.create(self.core_app.alloc, window) catch |err| {
                    log.warn("failed to open settings window err={}", .{err});
                    return false;
                };
            } else return false;
        },

        .ring_bell => switch (target) {
            .app => return false,
            .surface => |surface| {
                const features = self.config.@"bell-features";
                const hwnd = surface.rt_surface.window.hwnd;
                const foreground = winapi.GetForegroundWindow() == hwnd;
                // System audio bell only when configured (Ghostty's
                // default has no audio bell).
                if (features.system) _ = winapi.MessageBeep(0);
                // Taskbar attention only when configured AND the window
                // is in the background — flashing your own focused
                // window's taskbar button is pure noise.
                if (features.attention and !foreground) winapi.flashWindow(hwnd);
            },
        },

        // A tray balloon tip, which Windows 10/11 renders as a toast.
        // (Full WinRT toasts need an AUMID-registered shortcut or
        // package identity; the balloon path needs neither.)
        .desktop_notification => {
            self.notifyToast(value.title, value.body);

            // Also flash the source window so the taskbar points at
            // the right terminal.
            switch (target) {
                .app => {},
                .surface => |surface| winapi.flashWindow(
                    surface.rt_surface.window.hwnd,
                ),
            }
        },

        // OSC 9;4 progress → the taskbar button (winget, Write-Progress,
        // installers). Best-effort: if the taskbar object is unavailable
        // we still accept the action rather than log every update.
        .progress_report => switch (target) {
            .app => return false,
            .surface => |surface| {
                const window = surface.rt_surface.window;
                // Honor progress-style (progress can be disabled), and
                // ignore reports from a surface that isn't the window's
                // active one, so a background split/tab can't clobber
                // the single taskbar button's progress.
                if (self.config.@"progress-style" and
                    window.activeSurface() == surface.rt_surface)
                {
                    if (self.taskbarList()) |tb| {
                        const flag: winapi.DWORD = switch (value.state) {
                            .remove => winapi.TBPF_NOPROGRESS,
                            .set => winapi.TBPF_NORMAL,
                            .@"error" => winapi.TBPF_ERROR,
                            .indeterminate => winapi.TBPF_INDETERMINATE,
                            .pause => winapi.TBPF_PAUSED,
                        };
                        _ = tb.vtable.SetProgressState(tb, window.hwnd, flag);
                        if (value.progress) |p|
                            _ = tb.vtable.SetProgressValue(tb, window.hwnd, @min(p, 100), 100);
                    }
                }
            },
        },

        // The pwd is tracked by the core (terminal.getPwd, used for
        // working-directory inheritance); the apprt has nothing to do
        // with the notification, so accept it silently rather than log
        // "unimplemented" on every prompt.
        .pwd => {},

        // High-frequency notifications with no win32 UI (yet): hovering
        // a link fires mouse_over_link on every mouse move across it,
        // selection_changed on every drag tick, and color_change per
        // OSC 4/10/11. Logging "unimplemented" for each floods stderr;
        // decline them quietly instead.
        .mouse_over_link, .selection_changed, .color_change => return false,

        // The quit-after-last-window-closed linger is driven by the run
        // loop's window count (see run()); the core's start/stop signal
        // carries no extra information for us, so accept it silently.
        .quit_timer => {},

        // Everything else is honestly unimplemented for the skeleton:
        // report "not performed" so the core can fall back or ignore.
        else => {
            log.info("unimplemented action={s}", .{@tagName(action)});
            return false;
        },
    }

    return true;
}

/// Whether the WGL DX-interop extension is available, probed with a
/// throwaway hidden window and GL context. Drivers expose the same
/// extension set process-wide, so one probe decides for all surfaces.
/// Ask once (parented to the active window) if any surface across all
/// windows has a running process. Returns true to proceed with a
/// quit / close-all, false if the user cancelled.
fn confirmQuit(self: *App) bool {
    var needs = false;
    outer: for (self.windows.items) |window| {
        for (window.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.core_surface.needsConfirmQuit()) {
                    needs = true;
                    break :outer;
                }
            }
        }
    }
    if (!needs) return true;
    const parent: ?winapi.HWND = if (self.activeWindow()) |w| w.hwnd else null;
    return winapi.MessageBoxW(
        parent,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Processes are still running. Quit anyway?",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        winapi.MB_YESNO | winapi.MB_ICONWARNING | winapi.MB_DEFBUTTON2,
    ) == winapi.IDYES;
}

/// The shell taskbar-list object, created and HrInit'd on first use.
/// null if COM creation or init fails (progress is then a no-op).
fn taskbarList(self: *App) ?*winapi.ITaskbarList3 {
    if (self.taskbar) |tb| return tb;
    var ptr: ?*anyopaque = null;
    if (winapi.CoCreateInstance(
        &winapi.CLSID_TaskbarList,
        null,
        winapi.CLSCTX_INPROC_SERVER,
        &winapi.IID_ITaskbarList3,
        &ptr,
    ) < 0) return null;
    const tb: *winapi.ITaskbarList3 = @ptrCast(@alignCast(ptr orelse return null));
    if (tb.vtable.HrInit(tb) < 0) {
        _ = tb.vtable.Release(tb);
        return null;
    }
    self.taskbar = tb;
    return tb;
}

/// Cycle foreground focus to the previous/next top-level window.
fn gotoWindow(self: *App, mode: apprt.action.GotoWindow, current: *Window) void {
    const n = self.windows.items.len;
    if (n < 2) return;
    var idx: usize = 0;
    for (self.windows.items, 0..) |w, i| {
        if (w == current) idx = i;
    }
    const target = switch (mode) {
        .next => (idx + 1) % n,
        .previous => (idx + n - 1) % n,
    };
    const w = self.windows.items[target];
    if (winapi.IsIconic(w.hwnd) != 0) _ = winapi.ShowWindow(w.hwnd, winapi.SW_RESTORE);
    _ = winapi.SetForegroundWindow(w.hwnd);
}

fn probeFlipCapable(hinstance: winapi.HINSTANCE) bool {
    const hwnd = winapi.CreateWindowExW(
        0,
        Surface.host_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0,
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance,
        null,
    ) orelse return false;
    defer _ = winapi.DestroyWindow(hwnd);

    const hdc = winapi.GetDC(hwnd) orelse return false;
    defer _ = winapi.ReleaseDC(hwnd, hdc);

    const pfd: winapi.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = winapi.PFD_DRAW_TO_WINDOW |
            winapi.PFD_SUPPORT_OPENGL |
            winapi.PFD_DOUBLEBUFFER,
        .iPixelType = winapi.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
    };
    const format = winapi.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return false;
    if (winapi.SetPixelFormat(hdc, format, &pfd) == 0) return false;

    const ctx = winapi.wglCreateContext(hdc) orelse return false;
    defer _ = winapi.wglDeleteContext(ctx);
    if (winapi.wglMakeCurrent(hdc, ctx) == 0) return false;
    defer _ = winapi.wglMakeCurrent(null, null);

    // Cheap fast-fail: without the interop extension nothing below can
    // work.
    const proc = winapi.wglGetProcAddress("wglDXOpenDeviceNV") orelse return false;
    const v = @intFromPtr(proc);
    if (v <= 3 or v == @as(usize, @bitCast(@as(isize, -1)))) return false;

    // Exercise the FULL presenter pipeline once — D3D11 device, DXGI
    // composition swapchain, frame-latency waitable, DComp device/
    // target/visual, and the interop device open. The extension
    // resolving is NOT sufficient: on remote sessions, older drivers,
    // or VMs any of those creations can fail, and flip-enabled hosts
    // are created with WS_EX_NOREDIRECTIONBITMAP — a style under which
    // the SwapBuffers fallback presents into a redirection surface that
    // doesn't exist, i.e. a permanently blank window. Probing the whole
    // pipeline here means flip_capable=false on such machines and the
    // hosts keep a working SwapBuffers path. (Residual risk: the GL
    // renderbuffer registration happens per-surface at renderer init
    // and is not probed; its failure after all of this is rare.)
    var presenter = Surface.dxgi.Presenter.init(hwnd, 1, 1) catch |err| {
        log.info("flip probe: presenter pipeline unavailable err={}", .{err});
        return false;
    };
    presenter.deinit();
    return true;
}

/// Show a desktop notification as a tray balloon tip, which Windows
/// 10/11 renders as a toast. The notify icon (and its hidden owner
/// window) is created lazily and lives until terminate so repeated
/// notifications reuse it.
fn notifyToast(self: *App, title: []const u8, body: []const u8) void {
    log.debug("toast notification title={s} body={s}", .{ title, body });
    const hwnd = self.tray_hwnd orelse hwnd: {
        // The icon needs an owning window for shell callbacks; a
        // hidden top-level window of the standard class works (no
        // GWLP_USERDATA, so its wndproc falls through to default).
        const hwnd = winapi.CreateWindowExW(
            0,
            Window.class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Notifications"),
            0,
            0,
            0,
            0,
            0,
            null,
            null,
            self.hinstance,
            null,
        ) orelse return;

        var nid: winapi.NOTIFYICONDATAW = .{
            .hWnd = hwnd,
            .uID = 1,
            .uFlags = winapi.NIF_ICON | winapi.NIF_TIP,
            // Our embedded icon, falling back to the stock app icon.
            .hIcon = winapi.LoadIconW(self.hinstance, @ptrFromInt(1)) orelse
                winapi.LoadIconW(
                    null,
                    @ptrFromInt(@as(usize, winapi.IDI_APPLICATION)),
                ),
        };
        const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
        @memcpy(nid.szTip[0..tip.len], tip);
        if (winapi.Shell_NotifyIconW(winapi.NIM_ADD, &nid) == 0) {
            log.warn("tray icon add failed; notification dropped", .{});
            _ = winapi.DestroyWindow(hwnd);
            return;
        }
        self.tray_hwnd = hwnd;
        break :hwnd hwnd;
    };

    var nid: winapi.NOTIFYICONDATAW = .{
        .hWnd = hwnd,
        .uID = 1,
        .uFlags = winapi.NIF_INFO,
        .dwInfoFlags = winapi.NIIF_INFO,
    };
    _ = std.unicode.utf8ToUtf16Le(
        nid.szInfoTitle[0 .. nid.szInfoTitle.len - 1],
        truncateUtf8(title, nid.szInfoTitle.len - 1),
    ) catch 0;
    _ = std.unicode.utf8ToUtf16Le(
        nid.szInfo[0 .. nid.szInfo.len - 1],
        truncateUtf8(body, nid.szInfo.len - 1),
    ) catch 0;
    if (winapi.Shell_NotifyIconW(winapi.NIM_MODIFY, &nid) == 0) {
        log.warn("balloon notification failed", .{});
    }
}

/// Truncate UTF-8 to at most max bytes at a codepoint boundary. UTF-16
/// never needs more units than the UTF-8 byte count, so the result is
/// guaranteed to fit a max-unit UTF-16 buffer.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// Reload the configuration; see the GLFW reference implementation.
/// The window to anchor app-targeted UI (e.g. the settings window) to:
/// the foreground window if it's one of ours, else the most recent.
fn activeWindow(self: *App) ?*Window {
    const fg = winapi.GetForegroundWindow();
    for (self.windows.items) |w| {
        if (fg == w.hwnd) return w;
    }
    return if (self.windows.items.len > 0)
        self.windows.items[self.windows.items.len - 1]
    else
        null;
}

fn reloadConfig(
    self: *App,
    target: apprt.action.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    if (opts.soft) {
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core_surface| try core_surface.updateConfig(
                &self.config,
            ),
        }
        return;
    }

    // Load our configuration
    var config = try Config.load(self.core_app.alloc);
    errdefer config.deinit();

    // Call into our app to update
    switch (target) {
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core_surface| try core_surface.updateConfig(&config),
    }

    // Update the existing config, be sure to clean up the old one.
    self.config.deinit();
    self.config = config;

    // Profile overlay files may have changed; rescan on next use. An
    // open dropdown holds pointers into the old list's arena, so close
    // it first. An open command palette is the same class of hazard:
    // its match rows are indices into the combined command+profile
    // namespace of the OLD config/list — after the swap those indices
    // can point past either collection (out-of-bounds paint) or land
    // on a different row (executing the wrong entry).
    for (self.windows.items) |window| {
        if (window.profile_menu) |menu| menu.destroy();
        if (window.palette) |palette| palette.destroy();
    }
    if (self.profiles_list) |*l| {
        l.deinit();
        self.profiles_list = null;
    }

    // Window-level transparency/blur are applied by the apprt (not the
    // renderer), so re-apply them here for background-opacity /
    // background-blur changes to take effect live. Likewise the theme:
    // window-theme can force light/dark, so the DWM caption, strip
    // colors, and surface color scheme must be re-resolved.
    for (self.windows.items) |window| {
        window.reapplyTransparency();
        window.notifyColorScheme();
        window.refreshChrome();
    }

    // Global hotkeys may have changed.
    self.registerGlobalHotkeys();
}

fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
    const window = try Window.create(self.core_app.alloc, self, .{});
    errdefer window.destroy();
    try self.windows.append(self.core_app.alloc, window);

    const surface = window.activeSurface().?;

    // If we have a parent, inherit some properties
    if (self.config.@"window-inherit-font-size") {
        if (parent_) |parent| {
            surface.core_surface.setFontSize(parent.font_size) catch |err| {
                log.warn("error inheriting font size err={}", .{err});
            };
        }
    }

    return surface;
}

/// Send the given IPC to a running Ghostty. There is no IPC mechanism
/// for the win32 apprt yet, so this reports "not performed".
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}
