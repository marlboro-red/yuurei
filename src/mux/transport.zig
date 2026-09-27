//! Bounded, cancellable local transport, based on the Win32 launch channel.
const std = @import("std");
const w = @import("../apprt/win32/winapi.zig");
const windows = std.os.windows;
const H = w.HANDLE;
const alloc = std.heap.c_allocator;
const Overlapped = extern struct {
    internal: usize,
    internal_high: usize,
    position: extern union { offset: extern struct { low: u32, high: u32 }, pointer: ?*anyopaque },
    hEvent: ?H,
};

extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const H, w.BOOL, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?H;
extern "kernel32" fn ResetEvent(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetOverlappedResult(H, *Overlapped, *u32, w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn CancelIoEx(H, ?*Overlapped) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetNamedPipeClientProcessId(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?H;
extern "kernel32" fn QueryFullProcessImageNameW(H, u32, [*]u16, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "advapi32" fn OpenProcessToken(H, u32, *H) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(H, u32, ?*anyopaque, u32, *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;

pub const Identity = [32]u8;
pub fn identity(process: H) !Identity {
    var token: H = undefined;
    if (OpenProcessToken(process, 8, &token) == 0) return error.TokenAccess;
    defer _ = w.CloseHandle(token);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    // TOKEN_USER and TOKEN_MANDATORY_LABEL both start with SID_AND_ATTRIBUTES.
    for ([_]u32{ 1, 25 }) |kind| {
        var buf: [1024]u8 align(@alignOf(usize)) = undefined;
        var size: u32 = 0;
        if (GetTokenInformation(token, kind, &buf, buf.len, &size) == 0) return error.TokenAccess;
        const sid = @as(*const extern struct { sid: *anyopaque, attributes: u32 }, @ptrCast(&buf)).sid;
        hash.update(@as([*]const u8, @ptrCast(sid))[0..GetLengthSid(sid)]);
    }
    var session: u32 = 0;
    var returned: u32 = 0;
    if (GetTokenInformation(token, 12, &session, @sizeOf(u32), &returned) == 0) return error.TokenAccess;
    hash.update(std.mem.asBytes(&session));
    var path: [32768]u16 = undefined;
    var len: u32 = path.len;
    if (QueryFullProcessImageNameW(process, 0, &path, &len) == 0) return error.ProcessImage;
    const full = path[0..len];
    const slash = std.mem.lastIndexOfScalar(u16, full, '\\') orelse return error.ProcessImage;
    const basename = full[slash + 1 ..];
    if (!std.mem.eql(u16, basename, std.unicode.utf8ToUtf16LeStringLiteral("ghostty.exe")) and
        !std.mem.eql(u16, basename, std.unicode.utf8ToUtf16LeStringLiteral("yuurei-mux.exe")))
        return error.ProcessImage;
    // The native GUI and helper must be siblings in the same installation.
    hash.update(std.mem.sliceAsBytes(full[0..slash]));
    return hash.finalResult();
}
pub fn peer(pipe: H, server: bool, expected: Identity) !u32 {
    var pid: u32 = 0;
    const ok = if (server) GetNamedPipeServerProcessId(pipe, &pid) else GetNamedPipeClientProcessId(pipe, &pid);
    if (ok == 0) return error.PeerIdentity;
    const process = OpenProcess(0x1000, 0, pid) orelse return error.PeerIdentity;
    defer _ = w.CloseHandle(process);
    if (!std.mem.eql(u8, &expected, &(try identity(process)))) return error.PeerIdentity;
    return pid;
}

/// One outstanding overlapped operation, interruptible on shutdown and bounded
/// for connected peers. Cancellation completes before stack/buffer reuse.
pub const Io = struct {
    event: H,
    stop: ?H = null,
    pub fn init(stop: ?H) !Io {
        return .{ .event = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent, .stop = stop };
    }
    pub fn begin(self: *Io) Overlapped {
        _ = ResetEvent(self.event);
        var ov = std.mem.zeroes(Overlapped);
        ov.hEvent = self.event;
        return ov;
    }
    pub fn finish(self: *Io, pipe: H, ov: *Overlapped, timeout: u32) !u32 {
        const handles = [_]H{ self.event, self.stop orelse self.event };
        const result = WaitForMultipleObjects(if (self.stop != null) 2 else 1, &handles, 0, timeout);
        var bytes: u32 = 0;
        if (result != 0) {
            _ = CancelIoEx(pipe, ov);
            _ = GetOverlappedResult(pipe, ov, &bytes, 1);
            return if (result == 1) error.Stopped else error.IoTimeout;
        }
        if (GetOverlappedResult(pipe, ov, &bytes, 0) == 0) return error.PipeIo;
        return bytes;
    }
    pub fn transfer(self: *Io, pipe: H, bytes: []u8, writing: bool) !void {
        const started = GetTickCount64();
        var offset: usize = 0;
        while (offset < bytes.len) {
            const elapsed = GetTickCount64() - started;
            if (elapsed >= 3000) return error.IoTimeout;
            if (self.stop) |stop_event| if (WaitForSingleObject(stop_event, 0) == 0) return error.Stopped;
            var ov = self.begin();
            var n: u32 = 0;
            const size: u32 = @intCast(bytes.len - offset);
            const ok = if (writing) w.WriteFile(pipe, bytes[offset..].ptr, size, &n, &ov) else w.ReadFile(pipe, bytes[offset..].ptr, size, &n, &ov);
            if (ok == 0) {
                if (windows.GetLastError() != .IO_PENDING) return error.PipeIo;
                n = try self.finish(pipe, &ov, @intCast(3000 - elapsed));
            }
            if (n == 0) return error.PipeClosed;
            offset += n;
        }
    }

    /// Authenticated idle connections may sleep indefinitely. Once the first
    /// byte arrives, the remaining header/payload still has a bounded deadline.
    pub fn requestHeader(self: *Io, pipe: H, bytes: []u8) !void {
        var ov = self.begin();
        var n: u32 = 0;
        if (w.ReadFile(pipe, bytes.ptr, 1, &n, &ov) == 0) {
            if (windows.GetLastError() != .IO_PENDING) return error.PipeIo;
            n = try self.finish(pipe, &ov, w.INFINITE);
        }
        if (n != 1) return error.PipeClosed;
        try self.transfer(pipe, bytes[1..], false);
    }
};

pub fn pipeName(name: []const u8, owner: Identity) ![:0]u16 {
    return endpointName(name, owner, false);
}

pub fn endpointName(name: []const u8, owner: Identity, control: bool) ![:0]u16 {
    if (!@import("protocol.zig").validName(name)) return error.InvalidSessionName;
    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\LOCAL\\yuurei-mux-experimental-{x}-{s}{s}", .{ owner, name, if (control) ".control" else "" });
    defer alloc.free(path);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
}
