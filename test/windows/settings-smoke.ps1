param(
    [string]$Executable = "$PSScriptRoot/../../zig-out/bin/ghostty.exe",
    [string]$Artifacts = "$env:TEMP/yuurei-settings-smoke",
    [switch]$KeepOpen,
    [switch]$RenderingChecks,
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

[void](New-Item -ItemType Directory -Force -Path $Artifacts)
$isolation = Join-Path $Artifacts ([Guid]::NewGuid().ToString('N'))
$configDir = Join-Path $isolation 'ghostty'
[void](New-Item -ItemType Directory -Force -Path $configDir)
$config = Join-Path $configDir 'config'
$initial = "# GUI smoke test`nkeybind = f12=open_config`nwindow-theme = dark`nfont-size = 12`nfont-family = Consolas`nfont-family = Cascadia Mono`nwindows-restore-session = false`nconfirm-close-surface = false`n"
if ($RenderingChecks) {
    $initial += "command = cmd.exe /Q /K echo YUUREI RENDER CHECK`nkeybind = f10=new_tab`nkeybind = f9=close_surface`nkeybind = f8=new_split:right`nkeybind = f11=inspector:toggle`n"
}
if ($GraphicsStress) {
    $bulk = Join-Path $isolation 'bulk.vt'
    $done = Join-Path $isolation 'burst.done'
    $writer = [IO.StreamWriter]::new($bulk, $false, [Text.UTF8Encoding]::new($false))
    try {
        for ($i=0; $i -lt 20000; $i++) { $writer.WriteLine("$([char]27)[32m$i 日本語 Ελληνικά 👻 build output$([char]27)[0m") }
        $writer.WriteLine('YUUREI BURST COMPLETE')
    } finally { $writer.Dispose() }
    $command = ('chcp 65001 >nul & type "{0}" & echo done>"{1}"' -f $bulk,$done).Replace('\','\\')
    $initial += "keybind = f7=reload_config`nkeybind = f6=next_tab`nkeybind = f5=text:$command\r`n"
}
[IO.File]::WriteAllText($config, $initial)
$script:appProcess = Start-Process -FilePath (Resolve-Path $Executable) -PassThru -WindowStyle Hidden -Environment @{ XDG_CONFIG_HOME = $isolation; LOCALAPPDATA = $isolation } -RedirectStandardError (Join-Path $isolation 'stderr.log')
try {
    $terminal = Wait-Window 'ghostty'
    if ($RenderingChecks) {
        [void][SettingsNative]::ShowWindow($terminal, 5)
        Start-Sleep -Milliseconds 600
        Capture 'render-terminal' -Window $terminal -Desktop
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x79, 0)
        Start-Sleep -Milliseconds 300
        [void][SettingsNative]::PostMessage($terminal, 0x100, 0x77, 0)
        Start-Sleep -Milliseconds 600
        Capture 'render-tabs-split' -Window $terminal -Desktop
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
        for ($i=0; $i -lt 10; $i++) {
            [void][SettingsNative]::PostMessage($terminal,0x100,0x78,0)
            Start-Sleep -Milliseconds 250
        }
        [IO.File]::WriteAllText($config,$initial)
        [void][SettingsNative]::PostMessage($terminal,0x100,0x76,0)
        Start-Sleep -Milliseconds 500
        Assert (!$script:appProcess.HasExited) 'Application exited while closing stress surfaces'
    }
    [void][SettingsNative]::PostMessage($terminal, 0x100, 0x7B, 0x00580001)
    $script:settings = Wait-Window 'ghostty-settings'
    [void][SettingsNative]::ShowWindow($script:settings, 5)
    Capture 'dark-appearance'
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
    [void][SettingsNative]::SetWindowPos($script:settings, 0, 0, 0, 820, 650, 0x6)
    Capture 'minimum-size'
    Write-Output "Settings smoke tests passed. Screenshots: $Artifacts"
} finally {
    if (!$KeepOpen -and !$script:appProcess.HasExited) {
        # Only terminate the isolated process this script created.
        Stop-Process -Id $script:appProcess.Id
    }
}
