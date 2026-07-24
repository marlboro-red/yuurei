const std = @import("std");
const windows = std.os.windows;

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const unexpectedError = windows.unexpectedError;
pub const OpenFile = windows.OpenFile;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const SetHandleInformation = windows.SetHandleInformation;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = windows.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const FILE_SHARE_READ = windows.FILE_SHARE_READ;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const HANDLE = windows.HANDLE;
pub const HANDLE_FLAG_INHERIT = windows.HANDLE_FLAG_INHERIT;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const OPEN_EXISTING = windows.OPEN_EXISTING;
pub const PIPE_ACCESS_OUTBOUND = windows.PIPE_ACCESS_OUTBOUND;
pub const PIPE_TYPE_BYTE = windows.PIPE_TYPE_BYTE;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const S_OK = windows.S_OK;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;

// Toolhelp process snapshot, for the shell child-process check below.
pub const TH32CS_SNAPPROCESS: DWORD = 0x2;
pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [MAX_PATH]u16 = undefined,
};
pub extern "kernel32" fn CreateToolhelp32Snapshot(DWORD, DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn Process32NextW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetProcessId(HANDLE) callconv(.winapi) DWORD;

/// Whether the given process has any live child processes. Used as the
/// close-confirmation fallback for shells that can't report prompt
/// state via OSC 133 (cmd has no integration mechanism; wsl.exe is an
/// opaque launcher): an idle shell has no children, a running
/// vim/ssh/build does. Same approach as Windows Terminal, with the
/// same limits: processes inside a WSL VM are invisible, and an
/// orphaned grandchild whose intermediate parent exited is missed.
pub fn hasChildProcesses(root_pid: DWORD) bool {
    if (root_pid == 0) return false;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    defer CloseHandle(snap);

    var entry: PROCESSENTRY32W = .{};
    if (Process32FirstW(snap, &entry) == 0) return false;
    while (true) {
        if (entry.th32ParentProcessID == root_pid and
            entry.th32ProcessID != root_pid and
            !infrastructureProcess(&entry.szExeFile)) return true;
        if (Process32NextW(snap, &entry) == 0) return false;
    }
}

/// Console/WSL plumbing that a shell process spawns as part of merely
/// existing; their presence says nothing about user work in progress.
/// wsl.exe in particular always parents a nested wsl.exe (and a
/// conhost) even at an idle distro prompt.
fn infrastructureProcess(exe_file: *const [MAX_PATH]u16) bool {
    const len = std.mem.indexOfScalar(u16, exe_file, 0) orelse return false;
    var buf: [32]u8 = undefined;
    if (len > buf.len) return false;
    for (exe_file[0..len], 0..) |unit, i| {
        if (unit > 127) return false;
        buf[i] = std.ascii.toLower(@intCast(unit));
    }
    const name = buf[0..len];
    const ignored = [_][]const u8{
        "conhost.exe",
        "openconsole.exe",
        "wsl.exe",
        "wslhost.exe",
        "wslrelay.exe",
    };
    for (ignored) |ig| if (std.mem.eql(u8, name, ig)) return true;
    return false;
}

/// Attach to the parent process console, if any. The Ghostty exe is a
/// GUI-subsystem binary (no console window on launch), so when it is
/// run from a terminal it must attach to that terminal's console for
/// CLI output (`ghostty +version`) and logging to be visible. Called
/// once at startup; a no-op when there is no parent console (launched
/// from Explorer) or a console already exists.
pub fn attachParentConsole() void {
    if (exp.kernel32.GetConsoleWindow() != null) return;
    _ = exp.kernel32.AttachConsole(exp.ATTACH_PARENT_PROCESS);
}

/// Remove the Mark-of-the-Web (the Zone.Identifier alternate data
/// stream) from a file we ship and trust. Files extracted from a
/// downloaded release zip inherit the mark, and PowerShell's default
/// RemoteSigned policy then refuses to run our unsigned shell
/// integration script. The user already trusted the application
/// itself (SmartScreen) and the script ships beside it, so unblocking
/// it at injection time matches their intent. Failure (no mark
/// present, file read-only) is ignored.
pub fn unblockFile(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ads = std.fmt.bufPrint(
        &buf,
        "{s}:Zone.Identifier",
        .{path},
    ) catch return;

    var wbuf: [std.fs.max_path_bytes]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], ads) catch return;
    wbuf[len] = 0;
    _ = exp.kernel32.DeleteFileW(wbuf[0..len :0]);
}

/// Whether an executable can be found via the standard process search
/// path (the same order CreateProcessW uses).
pub fn isOnPath(name: []const u8) bool {
    var name_w: [windows.MAX_PATH:0]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(&name_w, name) catch return false;
    if (name_len >= name_w.len) return false;
    name_w[name_len] = 0;

    var buf: [windows.MAX_PATH:0]u16 = undefined;
    const len = exp.kernel32.SearchPathW(
        null,
        name_w[0..name_len :0],
        null,
        buf.len,
        &buf,
        null,
    );
    return len > 0 and len < buf.len;
}

