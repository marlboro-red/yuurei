//! Session save/restore for the win32 apprt (windows-restore-session).
//!
//! Version 2 JSON stores windows, tabs, complete split trees, and broker IDs.
//! The default workspace retains the original session path and can import
//! the legacy tab-separated v1 format. Named workspaces use hashed filenames.
//! Atomic saves are debounced after layout changes, and an exclusive lock
//! prevents separate GUI processes from overwriting the same workspace.

const std = @import("std");
const global = @import("../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const workspace = @import("../../mux/Workspace.zig");
const w = @import("winapi.zig");

const log = std.log.scoped(.win32);

const header = "yuurei-session 1";
const max_file_size = 1024 * 1024;

fn sessionPath(app: *App, alloc: std.mem.Allocator) ?[]const u8 {
    const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    const name = app.workspace_name orelse "default";
    if (std.mem.eql(u8, name, "default")) return std.fs.path.join(alloc, &.{ base, "ghostty", "session" }) catch null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const file = std.fmt.allocPrint(alloc, "workspace-{x}", .{digest}) catch return null;
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ base, "ghostty", file }) catch null;
}

fn ownWorkspace(app: *App) bool {
    if (app.session_lock_initialized) return app.session_lock != null;
    app.session_lock_initialized = true;
    const alloc = app.core_app.alloc;
    const path = sessionPath(app, alloc) orelse return false;
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(global.io(), dir) catch return false;
    const lock_path = std.fmt.allocPrint(alloc, "{s}.lock", .{path}) catch return false;
    defer alloc.free(lock_path);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, lock_path) catch return false;
    defer alloc.free(wide);
    const handle = w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, 4, 0x80, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        log.warn("workspace is already owned or unavailable; layout restore/save disabled", .{});
        return false;
    }
    app.session_lock = handle;
    return true;
}

/// Coalesce structural changes. No periodic wakeups while the layout is idle.
pub fn changed(app: *App) void {
    if (!app.config.@"windows-restore-session" or app.session_restoring or app.session_deadline_ms != null) return;
    app.session_deadline_ms = std.Io.Timestamp.now(global.io(), .awake).toMilliseconds() + 250;
    app.session_timer = w.SetTimer(null, 0, 275, null);
    if (app.session_timer == 0) {
        app.session_deadline_ms = null;
        save(app);
    }
}

pub fn tick(app: *App) void {
    const deadline = app.session_deadline_ms orelse return;
    if (std.Io.Timestamp.now(global.io(), .awake).toMilliseconds() < deadline) return;
    if (app.session_timer != 0) _ = w.KillTimer(null, app.session_timer);
    app.session_timer = 0;
    app.session_deadline_ms = null;
    save(app);
}

/// Record the current windows/tabs. Called with all windows still
/// alive (before teardown). Failures are silent: losing a session
/// snapshot must never block closing.
pub fn save(app: *App) void {
    if (!app.config.@"windows-restore-session" or app.session_restoring or !ownWorkspace(app)) return;
    saveLayout(app) catch |err| log.warn("workspace save failed: {}", .{err});
}

