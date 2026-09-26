# Implementing the Windows performance priorities

This follows the [Windows Terminal investigation](PERFORMANCE_WINDOWS_TERMINAL_RESEARCH_2026-09-26.md).
The machine, profiles and measurement limitations remain the same. We tested
three concrete candidates: inactive WGL drawable parking, a targeted Unicode
row-copy optimization, and pipelined overlapped PTY reads.
Raw timings, profiles, corpus definitions and hashes are preserved in
[the results](performance-priorities-2026-09-26.json).

## Final application measurements

Matched profiles on the same final executable, with diagnostics off. Output
figures are medians of three producer-write trials; typing uses forty samples
per mode, all without skips or timeouts. Each resource column is one fresh
launch; separate resource/switch repetitions are recorded below.

| Metric | Parking off (default) | Parking on |
| --- | ---: | ---: |
| Eight tabs, private commit | 368.00 MiB | 225.55 MiB |
| Eight tabs, resident working set | 134.30 MiB | 141.11 MiB |
| After output, private commit | 379.18 MiB | 238.02 MiB |
| ASCII producer writes | 28.79 ms | 29.02 ms |
| Colored producer writes | 65.40 ms | 66.49 ms |
| Unicode producer writes | 110.13 ms | 109.84 ms |
| Typing capture median | 18.32 ms | 18.22 ms |
| Typing capture p95 | 19.07 ms | 18.85 ms |

The previous build's Unicode median was 128.88 ms: this round reduces the
measured pipeline time by about 14.5%. Windows Terminal's earlier matched
baseline was 64.54 ms, so a substantial Unicode gap remains. Parking changes
commit significantly without improving resident memory; it is not needed to
receive the Unicode benefit. Whole output-suite terminal CPU was 2.25 seconds
with parking off and 2.11 with it on, versus 2.42 in the previous build's
sample. These include warmups and settle periods, not just parser work.

## Inactive drawable parking

`GHOSTTY_PARK_DRAWABLES=1` enables an application implementation of the earlier
standalone prototype. Inactive native hosts shrink to 64 × 64. Their logical
terminal size remains unchanged, so background shells are not resized. The
renderer releases frame resources and presents once at the smaller size,
retaining contexts and shader programs. Before re-showing a tab, the UI restores
geometry and the renderer draws/presents a full frame. An epoch on the UI
completion message rejects frames from an earlier visibility transition.

Native resize and rendering are serialized with the existing draw mutex. No
window manipulation runs on the renderer worker. Zoomed tabs retain their
visible split when revisited; layout occurs before the visibility transition.
The option is ignored when flip-model presentation is configured.

The initial application trial measured 269.30 MiB private commit at eight tabs,
falling to 238.80 MiB after forty switches, versus approximately 369 MiB in the
previous unparked build. Resident working set was 137.79 MiB initially and
137.54 MiB after switching: the main saving is commit, not an equivalent amount
of physical RAM. These are native application results, separate from the
earlier standalone WGL estimate.

The first trial's dispatch-to-present median was 11 ms and p95 21 ms. This
trace ends at presentation, before the UI show/compositor step, and must not
be called complete visual switching latency. Parking remains **off by default**:
the memory saving trades against backbuffer allocation and restoration work.
Only the current NVIDIA system has been tested; physical monitor disconnect,
mixed-DPI displays and other GPU vendors still need coverage.

A final same-executable repetition using the resource harness confirmed the
tradeoff: eight-tab commit was 372.19 MiB with parking off and 271.89 MiB on;
after forty switches it was 370.75 versus 244.17 MiB. Dispatch-to-present
median/p95 changed from **5/7 ms to 11/21 ms**. Across the two harnesses the
measured commit saving is roughly 100–140 MiB, with resident memory increasing
by about 7 MiB. Different startup/capture sequences affect driver allocations;
225 MiB should not be treated as a fixed eight-tab footprint.

The expanded native smoke runner checks forty rapidly queued tab switches,
returning to a zoomed split, unzoom, minimize/restore and composed-screen
background/text pixels. Its graphics stress also exercises shader reloads,
eleven surfaces, Unicode output, four busy splits and closing while output
continues. Both the original and expanded runs passed with parking enabled.
The final default-mode stress run also passed. Dedicated-renderer mode passed
the rendering/settings checks, but its forty-switch burst took about 900 ms
to restore: an initial fixed 800 ms assertion failed with no host yet shown.
The correctness check now polls for bounded completion after that initial
wait; this is not evidence of sub-second switching tails under arbitrary load.
With parking enabled, the final build also completed twenty cycles each of
tab creation/closure, shell exit, settings and inspector opening/closure,
then exited gracefully. Driver caches retained some commitment after closing
tabs; this finite lifecycle check is not a long-run leak bound.

