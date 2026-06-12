# Ghostty Windows Port — High-Level Plan

**Repo:** `marlboro-red/yuurei` (permanent fork of `ghostty-org/ghostty`)
**Working branch:** `main` *(since 2026-06-12; the old `windows-port`
staging branch was fast-forwarded into `main` when the project became a
standalone fork — upstream is tracked via the `upstream` remote and
merged in by release tag)*
**Date:** 2026-06-11
**Status:** Plan v2.1 — supersedes the standalone `yurei` attempt; updated same
day with the findings of the in-tree audit (§4a), which moved Phase 0 to
"mostly done upstream" and replaced Phase 2's GLFW vehicle (deleted upstream
July 2025) with a minimal win32 apprt skeleton.

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
5. **Track upstream on its release cadence.** Merge upstream release tags
   into `main` (merge, never rebase — public history stays stable for a
   standalone project). Divergence is debt; keeping the win32 layer
   additive keeps each payment small.

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

### 4a. Current-state audit (2026-06-11, this branch, Zig 0.15.2, Windows 11)

The plan above was drafted from the previous attempt's worldview ("16k lines
never compiled for Windows"). The in-tree reality is far better:

**What already works:**

- `zig build -Dtarget=x86_64-windows -Dapp-runtime=none` **compiles and links
  clean** on this machine, today, with zero changes. With `apprt=none` no exe
  is produced by design (`build.zig:177` — "Runtime none is libghostty"); the
  build emits `ghostty-internal.dll`/`-static.lib` (the full GUI core: App,
  Surface, termio, font, OpenGL renderer, config, input — the same lib the
  macOS app links) plus `ghostty-vt.dll` and headers. The feared "pervasive
  POSIX assumptions in core" have largely been paid down by upstream.
- **Upstream already carries real Windows scaffolding:**
  - `src/pty.zig` — `WindowsPty` selected by `builtin.os.tag`: pipe creation,
    `CreatePseudoConsole` / `ResizePseudoConsole` / `ClosePseudoConsole`.
  - `src/Command.zig` — `startWindows()`: `CreateProcessW` with the
    pseudoconsole attribute list, UTF-16 command line, handle inheritance.
  - `src/termio/Exec.zig` — a `threadMainWindows` read-thread branch exists
    (completeness audited in Phase 1 below).
  - `src/os/` — `windows.zig` hand bindings (kernel32 + ConPTY surface);
    `pipe.zig`, `file.zig`, `open.zig`, `path.zig` already gated for Windows.
- **Upstream CI already tests Windows:** `test.yml` has `test-windows`
  (`zig build -Dapp-runtime=none test` on a Windows runner) and
  `build-libghostty-windows-gnu`. ConPTY/termio code is *unit*-tested upstream
  on every push — to ghostty-org. All jobs are gated
  `if: github.repository == 'ghostty-org/ghostty'` and run on namespace-cloud
  runners, so **none of it runs on this fork**.

**What the audit found missing (feeds the phases below):**

- No CI on this fork (gated jobs + unavailable runners) → fork-own workflow.
- `src/os/` is in better shape than a first-pass grep suggests (verified by
  reading, not just searching): `hostname.zig` has a `GetComputerNameA` arm,
  `homedir.zig` has `homeWindows`, and `passwd.zig`'s
  `@compileError("not available on windows")` is an honest Rule-2 gate whose
  only call sites are Darwin-gated. Remaining watch item: `env.zig` gate
  coverage as new call sites appear.
- `threadMainWindows` quit-pipe path calls `posix.close()` on a Windows
  HANDLE; pipes are anonymous (`CreatePipe`), not overlapped named pipes —
  whether that supports the wait model needs a runtime test, not a code read.
- No headless ConPTY integration test anywhere (upstream's Windows tests are
  unit tests only — nothing spawns a real shell and round-trips output).
- **The GLFW apprt no longer exists.** Deleted upstream 2025-07-04
  (`fb9c52ecf` "Nuke GLFW from Orbit"). The only runtimes are `none`
  (libghostty) and `gtk`. Phase 2 as originally written is impossible; see the
  revised Phase 2.

### Phase 0 — Environment + fork CI green (days, not weeks)

Originally scoped at 2–4 weeks as the critical path; the audit (§4a) shows
upstream already did most of it. What remains:

- [x] Windows 11 machine; Zig 0.15.2 (matches `minimum_zig_version`).
- [x] `zig build -Dtarget=x86_64-windows -Dapp-runtime=none` compiles —
  verified locally, zero changes needed.
