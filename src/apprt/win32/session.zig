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
pub const catalog = @import("../../mux/WorkspaceCatalog.zig");
const w = @import("winapi.zig");
const Transfer = @import("../../mux/WorkspaceTransfer.zig");

const log = std.log.scoped(.win32);

const header = "yuurei-session 1";
const max_file_size = 1024 * 1024;

fn sessionPath(app: *App, alloc: std.mem.Allocator) ?[]const u8 {
    const base = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(base);
    const name = app.workspace_name orelse "default";
    const file = catalog.filename(alloc, name) catch return null;
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ base, "ghostty", file }) catch null;
}

/// Saved layouts only. Call from a worker; release results with catalog.deinit.
pub fn listSaved(alloc: std.mem.Allocator) ![]catalog.Entry {
    try recoverTransfers(alloc);
    const base = try global.environ().getAlloc(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    const directory = try std.fs.path.join(alloc, &.{ base, "ghostty" });
    defer alloc.free(directory);
    return catalog.list(global.io(), alloc, directory);
}

/// Owns the target lock and parsed layout until the UI commits or cancels.
/// Preparation must run on a worker. It never changes App or starts a shell.
pub const PreparedWorkspace = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    lock: ?w.HANDLE,
    layout: std.json.Parsed(workspace.State),

    pub fn deinit(self: *PreparedWorkspace) void {
        self.layout.deinit();
        if (self.lock) |lock| _ = w.CloseHandle(lock);
        self.alloc.free(self.name);
        self.* = undefined;
    }
};

/// current_ids must be an owned snapshot when called from a worker. The UI
/// must reject completion if its workspace/layout generation changed meanwhile.
pub fn prepareSwitch(alloc: std.mem.Allocator, name: []const u8, current_ids: []const []const u8) !PreparedWorkspace {
    return prepareTarget(alloc, name, current_ids, false, false);
}

pub fn prepareMove(alloc: std.mem.Allocator, name: []const u8, current_ids: []const []const u8) !PreparedWorkspace {
    return prepareTarget(alloc, name, current_ids, false, true);
}

/// Reserve a previously unused workspace identity without publishing a layout.
/// Cancelling releases the lock; no shell or saved workspace has been created.
pub fn prepareCreate(alloc: std.mem.Allocator, name: []const u8) !PreparedWorkspace {
    return prepareTarget(alloc, name, &.{}, true, false);
}

fn prepareTarget(alloc: std.mem.Allocator, name: []const u8, current_ids: []const []const u8, create: bool, allow_empty: bool) !PreparedWorkspace {
    if (!catalog.validName(name)) return error.InvalidWorkspaceName;
    try recoverTransfers(alloc);
    const base = try global.environ().getAlloc(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    const filename = try catalog.filename(alloc, name);
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ base, "ghostty", filename });
    defer alloc.free(path);
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{path});
    defer alloc.free(lock_path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, lock_path);
    defer alloc.free(wide);
    const lock = w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, 4, 0x80, null);
    if (lock == std.os.windows.INVALID_HANDLE_VALUE) return error.WorkspaceUnavailable;
    errdefer _ = w.CloseHandle(lock);
    if (create) {
        const existing: ?std.Io.File = std.Io.Dir.cwd().openFile(global.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| {
            file.close(global.io());
            return error.WorkspaceAlreadyExists;
        }
    }
    const data = if (create) try alloc.dupe(u8, "{\"version\":2,\"windows\":[]}") else try std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_file_size));
    defer alloc.free(data);
    // Own every string independently of the temporary file buffer.
    const parsed = try std.json.parseFromSlice(workspace.State, alloc, data, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (!create) {
        if (allow_empty and parsed.value.windows.len == 0) {
            try workspace.validate(parsed.value);
        } else try @import("../../mux/WorkspaceSwitch.zig").validate(parsed.value, current_ids);
    }
    return .{ .alloc = alloc, .name = try alloc.dupe(u8, name), .lock = lock, .layout = parsed };
}

