//! Shell profiles for the win32 apprt (Windows Terminal-style).
//!
//! A profile is a display name plus one of:
//!   - a synthesized command for an auto-detected shell (cmd,
//!     PowerShell, pwsh, nu, Git Bash, WSL distros), or
//!   - a user config-overlay file
//!     (%LOCALAPPDATA%\ghostty\profiles\<name>.conf) whose keys are a
//!     standard ghostty config fragment applied on top of the base
//!     configuration for surfaces spawned under the profile — so any
//!     config key (command, theme, font, padding, ...) works
//!     per-profile.
//!
//! A user file whose name matches an auto-detected shell shadows it.

const std = @import("std");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

pub const Source = union(enum) {
    /// Auto-detected shell: the command line to run.
    builtin: [:0]const u8,
    /// User overlay: absolute path to the .conf fragment.
    file: [:0]const u8,
};

pub const Profile = struct {
    name: [:0]const u8,
    /// Dim hint drawn beside the name in the menu (the command line,
    /// or the overlay file name for user profiles).
    hint: [:0]const u8,
    source: Source,
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Profile = &.{},
    /// Items before this index are user overlay profiles; from here on
    /// they are auto-detected shells (the menu draws a separator).
    detected_start: usize = 0,

    pub fn deinit(self: *List) void {
        self.arena.deinit();
    }

    pub fn byName(self: *const List, name: []const u8) ?*const Profile {
        for (self.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

/// Discover all profiles. Never fails: on any error the affected
/// source is simply absent. The WSL probe spawns `wsl.exe -l -q`
/// (windowless, bounded wait), so call this lazily (first menu open)
/// rather than at startup, and cache the result.
pub fn scan(gpa: std.mem.Allocator) List {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const alloc = arena.allocator();

    var items: std.ArrayList(Profile) = .empty;

    scanUserDir(alloc, &items);
    std.mem.sort(Profile, items.items, {}, nameLessThan);
    const detected_start = items.items.len;

    detectShells(alloc, &items);
    detectWsl(alloc, &items);

    return .{
        .arena = arena,
        .items = items.toOwnedSlice(alloc) catch &.{},
        .detected_start = detected_start,
    };
}

fn nameLessThan(_: void, a: Profile, b: Profile) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// User overlay fragments: %LOCALAPPDATA%\ghostty\profiles\*.conf,
/// profile name = file name without the extension.
fn scanUserDir(alloc: std.mem.Allocator, items: *std.ArrayList(Profile)) void {
    const base = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    const dir_path = std.fs.path.join(alloc, &.{ base, "ghostty", "profiles" }) catch return;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".conf")) continue;
        const stem = entry.name[0 .. entry.name.len - ".conf".len];
        if (stem.len == 0) continue;

        const name = alloc.dupeZ(u8, stem) catch continue;
        const path = std.fs.path.joinZ(alloc, &.{ dir_path, entry.name }) catch continue;
        items.append(alloc, .{
            .name = name,
            .hint = alloc.dupeZ(u8, entry.name) catch continue,
            .source = .{ .file = path },
        }) catch continue;
    }
}

/// Whether a user profile already claimed this name (shadowing).
fn shadowed(items: *const std.ArrayList(Profile), name: []const u8) bool {
    for (items.items) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return true;
    }
    return false;
}

fn addBuiltin(
    alloc: std.mem.Allocator,
    items: *std.ArrayList(Profile),
    name: [:0]const u8,
    command: [:0]const u8,
) void {
    if (shadowed(items, name)) return;
    items.append(alloc, .{
        .name = name,
        .hint = command,
        .source = .{ .builtin = command },
    }) catch {};
}

/// Whether an executable resolves on the PATH.
fn onPath(comptime exe: []const u8) bool {
    var buf: [winapi.MAX_PATH]u16 = undefined;
    const n = winapi.SearchPathW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral(exe),
        null,
        buf.len,
        &buf,
        null,
    );
    return n > 0 and n < buf.len;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// The 8.3 short form of a path (no spaces), or null if unavailable
/// (short names can be disabled per-volume).
fn shortPath(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var long_w: [winapi.MAX_PATH:0]u16 = undefined;
    const long_len = std.unicode.utf8ToUtf16Le(&long_w, path) catch return null;
    if (long_len >= long_w.len) return null;
    long_w[long_len] = 0;

    var short_w: [winapi.MAX_PATH]u16 = undefined;
    const n = winapi.GetShortPathNameW(long_w[0..long_len :0], &short_w, short_w.len);
    if (n == 0 or n >= short_w.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, short_w[0..n]) catch null;
}

