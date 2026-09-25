# Multiplexer development research

Research date: 2026-09-26. Scope: Zellij/tmux-like functionality built on the
Yuurei Windows port. This is a development proposal, not an implemented feature.

## Recommendation

Deliver named workspaces, complete layout restoration, and modal pane controls
first. For live sessions that survive GUI closure or crashes, introduce a
per-user background broker that owns ConPTY and terminal state independently of
the GUI. Build a one-pane reconnect prototype before committing to the full
broker migration.

Keep three promises distinct in the UI and documentation:

- **Workspace restoration:** recreate layouts and start new shells or explicitly
  configured commands.
- **Live detach/reattach:** retain the same running processes when a GUI leaves
  and returns.
- **Crash/reboot recovery:** reconstruct saved state after the broker or machine
  stops; this does not preserve the original processes.

## Current foundations

| Foundation | Code | Development implication |
| --- | --- | --- |
| Tabs containing split trees | [Window.zig](../src/apprt/win32/Window.zig), `Tree` and `Tab` | Reuse existing pane layout, tab ordering, and focus concepts. |
| Split creation, focus, equalization, zoom, and resize | [Window.zig](../src/apprt/win32/Window.zig), `newSplit`, `gotoSplit`, `equalizeSplits`, `toggleSplitZoom`, `resizeSplit` | Much of the visible tiled-pane functionality exists already. |
| Live tab movement across windows | [Window.zig](../src/apprt/win32/Window.zig), `tearOffTab` | Existing code reparents surface HWNDs without restarting shells. |
| Profile-aware spawning | [profiles.zig](../src/apprt/win32/profiles.zig), [Surface.zig](../src/apprt/win32/Surface.zig) | Layout panes can reference existing profile identities and cwd overrides. |
| Leader sequences and named key tables | [Binding.zig](../src/input/Binding.zig), [core Surface.zig](../src/Surface.zig), `activate_key_table` and related actions | Reuse the input engine for prefix keys and navigation/resize modes. |
| Key-mode notifications | [action.zig](../src/apprt/action.zig), `key_table` and `key_sequence` | Win32 lacks explicit handlers for these notifications; a mode indicator is a useful small extension. |
| Session restart metadata | [session.zig](../src/apprt/win32/session.zig), `save` and `restore` | Current format records the focused pane per tab, profile, manual title, and cwd. It does not serialize split trees or keep processes alive. |
| Backend abstraction | [backend.zig](../src/termio/backend.zig) | Currently supports only `exec`; a broker client backend is a plausible extension seam. |
| Binary terminal snapshots | [snapshot/main.zig](../src/terminal/snapshot/main.zig) | Incremental decoding exposes active state at `READY`, before history finishes, and supports unfinished VT stream continuation. |
| IPC placeholder | [App.zig](../src/apprt/win32/App.zig), `performIpc` | Currently returns false; Win32 needs a general command/control endpoint. |

The current ownership chain is approximately:

```text
Window -> Tab/SplitTree -> Win32 Surface -> Core Surface -> Exec -> ConPTY/process
```

[Win32 Surface](../src/apprt/win32/Surface.zig) owns both the HWND/GL resources and
the core surface. Its final reference release destroys that state.
[Pty.deinit](../src/pty.zig) closes the pseudoconsole. Merely keeping the app's
event loop running after its windows close does not preserve their terminals.

The headless refactor also reaches [Termio.zig](../src/termio/Termio.zig), which
directly references renderer state, wakeups, renderer mailboxes, and a surface
mailbox. A broker cannot simply instantiate the current GUI-bound core surface
unchanged.

## Architecture options

| Option | Benefits | Limits |
| --- | --- | --- |
| Keep hidden workspace windows in the GUI process | Shortest route to hiding and reopening live workspaces | GUI crash/restart still loses sessions; retains renderer/HWND resources unless further refactored. An interim feature only. |
| Native background broker | Preserves native PowerShell, cmd, and WSL-launching panes across GUI closure/crash; enables CLI control | Requires protocol design, state synchronization, backend integration, and ownership changes. Recommended durable architecture. |
| tmux control-mode adapter over WSL/SSH | Reuses an established server while showing its panes in native UI | Covers Linux/remote processes, not native Windows shell persistence. Useful as a later connection type. |
| Run tmux/Zellij inside a normal pane | Minimal implementation for existing WSL users | Nested UI, shortcuts, and scrollback behavior; does not provide native workspace integration. |

[tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode) was designed
for terminals to present tmux panes using their own UI. It supplies commands and
asynchronous notifications over a text protocol that can run through SSH.

## Proposed session and broker model

Run `yuurei --session-server` or a sibling executable as a normal process in the
user's logon session. It owns session state and execution. GUI clients own HWNDs,
WGL/DXGI, input presentation, selection, scrolling, clipboard, dialogs, and
rendering.

```text
CLI / GUI clients
        |
        | local authenticated named-pipe protocol
        v
Per-user broker
  sessions -> tabs/layout trees -> panes
                                 terminal state
                                 ConPTY + process tracking
```

Introduce stable `SessionId`, `TabId`, and `PaneId` values in a GUI-independent
model. Separate `PaneSession` from `PaneView`; references from layouts and views
must not accidentally define process lifetime. Closing a view, detaching a
session, terminating a pane, and terminating the broker must be distinct actions.

Start with one controlling client per session. Read-only mirrors can follow.
This postpones conflicting keyboard input and competing grid-size requests.
When detached, retain the last valid grid size and continue draining and parsing
output. On attach, the controlling client supplies new dimensions.

The control protocol should include version negotiation, framed messages,
request IDs, stable object IDs, bounded payloads, and sequenced events. Initial
operations should cover `list`, `create`, `attach`, `detach`, `rename`, `split`,
`resize`, `send-input`, `capture`, and `kill`. Reuse this endpoint for CLI
automation and GUI discovery rather than implementing separate command paths.

Extract execution and terminal state handling behind an event sink, or build a
broker-specific host around the terminal parser and the Windows process/PTY
helpers. Keep changes to shared Ghostty code narrow and explicit; the current
renderer and surface dependencies make this more than a Win32 window-lifetime
change.

### Reconnect and terminal fidelity

Use the existing [snapshot codecs](../src/terminal/snapshot/main.zig) as a
building block, with a separate transport envelope and event sequence:

1. Capture terminal state at sequence N while preserving a consistent boundary.
2. Send active state and VT continuation through `READY`.
3. Restore the view and apply ordered events after N.
4. Transfer remaining history through explicitly multiplexed protocol messages.

The snapshot package explicitly says it is not a complete transport protocol.
Its version 1 is still subject to change, so negotiate compatibility between
broker and GUI builds. [terminal.zig](../src/terminal/snapshot/terminal.zig)
documents unsupported Kitty image state and glyph glossary registrations. Audit
and test fidelity limits before promising transparent reconnection for all
applications.

Keep terminal query responses authoritative in the broker. A GUI parsing mirrored
VT must not generate duplicate responses. Snapshot/replay must not repeat
historical clipboard writes, notifications, or other external side effects.
Bound per-client queues; a slow or disconnected GUI must not stall ConPTY output
or other panes. Prefer a fresh snapshot over retaining unbounded replay history.

## Windows-specific constraints

- ConPTY closure sends close events to attached clients. Detaching must release
  only the view/subscription, leaving the broker's handles intact. Older Windows
  versions also require careful output draining during close; Microsoft documents
  changed close behavior starting with Windows 11 24H2.
  [ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)
- Preserve independent input/output servicing and bounded queues. Microsoft
  recommends independently serviced communication channels to avoid deadlocks.
  A detached GUI cannot be the component responsible for draining ConPTY.
  [Creating a pseudoconsole session](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session)
