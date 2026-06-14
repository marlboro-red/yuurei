# yuurei 幽霊 — Ghostty for Windows

A native Windows port of [Ghostty](https://github.com/ghostty-org/ghostty),
built as a fork that adds a Win32 app runtime inside the real Ghostty tree.

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
same core as upstream Ghostty. This fork adds the Windows platform layer — a
raw Win32 app runtime in [`src/apprt/win32/`](src/apprt/win32/) plus the
ConPTY plumbing around upstream's existing Windows scaffolding — and tracks
upstream `main` so feature parity holds by construction.

The port's design decisions, audits, and progress checklists live in
[`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md).

## Status

Working today, verified live on Windows 11:

- **Native window** with a Windows 11-style custom frame (caption buttons,
  drag, snap/maximize) and a real **tab strip** — new/switch/close tabs,
  drag-reorder, right-click to rename, plus multiple top-level windows. New
  tabs/windows inherit the working directory (OSC 7), and tab titles reflect
  it.
- **Splits** — directional create, spatial focus navigation, divider
  drag-resize, equalize, zoom, and collapse-on-exit, on upstream's shared
  split tree.
- **ConPTY** shell hosting with headless integration tests; prefers a
  vendored `conpty.dll` next to the exe, falling back to the OS ConPTY.
- **OpenGL rendering** via WGL — the same GPU renderer and HarfBuzz/FreeType
  text stack as upstream (vttest-verified through WSL: SGR/truecolor, DEC
  line drawing, CJK wide chars, emoji).
- **Low-latency typing** — ~17 ms median keyboard-to-pixels, at parity with
  Windows Terminal + WSL and at the one-vblank 60 Hz compositor floor
  (measured by a software photon-proxy benchmark in [`bench/`](bench/)).
  Getting there meant fixing a lost-wakeup bug in the IOCP event loop where
  keystroke echoes waited on the cursor-blink timer instead of waking the
  renderer — a 25× win (see [`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md)).
  The default present path is the classic, always-vsync-throttled one that
  camera studies rank fastest for typing on Windows; an opt-in DXGI
  flip-model + DirectComposition path (`windows-flip-model = true`) is
  available for MPO eligibility and the transparency future.
- **Keyboard input** through Ghostty's real key encoder (surrogate pairs,
  layout-aware keybinds) and **IME via imm32** with inline preedit at the
  cursor cell (implemented to contract; CJK-user verification still pending).
- **Clipboard** both directions with unsafe-paste / OSC 52 confirmation
  dialogs; **mouse** reporting, drag selection, wheel scrolling.
- **Per-Monitor v2 DPI awareness** with `WM_DPICHANGED` handling.
- **Dark/light theme** following the system, including the frame.
- **Command palette** (Ctrl+Shift+P), **terminal inspector** (Dear ImGui in
  its own window), and a native **settings window** (Ctrl+,) that edits your
  config file in place — preserving comments — and reloads live.
- **Desktop notifications** as native toasts (OSC 9 / OSC 777, via the tray
  balloon path), **scrollbars** fed by the core's scrollback, **find in
  terminal** (Ctrl+Shift+F) with live match counts, **Ctrl+click links**
  (http/https/mailto allowlist), and **file drag-and-drop** that pastes
  quoted paths.
- **Background opacity** and **`background-blur`** (DWM acrylic; whole-window
  today).
- **Quick terminal** with system-wide global hotkeys (`global:` keybinds via
  `RegisterHotKey`).
- **PowerShell-first** default shell (pwsh → powershell → cmd) and **pwsh
  shell integration** (OSC 133 prompt marks, OSC 7 cwd, titles) — which does
  not exist upstream for any platform.
- Stability: 45+ minute scroll soaks at stable memory; vsync and
  hidden-window present fixes after a real GPU-driver incident.

