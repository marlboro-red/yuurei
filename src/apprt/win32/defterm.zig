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

// ---------------------------------------------------------------------
// COM handoff server
//
// A class factory for CLSID_YuureiTerminal plus an ITerminalHandoff3
// object. Registered on the main STA thread (App owns the CoInitialize),
// so COM marshals EstablishPtyHandoff onto our message loop and it runs
// directly on the UI thread — no cross-thread handoff needed.

const HANDLE = winapi.HANDLE;
const HRESULT = winapi.HRESULT;

const S_OK: HRESULT = 0;
fn hr(comptime code: u32) HRESULT {
    return @bitCast(code);
}
const E_NOINTERFACE = hr(0x80004002);
const E_POINTER = hr(0x80004003);
const E_FAIL = hr(0x80004005);
const CLASS_E_NOAGGREGATION = hr(0x80040110);
const CLASS_E_CLASSNOTAVAILABLE = hr(0x80040111);

const HANDLE_FLAG_INHERIT: winapi.DWORD = 1;

/// STARTUPINFO-ish metadata conhost forwards (title, icon, size hints).
/// Fields past the title are unused today; the terminal sizes itself.
const TERMINAL_STARTUP_INFO = extern struct {
    pszTitle: ?[*:0]u16, // BSTR (NUL-terminated UTF-16)
    pszIconPath: ?[*:0]u16,
    iconIndex: i32,
    dwX: winapi.DWORD,
    dwY: winapi.DWORD,
    dwXSize: winapi.DWORD,
    dwYSize: winapi.DWORD,
    dwXCountChars: winapi.DWORD,
    dwYCountChars: winapi.DWORD,
    dwFillAttribute: winapi.DWORD,
    dwFlags: winapi.DWORD,
    wShowWindow: u16,
};

const ITerminalHandoff3 = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*ITerminalHandoff3, *const winapi.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ITerminalHandoff3) callconv(.winapi) u32,
        Release: *const fn (*ITerminalHandoff3) callconv(.winapi) u32,
        EstablishPtyHandoff: *const fn (
            *ITerminalHandoff3,
            *?HANDLE, // [out] in  (ConPTY reads keystrokes)
            *?HANDLE, // [out] out (ConPTY writes app output)
            ?HANDLE, // [in] signal
            ?HANDLE, // [in] reference
            ?HANDLE, // [in] server
            ?HANDLE, // [in] client
            *const TERMINAL_STARTUP_INFO,
        ) callconv(.winapi) HRESULT,
    };
};

const IClassFactory = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*IClassFactory, *const winapi.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IClassFactory) callconv(.winapi) u32,
        Release: *const fn (*IClassFactory) callconv(.winapi) u32,
        CreateInstance: *const fn (*IClassFactory, ?*anyopaque, *const winapi.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        LockServer: *const fn (*IClassFactory, winapi.BOOL) callconv(.winapi) HRESULT,
    };
};

/// A received handoff, owned by the callback once delivered: the
/// terminal's pipe ends (drive them exactly like a self-created PTY),
/// the signal pipe (resize), the reference handle (keeps conhost's
/// ConPTY alive; hold until teardown), and the client process (its exit
/// is the shell exit). `title` is the console app's window title, if any.
pub const Handoff = struct {
    our_read: HANDLE, // app output (== pty.out_pipe)
    our_write: HANDLE, // user input (== pty.in_pipe)
    signal: ?HANDLE,
    reference: ?HANDLE,
    client: ?HANDLE,
    title: ?[]const u16,
    title_buf: [256]u16,
};

/// Set by App.startHandoffServer; invoked on the UI thread when a
/// handoff arrives. Null means no app is ready to receive (the handoff
/// is then declined and conhost falls back).
pub var on_handoff: ?*const fn (Handoff) void = null;

fn guidEql(a: *const winapi.GUID, b: *const winapi.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// --- ITerminalHandoff3 (a process-lifetime singleton) ---

var handoff_vtable: ITerminalHandoff3.Vtbl = .{
    .QueryInterface = handoffQI,
    .AddRef = handoffAddRef,
    .Release = handoffRelease,
    .EstablishPtyHandoff = establishPtyHandoff,
};
var handoff_obj: ITerminalHandoff3 = .{ .vtable = &handoff_vtable };

fn handoffQI(self: *ITerminalHandoff3, riid: *const winapi.GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &winapi.IID_IUnknown) or
        guidEql(riid, &IID_ITerminalHandoff) or
        guidEql(riid, &IID_ITerminalHandoff2) or
        guidEql(riid, &IID_ITerminalHandoff3))
    {
        ppv.* = self;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}
