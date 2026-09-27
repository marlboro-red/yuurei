param(
    [string]$Executable = "$PSScriptRoot/../../zig-out/bin/yuurei-mux.exe",
    [string]$GuiExecutable,
    [switch]$NativePane,
    [string]$Artifacts = "$env:TEMP/yuurei-mux-tests"
)
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path $Executable).Path
$dir = Join-Path $Artifacts ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir -Force | Out-Null
$name = 'test-' + [guid]::NewGuid().ToString('N')
$worker = Join-Path $dir 'worker.ps1'
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText("$PSScriptRoot/shell.pid", "$PID")
$i=0
while(!(Test-Path "$PSScriptRoot/interactive")) {
    for($n=0;$n -lt 100;$n++) {
        [Console]::WriteLine("PID=$PID COUNTER=$i 日本語 é 🚀")
        $i++
    }
    [IO.File]::WriteAllText("$PSScriptRoot/counter", "$i")
    Start-Sleep -Milliseconds $(if(Test-Path "$PSScriptRoot/slow"){350}else{25})
}
[Console]::WriteLine('READY_FOR_INPUT')
while($true) {
    $key=[Console]::ReadKey($true)
    [IO.File]::WriteAllText("$PSScriptRoot/key", "$($key.KeyChar)")
    switch($key.KeyChar) {
        'a' { [Console]::Write("`e[?1049h`e[H`e[2JALTERNATE_SCREEN") }
        'b' { [Console]::Write("`e[?1049l"); [Console]::WriteLine('PRIMARY_RESTORED') }
        'q' { exit 0 }
        default { [Console]::WriteLine("INPUT_RECEIVED=$($key.KeyChar) PID=$PID") }
    }
}
'@ | Set-Content $worker -Encoding utf8
function Assert($condition, $message) { if(!$condition) { throw $message } }
function Wait-For([scriptblock]$condition, $message) {
    for($i=0;$i -lt 100;$i++) { if(& $condition) { return }; Start-Sleep -Milliseconds 100 }
    throw $message
}
function Invoke-Mux([string[]]$Arguments) {
    $psi=[Diagnostics.ProcessStartInfo]::new($Executable)
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($a in $Arguments){$psi.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::Start($psi)
    try {
        $output=$p.StandardOutput.ReadToEndAsync()
        $errors=$p.StandardError.ReadToEndAsync()
        if(!$p.WaitForExit(10000)) {$p.Kill();throw 'Mux client timed out'}
        $text=$output.GetAwaiter().GetResult()
        $log=$errors.GetAwaiter().GetResult()
        Add-Content "$dir/client.log" $log
        if($p.ExitCode -ne 0){throw "Mux $Arguments failed: $log"}
        return $text
    } finally {$p.Dispose()}
}
$broker=Start-Process $Executable -ArgumentList @('serve',$name,'pwsh.exe','-NoProfile','-File',('"{0}"' -f $worker)) -WindowStyle Hidden -PassThru -RedirectStandardError "$dir/broker.log" -RedirectStandardOutput "$dir/broker.out"
$gui=$null
try {
    Wait-For {Test-Path "$dir/counter"} 'Shell did not start'
    $first=Invoke-Mux @('status',$name) | ConvertFrom-Json
    Assert (!$first.exited -and !$first.failed) 'Initial session unhealthy'
    $duplicateRejected=$false
    try {Invoke-Mux @('serve',$name,'pwsh.exe') | Out-Null} catch {$duplicateRejected=$true}
    Assert $duplicateRejected 'Duplicate broker was accepted'
    $testShellPid=[int](Get-Content "$dir/shell.pid")
    Assert ($first.shell_pid -eq $testShellPid) 'Broker reports wrong shell PID'
    $before=[int](Get-Content "$dir/counter")
    Start-Sleep -Seconds 2
    Assert ([int](Get-Content "$dir/counter") -gt $before) 'Detached shell stopped producing output'
    $capture=Invoke-Mux @('capture',$name)
    Assert ($capture.Contains("PID=$testShellPid") -and $capture.Contains('日本語')) 'Snapshot lost shell output or Unicode'
    $capture | Set-Content "$dir/detached.txt"
    if($GuiExecutable) {
        $harness=Get-Content "$PSScriptRoot/tab-transfer-smoke.ps1" -Raw
        $begin=$harness.IndexOf('Add-Type -AssemblyName')
        $end=$harness.IndexOf('$isolation = Join-Path $Artifacts')
        Invoke-Expression $harness.Substring($begin,$end-$begin)
        New-Item -ItemType Directory "$dir/ghostty" | Out-Null
        $paneLaunch=if($NativePane){"windows-mux-session = $name"}else{'command = "{0}" attach {1}' -f $Executable.Replace('\','\\'),$name}
        $detachBinding=if($NativePane){'close_surface'}else{'text:\x1d'}
        $closePolicy=if($NativePane){'true'}else{'false'}
        @"
$paneLaunch
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = $closePolicy
font-size = 12
keybind = f5=text:x
keybind = f6=$detachBinding
keybind = f8=scroll_page_up
keybind = f9=scroll_to_bottom
"@ | Set-Content "$dir/ghostty/config"
        $gui=Start-Process $GuiExecutable -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$dir;LOCALAPPDATA=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui.log"
        Wait-For { [TabNative]::Windows($gui.Id).Count -eq 1 } 'Test GUI did not open'
        $window=[TabNative]::Windows($gui.Id)[0]
        [void][TabNative]::ShowWindow($window,5)
        [void][TabNative]::SetWindowPos($window,0,60,60,1400,900,0)
        [void][TabNative]::SetForegroundWindow($window)
        Start-Sleep -Seconds 3
        if($NativePane) {
            $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($gui.Id)" | Where-Object {$_.Name -in @('yuurei-mux.exe','pwsh.exe','cmd.exe','OpenConsole.exe')})
            Assert ($children.Count -eq 0) 'Native pane spawned a helper or shell'
        }
        $r=New-Object TabNative+Rect
        [void][TabNative]::GetWindowRect($window,[ref]$r)
        $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {$graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size);$bitmap.Save("$dir/attached.png")}
        finally {$graphics.Dispose();$bitmap.Dispose()}
        if($NativePane) {
            # Keep this scroll-position check within the broker's bounded
            # history: the burst workload otherwise evicts these rows in <1s.
            Set-Content "$dir/slow" ''
            Start-Sleep -Milliseconds 500
            [void][TabNative]::PostMessage($window,0x100,0x77,0)
            [void][TabNative]::PostMessage($window,0x101,0x77,0)
            foreach($frame in @('scroll-a','scroll-b')) {
                Start-Sleep -Milliseconds 350
                $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
                $graphics=[Drawing.Graphics]::FromImage($bitmap)
                try {$graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size);$bitmap.Save("$dir/$frame.png")}
                finally {$graphics.Dispose();$bitmap.Dispose()}
            }
            $a=[Drawing.Bitmap]::new("$dir/scroll-a.png")
            $b=[Drawing.Bitmap]::new("$dir/scroll-b.png")
            try {
                $different=0
                for($y=90;$y -lt $a.Height-30;$y+=4){for($x=20;$x -lt [Math]::Min(1000,$a.Width-40);$x+=4){if($a.GetPixel($x,$y).ToArgb() -ne $b.GetPixel($x,$y).ToArgb()){$different++}}}
                Assert ($different -eq 0) "Native scrollback moved during retained output ($different differing samples)"
            } finally {$a.Dispose();$b.Dispose()}
        }
        # Kill ONLY the test-owned GUI. This is the persistence assertion.
        $before=[int](Get-Content "$dir/counter")
        $gui.Kill(); $gui.WaitForExit(); $gui=$null
        Start-Sleep -Seconds 4
        Assert (!$broker.HasExited) 'GUI crash killed broker'
        Assert ([int](Get-Content "$dir/counter") -gt $before) 'GUI crash stalled shell output'
    }
    Set-Content "$dir/interactive" ''
    Start-Sleep -Milliseconds 500
    if($GuiExecutable) {
        $gui=Start-Process $GuiExecutable -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$dir;LOCALAPPDATA=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui-reconnect.log"
        Wait-For { [TabNative]::Windows($gui.Id).Count -eq 1 } 'Reconnect GUI did not open'
        $window=[TabNative]::Windows($gui.Id)[0]
        [void][TabNative]::ShowWindow($window,5)
        [void][TabNative]::SetWindowPos($window,0,60,60,1400,900,0)
        [void][TabNative]::SetForegroundWindow($window)
        Start-Sleep -Seconds 2
        [void][TabNative]::PostMessage($window,0x100,0x74,0)
        [void][TabNative]::PostMessage($window,0x101,0x74,0)
        Wait-For { (Test-Path "$dir/key") -and (Get-Content "$dir/key" -Raw) -eq 'x' } 'Reconnected GUI input did not reach original shell'
        Start-Sleep -Milliseconds 300
        $r=New-Object TabNative+Rect
        [void][TabNative]::GetWindowRect($window,[ref]$r)
        $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {$graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size);$bitmap.Save("$dir/reconnected.png")}
        finally {$graphics.Dispose();$bitmap.Dispose()}
        [void][TabNative]::PostMessage($window,0x100,0x75,0)
        [void][TabNative]::PostMessage($window,0x101,0x75,0)
        Assert ($gui.WaitForExit(8000)) 'Closing/detaching the view failed'
        $gui=$null
        Assert (!$broker.HasExited) 'Detach killed broker'
    }
    $second=Invoke-Mux @('status',$name) | ConvertFrom-Json
    Assert ($second.shell_pid -eq $testShellPid -and !$second.exited -and !$second.failed) 'Reconnect lost original shell'
    Invoke-Mux @('input',$name,'x') | Out-Null
    Start-Sleep -Milliseconds 200
    $capture=Invoke-Mux @('capture',$name)
    Assert ($capture.Contains("INPUT_RECEIVED=x PID=$testShellPid")) 'Reconnected input missed original shell'
    Invoke-Mux @('input',$name,'a') | Out-Null
    Start-Sleep -Milliseconds 200
    Assert ((Invoke-Mux @('capture',$name)).Contains('ALTERNATE_SCREEN')) 'Alternate screen not restored'
    Invoke-Mux @('resize',$name,'80','24') | Out-Null
    $invalidSizeRejected=$false
    try {Invoke-Mux @('resize',$name,'0','24') | Out-Null} catch {$invalidSizeRejected=$true}
    Assert $invalidSizeRejected 'Zero-sized terminal was accepted'
    Invoke-Mux @('input',$name,'b') | Out-Null
    Start-Sleep -Milliseconds 200
    Assert ((Invoke-Mux @('capture',$name)).Contains('PRIMARY_RESTORED')) 'Primary screen lost after resize'
    $samples=@()
    for($i=0;$i -lt 20;$i++) {
        $state=Invoke-Mux @('status',$name) | ConvertFrom-Json
        Assert ($state.shell_pid -eq $testShellPid -and !$state.failed) 'Repeated reconnect failed'
        $broker.Refresh()
        $samples += [pscustomobject]@{Reconnect=$i;PrivateMiB=$broker.PrivateMemorySize64/1MB;ResidentMiB=$broker.WorkingSet64/1MB;Handles=$broker.HandleCount;Threads=$broker.Threads.Count}
    }
    $samples | Export-Csv "$dir/memory.csv" -NoTypeInformation
    Assert ($samples[-1].Handles -le $samples[0].Handles+2) 'Reconnects leaked handles'
    $broker.Refresh(); $cpuBefore=$broker.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 2
    $broker.Refresh()
    [pscustomobject]@{IdleIntervalSeconds=2;CpuMilliseconds=$broker.TotalProcessorTime.TotalMilliseconds-$cpuBefore;PrivateMiB=$broker.PrivateMemorySize64/1MB;ResidentMiB=$broker.WorkingSet64/1MB} | ConvertTo-Json | Set-Content "$dir/idle.json"
    Invoke-Mux @('input',$name,'q') | Out-Null
    Start-Sleep -Milliseconds 500
    Assert ((Invoke-Mux @('status',$name) | ConvertFrom-Json).exited) 'Child exit was not observed'
    Invoke-Mux @('stop',$name) | Out-Null
    Assert ($broker.WaitForExit(5000)) 'Broker did not stop cleanly'
    Assert ($broker.ExitCode -eq 0) 'Broker shutdown failed'
    if($NativePane -and $GuiExecutable) {
        # The same config now names a missing broker. Keep an error pane;
        # never fall back to silently creating a new shell.
        $gui=Start-Process $GuiExecutable -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$dir;LOCALAPPDATA=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/missing-session.log"
        Wait-For { [TabNative]::Windows($gui.Id).Count -eq 1 } 'Missing session did not show an error pane'
        $window=[TabNative]::Windows($gui.Id)[0]
        [void][TabNative]::ShowWindow($window,5)
        [void][TabNative]::SetWindowPos($window,0,60,60,1400,900,0)
        [void][TabNative]::SetForegroundWindow($window)
        Start-Sleep -Seconds 1
        $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($gui.Id)" | Where-Object {$_.Name -in @('yuurei-mux.exe','pwsh.exe','cmd.exe','OpenConsole.exe')})
        Assert ($children.Count -eq 0) 'Missing session silently started a shell'
        $r=New-Object TabNative+Rect
        [void][TabNative]::GetWindowRect($window,[ref]$r)
        $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size)
            $bitmap.Save("$dir/missing-session.png")
            $middle=$bitmap.GetPixel($bitmap.Width-50,[int]($bitmap.Height/2)).ToArgb()
            $bottom=$bitmap.GetPixel([int]($bitmap.Width/2),$bitmap.Height-40).ToArgb()
            Assert ($middle -eq $bottom) 'Error pane did not fill the resized terminal area'
        }
        finally {$graphics.Dispose();$bitmap.Dispose()}
        [void][TabNative]::PostMessage($window,0x10,0,0)
        Assert ($gui.WaitForExit(5000)) 'Missing-session window would not close'
        $gui=$null
    }
    # Reclaim the same endpoint, then explicitly terminate a still-running
    # shell. This checks the lifetime distinction between detach and stop.
    $broker=Start-Process $Executable -ArgumentList @('serve',$name,'cmd.exe','/D','/Q','/K') -WindowStyle Hidden -PassThru -RedirectStandardError "$dir/live-stop.log" -RedirectStandardOutput "$dir/live-stop.out"
    Start-Sleep -Milliseconds 500
    $live=Invoke-Mux @('status',$name) | ConvertFrom-Json
    Assert (!$live.exited) 'Live-stop fixture exited early'
    Invoke-Mux @('stop',$name) | Out-Null
    Assert ($broker.WaitForExit(5000) -and $broker.ExitCode -eq 0) 'Stopping live shell hung the broker'
    Wait-For { !(Get-Process -Id $live.shell_pid -ErrorAction SilentlyContinue) } 'Stop left the hosted shell running'
    Write-Output "PASS: detached output, original PID, reconnect input, Unicode, alternate screen, resize, repeated reconnect, child exit, shutdown. Artifacts: $dir"
} finally {
    if($gui -and !$gui.HasExited){$gui.Kill();$gui.WaitForExit()}
    if(!$broker.HasExited){try {Invoke-Mux @('stop',$name) | Out-Null} catch {}; if(!$broker.WaitForExit(5000)){$broker.Kill();$broker.WaitForExit()}}
}
