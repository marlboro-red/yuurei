//! Bounded, whole-event replay history. Cursors are absolute byte positions,
//! including record headers. A stale reader fails rather than skipping output.
const Journal = @This();
const std = @import("std");
pub const capacity = 1024 * 1024;
pub const header_size = 8;
pub const Kind = enum(u8) { output = 1, resize = 2 };
bytes: [capacity]u8 = undefined,
first: u64 = 1,
end: u64 = 1,

/// Whether an append preserves every event at or after the protected cursor.
pub fn canAppend(self: *const Journal, cursor: u64, len: usize) bool {
    return cursor >= self.first and cursor <= self.end and
        len + header_size <= capacity and self.end - cursor <= capacity - len - header_size;
}

fn copyOut(self: *const Journal, position: u64, out: []u8) void {
    const start: usize = @intCast(position % capacity);
    const n = @min(out.len, capacity - start);
    @memcpy(out[0..n], self.bytes[start..][0..n]);
    @memcpy(out[n..], self.bytes[0 .. out.len - n]);
}

fn put(self: *Journal, data: []const u8) void {
    const start: usize = @intCast(self.end % capacity);
    const n = @min(data.len, capacity - start);
    @memcpy(self.bytes[start..][0..n], data[0..n]);
    @memcpy(self.bytes[0 .. data.len - n], data[n..]);
    self.end += data.len;
}

pub fn append(self: *Journal, kind: Kind, data: []const u8) void {
    std.debug.assert(data.len + header_size <= capacity);
    while (self.end - self.first + data.len + header_size > capacity) {
        var header: [header_size]u8 = undefined;
        self.copyOut(self.first, &header);
        self.first += header_size + std.mem.readInt(u32, header[0..4], .little);
    }
    var header: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], @intCast(data.len), .little);
    header[4] = @intFromEnum(kind);
    self.put(&header);
    self.put(data);
}

pub fn read(self: *const Journal, cursor: u64, out: []u8) ![]const u8 {
    if (cursor < self.first or cursor > self.end) return error.StaleCursor;
    if (cursor == self.end) return out[0..0];
    // Check boundaries even for an authenticated caller; an arbitrary offset
    // must never be interpreted as a valid event stream.
    var position = self.first;
    while (position < cursor) {
        var header: [header_size]u8 = undefined;
        self.copyOut(position, &header);
        position += header_size + std.mem.readInt(u32, header[0..4], .little);
    }
    if (position != cursor) return error.InvalidCursor;
    const len: usize = @intCast(self.end - cursor);
    if (len > out.len) return error.BufferTooSmall;
    self.copyOut(cursor, out[0..len]);
    return out[0..len];
}

pub const Event = struct { kind: Kind, data: []const u8 };
pub fn next(data: *[]const u8) !?Event {
    if (data.len == 0) return null;
    if (data.len < header_size) return error.TruncatedEvent;
    const len = std.mem.readInt(u32, data.*[0..4], .little);
    if (len > data.len - header_size) return error.TruncatedEvent;
    const kind = std.enums.fromInt(Kind, data.*[4]) orelse return error.InvalidEvent;
    if (!std.mem.eql(u8, data.*[5..8], &.{ 0, 0, 0 })) return error.InvalidEvent;
    if (kind == .resize and len != 4) return error.InvalidEvent;
    const result: Event = .{ .kind = kind, .data = data.*[header_size..][0..len] };
    data.* = data.*[header_size + len ..];
    return result;
}

test "mux journal wraps evicts whole events and rejects stale cursors" {
    const t = std.testing;
    const journal = try t.allocator.create(Journal);
    defer t.allocator.destroy(journal);
    journal.* = .{};
    const out = try t.allocator.alloc(u8, capacity);
    defer t.allocator.free(out);
    const chunk = [_]u8{'x'} ** 65536;
    const initial = journal.end;
    for (0..32) |_| journal.append(.output, &chunk);
    try t.expectError(error.StaleCursor, journal.read(initial, out));
    try t.expectError(error.InvalidCursor, journal.read(journal.first + 1, out));
    var data = try journal.read(journal.first, out);
    var count: usize = 0;
    while (try next(&data)) |event| {
        try t.expectEqualSlices(u8, &chunk, event.data);
        count += 1;
    }
    try t.expectEqual(@as(usize, 15), count);
    const cursor = journal.end;
    journal.append(.resize, &.{ 80, 0, 24, 0 });
    var tail = try journal.read(cursor, out);
    try t.expectEqual(Kind.resize, (try next(&tail)).?.kind);
    try t.expectEqual(@as(?Event, null), try next(&tail));
    try t.expectEqual(@as(usize, 0), (try journal.read(journal.end, out)).len);
}

test "mux journal refuses incomplete events" {
    var bytes: []const u8 = &.{ 4, 0, 0, 0, 2, 0, 0, 0, 80 };
    try std.testing.expectError(error.TruncatedEvent, next(&bytes));
}

test "mux protected cursor prevents overwrite and advances after delivery" {
    const t = std.testing;
    const journal = try t.allocator.create(Journal);
    defer t.allocator.destroy(journal);
    journal.* = .{};
    const out = try t.allocator.alloc(u8, capacity);
    defer t.allocator.free(out);
    const chunk = [_]u8{'x'} ** 65536;
    var cursor = journal.end;
    for (0..8) |_| {
        var count: usize = 0;
        while (journal.canAppend(cursor, chunk.len + header_size + 4)) {
            journal.append(.output, &chunk);
            count += 1;
        }
        try t.expectEqual(@as(usize, 15), count);
        try t.expect(journal.canAppend(cursor, 4));
        journal.append(.resize, &.{ 80, 0, 24, 0 });
        var events = try journal.read(cursor, out);
        while (try next(&events)) |event| {
            if (event.kind == .output) try t.expectEqualSlices(u8, &chunk, event.data);
        }
        cursor = journal.end;
    }
    try t.expect(!journal.canAppend(journal.first - 1, 1));
    try t.expect(!journal.canAppend(journal.end + 1, 1));
    try t.expect(!journal.canAppend(cursor, capacity));
}
