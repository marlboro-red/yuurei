# Windows performance and memory audit — 2026-09-26

Scope: Yuurei's Win32 runtime, WGL/DXGI integration, ConPTY lifecycle,
Windows font discovery, settings/inspector windows, and build configuration.
Upstream Ghostty was merged through `69bf1ac87` in `f56cfd411` first.

The [graphics-memory follow-up](PERFORMANCE_CONTEXT_FOLLOWUP_2026-09-26.md)
records a further custom-shader retention fix, context/worker experiments,
and stronger rendering validation.

## Measured findings and fixes

1. **High: unnecessary graphics allocations after the upstream merge.**
   Upstream's EGL renderer exports frames asynchronously and now needs three
   frame sets plus an RGBA export texture. Windows still completes frames
   synchronously and blits the render framebuffer directly. Allocating those
   resources on Windows brought eight idle tabs to 1,112 MiB private memory.
   Restoring one WGL frame and omitting export textures reduced this to
   932 MiB (about 16%). One tab fell from 202 to 178 MiB. This preserves
   GTK's export path. See `src/renderer/OpenGL.zig` and
   `src/renderer/opengl/Target.zig`; fixed in `509d0184a`.

2. **High: two leaked kernel handles per shell launch.**
   `Command.startWindows` discarded the primary thread handle without closing
   it. The owned process handle also survived both normal exit and forced
   closure; libxev closes its own duplicate, not this handle. Twenty tab cycles
   added approximately forty handles before the fix. Afterwards, twenty
   running-tab cycles returned to the starting count (357 before churn,
   355 afterwards as a background thread also finished). A direct repeated
   process-launch regression test checks equal kernel handle counts.
   See `src/Command.zig` and `src/termio/Exec.zig`; fixed in `a85d5ea84`.

3. **Medium: release binaries included Debug Unicode and OpenGL modules.**
   Compiler command lines confirmed `-ODebug` for these runtime modules.
   Unicode's shared module graph now inherits target/optimization from each
   consuming compile step, preserving the singleton required by vaxis.
   OpenGL receives explicit target/optimization options. Windows translates
   opaque EGL platform types to avoid importing an unused Windows SDK header.
   This removes a known build configuration problem; no isolated throughput
   speedup is claimed without a matched before/after benchmark.

4. **Medium: minimized inspector still rendered continuously.**
   The inspector invalidated itself every 33 ms and ran two ImGui frames per
   paint even while minimized. Measurements showed roughly 5–8% of one core
   while minimized. Its timer now stops on minimize, resumes on restore, and
   rendering checks visibility. A settled repeat measured 0.31% minimized,
   versus 6.25% visible and 5.31% after restoring the window. The visible
   inspector still intentionally
   updates at 30 Hz; reducing that further needs an interaction-aware policy.

5. **Low: initial config creation leaked its file handle.**
   `config.edit.openPath` dropped the file returned by `createFileAbsolute`.
   The new settings window calls this path. Creation now closes the handle
   immediately. This affects first creation, not every settings-window open.

## Measurement method

Machine: Ryzen 5 5600X, 12 logical processors, RTX 3060 Ti, driver
32.0.15.6094. Zig 0.16.0, ReleaseFast, Windows MSVC target, classic WGL
presentation. `bench/resources.ps1` launches an isolated configuration using
Consolas and `cmd.exe /Q /K`, disables cursor blinking and session restoration,
and records process private bytes, working set, kernel handles, threads,
GDI/USER objects, and CPU time over five-second intervals.

These are Yuurei process measurements, excluding shells, conhost and dedicated
GPU memory. Private committed memory is not resident RAM. Driver/allocator
caches can keep memory after surfaces close; short-run retained memory alone
does not establish a leak. CPU percentages use one core as 100%, not the
whole machine. Tracing is enabled for startup phase attribution. Avoid builds
and other benchmarks during measurement.

Final 20-cycle run (raw samples and binary hashes are in
`performance-2026-09-26.json`):

| State | Private MiB | Working set MiB | Kernel handles | Threads |
| --- | ---: | ---: | ---: | ---: |
| One tab | 178.85 | 72.86 | 356 | 14 |
| Eight tabs | 934.52 | 223.22 | 665 | 42 |
| Back to one tab | 251.98 | 111.32 | 357 | 14 |
| After 20 forced tab closures | 200.85 | 93.73 | 355 | 13 |
| After 20 normal shell exits | 211.53 | 93.14 | 355 | 10 |
| After 20 settings cycles | 195.61 | 91.13 | 369 | 11 |
| After 20 inspector cycles | 201.26 | 102.62 | 388 | 13 |

