# Performance audit follow-through

September 7, 2026. Baseline: `75945c729`. Windows x64, Zig 0.16.0,
ReleaseFast. Changes are split into local commits; nothing was pushed.

## Implemented

| Area | Change |
| --- | --- |
| Long sessions | Reset the snapshot-retention counter at 100,000 updates instead of destroying the snapshot on every subsequent update. |
| Compression traversal | Resume directly while activity and page generations are unchanged; invalidate cached pointers before destruction. Mutations retain the safe serial-validation fallback. |
| Font discovery | Share family metadata and lazily collected codepoint ranges across grids. Reopen matching fonts, not every known nonmatching candidate. Invalidate on `WM_FONTCHANGE` and reject stale publications. |
| Profiles | Enumerate WSL on a worker, publish on the UI thread, preserve menu indices and palette selection, and restore saved WSL profiles without waiting for enumeration. |
| Cell uploads | Flatten foreground rows into retained storage and upload only the changed byte span. Skip unchanged buffers, including shader-animation frames. Correct buffer element-count accounting. |
| Glyph uploads | Keep a bounded atlas change journal and upload affected full-width row bands. Independent textures retain their own versions; clearing, growth, and lagging readers fall back to full uploads. |
| Redraws | Track rebuilt rows, cursor layers, uniforms, and images instead of marking every update as a cell rebuild. Keep last-target presentation for exposure and resize behavior. |
| Image placement | Recompute virtual Kitty placements on content/image changes rather than unchanged snapshots. |
| Allocation | Retain frame scratch storage with a 256 KiB cap per renderer. |
| Search | Coalesce consecutive superseded queries, free their storage, and preserve selection commands as ordering barriers. |
| Split layout | Skip unchanged host/scrollbar geometry and the associated forced render. Keep existing delayed ConPTY repaint handling. |
| UI scheduling | Limit each Windows message-drain batch to 256 messages before servicing core work. |
| Visibility | Reconcile hidden startup and show/hide events with renderer occlusion; respect zoomed splits when restoring visibility. Avoid DXGI pacing waits on hidden hosts. |
| Diagnostics | Separate parser and terminal-lock wait time; report shaping-cache hits/misses/evictions and DXGI wait failures/timeouts only as appropriate for tracing/diagnosis. |
| Benchmarks | Add deterministic corpora, hashes, alternating binary order, warmups, repeated samples, configurable stream chunk sizes, and a better pixel-comparison harness. |

## Measurements and decisions

The comparison runner used 200,000 lines per corpus, 120 columns by 80 rows,
two warmups and nine measured executions per binary, alternating order.
Numbers below are full-process medians, including startup and file reads.
They do not measure rendering or keyboard-to-pixel latency.

| Corpus | Bytes | Baseline stream, ms | Candidate stream, ms |
| --- | ---: | ---: | ---: |
| ASCII | 15,600,000 | 26.36 | 25.20 |
| Color/SGR | 12,000,000 | 76.78 | 77.48 |
| Unicode | 19,200,000 | 55.10 | 55.16 |

These results do not establish a broad parser-throughput improvement. The
small changes vary by corpus and should not be presented as a universal gain.

The chunk-size experiment produced these candidate medians:

| Corpus | 1 KiB | 4 KiB | 16 KiB | 64 KiB |
| --- | ---: | ---: | ---: | ---: |
| ASCII | 51.34 ms | 33.18 ms | 27.55 ms | 25.73 ms |
| Color/SGR | 96.69 ms | 81.89 ms | 77.07 ms | 75.40 ms |
| Unicode | 89.53 ms | 64.76 ms | 57.07 ms | 55.40 ms |

This includes fewer file reads at larger sizes. It is not evidence that
waiting to batch ConPTY output improves interactive latency or throughput.
A native ASCII smoke run with vendored ConPTY reported roughly 73-byte
average reads, 1–2% of wall time in parsing, and 0% rounded lock-wait time.
The existing immediate-delivery Windows read loop remains unchanged.

**Correction to the initial source audit:** runtime compression is currently
unsupported on Windows. `terminal/mem.zig` enables retained-mapping reclamation
only on 64-bit Linux and Darwin; tests simulate it on other platforms.
`+scrollback-compression --mode=report` confirmed zero compressed pages on
Windows. The traversal fix benefits supported platforms, not Windows today.
Compression timings on this Windows machine must not be interpreted as a
compression speedup. Enabling Windows reclamation is a separate implementation
requiring reserve/commit/restore lifecycle validation.

Keep the current shaping-cache capacity: the numbered output corpus has
mostly unique runs, so a low hit rate alone does not justify retaining more
of them. The new tracing makes representative editor/TUI workloads measurable.

Keep flip-model presentation opt-in and preserve vsync/pacing for visible
windows. A hidden-window flip smoke run exposed repeated 100 ms wait timeouts,
leading to the visibility fix. Neither that run nor the source audit establishes
that removing the intermediate D3D copy, changing the present model, or removing
vsync improves visible latency. GPU timestamp/presentation traces are needed
before redesigning that path.

## Validation and limits

ReleaseFast application and benchmark builds passed. Targeted tests cover
compression and mutation safety, atlas journals, upload ranges, font coverage,
saved profiles, cursor layers, and search coalescing/selection ordering. An
91-test final targeted run passed, in addition to the compression-focused
libghostty-vt tests. Pixel-comparator tests passed without injecting input.

Native hidden-window smoke runs exercised vendored ConPTY, OpenGL, and the
opt-in flip presenter and exited with code 0. These are lifecycle/error checks,
not visual correctness checks or physical latency measurements. Visible-window
typing latency, mixed-DPI multi-monitor behavior, complex IME/image rendering,
and GPU-driver-specific performance still need representative hardware testing.

The final hidden flip-model smoke run reported zero pacing timeouts/failures
and zero error lines, versus 66 wait timeouts in the earlier hidden run.
It performed no shaping work while hidden. Padding-only uniform updates also
explicitly invalidate the draw so unchanged-row detection cannot hide them.

Reproduce the corpus and comparisons with `bench/performance.ps1` as described
in `bench/README.md`. Keep tracing disabled during timing comparisons and run
benchmarks separately from builds. The software pixel harness still requires
a correctly chosen echo region; ignored rectangles and pixel thresholds do
not automatically distinguish every unrelated animation from echoed text.
