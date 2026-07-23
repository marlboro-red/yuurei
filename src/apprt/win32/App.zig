/// Win32 apprt App: window class registration, the message loop, and
/// core-app action dispatch. Modeled on the deleted GLFW apprt's App
/// (fb9c52ecf~1), the historical minimal runtime.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
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

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but unused here.
    opts: struct {},
) !void {
    _ = opts;

    const module = std.os.windows.kernel32.GetModuleHandleW(null) orelse
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

    // If we had configuration errors, then log them.
    if (!config._diagnostics.empty()) {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (config._diagnostics.items()) |diag| {
            writer.end = 0;
            diag.format(&writer) catch continue;
            log.warn("configuration error: {s}", .{writer.buffered()});
        }

        // If we have any CLI errors, exit.
        if (config._diagnostics.containsLocation(.cli)) {
            log.warn("CLI errors detected, exiting", .{});
            _ = core_app.mailbox.push(.{ .quit = {} }, .{ .forever = {} });
        }
    }

    // Probe flip-model capability only when the config opts in. The
    // probe spins up a throwaway WGL context (tens of ms on some
    // drivers), and the default SwapBuffers path never needs it, so the
    // common launch shouldn't pay for it. Consequence: enabling
    // windows-flip-model at runtime needs a restart to take effect
    // (the config doc already notes it only affects new terminals).
    const flip_capable = config.@"windows-flip-model" and
        !std.process.hasEnvVarConstant("GHOSTTY_NO_FLIP") and
        probeFlipCapable(hinstance);
    log.info("flip-model capable={}", .{flip_capable});

    // Queue a single new window that starts on launch.
    // Note: above we may send a quit so this may never happen.
    _ = core_app.mailbox.push(.{ .new_window = .{} }, .{ .forever = {} });

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .thread_id = std.os.windows.kernel32.GetCurrentThreadId(),
        .flip_capable = flip_capable,
        .com_initialized = com_initialized,
    };
    handoff_app = self;

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

/// Receive a default-terminal handoff (defterm.zig): open a window
/// whose surface adopts conhost's PTY instead of spawning one. Runs on
/// the UI thread (COM marshals it onto our message loop).
fn onHandoff(h: defterm.Handoff) void {
    const app = handoff_app orelse {
        // No app to receive it: close the handles so conhost isn't left
        // waiting on a terminal that will never read.
        _ = winapi.CloseHandle(h.our_read);
        _ = winapi.CloseHandle(h.our_write);
        if (h.signal) |s| _ = winapi.CloseHandle(s);
        if (h.reference) |r| _ = winapi.CloseHandle(r);
        if (h.client) |c| _ = winapi.CloseHandle(c);
        return;
    };
    app.receiveHandoff(h) catch |err| {
        log.err("handoff surface creation failed err={}", .{err});
    };
}

pub fn terminate(self: *App) void {
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
    defterm.stopServer();
    if (self.com_initialized) winapi.CoUninitialize();
}

/// Adopt a default-terminal handoff into a new surface. NOT YET
/// IMPLEMENTED (increment 2b): the COM server and pipe handoff are in
/// place, but wiring conhost's PTY into a surface (termio adoption of a
/// pre-made pty + pre-existing client process) is the remaining work.
/// Until then, decline by releasing the handles so conhost isn't left
/// waiting. This path is unreachable in shipping builds because
/// defterm.handoff_ready gates the server off entirely.
fn receiveHandoff(self: *App, h: defterm.Handoff) !void {
    _ = self;
    _ = winapi.CloseHandle(h.our_read);
    _ = winapi.CloseHandle(h.our_write);
    if (h.signal) |s| _ = winapi.CloseHandle(s);
    if (h.reference) |r| _ = winapi.CloseHandle(r);
    if (h.client) |c| _ = winapi.CloseHandle(c);
    return error.HandoffNotImplemented;
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
            const now = std.time.milliTimestamp();
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
                self.quit_timer_id = winapi.SetTimer(
                    null,
                    0,
                    @intCast(@max(1, delay_ns / std.time.ns_per_ms) + 100),
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
            if (parent == null and self.windows.items.len == 0) {
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

            var url_w: [2048:0]u16 = undefined;
            // UTF-16 never needs more units than UTF-8 bytes, so a
            // byte-length check guarantees the buffer fits.
            if (url.len > url_w.len - 1) {
                log.warn("url too long, not opening", .{});
                return false;
            }
            const len = std.unicode.utf8ToUtf16Le(
                url_w[0 .. url_w.len - 1],
                url,
            ) catch {
                log.warn("invalid utf-8 in url, not opening", .{});
                return false;
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

    const proc = winapi.wglGetProcAddress("wglDXOpenDeviceNV") orelse return false;
    const v = @intFromPtr(proc);
    return v > 3 and v != @as(usize, @bitCast(@as(isize, -1)));
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
    // it first.
    for (self.windows.items) |window| {
        if (window.profile_menu) |menu| menu.destroy();
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
