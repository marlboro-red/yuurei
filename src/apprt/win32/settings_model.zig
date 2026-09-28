//! Settings metadata and file transactions, independent of the native UI.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const global = @import("../../global.zig");
const Allocator = std.mem.Allocator;

pub const Category = enum { appearance, terminal, windows, input, updates, shortcuts };
pub const categories = [_][]const u8{ "Appearance", "Terminal", "Windows & tabs", "Input", "Updates", "Keyboard shortcuts" };
pub const descriptions = [_][]const u8{
    "Themes, fonts, and transparency.",
    "Shell startup, cursor, and closing behavior.",
    "Persistent sessions, workspace restore, and tab behavior.",
    "Mouse, clipboard, and keyboard behavior.",
    "Release updates and installation status.",
    "Key combinations, sequences, and terminal actions.",
};
pub const Kind = enum { text, choice, toggle, theme, font };
pub const Field = struct {
    key: [:0]const u8,
    title: [:0]const u8,
    description: []const u8,
    category: Category,
    kind: Kind,
    choices: []const []const u8 = &.{},
    restart: bool = false,
};
pub const fields = [_]Field{
    .{ .key = "theme", .title = "Color theme", .description = "Theme name, path, or light/dark theme pair.", .category = .appearance, .kind = .theme },
    .{ .key = "font-family", .title = "Font family", .description = "Installed font or custom family name.", .category = .appearance, .kind = .font },
    .{ .key = "font-size", .title = "Font size", .description = "Text size in points, including fractional values.", .category = .appearance, .kind = .text },
    .{ .key = "background-opacity", .title = "Background opacity", .description = "Opacity from 0 to 1. A value of 1 is fully opaque.", .category = .appearance, .kind = .text },
    .{ .key = "background-blur", .title = "Background blur", .description = "Blur behind transparent terminal backgrounds.", .category = .appearance, .kind = .choice, .choices = &.{ "false", "true", "20", "40", "60", "80" } },
    .{ .key = "window-theme", .title = "Interface theme", .description = "System, light, or dark interface appearance.", .category = .appearance, .kind = .choice, .choices = &.{ "auto", "dark", "light", "ghostty", "system" } },
    .{ .key = "command", .title = "Default shell", .description = "For example: pwsh.exe, cmd.exe, or wsl.exe -d Ubuntu.", .category = .terminal, .kind = .text, .restart = true },
    .{ .key = "working-directory", .title = "Starting directory", .description = "Use home, inherit, or an absolute folder path.", .category = .terminal, .kind = .text, .restart = true },
    .{ .key = "cursor-style", .title = "Cursor shape", .description = "Default terminal cursor shape.", .category = .terminal, .kind = .choice, .choices = &.{ "block", "bar", "underline", "block_hollow" } },
    .{ .key = "cursor-style-blink", .title = "Blinking cursor", .description = "Enable cursor blinking.", .category = .terminal, .kind = .choice, .choices = &.{ "", "true", "false" } },
    .{ .key = "confirm-close-surface", .title = "Confirm before closing", .description = "Ask before closing a terminal with a running process.", .category = .terminal, .kind = .choice, .choices = &.{ "true", "false", "always" } },
    .{ .key = "windows-persistent-sessions", .title = "Persistent sessions (experimental)", .description = "Keep shells after windows close. New panes only.", .category = .windows, .kind = .toggle, .restart = true },
    .{ .key = "windows-restore-session", .title = "Restore workspace on launch", .description = "Restore tabs, splits, and folders. Reattach persistent shells.", .category = .windows, .kind = .toggle },
    .{ .key = "windows-titlebar-thin", .title = "Compact tab bar", .description = "Reduce the height of the title bar.", .category = .windows, .kind = .toggle },
    .{ .key = "window-inherit-working-directory", .title = "New windows keep the folder", .description = "Start new windows in the current terminal's directory.", .category = .windows, .kind = .toggle },
    .{ .key = "tab-inherit-working-directory", .title = "New tabs keep the folder", .description = "Start new tabs in the current terminal's directory.", .category = .windows, .kind = .toggle },
    .{ .key = "split-inherit-working-directory", .title = "New splits keep the folder", .description = "Start new panes in the current terminal's directory.", .category = .windows, .kind = .toggle },
    .{ .key = "mouse-hide-while-typing", .title = "Hide pointer while typing", .description = "Hide until the next mouse movement.", .category = .input, .kind = .toggle },
    .{ .key = "copy-on-select", .title = "Copy selected text", .description = "Copy selections directly to the Windows clipboard.", .category = .input, .kind = .choice, .choices = &.{ "none", "clipboard" } },
    .{ .key = "win32-input-mode", .title = "Windows keyboard compatibility", .description = "Preserve modifiers such as Shift+Enter in console apps.", .category = .input, .kind = .toggle, .restart = true },
    .{ .key = "windows-auto-update", .title = "Automatic updates", .description = "Download daily. Install after all windows and persistent sessions close.", .category = .updates, .kind = .toggle },
    .{ .key = "windows-workspace", .title = "Workspace name", .description = "Separate names keep independent saved layouts. Applies after restart.", .category = .windows, .kind = .text, .restart = true },
};

