const std = @import("std");
const winapi = @import("winapi.zig");

/// TranslateMessage can produce several UTF-16 units for one keydown:
/// surrogate pairs, ligatures, or an accent plus an uncomposable letter.
/// Consume the complete translation before dispatching another keydown.
pub fn take(alloc: std.mem.Allocator, hwnd: winapi.HWND) ![]u8 {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(alloc);
    var msg: winapi.MSG = undefined;
    while (winapi.PeekMessageW(&msg, hwnd, winapi.WM_CHAR, winapi.WM_CHAR, winapi.PM_REMOVE) != 0) {
        try units.append(alloc, @truncate(msg.wParam));
    }
    return std.unicode.utf16LeToUtf8Alloc(alloc, units.items);
}

pub fn takeDead(hwnd: winapi.HWND) bool {
    var msg: winapi.MSG = undefined;
    // Leaving a dead char queued lets the next keydown mistake it for its
    // own translation when both keydowns arrived before the UI drained them.
    if (winapi.PeekMessageW(&msg, hwnd, winapi.WM_DEADCHAR, winapi.WM_DEADCHAR, winapi.PM_REMOVE) != 0)
        return true;
    return winapi.PeekMessageW(&msg, hwnd, winapi.WM_SYSDEADCHAR, winapi.WM_SYSDEADCHAR, winapi.PM_REMOVE) != 0;
}

test "windows key text drains dead-key pairs and surrogate pairs" {
    const testing = std.testing;
    const hwnd = winapi.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 1, 1, null, null, winapi.GetModuleHandleW(null).?, null) orelse return error.CreateWindowFailed;
    defer _ = winapi.DestroyWindow(hwnd);

    try testing.expect(winapi.PostMessageW(hwnd, winapi.WM_DEADCHAR, '\'', 0) != 0);
    try testing.expect(takeDead(hwnd));
    try testing.expect(!takeDead(hwnd));
    for ([_]u16{ '\'', 'x', 0xD83D, 0xDE00 }) |unit|
        try testing.expect(winapi.PostMessageW(hwnd, winapi.WM_CHAR, unit, 0) != 0);
    const text = try take(testing.allocator, hwnd);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("'x\u{1F600}", text);
    const remaining = try take(testing.allocator, hwnd);
    defer testing.allocator.free(remaining);
    try testing.expectEqualStrings("", remaining);
}
