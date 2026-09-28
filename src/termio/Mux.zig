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
const InputQueue = @import("../mux/InputQueue.zig");
const protocol = @import("../mux/protocol.zig");
const renderer = @import("../renderer.zig");
const w = @import("../apprt/win32/winapi.zig");
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetEvent(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const w.HANDLE, w.BOOL, u32) callconv(.winapi) u32;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

alloc: std.mem.Allocator,
name: [:0]const u8,
shell: ?[]const u8 = null,
render_hold: @import("../mux/RenderHold.zig") = .{},
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
ended: std.atomic.Value(bool) = .init(false),
initial_exit_code: ?u32 = null,
mutex: std.Io.Mutex = .init,
input: InputQueue = .{},
pending_size: ?[12]u8 = null,
pending_clear: ?bool = null,

pub fn init(alloc: std.mem.Allocator, name: []const u8, launch: ?*const @import("Exec.zig")) !*Mux {
    const self = try createUnconnected(alloc, name);
    // Preserve the standard IO-startup error pane when a broker is absent,
    // busy or incompatible. Never silently launch a replacement shell.
    self.connect(name, launch) catch |err| {
        self.init_error = err;
        self.disconnected.store(true, .release);
    };
    return self;
}

/// Workspace preparation publishes this object before connecting so its stop
/// event can cancel a pipe request. Only the preparing worker may mutate it.
pub fn createUnconnected(alloc: std.mem.Allocator, name: []const u8) !*Mux {
    const stop = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(stop);
    const wake = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    errdefer _ = w.CloseHandle(wake);
    const self = try alloc.create(Mux);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .name = try alloc.dupeZ(u8, name), .stop = stop, .wake = wake };
    return self;
}

pub fn connectExisting(self: *Mux) !void {
    try self.load(self.name);
    if (self.ended.load(.acquire)) return error.SessionEnded;
}

fn connect(self: *Mux, name: []const u8, launch: ?*const @import("Exec.zig")) !void {
    self.load(name) catch |err| {
        if (err != error.SessionNotFound) return err;
        const exec = launch orelse return err;
        const process = try @import("../mux/Lifecycle.zig").start(self.alloc, name, exec.subprocess.args, exec.subprocess.cwd, if (exec.subprocess.env) |*env| env else null);
        defer _ = w.CloseHandle(process);
        self.load(name) catch |attach_err| {
            if (Client.exitedNormally(process, 1500)) return error.SessionEnded;
            return attach_err;
        };
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
    const status_reply = try client.request(.status, "", 0, bytes);
    const status = try std.json.parseFromSlice(protocol.Status, alloc, bytes[0..status_reply.length], .{ .ignore_unknown_fields = true });
    defer status.deinit();
    if (status.value.output_closed or status.value.exited) {
        self.ended.store(true, .release);
        self.initial_exit_code = if (status.value.exited) status.value.exit_code else null;
    }
    const shell_reply = try client.request(.shell, "", 0, bytes);
    self.shell = try alloc.dupe(u8, bytes[0..shell_reply.length]);
    self.client = client;
    self.initial = decoded;
    self.sequence = header.sequence;
}

pub fn initTerminal(self: *Mux, t: *terminal.Terminal) !void {
    if (self.init_error != null) return;
    // Presentation defaults belong to the view. Preserve broker-set dynamic
    // colors while using the GUI theme for default colors and palette entries.
    const restored = &self.initial.?.terminal.?;
    @import("../mux/cwd.zig").normalize(restored);
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
    if (self.ended.load(.acquire)) t.modes.set(.cursor_visible, false);
}

pub fn threadEnter(self: *Mux, io: *termio.Termio, td: *termio.Termio.ThreadData) !void {
    self.io = io;
    td.backend = .{ .mux = {} };
    if (self.init_error) |err| {
        if (err == error.SessionEnded) {
            self.closeSession();
            return;
        }
        self.setTitle("Session unavailable");
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        var message: [512]u8 = undefined;
        const explanation = switch (err) {
            error.SessionNotFound => "This session is no longer running.\r\nOpen a new tab to start a new shell.",
            error.SessionBusy => "This session is attached in another window.\r\nDetach it there, then choose Reconnect Session from the tab menu.",
            else => "Unable to connect to this session.\r\nChoose Reconnect Session from the tab menu to retry.",
        };
        const text = try std.fmt.bufPrint(&message, "{s}\r\n\r\nDetails: {s}", .{ explanation, @errorName(err) });
        var display = io.terminal.vtStream();
        defer display.deinit();
        display.nextSlice(text);
        io.terminal.modes.set(.cursor_visible, false);
        io.renderer_wakeup.notify() catch {};
        return;
    }
    self.stream = io.terminal.vtStream();
    self.stream.handler.effects.pwd_changed = @import("../mux/cwd.zig").changed;
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
    self.stream.handler.effects.render_hold = renderHold;
    renderHold(&self.stream.handler, io.terminal.modes.get(.synchronized_output));
    self.setTitle(io.terminal.getTitle() orelse "Multiplexer session");
    if (self.ended.load(.acquire)) self.showExit(self.initial_exit_code);
    try self.resize(io.size.grid(), io.size.cell);
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

/// UI-initiated replacement stops network activity before constructing a fresh
/// surface. Terminal pages remain alive until the old surface is destroyed.
pub fn disconnect(self: *Mux) void {
    self.disconnected.store(true, .release);
    self.threadExit();
    if (self.client) |*client| client.deinit();
    self.client = null;
}

pub fn deinit(self: *Mux) void {
    self.threadExit();
    if (self.stream_ready) self.stream.deinit();
    if (self.initial) |*initial| initial.deinit(self.alloc);
    if (self.client) |*client| client.deinit();
    _ = w.CloseHandle(self.stop);
    _ = w.CloseHandle(self.wake);
    self.alloc.free(self.name);
    if (self.shell) |shell| self.alloc.free(shell);
    self.input.deinit(self.alloc);
    self.alloc.destroy(self);
}

pub fn resize(self: *Mux, grid: renderer.GridSize, cell: renderer.CellSize) !void {
    if (self.ended.load(.acquire)) return;
    if (grid.columns == 0 or grid.rows == 0 or grid.columns > 512 or grid.rows > 256) return error.InvalidSize;
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], @intCast(grid.columns), .little);
    std.mem.writeInt(u16, bytes[2..4], @intCast(grid.rows), .little);
    self.mutex.lockUncancelable(global.io());
    std.mem.writeInt(u32, bytes[4..8], cell.width, .little);
    std.mem.writeInt(u32, bytes[8..12], cell.height, .little);
    self.pending_size = bytes;
    self.mutex.unlock(global.io());
    _ = SetEvent(self.wake);
}

