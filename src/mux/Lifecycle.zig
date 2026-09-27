//! Launch independent brokers without inheriting GUI console or job lifetime.
const std = @import("std");
const Command = @import("../Command.zig");
const Client = @import("Client.zig");
const protocol = @import("protocol.zig");
const w = @import("../apprt/win32/winapi.zig");
extern "kernel32" fn IsProcessInJob(w.HANDLE, ?w.HANDLE, *w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn start(alloc: std.mem.Allocator, name: []const u8, args: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !void {
    if (!protocol.validName(name)) return error.InvalidSessionName;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var module: [32768]u16 = undefined;
    const len = w.GetModuleFileNameW(null, &module, module.len);
    if (len == 0 or len >= module.len) return error.ExecutablePath;
    const path = try std.unicode.utf16LeToUtf8Alloc(a, module[0..len]);
    const exe = try std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse return error.ExecutablePath, "yuurei-mux.exe" });
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(a, exe);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "serve", name });
    try argv.appendSlice(a, args);
    const line = try Command.windowsCreateCommandLine(a, argv.items);
    const line_w = try std.unicode.utf8ToUtf16LeAllocZ(a, line);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const valid_cwd: ?[]const u8 = if (cwd) |value| block: {
        // Match the ordinary exec backend: shell-reported directories can be
        // stale. Invalid/missing directories must not prevent opening a tab.
        const native = if (std.mem.startsWith(u8, value, "file://"))
            @import("cwd.zig").decode(value, &cwd_buffer) orelse break :block null
        else
            value;
        var dir = std.Io.Dir.cwd().openDir(@import("../global.zig").io(), native, .{}) catch break :block null;
        dir.close(@import("../global.zig").io());
        break :block native;
    } else null;
    const cwd_w: ?[*:0]const u16 = if (valid_cwd) |value| (try std.unicode.utf8ToUtf16LeAllocZ(a, value)).ptr else null;
    const env_w = if (env) |value| try Command.createWindowsEnvBlock(a, value) else null;
    var in_job: w.BOOL = 0;
    if (IsProcessInJob(w.GetCurrentProcess(), null, &in_job) == 0) return error.JobQuery;
    // DETACHED_PROCESS + CREATE_UNICODE_ENVIRONMENT, explicitly break away
    // when necessary. Never silently inherit a kill-on-GUI-exit job.
    const flags: u32 = 0x00000008 | 0x00000400 | @as(u32, if (in_job != 0) 0x01000000 else 0);
    var si: w.STARTUPINFOW = .{};
    var pi: w.PROCESS_INFORMATION = .{};
    if (w.CreateProcessW(exe_w, line_w, null, null, 0, flags, if (env_w) |value| @ptrCast(value.ptr) else null, cwd_w, &si, &pi) == 0) {
        std.log.scoped(.mux).err("broker CreateProcessW failed: {}", .{std.os.windows.GetLastError()});
        return if (in_job != 0) error.BrokerJobBreakawayFailed else error.BrokerLaunchFailed;
    }
    _ = w.CloseHandle(pi.hThread.?);
    defer _ = w.CloseHandle(pi.hProcess.?);
    errdefer {
        _ = w.TerminateProcess(pi.hProcess.?, 1);
        _ = WaitForSingleObject(pi.hProcess.?, 3000);
    }
    const started = GetTickCount64();
    while (GetTickCount64() - started < 10000) {
        if (WaitForSingleObject(pi.hProcess.?, 10) == 0) return error.BrokerExitedDuringStartup;
        var client = Client.initControl(name, null) catch continue;
        defer client.deinit();
        if (client.server_pid != pi.dwProcessId) return error.SessionAlreadyExists;
        var buffer: [4096]u8 = undefined;
        _ = try client.request(.status, "", 0, &buffer);
        return;
    }
    return error.BrokerStartupTimeout;
}
