# Multiplexer implementation

Branch: `feature/multiplexer`, based on `6184a41a5` (v0.2.18).

Status: experimental single-pane broker, native pane backend, and diagnostic
console client implemented. Native attachment is disabled by default; the broker
is built only with the explicit `mux` target. Research is in
[`MULTIPLEXER_RESEARCH.md`](MULTIPLEXER_RESEARCH.md).

## First milestone: one persistent native pane

The user selected this milestone: prove that one PowerShell process can continue
running when its GUI closes or crashes, then reconnect with correct terminal
state. Keep this opt-in while it is experimental.

The broker owns ConPTY, its child process, output draining, terminal parsing,
and authoritative terminal state. The GUI owns presentation and user input.
Detaching releases a client connection; terminating a pane closes its ConPTY.
Do not use hidden GUI windows as the persistence guarantee.

Initial scope is a local broker and one controlling GUI. Broker or machine
restart does not preserve running processes. Default-terminal handoff, remote
transport, simultaneous viewers, and tmux interoperability need later work.

## Code boundaries verified in the current tree

- `src/apprt/win32/Surface.zig`: split view lifetime from session lifetime.
- `src/termio/backend.zig`: the normal `exec` backend and Windows-only `mux`
  implementation have separate ownership and teardown paths.
- `src/termio/Termio.zig`: renderer state, wakeups, and surface mailboxes remain
  dependencies. A headless host must address these rather than instantiate a
  normal GUI surface.
- `src/pty.zig`: the broker must own the Windows pseudoconsole and its pipe
  handles, including shutdown and continued output draining while detached.
- `src/apprt/win32/instance.zig`: existing authenticated launch forwarding is
  useful precedent, but is not a persistent session protocol. Its endpoint
  identity includes the build version; session discovery must explicitly handle
  incompatible builds without silently hiding or terminating older sessions.
- `src/terminal/snapshot/main.zig`: snapshot framing and parser continuation
  exist, but require an outer transport, ordering rules, and compatibility checks.
- `src/apprt/win32/Updater.zig`: installation replacement must account for a
  broker using the executable even when no GUI remains.

## Implementation gates

- [ ] Specify session/view ownership, detach/terminate semantics, and broker
      discovery, authentication, and version compatibility.
- [x] Implement versioned, bounded framing and a named single-pane endpoint;
      unit-test invalid magic, versions, flags, operations, and payload lengths.
- [x] Host one native shell independently of GUI lifetime; verify continued
      output and unchanged shell PID across client disconnects.
- [x] Establish authoritative terminal parsing and query responses in the broker.
      Clipboard and desktop effects are disabled in this prototype.
- [ ] Complete protocol adversarial testing, including fragmented requests,
      stalled peers, and cross-user/logon/elevation isolation on Windows.
- [x] Implement an incremental native pane backend with bounded event history.
      A stale client disconnects without stopping shell output.
- [ ] Replace short polling with independently multiplexed push notifications,
      and benchmark native attachment latency and idle CPU.
- [x] Attach a temporary console client using sequenced complete snapshots.
      It redraws the active viewport; it is not the final renderer integration.
- [x] Test resize, alternate screen, scrollback, partial UTF-8/VT sequences,
      child exit, repeated reconnects, and termination of only the test GUI.
- [ ] Measure attached/detached CPU, committed memory, resident memory, threads,
      handles, and reconnect latency against the normal single-pane path.
- [ ] Add named workspaces, tab/split layout ownership, and session controls
      after the persistence gate passes.

## Test isolation

Use a separate experimental build, isolated config/cache paths, and a distinct
broker endpoint. Never terminate the user's daily Yuurei instance: it hosts
this development session. Crash tests target only processes created by their
own harness. Release installation and automatic updates stay untouched.

## Build and exercise

```powershell
zig build mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build test-mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2 -Dtest-filter=mux
pwsh -NoProfile -File test/windows/mux-smoke.ps1 -GuiExecutable "$PWD/zig-out/bin/ghostty.exe" -NativePane
```

The test starts a broker separately from the disposable GUI, kills that GUI
during output, opens a second GUI, verifies input reaches the original shell,
and closes the native pane to detach. It verifies that the GUI creates no helper
shell, and compares retained scrollback screenshots during continued output.
It also tests duplicate host rejection, invalid dimensions, missing-session
handling, child exit, and repeated reconnect handle counts. Artifacts include
screenshots, logs, captures, and memory/idle CPU samples. Omitting `GuiExecutable`
runs the headless checks only. Omitting `NativePane` exercises the older console
client, where Ctrl+] detaches.

To open a native pane after starting a broker named `demo`:

```powershell
.\zig-out\bin\ghostty.exe --windows-mux-session=demo --windows-restore-session=false
```

The GUI and broker must be built from the same revision and installed as siblings
named `ghostty.exe` and `yuurei-mux.exe`. Closing the native pane detaches. Normal
close confirmation is skipped because the shell survives; an explicit `always`
policy still applies. Startup `input` is not replayed on attachment. Opening
another pane for the same session while one is attached shows an error pane;
there is no automatic shell fallback or takeover.

