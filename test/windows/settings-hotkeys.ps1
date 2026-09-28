#requires -Version 7.0
# Run on an isolated Win32 desktop. Uses posted messages; never global input.
param([string]$Executable="$PSScriptRoot/../../zig-out/settings-hotkeys/bin/ghostty.exe", [string]$Artifacts="$env:TEMP/yuurei-settings-hotkeys")
$ErrorActionPreference='Stop'
$harness=Get-Content "$PSScriptRoot/settings-smoke.ps1" -Raw -Encoding utf8
$start=$harness.IndexOf('Add-Type -AssemblyName')
Invoke-Expression $harness.Substring($start,$harness.IndexOf('function Assert-TerminalPixels')-$start)
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HotkeyText {
 [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr Read(IntPtr h, uint m, IntPtr count, StringBuilder text);
}
"@
$isolation=Join-Path $Artifacts ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$isolation/ghostty" -Force | Out-Null
$Artifacts=$isolation
$config="$isolation/ghostty/config"
$initial="# Keep this comment`nwindows-auto-update = false`nwindows-persistent-sessions = false`nwindows-restore-session = false`nconfirm-close-surface = false`nkeybind = f12=open_config`n"
[IO.File]::WriteAllText($config,$initial,[Text.UTF8Encoding]::new($false))
function Key($h,[int]$vk){[void][SettingsNative]::PostMessage($h,0x100,$vk,0);[void][SettingsNative]::PostMessage($h,0x101,$vk,0);Start-Sleep -Milliseconds 150}
function Select-First(){
 [void][SettingsNative]::SendMessage((Control 500),0x186,0,0)
 [void][SettingsNative]::SendMessage($script:settings,0x111,(500 -bor (1 -shl 16)),(Control 500))
}
$script:appProcess=$null
try {
 $script:appProcess=Start-Process (Resolve-Path $Executable) -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$isolation;XDG_CONFIG_HOME=$isolation;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$isolation/stderr.log"
 $terminal=Wait-Window 'ghostty';[void][SettingsNative]::ShowWindow($terminal,5);Key $terminal 0x7B
 $script:settings=Wait-Window 'ghostty-settings'
 Click 25
 Assert ([SettingsNative]::IsWindowVisible((Control 500))) 'Shortcut list missing'
 Click 505;Edit 501 'f12';Edit 502 'new_window';Click 504
 Assert ((Get-Content $config -Raw) -eq $initial) 'Conflict altered config'
 Click 505;Click 503;Key (Control 501) 0x79
 $text=[Text.StringBuilder]::new(128);[void][HotkeyText]::Read((Control 501),0xD,128,$text)
 Assert ($text.ToString() -eq 'f10') "Key capture failed: [$($text.ToString())]"
 Edit 502 'new_split:right';Click 504
 Assert ((Get-Content $config -Raw) -eq $initial) 'Shortcut applied before Save'
 Capture 'staged'
 Click 11
 $saved=Get-Content $config -Raw
 Assert ($saved.Contains('keybind = f10=new_split:right')) 'Shortcut was not saved'
 Assert ($saved.Contains('# Keep this comment') -and $saved.Contains('keybind = f12=open_config')) 'Save damaged unrelated config'
 [void][SettingsNative]::PostMessage($script:settings,0x10,0,0)
 Start-Sleep -Milliseconds 250
 Key $terminal 0x79
 for($attempt=0;$attempt -lt 40 -and [SettingsNative]::VisibleHosts($terminal) -ne 2;$attempt++){Start-Sleep -Milliseconds 100}
 Assert ([SettingsNative]::VisibleHosts($terminal) -eq 2) 'Saved shortcut did not take effect without restart'
 Key $terminal 0x7B;$script:settings=Wait-Window 'ghostty-settings';Click 25
 Edit 10 'f10';Select-First;Click 506;Click 11
 Assert ((Get-Content $config -Raw).Contains('keybind = f10=unbind')) 'Disable was not persisted'
 Capture 'disabled'
 [void][SettingsNative]::PostMessage($script:settings,0x10,0,0)
 Start-Sleep -Milliseconds 250;Key $terminal 0x79
 Assert ([SettingsNative]::VisibleHosts($terminal) -eq 2) 'Disabled shortcut still executes'
 Key $terminal 0x7B;$script:settings=Wait-Window 'ghostty-settings';Click 25
 Click 505;Edit 501 'f11';Edit 502 'new_tab';Click 504
 Add-Content $config '# External edit'
 $external=Get-Content $config -Raw
 Click 11
 Assert ((Get-Content $config -Raw) -eq $external) 'Shortcut save overwrote an external edit'
 Write-Output "PASS: capture, conflict rejection, staging, live reload, disable, preservation and external-edit protection. Artifacts: $isolation"
}finally{
 if($script:appProcess){if(!$script:appProcess.HasExited){$script:appProcess.Kill();$script:appProcess.WaitForExit()};$script:appProcess.Dispose()}
}
