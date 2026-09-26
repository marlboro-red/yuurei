# Windows Terminal performance follow-up

Implemented follow-up: [drawable parking, Unicode row copies and the overlapped-read experiment](PERFORMANCE_PRIORITIES_2026-09-26.md).

The [initial comparison](PERFORMANCE_WINDOWS_TERMINAL_2026-09-26.md) identified
two Windows Terminal advantages: private commit and bulk-output throughput.
This investigation isolates both on the same machine and matched profiles.
Raw trials, executable hashes, thread inventories and standalone graphics
experiments are preserved in
[the research data](performance-windows-terminal-research-2026-09-26.json).

## Final default build

The final build keeps the default pipe capacity, 128 KiB reads, 256 KiB
initial worker-stack commits, two render workers and scrollback compression.
Diagnostics were off. Values below compare the original baseline medians
with one final confirmation run; the controlled repetitions follow below.

| Metric | Yuurei before | Yuurei final | Windows Terminal baseline |
| --- | ---: | ---: | ---: |
| Eight tabs, private commit | 433.86 MiB | 368.62 MiB | 177.30 MiB |
| Eight tabs, resident working set | 132.17 MiB | 134.30 MiB | 141.23 MiB |
| ASCII producer writes | 56.89 ms | 29.26 ms | 30.17 ms |
| Colored producer writes | 120.79 ms | 65.48 ms | 70.18 ms |
| Unicode producer writes | 202.12 ms | 128.88 ms | 64.54 ms |
| Typing capture median | 18.28 ms | 18.27 ms | 33.19 ms |
| Typing capture p95 | 19.10 ms | 19.15 ms | 34.52 ms |

The final output suite consumed 2.42 terminal CPU-seconds versus 3.05 in
the original sampled Yuurei suite and 1.11 for Windows Terminal. This is a
whole-suite observation, not an isolated parser benchmark. All 40 final
typing samples completed without skips or timeouts. The resident-memory
result is essentially unchanged; the memory improvement is private commit.

## Worker stacks: reduce initial commit, retain growth

The installed Zig 0.16 Windows thread implementation passes `stack_size` to
`NtCreateThreadEx` as initial commit. The executable's default reservation
remains 16 MiB. Yuurei previously committed 4 MiB for every worker: two
render workers plus sixteen I/O workers at eight tabs.

Read-only `VirtualQueryEx` and thread-environment-block inventories found
73.51 MiB committed to Yuurei stacks versus 4.85 MiB in Windows Terminal.
With initial commit reduced to 256 KiB, Yuurei's measured stack commit after
the output workload was 7.93 MiB. Some workers grew beyond 256 KiB, while
their total reserved allocation remained 16 MiB. Eight-tab process commit
fell from roughly 434 MiB to 365–370 MiB. This chiefly saves commit budget;
it does not imply an equivalent reduction in resident RAM.

