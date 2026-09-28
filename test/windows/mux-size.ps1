#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-size-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
@'
Add-Type @"
using System; using System.IO; using System.Runtime.InteropServices; using System.Threading;
public static class Receiver {
 [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h,uint mode);
 public static void Run(string dir) {
  if(!SetConsoleMode(GetStdHandle(-10),0))throw new Exception("Raw input mode failed");
  var input=Console.OpenStandardInput();
  Console.OutputEncoding=new System.Text.UTF8Encoding(false);
  Console.Write("\x1b[14t\x1b[16t\x1b[18t");Console.Out.Flush();
  var text=new System.Text.StringBuilder();int replies=0;
  while(replies<3){int c=input.ReadByte();if(c<0)throw new Exception("EOF");text.Append((char)c);if(c=='t')replies++;}
  File.WriteAllText(Path.Combine(dir,"queries"),text.ToString());
  Console.Write("\x1b[?2048h");Console.Out.Flush();
  File.WriteAllText(Path.Combine(dir,"ready"),Environment.ProcessId.ToString());
  text.Clear();
  while(true){int c=input.ReadByte();if(c<0)throw new Exception("EOF");text.Append((char)c);if(c=='t')break;}
  File.WriteAllText(Path.Combine(dir,"resize"),text.ToString());
  Thread.Sleep(Timeout.Infinite);
 }
}
"@
[Receiver]::Run($PSScriptRoot)
'@ | Set-Content "$dir/worker.ps1"
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f5=increase_font_size:1

"@ | Set-Content "$dir/ghostty/config"
$gui=$null
try{
 $gui=Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui.log"
 Wait-For {(Test-Path "$dir/ready") -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Receiver did not start'
 $window=[TabNative]::Windows($gui.Id)[0]
 $queries=Get-Content "$dir/queries" -Raw
 Assert ($queries -match "`e\[4;[1-9][0-9]*;[1-9][0-9]*t") 'Text pixel size query missing'
 Assert ($queries -match "`e\[6;[1-9][0-9]*;[1-9][0-9]*t") 'Cell pixel size query missing'
 Assert ($queries -match "`e\[8;[1-9][0-9]*;[1-9][0-9]*t") 'Grid size query missing'
 # Resize the existing pane without changing the worker process.
 [void][TabNative]::PostMessage($window,0x100,0x74,0)
 [void][TabNative]::PostMessage($window,0x101,0x74,0)
 Wait-For {Test-Path "$dir/resize"} 'Mode 2048 resize report missing'
 $report=Get-Content "$dir/resize" -Raw
 Assert ($report -match "^`e\[48;[1-9][0-9]*;[1-9][0-9]*;[1-9][0-9]*;[1-9][0-9]*t$") 'Invalid resize report'
 Write-Output "PASS: character, cell and terminal pixel queries and in-band resize report. Artifacts: $dir"

}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($file in @(Get-ChildItem "$dir/ghostty/mux" -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)){
  $entry=Get-Content $file.FullName -Raw|ConvertFrom-Json
  & "$Bin/yuurei-mux.exe" stop $entry.name 2>$null | Out-Null
 }
}