pub fn clear(self: *Mux, history: bool) !void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.ended.load(.acquire)) return error.SessionExited;
    if (self.disconnected.load(.acquire)) return error.SessionDisconnected;
    self.pending_clear = history or (self.pending_clear orelse false);
    _ = SetEvent(self.wake);
}

fn renderHold(handler: *Stream.Handler, held: bool) void {
    const stream: *Stream = @fieldParentPtr("handler", handler);
    const self: *Mux = @fieldParentPtr("stream", stream);
    self.render_hold.set(held, GetTickCount64());
}

fn expireRenderHold(self: *Mux) void {
    if (!self.render_hold.expire(GetTickCount64())) return;
    self.io.renderer_state.mutex.lockUncancelable(global.io());
    defer self.io.renderer_state.mutex.unlock(global.io());
    self.io.terminal.modes.set(.synchronized_output, false);
    self.io.renderer_wakeup.notify() catch {};
}

pub fn queueWrite(self: *Mux, data: []const u8, linefeed: bool) !void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.ended.load(.acquire)) return error.SessionExited;
    if (self.disconnected.load(.acquire)) return error.SessionDisconnected;
    try self.input.append(self.alloc, data, linefeed);
    _ = SetEvent(self.wake);
}

fn titleChanged(handler: *Stream.Handler) void {
    const stream: *Stream = @fieldParentPtr("handler", handler);
    const self: *Mux = @fieldParentPtr("stream", stream);
    if (self.ended.load(.acquire)) return;
    self.setTitle(handler.terminal.getTitle() orelse "Multiplexer session");
}

fn setTitle(self: *Mux, text: []const u8) void {
    var title: [256]u8 = @splat(0);
    _ = std.fmt.bufPrintZ(&title, "{s}", .{text}) catch return;
    _ = self.io.surface_mailbox.push(.{ .set_title = title }, .{ .instant = {} });
}

fn showExit(self: *Mux, code: ?u32) void {
    self.ended.store(true, .release);
    self.mutex.lockUncancelable(global.io());
    self.input.deinit(self.alloc);
    self.mutex.unlock(global.io());
    if (code) |value| {
        var buffer: [80]u8 = undefined;
        self.setTitle(std.fmt.bufPrint(&buffer, "Session exited (code {d})", .{value}) catch "Session exited");
        self.closeSession();
    } else self.setTitle("Session output closed");
}

fn closeSession(self: *Mux) void {
    self.ended.store(true, .release);
    if (comptime @import("../build_config.zig").app_runtime == .win32) {
        const core = self.io.surface_mailbox.surface;
        _ = w.PostMessageW(core.rt_surface.window.hwnd, w.WM_APP_MUX_CLOSED, @intCast(core.id), 0);
    }
}

