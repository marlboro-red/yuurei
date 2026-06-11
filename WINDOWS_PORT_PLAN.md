# Ghostty Windows Port — High-Level Plan

**Repo:** `marlboro-red/yuurei` (fork of `ghostty-org/ghostty`)
**Working branch:** `windows-port` (`main` stays clean, tracking upstream)
**Date:** 2026-06-11
**Status:** Plan v2.0 — supersedes the standalone `yurei` attempt

---

## 1. Goal and Strategy

Port Ghostty to native Windows by **adding a Windows platform layer inside the
real Ghostty tree** — not by building a separate application around extracted
pieces of it.

This is a deliberate course-correction from the previous attempt (the
standalone `yurei` repo, audited in its `REVIEW.md`). That attempt re-implemented
the renderer, font system, config, input, and app runtime from scratch and
consumed only `ghostty-vt` as a library. The result demonstrated the platform
techniques (ConPTY, custom frame, GDI) but made feature parity structurally
unreachable: every Ghostty feature outside the VT engine became something to
re-implement. Working upstream-in-tree inverts that — the core (`src/terminal/`,
`src/termio/`, `src/font/`, `src/config/`, `src/input/`, the renderer
abstraction) is platform-agnostic Zig we get for free, and parity holds *by
construction* because it is the same core.

**Definition of done (v1):** a signed, winget-installable Ghostty that runs
pwsh/cmd/WSL shells through ConPTY, renders with the existing cross-platform
GPU stack, supports tabs, correct international keyboard input and IME,
clipboard/paste, DPI awareness, and Windows 11-style chrome — built from this
fork with every commit verified by Windows CI.

What "done" explicitly is **not** (v1 non-goals): D3D11 renderer, DirectWrite
rasterization, splits parity, quick-terminal/tray, jump lists, default-terminal
registration, ARM64. These are post-v1 (§6, Phase 4+) or cut until evidence
demands them.

---

## 2. Ground Rules (lessons paid for already)

These are process rules, but they are the highest-leverage part of the plan.
Each one corresponds to a specific, documented failure of the previous attempt.

1. **Nothing exists until it runs on Windows.** Windows CI (`windows-latest`)
   building and testing every push is the *first* deliverable, before any port
   code. A Windows VM or machine is set up in week one. The previous attempt
   wrote 16k lines that were never once compiled for Windows.
2. **No stub returns fake success.** Unimplemented paths are
   `@panic("TODO: windows")` or compile errors behind `comptime` gates — never
   empty slices, hardcoded values, or flag-flips with green unit tests.
   Misrepresented state cost more than missing features last time.
3. **Vertical slices, always shippable.** Every phase ends with an artifact a
   human can type into. No subsystem gets an API surface before something
   consumes it.
4. **No optimization, no benchmarks, until the slice works.** Correctness
   first; measure on real Windows hardware afterward.
5. **Track upstream weekly.** Rebase `windows-port` onto upstream `main` on a
   schedule. Divergence is debt; small frequent payments.

---

## 3. Stack Decisions

Guiding rule: **native where users can perceive it, boring and already-working
where they can't.**

