//! Portable-release updates. The helper exists only while doing work; idle
//! instances retain no worker thread, HTTP stack, or helper process.
const Updater = @This();
const std = @import("std");
const global = @import("../../global.zig");
const build = @import("../../build_config.zig");
const w = @import("winapi.zig");
const Allocator = std.mem.Allocator;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32_update);
extern "kernel32" fn GetSystemDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "shell32" fn IsUserAnAdmin() callconv(.winapi) w.BOOL;
const State = enum { idle, checking, available, downloading, ready, failed, unsupported };
const Result = struct { state: State, message: []const u8 };

state: State = .idle,
message_buf: [384]u8 = undefined,
message_len: usize = 0,
process: ?w.HANDLE = null,
started_ms: i64 = 0,
timer: usize = 0,
next_check_ms: i64 = 0,
job_path: ?[]const u8 = null,
cache_path: ?[]const u8 = null,
root: ?[]const u8 = null,
manual_download: bool = false,

pub fn releaseTag(version: []const u8) ?[]const u8 {
    const marker = "-yuurei.";
    const offset = (std.mem.indexOf(u8, version, marker) orelse return null) + marker.len;
    const tag = version[offset .. std.mem.indexOfScalarPos(u8, version, offset, '+') orelse version.len];
    if (tag.len < 2 or tag[0] != 'v') return null;
    const parsed = std.SemanticVersion.parse(tag[1..]) catch return null;
    if (parsed.pre != null or parsed.build != null) return null;
    return tag;
}

fn now() i64 {
    return std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
}

pub fn init(self: *Updater) void {
    if (IsUserAnAdmin() != 0) {
        self.set(.unsupported, "Run Yuurei without administrator privileges to update.");
        return;
    }
    if (releaseTag(build.version_string) == null) {
        self.set(.unsupported, "Updates are available in portable release builds.");
        return;
    }
    // Defer work until after startup. This timer carries no periodic render work.
    self.next_check_ms = now() + 30_000;
    self.timer = w.SetTimer(null, 0, 30_000, null);
    self.set(.idle, "Check for a newer release of Yuurei.");
}

pub fn message(self: *const Updater) []const u8 {
    return self.message_buf[0..self.message_len];
}

fn set(self: *Updater, state: State, value: []const u8) void {
    self.state = state;
    self.message_len = @min(value.len, self.message_buf.len);
    // Never leave a truncated UTF-8 sequence for the native UI converter.
    while (self.message_len > 0 and !std.unicode.utf8ValidateSlice(value[0..self.message_len])) self.message_len -= 1;
    @memcpy(self.message_buf[0..self.message_len], value[0..self.message_len]);
}

pub fn buttonLabel(self: *const Updater, enabled: bool) []const u8 {
    return switch (self.state) {
        .checking => "Checking...",
        .downloading => "Downloading...",
        .available => "Download update",
        .ready => if (enabled or self.manual_download) "Update ready" else "Install on exit",
        else => "Check for updates",
    };
}

pub fn buttonEnabled(self: *const Updater, enabled: bool) bool {
    return self.process == null and self.state != .unsupported and
        (self.state != .ready or (!enabled and !self.manual_download));
}