fn ownWorkspace(app: *App) bool {
    if (app.session_lock_initialized) return app.session_lock != null;
    app.session_lock_initialized = true;
    const alloc = app.core_app.alloc;
    recoverTransfers(alloc) catch |err| {
        log.warn("workspace recovery failed: {}", .{err});
        return false;
    };
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
    if (!app.session_restoring) app.workspace_generation +%= 1;
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
    if (app.workspace_job != null) return;
    save(app);
}

/// Record the current windows/tabs. Called with all windows still
/// alive (before teardown). Failures are silent: losing a session
/// snapshot must never block closing.
pub fn save(app: *App) void {
    // Explicit close/shutdown saves must capture the latest live layout.
    // Stop a preparation writer first so it cannot overwrite this save later.
    cancelSwitch(app);
    if (!app.config.@"windows-restore-session" or app.session_restoring or !ownWorkspace(app)) return;
    saveChecked(app) catch |err| log.warn("workspace save failed: {}", .{err});
}

/// Explicit workspace operations must not detach any views unless this succeeds.
/// Unlike the best-effort shutdown wrapper, failures remain visible to callers.
pub fn saveChecked(app: *App) !void {
    if (app.workspace_job != null) return error.WorkspaceSwitchInProgress;
    if (app.session_restoring) return error.WorkspaceRestoreInProgress;
    if (!ownWorkspace(app)) return error.WorkspaceUnavailable;
    try saveLayout(app);
}

fn saveLayout(app: *App) !void {
    const alloc = app.core_app.alloc;
    const path = sessionPath(app, alloc) orelse return error.WorkspaceUnavailable;
    defer alloc.free(path);
    const data = try captureLayout(app, alloc);
    defer alloc.free(data);
    try writeSaved(alloc, path, app.workspace_name orelse "default", data);
}

fn captureLayout(app: *App, output_alloc: std.mem.Allocator) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
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
    return output_alloc.dupe(u8, data);
}

pub fn writeSaved(alloc: std.mem.Allocator, path: []const u8, name: []const u8, data: []const u8) !void {
    try writeAtomic(global.io(), alloc, path, data);
    // Existing configurations with non-displayable names can still save their
    // layouts. Only publish names suitable for the embedded workspace picker.
    if (!std.mem.eql(u8, name, "default") and catalog.validName(name)) {
        const metadata = try std.fmt.allocPrint(alloc, "{s}.name", .{path});
        defer alloc.free(metadata);
        try writeAtomic(global.io(), alloc, metadata, name);
    }
}

pub fn beginSwitch(app: *App, hwnd: w.HWND, name: []const u8) !void {
    return beginWorkspace(app, hwnd, name, false, false, null);
}

pub fn beginMove(app: *App, hwnd: w.HWND, name: []const u8) !void {
    if (!app.config.@"windows-persistent-sessions" or !app.config.@"windows-restore-session") return error.WorkspacePersistenceDisabled;
    return beginWorkspace(app, hwnd, name, false, true, null);
}

pub fn beginNavigation(app: *App, hwnd: w.HWND, direction: catalog.Direction) !void {
    return beginWorkspace(app, hwnd, null, false, false, direction);
}

pub fn beginCreate(app: *App, hwnd: w.HWND, name: []const u8) !void {
    if (!app.config.@"windows-persistent-sessions" or !app.config.@"windows-restore-session") return error.WorkspacePersistenceDisabled;
    return beginWorkspace(app, hwnd, name, true, false, null);
}

