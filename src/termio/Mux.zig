//! Experimental native view of a Windows broker-owned terminal. A snapshot is
//! installed before the surface is exposed; thereafter terminal/page identities
//! remain stable and only ordered VT/resize events modify them.
const Mux = @This();
const std = @import("std");
const global = @import("../global.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const snapshot = @import("../terminal/snapshot/main.zig");
const Stream = @import("../terminal/stream_terminal.zig").Stream;
const Client = @import("../mux/Client.zig");
const Journal = @import("../mux/Journal.zig");
const protocol = @import("../mux/protocol.zig");
const renderer = @import("../renderer.zig");
const w = @import("../apprt/win32/winapi.zig");
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const w.HANDLE, w.BOOL, u32) callconv(.winapi) u32;

alloc: std.mem.Allocator,
name: [:0]const u8,
client: ?Client = null,
initial: ?snapshot.Decoded = null,
init_error: ?anyerror = null,
sequence: u64 = 0,
stop: w.HANDLE,
wake: w.HANDLE,
thread: ?std.Thread = null,
io: *termio.Termio = undefined,
stream: Stream = undefined,
stream_ready: bool = false,
disconnected: std.atomic.Value(bool) = .init(false),
mutex: std.Io.Mutex = .init,
input: [protocol.max_request]u8 = undefined,
input_len: usize = 0,
pending_size: ?[4]u8 = null,

pub fn init(alloc: std.mem.Allocator, name: []const u8, launch: ?*const @import("Exec.zig")) !*Mux {
    const stop = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(stop);
    const wake = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(wake);
    const self = try alloc.create(Mux);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .name = try alloc.dupeZ(u8, name), .stop = stop, .wake = wake };
    // Preserve the standard IO-startup error pane when a broker is absent,
    // busy or incompatible. Never silently launch a replacement shell.
    self.connect(name, launch) catch |err| {
        self.init_error = err;
        self.disconnected.store(true, .release);
    };
    return self;
}

fn connect(self: *Mux, name: []const u8, launch: ?*const @import("Exec.zig")) !void {
    self.load(name) catch |err| {
        if (err != error.SessionNotFound) return err;
        const exec = launch orelse return err;
        try @import("../mux/Lifecycle.zig").start(self.alloc, name, exec.subprocess.args, exec.subprocess.cwd, if (exec.subprocess.env) |*env| env else null);
        try self.load(name);
    };
}

fn load(self: *Mux, name: []const u8) !void {
    const alloc = self.alloc;
    var client = try Client.init(name, self.stop);
    errdefer client.deinit();
    try client.subscribe();
    const bytes = try std.heap.page_allocator.alloc(u8, protocol.max_response);
    defer std.heap.page_allocator.free(bytes);
    const header = try client.request(.snapshot, "", 0, bytes);
    var reader: std.Io.Reader = .fixed(bytes[0..header.length]);
    var decoded = try snapshot.decode(alloc, global.io(), &reader, .{ .max_continuation_bytes = 65536 });
    errdefer decoded.deinit(alloc);
    self.client = client;
    self.initial = decoded;
    self.sequence = header.sequence;
}

pub fn initTerminal(self: *Mux, t: *terminal.Terminal) !void {
    if (self.init_error != null) return;
    // Presentation defaults belong to the view. Preserve broker-set dynamic
    // colors while using the GUI theme for default colors and palette entries.
    const restored = &self.initial.?.terminal.?;
    try restored.colors.palette.changeDefault(self.alloc, t.colors.palette.original.*);
    restored.colors.background.default = t.colors.background.default;
    restored.colors.foreground.default = t.colors.foreground.default;
    restored.colors.cursor.default = t.colors.cursor.default;
    restored.width_px = t.width_px;
    restored.height_px = t.height_px;
    t.deinit(self.alloc);
    t.* = self.initial.?.toOwned();
    t.flags.dirty.clear = true;
    t.flags.dirty.palette = true;
}

pub fn threadEnter(self: *Mux, io: *termio.Termio, td: *termio.Termio.ThreadData) !void {
    self.io = io;
    td.backend = .{ .mux = {} };
    if (self.init_error) |err| {
        self.setTitle("Session unavailable");
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        var message: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&message, "Unable to attach to this session.\r\n\r\n" ++
            "Start the broker from the same build directory and close any other\r\n" ++
            "attached view, then reopen this pane.\r\n\r\nDetails: {s}", .{@errorName(err)});
        var display = io.terminal.vtStream();
        defer display.deinit();
        display.nextSlice(text);
        io.terminal.modes.set(.cursor_visible, false);
        io.renderer_wakeup.notify() catch {};
        return;
    }
    self.stream = io.terminal.vtStream();
    self.stream_ready = true;
    // Restore parser continuation using a readonly handler. No query replies,
    // clipboard writes, notifications or historical effects are replayed.
    switch (self.initial.?.continuation) {
        .ground => {},
        .bytes => |bytes| self.stream.nextSlice(bytes),
    }
    self.initial.?.deinit(self.alloc);
    self.initial = null;
    self.stream.handler.effects.title_changed = titleChanged;
    self.setTitle(io.terminal.getTitle() orelse "Multiplexer session");
    try self.resize(io.size.grid());
    self.thread = try std.Thread.spawn(@import("../os/windows.zig").worker_thread_config, run, .{self});
}