Honest remaining work: packaging/code-signing/winget, crisp per-pixel
transparency/blur (opacity and blur are whole-window/frosted today),
auto-update, Mica, and ARM64. See the Phase 3/4 checklists in
[`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md) for the live list.

## What's shared with Ghostty, and what's new here

The fork is deliberately **additive**: it adds new files for the Windows
layer and keeps changes to shared files small, so tracking upstream stays
cheap.

### Shared, unchanged, with upstream Ghostty

These are the same platform-agnostic Zig core as upstream — yuurei consumes
them as-is and inherits their improvements when upstream is merged in:

- [`src/terminal/`](src/terminal/) — VT parsing and terminal emulation.
- [`src/termio/`](src/termio/) — I/O threading. Upstream already carried the
  Windows ConPTY scaffolding here (`WindowsPty`, `Command.startWindows`,
  `Exec.threadMainWindows`); the fork completed and verified it end-to-end.
- [`src/font/`](src/font/) — HarfBuzz shaping, FreeType rasterization, and
  the `freetype_windows` font-discovery backend (all upstream).
- [`src/renderer/`](src/renderer/) — the OpenGL renderer and glyph atlas.
- [`src/config/`](src/config/) and [`src/input/`](src/input/) — config
  parsing and the key encoder (kitty protocol, `modifyOtherKeys`, keybinds).
- `src/datastruct/split_tree.zig` — the split tree that backs Windows splits.

### New in this fork (code)

- [`src/apprt/win32/`](src/apprt/win32/) — **the entire Windows app
  runtime**, written against hand-written Win32/COM externs in
  [`winapi.zig`](src/apprt/win32/winapi.zig):
  - `App.zig` — message loop, app lifecycle, global hotkeys, notifications.
  - `Window.zig` — custom frame, tab strip, splits, input routing.
  - `Surface.zig` — one tab/pane: GL host child window + WGL context + core
    surface.
  - `dxgi.zig` — hand-written D3D11/DXGI/DirectComposition bindings for the
    opt-in flip-model present path.
  - `CommandPalette.zig`, `SettingsWindow.zig`, `InspectorWindow.zig`,
    `Scrollbar.zig`, `SearchBar.zig` — the native GDI-painted UI surfaces.
- [`vendor/libxev/`](vendor/libxev/) — **vendored libxev with the IOCP
  lost-wakeup fix**: `AsyncIOCP` now heap-allocates its notify state behind a
  pointer so by-value copies share one allocation (the fd/mach-port backends
  already had this; only IOCP used copy-fragile inline state). This is the
  fix behind the typing-latency win.
- [`src/shell-integration/pwsh/ghostty.ps1`](src/shell-integration/pwsh/ghostty.ps1)
  — **pwsh shell integration that exists for no platform upstream** (OSC 133
  prompt marks, OSC 7 cwd, OSC 0 titles), plus an OSC 7 emitter added to the
  nushell integration.
- [`vendor/conpty/`](vendor/conpty/) — vendored `conpty.dll` +
  `OpenConsole.exe` from microsoft/terminal (MIT), shipped beside the exe.
- [`bench/`](bench/) — the software photon-proxy latency benchmark.
- [`dist/windows/`](dist/windows/) — icon, app manifest (PMv2 DPI), and the
  versioned resource script.
- `.github/workflows/windows-port.yml` and `release.yml` — fork CI and the
  release pipeline (upstream's Windows jobs are repo-gated and never run on
  forks).

The shared-file changes are small and surgical: registering `.win32` in
[`src/apprt/runtime.zig`](src/apprt/runtime.zig), `.win32` arms in the
OpenGL renderer, OSC 7 parsing on Windows, and a read-thread EOF fix in
`termio/Exec.zig` (a `BROKEN_PIPE` on child exit had been routed to
`unreachable`).

## Installing

Grab the latest zip from
[Releases](https://github.com/marlboro-red/yuurei/releases), extract it
anywhere, and run `bin\ghostty.exe`. The zip is portable — no installer, no
registry writes. SHA256 checksums are published alongside each zip.

The binaries are unsigned (distribution is GitHub-only by design), so
SmartScreen will warn on first run: choose "More info" → "Run anyway".

The zip bundles `conpty.dll` and `OpenConsole.exe` from the
[microsoft/terminal](https://github.com/microsoft/terminal) project (MIT, see
`THIRD_PARTY_NOTICES.md`) — a newer pseudoconsole than the one shipped in
Windows, measurably faster on output bursts. Delete them and yuurei falls
back to the in-box ConPTY.

## Building

Requirements: [Zig](https://ziglang.org/) — the version is pinned in
[`build.zig.zon`](build.zig.zon) (currently **0.15.2**). No Visual Studio
needed; Zig's bundled toolchain links everything.

```powershell
# Build the Windows app (win32 apprt is the default on Windows).
# ReleaseFast matters: a Debug build is ~14x slower end to end.
zig build -Doptimize=ReleaseFast

# Run it
zig-out\bin\ghostty.exe

# Run the test suite
zig build -Dapp-runtime=none test
```

CI builds and tests every push on `windows-latest` via
[`.github/workflows/windows-port.yml`](.github/workflows/windows-port.yml).

For everything about the core — configuration, docs, terminal feature
support — upstream's resources apply unchanged:
[ghostty.org/docs](https://ghostty.org/docs) and the
[upstream README](https://github.com/ghostty-org/ghostty#readme).

## Relationship to upstream

yuurei is its own project, maintained permanently as a fork — there is no
plan to merge the Windows port into upstream Ghostty. The port lives on
`main`; upstream Ghostty is tracked via the `upstream` remote and merged in
by release tag so the shared core keeps improving underneath us. All credit
for the core belongs upstream; all responsibility for the Windows layer lives
here.

## AI assistance disclosure

This port is developed with substantial AI assistance (Claude), disclosed
here in the spirit of upstream's [AI policy](AI_POLICY.md). Since yuurei does
not contribute code back to upstream, that policy's contribution requirements
don't apply — but if any piece of this fork were ever submitted upstream, it
would first require full human review and ownership per that policy.

## Credit and license

yuurei is a fork of [Ghostty](https://github.com/ghostty-org/ghostty),
created by Mitchell Hashimoto and the Ghostty contributors. All credit for
the terminal core, renderer, font stack, and overall architecture belongs to
the upstream project.

The yuurei icon is a color-inverted derivative of upstream Ghostty's
MIT-licensed icon artwork (a fitting treatment for a yūrei). If the upstream
project ever publishes trademark or brand guidelines that conflict with this
use, the icon will be replaced.

Like upstream, this repository is licensed under the MIT license — see
[`LICENSE`](LICENSE) (Copyright (c) 2024 Mitchell Hashimoto, Ghostty
contributors).
</content>
</invoke>
