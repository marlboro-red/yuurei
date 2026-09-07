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
compression timings: runtime compression currently reports zero compressed
pages on Windows because retained-mapping reclamation is unsupported there.

`+terminal-stream --chunk-size=1024` matches the Windows read-buffer ceiling;
the default is 65536. Differences include file-read overhead, so they do not
by themselves establish an end-to-end ConPTY batching benefit.

With `GHOSTTY_PERF_TRACE=1`, native I/O logs separate parsing from mutex wait
time. Shaping logs report cache hits, misses, and evictions; DXGI logs report
frame-wait failures and timeouts. Keep tracing off for ordinary timing runs.
