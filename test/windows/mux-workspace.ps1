#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-workspace-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type 'using System; using System.Runtime.InteropServices; public static class WorkspaceCapture { [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags); }'
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Set-Content "$PSScriptRoot/$PID.started" $PID
[Console]::WriteLine("PERSISTENT_PID=$PID 日本語 🚀")
while($true){$key=[Console]::ReadKey($true);Set-Content "$PSScriptRoot/$PID.input" "$($key.KeyChar)";[Console]::WriteLine("INPUT=$($key.KeyChar) PID=$PID")}
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
@"
windows-persistent-sessions = true
windows-restore-session = true
windows-workspace = dev
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f3=text:x
keybind = f4=new_tab
keybind = f5=new_split:right
keybind = f6=new_split:down
keybind = f7=toggle_split_zoom
keybind = f8=goto_tab:1
keybind = f9=set_tab_title:Project
"@ | Set-Content "$dir/ghostty/config" -Encoding utf8
function Mux([string[]]$Arguments){
 $psi=[Diagnostics.ProcessStartInfo]::new("$Bin/yuurei-mux.exe")
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.Environment['LOCALAPPDATA']=$dir
 foreach($arg in $Arguments){$psi.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($psi)
 try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(!$p.WaitForExit(10000)){$p.Kill();throw 'Helper timeout'};$result=$out.GetAwaiter().GetResult();$log=$err.GetAwaiter().GetResult();if($p.ExitCode -ne 0){throw $log};return $result}finally{$p.Dispose()}
}
function Launch([string]$Label,[string[]]$Arguments=@()) {
 $params=@{FilePath="$Bin/ghostty.exe";WindowStyle='Hidden';PassThru=$true;Environment=@{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'};RedirectStandardError="$dir/$Label.log"}
 if($Arguments.Count){$params.ArgumentList=$Arguments}
 return Start-Process @params
}
function LayoutPath([string]$Name){$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Name))).ToLowerInvariant();return "$dir/ghostty/workspace-$hash"}
$layout=LayoutPath 'dev';$gui=$null;$other=$null
try{
 $gui=Launch 'initial'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Initial window missing'
 $window=[TabNative]::Windows($gui.Id)[0]
 [void][TabNative]::ShowWindow($window,5)
 Key $window 0x74 # F5 split right
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 2} 'Right split failed'
 Key $window 0x75 # F6 split down
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 3} 'Down split failed'
 Key $window 0x78 # F9 title
 Key $window 0x76 # F7 zoom
 Key $window 0x73 # F4 new tab
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 4} 'Second tab failed'
 Key $window 0x77 # F8 first tab
 Wait-For {(Test-Path $layout) -and ((Get-Content $layout -Raw|ConvertFrom-Json).windows[0].tabs.Count -eq 2)} 'Layout was not autosaved'
 Start-Sleep -Milliseconds 700
 $before=Get-Content $layout -Raw|ConvertFrom-Json
 Assert ($before.windows[0].tabs[0].nodes.Count -eq 5) 'Split tree not serialized'
 Assert ($before.windows[0].tabs[0].title -eq 'Project' -and $null -ne $before.windows[0].tabs[0].zoomed) 'Title/zoom missing'
 $sessions=@(Mux @('list')|ConvertFrom-Json)
 Assert ($sessions.Count -eq 4) 'Expected four independent persistent panes'
 $ids=@($sessions.shell_pid|Sort-Object)
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 $gui=Launch 'restored'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Restored window missing'
 $window=[TabNative]::Windows($gui.Id)[0]
 Start-Sleep -Seconds 2
 $after=Get-Content $layout -Raw|ConvertFrom-Json
 Assert (($after.windows[0].tabs|ConvertTo-Json -Depth 10 -Compress) -eq ($before.windows[0].tabs|ConvertTo-Json -Depth 10 -Compress)) 'Restored layout changed'
 $restoredIds=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($restoredIds -join ',') -eq ($ids -join ',')) 'Restore replaced shells'
 Key $window 0x72 # F3 input into restored focused split
 Wait-For {@(Get-ChildItem "$dir/*.input").Count -eq 1} 'Restored split input failed'
 [void][TabNative]::ShowWindow($window,5)
 [void][TabNative]::SetForegroundWindow($window)
 Start-Sleep -Milliseconds 250
 $r=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($window,[ref]$r)
 $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$dc=$graphics.GetHdc();try{[void][WorkspaceCapture]::PrintWindow($window,$dc,2)}finally{$graphics.ReleaseHdc($dc)};$bitmap.Save("$dir/restored.png")}finally{$graphics.Dispose();$bitmap.Dispose()}
 # A forced second process must not overwrite the active workspace.
 $hash=(Get-FileHash $layout).Hash
 $other=Launch 'contender'
 Wait-For {[TabNative]::Windows($other.Id).Count -eq 1} 'Contender window missing'
 Start-Sleep -Seconds 1
 Assert ((Get-FileHash $layout).Hash -eq $hash) 'Concurrent process overwrote workspace'
 $other.Kill();$other.WaitForExit();$other.Dispose();$other=$null
 $other=Launch 'other-workspace' @('--windows-workspace=other')
 Wait-For {Test-Path (LayoutPath 'other')} 'Named workspace was not independent'
 Assert ((Get-FileHash $layout).Hash -eq $hash) 'Other workspace overwrote dev'
 Write-Output "PASS: four live panes, nested splits, focus/title/zoom restore after GUI crash, original PIDs, input, workspace ownership and isolation. Artifacts: $dir"
}finally{
 foreach($p in @($other,$gui)){if($p){if(!$p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
