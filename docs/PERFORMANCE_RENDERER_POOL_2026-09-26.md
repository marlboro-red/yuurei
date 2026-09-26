# Windows renderer worker pool

Yuurei now shares rendering across at most two Windows workers by default,
instead of creating a renderer thread for every terminal surface. Each
surface retains its own WGL context, shaders, mailbox and timers. Contexts
stay assigned to one worker, which restores the surface's thread-local GL
dispatch table before accessing its graphics resources. Other platforms
retain dedicated renderer threads.

Workers are created lazily and live until application shutdown. A single
terminal starts one worker; the second starts when another surface needs it.
New surfaces go to the least populated worker. A worker processes at most
64 mailbox messages per callback before yielding to other surfaces.

Closing a surface disarms its async notifications, cancels its timers and
waits for all callbacks and cancellation completions to drain before freeing
graphics resources and surface memory. The shared loop itself stays alive
for other surfaces. Application shutdown joins the workers after closing
all surfaces. Surface initialization also unwinds started I/O and renderer
workers if a later initialization step fails.

## Measured result

Matched serial runs used the same ReleaseFast executable, a 1600 × 1200
window and three-second sampling intervals. The only mode difference was
`GHOSTTY_RENDER_WORKERS=0` versus `2`.

| Eight idle tabs | Dedicated threads | Two workers |
| --- | ---: | ---: |
| Private commit | 570.64 MiB | 434.33 MiB |
| Resident working set | 222.60 MiB | 128.47 MiB |
| Total process threads | 42 | 30 |
| Handles | 665 | 499 |
| Private commit after 30 tab switches | 593.72 MiB | 430.32 MiB |
| Working set after 30 tab switches | 242.77 MiB | 126.41 MiB |
| Switch dispatch-to-present median | 6 ms | 6 ms |
| Switch dispatch-to-present p95 | 8 ms | 12 ms |

At eight tabs, private commit fell 23.9% and resident memory fell 42.3%.
These are additional savings over the earlier memory fixes. Total process
threads include driver and I/O threads; the renderer count itself falls from
eight to two. Single-tab working set was 72.70 versus 73.18 MiB, with 14
threads in both modes; single-tab private commit was 142.82 versus 150.61
MiB. The optimization primarily benefits multiple surfaces.

A prior run with three background output producers measured 588.00 versus
451.66 MiB private commit and 245.23 versus 151.64 MiB working set at eight
tabs. Both modes had a 6 ms median switch time. This is a responsiveness
stress result, not an equal-output memory or throughput comparison.

Raw results, executable hashes and timing samples are in
[performance-renderer-pool-2026-09-26.json](performance-renderer-pool-2026-09-26.json).

## Validation

The ReleaseFast build and targeted Windows/OpenGL/Shadertoy tests passed
(118 passed, one skipped). Native graphics stress exercises eleven surfaces,
custom shader reloads, repeated tab switches, 20,000 Unicode/ANSI lines,
four simultaneously busy splits and closure while output is arriving.
Pixel assertions check terminal rendering and progress in each busy pane.
The complete stress suite passed with both two workers and one worker.

The lifecycle runner passed 20 tab create/close cycles, 20 normal shell-exit
cycles, 20 settings cycles, 20 inspector cycles, minimize/restore and clean
final-window shutdown. Workers and driver caches remain alive after tabs
close, so returning to one tab does not imply returning to its startup
memory footprint.

## Configuration and limits

`GHOSTTY_RENDER_WORKERS=0` restores a dedicated renderer thread per surface.
Values `1` through `4` select a pool size; the default is `2`. This diagnostic
override must be set before launching Yuurei. Benchmark and smoke runners
accept the equivalent `-RendererWorkers` argument.

Terminals assigned to one worker share its rendering time. A costly shader,
driver call or frame-latency wait can delay other surfaces on that worker.
The busy-pane check establishes continued progress, not frame-rate parity
under every workload. Cross-driver behavior, overnight monitor disconnects,
DXGI presentation and long-duration stability need separate validation.

Measurements include Yuurei process private commit and resident working set,
excluding child shells and dedicated GPU allocations. Posted-key dispatch
to first presentation is not physical input-to-photon latency. Short-run
percentiles are descriptive, not established latency bounds. Background
output grows terminal history, so those samples do not establish equal-work
CPU throughput.

## Reproduction

Run these serially on the same ReleaseFast executable:

```powershell
pwsh -NoProfile -File bench/resources.ps1 -TabsOnly -RendererWorkers 0 -SwitchSamples 30 -IdleSeconds 3 -Width 1600 -Height 1200 -GracefulExit
pwsh -NoProfile -File bench/resources.ps1 -TabsOnly -RendererWorkers 2 -SwitchSamples 30 -IdleSeconds 3 -Width 1600 -Height 1200 -GracefulExit
pwsh -NoProfile -File bench/resources.ps1 -RendererWorkers 2 -Cycles 20 -IdleSeconds 2 -GracefulExit
pwsh -NoProfile -File test/windows/settings-smoke.ps1 -GraphicsStress -RendererWorkers 2
pwsh -NoProfile -File test/windows/settings-smoke.ps1 -GraphicsStress -RendererWorkers 1
```
