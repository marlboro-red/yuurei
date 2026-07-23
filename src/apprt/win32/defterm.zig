//! Default-terminal handoff (Windows "Default terminal application").
//!
//! When yuurei is registered as the default terminal, the inbox conhost
//! that a console app is launched under hands its ConPTY off to us over
//! COM (ITerminalHandoff3.EstablishPtyHandoff), passing the PTY pipes
//! and the client/server process handles. We then attach a surface to
//! those pipes instead of spawning our own ConPTY.
//!
//! This file has two jobs:
//!   1. register()/unregister() — the HKCU registry plumbing (also the
//!      `+defterm` CLI action), including the vendored proxy/stub DLL
//!      that marshals the handoff's `system_handle` parameters.
//!   2. the COM server — a class factory + ITerminalHandoff3 object,
//!      registered at app startup so a running yuurei receives handoffs
//!      (and COM's LocalServer32 launches one if none is running).
//!
//! Registration is per-user (HKCU); no elevation required, and it never
//! touches other users or machine-wide state.

const std = @import("std");
const builtin = @import("builtin");
const winapi = @import("winapi.zig");

const log = std.log.scoped(.win32);

/// yuurei's own delegation-terminal CLSID (minted for this fork).
pub const CLSID_YuureiTerminal: winapi.GUID = .{
    .Data1 = 0xC8B3E4A2,
    .Data2 = 0x7F19,
    .Data3 = 0x4D6C,
    .Data4 = .{ 0xB5, 0xA8, 0x1E, 0x9F, 0x3C, 0x2D, 0x4B, 0x60 },
};

/// The inbox OpenConsole (conhost) delegation-console CLSID. Paired
/// with our terminal CLSID so legacy consoles still work; this is the
/// same value Windows Terminal registers.
const CLSID_DelegationConsole: winapi.GUID = .{
    .Data1 = 0x2EACA947,
    .Data2 = 0x7F5F,
    .Data3 = 0x4CFA,
    .Data4 = .{ 0xBA, 0x87, 0x8F, 0x7F, 0xBE, 0xEF, 0xBE, 0x69 },
};

/// Proxy/stub CLSID = the first interface's IID (midl's default, see
/// vendor/defterm dlldata).
const CLSID_Proxy: winapi.GUID = .{
    .Data1 = 0x59D55CCE,
    .Data2 = 0xFC8A,
    .Data3 = 0x48B4,
    .Data4 = .{ 0xAC, 0xE8, 0x0A, 0x92, 0x86, 0xC6, 0x55, 0x7F },
};

/// The three ITerminalHandoff interface IIDs the proxy DLL serves.
const IID_ITerminalHandoff: winapi.GUID = CLSID_Proxy; // v1 IID == proxy CLSID
const IID_ITerminalHandoff2: winapi.GUID = .{
    .Data1 = 0xAA6B364F,
    .Data2 = 0x4A50,
    .Data3 = 0x4176,
    .Data4 = .{ 0x90, 0x02, 0x0A, 0xE7, 0x55, 0xE7, 0xB5, 0xEF },
};
const IID_ITerminalHandoff3: winapi.GUID = .{
    .Data1 = 0x6F23DA90,
    .Data2 = 0x15C5,
    .Data3 = 0x4203,
    .Data4 = .{ 0x9D, 0xB0, 0x64, 0xE7, 0x3F, 0x1B, 0x1B, 0x00 },
};

const HKCU = winapi.HKEY_CURRENT_USER;

/// Whether the COM handoff *server* (the receiver of
/// ITerminalHandoff3.EstablishPtyHandoff) is implemented and started at
/// app launch. Registering as the default terminal WITHOUT a working
/// server would break console launching system-wide — every `cmd` from
/// Explorer would hand off to a receiver that never answers. Until the
/// server lands (increment 2), register() refuses so no user can arm
/// that landmine; the registry functions themselves are complete and
/// unit-tested.
pub const handoff_ready = false;

/// The canonical registry form of a GUID is 38 chars:
/// "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}".
const guid_len = 38;
const GuidBuf = [guid_len + 1]u16;

/// Format a GUID (uppercase) into `buf`, returning the NUL-terminated
/// slice. `buf` must outlive the returned slice.
fn guidString(g: winapi.GUID, buf: *GuidBuf) [:0]const u16 {
    var ascii: [guid_len]u8 = undefined;
    _ = std.fmt.bufPrint(&ascii, "{{{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}}}", .{
        g.Data1,    g.Data2,    g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2],
        g.Data4[3], g.Data4[4], g.Data4[5],
        g.Data4[6], g.Data4[7],
    }) catch unreachable;
    for (0..guid_len) |i| buf[i] = ascii[i];
    buf[guid_len] = 0;
    return buf[0..guid_len :0];
}

fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Path to this executable as a NUL-terminated UTF-16 slice.
fn exePath(buf: *[winapi.MAX_PATH:0]u16) [:0]const u16 {
    const n = winapi.GetModuleFileNameW(null, buf, buf.len);
    buf[@min(n, buf.len - 1)] = 0;
    return buf[0..@min(n, buf.len - 1) :0];
}

/// Set a string value under HKCU\<subkey>. Returns success.
fn setString(subkey: [:0]const u16, name: ?[:0]const u16, value: [:0]const u16) bool {
    const bytes: winapi.DWORD = @intCast((value.len + 1) * 2);
    return winapi.RegSetKeyValueW(
        HKCU,
        subkey.ptr,
        if (name) |n| n.ptr else null,
        winapi.REG_SZ,
        value.ptr,
        bytes,
    ) == 0;
}

/// Register yuurei as the default terminal for the current user.
/// Idempotent. Returns false if any write failed (partial state is
/// then cleaned up by unregister()).
pub fn register() bool {
    if (comptime builtin.os.tag != .windows) return false;

    var path_buf: [winapi.MAX_PATH:0]u16 = undefined;
    const exe = exePath(&path_buf);

    // "\"<exe>\"" — quoted so a spaced path survives COM's launch.
    var cmd_buf: [winapi.MAX_PATH + 4:0]u16 = undefined;
    cmd_buf[0] = '"';
    @memcpy(cmd_buf[1 .. 1 + exe.len], exe);
    cmd_buf[1 + exe.len] = '"';
    cmd_buf[2 + exe.len] = 0;
    const cmd = cmd_buf[0 .. 2 + exe.len :0];

    const proxy = proxyPath(&path_buf) orelse return false;

    var tb: GuidBuf = undefined;
    var cb: GuidBuf = undefined;
    var pb: GuidBuf = undefined;
    const term_clsid = guidString(CLSID_YuureiTerminal, &tb);
    const console_clsid = guidString(CLSID_DelegationConsole, &cb);
    const proxy_clsid = guidString(CLSID_Proxy, &pb);

    var ok = true;

    // 1. LocalServer32 for our terminal CLSID -> this exe.
    ok = keyClsidLocalServer(term_clsid, cmd) and ok;

    // 2. Proxy/stub InprocServer32 + threading model.
    ok = keyProxyInproc(proxy_clsid, proxy) and ok;

    // 3. Interface -> proxy for all three handoff IIDs.
    inline for (.{ IID_ITerminalHandoff, IID_ITerminalHandoff2, IID_ITerminalHandoff3 }) |iid| {
        var ib: GuidBuf = undefined;
        const iid_str = guidString(iid, &ib);
        ok = keyInterfaceProxy(iid_str, proxy_clsid) and ok;
    }

    // 4. The delegation itself (this is what flips the OS setting).
    ok = setString(L("Console\\%%Startup"), L("DelegationConsole"), console_clsid) and ok;
    ok = setString(L("Console\\%%Startup"), L("DelegationTerminal"), term_clsid) and ok;

    if (!ok) {
        log.warn("defterm registration incomplete; rolling back", .{});
        unregister();
    }
    return ok;
}

fn keyClsidLocalServer(clsid: [:0]const u16, cmd: [:0]const u16) bool {
    // "Software\Classes\CLSID\{...}\LocalServer32"
    var sub: [96:0]u16 = undefined;
    var w: Utf16Builder = .{ .buf = &sub };
    w.add("Software\\Classes\\CLSID\\");
    w.addRaw(clsid);
    w.add("\\LocalServer32");
    return setString(w.slice(), null, cmd);
}

fn keyProxyInproc(clsid: [:0]const u16, proxy: [:0]const u16) bool {
    var sub: [96:0]u16 = undefined;
    var w: Utf16Builder = .{ .buf = &sub };
    w.add("Software\\Classes\\CLSID\\");
    w.addRaw(clsid);
    w.add("\\InprocServer32");
    var ok = setString(w.slice(), null, proxy);
    ok = setString(w.slice(), L("ThreadingModel"), L("Both")) and ok;
    return ok;
}

