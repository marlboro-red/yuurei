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
 public delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Callback cb,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 public static IntPtr Picker(IntPtr parent){IntPtr result=IntPtr.Zero;EnumChildWindows(parent,(h,p)=>{var b=new StringBuilder(128);GetClassName(h,b,128);if(b.ToString()=="ghostty-palette")result=h;return true;},IntPtr.Zero);return result;}
 [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
 [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 public static string Get(IntPtr h){var b=new StringBuilder(1024);GetWindowText(h,b,1024);return b.ToString();}
}
"@
@'
[Console]::Write("`e]2;EXIT_FIXTURE_PID=$PID`a")
while(!(Test-Path "$PSScriptRoot/$PID.exit")){Start-Sleep -Milliseconds 20}
exit ([int](Get-Content "$PSScriptRoot/$PID.exit"))
'@ | Set-Content "$dir/worker.ps1"
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
keybind = f3=session:list
keybind = f4=new_tab
keybind = f5=new_split:right
keybind = f6=session:detach
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
function Launch([string]$Log){Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/$Log.log"}
function Entries(){@(Mux @('list')|ConvertFrom-Json)}
function End-Shell($Entry,[int]$Code){Set-Content "$dir/$($Entry.shell_pid).exit" "$Code"}
function Assert-Removed($Entry){
 Wait-For {@(Entries|Where-Object name -eq $Entry.name).Count -eq 0} 'Exited session remains discoverable'
 Wait-For {!(Get-Process -Id $Entry.broker_pid -ErrorAction SilentlyContinue)} 'Exited session retained its broker'
 Wait-For {!(Get-Process -Id $Entry.shell_pid -ErrorAction SilentlyContinue)} 'Fixture shell did not exit'
}
function New-Session([int]$Key){
 $before=@(Entries|ForEach-Object name)
 Key $window $Key
 Wait-For {@(Entries|Where-Object name -NotIn $before).Count -eq 1} 'New fixture session missing'
 return @(Entries|Where-Object name -NotIn $before)[0]
}
$gui=$null;$suspended=$false
try{
 $gui=Launch 'attached';Wait-For {@(Entries).Count -eq 1 -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Initial session missing'
 $window=[TabNative]::Windows($gui.Id)[0];$anchor=@(Entries)[0]
 $tab=New-Session 0x73;Key $window 0x72
 Wait-For {[ExitTitle]::Picker($window) -ne 0} 'Session picker missing'
 End-Shell $tab 7;Assert-Removed $tab
 Wait-For {[ExitTitle]::Get($window).Contains("EXIT_FIXTURE_PID=$($anchor.shell_pid)")} 'Exited tab was not closed'
 $picker=[ExitTitle]::Picker($window)
 foreach($ch in $tab.name.ToCharArray()){[void][TabNative]::PostMessage($picker,0x102,[int]$ch,0)}
 Key $picker 0x0D
 Assert ([TabNative]::Hosts($window,$false).Count -eq 1) 'Picker retained an ended session and opened an error pane'
 Key $picker 0x1B
 $split=New-Session 0x74;End-Shell $split 0;Assert-Removed $split
 Wait-For {[TabNative]::Hosts($window,$false).Count -eq 1} 'Exited split was not removed'
 Assert (!(Mux @('status',$anchor.name)|ConvertFrom-Json).exited) 'Split exit stopped its sibling'
 $detached=New-Session 0x73;Key $window 0x75
 Assert (!(Mux @('status',$detached.name)|ConvertFrom-Json).exited) 'Detaching ended a running shell'
 End-Shell $detached 0;Assert-Removed $detached
 $frozen=New-Session 0x73
 Assert ([ExitTitle]::NtSuspendProcess($gui.Handle) -eq 0) 'Could not suspend fixture GUI';$suspended=$true
 End-Shell $frozen 0;Assert-Removed $frozen
 Assert ([ExitTitle]::NtResumeProcess($gui.Handle) -eq 0) 'Could not resume fixture GUI';$suspended=$false
 Wait-For {[ExitTitle]::Get($window).Contains("EXIT_FIXTURE_PID=$($anchor.shell_pid)")} 'Resumed view did not close its ended session'
 End-Shell $anchor 0;Assert-Removed $anchor
 Wait-For {$gui.HasExited} 'Last shell exit did not close the GUI'
 $gui.Dispose();$gui=$null
 # Immediate exits must not become BrokerLaunchFailed or disconnected panes.
 foreach($code in 0,7){
  Add-Content "$dir/ghostty/config" "command = cmd.exe /d /c exit $code"
  for($attempt=0;$attempt -lt 3;$attempt++){
   $gui=Launch "immediate-$code-$attempt"
   Wait-For {$gui.HasExited} 'Immediate shell exit left an error pane'
   Wait-For {@(Entries).Count -eq 0} 'Immediate shell exit retained a broker'
   $gui.Dispose();$gui=$null
  }
 }
 Write-Output "PASS: attached and detached cleanup, nonzero exit, split isolation, suspended view recovery, last-pane close, and immediate shell exits. Artifacts: $dir"
}finally{
 if($gui){if($suspended){[void][ExitTitle]::NtResumeProcess($gui.Handle)};if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Entries)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
