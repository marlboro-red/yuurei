#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-input-'+[guid]::NewGuid().ToString('N'))
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
  var input=Console.OpenStandardInput();byte[] buffer=new byte[4096];int total=0;
  File.WriteAllText(Path.Combine(dir,"ready"),Environment.ProcessId.ToString());
  using(var output=File.Create(Path.Combine(dir,"received.bin"))){
   while(total<524288){int n=input.Read(buffer,0,Math.Min(buffer.Length,524288-total));if(n==0)throw new Exception("Input closed");output.Write(buffer,0,n);total+=n;Thread.Sleep(5);}
  }
  File.WriteAllText(Path.Combine(dir,"done"),total.ToString());
  int next=input.ReadByte();File.WriteAllText(Path.Combine(dir,"next"),next.ToString());
  Thread.Sleep(Timeout.Infinite);
 }
}
"@
[Receiver]::Run($PSScriptRoot)
'@ | Set-Content "$dir/worker.ps1"
$payload=('0123456789abcdef'*32768)
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f5=text:$($payload.Substring(0,2048))
keybind = f6=text:z
"@ | Set-Content "$dir/ghostty/config"
$gui=$null
try{
 $gui=Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui.log"
 Wait-For {(Test-Path "$dir/ready") -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Receiver did not start'
 $window=[TabNative]::Windows($gui.Id)[0]
 # Keep each config line below its 4 KiB limit. Submit a contiguous 512 KiB
 # burst without touching the user's clipboard; queue units cover one large paste.
 for($i=0;$i -lt 256;$i++){
  [void][TabNative]::PostMessage($window,0x100,0x74,0)
  [void][TabNative]::PostMessage($window,0x101,0x74,0)
 }
 Wait-For {Test-Path "$dir/done"} 'Large input did not reach shell'
 $actual=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$dir/received.bin"))
 Assert ($actual -ceq $payload) 'Large input lost or reordered bytes'
 [void][TabNative]::PostMessage($window,0x100,0x75,0)
 [void][TabNative]::PostMessage($window,0x101,0x75,0)
 Wait-For {Test-Path "$dir/next"} 'Input did not recover after large paste'
 Assert ((Get-Content "$dir/next") -eq '122') 'Post-paste input was corrupted'
 Assert (!(Select-String "$dir/gui.log" -Pattern 'native session disconnected|failed to queue' -Quiet)) 'Paste disconnected the view'
 Write-Output "PASS: 512 KiB input through bounded wire requests, exact byte ordering, responsive subsequent input. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($file in @(Get-ChildItem "$dir/ghostty/mux" -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)){
  $entry=Get-Content $file.FullName -Raw|ConvertFrom-Json
  & "$Bin/yuurei-mux.exe" stop $entry.name 2>$null | Out-Null
 }
}