- Restrict the control pipe to the intended user/logon session and reject remote
  clients. Keep elevated and unelevated brokers separate. Input injection and
  command execution make the endpoint privileged within that user session.
  Microsoft documents using the logon SID in the pipe DACL for session isolation.
  [Named-pipe access control](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- Move ownership of process/job tracking into the broker. Audit inherited handles
  and job membership so terminating a GUI cannot terminate server-owned children.
- Treat default-terminal handoff as a separate compatibility milestone.
  [defterm.zig](../src/apprt/win32/defterm.zig) handles adopted pipes/HPCON, while
  [App.zig](../src/apprt/win32/App.zig) records limitations encountered with packed
  handles. Do not use the private vendored ConPTY packing interface as the general
  persistence mechanism; normally the broker should create and retain ConPTY.
- Broker survival covers GUI restart/crash. Broker crash, logout, reboot, and WSL
  shutdown need separately defined recovery semantics. Layout resurrection starts
  new processes. Zellij makes a similar distinction and gates rerunning
  resurrected commands behind user action.
  [Zellij session resurrection](https://zellij.dev/documentation/session-resurrection.html)

## Staged delivery

These are rough planning ranges for one developer familiar with the code,
including meaningful validation. They are not measured commitments. The broker
prototype should revise the later estimates.

| Stage | Deliverable | Rough planning range |
| --- | --- | --- |
| 1. Workspaces and layouts | Stable identities, named workspace switcher, complete split-tree persistence with ratios/focus/profile/cwd, declarative reusable layouts, migration from session format v1 | 1–2 weeks |
| 2. Multiplexer keyboard UX | Optional tmux-style prefix bindings and Zellij-style pane/tab/resize modes; mode indicator, escape behavior, shortcut hints, move/swap pane actions | 3–7 days |
| 3. Broker proof of concept | One PowerShell pane surviving disconnect and GUI termination, with the same PID and accurate screen on reconnect | 1–2 weeks |
| 4. Usable persistent sessions | Multiple panes/tabs, broker backend, discovery, CLI, synchronization, scrollback restore, config behavior, upgrade compatibility, failure recovery | 4–8 additional weeks |
| 5. Advanced functionality | tmux adapter, SSH transport, multiple viewers, floating panes, richer layout rules, plugin API | Separate estimates after earlier stages |

For stages 1–2, avoid automatically discovering and rerunning arbitrary commands
from a previous interactive shell. Persist explicitly configured launch commands
and make restart behavior clear. Current key tables are surface-local, so define
whether modes reset or persist when focus moves across panes and workspaces.

Stage 3 is the architecture gate: demonstrate snapshot fidelity, detached output
handling, and process lifetime before expanding session UI or committing to
multiple clients. An output-only relay is not sufficient evidence of faithful
reconnects.

## Acceptance criteria

- Layout round trips preserve all panes, split ratios, tab ordering, focus,
  profile identity, titles, and cwd; older session files migrate predictably.
- Prefix and modal controls work across pane focus changes, with a visible mode
  and reliable escape path; normal terminal input remains predictable.
- Detach a shell running a counter/build, reconnect, and verify the same PID and
  continued output.
- Kill only the GUI during heavy output; reconnect without freezing the shell
  or losing authoritative terminal state.
- Reconnect to an alternate-screen application, different grid size, long
  scrollback, and incomplete UTF-8/VT sequence with a faithful result or a
  documented unsupported case.
- Attach replay does not duplicate clipboard writes, notifications, or terminal
  query responses.
- Slow clients cannot stall other panes; queue and snapshot limits are enforced.
- Another user/logon session cannot list sessions or send commands through IPC.
- Broker/GUI protocol version mismatch produces a recoverable result without
  killing the existing session.
- Validate PowerShell, cmd, WSL, and native console applications. Validate
  default-terminal handoff separately before including it in the persistence
  guarantee.

## Open product choices

1. Must the first release survive GUI crashes, or is hiding/reopening a workspace
   within one GUI process useful on its own?
2. Are workspaces global across windows? Can one workspace appear in multiple
   windows, and who owns its authoritative layout?
3. Does closing the last window detach by default? How should explicit Quit,
   Terminate Session, and broker shutdown differ?
4. Must native Windows and WSL panes share one session model in the first release?
5. Is one controlling GUI sufficient initially? Are read-only mirrors required?
6. Are CLI automation, capture, and send-input first-release requirements?
7. Which state should survive broker restart: layout only, viewport, scrollback,
   configured commands? What storage limits and command-restart behavior apply?
8. Should pane/tab modes persist across focus changes, or reset to normal input?
9. Is tmux interoperability a priority, or should native Windows persistence take
   precedence over remote connection types?

## Primary references

- [Microsoft: Pseudoconsoles](https://learn.microsoft.com/en-us/windows/console/pseudoconsoles)
- [Microsoft: Creating a pseudoconsole session](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session)
- [Microsoft: ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)
- [Microsoft: Named-pipe security and access rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [tmux: Control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Zellij: Session resurrection](https://zellij.dev/documentation/session-resurrection.html)
- [WezTerm: Multiplexing](https://wezterm.org/multiplexing.html)