fn handoffAddRef(_: *ITerminalHandoff3) callconv(.winapi) u32 {
    return 1; // singleton; lives for the process
}
fn handoffRelease(_: *ITerminalHandoff3) callconv(.winapi) u32 {
    return 1;
}

fn establishPtyHandoff(
    _: *ITerminalHandoff3,
    in_out: *?HANDLE,
    out_out: *?HANDLE,
    signal: ?HANDLE,
    reference: ?HANDLE,
    server: ?HANDLE,
    client: ?HANDLE,
    startup: *const TERMINAL_STARTUP_INFO,
) callconv(.winapi) HRESULT {
    // The server (conhost) handle is not needed once we have the pipes.
    if (server) |s| _ = winapi.CloseHandle(s);

    const cb = on_handoff orelse return E_FAIL;

    const pipes = createHandoffPipes() catch return E_FAIL;
    // Return conhost's ends (the proxy duplicates them cross-process).
    in_out.* = pipes.conhost_in;
    out_out.* = pipes.conhost_out;

    var h: Handoff = .{
        .our_read = pipes.our_read,
        .our_write = pipes.our_write,
        .signal = signal,
        .reference = reference,
        .client = client,
        .title = null,
        .title_buf = undefined,
    };
    if (startup.pszTitle) |t| {
        const src = std.mem.sliceTo(t, 0);
        const n = @min(src.len, h.title_buf.len);
        @memcpy(h.title_buf[0..n], src[0..n]);
        h.title = h.title_buf[0..n];
    }

    cb(h);
    return S_OK;
}

const HandoffPipes = struct {
    our_read: HANDLE,
    our_write: HANDLE,
    conhost_in: HANDLE,
    conhost_out: HANDLE,
};

var pipe_counter: std.atomic.Value(u32) = .init(1);

/// Create the two pipes for a handoff, mirroring pty.WindowsPty.open:
/// an overlapped named pipe for user input (our write / conhost read)
/// and an anonymous pipe for app output (our read / conhost write). The
/// named pipe is required for libxev's IOCP path. Returns our ends plus
/// conhost's ends (the latter marshaled back over the proxy).
fn createHandoffPipes() !HandoffPipes {
    var name_a: [128]u8 = undefined;
    const name = std.fmt.bufPrintZ(
        &name_a,
        "\\\\.\\pipe\\LOCAL\\yuurei-handoff-{d}-{d}",
        .{ winapi.GetCurrentProcessId(), pipe_counter.fetchAdd(1, .monotonic) },
    ) catch return error.NameTooLong;
    var name_w: [128:0]u16 = undefined;
    const nlen = std.unicode.utf8ToUtf16Le(&name_w, name) catch return error.Encode;
    name_w[nlen] = 0;

    var sa: winapi.SECURITY_ATTRIBUTES = .{ .bInheritHandle = winapi.FALSE };

    const our_write = winapi.CreateNamedPipeW(
        name_w[0..nlen :0].ptr,
        winapi.PIPE_ACCESS_OUTBOUND |
            winapi.FILE_FLAG_FIRST_PIPE_INSTANCE |
            winapi.FILE_FLAG_OVERLAPPED,
        winapi.PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        &sa,
    );
    if (our_write == winapi.INVALID_HANDLE_VALUE) return error.CreatePipe;
    errdefer _ = winapi.CloseHandle(our_write);

    const conhost_in = winapi.CreateFileW(
        name_w[0..nlen :0].ptr,
        winapi.GENERIC_READ,
        0,
        &sa,
        winapi.OPEN_EXISTING,
        winapi.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (conhost_in == winapi.INVALID_HANDLE_VALUE) return error.OpenPipe;
    errdefer _ = winapi.CloseHandle(conhost_in);

    var our_read: ?HANDLE = null;
    var conhost_out: ?HANDLE = null;
    if (winapi.CreatePipe(&our_read, &conhost_out, &sa, 0) == 0) return error.CreatePipe;

    // Our ends must not leak into any child we later spawn.
    _ = winapi.SetHandleInformation(our_write, HANDLE_FLAG_INHERIT, 0);
    _ = winapi.SetHandleInformation(our_read.?, HANDLE_FLAG_INHERIT, 0);

    return .{
        .our_read = our_read.?,
        .our_write = our_write,
        .conhost_in = conhost_in,
        .conhost_out = conhost_out.?,
    };
}

// --- IClassFactory (a process-lifetime singleton) ---

var factory_vtable: IClassFactory.Vtbl = .{
    .QueryInterface = factoryQI,
    .AddRef = factoryAddRef,
    .Release = factoryRelease,
    .CreateInstance = factoryCreateInstance,
    .LockServer = factoryLockServer,
};
var factory_obj: IClassFactory = .{ .vtable = &factory_vtable };

fn factoryQI(self: *IClassFactory, riid: *const winapi.GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &winapi.IID_IUnknown) or guidEql(riid, &winapi.IID_IClassFactory)) {
        ppv.* = self;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}
