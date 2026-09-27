#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-cwd-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $dir 'working directory 日本語'
New-Item -ItemType Directory "$dir/ghostty",$target -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class CwdTitle {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 public static string Get(IntPtr h){var b=new StringBuilder(512);GetWindowText(h,b,512);return b.ToString();}
}
'@
@'
@{pid=$PID;cwd=[Environment]::CurrentDirectory} | ConvertTo-Json | Set-Content "$PSScriptRoot/$PID.started"
function Report([string]$Path,[string]$Title){
 $uri=([Uri]$Path).AbsoluteUri.Replace('file:///','file://'+$env:COMPUTERNAME+'/')
 [Console]::Write("`e]7;$uri`a`e]2;$Title`a")
}
Report (Join-Path $PSScriptRoot 'working directory 日本語') 'CWD_READY'
while($true){$key=[Console]::ReadKey($true);if($key.KeyChar -eq 'd'){Report (Join-Path $PSScriptRoot 'deleted-directory') 'CWD_MISSING'}}
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f4=new_tab
keybind = f5=new_split:right
keybind = f6=text:d
"@ | Set-Content "$dir/ghostty/config"
function Mux([string[]]$Arguments){
 $psi=[Diagnostics.ProcessStartInfo]::new("$Bin/yuurei-mux.exe")
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['LOCALAPPDATA']=$dir
 foreach($arg in $Arguments){$psi.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($psi)
 try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(!$p.WaitForExit(10000)){$p.Kill();throw 'Helper timeout'};$result=$out.GetAwaiter().GetResult();$log=$err.GetAwaiter().GetResult();if($p.ExitCode -ne 0){throw $log};return $result}finally{$p.Dispose()}
}
function Launch([string]$Label){Start-Process "$Bin/ghostty.exe" -WorkingDirectory $dir -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/$Label.log"}
$gui=$null
try{
 $gui=Launch 'initial';Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Wait-For {[CwdTitle]::Get($window).Contains('CWD_READY')} 'OSC 7 producer not ready'
 $first=@(Mux @('list')|ConvertFrom-Json)[0]
 Key $window 0x73
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 2 -and [CwdTitle]::Get($window).Contains('CWD_READY')} 'New tab failed after OSC 7'
 Key $window 0x74
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 3 -and [CwdTitle]::Get($window).Contains('CWD_READY')} 'Split failed after OSC 7'
 $children=@(Get-ChildItem "$dir/*.started"|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json}|Where-Object pid -ne $first.shell_pid)
 foreach($child in $children){Assert ($child.cwd -eq $target) 'New pane did not inherit decoded Unicode directory'}
 Key $window 0x75
 Wait-For {[CwdTitle]::Get($window).Contains('CWD_MISSING')} 'Missing-directory report not received'
 $before=@(Get-ChildItem "$dir/*.started"|Select-Object -ExpandProperty Name)
 Key $window 0x73
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 4 -and [CwdTitle]::Get($window).Contains('CWD_READY')} 'Missing directory prevented opening tab'
 $fallback=Get-ChildItem "$dir/*.started"|Where-Object Name -NotIn $before|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json}
 Assert ($fallback.cwd -eq $dir) 'Missing-directory fallback did not inherit GUI cwd'
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 Add-Content "$dir/ghostty/config" "windows-mux-session = $($first.name)"
 $gui=Launch 'snapshot';Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Reattachment window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Wait-For {[CwdTitle]::Get($window).Contains('CWD_READY')} 'Snapshot not restored'
 $before=@(Get-ChildItem "$dir/*.started"|Select-Object -ExpandProperty Name)
 Key $window 0x73
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 5} 'New tab failed after snapshot restoration'
 $restored=Get-ChildItem "$dir/*.started"|Where-Object Name -NotIn $before|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json}
 Assert ($restored.cwd -eq $target) 'Snapshot did not retain decoded directory'
 Write-Output "PASS: local-host OSC 7, percent-encoded Unicode/spaces, new tabs, splits, missing-directory fallback and snapshot reattachment. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
