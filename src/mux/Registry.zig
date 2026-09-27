//! Discovery records are hints, never authority to attach to or stop a process.
//! Validate PID creation time and installation identity before showing a record;
//! actual operations still authenticate the named-pipe peer and build version.
const std = @import("std");
const global = @import("../global.zig");
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const w = @import("../apprt/win32/winapi.zig");
const Time = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetProcessTimes(w.HANDLE, *Time, *Time, *Time, *Time) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;

pub const Entry = struct {
    name: []const u8,
    broker_pid: u32,
    shell_pid: u32,
    created: u64,
    version: []const u8,
    exited: bool = false,
};

fn creation(process: w.HANDLE) !u64 {
    var times: [4]Time = undefined;
    if (GetProcessTimes(process, &times[0], &times[1], &times[2], &times[3]) == 0) return error.ProcessTime;
    return (@as(u64, times[0].high) << 32) | times[0].low;
}

fn directory(alloc: std.mem.Allocator) ![]const u8 {
    const base = try global.environ().getAlloc(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    const identity = try transport.identity(w.GetCurrentProcess());
    const key = try std.fmt.allocPrint(alloc, "{x}", .{identity});
    defer alloc.free(key);
    return std.fs.path.join(alloc, &.{ base, "ghostty", "mux", key });
}

/// Returns the owned record path, removed by the broker on orderly shutdown.
pub fn publish(alloc: std.mem.Allocator, name: []const u8, shell_pid: u32, exited: bool) ![]const u8 {
    if (!protocol.validName(name)) return error.InvalidSessionName;
    const dir = try directory(alloc);
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(global.io(), dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, name });
    errdefer alloc.free(path);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{d}.tmp", .{ path, w.GetCurrentProcessId() });
    defer alloc.free(tmp);
    defer std.Io.Dir.deleteFileAbsolute(global.io(), tmp) catch {};
    const entry: Entry = .{
        .name = name,
        .broker_pid = w.GetCurrentProcessId(),
        .shell_pid = shell_pid,
        .created = try creation(w.GetCurrentProcess()),
        .version = @import("../build_config.zig").version_string,
        .exited = exited,
    };
    const data = try std.json.Stringify.valueAlloc(alloc, entry, .{});
    defer alloc.free(data);
    {
        const file = try std.Io.Dir.createFileAbsolute(global.io(), tmp, .{});
        defer file.close(global.io());
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(global.io(), &buffer);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }
    try std.Io.Dir.renameAbsolute(tmp, path, global.io());
    return path;
}

/// All strings and the returned slice belong to alloc (usually a UI arena).
pub fn list(alloc: std.mem.Allocator) ![]Entry {
    const path = try directory(alloc);
    defer alloc.free(path);
    var dir = std.Io.Dir.cwd().openDir(global.io(), path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(Entry, 0),
        else => return err,
    };
    defer dir.close(global.io());
    const identity = try transport.identity(w.GetCurrentProcess());
    var result: std.ArrayList(Entry) = .empty;
    errdefer {
        for (result.items) |entry| {
            alloc.free(entry.name);
            alloc.free(entry.version);
        }
        result.deinit(alloc);
    }
    var iterator = dir.iterate();
    var scanned: usize = 0;
    while (try iterator.next(global.io())) |file| {
        scanned += 1;
        if (scanned > 1024 or result.items.len >= 128) break;
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
        const data = dir.readFileAlloc(global.io(), file.name, alloc, .limited(4096)) catch continue;
        defer alloc.free(data);
        const parsed = std.json.parseFromSlice(Entry, alloc, data, .{}) catch continue;
        defer parsed.deinit();
        const entry = parsed.value;
        if (!protocol.validName(entry.name) or !std.mem.eql(u8, entry.name, file.name[0 .. file.name.len - 5])) continue;
        const process = OpenProcess(0x1000 | 0x100000, 0, entry.broker_pid) orelse continue;
        defer _ = w.CloseHandle(process);
        if (WaitForSingleObject(process, 0) == 0) continue;
        if ((creation(process) catch continue) != entry.created) continue;
        const owner = transport.identity(process) catch continue;
        if (!std.mem.eql(u8, &owner, &identity)) continue;
        const name = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(name);
        const version = try alloc.dupe(u8, entry.version);
        errdefer alloc.free(version);
        try result.append(alloc, .{ .name = name, .version = version, .created = entry.created, .broker_pid = entry.broker_pid, .shell_pid = entry.shell_pid, .exited = entry.exited });
    }
    return result.toOwnedSlice(alloc);
}