fn run(self: *Mux) void {
    self.loop() catch |err| {
        if (WaitForSingleObject(self.stop, 0) == 0) return;
        if (err == error.PipeIo or err == error.PipeClosed or err == error.BrokerExited) if (self.client) |client| if (client.server) |process| {
            if (Client.exitedNormally(process, 1500)) {
                self.closeSession();
                return;
            }
        };
        self.render_hold.set(true, 0);
        self.expireRenderHold();
        self.disconnected.store(true, .release);
        std.log.scoped(.mux).err("native session disconnected: {}", .{err});
        self.setTitle(if (err == error.SessionHistoryExpired) "Session history expired - reopen pane" else "Session disconnected - reopen pane");
        if (err == error.SessionHistoryExpired) {
            if (comptime @import("../build_config.zig").app_runtime == .win32) {
                const core = self.io.surface_mailbox.surface;
                _ = w.PostMessageW(core.rt_surface.window.hwnd, w.WM_APP_MUX_RECONNECT, @intCast(core.id), 0);
            }
        }
        // Keep the terminal and its tracked pins intact. A fresh pane can take
        // a new snapshot; this pane must not silently replace live page state.
    };
}

fn loop(self: *Mux) !void {
    const buffer = try self.alloc.alloc(u8, Journal.capacity);
    defer self.alloc.free(buffer);
    var input: [protocol.max_request]u8 = undefined;
    while (WaitForSingleObject(self.stop, 0) != 0) {
        self.expireRenderHold();
        self.mutex.lockUncancelable(global.io());
        const clear_history = self.pending_clear;
        self.pending_clear = null;
        const len = @min(input.len, self.input.pending().len);
        @memcpy(input[0..len], self.input.pending()[0..len]);
        const size = self.pending_size;
        self.pending_size = null;
        self.mutex.unlock(global.io());
        if (size) |bytes| _ = self.client.?.request(.resize, &bytes, 0, buffer) catch |err| switch (err) {
            error.SessionBackpressure => retry: {
                self.mutex.lockUncancelable(global.io());
                if (self.pending_size == null) self.pending_size = bytes;
                self.mutex.unlock(global.io());
                // Events below drain a full journal; the broker signals when
                // its input queue frees space. Do not spin on backpressure.
                break :retry protocol.Header{ .op = .retry, .length = 0 };
            },
            else => return err,
        };
        if (clear_history) |history| _ = self.client.?.request(.clear, &.{@intFromBool(history)}, 0, buffer) catch |err| switch (err) {
            error.SessionBackpressure => retry: {
                self.mutex.lockUncancelable(global.io());
                self.pending_clear = history or (self.pending_clear orelse false);
                self.mutex.unlock(global.io());
                // Events below drain a full journal; the broker signals when
                // its input queue frees space. Do not spin on backpressure.
                break :retry protocol.Header{ .op = .retry, .length = 0 };
            },
            else => return err,
        };
        var more_input = false;
        if (len > 0) {
            const accepted = block: {
                _ = self.client.?.request(.input, input[0..len], 0, buffer) catch |err| switch (err) {
                    error.SessionBackpressure => break :block false,
                    else => return err,
                };
                break :block true;
            };
            if (accepted) {
                self.mutex.lockUncancelable(global.io());
                self.input.consume(self.alloc, len);
                more_input = self.input.pending().len > 0;
                self.mutex.unlock(global.io());
            }
        }
        const reply = try self.client.?.request(.events, "", self.sequence, buffer);
        if (reply.sequence < self.sequence or reply.sequence - self.sequence != reply.length) return error.InvalidSequence;
        if (reply.length > 0) {
            self.io.renderer_state.mutex.lockUncancelable(global.io());
            defer self.io.renderer_state.mutex.unlock(global.io());
            var events: []const u8 = buffer[0..reply.length];
            while (try Journal.next(&events)) |event| switch (event.kind) {
                .output => self.stream.nextSlice(event.data),
                .clear => {
                    _ = @import("../mux/terminal_ops.zig").clear(&self.io.terminal, event.data[0] != 0);
                },
                .resize => try self.stream.handler.resize(.{
                    .cols = std.mem.readInt(u16, event.data[0..2], .little),
                    .rows = std.mem.readInt(u16, event.data[2..4], .little),
                    .cell_size_px = if (event.data.len == 12) .{ .width = std.mem.readInt(u32, event.data[4..8], .little), .height = std.mem.readInt(u32, event.data[8..12], .little) } else null,
                }),
                .exited => {
                    self.showExit(if (std.mem.readInt(u32, event.data[4..8], .little) == 1) std.mem.readInt(u32, event.data[0..4], .little) else null);
                    self.io.terminal.modes.set(.cursor_visible, false);
                },
            };
            if (self.stream.handler.semantic_failure) return error.TerminalStateFailed;
            if (self.ended.load(.acquire)) self.io.terminal.modes.set(.cursor_visible, false);
            self.sequence = reply.sequence;
            self.io.renderer_wakeup.notify() catch {};
        }
        // Catch up immediately while output is available. Once empty, wait
        // for input, output, shutdown, or broker death without a polling timer.
        if (reply.length == 0 and !more_input) {
            const handles = [_]w.HANDLE{ self.stop, self.wake, self.client.?.notification.?, self.client.?.server.? };
            switch (WaitForMultipleObjects(handles.len, &handles, 0, self.render_hold.wait(GetTickCount64()))) {
                0 => return,
                1, 2, 0x102 => {},
                else => return error.BrokerExited,
            }
        }
    }
}
