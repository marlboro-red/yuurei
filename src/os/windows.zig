const std = @import("std");
const windows = std.os.windows;

/// Zig 0.16 commits the requested stack size on Windows rather than only
/// reserving address space. Its 16 MiB default costs 48 MiB for a surface's
/// renderer, I/O dispatcher, and reader. Keep a conservative 4 MiB per worker.
pub const worker_thread_config: std.Thread.SpawnConfig = .{
    .stack_size = 4 * 1024 * 1024,
};

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
// Fork (yuurei): the Windows-port helpers below call CloseHandle bare.
pub const CloseHandle = windows.CloseHandle;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const DELETE = 0x00010000;
pub const ERROR_SUCCESS = 0;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const S_OK = 0;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const exp = struct {
    // Fork (yuurei) additions used by the Windows port.
    pub const LOAD_LIBRARY_SEARCH_APPLICATION_DIR: windows.DWORD = 0x00000200;
    pub const ATTACH_PARENT_PROCESS: windows.DWORD = 0xFFFFFFFF;

    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        // Fork (yuurei) additions: console attach, DLL load, path search,
        // file unblock — used by the Windows port helpers below.
        // Zig 0.16 removed std.os.windows.kernel32.GetProcAddress too.
        pub extern "kernel32" fn GetProcAddress(
            hModule: windows.HMODULE,
            lpProcName: [*:0]const u8,
        ) callconv(.winapi) ?windows.FARPROC;
        pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?windows.HWND;
        pub extern "kernel32" fn DeleteFileW(
            lpFileName: [*:0]const u16,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: [*:0]const u16,
            hFile: ?windows.HANDLE,
            dwFlags: windows.DWORD,
        ) callconv(.winapi) ?windows.HMODULE;
        pub extern "kernel32" fn FreeLibrary(
            hLibModule: windows.HMODULE,
        ) callconv(.winapi) windows.BOOL;
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
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: [*]const u8,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

// ====================================================================
// Fork (yuurei) Windows-port additions: child-process detection (close
// confirmation), console attach, file unblock, PATH search, and the
// vendored-ConPTY wrapper (createPseudoConsole..reparentPseudoConsole).
// ====================================================================
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

// Process creation-time lookup, to reject Toolhelp PID-reuse false
// positives in hasChildProcesses (a recycled parent PID can make an
// unrelated orphan look like a child).
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const FILETIME = extern struct {
    dwLowDateTime: DWORD = 0,
    dwHighDateTime: DWORD = 0,
};
pub extern "kernel32" fn OpenProcess(DWORD, windows.BOOL, DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetProcessTimes(HANDLE, *FILETIME, *FILETIME, *FILETIME, *FILETIME) callconv(.winapi) windows.BOOL;

/// A process's creation time as a raw 100ns tick count, or null if it
/// can't be opened/queried.
fn processCreationTime(pid: DWORD) ?u64 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) orelse return null;
    defer CloseHandle(h);
    var creation: FILETIME = .{};
    var exit_t: FILETIME = .{};
    var kernel_t: FILETIME = .{};
    var user_t: FILETIME = .{};
    if (GetProcessTimes(h, &creation, &exit_t, &kernel_t, &user_t) == FALSE) return null;
    return (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
}

/// Whether `child_pid` looks like a PID-reuse ghost of `root_created`: a
/// genuine child is created no earlier than its parent, so a "child" that
/// predates root means root's PID was recycled onto an unrelated tree.
/// Conservative: if either timestamp is unavailable, not treated as reuse.
fn pidReused(root_created: ?u64, child_pid: DWORD) bool {
    const rc = root_created orelse return false;
    const cc = processCreationTime(child_pid) orelse return false;
    return cc < rc;
}

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

    // First pass: identify the root's own image so we can tell a WSL
    // *profile* tab (root is wsl.exe, whose nested wsl.exe/wslhost/relay
    // are plumbing) from an ordinary shell in which the user ran `wsl`
    // (that child wsl.exe is a real interactive session and must block a
    // silent close).
    var entry: PROCESSENTRY32W = .{};
    if (Process32FirstW(snap, &entry) == FALSE) return false;
    var root_is_wsl = false;
    while (true) {
        if (entry.th32ProcessID == root_pid) {
            root_is_wsl = exeNameIs(&entry.szExeFile, "wsl.exe");
            break;
        }
        if (Process32NextW(snap, &entry) == FALSE) break;
    }

    // Second pass: any non-infrastructure child means work in progress.
    // Guard against PID reuse (a recycled root_pid attracting an unrelated
    // orphan) by rejecting any "child" created before root.
    const root_created = processCreationTime(root_pid);
    if (Process32FirstW(snap, &entry) == FALSE) return false;
    while (true) {
        if (entry.th32ParentProcessID == root_pid and
            entry.th32ProcessID != root_pid and
            !infrastructureProcess(&entry.szExeFile, root_is_wsl) and
            !pidReused(root_created, entry.th32ProcessID)) return true;
        if (Process32NextW(snap, &entry) == FALSE) return false;
    }
}