/// ConPTY entry points, resolved on first use. A conpty.dll next to
/// the executable (vendored OpenConsole; MIT, from the Windows Terminal
/// project — see WINDOWS_PORT_PLAN.md) is preferred so ConPTY behavior
/// ships on our release schedule rather than the user's Windows build;
/// otherwise the OS console host via kernel32 is used. Only the
/// application directory is searched for the DLL, never the working
/// directory.
pub const conpty = struct {
    const log = std.log.scoped(.conpty);

    const CreateFn = *const fn (
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        dwFlags: windows.DWORD,
        phPC: *exp.HPCON,
    ) callconv(.winapi) windows.HRESULT;
    const ResizeFn = *const fn (
        hPC: exp.HPCON,
        size: windows.COORD,
    ) callconv(.winapi) windows.HRESULT;
    const CloseFn = *const fn (hPC: exp.HPCON) callconv(.winapi) void;
    // Adopt a ConPTY handed to us by conhost (default-terminal handoff):
    // packs the handed-off server/reference/signal handles into a real
    // HPCON we can resize/close normally. Only the vendored OpenConsole
    // conpty.dll exports this (ConptyPackPseudoConsole); the OS kernel32
    // ConPTY does not, so it stays optional.
    const PackFn = *const fn (
        hServerProcess: windows.HANDLE,
        hRef: windows.HANDLE,
        hSignal: windows.HANDLE,
        phPC: *exp.HPCON,
    ) callconv(.winapi) windows.HRESULT;

    var create_fn: CreateFn = undefined;
    var resize_fn: ResizeFn = undefined;
    var close_fn: CloseFn = undefined;
    var pack_fn: ?PackFn = null;
    var once = std.once(resolve);

    fn resolve() void {
        vendored: {
            const module = exp.kernel32.LoadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
                null,
                exp.LOAD_LIBRARY_SEARCH_APPLICATION_DIR,
            ) orelse break :vendored;
            const create = windows.kernel32.GetProcAddress(
                module,
                "CreatePseudoConsole",
            ) orelse break :vendored;
            const resize = windows.kernel32.GetProcAddress(
                module,
                "ResizePseudoConsole",
            ) orelse break :vendored;
            const close = windows.kernel32.GetProcAddress(
                module,
                "ClosePseudoConsole",
            ) orelse break :vendored;

            create_fn = @ptrCast(create);
            resize_fn = @ptrCast(resize);
            close_fn = @ptrCast(close);
            // Optional: only present in the vendored OpenConsole DLL, used
            // for default-terminal handoff adoption.
            if (windows.kernel32.GetProcAddress(module, "ConptyPackPseudoConsole")) |pack| {
                pack_fn = @ptrCast(pack);
            }
            log.info("using vendored conpty.dll", .{});
            return;
        }

        create_fn = exp.kernel32.CreatePseudoConsole;
        resize_fn = exp.kernel32.ResizePseudoConsole;
        close_fn = exp.kernel32.ClosePseudoConsole;
        log.info("using OS ConPTY (kernel32)", .{});
    }

    pub fn createPseudoConsole(
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        dwFlags: windows.DWORD,
        phPC: *exp.HPCON,
    ) windows.HRESULT {
        once.call();
        return create_fn(size, hInput, hOutput, dwFlags, phPC);
    }

    pub fn resizePseudoConsole(
        hPC: exp.HPCON,
        size: windows.COORD,
    ) windows.HRESULT {
        once.call();
        return resize_fn(hPC, size);
    }

    pub fn closePseudoConsole(hPC: exp.HPCON) void {
        once.call();
        close_fn(hPC);
    }

    /// Adopt a handed-off ConPTY. Consumes the server/reference/signal
    /// handles into the returned HPCON (released by closePseudoConsole),
    /// so the caller must not close them separately on success. Errors if
    /// the running conpty.dll doesn't export the pack entry point (the OS
    /// ConPTY doesn't); default-terminal handoff requires the vendored DLL.
    pub fn packPseudoConsole(
        hServerProcess: windows.HANDLE,
        hRef: windows.HANDLE,
        hSignal: windows.HANDLE,
        phPC: *exp.HPCON,
    ) error{Unsupported}!windows.HRESULT {
        once.call();
        const f = pack_fn orelse return error.Unsupported;
        return f(hServerProcess, hRef, hSignal, phPC);
    }
};

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const LOAD_LIBRARY_SEARCH_APPLICATION_DIR: windows.DWORD = 0x00000200;

    pub const ATTACH_PARENT_PROCESS: windows.DWORD = 0xFFFFFFFF;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: windows.LPSTR,
            nSize: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: windows.DWORD,
            lpBuffer: windows.LPWSTR,
        ) callconv(.winapi) windows.DWORD;
        pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?windows.HWND;
        pub extern "kernel32" fn DeleteFileW(
            lpFileName: [*:0]const u16,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: [*:0]const u16,
            hFile: ?windows.HANDLE,
            dwFlags: windows.DWORD,
        ) callconv(.winapi) ?windows.HMODULE;
        pub extern "kernel32" fn AttachConsole(
            dwProcessId: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SearchPathW(
            lpPath: ?windows.LPCWSTR,
            lpFileName: windows.LPCWSTR,
            lpExtension: ?windows.LPCWSTR,
            nBufferLength: windows.DWORD,
            lpBuffer: windows.LPWSTR,
            lpFilePart: ?*?windows.LPWSTR,
        ) callconv(.winapi) windows.DWORD;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};
