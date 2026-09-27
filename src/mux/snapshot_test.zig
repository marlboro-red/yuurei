const std = @import("std");
const terminal = @import("../terminal/main.zig");
const snapshot = @import("../terminal/snapshot/main.zig");
const Stream = @import("../terminal/stream_terminal.zig").Stream;

test "mux snapshot reconnect preserves pending UTF8 CSI OSC and both screens" {
    const t = std.testing;
    const cases = [_]struct { before: []const u8, after: []const u8 }{
        .{ .before = "primary\r\n\xe6\x97", .after = "\xa5\xe6\x9c\xac\xe8\xaa\x9e" },
        .{ .before = "primary\x1b[?1049h\x1b[31", .after = "mALT\x1b[0m" },
        .{ .before = "primary\x1b]2;pending", .after = " title\x07done" },
        .{ .before = "primary\x1b[?1049hALT", .after = "\x1b[?1049l restored" },
    };
    for (cases) |case| {
        var source = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 40, .rows = 5 });
        defer source.deinit(t.allocator);
        var stream = Stream.init(.{ .allocator = t.allocator, .handler = source.vtHandler(), .continuation_max_bytes = 65536 });
        defer stream.deinit();
        stream.nextSlice("history1\r\nhistory2\r\nhistory3\r\nhistory4\r\nhistory5\r\nhistory6\r\n");
        stream.nextSlice(case.before);
        var continuation: std.Io.Writer.Allocating = .init(t.allocator);
        defer continuation.deinit();
        try stream.writeContinuation(&continuation.writer);
        var encoded: std.Io.Writer.Allocating = .init(t.allocator);
        defer encoded.deinit();
        try snapshot.encode(t.allocator, &encoded.writer, &source, .{ .continuation = .{ .bytes = continuation.written() } });
        var reader: std.Io.Reader = .fixed(encoded.written());
        var decoded = try snapshot.decode(t.allocator, t.io, &reader, .{ .max_continuation_bytes = 65536 });
        defer decoded.deinit(t.allocator);
        var restored = decoded.toOwned();
        defer restored.deinit(t.allocator);
        var live = Stream.init(.{ .allocator = t.allocator, .handler = restored.vtHandler(), .continuation_max_bytes = 65536 });
        defer live.deinit();
        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| live.nextSlice(bytes),
        }
        live.nextSlice(case.after);
        stream.nextSlice(case.after);
        // Compare complete binary terminal state, including the inactive screen,
        // scrollback, modes, cursor and parser continuation after reconnect.
        var expected: std.Io.Writer.Allocating = .init(t.allocator);
        defer expected.deinit();
        var actual: std.Io.Writer.Allocating = .init(t.allocator);
        defer actual.deinit();
        try snapshot.encode(t.allocator, &expected.writer, &source, .{ .continuation = .ground });
        try snapshot.encode(t.allocator, &actual.writer, &restored, .{ .continuation = .ground });
        try t.expectEqualSlices(u8, expected.written(), actual.written());
    }
}
