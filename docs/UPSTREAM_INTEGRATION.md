# September 2026 Ghostty integration

Integration branch: `integration/ghostty-2026-09`. Release branch: `main`.

This integrates upstream `82938b633` (September 6) from common ancestor
`4c725242b` (July 24). The initial audit counted 1,061 upstream-only commits
and 200 fork-only commits. The safety backports and v0.2.14 release preparation
were subsequently added to main before this integration began.

The integration is intentionally separate from v0.2.14. Do not publish its
binary as that release or merge it into main solely because it compiles.

## Reconciliation

- Preserve Yuurei's Windows app runtime, ConPTY and default-terminal binaries,
  branding, release workflow, and Windows CI. Keep removed upstream-only
  workflows removed.
- Combine upstream's animation scheduling with Windows wait-before-sampling
  frame pacing, including draw-only animation paths.
- Preserve mailbox wakeups during visibility changes while adding upstream
  visibility reports.
- Keep changed-span cell uploads, atlas dirty-row uploads, cached font
  metadata, asynchronous WSL discovery, and compression continuation caching.
- Adapt cursor-layer comparisons to upstream's foreground row storage.
- Retain search-query coalescing and selection barriers on TerminalSearch;
  adapt the stale-screen-selection regression to its new API.
- Adapt Windows text paste and OSC 52 reads to structured clipboard results.
  Unsupported Kitty clipboard requests and MIME listings return unsupported
  without taking request ownership. Denied OSC 52 reads use the core denial
  response. Native paste protection remains in place.
- Append ConPTY mode 9001 after upstream modes to preserve upstream mode-bit
  ordering. Portable v1 snapshots retain the upstream 43-bit wire registry;
  ConPTY transport negotiation is not serialized. Golden-fixture and explicit
  transport-mode exclusion tests cover this boundary.
- Keep Zig 0.16.0. Adopt upstream dependencies, and keep sanitizer flags on
  C compilation rather than passing them to the new Aro header translator.

## Release safety backports

Before tagging v0.2.14, three upstream regression cases reproduced crashes
in the fork, in both libghostty-vt test configurations. Main now includes:

- `33d34cf5c`: prevent VS15 cursor underflow.
- `33cda4dc5`: reload grapheme cell pointers after page growth.
- `9313d580c`: migrate cursor style/hyperlink references on scroll clear.
- `2f7fbadb0`: release discarded I/O message allocations, with additional
  allocator-backed write and mailbox teardown tests.

The release's portable x86_64_v2 ReleaseFast build, version smoke check,
111-test combined Windows regression run, and targeted libghostty-vt tests
passed locally before tagging. The release pipeline also runs the full core
suite before publishing its ZIP and checksum.

## Integration validation and remaining checks

ReleaseFast application and benchmark builds pass. The full Windows suite
passed 3,736 tests with 80 skipped; subsequent clipboard-capability and
reserved snapshot-bit tests passed in targeted runs. Targeted libghostty-vt
tests cover the crash backports, compression traversal, and TerminalSearch.
Hidden-window Unicode and color-output smoke runs exited with code 0 using
vendored ConPTY and OpenGL, including opt-in DXGI flip presentation. These
are lifecycle checks, not visual or latency measurements.

Manual testing exposed unresponsive native caption buttons when maximized.
The window returned HTCAPTION across all three buttons when DWM declined
hit testing. A TITLEBARINFOEX bounds fallback now returns the native button
codes and leaves native press tracking to Windows. The targeted caption
test run passed all 75 tests, and the ReleaseFast build passed. Live probes
at 200% scaling confirmed minimize, maximize, and close hit codes while
adjacent title-bar space remained draggable. Automated mouse clicks could
not obtain foreground/pointer control, so visual hover and physical clicks
still need manual confirmation.

The v0.2.14 release workflow completed successfully. Its published ZIP was
downloaded, checked against the published SHA-256, and its packaged executable
passed the version startup smoke check. The upstream integration is not part
of that release and remains local, unmerged into main.

Before merging to main, manually exercise PowerShell, cmd, Git Bash and WSL;
tabs/splits and session restoration; clipboard allow/deny flows; resize and
mixed-DPI movement; IME; and animated Kitty images/custom shaders across
hide/show transitions. Test both presentation modes on representative GPUs.
macOS and GTK builds were not validated on this Windows machine.

Windows continues to expose only its existing text clipboard support. The
new upstream Kitty clipboard protocol and editor-backed config-window mode
are not claimed as implemented Windows features.
