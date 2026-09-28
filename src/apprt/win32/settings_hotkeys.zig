//! Staged shortcuts. Persist only explicit changes after existing config entries.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const Binding = @import("../../input/Binding.zig");
const Allocator = std.mem.Allocator;

pub const Row = struct {
    key: []const u8,
    trigger: []const u8,
    actions: []const u8,
    disabled: bool = false,
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    original: []const Row = &.{},
    defaults: []const Row = &.{},
    rows: std.ArrayList(Row) = .empty,

    pub fn init(a: Allocator, current: *const Config, defaults: *const Config) !State {
        var self: State = .{ .arena = .init(a) };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        self.original = try collect(alloc, &current.keybind);
        self.defaults = try collect(alloc, &defaults.keybind);
        try self.rows.appendSlice(alloc, self.original);
        // Keep disabled default shortcuts discoverable and individually resettable.
        for (self.defaults) |row| if (find(self.rows.items, row.key) == null) {
            var disabled = row;
            disabled.disabled = true;
            try self.rows.append(alloc, disabled);
        };
        self.original = try alloc.dupe(Row, self.rows.items);
        self.sort();
        return self;
    }
    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
    pub fn sort(self: *State) void {
        std.mem.sort(Row, self.rows.items, {}, struct {
            fn less(_: void, a: Row, b: Row) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.less);
    }
    pub fn dirty(self: *const State) bool {
        if (self.rows.items.len != self.original.len) return true;
        for (self.rows.items) |row| {
            const i = find(self.original, row.key) orelse return true;
            if (!equal(row, self.original[i])) return true;
        }
        return false;
    }
    pub fn put(self: *State, selected: ?usize, trigger: []const u8, actions: []const u8) !void {
        const a = self.arena.allocator();
        const row = try normalize(a, trigger, actions);
        for (self.rows.items, 0..) |other, i| {
            if (selected == i or other.disabled) continue;
            if (conflicts(row.key, other.key)) return error.ShortcutConflict;
        }
        if (selected) |i| {
            // Moving a shortcut must disable its old trigger, including defaults.
            if (!std.mem.eql(u8, self.rows.items[i].key, row.key)) {
                try self.rows.ensureUnusedCapacity(a, 1);
                self.rows.items[i].disabled = true;
                if (find(self.rows.items, row.key)) |existing| self.rows.items[existing] = row else self.rows.appendAssumeCapacity(row);
            } else self.rows.items[i] = row;
        } else if (find(self.rows.items, row.key)) |i| self.rows.items[i] = row else try self.rows.append(a, row);
        self.sort();
    }
    pub fn reset(self: *State, i: usize) void {
        const key = self.rows.items[i].key;
        if (find(self.defaults, key)) |d| {
            for (self.rows.items, 0..) |*row, other| {
                if (other != i and conflicts(key, row.key)) row.disabled = true;
            }
            self.rows.items[i] = self.defaults[d];
        } else self.rows.items[i].disabled = true;
    }
    pub fn resetAll(self: *State) !void {
        const a = self.arena.allocator();
        try self.rows.ensureUnusedCapacity(a, self.defaults.len);
        for (self.rows.items) |*row| row.disabled = true;
        for (self.defaults) |row| {
            if (find(self.rows.items, row.key)) |i| self.rows.items[i] = row else self.rows.appendAssumeCapacity(row);
        }
        self.sort();
    }
    pub fn suffix(self: *const State, a: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        // Unbind first so moving a leader cannot erase newly assigned sequences.
        for (self.original) |old| {
            if (old.disabled) continue;
            const same = if (find(self.rows.items, old.key)) |i| equal(old, self.rows.items[i]) else false;
            if (!same) try out.writer.print("keybind = {s}=unbind\n", .{old.key});
        }
        for (self.rows.items) |row| {
            if (row.disabled) continue;
            if (find(self.original, row.key)) |i| {
                if (equal(row, self.original[i])) continue;
            }
            try writeRow(&out.writer, row);
        }
        return a.dupe(u8, out.written());
    }
};

pub fn find(rows: []const Row, key: []const u8) ?usize {
    for (rows, 0..) |row, i| if (std.mem.eql(u8, row.key, key)) return i;
    return null;
}
fn equal(a: Row, b: Row) bool {
    return a.disabled == b.disabled and (a.disabled or (std.mem.eql(u8, a.trigger, b.trigger) and std.mem.eql(u8, a.actions, b.actions)));
}
pub fn conflicts(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const short, const long = if (a.len < b.len) .{ a, b } else .{ b, a };
    return std.mem.startsWith(u8, long, short) and long[short.len] == '>';
}
pub fn matches(row: Row, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t");
    while (words.next()) |word| if (std.ascii.indexOfIgnoreCase(row.trigger, word) == null and std.ascii.indexOfIgnoreCase(row.actions, word) == null and !(row.disabled and std.ascii.indexOfIgnoreCase("disabled", word) != null)) return false;
    return true;
}
fn writeRow(w: *std.Io.Writer, row: Row) !void {
    var lines = std.mem.splitScalar(u8, row.actions, '\n');
    try w.print("keybind = {s}={s}\n", .{ row.trigger, lines.next().? });
    while (lines.next()) |action| try w.print("keybind = chain={s}\n", .{action});
}
fn walk(a: Allocator, set: *const Binding.Set, prefix: []const u8, rows: *std.ArrayList(Row), table: []const u8) anyerror!void {
    var it = set.bindings.iterator();
    while (it.next()) |entry| {
        const key = try std.fmt.allocPrint(a, "{s}{f}", .{ prefix, entry.key_ptr.* });
        switch (entry.value_ptr.*) {
            .leader => |leader| try walk(a, leader, try std.fmt.allocPrint(a, "{s}>", .{key}), rows, table),
            .leaf, .leaf_chained => {
                const leaf = switch (entry.value_ptr.*) {
                    .leaf => |*v| v.generic(),
                    .leaf_chained => |*v| v.generic(),
                    else => unreachable,
                };
                const flags = leaf.flags;
                const trigger = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}{s}", .{
                    table,                                      if (flags.global) "global:" else "",           if (flags.all) "all:" else "",
                    if (!flags.consumed) "unconsumed:" else "", if (flags.performable) "performable:" else "", key,
                });
                var actions: std.Io.Writer.Allocating = .init(a);
                defer actions.deinit();
                for (leaf.actionsSlice(), 0..) |action, i| {
                    if (i > 0) try actions.writer.writeByte('\n');
                    try actions.writer.print("{f}", .{action});
                }
                try rows.append(a, .{ .key = try std.fmt.allocPrint(a, "{s}{s}", .{ table, key }), .trigger = trigger, .actions = try a.dupe(u8, actions.written()) });
            },
        }
    }
}
fn collect(a: Allocator, bindings: *const Config.Keybinds) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    try walk(a, &bindings.set, "", &rows, "");
    var it = bindings.tables.iterator();
    while (it.next()) |table| try walk(a, table.value_ptr, "", &rows, try std.fmt.allocPrint(a, "{s}/", .{table.key_ptr.*}));
    return rows.toOwnedSlice(a);
}
pub fn normalize(a: Allocator, trigger: []const u8, actions: []const u8) !Row {
    if (trigger.len == 0 or trigger.len > 1024 or actions.len == 0 or actions.len > 8192 or std.mem.indexOfAny(u8, trigger, "=\r\n\x00") != null or std.mem.indexOfScalar(u8, actions, 0) != null) return error.InvalidShortcut;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var bindings: Config.Keybinds = .{};
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, actions, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |raw| {
        const action = std.mem.trim(u8, raw, " \t\r");
        if (action.len == 0) return error.InvalidShortcut;
        try bindings.parseCLI(temp, try std.fmt.allocPrint(temp, "{s}={s}", .{ if (first) trigger else "chain", action }));
        first = false;
    }
    const rows = try collect(temp, &bindings);
    if (rows.len != 1) return error.InvalidShortcut;
    return .{ .key = try a.dupe(u8, rows[0].key), .trigger = try a.dupe(u8, rows[0].trigger), .actions = try a.dupe(u8, rows[0].actions) };
}

