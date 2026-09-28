//! Preconditions for switching live workspaces without replacing shells.
const std = @import("std");
const workspace = @import("Workspace.zig");

/// Append an extracted tab to the first destination window and select it.
/// New arrays belong to alloc; nested data and the empty-target result borrow inputs.
pub fn appendTab(alloc: std.mem.Allocator, target: workspace.State, selected: workspace.State) !workspace.State {
    try workspace.validate(target);
    try validate(selected, &.{});
    if (selected.windows.len != 1 or selected.windows[0].tabs.len != 1) return error.InvalidWorkspace;
    if (target.windows.len == 0) return selected;
    const windows = try alloc.dupe(workspace.Window, target.windows);
    errdefer alloc.free(windows);
    const tabs = try alloc.alloc(workspace.Tab, windows[0].tabs.len + 1);
    errdefer alloc.free(tabs);
    @memcpy(tabs[0 .. tabs.len - 1], windows[0].tabs);
    tabs[tabs.len - 1] = selected.windows[0].tabs[0];
    windows[0].tabs = tabs;
    windows[0].active = tabs.len - 1;
    const result: workspace.State = .{ .windows = windows };
    try validate(result, &.{});
    return result;
}

test "mux workspace move appends intact tabs and supports empty destinations" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const source_nodes = [_]workspace.Node{.{ .leaf = .{ .session = "source" } }};
    const target_nodes = [_]workspace.Node{.{ .leaf = .{ .session = "target" } }};
    const source_tabs = [_]workspace.Tab{.{ .title = "Source", .nodes = &source_nodes, .focused = 0, .zoomed = 0 }};
    const target_tabs = [_]workspace.Tab{.{ .title = "Target", .nodes = &target_nodes, .focused = 0 }};
    const source_windows = [_]workspace.Window{.{ .tabs = &source_tabs, .active = 0 }};
    const target_windows = [_]workspace.Window{.{ .tabs = &target_tabs, .active = 0 }};
    const source: workspace.State = .{ .windows = &source_windows };
    const result = try appendTab(arena.allocator(), .{ .windows = &target_windows }, source);
    try t.expectEqual(@as(usize, 2), result.windows[0].tabs.len);
    try t.expectEqual(@as(usize, 1), result.windows[0].active);
    try t.expectEqualStrings("Target", result.windows[0].tabs[0].title);
    try t.expectEqualStrings("Source", result.windows[0].tabs[1].title);
    try t.expectEqual(@as(?u16, 0), result.windows[0].tabs[1].zoomed);
    const empty = try appendTab(arena.allocator(), .{ .windows = &.{} }, source);
    try t.expectEqualStrings("Source", empty.windows[0].tabs[0].title);
    try t.expectError(error.DuplicateSession, appendTab(arena.allocator(), source, source));
}

/// Partition one tab without copying terminal state or duplicating shell IDs.
/// The returned arrays belong to alloc; nested tab data borrows from source.
pub fn extract(alloc: std.mem.Allocator, source: workspace.State, window_index: usize, tab_index: usize) !struct { remaining: workspace.State, selected: workspace.State } {
    try validate(source, &.{});
    if (window_index >= source.windows.len or tab_index >= source.windows[window_index].tabs.len) return error.WorkspaceChanged;
    const selected_window = source.windows[window_index];
    const selected_tabs = try alloc.dupe(workspace.Tab, selected_window.tabs[tab_index .. tab_index + 1]);
    errdefer alloc.free(selected_tabs);
    const selected = try alloc.dupe(workspace.Window, &.{.{ .tabs = selected_tabs, .active = 0, .geometry = selected_window.geometry }});
    errdefer alloc.free(selected);
    var remaining: std.ArrayList(workspace.Window) = .empty;
    errdefer remaining.deinit(alloc);
    const tabs = try alloc.alloc(workspace.Tab, selected_window.tabs.len - 1);
    errdefer alloc.free(tabs);
    @memcpy(tabs[0..tab_index], selected_window.tabs[0..tab_index]);
    @memcpy(tabs[tab_index..], selected_window.tabs[tab_index + 1 ..]);
    for (source.windows, 0..) |window, i| {
        if (i != window_index) {
            try remaining.append(alloc, window);
        } else if (tabs.len > 0) {
            const active = window.active - @as(usize, if (window.active > tab_index) 1 else 0);
            try remaining.append(alloc, .{ .tabs = tabs, .active = @min(active, tabs.len - 1), .geometry = window.geometry });
        }
    }
    return .{ .remaining = .{ .windows = try remaining.toOwnedSlice(alloc) }, .selected = .{ .windows = selected } };
}

test "mux workspace extraction keeps all selected panes and removes their source tab" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const nodes = [_]workspace.Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.4, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session = "one" } },
        .{ .leaf = .{ .session = "two" } },
    };
    const other = [_]workspace.Node{.{ .leaf = .{ .session = "other" } }};
    const tabs = [_]workspace.Tab{
        .{ .nodes = &nodes, .focused = 2, .zoomed = 2, .title = "Project" },
        .{ .nodes = &other, .focused = 0 },
    };
    const windows = [_]workspace.Window{.{ .tabs = &tabs, .active = 1 }};
    const result = try extract(arena.allocator(), .{ .windows = &windows }, 0, 0);
    try validate(result.selected, &.{"other"});
    try validate(result.remaining, &.{ "one", "two" });
    try t.expectEqual(@as(usize, 1), result.remaining.windows[0].tabs.len);
    try t.expectEqual(@as(usize, 0), result.remaining.windows[0].active);
    try t.expectEqualStrings("Project", result.selected.windows[0].tabs[0].title);
    try t.expectEqual(@as(?u16, 2), result.selected.windows[0].tabs[0].zoomed);
    const last = try extract(arena.allocator(), result.remaining, 0, 0);
    try t.expectEqual(@as(usize, 0), last.remaining.windows.len);
}

/// Current IDs are borrowed from the active view layout. Broker availability
/// still needs checking during attachment; this is deliberately not a liveness
/// check. The target's exclusive workspace lock must be held through commit.
pub fn validate(target: workspace.State, current_ids: []const []const u8) !void {
    try workspace.validate(target);
    if (target.windows.len == 0) return error.EmptyWorkspace;
    for (target.windows) |window| {
        for (window.tabs) |tab| {
            for (tab.nodes) |node| switch (node) {
                .leaf => |pane| {
                    const id = pane.session orelse return error.NonPersistentWorkspace;
                    for (current_ids) |current| {
                        if (std.mem.eql(u8, id, current)) return error.WorkspaceSessionOverlap;
                    }
                },
                .split => {},
            };
        }
    }
}

test "mux workspace switch rejects overlap local panes and empty layouts" {
    const t = std.testing;
    var nodes = [_]workspace.Node{.{ .leaf = .{ .session = "target-shell" } }};
    const tabs = [_]workspace.Tab{.{ .nodes = &nodes, .focused = 0 }};
    const windows = [_]workspace.Window{.{ .tabs = &tabs, .active = 0 }};
    const target: workspace.State = .{ .windows = &windows };
    try validate(target, &.{"current-shell"});
    try t.expectError(error.WorkspaceSessionOverlap, validate(target, &.{"target-shell"}));
    nodes[0].leaf.session = null;
    try t.expectError(error.NonPersistentWorkspace, validate(target, &.{}));
    try t.expectError(error.EmptyWorkspace, validate(.{ .windows = &.{} }, &.{}));
}
