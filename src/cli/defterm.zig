const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// `--unregister`: remove the default-terminal registration instead
    /// of adding it.
    unregister: bool = false,

    /// `--status`: report whether yuurei is currently the default
    /// terminal, and exit.
    status: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+defterm` action: register (default), unregister, or report the
/// Windows default-terminal handoff. Windows only.
///
///   ghostty +defterm              # register yuurei as default terminal
///   ghostty +defterm --unregister # remove the registration
///   ghostty +defterm --status     # print current state
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc: Allocator, argsIter: anytype) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc, &opts, argsIter);

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (comptime builtin.os.tag != .windows) {
        try stdout.writeAll("+defterm is only supported on Windows.\n");
        return 1;
    }

    const defterm = @import("../apprt/win32/defterm.zig");

    if (opts.status) {
        if (defterm.isRegistered()) {
            try stdout.writeAll("yuurei IS the default terminal application.\n");
        } else {
            try stdout.writeAll("yuurei is NOT the default terminal application.\n");
        }
        return 0;
    }

    if (opts.unregister) {
        defterm.unregister();
        try stdout.writeAll("Removed yuurei's default-terminal registration.\n");
        return 0;
    }

    // Refuse to register until the handoff server is implemented:
    // registering without it would break console launching.
    if (!defterm.handoff_ready) {
        try stdout.writeAll(
            "Default-terminal handoff is not yet available in this build.\n" ++
                "(The registration plumbing is in place; the COM handoff server is\n" ++
                "still under construction. Registering now would break console\n" ++
                "launching, so it is disabled.)\n",
        );
        return 1;
    }

    if (defterm.register()) {
        try stdout.writeAll(
            "yuurei is now the default terminal application.\n" ++
                "Console apps launched from Explorer, Start, or a debugger will open here.\n" ++
                "Run `ghostty +defterm --unregister` to undo.\n",
        );
        return 0;
    }

    try stdout.writeAll("Failed to register (see log). Registration was rolled back.\n");
    return 1;
}
