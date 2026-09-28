//! Saved workspace discovery. These entries describe layouts, not live brokers.
//! Companion name files preserve compatibility with the version 2 layout format.
const std = @import("std");
const workspace = @import("Workspace.zig");

pub const Entry = struct {
    name: []const u8,
    windows: usize,
    tabs: usize,
    panes: usize,
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 4096 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

/// Preserve the existing on-disk identity exactly; names never become paths.
pub fn filename(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "default")) return alloc.dupe(u8, "session");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    return std.fmt.allocPrint(alloc, "workspace-{x}", .{digest});
}

pub fn deinit(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| alloc.free(entry.name);
    alloc.free(entries);
}

/// Run on a worker: directory enumeration and layout reads may block.
/// All returned storage belongs to alloc. Malformed or missing layouts are skipped.
pub fn list(io: std.Io, alloc: std.mem.Allocator, directory: []const u8) ![]Entry {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(Entry, 0),
        else => return err,
    };
    defer dir.close(io);
    var result: std.ArrayList(Entry) = .empty;
    errdefer {
        for (result.items) |entry| alloc.free(entry.name);
        result.deinit(alloc);
    }
    var iterator = dir.iterate();
    var scanned: usize = 0;
    while (try iterator.next(io)) |file| {
        scanned += 1;
        if (scanned > 1024 or result.items.len >= 128) break;
        if (file.kind != .file) continue;
        const is_default = std.mem.eql(u8, file.name, "session");
        if (!is_default and (!std.mem.startsWith(u8, file.name, "workspace-") or
            file.name.len != 10 + 64 + 5 or !std.mem.endsWith(u8, file.name, ".name"))) continue;
        const name = if (is_default) try alloc.dupe(u8, "default") else dir.readFileAlloc(io, file.name, alloc, .limited(4096)) catch continue;
        defer alloc.free(name);
        if (!validName(name) or (!is_default and std.mem.eql(u8, name, "default"))) continue;
        const expected = try filename(alloc, name);
        defer alloc.free(expected);
        const layout_file = if (is_default) file.name else file.name[0 .. file.name.len - 5];
        if (!std.mem.eql(u8, expected, layout_file)) continue;
        const data = dir.readFileAlloc(io, layout_file, alloc, .limited(1024 * 1024)) catch continue;
        defer alloc.free(data);
        const parsed = std.json.parseFromSlice(workspace.State, alloc, data, .{}) catch continue;
        defer parsed.deinit();
        workspace.validate(parsed.value) catch continue;
        var entry: Entry = .{ .name = undefined, .windows = parsed.value.windows.len, .tabs = 0, .panes = 0 };
        for (parsed.value.windows) |window| {
            entry.tabs += window.tabs.len;
            for (window.tabs) |tab| {
                for (tab.nodes) |node| {
                    if (node == .leaf) entry.panes += 1;
                }
            }
        }
        entry.name = try alloc.dupe(u8, name);
        errdefer alloc.free(entry.name);
        try result.append(alloc, entry);
    }
    std.mem.sort(Entry, result.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return result.toOwnedSlice(alloc);
}

test "mux workspace catalog validates identity and skips missing and malformed layouts" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const layout = "{\"version\":2,\"windows\":[]}";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "session", .data = layout });
    const file = try filename(t.allocator, "Project A");
    defer t.allocator.free(file);
    const metadata = try std.fmt.allocPrint(t.allocator, "{s}.name", .{file});
    defer t.allocator.free(metadata);
    try tmp.dir.writeFile(t.io, .{ .sub_path = file, .data = layout });
    try tmp.dir.writeFile(t.io, .{ .sub_path = metadata, .data = "Project A" });
    {
        const entries = try list(t.io, t.allocator, root);
        defer deinit(t.allocator, entries);
        try t.expectEqual(@as(usize, 2), entries.len);
        try t.expectEqualStrings("Project A", entries[0].name);
        try t.expectEqual(@as(usize, 0), entries[0].panes);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = metadata, .data = "Other project" });
    {
        const entries = try list(t.io, t.allocator, root);
        defer deinit(t.allocator, entries);
        try t.expectEqual(@as(usize, 1), entries.len);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = metadata, .data = "Project A" });
    // At this point both layouts exist; remove the named one to exercise a
    // companion file left behind after layout removal.
    try tmp.dir.deleteFile(t.io, file);
    {
        const entries = try list(t.io, t.allocator, root);
        defer deinit(t.allocator, entries);
        try t.expectEqual(@as(usize, 1), entries.len);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = file, .data = "{" });
    const entries = try list(t.io, t.allocator, root);
    defer deinit(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expect(!validName("bad\nname"));
    try t.expect(!validName("\xff"));
}

test "mux workspace catalog counts saved panes without claiming live sessions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const nodes = [_]workspace.Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session = "shell-one" } },
        .{ .leaf = .{} },
    };
    const tabs = [_]workspace.Tab{.{ .nodes = &nodes, .focused = 1 }};
    const windows = [_]workspace.Window{.{ .tabs = &tabs, .active = 0 }};
    const data = try std.json.Stringify.valueAlloc(t.allocator, workspace.State{ .windows = &windows }, .{});
    defer t.allocator.free(data);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "session", .data = data });
    const entries = try list(t.io, t.allocator, root);
    defer deinit(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expectEqual(@as(usize, 1), entries[0].windows);
    try t.expectEqual(@as(usize, 1), entries[0].tabs);
    try t.expectEqual(@as(usize, 2), entries[0].panes);
}
