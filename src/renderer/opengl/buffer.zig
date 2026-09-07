const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a buffer.
pub const Options = struct {
    target: gl.Buffer.Target = .array,
    usage: gl.Buffer.Usage = .dynamic_draw,
};

/// OpenGL data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with OpenGL.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `gl.Buffer` instance.
        buffer: gl.Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Last successfully uploaded bytes and retained row-flattening space.
        /// A CPU mirror lets cursor-only and animation frames reuse GPU data.
        uploaded: std.ArrayList(u8) = .empty,
        staging: std.ArrayList(T) = .empty,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setDataNullManual(len * @sizeOf(T), opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setData(data, opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = data.len,
            };
        }

        pub fn deinit(self: Self) void {
            self.buffer.destroy();
            var uploaded = self.uploaded;
            uploaded.deinit(std.heap.c_allocator);
            var staging = self.staging;
            staging.deinit(std.heap.c_allocator);
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            const bytes = std.mem.sliceAsBytes(data);
            try self.uploaded.ensureTotalCapacity(std.heap.c_allocator, bytes.len);
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            // If we need more space than our buffer has, we need to reallocate.
            if (data.len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = data.len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
                self.uploaded.clearRetainingCapacity();
            }

            if (changedRange(self.uploaded.items, bytes)) |range| {
                try binding.setSubData(range.start, bytes[range.start..range.end]);
            }
            self.uploaded.items.len = bytes.len;
            @memcpy(self.uploaded.items, bytes);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            try self.staging.ensureTotalCapacity(std.heap.c_allocator, total_len);
            self.staging.clearRetainingCapacity();
            for (lists) |list| {
                self.staging.appendSliceAssumeCapacity(list.items);
            }
            try self.sync(self.staging.items);
            return total_len;
        }
    };
}

/// Bytes outside this span already match GPU storage. A shorter identical
/// prefix needs no write: the caller separately updates the draw count.
fn changedRange(previous: []const u8, next: []const u8) ?struct { start: usize, end: usize } {
    var start: usize = 0;
    const shared = @min(previous.len, next.len);
    while (start < shared and previous[start] == next[start]) : (start += 1) {}
    if (start == next.len) return null;
    var end = next.len;
    if (previous.len == next.len) {
        while (end > start and previous[end - 1] == next[end - 1]) : (end -= 1) {}
    }
    return .{ .start = start, .end = end };
}

test "buffer upload ranges preserve shifted rows and shrink" {
    const testing = std.testing;
    try testing.expect(changedRange("abc", "abc") == null);
    try testing.expect(changedRange("abc", "ab") == null);
    try testing.expect(changedRange("abc", "") == null);
    const middle = changedRange("abcdef", "abXYef").?;
    try testing.expectEqual(@as(usize, 2), middle.start);
    try testing.expectEqual(@as(usize, 4), middle.end);
    const grow = changedRange("abef", "abcdef").?;
    try testing.expectEqual(@as(usize, 2), grow.start);
    try testing.expectEqual(@as(usize, 6), grow.end);
    const shrink = changedRange("abcdef", "abef").?;
    try testing.expectEqual(@as(usize, 2), shrink.start);
    try testing.expectEqual(@as(usize, 4), shrink.end);
}
