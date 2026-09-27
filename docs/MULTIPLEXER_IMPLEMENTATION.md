# Multiplexer implementation

Branch: `feature/multiplexer`, based on `6184a41a5` (v0.2.18).

Status: experimental single-pane broker and console attachment implemented.
The normal application and release build do not enable or install it. Research is in
[`MULTIPLEXER_RESEARCH.md`](MULTIPLEXER_RESEARCH.md).

## Proposed first milestone: one persistent native pane

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
- `src/termio/backend.zig`: currently only an `exec` backend; client attachment
  needs a separate backend or another explicit integration boundary.
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
- [ ] Implement an incremental native pane backend.
      Bound slow-client queues so GUI stalls cannot stall shell output.
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
zig build test-mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2 -Dtest-filter=mux
pwsh -NoProfile -File test/windows/mux-smoke.ps1 -GuiExecutable 'C:\path\to\ghostty.exe'
```

The test starts a broker separately from the disposable GUI, kills that GUI
during output, opens a second GUI, verifies input reaches the original shell,
and detaches with Ctrl+]. It also tests duplicate host rejection, invalid
dimensions, child exit, and repeated reconnect handle counts. Artifacts include
screenshots, logs, captures, and memory/idle CPU samples. Omitting `GuiExecutable`
runs the headless checks only.

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
client at a time, so detach the console client before issuing diagnostic commands.
The broker retains an exited shell's screen until explicitly stopped.

## Current bounds and limitations

- The broker uses a blocking output reader and an event-driven input writer.
  Network writes occur outside the terminal lock, so an unread client response
  does not retain that lock or stop PTY draining.
- Requests and the pending input queue are limited to 64 KiB each. Responses
  are limited to 16 MiB, parser continuation to 64 KiB, and scrollback to a
  1 MiB target (terminal page granularity applies). Grid dimensions are limited
  to 512 columns by 256 rows. Kitty image storage is disabled.
- Each transport transfer has a three-second deadline; failed or incompatible
  clients disconnect without terminating the broker. Authentication checks
  OS-reported PID, user SID, integrity SID, Windows session ID, and image path.
  Remote pipe clients are rejected. A hello exchanges the build version string.
- The console client polls at 100 ms and reconstructs the active viewport from
  snapshots. Its redraw latency, allocations, selection/scrollback behavior,
  and full keyboard/mouse protocol coverage are not production quality.
  This path exists to exercise persistence before adding native pane attachment.
- Binary snapshots preserve both screens and scrollback, but the temporary
  viewport formatter is not a full-fidelity native view. Full-screen application
  compatibility, graphics, clipboard, notifications, and accessibility require
  additional implementation and validation.
- Complete snapshots replace previous state at each sequence boundary; there
  is no accumulated output replay log. Incremental transport is still required
  for efficient rendering and normal terminal interaction.

Initial validation on 2026-09-27: PowerShell continued producing output after
test GUI termination; reconnect used the same PID and delivered input. Twenty
reconnects held broker handles and threads constant. One run measured about
13 MiB resident and 54 MiB committed. These are prototype observations, not
performance acceptance thresholds or long-term leak measurements.
