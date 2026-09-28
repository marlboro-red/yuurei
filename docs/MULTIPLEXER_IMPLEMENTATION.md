# Multiplexer implementation

Branch: `feature/multiplexer`, based on `6184a41a5` (v0.2.18).

Status: opt-in persistent native panes, automatic broker startup, discovery,
native session controls, named workspace restore, automatic stale-view recovery,
exit status, and bounded large-input delivery are implemented. Each
pane currently owns an independent broker; one view attaches per broker.
The broker is bundled in normal Windows builds. Research is in
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

- [x] Specify session/view ownership, detach/terminate semantics, and broker
      discovery, authentication, and version compatibility.
- [x] Implement versioned, bounded framing and a named single-pane endpoint;
      unit-test invalid magic, versions, flags, operations, and payload lengths.
- [x] Host one native shell independently of GUI lifetime; verify continued
      output and unchanged shell PID across client disconnects.
- [x] Establish authoritative terminal parsing and query responses in the broker.
      Clipboard and desktop effects are disabled in this prototype.
- [x] Test fragmented requests, stalled peers, malformed framing, oversized
      payloads, unauthorized executable rejection, and recovery without leaks.
- [ ] Validate cross-user/logon/elevation isolation with separate Windows accounts.
- [x] Implement an incremental native pane backend with bounded event history.
      A stale client disconnects without stopping shell output.
- [x] Replace short polling with independently multiplexed push notifications,
      and benchmark native attachment latency and idle CPU.
- [x] Attach a temporary console client using sequenced complete snapshots.
      It redraws the active viewport; it is not the final renderer integration.
- [x] Test resize, alternate screen, scrollback, partial UTF-8/VT sequences,
      child exit, repeated reconnects, and termination of only the test GUI.
- [x] Measure attached/detached CPU, committed memory, resident memory, threads,
      handles, and reconnect latency against the normal single-pane path.
- [x] Add named workspaces, tab/split layout ownership, and session controls
      after the persistence gate passes.

## Test isolation

Use a separate experimental build, isolated config/cache paths, and a distinct
broker endpoint. Never terminate the user's daily Yuurei instance: it hosts
this development session. Crash tests target only processes created by their
own harness. Release installation and automatic updates stay untouched.

## Build and exercise

Enable **Settings → Windows & tabs → Persistent sessions (experimental)** and
select **Save changes**. The setting is off by default and applies to new tabs
and splits; existing shells are unchanged. Yuurei starts the background helper
automatically. **Ctrl+Shift+S** opens the session picker. Disabling the setting
does not terminate existing persistent sessions. Alternatively,
set `windows-persistent-sessions = true`. Normal Windows builds now include the
matching `yuurei-mux.exe`. Each new tab/split starts an independent named broker
using the usual prepared command, environment, shell integration, and working
directory. Broker creation uses `DETACHED_PROCESS` and explicit job breakaway;
if the parent job forbids breakaway, startup fails visibly instead of claiming
the session will survive its GUI.

Closing a persistent tab detaches it. The tab context menu offers **Attach
Session**, **Detach Tab**, and **End Session…** (confirmation
required). Attaching a session already visible in the current process focuses
that pane. Discovery validates process creation times and installation identity;
pipe authentication/version checks remain authoritative.

### Keyboard session navigation and names

**Ctrl+Shift+S** opens the session picker inside the terminal area, above the
session bar. It follows window resizing and uses the terminal colors and
monospace text; it is not a separate popup. Type to fuzzy-search names, IDs, or
PIDs; use **Up/Down**, **Ctrl+P/Ctrl+N**, or **Page Up/Page Down** to navigate.
**Enter** focuses an existing local pane or attaches a detached session.
**Delete** ends the selected session, including a detached session,
without attaching it first. The bottom session bar asks for confirmation:
press **Y** to end the named session, or **Esc** / **N** to cancel. Enter does
not confirm. Confirmation keys are consumed instead of being sent to a shell.
Persistent tabs show the current pane's session name, state, and shell PID in
this bar. It follows pane focus, stays visible in fullscreen, and uses the
terminal's colors. There is no background polling or extra rendering thread.
The command palette also provides **End Session…** for the current pane.
Bind `session:terminate` to a preferred shortcut, for example
`keybind = ctrl+b>x=session:terminate`. Ending a session stops its shell and
running programs and removes it from the session list; closing a pane only
detaches it.
**F2** renames the selected session; type a name and press **Enter** to save,
or **Escape** to cancel. **F5** refreshes discovery without clearing the search.
**Escape** closes the picker. No discovery polling runs while it is closed.

Session names support Unicode and spaces, up to 128 UTF-8 bytes. They are
independent of tab titles and stable session IDs. The broker retains the name
across detach and GUI crash/restart. Shell exit or explicit termination ends
the session and its name; this does not add persistence across machine restart.
Duplicate display names are allowed; the picker also shows the session ID/PID.

The regular **Ctrl+Shift+P** command palette includes **Switch Session**,
**Rename Session**, and **Detach Session**. Detach closes only the focused
persistent pane and leaves its shell running. All three actions are remappable,
including through an optional prefix-key workflow:

```ini
keybind = ctrl+b>s=session:list
keybind = ctrl+b>r=session:rename
keybind = ctrl+b>d=session:detach
```

