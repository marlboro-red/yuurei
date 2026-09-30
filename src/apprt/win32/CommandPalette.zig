/// A native command palette: a borderless popup over the parent window
/// with a typed filter and a selectable list of commands from the
/// `command-palette-entry` config (defaults to every named binding
/// action). Enter or click performs the selected command on the
/// window's focused surface; Escape or focus loss dismisses. Session mode
/// is an embedded terminal-area view and stays open across focus changes.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const winapi = @import("winapi.zig");
const SessionPreview = @import("SessionPreview.zig");
const Registry = @import("../../mux/Registry.zig");
const session = @import("session.zig");
const WorkspaceJob = @import("WorkspaceJob.zig");

const log = std.log.scoped(.win32);

/// The palette window class name, registered once by App.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-palette");

/// The window the palette is summoned over.
window: *Window,

/// The popup or embedded child window.
hwnd: winapi.HWND,
/// Session navigation occupies the terminal area as a child view.
embedded: bool = false,

/// The typed filter, as WM_CHAR delivered it (UTF-16).
filter: std.ArrayList(u16) = .empty,

/// Indices into commands() matching the filter, in command order.
matches: std.ArrayList(usize) = .empty,

/// Index into matches of the highlighted row.
selected: usize = 0,

/// Index into matches of the first visible row.
scroll: usize = 0,
mode: enum { commands, sessions, rename_session, workspaces, create_workspace } = .commands,
move_workspace: bool = false,
workspace_listing: ?*WorkspaceJob = null,
workspace_loaded: bool = false,
workspaces: []session.catalog.Entry = &.{},
session_arena: std.heap.ArenaAllocator,
sessions: []Registry.Entry = &.{},
rename_id: ?[]const u8 = null,
rename_fresh: bool = false,
rename_text: std.ArrayList(u16) = .empty,
error_text: ?[]const u8 = null,
preview: ?*SessionPreview = null,

/// Cached fonts, recreated on DPI change. The palette repaints on every
/// keystroke; re-creating fonts each paint is measurable GDI churn.
font_title: ?*anyopaque = null,
font_desc: ?*anyopaque = null,
font_dpi: u32 = 0,

/// Logical (96-dpi) metrics, scaled by the parent window DPI.
const width_logical: i32 = 560;
const input_height_logical: i32 = 40;
const row_height_logical: i32 = 44;
const max_visible_rows: usize = 8;

/// Hard cap on filter length in UTF-16 units. refilter converts into a
/// fixed [512]u8 and utf16LeToUtf8 does not bounds-check its
/// destination; 3 output bytes per unit is the worst case.
const filter_max_units: usize = 512 / 3;

pub fn create(alloc: Allocator, window: *Window) !*CommandPalette {
    return createView(alloc, window, false);
}

pub fn createSessions(alloc: Allocator, window: *Window) !*CommandPalette {
    return createView(alloc, window, true);
}

