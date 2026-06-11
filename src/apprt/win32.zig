//! Win32 apprt: the native Windows application runtime for Ghostty.
//!
//! Status: skeleton (WINDOWS_PORT_PLAN.md Phase 2). This registers the
//! runtime with the build and satisfies the comptime apprt interface so
//! the full Ghostty exe compiles for Windows. Per plan Rule 2, every
//! unimplemented runtime path is an explicit @panic — nothing here
//! returns fake success.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const winapi = @import("win32/winapi.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
}
