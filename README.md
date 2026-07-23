# yuurei 幽霊 — Ghostty for Windows

A native Windows port of [Ghostty](https://github.com/ghostty-org/ghostty),
built as a fork that adds a Win32 app runtime inside the real Ghostty tree.

## What this is

[Ghostty](https://github.com/ghostty-org/ghostty) is a fast, native terminal
emulator by Mitchell Hashimoto and the Ghostty contributors. Upstream ships
true native apps for macOS (SwiftUI/Metal) and Linux (GTK) on a shared,
platform-agnostic Zig core (`libghostty`) — but no Windows app.

yuurei is that Windows app. It is **not** a rewrite: the terminal emulation,
VT parsing, font shaping, renderer, config, and input encoding are the exact
same core as upstream Ghostty. This fork adds only the Windows platform layer
— a raw Win32 app runtime in [`src/apprt/win32/`](src/apprt/win32/) plus the
ConPTY plumbing — and tracks upstream `main` so core improvements land here by
construction.

Design notes, audits, and progress checklists live in
[`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md).

## Features

Everything below works today, verified live on Windows 11.

**Windows-native chrome**
- Custom Windows 11 frame with the real DWM caption buttons (native hover,
  the red close, Snap Layouts) and a **Mica Alt** title-bar backdrop.
- Antialiased rounded tabs that float Notepad-style, an active-tab accent
  underline in your system color, and a compact `windows-titlebar-thin` mode
  for a wezterm-style thin bar.
- Per-Monitor v2 DPI awareness; dark/light theme following the system.

**Tabs, splits, windows**
- Tab strip: new / switch / close, drag-reorder, tear-off to a new window,
  right-click rename, middle-click close. Multiple top-level windows.
- **Shell profiles** (Windows Terminal-style): auto-detected shells (cmd,
  PowerShell, pwsh, Nushell, Git Bash) and WSL distros, plus user
  config-overlay profiles, from a split new-tab button, the command palette,
  `ctrl+shift+1..9`, or the tab context menu.
- **Session restore** (`windows-restore-session`): reopen your tabs — profile,
  working directory, title — on the next launch.
- Splits: directional create, spatial focus, drag-resize, equalize, zoom.

**Terminal**
- **ConPTY** shell hosting; ships a vendored `conpty.dll` +
  `OpenConsole.exe` (newer, faster on output bursts) beside the exe.
- **OpenGL rendering** via WGL — the same GPU renderer and HarfBuzz/FreeType
  text stack as upstream.
- **Low-latency typing** — ~17 ms median keyboard-to-pixels, at parity with
  Windows Terminal + WSL and at the 60 Hz compositor floor. Getting there
  meant fixing a lost-wakeup bug in the IOCP event loop (a 25× win; see
  [`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md)). An opt-in DXGI flip-model +
  DirectComposition present path (`windows-flip-model = true`) is available.
- **Shell integration** for pwsh and Nushell (OSC 133 prompt marks, OSC 7
  cwd, titles) — pwsh integration exists for no platform upstream.

**Input & interaction**
- Full key encoding (kitty protocol, layout-aware keybinds, surrogate pairs),
  **AltGr** and **dead keys** on international layouts, and **IME** via imm32
  with inline preedit at the cursor cell.
- Clipboard both ways with unsafe-paste / OSC 52 confirmation; mouse
  reporting, drag selection, wheel scrolling, Ctrl+click links, and
  drag-and-drop that pastes quoted paths.

**More**
- Command palette (Ctrl+Shift+P), native settings window (Ctrl+,, edits your
  config in place and reloads live), terminal inspector, scrollbars, and find
  in terminal (Ctrl+Shift+F) with live match counts.
- Quick terminal with system-wide global hotkeys (`global:` keybinds).
- Native toast notifications, taskbar progress (OSC 9;4), background opacity
  and blur, mouse-hide-while-typing.

**In progress / not yet done:** default-terminal handoff (the registration and
COM proxy are in place; the handoff server is next), UIA accessibility,
per-pixel transparency, auto-update, packaging / code-signing / winget, and
ARM64. See [`WINDOWS_PORT_PLAN.md`](WINDOWS_PORT_PLAN.md) for the live list.

## What's shared, and what's new here

The fork is deliberately **additive**: new files for the Windows layer, small
surgical changes to shared files, so tracking upstream stays cheap.

**Shared, unchanged, with upstream Ghostty** — consumed as-is:
[`src/terminal/`](src/terminal/) (VT parsing/emulation),
[`src/termio/`](src/termio/) (I/O threading; upstream already carried the
ConPTY scaffolding, which the fork completed end-to-end),
[`src/font/`](src/font/) (shaping, rasterization, `freetype_windows`
discovery), [`src/renderer/`](src/renderer/) (OpenGL renderer),
[`src/config/`](src/config/) and [`src/input/`](src/input/) (config + key
encoder), and the split tree behind Windows splits.

**New in this fork:**
- [`src/apprt/win32/`](src/apprt/win32/) — **the entire Windows app runtime**,
  written against hand-written Win32/COM externs in
  [`winapi.zig`](src/apprt/win32/winapi.zig): the message loop and lifecycle
  (`App.zig`), custom frame + tab strip + splits + input (`Window.zig`), the
  GL host per tab (`Surface.zig`), profiles, session restore, the flip-model
  present path (`dxgi.zig`), and the GDI-painted UI surfaces (command palette,
  settings, inspector, scrollbar, search bar).
- [`vendor/libxev/`](vendor/libxev/) — **vendored libxev with the IOCP
  lost-wakeup fix** (`AsyncIOCP` heap-allocates its notify state), the fix
  behind the typing-latency win.
- [`vendor/conpty/`](vendor/conpty/) — vendored `conpty.dll` +
  `OpenConsole.exe` from [microsoft/terminal](https://github.com/microsoft/terminal)
  (MIT), installed beside the exe.
- [`vendor/defterm/`](vendor/defterm/) — the default-terminal handoff
  proxy/stub (Microsoft's `ITerminalHandoff` IDL + a prebuilt marshaling DLL).
- [`src/shell-integration/pwsh/`](src/shell-integration/pwsh/ghostty.ps1) —
  pwsh shell integration, plus an OSC 7 emitter for the Nushell integration.
- [`bench/`](bench/), [`dist/windows/`](dist/windows/), and the fork's CI /
  release workflows.

## Installing

Grab the latest zip from
[Releases](https://github.com/marlboro-red/yuurei/releases), extract it
anywhere, and run `bin\ghostty.exe`. It's portable — no installer, no registry
writes — with SHA256 checksums alongside each zip.

The binaries are unsigned (distribution is GitHub-only by design), so
SmartScreen warns on first run: choose **More info → Run anyway**.

The zip bundles `conpty.dll` and `OpenConsole.exe`
([microsoft/terminal](https://github.com/microsoft/terminal), MIT — see
`THIRD_PARTY_NOTICES.md`): a newer pseudoconsole, measurably faster on output
bursts. Delete them and yuurei falls back to the in-box ConPTY.

## Building

Requires [Zig](https://ziglang.org/) at the version pinned in
[`build.zig.zon`](build.zig.zon) (currently **0.15.2**). No Visual Studio
needed — Zig's toolchain links everything.

```powershell
# Build the Windows app (win32 is the default apprt on Windows).
# ReleaseFast matters: a Debug build is dramatically slower.
zig build -Doptimize=ReleaseFast

# Run it
zig-out\bin\ghostty.exe

# Test suite
zig build -Dapp-runtime=none test
```

CI builds and tests every push on `windows-latest`
([`windows-port.yml`](.github/workflows/windows-port.yml)). For everything
about the core — configuration, docs, terminal features — upstream's resources
apply unchanged: [ghostty.org/docs](https://ghostty.org/docs).

## Relationship to upstream

yuurei is its own project, maintained permanently as a fork — there is no plan
to merge the Windows port into upstream. The port lives on `main`; upstream is
tracked via the `upstream` remote and merged in so the shared core keeps
improving underneath us. All credit for the core belongs upstream; all
responsibility for the Windows layer lives here.

## AI assistance disclosure

This port is developed with substantial AI assistance (Claude), disclosed in
the spirit of upstream's [AI policy](AI_POLICY.md). Since yuurei does not
contribute code back to upstream, that policy's contribution requirements don't
apply — but any piece submitted upstream would first require full human review
and ownership per that policy.

## Credit and license

yuurei is a fork of [Ghostty](https://github.com/ghostty-org/ghostty), created
by Mitchell Hashimoto and the Ghostty contributors. All credit for the
terminal core, renderer, font stack, and architecture belongs to the upstream
project.

The yuurei icon is a color-inverted derivative of upstream's MIT-licensed icon
artwork (a fitting treatment for a yūrei); it will be replaced if upstream ever
publishes conflicting brand guidelines.

Licensed under the MIT license — see [`LICENSE`](LICENSE) (Copyright (c) 2024
Mitchell Hashimoto, Ghostty contributors).