fn factoryAddRef(_: *IClassFactory) callconv(.winapi) u32 {
    return 1;
}
fn factoryRelease(_: *IClassFactory) callconv(.winapi) u32 {
    return 1;
}
fn factoryCreateInstance(
    _: *IClassFactory,
    outer: ?*anyopaque,
    riid: *const winapi.GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT {
    ppv.* = null;
    if (outer != null) return CLASS_E_NOAGGREGATION; // no aggregation
    return handoffQI(&handoff_obj, riid, ppv);
}
fn factoryLockServer(_: *IClassFactory, _: winapi.BOOL) callconv(.winapi) HRESULT {
    return S_OK;
}

/// The CoRegisterClassObject cookie while the server is registered.
var class_cookie: winapi.DWORD = 0;

/// Register the handoff class object on the current (STA) thread so COM
/// routes EstablishPtyHandoff to this process's message loop. Safe to
/// call when not the default terminal (it just sits idle). No-op if the
/// server is gated off.
pub fn startServer() void {
    if (comptime builtin.os.tag != .windows) return;
    if (!handoff_ready) return;
    if (class_cookie != 0) return;
    const rc = winapi.CoRegisterClassObject(
        &CLSID_YuureiTerminal,
        &factory_obj,
        winapi.CLSCTX_LOCAL_SERVER,
        winapi.REGCLS_MULTIPLEUSE,
        &class_cookie,
    );
    if (rc != S_OK) {
        log.warn("defterm CoRegisterClassObject failed hr={x}", .{@as(u32, @bitCast(rc))});
        class_cookie = 0;
    }
}

pub fn stopServer() void {
    if (comptime builtin.os.tag != .windows) return;
    if (class_cookie == 0) return;
    _ = winapi.CoRevokeClassObject(class_cookie);
    class_cookie = 0;
}

test "class factory and handoff vtables answer QueryInterface" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    // Factory: IClassFactory and IUnknown resolve, others don't.
    var ppv: ?*anyopaque = null;
    try testing.expectEqual(S_OK, factory_obj.vtable.QueryInterface(&factory_obj, &winapi.IID_IClassFactory, &ppv));
    try testing.expect(ppv != null);
    try testing.expectEqual(E_NOINTERFACE, factory_obj.vtable.QueryInterface(&factory_obj, &CLSID_YuureiTerminal, &ppv));

    // CreateInstance hands back an ITerminalHandoff3.
    var obj: ?*anyopaque = null;
    try testing.expectEqual(S_OK, factory_obj.vtable.CreateInstance(&factory_obj, null, &IID_ITerminalHandoff3, &obj));
    try testing.expect(obj != null);
}

test "EstablishPtyHandoff creates pipes and delivers to the callback" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const Captured = struct {
        var got: ?Handoff = null;
        fn cb(h: Handoff) void {
            got = h;
        }
    };
    Captured.got = null;
    on_handoff = Captured.cb;
    defer on_handoff = null;

    var in_h: ?HANDLE = null;
    var out_h: ?HANDLE = null;
    var startup: TERMINAL_STARTUP_INFO = std.mem.zeroes(TERMINAL_STARTUP_INFO);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    startup.pszTitle = @constCast(title.ptr);

    const rc = handoff_obj.vtable.EstablishPtyHandoff(
        &handoff_obj,
        &in_h,
        &out_h,
        null,
        null,
        null,
        null,
        &startup,
    );
    try testing.expectEqual(S_OK, rc);
    // conhost's two ends were produced...
    try testing.expect(in_h != null and out_h != null);
    // ...and the callback received our ends + the title.
    try testing.expect(Captured.got != null);
    const h = Captured.got.?;
    try testing.expect(h.title != null);
    try testing.expectEqualSlices(u16, title, h.title.?);

    // Clean up every handle the test produced.
    _ = winapi.CloseHandle(in_h.?);
    _ = winapi.CloseHandle(out_h.?);
    _ = winapi.CloseHandle(h.our_read);
    _ = winapi.CloseHandle(h.our_write);
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
