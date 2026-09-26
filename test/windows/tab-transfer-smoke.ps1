param(
    [string]$Executable = "$PSScriptRoot/../../zig-out/bin/ghostty.exe",
    [string]$Artifacts = "$env:TEMP/yuurei-tab-transfer"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class TabNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder name, int size);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref Point p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static IntPtr[] Windows(uint pid) {
        var result=new List<IntPtr>();
        EnumWindows((h,p)=>{uint owner; GetWindowThreadProcessId(h,out owner); if(owner==pid && Class(h)=="ghostty") result.Add(h); return true;},IntPtr.Zero);
        return result.ToArray();
    }
    public static IntPtr[] Hosts(IntPtr window, bool visible) {
        var result=new List<IntPtr>();
        EnumChildWindows(window,(h,p)=>{if(Class(h)=="ghostty-host" && (!visible || IsWindowVisible(h))) result.Add(h); return true;},IntPtr.Zero);
        return result.ToArray();
    }
    static string Class(IntPtr h) { var name=new StringBuilder(128); GetClassName(h,name,128); return name.ToString(); }
}
'@
[void][TabNative]::SetThreadDpiAwarenessContext(-4)
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
function Wait-For([scriptblock]$Condition, [string]$Message) {
    for ($i=0; $i -lt 100; $i++) { if (& $Condition) { return }; Start-Sleep -Milliseconds 100 }
    throw $Message
}
function Key($Window, [int]$VirtualKey) {
    [void][TabNative]::PostMessage($Window, 0x100, $VirtualKey, 0)
    [void][TabNative]::PostMessage($Window, 0x101, $VirtualKey, 0)
    Start-Sleep -Milliseconds 200
}
function Packed($Point) { return [IntPtr]([int](($Point.x -band 0xFFFF) -bor (($Point.y -band 0xFFFF) -shl 16))) }
function Check-Rendering($Window, [string]$Name) {
    [void][TabNative]::SetForegroundWindow($Window)
    Start-Sleep -Milliseconds 250
    $hostWindow = [TabNative]::Hosts($Window,$true)[0]
    $r = New-Object TabNative+Rect
    [void][TabNative]::GetWindowRect($hostWindow,[ref]$r)
    $bitmap = [Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size)
        $bitmap.Save((Join-Path $isolation "$Name.png"))
        $background=0; $text=0; $total=0
        for ($y=8; $y -lt $bitmap.Height-8; $y+=4) {
            for ($x=8; $x -lt $bitmap.Width-8; $x+=4) {
                $c=$bitmap.GetPixel($x,$y); $total++
                if ([math]::Abs([int]$c.R-40) -le 3 -and [math]::Abs([int]$c.G-44) -le 3 -and [math]::Abs([int]$c.B-52) -le 3) { $background++ }
                if ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 180) { $text++ }
            }
        }
        Assert ($background/$total -gt 0.8 -and $text -gt 10) "$Name lost terminal rendering"
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Drag($Source, [int]$Tab, $Target, [int]$TargetX = 30, [int]$TargetY = 18, [switch]$Cancel) {
    $scale = [TabNative]::GetDpiForWindow($Source)/96.0
    $from = New-Object TabNative+Point
    $from.x = [int]((8 + $Tab*190 + 40)*$scale); $from.y = [int](18*$scale)
    $screen = New-Object TabNative+Point
    $screen.x = [int]($TargetX*[TabNative]::GetDpiForWindow($Target)/96.0)
    $screen.y = [int]($TargetY*[TabNative]::GetDpiForWindow($Target)/96.0)
    [void][TabNative]::ClientToScreen($Target,[ref]$screen)
    $to = $screen
    [void][TabNative]::ScreenToClient($Source,[ref]$to)
    [void][TabNative]::SetForegroundWindow($Source)
    # Put the real pointer at the press point too. SetCapture can queue a
    # native WM_MOUSEMOVE; leaving it at the previous drop position would
    # make that queued move reorder a tab during this synthetic press.
    $pressScreen = $from
    [void][TabNative]::ClientToScreen($Source,[ref]$pressScreen)
    [void][TabNative]::SetCursorPos($pressScreen.x,$pressScreen.y)
    Start-Sleep -Milliseconds 100
    [void][TabNative]::SendMessage($Source,0x201,1,(Packed $from))
    [void][TabNative]::SetCursorPos($screen.x,$screen.y)
    [void][TabNative]::SendMessage($Source,0x200,1,(Packed $to))
    Start-Sleep -Milliseconds 150
    if ($Cancel) { [void][TabNative]::SendMessage($Source,0x215,0,0) }
    [void][TabNative]::SendMessage($Source,0x202,0,(Packed $to))
    Start-Sleep -Milliseconds 400
}
$isolation = Join-Path $Artifacts ([guid]::NewGuid().ToString('N'))
$configDir = Join-Path $isolation 'ghostty'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$counter = Join-Path $isolation 'counter.txt'
$command = ('set /a YUUREI_TRANSFER+=1 > "{0}"' -f $counter).Replace('\','\\')
@"
command = cmd.exe /D /Q /K set YUUREI_TRANSFER=0
background = #282c34
foreground = #ffffff
windows-restore-session = false
confirm-close-surface = false
keybind = f2=new_window
keybind = f3=new_tab
keybind = f4=new_split:right
keybind = f5=text:$command\r
keybind = f6=toggle_split_zoom
keybind = f7=close_surface
"@ | Set-Content (Join-Path $configDir 'config')
$app = Start-Process -FilePath (Resolve-Path $Executable) -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$isolation; LOCALAPPDATA=$isolation} -RedirectStandardError (Join-Path $isolation 'stderr.log')
try {
    Wait-For { [TabNative]::Windows($app.Id).Count -eq 1 } 'Initial window did not open'
    $source = [TabNative]::Windows($app.Id)[0]
    [void][TabNative]::ShowWindow($source,5)
    [void][TabNative]::SetWindowPos($source,0,40,50,1200,900,0)
    Key $source 0x72 # new tab
    Key $source 0x73 # split
    Wait-For { [TabNative]::Hosts($source,$false).Count -eq 3 } 'Split tab did not open'
    $movedHosts = [TabNative]::Hosts($source,$true)
    Assert ($movedHosts.Count -eq 2) 'Expected two visible splits'
    Key $source 0x74
    Wait-For { (Test-Path $counter) -and (Get-Content $counter -Raw).Trim() -eq '1' } 'Initial shell command failed'
    Key $source 0x75 # zoom
    Key $source 0x71 # second window
    Wait-For { [TabNative]::Windows($app.Id).Count -eq 2 } 'Destination did not open'
    $target = @([TabNative]::Windows($app.Id) | Where-Object { $_ -ne $source })[0]
    [void][TabNative]::SetWindowPos($target,0,1300,50,1200,900,0)
    Drag $source 1 $target -Cancel
    Assert ([TabNative]::Hosts($source,$false).Count -eq 3) 'Cancelled drag moved a tab'
    Drag $source 1 $target
    Assert ([TabNative]::Windows($app.Id).Count -eq 2) 'Drop created an unwanted third window'
    Assert ([TabNative]::Hosts($source,$false).Count -eq 1) "Source retained transferred surfaces ($([TabNative]::Hosts($source,$false).Count) source, $([TabNative]::Hosts($target,$false).Count) destination)"
    foreach ($hostHandle in $movedHosts) { Assert ([TabNative]::Hosts($target,$false) -contains $hostHandle) 'Live surface was replaced instead of transferred' }
    Assert ([TabNative]::Hosts($target,$true).Count -eq 1) 'Transfer lost split zoom'
    Key $target 0x74
    Wait-For { (Get-Content $counter -Raw).Trim() -eq '2' } 'Transfer lost running shell state or input routing'
    Check-Rendering $target 'transferred-zoomed'
    Key $target 0x75
    Assert ([TabNative]::Hosts($target,$true).Count -eq 2) 'Transferred splits did not unzoom'
    # Tear the transferred tab back out, then merge its sole tab again.
    Drag $target 0 $target 100 200
    Wait-For { [TabNative]::Windows($app.Id).Count -eq 3 } 'Tear-off stopped working'
    $detached = @([TabNative]::Windows($app.Id) | Where-Object { $_ -ne $source -and $_ -ne $target })[0]
    [void][TabNative]::SetWindowPos($detached,0,40,1000,1200,900,0)
    Drag $detached 0 $source
    Wait-For { ![TabNative]::IsWindow($detached) } 'Empty source window stayed open'
    Assert ([TabNative]::Windows($app.Id).Count -eq 2) 'Wrong window count after round trip'
    foreach ($hostHandle in $movedHosts) { Assert ([TabNative]::Hosts($source,$false) -contains $hostHandle) 'Round trip replaced a surface' }
    Key $source 0x74
    Wait-For { (Get-Content $counter -Raw).Trim() -eq '3' } 'Round trip lost shell state'
    Check-Rendering $source 'round-trip'
    Key $source 0x76
    Assert ([TabNative]::Hosts($source,$false).Count -eq 2) 'Closing a transferred split failed'
    Write-Output "Tab transfer smoke tests passed. Artifacts: $isolation"
} finally {
    if (!$app.HasExited) { $app.Kill(); $app.WaitForExit() }
}
