#requires -Version 7.0
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
 [StructLayout(LayoutKind.Explicit,Size=40)] struct Input {
  [FieldOffset(0)] public uint type;
  [FieldOffset(8)] public ushort key;
  [FieldOffset(12)] public uint flags;
 }
 [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 public static void OpenDefaultPicker(IntPtr window){
  if(GetForegroundWindow()!=window)throw new Exception("Test window is not foreground");
  if(GetAsyncKeyState(0x11)<0||GetAsyncKeyState(0x10)<0)throw new Exception("User modifiers are held");
  var keys=new Input[]{new Input{type=1,key=0x11},new Input{type=1,key=0x10},new Input{type=1,key=0x53},new Input{type=1,key=0x53,flags=2},new Input{type=1,key=0x10,flags=2},new Input{type=1,key=0x11,flags=2}};
  if(SendInput(6,keys,40)!=6){SendInput(3,new Input[]{keys[3],keys[4],keys[5]},40);throw new Exception("Keyboard injection failed");}
 }
 [DllImport("user32.dll",EntryPoint="PostMessageW",ExactSpelling=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback cb,IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 public static IntPtr Palette(uint pid){IntPtr found=IntPtr.Zero;EnumWindows((h,p)=>{uint owner;GetWindowThreadProcessId(h,out owner);var b=new StringBuilder(128);GetClassName(h,b,128);if(owner==pid&&b.ToString()=="ghostty-palette")found=h;return true;},IntPtr.Zero);return found;}
 public static string Title(IntPtr h){var b=new StringBuilder(512);GetWindowText(h,b,512);return b.ToString();}
}
'@
@'
[Console]::Write("`e]2;SESSION_PID=$PID`a")
while($true){$key=[Console]::ReadKey($true);Set-Content "$PSScriptRoot/$PID.input" "$($key.KeyChar)"}
'@ | Set-Content "$dir/worker.ps1"
@"
windows-persistent-sessions = true
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f3=session:list
keybind = f4=new_tab
keybind = f6=session:rename
keybind = f7=session:detach
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
function Screenshot($H,[string]$Name){$r=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($H,[ref]$r);$bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top);$g=[Drawing.Graphics]::FromImage($bitmap);try{$g.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size);$bitmap.Save("$dir/$Name.png")}finally{$g.Dispose();$bitmap.Dispose()}}
$gui=$null
try{
 $gui=Launch 'initial'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and @(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Initial session missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5);[void][TabNative]::SetForegroundWindow($window)
 $first=@(Mux @('list')|ConvertFrom-Json)[0]
 Key $window 0x75 # F6 rename current
 $picker=Palette
 SendText $picker 'Backend 日本語';Screenshot $picker 'rename-edit';Key $picker 0x0D
 Mux @('list') | Set-Content "$dir/after-rename.json"
 if([TabNative]::IsWindow($picker)){Screenshot $picker 'rename-result'}
 Wait-For {(@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'Backend 日本語'} 'Keyboard rename did not persist'
 Key $picker 0x1B
 Key $window 0x73 # F4 new tab
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 2} 'Second session missing'
 $second=@(Mux @('list')|ConvertFrom-Json)|Where-Object name -ne $first.name
 Mux @('rename',$second.name,'Frontend')|Out-Null
 [void][TabNative]::SetForegroundWindow($window)
 [SessionNative]::OpenDefaultPicker($window) # Actual default Ctrl+Shift+S
 $picker=Palette;Screenshot $picker 'sessions'
 Key $picker 0x28;Key $picker 0x0D # Down, Enter -> Frontend
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($second.shell_pid)")} 'Arrow navigation selected wrong session'
 Key $window 0x7A;Key $window 0x7B # Remapped prefix F11, F12
 $picker=Palette;SendText $picker 'Backend';Key $picker 0x74;Key $picker 0x0D
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($first.shell_pid)")} 'Search did not focus existing pane'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 2) 'Switching created a duplicate shell'
 Key $window 0x72;$picker=Palette;SendText $picker 'Backend';Key $picker 0x71 # F2
 [void][TabNative]::PostMessage($picker,0x102,8,0);Key $picker 0x0D
 Assert ((@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'Backend 日本語') 'Empty rename changed session name'
 SendText $picker 'API 日本語';Key $picker 0x0D
 Wait-For {(@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'API 日本語'} 'F2 rename failed'
 Screenshot $picker 'renamed';Key $picker 0x1B
 Key $window 0x76 # F7 detach current
 Assert (!(Mux @('status',$first.name)|ConvertFrom-Json).exited) 'Detach terminated shell'
 Key $window 0x72;$picker=Palette;SendText $picker 'API';Key $picker 0x0D
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($first.shell_pid)")} 'Detached session did not reattach'
 Key $window 0x79 # F10 input
 Wait-For {(Test-Path "$dir/$($first.shell_pid).input") -and (Get-Content "$dir/$($first.shell_pid).input") -eq 'x'} 'Input after switching missed original shell'
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 Add-Content "$dir/ghostty/config" "windows-mux-session = $($first.name)"
 $gui=Launch 'reattach';Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Reopened GUI missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Key $window 0x78 # F9 command palette
 $picker=Palette;SendText $picker 'Switch Session';Key $picker 0x0D
 $picker=Palette;SendText $picker '日本語';Screenshot $picker 'after-restart';Key $picker 0x0D
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($first.shell_pid)")} 'Named session was lost after GUI restart'
 Assert ((@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'API 日本語') 'Name did not survive GUI restart'
 Write-Output "PASS: keyboard session picker, fuzzy search, arrows, remappable actions, Unicode rename, empty-name rejection, detach/reattach, original PID/input, command-palette entry and GUI restart. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
