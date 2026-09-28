#requires -Version 7.0
# Run on an isolated desktop; all input uses posted window messages.
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-picker-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class SessionNative {
 [DllImport("user32.dll",EntryPoint="PostMessageW",ExactSpelling=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback cb,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Callback cb,IntPtr p);
 [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent,IntPtr child);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 public static IntPtr Palette(uint pid){return Find(pid,"ghostty-palette");} public static IntPtr Dialog(uint pid){return Find(pid,"#32770");} static IntPtr Find(uint pid,string windowClass){IntPtr found=IntPtr.Zero;Callback inspect=(h,p)=>{var b=new StringBuilder(128);GetClassName(h,b,128);if(b.ToString()==windowClass)found=h;return true;};EnumWindows((h,p)=>{uint owner;GetWindowThreadProcessId(h,out owner);if(owner==pid){inspect(h,p);EnumChildWindows(h,inspect,IntPtr.Zero);}return true;},IntPtr.Zero);return found;}
 public static string Title(IntPtr h){var b=new StringBuilder(512);GetWindowText(h,b,512);return b.ToString();}
}
'@
@'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Write("`e]2;SESSION_PID=$PID`a")
[Console]::WriteLine("PREVIEW_PID=$PID 日本語 & literal")
while($true){$key=[Console]::ReadKey($true);Set-Content "$PSScriptRoot/$PID.input" "$($key.KeyChar)"}
'@ | Set-Content "$dir/worker.ps1"
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f2=clear_screen
keybind = f3=session:list
keybind = f4=new_tab
keybind = f5=new_split:right
keybind = f1=toggle_fullscreen
keybind = f6=session:rename
keybind = f7=session:detach
keybind = f8=session:terminate
keybind = f9=toggle_command_palette
keybind = f10=text:x
keybind = f11>f12=session:list
"@ | Set-Content "$dir/ghostty/config"
function Mux([string[]]$Arguments){
 $psi=[Diagnostics.ProcessStartInfo]::new("$Bin/yuurei-mux.exe")
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['LOCALAPPDATA']=$dir
 foreach($arg in $Arguments){$psi.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($psi)
 try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(!$p.WaitForExit(10000)){$p.Kill();throw 'Helper timeout'};$result=$out.GetAwaiter().GetResult();$log=$err.GetAwaiter().GetResult();if($p.ExitCode -ne 0){throw $log};return $result}finally{$p.Dispose()}
}
function Launch([string]$Log){Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/$Log.log"}
function Palette(){Wait-For {[SessionNative]::Palette($gui.Id) -ne 0} 'Session picker missing';return [SessionNative]::Palette($gui.Id)}
function SendText($H,[string]$Text){foreach($ch in $Text.ToCharArray()){[void][SessionNative]::PostMessageW($H,0x102,[int]$ch,0)};Start-Sleep -Milliseconds 100}
$gui=$null
try {
 $gui=Launch 'initial'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and @(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Initial session missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 $first=@(Mux @('list')|ConvertFrom-Json)[0]
 Wait-For {(Mux @('preview',$first.name)).Contains('PREVIEW_PID=')} 'Fixture output missing'
 $before=Mux @('preview',$first.name)
 Key $window 0x71
 Start-Sleep -Milliseconds 500
 $after=Mux @('preview',$first.name)
 Assert (!$after.Contains('PREVIEW_PID=')) 'Broker retained cleared content'
 Key $window 0x76
 Wait-For {$gui.HasExited} 'Detach failed'
 $gui.Dispose();$gui=Launch 'reattach'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'New GUI missing'
 $window=[TabNative]::Windows($gui.Id)[0];Key $window 0x72;$picker=Palette
 Mux @('rename',$first.name,'Cleared') | Out-Null
 Key $picker 0x74;SendText $picker 'Cleared';Key $picker 0x0D
 Wait-For {([SessionNative]::Title($window)).Contains("SESSION_PID=$($first.shell_pid)")} 'Cleared session was not reattached'
 Assert (!(Mux @('preview',$first.name)).Contains('PREVIEW_PID=')) 'Cleared content returned on attach'
 [pscustomobject]@{artifacts=$dir;beforeClear=$before;brokerAfterClear=$after} | ConvertTo-Json
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
