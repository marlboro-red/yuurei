const std = @import("std");
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const w = @import("../apprt/win32/winapi.zig");
const windows = std.os.windows;
const H = w.HANDLE;
const alloc = std.heap.c_allocator;
const build_identity = @import("../build_config.zig").version_string;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) H;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?H;
extern "kernel32" fn DuplicateHandle(H, H, H, *H, u32, w.BOOL, u32) callconv(.winapi) w.BOOL;
const Client = @This();

pipe: H,
io: transport.Io,
server_pid: u32,
notification: ?H = null,
server: ?H = null,
pub fn init(name: []const u8, stop: ?H) !Client {
    return connect(name, stop, false);
}
pub fn initControl(name: []const u8, stop: ?H) !Client {
    return connect(name, stop, true);
}
fn connect(name: []const u8, stop: ?H, control: bool) !Client {
    const identity = try transport.identity(GetCurrentProcess());
    const path = try transport.endpointName(name, identity, control);
    defer alloc.free(path);
    const pipe = w.CreateFileW(path, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED | 0x00110000, null);
    if (pipe == windows.INVALID_HANDLE_VALUE) return error.SessionUnavailable;
    errdefer _ = w.CloseHandle(pipe);
    const server_pid = try transport.peer(pipe, true, identity);
    var result: Client = .{ .pipe = pipe, .io = try transport.Io.init(stop), .server_pid = server_pid };
    errdefer _ = w.CloseHandle(result.io.event);
    var buf: [256]u8 = undefined;
    const response = try result.request(.hello, build_identity, 0, &buf);
    if (!std.mem.eql(u8, buf[0..response.length], build_identity)) return error.IncompatibleBuild;
    return result;
}
pub fn deinit(self: *Client) void {
    if (self.notification) |event| _ = w.CloseHandle(event);
    if (self.server) |process| _ = w.CloseHandle(process);
    _ = w.CloseHandle(self.io.event);
    _ = w.CloseHandle(self.pipe);
}
pub fn subscribe(self: *Client) !void {
    if (self.notification != null) return error.AlreadySubscribed;
    const process = OpenProcess(0x1000 | 0x40 | 0x100000, 0, self.server_pid) orelse return error.PeerIdentity;
    errdefer _ = w.CloseHandle(process);
    if (!std.mem.eql(u8, &(try transport.identity(GetCurrentProcess())), &(try transport.identity(process)))) return error.PeerIdentity;
    var bytes: [8]u8 = undefined;
    const reply = try self.request(.subscribe, "", 0, &bytes);
    if (reply.length != 8) return error.InvalidResponse;
    const remote: H = @ptrFromInt(std.mem.readInt(u64, &bytes, .little));
    var event: H = undefined;
    // The view only needs SYNCHRONIZE; it cannot reset/set the broker event.
    if (DuplicateHandle(process, remote, GetCurrentProcess(), &event, 0x100000, 0, 0) == 0) return error.DuplicateEvent;
    self.notification = event;
    self.server = process;
}
pub fn request(self: *Client, op: protocol.Op, payload: []const u8, sequence: u64, buffer: []u8) !protocol.Header {
    if (payload.len > protocol.max_request) return error.PayloadTooLarge;
    var bytes = (protocol.Header{ .op = op, .length = @intCast(payload.len), .sequence = sequence }).encode();
    try self.io.transfer(self.pipe, &bytes, true);
    try self.io.transfer(self.pipe, @constCast(payload), true);
    try self.io.transfer(self.pipe, &bytes, false);
    const header = try protocol.Header.decode(&bytes, @intCast(buffer.len));
    if (header.op == .resync and header.length == 0) return error.SessionHistoryExpired;
    if (header.op != op) return error.InvalidResponse;
    try self.io.transfer(self.pipe, buffer[0..header.length], false);
    return header;
}