| Layer | Decision | Rejected alternatives |
|---|---|---|
| UI / windowing | Raw Win32 (`CreateWindowExW` + message loop + DWM), written in Zig as `src/apprt/win32.zig` (modeled on the `gtk` apprt, not the `embedded` C-API path) | WinUI 3 / XAML (runtime weight, Zig↔WinRT friction, App SDK churn); Qt/GTK (non-native); second-language app over libghostty (binding friction, unstable C API) |
| Win32/COM bindings | **Generated bindings via [zigwin32](https://github.com/marlersoft/zigwin32)** (from Microsoft's win32metadata), vendored/trimmed if dependency policy requires | Hand-written bindings (the prior attempt hand-wrote ~1k lines: mostly right, still had wrong DLL attributions, wrong calling-convention constant, and zero COM machinery — COM vtables/IIDs are not hand-writable at sustainable quality) |
| PTY | ConPTY, **vendoring `conpty.dll` + `OpenConsole.exe` from the Windows Terminal repo (MIT)** so ConPTY behavior ships on our release schedule, not the user's Windows build | OS-installed conhost (support matrix hostage to Windows version); winpty (legacy) |
| GPU rendering | **Existing OpenGL backend to ship**; D3D11 as a post-v1 backend, triggered only by field evidence (GL driver crashes on Intel iGPUs, RDP problems) | D3D12/Vulkan (explicit-sync complexity, zero payoff for textured quads); Direct2D as primary (loses the shared atlas architecture) |
| Font discovery | **DirectWrite early** (`IDWriteFontCollection`, `IDWriteFontFallback::MapCharacters`) — missing fonts and broken CJK/emoji fallback are immediately user-visible | fontconfig on Windows |
| Text shaping | HarfBuzz (already in tree) — permanent | `IDWriteTextAnalyzer` (worse API, no gain) |
| Glyph rasterization | FreeType (already in tree) — possibly permanent; DWrite/ClearType demoted to "only if users complain" (subpixel AA interacts badly with GPU-composited transparent backgrounds; Windows Terminal largely ships grayscale AA anyway) | DWrite raster as a headline goal |
| IME | imm32 (`WM_IME_*`, composition window at cursor cell) first | TSF (COM swamp; escalation path only if CJK users report edge cases) |
| Toolchain | Zig's bundled toolchain (cross-compiles/links COFF with bundled MinGW libs — no Visual Studio needed); develop anywhere, **run** on Windows CI + hardware; Zig version pinned to Ghostty's | MSVC dependency |
| Distribution | winget + Scoop first (zero infra, solves updates); **code-signing cert budgeted early** (SmartScreen kills unsigned downloads); MSI/MSIX later | MSIX-first; custom Sparkle-style updater for v1 |

---

## 4. Phases

Estimates assume one developer, part-time-to-full-time, consistent with
upstream's original 6–12 month framing. The difference from the old plan:
a usable terminal exists at ~month 2–3, not at the end.

### Phase 0 — Environment + core compiles for Windows (2–4 weeks)

**This is the actual critical path.** The enemy is not D3D11; it is pervasive
POSIX assumptions in core (file descriptors in `termio/`, fork/exec, signals,
paths in `src/os/`).

- Windows 11 machine or VM; WinDbg; reference terminals installed.
- GitHub Actions `windows-latest` workflow: build + unit tests, required on
  every push to `windows-port`.
- Target: `zig build -Dtarget=x86_64-windows -Dapp-runtime=none` compiles.
  The existing `src/apprt/none.zig` runtime is the vehicle; let the compile
  errors be the work list.
- Chase POSIX-isms with small, self-contained fixes (`std.fs.File` handle
  abstractions, `builtin.os` gates). Each is a candidate upstream PR (§5).
- **Exit criterion:** core + `apprt=none` compiles for `x86_64-windows` in CI;
  unit tests for platform-agnostic core pass on Windows.

### Phase 1 — ConPTY backend in `src/termio/` (2–3 weeks)

- New PTY backend behind the existing abstraction in `termio/`:
  - **Named pipes with overlapped I/O** (anonymous pipes cannot participate in
    waits — proven the hard way last time).
  - `CreatePseudoConsole` + attribute-list `CreateProcessW`
    (`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; the
    `STARTF_USESTDHANDLES`-with-NULL-handles inheritance trick).
  - Environment block (`CREATE_UNICODE_ENVIRONMENT`) with parent inheritance,
    cwd, heap-allocated command line (32K limit), argument quoting.
  - Correct lifecycle: `errdefer` the HPCON; shutdown = drain/close pipes →
    `ClosePseudoConsole` → wait on **process handle** → terminate as last
    resort. Exit detection via the process handle, never via read()-returns-0.
  - Wire into Ghostty's existing I/O thread model (`termio/Thread.zig`) — the
    threading architecture already exists upstream; do not invent one.
- Vendor OpenConsole/conpty.dll; fall back to OS ConPTY if absent.
- Headless integration tests on CI: spawn cmd.exe/pwsh, assert output
  round-trips, resize, exit detection.
- **Exit criterion:** CI proves a real shell spawns, echoes, resizes, and its
  death is detected — with no UI existing yet.

### Phase 2 — Proof of life: GLFW bootstrap (2–4 weeks)

The de-risking phase the previous attempt skipped. GLFW + OpenGL + FreeType +
HarfBuzz are all already in tree and all work on Windows.

- Make `-Dapp-runtime=glfw -Dtarget=x86_64-windows` build and run, wired to the
  Phase 1 ConPTY backend.
- Font discovery: minimal DirectWrite enumeration (or even a hardcoded font
  path at first — honestly labeled) to feed the existing FreeType/HarfBuzz
  stack.
- **Deliverable: actual Ghostty** — real renderer, real shaping, real config,
  real keybindings — running a real shell in an ugly window on Windows.
- From this point every change regresses against a known-good baseline instead
  of assembling a non-working system.
- **Exit criterion:** daily-drivable (ugly) terminal; vttest reasonably clean
  through ConPTY; screenshot in the README.

### Phase 3 — Native Win32 apprt (2–3 months)

`src/apprt/win32.zig`, a direct Zig runtime like `gtk.zig`.

- Window class, message loop, custom frame: `WM_NCCALCSIZE`/`WM_NCHITTEST`/
  DWM Mica/`DwmExtendFrameIntoClientArea`, the flicker trifecta (null
  background brush, `WM_ERASEBKGND`, `SWP_NOCOPYBITS`), modal-loop timer so
  output keeps flowing during drags, PMv2 DPI awareness **queried at window
  creation**, `WM_DPICHANGED`. *(The prior attempt's frame code validated this
  recipe in Zig — salvage the knowledge, rewrite against generated bindings.)*
- **Input gets disproportionate budget — it is where real terminals fail:**
  - The `TranslateMessage` ordering trap (handled `WM_KEYDOWN` must swallow its
    queued `WM_CHAR`).
  - UTF-16 surrogate-pair reassembly in `WM_CHAR`; `WM_UNICHAR`.
  - AltGr discrimination via lParam bit 24 / scancode, not `GetKeyState`;
    dead keys (`WM_DEADCHAR`).
  - IME via imm32, candidate window positioned at the cursor cell.
  - Route everything through Ghostty's existing `input/` key encoding (kitty
    protocol, modifyOtherKeys come for free — do not write a parallel encoder).
- Clipboard (Unicode text both directions, bracketed paste through core's
  existing handling, format listener), mouse reporting through core, tabs via
  Ghostty's surface/tab model, GDI-free rendering (the OpenGL surface hosts in
  the Win32 window).
- Theme detection (registry + `WM_SETTINGCHANGE`), `config` paths
  (`%APPDATA%\ghostty\config`), shell-integration injection for
  pwsh/cmd-via-Clink/WSL.
- **Exit criterion:** `-Dapp-runtime=win32` is the default Windows build and
  beats the GLFW build on every axis; GLFW remains as fallback.

### Phase 4 — Ship + polish strictly by user pain (ongoing)

- Code signing, winget/Scoop manifests, crash reporting (Sentry supports
  Windows minidumps; upstream already integrates sentry).
- Then, **in order of observed user pain, not spec order:** splits; DirectWrite
  fallback hardening; quick-terminal global hotkey; tray; jump lists;
  default-terminal registration; D3D11 backend **only when GL driver telemetry
  demands it** (it is ~2k lines of COM + pipeline work with mostly-invisible
  payoff; the trigger is crash reports, not aesthetics); DWrite rasterization
  only on rendering complaints; ARM64 after x64 is stable.

---

## 5. Upstreaming Strategy

The fork is a staging area, not a destination. Every Phase 0 POSIX-ism fix and
most of Phase 1 are upstreamable as small, low-risk PRs; the apprt itself can
follow once it exists and upstream signals appetite (per Mitchell's framework
in discussion #2563).

**Upstream's AI policy (`AI_POLICY.md`) is strict and must be honored:**

- All AI assistance must be **disclosed** (tool + extent) on every contribution.
- The human contributor must **fully understand and be able to explain every
  line** without AI aid. Practically: AI-drafted code in this fork is working
  material; nothing goes into an upstream PR until the human author has
  reviewed, edited, and internalized it to the point of independent ownership.
- Poor AI-assisted contributions earn a public denouncement list. The bar for
  upstream PRs is therefore *higher* than for fork-internal work: small,
  single-purpose, personally understood, tested on real Windows hardware.

PR cadence: prefer many small PRs (one POSIX-ism, one termio fix) over a
mega-PR. Each carries Windows CI evidence.

---

## 6. Salvage List from the `yurei` Attempt

The standalone repo (`marlboro-red/yurei`, see its `REVIEW.md` for the full
audit) is retired as a codebase but mined for:

| Asset | Disposition |
|---|---|
| ConPTY spawn sequence (attribute list, HPCON-by-value, handle-inheritance trick) | Reference for Phase 1 — it matched Microsoft's sample; fix the lifecycle/shutdown bugs documented in REVIEW.md Part 2 |
| Custom frame / DWM / resize-pipeline recipe | Reference for Phase 3 — validated as correct; rewrite on generated bindings |
| Comptime box-drawing table (U+2500–259F fill-rect rendering) | Possible direct port if upstream's font path doesn't already cover it better |
| REVIEW.md bug catalogue (chunk-boundary parsing, TranslateMessage trap, surrogate pairs, AltGr, GDI lifetimes, UTF-16 edge cases) | Becomes the Phase 3 input/window **test checklist** — every documented bug gets a regression test here |
| Everything else (terminal adapter, D3D11/DWrite stubs, custom config/input/mailbox) | Superseded by the real core in this tree |

---

## 7. Risk Register

| Risk | Exposure | Mitigation |
|---|---|---|
| ConPTY is a translating middleman (latency, sequence filtering, repaints) | Some Ghostty features degrade behind it; not fully fixable | Vendor OpenConsole (newest ConPTY always); document known degradations; watch upstream conpty passthrough work |
| Upstream churn against apprt/termio interfaces | Continuous rebase tax | Weekly rebases; upstream small pieces early so the surface we depend on stabilizes around us |
| POSIX assumptions run deeper than expected (Phase 0 overruns) | Schedule | Phase 0 is timeboxed to discovery first: a complete inventory of `posix.`/`fork`/fd usage before fixing; re-estimate at week 2 |
| Zig-on-Windows toolchain maturity (linker, libc corner cases) | Build breakage | Pin Zig to upstream's version; CI catches immediately; upstream Zig issues promptly |
| GL driver quality on Intel iGPUs / RDP | Rendering failures for a user slice | Known, bounded: GLFW fallback, software hints, and the explicit D3D11 escalation path |
| Code signing cost/process (SmartScreen) | Adoption at download | Budget the cert in Phase 4 week one, not at release |
| Solo-developer review bottleneck for upstream PRs | Throughput | Keep fork releasable independently; upstreaming is parallel, never blocking |

---

## 8. Milestone Summary

| # | Milestone | Proof | Cumulative timeline |
|---|---|---|---|
| M0 | Windows CI green on core (`apprt=none`) | CI badge | ~1 month |
| M1 | Shell round-trip headless via ConPTY | CI integration test | ~1.5–2 months |
| M2 | **Proof of life:** Ghostty/GLFW running pwsh on Windows | Screenshot + daily use | ~2–3 months |
| M3 | Native Win32 apprt is the default Windows build | Tabs, IME, paste, DPI all real | ~5–6 months |
| M4 | Signed v1 on winget | `winget install ghostty` | ~6–8 months |
| M5+ | Splits, quick terminal, D3D11-if-needed, ARM64 | By user pain | post-v1 |

---

*The previous plan's failure mode was not its architecture — it was building
breadth-first scaffolding that could never run. This plan's contract is the
inverse: at every milestone there is a smaller amount of code, all of which
runs, on the platform that matters.*
