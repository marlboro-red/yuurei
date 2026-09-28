#requires -Version 7.0
# Run on an isolated desktop; reuse the workspace fixture and posted-key helpers.
param([string]$Bin="$PSScriptRoot/../../zig-out/workspace-move/bin")
$setup=Get-Content "$PSScriptRoot/mux-workspace-switch.ps1" -Raw -Encoding utf8
$start=$setup.IndexOf('$ErrorActionPreference')
$fixture=$setup.Substring($start,$setup.IndexOf('$gui=$null;$peer=$null')-$start)
$fixture=$fixture.Replace('"$PSScriptRoot/tab-transfer-smoke.ps1"', "'$PSScriptRoot/tab-transfer-smoke.ps1'")
Invoke-Expression $fixture
Add-Content "$dir/ghostty/config" 'keybind = f17=session:workspace_move' -Encoding utf8
function MovePicker([IntPtr]$Window,[string]$Name) {
 Key $Window 0x80
 Wait-For {[WorkspacePicker]::Find($Window) -ne 0} 'Move picker missing'
 $picker=[WorkspacePicker]::Find($Window)
 Start-Sleep -Milliseconds 400
 foreach($ch in $Name.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 return $picker
}
function Layout([string]$Name) { Get-Content (LayoutPath $Name) -Raw | ConvertFrom-Json }
function SameShells {
 Assert ((@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object) -join ',') -eq ($ids -join ',')) 'Move changed shell PIDs'
 Assert (@(Get-ChildItem "$dir/*.started").Count -eq 5) 'Move started another shell'
}
$gui=$null;$peer=$null
try {
 $gui=Launch 'alpha'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'Source window missing'
 $window=[TabNative]::Windows($gui.Id)[0];[void][TabNative]::ShowWindow($window,5)
 Key $window 0x74;Key $window 0x78;Key $window 0x76;Key $window 0x73;Key $window 0x77
 Wait-For {(Test-Path (LayoutPath 'alpha')) -and (Layout 'alpha').windows[0].tabs.Count -eq 2} 'Source tabs missing'
 $peer=Launch 'beta'
 Wait-For {[TabNative]::Windows($peer.Id).Count -eq 1} 'Destination window missing'
 $targetWindow=[TabNative]::Windows($peer.Id)[0];[void][TabNative]::ShowWindow($targetWindow,5)
 Key $targetWindow 0x79
 Wait-For {(Test-Path (LayoutPath 'beta')) -and (Layout 'beta').windows.Count -eq 2 -and @(Get-ChildItem "$dir/*.started").Count -eq 5} 'Destination layout missing'
 $ids=@(@(Mux @('list')|ConvertFrom-Json).shell_pid|Sort-Object)
 $alpha=Layout 'alpha';$beta=Layout 'beta'
 $originalHostHandles=@([TabNative]::Hosts($window,$false))
 $originalHosts=$originalHostHandles -join ','
 # Reject a destination owned by another GUI, without altering either layout.
 $picker=MovePicker $window 'beta';Key $picker 0x0D;Start-Sleep -Milliseconds 500
 Assert ([WorkspacePicker]::Find($window) -ne 0 -and (@([TabNative]::Hosts($window,$false)) -join ',') -eq $originalHosts) 'Busy move changed source views'
 Assert ((Layout 'alpha').windows[0].tabs.Count -eq 2 -and (Layout 'beta').windows[0].tabs.Count -eq 1) 'Busy move modified layouts'
 Key $picker 0x1B
 $peer.Kill();$peer.WaitForExit();$peer.Dispose();$peer=$null
 # Cancel queued preparation; an existing destination must never be deleted.
 $picker=MovePicker $window 'beta'
 [void][WorkspacePicker]::Post($picker,0x100,0x0D,0)
 [void][WorkspacePicker]::Post($picker,0x100,0x1B,0)
 Start-Sleep -Milliseconds 600
 Assert ((@([TabNative]::Hosts($window,$false)) -join ',') -eq $originalHosts) 'Cancelled move detached views'
 Assert ((Layout 'alpha').windows[0].tabs.Count -eq 2 -and (Layout 'beta').windows[0].tabs.Count -eq 1) 'Cancelled move changed layouts'
 # Refresh retains move mode; source stays open with its other tab.
 $picker=MovePicker $window 'beta';Key $picker 0x74;Start-Sleep -Milliseconds 400
 foreach($ch in 'beta'.ToCharArray()){[void][WorkspacePicker]::Post($picker,0x102,[int]$ch,0)}
 Key $picker 0x0D
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and @([TabNative]::Hosts($window,$false)).Count -eq 1} 'Move did not detach the selected tab'
 Assert ([TabNative]::Windows($gui.Id)[0] -eq $window) 'Move replaced the source window'
 Assert ([TabNative]::Hosts($window,$false)[0] -in $originalHostHandles) 'Move replaced the remaining pane'
 $remaining=Layout 'alpha';$combined=Layout 'beta'
 Assert ($remaining.windows[0].tabs.Count -eq 1) 'Source retained moved tab'
 Assert ($combined.windows.Count -eq 2 -and $combined.windows[0].tabs.Count -eq 2 -and $combined.windows[0].active -eq 1) 'Destination append or selection incorrect'
 Assert (($combined.windows[0].tabs[1]|ConvertTo-Json -Depth 12 -Compress) -eq ($alpha.windows[0].tabs[0]|ConvertTo-Json -Depth 12 -Compress)) 'Move lost split/title/zoom metadata'
 Assert (($combined.windows[1]|ConvertTo-Json -Depth 12 -Compress) -eq ($beta.windows[1]|ConvertTo-Json -Depth 12 -Compress)) 'Move changed another destination window'
 SameShells
 $peer=Launch 'beta'
 Wait-For {[TabNative]::Windows($peer.Id).Count -eq 2 -and @([TabNative]::Windows($peer.Id)|Where-Object {@([TabNative]::Hosts($_,$false)).Count -eq 3}).Count -eq 1} 'Destination could not restore after move'
 $targetWindow=@([TabNative]::Windows($peer.Id)|Where-Object {@([TabNative]::Hosts($_,$false)).Count -eq 3})[0]
 Assert ($targetWindow -ne 0) 'Moved split did not restore'
 [void][TabNative]::ShowWindow($targetWindow,5)
 Wait-For {@([TabNative]::Hosts($targetWindow,$true)).Count -eq 1} 'Moved zoom did not restore'
 Key $targetWindow 0x72
 Wait-For {@(Get-ChildItem "$dir/*.input").Count -eq 1} 'Moved shell did not receive input'
 Assert ((Get-Content (Get-ChildItem "$dir/*.input")[0].FullName -Raw) -match '^x\r?\n$') 'Move picker keys leaked into a shell'
 $peer.Kill();$peer.WaitForExit();$peer.Dispose();$peer=$null
 # Sending the final tab closes only its source window; all shells remain alive.
 $picker=MovePicker $window 'beta';Key $picker 0x0D
 Assert ($gui.WaitForExit(10000)) 'Last-tab move did not close the empty source window'
 Assert ($gui.ExitCode -eq 0) 'Last-tab move crashed the source GUI'
 $gui.Dispose();$gui=$null
 Assert ((Layout 'alpha').windows.Count -eq 0 -and (Layout 'beta').windows[0].tabs.Count -eq 3) 'Last-tab move did not persist both layouts'
 SameShells
 # The now-empty source is a valid destination, with no replacement shell.
 $gui=Launch 'beta'
 Wait-For {[TabNative]::Windows($gui.Id).Count -eq 2 -and @([TabNative]::Windows($gui.Id)|Where-Object {@([TabNative]::Hosts($_,$false)).Count -eq 4}).Count -eq 1} 'Could not reopen destination'
 $window=@([TabNative]::Windows($gui.Id)|Where-Object {@([TabNative]::Hosts($_,$false)).Count -eq 4})[0]
 Assert ($window -ne 0) 'Destination tabs did not restore'
 $picker=MovePicker $window 'alpha';Key $picker 0x0D
 Wait-For {[WorkspacePicker]::Find($window) -eq 0 -and @([TabNative]::Hosts($window,$false)).Count -eq 3} 'Move into empty workspace failed'
 Assert ((Layout 'alpha').windows[0].tabs.Count -eq 1 -and (Layout 'beta').windows[0].tabs.Count -eq 2) 'Empty destination move lost or duplicated tabs'
 SameShells
 Write-Output "PASS: busy target, cancellation, refresh mode, split/title/zoom preservation, multi-window destination, shell PIDs and input, last-tab closure, empty destination. Artifacts: $dir"
} finally {
 foreach($p in @($peer,$gui)){if($p){if(!$p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}}
 foreach($entry in @(Mux @('list')|ConvertFrom-Json)){try{Mux @('stop',$entry.name)|Out-Null}catch{}}
}
