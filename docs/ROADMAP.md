# Roadmap

What's left, as of 2026-07-27. The port itself is done and daily-driven —
see [`WINDOWS_PORT_PLAN.md`](../WINDOWS_PORT_PLAN.md) for the historical
plan and engineering log. The fork's standing rule applies to everything
below: **ordered by observed user pain, not spec order**, and the list
shrinks by evidence, not by ambition.

## Next up: default-terminal handoff (ship the gate flip)

The feature is functionally complete behind `defterm.handoff_ready =
false`: registration/unregistration, the COM LocalServer, ConPTY adoption
via `ConptyPackPseudoConsole`, resize reflow, and exit detection have all
been verified live. It stays gated because becoming the default terminal
intercepts *every* console launch system-wide — high blast radius.
Remaining before the flip:

- [ ] Soak test beyond cmd.exe: pwsh, WSL, Nushell, Git Bash, a
      debugger-launched console — render, resize, exit for each.
- [ ] Reboot persistence: registration survives, COM cold-start
      (`-Embedding` LocalServer launch) hands off correctly.
- [ ] Concurrent handoffs: several console apps launched rapidly, each
      gets its own surface, no 0xc0000142 under load.
- [ ] Exit-code propagation (reader-EOF currently reports 0) and the
      `show_child_exited` action (wait-after-command configs).
- [ ] Re-smoke against the vendored ConPTY 1.25 pair, then flip the
      gate and cut a release.

## Accessibility

- [ ] **UIA provider** — the largest untouched gap. Screen readers see
      nothing today. Needs `ITextProvider`/`IRawElementProviderSimple`
      over the terminal grid.
- [ ] IME is implemented to the imm32 contract but still needs
      verification by a real CJK user.

## Settings window redesign

- [x] Rebuild the settings window to be easy to use, visually polished,
      and modern, with a coherent Windows-native design rather than a
      small collection of controls.
- [x] Add clear category navigation, search, readable descriptions, and
      visible distinctions between base settings and profile overrides.
- [x] Design consistent typography, spacing, colors, and controls for
      light/dark themes and different display scales.
- [x] Provide keyboard navigation, accessible control names and focus
      states, useful validation, and clear save/reset feedback.
- [x] Validate font/theme and shell changes, search, reset, staged saves,
      external edit conflicts, and light/dark layouts with the native GUI smoke test
      (`test/windows/settings-smoke.ps1`).
- [ ] Add direct profile editing and full terminal/theme previews. The
      current settings window edits the base config and shows a font/cursor
      sample; profiles remain configurable through their files.
- [ ] Check with Narrator and mixed-DPI monitors on physical hardware.

## Session restore v2

- [ ] Record splits and window geometry (a tab currently restores as its
      focused pane; windows restore at default size/position).

Multiplexer work is on `feature/multiplexer`. An opt-in single-pane broker and
console client exercise live detach/reattach before native workspace integration.
See [`MULTIPLEXER_IMPLEMENTATION.md`](MULTIPLEXER_IMPLEMENTATION.md) for build
instructions, validation, and remaining gates, and
[`MULTIPLEXER_RESEARCH.md`](MULTIPLEXER_RESEARCH.md) for the original research.
This experimental tool is not part of the normal application or release build.

## Rendering / presentation

- [ ] Per-pixel transparency: premultiplied alpha on the DComp visual —
      real text-over-blur without the layered-window latency penalty.
      Requires `windows-flip-model`.
- [ ] GL fallback story: we require GL 4.3; RDP and driverless VMs
      (WARP-only) get nothing. Options: core-context creation via
      `wglCreateContextAttribsARB` + graceful degradation, or the
      long-parked D3D11 backend if field reports ever demand it.
- [ ] `ALLOW_TEARING` min-latency mode on the flip path (candidate
      behind `window-vsync = false`).

## Performance

- [ ] Session restore runs a full config load+finalize per restored tab
      (`spawnConfig`); reuse one loaded overlay per batch.
- [ ] Profiles: async scan/prewarm (the WSL probe is lazy but still
      blocks the first menu open) and argv storage cleanup.
- [ ] Flip path hardening: flip-wait timeout + `Present` failure
      handling; per-adapter D3D device sharing.
- [ ] Startup is 183 ms cold / 31 ms per tab after the 2026-07-27
      prewarm work (`GHOSTTY_PERF_TRACE=1` has phase marks); nothing
      further here until something regresses.

## Feature backlog (from the Windows Terminal comparison audit)

None of these are promised; they graduate off this list when someone
actually hits the gap:

- Touch / `WM_POINTER` scrolling and selection
- Broadcast input (type into all splits)
- HTML/RTF clipboard formats
- Hover URL preview; `file://` links stay blocked by design (untrusted
  terminal output executing a path is a footgun, not a feature)
- Undo close tab; `set_tab_title` action; tab merge-in drag (tear-off
  exists, re-dock doesn't)
- Jump lists; WinRT toasts (both want package identity we don't have by
  design — GitHub-only, unpackaged)
- Search: case-sensitivity and regex toggles
- `window-theme = ghostty` (match terminal background) — currently falls
  back to the OS theme
- Remaining unimplemented apprt actions (log as `unimplemented action=`
  warnings — grep the log in normal use to find ones that matter)

## Platform

- [ ] ARM64 (after x64 stops changing; Zig cross-compiles, CI needs an
      ARM runner or cross-built release artifacts)
- Auto-update: implemented for portable releases, with daily checks, verified
  downloads, installation after exit, and rollback. See [UPDATES.md](UPDATES.md).
- Packaging/signing/winget: **non-goals by choice**, revisit only if
  the SmartScreen wall measurably costs adoption.

## Meta

- [ ] A screenshot in the README — the one Phase 2 exit criterion never
      closed, which is funny given everything since.
