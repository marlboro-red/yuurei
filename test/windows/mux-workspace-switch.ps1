#requires -Version 7.0
# Run on an isolated desktop. No global keyboard input or user configuration.
param([string]$Bin="$PSScriptRoot/../../zig-out/workspace-inplace/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-workspace-switch-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
$harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw -Encoding utf8
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'),$harness.IndexOf('$isolation = Join-Path $Artifacts')-$harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class WorkspacePicker {
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback cb,IntPtr p);
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint cmd);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Callback cb,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",EntryPoint="PostMessageW")] public static extern bool Post(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static IntPtr Search(IntPtr parent){IntPtr found=IntPtr.Zero;EnumWindows((h,p)=>{var b=new StringBuilder(128);GetClassName(h,b,128);if(GetWindow(h,4)==parent && b.ToString()=="ghostty-search")found=h;return true;},IntPtr.Zero);return found;}
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
keybind = f10=new_window
keybind = f11=start_search
keybind = chain=search:WORKSPACE
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
 [void][TabNative]::ShowWindow($window,3)
 Assert ([WorkspacePicker]::IsZoomed($window)) 'Test window did not maximize'
 SelectWorkspace $window 'alpha'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'Switch to alpha failed'
 Assert ([WorkspacePicker]::IsZoomed($window)) 'Workspace switch lost maximized state'
 $window=[TabNative]::Windows($gui.Id)[0]
 Assert (@([TabNative]::Hosts($window,$true)).Count -eq 1) 'Zoom was not restored'
 Key $window 0x72
 Wait-For {@(Get-ChildItem "$dir/*.input").Count -eq 1} 'Restored pane did not receive input'
 $live=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($live -join ',') -eq ($ids -join ',')) 'Switch replaced shells'
 SelectWorkspace $window 'beta'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'Switch back to beta failed'
 $window=[TabNative]::Windows($gui.Id)[0]
 Assert ([WorkspacePicker]::IsZoomed($window)) 'Round trip lost maximized state'
 [void][TabNative]::ShowWindow($window,9)
 $saved=Get-Content $alphaPath -Raw|ConvertFrom-Json
 Assert (($saved.windows[0].tabs|ConvertTo-Json -Depth 12 -Compress) -eq ($alpha.windows[0].tabs|ConvertTo-Json -Depth 12 -Compress)) 'Switch lost alpha tab layout'
 # Create from the embedded list. Empty/duplicate names must not change views.
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Workspace picker missing before create'
 $picker=[WorkspacePicker]::Find($window);Start-Sleep -Milliseconds 500
 foreach($ch in 'alpha'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Key $picker 0x71;Key $picker 0x0D;Start-Sleep -Milliseconds 200
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Empty name changed workspace'
 foreach($ch in 'alpha'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Key $picker 0x0D;Start-Sleep -Milliseconds 500
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Duplicate name changed workspace'
 Assert (@(Mux @('workspaces')|ConvertFrom-Json).Count -eq 2) 'Duplicate create changed catalog'
 Key $picker 0x1B
 # Cancellation keeps the alpha filter/selection: Enter still switches to it.
 Key $picker 0x0D
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'Create cancellation lost the previous selection'
 $window=[TabNative]::Windows($gui.Id)[0]
 $originalHosts=@([TabNative]::Hosts($window,$false))
 Key $window 0x7A
 $searchBefore=[WorkspacePicker]::Search($window)
 Assert ($searchBefore -ne 0) 'Search bar did not open before extraction'
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Picker missing before new workspace'
 $picker=[WorkspacePicker]::Find($window);Start-Sleep -Milliseconds 500;Key $picker 0x71
 foreach($ch in 'cancelled'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 [void][WorkspacePicker]::Post($picker,0x100,0x0D,0)
 [void][WorkspacePicker]::Post($picker,0x100,0x1B,0)
 Start-Sleep -Milliseconds 500
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Cancelled creation replaced current views'
 Assert (!(Test-Path (LayoutPath 'cancelled'))) 'Cancelled creation published a workspace'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 4) 'Cancelled creation started a shell'
 Key $picker 0x71
 foreach($ch in 'gamma 日本'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Key $picker 0x0D
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'New workspace did not open'
 $window=[TabNative]::Windows($gui.Id)[0]
 $gammaPath=LayoutPath 'gamma 日本'
 Wait-For {(Test-Path "$gammaPath.name")} 'New workspace was not saved'
 $gamma=Get-Content $gammaPath -Raw|ConvertFrom-Json
 Assert ($gamma.windows.Count -eq 1 -and $gamma.windows[0].tabs.Count -eq 1) 'New workspace layout incorrect'
 $live=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($live -join ',') -eq ($ids -join ',')) 'Creation changed shell PIDs'
 Assert (@(Get-ChildItem "$dir/*.started").Count -eq 4) 'Creation started an unwanted shell'
 # The picker closes before discarded views finish teardown on the UI thread.
 Wait-For {@([TabNative]::Hosts($window,$false)).Count -eq 2} 'Creation did not finish detaching other tabs'
 $movedHosts=@([TabNative]::Hosts($window,$false))
 Assert ([WorkspacePicker]::Search($window) -eq $searchBefore) 'Extraction discarded search on a retained pane'
 Assert ($movedHosts.Count -eq 2 -and @($movedHosts|Where-Object {$_ -notin $originalHosts}).Count -eq 0) 'Creation replaced live pane views'
 Assert (@([TabNative]::Hosts($window,$true)).Count -eq 1) 'Creation lost selected zoom'
 Assert (($gamma.windows[0].tabs[0]|ConvertTo-Json -Depth 12 -Compress) -eq ($alpha.windows[0].tabs[0]|ConvertTo-Json -Depth 12 -Compress)) 'Creation lost the selected split layout'
 $remaining=Get-Content $alphaPath -Raw|ConvertFrom-Json
 Assert ($remaining.windows[0].tabs.Count -eq 1 -and ($remaining.windows[0].tabs[0]|ConvertTo-Json -Depth 12 -Compress) -eq ($alpha.windows[0].tabs[1]|ConvertTo-Json -Depth 12 -Compress)) 'Other tabs were not retained in source'
 $ids=$live
 Key $window 0x72
 Wait-For {(@(Get-ChildItem "$dir/*.input").Count -eq 1) -and @(Get-Content (Get-ChildItem "$dir/*.input")[0].FullName).Count -eq 2} 'Moved pane did not retain input'
 foreach($inputFile in Get-ChildItem "$dir/*.input"){Assert ((Get-Content $inputFile.FullName -Raw) -match '^x\r?\nx\r?\n$') 'Picker keystrokes leaked into a shell'}
 SelectWorkspace $window 'alpha'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'Could not switch back after creation'
 $window=[TabNative]::Windows($gui.Id)[0]
 Assert (@([TabNative]::Hosts($window,$false)).Count -eq 1) 'Switch back resurrected the moved tab'
 Assert ([WorkspacePicker]::Search($window) -eq 0) 'Switch retained search referencing detached pages'
 SelectWorkspace $window 'beta'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id)[0] -eq $window} 'Could not return to beta after creation'
 $window=[TabNative]::Windows($gui.Id)[0]
 # Another GUI owns alpha: beta must remain intact and its picker must stay open.
 $peer=Launch 'alpha'
 Wait-For {[TabNative]::Windows($peer.Id).Count -eq 1} 'Peer window missing'
 Key $window 0x7B
 Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Picker missing before busy create'
 $picker=[WorkspacePicker]::Find($window);Start-Sleep -Milliseconds 500;Key $picker 0x71
 foreach($ch in 'alpha'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Key $picker 0x0D;Start-Sleep -Milliseconds 500
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Busy creation discarded source'
 Key $picker 0x1B;Key $picker 0x1B
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
 # Emulate an interrupted rollback: startup must finish the journal before restore.
 $recoveryPath=LayoutPath 'recovery'
 $betaData=Get-Content $betaPath -Raw
 Set-Content $recoveryPath $betaData -Encoding utf8
 Set-Content "$recoveryPath.name" 'recovery' -NoNewline -Encoding utf8
 @{source='beta';target='recovery';source_data=$betaData;target_data=$null}|ConvertTo-Json -Compress|Set-Content "$betaPath.move" -Encoding utf8
 $gui=Launch 'beta'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Beta did not reopen after close'
 Assert (!(Test-Path "$betaPath.move") -and !(Test-Path $recoveryPath)) 'Interrupted transfer was not recovered'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 $live=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($live -join ',') -eq ($ids -join ',')) 'Close during preparation replaced shells'
 # Grow/shrink a multi-window workspace, always retaining the invoking HWND.
 Key $window 0x79
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 2} 'Second workspace window missing'
 Wait-For {(Get-Content $betaPath -Raw|ConvertFrom-Json).windows.Count -eq 2} 'Two-window layout was not saved'
 Wait-For {@(Get-ChildItem "$dir/*.started").Count -eq 5} 'Second window shell missing'
 SelectWorkspace $window 'alpha'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Two-to-one switch failed'
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Two-to-one switch replaced owner window'
 SelectWorkspace $window 'beta'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 2} 'One-to-two switch failed'
 Assert ([TabNative]::Windows($gui.Id) -contains $window) 'One-to-two switch replaced owner window'
 $secondary=@([TabNative]::Windows($gui.Id)|Where-Object {$_ -ne $window})[0]
 SelectWorkspace $secondary 'alpha'
 Wait-For {[WorkspacePicker]::Find($secondary) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Switch from secondary window failed'
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $secondary) 'Secondary invoking window was not reused'
 $window=$secondary
 SelectWorkspace $window 'beta'
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 2} 'Could not restore two windows'
 $beforeExtraction=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 # Extract the only tab in a window, then the final tab of its new workspace.
 foreach($newName in @('delta','epsilon')) {
     $paneHandles=@([TabNative]::Hosts($window,$false))
     Key $window 0x7B
     Wait-For {[WorkspacePicker]::Find($window) -ne 0} 'Picker missing before last-tab extraction'
     $picker=[WorkspacePicker]::Find($window);Start-Sleep -Milliseconds 400;Key $picker 0x71
     foreach($ch in $newName.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
     Key $picker 0x0D
     Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and [TabNative]::Windows($gui.Id).Count -eq 1} 'Last-tab extraction failed'
     Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Last-tab extraction replaced the window'
     Assert ((@([TabNative]::Hosts($window,$false)) -join ',') -eq ($paneHandles -join ',')) 'Last-tab extraction replaced its pane'
 }
 Assert ((Get-Content (LayoutPath 'delta') -Raw|ConvertFrom-Json).windows.Count -eq 0) 'Final tab remained in source workspace'
 $afterExtraction=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 Assert (($beforeExtraction -join ',') -eq ($afterExtraction -join ',')) 'Last-tab extraction changed shell processes'
 # Missing target broker must fail, without silently creating a replacement.
 $target=$alpha.windows[0].tabs[0].nodes|Where-Object { $_.leaf.session }|Select-Object -Last 1
 Mux @('stop',$target.leaf.session)|Out-Null
 Start-Sleep -Milliseconds 300
 SelectWorkspace $window 'gamma 日本';Start-Sleep -Milliseconds 700
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window -and [WorkspacePicker]::Find($window) -ne 0) 'Missing session discarded current views'
 Assert (@(Mux @('list')|ConvertFrom-Json).Count -eq 4) 'Missing shell was resurrected'
 Key ([WorkspacePicker]::Find($window)) 0x1B
 Write-Output "PASS: multi-window in-place switching, last-tab extraction, retained search, tab extraction with original pane HWNDs, journal recovery, workspace creation, empty/duplicate rejection, cancelled name entry preserves filter/selection, discovery, keyboard switching, original PIDs, input, split/title/zoom preservation, cancellation, close during preparation, F6 navigation, busy target and partial-attachment rollback. Artifacts: $dir"
} finally {
 foreach($p in @($peer,$gui)){if($p){if(!$p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
