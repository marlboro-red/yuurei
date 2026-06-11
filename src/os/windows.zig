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

    var create_fn: CreateFn = undefined;
    var resize_fn: ResizeFn = undefined;
    var close_fn: CloseFn = undefined;
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
