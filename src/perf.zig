//! Lightweight, env-gated performance tracing (yuurei Phase 5).
//!
//! Set GHOSTTY_PERF_TRACE=1 to enable (an empty value or "0" leaves it
//! disabled). Costs a single relaxed atomic load on the traced paths
//! when disabled. This is intentionally minimal plumbing for measuring
//! the port on real machines — not a general profiling framework.
const std = @import("std");
const builtin = @import("builtin");

/// Nanosecond timestamp of the most recent key press. Consumed by the
/// renderer on the first present after pty data arrived (the echo
/// frame) — a present triggered by the key itself (cursor blink
/// reset) must not consume it, so consumption is gated on echo_seen.
/// One global is enough for the single-focused-surface measurements
/// this is for.
pub var key_press_ns: std.atomic.Value(i64) = .init(0);

/// Set by the io read thread when pty output arrives while a key
/// press is pending: the next present is the echo frame.
pub var echo_seen: std.atomic.Value(bool) = .init(false);

var enabled = std.atomic.Value(u8).init(0xFF);

/// Whether tracing is enabled (GHOSTTY_PERF_TRACE set to something
/// other than "" or "0" — presence alone must not enable it, or the
/// conventional VAR=0 would turn tracing on). First call reads the
/// environment; later calls are a relaxed load.
pub fn isEnabled() bool {
    const v = enabled.load(.monotonic);
    if (v != 0xFF) return v != 0;
    const e = read: {
        if (comptime builtin.os.tag == .windows) {
            const key = std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_PERF_TRACE");
            const value = std.process.getenvW(key) orelse break :read false;
            if (value.len == 0) break :read false;
            if (value.len == 1 and value[0] == '0') break :read false;
            break :read true;
        }
        const value = std.posix.getenv("GHOSTTY_PERF_TRACE") orelse break :read false;
        break :read value.len > 0 and !std.mem.eql(u8, value, "0");
    };
    enabled.store(@intFromBool(e), .monotonic);
    return e;
}

/// Record a key press instant.
pub fn keyPress() void {
    if (!isEnabled()) return;
    echo_seen.store(false, .monotonic);
    const now: i64 = @intCast(std.time.nanoTimestamp());
    key_press_ns.store(now, .monotonic);
    last_key_ns.store(now, .monotonic);
}

/// Like key_press_ns but never consumed, so timeline tracing can
/// reference presents after the echo present was already counted.
var last_key_ns: std.atomic.Value(i64) = .init(0);

/// Called by the io read thread when pty output arrives; marks the
/// pending key press (if any) as echoed.
pub fn ptyData() void {
    if (key_press_ns.load(.monotonic) != 0) echo_seen.store(true, .monotonic);
}

/// Elapsed ms since the most recent key press (within 2s), or null.
/// Used by timeline tracing to correlate pipeline stages; not consumed
/// by keyToPresent so post-echo presents still correlate.
pub fn sinceKeyMs() ?i64 {
    if (!isEnabled()) return null;
    const t = last_key_ns.load(.monotonic);
    if (t == 0) return null;
    const now: i64 = @intCast(std.time.nanoTimestamp());
    const ms = @divTrunc(now - t, std.time.ns_per_ms);
    if (ms > 2000) return null;
    return ms;
}

/// Consume the pending key press and return the elapsed time to now,
/// if a press was pending and its echo has arrived from the pty.
pub fn keyToPresent() ?u64 {
    if (!isEnabled()) return null;
    if (!echo_seen.load(.monotonic)) return null;
    const t = key_press_ns.swap(0, .monotonic);
    if (t == 0) return null;
    echo_seen.store(false, .monotonic);
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return @intCast(@max(0, now - t));
}
