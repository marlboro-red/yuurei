//! Preconditions for switching live workspaces without replacing shells.
const std = @import("std");
const workspace = @import("Workspace.zig");

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