## Unicode: specialize grapheme-only row copying

Two independent profiles of the terminal-stream benchmark collected 696 and
678 main-thread leaf samples. `clonePartialRowFrom` accounted for 271 and 258
samples respectively (38–39%). UTF-8 conversion was much smaller. These are
wall-clock instruction samples obtained by briefly suspending only the newly
launched benchmark, not inclusive CPU stacks or inline-function attribution.
The sampler follows Microsoft's
[thread-context requirements](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadcontext)
and resolves matching local PDBs with
[DbgHelp](https://learn.microsoft.com/en-us/windows/win32/debug/retrieving-symbol-information-by-address).
Profiled runs are never used as throughput measurements.

A row with even one combining mark previously used the general managed-cell
copy loop for every cell. A specialized path now handles rows with graphemes
but no styles, hyperlinks or Kitty virtual placeholders. Plain cells copy
directly; graphemes still receive independent destination-owned storage. The
general path remains for other managed rows. Copying stays incremental so a
failed allocation cannot leave unowned source references in later cells.
This optimization is in the shared terminal core; it changes neither Unicode
width/grapheme rules nor the Windows input/rendering behavior.

Five unsampled process runs after one warmup per executable, using identical
pre-generated corpora of one million lines, 85 × 29 cells and 128 KiB chunks:

| Corpus | Before | Candidate | Change |
| --- | ---: | ---: | ---: |
| Mixed Unicode | 723.29 ms | 610.44 ms | 15.6% faster |
| Combining marks | 1,377.93 ms | 1,306.90 ms | 5.2% faster |
| ASCII | 96.01 ms | 95.07 ms | Essentially unchanged |
| CJK | 261.09 ms | 260.54 ms | Essentially unchanged |
| Greek | 174.27 ms | 173.60 ms | Essentially unchanged |
| Emoji | 312.26 ms | 309.67 ms | Essentially unchanged |

These timings include process startup and file IO, but exclude ConPTY,
compression workers and rendering. They establish the benefit in terminal
state processing, not the whole interactive application. The first candidate
passed 648 clone, grapheme, scrolling and print-path tests across the lib-vt
test configurations. Additional coverage checks partial copies with existing
destination graphemes and failure with zero destination grapheme capacity.
The final version passed 97 clone tests, including the allocation-failure
case, and 119 Windows/OpenGL/shader tests (one skipped). These test builds
use Debug; the application and timed benchmark binaries use ReleaseFast.

The final profile collected 554 leaf samples: row copying fell to 115 (21%),
with `printSliceFill` at 105 and `printSlice` at 67. That supports the selected
optimization while showing that printing and row copying still account for
substantial work. It does not justify replacing Unicode rules or
claiming UTF-8 decoding is now the dominant bottleneck.

## Overlapped reads: retain as a research patch

The prototype uses a named ConPTY output pipe with overlapped reads and two
128 KiB buffers. It queues the next read before parsing the previous buffer.
A separate stop event avoids a cancellation race; pending I/O is cancelled
and completion awaited before releasing its buffers. Default-terminal handoffs
retain their existing synchronous handles.

Matched diagnostic runs on the same executable parsed exactly 82,801,086 bytes:

| Metric | Synchronous | Overlapped |
| --- | ---: | ---: |
| Read calls | 1,241 | 1,242 |
| Aggregate parsing time | 804.82 ms | 819.04 ms |
| ASCII producer median | 29.33 ms | 28.85 ms |
| Colored producer median | 67.00 ms | 66.39 ms |
| Unicode producer median | 124.99 ms | 122.60 ms |

A separate overlapped trial without diagnostic counters measured
28.52/65.12/121.87 ms and 2.44 terminal CPU-seconds for the output suite.
The improvement is small compared with run variation and the earlier 1 KiB
to 128 KiB batching improvement. Eight surfaces add sixteen event handles and
up to 2 MiB of bounded reader buffers, plus more cancellation/ownership code.

The normal build therefore retains synchronous reads. The exact experiment
is preserved in [an unapplied patch](../bench/prototypes/windows-overlapped-read.patch)
for future investigation. It passes `git apply --check` against the retained
reader and is deliberately not a shipping feature or supported setting.

## Reproduction

See [bench/README.md](../bench/README.md) for the resource, application comparison,
leaf sampler and terminal-stream comparison commands. Keep builds, profilers,
GUI checks and timing trials serial. Preserve executable and corpus hashes.
The raw results include exact UTF-8 corpus lines and repetition counts; generate
these files before running the timing tool. The retained code changes are
`60512eef0` (optional parking and zoom restoration) and `06fe5e24a`
(grapheme-only copies).
The original user terminal sessions and configurations were not changed.
