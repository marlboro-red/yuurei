//! Windows renderer workers. Each surface keeps its context and event state,
//! but shares an IOCP loop and OS thread with other surfaces on its worker.
const Pool = @This();
const std = @import("std");
const global = @import("../../global.zig");
const xev = global.xev;
const Thread = @import("../../renderer/Thread.zig");
const windows = @import("../../os/windows.zig");

alloc: std.mem.Allocator,
limit: usize,
workers: [4]?*Worker = @splat(null),
users: [4]usize = @splat(0),

pub fn create(alloc: std.mem.Allocator, limit: usize) !*Pool {
    std.debug.assert(limit > 0 and limit <= 4);
    const self = try alloc.create(Pool);
    self.* = .{ .alloc = alloc, .limit = limit };
    return self;
}

/// Called only by the app thread, as is remove/destroy.
pub fn add(self: *Pool, renderer: *Thread) !void {
    var index: usize = 0;
    for (self.users[0..self.limit], 0..) |count, i| {
        if (count < self.users[index]) index = i;
    }
    const worker = self.workers[index] orelse worker: {
        const value = try Worker.create(self.alloc);
        self.workers[index] = value;
        break :worker value;
    };
    try worker.request(.{ .start = renderer });
    renderer.pool_worker = index;
    self.users[index] += 1;
}

pub fn remove(self: *Pool, renderer: *Thread) void {
    const index = renderer.pool_worker;
    self.workers[index].?.request(.{ .remove = renderer }) catch |err| {
        // Never free a surface while callbacks might still refer to it.
        std.debug.panic("renderer removal failed: {}", .{err});
    };
    self.users[index] -= 1;
}

pub fn destroy(self: *Pool) void {
    for (self.workers, self.users) |worker, count| {
        std.debug.assert(count == 0);
        if (worker) |w| w.destroy(self.alloc);
    }
    self.alloc.destroy(self);
}

const Action = union(enum) { start: *Thread, remove: *Thread, shutdown };
const Request = struct {
    action: Action,
    done: std.Io.Event = .unset,
    failure: ?anyerror = null,
};

const Worker = struct {
    loop: xev.Loop,
    control: xev.Async,
    control_c: xev.Completion = .{},
    drain_timer: xev.Timer,
    drain_c: xev.Completion = .{},
    thread: std.Thread = undefined,
    request_mutex: std.Io.Mutex = .init,
    pending: std.atomic.Value(?*Request) = .init(null),
    removing: ?*Request = null,

    fn create(alloc: std.mem.Allocator) !*Worker {
        const self = try alloc.create(Worker);
        errdefer alloc.destroy(self);
        var loop = try xev.Loop.init(.{});
        errdefer loop.deinit();
        var control = try xev.Async.init();
        errdefer control.deinit();
        var timer = try xev.Timer.init();
        errdefer timer.deinit();
        self.* = .{
            .loop = loop,
            .control = control,
            .drain_timer = timer,
        };
        self.thread = try std.Thread.spawn(windows.worker_thread_config, run, .{self});
        self.thread.setName(global.io(), "renderer-pool") catch {};
        return self;
    }

    fn destroy(self: *Worker, alloc: std.mem.Allocator) void {
        self.request(.shutdown) catch unreachable;
        self.thread.join();
        self.control.deinit();
        self.drain_timer.deinit();
        self.loop.deinit();
        alloc.destroy(self);
    }

    fn request(self: *Worker, action: Action) !void {
        const io = global.io();
        self.request_mutex.lockUncancelable(io);
        defer self.request_mutex.unlock(io);
        var req: Request = .{ .action = action };
        self.pending.store(&req, .release);
        try self.control.notify();
        req.done.waitUncancelable(io);
        if (req.failure) |err| return err;
    }

    fn run(self: *Worker) void {
        self.control.wait(&self.loop, &self.control_c, Worker, self, controlCallback);
        self.loop.run(.until_done) catch |err| {
            std.debug.panic("renderer worker loop failed: {}", .{err});
        };
    }

    fn controlCallback(self_: ?*Worker, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
        result catch unreachable;
        const self = self_.?;
        const req = self.pending.swap(null, .acquire) orelse return .rearm;
        switch (req.action) {
            .start => |renderer| {
                renderer.sharedStart(&self.loop) catch |err| {
                    req.failure = err;
                };
            },
            .remove => |renderer| {
                renderer.sharedStop();
                self.removing = req;
                self.drain_timer.run(&self.loop, &self.drain_c, 0, Worker, self, drainCallback);
                return .rearm;
            },
            .shutdown => {
                self.loop.stop();
                req.done.set(global.io());
                return .disarm;
            },
        }
        req.done.set(global.io());
        return .rearm;
    }

    fn drainCallback(self_: ?*Worker, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
        result catch unreachable;
        const self = self_.?;
        const req = self.removing.?;
        const renderer = req.action.remove;
        if (!renderer.sharedDrained()) {
            self.drain_timer.run(&self.loop, &self.drain_c, 1, Worker, self, drainCallback);
            return .disarm;
        }
        renderer.sharedFinish() catch |err| {
            req.failure = err;
        };
        self.removing = null;
        req.done.set(global.io());
        return .disarm;
    }
};
