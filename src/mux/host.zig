const std = @import("std");
const global = @import("../global.zig");
const terminal = @import("../terminal/main.zig");
const snapshot = @import("../terminal/snapshot/main.zig");
const Stream = @import("../terminal/stream_terminal.zig").Stream;
const Handler = Stream.Handler;
const Pty = @import("../pty.zig").Pty;
const Command = @import("../Command.zig");
const w = @import("../apprt/win32/winapi.zig");
const windows = std.os.windows;
const transport = @import("transport.zig");
const Client = @import("Client.zig");
const Journal = @import("Journal.zig");
const protocol = @import("protocol.zig");
const H = w.HANDLE;
const alloc = std.heap.c_allocator;
const build_identity = @import("../build_config.zig").version_string;
const worker_config = @import("../os/windows.zig").worker_thread_config;
extern "kernel32" fn ConnectNamedPipe(H, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn DisconnectNamedPipe(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetProcessId(H) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) H;
extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const H, w.BOOL, u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn CancelSynchronousIo(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateEventW(?*anyopaque, w.BOOL, w.BOOL, ?[*:0]const u16) callconv(.winapi) ?H;
extern "kernel32" fn SetEvent(H) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) H;
extern "kernel32" fn GetConsoleMode(H, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetConsoleMode(H, u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(u32) callconv(.winapi) w.BOOL;
const ConsoleInfo = extern struct { size: [2]i16, cursor: [2]i16, attributes: u16, window: [4]i16, maximum: [2]i16 };
extern "kernel32" fn GetConsoleScreenBufferInfo(H, *ConsoleInfo) callconv(.winapi) w.BOOL;

const Input = struct {
    handle: H,
    mutex: std.Io.Mutex = .init,
    bytes: [protocol.max_request]u8 = undefined,
    len: usize = 0,
    stopped: std.atomic.Value(bool) = .init(false),
    overflow: std.atomic.Value(bool) = .init(false),
    fn read(self: *Input) void {
        var buf: [4096]u8 = undefined;
        while (!self.stopped.load(.acquire)) {
            var n: u32 = 0;
            if (w.ReadFile(self.handle, &buf, buf.len, &n, null) == 0 or n == 0) break;
            // Ctrl+] detaches this experimental client. It never kills a pane.
            if (std.mem.indexOfScalar(u8, buf[0..n], 0x1d) != null) break;
            self.mutex.lockUncancelable(global.io());
            defer self.mutex.unlock(global.io());
            if (n > self.bytes.len - self.len) {
                self.overflow.store(true, .release);
                break;
            }
            @memcpy(self.bytes[self.len..][0..n], buf[0..n]);
            self.len += n;
        }
        self.stopped.store(true, .release);
    }
};

// One pane per experimental broker. All terminal access is serialized. No view
// owns the process or PTY, and no client socket is used by the output reader.
const Session = struct {
    name: []const u8,
    label: [128]u8 = undefined,
    label_len: usize = 0,
    pty: Pty,
    command: Command,
    term: terminal.Terminal,
    stream: Stream = undefined,
    mutex: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    output_closed: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    sequence: u64 = 1,
    journal: *Journal,
    input_mutex: std.Io.Mutex = .init,
    input: [protocol.max_request]u8 = undefined,
    input_len: usize = 0,
    input_event: H = undefined,
    output_event: H = undefined,
    space_event: H = undefined,
    stop_event: H = undefined,
    protected_cursor: ?u64 = null,

    // Caller holds the terminal mutex, serializing atomic record publication.
    fn publishRecord(self: *Session) void {
        if (@import("Registry.zig").publish(alloc, self.name, GetProcessId(self.command.pid.?), self.exited.load(.acquire), self.label[0..self.label_len])) |path| alloc.free(path) else |_| {}
    }

    fn detach(self: *Session) void {
        self.mutex.lockUncancelable(global.io());
        self.protected_cursor = null;
        self.mutex.unlock(global.io());
        _ = SetEvent(self.space_event);
    }

    fn write(self: *Session, bytes: []const u8) !void {
        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        if (self.failed.load(.acquire)) return error.SessionFailed;
        if (self.output_closed.load(.acquire) or self.exited.load(.acquire)) return error.SessionExited;
        if (bytes.len > self.input.len - self.input_len) return error.InputQueueFull;
        @memcpy(self.input[self.input_len..][0..bytes.len], bytes);
        self.input_len += bytes.len;
        _ = SetEvent(self.input_event);
    }

    fn writeLoop(self: *Session) void {
        var io = transport.Io.init(null) catch {
            self.failed.store(true, .release);
            return;
        };
        defer _ = w.CloseHandle(io.event);
        var bytes: [protocol.max_request]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            _ = WaitForSingleObject(self.input_event, w.INFINITE);
            self.input_mutex.lockUncancelable(global.io());
            const len = self.input_len;
            @memcpy(bytes[0..len], self.input[0..len]);
            self.input_len = 0;
            self.input_mutex.unlock(global.io());
            _ = SetEvent(self.output_event);
            if (self.stopping.load(.acquire)) return;
            io.transfer(self.pty.in_pipe, bytes[0..len], true) catch {
                if (WaitForSingleObject(self.command.pid.?, 0) == 0) return;
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn reply(_: *Handler, bytes: []const u8) void {
        current.?.write(bytes) catch |err| {
            if (err == error.SessionExited) return;
            current.?.failed.store(true, .release);
        };
    }

    fn watchExit(self: *Session) void {
        const handles = [_]H{ self.stop_event, self.command.pid.? };
        if (WaitForMultipleObjects(handles.len, &handles, 0, w.INFINITE) != 1) return;
        var code: u32 = 0;
        _ = GetExitCodeProcess(self.command.pid.?, &code);
        self.mutex.lockUncancelable(global.io());
        self.exited.store(true, .release);
        var data: [8]u8 = undefined;
        std.mem.writeInt(u32, data[0..4], code, .little);
        std.mem.writeInt(u32, data[4..8], 1, .little);
        self.journal.append(.exited, &data);
        self.sequence = self.journal.end;
        self.publishRecord();
        self.mutex.unlock(global.io());
        _ = SetEvent(self.output_event);
    }

    fn read(self: *Session) void {
        var bytes: [64 * 1024]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            var count: u32 = 0;
            if (w.ReadFile(self.pty.out_pipe, &bytes, bytes.len, &count, null) == 0 or count == 0) {
                if (self.stopping.load(.acquire)) return;
                const exited = WaitForSingleObject(self.command.pid.?, 1000) == 0;
                var code: u32 = 0;
                _ = GetExitCodeProcess(self.command.pid.?, &code);
                self.mutex.lockUncancelable(global.io());
                self.output_closed.store(true, .release);
                var data: [8]u8 = undefined;
                std.mem.writeInt(u32, data[0..4], code, .little);
                std.mem.writeInt(u32, data[4..8], @intFromBool(exited), .little);
                self.journal.append(.exited, &data);
                self.sequence = self.journal.end;
                self.publishRecord();
                self.mutex.unlock(global.io());
                _ = SetEvent(self.output_event);
                return;
            }
            self.mutex.lockUncancelable(global.io());
            // Leave room for a resize command while output is backpressured.
            // A disconnected or unresponsive view must not stall a detached
            // shell forever. The connection owns the cursor under this lock.
            while (self.protected_cursor) |cursor| {
                if (self.journal.canAppend(cursor, count + 2 * Journal.header_size + 4 + 8)) break;
                self.mutex.unlock(global.io());
                const waited = WaitForSingleObject(self.space_event, 3000);
                self.mutex.lockUncancelable(global.io());
                if (self.stopping.load(.acquire)) {
                    self.mutex.unlock(global.io());
                    return;
                }
                if (waited != 0) self.protected_cursor = null;
            }
            self.stream.nextSlice(bytes[0..count]);
            self.journal.append(.output, bytes[0..count]);
            self.sequence = self.journal.end;
            if (self.stream.handler.semantic_failure) self.failed.store(true, .release);
            self.mutex.unlock(global.io());
            _ = SetEvent(self.output_event);
        }
    }

    fn respond(self: *Session, request: protocol.Header, payload: []const u8, out: *std.Io.Writer) !void {
        switch (request.op) {
            .rename => {
                if (!protocol.validLabel(payload)) return error.InvalidSessionLabel;
                const path = try @import("Registry.zig").publish(alloc, self.name, GetProcessId(self.command.pid.?), self.exited.load(.acquire), payload);
                alloc.free(path);
                @memcpy(self.label[0..payload.len], payload);
                self.label_len = payload.len;
            },
            .subscribe => {
                if (payload.len != 0 or self.protected_cursor != null) return error.InvalidPayload;
                self.protected_cursor = self.sequence;
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @intFromPtr(self.output_event), .little);
                try out.writeAll(&bytes);
            },
            .resync, .retry => return error.InvalidOperation,
            .events => {
                if (payload.len != 0) return error.InvalidPayload;
                const data = try self.journal.read(request.sequence, out.buffer);
                out.end = data.len;
                // The reply owns a copy now; the journal may reuse that space.
                if (self.protected_cursor != null) self.protected_cursor = self.sequence;
                _ = SetEvent(self.space_event);
            },
            .hello => {
                if (!std.mem.eql(u8, payload, build_identity)) return error.IncompatibleBuild;
                try out.writeAll(build_identity);
            },
            .input => {
                try self.write(payload);
            },
            .stop => {
                if (payload.len != 0) return error.InvalidPayload;
            },
            .status => {
                if (payload.len != 0) return error.InvalidPayload;
                var code: u32 = 0;
                _ = GetExitCodeProcess(self.command.pid.?, &code);
                try out.print("{{\"shell_pid\":{d},\"broker_pid\":{d},\"exited\":{s},\"failed\":{s},\"output_closed\":{s},\"exit_code\":{d}}}\n", .{
                    GetProcessId(self.command.pid.?),                                         windows.GetCurrentProcessId(),
                    if (WaitForSingleObject(self.command.pid.?, 0) == 0) "true" else "false", if (self.failed.load(.acquire)) "true" else "false",
                    if (self.output_closed.load(.acquire)) "true" else "false",               code,
                });
            },
            .resize => {
                if (payload.len != 4) return error.InvalidPayload;
                const cols = std.mem.readInt(u16, payload[0..2], .little);
                const rows = std.mem.readInt(u16, payload[2..4], .little);
                if (cols == 0 or rows == 0 or cols > 512 or rows > 256) return error.InvalidSize;
                if (self.protected_cursor) |cursor| if (!self.journal.canAppend(cursor, payload.len)) return error.Backpressure;
                const old_cols = self.term.cols;
                const old_rows = self.term.rows;
                try self.term.resize(alloc, .{ .cols = cols, .rows = rows });
                if (!self.output_closed.load(.acquire)) self.pty.setSize(.{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 }) catch |err| {
                    self.term.resize(alloc, .{ .cols = old_cols, .rows = old_rows }) catch {
                        self.failed.store(true, .release);
                    };
                    return err;
                };
                self.journal.append(.resize, payload);
                self.sequence = self.journal.end;
                _ = SetEvent(self.output_event);
            },
            .snapshot => {
                if (payload.len != 0) return error.InvalidPayload;
                if (request.sequence == self.sequence) return;
                var continuation: [64 * 1024]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&continuation);
                try self.stream.writeContinuation(&writer);
                try snapshot.encode(alloc, out, &self.term, .{
                    .continuation = if (writer.buffered().len == 0) .ground else .{ .bytes = writer.buffered() },
                });
                if (self.protected_cursor != null) self.protected_cursor = self.sequence;
                _ = SetEvent(self.space_event);
            },
        }
    }
};
var current: ?*Session = null;

fn serve(name: []const u8, args: anytype) !void {
    const identity = try transport.identity(GetCurrentProcess());
    const path = try transport.pipeName(name, identity);
    defer alloc.free(path);
    // Claim the endpoint BEFORE creating a shell. A duplicate host must fail
    // without creating an orphan session. OS identity checked on every connect.
    const pipe = w.CreateNamedPipeW(path, 3 | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE, 8, 1, 65536, 65536, 0, null);
    if (pipe == windows.INVALID_HANDLE_VALUE) return error.SessionAlreadyExists;
    defer _ = w.CloseHandle(pipe);
    const control_path = try transport.endpointName(name, identity, true);
    defer alloc.free(control_path);
    const control_pipe = w.CreateNamedPipeW(control_path, 3 | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE, 8, 1, 4096, 4096, 0, null);
    if (control_pipe == windows.INVALID_HANDLE_VALUE) return error.SessionAlreadyExists;
    defer _ = w.CloseHandle(control_pipe);
    const shell = try alloc.dupeZ(u8, args.next() orelse "pwsh.exe");
    defer alloc.free(shell);
    var argv: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    try argv.append(alloc, try alloc.dupeZ(u8, shell));
    while (args.next()) |a| try argv.append(alloc, try alloc.dupeZ(u8, a));
    const journal = try alloc.create(Journal);
    defer alloc.destroy(journal);
    journal.* = .{};
    var session: Session = .{
        .name = name,
        .journal = journal,
        .pty = try Pty.open(.{ .ws_col = 100, .ws_row = 30, .ws_xpixel = 0, .ws_ypixel = 0 }),
        .command = .{ .path = shell, .args = argv.items, .os_pre_exec = null, .rt_pre_exec = null, .rt_post_fork = null, .rt_pre_exec_info = undefined, .rt_post_fork_info = undefined },
        .term = undefined,
    };
    defer session.pty.deinit();
    session.term = try terminal.Terminal.init(global.io(), alloc, .{
        .cols = 100,
        .rows = 30,
        .max_scrollback_bytes = 1024 * 1024,
        // Image state is not preserved by the upstream snapshot codec yet.
        .kitty_image_storage_limit = 0,
    });
    defer session.term.deinit(alloc);
    session.stream = Stream.init(.{ .allocator = alloc, .handler = session.term.vtHandler(), .continuation_max_bytes = 64 * 1024 });
    defer session.stream.deinit();
    current = &session;
    defer current = null;
    session.stream.handler.effects.write_pty = Session.reply;
    session.stream.handler.effects.device_attributes = struct {
        fn attributes(_: *Handler) @import("../terminal/device_attributes.zig").Attributes {
            return .{};
        }
    }.attributes;
    session.input_event = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    defer _ = w.CloseHandle(session.input_event);
    session.output_event = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    defer _ = w.CloseHandle(session.output_event);
    session.space_event = CreateEventW(null, 0, 0, null) orelse return error.CreateEvent;
    defer _ = w.CloseHandle(session.space_event);
    session.stop_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEvent;
    defer _ = w.CloseHandle(session.stop_event);
    session.command.pseudo_console = session.pty.pseudo_console;
    try session.command.start(alloc);
    defer session.command.deinit();
    const record = try @import("Registry.zig").publish(alloc, name, GetProcessId(session.command.pid.?), false, "");
    defer {
        std.Io.Dir.deleteFileAbsolute(global.io(), record) catch {};
        alloc.free(record);
    }
    const input_writer = try std.Thread.spawn(worker_config, Session.writeLoop, .{&session});
    defer {
        session.stopping.store(true, .release);
        _ = SetEvent(session.input_event);
        input_writer.join();
    }
    const reader = try std.Thread.spawn(worker_config, Session.read, .{&session});
    defer {
        session.stopping.store(true, .release);
        // Cancellation can race with entry into ReadFile. Retry until the
        // reader exits so no pending read can outlive the PTY or Session.
        _ = SetEvent(session.space_event);
        while (WaitForSingleObject(reader.getHandle(), 10) != 0) _ = CancelSynchronousIo(reader.getHandle());
        reader.join();
    }
    const control_thread = try std.Thread.spawn(worker_config, controlLoop, .{ &session, control_pipe, identity });
    defer {
        _ = SetEvent(session.stop_event);
        control_thread.join();
    }
    const exit_thread = try std.Thread.spawn(worker_config, Session.watchExit, .{&session});
    defer {
        _ = SetEvent(session.stop_event);
        exit_thread.join();
    }
    try serveConnections(&session, pipe, identity, false);
}

fn controlLoop(session: *Session, pipe: H, identity: transport.Identity) void {
    serveConnections(session, pipe, identity, true) catch |err| {
        std.log.scoped(.mux).err("session control listener failed: {}", .{err});
        _ = SetEvent(session.stop_event);
    };
}

fn serveConnections(session: *Session, pipe: H, identity: transport.Identity, control: bool) !void {
    const response = try alloc.alloc(u8, if (control) 4096 else Journal.capacity);
    defer alloc.free(response);
    const request_buf = try alloc.alloc(u8, protocol.max_request);
    defer alloc.free(request_buf);
    var io = try transport.Io.init(session.stop_event);
    defer _ = w.CloseHandle(io.event);
    while (true) {
        if (WaitForSingleObject(session.stop_event, 0) == 0) return;
        var ov = io.begin();
        if (ConnectNamedPipe(pipe, &ov) == 0) switch (windows.GetLastError()) {
            .PIPE_CONNECTED => {},
            .IO_PENDING => {
                _ = io.finish(pipe, &ov, w.INFINITE) catch |err| switch (err) {
                    error.Stopped => return,
                    else => return err,
                };
            },
            else => return error.AcceptFailed,
        };
        const stop = connection(session, pipe, &io, identity, request_buf, response, control) catch false;
        _ = DisconnectNamedPipe(pipe);
        if (stop) {
            _ = SetEvent(session.stop_event);
            return;
        }
    }
}

fn connection(session: *Session, pipe: H, io: *transport.Io, identity: transport.Identity, request_buf: []u8, response: []u8, control: bool) !bool {
    _ = try transport.peer(pipe, false, identity);
    defer if (!control) session.detach();
    var ready = false;
    while (true) {
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (ready and !control) try io.requestHeader(pipe, &header_bytes) else try io.transfer(pipe, &header_bytes, false);
        const header = try protocol.Header.decode(&header_bytes, protocol.max_request);
        if (!ready and header.op != .hello) return error.HandshakeRequired;
        if (control and header.op != .hello and header.op != .status and header.op != .stop and header.op != .rename) return error.InvalidOperation;
        const payload = request_buf[0..header.length];
        try io.transfer(pipe, payload, false);
        // Snapshots need a larger temporary buffer, not a permanent allocation
        // in every idle broker. Page allocation returns the commit on release.
        const snapshot_buffer = if (header.op == .snapshot)
            try std.heap.page_allocator.alloc(u8, protocol.max_response)
        else
            null;
        defer if (snapshot_buffer) |bytes| std.heap.page_allocator.free(bytes);
        var writer: std.Io.Writer = .fixed(snapshot_buffer orelse response);
        var response_op = header.op;
        const sequence = block: {
            session.mutex.lockUncancelable(global.io());
            defer session.mutex.unlock(global.io());
            session.respond(header, payload, &writer) catch |err| switch (err) {
                error.StaleCursor => response_op = .resync,
                error.InputQueueFull, error.SessionExited => response_op = .retry,
                else => return err,
            };
            ready = true;
            break :block session.sequence;
        };
        var reply = (protocol.Header{ .op = response_op, .length = @intCast(writer.buffered().len), .sequence = sequence }).encode();
        try io.transfer(pipe, &reply, true);
        try io.transfer(pipe, writer.buffered(), true);
        if (header.op == .stop) return true;
    }
}

pub fn run(operation: []const u8, name: []const u8, args: anytype) !void {
    if (std.mem.eql(u8, operation, "serve")) return serve(name, args);
    if (std.mem.eql(u8, operation, "start")) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        while (args.next()) |arg| try argv.append(alloc, arg);
        return @import("Lifecycle.zig").start(alloc, name, argv.items, null, null);
    }
    if (std.mem.eql(u8, operation, "list")) {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const entries = try @import("Registry.zig").list(arena.allocator());
        const data = try std.json.Stringify.valueAlloc(arena.allocator(), entries, .{});
        var bytes: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(global.io(), &bytes);
        try out.interface.writeAll(data);
        try out.interface.writeByte('\n');
        try out.interface.flush();
        return;
    }
    var client = if (std.mem.eql(u8, operation, "status") or std.mem.eql(u8, operation, "stop") or std.mem.eql(u8, operation, "rename"))
        try Client.initControl(name, null)
    else
        try Client.init(name, null);
    defer client.deinit();
    const buffer = try alloc.alloc(u8, protocol.max_response);
    defer alloc.free(buffer);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(global.io(), &stdout_buf);
    if (std.mem.eql(u8, operation, "watch") or std.mem.eql(u8, operation, "attach")) {
        // Temporary console client. Native pane attachment will use
        // the binary state directly; this formatter view is a diagnostic only.
        const interactive = std.mem.eql(u8, operation, "attach");
        const output = GetStdHandle(@bitCast(@as(i32, -11)));
        const input = GetStdHandle(@bitCast(@as(i32, -10)));
        var output_mode: u32 = 0;
        if (GetConsoleMode(output, &output_mode) == 0) return error.ConsoleRequired;
        const old_cp = GetConsoleOutputCP();
        if (SetConsoleOutputCP(65001) == 0 or SetConsoleMode(output, output_mode | 4) == 0) return error.ConsoleMode;
        defer {
            _ = SetConsoleOutputCP(old_cp);
            _ = SetConsoleMode(output, output_mode);
        }
        var input_mode: u32 = 0;
        const input_cp = GetConsoleCP();
        if (interactive) {
            if (GetConsoleMode(input, &input_mode) == 0) return error.ConsoleRequired;
            if (SetConsoleMode(input, 0x200) == 0 or SetConsoleCP(65001) == 0) return error.ConsoleMode;
        }
        defer if (interactive) {
            _ = SetConsoleMode(input, input_mode);
            _ = SetConsoleCP(input_cp);
        };
        var input_state: Input = .{ .handle = input };
        const input_thread: ?std.Thread = if (interactive) try std.Thread.spawn(worker_config, Input.read, .{&input_state}) else null;
        defer if (input_thread) |thread| {
            input_state.stopped.store(true, .release);
            while (WaitForSingleObject(thread.getHandle(), 10) != 0) _ = CancelSynchronousIo(thread.getHandle());
            thread.join();
        };
        defer {
            stdout.interface.writeAll("\x1b[?2026l\x1b[?1l\x1b[?2004l\x1b[0m\x1b[?25h\r\n") catch {};
            stdout.interface.flush() catch {};
        }
        var old_size: [4]u8 = @splat(0);
        var sequence: u64 = 0;
        while (true) {
            if (interactive and input_state.stopped.load(.acquire)) {
                if (input_state.overflow.load(.acquire)) return error.InputQueueFull;
                return;
            }
            var info: ConsoleInfo = undefined;
            if (GetConsoleScreenBufferInfo(output, &info) != 0) {
                var size: [4]u8 = undefined;
                std.mem.writeInt(u16, size[0..2], @intCast(std.math.clamp(@as(i32, info.window[2]) - info.window[0] + 1, 1, 512)), .little);
                std.mem.writeInt(u16, size[2..4], @intCast(std.math.clamp(@as(i32, info.window[3]) - info.window[1] + 1, 1, 256)), .little);
                if (!std.mem.eql(u8, &size, &old_size)) {
                    _ = try client.request(.resize, &size, 0, buffer);
                    old_size = size;
                }
            }
            if (interactive) {
                var input_bytes: [protocol.max_request]u8 = undefined;
                const n = blk: {
                    input_state.mutex.lockUncancelable(global.io());
                    defer input_state.mutex.unlock(global.io());
                    const n = input_state.len;
                    @memcpy(input_bytes[0..n], input_state.bytes[0..n]);
                    input_state.len = 0;
                    break :blk n;
                };
                if (n > 0) _ = try client.request(.input, input_bytes[0..n], 0, buffer);
            }
            const header = try client.request(.snapshot, "", sequence, buffer);
            sequence = header.sequence;
            if (header.length > 0) {
                var source: std.Io.Reader = .fixed(buffer[0..header.length]);
                var decoded = try snapshot.decode(alloc, global.io(), &source, .{ .max_continuation_bytes = 64 * 1024 });
                defer decoded.deinit(alloc);
                var restored = decoded.toOwned();
                defer restored.deinit(alloc);
                var formatter = terminal.formatter.TerminalFormatter.init(&restored, .vt);
                const pages = &restored.screens.active.pages;
                formatter.content = .{ .selection = terminal.Selection.init(
                    pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
                    pages.pin(.{ .active = .{ .x = restored.cols - 1, .y = restored.rows - 1 } }).?,
                    false,
                ) };
                formatter.extra = .none;
                formatter.extra.screen.cursor = true;
                try stdout.interface.writeAll("\x1b[?2026h\x1b[0m\x1b[H\x1b[2J");
                try formatter.format(&stdout.interface);
                try stdout.interface.writeAll(if (restored.modes.get(.cursor_keys)) "\x1b[?1h" else "\x1b[?1l");
                try stdout.interface.writeAll(if (restored.modes.get(.bracketed_paste)) "\x1b[?2004h" else "\x1b[?2004l");
                try stdout.interface.writeAll("\x1b[?2026l");
                try stdout.interface.flush();
            }
            Sleep(100);
        }
    }
    if (std.mem.eql(u8, operation, "capture") or std.mem.eql(u8, operation, "snapshot")) {
        const header = try client.request(.snapshot, "", 0, buffer);
        if (std.mem.eql(u8, operation, "snapshot")) {
            try stdout.interface.writeAll(buffer[0..header.length]);
        } else {
            var reader: std.Io.Reader = .fixed(buffer[0..header.length]);
            var decoded = try snapshot.decode(alloc, global.io(), &reader, .{ .max_continuation_bytes = 64 * 1024 });
            defer decoded.deinit(alloc);
            var restored = decoded.toOwned();
            defer restored.deinit(alloc);
            const formatter = terminal.formatter.TerminalFormatter.init(&restored, .plain);
            try formatter.format(&stdout.interface);
        }
    } else {
        const op = std.meta.stringToEnum(protocol.Op, operation) orelse return error.InvalidOperation;
        var size: [4]u8 = undefined;
        const payload = switch (op) {
            .rename => args.next() orelse return error.ExpectedSessionLabel,
            .input => args.next() orelse return error.ExpectedInput,
            .resize => blk: {
                std.mem.writeInt(u16, size[0..2], try std.fmt.parseInt(u16, args.next() orelse return error.ExpectedColumns, 10), .little);
                std.mem.writeInt(u16, size[2..4], try std.fmt.parseInt(u16, args.next() orelse return error.ExpectedRows, 10), .little);
                break :blk &size;
            },
            else => "",
        };
        const header = try client.request(op, payload, 0, buffer);
        try stdout.interface.writeAll(buffer[0..header.length]);
    }
    try stdout.interface.flush();
}
