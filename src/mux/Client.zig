const std = @import("std");
const transport = @import("transport.zig");
const protocol = @import("protocol.zig");
const w = @import("../apprt/win32/winapi.zig");
const windows = std.os.windows;
const H = w.HANDLE;
const alloc = std.heap.c_allocator;
const build_identity = @import("../build_config.zig").version_string;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) H;
const Client = @This();

pipe: H,
io: transport.Io,
pub fn init(name: []const u8, stop: ?H) !Client {
    const identity = try transport.identity(GetCurrentProcess());
    const path = try transport.pipeName(name, identity);
    defer alloc.free(path);
    const pipe = w.CreateFileW(path, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED | 0x00110000, null);
    if (pipe == windows.INVALID_HANDLE_VALUE) return error.SessionUnavailable;
    errdefer _ = w.CloseHandle(pipe);
    _ = try transport.peer(pipe, true, identity);
    var result: Client = .{ .pipe = pipe, .io = try transport.Io.init(stop) };
    errdefer _ = w.CloseHandle(result.io.event);
    var buf: [256]u8 = undefined;
    const response = try result.request(.hello, build_identity, 0, &buf);
    if (!std.mem.eql(u8, buf[0..response.length], build_identity)) return error.IncompatibleBuild;
    return result;
}
pub fn deinit(self: *Client) void {
    _ = w.CloseHandle(self.io.event);
    _ = w.CloseHandle(self.pipe);
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
