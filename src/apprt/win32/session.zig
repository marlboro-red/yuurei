//! Session save/restore for the win32 apprt (windows-restore-session).
//!
//! State is a small tab-separated text file at
//! %LOCALAPPDATA%\ghostty\session, rewritten whenever a window closes
//! or the app quits, and consumed by the first window creation on the
//! next launch. Per tab: profile name, manual title, and working
//! directory (splits are not yet recorded; a tab restores as its
//! focused pane).
//!
//! Format (fields are tab-separated, empty allowed):
//!   yuurei-session 1
//!   window
//!   tab\t<profile>\t<title>\t<cwd>
//!   active\t<idx>

const std = @import("std");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

const header = "yuurei-session 1";
const max_file_size = 64 * 1024;

fn sessionPath(alloc: std.mem.Allocator) ?[]const u8 {
    const base = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    return std.fs.path.join(alloc, &.{ base, "ghostty", "session" }) catch null;
}

/// A field is one line-cell: tabs and newlines stripped so the format
/// can't be broken by hostile titles/paths.
fn writeField(w: anytype, field: []const u8) void {
    for (field) |c| {
        if (c == '\t' or c == '\n' or c == '\r') continue;
        w.writeByte(c) catch return;
    }
}

/// Record the current windows/tabs. Called with all windows still
/// alive (before teardown). Failures are silent: losing a session
/// snapshot must never block closing.
pub fn save(app: *App) void {
    if (!app.config.@"windows-restore-session") return;
    const alloc = app.core_app.alloc;
    const path = sessionPath(alloc) orelse return;
    defer alloc.free(path);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const w = &buf.writer;

    w.writeAll(header ++ "\n") catch return;
    var recorded: usize = 0;
    for (app.windows.items) |window| {
        // The quick terminal is summoned, not restored.
        if (window.quick) continue;
        if (window.tabs.items.len == 0) continue;
        recorded += 1;
        w.writeAll("window\n") catch return;
        for (window.tabs.items) |*tab| {
            const surface = tab.focused;
            w.writeAll("tab\t") catch return;
            writeField(w, surface.profile_name orelse "");
            w.writeByte('\t') catch return;
            writeField(w, tab.custom_title orelse "");
            w.writeByte('\t') catch return;
            const cwd = surface.core_surface.pwd(alloc) catch null;
            defer if (cwd) |c| alloc.free(c);
            writeField(w, cwd orelse "");
            w.writeByte('\n') catch return;
        }
        w.print("active\t{d}\n", .{window.active_tab}) catch return;
    }

    // Nothing restorable is open — e.g. quitting from a lingering quick
    // terminal after the real windows already closed (their good snapshot
    // was written when they closed). Overwriting now with a header-only
    // file would silently destroy that snapshot, so leave it untouched:
    // restoring the last real layout beats restoring nothing.
    if (recorded == 0) return;

    writeAtomic(alloc, path, buf.written());
}

/// Replace the session file atomically: write a sibling temp and rename
/// it over the target. A crash or power loss mid-write then leaves the
/// previous good file intact rather than a truncated/empty one.
fn writeAtomic(alloc: std.mem.Allocator, path: []const u8, data: []const u8) void {
    // The parent (%LOCALAPPDATA%\ghostty) may not exist yet.
    if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};

    const tmp = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
    defer alloc.free(tmp);

    write: {
        const file = std.fs.createFileAbsolute(tmp, .{ .truncate = true }) catch break :write;
        defer file.close();
        file.writeAll(data) catch break :write;
        // Rename over the target (atomic replace on NTFS). Only on a
        // fully-written temp do we touch the real file.
        std.fs.renameAbsolute(tmp, path) catch break :write;
        return;
    }
    // Something failed; don't leave a stray temp or the stale target.
    std.fs.deleteFileAbsolute(tmp) catch {};
}

/// Restore the recorded session, returning the surface of the last
/// window created, or null if there is nothing (or it is disabled) —
/// the caller then creates the default window. The session file is
/// left in place; it is rewritten at the next close anyway.
pub fn restore(app: *App) ?*Surface {
    if (!app.config.@"windows-restore-session") return null;
    const alloc = app.core_app.alloc;
    const path = sessionPath(alloc) orelse return null;
    defer alloc.free(path);

    const data = std.fs.cwd().readFileAlloc(alloc, path, max_file_size) catch
        return null;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, std.mem.trimRight(u8, lines.next() orelse "", "\r"), header))
        return null;

    var result: ?*Surface = null;
    var window: ?*Window = null;
    const profile_list = app.ensureProfiles();

    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
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
                    profile_list.byName(profile_name)
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