The first five-second interval of this run included a 7.8% CPU transient;
later settled terminal intervals were 0–0.6%. A separate warm repeat returned
0% for the first interval. Do not interpret launch-adjacent samples as steady
idle consumption. Initial settings/inspector use also introduces process-wide
Windows/driver resources; the short churn runs do not attribute every retained
handle or prove that every cache is bounded.

The harness verifies surface counts so failed input automation cannot be
mistaken for a leak. Normal shell exit uses a configured `text:exit\r` action;
bare posted `WM_CHAR` messages are deliberately ignored by Yuurei. Discarded
development runs that left tabs open are excluded from conclusions. An old
pre-upstream binary run overlapped compilation and is also excluded from
timing comparisons.

Startup traces in one warm run placed font prewarm at 25 ms, WGL context
creation at 89 ms, shell spawn at 106 ms and first PTY output at 109 ms after
app initialization began. The WGL stage is a useful profiling target, but
this single trace is not a cold-start distribution or first-visible-frame
measurement. Window-handle discovery is recorded separately by the harness.

## Throughput and compression baseline

Current ReleaseFast benchmark, 100,000 lines per corpus, 120 columns by 80
rows, one warmup and five measured processes, 64 KiB read chunks. These are
full-process medians including setup and file I/O, not isolated compression
times or end-to-end terminal throughput. No matched earlier benchmark binary
was built in this audit, so these establish a baseline rather than a speedup.

| Corpus | Stream ms | Compression noop ms | Compression incremental ms |
| --- | ---: | ---: | ---: |
| ASCII | 15.92 | 31.21 | 55.22 |
| Color/SGR | 44.81 | 64.36 | 86.90 |
| Unicode | 29.38 | 49.48 | 73.46 |

The ASCII report with a 100,000,000-byte scrollback limit compressed 248
pages: 99,549,184 raw bytes into 1,570,187 encoded bytes (1.58%). Estimated
resident-byte savings were 97,978,997 bytes. This confirms the upstream
Windows compression path is active; it is not a direct working-set reading
and does not imply the same reduction in private commit.

ReleaseFast application and benchmark builds passed. The final targeted suite
passed 184 tests with one skipped. Native smoke checks passed for settings,
terminal rendering, tabs, splits and the inspector, with the terminal capture
also inspected visually. The resource harness exercised twenty cycles each
of forced closure, normal shell exit, settings and inspector teardown.

## Per-tab memory follow-up

The follow-up corrected the initial hidden-tab diagnosis: `setVisible(false)`
already releases frame targets, atlas texture copies, cell buffers and custom
shader textures. It retains programs, images, the WGL context and native
drawable. Adding another eviction mechanism would duplicate existing work.

Three changes are committed separately:

- `10e464cb4`: use explicit 4 MiB Windows worker stacks. Zig 0.16's default
  thread stack is 16 MiB, passed as committed stack size on Windows. The
  renderer, I/O dispatcher and PTY reader consequently committed about
  48 MiB per surface. The explicit budget reduces that to 12 MiB; lifecycle
  samples confirmed the original 32 MiB dispatch/renderer and 16 MiB reader
  increments. Startup prewarm and WSL discovery use the same budget.
- `b827d37b2`: detach linked GL shaders so deletion can finish, release shaders
  and programs on compilation/link failure, and delete pipeline VAOs/FBOs.
  These repair ownership; no isolated memory reduction is attributed to them.
- `46cda6002`: flush GL commands after releasing hidden frame resources.
  An inactive context may otherwise leave deletion work queued until its next
  frame. This submits work without adding a GPU completion wait.

Matched warm ReleaseFast runs at **1600 x 1200 physical window pixels**, on
the same machine and configuration described above:

| Phase | Baseline private MiB | Candidate private MiB | Baseline working MiB | Candidate working MiB |
| --- | ---: | ---: | ---: | ---: |
| One tab | 178.81 | 141.61 | 72.79 | 72.65 |
| Eight tabs | 933.44 | 576.59 | 223.73 | 222.36 |
| After 30 tab switches | 964.19 | 612.11 | 246.77 | 247.28 |

Eight-tab private commit decreased **356.85 MiB (38.2%)**. Resident working
memory was essentially unchanged. The intermediate stack/ownership build
measured 645.38 MiB with eight tabs; submitting deletions reduced this by
another approximately 69 MiB. Treat these as this driver's observed values,
not guaranteed savings on every GPU. Raw samples, binary hashes and switch
timings are in `performance-graphics-memory-2026-09-26.json`.