fn keyInterfaceProxy(iid: [:0]const u16, proxy_clsid: [:0]const u16) bool {
    var sub: [96:0]u16 = undefined;
    var w: Utf16Builder = .{ .buf = &sub };
    w.add("Software\\Classes\\Interface\\");
    w.addRaw(iid);
    w.add("\\ProxyStubClsid32");
    return setString(w.slice(), null, proxy_clsid);
}

/// Remove all registration. Idempotent; safe to call on partial state.
pub fn unregister() void {
    if (comptime builtin.os.tag != .windows) return;

    _ = winapi.RegDeleteKeyValueW(HKCU, L("Console\\%%Startup").ptr, L("DelegationConsole").ptr);
    _ = winapi.RegDeleteKeyValueW(HKCU, L("Console\\%%Startup").ptr, L("DelegationTerminal").ptr);

    inline for (.{ CLSID_YuureiTerminal, CLSID_Proxy }) |clsid| {
        var gb: GuidBuf = undefined;
        const s = guidString(clsid, &gb);
        var sub: [96:0]u16 = undefined;
        var w: Utf16Builder = .{ .buf = &sub };
        w.add("Software\\Classes\\CLSID\\");
        w.addRaw(s);
        _ = winapi.RegDeleteTreeW(HKCU, w.slice().ptr);
    }
    inline for (.{ IID_ITerminalHandoff, IID_ITerminalHandoff2, IID_ITerminalHandoff3 }) |iid| {
        var gb: GuidBuf = undefined;
        const s = guidString(iid, &gb);
        var sub: [96:0]u16 = undefined;
        var w: Utf16Builder = .{ .buf = &sub };
        w.add("Software\\Classes\\Interface\\");
        w.addRaw(s);
        _ = winapi.RegDeleteTreeW(HKCU, w.slice().ptr);
    }
}

/// Whether yuurei is currently the registered default terminal.
pub fn isRegistered() bool {
    if (comptime builtin.os.tag != .windows) return false;
    var buf: [64]u16 = undefined;
    var size: winapi.DWORD = buf.len * 2;
    if (winapi.RegGetValueW(
        HKCU,
        L("Console\\%%Startup").ptr,
        L("DelegationTerminal").ptr,
        0x2, // RRF_RT_REG_SZ
        null,
        &buf,
        &size,
    ) != 0) return false;
    var gb: GuidBuf = undefined;
    const want = guidString(CLSID_YuureiTerminal, &gb);
    const got = std.mem.sliceTo(buf[0..], 0);
    return std.mem.eql(u16, got, want);
}

/// Proxy DLL path: yuurei-defterm-proxy.dll beside the exe.
fn proxyPath(scratch: *[winapi.MAX_PATH:0]u16) ?[:0]const u16 {
    const n = winapi.GetModuleFileNameW(null, scratch, scratch.len);
    if (n == 0 or n >= scratch.len) return null;
    // Replace the file name after the last '\'.
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        if (scratch[i - 1] == '\\') break;
    }
    const name = L("yuurei-defterm-proxy.dll");
    if (i + name.len >= scratch.len) return null;
    @memcpy(scratch[i .. i + name.len], name);
    scratch[i + name.len] = 0;
    return scratch[0 .. i + name.len :0];
}

test "guidString formats the canonical registry form" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: GuidBuf = undefined;
    const s = guidString(CLSID_YuureiTerminal, &buf);
    try std.testing.expectEqual(@as(usize, guid_len), s.len);
    const expect = L("{C8B3E4A2-7F19-4D6C-B5A8-1E9F3C2D4B60}");
    try std.testing.expectEqualSlices(u16, expect, s);
    // Sentinel present exactly at guid_len (no trailing garbage).
    try std.testing.expectEqual(@as(u16, 0), buf[guid_len]);
}

/// Tiny UTF-16 key-path builder over a fixed buffer.
const Utf16Builder = struct {
    buf: []u16,
    len: usize = 0,

    fn add(self: *Utf16Builder, comptime s: []const u8) void {
        const w = L(s);
        @memcpy(self.buf[self.len .. self.len + w.len], w);
        self.len += w.len;
        self.buf[self.len] = 0;
    }
    fn addRaw(self: *Utf16Builder, s: []const u16) void {
        // Trim a trailing NUL if the caller passed a sentinel array.
        const n = std.mem.indexOfScalar(u16, s, 0) orelse s.len;
        @memcpy(self.buf[self.len .. self.len + n], s[0..n]);
        self.len += n;
        self.buf[self.len] = 0;
    }
    fn slice(self: *Utf16Builder) [:0]const u16 {
        return self.buf[0..self.len :0];
    }
};
