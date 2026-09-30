# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## Asynchronous persistent-tab and pane-split startup

Build with the pinned Zig version (0.16.0). Use a matching GUI and broker
from the same build; run the integration test on an isolated Windows desktop:

```powershell
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build test-mux -Dtest-filter="startup" --summary all
pwsh -NoProfile -File test/windows/mux-startup.ps1 -Bin "$PWD/zig-out/bin"
```

Repeat the GUI test with a Debug build. The portable queue tests also run
without the Windows toolchain or project dependencies:

```sh
zig test src/mux/StartupQueue.zig
zig test src/mux/StartupQueue.zig -O ReleaseFast
zig test src/apprt/win32/StartupTarget.zig
zig test src/apprt/win32/StartupTarget.zig -O ReleaseFast
```

The integration fixture isolates its config/registry, delays only its own
brokers using `GHOSTTY_MUX_TEST_STARTUP_DELAY_MS`, and checks:

- an existing window answers bounded `WM_NULL` probes and resizes while a
  new tab or split's broker is starting
- successful output delivery and FIFO publication of repeated/mixed tab and
  split requests, including nonpersistent profiles queued behind a broker,
  preserving split orientation and request-time target/cwd
- tab focus changes, tree rebuilds and zoom do not retarget/hide pending splits
- missing sessions and an absent helper executable show errors without
  launching a fallback shell or breaking the existing tab
- closing during startup removes the unpublished broker/shell, while the
  previously attached persistent session survives
- closing a pending split's target pane or tab cancels only that request; a
  queued ordinary tab still publishes without a zombie pane or broker
- closing at the native-surface-created / not-yet-published boundary also
  cancels tab/split publication (`GHOSTTY_MUX_TEST_CLOSE_ON_PUBLISH`)

The helper-removal case operates on a temporary copy of the installation.
Cleanup only targets this fixture's recorded processes and isolated sessions.
Do not use either test-only environment variable for ordinary usage.

`timing.json` separates UI responsiveness from time to the shell's output
marker. It is a deterministic regression check, not a production speedup
benchmark. For a real comparison, use the same ReleaseFast build, shell,
profile, window dimensions and restoration settings, alternate persistent
sessions off/on, and compare cold launches separately from warm new tabs and splits.
Include both few-session and many-detached-session cases.

Set `GHOSTTY_PERF_TRACE=1` to capture request, broker-ready, attachment-ready,
and publication marks. New async marks include the session ID as `context`
so overlapping requests can be correlated. `new-tab-request-returned` measures
when the message handler is free again; the split equivalent is
`new-split-request-returned`. `mux-tab-published` and `mux-split-published`
record surface publication, not proof of a physically presented frame or a
ready prompt. Initial-window startup, workspace attachment, and existing
session attachment retain their existing paths. Ordinary/profile new tabs
and pane splits share a FIFO preparation queue; each split stays bound to its
original pane identity, even if focus or tree indices change while starting.
Removing that pane (including moving it to another window) cancels the request.
A completed split activates its original tab, focuses the new pane, and exits
zoom so every inserted pane is visible.
