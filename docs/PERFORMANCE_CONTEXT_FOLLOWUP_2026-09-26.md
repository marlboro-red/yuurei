# Windows graphics memory follow-up — 2026-09-26

This continues the [performance audit](PERFORMANCE_AUDIT_2026-09-26.md).
The machine, driver and ReleaseFast configuration are unchanged. Measurements
exclude shells and dedicated GPU allocations; private commit is not resident
RAM. Raw samples and executable hashes are in
[the accompanying JSON](performance-context-followup-2026-09-26.json).

## Fixed: pipelines retained deleted frame resources

`65a48f4a7` clears framebuffer texture attachments and vertex-array buffer
bindings when releasing a hidden tab's frame set. Pipelines survive across
tab switches, so deleting the frame's textures and buffers did not release
their storage while those container objects still referenced them. This is
the lifetime behavior specified in OpenGL's
[deleted-object rules, section 5.1](https://registry.khronos.org/OpenGL/specs/gl/glspec43.compatibility.pdf).

The fix runs on the renderer thread with its context current, after frame
completion and resource deletion, before the existing flush. It retains the
linked programs and pipeline objects. Drawing binds new frame resources on
the next visible frame. No context destruction or additional completion wait
is introduced.

Two passthrough shader passes exercise both intermediate textures. Warm,
serial runs used eight tabs at 1600 x 1200 physical window pixels, three-second
sampling intervals and thirty tab switches:

| Phase | Before private MiB | After private MiB | Before working MiB | After working MiB |
| --- | ---: | ---: | ---: | ---: |
| One tab | 164.51 | 165.26 | 83.34 | 83.28 |
| Eight tabs | 689.55 | 600.55 | 236.67 | 236.71 |
| After 30 switches | 726.58 | 629.23 | 261.81 | 257.72 |

The eight-tab reduction is **89 MiB (12.9%)**, increasing to **97.35 MiB**
after switching. This is a custom-shader workload, not a revision of the
earlier plain-terminal measurement. Working memory was effectively unchanged
before switching. Both idle samples measured zero CPU.

Median dispatch-to-present time was 9 ms in both runs. The observed p95 was
14 ms before and 19 ms after; this short sample cannot establish latency
equivalence or a reliable tail-latency regression. These timings exclude
message queue delay and physical scanout. Shader cache warmup runs and one
trial overlapping GUI checks were excluded from the comparison.

A separate plain-terminal comparison showed effectively unchanged memory:
eight tabs measured 571.47 MiB before and 570.54 MiB after (working sets
222.41 and 222.50 MiB). After thirty switches they measured 598.23 and
598.80 MiB private commit. Both medians were 6 ms; observed p95 was 15 ms
before and 16 ms after. Do not advertise the custom-shader saving for ordinary
tabs without shaders.

## Prototype: context retirement versus worker lifetime

The standalone WGL probe isolates eight contexts from terminal state. It
retains all eight native windows while varying context and worker lifetimes:

| Variant | Private MiB | Working MiB |
| --- | ---: | ---: |
| All contexts and workers retained | 354.80 | 197.80 |
| Inactive contexts deleted, workers retained | 328.12 | 186.14 |
| Inactive contexts deleted, workers exited | 194.45 | 73.14 |
| Inactive contexts retained unbound, workers exited | 216.93 | 88.94 |

Deleting contexts alone saved only 26.68 MiB. Ending their workers while
retaining the unbound contexts saved 137.87 MiB. This implicates substantial
thread-associated allocations, including driver/runtime state; the experiment
does not separate those from thread stacks or establish application savings.

Do not enable inactive-context destruction based on this result. It would
require reconstructing programs, images and textures on every return for a
modest observed saving when workers remain alive. A Windows renderer-worker
pool that retains contexts is a better next prototype. It must preserve
context exclusivity and thread-local GL dispatch, avoid one busy tab blocking
all others, and retain hidden-tab mailbox/compression processing. The probe
does not yet validate migrating and rendering Yuurei contexts on shared workers.

The subsequent [renderer pool implementation and measurements](PERFORMANCE_RENDERER_POOL_2026-09-26.md)
validate this approach in Yuurei itself and supersede the prototype recommendation.

## Rendering validation

The earlier black/stale captures could not be reproduced in fresh runs of
the same unchanged executable and exact earlier harness. Pre-merge and
post-merge executables also rendered correctly in this session. Temporary
readback confirmed valid terminal pixels in both the render target and the
native backbuffer; that instrumentation was removed. No rendering fix or
causal attribution to the merge is claimed for the intermittent anomaly.

The smoke runner now asserts known terminal background and text pixels in
composed-screen captures. It rejects the archived bad capture and accepts
the current ones. It checks plain rendering, splits, a custom shader, bulk
output and restoration after closing stress surfaces. Process survival alone
no longer constitutes a rendering pass. The bulk-output emitter uses .NET
console output with explicit UTF-8 instead of `cmd / type`, which produced
mojibake in the prior stress workload.

ReleaseFast build and the targeted Windows/OpenGL/Shadertoy suite passed:
118 passed, one skipped. Native settings and eleven-surface shader stress
completed, including repeated reload/switch operations and 20,000 output
lines. Cross-driver behavior and long-duration stability remain unmeasured.

## Reproduction

Run each command serially, warming both binaries before comparing:

```powershell
pwsh -NoProfile -File bench/resources.ps1 -Executable <binary> -TabsOnly -ShaderWorkload -SwitchSamples 30 -IdleSeconds 3 -Width 1600 -Height 1200
pwsh -NoProfile -File test/windows/settings-smoke.ps1 -GraphicsStress
python bench/wgl-memory.py --shaders --detach
python bench/wgl-memory.py --shaders --detach --retire-inactive
python bench/wgl-memory.py --shaders --detach --retire-inactive --exit-retired-workers
python bench/wgl-memory.py --shaders --detach --retire-inactive --exit-retired-workers --retain-retired-contexts
```