fn createView(alloc: Allocator, window: *Window, embedded: bool) !*CommandPalette {
    const self = try alloc.create(CommandPalette);
    errdefer alloc.destroy(self);

    const hwnd = winapi.CreateWindowExW(
        if (embedded) 0 else winapi.WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        if (embedded) winapi.WS_CHILD | winapi.WS_CLIPSIBLINGS else winapi.WS_POPUP,
        0,
        0,
        1,
        1,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = winapi.DestroyWindow(hwnd);

    self.* = .{ .window = window, .hwnd = hwnd, .embedded = embedded, .mode = if (embedded) .sessions else .commands, .session_arena = .init(alloc) };
    _ = winapi.SetWindowLongPtrW(
        hwnd,
        winapi.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    if (embedded) self.preview = SessionPreview.create(hwnd) catch null;
    self.refilter();
    _ = winapi.ShowWindow(hwnd, winapi.SW_SHOW);
    // No SetFocus here: the caller assigns window.palette first, then
    // focuses, so the parent's WM_KILLFOCUS sees consistent state.
    return self;
}

/// Dismiss the palette without giving focus back to the parent (the
/// focus-loss path, and the tail of every other path).
pub fn destroy(self: *CommandPalette) void {
    const alloc = self.window.app.core_app.alloc;
    if (self.workspace_listing) |job| job.destroy();
    if (self.window.app.workspace_job) |job| {
        if (job.hwnd == self.hwnd) session.cancelSwitch(self.window.app);
    }
    self.window.palette = null;
    _ = winapi.KillTimer(self.hwnd, 1);
    if (self.preview) |preview| preview.destroy();
    if (self.font_title) |f| _ = winapi.DeleteObject(f);
    if (self.font_desc) |f| _ = winapi.DeleteObject(f);
    _ = winapi.SetWindowLongPtrW(self.hwnd, winapi.GWLP_USERDATA, 0);
    _ = winapi.DestroyWindow(self.hwnd);
    if (self.embedded) self.window.refreshActiveTab();
    self.filter.deinit(alloc);
    self.rename_text.deinit(alloc);
    self.matches.deinit(alloc);
    self.session_arena.deinit();
    if (self.rename_id) |id| alloc.free(id);
    alloc.destroy(self);
}

pub fn showSessions(self: *CommandPalette) void {
    if (self.workspace_listing) |job| job.destroy();
    self.workspace_listing = null;
    self.workspaces = &.{};
    if (self.embedded and self.preview == null) self.preview = SessionPreview.create(self.hwnd) catch null;
    self.mode = .sessions;
    self.error_text = null;
    self.filter.clearRetainingCapacity();
    _ = self.session_arena.reset(.free_all);
    self.sessions = Registry.list(self.session_arena.allocator()) catch block: {
        self.error_text = "Unable to load sessions. Press F5 to retry.";
        break :block &.{};
    };
    // Exit records exist briefly while the broker notifies attached views.
    // They are no longer attachable sessions.
    var live: usize = 0;
    for (self.sessions) |entry| {
        if (entry.exited) continue;
        self.sessions[live] = entry;
        live += 1;
    }
    self.sessions = self.sessions[0..live];
    std.mem.sort(Registry.Entry, self.sessions, {}, struct {
        fn less(_: void, a: Registry.Entry, b: Registry.Entry) bool {
            return std.ascii.lessThanIgnoreCase(if (a.label.len > 0) a.label else a.name, if (b.label.len > 0) b.label else b.name);
        }
    }.less);
    self.refilter();
}

pub fn showWorkspaces(self: *CommandPalette) void {
    self.move_workspace = false;
    if (self.preview) |preview| preview.destroy();
    self.preview = null;
    if (self.workspace_listing) |job| job.destroy();
    self.workspace_listing = null;
    self.workspace_loaded = false;
    self.workspaces = &.{};
    self.mode = .workspaces;
    self.filter.clearRetainingCapacity();
    self.error_text = "Loading workspaces…";
    self.refilter();
    const job = WorkspaceJob.create(self.hwnd) catch {
        self.workspaceFailed(error.OutOfMemory);
        return;
    };
    job.start() catch |err| {
        job.destroy();
        self.workspaceFailed(err);
        return;
    };
    self.workspace_listing = job;
}

fn workspaceMode(self: *const CommandPalette) bool {
    return self.mode == .workspaces or self.mode == .create_workspace;
}

fn isEditing(self: *const CommandPalette) bool {
    return self.mode == .rename_session or self.mode == .create_workspace;
}

pub fn newWorkspace(self: *CommandPalette) void {
    if (self.window.app.workspace_job != null) return;
    self.mode = .create_workspace;
    self.rename_text.clearRetainingCapacity();
    self.rename_fresh = false;
    self.error_text = null;
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}

fn cancelCreate(self: *CommandPalette) void {
    session.cancelSwitch(self.window.app);
    self.mode = .workspaces;
    self.rename_text.clearRetainingCapacity();
    self.error_text = null;
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}

fn createWorkspace(self: *CommandPalette) void {
    var buffer: [512]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buffer, self.rename_text.items) catch 0;
    const name = std.mem.trim(u8, buffer[0..n], " ");
    session.beginCreate(self.window.app, self.hwnd, name) catch |err| {
        self.workspaceFailed(err);
        return;
    };
    self.workspaceFailed(error.WorkspaceSwitchInProgress);
}

pub fn workspaceFailed(self: *CommandPalette, err: anyerror) void {
    self.error_text = workspaceError(err);
    _ = winapi.InvalidateRect(self.hwnd, null, 0);
}

pub fn workspaceError(err: anyerror) []const u8 {
    return switch (err) {
        error.NoOtherWorkspace => "No other saved workspace with panes.",
        error.NoLastWorkspace => "No previous workspace in this window.",
        error.InvalidWorkspaceName => "Enter a workspace name without control characters.",
        error.WorkspaceAlreadyExists => "A saved workspace already uses this name.",
        error.WorkspacePersistenceDisabled => "Enable persistent sessions and session restore in Settings first.",
        error.WorkspaceRecoveryRequired => "A saved update needs recovery. Close and reopen this window.",
        error.WorkspaceAlreadyActive => "This workspace is already active.",
        error.WorkspaceSwitchInProgress => "Preparing workspace. Escape cancels.",
        error.WorkspaceUnavailable => "Workspace is open elsewhere or unavailable.",
        error.NonPersistentWorkspace => "Switching requires persistent sessions in both workspaces.",
        error.WorkspaceSessionOverlap => "These workspaces contain the same shell. Switch cancelled.",
        error.WorkspaceChanged => "Current layout changed. Retry the workspace switch.",
        error.SessionBusy => "A target session is attached elsewhere. Switch cancelled.",
        error.SessionNotFound, error.SessionEnded => "A target session has ended. Switch cancelled.",
        error.IncompatibleBuild => "Target sessions use a different build. Switch cancelled.",
        error.EmptyWorkspace => "This workspace has no saved panes.",
        else => "Workspace unavailable. Refresh the workspace list and retry.",
    };
}

pub fn sessionClosed(self: *CommandPalette, name: []const u8) void {
    if (self.mode == .commands or self.workspaceMode()) return;
    const editing = self.mode == .rename_session;
    if (editing) self.mode = .sessions;
    var live: usize = 0;
    for (self.sessions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) continue;
        self.sessions[live] = entry;
        live += 1;
    }
    self.sessions = self.sessions[0..live];
    self.refilter();
    if (editing) {
        if (self.rename_id) |id| {
            for (self.matches.items, 0..) |index, position| {
                if (!std.mem.eql(u8, self.sessions[index].name, id)) continue;
                self.moveSelection(@intCast(position));
                self.mode = .rename_session;
                return;
            }
        }
        self.cancelRename();
        self.error_text = "Session ended.";
    }
}

fn refreshSessions(self: *CommandPalette) void {
    var selected_id: [128]u8 = undefined;
    const id = if (self.selected < self.matches.items.len) self.sessions[self.matches.items[self.selected]].name else "";
    const id_len = @min(id.len, selected_id.len);
    @memcpy(selected_id[0..id_len], id[0..id_len]);
    var previous: [filter_max_units]u16 = undefined;
    const len = self.filter.items.len;
    @memcpy(previous[0..len], self.filter.items);
    self.showSessions();
    self.filter.appendSlice(self.window.app.core_app.alloc, previous[0..len]) catch {};
    self.refilter();
    for (self.matches.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, self.sessions[entry].name, selected_id[0..id_len])) continue;
        self.moveSelection(@intCast(i));
        break;
    }
}