fn beginWorkspace(app: *App, hwnd: w.HWND, name: ?[]const u8, create: bool, move: bool, direction: ?catalog.Direction) !void {
    if (name) |value| if (!catalog.validName(value)) return error.InvalidWorkspaceName;
    if (app.workspace_job != null) return error.WorkspaceSwitchInProgress;
    if (name) |value| if (std.mem.eql(u8, app.workspace_name orelse "default", value)) return error.WorkspaceAlreadyActive;
    if (!ownWorkspace(app)) return error.WorkspaceUnavailable;
    const Job = @import("WorkspaceJob.zig");
    const job = try Job.create(hwnd);
    errdefer job.destroy();
    job.create_new = create;
    job.move_tab = move;
    job.direction = direction;
    var saved_index: usize = 0;
    const owner = for (app.windows.items) |window| {
        if (window.quick or window.tabs.items.len == 0) continue;
        if (window.hwnd == hwnd) break window;
        if (window.palette) |palette| if (palette.hwnd == hwnd) break window;
        saved_index += 1;
    } else return error.WorkspaceChanged;
    job.source_window = saved_index;
    job.source_tab = owner.active_tab;
    job.owner = owner.hwnd;
    job.backend_alloc = app.core_app.alloc;
    if (name) |value| job.target = try Job.alloc.dupe(u8, value);
    job.source_name = try Job.alloc.dupe(u8, app.workspace_name orelse "default");
    job.source_path = sessionPath(app, Job.alloc) orelse return error.WorkspaceUnavailable;
    job.source_data = try captureLayout(app, Job.alloc);
    job.generation = app.workspace_generation;
    try job.start();
    app.workspace_job = job;
    owner.refreshSessionBar(false);
}

pub fn cancelSwitch(app: *App) void {
    const job = app.workspace_job orelse return;
    app.workspace_job = null;
    job.destroy();
    for (app.windows.items) |window| window.refreshSessionBar(false);
    changed(app);
}

/// Called outside window procedures so successful switching may destroy old views.
pub fn pollSwitch(app: *App) void {
    const job = app.workspace_job orelse return;
    if (app.quit) {
        cancelSwitch(app);
        return;
    }
    // Cancel before the close sweep, even while the worker is still running.
    // The sweep must be able to persist ended panes without a pending worker
    // later writing an older layout over the termination record.
    const stale = stale: {
        if (job.generation != app.workspace_generation) break :stale true;
        for (app.windows.items) |window| {
            if (window.should_close) break :stale true;
            for (window.tabs.items) |tab| for (tab.tree.nodes) |node| {
                if (node == .leaf and node.leaf.should_close) break :stale true;
            };
        }
        break :stale false;
    };
    if (stale) {
        const owner = job.hwnd;
        cancelSwitch(app);
        reportFailure(app, owner, error.WorkspaceChanged);
        return;
    }
    if (!job.done.load(.acquire)) return;
    app.workspace_job = null;
    defer job.destroy();
    const failure = job.failure orelse failed: {
        commitSwitch(app, job) catch |err| break :failed err;
        return;
    };
    log.warn("workspace switch failed: {}", .{failure});
    reportFailure(app, job.hwnd, failure);
    changed(app);
}

fn reportFailure(app: *App, hwnd: w.HWND, failure: anyerror) void {
    for (app.windows.items) |window| {
        if (window.hwnd == hwnd) window.workspaceFailed(failure);
        if (window.palette) |palette| if (palette.hwnd == hwnd) palette.workspaceFailed(failure);
    }
}

