#requires -Version 7.0
# PostedKeys avoids global SendInput for runs on an isolated Windows desktop.
param([string]$Bin="$PSScriptRoot/../../zig-out/bin",[switch]$PostedKeys)
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-picker-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class SessionNative {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
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
function Assert-BarSpace($H){
 $client=New-Object SessionNative+Rect;[void][SessionNative]::GetClientRect($H,[ref]$client)
 $height=[int](26*[TabNative]::GetDpiForWindow($H)/96)
 foreach($hostWindow in [TabNative]::Hosts($H,$true)){
  $r=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($hostWindow,[ref]$r)
  $point=New-Object TabNative+Point;$point.x=$r.right;$point.y=$r.bottom;[void][TabNative]::ScreenToClient($H,[ref]$point)
  Assert ($point.y -le $client.bottom-$height) 'Terminal overlaps the session bar'
 }
}
function Assert-EmbeddedPicker($Picker,$Window){
 Assert ([SessionNative]::IsChild($Window,$Picker)) 'Session picker is a separate popup'
 $client=New-Object SessionNative+Rect;[void][SessionNative]::GetClientRect($Window,[ref]$client)
 $rect=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($Picker,[ref]$rect)
 $origin=New-Object TabNative+Point;$origin.x=$rect.left;$origin.y=$rect.top;[void][TabNative]::ScreenToClient($Window,[ref]$origin)
 $bar=[int](26*[TabNative]::GetDpiForWindow($Window)/96)
 Assert ($origin.x -eq 0 -and $rect.right-$rect.left -eq $client.right) 'Picker does not fill the terminal width'
 Assert ($origin.y -ge 0 -and $origin.y+$rect.bottom-$rect.top -eq $client.bottom-$bar) 'Picker overlaps tabs or session bar'
}
function Screenshot($H,[string]$Name){$r=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($H,[ref]$r);$bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top);$g=[Drawing.Graphics]::FromImage($bitmap);try{if($PostedKeys){$dc=$g.GetHdc();try{[void][SessionNative]::PrintWindow($H,$dc,2)}finally{$g.ReleaseHdc($dc)}}else{$g.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size)};$bitmap.Save("$dir/$Name.png")}finally{$g.Dispose();$bitmap.Dispose()}}
$gui=$null
try{
 $gui=Launch 'initial'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and @(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Initial session missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5);[void][TabNative]::SetForegroundWindow($window)
 $first=@(Mux @('list')|ConvertFrom-Json)[0]
 Wait-For {$previewText=Mux @('preview',$first.name);$previewText | Set-Content "$dir/attached-preview.txt";$previewText.Contains("PREVIEW_PID=$($first.shell_pid) 日本語 & literal")} 'Attached read-only preview missing Unicode content'
 Key $window 0x75 # F6 rename current
 $picker=Palette
 Assert-EmbeddedPicker $picker $window
 SendText $picker 'Backend 日本語';Screenshot $picker 'rename-edit';Key $picker 0x0D
 Mux @('list') | Set-Content "$dir/after-rename.json"
 if([TabNative]::IsWindow($picker)){Screenshot $picker 'rename-result'}
 Wait-For {(@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'Backend 日本語'} 'Keyboard rename did not persist'
 Key $picker 0x1B
 Key $window 0x73 # F4 new tab
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 2} 'Second session missing'
 $second=@(Mux @('list')|ConvertFrom-Json)|Where-Object name -ne $first.name
 Mux @('rename',$second.name,'Frontend')|Out-Null
 Key $window 0x74 # F5 split: each pane owns a distinct session
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 3} 'Split session missing'
 $split=@(Mux @('list')|ConvertFrom-Json)|Where-Object { $_.name -ne $first.name -and $_.name -ne $second.name }
 Assert-BarSpace $window
 Key $window 0x70;Assert-BarSpace $window;Screenshot $window 'fullscreen-session-bar';Key $window 0x70
 Key $window 0x77 # F8: end only the selected split
 Screenshot $window 'end-split-confirmation';Key $window 0x59
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 2} 'Ending a split left its broker registered'
 Wait-For {!(Get-Process -Id $split.shell_pid -ErrorAction SilentlyContinue)} 'Split shell survived termination'
 Assert (!(Mux @('status',$second.name)|ConvertFrom-Json).exited) 'Ending a split stopped its sibling'
 Assert-BarSpace $window
 [void][TabNative]::SetForegroundWindow($window)
 Start-Sleep -Milliseconds 200
 if($PostedKeys){Key $window 0x72}else{[SessionNative]::OpenDefaultPicker($window)} # Actual default Ctrl+Shift+S in interactive mode
 $picker=Palette;Assert-EmbeddedPicker $picker $window;Start-Sleep -Milliseconds 400;Screenshot $picker 'sessions'
 # Clicking the preview must never attach the corresponding list row.
 $previewRect=New-Object SessionNative+Rect;[void][SessionNative]::GetClientRect($picker,[ref]$previewRect)
 $previewX=[int]($previewRect.right*0.75);$previewY=[int](52*[TabNative]::GetDpiForWindow($picker)/96)
 [void][SessionNative]::PostMessageW($picker,0x201,1,($previewX -bor ($previewY -shl 16)));Start-Sleep -Milliseconds 100
 Assert ([TabNative]::IsWindow($picker)) 'Clicking the preview activated a list row'
 $original=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($window,[ref]$original)
 [void][TabNative]::SetWindowPos($window,0,0,0,1000,700,0x16);Start-Sleep -Milliseconds 150
 Assert-EmbeddedPicker $picker $window;Screenshot $picker 'sessions-resized'
 [void][TabNative]::SetWindowPos($window,0,0,0,($original.right-$original.left),($original.bottom-$original.top),0x16);Start-Sleep -Milliseconds 150
 Assert-EmbeddedPicker $picker $window
 Key $window 0x70;Assert-EmbeddedPicker $picker $window;Screenshot $picker 'sessions-fullscreen';Key $window 0x70
 Key $picker 0x28;Key $picker 0x74;Key $picker 0x0D # Down, refresh preserves selection, Enter -> Frontend
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($second.shell_pid)")} 'Arrow navigation selected wrong session'
 Key $window 0x7A;Key $window 0x7B # Remapped prefix F11, F12
 $picker=Palette;SendText $picker 'Backend';Key $picker 0x74;Key $picker 0x0D
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($first.shell_pid)")} 'Search did not focus existing pane'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 2) 'Switching created a duplicate shell'
 Key $window 0x72;$picker=Palette;SendText $picker 'Backend';Key $picker 0x71 # F2
 SendText $picker 'Discarded name';Screenshot $picker 'inline-rename';Key $picker 0x1B
 Assert ([TabNative]::IsWindow($picker)) 'Cancelling inline rename dismissed the session list'
 Key $picker 0x28;Key $picker 0x0D # Search and selection survive cancellation.
 Wait-For {[SessionNative]::Title($window).Contains("SESSION_PID=$($first.shell_pid)")} 'Cancelling rename lost the filtered selection'
 Assert ((@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'Backend 日本語') 'Cancelled rename changed session name'
 Key $window 0x72;$picker=Palette;Key $picker 0x71
 Key $picker 0x28 # Navigation must not retarget an active inline edit.
 [void][TabNative]::PostMessage($picker,0x102,8,0);Key $picker 0x0D
 Assert ((@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'Backend 日本語') 'Empty rename changed session name'
 SendText $picker 'API 日本語';Key $picker 0x0D
 Wait-For {(@(Mux @('list')|ConvertFrom-Json)|Where-Object name -eq $first.name).label -eq 'API 日本語'} 'F2 rename failed'
 Screenshot $picker 'renamed';Key $picker 0x1B
 Key $window 0x76 # F7 detach current
 Assert (!(Mux @('status',$first.name)|ConvertFrom-Json).exited) 'Detach terminated shell'
 Assert ((Mux @('preview',$first.name)).Contains("PREVIEW_PID=$($first.shell_pid)")) 'Detached preview missing screen contents'
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
 # End a detached session directly from the picker using the inline bar.
 # Enter must not confirm; Escape must leave both sessions intact.
 Key $window 0x72;$picker=Palette;SendText $picker 'Frontend';Key $picker 0x2E
 Assert ([SessionNative]::Dialog($gui.Id) -eq 0) 'Session confirmation opened a Windows dialog'
 Screenshot $window 'end-detached-confirmation'
 Key $window 0x0D;Key $window 0x1B
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 2) 'Enter or Escape ended a session'
 Assert ((Get-Content "$dir/$($first.shell_pid).input") -eq 'x') 'Confirmation keys leaked into the shell'
 Key $window 0x72;$picker=Palette;SendText $picker 'Frontend';Key $picker 0x2E;Key $window 0x59
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 1} 'Delete and Y did not remove detached session'
 Wait-For {!(Get-Process -Id $second.shell_pid -ErrorAction SilentlyContinue)} 'Detached shell survived termination'
 Assert (!(Mux @('status',$first.name)|ConvertFrom-Json).exited) 'Ending detached session stopped another session'
 Assert ((Get-Content "$dir/$($first.shell_pid).input") -eq 'x') 'Confirmation Y leaked into another shell'
 # Command palette exposes the action; Esc cancels it. A remapped action
 # then ends the current session and closes its last pane.
 Key $window 0x78;$picker=Palette;SendText $picker 'End Session';Key $picker 0x0D
 Assert ([SessionNative]::Dialog($gui.Id) -eq 0) 'Command action opened a Windows dialog'
 Key $window 0x1B
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 1) 'Escape ended the active session'
 Key $window 0x77;Screenshot $window 'end-active-confirmation';Key $window 0x59
 Wait-For {@(Mux @('list')|ConvertFrom-Json).Count -eq 0} 'Remapped terminate action left its broker registered'
 Wait-For {!(Get-Process -Id $first.shell_pid -ErrorAction SilentlyContinue)} 'Active shell survived termination'
 Wait-For {$gui.HasExited} 'Ending the last session did not close its pane'
 Write-Output "PASS: attached/detached Unicode previews, preview click isolation, session picker, Unicode rename, detach/reattach, GUI restart, inline cancellation and termination, split isolation, fullscreen bar geometry, and confirmation input isolation. Artifacts: $dir"
}finally{
 if($gui){if(!$gui.HasExited){$gui.Kill();$gui.WaitForExit()};$gui.Dispose()}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
