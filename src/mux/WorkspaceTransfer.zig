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
};

pub fn validate(record: Record) !void {
    if (!catalog.validName(record.source) or !catalog.validName(record.target) or
        std.mem.eql(u8, record.source, record.target)) return error.InvalidWorkspaceTransfer;
    if (record.source_data.len > 1024 * 1024 or (if (record.target_data) |data| data.len > 1024 * 1024 else false)) return error.WorkspaceTooLarge;
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
