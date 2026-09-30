//! Resolve asynchronous split destinations against the current UI-owned trees.
//! A surface identity survives tree rebuilds and tab reorder; an array index,
//! SplitTree handle or raw pointer does not safely describe a pending request.
const std = @import("std");

pub const Location = struct { tab: usize, node: usize };

/// Generic only so this ownership rule can be tested without a Windows GUI.
/// Call from the UI thread; workers never inspect the tabs or their surfaces.
pub fn find(tabs: anytype, surface_id: u64) ?Location {
    for (tabs, 0..) |tab, tab_index| {
        for (tab.tree.nodes, 0..) |node, node_index| switch (node) {
            .split => {},
            .leaf => |surface| {
                if (surface.core_surface.id == surface_id and !surface.should_close)
                    return .{ .tab = tab_index, .node = node_index };
            },
        };
    }
    return null;
}

const Pane = struct { core_surface: struct { id: u64 }, should_close: bool = false };
const Node = union(enum) { split, leaf: *Pane };
const Tab = struct { tree: struct { nodes: []const Node } };

test "split target follows identity through tree rebuild and tab reorder" {
    const t = std.testing;
    var first: Pane = .{ .core_surface = .{ .id = 10 } };
    var second: Pane = .{ .core_surface = .{ .id = 20 } };
    var inserted: Pane = .{ .core_surface = .{ .id = 30 } };
    const original = [_]Node{.{ .leaf = &first }};
    const other = [_]Node{.{ .leaf = &second }};
    var tabs = [_]Tab{ .{ .tree = .{ .nodes = &original } }, .{ .tree = .{ .nodes = &other } } };
    try t.expectEqual(Location{ .tab = 0, .node = 0 }, find(&tabs, 10).?);
    const rebuilt = [_]Node{ .split, .{ .leaf = &inserted }, .{ .leaf = &first } };
    tabs[0].tree.nodes = &rebuilt;
    std.mem.swap(Tab, &tabs[0], &tabs[1]);
    try t.expectEqual(Location{ .tab = 1, .node = 2 }, find(&tabs, 10).?);
    // A second queued split must still find the original pane, not the first
    // request's newly focused surface at a different node.
    try t.expectEqual(Location{ .tab = 1, .node = 2 }, find(&tabs, 10).?);
}

test "split target rejects closing removed and replaced panes" {
    const t = std.testing;
    var pane: Pane = .{ .core_surface = .{ .id = 42 } };
    const nodes = [_]Node{.{ .leaf = &pane }};
    var tabs = [_]Tab{.{ .tree = .{ .nodes = &nodes } }};
    pane.should_close = true;
    try t.expect(find(&tabs, 42) == null);
    pane.should_close = false;
    // Even reuse of the same allocation cannot redirect a request once the
    // new surface has its own identity.
    pane.core_surface.id = 43;
    try t.expect(find(&tabs, 42) == null);
    tabs[0].tree.nodes = &.{};
    try t.expect(find(&tabs, 43) == null);
    try t.expect(find(tabs[0..0], 43) == null);
}

test "split target never falls back to a surviving pane or another window" {
    const t = std.testing;
    var first: Pane = .{ .core_surface = .{ .id = 1 } };
    var second: Pane = .{ .core_surface = .{ .id = 2 } };
    const first_nodes = [_]Node{.{ .leaf = &first }};
    const second_nodes = [_]Node{.{ .leaf = &second }};
    const origin = [_]Tab{.{ .tree = .{ .nodes = &first_nodes } }};
    const destination = [_]Tab{.{ .tree = .{ .nodes = &second_nodes } }};
    try t.expect(find(&origin, 2) == null);
    try t.expectEqual(Location{ .tab = 0, .node = 0 }, find(&destination, 2).?);
}