fn commitSwitch(app: *App, job: *@import("WorkspaceJob.zig")) !void {
    if (job.move_tab) {
        const owner = for (app.windows.items) |window| {
            if (window.hwnd == job.owner) break window;
        } else return error.WorkspaceChanged;
        if (job.source_tab >= owner.tabs.items.len) return error.WorkspaceChanged;
        app.session_restoring = true;
        defer app.session_restoring = false;
        owner.detachWorkspaceTab(job.source_tab);
        app.workspace_generation +%= 1;
        job.accepted.store(true, .release);
        return;
    }
    const prepared = &job.prepared.?;
    const name = try app.core_app.alloc.dupe(u8, prepared.name);
    errdefer app.core_app.alloc.free(name);
    const previous_count = app.windows.items.len;
    app.session_restoring = true;
    defer app.session_restoring = false;
    errdefer while (app.windows.items.len > previous_count) {
        const window = app.windows.pop().?;
        window.destroy();
    };
    if (job.create_new) {
        const owner = for (app.windows.items) |window| {
            if (window.hwnd == job.owner) break window;
        } else return error.WorkspaceChanged;
        if (job.source_tab >= owner.tabs.items.len) return error.WorkspaceChanged;
        owner.clearWorkspaceUi(&owner.tabs.items[job.source_tab].tree);
        // Move the live tree by value. The pane HWNDs and terminal pins stay put.
        const tab = owner.tabs.orderedRemove(job.source_tab);
        owner.discardWorkspaceTabs(0);
        owner.tabs.appendAssumeCapacity(tab);
        adoptWorkspace(app, prepared, name);
        var i: usize = 0;
        while (i < app.windows.items.len) {
            const window = app.windows.items[i];
            if (window == owner or window.quick) {
                i += 1;
            } else {
                _ = app.windows.orderedRemove(i);
                window.destroy();
            }
        }
        owner.activateTab(0);
        owner.refreshSessionBar(true);
        _ = w.SetFocus(owner.hwnd);
        app.workspace_generation +%= 1;
        job.accepted.store(true, .release);
        return;
    }
    // Reuse the picker owner's window first, then any other normal windows.
    // Newly restored hosts remain hidden until every target tab is ready.
    var targets: [16]*Window = undefined;
    var old_counts: [16]usize = undefined;
    var target_count: usize = 0;
    for (app.windows.items[0..previous_count]) |window| {
        if (!window.quick and window.hwnd == job.owner) {
            targets[target_count] = window;
            target_count += 1;
            break;
        }
    }
    for (app.windows.items[0..previous_count]) |window| {
        if (target_count >= prepared.layout.value.windows.len) break;
        if (window.quick or (target_count > 0 and targets[0] == window)) continue;
        targets[target_count] = window;
        target_count += 1;
    }
    var staged: usize = 0;
    errdefer for (targets[0..staged], old_counts[0..staged]) |window, first| window.discardWorkspaceTabs(first);
    for (prepared.layout.value.windows, 0..) |saved, i| {
        if (i >= target_count) {
            targets[i] = newRestoredWindow(app) orelse return error.CreateWindowFailed;
            target_count += 1;
            applyGeometry(targets[i], saved.geometry);
        }
        const window = targets[i];
        old_counts[i] = window.tabs.items.len;
        staged += 1;
        for (saved.tabs) |tab| try window.stageWorkspaceTab(tab, job.muxes.items);
    }
    adoptWorkspace(app, prepared, name);
    for (prepared.layout.value.windows, 0..) |saved, i| targets[i].installWorkspaceTabs(old_counts[i], saved.active);
    // Preserve quick terminals and the reused outer windows; retire only extras.
    var index: usize = 0;
    while (index < previous_count and index < app.windows.items.len) {
        const window = app.windows.items[index];
        const keep = window.quick or for (targets[0..staged]) |target| {
            if (window == target) break true;
        } else false;
        if (keep) {
            index += 1;
        } else {
            _ = app.windows.orderedRemove(index);
            window.destroy();
        }
    }
    for (targets[0..staged], old_counts[0..staged]) |window, old_count| {
        if (old_count == 0) window.applyStartupShow();
    }
    if (staged > 0) _ = w.SetFocus(targets[0].hwnd);
    app.workspace_generation +%= 1;
}

fn adoptWorkspace(app: *App, prepared: *PreparedWorkspace, name: []const u8) void {
    if (app.session_timer != 0) _ = w.KillTimer(null, app.session_timer);
    app.session_timer = 0;
    app.session_deadline_ms = null;
    if (app.session_lock) |lock| _ = w.CloseHandle(lock);
    app.session_lock = prepared.lock;
    prepared.lock = null;
    app.session_lock_initialized = true;
    if (app.last_workspace_name) |old| app.core_app.alloc.free(old);
    app.last_workspace_name = app.workspace_name;
    app.workspace_name = name;
}

