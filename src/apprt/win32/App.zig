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
const Scrollbar = @import("Scrollbar.zig");
const SearchBar = @import("SearchBar.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

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
/// WS_EX_NOREDIRECTIONBITMAP when true — the style is creation-only
/// and would break the SwapBuffers fallback, so it must be decided
/// before the renderer ever runs.
flip_capable: bool = false,

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

    // Probe flip-model capability now that the host class exists.
    const flip_capable = !std.process.hasEnvVarConstant("GHOSTTY_NO_FLIP") and
        probeFlipCapable(hinstance);
    log.info("flip-model capable={}", .{flip_capable});

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

    // Queue a single new window that starts on launch.
    // Note: above we may send a quit so this may never happen.
    _ = core_app.mailbox.push(.{ .new_window = .{} }, .{ .forever = {} });

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .thread_id = std.os.windows.kernel32.GetCurrentThreadId(),
        .flip_capable = flip_capable,
    };

    // Make sure the loop processes the queued message immediately.
    self.wakeup();

    // Register `global:` keybinds as system-wide hotkeys.
    self.registerGlobalHotkeys();
}

pub fn terminate(self: *App) void {
    if (self.tray_hwnd) |hwnd| {
        var nid: winapi.NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = 1 };
        _ = winapi.Shell_NotifyIconW(winapi.NIM_DELETE, &nid);
        _ = winapi.DestroyWindow(hwnd);
    }
    self.unregisterGlobalHotkeys();
    self.hotkey_actions.deinit(self.core_app.alloc);
    while (self.windows.pop()) |window| window.destroy();
    self.windows.deinit(self.core_app.alloc);
    self.config.deinit();
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
            continue;
        }

        // If the tick caused us to quit, then we're done.
        if (self.quit or self.windows.items.len == 0) {
            while (self.windows.pop()) |window| window.destroy();
            return;
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
            self.quit = true;
            self.wakeup();
        },

        .new_window => _ = try self.newSurface(switch (target) {
            .app => null,
            .surface => |v| v,
        }),

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
            .app => {},
            .surface => |surface| surface.rt_surface.window.gotoTab(value),
        },

        .close_tab => switch (target) {
            .app => {},
            .surface => |surface| {
                surface.rt_surface.window.closeTabContaining(surface.rt_surface);
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
            .app => {},
            .surface => |surface| surface.rt_surface.window.gotoSplit(value),
        },

        .resize_split => switch (target) {
            .app => {},
            .surface => |surface| surface.rt_surface.window.resizeSplit(value),
        },

        .equalize_splits => switch (target) {
            .app => {},
            .surface => |surface| surface.rt_surface.window.equalizeSplits(),
        },

        .toggle_split_zoom => switch (target) {
            .app => {},
            .surface => |surface| surface.rt_surface.window.toggleSplitZoom(),
        },

        .close_window => switch (target) {
            .app => {},
            .surface => |surface| {
                surface.rt_surface.window.should_close = true;
            },
        },

        .set_title => switch (target) {
            .app => {},
            .surface => |surface| try surface.rt_surface.setTitle(value.title),
        },

        .mouse_shape => switch (target) {
            .app => {},
            .surface => |surface| try surface.rt_surface.setMouseShape(value),
        },

        .initial_size => switch (target) {
            .app => {},
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
                if (surface.rt_surface.window.search) |search| search.destroy();
            },
        },

        .search_total => switch (target) {
            .app => return false,
            .surface => |surface| {
                if (surface.rt_surface.window.search) |search| {
                    search.setTotal(value.total);
                }
            },
        },

        .search_selected => switch (target) {
            .app => return false,
            .surface => |surface| {
                if (surface.rt_surface.window.search) |search| {
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
            .app => {},
            .surface => |surface| {
                const hwnd = surface.rt_surface.window.hwnd;
                // Beep only when we're in the background; flash either
                // way so the bell is visible on the taskbar.
                if (winapi.GetForegroundWindow() != hwnd) {
                    _ = winapi.MessageBeep(0);
                }
                winapi.flashWindow(hwnd);
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

    // Window-level transparency/blur are applied by the apprt (not the
    // renderer), so re-apply them here for background-opacity /
    // background-blur changes to take effect live.
    for (self.windows.items) |window| window.reapplyTransparency();

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
