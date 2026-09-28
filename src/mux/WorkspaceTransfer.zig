//! Recoverable two-layout updates when a live tab becomes a workspace.
//! Callers must hold both workspace locks through finish/recovery.
const std = @import("std");
const catalog = @import("WorkspaceCatalog.zig");
const Workspace = @import("Workspace.zig");

pub const Record = struct {
    source: []const u8,
    target: []const u8,
    source_data: []const u8,
    target_data: ?[]const u8,
    // Before-image retained if publishing the cancellation journal itself fails.
    can_cancel: bool = false,
    cancel_target_data: ?[]const u8 = null,
};

pub fn validate(record: Record) !void {
    if (!catalog.validName(record.source) or !catalog.validName(record.target) or
        std.mem.eql(u8, record.source, record.target)) return error.InvalidWorkspaceTransfer;
    if (record.source_data.len > 1024 * 1024 or (if (record.target_data) |data| data.len > 1024 * 1024 else false) or
        (if (record.cancel_target_data) |data| data.len > 1024 * 1024 else false)) return error.WorkspaceTooLarge;
}

/// Caller owns the source lock and has joined its cancelled transfer worker.
/// Persist the latest live layout in recovery before an ordinary save, so a
/// later recovery cannot resurrect panes closed after failed cancellation.
pub fn refreshSource(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, source: []const u8, data: []const u8) !void {
    const path = try journalPath(alloc, directory, source);
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{});
    defer parsed.deinit();
    const record = parsed.value;
    if (!std.mem.eql(u8, source, record.source)) return error.InvalidWorkspaceTransfer;
    try begin(io, alloc, directory, .{
        .source = source,
        .target = record.target,
        .source_data = data,
        .target_data = if (record.can_cancel) record.cancel_target_data else record.target_data,
    });
}

/// Call after acquiring a workspace lock. An unfinished transfer can still own
/// its other workspace, preventing recovery even though this lock is available.
pub fn requireAvailable(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, name: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > 1024) return error.WorkspaceTooLarge;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".move")) continue;
        const bytes = dir.readFileAlloc(io, entry.name, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(bytes);
        const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.source, name) or std.mem.eql(u8, parsed.value.target, name)) return error.WorkspaceRecoveryRequired;
    }
}

pub fn journalPath(alloc: std.mem.Allocator, directory: []const u8, source: []const u8) ![]const u8 {
    const file = try catalog.filename(alloc, source);
    defer alloc.free(file);
    return std.fmt.allocPrint(alloc, "{s}{s}{s}.move", .{ directory, std.fs.path.sep_str, file });
}

pub fn begin(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, record: Record) !void {
    try validate(record);
    try validateLayouts(alloc, record);
    const path = try journalPath(alloc, directory, record.source);
    defer alloc.free(path);
    const data = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(data);
    try writeAtomic(io, alloc, path, data);
}

pub fn finish(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, record: Record) !void {
    try validate(record);
    try validateLayouts(alloc, record);
    // Target first: the moved panes are never absent from both layouts.
    try put(io, alloc, directory, record.target, record.target_data);
    try put(io, alloc, directory, record.source, record.source_data);
    const journal = try journalPath(alloc, directory, record.source);
    defer alloc.free(journal);
    try std.Io.Dir.deleteFileAbsolute(io, journal);
}

fn validateLayouts(alloc: std.mem.Allocator, record: Record) !void {
    const source = try std.json.parseFromSlice(Workspace.State, alloc, record.source_data, .{});
    defer source.deinit();
    try Workspace.validate(source.value);
    if (record.target_data) |data| {
        const target = try std.json.parseFromSlice(Workspace.State, alloc, data, .{});
        defer target.deinit();
        try Workspace.validate(target.value);
    }
}

pub fn apply(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, record: Record) !void {
    try begin(io, alloc, directory, record);
    try finish(io, alloc, directory, record);
}

fn put(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, name: []const u8, data: ?[]const u8) !void {
    const file = try catalog.filename(alloc, name);
    defer alloc.free(file);
    const path = try std.fs.path.join(alloc, &.{ directory, file });
    defer alloc.free(path);
    const metadata = try std.fmt.allocPrint(alloc, "{s}.name", .{path});
    defer alloc.free(metadata);
    if (data) |value| {
        const parsed = try std.json.parseFromSlice(Workspace.State, alloc, value, .{});
        defer parsed.deinit();
        try Workspace.validate(parsed.value);
        try writeAtomic(io, alloc, path, value);
        if (!std.mem.eql(u8, name, "default")) try writeAtomic(io, alloc, metadata, name);
    } else {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| if (err != error.FileNotFound) return err;
        std.Io.Dir.deleteFileAbsolute(io, metadata) catch |err| if (err != error.FileNotFound) return err;
    }
}

pub fn writeAtomic(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    // The parent (%LOCALAPPDATA%\ghostty) may not exist yet. createDirPath
    // is idempotent (mkdir -p), so an already-present dir is fine.
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);

    // Unique per-process temp name: isolated/config-specific instances can
    // save concurrently. A shared
    // deterministic ".tmp" would let two writers interleave truncate/
    // write/rename and corrupt or cross-replace each other's snapshot;
    // per-PID names keep every writer isolated until its atomic rename.
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{d}.tmp", .{
        path,
        std.os.windows.GetCurrentProcessId(),
    });
    defer alloc.free(tmp);
    // Close the writer before replacement and remove only our temporary file on
    // failure. The previous layout must remain usable if a switch is aborted.
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp, .{ .truncate = true });
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
        try file.sync(io);
    }
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