/// Finish a journal left by a crash before anyone restores either layout.
/// Active transfers hold both locks and are skipped, never overwritten.
fn recoverTransfers(alloc: std.mem.Allocator) !void {
    const base = try global.environ().getAlloc(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    const directory = try std.fs.path.join(alloc, &.{ base, "ghostty" });
    defer alloc.free(directory);
    var dir = std.Io.Dir.cwd().openDir(global.io(), directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(global.io());
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(global.io())) |entry| {
        count += 1;
        if (count > 1024) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".move")) continue;
        const data = dir.readFileAlloc(global.io(), entry.name, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(data);
        const parsed = try std.json.parseFromSlice(Transfer.Record, alloc, data, .{});
        defer parsed.deinit();
        const record = parsed.value;
        try Transfer.validate(record);
        const expected = try Transfer.journalPath(alloc, directory, record.source);
        defer alloc.free(expected);
        if (!std.mem.eql(u8, entry.name, std.fs.path.basename(expected))) return error.InvalidWorkspaceTransfer;
        const source_lock = transferLock(alloc, directory, record.source) catch continue;
        defer _ = w.CloseHandle(source_lock);
        const target_lock = transferLock(alloc, directory, record.target) catch continue;
        defer _ = w.CloseHandle(target_lock);
        // The file may have changed or vanished while an active writer owned it.
        const current = dir.readFileAlloc(global.io(), entry.name, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(current);
        if (!std.mem.eql(u8, data, current)) continue;
        try Transfer.finish(global.io(), alloc, directory, record);
    }
}

fn transferLock(alloc: std.mem.Allocator, directory: []const u8, name: []const u8) !w.HANDLE {
    const file = try catalog.filename(alloc, name);
    defer alloc.free(file);
    const path = try std.fmt.allocPrint(alloc, "{s}{s}{s}.lock", .{ directory, std.fs.path.sep_str, file });
    defer alloc.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    const lock = w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, 4, 0x80, null);
    if (lock == std.os.windows.INVALID_HANDLE_VALUE) return error.WorkspaceUnavailable;
    return lock;
}

fn applyGeometry(window: *Window, geometry: ?workspace.Geometry) void {
    const g = geometry orelse return;
    const monitor = w.MonitorFromPoint(.{ .x = g.x, .y = g.y }, w.MONITOR_DEFAULTTONEAREST);
    var info: w.MONITORINFO = std.mem.zeroes(w.MONITORINFO);
    info.cbSize = @sizeOf(w.MONITORINFO);
    if (w.GetMonitorInfoW(monitor, &info) == 0) return;
    const width = @min(@as(i32, @intCast(g.width)), info.rcWork.right - info.rcWork.left);
    const height = @min(@as(i32, @intCast(g.height)), info.rcWork.bottom - info.rcWork.top);
    _ = w.SetWindowPos(window.hwnd, null, std.math.clamp(g.x, info.rcWork.left, info.rcWork.right - width), std.math.clamp(g.y, info.rcWork.top, info.rcWork.bottom - height), width, height, w.SWP_NOACTIVATE | w.SWP_NOZORDER);
}

/// Replace the session file atomically: write a sibling temp and rename
/// it over the target. A crash or power loss mid-write then leaves the
/// previous good file intact rather than a truncated/empty one.
const writeAtomic = @import("../../mux/WorkspaceTransfer.zig").writeAtomic;

test "session atomic save replaces a layout and reports replacement failure" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "session" });
    defer t.allocator.free(path);
    try writeAtomic(t.io, t.allocator, path, "previous layout");
    try writeAtomic(t.io, t.allocator, path, "replacement");
    const data = try tmp.dir.readFileAlloc(t.io, "session", t.allocator, .limited(1024));
    defer t.allocator.free(data);
    try t.expectEqualStrings("replacement", data);

    // A nonempty directory cannot be replaced by a layout file. The error
    // must reach the caller and the existing contents must survive.
    try tmp.dir.createDirPath(t.io, "blocked");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "blocked/marker", .data = "keep" });
    const blocked = try std.fs.path.join(t.allocator, &.{ root, "blocked" });
    defer t.allocator.free(blocked);
    var failed = false;
    writeAtomic(t.io, t.allocator, blocked, "new layout") catch {
        failed = true;
    };
    try t.expect(failed);
    const marker = try tmp.dir.readFileAlloc(t.io, "blocked/marker", t.allocator, .limited(1024));
    defer t.allocator.free(marker);
    try t.expectEqualStrings("keep", marker);
    const temporary = try std.fmt.allocPrint(t.allocator, "{s}.{d}.tmp", .{ blocked, std.os.windows.GetCurrentProcessId() });
    defer t.allocator.free(temporary);
    try t.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(t.io, temporary, .{}));
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
