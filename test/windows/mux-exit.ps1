#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-exit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class ExitTitle {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 public static string Get(IntPtr h){var b=new StringBuilder(1024);GetWindowText(h,b,1024);return b.ToString();}
}
"@
@'
[Console]::WriteLine("EXIT_FIXTURE_PID=$PID")
while(!(Test-Path "$PSScriptRoot/exit.go")){Start-Sleep -Milliseconds 20}
[Console]::WriteLine('FINAL_OUTPUT_RETAINED')
exit 7
'@ | Set-Content "$dir/worker.ps1"
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
"@ | Set-Content "$dir/ghostty/config"
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
  if($p.ExitCode -ne 0){throw "Helper failed: $log"};return $result
 }finally{$p.Dispose()}
}
$gui=$null;$sessions=@()
try{
 for($attempt=0;$attempt -lt 2;$attempt++){
  $gui=Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui-$attempt.log"
  Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Window missing'
  $window=[TabNative]::Windows($gui.Id)[0]
  if($attempt -eq 0){
   Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Session missing'
   $sessions=@(Mux @('list')|ConvertFrom-Json);$name=$sessions[0].name
   Set-Content "$dir/exit.go" ''
  }
  Wait-For {[ExitTitle]::Get($window).Contains('Session exited (code 7)')} 'Exit status missing from pane title'
  $status=Mux @('status',$name)|ConvertFrom-Json
  Assert ($status.exited -and !$status.failed -and $status.exit_code -eq 7) 'Normal exit misreported as failure'
  Assert ((@(Mux @('list')|ConvertFrom-Json))[0].exited) 'Discovery did not retain exit state'
  $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
  Start-Sleep -Milliseconds 300
  Assert ((Mux @('capture',$name)).Contains('FINAL_OUTPUT_RETAINED')) 'Exit lost final output'
  if($attempt -eq 0){Add-Content "$dir/ghostty/config" "windows-mux-session = $name"}
 }
 Write-Output "PASS: attached exit status, normal EOF, retained final output, discovery, exited-session reattachment. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 try{$sessions=@(Mux @('list')|ConvertFrom-Json)}catch{}
 foreach($entry in $sessions){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
