//! Convert the VT library's raw OSC 7 metadata into a safe local Windows path.
const std = @import("std");

pub fn decode(value: []const u8, buffer: []u8) ?[]const u8 {
    const uri = std.mem.startsWith(u8, value, "file://");
    const raw = if (uri) block: {
        const after = value[7..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        const host = after[0..slash];
        if (host.len > 0 and !(@import("../os/hostname.zig").isLocal(host) catch false)) return null;
        break :block after[slash + 1 ..];
    } else value;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n == buffer.len) return null;
        var byte = raw[i];
        if (uri and byte == '%') {
            if (i + 2 >= raw.len) return null;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return null;
            byte = hi * 16 + lo;
            i += 2;
        }
        if (byte < 0x20 or byte == 0x7f) return null;
        buffer[n] = if (byte == '/') '\\' else byte;
        n += 1;
        i += 1;
    }
    const path = buffer[0..n];
    if (n < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') return null;
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    return path;
}

pub fn normalize(terminal: *@import("../terminal/main.zig").Terminal) void {
    const raw = terminal.getPwd() orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    terminal.setPwd(decode(raw, &buffer) orelse "") catch {};
}

pub fn changed(handler: *@import("../terminal/stream_terminal.zig").Handler) void {
    normalize(handler.terminal);
}

test "mux cwd decodes local file URLs and rejects unsafe or invalid paths" {
    const t = std.testing;
    var buffer: [1024]u8 = undefined;
    try t.expectEqualStrings("C:\\Users\\working directory\\日本語", decode("file://localhost/C:/Users/working%20directory/%E6%97%A5%E6%9C%AC%E8%AA%9E", &buffer).?);
    try t.expectEqualStrings("C:\\", decode("file:///C:/", &buffer).?);
    try t.expectEqualStrings("C:\\literal%20name", decode("C:/literal%20name", &buffer).?);
    for ([_][]const u8{ "file://remote.invalid/C:/tmp", "file:////server/share", "file:///C:/bad%00name", "file:///C:/bad%XY", "file:///tmp", "relative", "\\\\server\\share" }) |value|
        try t.expect(decode(value, &buffer) == null);
}
