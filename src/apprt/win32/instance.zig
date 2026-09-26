//! Route compatible launches to one window/surface owner. The local pipe is
//! authenticated with OS-reported process IDs, token identity, and image path.
const std = @import("std");
const global = @import("../../global.zig");
const Config = @import("../../config.zig").Config;
const App = @import("App.zig");
const Window = @import("Window.zig");
const w = @import("winapi.zig");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.win32_instance);
const H = w.HANDLE;
const max_payload = 1024 * 1024;
const PIPE_ACCESS_DUPLEX = 3;
const PIPE_REJECT_REMOTE_CLIENTS = 8;
const SECURITY_SQOS_PRESENT = 0x00100000;
const SECURITY_IDENTIFICATION = 0x00010000;
const Entry = struct { key: []const u8, value: []const u8 };
const Request = struct { cwd: ?[]const u8, command: ?@import("../../config.zig").Command, env: []const Entry };
const Parsed = std.json.Parsed(Request);
const Overlapped = extern struct {
    internal: usize,
    internal_high: usize,
    position: extern union { offset: extern struct { low: u32, high: u32 }, pointer: ?*anyopaque },
    hEvent: ?H,
};

extern "kernel32" fn CreateMutexW(?*anyopaque, w.BOOL, [*:0]const u16) callconv(.winapi) ?H;
extern "kernel32" fn ReleaseMutex(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const H, w.BOOL, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?H;
extern "kernel32" fn SetEvent(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn ResetEvent(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn ConnectNamedPipe(H, *Overlapped) callconv(.winapi) w.BOOL;
extern "kernel32" fn DisconnectNamedPipe(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetOverlappedResult(H, *Overlapped, *u32, w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn CancelIoEx(H, ?*Overlapped) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetNamedPipeClientProcessId(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?H;
extern "kernel32" fn QueryFullProcessImageNameW(H, u32, [*]u16, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "advapi32" fn OpenProcessToken(H, u32, *H) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(H, u32, ?*anyopaque, u32, *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;
extern "user32" fn AllowSetForegroundWindow(u32) callconv(.winapi) w.BOOL;

const Identity = [32]u8;
fn identity(process: H) !Identity {
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
    hash.update(std.mem.sliceAsBytes(path[0..len]));
    return hash.finalResult();
}
fn peer(pipe: H, server: bool, expected: Identity) !u32 {
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
const Io = struct {
    event: H,
    stop: ?H = null,
    fn init(stop: ?H) !Io {
        return .{ .event = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent, .stop = stop };
    }
    fn begin(self: *Io) Overlapped {
        _ = ResetEvent(self.event);
        var ov = std.mem.zeroes(Overlapped);
        ov.hEvent = self.event;
        return ov;
    }
    fn finish(self: *Io, pipe: H, ov: *Overlapped, timeout: u32) !u32 {
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
    fn transfer(self: *Io, pipe: H, bytes: []u8, writing: bool) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.stop) |stop_event| if (WaitForSingleObject(stop_event, 0) == 0) return error.Stopped;
            var ov = self.begin();
            var n: u32 = 0;
            const size: u32 = @intCast(bytes.len - offset);
            const ok = if (writing) w.WriteFile(pipe, bytes[offset..].ptr, size, &n, &ov) else w.ReadFile(pipe, bytes[offset..].ptr, size, &n, &ov);
            if (ok == 0) {
                if (windows.GetLastError() != .IO_PENDING) return error.PipeIo;
                n = try self.finish(pipe, &ov, 3000);
            }
            if (n == 0) return error.PipeClosed;
            offset += n;
        }
    }
};

pub const Startup = union(enum) { forwarded, isolated, host: *Server };

pub fn start(alloc: Allocator) !Startup {
    var env = try global.environMap();
    defer env.deinit();
    if (env.get("GHOSTTY_NEW_INSTANCE") != null) return .isolated;
    const id = try identity(windows.GetCurrentProcess());
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&id);
    hash.update("yuurei-launch-v1");
    hash.update(@import("../../build_config.zig").version_string);
    const cwd = try std.process.currentPathAlloc(global.io(), alloc);
    defer alloc.free(cwd);
    // Do not combine different config roots or process-wide renderer settings.
    for ([_][]const u8{ "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "GHOSTTY_RESOURCES_DIR", "GHOSTTY_RENDER_WORKERS", "GHOSTTY_PARK_DRAWABLES", "GHOSTTY_NO_FLIP" }) |key| {
        hash.update(key);
        if (env.get(key)) |v| {
            hash.update(v);
            if ((std.mem.indexOf(u8, key, "CONFIG") != null or std.mem.endsWith(u8, key, "DATA") or std.mem.endsWith(u8, key, "_DIR")) and !std.fs.path.isAbsolute(v)) hash.update(cwd);
        }
        hash.update(&.{0});
    }
    var args = try global.args().iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "-Embedding") or std.ascii.eqlIgnoreCase(arg, "/Embedding")) return .isolated;
        // cwd is carried by the request, not part of configuration identity.
        if (std.mem.startsWith(u8, arg, "--working-directory=")) continue;
        if (std.mem.eql(u8, arg, "--working-directory")) {
            _ = args.next();
            continue;
        }
        hash.update(arg);
        hash.update(&.{0});
        if (std.mem.cutPrefix(u8, arg, "--config-file=")) |path| {
            if (!std.fs.path.isAbsolute(path)) hash.update(cwd);
        } else if (std.mem.eql(u8, arg, "--config-file")) hash.update(cwd);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    const mutex_name = try std.fmt.allocPrintSentinel(alloc, "Local\\yuurei-{s}", .{digest}, 0);
    defer alloc.free(mutex_name);
    const mutex_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, mutex_name);
    defer alloc.free(mutex_w);
    const pipe_name = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\yuurei-{s}", .{digest});
    defer alloc.free(pipe_name);
    const pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name);
    var cleanup_on_error = true;
    errdefer if (cleanup_on_error) alloc.free(pipe_w);
    const mutex = CreateMutexW(null, 0, mutex_w) orelse return error.CreateMutex;
    errdefer if (cleanup_on_error) {
        _ = ReleaseMutex(mutex);
        _ = w.CloseHandle(mutex);
    };
    const acquired = WaitForSingleObject(mutex, 0);
    if (acquired == 0 or acquired == 0x80) {
        const stop = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent;
        errdefer _ = w.CloseHandle(stop);
        const self = try alloc.create(Server);
        self.* = .{ .alloc = alloc, .identity = id, .mutex = mutex, .pipe_name = pipe_w, .stop_event = stop };
        return .{ .host = self };
    }
    if (acquired != 258) return error.InstanceLock;
    defer {
        alloc.free(pipe_w);
        _ = w.CloseHandle(mutex);
    }
    cleanup_on_error = false;
    var cfg = try Config.load(alloc);
    defer cfg.deinit();
    if (cfg._diagnostics.containsLocation(.cli)) return .isolated;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);
    var it = env.iterator();
    while (it.next()) |entry| try entries.append(alloc, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    const directory = if (cfg.@"working-directory") |wd| wd.value() orelse cwd else cwd;
    const resolved = try std.fs.path.resolve(alloc, &.{ cwd, directory });
    defer alloc.free(resolved);
    const bytes = try std.json.Stringify.valueAlloc(alloc, Request{
        .cwd = resolved,
        .command = cfg.@"initial-command" orelse cfg.command,
        .env = entries.items,
    }, .{});
    defer alloc.free(bytes);
    if (bytes.len > max_payload) return error.LaunchTooLarge;
    var pipe: H = w.INVALID_HANDLE_VALUE;
    for (0..250) |_| {
        pipe = w.CreateFileW(pipe_w, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null);
        if (pipe != w.INVALID_HANDLE_VALUE) break;
        Sleep(20);
    }
    if (pipe == w.INVALID_HANDLE_VALUE) return error.LaunchHostUnavailable;
    defer _ = w.CloseHandle(pipe);
    const pid = try peer(pipe, true, id);
    _ = AllowSetForegroundWindow(pid);
    var io = try Io.init(null);
    defer _ = w.CloseHandle(io.event);
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    try io.transfer(pipe, &length, true);
    try io.transfer(pipe, bytes, true);
    var ack: [1]u8 = undefined;
    try io.transfer(pipe, &ack, false);
    if (ack[0] != 1) return error.LaunchRejected;
    try io.transfer(pipe, &ack, true);
    return .forwarded;
}

pub const Server = struct {
    alloc: Allocator,
    identity: Identity,
    mutex: H,
    pipe_name: [:0]u16,
    stop_event: H,
    thread: ?std.Thread = null,
    app: ?*App = null,
    queue_lock: std.Io.Mutex = .init,
    queue: std.ArrayList(Parsed) = .empty,

    pub fn attach(self: *Server, app: *App) !void {
        const pipe = w.CreateNamedPipeW(self.pipe_name, PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, null);
        if (pipe == w.INVALID_HANDLE_VALUE) return error.CreateLaunchPipe;
        errdefer _ = w.CloseHandle(pipe);
        const io = try Io.init(self.stop_event);
        errdefer _ = w.CloseHandle(io.event);
        self.app = app;
        errdefer self.app = null;
        self.thread = try std.Thread.spawn(@import("../../os/windows.zig").worker_thread_config, run, .{ self, pipe, io });
        app.instance = self;
    }
    pub fn stop(self: *Server) void {
        _ = SetEvent(self.stop_event);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.app) |app| app.instance = null;
        self.app = null;
    }
    pub fn deinit(self: *Server) void {
        self.stop();
        for (self.queue.items) |request| request.deinit();
        self.queue.deinit(self.alloc);
        _ = w.CloseHandle(self.stop_event);
        _ = ReleaseMutex(self.mutex);
        _ = w.CloseHandle(self.mutex);
        self.alloc.free(self.pipe_name);
        self.alloc.destroy(self);
    }
    fn run(self: *Server, pipe: H, initial_io: Io) void {
        defer _ = w.CloseHandle(pipe);
        var io = initial_io;
        defer _ = w.CloseHandle(io.event);
        while (WaitForSingleObject(self.stop_event, 0) != 0) {
            var ov = io.begin();
            if (ConnectNamedPipe(pipe, &ov) == 0) {
                const err = windows.GetLastError();
                if (err == .IO_PENDING) {
                    _ = io.finish(pipe, &ov, 0xFFFFFFFF) catch break;
                } else if (err != .PIPE_CONNECTED) break;
            }
            self.receive(&io, pipe) catch |err| {
                log.warn("launch request rejected err={}", .{err});
            };
            _ = DisconnectNamedPipe(pipe);
        }
    }
    fn receive(self: *Server, io: *Io, pipe: H) !void {
        _ = try peer(pipe, false, self.identity);
        var length: [4]u8 = undefined;
        try io.transfer(pipe, &length, false);
        const size = std.mem.readInt(u32, &length, .little);
        if (size == 0 or size > max_payload) return error.LaunchTooLarge;
        const bytes = try self.alloc.alloc(u8, size);
        defer self.alloc.free(bytes);
        try io.transfer(pipe, bytes, false);
        const parsed = try std.json.parseFromSlice(Request, self.alloc, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        self.queue_lock.lockUncancelable(global.io());
        if (self.queue.items.len >= 32) {
            self.queue_lock.unlock(global.io());
            return error.LaunchQueueFull;
        }
        self.queue.append(self.alloc, parsed) catch |err| {
            self.queue_lock.unlock(global.io());
            return err;
        };
        self.queue_lock.unlock(global.io());
        self.app.?.wakeup();
        var ack = [_]u8{1};
        // Once queued the request owns parsed, even if the client disconnects.
        io.transfer(pipe, &ack, true) catch return;
        io.transfer(pipe, &ack, false) catch {};
    }
    pub fn drain(self: *Server) void {
        self.queue_lock.lockUncancelable(global.io());
        var queue = self.queue;
        self.queue = .empty;
        self.queue_lock.unlock(global.io());
        defer queue.deinit(self.alloc);
        for (queue.items) |request| {
            defer request.deinit();
            self.open(request.value) catch |err| log.err("cannot open forwarded launch err={}", .{err});
        }
    }
    fn open(self: *Server, request: Request) !void {
        const app = self.app.?;
        const window = try Window.create(self.alloc, app, .{ .no_initial_tab = true });
        errdefer window.destroy();
        window.launch_environment = std.process.Environ.Map.init(self.alloc);
        for (request.env) |entry| try window.launch_environment.?.put(entry.key, entry.value);
        _ = try window.newTabWithOpts(.{ .cwd = request.cwd, .command = request.command });
        try app.windows.append(self.alloc, window);
        _ = w.ShowWindow(window.hwnd, w.SW_SHOW);
        _ = w.SetForegroundWindow(window.hwnd);
        _ = w.SetFocus(window.hwnd);
    }
};

test "launch request preserves command arguments and empty environment values" {
    const alloc = std.testing.allocator;
    const request: Request = .{
        .cwd = "C:\\work space\\日本語",
        .command = .{ .direct = &.{ "pwsh.exe", "-Command", "echo 'two words'" } },
        .env = &.{ .{ .key = "EMPTY", .value = "" }, .{ .key = "VALUE", .value = "a=b\nsecond line" } },
    };
    const bytes = try std.json.Stringify.valueAlloc(alloc, request, .{});
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(Request, alloc, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(request.cwd.?, parsed.value.cwd.?);
    try std.testing.expectEqualStrings("echo 'two words'", parsed.value.command.?.direct[2]);
    try std.testing.expectEqual(@as(u8, 0), parsed.value.command.?.direct[2].ptr[parsed.value.command.?.direct[2].len]);
    try std.testing.expectEqualStrings("", parsed.value.env[0].value);
    try std.testing.expectEqualStrings(request.env[1].value, parsed.value.env[1].value);
}