pub fn choiceLabel(index: usize, raw: []const u8) []const u8 {
    const key = fields[index].key;
    if (std.mem.eql(u8, key, "confirm-close-surface")) {
        if (std.mem.eql(u8, raw, "true")) return "Running processes";
        if (std.mem.eql(u8, raw, "false")) return "Never";
        if (std.mem.eql(u8, raw, "always")) return "Always";
    }
    const pairs = .{
        .{ "", "Use default" },                    .{ "true", "On" },                   .{ "false", "Off" },
        .{ "none", "Off" },                        .{ "clipboard", "To clipboard" },    .{ "auto", "Automatic" },
        .{ "system", "Follow Windows" },           .{ "dark", "Dark" },                 .{ "light", "Light" },
        .{ "ghostty", "Follow Windows (legacy)" }, .{ "block", "Block" },               .{ "bar", "Bar" },
        .{ "underline", "Underline" },             .{ "block_hollow", "Hollow block" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, raw, pair[0])) return pair[1];
    }
    return raw;
}

pub fn choiceValue(index: usize, label: []const u8) []const u8 {
    for (fields[index].choices) |v| {
        if (std.ascii.eqlIgnoreCase(label, choiceLabel(index, v))) return v;
    }
    return label;
}

pub fn matches(field: Field, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t");
    while (words.next()) |word| {
        if (std.ascii.indexOfIgnoreCase(field.title, word) == null and
            std.ascii.indexOfIgnoreCase(field.description, word) == null and
            std.ascii.indexOfIgnoreCase(field.key, word) == null) return false;
    }
    return true;
}

pub fn value(text: []const u8, key: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, withoutBom(text), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const next = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "font-family")) {
            if (next.len == 0) result = null else if (result == null) {
                result = next;
            }
        } else result = next;
    }
    return result;
}

fn withoutBom(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
}

pub fn effective(alloc: Allocator, config: *const Config, index: usize) ![]const u8 {
    inline for (fields, 0..) |field, i| {
        if (index == i) {
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            const v = @field(config, field.key);
            try @import("../../config/formatter.zig").formatEntry(@TypeOf(v), field.key, v, &buf.writer);
            return alloc.dupe(u8, value(buf.written(), field.key) orelse "");
        }
    }
    unreachable;
}

pub fn validate(alloc: Allocator, index: usize, text: []const u8) !void {
    if (std.mem.indexOfAny(u8, text, "\r\n\x00") != null) return error.InvalidValue;
    const field = fields[index];
    if (std.mem.eql(u8, field.key, "font-size") or std.mem.eql(u8, field.key, "background-opacity")) {
        const n = std.fmt.parseFloat(f64, text) catch return error.InvalidValue;
        if (!std.math.isFinite(n)) return error.InvalidValue;
        if (std.mem.eql(u8, field.key, "font-size")) {
            if (n < 4 or n > 96) return error.InvalidValue;
        } else if (n < 0 or n > 1) return error.InvalidValue;
    }
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arg = try std.fmt.allocPrint(alloc, "--{s}={s}", .{ field.key, text });
    defer alloc.free(arg);
    var iter = @import("../../cli.zig").args.sliceIterator(&.{arg});
    try cfg.loadIter(alloc, &iter);
    // Theme names are parsed before their files are loaded. Finalize here so
    // misspelled names don't get written as apparently valid settings.
    if (index == 0) try cfg.finalize();
    if (!cfg._diagnostics.empty()) return error.InvalidValue;
}

pub const Change = struct { index: usize, value: ?[]const u8 };

/// Rewrite only edited keys. Reset removes all occurrences so an earlier
/// duplicate cannot unexpectedly become active. Preserve font fallbacks
/// unless the font-family control itself was edited.
pub fn rewrite(alloc: Allocator, text: []const u8, changes: []const Change) ![]u8 {
    if (changes.len == 0) return alloc.dupe(u8, text);
    const newline: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var written: [fields.len]bool = @splat(false);
    const content = withoutBom(text);
    if (content.len != text.len) try out.writer.writeAll("\xef\xbb\xbf");
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 and lines.peek() == null) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        var changed = false;
        if (line.len > 0 and line[0] != '#') {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const key = std.mem.trim(u8, line[0..eq], " \t");
                for (changes) |change| {
                    if (!std.mem.eql(u8, key, fields[change.index].key)) continue;
                    if (!written[change.index]) {
                        if (change.value) |v| try out.writer.print("{s} = {s}{s}", .{ key, v, newline });
                        written[change.index] = true;
                    }
                    changed = true;
                    break;
                }
            }
        }
        if (!changed) try out.writer.print("{s}{s}", .{ std.mem.trimEnd(u8, raw, "\r"), newline });
    }
    for (changes) |change| {
        if (!written[change.index]) {
            if (change.value) |v| try out.writer.print("{s} = {s}{s}", .{ fields[change.index].key, v, newline });
        }
    }
    return alloc.dupe(u8, out.written());
}

