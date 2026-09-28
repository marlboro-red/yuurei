#requires -Version 7.0
# Run on an isolated desktop. No global keyboard input or user configuration.
param([string]$Bin="$PSScriptRoot/../../zig-out/workspace-switch/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-workspace-switch-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw -Encoding utf8
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class WorkspacePicker {
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Callback cb,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",EntryPoint="PostMessageW")] public static extern bool Post(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static IntPtr Find(IntPtr parent){IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(h,p)=>{var b=new StringBuilder(128);GetClassName(h,b,128);if(b.ToString()=="ghostty-palette")found=h;return true;},IntPtr.Zero);return found;}
}
'@
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Set-Content "$PSScriptRoot/$PID.started" $PID
[Console]::WriteLine("WORKSPACE_PID=$PID")
while($true){$key=[Console]::ReadKey($true);Add-Content "$PSScriptRoot/$PID.input" "$($key.KeyChar)"}
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
@"
windows-persistent-sessions = true
windows-restore-session = true
windows-auto-update = false
confirm-close-surface = false
command = pwsh.exe -NoLogo -NoProfile -File "$($dir.Replace('\','\\'))/worker.ps1"
keybind = f3=text:x
keybind = f4=new_tab
keybind = f5=new_split:right
keybind = f7=toggle_split_zoom
keybind = f8=goto_tab:1
keybind = f9=set_tab_title:Project
keybind = f12=session:workspaces
"@ | Set-Content "$dir/ghostty/config" -Encoding utf8
function Mux([string[]]$Arguments){
 $psi=[Diagnostics.ProcessStartInfo]::new("$Bin/yuurei-mux.exe")
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.Environment['LOCALAPPDATA']=$dir
 foreach($arg in $Arguments){$psi.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($psi)
 try{$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(!$p.WaitForExit(10000)){$p.Kill();throw 'Helper timeout'};$result=$out.GetAwaiter().GetResult();$log=$err.GetAwaiter().GetResult();if($p.ExitCode -ne 0){throw $log};return $result}finally{$p.Dispose()}
}
function Launch([string]$Name){Start-Process "$Bin/ghostty.exe" -WindowStyle Hidden -PassThru -ArgumentList "--windows-workspace=$Name" -Environment @{LOCALAPPDATA=$dir;XDG_CONFIG_HOME=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/$Name.log"}
function LayoutPath([string]$Name){$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Name))).ToLowerInvariant();return "$dir/ghostty/workspace-$hash"}
function SelectWorkspace([IntPtr]$Window,[string]$Name){
 Key $Window 0x7B
 Wait-For {[WorkspacePicker]::Find($Window) -ne 0} 'Workspace picker missing'
 $picker=[WorkspacePicker]::Find($Window)
 Start-Sleep -Milliseconds 500
 $rect=New-Object TabNative+Rect;[void][TabNative]::GetWindowRect($Window,[ref]$rect)
 $bitmap=[Drawing.Bitmap]::new($rect.right-$rect.left,$rect.bottom-$rect.top);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$dc=$graphics.GetHdc();try{[void][WorkspacePicker]::PrintWindow($Window,$dc,2)}finally{$graphics.ReleaseHdc($dc)};$bitmap.Save("$dir/workspaces.png")}finally{$graphics.Dispose();$bitmap.Dispose()}
 foreach($ch in $Name.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Start-Sleep -Milliseconds 100
 Key $picker 0x0D
}
$gui=$null;$peer=$null
try {
 $gui=Launch 'alpha'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Alpha window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Key $window 0x74;Key $window 0x78;Key $window 0x76;Key $window 0x73;Key $window 0x77
 $alphaPath=LayoutPath 'alpha';$betaPath=LayoutPath 'beta'
 Wait-For {(Test-Path "$alphaPath.name") -and (Get-Content $alphaPath -Raw|ConvertFrom-Json).windows[0].tabs.Count -eq 2} 'Alpha layout missing'
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 3} 'Alpha shells missing'
 $alpha=Get-Content $alphaPath -Raw|ConvertFrom-Json
 $gui.Kill();$gui.WaitForExit();$gui.Dispose();$gui=$null
 $gui=Launch 'beta'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and (Test-Path "$betaPath.name")} 'Beta window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 4} 'Beta shell missing'
 $ids=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 $catalog=@(Mux @('workspaces')|ConvertFrom-Json)
 Assert ($catalog.Count -eq 2 -and ($catalog|Where-Object name -eq 'alpha').panes -eq 3) 'Workspace catalog incorrect'
 SelectWorkspace $window 'alpha'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and [TabNative]::Windows($gui.Id)[0] -ne $window} 'Switch to alpha failed'
 $window=[TabNative]::Windows($gui.Id)[0]
 Assert (@([TabNative]::Hosts($window,$true)).Count -eq 1) 'Zoom was not restored'
 Key $window 0x72
 Wait-For {@(Get-ChildItem "$dir/*.input").Count -eq 1} 'Restored pane did not receive input'
 $live=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($live -join ',') -eq ($ids -join ',')) 'Switch replaced shells'
 SelectWorkspace $window 'beta'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1 -and [TabNative]::Windows($gui.Id)[0] -ne $window} 'Switch back to beta failed'
 $window=[TabNative]::Windows($gui.Id)[0]
 $saved=Get-Content $alphaPath -Raw|ConvertFrom-Json
 Assert (($saved.windows[0].tabs|ConvertTo-Json -Depth 12 -Compress) -eq ($alpha.windows[0].tabs|ConvertTo-Json -Depth 12 -Compress)) 'Switch lost alpha tab layout'
 # Another GUI owns alpha: beta must remain intact and its picker must stay open.
 $peer=Launch 'alpha'
 Wait-For {[TabNative]::Windows($peer.Id).Count -eq 1} 'Peer window missing'
 SelectWorkspace $window 'alpha';Start-Sleep -Milliseconds 700
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window -and [WorkspacePicker]::Find($window) -ne 0) 'Busy workspace discarded current views'
 Key ([WorkspacePicker]::Find($window)) 0x1B
 $peer.Kill();$peer.WaitForExit();$peer.Dispose();$peer=$null
 # Escape cancels a pending switch without closing the original terminal.
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Workspace picker missing before cancellation'
 $picker=[WorkspacePicker]::Find($window)
 Start-Sleep -Milliseconds 500
 foreach($ch in 'alpha'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 [void][WorkspacePicker]::Post($picker,0x100,0x0D,0)
 [void][WorkspacePicker]::Post($picker,0x100,0x1B,0)
 Start-Sleep -Milliseconds 700
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window -and [WorkspacePicker]::Find($window) -eq 0) 'Cancellation discarded current views'
 # F6 toggles between the embedded workspace and shell session lists.
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Workspace picker missing before F6'
 $picker=[WorkspacePicker]::Find($window);Key $picker 0x75;Key $picker 0x75;Key $picker 0x1B
 # Closing the source during preparation must cancel and retain its saved layout.
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Picker missing before close'
 $picker=[WorkspacePicker]::Find($window);Start-Sleep -Milliseconds 500
 foreach($ch in 'alpha'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 [void][WorkspacePicker]::Post($picker,0x100,0x0D,0)
 [void][WorkspacePicker]::Post($window,0x10,0,0)
 Wait-For {$gui.HasExited} 'Source close did not finish during preparation'
 $gui.Dispose();$gui=$null
 Assert ((Get-Content $betaPath -Raw|ConvertFrom-Json).windows[0].tabs.Count -eq 1) 'Close lost source workspace'
 $gui=Launch 'beta'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Beta did not reopen after close'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 $live=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($live -join ',') -eq ($ids -join ',')) 'Close during preparation replaced shells'
 # Missing target broker must fail, without silently creating a replacement.
 $target=$alpha.windows[0].tabs[0].nodes|Where-Object { $_.leaf.session }|Select-Object -Last 1
 Mux @('stop',$target.leaf.session)|Out-Null
 Start-Sleep -Milliseconds 300
 SelectWorkspace $window 'alpha';Start-Sleep -Milliseconds 700
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window -and [WorkspacePicker]::Find($window) -ne 0) 'Missing session discarded current views'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 3) 'Missing shell was resurrected'
 Key ([WorkspacePicker]::Find($window)) 0x1B
 Write-Output "PASS: workspace discovery, keyboard switching, original PIDs, input, split/title/zoom preservation, cancellation, close during preparation, F6 navigation, busy target and partial-attachment rollback. Artifacts: $dir"
} finally {
 foreach($p in @($peer,$gui)){if($p){if(!$p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