pub fn renameSession(self: *CommandPalette, id: []const u8) void {
    if (self.mode != .sessions) return;
    const position = for (self.matches.items, 0..) |index, position| {
        if (std.mem.eql(u8, self.sessions[index].name, id)) break position;
    } else return;
    const alloc = self.window.app.core_app.alloc;
    const copy = alloc.dupe(u8, id) catch return;
    if (self.rename_id) |old| alloc.free(old);
    self.rename_id = copy;
    self.moveSelection(@as(i32, @intCast(position)) - @as(i32, @intCast(self.selected)));
    const entry = self.sessions[self.matches.items[position]];
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, if (entry.label.len > 0) entry.label else entry.name) catch return;
    defer alloc.free(wide);
    self.rename_text.clearRetainingCapacity();
    self.rename_text.appendSlice(alloc, wide) catch return;
    self.mode = .rename_session;
    self.error_text = null;
    self.rename_fresh = true;
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn cancelRename(self: *CommandPalette) void {
    self.mode = .sessions;
    self.error_text = null;
    self.rename_text.clearRetainingCapacity();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn editText(self: *CommandPalette) *std.ArrayList(u16) {
    return if (self.isEditing()) &self.rename_text else &self.filter;
}

fn saveSessionName(self: *CommandPalette) void {
    var buffer: [512]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buffer, self.rename_text.items) catch 0;
    const name = std.mem.trim(u8, buffer[0..n], " \t\r\n");
    if (!@import("../../mux/protocol.zig").validLabel(name)) {
        self.error_text = "Use 1–128 UTF-8 bytes without control characters.";
        _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
        return;
    }
    self.saveName(name) catch |err| {
        log.err("session rename failed: {}", .{err});
        self.error_text = "Rename failed. Check the session is running and retry.";
        _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
        return;
    };
    self.cancelRename();
    self.refreshSessions();
    for (self.window.app.windows.items) |window| window.refreshSessionBar(true);
}

fn saveName(self: *CommandPalette, name: []const u8) !void {
    var client = try @import("../../mux/Client.zig").initControl(self.rename_id orelse return error.NoSession, null);
    defer client.deinit();
    var reply: [256]u8 = undefined;
    _ = try client.request(.rename, name, 0, &reply);
}

fn endSelectedSession(self: *CommandPalette) void {
    if (self.mode != .sessions or self.matches.items.len == 0) return;
    const window = self.window;
    const alloc = window.app.core_app.alloc;
    const entry = self.sessions[self.matches.items[self.selected]];
    const name = alloc.dupe(u8, entry.name) catch return;
    defer alloc.free(name);
    const label = alloc.dupe(u8, if (entry.label.len > 0) entry.label else entry.name) catch return;
    defer alloc.free(label);
    // Copy the selection before dismissing the palette. The window owns
    // the inline confirmation, including for detached sessions.
    self.dismiss();
    window.endSession(name, label);
}

/// Dismiss the palette and return focus to the parent window.
fn dismiss(self: *CommandPalette) void {
    const window = self.window;
    self.destroy();
    _ = winapi.SetFocus(window.hwnd);
}

/// Perform the selected entry: a core command on the focused surface,
/// or a profile spawn for the appended profile rows.
fn execute(self: *CommandPalette) void {
    const window = self.window;
    if (self.mode == .create_workspace) return self.createWorkspace();
    if (self.mode == .workspaces) {
        if (self.matches.items.len == 0) return;
        const name = self.workspaces[self.matches.items[self.selected]].name;
        const result = if (self.move_workspace) session.beginMove(window.app, self.hwnd, name) else session.beginSwitch(window.app, self.hwnd, name);
        result catch |err| {
            self.workspaceFailed(err);
            return;
        };
        self.workspaceFailed(error.WorkspaceSwitchInProgress);
        return;
    }
    if (self.mode == .rename_session) return self.saveSessionName();
    if (self.mode == .sessions) {
        if (self.matches.items.len == 0) return;
        const alloc = window.app.core_app.alloc;
        const id = alloc.dupe(u8, self.sessions[self.matches.items[self.selected]].name) catch return;
        defer alloc.free(id);
        self.dismiss();
        window.attachSession(id) catch |err| log.err("session attachment failed: {}", .{err});
        return;
    }
    if (self.matches.items.len == 0) return self.dismiss();
    const idx = self.matches.items[self.selected];
    const cmds = self.commands();

    if (idx >= cmds.len) {
        const pi = idx - cmds.len;
        self.dismiss();
        const list = window.app.ensureProfiles();
        if (pi < list.items.len) {
            window.requestNewTab(&list.items[pi], null) catch |err| {
                log.err("error opening profile tab err={}", .{err});
            };
        }
        return;
    }

    const action = cmds[idx].action;
    self.dismiss();
    const surface = window.activeSurface() orelse return;
    _ = surface.core_surface.performBindingAction(action) catch |err| {
        log.err("error performing palette action err={}", .{err});
    };
}

fn commands(self: *const CommandPalette) []const input.Command {
    return self.window.app.config.@"command-palette-entry".value.items;
}

/// A resolved palette row: core commands first, then one "New Tab:"
/// row per profile.
const EntryRef = struct {
    title: []const u8,
    description: []const u8,
    action: ?input.Binding.Action,
    /// Shortcut label override for profile rows (core rows resolve
    /// theirs from the keybind set).
    label: ?[]const u8,
};

fn entryCount(self: *const CommandPalette) usize {
    if (self.workspaceMode()) return self.workspaces.len;
    if (self.mode != .commands) return self.sessions.len;
    return self.commands().len +
        self.window.app.ensureProfiles().items.len;
}

fn entryAt(
    self: *const CommandPalette,
    i: usize,
    title_buf: []u8,
    label_buf: []u8,
) EntryRef {
    if (self.workspaceMode()) {
        const entry = self.workspaces[i];
        return .{ .title = entry.name, .description = "Saved workspace", .action = null, .label = std.fmt.bufPrint(label_buf, "Tabs {d} · Panes {d}{s}", .{ entry.tabs, entry.panes, if (std.mem.eql(u8, entry.name, self.window.app.workspace_name orelse "default")) " · Active" else "" }) catch "" };
    }
    if (self.mode != .commands) {
        const entry = self.sessions[i];
        return .{
            .title = if (entry.label.len > 0) entry.label else entry.name,
            .description = std.fmt.bufPrint(title_buf, "PID {d} · {s}{s}", .{ entry.shell_pid, entry.name, if (std.mem.eql(u8, entry.version, @import("../../build_config.zig").version_string)) "" else " · Different build" }) catch entry.name,
            .action = null,
            .label = null,
        };
    }
    const cmds = self.commands();
    if (i < cmds.len) return .{
        .title = cmds[i].title,
        .description = cmds[i].description,
        .action = cmds[i].action,
        .label = null,
    };
    const list = self.window.app.ensureProfiles();
    const pi = i - cmds.len;
    const p = &list.items[pi];
    return .{
        .title = std.fmt.bufPrint(title_buf, "New Tab: {s}", .{p.name}) catch
            p.name,
        .description = p.hint,
        .action = null,
        .label = if (pi < 9)
            std.fmt.bufPrint(label_buf, "ctrl+shift+{d}", .{pi + 1}) catch null
        else
            null,
    };
}