pub fn read(alloc: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => alloc.dupe(u8, ""),
        else => return err,
    };
}

pub fn save(alloc: Allocator, path: []const u8, baseline: []const u8, changes: []const Change) !void {
    return saveWithShortcuts(alloc, path, baseline, changes, "");
}

pub fn saveWithShortcuts(alloc: Allocator, path: []const u8, baseline: []const u8, changes: []const Change, shortcuts: []const u8) !void {
    const io = global.io();
    const current = try read(alloc, path);
    defer alloc.free(current);
    if (!std.mem.eql(u8, current, baseline)) return error.ConfigChanged;
    const settings = try rewrite(alloc, current, changes);
    defer alloc.free(settings);
    const text = try appendShortcuts(alloc, settings, shortcuts);
    defer alloc.free(text);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{d}.settings.tmp", .{ path, std.os.windows.GetCurrentThreadId() });
    defer alloc.free(tmp);
    defer std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp, .{ .truncate = true });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(text);
        try writer.interface.flush();
        try file.sync(io);
    }
    // Recheck after preparing the replacement: avoid overwriting an editor
    // save that occurred while the settings file was being written.
    const latest = try read(alloc, path);
    defer alloc.free(latest);
    if (!std.mem.eql(u8, latest, baseline)) return error.ConfigChanged;
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

test "windows settings transactions preserve comments, fallbacks and reset duplicates" {
    const a = std.testing.allocator;
    const original = "# keep me\r\nfont-family = A\r\nfont-family = B\r\nfont-size = 10\r\nfont-size = 12\r\n";
    const updated = try rewrite(a, original, &.{.{ .index = 2, .value = "14" }});
    defer a.free(updated);
    try std.testing.expectEqualStrings("# keep me\r\nfont-family = A\r\nfont-family = B\r\nfont-size = 14\r\n", updated);
    const reset = try rewrite(a, updated, &.{.{ .index = 2, .value = null }});
    defer a.free(reset);
    try std.testing.expect(value(reset, "font-size") == null);
    try std.testing.expectEqualStrings("A", value(reset, "font-family").?);
    const font = try rewrite(a, original, &.{.{ .index = 1, .value = "C" }});
    defer a.free(font);
    try std.testing.expect(std.mem.indexOf(u8, font, "font-family = B") == null);
}

test "windows settings validation and search" {
    try validate(std.testing.allocator, 2, "12.5");
    try std.testing.expectError(error.InvalidValue, validate(std.testing.allocator, 2, "nan"));
    try std.testing.expectError(error.InvalidValue, validate(std.testing.allocator, 3, "1.5"));
    try std.testing.expectError(error.InvalidValue, validate(std.testing.allocator, 6, "pwsh\ncommand=cmd"));
    try std.testing.expect(matches(fields[14], "WINDOW folder"));
    try std.testing.expect(!matches(fields[14], "font"));
}

test "windows settings choices use supported config values" {
    for (fields, 0..) |field, i| {
        for (field.choices) |choice| {
            if (choice.len > 0) try validate(std.testing.allocator, i, choice);
            try std.testing.expectEqualStrings(choice, choiceValue(i, choiceLabel(i, choice)));
        }
        if (field.kind == .toggle) {
            try validate(std.testing.allocator, i, "true");
            try validate(std.testing.allocator, i, "false");
        }
    }
}

test "windows settings preserve BOM and honor font reset chains" {
    const a = std.testing.allocator;
    const original = "\xef\xbb\xbffont-size = 12\nfont-family = A\nfont-family =\nfont-family = B\nfont-family = C\n";
    try std.testing.expectEqualStrings("12", value(original, "font-size").?);
    try std.testing.expectEqualStrings("B", value(original, "font-family").?);
    const updated = try rewrite(a, original, &.{.{ .index = 2, .value = "14" }});
    defer a.free(updated);
    try std.testing.expect(std.mem.startsWith(u8, updated, "\xef\xbb\xbffont-size = 14\n"));
    const unchanged = try rewrite(a, original, &.{});
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
}

fn appendShortcuts(alloc: Allocator, text: []const u8, shortcuts: []const u8) ![]u8 {
    if (shortcuts.len == 0) return alloc.dupe(u8, text);
    const newline: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.writer.writeAll(newline);
    var lines = std.mem.splitScalar(u8, shortcuts, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        try out.writer.writeAll(line);
        try out.writer.writeAll(newline);
    }
    return alloc.dupe(u8, out.written());
}

test "windows settings shortcut transactions preserve unrelated config and CRLF" {
    const a = std.testing.allocator;
    const original = "\xef\xbb\xbf# shortcuts\r\nconfig-file = custom.conf\r\nkeybind = f23=new_tab\r\n";
    const updated = try appendShortcuts(a, original, "keybind = f23=unbind\nkeybind = f24=new_tab\n");
    defer a.free(updated);
    try std.testing.expectEqualStrings(original ++ "keybind = f23=unbind\r\nkeybind = f24=new_tab\r\n", updated);
    const unchanged = try appendShortcuts(a, original, "");
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
}