pub fn threadExit(self: *Mux) void {
    _ = SetEvent(self.stop);
    _ = SetEvent(self.wake);
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn deinit(self: *Mux) void {
    self.threadExit();
    if (self.stream_ready) self.stream.deinit();
    if (self.initial) |*initial| initial.deinit(self.alloc);
    if (self.client) |*client| client.deinit();
    _ = w.CloseHandle(self.stop);
    _ = w.CloseHandle(self.wake);
    self.alloc.free(self.name);
    self.alloc.destroy(self);
}

pub fn resize(self: *Mux, grid: renderer.GridSize) !void {
    if (grid.columns == 0 or grid.rows == 0 or grid.columns > 512 or grid.rows > 256) return error.InvalidSize;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], @intCast(grid.columns), .little);
    std.mem.writeInt(u16, bytes[2..4], @intCast(grid.rows), .little);
    self.mutex.lockUncancelable(global.io());
    self.pending_size = bytes;
    self.mutex.unlock(global.io());
    _ = SetEvent(self.wake);
}

pub fn queueWrite(self: *Mux, data: []const u8, linefeed: bool) !void {
    if (self.disconnected.load(.acquire)) return error.SessionDisconnected;
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const extra = if (linefeed) std.mem.count(u8, data, "\r") else 0;
    if (data.len > self.input.len - self.input_len or extra > self.input.len - self.input_len - data.len) return error.InputQueueFull;
    for (data) |byte| {
        self.input[self.input_len] = byte;
        self.input_len += 1;
        if (linefeed and byte == '\r') {
            self.input[self.input_len] = '\n';
            self.input_len += 1;
        }
    }
    _ = SetEvent(self.wake);
}

fn titleChanged(handler: *Stream.Handler) void {
    const stream: *Stream = @fieldParentPtr("handler", handler);
    const self: *Mux = @fieldParentPtr("stream", stream);
    self.setTitle(handler.terminal.getTitle() orelse "Multiplexer session");
}

fn setTitle(self: *Mux, text: []const u8) void {
    var title: [256]u8 = @splat(0);
    _ = std.fmt.bufPrintZ(&title, "{s}", .{text}) catch return;
    _ = self.io.surface_mailbox.push(.{ .set_title = title }, .{ .instant = {} });
}

fn run(self: *Mux) void {
    self.loop() catch |err| {
        if (WaitForSingleObject(self.stop, 0) == 0) return;
        self.disconnected.store(true, .release);
        std.log.scoped(.mux).err("native session disconnected: {}", .{err});
        self.setTitle(if (err == error.SessionHistoryExpired) "Session history expired - reopen pane" else "Session disconnected - reopen pane");
        // Keep the terminal and its tracked pins intact. A fresh pane can take
        // a new snapshot; this pane must not silently replace live page state.
    };
}

fn loop(self: *Mux) !void {
    const buffer = try self.alloc.alloc(u8, Journal.capacity);
    defer self.alloc.free(buffer);
    var input: [protocol.max_request]u8 = undefined;
    while (WaitForSingleObject(self.stop, 0) != 0) {
        self.mutex.lockUncancelable(global.io());
        const len = self.input_len;
        @memcpy(input[0..len], self.input[0..len]);
        self.input_len = 0;
        const size = self.pending_size;
        self.pending_size = null;
        self.mutex.unlock(global.io());
        if (size) |bytes| _ = try self.client.?.request(.resize, &bytes, 0, buffer);
        if (len > 0) _ = try self.client.?.request(.input, input[0..len], 0, buffer);
        const reply = try self.client.?.request(.events, "", self.sequence, buffer);
        if (reply.sequence < self.sequence or reply.sequence - self.sequence != reply.length) return error.InvalidSequence;
        if (reply.length > 0) {
            self.io.renderer_state.mutex.lockUncancelable(global.io());
            defer self.io.renderer_state.mutex.unlock(global.io());
            var events: []const u8 = buffer[0..reply.length];
            while (try Journal.next(&events)) |event| switch (event.kind) {
                .output => self.stream.nextSlice(event.data),
                .resize => try self.io.terminal.resize(self.alloc, .{
                    .cols = std.mem.readInt(u16, event.data[0..2], .little),
                    .rows = std.mem.readInt(u16, event.data[2..4], .little),
                }),
            };
            if (self.stream.handler.semantic_failure) return error.TerminalStateFailed;
            self.sequence = reply.sequence;
            self.io.renderer_wakeup.notify() catch {};
        }
        // Catch up immediately while output is available. Once empty, wait
        // for input, output, shutdown, or broker death without a polling timer.
        if (reply.length == 0) {
            const handles = [_]w.HANDLE{ self.stop, self.wake, self.client.?.notification.?, self.client.?.server.? };
            switch (WaitForMultipleObjects(handles.len, &handles, 0, w.INFINITE)) {
                0 => return,
                1, 2 => {},
                else => return error.BrokerExited,
            }
        }
    }
}