/// Fixed probes for the common Windows shells. Commands are bare names
/// where PATH resolution suffices; quoting protects the Git Bash path.
fn detectShells(alloc: std.mem.Allocator, items: *std.ArrayList(Profile)) void {
    // cmd is part of Windows; probe anyway so a bizarre system just
    // omits it instead of offering a dead entry.
    if (onPath("cmd.exe")) addBuiltin(alloc, items, "Command Prompt", "cmd");

    // PowerShell 7+ (pwsh) and Windows PowerShell 5.1 are distinct
    // products; list whichever exists (commonly both).
    if (onPath("pwsh.exe")) addBuiltin(alloc, items, "PowerShell", "pwsh");
    if (onPath("powershell.exe"))
        addBuiltin(alloc, items, "Windows PowerShell", "powershell");

    if (onPath("nu.exe")) addBuiltin(alloc, items, "Nushell", "nu");

    // Git Bash keeps its own home under Program Files; -i -l gives the
    // login shell users expect from the Git Bash shortcut. The termio
    // Windows spawn path splits shell commands on whitespace with no
    // quote handling, so the space in "Program Files" must go: use the
    // 8.3 short path. (PATH probing is wrong here: a bare bash.exe
    // resolves to the WSL launcher in System32, not Git Bash.)
    git: {
        const pf = std.process.getEnvVarOwned(alloc, "ProgramFiles") catch
            break :git;
        const bash = std.fs.path.join(alloc, &.{ pf, "Git", "bin", "bash.exe" }) catch
            break :git;
        if (!fileExists(bash)) break :git;
        const short = shortPath(alloc, bash) orelse break :git;
        if (std.mem.indexOfAny(u8, short, " \t") != null) break :git;
        const cmd = std.fmt.allocPrintSentinel(alloc, "{s} -i -l", .{short}, 0) catch
            break :git;
        addBuiltin(alloc, items, "Git Bash", cmd);
    }
}

/// One profile per installed WSL distribution, via `wsl.exe -l -q`.
/// wsl.exe emits UTF-16LE. Docker Desktop's plumbing distros are
/// hidden, matching Windows Terminal.
fn detectWsl(alloc: std.mem.Allocator, items: *std.ArrayList(Profile)) void {
    if (!onPath("wsl.exe")) return;
    const out = runCapture(alloc, "wsl.exe -l -q", 2000) orelse return;

    // UTF-16LE -> UTF-8 (re-aligned copy; drop a BOM if present).
    const units = alloc.alloc(u16, out.len / 2) catch return;
    for (units, 0..) |*u, i|
        u.* = std.mem.readInt(u16, out[i * 2 ..][0..2], .little);
    const trimmed = if (units.len > 0 and units[0] == 0xFEFF) units[1..] else units;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, trimmed) catch return;

    var lines = std.mem.splitScalar(u8, utf8, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "docker-desktop")) continue;

        const name = std.fmt.allocPrintSentinel(alloc, "WSL: {s}", .{line}, 0) catch
            continue;
        if (shadowed(items, name)) continue;
        const cmd = std.fmt.allocPrintSentinel(alloc, "wsl -d {s}", .{line}, 0) catch
            continue;
        items.append(alloc, .{
            .name = name,
            .hint = cmd,
            .source = .{ .builtin = cmd },
        }) catch continue;
    }
}

/// Run a command windowless and capture its stdout, waiting at most
/// timeout_ms. Returns null on any failure or timeout (the child is
/// then killed). The result is allocated from `alloc`.
fn runCapture(
    alloc: std.mem.Allocator,
    command: []const u8,
    timeout_ms: u32,
) ?[]u8 {
    var sa: winapi.SECURITY_ATTRIBUTES = .{ .bInheritHandle = winapi.TRUE };
    var read_h: ?winapi.HANDLE = null;
    var write_h: ?winapi.HANDLE = null;
    if (winapi.CreatePipe(&read_h, &write_h, &sa, 0) == 0) return null;
    defer _ = winapi.CloseHandle(read_h.?);
    // The read end must not leak into the child or reads never EOF.
    _ = winapi.SetHandleInformation(read_h.?, winapi.HANDLE_FLAG_INHERIT, 0);

    var cmd_w_buf: [512:0]u16 = undefined;
    const cmd_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, command) catch {
        _ = winapi.CloseHandle(write_h.?);
        return null;
    };
    cmd_w_buf[cmd_len] = 0;

    var si: winapi.STARTUPINFOW = .{
        .dwFlags = winapi.STARTF_USESTDHANDLES,
        .hStdOutput = write_h,
        .hStdError = write_h,
    };
    var pi: winapi.PROCESS_INFORMATION = .{};
    const ok = winapi.CreateProcessW(
        null,
        cmd_w_buf[0..cmd_len :0],
        null,
        null,
        winapi.TRUE,
        winapi.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );
    // The parent's write end must close regardless so ReadFile sees
    // EOF once the child exits.
    _ = winapi.CloseHandle(write_h.?);
    if (ok == 0) return null;
    defer _ = winapi.CloseHandle(pi.hProcess.?);
    defer _ = winapi.CloseHandle(pi.hThread.?);

    // Drain the pipe first (a full pipe would deadlock the child if we
    // waited on the process before reading), then bound the wait.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: winapi.DWORD = 0;
        if (winapi.ReadFile(read_h.?, &buf, buf.len, &n, null) == 0 or n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch break;
        if (out.items.len > 1 << 20) break;
    }
    if (winapi.WaitForSingleObject(pi.hProcess.?, timeout_ms) != 0) {
        _ = winapi.TerminateProcess(pi.hProcess.?, 1);
        return null;
    }

    return alloc.dupe(u8, out.items) catch null;
}