test "windows settings hotkeys preserve flags chains and sequence conflicts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row = try normalize(a, "unconsumed:ctrl+b>c", "new_tab\ngoto_split:left");
    try std.testing.expectEqualStrings("unconsumed:ctrl+b>c", row.trigger);
    try std.testing.expectEqualStrings("new_tab\ngoto_split:left", row.actions);
    try std.testing.expect(conflicts("ctrl+b", "ctrl+b>c"));
    try std.testing.expect(!conflicts("ctrl+b>c", "ctrl+b>d"));
    try std.testing.expectError(error.InvalidShortcut, normalize(a, "ctrl+a\nkeybind", "new_tab"));
}

fn applySuffix(a: Allocator, cfg: *Config, suffix: []const u8) !void {
    var lines = std.mem.splitScalar(u8, suffix, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try cfg.keybind.parseCLI(a, line["keybind = ".len..]);
    }
}

test "windows settings hotkeys stage moves disable defaults and preserve unrelated bindings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var current = try Config.default(a);
    defer current.deinit();
    var defaults = try Config.default(a);
    defer defaults.deinit();
    try current.keybind.parseCLI(a, "f23=text:keep");
    var state = try State.init(std.testing.allocator, &current, &defaults);
    defer state.deinit();
    try std.testing.expect(!state.dirty());
    const old = find(state.rows.items, "f23").?;
    try state.put(old, "f24", "new_tab");
    try std.testing.expect(state.dirty());
    const suffix = try state.suffix(a);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "f23=unbind") != null);
    try applySuffix(a, &current, suffix);
    try std.testing.expect(current.keybind.set.get(try Binding.Trigger.parse("f23")) == null);
    try std.testing.expect(current.keybind.set.get(try Binding.Trigger.parse("f24")) != null);
    try std.testing.expect(current.keybind.set.get(try Binding.Trigger.parse("ctrl+shift+t")) != null);
    try std.testing.expectError(error.ShortcutConflict, state.put(null, "ctrl+shift+t", "new_window"));
}

