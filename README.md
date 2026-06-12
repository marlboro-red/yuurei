# yuurei — Ghostty for Windows

A native Windows port of [Ghostty](https://github.com/ghostty-org/ghostty),
built as a fork that adds a Win32 apprt inside the real Ghostty tree.

<!-- Screenshot is added separately; do not commit binary assets in this commit. -->
![screenshot](docs/screenshot.png)

## What this is

[Ghostty](https://github.com/ghostty-org/ghostty) is a fast, feature-rich,
native terminal emulator by Mitchell Hashimoto and the Ghostty contributors.
Upstream ships true native apps for macOS (SwiftUI/Metal) and Linux (GTK) on
top of a shared, platform-agnostic Zig core (`libghostty`) — but no Windows
app.

yuurei is that Windows app. It is **not** a rewrite: the terminal emulation,
VT parsing, font shaping, renderer, config, and input encoding are the exact
same core as upstream Ghostty. This fork adds the Windows platform layer —
a raw Win32 app runtime in [`src/apprt/win32/`](src/apprt/win32/) plus the
ConPTY plumbing around upstream's existing Windows scaffolding — and tracks
upstream `main` so feature parity holds by construction.

The port's design decisions, audits, and progress checklists live in
[`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md).

## Status

Working today, verified live on Windows 11:

- **Native window** with a Windows 11-style custom frame (caption buttons,
  drag, snap/maximize) and a real **tab strip** — new/switch/close tabs,
  plus multiple top-level windows
- **ConPTY** shell hosting with headless integration tests; prefers a
  vendored `conpty.dll` next to the exe, falling back to the OS ConPTY
- **OpenGL rendering** via WGL — the same GPU renderer and HarfBuzz/FreeType
  text stack as upstream (vttest-verified through WSL, SGR/truecolor,
  DEC line drawing, CJK wide chars, emoji)
- **Keyboard input** through Ghostty's real key encoder (surrogate pairs,
  layout-aware keybinds) and **IME via imm32** with inline preedit at the
  cursor cell — implemented to contract, *CJK-user verification still pending*
- **Clipboard** both directions with unsafe-paste / OSC 52 confirmation
  dialogs; **mouse** reporting, drag selection, wheel scrolling
- **Per-Monitor v2 DPI awareness** with `WM_DPICHANGED` handling
- **Dark/light theme** following the system, including the frame
- **Splits** — directional create, spatial focus navigation, resize,
  equalize, zoom, and collapse-on-exit, using upstream's shared split tree
- **Quick terminal** with system-wide global hotkeys (`global:` keybinds via
  `RegisterHotKey`)
- **PowerShell-first** default shell (pwsh → powershell → cmd) and **pwsh
  shell integration** (OSC 133 prompt marks, OSC 7 cwd, titles) — a feature
  that doesn't exist upstream for any platform
- Stability: 45+ minute scroll soaks at stable memory; vsync and
  hidden-window present fixes after a real GPU-driver incident

Honest remaining work: packaging/code signing/winget, WinRT toast
notifications (interim flash+beep today), command palette, inspector
wiring, background opacity/blur, settings GUI, auto-update,
Mica/snap-layouts polish, split divider drag, ARM64. See the Phase 3/4
checklists in [`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md) for the
live list.

## Building

Requirements: [Zig](https://ziglang.org/) — the version is pinned in
[`build.zig.zon`](build.zig.zon) (currently **0.15.2**). No Visual Studio
needed; Zig's bundled toolchain links everything.

```powershell
# Build the Windows app (win32 apprt is the default on Windows)
zig build

# Run it
zig-out\bin\ghostty.exe

# Run the test suite
zig build -Dapp-runtime=none test
```

CI builds and tests every push on `windows-latest` via
[`.github/workflows/windows-port.yml`](.github/workflows/windows-port.yml)
(upstream's Windows jobs are repo-gated and never run on forks).

For everything about the core — configuration, docs, terminal feature
support — upstream's resources apply unchanged:
[ghostty.org/docs](https://ghostty.org/docs) and the
[upstream README](https://github.com/ghostty-org/ghostty#readme).

## Relationship to upstream

yuurei is its own project, maintained permanently as a fork — there is no
plan to merge the Windows port into upstream Ghostty. The port lives on
`main`; upstream Ghostty is tracked via the `upstream` remote and merged
in by release tag so the shared core keeps improving underneath us. All
credit for the core belongs upstream; all responsibility for the Windows
layer lives here.

## AI assistance disclosure

This port is developed with substantial AI assistance (Claude), disclosed
here in the spirit of upstream's [AI policy](AI_POLICY.md). Since yuurei
does not contribute code back to upstream, that policy's contribution
requirements don't apply — but if any piece of this fork were ever
submitted upstream, it would first require full human review and
ownership per that policy.

## Credit and license

yuurei is a fork of [Ghostty](https://github.com/ghostty-org/ghostty),
created by Mitchell Hashimoto and the Ghostty contributors. All credit for
the terminal core, renderer, font stack, and overall architecture belongs to
the upstream project.

Like upstream, this repository is licensed under the MIT license — see
[`LICENSE`](LICENSE) (Copyright (c) 2024 Mitchell Hashimoto, Ghostty
contributors).
