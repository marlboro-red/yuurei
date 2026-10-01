#requires -Version 7.4
# Run on an isolated Windows desktop with matching ghostty/yuurei-mux builds.
# Message-pump and GDI-lifecycle evidence only; this is not visual flicker verification.
param(
    [string]$Bin = "$PSScriptRoot/../../zig-out/bin",
    [ValidateRange(100,1000)][int]$ResponseBudgetMs = 500,
    [string]$Artifacts = "$env:TEMP/yuurei-session-navigator"
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
public static class NavigatorNative {
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
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
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
        foreach (var parent in Windows(pid)) EnumChildWindows(parent, (h, p) => { if (Class(h) == "ghostty-palette") result = h; return true; }, IntPtr.Zero);
        return result;
    }
    [StructLayout(LayoutKind.Sequential)] public struct GuiInfo { public uint size, flags; public IntPtr active, focus, capture, menu, move, caret; public Rect caretRect; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flag);
    [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
    [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr hwnd);
    public static IntPtr Focus(IntPtr hwnd) { uint pid; var tid = GetWindowThreadProcessId(hwnd, out pid); var info = new GuiInfo(); info.size = (uint)Marshal.SizeOf(info); return GetGUIThreadInfo(tid, ref info) ? info.focus : IntPtr.Zero; }
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
[void][NavigatorNative]::SetThreadDpiAwarenessContext(-4)
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
    $ok = [NavigatorNative]::Ping($Window, $ResponseBudgetMs)
    $metrics.Add([pscustomobject]@{phase=$Phase; metric='ui_probe_ms'; value=$timer.Elapsed.TotalMilliseconds; success=$ok})
    Assert $ok "$Phase blocked the UI message pump for at least ${ResponseBudgetMs}ms"
}
function Key([IntPtr]$Window, [int]$VirtualKey) {
    Assert ([NavigatorNative]::PostMessage($Window, 0x100, $VirtualKey, 1)) 'Could not post key down'
    $released = [NavigatorNative]::PostMessage($Window, 0x101, $VirtualKey, 0xC0000001)
    # Escape may destroy the picker before the synthetic release is posted.
    # Keep failures on live windows (including an active confirmation) visible.
    if (!$released -and $VirtualKey -eq 0x1B -and ![NavigatorNative]::IsWindow($Window)) { return }
    Assert $released 'Could not post key up'
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
function New-Case([string]$Name) {
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
keybind = f5=new_tab
keybind = f9=session:list
"@ | Set-Content "$path/ghostty/config" -Encoding utf8
    $case = [pscustomobject]@{name=$Name; path=$path; bin=$Bin; gui=$null; owned=[Collections.Generic.List[Diagnostics.Process]]::new()}
    $cases.Add($case)
    return $case
}
function Launch($Case) {
    $Case.gui = Start-Process "$($Case.bin)/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{
        LOCALAPPDATA=$Case.path; XDG_CONFIG_HOME=$Case.path; GHOSTTY_NEW_INSTANCE='1'
        GHOSTTY_PERF_TRACE='1'
    } -RedirectStandardError "$($Case.path)/gui.log" -RedirectStandardOutput "$($Case.path)/gui.stdout.log"
    Wait-For { [NavigatorNative]::Windows($Case.gui.Id).Count -eq 1 } "$($Case.name): window missing"
    $window = [NavigatorNative]::Windows($Case.gui.Id)[0]
    [void][NavigatorNative]::ShowWindow($window, 5)
    [void][NavigatorNative]::SetWindowPos($window, 0, 80, 80, 1100, 800, 0x14)
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
function Picker-Alive($Case, $Window, $Picker) {
    Assert ([NavigatorNative]::Palette($Case.gui.Id) -eq $Picker) 'Navigator was destroyed/replaced'
    Assert ([NavigatorNative]::Focus($Window) -eq $Picker) 'Focus left navigator'
    Probe $Picker 'navigator'
}
$passed = $false
try {
    $case = New-Case 'navigator'
    $window = Launch $case
    Wait-For { [NavigatorNative]::Title($window).Contains('MUX_STARTUP_READY_') } 'Persistent shell output missing'
    for ($i=1; $i -lt 3; $i++) {
        Key $window 0x74
        Wait-For { @(Sessions $case).Count -eq ($i+1) } 'New test broker missing'
        Start-Sleep -Milliseconds 500
    }
    $all = @(Sessions $case)
    foreach ($entry in $all) { Hold-SessionProcesses $case $entry }
    $all | ConvertTo-Json -Depth 5 | Set-Content "$($case.path)/actual-brokers.json"
    Assert ($all.Count -eq 3) 'Expected three actual brokers'
    foreach ($entry in $all) {
        Assert ($entry.broker_pid -gt 0 -and $entry.shell_pid -gt 0) 'Persistent mux path not active'
        Assert ((Mux $case @('preview', $entry.name)).Length -gt 0) 'Actual broker preview unavailable'
    }
    Wait-For { [NavigatorNative]::Hosts($window) -eq 3 } 'Test tab creation did not finish'
    Start-Sleep -Milliseconds 500
    Key $window 0x78
    Wait-For { [NavigatorNative]::Palette($case.gui.Id) -ne 0 } 'Navigator did not open'
    $picker = [NavigatorNative]::Palette($case.gui.Id)
    Wait-For { [NavigatorNative]::Focus($window) -eq $picker } 'Navigator initialization did not focus its view'
    Picker-Alive $case $window $picker
    # Tear down and recreate preview workers, including a pending debounce and
    # an in-flight preview. No late completion may target the reopened view.
    for ($cycle=0; $cycle -lt 6; $cycle++) {
        Key $picker 0x28
        if ($cycle % 2) { Start-Sleep -Milliseconds 130 }
        Key $picker 0x1B
        Wait-For { [NavigatorNative]::Palette($case.gui.Id) -eq 0 } 'Navigator did not dismiss'
        Key $window 0x78
        Wait-For { [NavigatorNative]::Palette($case.gui.Id) -ne 0 } 'Navigator did not reopen'
        $picker = [NavigatorNative]::Palette($case.gui.Id)
        Wait-For { [NavigatorNative]::Focus($window) -eq $picker } 'Reopened navigator did not gain focus'
        Picker-Alive $case $window $picker
    }
    [void][NavigatorNative]::SetWindowPos($window,0,80,80,900,650,0x14)
    for ($i=0; $i -lt 20; $i++) {
        Key $picker $(if ($i % 2) {0x26} else {0x28})
        [void][NavigatorNative]::InvalidateRect($picker,0,$false)
        [void][NavigatorNative]::UpdateWindow($picker)
    }
    Start-Sleep -Milliseconds 1000
    $gdiBefore = [NavigatorNative]::GetGuiResources($case.gui.Handle,0)
    for ($i=0; $i -lt 120; $i++) {
        Key $picker $(if ($i % 2) {0x26} else {0x28})
        [void][NavigatorNative]::InvalidateRect($picker,0,$false)
        [void][NavigatorNative]::UpdateWindow($picker)
    }
    Start-Sleep -Milliseconds 300
    Key $picker 0x21; Key $picker 0x22 # Page Up / Page Down
    [void][NavigatorNative]::PostMessage($window,7,0,0) # parent WM_SETFOCUS redirects to navigator
    Start-Sleep -Milliseconds 200
    Picker-Alive $case $window $picker
    $gdiAfter = [NavigatorNative]::GetGuiResources($case.gui.Handle,0)
    Assert ($gdiAfter -le $gdiBefore + 4) "GDI resources grew after navigation: $gdiBefore -> $gdiAfter"
    foreach ($cancel in @(0x1B,0x4E)) {
        Key $picker 0x2E
        Key $picker 0x28 # frozen selection while confirming
        Key $picker 0x0D # Enter must not accidentally accept
        Key $picker 0x2E # repeated End must not change target
        Key $picker $cancel
        Start-Sleep -Milliseconds 150
        Picker-Alive $case $window $picker
        Assert (@(Sessions $case).Count -eq 3) 'Cancel ended a session'
    }
    # Explicit confirm; autorepeat Y must not end another session or enter filter text.
    Key $picker 0x2E
    [void][NavigatorNative]::PostMessage($picker,0x100,0x59,1)
    for ($i=0;$i -lt 10;$i++) { [void][NavigatorNative]::PostMessage($picker,0x100,0x59,0x40000001) }
    [void][NavigatorNative]::PostMessage($picker,0x101,0x59,0xC0000001)
    Wait-For { @(Sessions $case).Count -eq 2 } 'Confirmed end did not stop exactly one broker'
    Picker-Alive $case $window $picker
    # End again without reopening or refiltering. This also checks confirmation keys did not produce filter text.
    Key $picker 0x2E; Key $picker 0x59
    Wait-For { @(Sessions $case).Count -eq 1 } 'Second end failed or confirmation text leaked into filter'
    Picker-Alive $case $window $picker
    # Confirming the last attached session leaves an empty navigator alive.
    Key $picker 0x2E; Key $picker 0x59
    Wait-For { @(Sessions $case).Count -eq 0 } 'Final attached session was not ended'
    Start-Sleep -Milliseconds 300
    Picker-Alive $case $window $picker
    # A detached session can disappear without any surface-close notification.
    $staleName = 'nav-stale-' + [guid]::NewGuid().ToString('N')
    Mux $case @('start',$staleName,'pwsh.exe','-NoLogo','-NoProfile','-File',"$($case.path)/worker.ps1") | Out-Null
    Wait-For { @(Sessions $case).Count -eq 1 } 'Detached fixture broker missing'
    $stale = @(Sessions $case)[0]
    Hold-SessionProcesses $case $stale
    Key $picker 0x74
    Start-Sleep -Milliseconds 200
    Key $picker 0x2E
    Start-Sleep -Milliseconds 100
    Mux $case @('stop',$stale.name) | Out-Null
    Wait-For { @(Sessions $case).Count -eq 0 } 'External stop failed'
    Start-Sleep -Milliseconds 200
    Key $picker 0x59 # stale confirmation: must stay here and remove the dead row
    Start-Sleep -Milliseconds 200
    Picker-Alive $case $window $picker
    Key $picker 0x74
    Key $picker 0x2E; Key $picker 0x28; Key $picker 0x26
    Start-Sleep -Milliseconds 200
    Picker-Alive $case $window $picker
    Wait-For { @($case.owned | Where-Object { !$_.HasExited }).Count -eq 0 } 'Test broker/shell survived stop'
    Key $picker 0x1B
    Assert ($case.gui.WaitForExit(5000)) 'Dismissing empty navigator did not close empty window'
    Assert ($case.gui.ExitCode -eq 0) 'GUI failed on empty navigator teardown'
    $passed = $true
    [pscustomobject]@{passed=$true; broker_count=4; navigation_iterations=120; reopen_cycles=6; gdi_before=$gdiBefore; gdi_after=$gdiAfter; visual_verification=$false; persistent_sessions=$true; owned_processes_exited=$true} | ConvertTo-Json | Set-Content "$dir/result.json"
    Write-Output "PASS: persistent mux, navigation, confirm/cancel/repeat, stale target, empty navigator, focus, GDI lifecycle. $dir"
} finally {
    $metrics | ConvertTo-Json -Depth 5 | Set-Content "$dir/timing.json"
    foreach ($case in $cases) {
        if ($case.gui -and !$case.gui.HasExited) { $case.gui.Kill(); $case.gui.WaitForExit() }
        # Registry.list validates broker identity. This is the fixture's unique
        # LOCALAPPDATA directory, never the user's session registry.
        try {
            foreach ($entry in @(Sessions $case)) {
                try { Hold-SessionProcesses $case $entry } catch {}
                Mux $case @('stop',$entry.name) | Out-Null
            }
        } catch { Write-Warning $_ }
        foreach ($process in $case.owned) {
            try { if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() } } catch { Write-Warning $_ }
            $process.Dispose()
        }
        if ($case.gui) { $case.gui.Dispose() }
    }
    if (!$passed) { 'FAILED; see runner log' | Set-Content "$dir/FAILED.txt" }
}