These bindings mean press **Ctrl+B**, release, then press **S**, **R**, or **D**.
The prefix is an example, not an additional default. Direct shortcuts work too.
The helper supports `yuurei-mux.exe rename <session-id> "Backend"`; `list`
returns both stable IDs and display labels. Control-channel renaming works while
a native view is attached. `test/windows/mux-picker.ps1` verifies the complete
keyboard workflow, Unicode names, validation, original shell identity, and GUI
restart; the exit test verifies cleanup after shell termination.

`windows-workspace = dev` selects a named saved layout; `windows-restore-session`
controls saving/restoration. Version 2 preserves complete split trees, ratios,
focus, zoom, titles, directories, session IDs, and on-screen window geometry.
Changes are saved atomically after a short debounce, including before GUI
crashes rather than only on exit. An exclusive workspace lock prevents a second
process from overwriting a live workspace. The original flat format is imported
on first restoration. Layouts are bounded to 16 windows / 64 panes and 1 MiB.

Manual broker commands remain available:

```powershell
.\zig-out\bin\yuurei-mux.exe start dev pwsh.exe -NoLogo
.\zig-out\bin\yuurei-mux.exe list
.\zig-out\bin\yuurei-mux.exe status dev
.\zig-out\bin\yuurei-mux.exe stop dev
```

`start` detaches automatically; `serve` remains a foreground diagnostic command.
`list` returns live discovery records for the current installation/user/session.
Existing brokers from incompatible builds are shown, but not silently replaced.
Running shells are not preserved across broker termination, logoff, or reboot.

```powershell
zig build mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build test-mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2 -Dtest-filter=mux
pwsh -NoProfile -File test/windows/mux-smoke.ps1 -GuiExecutable "$PWD/zig-out/bin/ghostty.exe" -NativePane
pwsh -NoProfile -File test/windows/mux-lifecycle.ps1
pwsh -NoProfile -File test/windows/mux-workspace.ps1
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

Lifecycle coverage checks inherited command/Unicode arguments/environment/cwd,
automatic detached startup, discovery, GUI crash, and termination while attached.
Workspace coverage creates four shells across two tabs with nested splits,
kills/reopens the GUI, verifies identical live PIDs/layout/focus/zoom/input,
and checks exclusive ownership plus independent named workspaces.

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
Use `start` or the native persistent-session setting for detached startup.
Closing a console that directly hosts `serve`, killing
the broker, logout, and reboot are outside the persistence guarantee.

`stop` explicitly terminates the hosted session. `status`, `capture`, `snapshot`
(binary), `input`, and `resize` are diagnostic commands. There is one connected
view at a time, so detach it before issuing capture/input/resize diagnostics.
`status` and `stop` use a separate authenticated control endpoint and work while
a view remains attached. Control connections cannot subscribe, resize, or input.
Shell exit closes its attached pane and ends the broker. Detached sessions also
end when their shell exits. The broker allows up to one second for exit-event
delivery, then cleans up independently of whether a view is responsive.

`test/windows/mux-exit.ps1` checks attached/detached cleanup, split isolation,
nonzero and immediate exits, and a suspended view. `test/windows/mux-transport.ps1` uses
an isolated installation to exercise real pipe framing and timeout failures.
The four-second suspended-view benchmark verifies automatic history recovery
and subsequent input to the original shell.
`test/windows/mux-input.ps1` verifies a 512 KiB input burst byte-for-byte and
subsequent input; queue unit tests cover a single large append and atomic limit
rejection. `mux-lifecycle.ps1 -Cycles 10` repeats native crash/reattachment and
checks the original PID, live output, broker handles, threads, and memory.

## Current bounds and limitations

See [native performance measurements](MULTIPLEXER_BENCHMARK.md) for the
direct-versus-broker comparison, the original event-history overrun, and the
verified notification/backpressure and memory improvements. This remains an
experimental backend.

- The broker uses a blocking output reader and an event-driven input writer.
  Network writes occur outside the terminal lock. An unread response cannot
  retain that lock; subscribed views use the bounded backpressure described below.
- Wire requests and broker pending input are limited to 64 KiB each. Native
  views queue up to 16 MiB of input on demand, split it into bounded requests,
  and retry when the broker is backpressured. Drained paste storage is freed.
  Responses
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
  string; protocol version 5 includes exit events and input-backpressure replies. After the
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
  sessions continue draining and evicting old events. An expired native view
  automatically replaces its surface from a fresh snapshot of the same session,
  preserving its position in the split tree. Local selection and search state
  reset during recovery; live terminal pages are never replaced beneath pins.
- Native input, resize, and output wake the connection worker immediately.
  The view duplicates a wait-only handle to the authenticated broker's output
  event, catches up until the journal is empty, then waits without a polling
  timer. A broker process handle also wakes it on broker exit. Connection errors retain
  the view and leave the broker alive. **Reconnect Session** retries an existing
  session without silently launching a replacement shell. An event-driven process
  watch detects shell exit independently of ConPTY EOF, closes the attached
  pane, and releases the broker and its discovery record.
- The updater waits for both GUI and broker processes from the installation;
  closing the GUI alone no longer makes a live broker eligible for replacement.

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
