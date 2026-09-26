# Latency benchmark harness

A software "photon proxy" for measuring keyboard-to-pixels latency of any
terminal window, with no external hardware. It injects a keystroke at a
precise instant and polls a small screen region in a tight loop until the
pixels change, reporting the elapsed time. Because the capture reflects
the composed desktop, the number approximates keyboard-to-photon latency
minus physical scanout — and, crucially, it is measured identically across
terminals, so cross-terminal comparisons are apples-to-apples.

This is the harness that caught the libxev wakeup-loss bug (yuurei was
measuring ~433 ms median against Windows Terminal's ~17 ms; see
`WINDOWS_PORT_PLAN.md`). Keep it around — latency regressions are easy to
introduce and hard to feel reliably by hand.

## Scripts

- **`bench-setup.ps1`** — launch an exe, find its top-level window by class,
  move it to a fixed rect. Returns `HWND=... PID=...`.
- **`bench-shot.ps1`** — move a window to `(100,100,1000,600)` and screenshot
  that screen rect to a PNG, so you can read off the pixel coordinates of the
  echo cell for `-RegionX/-RegionY`.
- **`photon-bench.ps1`** — the measurement. Foregrounds the target, injects
  `a` via `keybd_event` (real input; conhost accepts posted messages but
  Windows Terminal and yuurei need real input + foreground), polls the region
  until any pixel differs, records the delta, backspaces, repeats. Reports
  successful samples, focus skips, timeouts, median, p95, and p99. `-Json`
  preserves the unrounded samples in collection order.

## Usage

```powershell
# 1. Launch the terminal you want to measure, note its HWND.
#    (Get-Process <name>).MainWindowHandle  — or use bench-setup.ps1.

# 2. Position it and screenshot to find the echo cell coordinates.
powershell -NoProfile -File bench\bench-shot.ps1 -Hwnd <HWND> -Out shot.png
#    Open shot.png; the window is at screen (100,100). Read off where the
#    character will echo (just past the prompt) → RegionX, RegionY.

# 3. Measure.
powershell -NoProfile -File bench\photon-bench.ps1 `
  -Hwnd <HWND> -RegionX 390 -RegionY 300 -RegionW 400 -RegionH 50 `
  -Samples 100 -Label "yuurei"
```

### Avoiding a phase-locking artifact

`-SettleMs` (default 600) is the pause before each sample. If the terminal
only repaints on a periodic timer (the exact bug this harness found), a
settle interval near that timer's period makes every keystroke land at the
same phase and the median looks artificially stable. Always sanity-check a
result by re-running with a different `-SettleMs` (e.g. 600 and 950); a
correctly wake-driven terminal returns the same median at both.

## Reference numbers (this machine: 4K @ 60 Hz)

| Terminal              | median key-to-pixels |
|-----------------------|----------------------|
| Windows Terminal + WSL| ~16.9 ms             |
| yuurei (after fix)    | ~17 ms               |
| yuurei (before fix)   | ~433 ms              |

These are historical software-capture measurements, not a physical scanout
measurement or proof of a latency floor. Compare latency distributions under
the same capture, display, focus, and workload conditions.

The harness adds deterministic settle jitter (`-JitterMs`, default 100) to
avoid repeatedly sampling one timer phase. Capture a tight echo region and
exclude a blinking cursor or animation with `-IgnoreX/-IgnoreY/-IgnoreW/-IgnoreH`
(coordinates relative to the region). `-MinChangedPixels` rejects small pixel
changes. These controls do not automatically distinguish echoed text from all
unrelated screen changes; choose the region carefully. Run the comparator's
noninteractive checks with `powershell -NoProfile -File bench/test-photon.ps1`.

## Reproducible throughput comparisons

Build both revisions using Zig 0.16 and `-Doptimize=ReleaseFast -Demit-bench`.
Keep the correct Zig directory first on PATH as build helpers also use it.
Use PowerShell 7 for the throughput runner (including its UTF-8 Unicode
corpus). Generate corpora once outside the repository, before timing:

```powershell
./bench/performance.ps1 -Generate -DataDirectory "$env:TEMP/yuurei-corpora"
./bench/performance.ps1 -DataDirectory "$env:TEMP/yuurei-corpora" `
  -Baseline C:/baseline/ghostty-bench.exe -Candidate ./zig-out/bin/ghostty-bench.exe `
  -OutputJson "$env:TEMP/yuurei-comparison.json"
./bench/performance.ps1 -DataDirectory "$env:TEMP/yuurei-corpora" `
  -Candidate ./zig-out/bin/ghostty-bench.exe -ChunkSizes