/// Lowercased ASCII image name of a PROCESSENTRY32W, into `buf`. Null if
/// the name is non-ASCII or longer than `buf`.
fn exeNameLower(exe_file: *const [MAX_PATH]u16, buf: []u8) ?[]const u8 {
    const len = std.mem.indexOfScalar(u16, exe_file, 0) orelse return null;
    if (len > buf.len) return null;
    for (exe_file[0..len], 0..) |unit, i| {
        if (unit > 127) return null;
        buf[i] = std.ascii.toLower(@intCast(unit));
    }
    return buf[0..len];
}

fn exeNameIs(exe_file: *const [MAX_PATH]u16, comptime name: []const u8) bool {
    var buf: [32]u8 = undefined;
    const got = exeNameLower(exe_file, &buf) orelse return false;
    return std.mem.eql(u8, got, name);
}

/// Console/WSL plumbing whose presence says nothing about user work.
/// conhost/OpenConsole are console hosts under any shell. The wsl.exe
/// launcher processes are plumbing ONLY inside a WSL-profile tab
/// (`root_is_wsl`): a WSL shell always parents a nested wsl.exe (and a
/// conhost) even at an idle prompt. Under an ordinary shell, a wsl.exe
/// child IS the user's interactive session, so it is not ignored.
fn infrastructureProcess(exe_file: *const [MAX_PATH]u16, root_is_wsl: bool) bool {
    var buf: [32]u8 = undefined;
    const name = exeNameLower(exe_file, &buf) orelse return false;

    if (std.mem.eql(u8, name, "conhost.exe")) return true;
    if (std.mem.eql(u8, name, "openconsole.exe")) return true;

    if (root_is_wsl) {
        if (std.mem.eql(u8, name, "wsl.exe")) return true;
        if (std.mem.eql(u8, name, "wslhost.exe")) return true;
        if (std.mem.eql(u8, name, "wslrelay.exe")) return true;
    }
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
        phPC: *HPCON,
    ) callconv(.winapi) HRESULT;
    const ResizeFn = *const fn (
        hPC: HPCON,
        size: windows.COORD,
    ) callconv(.winapi) HRESULT;
    const CloseFn = *const fn (hPC: HPCON) callconv(.winapi) void;
    // Adopt a ConPTY handed to us by conhost (default-terminal handoff):
    // packs the handed-off server/reference/signal handles into a real
    // HPCON we can resize/close normally. Only the vendored OpenConsole
    // conpty.dll exports this (ConptyPackPseudoConsole); the OS kernel32
    // ConPTY does not, so it stays optional.
    const PackFn = *const fn (
        hServerProcess: windows.HANDLE,
        hRef: windows.HANDLE,
        hSignal: windows.HANDLE,
        phPC: *HPCON,
    ) callconv(.winapi) HRESULT;
    // Reparent a (packed) ConPTY's pseudo-window to a real terminal
    // window. Microsoft's handoff receiver does this after packing so the
    // ConPTY is bound to the terminal HWND; also the step that appears to
    // let ResizePseudoConsole accept a packed HPCON. Vendored-DLL only.
    const ReparentFn = *const fn (
        hPC: HPCON,
        hwnd: windows.HWND,
    ) callconv(.winapi) HRESULT;

    var create_fn: CreateFn = undefined;
    var resize_fn: ResizeFn = undefined;
    var close_fn: CloseFn = undefined;
    var pack_fn: ?PackFn = null;
    var reparent_fn: ?ReparentFn = null;
    // One-time init, safe against concurrent first callers (renderer/io
    // threads can race the first pty open). A plain "checked boolean"
    // is not enough: two threads passing the check would both run
    // resolve() and race on the non-atomic function-pointer globals.
    // Losers of the claim spin until the winner publishes; resolution is
    // a handful of LoadLibrary/GetProcAddress calls, so the wait is
    // bounded and only ever paid once per process.
    const ResolveState = enum(u8) { uninit, busy, done };
    var resolve_state: std.atomic.Value(ResolveState) = .init(.uninit);
    fn ensureResolved() void {
        while (true) {
            switch (resolve_state.load(.acquire)) {
                .done => return,
                .uninit => if (resolve_state.cmpxchgWeak(
                    .uninit,
                    .busy,
                    .acquire,
                    .monotonic,
                ) == null) {
                    resolve();
                    resolve_state.store(.done, .release);
                    return;
                },
                .busy => std.atomic.spinLoopHint(),
            }
        }
    }

    fn resolve() void {
        vendored: {
            const module = exp.kernel32.LoadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
                null,
                exp.LOAD_LIBRARY_SEARCH_APPLICATION_DIR,
            ) orelse break :vendored;
            // A conpty.dll missing a mandatory export is unusable:
            // release it before falling back so the module doesn't leak.
            const create = exp.kernel32.GetProcAddress(
                module,
                "CreatePseudoConsole",
            ) orelse {
                _ = exp.kernel32.FreeLibrary(module);
                break :vendored;
            };
            const resize = exp.kernel32.GetProcAddress(
                module,
                "ResizePseudoConsole",
            ) orelse {
                _ = exp.kernel32.FreeLibrary(module);
                break :vendored;
            };
            const close = exp.kernel32.GetProcAddress(
                module,
                "ClosePseudoConsole",
            ) orelse {
                _ = exp.kernel32.FreeLibrary(module);
                break :vendored;
            };

            create_fn = @ptrCast(create);
            resize_fn = @ptrCast(resize);
            close_fn = @ptrCast(close);
            // Optional: only present in the vendored OpenConsole DLL, used
            // for default-terminal handoff adoption.
            if (exp.kernel32.GetProcAddress(module, "ConptyPackPseudoConsole")) |pack| {
                pack_fn = @ptrCast(pack);
            }
            if (exp.kernel32.GetProcAddress(module, "ConptyReparentPseudoConsole")) |reparent| {
                reparent_fn = @ptrCast(reparent);
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
        phPC: *HPCON,
    ) HRESULT {
        ensureResolved();
        return create_fn(size, hInput, hOutput, dwFlags, phPC);
    }

    pub fn resizePseudoConsole(
        hPC: HPCON,
        size: windows.COORD,
    ) HRESULT {
        ensureResolved();
        return resize_fn(hPC, size);
    }

    pub fn closePseudoConsole(hPC: HPCON) void {
        ensureResolved();
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
        phPC: *HPCON,
    ) error{Unsupported}!HRESULT {
        ensureResolved();
        const f = pack_fn orelse return error.Unsupported;
        return f(hServerProcess, hRef, hSignal, phPC);
    }

    /// Bind a (packed) handoff HPCON to a real terminal window. Errors if
    /// the running conpty.dll lacks the entry point.
    pub fn reparentPseudoConsole(
        hPC: HPCON,
        hwnd: windows.HWND,
    ) error{Unsupported}!HRESULT {
        ensureResolved();
        const f = reparent_fn orelse return error.Unsupported;
        return f(hPC, hwnd);
    }
};