The 30-sample tab dispatch-to-present median was 6 ms in both builds; p95 was
6 ms baseline and 8 ms candidate. This is key-handler dispatch through the
first traced presentation, with millisecond resolution. It excludes time
queued before dispatch and does not measure physical scanout. The small
sample does not establish latency equivalence or a statistically reliable
2 ms regression. Both eight-tab idle samples consumed zero measured CPU.

Shrinking hidden native host windows to 1 x 1 saved only about 1 MiB across
seven hidden tabs. A standalone eight-context WGL probe consumed roughly
350–365 MiB private commit without terminal state. Releasing the shader
compiler and requesting a core profile produced no repeatable major benefit.
These experiments do not establish a universal driver-memory floor or justify
context sharing without a separate correctness and lifetime design.

Validation: ReleaseFast build passed; targeted Windows, OpenGL and Shadertoy
tests passed (118 passed, one skipped). Native stress completed with eleven
surfaces, ten shader reload/tab-switch cycles, a 128-function custom shader,
20,000 Unicode/ANSI output lines, surface teardown and settings assertions.
This exercises the smaller stacks but is not an exhaustive stack-depth bound
for third-party drivers or arbitrary shaders. Desktop captures showed black
and stale regions in both baseline and candidate, including before custom
shaders were loaded. Rendering-versus-capture attribution remains unresolved;
these stress runs are **not a visual correctness pass**.

## Remaining priorities

1. **Attribute the remaining context/driver allocations.** Eight quiet tabs
   now use approximately 577 MiB private commit and 222 MiB working set.
   Frame resources are already evicted on hiding. Use ETW/GPUView or a graphics
   debugger before considering context pooling or destruction on inactivity.
   Resolve the baseline/candidate desktop capture anomaly before accepting
   broader renderer changes. Preserve PTY state and validate atlas reupload,
   custom shaders, resize and device loss.

2. **Attribute per-surface thread and kernel cost.** Going from one to eight
   tabs added 28 threads in this run (14 to 42). Explicit stack budgets fixed
   excessive initial commit without restructuring I/O. A thread
   count does not by itself prove meaningful idle CPU overhead: quiet tabs
   measured near zero CPU.

3. **Profile the synchronous GPU boundary under output load.** WGL calls
   `gl.finish` before presentation and uses vsynced `SwapBuffers`. These can
   serialize CPU/GPU work. Do not simply remove synchronization: frame and
   upload lifetimes currently rely on synchronous completion, and the port
   documents driver trouble with unthrottled presentation. Compare busy-frame
   traces and software key-to-pixels distributions before changing this.

4. **Measure ConPTY feeding versus parsing.** The Windows read loop parses
   at most 1 KiB per read, unlike POSIX's gather pipeline. Existing source
   notes report a neutral 64 KiB experiment. Use the existing parse/lock-wait
   instrumentation with ASCII, color, Unicode and full-screen updates before
   introducing another thread or batching delay. Parser-only benchmarks do
   not include ConPTY, shaping, rendering, or presentation.

5. **Recheck long scrollback with the new upstream Windows reclamation.**
   `DiscardVirtualMemory` support is now present, so the old benchmark README
   statement that Windows never compresses pages is obsolete. Discard retains
   commit charge while allowing physical pages to be reclaimed; compare
   working set and private commit separately. Compression's report estimates
   bytes from page state, not a direct OS memory measurement.

6. **Test larger profiles and font collections.** Font metadata is cached
   across grids and invalidated on `WM_FONTCHANGE`; coverage matching still
   searches stored ranges. Settings enumerates fonts/themes on each open.
   Current churn does not establish unbounded GDI growth. Cache or defer this
   work only if opening latency is material with large installed collections.

The Win32 message loop blocks when idle and bounds message draining at 256.
Divider layout is already throttled to roughly 16 ms and unchanged geometry
avoids redundant positioning. WSL discovery runs outside the UI thread with
bounded output and timeout handling. These should be preserved.

## Reproduction and limits

```powershell
zig build -Doptimize=ReleaseFast -Demit-bench
pwsh -NoProfile -File bench/resources.ps1 -Cycles 20
pwsh -NoProfile -File test/windows/settings-smoke.ps1 -RenderingChecks
zig build test -Dtest-filter=windows -Dtest-filter=compression -Dtest-filter=grapheme
```

The resource runner prints its artifact directory containing configuration,
stderr phase traces and JSON samples. Use `bench/performance.ps1` for saved
corpus benchmarks and `bench/photon-bench.ps1` for composed-screen latency.
This audit does not establish physical input-to-photon latency, an overnight
leak bound, discrete GPU allocation totals, or parity across Intel/AMD/NVIDIA
drivers. DXGI remains opt-in and needs a separate matched measurement series.
