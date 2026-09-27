//! Bounded saved view layout. Live shells remain authoritative in brokers.
const std = @import("std");
const protocol = @import("protocol.zig");
pub const Pane = struct { profile: []const u8 = "", cwd: []const u8 = "", session: ?[]const u8 = null };
pub const Node = union(enum) {
    leaf: Pane,
    split: struct { layout: enum { horizontal, vertical }, ratio: f32, left: u16, right: u16 },
};
pub const Tab = struct { title: []const u8 = "", nodes: []const Node, focused: u16, zoomed: ?u16 = null };
pub const Geometry = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Window = struct { tabs: []const Tab, active: usize, geometry: ?Geometry = null };
pub const State = struct { version: u32 = 2, windows: []const Window };

pub fn validate(state: State) !void {
    if (state.version != 2 or state.windows.len > 16) return error.InvalidWorkspace;
    var pane_count: usize = 0;
    var names: [64][]const u8 = undefined;
    var name_count: usize = 0;
    for (state.windows) |window| {
        if (window.tabs.len == 0 or window.tabs.len > 64 or window.active >= window.tabs.len) return error.InvalidWorkspace;
        if (window.geometry) |g| {
            if (g.width < 200 or g.width > 16384 or g.height < 100 or g.height > 16384 or
                g.x < -100000 or g.x > 100000 or g.y < -100000 or g.y > 100000) return error.InvalidWorkspace;
        }
        for (window.tabs) |tab| {
            if (tab.title.len > 4096 or tab.nodes.len == 0 or tab.nodes.len > 127 or tab.focused >= tab.nodes.len) return error.InvalidWorkspace;
            if (tab.nodes[tab.focused] != .leaf) return error.InvalidWorkspace;
            if (tab.zoomed) |zoomed| if (zoomed >= tab.nodes.len or tab.nodes[zoomed] != .leaf) return error.InvalidWorkspace;
            var seen = [_]bool{false} ** 127;
            var pending: [127]u16 = undefined;
            var len: usize = 1;
            pending[0] = 0;
            while (len > 0) {
                len -= 1;
                const index = pending[len];
                if (index >= tab.nodes.len or seen[index]) return error.InvalidWorkspace;
                seen[index] = true;
                switch (tab.nodes[index]) {
                    .leaf => |pane| {
                        pane_count += 1;
                        if (pane_count > 64 or pane.profile.len > 4096 or pane.cwd.len > 32768) return error.InvalidWorkspace;
                        if (pane.session) |name| {
                            if (!protocol.validName(name)) return error.InvalidWorkspace;
                            for (names[0..name_count]) |existing| if (std.mem.eql(u8, name, existing)) return error.DuplicateSession;
                            names[name_count] = name;
                            name_count += 1;
                        }
                    },
                    .split => |split| {
                        if (!std.math.isFinite(split.ratio) or split.ratio <= 0 or split.ratio >= 1 or len + 2 > pending.len) return error.InvalidWorkspace;
                        pending[len] = split.left;
                        pending[len + 1] = split.right;
                        len += 2;
                    },
                }
            }
            for (seen[0..tab.nodes.len]) |visited| if (!visited) return error.InvalidWorkspace;
        }
    }
}

test "mux workspace rejects cycles orphan nodes invalid focus and duplicate sessions" {
    const t = std.testing;
    var nodes = [_]Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session = "one" } },
        .{ .leaf = .{ .session = "two" } },
    };
    var tabs = [_]Tab{.{ .nodes = &nodes, .focused = 1 }};
    const windows = [_]Window{.{ .tabs = &tabs, .active = 0 }};
    const state: State = .{ .windows = &windows };
    try validate(state);
    nodes[0].split.right = 0;
    try t.expectError(error.InvalidWorkspace, validate(state));
    nodes[0].split.right = 1;
    try t.expectError(error.InvalidWorkspace, validate(state));
    nodes[0].split.right = 2;
    nodes[2].leaf.session = "one";
    try t.expectError(error.DuplicateSession, validate(state));
    nodes[2].leaf.session = "two";
    tabs[0].focused = 0;
    try t.expectError(error.InvalidWorkspace, validate(state));
    tabs[0].focused = 1;
    nodes[0].split.ratio = std.math.nan(f32);
    try t.expectError(error.InvalidWorkspace, validate(state));
}

test "mux workspace JSON preserves split ratios focus zoom and identifiers" {
    const t = std.testing;
    const nodes = [_]Node{
        .{ .split = .{ .layout = .vertical, .ratio = 0.25, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session = "dev", .cwd = "C:\\work" } },
        .{ .leaf = .{ .session = "build" } },
    };
    const tabs = [_]Tab{.{ .title = "Project", .nodes = &nodes, .focused = 2, .zoomed = 2 }};
    const windows = [_]Window{.{ .tabs = &tabs, .active = 0 }};
    const encoded = try std.json.Stringify.valueAlloc(t.allocator, State{ .windows = &windows }, .{});
    defer t.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(State, t.allocator, encoded, .{});
    defer parsed.deinit();
    try validate(parsed.value);
    try t.expectEqual(@as(f32, 0.25), parsed.value.windows[0].tabs[0].nodes[0].split.ratio);
    try t.expectEqualStrings("dev", parsed.value.windows[0].tabs[0].nodes[1].leaf.session.?);
    try t.expectEqual(@as(?u16, 2), parsed.value.windows[0].tabs[0].zoomed);
}
