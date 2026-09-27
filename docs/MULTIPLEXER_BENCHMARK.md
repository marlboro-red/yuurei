# Native multiplexer benchmark — 2026-09-27

## Follow-up after output and memory fixes

The later comparison uses `33dc97973` plus the memory changes committed with
this report: event-driven wakeups, protected journal cursors, 256 KiB initial
worker stack commits, and temporary page-allocated snapshot buffers. Same
machine and settings, three alternating fresh instances per mode, 20 seconds
idle each, then unpaced ~8 MiB ASCII and Unicode workloads. Raw samples:
`bench/results/mux-2026-09-27-improved.json`.

| Measurement | Direct | Multiplexed |
|---|---:|---:|
| Idle private commit, median | 114.4 MiB | 123.1 MiB |
| Idle resident working set, median | 79.3 MiB | 92.1 MiB |
| Idle CPU, median percentage of one core | 0.31% | 0.39% |
| Input-to-title response, median (60 samples) | 0.59 ms | 0.62 ms |
| Input-to-title response, nearest-rank p95 | 0.70 ms | 0.89 ms |
| Unpaced ASCII, median | 121.9 MiB/s | 95.2 MiB/s |
| Unpaced Unicode, median | 83.7 MiB/s | 59.1 MiB/s |
| Burst completion | 3/3 both workloads | 3/3 both workloads |

Mux commit fell about 46.4 MiB from the original median, reducing the
direct-relative overhead from 55.6 MiB to 8.7 MiB (about 84%). Broker-only
private commit is now about 6.25 MiB. Post-workload median commit was
114.85 MiB direct / 123.70 MiB multiplexed. Resident memory is essentially
unchanged; reducing unused stack/buffer commit does not imply fewer resident
pages. Saturated throughput remains lower: approximately 22% for ASCII and
29% for Unicode in this comparison. Duplicate parsing and transport remain.

The 16 MiB default stack size in Zig 0.16 was committed for each broker worker.
The existing Yuurei 256 KiB worker setting leaves stack growth available; the
dedicated test successfully touched a 2 MiB stack frame. The broker now keeps
only a 1 MiB response buffer and allocates its larger snapshot buffer only
while producing a snapshot. GUI snapshot staging is also page-allocated and
released after decoding, avoiding long-lived heap retention.

Additional suspension checks exercised bounded backpressure. Suspending the
owned GUI for one second held the producer until resume, then completed both
bursts without loss/disconnect. Suspending it for four seconds allowed the
producer to finish after protection expired at three seconds; the resumed
view reported expired history as designed. This prevents a hung view from
permanently blocking its shell, but such a view still needs reopening.

```powershell
pwsh -NoProfile -File bench/multiplexer.ps1
pwsh -NoProfile -File bench/multiplexer.ps1 -Runs 1 -IdleSeconds 1 -SuspendViewMs 1000
# Expected expired-view failure; stall.json confirms producer completed:
pwsh -NoProfile -File bench/multiplexer.ps1 -Runs 1 -IdleSeconds 1 -SuspendViewMs 4000
```

These are short local tests, not proof of long-term stability or physical
keyboard-to-screen latency. The baseline observations below remain for
comparison; their burst failure and polling delay describe the old code.

## Original baseline

Measured commit `384a1181a`, ReleaseFast, portable `x86_64_v2`, on Windows
11 Home 10.0.26200, Ryzen 5 5600X (6 cores / 12 logical processors).
The existing daily-use Yuurei session remained running. These are local
comparisons, not controlled laboratory results or long-term leak tests.

## Results

Three fresh instances of each mode, alternating order. One pane, configured
100×30 cells, font size 12, 1 MiB scrollback in both modes. Multiplexer totals
include GUI plus broker. PowerShell and ConPTY processes are excluded from
the resource totals. Resident totals sum process working sets and may count
shared pages twice. Commit means private committed bytes, not virtual size.

| Measurement | Direct | Multiplexed |
|---|---:|---:|
| Idle private commit, median | 113.9 MiB | 169.5 MiB |
| Idle resident working set, median | 79.3 MiB | 92.2 MiB |
| Threads at idle | 17 | 23 |
| Idle CPU, median percentage of one core | 0.47% | 0.62% |
| Input-to-title response, median | 0.60 ms | 15.51 ms |
| Input-to-title response, nearest-rank p95 | 0.75 ms | 16.10 ms |
| Paced ASCII output | 0.54 MiB/s | 0.54 MiB/s |
| Paced Unicode output | 0.68 MiB/s | 0.68 MiB/s |
| Unpaced ~8 MiB ASCII burst | Completed | Event history expired; view disconnected |

Memory overhead is approximately 55.6 MiB committed (+49%) and 12.9 MiB
summed resident working set (+16%). Idle CPU ranges overlap: direct
0.31–0.62%, multiplexed 0.16–0.78%, measured over 20 seconds per run.
These samples do not establish a meaningful idle CPU regression.

Both modes completed all paced workloads. Aggregate GUI/broker CPU time
was similar: median ASCII 15.63 / 15.64 seconds and Unicode 12.53 / 12.42
seconds for direct / multiplexed. The producer sleeps between blocks;
these rates demonstrate keeping up, not maximum throughput. Windows timer
granularity makes the requested 1 ms sleeps substantially longer here.

Input measurements use a separate run: 20 synthetic F5 presses per fresh
instance, 60 samples per mode. F5 sends `x`; a C# program in PowerShell reads
the key and returns an OSC title marker. A yielding C# loop observes the
window title without sleep-based polling. This measures an application
response path, not physical keyboard-to-pixel latency. The original paced
run's PowerShell sleep-polled latency samples are retained in its raw JSON
but must not be used; timer quantization dominated them.

Two independent unpaced attempts disconnected the multiplexed pane with
`SessionHistoryExpired`. Direct ASCII rates were 101 and 120 MiB/s; Unicode
84 and 76 MiB/s. These measure source bytes through ConPTY to a final GUI
title marker; ConPTY may coalesce output, so they are not parser-only or
frame-presentation throughput. No successful mux burst rate is claimed.

## Implications

The current implementation is not ready to become the default. Priorities:

1. Prevent a fast producer from permanently disconnecting an attached view
   when the bounded event journal wraps. Preserve detached output draining
   and tracked terminal state while designing recovery/backpressure.
2. Replace the 8 ms output polling with notifications. The measured response
   delay is consistent with polling and Windows timer granularity; isolate
   its contribution by repeating this benchmark after the change.
3. Profile broker allocations and duplicate terminal state before reducing
   memory. Increasing journal capacity alone would trade memory for a later
   overrun and would not resolve the underlying problem.

## Reproduction

Build both binaries from the same revision, then run sequentially:

```powershell
zig build mux -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
pwsh -NoProfile -File bench/multiplexer.ps1 -ChunkPauseMs 1
pwsh -NoProfile -File bench/multiplexer.ps1 -OutputMiB 0 -IdleSeconds 1
pwsh -NoProfile -File bench/multiplexer.ps1 -Runs 1 -IdleSeconds 1
```

On the original baseline the last command fails upon detecting the burst
disconnect; it passes after the fixes above. The harness creates isolated config and owned test processes;
it does not stop existing user sessions. Raw completed results are in
`bench/results/mux-2026-09-27-{paced,latency}.json`. Logs, failed-run details,
and per-process idle samples remain under `%TEMP%/yuurei-mux-bench/`.
