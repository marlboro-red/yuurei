//! Experimental local protocol. Fixed little-endian framing; no native structs
//! cross the wire. Version mismatches fail before payload allocation or input.
const std = @import("std");
pub const header_size = 24;
pub const max_request = 64 * 1024;
pub const max_response = 16 * 1024 * 1024;
pub const Op = enum(u16) { status = 1, snapshot = 2, input = 3, resize = 4, stop = 5, hello = 6, events = 7, resync = 8, subscribe = 9 };
pub const Header = struct {
    op: Op,
    length: u32,
    sequence: u64 = 0,

    pub fn encode(self: Header) [header_size]u8 {
        var bytes: [header_size]u8 = @splat(0);
        bytes[0..4].* = "YMUX".*;
        std.mem.writeInt(u16, bytes[4..6], 3, .little);
        std.mem.writeInt(u16, bytes[6..8], @intFromEnum(self.op), .little);
        std.mem.writeInt(u32, bytes[8..12], self.length, .little);
        std.mem.writeInt(u64, bytes[16..24], self.sequence, .little);
        return bytes;
    }

    pub fn decode(bytes: *const [header_size]u8, limit: u32) !Header {
        if (!std.mem.eql(u8, bytes[0..4], "YMUX")) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != 3) return error.IncompatibleVersion;
        if (std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidFlags;
        const op = std.enums.fromInt(Op, std.mem.readInt(u16, bytes[6..8], .little)) orelse return error.InvalidOperation;
        const length = std.mem.readInt(u32, bytes[8..12], .little);
        if (length > limit) return error.PayloadTooLarge;
        return .{ .op = op, .length = length, .sequence = std.mem.readInt(u64, bytes[16..24], .little) };
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

test "mux framing validates versions bounds flags and operations" {
    const t = std.testing;
    var bytes = (Header{ .op = .snapshot, .length = 1024, .sequence = 0x123456789abcdef }).encode();
    const decoded = try Header.decode(&bytes, max_response);
    try t.expectEqual(@as(u64, 0x123456789abcdef), decoded.sequence);
    try t.expectError(error.PayloadTooLarge, Header.decode(&bytes, 1023));
    bytes[4] = 1;
    try t.expectError(error.IncompatibleVersion, Header.decode(&bytes, max_response));
    bytes[4] = 3;
    bytes[12] = 1;
    try t.expectError(error.InvalidFlags, Header.decode(&bytes, max_response));
    bytes[12] = 0;
    bytes[6] = 255;
    try t.expectError(error.InvalidOperation, Header.decode(&bytes, max_response));
    bytes[0] = 0;
    try t.expectError(error.InvalidMagic, Header.decode(&bytes, max_response));
}

test "mux endpoint names cannot escape the local namespace" {
    for ([_][]const u8{ "", "../test", "a\\b", "a b", "日本語" }) |name| try std.testing.expect(!validName(name));
    try std.testing.expect(validName("probe-1_A"));
}