/// The keybinding bound to `action`, formatted (e.g. "ctrl+shift+p"),
/// or null if unbound. Uses the config's reverse action→trigger map.
fn keybindLabel(
    self: *const CommandPalette,
    action: input.Binding.Action,
    buf: []u8,
) ?[]const u8 {
    const trigger = self.window.app.config.keybind.set.reverse.get(action) orelse
        return null;
    return std.fmt.bufPrint(buf, "{f}", .{trigger}) catch null;
}

/// Recompute matches for the current filter (case-insensitive substring
/// of the title or description) and fit the popup to them.
/// Paste clipboard text into the filter at the cap, then re-filter.
fn paste(self: *CommandPalette) void {
    const edit = self.editText();
    const alloc = self.window.app.core_app.alloc;
    if (self.isEditing() and self.rename_fresh) {
        edit.clearRetainingCapacity();
        self.rename_fresh = false;
    }
    var buf: [filter_max_units]u16 = undefined;
    const room = filter_max_units -| edit.items.len;
    if (room == 0) return;
    const n = winapi.clipboardTextUtf16(self.hwnd, buf[0..@min(room, buf.len)]);
    if (n == 0) return;
    edit.appendSlice(alloc, buf[0..n]) catch return;
    self.refilter();
}

/// Fuzzy subsequence score of `needle` within `haystack` (ASCII
/// case-insensitive). null if not a subsequence at all. Higher is
/// better: bonuses for consecutive matches and matches at word starts,
/// so "nt" ranks "New Tab" above an incidental "n...t..." match.
fn fuzzyScore(needle: []const u8, haystack: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    var score: i32 = 0;
    var ni: usize = 0;
    var prev_match = false;
    var prev_char: u8 = ' ';
    for (haystack) |hc| {
        if (ni >= needle.len) break;
        if (std.ascii.toLower(needle[ni]) == std.ascii.toLower(hc)) {
            score += 1;
            if (prev_match) score += 3;
            if (prev_char == ' ' or prev_char == '-' or
                prev_char == '_' or prev_char == ':') score += 6;
            ni += 1;
            prev_match = true;
        } else prev_match = false;
        prev_char = hc;
    }
    if (ni < needle.len) return null;
    // Slight preference for tighter (shorter) matches.
    return score - @as(i32, @intCast(@min(haystack.len / 4, 16)));
}

const Scored = struct { i: usize, score: i32 };

fn scoreLessThan(_: void, a: Scored, b: Scored) bool {
    // Higher score first; stable by original index on ties.
    if (a.score != b.score) return a.score > b.score;
    return a.i < b.i;
}

pub fn profilesChanged(self: *CommandPalette) void {
    const selected_entry: ?usize = if (self.selected < self.matches.items.len)
        self.matches.items[self.selected]
    else
        null;
    self.refilter();
    if (selected_entry) |entry| {
        for (self.matches.items, 0..) |candidate, i| {
            if (candidate != entry) continue;
            self.selected = i;
            self.scroll = i -| (self.visibleRows() -| 1);
            break;
        }
    }
}

fn refilter(self: *CommandPalette) void {
    if (self.isEditing()) {
        _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
        return;
    }
    const alloc = self.window.app.core_app.alloc;
    self.matches.clearRetainingCapacity();

    var buf: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, self.filter.items) catch 0;
    const needle = buf[0..len];

    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);

    var title_buf: [256]u8 = undefined;
    var label_buf: [32]u8 = undefined;
    for (0..self.entryCount()) |i| {
        const entry = self.entryAt(i, &title_buf, &label_buf);
        if (needle.len == 0) {
            scored.append(alloc, .{ .i = i, .score = 0 }) catch return;
            continue;
        }
        // Best of title (preferred) and description (penalized).
        var best: ?i32 = fuzzyScore(needle, entry.title);
        if (fuzzyScore(needle, entry.description)) |d| {
            const dp = d - 8;
            if (best == null or dp > best.?) best = dp;
        }
        if (best) |s| scored.append(alloc, .{ .i = i, .score = s }) catch return;
    }

    if (needle.len > 0) std.mem.sort(Scored, scored.items, {}, scoreLessThan);
    for (scored.items) |s| self.matches.append(alloc, s.i) catch return;

    self.selected = 0;
    self.scroll = 0;
    self.layout();
    self.selectPreview();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

fn rowHeight(self: *const CommandPalette) i32 {
    return self.window.scale(if (self.mode != .commands) @as(i32, 24) else row_height_logical);
}

fn listWidth(self: *const CommandPalette, width: i32) i32 {
    if (self.workspaceMode()) return width;
    return if (self.embedded and self.mode != .commands and width >= self.window.scale(600)) @divTrunc(width * 2, 5) else width;
}

fn selectPreview(self: *CommandPalette) void {
    _ = winapi.KillTimer(self.hwnd, 1);
    const preview = self.preview orelse return;
    const id = if ((self.mode == .sessions or self.mode == .rename_session) and self.selected < self.matches.items.len)
        self.sessions[self.matches.items[self.selected]].name
    else
        "";
    preview.select(id);
    if (id.len > 0) _ = winapi.SetTimer(self.hwnd, 1, 120, null);
}

fn visibleRows(self: *const CommandPalette) usize {
    if (self.embedded) {
        var client: winapi.RECT = undefined;
        _ = winapi.GetClientRect(self.window.hwnd, &client);
        const room = client.bottom - self.window.titlebarHeight() - self.window.sessionBarHeight() - self.window.scale(input_height_logical + 30);
        const rows: usize = @intCast(@max(1, @divTrunc(room, self.rowHeight())));
        return @min(self.matches.items.len, rows);
    }
    return @min(self.matches.items.len, max_visible_rows);
}

