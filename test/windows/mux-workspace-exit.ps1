#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-workspace-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Set-Content "$PSScriptRoot/$PID.started" $PID
[Console]::WriteLine("PERSISTENT_PID=$PID 日本語 🚀")
while(!(Test-Path "$PSScriptRoot/$PID.exit")){Start-Sleep -Milliseconds 100}
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
keybind = f10=session:terminate
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
$layout=LayoutPath 'dev';$gui=$null
try {
 $gui=Launch 'initial'
 Wait-For {(Test-Path $layout) -and @(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Initial layout missing'
 $first=@(Mux @('list')|ConvertFrom-Json)[0]
 Set-Content "$dir/$($first.shell_pid).exit" 'exit'
 Wait-For {$gui.HasExited} 'Shell exit did not close GUI'
 $gui.Dispose();$gui=$null
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 0} 'Ended broker remained registered'
 $stale=Get-Content $layout -Raw
 $gui=Launch 'reopened'
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Reopen did not start shell'
 $next=@(Mux @('list')|ConvertFrom-Json)[0]
 Assert ($first.name -ne $next.name) 'Ended session ID was restored'
 Assert (!(($stale|ConvertFrom-Json).windows.Count)) 'Ended last window remained saved'
 # Closing a window must detach and preserve the live shell/layout.
 $window=[TabNative]::Windows($gui.Id)[0]
 [void][TabNative]::PostMessage($window,0x10,0,0)
 Wait-For {$gui.HasExited} 'Window close failed'
 $gui.Dispose();$gui=Launch 'detached-restore'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Detached layout did not reopen'
 Start-Sleep -Milliseconds 500
 $restored=@(Mux @('list')|ConvertFrom-Json)
 Assert ($restored.Count -eq 1 -and $restored[0].shell_pid -eq $next.shell_pid) 'Ordinary close replaced the detached shell'
 # Keyboard termination must persist an empty workspace, just like shell exit.
 $window=[TabNative]::Windows($gui.Id)[0];Key $window 0x79
 Key $window 0x59
 Wait-For {$gui.HasExited} 'Keyboard termination did not close the last pane'
 $gui.Dispose();$gui=$null
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 0} 'Terminated broker remained registered'
 Assert (!((Get-Content $layout -Raw|ConvertFrom-Json).windows.Count)) 'Keyboard termination retained the ended session'
 [pscustomobject]@{artifacts=$dir;oldSession=$first.name;newSession=$next.name;oldPid=$first.shell_pid;newPid=$next.shell_pid;staleLayout=$stale} | ConvertTo-Json -Depth 5
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
