param(
    [string]$Executable = "$PSScriptRoot/../../zig-out/bin/ghostty.exe",
    [string]$Artifacts = "$env:TEMP/yuurei-settings-smoke",
    [switch]$KeepOpen,
    [switch]$RenderingChecks,
    [ValidateRange(0,4)][int]$RendererWorkers = 2,
    [switch]$GraphicsStress
)
$ErrorActionPreference = 'Stop'
if ($GraphicsStress) { $RenderingChecks = $true }
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SettingsNative {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h, string s);
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendText(IntPtr h, uint m, IntPtr w, string text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiInfo {
        public uint size, flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public Rect caretRect;
    }
    public static IntPtr Focus(IntPtr window) {
        uint process; uint thread = GetWindowThreadProcessId(window, out process);
        var info = new GuiInfo(); info.size = (uint)Marshal.SizeOf<GuiInfo>();
        if (!GetGUIThreadInfo(thread, ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info.focus;
    }
    public static int VisibleHosts(IntPtr window) {
        int count=0;
        EnumChildWindows(window,(h,l) => {
            var name=new StringBuilder(64); GetClassName(h,name,name.Capacity);
            if (name.ToString()=="ghostty-host" && IsWindowVisible(h)) count++;
            return true;
        },IntPtr.Zero);
        return count;
    }
    public static IntPtr Find(uint process, string name) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h,l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != process) return true;
            var s = new StringBuilder(256); GetClassName(h,s,s.Capacity);
            if (s.ToString() == name) { result = h; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Wait-Window([string]$Class) {
    for ($i = 0; $i -lt 100; $i++) {
        $h = [SettingsNative]::Find($script:appProcess.Id, $Class)
        if ($h -ne [IntPtr]::Zero) { return $h }
        if ($script:appProcess.HasExited) { throw "yuurei exited with $($script:appProcess.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    throw "Window $Class did not appear"
}
function Control([int]$Id) { return [SettingsNative]::GetDlgItem($script:settings, $Id) }
function Click([int]$Id) { [void][SettingsNative]::SendMessage((Control $Id), 0xF5, 0, 0); Start-Sleep -Milliseconds 120 }
function Edit([int]$Id, [string]$Value) {
    $h = Control $Id
    [void][SettingsNative]::SendText($h, 0xC, 0, $Value)
    $class = [Text.StringBuilder]::new(64)
    [void][SettingsNative]::GetClassName($h, $class, 64)
    if ($class.ToString() -eq 'ComboBox') {
        # WM_SETTEXT doesn't emit CBN_EDITCHANGE; reproduce the notification
        # that the native control emits when the user types into its edit.
        [void][SettingsNative]::SendMessage($script:settings, 0x111, ($Id -bor (5 -shl 16)), $h)
    }
    Start-Sleep -Milliseconds 120
}
function Capture([string]$Name, [IntPtr]$Window = $script:settings, [switch]$Desktop) {
    [void][SettingsNative]::SetThreadDpiAwarenessContext(-4)
    if ($Desktop) {
        [void][SettingsNative]::ShowWindow($Window, 5)
        [void][SettingsNative]::SetWindowPos($Window, -1, 40, 40, 1200, 800, 0)
    }
    Start-Sleep -Milliseconds 150
    $r = New-Object SettingsNative+Rect
    [void][SettingsNative]::GetWindowRect($Window, [ref]$r)
    $bitmap = [Drawing.Bitmap]::new($r.right - $r.left, $r.bottom - $r.top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    if ($Desktop) {
        try { $graphics.CopyFromScreen($r.left, $r.top, 0, 0, $bitmap.Size) }
        finally {
            $graphics.Dispose()
            [void][SettingsNative]::SetWindowPos($Window, -2, 0, 0, 0, 0, 0x13)
        }
    } else {
        $dc = $graphics.GetHdc()
        try { [void][SettingsNative]::PrintWindow($Window, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
    }
    try { $bitmap.Save((Join-Path $Artifacts "$Name.png")) } finally { $bitmap.Dispose() }
}

function Assert-TerminalPixels([string]$Name, [double]$MinBackgroundFraction = 0.8) {
    # The isolated config has a known background. Check the composed screen,
    # not just process survival: a successful SwapBuffers can still show a
    # blank or stale native backbuffer. Sample well inside the terminal area.
    $bitmap = [Drawing.Bitmap]::new((Join-Path $Artifacts "$Name.png"))
    try {
        $matching = 0; $total = 0; $text = 0
        for ($y=100; $y -lt $bitmap.Height-40; $y+=4) {
            for ($x=40; $x -lt $bitmap.Width-60; $x+=4) {
                $c=$bitmap.GetPixel($x,$y); $total++
                if ([math]::Abs([int]$c.R-40) -le 3 -and [math]::Abs([int]$c.G-44) -le 3 -and [math]::Abs([int]$c.B-52) -le 3) { $matching++ }
                if ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 180) { $text++ }
            }
        }
        Assert ($matching/$total -gt $MinBackgroundFraction) "$Name has a blank/stale terminal background ($matching/$total matching pixels)"
        Assert ($text -gt 20) "$Name has no visible terminal text"
    } finally { $bitmap.Dispose() }
}

function Assert-CategoryHighlight([int]$Selected, [bool]$Light = $false) {
    # Sample the displayed pixels without PrintWindow, resizing, or another
    # forced repaint: those would hide stale owner-drawn button contents.
    $bitmap = [Drawing.Bitmap]::new(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        foreach ($id in 20,21,22,23) {
            $r = New-Object SettingsNative+Rect
            [void][SettingsNative]::GetWindowRect((Control $id), [ref]$r)
            $graphics.CopyFromScreen($r.right - 20, [int](($r.top + $r.bottom)/2), 0, 0, $bitmap.Size)
            $expected = if ($id -eq $Selected) { if ($Light) { 0xD6E0EA } else { 0x2C394B } } else { if ($Light) { 0xE9EDF0 } else { 0x1C2028 } }
            $actual = $bitmap.GetPixel(0,0).ToArgb() -band 0xFFFFFF
            Assert ($actual -eq $expected) "Category $id has stale highlight (selected=$Selected, actual=$($actual.ToString('X6')))"
        }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Check-CategoryHighlights([bool]$Light = $false) {
    [void][SettingsNative]::SetWindowPos($script:settings, -1, 0, 0, 0, 0, 0x13)
    Start-Sleep -Milliseconds 200
    try {
        foreach ($id in 21,22,23,20) { Click $id; Assert-CategoryHighlight $id $Light }
        Edit 10 'folder'
        Assert-CategoryHighlight -1 $Light
        Edit 10 ''
        Assert-CategoryHighlight 20 $Light
    } finally { [void][SettingsNative]::SetWindowPos($script:settings, -2, 0, 0, 0, 0, 0x13) }
}

[void](New-Item -ItemType Directory -Force -Path $Artifacts)
$isolation = Join-Path $Artifacts ([Guid]::NewGuid().ToString('N'))
$configDir = Join-Path $isolation 'ghostty'
[void](New-Item -ItemType Directory -Force -Path $configDir)
$config = Join-Path $configDir 'config'
$initial = "# GUI smoke test`nkeybind = f12=open_config`nwindow-theme = dark`nfont-size = 12`nfont-family = Consolas`nfont-family = Cascadia Mono`nwindows-restore-session = false`nconfirm-close-surface = false`n"
if ($RenderingChecks) {
    $initial += "keybind = f1=toggle_split_zoom`nkeybind = f6=next_tab`n"
    $initial += "background = #282c34`nforeground = #ffffff`ncommand = cmd.exe /Q /K echo YUUREI RENDER CHECK`nkeybind = f10=new_tab`nkeybind = f9=close_surface`nkeybind = f8=new_split:right`nkeybind = f11=inspector:toggle`n"
}
if ($GraphicsStress) {
    $bulk = Join-Path $isolation 'bulk.vt'
    $done = Join-Path $isolation 'burst.done'
    $writer = [IO.StreamWriter]::new($bulk, $false, [Text.UTF8Encoding]::new($false))
    try {
        for ($i=0; $i -lt 20000; $i++) { $writer.WriteLine("$([char]27)[32m$i 日本語 Ελληνικά 👻 build output$([char]27)[0m") }
        $writer.WriteLine('YUUREI BURST COMPLETE')
    } finally { $writer.Dispose() }
    $emitter = Join-Path $isolation 'emit.ps1'
    @'
param([string]$InputFile, [string]$DoneFile)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Write([IO.File]::ReadAllText($InputFile, [Text.Encoding]::UTF8))
[IO.File]::WriteAllText($DoneFile, 'done')
'@ | Set-Content -LiteralPath $emitter
    $command = ('pwsh -NoProfile -File "{0}" "{1}" "{2}"' -f $emitter,$bulk,$done).Replace('\','\\')
    $initial += "keybind = f7=reload_config`nkeybind = f6=next_tab`nkeybind = f5=text:$command\r`n"
    $busy = Join-Path $isolation 'busy.ps1'
    @'
$until = [DateTime]::UtcNow.AddSeconds(20)
$i = 0
while ([DateTime]::UtcNow -lt $until) {
    for ($j=0; $j -lt 16; $j++) { [Console]::WriteLine("{0:D8} worker output" -f $i); $i++ }
    [Threading.Thread]::Sleep(20)
}
'@ | Set-Content -LiteralPath $busy
    $busyCommand = ('pwsh -NoProfile -File "{0}"' -f $busy).Replace('\','\\')
    $initial += "keybind = f2=last_tab`nkeybind = f3=text:$busyCommand\r`nkeybind = f4=goto_split:next`n"
}
[IO.File]::WriteAllText($config, $initial)
$script:appProcess = Start-Process -FilePath (Resolve-Path $Executable) -PassThru -WindowStyle Hidden -Environment @{ XDG_CONFIG_HOME = $isolation; LOCALAPPDATA = $isolation; GHOSTTY_RENDER_WORKERS = "$RendererWorkers" } -RedirectStandardError (Join-Path $isolation 'stderr.log')
try {
    $terminal = Wait-Window 'ghostty'
    if ($RenderingChecks) {
        [void][SettingsNative]::ShowWindow($terminal, 5)
        Start-Sleep -Milliseconds 600
        Capture 'render-terminal' -Window $terminal -Desktop
        Assert-TerminalPixels 'render-terminal'
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x79, 0)
        Start-Sleep -Milliseconds 300
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x77, 0)
        Start-Sleep -Milliseconds 600
        Capture 'render-tabs-split' -Window $terminal -Desktop
        Assert-TerminalPixels 'render-tabs-split'
        Assert ([SettingsNative]::VisibleHosts($terminal) -eq 2) 'Both splits must be visible'
        [void][SettingsNative]::PostMessage($terminal,0x100,0x70,0)
        Start-Sleep -Milliseconds 300
        Assert ([SettingsNative]::VisibleHosts($terminal) -eq 1) 'Zoom must hide the other split'
        # Queue rapid transitions to reject stale frame-completion messages.
        for ($i=0; $i -lt 40; $i++) { [void][SettingsNative]::PostMessage($terminal,0x100,0x75,0) }
        Start-Sleep -Milliseconds 800
        $visibleAfterBurst=[SettingsNative]::VisibleHosts($terminal)
        if ($visibleAfterBurst -ne 1) {
            Write-Host "Rapid-switch restoration pending after 800 ms: $visibleAfterBurst visible hosts"
            for ($settle=0; $settle -lt 50 -and [SettingsNative]::VisibleHosts($terminal) -ne 1; $settle++) { Start-Sleep -Milliseconds 100 }
            Write-Host "Rapid-switch restoration settled after $($settle*100) additional ms"
        }
        Assert ([SettingsNative]::VisibleHosts($terminal) -eq 1) "Returning to a zoomed tab must retain zoom ($([SettingsNative]::VisibleHosts($terminal)) hosts visible)"
        Capture 'render-zoom-restored' -Window $terminal -Desktop
        Assert-TerminalPixels 'render-zoom-restored'
        [void][SettingsNative]::ShowWindow($terminal,6)
        Start-Sleep -Milliseconds 200
        [void][SettingsNative]::ShowWindow($terminal,9)
        [void][SettingsNative]::PostMessage($terminal,0x100,0x70,0)
        Start-Sleep -Milliseconds 500
        Assert ([SettingsNative]::VisibleHosts($terminal) -eq 2) 'Unzoom must restore both splits'
        Capture 'render-unzoom-restored' -Window $terminal -Desktop
        Assert-TerminalPixels 'render-unzoom-restored'
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x78, 0)
        Start-Sleep -Milliseconds 200
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x78, 0)
        Start-Sleep -Milliseconds 200
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x7A, 0)
        $inspector = Wait-Window 'ghostty-inspector'
        Capture 'render-inspector' -Window $inspector -Desktop
        [void][SettingsNative]::PostMessage($inspector, 0x10, 0, 0)
        Start-Sleep -Milliseconds 150
    }
    if ($GraphicsStress) {
        $shader = Join-Path $isolation 'stress.glsl'
        $source = [Text.StringBuilder]::new("float f0(vec2 p) { return p.x; }`n")
        for ($i=1; $i -le 128; $i++) { [void]$source.AppendLine("float f$i(vec2 p) { return f$($i-1)(p)*0.999+0.001; }") }
        [void]$source.AppendLine('void mainImage(out vec4 color, in vec2 coord) { color = texture(iChannel0, coord/iResolution.xy) + vec4(f128(coord)*0.000001); }')
        [IO.File]::WriteAllText($shader,$source.ToString())
        [IO.File]::WriteAllText($config,$initial+"custom-shader = $($shader.Replace('\','/'))`ncustom-shader-animation = false`n")
        [void][SettingsNative]::PostMessage($terminal,0x100,0x76,0)
        Start-Sleep -Milliseconds 750
        Capture 'graphics-shader-single' -Window $terminal -Desktop
        Assert-TerminalPixels 'graphics-shader-single'
        for ($i=0; $i -lt 7; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x79,0)
            Start-Sleep -Milliseconds 350
        }
        for ($i=0; $i -lt 3; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x77,0)
            Start-Sleep -Milliseconds 350
        }
        for ($i=0; $i -lt 10; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x76,0)
            Start-Sleep -Milliseconds 500
            [void][SettingsNative]::PostMessage($terminal,0x100,0x75,0)
            Start-Sleep -Milliseconds 250
            Assert (!$script:appProcess.HasExited) 'Application exited during shader reload and tab switching'
        }
        [void][SettingsNative]::PostMessage($terminal,0x100,0x74,0)
        for ($i=0; $i -lt 300 -and !(Test-Path -LiteralPath $done); $i++) {
            Start-Sleep -Milliseconds 100
            Assert (!$script:appProcess.HasExited) 'Application exited during bulk output'
        }
        Assert (Test-Path -LiteralPath $done) 'Bulk-output command did not finish'
        Start-Sleep -Seconds 1
        Capture 'graphics-stress' -Window $terminal -Desktop
        Assert-TerminalPixels 'graphics-stress' -MinBackgroundFraction 0.4
        # The last tab has four splits. Keep all four producing while checking
        # that each portion of the composed screen continues to change.
        [void][SettingsNative]::PostMessage($terminal,0x100,0x71,0)
        Start-Sleep -Milliseconds 350
        for ($i=0; $i -lt 4; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x72,0)
            Start-Sleep -Milliseconds 250
            [void][SettingsNative]::PostMessage($terminal,0x100,0x73,0)
            Start-Sleep -Milliseconds 100
        }
        Start-Sleep -Seconds 2
        Capture 'graphics-busy-splits-a' -Window $terminal -Desktop
        Start-Sleep -Milliseconds 350
        Capture 'graphics-busy-splits-b' -Window $terminal -Desktop
        Assert-TerminalPixels 'graphics-busy-splits-b' -MinBackgroundFraction 0.4
        $first = [Drawing.Bitmap]::new((Join-Path $Artifacts 'graphics-busy-splits-a.png'))
        $second = [Drawing.Bitmap]::new((Join-Path $Artifacts 'graphics-busy-splits-b.png'))
        try {
            # Repeated right splits divide the client into 1/2, 1/4, 1/8,
            # 1/8. Sample each interior broadly: a narrow strip can contain
            # only the unchanged leading zeros of the output counter.
            foreach ($bounds in @(@(0.02,0.48),@(0.51,0.72),@(0.755,0.85),@(0.88,0.965))) {
                $changed = 0
                $left = [int]($first.Width*$bounds[0])
                $right = [int]($first.Width*$bounds[1])
                for ($y=110; $y -lt $first.Height-100; $y+=3) {
                    for ($x=$left; $x -lt $right; $x+=2) {
                        if ($first.GetPixel($x,$y).ToArgb() -ne $second.GetPixel($x,$y).ToArgb()) { $changed++ }
                    }
                }
                Assert ($changed -gt 20) "Busy split at $left stopped presenting ($changed changed samples)"
            }
        } finally { $first.Dispose(); $second.Dispose() }
        # Close while output is still arriving to exercise callback teardown.
        for ($i=0; $i -lt 10; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x78,0)
            Start-Sleep -Milliseconds 250
        }
        [IO.File]::WriteAllText($config,$initial)
        [void][SettingsNative]::PostMessage($terminal,0x100,0x76,0)
        Start-Sleep -Milliseconds 500
        Assert (!$script:appProcess.HasExited) 'Application exited while closing stress surfaces'
        Capture 'graphics-restored' -Window $terminal -Desktop
        Assert-TerminalPixels 'graphics-restored'
    }
    [void][SettingsNative]::PostMessage($terminal, 0x100, 0x7B, 0x00580001)
    $script:settings = Wait-Window 'ghostty-settings'
    [void][SettingsNative]::ShowWindow($script:settings, 5)
    Capture 'dark-appearance'
    Check-CategoryHighlights
    [void][SettingsNative]::SendMessage($script:settings, 0x28, (Control 10), 1)
    [void][SettingsNative]::PostMessage((Control 10), 0x100, 9, 0)
    Start-Sleep -Milliseconds 100
    Assert ([SettingsNative]::Focus($script:settings) -eq (Control 20)) 'Tab should move from search to categories'
    foreach ($id in 20,21,22,23) {
        [void][SettingsNative]::PostMessage((Control $id), 0x100, 9, 0)
        Start-Sleep -Milliseconds 60
    }
    $focus = [SettingsNative]::Focus($script:settings)
    Assert ($focus -eq (Control 100) -or [SettingsNative]::IsChild((Control 100), $focus)) 'Tab should reach settings before footer actions'
    Assert ([SettingsNative]::SendMessage((Control 100), 0x146, 0, 0).ToInt64() -gt 0) 'Theme dropdown was not populated'
    Assert (![SettingsNative]::IsWindowEnabled((Control 11))) 'Save should start disabled'
    Edit 102 '15.5'
    Assert ([SettingsNative]::IsWindowEnabled((Control 11))) 'Editing should enable Save'
    Assert ([IO.File]::ReadAllText($config) -eq $initial) 'Edits must remain staged'
    Click 11
    $saved = [IO.File]::ReadAllText($config)
    Assert ($saved.Contains('font-size = 15.5')) 'Font size was not saved'
    Assert ($saved.Contains('font-family = Cascadia Mono')) 'Unedited fallback font was lost'
    Assert (![SettingsNative]::IsWindowEnabled((Control 11))) 'Save should clear dirty state'
    Edit 102 'nan'
    Click 11
    Assert ([IO.File]::ReadAllText($config) -eq $saved) 'Invalid font size changed config'
    Capture 'validation'
    Edit 102 '15.5'
    Edit 100 'yuurei-nonexistent-theme-smoke'
    Click 11
    Assert ([IO.File]::ReadAllText($config) -eq $saved) 'Unknown theme changed config'
    Edit 100 'Catppuccin Mocha'
    Click 11
    Assert ([IO.File]::ReadAllText($config).Contains('theme = Catppuccin Mocha')) 'Theme choice did not save'
    Edit 10 'folder'
    Assert (![SettingsNative]::IsWindowVisible((Control 102))) 'Search did not hide nonmatching controls'
    Assert ([SettingsNative]::IsWindowVisible((Control 113))) 'Search did not find folder inheritance'
    Capture 'search'
    Edit 10 'this-setting-does-not-exist'
    Capture 'empty-search'
    Edit 10 ''
    Click 22
    Capture 'windows-tabs'
    Click 23
    $beforeToggle = [SettingsNative]::SendMessage((Control 116), 0xF0, 0, 0)
    Click 116
    Assert ([SettingsNative]::SendMessage((Control 116), 0xF0, 0, 0) -ne $beforeToggle) 'Native toggle did not change state'
    [void][SettingsNative]::SendMessage($script:settings, 0x28, (Control 116), 1)
    [void][SettingsNative]::PostMessage((Control 116), 0x100, 0x20, 0)
    [void][SettingsNative]::PostMessage((Control 116), 0x101, 0x20, 0)
    Start-Sleep -Milliseconds 100
    Assert ([SettingsNative]::SendMessage((Control 116), 0xF0, 0, 0) -eq $beforeToggle) 'Space should toggle a focused checkbox'
    Capture 'input'
    Edit 117 'To clipboard'
    Click 11
    Assert ([IO.File]::ReadAllText($config).Contains('copy-on-select = clipboard')) 'Friendly choice label was not converted to config value'
    Click 21
    [void][SettingsNative]::SendMessage((Control 108), 0x14E, 1, 0)
    [void][SettingsNative]::SendMessage($script:settings, 0x111, (108 -bor (1 -shl 16)), (Control 108))
    Start-Sleep -Milliseconds 100
    Edit 106 'cmd.exe'
    Click 11
    Assert ([IO.File]::ReadAllText($config).Contains('command = cmd.exe')) 'Shell selection did not save'
    Assert ([IO.File]::ReadAllText($config).Contains('cursor-style = bar')) 'Native dropdown selection did not save'
    Capture 'terminal'
    Click 20
    Click 202
    Click 11
    Assert (![IO.File]::ReadAllText($config).Contains('font-size =')) 'Reset failed to remove font size'
    Edit 102 '16'
    [IO.File]::AppendAllText($config, "# external edit`n")
    $external = [IO.File]::ReadAllText($config)
    Click 11
    Assert ([IO.File]::ReadAllText($config) -eq $external) 'Save overwrote an external edit'
    Capture 'external-conflict'
    # Revert prompts before discarding; answer only this test process's dialog.
    [void][SettingsNative]::PostMessage((Control 12), 0xF5, 0, 0)
    $dialog = Wait-Window '#32770'
    [void][SettingsNative]::PostMessage($dialog, 0x111, 6, 0)
    Start-Sleep -Milliseconds 150
    Assert (![SettingsNative]::IsWindowEnabled((Control 11))) 'Revert did not clear dirty state'
    Assert ([IO.File]::ReadAllText($config) -eq $external) 'Revert changed the external file'
    [void][SettingsNative]::PostMessage($script:settings, 0x10, 0, 0)
    Start-Sleep -Milliseconds 150
    [IO.File]::AppendAllText($config, "window-theme = light`n")
    # Reload the application before opening settings for the light palette.
    [void][SettingsNative]::PostMessage($terminal, 0x10, 0, 0)
    [void]$script:appProcess.WaitForExit(5000)
    Assert ($script:appProcess.HasExited) 'Test application did not close'
    $script:appProcess = Start-Process -FilePath (Resolve-Path $Executable) -PassThru -WindowStyle Hidden -Environment @{ XDG_CONFIG_HOME = $isolation; LOCALAPPDATA = $isolation } -RedirectStandardError (Join-Path $isolation 'light-stderr.log')
    $terminal = Wait-Window 'ghostty'
    [void][SettingsNative]::PostMessage($terminal, 0x100, 0x7B, 0x00580001)
    $script:settings = Wait-Window 'ghostty-settings'
    [void][SettingsNative]::ShowWindow($script:settings, 5)
    Capture 'light-appearance'
    Check-CategoryHighlights $true
    [void][SettingsNative]::SetWindowPos($script:settings, 0, 0, 0, 820, 650, 0x6)
    Capture 'minimum-size'
    Write-Output "Settings smoke tests passed. Screenshots: $Artifacts"
} finally {
    if (!$KeepOpen -and !$script:appProcess.HasExited) {
        # Only terminate the isolated process this script created.
        Stop-Process -Id $script:appProcess.Id
    }
}