/// Size and position the popup over the parent: centered horizontally,
/// just below the title strip, shrinking with the match count.
pub fn layout(self: *CommandPalette) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(window.hwnd, &client);
    if (self.embedded) {
        const top = window.titlebarHeight();
        _ = winapi.SetWindowPos(self.hwnd, null, 0, top, @max(1, client.right), @max(1, client.bottom - top - window.sessionBarHeight()), winapi.SWP_NOACTIVATE);
        if (self.matches.items.len > 0) {
            self.scroll = @min(self.scroll, self.selected);
            if (self.selected >= self.scroll + self.visibleRows()) self.scroll = self.selected - self.visibleRows() + 1;
        }
        _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
        return;
    }
    var origin: winapi.POINT = .{ .x = 0, .y = 0 };
    _ = winapi.ClientToScreen(window.hwnd, &origin);

    const client_w = client.right - client.left;
    const w = @min(window.scale(width_logical), client_w - window.scale(40));
    const h = window.scale(input_height_logical) + (if (self.mode == .commands) @as(i32, 0) else window.scale(30)) +
        @as(i32, @intCast(self.visibleRows())) * self.rowHeight();

    _ = winapi.SetWindowPos(
        self.hwnd,
        null,
        origin.x + @divTrunc(client_w - w, 2),
        origin.y + window.titlebarHeight() + window.scale(4),
        w,
        h,
        winapi.SWP_NOZORDER | winapi.SWP_NOACTIVATE,
    );
}

/// Move the highlight, keeping it visible.
fn moveSelection(self: *CommandPalette, delta: i32) void {
    if (self.isEditing()) return;
    const count = self.matches.items.len;
    if (count == 0) return;
    const max: i32 = @intCast(count - 1);
    self.selected = @intCast(std.math.clamp(
        @as(i32, @intCast(self.selected)) + delta,
        0,
        max,
    ));
    if (self.selected < self.scroll) self.scroll = self.selected;
    const visible = self.visibleRows();
    if (self.selected >= self.scroll + visible)
        self.scroll = self.selected - visible + 1;
    self.selectPreview();
    _ = winapi.InvalidateRect(self.hwnd, null, winapi.FALSE);
}

/// The match row at a client y, if any.
fn rowAt(self: *const CommandPalette, x: i32, y: i32) ?usize {
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);
    if (x < 0 or x >= self.listWidth(client.right)) return null;
    const top = self.window.scale(input_height_logical);
    if (y < top) return null;
    if (y >= top + @as(i32, @intCast(self.visibleRows())) * self.rowHeight()) return null;
    const row = self.scroll +
        @as(usize, @intCast(@divTrunc(y - top, self.rowHeight())));
    if (row >= self.matches.items.len) return null;
    return row;
}

// ---------------------------------------------------------------------
// Painting