fn saveLayout(app: *App) !void {
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const path = sessionPath(app, alloc) orelse return;
    var windows: std.ArrayList(workspace.Window) = .empty;
    for (app.windows.items) |window| {
        if (window.quick or window.tabs.items.len == 0) continue;
        var tabs: std.ArrayList(workspace.Tab) = .empty;
        for (window.tabs.items) |*tab| {
            const nodes = try alloc.alloc(workspace.Node, tab.tree.nodes.len);
            var focused: u16 = 0;
            for (tab.tree.nodes, 0..) |node, index| {
                nodes[index] = switch (node) {
                    .leaf => |surface| leaf: {
                        if (surface == tab.focused) focused = @intCast(index);
                        break :leaf .{ .leaf = .{
                            .profile = surface.profile_name orelse "",
                            .cwd = (surface.core_surface.pwd(alloc) catch null) orelse "",
                            .session = if (surface.core_surface.io.backend == .mux) surface.core_surface.io.backend.mux.name else null,
                        } };
                    },
                    .split => |split| .{ .split = .{ .layout = @enumFromInt(@intFromEnum(split.layout)), .ratio = split.ratio, .left = @intFromEnum(split.left), .right = @intFromEnum(split.right) } },
                };
            }
            try tabs.append(alloc, .{ .title = tab.custom_title orelse "", .nodes = nodes, .focused = focused, .zoomed = if (tab.tree.zoomed) |z| @intFromEnum(z) else null });
        }
        var rect: w.RECT = undefined;
        var geometry: ?workspace.Geometry = null;
        if (w.GetWindowRect(window.hwnd, &rect) != 0 and rect.right - rect.left >= 200 and rect.bottom - rect.top >= 100 and rect.left > -30000 and rect.top > -30000)
            geometry = .{ .x = rect.left, .y = rect.top, .width = @intCast(rect.right - rect.left), .height = @intCast(rect.bottom - rect.top) };
        try windows.append(alloc, .{ .tabs = tabs.items, .active = window.active_tab, .geometry = geometry });
    }
    const state: workspace.State = .{ .windows = windows.items };
    try workspace.validate(state);
    const data = try std.json.Stringify.valueAlloc(alloc, state, .{});
    if (data.len > max_file_size) return error.WorkspaceTooLarge;
    writeAtomic(alloc, path, data);
}

/// Replace the session file atomically: write a sibling temp and rename
/// it over the target. A crash or power loss mid-write then leaves the
/// previous good file intact rather than a truncated/empty one.
fn writeAtomic(alloc: std.mem.Allocator, path: []const u8, data: []const u8) void {
    const io = global.io();
    // The parent (%LOCALAPPDATA%\ghostty) may not exist yet. createDirPath
    // is idempotent (mkdir -p), so an already-present dir is fine.
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    // Unique per-process temp name: isolated/config-specific instances can
    // save concurrently. A shared
    // deterministic ".tmp" would let two writers interleave truncate/
    // write/rename and corrupt or cross-replace each other's snapshot;
    // per-PID names keep every writer isolated until its atomic rename.
    const tmp = std.fmt.allocPrint(alloc, "{s}.{d}.tmp", .{
        path,
        std.os.windows.GetCurrentProcessId(),
    }) catch return;
    defer alloc.free(tmp);

    write: {
        const file = std.Io.Dir.createFileAbsolute(io, tmp, .{ .truncate = true }) catch break :write;
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        fw.interface.writeAll(data) catch break :write;
        fw.interface.flush() catch break :write;
        // Rename over the target (atomic replace on NTFS). Only on a
        // fully-written temp do we touch the real file.
        std.Io.Dir.renameAbsolute(tmp, path, io) catch break :write;
        return;
    }
    // Something failed; don't leave a stray temp or the stale target.
    std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
}