test "windows settings hotkeys table flags and chained actions roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = try Config.default(a);
    defer cfg.deinit();
    var defaults = try Config.default(a);
    defer defaults.deinit();
    try cfg.keybind.parseCLI(a, "navigation/unconsumed:f23=new_tab");
    try cfg.keybind.parseCLI(a, "chain=goto_split:left");
    var state = try State.init(std.testing.allocator, &cfg, &defaults);
    defer state.deinit();
    const index = find(state.rows.items, "navigation/f23").?;
    try std.testing.expectEqualStrings("navigation/unconsumed:f23", state.rows.items[index].trigger);
    try state.put(index, "navigation/unconsumed:f23", "new_window\ngoto_split:right");
    try applySuffix(a, &cfg, try state.suffix(a));
    const rows = try collect(a, &cfg.keybind);
    const updated = rows[find(rows, "navigation/f23").?];
    try std.testing.expectEqualStrings("navigation/unconsumed:f23", updated.trigger);
    try std.testing.expectEqualStrings("new_window\ngoto_split:right", updated.actions);
}

test "windows settings hotkeys reset disabled defaults and reject sequence prefix collisions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = try Config.default(a);
    defer cfg.deinit();
    var defaults = try Config.default(a);
    defer defaults.deinit();
    try cfg.keybind.parseCLI(a, "ctrl+shift+t=unbind");
    try cfg.keybind.parseCLI(a, "f23>f24=new_tab");
    var state = try State.init(std.testing.allocator, &cfg, &defaults);
    defer state.deinit();
    const disabled = find(state.rows.items, "ctrl+shift+t").?;
    try std.testing.expect(state.rows.items[disabled].disabled);
    state.reset(disabled);
    try std.testing.expectError(error.ShortcutConflict, state.put(null, "f23", "new_window"));
    try applySuffix(a, &cfg, try state.suffix(a));
    try std.testing.expect(cfg.keybind.set.get(try Binding.Trigger.parse("ctrl+shift+t")) != null);
    try state.resetAll();
    try applySuffix(a, &cfg, try state.suffix(a));
    try std.testing.expect(Config.Keybinds.equal(defaults.keybind, cfg.keybind));
}

/// Keep table/behavior modifiers when recording a replacement key combination.
pub fn scopePrefix(trigger: []const u8) []const u8 {
    var end: usize = 0;
    if (std.mem.indexOfScalar(u8, trigger, '/')) |slash| {
        if (slash > 0 and std.mem.indexOfAny(u8, trigger[0..slash], "+>") == null) end = slash + 1;
    }
    while (true) {
        const before = end;
        for ([_][]const u8{ "global:", "all:", "unconsumed:", "performable:" }) |flag| {
            if (std.mem.startsWith(u8, trigger[end..], flag)) {
                end += flag.len;
                break;
            }
        }
        if (end == before) return trigger[0..end];
    }
}

test "windows settings hotkey recording retains scope and behavior" {
    try std.testing.expectEqualStrings("navigation/unconsumed:", scopePrefix("navigation/unconsumed:ctrl+c"));
    try std.testing.expectEqualStrings("performable:", scopePrefix("performable:ctrl+c"));
    try std.testing.expectEqualStrings("", scopePrefix("ctrl+/"));
}