- [x] Fork CI: `.github/workflows/windows-port.yml` on `windows-latest`
  (upstream's Windows jobs never run here, §4a): build `apprt=none` + run
  `zig build -Dapp-runtime=none test` on every push to `windows-port`.
  *Written; goes live on first push.*
- [x] `zig build -Dapp-runtime=none test` passes on this machine — the full
  unit suite is green natively on Windows with zero changes (2026-06-11).
- [x] Close the known `src/os/` runtime gaps — audit found they were already
  closed upstream (§4a): hostname, homedir, pipe, file, path, open all have
  real Windows implementations; passwd is honestly comptime-gated and
  unreachable on Windows.
- **Exit criterion (unchanged):** core + `apprt=none` compiles for
  `x86_64-windows` in *this fork's* CI; platform-agnostic unit tests pass on
  Windows.

### Phase 1 — ConPTY backend in `src/termio/` (2–3 weeks)

**Audit note (§4a): this is completion-and-verification work, not greenfield.**
`WindowsPty`, `Command.startWindows()`, and `Exec.threadMainWindows` already
exist upstream. The honest status is "written, unit-tested, never proven
against a live shell end-to-end." Concrete work list from the audit:

- [x] ~~Fix `threadMainWindows` quit-pipe teardown~~ Audited 2026-06-11: the
  reported `posix.close()`-on-HANDLE is a false alarm — Zig's `std.posix.close`
  calls `CloseHandle` on Windows. The *real* bug found: `ReadFile` failing
  with `ERROR_BROKEN_PIPE` (the documented EOF when the pseudoconsole side
  closes, i.e. every child exit) was routed to `unreachable` — a guaranteed
  crash on shell exit. **Fixed**: `BROKEN_PIPE`/`HANDLE_EOF`/`INVALID_HANDLE`
  now exit the read thread gracefully, mirroring the POSIX branch.
- [x] Audit the pipe/wait model. Resolved 2026-06-11: upstream's design is
  sound — the pty *input* pipe is already an overlapped **named** pipe
  (required by libxev's IOCP stream writes; see comment in
  `pty.zig:WindowsPty.open`); the *output* pipe is anonymous but read by a
  dedicated thread with synchronous `ReadFile`, unblocked at shutdown by
  `CancelIoEx` from `threadExit` (quit byte + cancel, then `join`). No
  rewrite needed.
- [x] Verify exit detection goes through the **process handle** — confirmed:
  `Command.wait` uses `WaitForSingleObject(hProcess)` +
  `GetExitCodeProcess`; covered by the new round-trip test.
- [ ] Verify env block (`CREATE_UNICODE_ENVIRONMENT`), cwd, command-line
  quoting and the 32K limit in `startWindows()` against the checklist below.
  (Env/cwd/quoting have upstream unit tests; the 32K limit and quoting edge
  cases still need targeted tests.)
- [~] **The actual deliverable: headless ConPTY integration tests** — two
  landed 2026-06-11, both passing natively:
  1. `Command.zig` "windows pseudo console round-trip": cmd.exe on a real
     pseudoconsole, output round-trips through the pty pipe, exit via the
     process handle.
  2. `termio/Exec.zig` "conpty shell exit via xev stream write and process
     watcher": the exec stack minus Termio — input written to the pty's
     overlapped named pipe through `xev.Stream` (IOCP) and exit detected by
     `xev.Process` (job-object watcher), the two Windows paths nothing else
     exercised. Confirmed `xev.Process` IS implemented for IOCP (job objects
     + `GetExitCodeProcess`), retiring that open risk.

  Found while writing #2 — **libxev IOCP pitfall**: `loop.run(.no_wait)`
  never polls the completion port (`tick(0)` breaks before
  `GetQueuedCompletionStatusEx`), so IO completions only ever arrive from
  blocking runs. Real termio runs `.until_done` and is unaffected, but any
  future Windows code that pumps `.no_wait` will silently never complete IO.
  Candidate upstream libxev issue/fix.

  Still open: a test through the full `termio.Thread`/`Termio` stack
  (exercises `threadMainWindows` + `processExit` wiring), resize assertions,
  pwsh coverage.
- [~] Vendor OpenConsole/conpty.dll (MIT, from Windows Terminal repo); fall
  back to OS ConPTY when absent. *(2026-06-12: the loader side is done —
  ConPTY entry points resolve at first use, preferring a conpty.dll next
  to the exe via `LOAD_LIBRARY_SEARCH_APPLICATION_DIR` (no cwd
  DLL-planting), falling back to kernel32; which provider loaded is
  logged. Remaining: acquiring/shipping the OpenConsole binaries is a
  Phase 4 packaging-pipeline step.)*

Reference design (kept from v2.0 — measure upstream's code against this):
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
- **Exit criterion:** CI proves a real shell spawns, echoes, resizes, and its
  death is detected — with no UI existing yet.

### Phase 2 — Proof of life: minimal win32 apprt skeleton (3–5 weeks)

**Revised (§4a): the GLFW vehicle no longer exists.** Upstream deleted the
GLFW apprt on 2025-07-04 (`fb9c52ecf` "Nuke GLFW from Orbit"); resurrecting it
in-fork was considered and rejected — it would mean reverting a deliberate
upstream deletion, carrying a dead runtime through weekly rebases (Rule 5),
against apprt interfaces that have drifted a year past it, for zero upstream
value. The de-risking argument for GLFW is also weaker than when v2.0 was
drafted: the core already compiles for Windows and upstream unit-tests it in
CI, so there is much less left to de-risk.

Instead, proof of life is the **smallest possible `src/apprt/win32.zig`** —
the start of Phase 3's runtime, built skeleton-first:

- [x] Register `.win32` in `src/apprt/runtime.zig` + build wiring
  (2026-06-11): `src/apprt/win32/{App,Surface}.zig` satisfy the comptime
  apprt interface with honest `@panic("TODO: windows")` bodies;
  `renderer/OpenGL.zig` got `.win32` arms (panics, pending WGL);
  `zig build -Dapp-runtime=win32` produces a working `ghostty.exe` —
  `+version` reports runtime `.win32`, font engine `.freetype_windows`,
  renderer OpenGL, libxev iocp. In fork CI on every push. Not yet the
  Windows default — that flip happens at this phase's exit criterion.
  *(2026-06-11, later: now a GUI-subsystem binary — no console window on
  launch. The MSVC CRT's WinMain requirement is sidestepped by keeping
  the console CRT entry (`/ENTRY:mainCRTStartup`) under
  `/SUBSYSTEM:WINDOWS`, and CLI/log output from terminals works via
  `AttachConsole(ATTACH_PARENT_PROCESS)` at startup.)*
- [x] One window class, `CreateWindowExW`, bare message loop, **standard
  system frame**. Done 2026-06-11: `App.run` is a real
  `GetMessageW`/`PeekMessageW` loop modeled on the deleted GLFW apprt's
  contract (wait → dispatch → `core_app.tick` → deferred surface closes);
  `wakeup` posts a `WM_NULL` thread message. Win32 calls go through
  hand-written externs in `win32/winapi.zig` (plain functions only — the
  plan's zigwin32 decision is about COM and still stands for when
  DirectWrite/TSF arrive).
- [x] WGL context creation hosting the existing OpenGL renderer. Done:
  legacy `wglCreateContext` (explicit-attribs core context is a TODO),
  context handed from main thread to renderer thread via
  `surfaceInit`/`finalizeSurfaceInit`/`threadEnter` arms; viewport synced
  from the client rect in `drawFrameStart`; `SwapBuffers` in
  `drawFrameEnd`. Driver gave GL 4.6.
- [x] Crude input: `WM_KEYDOWN` (VK→key map) submits without text; if
  unconsumed, the queued `WM_CHAR` completes it with layout-cooked UTF-8
  (surrogate pairs reassembled) — the GLFW pairing adapted to the
  TranslateMessage trap. Known-crude, documented in-code: no IME, no AltGr
  discrimination (reports ctrl+alt), no dead keys, partial VK map. Also:
  focus, resize, mouse wheel, and CF_UNICODETEXT clipboard both ways.
  Mouse buttons/motion (selection) not wired yet.
- [x] Font discovery: nothing needed for proof of life — upstream's
  `freetype_windows` discovery backend plus embedded JetBrains Mono just
  worked.
- [x] Wired to the Phase 1 ConPTY backend.
- [x] **Deliverable: actual Ghostty** — real renderer, real shaping, real
  config — running a real shell in an ugly window on Windows. **Achieved
  2026-06-11**: cmd.exe banner + prompt render with JetBrains Mono;
  typed commands round-trip live; the shell sets the window title via OSC.
- From this point every change regresses against a known-good baseline
  instead of assembling a non-working system.
- [x] Mouse: buttons + motion with capture (drag-selection works — verified
  end-to-end by drag-selecting in the live window and reading the result
  off the clipboard), wheel scrolling. Mouse-shape cursors still TODO.
- [x] Keybinds actually fire: keybind triggers match on the unshifted
  codepoint, so `WM_KEYDOWN` now derives it from the layout via
  `MapVirtualKeyW(VK_TO_CHAR)`. Verified live: `ctrl+shift+c` copies the
  selection, `ctrl+shift+v` pastes through the bracketed-paste path.
- [x] Fuller VK map: OEM punctuation, numpad operators, locks,
  print-screen/pause/menu, left/right modifier discrimination via the
  extended-key bit and right-shift scancode, numpad enter.
- [x] `WM_DPICHANGED` (the PMv2 manifest upstream already ships made us
  per-monitor-aware from day one): apply the suggested rect, forward the
  new scale to `contentScaleCallback`. (Single-monitor machine — code
  follows the documented contract but a real multi-DPI drag is untested.)
- [x] SGR colors verified rendering in the live window (16-color fg/bg).
- [x] IME via imm32 (2026-06-12): `WM_IME_COMPOSITION` routes
  `GCS_RESULTSTR` commits through `keyCallback` and `GCS_COMPSTR` through
  `preeditCallback` (inline preedit; the system composition window is
  suppressed); composition UI positioned at the cursor cell via
  `imePoint()` + `ImmSetCompositionWindow`. **Implemented to the imm32
  contract but not yet exercised with a real CJK IME — needs manual
  verification by a CJK user before it can be called done.** TSF remains
  the documented escalation path.
- [x] Default shell prefers PowerShell (2026-06-12): pwsh.exe →
  powershell.exe → cmd.exe, resolved via the process search path.
  Verified: live window spawns pwsh. (Shell-integration injection for
  pwsh does not exist upstream for any platform — new work, tracked under
  Phase 3's shell-integration item.)
- [~] VT conformance (2026-06-12): a vttest-style probe through the live
  window passed cleanly — cursor addressing, SGR attribute set
  (bold/italic/underline/reverse/strike), 16/256/truecolor, DEC special
  graphics line drawing, CJK wide characters, emoji, DECSTBM scroll
  regions (verified exact post-scroll state), right-margin wrap, OSC
  title. Still open: the full interactive vttest — needs WSL (not
  installed on the dev machine) or a POSIX host to run vttest inside
  Ghostty.
- [x] Modal-loop timer (2026-06-12): core app keeps ticking during
  interactive move/resize via a WM_ENTERSIZEMOVE-scoped 16ms timer.
- [x] `initial_size` action honored (client→window rect via
  `AdjustWindowRectExForDpi`).
- [x] Stability soak (2026-06-12): 45+ minutes under continuous scrolling
  output (timestamped directory listings in a tight loop), memory stable
  at ~78MB, no crash. Longer multi-day soaks accumulate naturally from
  daily driving.
- [x] pwsh shell integration (2026-06-12) — **new feature, exists for no
  platform upstream**: `src/shell-integration/pwsh/ghostty.ps1` (5.1- and
  7+-compatible) emits OSC 133 prompt marks (A/B/C/D with exit codes),
  OSC 7 cwd, and OSC 0 titles via prompt + PSConsoleHostReadLine wraps;
  auto-injected by rewriting the command to `-NoExit -Command
  . <script>` (returns a direct command so spawn-layer quoting is exact;
  bails on -Command/-File/-EncodedCommand/-NoExit). Verified live:
  injection log, error-free startup, title following cwd via our OSC.
- [x] `zig build` on Windows now defaults to the win32 runtime
  (2026-06-12) — the exe is the default Windows artifact.
- [x] Dark title bar via DWMWA_USE_IMMERSIVE_DARK_MODE, following theme
  changes (2026-06-12).
- [x] Multiple windows (2026-06-12): `new_window` keybind/action spawns
  additional surfaces, each a top-level window with its own renderer
  thread and WGL context — verified live (targeted F9 → second window).
  `new_tab` opens a window as an interim (honest log) until the real
  tab strip lands with the custom-frame work; `close_window` wired to
  the deferred-close path.
- [x] **vttest through WSL inside the live window (2026-06-12)**: WSL1 +
  Ubuntu installed (firmware virtualization disabled on the dev machine,
  so WSL2 unavailable); vttest 2.7 driven interactively inside Ghostty.
  Results: test 1 cursor movements — E-frame screen pixel-perfect,
  autowrap screen complete I–Z/i–z margins in order; menu 11.6 ISO-6429
  colors — full 64-combination fg/bg matrix correct in both bright
  variants; menu 11.8 xterm set-window-title — OSC title flowed
  WSL→ConPTY→core→strip and the OS window title matched exactly.
  (Methodology note: screenshot captures can catch screens mid-redraw;
  judge only settled screens.)
- **Exit criterion (still open):** screenshot in the README. Everything
  else on the Phase 2 list is done.

**Incident (2026-06-12): GPU driver timeouts (LiveKernelEvent 141).**
Hours of accumulated test instances triggered bursts of video-engine
timeout kernel events (WER `Kernel_141` reports), destabilizing the
whole desktop (GPU device-loss kills unrelated apps). Two win32 apprt
defects were the likely trigger, both fixed:
1. The swap interval was never set — config `vsync = true` was ignored
   and SwapBuffers ran unthrottled. Now `wglSwapIntervalEXT(1)` on
   renderer-thread enter (warns if unavailable).
2. Hidden tab hosts kept presenting; drawFrameEnd now skips SwapBuffers
   for invisible windows.
Post-fix: ~2% of one core at idle, no driver events. This validates the
plan's "GL driver quality" risk-register entry — on NVIDIA, not Intel.

### Phase 3 — Native Win32 apprt, completed (2–3 months)

Fill out the Phase 2 skeleton in `src/apprt/win32.zig` until it is a real
runtime like `gtk.zig`.

- Window class, message loop, custom frame: `WM_NCCALCSIZE`/`WM_NCHITTEST`/
  DWM Mica/`DwmExtendFrameIntoClientArea`, the flicker trifecta (null
  background brush, `WM_ERASEBKGND`, `SWP_NOCOPYBITS`), modal-loop timer so
  output keeps flowing during drags, PMv2 DPI awareness **queried at window
  creation**, `WM_DPICHANGED`. *(The prior attempt's frame code validated this
  recipe in Zig — salvage the knowledge, rewrite against generated bindings.)*
  - [x] Prerequisite landed (2026-06-12): the GL surface renders into a
    disabled child window ("ghostty-host") instead of the top-level
    window, so the parent can own GDI-painted chrome (tab strip, caption
    buttons) that the GL swap chain can't overdraw. Verified zero
    behavioral change: rendering, input passthrough (disabled child →
    parent), resize tracking.
  - [x] Custom frame landed (2026-06-12): `WM_NCCALCSIZE` removes the
    standard title bar (keeping DefWindowProc's left/right/bottom resize
    borders + maximize inset); `WM_NCHITTEST` synthesizes the top resize
    border, drags via HTCAPTION, and exempts the caption buttons; the
    strip is GDI-painted (theme-aware background, centered title, Segoe
    MDL2 caption glyphs with hover states including red close). All
    verified live: drag, maximize/restore with correct inset, close via
    button → clean exit. A frame recalc (`SWP_FRAMECHANGED`) is forced
    after the wndproc is wired since the initial frame computes before
    that. *(Test-harness note: PowerShell-driven clicks need
    `SetThreadDpiAwarenessContext(-4)` + foregrounding — coordinates are
    otherwise DPI-virtualized and clicks land on overlapping windows.)*
  - [x] **Tabs (2026-06-12)**: the apprt split into `Window.zig` (one
    top-level window owning frame, strip, input routing) and
    `Surface.zig` (one tab: GL host child + WGL context + core
    surface). The strip draws real tabs (active/hover states, per-tab
    close, "+" button) ahead of the caption buttons; switching toggles
    host-child visibility with focus callbacks. `new_tab`, `goto_tab`
    (previous/next/last/index), `close_tab`, and `close_window` actions
    wired. Verified live end-to-end: "+" spawned a second shell, typed
    text landed only in the active tab, switching preserved both
    sessions' content, closing a tab re-laid-out the strip with the
    window surviving.
  - Tab drag-reorder + `move_tab` landed 2026-06-12 (tabs activate on
    press; captured drag reorders across slots; move_tab wraps
    cyclically — all verified live via posted-message input).
  - Tab tooltips landed 2026-06-12 (comctl32, one tool per slot,
    explicit TTM_RELAYEVENT; verified to API contract, hover popup
    visual check pending normal desktop use — dev machine state
    suppresses popups).
  - Scrollbars landed 2026-06-12: a native SCROLLBAR control in a
    reserved column beside each GL host, fed by the core `scrollbar`
    action (SetScrollInfo range/page/pos), WM_VSCROLL →
    `scroll_to_row` with 32-bit track positions, focus handed back to
    the terminal on SB_ENDSCROLL. Verified live: thumb tracked 200
    lines of scrollback and SB_PAGEUP moved the viewport.
  - Remaining polish: Mica/backdrop.
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
- **Exit criterion:** `-Dapp-runtime=win32` is the default Windows build with
  tabs, IME, paste, and DPI all real — nothing on the Phase 2 skeleton's
  `@panic("TODO")` list remains reachable in normal use.

### Phase 3a — macOS feature-parity sweep (2026-06-12, in progress)

Working down the gap list from the macOS comparison audit:

- [x] `open_config`: opens the config file in notepad via ShellExecuteW
  (no .ghostty file association exists). Verified live: F8 keybind →
  notepad with the config path.
- [x] `ring_bell`: taskbar/caption attention flash; beep only when the
  window is in the background.
- [x] `desktop_notification` (2026-06-12, real): a lazily created tray
  notify icon + NIF_INFO balloon tip, which Win 10/11 renders as a
  toast — no AUMID/package identity needed (WinRT toasts can replace
  this after packaging). Source window still flashes. Verified to the
  OS boundary (dev machine has ToastEnabled=0 so Windows declines to
  render). **Correction (same day):** the earlier finding that ConPTY
  consumes OSC 9/777 was wrong — it was an artifact of a broken test
  harness (bare posted WM_CHARs are dropped by charEvent's
  TranslateMessage-trap design; typing needs KEYDOWN+CHAR pairs).
  Retested properly: OSC 9 flows through ConPTY end-to-end into the
  toast handler; OSC 777 likewise (the second emission only hit
  core's 1/sec notification rate limiter).
- [x] Clipboard confirmation: unsafe pastes (core's UnsafePaste) and
  OSC 52 reads/writes now prompt with a native yes/no warning dialog,
  defaulting to No. Verified live: multi-line paste into cmd.exe raised
  the dialog; No blocked the paste.
- [x] Quick terminal + global keybinds (2026-06-12): `global:`-flagged
  keybinds register as Win32 system hotkeys (`RegisterHotKey`, null-hwnd
  thread messages handled in the run loop; trigger→VK mapping for
  letters/digits/F-keys/backquote/space); app-scoped hotkey actions
  dispatch through `core_app.performAction`. The quick terminal is a
  topmost tool window docked to the top of the primary monitor (full
  width, 40% height) that hides on focus loss, toggled by
  `toggle_quick_terminal`; a hidden quick terminal never keeps the app
  alive as the last window. Verified live: a real system-wide
  Ctrl+Alt+G summoned it (0,0 full-width) and a second fire hid it.
  *(Also fixed by this work's testing: `LoadCursorW` MAKEINTRESOURCE
  ids tripped Debug alignment checks for odd ids like IDC_IBEAM —
  latent crash on any text-cursor mouse shape.)*
- [x] **Splits (2026-06-12)** — built on upstream's shared
  `datastruct/split_tree.zig` (`SplitTree(Surface)`; surfaces gained the
  ref/unref view contract). Each tab is now a split tree of surfaces;
  layout comes from the tree's `spatial()` slots mapped onto the
  terminal area with a 2px gap (parent paints the gap background,
  `WS_CLIPCHILDREN` protects the GL hosts). Input routes positionally:
  clicks focus the split under the cursor, wheel scrolls the hovered
  split, keyboard/IME follow split focus. Actions wired: `new_split`
  (all four directions), `goto_split` (spatial + wrapped prev/next),
  `resize_split`, `equalize_splits`, `toggle_split_zoom`; closing a
  shell collapses its split, closing the last closes the tab. Verified
  live: split right, marker typed into the focused new pane only,
  `goto_split` moved focus (solid vs hollow cursors), `exit` collapsed
  back to a full-width survivor with history intact.
- [x] **Split divider drag + snap layouts (2026-06-12)** — dividers are
  draggable (captured drag updates the ratio in place, 5–95% clamp,
  WE/NS resize cursors over the gap); re-laid-out surfaces get an
  explicit `refreshCallback()` because an idle surface never presents
  after a resize, which left stale pixels in newly exposed regions.
  The maximize button reports `HTMAXBUTTON` from `WM_NCHITTEST` (snap
  layouts flyout eligibility) with NC mouse handlers for hover paint
  and click → maximize/restore. Verified live: drag re-rendered both
  panes cleanly; maximize click zoomed and a second click restored the
  exact prior rect. (The flyout itself didn't appear under synthetic
  hover on the dev machine — but neither did Notepad's, so the hit-test
  contract is as verified as the environment allows.)
- [x] **Command palette (2026-06-12)** — a native borderless popup
  (own window class, CS_DROPSHADOW, GDI-painted like the strip) over
  the active window: typed case-insensitive filter over the
  `command-palette-entry` commands (titles + descriptions), keyboard
  navigation, mouse hover/click/wheel, Escape/focus-loss dismissal;
  Enter executes via the focused surface's `performBindingAction`.
  Default binding Ctrl+Shift+P works out of the box. Verified live:
  filter "split right" narrowed to one command and Enter created the
  split.
- [x] **Background opacity (2026-06-12)** — `background-opacity < 1`
  maps to window-level alpha (WS_EX_LAYERED +
  SetLayeredWindowAttributes); `toggle_background_opacity` flips
  between configured and opaque. Per-pixel GL alpha (true blur/Mica
  behind text) needs a DirectComposition swap chain — future work.
  Verified live at 0.85 with the toggle.
- [x] **Inspector (2026-06-12)** — `inspector` toggle/show/hide opens a
  native top-level window hosting the shared Dear ImGui inspector
  (own WGL context on the main thread, ~30fps timer +
  `render_inspector` repaints, ImGui io input translation, DPI-scaled
  style). Found live: the imgui GL3 backend leaves GL_SCISSOR_TEST on,
  confining the next clear to the last clip rect. The surface owns its
  inspector window and tears it down before the core surface dies.
- Remaining from the audit, in rough order: settings GUI, auto-update,
  WinRT toasts.

### Phase 3b — survey-driven gaps (2026-06-12)

Surveyed the other Windows ports (amanthanvi/winghostty,
deblasis/wintty, InsipidPoint/ghostty-windows) and closed the cheap
user-facing gaps they exposed:

- [x] **open_url** — Ctrl+click on detected/OSC 8 links opens via
  ShellExecuteW behind an http/https/mailto allowlist (a bare path or
  file URL would execute; terminal output is untrusted). Verified
  live: file URL refused with a log, https link opened the browser.
- [x] **File drag-and-drop** — WM_DROPFILES pastes dropped paths
  through the normal unsafe-paste-confirmed path, double-quoted when
  cmd/pwsh would split them. Verified live via a fabricated HDROP.
- [x] **Find-in-terminal** — search bar popup docked top-right; core
  owns matching/lifecycle (search, navigate_search, end_search in;
  start_search, search_total, search_selected out). Verified live
  with highlighted matches, live counts, and selection navigation.
- [ ] **win32-input-mode (mode 9001)** — conhost requests
  full-fidelity key encoding (CSI Vk;Sc;Uc;Kd;Cs;Rc _) when a client
  uses ReadConsoleInput. We currently log "unimplemented mode: 9001"
  and conhost falls back to synthesizing input from plain VT, which
  works for everything tested so far. Implementing means plumbing a
  terminal mode + a Windows arm in the shared key encoder (VK +
  scancode recovery from the key event) — a focused arc of its own.
  InsipidPoint's port proves it's tractable.
- Deliberately skipped from the survey: session restore (large,
  winghostty has it), signed installers/winget/Scoop (distribution
  stays GitHub-only by choice), WinUI/DX12 rearchitecture (wintty's
  approach; our WGL renderer measures at conhost parity).

### Phase 4 — Ship + polish strictly by user pain (ongoing)

**Distribution decision (2026-06-12): GitHub Releases only.** No code
signing, no winget/Scoop, no installer — by choice. Landed:

- [x] Inverted-icon branding (derivative of upstream's MIT artwork,
  attribution + swap-on-request commitment in README), embedded via
  dist/windows/ghostty.rc with a real VERSIONINFO (ProductName yuurei,
  0.1.0), wired to the window class and tray icon.
- [x] vendor/conpty: conpty.dll + OpenConsole.exe from
  microsoft/terminal (MIT, NOTICE.md), shipped beside the exe in
  releases. Best 10MB burst with it: 885 ms vs 1.25–1.5 s in-box
  baseline (noisy machine, but the best time recorded).
- [x] .github/workflows/release.yml: v* tag → ReleaseFast build +
  suite → portable zip (bin/, share/, LICENSE, README,
  THIRD_PARTY_NOTICES) + SHA256 → GitHub Release.

Still open if user pain demands: crash reporting (Sentry supports
Windows minidumps; upstream already integrates sentry).
- Then, **in order of observed user pain, not spec order:** splits; DirectWrite
  fallback hardening; quick-terminal global hotkey; tray; jump lists;
  default-terminal registration; D3D11 backend **only when GL driver telemetry
  demands it** (it is ~2k lines of COM + pipeline work with mostly-invisible
  payoff; the trigger is crash reports, not aesthetics); DWrite rasterization
  only on rendering complaints; ARM64 after x64 is stable.

### Phase 5 — Performance and efficiency (2026-06-12, in progress)

Measured on the 4K dev machine (ReleaseFast unless noted):

| Metric | Result |
| --- | --- |
| Startup to visible window | ~200 ms (debug and release) |
| Idle CPU | 0.2–0.3% of one core; ~42 MB working set |
| 100k pwsh lines end-to-end | 5.1 s — parity with classic conhost (4.9 s) |
| 10 MB single raw write | 1.25 s vs conhost 0.66 s — the gap is conhost's own re-render inside ConPTY, a tax every ConPTY-based terminal (incl. Windows Terminal) pays |
| Busy hidden tab | 9.7% → 8.6% of a core after the occlusion fix (and GPU draws eliminated entirely) |
| Debug vs ReleaseFast | 100k lines: 72 s vs 5.1 s (~14x) — README now steers builds to ReleaseFast |

Landed fixes:

- [x] **Renderer occlusion wiring**: `occlusionCallback` on tab
  switches (`Surface.setVisible`), window minimize (`WM_SIZE`), and
  quick-terminal hide/show. Occluded renderers skip cell rebuilds and
  draws entirely (previously only SwapBuffers was skipped).
- [x] **Strip GDI caching**: the two strip fonts are cached per DPI
  instead of being created/destroyed on every WM_PAINT (the strip
  repaints on every hover change).
- [x] **Resize-storm coalescing**: divider drags and interactive
  border resizes run the full per-split resize pipeline (ConPTY
  resize + renderer resize); both are throttled to ~60 Hz with an
  exact final layout on release/exit (WM_EXITSIZEMOVE).
- [x] **Hover repaint isolation**: strip hover changes invalidated the
  whole window, so crossing the tab strip redrew the terminal per
  hover change. Now: `invalidateStrip()` for strip-only changes,
  region-aware WM_PAINT (strip paints skip the renderer refresh and
  background fill; terminal paints skip the strip), and a fingerprint
  guard on the tooltip re-sync. Verified: a 60-toggle hover storm
  produced zero renderer activity (was one full refresh per toggle).
- [x] **window-vsync honored** (was hardcoded on): `window-vsync =
  false` now sets WGL swap interval 0 for minimum input latency;
  default remains on. Safety-checked: busy output with vsync off holds
  the same CPU as on (the renderer is damage-driven, no free-spin).
- Tried and rejected (both noted in-source so nobody retries blind):
  64 KB ConPTY read buffer (Exec.zig) and 128 KB ConPTY output pipe
  buffer (pty.zig) — both measured neutral on the 10 MB burst. The
  burst wall clock is conhost's re-render inside ConPTY; nothing on
  our side of the pipe moves it. The real lever is the Phase 4
  OpenConsole binaries drop (a newer, faster conhost).

- [x] **Perf tracing instrumentation** (`GHOSTTY_PERF_TRACE=1`,
  src/perf.zig): key→present latency (gated on the pty echo arriving,
  so cursor-reset presents don't consume the sample) logged by the
  renderer, and per-second io read/parse statistics (KB/s, chunk
  count/size, parse share of wall) logged by the read thread. Costs
  one relaxed atomic load per traced path when disabled.

Instrumented results (ReleaseFast):

| Metric | Result |
| --- | --- |
| Key→present (echo) median | 1.22 ms vsync on, 1.05 ms vsync off (p90 ≈ 2.1 ms both) — sporadic presents don't hit vsync backpressure; remaining photon latency is DWM's |
| Burst io profile (10 MB) | ConPTY delivers ~3.3 MB/s in ~307-byte chunks (~11k chunks/s); our parse is **6% of wall** — the read thread waits on conhost 94% of the time |

The burst numbers close the throughput question: nothing on our side
of the pipe is the bottleneck (also why the 64 KB read buffer and
128 KB pipe buffer experiments were neutral — conhost writes ~300 B at
a time). The only real throughput lever is the Phase 4 OpenConsole
binaries drop (newer conhost with faster ConPTY).

Methodology note: latency was measured by posting
KEYDOWN+CHAR+KEYUP 'a' presses at 150 ms spacing and taking the median
of the renderer's trace lines; bursts via a 10 MB single
[Console]::Write from pwsh.

Candidate future work: DWM present timing/Mica interactions, and
re-running this table after upstream merges (the suite lives in this
section).

---

## 5. Relationship to Upstream

**Decision (2026-06-12): yuurei is its own project, maintained permanently
as a fork. There is no intention to merge the port into upstream Ghostty.**
This supersedes the original "staging area, not a destination" framing.

What this changes:

- The fork *is* the destination. Code quality standards are ours to set;
  the practical bar stays "verified live + CI green on every commit."
- Upstream tracking still matters — it's how the shared core keeps
  improving underneath the port. `main` stays clean against upstream;
  `windows-port` rebases regularly (Rule 5 stands: divergence is debt).
  Keeping the win32 layer additive (new files; minimal shared-file
  churn) keeps that rebase cheap.
- Upstream's `AI_POLICY.md` contribution requirements don't bind this
  fork's internal work; AI assistance remains disclosed in the README
  for transparency. If anything were ever submitted upstream after all,
  the full human-review-and-ownership bar would apply first.

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
| GL driver quality on Intel iGPUs / RDP | Rendering failures for a user slice | Known, bounded: software-GL hints and the explicit D3D11 escalation path |
| Code signing cost/process (SmartScreen) | Adoption at download | Budget the cert in Phase 4 week one, not at release |
| Solo-developer review bottleneck for upstream PRs | Throughput | Keep fork releasable independently; upstreaming is parallel, never blocking |

---

## 8. Milestone Summary

Timelines re-baselined after the §4a audit (Phase 0 collapsed from ~1 month
to days; Phase 2's GLFW shortcut is gone but its replacement seeds Phase 3).

| # | Milestone | Proof | Cumulative timeline |
|---|---|---|---|
| M0 | Fork Windows CI green on core (`apprt=none` build + tests) | CI badge | **Done 2026-06-11** |
| M1 | Shell round-trip headless via ConPTY | CI integration test | ~3–5 weeks |
| M2 | **Proof of life:** Ghostty/win32-skeleton running a live shell on Windows | Screenshot + daily use | **Render+input live 2026-06-11**; daily-drivability still open |
| M3 | Win32 apprt completed, default Windows build | Tabs, IME, paste, DPI all real | **Tabs/IME/paste/DPI all landed 2026-06-12; default flipped. Remaining: CJK-user IME verification + polish** |
| M4 | Signed v1 on winget | `winget install ghostty` | ~6–8 months |
| M5+ | Splits, quick terminal, D3D11-if-needed, ARM64 | By user pain | post-v1 |

---

*The previous plan's failure mode was not its architecture — it was building
breadth-first scaffolding that could never run. This plan's contract is the
inverse: at every milestone there is a smaller amount of code, all of which
runs, on the platform that matters.*