The native backend installs one binary snapshot before the surface is exposed,
then applies ordered VT-output and resize events to the same terminal object.
Selection pins and viewport state remain local to the view. A read-only parser
prevents duplicate query replies and external side effects. Resize events are
ordered with output rather than applied speculatively by the GUI.

For manual experimentation, start a separate host and attach from a console:

```powershell
$mux = (Resolve-Path .\zig-out\bin\yuurei-mux.exe).Path
Start-Process -FilePath $mux -ArgumentList 'serve demo pwsh.exe -NoLogo -NoProfile' -WindowStyle Hidden
& $mux attach demo
# Ctrl+] detaches. Running attach again reconnects to the same shell.
& $mux status demo
& $mux capture demo
& $mux stop demo
```

`serve` runs in the foreground of its own process; it does not daemonize itself.
Automatic launch, job/console breakaway, discovery, and upgrade coordination are
still integration work. Closing a console that directly hosts `serve`, killing
the broker, logout, and reboot are outside the persistence guarantee.

`stop` explicitly terminates the hosted session. `status`, `capture`, `snapshot`
(binary), `input`, and `resize` are diagnostic commands. There is one connected
client at a time, so detach the native or console client before issuing diagnostic commands.
The broker retains an exited shell's screen until explicitly stopped.

## Current bounds and limitations

See [native performance measurements](MULTIPLEXER_BENCHMARK.md) for the
direct-versus-broker comparison, the original event-history overrun, and the
verified notification/backpressure and memory improvements. This remains an
experimental backend.

- The broker uses a blocking output reader and an event-driven input writer.
  Network writes occur outside the terminal lock. An unread response cannot
  retain that lock; subscribed views use the bounded backpressure described below.
- Requests and the pending input queue are limited to 64 KiB each. Responses
  are limited to 16 MiB, parser continuation to 64 KiB, and scrollback to a
  1 MiB target (terminal page granularity applies). Grid dimensions are limited
  to 512 columns by 256 rows. Kitty image storage is disabled.
- Broker workers use the standard 256 KiB initial stack commit with on-demand
  growth. The broker retains a 1 MiB response buffer; larger snapshot staging
  buffers use temporary page allocations released after each snapshot transfer.
- Each transport transfer has a three-second deadline; failed or incompatible
  clients disconnect without terminating the broker. Authentication checks
  OS-reported PID, user SID, integrity SID, Windows session ID, and image path.
  The image must be one of the two expected executables in the same installation
  directory. Remote pipe clients are rejected. A hello exchanges the build version
  string; protocol version 3 adds native output-event subscriptions. After the
  handshake, an idle connection waits indefinitely for the first header byte;
  the rest of each transfer remains bounded.
- The console client polls at 100 ms and reconstructs the active viewport from
  snapshots. Its redraw latency, allocations, selection/scrollback behavior,
  and full keyboard/mouse protocol coverage are not production quality.
  It is retained as a diagnostic path; native panes do not use this formatter.
- Binary snapshots preserve both screens and scrollback, but the temporary
  viewport formatter is not a full-fidelity native view. Full-screen application
  compatibility, graphics, clipboard, notifications, and accessibility require
  additional implementation and validation.
- Native panes use a 1 MiB circular event history. A subscribed view protects
  its undelivered events; the broker pauses PTY reads when that history fills.
  Copying events to the response releases their journal space. Disconnect
  releases protection immediately; three seconds without space also releases
  it so an unresponsive view cannot permanently block shell output. Detached
  sessions continue draining and evicting old events. An expired client retains its last
  screen and gets a disconnected title; close and reopen the pane to take a fresh
  snapshot. It never replaces a live terminal beneath tracked selection pins.
- Native input, resize, and output wake the connection worker immediately.
  The view duplicates a wait-only handle to the authenticated broker's output
  event, catches up until the journal is empty, then waits without a polling
  timer. A broker process handle also wakes it on broker exit. Connection errors retain
  the view and leave the broker alive. Broker exit and automatic reconnect UI
  still need refinement.

Initial validation on 2026-09-27: PowerShell continued producing output after
test GUI termination; reconnect used the same PID and delivered input. Twenty
reconnects held broker handles and threads constant. One run measured about
13 MiB resident and 54 MiB committed. These are prototype observations, not
performance acceptance thresholds or long-term leak measurements.

Native follow-up: GUI crash/reopen retained the original PID, Unicode rendering,
and input; there were no GUI-owned shell/helper children. Retained scrollback
screenshots stayed identical while output continued. Burst tests are separate:
the 1 MiB history limit can legitimately evict viewed rows during sustained
output. Unit tests compare complete binary terminal states after snapshot
restoration plus partial UTF-8, alternate-screen transitions, and ordered resize
events. Normal tab transfer between independently launched windows also passed.