A dedicated ReleaseFast test touches a volatile 2 MiB stack frame on a
worker, verifying growth beyond the initial commit. This follows Windows'
[documented distinction between reserved and committed stack memory](https://learn.microsoft.com/en-us/windows/win32/procthread/thread-stack-size).

## Output: batching was a real bottleneck

Yuurei read only 1 KiB per synchronous `ReadFile`. Each read also parses,
locks shared terminal state and notifies the renderer. Windows Terminal
1.24.11911.0 uses a 128 KiB buffer and an overlapped pipe, issuing the next
read before processing the previous batch. See the pinned
[ConPTY connection implementation](https://github.com/microsoft/terminal/blob/v1.24.11911.0/src/cascadia/TerminalConnection/ConptyConnection.cpp#L744).

Controlled trials used the same experimental executable, the original pipe
capacity, and an override selecting the read length. Aggregate diagnostic
counters covered 82,801,086 bytes per trial, including workload warmups.

| Read length | Read calls | ASCII median | Color median | Unicode median |
| --- | ---: | ---: | ---: | ---: |
| 1 KiB | 81,241 | 57.67 ms | 121.65 ms | 202.32 ms |
| 16 KiB | 6,037 | 47.44 ms | 101.21 ms | 190.86 ms |
| 64 KiB | 2,012 | 29.75 ms | 65.51 ms | 169.79 ms |
| 128 KiB | 1,241 | 29.12 ms | 65.24 ms | 125.55 ms |

These are medians of three producer-write measurements per corpus after
one warmup. They measure the console pipeline and backpressure, not pure
parser speed or final displayed pixels. Diagnostic timing was enabled for
this table. Aggregate parsing time stayed around 0.81–0.84 seconds; mutex
wait was just 0.1–2.1 milliseconds. This supports larger reads, not a mutex
rewrite. Reads return available bytes without waiting to fill the buffer.

A separate 128 KiB trial with diagnostics off and compression on measured
28.41/65.97/133.31 ms for ASCII/color/Unicode, with 18.20 ms median typing
capture latency and 19.08 ms p95 (40 samples, no skips or timeouts).
Original comparison medians were 56.89/120.79/202.12 ms for Yuurei and
30.17/70.18/64.54 ms for Windows Terminal. ASCII and colored output are
now competitive on this workload; Unicode retains a substantial gap.

Increasing the pipe capacity itself from the system default to 128 KiB
yielded 28.55/65.52/124.79 ms in one follow-up trial. ASCII/color were
essentially unchanged and Unicode remained within the earlier trial range.
The pipe retains its system default; the supported improvement is read
batching. The final binary is validated separately after reverting this
experimental capacity change.

Disabling scrollback compression at the same 128 KiB read size did not
improve total CPU meaningfully: 2.36 versus 2.33 CPU-seconds for the whole
suite, including warmups and settles. It increased post-output resident
memory by about 5 MiB. Compression remains enabled. Renderer-worker CPU
includes compression and driver work, so thread names alone do not isolate
GPU rendering costs.

## Graphics: the largest remaining memory opportunity

A standalone WGL probe reproduces substantial private commit without a
terminal parser, scrollback or shell. With two workers, eight contexts and
1600 × 1200 drawables it reached 307.96 MiB private commit. Omitting shader
compilation barely changed it (305.27 MiB). Using 400 × 300 drawables reduced
it to 134.03 MiB. Drawable dimensions matter much more than these programs.

Keeping contexts and programs, but resizing inactive drawables to 64 × 64
and performing a clear/present on their owning worker, reduced eight-context
commit to 190.29 MiB: about 118 MiB less than the full-size probe. Resident
working set increased from 98.81 to 107.61 MiB, so this is specifically a
commit result. Resizing actual Yuurei hidden host windows without presenting
barely changed commit (368.87 to 366.87 MiB). Native resize alone is not a
validated fix.

This is a promising prototype, not a promised application saving. Driver
allocations and caching are opaque, GPU allocations are not accounted for,
and results may differ on Intel/AMD or another NVIDIA driver. Microsoft has
also historically discussed per-context costs and renderer consolidation in
[its memory investigation](https://github.com/microsoft/terminal/issues/15186);
that discussion is context, not evidence about this installed release.

## Implementation priorities

1. **Park inactive drawables through the renderer.** Order the resize and
   small presentation on the owning render worker, retaining context and
   shaders. Restore drawable dimensions and render a complete frame before
   showing the surface. Preserve the terminal/ConPTY cell grid. Validate fast
   tab switching, splits, zoom, tear-off, custom shaders, DPI changes, monitor
   disconnect/reconnect and shutdown while busy. Measure both switching tails
   and memory on multiple GPU vendors before enabling this by default.
2. **Profile the remaining Unicode workload by function.** Separate decoding,
   width/grapheme handling, complex cells, scrollback compression and rendering.
   Ghostty already has SIMD and printable-run paths; adding a generic “SIMD
   optimization” is not a diagnosis. Preserve Unicode correctness and exercise
   existing parser tests/fuzzing for any changes to shared upstream code.
3. **Evaluate overlapped reads only against the improved baseline.** Windows
   Terminal pipelines reads and processing; Yuurei still uses synchronous
   reads. A bounded double-buffer prototype may help if profiles show stalls.
   Cancellation, shutdown, backpressure and foreground input latency must stay
   correct. Avoid unbounded queues that trade speed for memory growth.
4. **Consider one presentation target per window or a D3D backend later.**
   These may remove per-surface driver costs but have a much larger validation
   surface. First establish how much inactive drawable parking recovers.

Windows Terminal's
[text buffer](https://github.com/microsoft/terminal/blob/v1.24.11911.0/src/buffer/out/textBuffer.cpp#L112)
reserves address space and commits incrementally. Ghostty also allocates
terminal pages lazily; these measurements do not justify replacing its core
buffer. Its existing
[printable-run parser](https://github.com/microsoft/terminal/blob/v1.24.11911.0/src/terminal/parser/stateMachine.cpp#L1976)
is useful for comparison, not proof of where Yuurei spends time.

## Reproduction and limitations

Validation included a ReleaseFast application build, 119 passing targeted
Windows/OpenGL/shader tests (one skipped), and a separate ReleaseFast stack
growth test. The repository's normal test executable uses Debug regardless
of the application's optimization setting. Native settings/graphics stress
also passed with eleven surfaces, shader reloads, Unicode output, four busy
splits and closing surfaces under load.
The final defaults also passed twenty cycles each of tab creation/closure,
shell exit, settings and inspector opening/closure, followed by successful
graceful process exit. This checks lifecycle behavior; it is not a long-run
leak bound. Implementation commits are `4b0e5d809` (stack commitment) and
`608655fcb` (read batching).

Use `bench/compare-windows-terminal.ps1` serially with builds and other GUI
tests. `GHOSTTY_PTY_READ_KIB=1|4|16|64|128` selects the bounded Windows read
length; unset uses 128 KiB. `GHOSTTY_IO_STATS=1` logs aggregate per-reader
timings at shutdown. Leave it unset for final timings. Optional
`-YuureiConfig 'scrollback-compression=false'` makes the compression control.
`bench/windows-memory-map.py PID` inventories committed regions and stacks
without recording terminal contents.

The graphics control is `python bench/wgl-memory.py --pool-size 2 --count 8
--width 1600 --height 1200 --shaders --detach`; add `--shrink-inactive` for the
parking prototype. These are separate processes, not application modes.

Measurements use one Windows/NVIDIA system with existing user applications
open. Private commit is not resident RAM; summed process working sets are
not unique physical memory. Software typing capture includes compositor and
capture timing and is not physical input-to-photon latency. Small sample
counts establish useful directions, not universal rankings or tail guarantees.