```

The runner alternates binary order, uses two warmups and nine measurements,
and records corpus hashes and raw wall-time samples. Do not run benchmarks
alongside builds or other benchmarks. Full-process times include startup and
file I/O; the compression `noop` case provides a setup comparison. Run
`+scrollback-compression --mode=report --data=<corpus>` before interpreting
compression timings. Current upstream supports retained-mapping reclamation
on 64-bit Windows through `DiscardVirtualMemory`. This can reduce resident
memory while retaining the mapping's private commit charge; inspect both
working set and private bytes instead of treating them as interchangeable.

`+terminal-stream --chunk-size=1024` matches the Windows read-buffer ceiling;
the default is 65536. Differences include file-read overhead, so they do not
by themselves establish an end-to-end ConPTY batching benefit.

With `GHOSTTY_PERF_TRACE=1`, native I/O logs separate parsing from mutex wait
time. Shaping logs report cache hits, misses, and evictions; DXGI logs report
frame-wait failures and timeouts. Keep tracing off for ordinary timing runs.

## Windows resource lifecycle

Run `pwsh -NoProfile -File bench/resources.ps1 -Cycles 20` against a ReleaseFast
build. It uses an isolated config and reports one/eight tabs, repeated tab
closure, normal shell exits, settings and inspector churn, and minimized
windows. CPU is expressed as a percentage of one core. The printed artifact
directory contains raw JSON and startup traces. Surface counts are checked
before accepting closure measurements. Run serially with other benchmarks;
its measurements exclude child processes and dedicated GPU allocations.

For a shorter per-tab comparison, run:

```powershell
pwsh -NoProfile -File bench/resources.ps1 -TabsOnly -SwitchSamples 30 -Width 1600 -Height 1200
pwsh -NoProfile -File test/windows/settings-smoke.ps1 -GraphicsStress
python bench/wgl-memory.py --count 8
python bench/wgl-memory.py --count 8 --shaders --detach
```

Specify both dimensions in physical pixels, or omit both to use the default
window size. The JSON records dimensions, executable hash and samples.
Tab timings span posted-key handler dispatch to the first traced present;
they exclude message queue delay and physical scanout. The short-run p95 is
descriptive, not a statistically established bound. `-ProbeHiddenHosts` is an
optional experiment that temporarily shrinks only the isolated process's
hidden terminal HWNDs, then restores their sizes.

`wgl-memory.py` isolates process memory used by separate WGL contexts on
worker threads, without terminal state. It uses hidden 1200 x 800 windows
and optionally compiles the built-in shaders. `--core` requests OpenGL 4.3
core; `--release-compiler` tests the driver hint. This is a driver-cost probe,
not an exact model of Yuurei or a dedicated-VRAM measurement. Run variants
serially and warm shader caches before comparing them.

`-GraphicsStress` adds custom shader reloads, eleven surfaces, tab switching
and 20,000 Unicode/ANSI output lines to the native settings checks. Completion
assertions check process and command progress; inspect the captures separately
before claiming rendering correctness. With `GHOSTTY_PERF_TRACE=1`, lifecycle
logs also report process-wide private commit and working set around startup,
shader initialization and frame-resource release. Concurrent allocations make
these stage samples unsuitable as exact per-object accounting.

Use `resources.ps1 -TabsOnly -ShaderWorkload -SwitchSamples 30` to exercise
two custom-shader passes. This catches retained ping-pong textures that the
plain-terminal workload does not allocate. Warm each executable once before
comparing it, and run all builds, GUI checks and measurements serially.

The WGL probe can separate inactive context and worker lifetimes:

```powershell
python bench/wgl-memory.py --shaders --detach --retire-inactive
python bench/wgl-memory.py --shaders --detach --retire-inactive --exit-retired-workers
python bench/wgl-memory.py --shaders --detach --retire-inactive --exit-retired-workers --retain-retired-contexts
```

Each variant retains the native windows. The first deletes old contexts but
keeps their workers alive; the second also ends those workers; the third
ends the workers while retaining their unbound contexts and GL objects.
These are isolated prototypes, not application modes or tab-switch benchmarks.
The native smoke runner now checks the known terminal background and text
pixels in composed-screen captures, including restoration after shader stress.