test "mux workspace transfer recovers interrupted publication and cancellation" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const before = "{\"version\":2,\"windows\":[]}";
    const record: Record = .{ .source = "default", .target = "Project 日本", .source_data = before, .target_data = before };
    try begin(t.io, t.allocator, dir, record);
    // Emulate a process ending after only the target file was replaced.
    try put(t.io, t.allocator, dir, record.target, before);
    const journal = try journalPath(t.allocator, dir, record.source);
    defer t.allocator.free(journal);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, journal, t.allocator, .limited(8 * 1024 * 1024));
    defer t.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Record, t.allocator, bytes, .{});
    defer parsed.deinit();
    try finish(t.io, t.allocator, dir, parsed.value);
    try t.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(t.io, journal, .{}));
    try apply(t.io, t.allocator, dir, .{ .source = "default", .target = record.target, .source_data = before, .target_data = null });
    const entries = try catalog.list(t.io, t.allocator, dir);
    defer catalog.deinit(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expectEqualStrings("default", entries[0].name);
}

test "mux workspace transfer retains its journal when the source replacement fails" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    try tmp.dir.createDirPath(t.io, "session");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "session/marker", .data = "keep" });
    const layout = "{\"version\":2,\"windows\":[]}";
    const record: Record = .{ .source = "default", .target = "Project", .source_data = layout, .target_data = layout };
    var failed = false;
    apply(t.io, t.allocator, dir, record) catch {
        failed = true;
    };
    try t.expect(failed);
    const journal = try tmp.dir.readFileAlloc(t.io, "session.move", t.allocator, .limited(4096));
    defer t.allocator.free(journal);
    try t.expect(journal.len > 0);
    // Resolve the write failure and retry exactly the recorded operation.
    try tmp.dir.deleteFile(t.io, "session/marker");
    try tmp.dir.deleteDir(t.io, "session");
    try finish(t.io, t.allocator, dir, record);
    const entries = try catalog.list(t.io, t.allocator, dir);
    defer catalog.deinit(t.allocator, entries);
    try t.expectEqual(@as(usize, 2), entries.len);
}

test "mux workspace move rollback restores an existing destination" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const before = "{\"version\":2,\"windows\":[{\"tabs\":[{\"title\":\"keep\",\"nodes\":[{\"leaf\":{\"session\":\"original\"}}],\"focused\":0}],\"active\":0}]}";
    const empty = "{\"version\":2,\"windows\":[]}";
    try apply(t.io, t.allocator, dir, .{ .source = "source", .target = "target", .source_data = empty, .target_data = empty });
    try apply(t.io, t.allocator, dir, .{ .source = "source", .target = "target", .source_data = empty, .target_data = before });
    const file = try catalog.filename(t.allocator, "target");
    defer t.allocator.free(file);
    const restored = try tmp.dir.readFileAlloc(t.io, file, t.allocator, .limited(4096));
    defer t.allocator.free(restored);
    try t.expectEqualStrings(before, restored);
    const entries = try catalog.list(t.io, t.allocator, dir);
    defer catalog.deinit(t.allocator, entries);
    try t.expectEqual(@as(usize, 2), entries.len);
}

test "mux workspace failed cancellation preserves later closures and blocks both layouts" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const live = "{\"version\":2,\"windows\":[{\"tabs\":[{\"nodes\":[{\"leaf\":{\"session\":\"live\"}}],\"focused\":0}],\"active\":0}]}";
    const empty = "{\"version\":2,\"windows\":[]}";
    // A forward journal survives a failure to publish rollback. The user then
    // terminates the shell: the next save must preserve that newer empty state
    // and the original destination, not complete the forward transfer later.
    try begin(t.io, t.allocator, dir, .{
        .source = "default",
        .target = "target",
        .source_data = empty,
        .target_data = live,
        .can_cancel = true,
        .cancel_target_data = empty,
    });
    try t.expectError(error.WorkspaceRecoveryRequired, requireAvailable(t.io, t.allocator, dir, "default"));
    try t.expectError(error.WorkspaceRecoveryRequired, requireAvailable(t.io, t.allocator, dir, "target"));
    try requireAvailable(t.io, t.allocator, dir, "unrelated");
    try refreshSource(t.io, t.allocator, dir, "default", live);
    // A second save after the shell exits updates the cancellation journal too.
    try refreshSource(t.io, t.allocator, dir, "default", empty);
    const bytes = try tmp.dir.readFileAlloc(t.io, "session.move", t.allocator, .limited(8192));
    defer t.allocator.free(bytes);
    const record = try std.json.parseFromSlice(Record, t.allocator, bytes, .{});
    defer record.deinit();
    try t.expectEqualStrings(empty, record.value.source_data);
    try t.expectEqualStrings(empty, record.value.target_data.?);
    try finish(t.io, t.allocator, dir, record.value);
    try requireAvailable(t.io, t.allocator, dir, "default");
    try requireAvailable(t.io, t.allocator, dir, "target");
}
