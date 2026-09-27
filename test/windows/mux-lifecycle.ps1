#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-lifecycle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty","$dir/working directory" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
@'
param([string]$Marker)
@{pid=$PID;cwd=[Environment]::CurrentDirectory;marker=$Marker;env=$env:YUUREI_MUX_TEST} | ConvertTo-Json | Set-Content "$PSScriptRoot/shell.json"
while($true){[Console]::WriteLine("SHELL_PID=$PID MARKER=$Marker");Start-Sleep -Milliseconds 100}
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1" -Marker "space & 日本語"
working-directory = $($dir.Replace('\','\\'))/working directory
env = YUUREI_MUX_TEST=owned
"@ | Set-Content "$dir/ghostty/config" -Encoding utf8
function Mux([string[]]$Arguments){
 $psi=[Diagnostics.ProcessStartInfo]::new("$Bin/yuurei-mux.exe")
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.Environment['LOCALAPPDATA']=$dir
 foreach($arg in $Arguments){$psi.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($psi)
 try{
  $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
  if(!$p.WaitForExit(15000)){$p.Kill();throw 'Helper timeout'}
  $result=$out.GetAwaiter().GetResult();$log=$err.GetAwaiter().GetResult()
  if($p.ExitCode -ne 0){throw "Helper failed: $log"}
  return $result
 }finally{$p.Dispose()}
}
$gui=$null;$sessions=@()
try{
 $gui=Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui.log"
 Wait-For {Test-Path "$dir/shell.json"} 'Automatic broker did not start configured shell'
 $shell=Get-Content "$dir/shell.json" -Raw | ConvertFrom-Json
 Assert ($shell.marker -eq 'space & 日本語' -and $shell.env -eq 'owned') 'Command/environment was lost'
 Assert ($shell.cwd -eq "$dir\working directory") 'Working directory was lost'
 $sessions=@(Mux @('list') | ConvertFrom-Json)
 Assert ($sessions.Count -eq 1) 'Discovery did not find exactly one broker'
 $name=$sessions[0].name
 $status=Mux @('status',$name) | ConvertFrom-Json
 Assert ($status.shell_pid -eq $shell.pid) 'Control status has wrong shell'
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 Start-Sleep -Milliseconds 500
 Assert ((Mux @('status',$name)|ConvertFrom-Json).shell_pid -eq $shell.pid) 'GUI crash killed hosted shell'
 Add-Content "$dir/ghostty/config" "windows-mux-session = $name"
 $gui=Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/reconnect.log"
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Reconnect window missing'
 Start-Sleep -Seconds 1
 Assert ((Mux @('status',$name)|ConvertFrom-Json).shell_pid -eq $shell.pid) 'Reattachment created a replacement shell'
 Mux @('stop',$name)|Out-Null
 Wait-For {!(Get-Process -Id $shell.pid -ErrorAction SilentlyContinue)} 'Control stop with attached GUI left shell running'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 0) 'Stopped session remained discoverable'
 Write-Output "PASS: automatic detached startup, command/env/cwd, discovery, GUI crash, original PID reattach, attached termination. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 try{$sessions=@(Mux @('list')|ConvertFrom-Json)}catch{}
 foreach($entry in $sessions){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
