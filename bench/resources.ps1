#requires -Version 7.0
param(
    [string]$Executable = "$PSScriptRoot/../zig-out/bin/ghostty.exe",
    [string]$Artifacts = "$env:TEMP/yuurei-resources",
    [ValidateRange(1,1000)][int]$Cycles = 20,
    [ValidateRange(1,60)][int]$IdleSeconds = 5
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ResourceNative {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr p, uint flags);
    public static IntPtr Find(uint process, string name) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h,l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != process) return true;
            var s = new StringBuilder(256); GetClassName(h,s,256);
            if (s.ToString() == name) { result = h; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static int SurfaceCount(IntPtr parent) {
        int count = 0;
        EnumChildWindows(parent, (h,l) => {
            var s = new StringBuilder(256); GetClassName(h,s,256);
            if (s.ToString() == "ghostty-host") count++;
            return true;
        }, IntPtr.Zero);
        return count;
    }
}
'@
$run = Join-Path $Artifacts ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $run 'ghostty'))
@'
command = cmd.exe /Q /K
font-family = Consolas
cursor-style-blink = false
windows-restore-session = false
confirm-close-surface = false
keybind = f10=new_tab
keybind = f9=close_surface
keybind = f12=open_config
keybind = f11=inspector:toggle
keybind = f7=text:exit\r
'@ | Set-Content (Join-Path $run 'ghostty/config')
$rows = [Collections.Generic.List[object]]::new()
function Find-Window([string]$Class) {
    for ($i=0; $i -lt 200; $i++) {
        if ($app.HasExited) { throw "Process exited: $($app.ExitCode)" }
        $h = [ResourceNative]::Find($app.Id, $Class)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 25
    }
    throw "Window missing: $Class"
}
function Key([int]$Code) { [void][ResourceNative]::PostMessage($terminal, 0x100, $Code, 0); Start-Sleep -Milliseconds 350 }
function Assert-Surfaces([int]$Expected) {
    for ($i=0; $i -lt 100; $i++) {
        if ([ResourceNative]::SurfaceCount($terminal) -eq $Expected) { return }
        Start-Sleep -Milliseconds 50
    }
    throw "Expected $Expected terminal surfaces, found $([ResourceNative]::SurfaceCount($terminal))"
}
function Sample([string]$Phase) {
    $app.Refresh(); $cpu = $app.TotalProcessorTime.TotalMilliseconds
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $IdleSeconds
    $app.Refresh(); $watch.Stop()
    $row = [pscustomobject]@{
        phase=$Phase; private_mib=[math]::Round($app.PrivateMemorySize64/1MB,2)
        working_mib=[math]::Round($app.WorkingSet64/1MB,2); handles=$app.HandleCount
        threads=$app.Threads.Count; gdi=[ResourceNative]::GetGuiResources($app.Handle,0)
        user=[ResourceNative]::GetGuiResources($app.Handle,1)
        cpu_one_core_percent=[math]::Round(($app.TotalProcessorTime.TotalMilliseconds-$cpu)/$watch.Elapsed.TotalMilliseconds*100,3)
    }
    $rows.Add($row); Write-Host ($row | ConvertTo-Json -Compress)
}
$startup = [Diagnostics.Stopwatch]::StartNew()
$app = Start-Process -FilePath (Resolve-Path $Executable) -PassThru -WindowStyle Hidden -Environment @{XDG_CONFIG_HOME=$run; LOCALAPPDATA=$run; GHOSTTY_PERF_TRACE='1'} -RedirectStandardError (Join-Path $run 'stderr.log')
try {
    $terminal = Find-Window 'ghostty'; $startup.Stop()
    [void][ResourceNative]::ShowWindow($terminal,5)
    Start-Sleep -Seconds 2
    Sample 'one-tab'
    for ($i=0; $i -lt 7; $i++) { Key 0x79 }
    Assert-Surfaces 8
    Sample 'eight-tabs'
    for ($i=0; $i -lt 7; $i++) { Key 0x78 }
    Assert-Surfaces 1
    Sample 'after-eight-tabs'
    for ($i=0; $i -lt $Cycles; $i++) { Key 0x79; Assert-Surfaces 2; Key 0x78; Assert-Surfaces 1 }
    Sample 'after-tab-cycles'
    for ($i=0; $i -lt $Cycles; $i++) {
        Key 0x79
        Assert-Surfaces 2
        Key 0x76
        Assert-Surfaces 1
    }
    Sample 'after-shell-exit-cycles'
    for ($i=0; $i -lt $Cycles; $i++) {
        Key 0x7B; $h=Find-Window 'ghostty-settings'
        [void][ResourceNative]::PostMessage($h,0x10,0,0)
        Start-Sleep -Milliseconds 150
    }
    Sample 'after-settings-cycles'
    for ($i=0; $i -lt $Cycles; $i++) {
        Key 0x7A; $h=Find-Window 'ghostty-inspector'
        [void][ResourceNative]::PostMessage($h,0x10,0,0)
        Start-Sleep -Milliseconds 150
    }
    Sample 'after-inspector-cycles'
    Key 0x7A; $h=Find-Window 'ghostty-inspector'
    Sample 'inspector-visible'
    [void][ResourceNative]::ShowWindow($h,6)
    Start-Sleep -Seconds 1
    Sample 'inspector-minimized'
    [void][ResourceNative]::ShowWindow($h,9)
    Start-Sleep -Seconds 1
    Sample 'inspector-restored'
    [void][ResourceNative]::PostMessage($h,0x10,0,0)
    Start-Sleep -Milliseconds 350
    [void][ResourceNative]::ShowWindow($terminal,6)
    Sample 'minimized'
    [pscustomobject]@{executable=(Resolve-Path $Executable).Path; startup_window_ms=$startup.Elapsed.TotalMilliseconds; cycles=$Cycles; samples=$rows} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $run 'results.json')
    Write-Host "Results: $run"
} finally {
    if (!$app.HasExited) { Stop-Process -Id $app.Id }
    $app.Dispose()
}
