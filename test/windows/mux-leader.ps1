#requires -Version 7.0
# Run on an isolated desktop. No global input or user configuration.
param([string]$Bin="$PSScriptRoot/../../zig-out/mux-leader/bin")
$setup=Get-Content "$PSScriptRoot/mux-workspace-switch.ps1" -Raw -Encoding utf8
$start=$setup.IndexOf('$ErrorActionPreference')
$fixture=$setup.Substring($start,$setup.IndexOf('$gui=$null;$peer=$null')-$start)
$fixture=$fixture.Replace('"$PSScriptRoot/tab-transfer-smoke.ps1"', "'$PSScriptRoot/tab-transfer-smoke.ps1'")
Invoke-Expression $fixture
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Set-Content "$PSScriptRoot/$PID.started" $PID
[Console]::WriteLine("LEADER_PID=$PID")
while($true){$key=[Console]::ReadKey($true);Add-Content "$PSScriptRoot/$PID.input" ([int]$key.KeyChar)}
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
@'
keybind = ctrl+b=session:leader
keybind = f18=session:leader
keybind = f20=reload_config
keybind = yuurei_mux/u=text:U
keybind = yuurei_mux/f20=reload_config
'@ | Add-Content "$dir/ghostty/config" -Encoding utf8
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class LeaderKeys {
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr p);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a,uint b,bool attach);
 [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
 [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW")] static extern IntPtr Send(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
 [DllImport("user32.dll",EntryPoint="PostMessageW")] static extern bool Post(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static void Burst(IntPtr window,int count){for(int i=0;i<count;i++)foreach(int key in new[]{0x81,0x51}){
  if(!Post(window,0x100,(IntPtr)key,IntPtr.Zero)||!Post(window,0x101,(IntPtr)key,IntPtr.Zero))throw new Exception("Input queue full");
 }}
 public static void Ctrl(IntPtr window,int key){
  uint current=GetCurrentThreadId(), target=GetWindowThreadProcessId(window,IntPtr.Zero);
  if(!AttachThreadInput(current,target,true))throw new Exception("Attach input failed");
  var before=new byte[256];GetKeyboardState(before);
  try{var state=(byte[])before.Clone();state[0x11]=0x80;SetKeyboardState(state);
   IntPtr result;if(Send(window,0x100,(IntPtr)key,IntPtr.Zero,2,5000,out result)==IntPtr.Zero)throw new Exception("Key timed out");
   Send(window,0x101,(IntPtr)key,new IntPtr(0xC0000001L),2,5000,out result);
  }finally{SetKeyboardState(before);AttachThreadInput(current,target,false);}
 }
}
'@
function Inputs([int[]]$Expected) {
 Start-Sleep -Milliseconds 150
 $actual=@(Get-ChildItem "$dir/*.input"|ForEach-Object {Get-Content $_.FullName}|ForEach-Object {[int]$_}|Sort-Object)
 Assert (($actual -join ',') -eq (@($Expected|Sort-Object) -join ',')) "Unexpected shell input: $($actual -join ',')"
}
function Leader { Key $window 0x81 }
function Resources([string]$Stage) {
 $private=0L;$resident=0L;$handles=0;$threads=0;$cpu=0.0
 $processIds=@($gui.Id)+@(@(Mux @('list')|ConvertFrom-Json).broker_pid)
 foreach($processId in $processIds|Select-Object -Unique){
  $process=Get-Process -Id $processId
  try{$private+=$process.PrivateMemorySize64;$resident+=$process.WorkingSet64;$handles+=$process.HandleCount;$threads+=$process.Threads.Count;$cpu+=$process.TotalProcessorTime.TotalMilliseconds}finally{$process.Dispose()}
 }
 return [ordered]@{stage=$Stage;scope='GUI + session brokers, excluding shells and ConPTY';private_bytes=$private;resident_bytes=$resident;handles=$handles;threads=$threads;cpu_ms=$cpu}
}
$gui=$null
try {
 $gui=Launch 'leader'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and @(Get-ChildItem "$dir/*.started").Count -eq 1} 'Leader window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Leader;Key $window 0x51;Inputs @() # Unknown command.
 Leader;Key $window 0x1B;Inputs @() # Escape.
 Leader;[LeaderKeys]::Ctrl($window,0x51);Inputs @() # Unknown control key.
 # Prefix autorepeat must not activate a command or send bytes.
 [void][WorkspacePicker]::Post($window,0x100,0x81,0)
 [void][WorkspacePicker]::Post($window,0x100,0x81,0x40000001)
 [void][WorkspacePicker]::Post($window,0x101,0x81,0)
 Start-Sleep -Milliseconds 200
 # Command repeats/releases remain captured after the one-shot table closes.
 [void][WorkspacePicker]::Post($window,0x100,0x55,0)
 [void][WorkspacePicker]::Post($window,0x100,0x55,0x40000001)
 [void][WorkspacePicker]::Post($window,0x101,0x55,0)
 Inputs @(85)
 [LeaderKeys]::Ctrl($window,0x42);[LeaderKeys]::Ctrl($window,0x42)
 Inputs @(85,2) # Explicit prefix pass-through.
 Leader;Start-Sleep -Milliseconds 5400;Key $window 0x55
 Inputs @(85,2,117) # Timeout drops the prefix; next input is ordinary.
 Leader;[void][WorkspacePicker]::Post($window,0x8,0,0);Start-Sleep -Milliseconds 100;Key $window 0x55
 Inputs @(85,2,117,117) # Focus loss.
 Leader;Key $window 0x43
 Wait-For {@([TabNative]::Hosts($window,$false)).Count -eq 2} 'Leader new tab failed'
 Leader;Key $window 0x44
 Wait-For {@([TabNative]::Hosts($window,$false)).Count -eq 3} 'Leader split right failed'
 Leader;Key $window 0x45
 Wait-For {@([TabNative]::Hosts($window,$false)).Count -eq 4} 'Leader split down failed'
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 4} 'Split shells did not start'
 [void][TabNative]::ShowWindow($window,5)
 Leader;Key $window 0x5A
 Wait-For {@([TabNative]::Hosts($window,$true)).Count -eq 1} 'Leader zoom failed'
 Leader;Key $window 0x53
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Leader session picker failed'
 Key ([WorkspacePicker]::Find($window)) 0x1B
 Wait-For {[WorkspacePicker]::Find($window) -eq 0} 'Session picker did not dismiss'
 Leader;Key $window 0x57
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Leader workspace picker failed'
 Key ([WorkspacePicker]::Find($window)) 0x1B
 Wait-For {[WorkspacePicker]::Find($window) -eq 0} 'Workspace picker did not dismiss'
 Leader;Key $window 0x58;Key $window 0x1B
 Inputs @(85,2,117,117) # Session-end confirmation does not leak keys.
 # Reload replaces the named table safely and uses the edited command.
 Add-Content "$dir/ghostty/config" 'keybind = yuurei_mux/u=text:V' -Encoding utf8
 Leader;Key $window 0x83;Start-Sleep -Milliseconds 500
 Leader;Key $window 0x55
 Inputs @(85,2,117,117,86)
 # Capture the GDI bar, which must reflect the edited table, not hardcoded keys.
 Leader
 $rect=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($window,[ref]$rect)
 $bitmap=[Drawing.Bitmap]::new($rect.right-$rect.left,$rect.bottom-$rect.top);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$dc=$graphics.GetHdc();try{[void][WorkspacePicker]::PrintWindow($window,$dc,2)}finally{$graphics.ReleaseHdc($dc)};$bitmap.Save("$dir/leader.png")}finally{$graphics.Dispose();$bitmap.Dispose()}
 Key $window 0x1B
 $samples=@(Resources 'before')
 [LeaderKeys]::Burst($window,500);Key $window 0x72
 Wait-For {@(Get-ChildItem "$dir/*.input"|ForEach-Object {Get-Content $_.FullName}).Count -eq 6} 'First stress batch did not drain'
 Inputs @(85,2,117,117,86,120)
 $samples+=Resources '500 cycles'
 [LeaderKeys]::Burst($window,500);Key $window 0x72
 Wait-For {@(Get-ChildItem "$dir/*.input"|ForEach-Object {Get-Content $_.FullName}).Count -eq 7} 'Second stress batch did not drain'
 Inputs @(85,2,117,117,86,120,120)
 $samples+=Resources '1000 cycles'
 $samples|ConvertTo-Json -Depth 4|Set-Content "$dir/leader-resources.json" -Encoding utf8
 # Ordinary terminals have no session bar; activating and cancelling must
 # restore their exact viewport height without leaving a reserved blank row.
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 Add-Content "$dir/ghostty/config" "windows-persistent-sessions = false`nwindows-restore-session = false" -Encoding utf8
 $gui=Launch 'local'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and @(Get-ChildItem "$dir/*.started").Count -eq 5} 'Local terminal missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Start-Sleep -Milliseconds 300
 $hostWindow=[TabNative]::Hosts($window,$false)[0]
 $before=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($hostWindow,[ref]$before)
 Leader
 $during=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($hostWindow,[ref]$during)
 Assert (($during.bottom-$during.top) -lt ($before.bottom-$before.top)) 'Local leader bar did not reserve space'
 Key $window 0x1B
 $after=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($hostWindow,[ref]$after)
 Assert (($after.bottom-$after.top) -eq ($before.bottom-$before.top)) 'Local cancellation left a blank bar'
 Leader;Start-Sleep -Milliseconds 5400
 [void][TabNative]::GetWindowRect($hostWindow,[ref]$after)
 Assert (($after.bottom-$after.top) -eq ($before.bottom-$before.top)) 'Local timeout left a blank bar'
 Write-Output "PASS: custom commands, Ctrl+B pass-through, invalid keys, Escape, timeout, focus loss, repeats/releases, tabs/splits/zoom, pickers, confirmation isolation, config reload. Artifacts: $dir"
} finally {
 if($gui){
  if(!$gui.HasExited){
   foreach($ownedWindow in [TabNative]::Windows($gui.Id)){[void][WorkspacePicker]::Post($ownedWindow,0x10,0,0)}
   if(!$gui.WaitForExit(5000)){$gui.Kill();$gui.WaitForExit()}
  }
  $gui.Dispose()
 }
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
