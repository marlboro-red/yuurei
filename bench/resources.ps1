#requires -Version 7.0
param(
    [string]$Executable = "$PSScriptRoot/../zig-out/bin/ghostty.exe",
    [string]$Artifacts = "$env:TEMP/yuurei-resources",
    [ValidateRange(1,1000)][int]$Cycles = 20,
    [ValidateRange(1,60)][int]$IdleSeconds = 5,
    [switch]$TabsOnly,
    [switch]$ProbeHiddenHosts,
    [switch]$ShaderWorkload,
    [switch]$BusyWorkload,
    [switch]$GracefulExit,
    [ValidateRange(0,4)][int]$RendererWorkers = 2,
    [ValidateRange(0,1000)][int]$SwitchSamples = 0,
    [ValidateRange(0,16384)][int]$Width = 0,
    [ValidateRange(0,16384)][int]$Height = 0
)
$ErrorActionPreference = 'Stop'
if (($Width -eq 0) -ne ($Height -eq 0)) { throw 'Specify both Width and Height, or neither' }
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
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
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
    static System.Collections.Generic.Dictionary<IntPtr, Rect> saved = new System.Collections.Generic.Dictionary<IntPtr, Rect>();
    public static void ShrinkHiddenHosts(IntPtr parent) {
        EnumChildWindows(parent, (h,l) => {
            var s = new StringBuilder(256); GetClassName(h,s,256);
            Rect r;
            if (s.ToString() == "ghostty-host" && !IsWindowVisible(h) && GetWindowRect(h,out r)) {
                saved[h] = r;
                if (!SetWindowPos(h,IntPtr.Zero,0,0,1,1,0x16)) throw new Exception("Host resize failed");
            }
            return true;
        }, IntPtr.Zero);
    }
    public static void RestoreHosts() {
        foreach (var pair in saved) {
            var r=pair.Value;
            if (!SetWindowPos(pair.Key,IntPtr.Zero,0,0,r.right-r.left,r.bottom-r.top,0x16)) throw new Exception("Host restore failed");
        }
        saved.Clear();
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
keybind = f6=next_tab
'@ | Set-Content (Join-Path $run 'ghostty/config')
if ($ShaderWorkload) {
    $shader = Join-Path $run 'passthrough.glsl'
    'void mainImage(out vec4 color, in vec2 coord) { color = texture(iChannel0, coord/iResolution.xy); }' | Set-Content -LiteralPath $shader
    $shaderConfig = $shader.Replace('\','/')
    # Two passes exercise both ping-pong textures and intermediate FBOs.
    "custom-shader = $shaderConfig`ncustom-shader = $shaderConfig`ncustom-shader-animation = false" | Add-Content (Join-Path $run 'ghostty/config')
}
if ($BusyWorkload) {
    $producer = Join-Path $run 'produce.ps1'
    @'
$until = [DateTime]::UtcNow.AddSeconds(90)
$block = ("render-pool background output 0123456789 abcdefghijklmnopqrstuvwxyz`n" * 32)
while ([DateTime]::UtcNow -lt $until) {
    [Console]::Write($block)
    [Threading.Thread]::Sleep(5)
}
'@ | Set-Content -LiteralPath $producer
    $command = ('pwsh -NoProfile -File "{0}"' -f $producer).Replace('\','\\')
    "keybind = f5=text:$command\r" | Add-Content (Join-Path $run 'ghostty/config')
}
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
function Save-Results {
    [pscustomobject]@{
        executable=(Resolve-Path $Executable).Path
        sha256=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
        startup_window_ms=$startup.Elapsed.TotalMilliseconds
        window_width=$rect.right-$rect.left; window_height=$rect.bottom-$rect.top
        tabs_only=[bool]$TabsOnly; cycles=$Cycles; idle_seconds=$IdleSeconds
        shader_workload=[bool]$ShaderWorkload
        busy_workload=[bool]$BusyWorkload
        renderer_workers=$RendererWorkers
        park_drawables=$env:GHOSTTY_PARK_DRAWABLES
        switch_samples=$SwitchSamples; samples=$rows
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $run 'results.json')
}
$startup = [Diagnostics.Stopwatch]::StartNew()
$app = Start-Process -FilePath (Resolve-Path $Executable) -PassThru -WindowStyle Hidden -Environment @{XDG_CONFIG_HOME=$run; LOCALAPPDATA=$run; GHOSTTY_PERF_TRACE='1'; GHOSTTY_RENDER_WORKERS="$RendererWorkers"} -RedirectStandardError (Join-Path $run 'stderr.log')
try {
    $terminal = Find-Window 'ghostty'; $startup.Stop()
    [void][ResourceNative]::SetThreadDpiAwarenessContext(-4)
    if ($Width -gt 0 -and $Height -gt 0) { [void][ResourceNative]::SetWindowPos($terminal,0,0,0,$Width,$Height,0x16) }
    $rect = [ResourceNative+Rect]::new()
    [void][ResourceNative]::GetWindowRect($terminal,[ref]$rect)
    Write-Host "Window pixels: $($rect.right-$rect.left) x $($rect.bottom-$rect.top)"
    [void][ResourceNative]::ShowWindow($terminal,5)
    Start-Sleep -Seconds 2
    Sample 'one-tab'
    for ($i=0; $i -lt 7; $i++) {
        if ($BusyWorkload -and $i -lt 3) { Key 0x74 }
        Key 0x79
    }
    Assert-Surfaces 8
    Sample 'eight-tabs'
    if ($SwitchSamples -gt 0) {
        $latencies = [Collections.Generic.List[int]]::new()
        $log = Join-Path $run 'stderr.log'
        for ($i=0; $i -lt $SwitchSamples; $i++) {
            $offset = @(Get-Content -LiteralPath $log).Count
            Key 0x75
            $matchesForSwitch = @(Get-Content -LiteralPath $log | Select-Object -Skip $offset | Select-String 'perf: present key\+(\d+)ms')
            if ($matchesForSwitch.Count -eq 0) { throw 'No traced presentation after tab switch' }
            $latencies.Add([int]$matchesForSwitch[0].Matches[0].Groups[1].Value)
        }
        $latencies | ConvertTo-Json | Set-Content (Join-Path $run 'tab-switch-ms.json')
        $sorted = @($latencies | Sort-Object)
        Write-Host "Tab dispatch-to-present ms: median=$($sorted[[int][math]::Floor($sorted.Count/2)]) p95=$($sorted[[int][math]::Floor(($sorted.Count-1)*0.95)])"
        Sample 'after-tab-switches'
    }
    if ($ProbeHiddenHosts) {
        [ResourceNative]::ShrinkHiddenHosts($terminal)
        Sample 'hidden-hosts-shrunk'
        [ResourceNative]::RestoreHosts()
        Sample 'hidden-hosts-restored'
    }
    if ($TabsOnly) {
        Save-Results
        Write-Host "Results: $run"
        return
    }
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
    Save-Results
    Write-Host "Results: $run"
} finally {
    try {
        if (!$app.HasExited -and $GracefulExit -and $terminal) {
            [void][ResourceNative]::PostMessage($terminal,0x10,0,0)
            if (!$app.WaitForExit(15000)) { throw 'Application did not exit after closing its final window' }
            if ($app.ExitCode -ne 0) { throw "Application exited with code $($app.ExitCode)" }
            Write-Host 'Graceful exit passed'
        }
    } finally {
        if (!$app.HasExited) { Stop-Process -Id $app.Id }
        $app.Dispose()
    }
}
