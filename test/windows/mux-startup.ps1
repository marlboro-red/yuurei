#requires -Version 7.4
# Run on an isolated Windows desktop with matching ghostty/yuurei-mux builds.
# The broker's test-only delay begins after publishing its shell/broker PIDs,
# before its listeners start. Initial window creation is intentionally outside
# the responsiveness assertions; this regression covers subsequent new tabs and pane splits.
# Keep the injected delay below the transport's 3000ms handshake deadline.
param(
    [string]$Bin = "$PSScriptRoot/../../zig-out/bin",
    [ValidateRange(1500,2500)][int]$DelayMs = 2000,
    [ValidateRange(100,1000)][int]$ResponseBudgetMs = 500,
    [string]$Artifacts = "$env:TEMP/yuurei-mux-startup"
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'This test requires Windows and an interactive desktop' }
$Bin = (Resolve-Path $Bin).Path
foreach ($file in @('ghostty.exe', 'yuurei-mux.exe')) {
    if (!(Test-Path "$Bin/$file")) { throw "Missing executable: $Bin/$file" }
}
$dir = Join-Path $Artifacts ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir -Force | Out-Null
$metrics = [Collections.Generic.List[object]]::new()
$cases = [Collections.Generic.List[object]]::new()
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MuxStartupNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    static string Class(IntPtr h) { var b = new StringBuilder(128); GetClassName(h, b, b.Capacity); return b.ToString(); }
    public static IntPtr[] Windows(uint pid) {
        var result = new List<IntPtr>();
        EnumWindows((h, p) => { uint owner; GetWindowThreadProcessId(h, out owner); if (owner == pid && Class(h) == "ghostty") result.Add(h); return true; }, IntPtr.Zero);
        return result.ToArray();
    }
    public static IntPtr Palette(uint pid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h, p) => { uint owner; GetWindowThreadProcessId(h, out owner); if (owner == pid && Class(h) == "ghostty-palette") result = h; return true; }, IntPtr.Zero);
        return result;
    }
    public static int Hosts(IntPtr parent) {
        int count = 0;
        EnumChildWindows(parent, (h, p) => { if (Class(h) == "ghostty-host") count++; return true; }, IntPtr.Zero);
        return count;
    }
    public static int VisibleHosts(IntPtr parent) {
        int count = 0;
        EnumChildWindows(parent, (h, p) => { if (Class(h) == "ghostty-host" && IsWindowVisible(h)) count++; return true; }, IntPtr.Zero);
        return count;
    }
    public static string Title(IntPtr h) { var b = new StringBuilder(1024); GetWindowText(h, b, b.Capacity); return b.ToString(); }
    public static bool Ping(IntPtr h, uint timeout) {
        UIntPtr result;
        // WM_NULL is processed by the target UI thread. BLOCK | ABORTIFHUNG |
        // ERRORONEXIT keeps this probe bounded even when a regression hangs it.
        return SendMessageTimeout(h, 0, IntPtr.Zero, IntPtr.Zero, 0x23, timeout, out result) != IntPtr.Zero;
    }
}
'@
[void][MuxStartupNative]::SetThreadDpiAwarenessContext(-4)
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Wait-For([scriptblock]$Condition, [string]$Message, [int]$TimeoutMs = 20000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 40
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMs)
    throw $Message
}
function Probe([IntPtr]$Window, [string]$Phase) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $ok = [MuxStartupNative]::Ping($Window, $ResponseBudgetMs)
    $metrics.Add([pscustomobject]@{phase=$Phase; metric='ui_probe_ms'; value=$timer.Elapsed.TotalMilliseconds; success=$ok})
    Assert $ok "$Phase blocked the UI message pump for at least ${ResponseBudgetMs}ms"
}
function Key([IntPtr]$Window, [int]$VirtualKey) {
    Assert ([MuxStartupNative]::PostMessage($Window, 0x100, $VirtualKey, 0)) 'Could not post key down'
    Assert ([MuxStartupNative]::PostMessage($Window, 0x101, $VirtualKey, 0)) 'Could not post key up'
}
function Mux($Case, [string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new("$($Case.bin)/yuurei-mux.exe")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['LOCALAPPDATA'] = $Case.path
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill(); $process.WaitForExit(); throw "Mux helper timed out: $Arguments" }
        $result = $output.GetAwaiter().GetResult()
        $log = $errors.GetAwaiter().GetResult()
        Add-Content "$($Case.path)/client.log" $log
        if ($process.ExitCode -ne 0) { throw "Mux $Arguments failed: $log" }
        return $result
    } finally { $process.Dispose() }
}
function Sessions($Case) { return @(Mux $Case @('list') | ConvertFrom-Json) }
function New-Case([string]$Name, [string]$ExtraConfig = '') {
    $path = Join-Path $dir $Name
    New-Item -ItemType Directory "$path/ghostty" -Force | Out-Null
    @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Set-Content "$PSScriptRoot/$PID.started" $PID
(Get-Location).Path | Set-Content "$PSScriptRoot/$PID.initial-cwd"
$ownDirectory = New-Item -ItemType Directory "$PSScriptRoot/cwd-$PID" -Force
Set-Location $ownDirectory.FullName
$cwdUri = [Uri]::new($ownDirectory.FullName + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
while ($true) {
    [Console]::Write("`e]7;$cwdUri`a")
    [Console]::Write("`e]2;MUX_STARTUP_READY_$PID`a")
    [Console]::WriteLine("MUX_STARTUP_OUTPUT=$PID 日本語")
    Start-Sleep -Milliseconds 100
}
'@ | Set-Content "$path/worker.ps1" -Encoding utf8
    @"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
working-directory = "$($path.Replace('\','\\'))"
split-inherit-working-directory = true
command = pwsh.exe -NoLogo -NoProfile -File "$($path.Replace('\','\\'))/worker.ps1"
keybind = f1=new_split:right
keybind = f2=new_split:down
keybind = f3=goto_split:previous
keybind = f4=close_tab:this
keybind = f5=new_tab
keybind = f6=goto_tab:1
keybind = f7=goto_tab:3
keybind = f8=goto_tab:4
keybind = f9=toggle_command_palette
keybind = f10=set_tab_title:
keybind = f11=close_surface
keybind = f12=goto_tab:2
keybind = f13=goto_split:left
keybind = f14=goto_split:up
keybind = f15=toggle_split_zoom
keybind = f16=goto_split:right
$ExtraConfig
"@ | Set-Content "$path/ghostty/config" -Encoding utf8
    $case = [pscustomobject]@{name=$Name; path=$path; bin=$Bin; helper_backup=$null; gui=$null; owned=[Collections.Generic.List[Diagnostics.Process]]::new()}
    $cases.Add($case)
    return $case
}
function Launch($Case, [int]$Delay = $DelayMs, [string]$CloseOnPublish = '') {
    $Case.gui = Start-Process "$($Case.bin)/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{
        LOCALAPPDATA=$Case.path; XDG_CONFIG_HOME=$Case.path; GHOSTTY_NEW_INSTANCE='1'
        GHOSTTY_MUX_TEST_STARTUP_DELAY_MS="$Delay"; GHOSTTY_PERF_TRACE='1'
        GHOSTTY_MUX_TEST_CLOSE_ON_PUBLISH=$CloseOnPublish
    } -RedirectStandardError "$($Case.path)/gui.log"
    Wait-For { [MuxStartupNative]::Windows($Case.gui.Id).Count -eq 1 } "$($Case.name): window missing"
    $window = [MuxStartupNative]::Windows($Case.gui.Id)[0]
    [void][MuxStartupNative]::ShowWindow($window, 5)
    [void][MuxStartupNative]::SetWindowPos($window, 0, 80, 80, 1100, 800, 0x14)
    return $window
}
function Hold-SessionProcesses($Case, $Session) {
    foreach ($processId in @($Session.broker_pid, $Session.shell_pid)) {
        $process = [Diagnostics.Process]::GetProcessById($processId)
        # Open a handle now so later exit checks cannot mistake PID reuse for
        # a leaked test process. Cleanup only touches these test-owned handles.
        [void]$process.Handle
        $Case.owned.Add($process)
    }
}
function Wait-Pending($Case, [IntPtr]$Window, [string[]]$PreviousNames, [int]$HostCount, [string]$Phase) {
    Wait-For {
        Probe $Window $Phase
        @(Sessions $Case | Where-Object { $_.name -notin $PreviousNames }).Count -gt 0
    } "$Phase did not create a pending broker"
    $pending = @(Sessions $Case | Where-Object { $_.name -notin $PreviousNames })
    Assert ($pending.Count -eq 1) "$Phase did not create exactly one broker for its request"
    Hold-SessionProcesses $Case $pending[0]
    Assert ([MuxStartupNative]::Hosts($Window) -eq $HostCount) "$Phase exposed a surface before delayed readiness (or the test hook is not active)"
    Probe $Window $Phase
    return $pending[0]
}
function Wait-Output($Case, [IntPtr]$Window, $Session, [string]$Phase) {
    Wait-For {
        Probe $Window $Phase
        [MuxStartupNative]::Title($Window).Contains("MUX_STARTUP_READY_$($Session.shell_pid)")
    } "$Phase did not deliver shell output to the new surface" ($DelayMs + 15000)
}
function Open-Profile($Case, [IntPtr]$Window, [string]$Name) {
    Key $Window 0x78
    Wait-For { [MuxStartupNative]::Palette($Case.gui.Id) -ne 0 } 'Profile palette did not open'
    $palette = [MuxStartupNative]::Palette($Case.gui.Id)
    foreach ($character in $Name.ToCharArray()) {
        Assert ([MuxStartupNative]::PostMessage($palette, 0x102, [int]$character, 0)) 'Could not filter profile palette'
    }
    Key $palette 0x0D
}
function Close-Gui($Case, [IntPtr]$Window, [int]$TimeoutMs = 5000, [switch]$LastTab) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($LastTab) { Key $Window 0x7A } else { Assert ([MuxStartupNative]::PostMessage($Window, 0x10, 0, 0)) 'Could not post WM_CLOSE' }
    $closed = $Case.gui.WaitForExit($TimeoutMs)
    $metrics.Add([pscustomobject]@{phase=$Case.name; metric='close_ms'; value=$timer.Elapsed.TotalMilliseconds; success=$closed})
    Assert $closed "$($Case.name): close request did not finish within ${TimeoutMs}ms"
    Assert ($Case.gui.ExitCode -eq 0) "$($Case.name): GUI did not exit cleanly"
}
try {
    $success = New-Case 'success'
    $window = Launch $success
    Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Baseline shell output missing'
    $baseline = @(Sessions $success)
    Assert ($baseline.Count -eq 1) 'Baseline should own exactly one broker'
    Hold-SessionProcesses $success $baseline[0]

    $timer = [Diagnostics.Stopwatch]::StartNew()
    Key $window 0x74 # F5: new tab
    $pending = Wait-Pending $success $window @($baseline.name) 1 'new-tab-pending'
    $metrics.Add([pscustomobject]@{phase='new-tab'; metric='broker_published_ms'; value=$timer.Elapsed.TotalMilliseconds})
    # Queue a resize, then ping the UI thread. Do not use a synchronous native
    # resize API that could hang the test itself if startup blocks the UI.
    Assert ([MuxStartupNative]::SetWindowPos($window, 0, 80, 80, 1120, 820, 0x4014)) 'Could not queue resize'
    Wait-For {
        Probe $window 'resize-pending'
        $rect = [MuxStartupNative+Rect]::new()
        [void][MuxStartupNative]::GetWindowRect($window, [ref]$rect)
        ($rect.right - $rect.left) -eq 1120 -and ($rect.bottom - $rect.top) -eq 820
    } 'Window did not resize during broker startup' $ResponseBudgetMs
    Assert ([MuxStartupNative]::Hosts($window) -eq 1) 'Resize only completed after broker startup'
    Wait-Output $success $window $pending 'new-tab-output'
    $metrics.Add([pscustomobject]@{phase='new-tab'; metric='first_output_title_ms'; value=$timer.Elapsed.TotalMilliseconds})
    Assert ([MuxStartupNative]::Hosts($window) -eq 2) 'New tab did not publish exactly one surface'

    # Submit a second request while the first is still in flight. Workers may
    # prepare concurrently; publication must preserve request order. Inspect
    # the final tab positions rather than racing an intermediate active title.
    $beforeBurst = @(Sessions $success)
    $timer.Restart()
    Key $window 0x74
    $first = Wait-Pending $success $window @($beforeBurst.name) 2 'burst-first-pending'
    Key $window 0x74
    $second = Wait-Pending $success $window @($beforeBurst.name + $first.name) 2 'burst-second-pending'
    Wait-For {
        Probe $window 'burst-output'
        [MuxStartupNative]::Hosts($window) -eq 4
    } 'Burst did not publish both prepared surfaces' ($DelayMs + 15000)
    Wait-Output $success $window $second 'burst-second-output'
    $metrics.Add([pscustomobject]@{phase='burst'; metric='two_requests_output_ms'; value=$timer.Elapsed.TotalMilliseconds})
    Assert ([MuxStartupNative]::Hosts($window) -eq 4) 'Burst dropped or duplicated a tab'
    Assert (@(Sessions $success).Count -eq 4) 'Burst dropped or duplicated a broker'
    Assert (@(Get-ChildItem "$($success.path)/*.started").Count -eq 4) 'Burst dropped or duplicated a shell'
    Key $window 0x76 # F7: tab 3 must be the first pending request
    Wait-Output $success $window $first 'burst-tab-three'
    Key $window 0x77 # F8: tab 4 must be the second pending request
    Wait-Output $success $window $second 'burst-tab-four'
    Key $window 0x75 # F6: original tab
    Wait-Output $success $window $baseline[0] 'original-tab'
    Close-Gui $success $window

    # Queue tab, right split and down split before any worker is ready. Both
    # splits target the original pane even after earlier requests change focus
    # and rebuild the tree. The final geometry must be A above D, left of R.
    $mixed = New-Case 'mixed-tabs-splits'
    $window = Launch $mixed
    Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Mixed baseline missing'
    $original = @(Sessions $mixed)
    Hold-SessionProcesses $mixed $original[0]
    $timer.Restart()
    Key $window 0x74 # Tab request
    $newTab = Wait-Pending $mixed $window @($original.name) 1 'mixed-tab-pending'
    Key $window 0x70 # Right split, targeting original
    $right = Wait-Pending $mixed $window @($original.name + $newTab.name) 1 'mixed-right-pending'
    Key $window 0x71 # Down split, still targeting original
    $down = Wait-Pending $mixed $window @($original.name + $newTab.name + $right.name) 1 'mixed-down-pending'
    Key $window 0x7E # Zoom original while workers run; publication must show new splits
    Wait-Output $mixed $window $down 'mixed-final-output'
    Wait-For { Probe $window 'mixed-visible'; [MuxStartupNative]::VisibleHosts($window) -eq 3 } 'Splits did not publish into the original tab or left panes hidden'
    Assert ([MuxStartupNative]::Hosts($window) -eq 4) 'Mixed requests duplicated or lost a surface'
    Assert (@(Sessions $mixed).Count -eq 4) 'Mixed requests duplicated or lost a broker'
    $expectedCwd = [IO.Path]::GetFullPath("$($mixed.path)/cwd-$($original[0].shell_pid)").TrimEnd('\', '/')
    foreach ($splitSession in @($right, $down)) {
        $actualCwd = (Get-Content "$($mixed.path)/$($splitSession.shell_pid).initial-cwd" -Raw).Trim().TrimEnd('\', '/')
        Assert ($actualCwd -eq $expectedCwd) 'Split did not snapshot the original target working directory'
    }
    Key $window 0x7D # Up from down split must select original, not a newly focused pane
    Wait-Output $mixed $window $original[0] 'mixed-original-above-down'
    Key $window 0x7F # Right from original must select first split
    Wait-Output $mixed $window $right 'mixed-right-orientation'
    Key $window 0x7B # Tab 2 is the ordinary tab, without any splits
    Wait-Output $mixed $window $newTab 'mixed-tab-two'
    Wait-For { Probe $window 'mixed-tab-visible'; [MuxStartupNative]::VisibleHosts($window) -eq 1 } 'Pending splits followed new-tab focus'
    $metrics.Add([pscustomobject]@{phase='mixed'; metric='three_requests_output_ms'; value=$timer.Elapsed.TotalMilliseconds})
    Close-Gui $mixed $window

    # A nonpersistent profile is ready immediately, but must not overtake a
    # persistent request already in the shared publication queue.
    $mixedProfiles = New-Case 'mixed-persistent-direct'
    New-Item -ItemType Directory "$($mixedProfiles.path)/ghostty/profiles" -Force | Out-Null
    'windows-persistent-sessions = false' | Set-Content "$($mixedProfiles.path)/ghostty/profiles/DirectReady.conf" -Encoding utf8
    $window = Launch $mixedProfiles
    Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Mixed-profile baseline missing'
    $original = @(Sessions $mixedProfiles)
    Hold-SessionProcesses $mixedProfiles $original[0]
    Key $window 0x74
    $persistent = Wait-Pending $mixedProfiles $window @($original.name) 1 'mixed-profile-persistent-pending'
    Open-Profile $mixedProfiles $window 'DirectReady'
    Wait-For { Probe $window 'mixed-profile-queued'; [MuxStartupNative]::Palette($mixedProfiles.gui.Id) -eq 0 } 'Direct profile request did not close its palette'
    Assert ([MuxStartupNative]::Hosts($window) -eq 1) 'Ready direct request bypassed the earlier pending broker'
    Wait-For { Probe $window 'mixed-profile-publication'; [MuxStartupNative]::Hosts($window) -eq 3 } 'Mixed profiles did not both publish'
    Wait-For {
        $script:directReadyPids = @(Get-ChildItem "$($mixedProfiles.path)/*.started" | Where-Object { [int]$_.BaseName -notin @($original[0].shell_pid, $persistent.shell_pid) } | ForEach-Object { [int]$_.BaseName })
        $script:directReadyPids.Count -eq 1
    } 'Queued direct profile did not start exactly one shell'
    $directReadyPid = $script:directReadyPids[0]
    $directReady = [Diagnostics.Process]::GetProcessById($directReadyPid)
    [void]$directReady.Handle
    $mixedProfiles.owned.Add($directReady)
    Key $window 0x76 # Tab 3 must be the later direct profile
    Key $window 0x79 # Clear profile label to expose shell output title
    Wait-For { Probe $window 'mixed-profile-direct'; [MuxStartupNative]::Title($window).Contains("MUX_STARTUP_READY_$directReadyPid") } 'Direct profile lost its request-order tab position'
    Key $window 0x7B # Tab 2 must be the earlier persistent request
    Wait-Output $mixedProfiles $window $persistent 'mixed-profile-persistent-second'
    Assert (@(Sessions $mixedProfiles).Count -eq 2) 'Direct profile unexpectedly launched a broker'
    Close-Gui $mixedProfiles $window

    # Close a captured target while another pane/tab survives. A pending tab
    # queued behind the invalid split must still publish, and no split may be
    # retargeted to a surviving pane. Previously published brokers stay alive.
    foreach ($targetKind in @('pane', 'tab')) {
        $cancelTarget = New-Case "close-target-$targetKind"
        $window = Launch $cancelTarget
        Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Target-close baseline missing'
        $initial = @(Sessions $cancelTarget)
        Hold-SessionProcesses $cancelTarget $initial[0]
        Key $window $(if ($targetKind -eq 'pane') { 0x70 } else { 0x74 })
        $target = Wait-Pending $cancelTarget $window @($initial.name) 1 'target-setup-pending'
        Wait-Output $cancelTarget $window $target 'target-setup-output'
        $existing = @(Sessions $cancelTarget)
        Key $window 0x71
        $abandoned = Wait-Pending $cancelTarget $window @($existing.name) 2 'target-split-pending'
        Key $window 0x74
        $survivor = Wait-Pending $cancelTarget $window @($existing.name + $abandoned.name) 2 'target-surviving-tab-pending'
        Key $window $(if ($targetKind -eq 'pane') { 0x7A } else { 0x73 })
        Wait-For {
            Probe $window 'target-closed'
            $cancelTarget.owned[4].HasExited -and $cancelTarget.owned[5].HasExited
        } 'Closed target did not dispose its unpublished broker/shell' 1500
        Wait-Output $cancelTarget $window $survivor 'target-surviving-tab-output'
        Assert ([MuxStartupNative]::Hosts($window) -eq 2) 'Canceled split was published into a surviving pane/tab'
        Assert (!$cancelTarget.owned[0].HasExited -and !$cancelTarget.owned[1].HasExited -and !$cancelTarget.owned[2].HasExited -and !$cancelTarget.owned[3].HasExited) 'Target cancellation killed an existing persistent session'
        $remaining = @(Sessions $cancelTarget)
        Assert ($remaining.Count -eq 3 -and $abandoned.name -notin $remaining.name) 'Canceled split left a discoverable orphan'
        Key $window 0x75
        Wait-Output $cancelTarget $window $initial[0] 'target-original-survives'
        Close-Gui $cancelTarget $window
    }

    # An explicit missing session must keep the existing error-pane behavior,
    # and must not run the configured command as a replacement shell.
    $missingName = 'startup-missing-' + [guid]::NewGuid().ToString('N')
    $missing = New-Case 'missing-session' "windows-persistent-sessions = false`nwindows-mux-session = $missingName"
    $timer.Restart()
    $window = Launch $missing 0
    Wait-For {
        Probe $window 'missing-session'
        [MuxStartupNative]::Title($window).Contains('Session unavailable')
    } 'Missing broker did not show the normal error pane'
    $metrics.Add([pscustomobject]@{phase='missing-session'; metric='error_title_ms'; value=$timer.Elapsed.TotalMilliseconds})
    Assert (@(Sessions $missing).Count -eq 0) 'Missing broker silently created a session'
    Assert (@(Get-ChildItem "$($missing.path)/*.started").Count -eq 0) 'Missing broker silently created a shell'
    Close-Gui $missing $window

    # Exercise the changed async error path with an isolated installation.
    # The baseline uses a direct shell, so no running image locks the helper
    # that we rename. The user's supplied build directory is never modified.
    $noHelper = New-Case 'missing-helper' 'windows-persistent-sessions = false'
    $install = Join-Path $noHelper.path 'install'
    $noHelper.bin = Join-Path $install 'bin'
    New-Item -ItemType Directory $noHelper.bin, "$($noHelper.path)/ghostty/profiles" -Force | Out-Null
    Copy-Item "$Bin/*" $noHelper.bin -Recurse -Force
    foreach ($resourceDirectory in @('share', 'lib')) {
        $source = Join-Path (Split-Path $Bin -Parent) $resourceDirectory
        if (Test-Path $source) { Copy-Item $source (Join-Path $install $resourceDirectory) -Recurse -Force }
    }
    $profileName = 'MuxStartupMissingHelper'
    'windows-persistent-sessions = true' | Set-Content "$($noHelper.path)/ghostty/profiles/$profileName.conf" -Encoding utf8
    $window = Launch $noHelper 0
    Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Missing-helper direct baseline output missing'
    $directFiles = @(Get-ChildItem "$($noHelper.path)/*.started")
    Assert ($directFiles.Count -eq 1) 'Missing-helper baseline did not create exactly one direct shell'
    $directPid = [int](Get-Content $directFiles[0].FullName -Raw)
    $directProcess = [Diagnostics.Process]::GetProcessById($directPid)
    [void]$directProcess.Handle
    $noHelper.owned.Add($directProcess)
    Assert (@(Sessions $noHelper).Count -eq 0) 'Missing-helper baseline unexpectedly started a broker'
    $noHelper.helper_backup = "$($noHelper.bin)/yuurei-mux.exe.disabled"
    Move-Item "$($noHelper.bin)/yuurei-mux.exe" $noHelper.helper_backup
    Assert (!(Test-Path "$($noHelper.bin)/yuurei-mux.exe")) 'Could not remove isolated helper from the launch path'
    $timer.Restart()
    Open-Profile $noHelper $window $profileName
    Wait-For {
        Probe $window 'missing-helper'
        [MuxStartupNative]::Hosts($window) -eq 2
    } 'Async helper failure did not publish an error surface'
    Key $window 0x79 # F10 clears the profile label, exposing the IO title
    Wait-For {
        Probe $window 'missing-helper-error'
        [MuxStartupNative]::Title($window).Contains('Session unavailable')
    } 'Async helper failure did not show the normal error pane'
    $metrics.Add([pscustomobject]@{phase='missing-helper'; metric='error_title_ms'; value=$timer.Elapsed.TotalMilliseconds})
    Assert (!$directProcess.HasExited) 'Async startup failure killed the original direct shell'
    Assert (@(Get-ChildItem "$($noHelper.path)/*.started").Count -eq 1) 'Async helper failure silently launched a replacement shell'
    Key $window 0x70 # Split the persistent-profile error pane while helper is absent
    Wait-For {
        Probe $window 'missing-helper-split'
        [MuxStartupNative]::Hosts($window) -eq 3
    } 'Async split helper failure did not publish one error surface'
    Wait-For {
        Probe $window 'missing-helper-split-error'
        [MuxStartupNative]::Title($window).Contains('Session unavailable')
    } 'Async split helper failure did not preserve normal error-pane behavior'
    Assert (!$directProcess.HasExited) 'Failed split killed the existing direct shell'
    Assert (@(Get-ChildItem "$($noHelper.path)/*.started").Count -eq 1) 'Failed split silently launched a replacement shell'
    Move-Item $noHelper.helper_backup "$($noHelper.bin)/yuurei-mux.exe"
    $noHelper.helper_backup = $null
    Assert (@(Sessions $noHelper).Count -eq 0) 'Async helper failure left an unexpected broker'
    Key $window 0x75
    Wait-For {
        Probe $window 'missing-helper-original'
        [MuxStartupNative]::Title($window).Contains("MUX_STARTUP_READY_$directPid")
    } 'Original direct tab stopped working after async startup failure'
    Close-Gui $noHelper $window

    # Trigger a close at the native-surface-created / tree-not-published
    # boundary. A pre-init cancellation check alone misses this reentrant case.
    foreach ($operation in @('tab', 'split')) {
        foreach ($closePoint in @('window', 'last-pane')) {
            $atPublish = New-Case "close-on-publication-$operation-$closePoint"
            $window = Launch $atPublish $DelayMs $closePoint
            Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Publication-close baseline missing'
            $original = @(Sessions $atPublish)
            Hold-SessionProcesses $atPublish $original[0]
            Key $window $(if ($operation -eq 'split') { 0x70 } else { 0x74 })
            $abandoned = Wait-Pending $atPublish $window @($original.name) 1 'close-on-publication-pending'
            Assert ($atPublish.gui.WaitForExit($DelayMs + 15000)) 'Close dispatched during native creation was overridden by publication'
            Assert ($atPublish.gui.ExitCode -eq 0) 'Publication-stage cancellation did not exit cleanly'
            Wait-For { $atPublish.owned[2].HasExited -and $atPublish.owned[3].HasExited } 'Publication-stage cancellation accepted and orphaned its new broker/shell' 5000
            Assert (!$atPublish.owned[0].HasExited -and !$atPublish.owned[1].HasExited) 'Publication-stage cancellation killed the existing persistent session'
            $remaining = @(Sessions $atPublish)
            Assert ($remaining.Count -eq 1 -and $remaining[0].name -eq $original[0].name) 'Publication-stage cancellation left an extra discoverable session'
        }
    }

    foreach ($operation in @('tab', 'split')) {
    foreach ($closeMode in @('window', 'last-tab')) {
        $cancel = New-Case "close-$closeMode-pending-$operation"
        $window = Launch $cancel
        Wait-For { [MuxStartupNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Cancellation baseline missing'
        $original = @(Sessions $cancel)
        Assert ($original.Count -eq 1) 'Cancellation baseline should own exactly one broker'
        Hold-SessionProcesses $cancel $original[0]
        $timer.Restart()
        Key $window $(if ($operation -eq 'split') { 0x70 } else { 0x74 })
        $abandoned = Wait-Pending $cancel $window @($original.name) 1 'close-pending'
        # Registry publication follows CreateProcess: the retained live shell
        # handle proves this is not merely an unstarted broker. Do not wait for
        # PowerShell profile/engine startup, which can outlast the delay on a
        # cold machine. Cancellation must clean up even before fixture code runs.
        Assert (!$cancel.owned[2].HasExited -and !$cancel.owned[3].HasExited) 'Pending broker/shell exited before cancellation'
        Assert ([MuxStartupNative]::Hosts($window) -eq 1) 'Cancellation missed the in-flight startup interval'
        Close-Gui $cancel $window 1500 -LastTab:($closeMode -eq 'last-tab')
        Wait-For { $cancel.owned[2].HasExited -and $cancel.owned[3].HasExited } 'Closing during startup left the new broker or shell alive' 5000
        Assert (!$cancel.owned[0].HasExited -and !$cancel.owned[1].HasExited) 'Startup cancellation killed the previously attached persistent session'
        # Observe past the original ready time to detect a canceled request being
        # published late or a queued worker launching a replacement after close.
        $remaining = $DelayMs + 1000 - $timer.ElapsedMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        $remainingSessions = @(Sessions $cancel)
        Assert ($remainingSessions.Count -eq 1 -and $remainingSessions[0].name -eq $original[0].name) 'Canceled startup left an extra discoverable broker'
        $startedPids = @(Get-ChildItem "$($cancel.path)/*.started" | ForEach-Object { [int]$_.BaseName })
        Assert (@($startedPids | Where-Object { $_ -notin @($original[0].shell_pid, $abandoned.shell_pid) }).Count -eq 0) 'Canceled startup launched an unexpected replacement shell'
        Assert ($cancel.owned[2].HasExited -and $cancel.owned[3].HasExited) 'Canceled startup left an orphaned process'
    }
    }
    Write-Output "PASS: responsive pending tabs/splits/resize, first output, mixed FIFO, split orientation and original target, missing session/helper errors, and target-pane/tab/window close cancellation without orphaning new processes. Artifacts: $dir"
} finally {
    [pscustomobject]@{
        injected_delay_ms=$DelayMs
        response_budget_ms=$ResponseBudgetMs
        max_ui_probe_ms=($metrics | Where-Object metric -eq 'ui_probe_ms' | Measure-Object value -Maximum).Maximum
        samples=$metrics.ToArray()
    } | ConvertTo-Json -Depth 5 | Set-Content "$dir/timing.json" -Encoding utf8
    foreach ($case in $cases) {
        if ($case.helper_backup -and (Test-Path $case.helper_backup)) {
            try { Move-Item $case.helper_backup "$($case.bin)/yuurei-mux.exe"; $case.helper_backup = $null } catch { Write-Warning $_ }
        }
        if ($case.gui) {
            if (!$case.gui.HasExited) { $case.gui.Kill(); $case.gui.WaitForExit() }
            $case.gui.Dispose()
        }
        # Capture fixture-owned processes even when failure happened before
        # Wait-Pending retained their handles. Match the unique worker path,
        # not merely an executable name; stale registry records can omit a
        # shell whose broker has already died.
        try {
            $fixtureProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'yuurei-mux.exe' OR Name = 'pwsh.exe'" | Where-Object {
                $_.CommandLine -and $_.CommandLine.Contains($case.path)
            })
            foreach ($fixtureProcess in $fixtureProcesses) {
                try {
                    $process = [Diagnostics.Process]::GetProcessById($fixtureProcess.ProcessId)
                    [void]$process.Handle
                    $case.owned.Add($process)
                } catch { Write-Warning $_ }
            }
        } catch { Write-Warning $_ }
        # Every helper uses an isolated LOCALAPPDATA registry. Never touch
        # sessions from the user's normal configuration.
        try { foreach ($session in @(Sessions $case)) { try { Mux $case @('stop', $session.name) | Out-Null } catch { Write-Warning $_ } } } catch { Write-Warning $_ }
        foreach ($process in $case.owned) {
            try { if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() } } catch { Write-Warning $_ }
            $process.Dispose()
        }
    }
}