fn writeFile(alloc: Allocator, path: []const u8, data: []const u8) !void {
    _ = alloc;
    const io = global.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn paths(self: *Updater, alloc: Allocator) !void {
    if (self.job_path != null) return;
    const tag = releaseTag(build.version_string) orelse return error.NotReleaseBuild;
    _ = tag;
    var buf: [32768]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.ExecutablePath;
    const exe = try std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]);
    defer alloc.free(exe);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(exe), "ghostty.exe")) return error.NotPortablePackage;
    const bin = std.fs.path.dirname(exe) orelse return error.NotPortablePackage;
    const root = std.fs.path.dirname(bin) orelse return error.NotPortablePackage;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(bin), "bin") or
        std.ascii.eqlIgnoreCase(std.fs.path.basename(root), "zig-out")) return error.NotPortablePackage;
    // Require the release layout, keeping source builds and lone copied exes
    // out of the in-place updater.
    for ([_][]const u8{ "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "bin/conpty.dll", "bin/OpenConsole.exe", "bin/yuurei-defterm-proxy.dll" }) |required| {
        const path = try std.fs.path.join(alloc, &.{ root, required });
        defer alloc.free(path);
        try std.Io.Dir.cwd().access(global.io(), path, .{});
    }
    const base = try global.environ().getAlloc(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    const lower = try std.ascii.allocLowerString(alloc, root);
    defer alloc.free(lower);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lower, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const cache = try std.fs.path.join(alloc, &.{ base, "yuurei", "updates", &hex });
    errdefer alloc.free(cache);
    const job = try std.fmt.allocPrint(alloc, "{s}\\job-{d}", .{ cache, w.GetCurrentProcessId() });
    errdefer alloc.free(job);
    self.root = try alloc.dupe(u8, root);
    self.cache_path = cache;
    self.job_path = job;
}

fn launch(self: *Updater, alloc: Allocator, mode: []const u8) !w.HANDLE {
    try self.paths(alloc);
    try std.Io.Dir.cwd().createDirPath(global.io(), self.job_path.?);
    const script = try std.fs.path.join(alloc, &.{ self.job_path.?, "update-helper.ps1" });
    defer alloc.free(script);
    try writeFile(alloc, script, @embedFile("update-helper.ps1"));
    const request = try std.fs.path.join(alloc, &.{ self.job_path.?, "request.json" });
    defer alloc.free(request);
    const result = try std.fs.path.join(alloc, &.{ self.job_path.?, "result.json" });
    defer alloc.free(result);
    std.Io.Dir.cwd().deleteFile(global.io(), result) catch {};
    const data = try std.json.Stringify.valueAlloc(alloc, .{
        .root = self.root.?,
        .cache = self.cache_path.?,
        .current = releaseTag(build.version_string).?,
        .mode = mode,
        .parent = w.GetCurrentProcessId(),
        .manual = self.manual_download,
    }, .{});
    defer alloc.free(data);
    try writeFile(alloc, request, data);
    var sysbuf: [32768]u16 = undefined;
    const n = GetSystemDirectoryW(&sysbuf, sysbuf.len);
    if (n == 0 or n >= sysbuf.len) return error.SystemDirectory;
    const system = try std.unicode.utf16LeToUtf8Alloc(alloc, sysbuf[0..n]);
    defer alloc.free(system);
    const executable = try std.fs.path.join(alloc, &.{ system, "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer alloc.free(executable);
    const executable_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, executable);
    defer alloc.free(executable_w);
    // Paths are arguments to -File, never PowerShell source. Windows filenames
    // cannot contain quotes, and neither argument ends in a backslash.
    const command = try std.fmt.allocPrint(
        alloc,
        "\"{s}\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{s}\\update-helper.ps1\" -Request \"{s}\"",
        .{ executable, self.job_path.?, request },
    );
    defer alloc.free(command);
    const command_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, command);
    defer alloc.free(command_w);
    var si: w.STARTUPINFOW = .{};
    var pi: w.PROCESS_INFORMATION = .{};
    if (w.CreateProcessW(executable_w, command_w, null, null, 0, w.CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return error.HelperLaunch;
    _ = w.CloseHandle(pi.hThread.?);
    return pi.hProcess.?;
}

pub fn click(self: *Updater, alloc: Allocator, enabled: bool) void {
    if (!self.buttonEnabled(enabled)) return;
    if (self.state == .ready) {
        self.manual_download = true;
        self.set(.ready, "Update will install after all Yuurei instances close.");
        return;
    }
    const download = self.state == .available;
    self.start(alloc, if (download) "download" else "check");
    if (download and self.process != null) self.manual_download = true;
}

fn start(self: *Updater, alloc: Allocator, mode: []const u8) void {
    self.process = self.launch(alloc, mode) catch |err| {
        log.warn("updater start failed: {}", .{err});
        if (self.timer != 0) _ = w.KillTimer(null, self.timer);
        self.timer = 0;
        self.set(if (err == error.NotPortablePackage or err == error.NotReleaseBuild) .unsupported else .failed, "Could not start updater. Use the portable release package in a writable folder.");
        return;
    };
    self.started_ms = now();
    self.set(if (std.mem.eql(u8, mode, "check")) .checking else .downloading, if (std.mem.eql(u8, mode, "check")) "Checking GitHub Releases..." else "Checking and downloading updates...");
    if (self.timer != 0) _ = w.KillTimer(null, self.timer);
    self.timer = w.SetTimer(null, 0, 1000, null);
}

/// Called on the UI thread. Returns true when Settings should refresh status.
pub fn poll(self: *Updater, alloc: Allocator, enabled: bool) bool {
    if (self.state == .unsupported) return false;
    const time = now();
    if (self.process) |process| {
        const finished = WaitForSingleObject(process, 0) == 0;
        if (!finished and time - self.started_ms < 6 * 60 * 1000) return false;
        if (!finished) {
            _ = w.TerminateProcess(process, 1);
            _ = WaitForSingleObject(process, 5000);
        }
        _ = w.CloseHandle(process);
        self.process = null;
        self.set(.failed, "Update check failed. Check your connection and PowerShell policy, then retry.");
        if (finished) read: {
            const path = std.fs.path.join(alloc, &.{ self.job_path.?, "result.json" }) catch break :read;
            defer alloc.free(path);
            const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(8192)) catch break :read;
            defer alloc.free(data);
            const parsed = std.json.parseFromSlice(Result, alloc, data, .{ .ignore_unknown_fields = true }) catch break :read;
            defer parsed.deinit();
            self.set(parsed.value.state, parsed.value.message);
        }
        if (self.timer != 0) _ = w.KillTimer(null, self.timer);
        self.timer = w.SetTimer(null, 0, 60 * 60 * 1000, null);
        self.next_check_ms = time + 24 * 60 * 60 * 1000;
        return true;
    }
    if (time < self.next_check_ms or self.state == .ready) return false;
    self.next_check_ms = time + 60 * 60 * 1000;
    if (enabled) {
        self.start(alloc, "automatic");
        return true;
    }
    if (self.timer != 0) _ = w.KillTimer(null, self.timer);
    self.timer = w.SetTimer(null, 0, 60 * 60 * 1000, null);
    return false;
}

pub fn deinit(self: *Updater, alloc: Allocator, enabled: bool) void {
    var installing = false;
    if (self.timer != 0) _ = w.KillTimer(null, self.timer);
    if (self.process) |process| {
        // Only checks/downloads run under this handle. Installation is detached
        // below and must never be terminated halfway through replacing files.
        _ = w.TerminateProcess(process, 1);
        _ = WaitForSingleObject(process, 5000);
        _ = w.CloseHandle(process);
    }
    if (self.state != .unsupported) install: {
        self.paths(alloc) catch break :install;
        const path = std.fs.path.join(alloc, &.{ self.cache_path.?, "pending.json" }) catch break :install;
        defer alloc.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(8192)) catch break :install;
        defer alloc.free(data);
        const pending = std.json.parseFromSlice(struct { manual: bool = false }, alloc, data, .{ .ignore_unknown_fields = true }) catch break :install;
        defer pending.deinit();
        // A manual download authorizes installation across later exits of
        // isolated instances even when their automatic checks are disabled.
        if (!enabled and !self.manual_download and !pending.value.manual) break :install;
        const process = self.launch(alloc, "install") catch break :install;
        _ = w.CloseHandle(process);
        installing = true;
    }
    if (self.job_path) |path| {
        if (!installing) {
            for ([_][]const u8{ "request.json", "result.json", "update-helper.ps1" }) |name| {
                const file = std.fs.path.join(alloc, &.{ path, name }) catch continue;
                defer alloc.free(file);
                std.Io.Dir.cwd().deleteFile(global.io(), file) catch {};
            }
            std.Io.Dir.cwd().deleteDir(global.io(), path) catch {};
        }
        alloc.free(path);
    }
    if (self.cache_path) |path| alloc.free(path);
    if (self.root) |path| alloc.free(path);
}

test "updater release versions exclude development and prerelease builds" {
    const t = std.testing;
    try t.expectEqualStrings("v0.2.17", releaseTag("1.3.2-yuurei.v0.2.17+e57ac35").?);
    try t.expect(releaseTag("1.3.2-main+e57ac35") == null);
    try t.expect(releaseTag("1.3.2-yuurei.v0.2.18-beta+abcd") == null);
    try t.expect(releaseTag("1.3.2-yuurei.vjunk") == null);
}