/// (Re)create the cached title/description fonts for the current DPI.
fn ensureFonts(self: *CommandPalette) void {
    const dpi = winapi.GetDpiForWindow(self.hwnd);
    if (self.font_dpi == dpi and self.font_title != null) return;
    if (self.font_title) |f| _ = winapi.DeleteObject(f);
    if (self.font_desc) |f| _ = winapi.DeleteObject(f);
    const face = if (self.embedded) std.unicode.utf8ToUtf16LeStringLiteral("Consolas") else std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.font_title = winapi.CreateFontW(-self.window.scale(13), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_desc = winapi.CreateFontW(-self.window.scale(10), 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, face);
    self.font_dpi = dpi;
}

fn paint(self: *CommandPalette, hdc: winapi.HDC) void {
    const window = self.window;
    var client: winapi.RECT = undefined;
    _ = winapi.GetClientRect(self.hwnd, &client);

    const light = window.isLight();
    const terminal_bg = window.app.config.background;
    const terminal_fg = window.app.config.foreground;
    const bg: u32 = if (self.embedded) @as(u32, terminal_bg.b) << 16 | @as(u32, terminal_bg.g) << 8 | terminal_bg.r else if (light) 0x00F5F5F5 else 0x001F1F1F;
    const fg: u32 = if (self.embedded) @as(u32, terminal_fg.b) << 16 | @as(u32, terminal_fg.g) << 8 | terminal_fg.r else if (light) 0x00000000 else 0x00FFFFFF;
    const select_bg: u32 = if (self.embedded) fg else if (light) 0x00DDDDDD else 0x00383838;
    const border: u32 = if (light) 0x00B0B0B0 else 0x00484848;
    const fg_dim: u32 = if (self.embedded) fg else if (light) 0x00505050 else 0x00A0A0A0;

    const bg_brush = winapi.CreateSolidBrush(bg) orelse return;
    defer _ = winapi.DeleteObject(bg_brush);
    _ = winapi.FillRect(hdc, &client, bg_brush);

    _ = winapi.SetBkMode(hdc, winapi.TRANSPARENT_BK);

    self.ensureFonts();
    const title_font = self.font_title;
    const desc_font = self.font_desc;

    const margin = window.scale(12);
    const input_h = window.scale(input_height_logical);
    const row_h = self.rowHeight();

    // Filter row: typed text (with a caret block) or a placeholder.
    if (title_font) |f| {
        const old = winapi.SelectObject(hdc, f);
        defer if (old) |o| {
            _ = winapi.SelectObject(hdc, o);
        };

        var text_rect: winapi.RECT = .{
            .left = margin,
            .top = 0,
            .right = client.right - margin,
            .bottom = input_h,
        };
        const header_text = if (self.mode == .create_workspace) self.rename_text.items else self.filter.items;
        if (header_text.len > 0) {
            _ = winapi.SetTextColor(hdc, fg);
            var buf: [512:0]u16 = undefined;
            const n = @min(header_text.len, buf.len - 1);
            @memcpy(buf[0..n], header_text[0..n]);
            buf[n] = 0;
            _ = winapi.DrawTextW(
                hdc,
                buf[0..n :0],
                @intCast(n),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );

            // Caret after the text.
            var extent: winapi.SIZE = undefined;
            if (self.mode != .rename_session and winapi.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &extent) != 0) {
                var caret: winapi.RECT = .{
                    .left = margin + extent.cx + window.scale(1),
                    .top = @divTrunc(input_h - extent.cy, 2),
                    .right = margin + extent.cx + window.scale(3),
                    .bottom = @divTrunc(input_h + extent.cy, 2),
                };
                if (winapi.CreateSolidBrush(fg)) |b| {
                    defer _ = winapi.DeleteObject(b);
                    _ = winapi.FillRect(hdc, &caret, b);
                }
            }
        } else {
            _ = winapi.SetTextColor(hdc, fg_dim);
            const placeholder = switch (self.mode) {
                .commands => std.unicode.utf8ToUtf16LeStringLiteral("Type a command\u{2026}"),
                .sessions, .rename_session => std.unicode.utf8ToUtf16LeStringLiteral("Search sessions\u{2026}"),
                .workspaces => if (self.move_workspace) std.unicode.utf8ToUtf16LeStringLiteral("Move tab to workspace\u{2026}") else std.unicode.utf8ToUtf16LeStringLiteral("Search workspaces\u{2026}"),
                .create_workspace => std.unicode.utf8ToUtf16LeStringLiteral("New workspace name"),
            };
            _ = winapi.DrawTextW(
                hdc,
                placeholder,
                @intCast(placeholder.len),
                &text_rect,
                winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE,
            );
        }
    }

    // Separator under the filter row.
    {
        var sep: winapi.RECT = .{
            .left = 0,
            .top = input_h - 1,
            .right = client.right,
            .bottom = input_h,
        };
        const sep_brush = winapi.CreateSolidBrush(border);
        if (sep_brush) |b| {
            defer _ = winapi.DeleteObject(b);
            _ = winapi.FillRect(hdc, &sep, b);
        }
    }

    const list_width = self.listWidth(client.right);
    // Match rows: commands retain descriptions; sessions use a single line.
    const end = @min(self.scroll + self.visibleRows(), self.matches.items.len);
    for (self.matches.items[self.scroll..end], self.scroll..) |cmd_idx, row| {
        const row_fg = if (self.embedded and row == self.selected) bg else fg;
        const row_dim = if (self.embedded and row == self.selected) bg else fg_dim;
        var title_buf: [256]u8 = undefined;
        var label_buf: [32]u8 = undefined;
        const cmd = self.entryAt(cmd_idx, &title_buf, &label_buf);
        const top = input_h + @as(i32, @intCast(row - self.scroll)) * row_h;

        if (row == self.selected) {
            var row_rect: winapi.RECT = .{
                .left = 0,
                .top = top,
                .right = list_width,
                .bottom = top + row_h,
            };
            const brush = winapi.CreateSolidBrush(select_bg);
            if (brush) |b| {
                defer _ = winapi.DeleteObject(b);
                _ = winapi.FillRect(hdc, &row_rect, b);
            }
        }

        if (self.mode != .commands) {
            const old = if (title_font) |f| winapi.SelectObject(hdc, f) else null;
            defer if (old) |f| {
                _ = winapi.SelectObject(hdc, f);
            };
            _ = winapi.SetTextColor(hdc, row_fg);
            var wide: [512]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&wide, Window.utf8Capped(cmd.title, wide.len - 1)) catch 0;
            var rect: winapi.RECT = .{ .left = margin, .top = top, .right = list_width - margin - window.scale(if (self.workspaceMode()) @as(i32, 250) else 100), .bottom = top + row_h };
            wide[n] = 0;
            if (self.mode == .rename_session and row == self.selected) {
                const count = @min(self.rename_text.items.len, wide.len - 1);
                @memcpy(wide[0..count], self.rename_text.items[0..count]);
                wide[count] = 0;
                const edit_bg = if (self.rename_fresh) fg else bg;
                const edit_fg = if (self.rename_fresh) bg else fg;
                if (winapi.CreateSolidBrush(edit_bg)) |brush| {
                    defer _ = winapi.DeleteObject(brush);
                    _ = winapi.FillRect(hdc, &rect, brush);
                }
                _ = winapi.SetTextColor(hdc, edit_fg);
                _ = winapi.DrawTextW(hdc, wide[0..count :0], @intCast(count), &rect, winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE | winapi.DT_NOPREFIX);
                var extent: winapi.SIZE = .{ .cx = 0, .cy = window.scale(13) };
                _ = winapi.GetTextExtentPoint32W(hdc, &wide, @intCast(count), &extent);
                const caret_x = @min(rect.right - window.scale(2), rect.left + extent.cx);
                var caret: winapi.RECT = .{ .left = caret_x, .right = caret_x + window.scale(2), .top = top + window.scale(4), .bottom = top + row_h - window.scale(4) };
                if (winapi.CreateSolidBrush(edit_fg)) |brush| {
                    defer _ = winapi.DeleteObject(brush);
                    _ = winapi.FrameRect(hdc, &rect, brush);
                    if (!self.rename_fresh) _ = winapi.FillRect(hdc, &caret, brush);
                }
                _ = winapi.SetTextColor(hdc, row_fg);
            } else {
                _ = winapi.DrawTextW(hdc, wide[0..n :0], @intCast(n), &rect, winapi.DT_LEFT | winapi.DT_VCENTER | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS | winapi.DT_NOPREFIX);
            }
            var pid_buf: [32]u8 = undefined;
            const pid = if (self.workspaceMode()) cmd.label orelse "" else std.fmt.bufPrint(&pid_buf, "PID {d}", .{self.sessions[cmd_idx].shell_pid}) catch "";
            const pn = std.unicode.utf8ToUtf16Le(&wide, pid) catch 0;
            wide[pn] = 0;
            rect.left = @max(margin, rect.right);
            rect.right = list_width - margin;
            _ = winapi.DrawTextW(hdc, wide[0..pn :0], @intCast(pn), &rect, winapi.DT_RIGHT | winapi.DT_VCENTER | winapi.DT_SINGLELINE | winapi.DT_NOPREFIX);
            continue;
        }

        // The keybinding accelerator (right-aligned on the title line);
        // reserve room on the title's right so it doesn't overlap.
        var kb_buf: [64]u8 = undefined;
        const kb_label = cmd.label orelse if (cmd.action) |action|
            self.keybindLabel(action, &kb_buf)
        else
            null;
        const kb_reserve: i32 = if (kb_label != null) window.scale(120) else 0;
        const title_bottom = top + @divTrunc(row_h, 2) + window.scale(4);

        var buf: [512]u16 = undefined;
        if (title_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, row_fg);
            const n = std.unicode.utf8ToUtf16Le(
                buf[0 .. buf.len - 1],
                // Config entry titles are unbounded; cap before the
                // fixed-buffer conversion (no destination bounds check).
                Window.utf8Capped(cmd.title, buf.len - 1),
            ) catch 0;
            if (n > 0) {
                buf[n] = 0;
                var rect: winapi.RECT = .{
                    .left = margin,
                    .top = top + window.scale(4),
                    .right = client.right - margin - kb_reserve,
                    .bottom = title_bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..n :0],
                    @intCast(n),
                    &rect,
                    winapi.DT_LEFT | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
        }
        if (kb_label) |label| if (desc_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, row_dim);
            var kbuf: [128]u16 = undefined;
            const kn = std.unicode.utf8ToUtf16Le(kbuf[0 .. kbuf.len - 1], label) catch 0;
            if (kn > 0) {
                kbuf[kn] = 0;
                var rect: winapi.RECT = .{
                    .left = client.right - margin - kb_reserve,
                    .top = top + window.scale(4),
                    .right = client.right - margin,
                    .bottom = title_bottom,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    kbuf[0..kn :0],
                    @intCast(kn),
                    &rect,
                    winapi.DT_RIGHT | winapi.DT_SINGLELINE,
                );
            }
        };
        if (desc_font) |f| {
            const old = winapi.SelectObject(hdc, f);
            defer if (old) |o| {
                _ = winapi.SelectObject(hdc, o);
            };
            _ = winapi.SetTextColor(hdc, row_dim);
            const n = std.unicode.utf8ToUtf16Le(
                buf[0 .. buf.len - 1],
                Window.utf8Capped(cmd.description, buf.len - 1),
            ) catch 0;
            if (n > 0) {
                buf[n] = 0;
                var rect: winapi.RECT = .{
                    .left = margin,
                    .top = top + @divTrunc(row_h, 2) + window.scale(2),
                    .right = client.right - margin,
                    .bottom = top + row_h,
                };
                _ = winapi.DrawTextW(
                    hdc,
                    buf[0..n :0],
                    @intCast(n),
                    &rect,
                    winapi.DT_LEFT | winapi.DT_SINGLELINE | winapi.DT_END_ELLIPSIS,
                );
            }
        }
    }

    if (list_width < client.right and self.matches.items.len > 0) {
        var sep: winapi.RECT = .{ .left = list_width, .top = input_h, .right = list_width + 1, .bottom = client.bottom - window.scale(30) };
        if (winapi.CreateSolidBrush(border)) |brush| {
            defer _ = winapi.DeleteObject(brush);
            _ = winapi.FillRect(hdc, &sep, brush);
        }
        const old = if (title_font) |f| winapi.SelectObject(hdc, f) else null;
        defer if (old) |f| {
            _ = winapi.SelectObject(hdc, f);
        };
        _ = winapi.SetTextColor(hdc, fg);
        var heading: winapi.RECT = .{ .left = list_width + margin, .top = input_h, .right = client.right - margin, .bottom = input_h + row_h };
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Preview · F5 refresh");
        _ = winapi.DrawTextW(hdc, title, title.len, &heading, winapi.DT_SINGLELINE | winapi.DT_VCENTER | winapi.DT_NOPREFIX);
        var wide: [SessionPreview.capacity]u16 = undefined;
        const content = if (self.preview) |preview| preview.copy(wide[0 .. wide.len - 1]) else std.unicode.utf8ToUtf16LeStringLiteral("Preview unavailable.");
        // Draw physical lines independently: clip horizontally, never reflow
        // terminal output to the preview width or interpret '&' as a mnemonic.
        var lines = std.mem.splitScalar(u16, content, '\n');
        var y = heading.bottom + window.scale(8);
        const line_h = window.scale(16);
        const bottom = client.bottom - window.scale(30);
        while (lines.next()) |line| {
            if (y + line_h > bottom) break;
            var rect: winapi.RECT = .{ .left = heading.left, .top = y, .right = heading.right, .bottom = y + line_h };
            var line_buffer: [SessionPreview.capacity:0]u16 = undefined;
            @memcpy(line_buffer[0..line.len], line);
            line_buffer[line.len] = 0;
            _ = winapi.DrawTextW(hdc, line_buffer[0..line.len :0], @intCast(line.len), &rect, winapi.DT_SINGLELINE | winapi.DT_NOPREFIX);
            y += line_h;
        }
    }

    if (self.mode != .commands) {
        const hint = self.error_text orelse if (self.mode == .create_workspace)
            "Move current tab to workspace · Enter save · Esc cancel"
        else if (self.mode == .workspaces and self.move_workspace)
            "Enter move tab · F5 refresh · Esc cancel"
        else if (self.mode == .workspaces)
            "Enter switch · F2 workspace from tab · F5 refresh · F6 sessions · Esc close"
        else if (self.mode == .rename_session)
            "Rename session · Enter save · Esc cancel"
        else if (self.matches.items.len == 0)
            "No matching sessions · F5 refresh"
        else
            "Enter switch · F2 rename · Del end · F5 refresh · F6 workspaces · Esc close";
        var wide: [256]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, hint) catch 0;
        var rect: winapi.RECT = .{ .left = margin, .top = client.bottom - window.scale(30), .right = client.right - margin, .bottom = client.bottom };
        const old_font = if (desc_font) |font| winapi.SelectObject(hdc, font) else null;
        defer if (old_font) |font| {
            _ = winapi.SelectObject(hdc, font);
        };
        _ = winapi.SetTextColor(hdc, fg_dim);
        wide[n] = 0;
        _ = winapi.DrawTextW(hdc, wide[0..n :0], @intCast(n), &rect, winapi.DT_LEFT | winapi.DT_SINGLELINE | winapi.DT_VCENTER | winapi.DT_END_ELLIPSIS);
    }

    // Border.
    if (!self.embedded) if (winapi.CreateSolidBrush(border)) |b| {
        defer _ = winapi.DeleteObject(b);
        _ = winapi.FrameRect(hdc, &client, b);
    };
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
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        WorkspaceJob.ready_message => {
            if (self.workspace_listing) |job| {
                if (!self.workspace_loaded and job.done.load(.acquire)) {
                    if (job.thread) |thread| thread.join();
                    job.thread = null;
                    self.workspace_loaded = true;
                    if (job.failure) |err| self.workspaceFailed(err) else {
                        self.workspaces = job.entries orelse &.{};
                        if (self.mode != .create_workspace) self.error_text = null;
                    }
                    if (self.mode == .create_workspace) {
                        self.mode = .workspaces;
                        self.refilter();
                        self.mode = .create_workspace;
                    } else self.refilter();
                }
            }
            return 0;
        },
        winapi.WM_TIMER => {
            if (wparam == 1) {
                _ = winapi.KillTimer(hwnd, 1);
                if (self.preview) |preview| preview.request();
            }
            return 0;
        },
        SessionPreview.ready_message => {
            _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            return 0;
        },
        winapi.WM_ERASEBKGND => return 1,

        winapi.WM_PAINT => {
            var ps: winapi.PAINTSTRUCT = undefined;
            if (winapi.BeginPaint(hwnd, &ps)) |hdc| {
                self.paint(hdc);
                _ = winapi.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        winapi.WM_KEYDOWN => {
            // Once submitted, keep the displayed name aligned with the job.
            // Escape cancels preparation; no confirmation key reaches a shell.
            if (self.mode == .create_workspace and self.window.app.workspace_job != null and wparam != winapi.VK_ESCAPE) return 0;
            switch (@as(u8, @truncate(wparam))) {
                winapi.VK_ESCAPE => if (self.mode == .create_workspace) self.cancelCreate() else if (self.mode == .rename_session) self.cancelRename() else self.dismiss(),
                winapi.VK_RETURN => self.execute(),
                winapi.VK_UP => self.moveSelection(-1),
                winapi.VK_DOWN => self.moveSelection(1),
                'N' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) self.moveSelection(1),
                'P' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) self.moveSelection(-1),
                'A' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) {
                    if (self.isEditing()) {
                        self.rename_fresh = true;
                    } else self.filter.clearRetainingCapacity();
                    self.refilter();
                },
                winapi.VK_F1 + 1 => if (self.mode == .sessions and self.matches.items.len > 0) self.renameSession(self.sessions[self.matches.items[self.selected]].name) else if (self.mode == .workspaces and !self.move_workspace) self.newWorkspace(),
                winapi.VK_F1 + 4 => if (self.mode == .sessions) self.refreshSessions() else if (self.mode == .workspaces) {
                    const moving = self.move_workspace;
                    self.showWorkspaces();
                    self.move_workspace = moving;
                },
                winapi.VK_F1 + 5 => if (self.mode == .sessions) self.showWorkspaces() else if (self.mode == .workspaces) {
                    session.cancelSwitch(self.window.app);
                    self.showSessions();
                },
                winapi.VK_DELETE => self.endSelectedSession(),
                winapi.VK_PRIOR => self.moveSelection(
                    -@as(i32, @intCast(@max(1, self.visibleRows()))),
                ),
                winapi.VK_NEXT => self.moveSelection(
                    @as(i32, @intCast(@max(1, self.visibleRows()))),
                ),
                // Ctrl+V pastes clipboard text into the filter.
                'V' => if (winapi.GetKeyState(winapi.VK_CONTROL) < 0) self.paste(),
                else => {},
            }
            return 0;
        },

        winapi.WM_CHAR => {
            if (self.mode == .create_workspace and self.window.app.workspace_job != null) return 0;
            const edit = self.editText();
            const alloc = self.window.app.core_app.alloc;
            const ch: u16 = @truncate(wparam);
            if ((ch == 0x08 or (ch >= 0x20 and ch != 0x7f)) and self.isEditing() and self.rename_fresh) {
                edit.clearRetainingCapacity();
                self.rename_fresh = false;
            }
            if (ch == 0x08) {
                // Backspace: drop one codepoint (both surrogate halves).
                if (edit.pop()) |unit| {
                    if (unit >= 0xDC00 and unit <= 0xDFFF) _ = edit.pop();
                    self.refilter();
                }
            } else if (ch >= 0x20 and ch != 0x7F) {
                // Enforce the fixed-buffer cap; a surrogate lead needs
                // room for its trail too (a trail always pairs with an
                // admitted lead, so it is never refused alone).
                const lead = ch >= 0xD800 and ch <= 0xDBFF;
                const trail = ch >= 0xDC00 and ch <= 0xDFFF;
                const need: usize = if (lead) 2 else 1;
                if (!trail and edit.items.len + need > filter_max_units)
                    return 0;
                edit.append(alloc, ch) catch return 0;
                self.refilter();
            }
            return 0;
        },

        winapi.WM_MOUSEMOVE => {
            if (self.isEditing()) return 0;
            if (self.rowAt(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))), lparamY(lparam))) |row| {
                if (row != self.selected) {
                    self.selected = row;
                    self.selectPreview();
                    _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
                }
            }
            return 0;
        },

        winapi.WM_LBUTTONDOWN => {
            if (self.isEditing()) return 0;
            if (self.rowAt(@as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))), lparamY(lparam))) |row| {
                self.selected = row;
                self.execute();
            }
            return 0;
        },

        winapi.WM_MOUSEWHEEL => {
            if (self.isEditing()) return 0;
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const rows: i32 = if (delta > 0) -3 else 3;
            const count = self.matches.items.len;
            const visible = self.visibleRows();
            if (count > visible) {
                const max_scroll: i32 = @intCast(count - visible);
                self.scroll = @intCast(std.math.clamp(
                    @as(i32, @intCast(self.scroll)) + rows,
                    0,
                    max_scroll,
                ));
                self.selected = std.math.clamp(
                    self.selected,
                    self.scroll,
                    self.scroll + visible - 1,
                );
                self.selectPreview();
                _ = winapi.InvalidateRect(hwnd, null, winapi.FALSE);
            }
            return 0;
        },

        winapi.WM_KILLFOCUS => {
            if (!self.embedded) self.destroy();
            return 0;
        },

        else => return winapi.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn lparamY(lparam: winapi.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}
