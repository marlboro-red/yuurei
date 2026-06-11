# Ghostty Windows Port — High-Level Plan

**Repo:** `marlboro-red/yuurei` (fork of `ghostty-org/ghostty`)
**Working branch:** `windows-port` (`main` stays clean, tracking upstream)
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
- [ ] Vendor OpenConsole/conpty.dll (MIT, from Windows Terminal repo); fall
  back to OS ConPTY when absent.

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

- Register `.win32` in `src/apprt/runtime.zig` + build wiring; make it the
  Windows default for the exe build (`-Dapp-runtime=win32`).
- One window class, `CreateWindowExW`, bare message loop, **standard system
  frame** (no DWM custom chrome yet).
- WGL context creation hosting the existing OpenGL renderer.
- Crude input only: `WM_CHAR` → core's existing `input/` encoding. No IME, no
  AltGr correctness, no dead keys yet — gaps are `@panic("TODO: windows")`
  per Rule 2, never silent wrong behavior.
- Font discovery: minimal DirectWrite enumeration (or even a hardcoded font
  path at first — honestly labeled) to feed the existing FreeType/HarfBuzz
  stack.
- Wired to the Phase 1 ConPTY backend.
- **Deliverable: actual Ghostty** — real renderer, real shaping, real config —
  running a real shell in an ugly window on Windows.
- From this point every change regresses against a known-good baseline instead
  of assembling a non-working system.
- **Exit criterion:** daily-drivable (ugly) terminal; vttest reasonably clean
  through ConPTY; screenshot in the README.

### Phase 3 — Native Win32 apprt, completed (2–3 months)

Fill out the Phase 2 skeleton in `src/apprt/win32.zig` until it is a real
runtime like `gtk.zig`.

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
- **Exit criterion:** `-Dapp-runtime=win32` is the default Windows build with
  tabs, IME, paste, and DPI all real — nothing on the Phase 2 skeleton's
  `@panic("TODO")` list remains reachable in normal use.

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
| GL driver quality on Intel iGPUs / RDP | Rendering failures for a user slice | Known, bounded: software-GL hints and the explicit D3D11 escalation path |
| Code signing cost/process (SmartScreen) | Adoption at download | Budget the cert in Phase 4 week one, not at release |
| Solo-developer review bottleneck for upstream PRs | Throughput | Keep fork releasable independently; upstreaming is parallel, never blocking |

---

## 8. Milestone Summary

Timelines re-baselined after the §4a audit (Phase 0 collapsed from ~1 month
to days; Phase 2's GLFW shortcut is gone but its replacement seeds Phase 3).

| # | Milestone | Proof | Cumulative timeline |
|---|---|---|---|
| M0 | Fork Windows CI green on core (`apprt=none` build + tests) | CI badge | ~1 week |
| M1 | Shell round-trip headless via ConPTY | CI integration test | ~3–5 weeks |
| M2 | **Proof of life:** Ghostty/win32-skeleton running pwsh on Windows | Screenshot + daily use | ~2–3 months |
| M3 | Win32 apprt completed, default Windows build | Tabs, IME, paste, DPI all real | ~5–6 months |
| M4 | Signed v1 on winget | `winget install ghostty` | ~6–8 months |
| M5+ | Splits, quick terminal, D3D11-if-needed, ARM64 | By user pain | post-v1 |

---

*The previous plan's failure mode was not its architecture — it was building
breadth-first scaffolding that could never run. This plan's contract is the
inverse: at every milestone there is a smaller amount of code, all of which
runs, on the platform that matters.*
