//! Quote dropped paths for the shell launched in a surface.
const std = @import("std");

pub fn appendPath(alloc: std.mem.Allocator, out: *std.ArrayList(u8), exe: []const u8, path: []const u8) !void {
    const name = std.fs.path.basename(exe);
    const powershell = std.ascii.eqlIgnoreCase(name, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(name, "pwsh") or
        std.ascii.eqlIgnoreCase(name, "powershell.exe") or
        std.ascii.eqlIgnoreCase(name, "powershell");

    if (powershell) {
        // Double quotes expand variables and subexpressions in PowerShell.
        // Its parser also recognizes typographic apostrophes as quotes.
        try out.append(alloc, '\'');
        var it = (try std.unicode.Utf8View.init(path)).iterator();
        while (it.nextCodepointSlice()) |cp| {
            try out.appendSlice(alloc, cp);
            const value = try std.unicode.utf8Decode(cp);
            switch (value) {
                '\'', 0x2018, 0x2019, 0x201A, 0x201B => try out.appendSlice(alloc, cp),
                else => {},
            }
        }
        try out.append(alloc, '\'');
    } else {
        const quote = std.mem.indexOfAny(u8, path, " \t&^=;,'`(){}[]!") != null;
        if (quote) try out.append(alloc, '"');
        try out.appendSlice(alloc, path);
        if (quote) try out.append(alloc, '"');
    }
}

test "windows dropped PowerShell paths are literal" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendPath(alloc, &out, "C:\\Program Files\\PowerShell\\7\\PWSH.EXE", "C:\\a' b\\$(1+2)`$HOME.txt");
    try std.testing.expectEqualStrings("'C:\\a'' b\\$(1+2)`$HOME.txt'", out.items);
    out.clearRetainingCapacity();
    try appendPath(alloc, &out, "powershell", "C:\\a\u{2019}b.txt");
    try std.testing.expectEqualStrings("'C:\\a\u{2019}\u{2019}b.txt'", out.items);
    out.clearRetainingCapacity();
    try appendPath(alloc, &out, "cmd.exe", "C:\\a b.txt");
    try std.testing.expectEqualStrings("\"C:\\a b.txt\"", out.items);
}
