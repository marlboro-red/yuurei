# Yuurei versus Windows Terminal

Yuurei used slightly less resident memory and responded sooner in the typing
capture test on this machine. Windows Terminal used substantially less private
commit and completed the bulk-output producer writes faster. These results
do not support calling either terminal faster in every workload.

## Setup

- Windows 11 build 26200, Ryzen 5 5600X, NVIDIA RTX 3060 Ti, driver
  32.0.15.6094, 3840 × 2160 display reporting 59 Hz, 200% scaling.
- Yuurei ReleaseFast executable built from `4afb092a9`, default two-worker
  pool and WGL presentation. No performance tracing or custom shaders.
- Windows Terminal 1.24.11911.0, an official portable distribution matching
  the installed version. Its settings were isolated from the user's sessions.
- Both: `cmd.exe /D /Q /K`, Consolas 12, opaque black background, 1600 × 1200
  outer window, 85 × 29 terminal cells and 10,000 scrollback lines. Yuurei's
  byte limit was disabled to make the line limits comparable; its default
  scrollback compression remained enabled.
- Runs were serial, with no concurrent builds or other benchmark sessions.
  Existing user applications remained open. This was not a clean-room system.

The portable distribution and marker behavior are documented by
[Microsoft](https://learn.microsoft.com/en-us/windows/terminal/distributions).
The exact downloaded archive, executable hashes, environment, per-run process
samples and timing samples are recorded in
[the raw results](performance-windows-terminal-comparison-2026-09-26.json).

## Memory

Medians from four fresh process runs per terminal, with three-second idle
sampling intervals. Each new tab ran an initialization script; the harness
checked eight completion records before measuring eight tabs.

| Terminal process metric | Yuurei | Windows Terminal |
| --- | ---: | ---: |
| One tab: resident working set | 76.27 MiB | 95.68 MiB |
| One tab: private commit | 149.33 MiB | 66.13 MiB |
| Eight tabs: resident working set | 132.17 MiB | 141.23 MiB |
| Eight tabs: private commit | 433.86 MiB | 177.30 MiB |
| Eight tabs: threads | 30 | 159 |
| Eight tabs: handles | 549 | 1,592 |
| Eight tabs after output: resident working set | 132.68 MiB | 160.39 MiB |
| Eight tabs after output: private commit | 446.33 MiB | 201.47 MiB |

The after-output rows have two runs per terminal. At eight idle tabs, Yuurei
used 6.4% less resident memory, but about 2.45 times the private commit.
Working set includes resident shared mappings, and private commit is not
physical RAM. GPU allocations are not included. Fewer threads alone does not
establish lower CPU cost or higher throughput.

Both process trees contained eight `cmd.exe` and eight `OpenConsole.exe`
children. In the first full runs, these added roughly 54 MiB and 18 MiB of
private commit respectively for either application. Their working sets were
also similar. The large commit difference is in the terminal processes; it
is not explained by using different shells. Summing working sets would
double-count shared pages, so no unique physical-memory tree total is claimed.

## Typing latency

The final validation captured only the interior of the echoed `a` glyph,
excluding both the old and new bar cursor positions. Before injecting input,
the harness checked that this region stayed black across multiple cursor
phases. Foreground checks guard every sample; all 40 samples per terminal
completed without a focus skip or timeout.

| Key injection to captured character | Yuurei | Windows Terminal |
| --- | ---: | ---: |
| Median | 18.28 ms | 33.19 ms |
| p95 | 19.10 ms | 34.52 ms |

Two earlier runs of 40 samples per terminal measured combined medians of
18.23 and 33.27 ms respectively. Their wider region included the moved
Windows Terminal cursor at its right edge. The final narrower capture
confirmed the same separation using just the character. Both versions of
the measurements are retained in the raw results, with the final validation
reported above.

The benchmark uses real key injection and desktop screen capture, not an
external camera or physical input device. Capture/compositor timing is part
of the result. These are software key-to-pixels measurements, not physical
input-to-photon latency, and 40 samples do not establish long-tail bounds.
They also cannot be compared directly to the earlier 6 ms posted-key
dispatch-to-present tab-switch metric.

## Bulk output

Each corpus contained 100,000 lines. UTF-8 encoding and allocation occurred
before timing. A PowerShell 7.6.6 producer wrote 100 prebuilt blocks to its
standard-output stream and flushed it. There was one warmup plus three
measured iterations per corpus in each of two fresh sessions, giving six
measured samples per corpus per terminal. History and screen were cleared
before each iteration, with a two-second settle afterward.

| Corpus | Bytes | Yuurei median write time | Windows Terminal median write time |
| --- | ---: | ---: | ---: |
| ASCII | 6,900,000 | 56.89 ms | 30.17 ms |
| ANSI-colored text | 5,100,000 | 120.79 ms | 70.18 ms |
| Mixed Unicode and emoji | 8,700,000 | 202.12 ms | 64.54 ms |

Windows Terminal completed these writes about 1.9×, 1.7× and 3.1× faster.
This measures producer completion through each application's console pipeline,
including backpressure and buffering. It is not a pure parser benchmark and
does not time the final pixels appearing. Final screenshots independently
showed the completed Unicode marker in both terminals. Font fallback and
shaping differ between the applications, so these are not identical glyph
rendering workloads.

One paired measurement of terminal-process CPU over the complete output
suite, including warmups and settle periods, was 3.05 CPU-seconds for Yuurei
versus 1.11 for Windows Terminal. This is supporting evidence from one pair,
not a replicated CPU-efficiency result or total process-tree CPU measurement.

## Scope

These measurements cover native CMD input and burst output on one NVIDIA
system. They do not establish behavior in WSL, Claude Code, large multi-pane
TUIs, sustained frame rates, other GPUs, monitor reconnects or overnight use.
The benchmark profiles are deliberately isolated; results are not measurements
of the user's existing configured terminal windows.

Reproduction commands and capture-region requirements are documented in
[bench/README.md](../bench/README.md#windows-terminal-comparison).
