#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('yuurei','wt')][string]$Terminal,
    [Parameter(Mandatory)][string]$Executable,
    [string]$Artifacts = "$env:TEMP/yuurei-wt-comparison/runs",
    [int]$LatencySamples = 40,
    [int]$IdleSeconds = 3,
    [switch]$SkipLatency,
    [switch]$SkipOutput,
    [string[]]$YuureiConfig = @(),
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ComparisonNative {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr h, out IntPtr text);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte sc, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    public static IntPtr Find(string title) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h,l) => { var s = new StringBuilder(512); GetWindowText(h,s,512);
            if (!s.ToString().Contains(title)) return true; result=h; return false; }, IntPtr.Zero);
        return result;
    }
    public static bool Foreground(IntPtr h) {
        if (GetForegroundWindow()==h) return true;
        uint p; uint fg=GetWindowThreadProcessId(GetForegroundWindow(),out p), me=GetCurrentThreadId();
        AttachThreadInput(me,fg,true); SetForegroundWindow(h); AttachThreadInput(me,fg,false);
        return GetForegroundWindow()==h;
    }
    public static void Key(IntPtr h, byte key) {
        if (!Foreground(h)) throw new Exception("Could not focus isolated benchmark window");
        keybd_event(key,0,0,UIntPtr.Zero); keybd_event(key,0,2,UIntPtr.Zero);
    }
    public static string ThreadName(uint id) {
        var h=OpenThread(0x800,false,id);
        if (h==IntPtr.Zero) return "";
        try {
            IntPtr text;
            if (GetThreadDescription(h,out text)<0) return "";
            try { return Marshal.PtrToStringUni(text) ?? ""; }
            finally { LocalFree(text); }
        } finally { CloseHandle(h); }
    }
}
'@
[void][ComparisonNative]::SetThreadDpiAwarenessContext(-4)
$run = Join-Path $Artifacts ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $run 'ghostty'))
$title = 'terminal-bench-' + (Split-Path $run -Leaf)
$init = Join-Path $run 'init.cmd'
@"
@echo off
title $title
prompt `$G
echo ready>>"$run\ready.txt"
cls
"@ | Set-Content $init -Encoding ascii
$command = 'cmd.exe /D /Q /K "' + $init + '"'
$producer = Join-Path $run 'output.ps1'
@'
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$stream = [Console]::OpenStandardOutput()
$rows = [Collections.Generic.List[object]]::new()
$esc = [char]27
$patterns = [ordered]@{
    ascii = "The quick brown fox 0123456789 build output repeated for scrollback`r`n"
    color = "${esc}[31merror${esc}[0m ${esc}[1;32mbuild output${esc}[0m 0123456789`r`n"
    unicode = "日本語 Ελληνικά Кириллица العربية 👻 🚀 combining: é`r`n"
}
$size = @{ columns=[Console]::WindowWidth; rows=[Console]::WindowHeight }
foreach ($kind in $patterns.Keys) {
    # Exactly 100,000 lines. Allocate and encode before the timed writes.
    $block = [Text.Encoding]::UTF8.GetBytes($patterns[$kind] * 1000)
    foreach ($iteration in 0..3) {
        [Console]::Write("${esc}[3J${esc}[2J${esc}[H")
        Start-Sleep -Milliseconds 500
        $watch = [Diagnostics.Stopwatch]::StartNew()
        for ($i=0; $i -lt 100; $i++) { $stream.Write($block,0,$block.Length) }
        $stream.Flush()
        $watch.Stop()
        $rows.Add(@{ kind=$kind; iteration=$iteration; warmup=($iteration -eq 0); bytes=$block.Length*100; writer_ms=$watch.Elapsed.TotalMilliseconds })
        [Console]::WriteLine("OUTPUT COMPLETE $kind $iteration")
        Start-Sleep -Seconds 2
    }
}
@{ size=$size; samples=$rows } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'output-results.json')
'@ | Set-Content $producer -Encoding utf8
$outputCommand = 'pwsh -NoProfile -File "' + $producer + '"'
$envMap = @{ GHOSTTY_RENDER_WORKERS='2'; XDG_CONFIG_HOME=$run; LOCALAPPDATA=$run }
if ($Terminal -eq 'yuurei') {
    @"
command = $command
title = $title
font-family = Consolas
font-size = 12
background = #000000
foreground = #ffffff
cursor-style = bar
cursor-style-blink = false
windows-restore-session = false
confirm-close-surface = false
scrollback-limit-lines = 10000
scrollback-limit-bytes = unlimited
keybind = f8=new_tab
keybind = f5=text:$($outputCommand.Replace('\','\\'))\r
"@ | Set-Content (Join-Path $run 'ghostty/config')
    if ($YuureiConfig.Count) { $YuureiConfig | Add-Content (Join-Path $run 'ghostty/config') }
} else {
    # Only accept an explicitly isolated portable distribution.
    $portable = Split-Path (Resolve-Path $Executable)
    if ($portable -notlike "$env:TEMP/*" -and $portable -notlike "$env:TEMP\*") { throw 'Windows Terminal must be an isolated portable copy under TEMP' }
    [IO.File]::WriteAllText((Join-Path $portable '.portable'),'')
    [void][IO.Directory]::CreateDirectory((Join-Path $portable 'settings'))
    @{
        defaultProfile='{964a9228-6386-45ed-a53b-069051c44eb0}'
        confirmCloseAllTabs=$false; firstWindowPreference='defaultProfile'; launchMode='default'
        alwaysShowTabs=$true; showTabsInTitlebar=$true; copyOnSelect=$false
        disabledProfileSources=@('Windows.Terminal.Wsl','Windows.Terminal.Azure','Windows.Terminal.PowershellCore','Windows.Terminal.SSH')
        profiles=@{ defaults=@{ font=@{ face='Consolas'; size=12 }; historySize=10000; background='#000000'; foreground='#ffffff'; opacity=100; useAcrylic=$false; padding='0'; cursorShape='bar' }; list=@(@{ guid='{964a9228-6386-45ed-a53b-069051c44eb0}'; name='Benchmark'; commandline=$command; tabTitle=$title; suppressApplicationTitle=$true }) }
        actions=@(@{command='newTab';keys='f8'},@{command=@{action='sendInput';input=($outputCommand+"`r")};keys='f5'})
    } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $portable 'settings/settings.json')
    Copy-Item (Join-Path $portable 'settings/settings.json') (Join-Path $run 'windows-terminal-settings.json')
}
$app = $null
$hwnd = [IntPtr]::Zero
$rows = [Collections.Generic.List[object]]::new()
$outputCost = $null
function Wait-Tabs([int]$Count) {
    for ($i=0; $i -lt 100; $i++) {
        if ((Test-Path (Join-Path $run 'ready.txt')) -and @(Get-Content (Join-Path $run 'ready.txt')).Count -eq $Count) { Start-Sleep -Milliseconds 350; return }
        Start-Sleep -Milliseconds 100
    }
    throw "Expected $Count initialized shells"
}
function Sample([string]$Phase) {
    $app.Refresh(); $cpu=$app.TotalProcessorTime.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Seconds $IdleSeconds
    $app.Refresh(); $watch.Stop()
    $row=[ordered]@{ phase=$Phase; private_mib=$app.PrivateMemorySize64/1MB; working_mib=$app.WorkingSet64/1MB; handles=$app.HandleCount; threads=$app.Threads.Count; cpu_one_core_percent=($app.TotalProcessorTime.TotalMilliseconds-$cpu)/$watch.Elapsed.TotalMilliseconds*100 }
    Write-Host ($row | ConvertTo-Json -Compress)
    # Record infrastructure and shells separately. Summed working sets can
    # double-count shared pages, so they are not a unique physical-RAM total.
    $processes=@(Get-CimInstance Win32_Process)
    $ids=[Collections.Generic.HashSet[uint32]]::new(); [void]$ids.Add($app.Id)
    do {
        $changed=$false
        foreach ($p in $processes) {
            if ($ids.Contains($p.ParentProcessId) -and $ids.Add($p.ProcessId)) { $changed=$true }
        }
    } while ($changed)
    $row.children=@(foreach ($p in $processes) {
        if ($p.ProcessId -ne $app.Id -and $ids.Contains($p.ProcessId)) {
            $child=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if ($child) { @{ name=$p.Name; pid=$p.ProcessId; parent=$p.ParentProcessId; private_mib=$child.PrivateMemorySize64/1MB; working_mib=$child.WorkingSet64/1MB } }
        }
    })
    $rows.Add($row)
}
function Capture([string]$Name) {
    $bmp=[Drawing.Bitmap]::new($rect.right-$rect.left,$rect.bottom-$rect.top)
    $g=[Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($rect.left,$rect.top,0,0,$bmp.Size); $bmp.Save((Join-Path $run "$Name.png")) }
    finally { $g.Dispose(); $bmp.Dispose() }
}
function Thread-Cpu {
    $app.Refresh()
    @(foreach ($thread in $app.Threads) {
        try { @{ id=$thread.Id; name=[ComparisonNative]::ThreadName($thread.Id); cpu_ms=$thread.TotalProcessorTime.TotalMilliseconds } }
        catch { } # Threads may exit between enumeration and the query.
    })
}
try {
    if ($Terminal -eq 'yuurei') {
        $launch=Start-Process (Resolve-Path $Executable) -WindowStyle Hidden -PassThru -Environment $envMap -RedirectStandardError (Join-Path $run 'stderr.log')
    } else {
        $launch=Start-Process (Resolve-Path $Executable) -ArgumentList '-w','new' -WindowStyle Hidden -PassThru
    }
    for ($i=0; $i -lt 150; $i++) {
        $hwnd=[ComparisonNative]::Find($title)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Isolated benchmark window missing' }
    [uint32]$owner=0; [void][ComparisonNative]::GetWindowThreadProcessId($hwnd,[ref]$owner)
    $candidate=Get-Process -Id $owner
    if ($candidate.Path -ne (Resolve-Path $Executable).Path) { throw 'Window belongs to a different executable' }
    $app=$candidate
    [void][ComparisonNative]::ShowWindow($hwnd,9)
    [void][ComparisonNative]::SetWindowPos($hwnd,0,30,30,1600,1200,0x14)
    if (![ComparisonNative]::Foreground($hwnd)) { throw 'Could not focus benchmark' }
    $rect=[ComparisonNative+Rect]::new(); [void][ComparisonNative]::GetWindowRect($hwnd,[ref]$rect)
    Wait-Tabs 1
    Start-Sleep -Seconds 2
    Sample 'one-tab'
    for ($i=2; $i -le 8; $i++) { [ComparisonNative]::Key($hwnd,0x77); Wait-Tabs $i }
    Sample 'eight-tabs'
    Capture 'eight-tabs'
    # Cmd's single-character prompt occupies the first cell. Find its white
    # pixels to locate the echo row, then sample inside the next glyph.
    if (!$SkipLatency) {
        $bmp=[Drawing.Bitmap]::new((Join-Path $run 'eight-tabs.png'))
        try {
            $top=-1; $bottom=-1
            for ($y=90; $y -lt 250; $y++) { for ($x=14; $x -lt 28; $x++) {
                $c=$bmp.GetPixel($x,$y)
                if ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 180) {
                    if ($top -lt 0) { $top=$y }; $bottom=$y
                }
            } }
            if ($top -lt 0) { throw 'Prompt pixels missing' }
        } finally { $bmp.Dispose() }
        # Interior of the echo glyph at this machine's 200% DPI, excluding
        # both old and new bar cursor positions. Review captures on other DPI.
        $regionX=$rect.left+40; $regionY=$rect.top+$top-2
        $probe=[Drawing.Bitmap]::new(7,$bottom-$top+5)
        $graphics=[Drawing.Graphics]::FromImage($probe)
        try {
            # Cover several cursor phases without sending input. The sampled
            # glyph interior must remain black before a character is typed.
            for ($check=0; $check -lt 12; $check++) {
                $graphics.CopyFromScreen($regionX,$regionY,0,0,$probe.Size)
                for ($y=0; $y -lt $probe.Height; $y++) { for ($x=0; $x -lt $probe.Width; $x++) {
                    $pixel=$probe.GetPixel($x,$y)
                    if ($pixel.R -gt 16 -or $pixel.G -gt 16 -or $pixel.B -gt 16) { throw 'Latency region contains a cursor, prompt or unrelated pixels' }
                } }
                Start-Sleep -Milliseconds 100
            }
        } finally { $graphics.Dispose(); $probe.Dispose() }
        $latency=& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/photon-bench.ps1" -Hwnd $hwnd.ToInt64() -RegionX $regionX -RegionY $regionY -RegionW 7 -RegionH ($bottom-$top+5) -MinChangedPixels 5 -Samples $LatencySamples -Json -DumpBitmaps
        if ($LASTEXITCODE -ne 0) { throw 'Latency measurement failed' }
        $latency | Set-Content (Join-Path $run 'latency.json')
        Copy-Item "$env:TEMP/bench-A.png" (Join-Path $run 'latency-before.png')
        Copy-Item "$env:TEMP/bench-B.png" (Join-Path $run 'latency-after.png')
        @{ x=$regionX; y=$regionY; width=7; height=$bottom-$top+5 } | ConvertTo-Json | Set-Content (Join-Path $run 'latency-region.json')
        Capture 'after-latency'
    }
    if (!$SkipOutput) {
        $threadsBefore=Thread-Cpu
        $app.Refresh(); $outputCpu=$app.TotalProcessorTime.TotalMilliseconds
        $outputWatch=[Diagnostics.Stopwatch]::StartNew()
        [ComparisonNative]::Key($hwnd,0x74)
        for ($i=0; $i -lt 2400; $i++) {
            if (Test-Path (Join-Path $run 'output-results.json')) { break }
            if ($app.HasExited) { throw 'Terminal exited during output' }
            Start-Sleep -Milliseconds 100
        }
        if (!(Test-Path (Join-Path $run 'output-results.json'))) { throw 'Output workload timed out' }
        $app.Refresh(); $outputWatch.Stop()
        $outputCost=@{ terminal_cpu_ms=$app.TotalProcessorTime.TotalMilliseconds-$outputCpu; wall_ms=$outputWatch.Elapsed.TotalMilliseconds; threads_before=$threadsBefore; threads_after=(Thread-Cpu) }
        Sample 'after-output'
        Capture 'after-output'
    }
    [ordered]@{ terminal=$Terminal; executable=(Resolve-Path $Executable).Path; sha256=(Get-FileHash $Executable -Algorithm SHA256).Hash; version=$app.MainModule.FileVersionInfo.FileVersion; width=$rect.right-$rect.left; height=$rect.bottom-$rect.top; shell=$command; font='Consolas 12'; history_lines=10000; yuurei_config=$YuureiConfig; read_kib_override=$env:GHOSTTY_PTY_READ_KIB; io_stats=$env:GHOSTTY_IO_STATS; output_cost=$outputCost; samples=$rows } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $run 'resources.json')
    Write-Host "RESULTS=$run HWND=$hwnd PID=$($app.Id)"
} finally {
    if (!$KeepOpen -and $app -and !$app.HasExited) {
        [void][ComparisonNative]::PostMessage($hwnd,0x10,0,0)
        if (!$app.WaitForExit(15000)) { Stop-Process -Id $app.Id; throw 'Isolated terminal failed to exit cleanly' }
    }
}