/// Restore the recorded session, returning the surface of the last
/// window created, or null if there is nothing (or it is disabled) —
/// the caller then creates the default window. The session file is
/// left in place; it is rewritten at the next close anyway.
pub fn restore(app: *App) ?*Surface {
    if (!app.config.@"windows-restore-session" or !ownWorkspace(app)) return null;
    app.session_restoring = true;
    defer app.session_restoring = false;
    const alloc = app.core_app.alloc;
    const path = sessionPath(app, alloc) orelse return null;
    defer alloc.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_file_size)) catch
        return null;
    defer alloc.free(data);

    if (std.mem.startsWith(u8, std.mem.trimStart(u8, data, " \r\n\t"), "{")) return restoreLayout(app, data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"), header))
        return null;

    var result: ?*Surface = null;
    var window: ?*Window = null;
    _ = app.ensureProfiles();
    const profile_list = &app.profiles_list.?;

    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse continue;

        if (std.mem.eql(u8, kind, "window")) {
            if (window) |win| {
                if (finalizeRestoredWindow(app, win)) |kept|
                    result = kept.activeSurface();
            }
            window = newRestoredWindow(app);
        } else if (std.mem.eql(u8, kind, "tab")) {
            const win = window orelse continue;
            const profile_name = fields.next() orelse "";
            const title = fields.next() orelse "";
            const cwd = fields.next() orelse "";

            _ = win.newTabWithOpts(.{
                .profile = if (profile_name.len > 0)
                    profile_list.bySavedName(profile_name)
                else
                    null,
                .cwd = if (cwd.len > 0) cwd else null,
            }) catch |err| {
                log.warn("session tab restore failed err={}", .{err});
                continue;
            };

            if (title.len > 0) {
                const tab = &win.tabs.items[win.tabs.items.len - 1];
                if (tab.custom_title) |t| alloc.free(t);
                tab.custom_title = alloc.dupe(u8, title) catch null;
            }
        } else if (std.mem.eql(u8, kind, "active")) {
            const win = window orelse continue;
            const idx = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;
            if (win.tabs.items.len > 0)
                win.activateTab(@min(idx, win.tabs.items.len - 1));
        }
    }

    if (window) |win| {
        if (finalizeRestoredWindow(app, win)) |kept|
            result = kept.activeSurface();
    }

    return result;
}

fn restoreLayout(app: *App, data: []const u8) ?*Surface {
    const parsed = std.json.parseFromSlice(workspace.State, app.core_app.alloc, data, .{}) catch return null;
    defer parsed.deinit();
    workspace.validate(parsed.value) catch |err| {
        log.warn("invalid workspace layout: {}", .{err});
        return null;
    };
    var result: ?*Surface = null;
    for (parsed.value.windows) |saved| {
        const window = newRestoredWindow(app) orelse continue;
        if (saved.geometry) |g| {
            const monitor = w.MonitorFromPoint(.{ .x = g.x, .y = g.y }, w.MONITOR_DEFAULTTONEAREST);
            var info: w.MONITORINFO = std.mem.zeroes(w.MONITORINFO);
            info.cbSize = @sizeOf(w.MONITORINFO);
            if (w.GetMonitorInfoW(monitor, &info) != 0) {
                const width = @min(@as(i32, @intCast(g.width)), info.rcWork.right - info.rcWork.left);
                const height = @min(@as(i32, @intCast(g.height)), info.rcWork.bottom - info.rcWork.top);
                _ = w.SetWindowPos(window.hwnd, null, std.math.clamp(g.x, info.rcWork.left, info.rcWork.right - width), std.math.clamp(g.y, info.rcWork.top, info.rcWork.bottom - height), width, height, w.SWP_NOACTIVATE | w.SWP_NOZORDER);
            }
        }
        for (saved.tabs) |tab| window.restoreTab(tab) catch |err| log.warn("workspace tab restore failed: {}", .{err});
        if (window.tabs.items.len > 0) window.activateTab(@min(saved.active, window.tabs.items.len - 1));
        if (finalizeRestoredWindow(app, window)) |kept| result = kept.activeSurface();
    }
    return result;
}

/// Show a restored window, or drop it when no tab could be restored
/// (an empty shell window would be useless and blocks the fallback).
fn finalizeRestoredWindow(app: *App, win: *Window) ?*Window {
    if (win.tabs.items.len == 0) {
        for (app.windows.items, 0..) |w2, i| {
            if (w2 == win) {
                _ = app.windows.orderedRemove(i);
                break;
            }
        }
        win.destroy();
        return null;
    }
    win.applyStartupShow();
    return win;
}

fn newRestoredWindow(app: *App) ?*Window {
    const alloc = app.core_app.alloc;
    const window = Window.create(alloc, app, .{ .no_initial_tab = true }) catch |err| {
        log.warn("session window restore failed err={}", .{err});
        return null;
    };
    app.windows.append(alloc, window) catch {
        window.destroy();
        return null;
    };
    // Size before the tabs spawn so the shells start at the final grid,
    // exactly like a normal launch.
    window.applyDefaultSize();
    return window;
}
