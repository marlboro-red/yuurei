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
  `n`, `skipped`, `median`, and the sorted samples.

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
  -Samples 15 -Label "yuurei"
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

~16–17 ms is the one-vblank compositor floor at 60 Hz; both terminals hit
it, so they are at parity. There is no more latency to extract on this
display without GPU-bypass tricks that camera studies show make typing
*worse*, not better.
