#requires -Version 7.0
param(
    [string]$Bin = "$PSScriptRoot/../zig-out/bin",
    [ValidateRange(1,100)][int]$Runs = 3,
    [ValidateRange(1,60)][int]$IdleSeconds = 20,
    [ValidateRange(0,1000)][int]$ChunkPauseMs = 0,
    [ValidateRange(0,1024)][int]$OutputMiB = 8,
    [string]$Artifacts = "$env:TEMP/yuurei-mux-bench"
)
$ErrorActionPreference = 'Stop'
$Bin = (Resolve-Path $Bin).Path
$root = Join-Path $Artifacts ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root -Force | Out-Null
$harness = Get-Content "$PSScriptRoot/../test/windows/tab-transfer-smoke.ps1" -Raw
Invoke-Expression $harness.Substring($harness.IndexOf('Add-Type -AssemblyName'), $harness.IndexOf('$isolation = Join-Path $Artifacts') - $harness.IndexOf('Add-Type -AssemblyName'))
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class BenchTitle {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Get(IntPtr h) {var b=new StringBuilder(1024);GetWindowText(h,b,1024);return b.ToString();}
 public static double Roundtrip(IntPtr h,string expected) {
  var b=new StringBuilder(1024);var timer=System.Diagnostics.Stopwatch.StartNew();
  PostMessage(h,0x100,(IntPtr)0x74,IntPtr.Zero);PostMessage(h,0x101,(IntPtr)0x74,IntPtr.Zero);
  while(timer.Elapsed.TotalSeconds<10){b.Clear();GetWindowText(h,b,1024);if(b.ToString().Contains(expected))return timer.Elapsed.TotalMilliseconds;System.Threading.Thread.Yield();}
  throw new Exception("Input roundtrip timed out");
 }
}
'@
$rows = [Collections.Generic.List[object]]::new()
function Sample($Processes) {
    $cpu=0.0; $private=0L; $resident=0L; $threads=0; $handles=0
    foreach($p in $Processes) { $p.Refresh(); $cpu+=$p.TotalProcessorTime.TotalMilliseconds; $private+=$p.PrivateMemorySize64; $resident+=$p.WorkingSet64; $threads+=$p.Threads.Count; $handles+=$p.HandleCount }
    [pscustomobject]@{cpu_ms=$cpu;private_mib=$private/1MB;resident_mib=$resident/1MB;threads=$threads;handles=$handles}
}
function Wait-Title($Window,$Expected) {
    $limit=[Diagnostics.Stopwatch]::StartNew()
    while($limit.Elapsed.TotalSeconds -lt 60) {
        $title=[BenchTitle]::Get($Window)
        if($title.Contains($Expected)){return}
        if($title -match 'history expired|disconnected|unavailable'){throw "Pane failed: $title"}
        Start-Sleep -Milliseconds 2
    }
    throw "Timed out waiting for $Expected; title=$([BenchTitle]::Get($Window))"
}
for($run=0;$run -lt $Runs;$run++) {
    $order=if($run%2){@('mux','direct')}else{@('direct','mux')}
    foreach($mode in $order) {
        $dir=Join-Path $root "$run-$mode"
        New-Item -ItemType Directory "$dir/ghostty" -Force | Out-Null
        @'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Type @"
using System; using System.IO; using System.Text; using System.Diagnostics; using System.Threading;
public static class Producer {
 public static void Run(string dir, int pause, int mib) {
  var output=Console.OpenStandardOutput();
  Action<string> title=s=>{var b=Encoding.UTF8.GetBytes("\x1b]2;"+s+"\x07");output.Write(b,0,b.Length);output.Flush();};
  File.WriteAllText(Path.Combine(dir,"shell.pid"),Environment.ProcessId.ToString());
  title("BENCH_READY");
  foreach(var kind in new[]{"ascii","unicode"}) {
   string line=kind=="ascii" ? "The quick brown fox 0123456789 build output repeated for scrollback\r\n" : "日本語 Ελληνικά Кириллица العربية 👻 🚀 combining: é\r\n";
   var builder=new StringBuilder();for(int i=0;i<128;i++)builder.Append(line);
   byte[] block=Encoding.UTF8.GetBytes(builder.ToString());int count=(mib*1024*1024)/block.Length;
   while(!File.Exists(Path.Combine(dir,kind+".go")))Thread.Sleep(2);
   var watch=Stopwatch.StartNew();for(int i=0;i<count;i++){output.Write(block,0,block.Length);if(pause>0)Thread.Sleep(pause);}output.Flush();
   title("BENCH_DONE_"+kind);watch.Stop();
   File.WriteAllText(Path.Combine(dir,kind+".json"),"{\"bytes\":"+(count*block.Length)+",\"producer_ms\":"+watch.Elapsed.TotalMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture)+"}");
  }
  for(int i=0;i<20;i++){Console.ReadKey(true);title("BENCH_KEY_"+i+"_END");}
  Thread.Sleep(Timeout.Infinite);
 }
}
"@
[Producer]::Run($PSScriptRoot, [int](Get-Content "$PSScriptRoot/pause.txt"), [int](Get-Content "$PSScriptRoot/size.txt"))
'@ | Set-Content "$dir/worker.ps1" -Encoding utf8
        Set-Content "$dir/pause.txt" $ChunkPauseMs
        Set-Content "$dir/size.txt" $OutputMiB
        $name='bench-'+[guid]::NewGuid().ToString('N')
        $launch=if($mode -eq 'mux'){"windows-mux-session = $name"}else{'command = pwsh.exe -NoLogo -NoProfile -File "'+("$dir/worker.ps1".Replace('\','\\'))+'"'}
        @"
$launch
windows-restore-session = false
windows-auto-update = false
confirm-close-surface = false
scrollback-limit-bytes = 1048576
font-size = 12
window-width = 100
window-height = 30
keybind = f5=text:x
"@ | Set-Content "$dir/ghostty/config"
        $gui=$null; $broker=$null; $shellProcess=$null
        try {
            if($mode -eq 'mux') {
                $broker=Start-Process "$Bin/yuurei-mux.exe" -ArgumentList @('serve',$name,'pwsh.exe','-NoLogo','-NoProfile','-File',('"{0}"' -f "$dir/worker.ps1")) -WindowStyle Hidden -PassThru -RedirectStandardError "$dir/broker.log"
                Wait-For {Test-Path "$dir/shell.pid"} 'Broker shell failed to initialize'
            }
            $gui=Start-Process "$Bin/ghostty.exe" -PassThru -Environment @{XDG_CONFIG_HOME=$dir;LOCALAPPDATA=$dir;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError "$dir/gui.log"
            Wait-For {[TabNative]::Windows($gui.Id).Count -eq 1} 'GUI failed to open'
            $window=[TabNative]::Windows($gui.Id)[0]
            [void][TabNative]::ShowWindow($window,5)
            Wait-Title $window 'BENCH_READY'
            $shellProcess=Get-Process -Id ([int](Get-Content "$dir/shell.pid"))
            $owned=@($gui);if($broker){$owned+=,$broker}
            Start-Sleep -Seconds 3
            $before=Sample $owned
            $timer=[Diagnostics.Stopwatch]::StartNew()
            Start-Sleep -Seconds $IdleSeconds
            $after=Sample $owned
            $idleElapsed=$timer.Elapsed.TotalMilliseconds
            $result=[ordered]@{run=$run;mode=$mode;idle=$after;idle_cpu_ms=$after.cpu_ms-$before.cpu_ms;idle_one_core_percent=100*($after.cpu_ms-$before.cpu_ms)/$idleElapsed;shell=Sample @($shellProcess);gui=Sample @($gui)}
            if($broker){$result.broker=Sample @($broker)}
            $result.chunk_pause_ms=$ChunkPauseMs
            $result.output_mib=$OutputMiB
            $result | ConvertTo-Json -Depth 8 | Set-Content "$dir/idle.json"
            foreach($kind in 'ascii','unicode') {
                $before=Sample $owned
                $timer.Restart()
                [IO.File]::WriteAllText("$dir/$kind.go",'go')
                Wait-Title $window "BENCH_DONE_$kind"
                $elapsed=$timer.Elapsed.TotalMilliseconds
                Wait-For {Test-Path "$dir/$kind.json"} 'Missing producer measurement'
                $producer=Get-Content "$dir/$kind.json" -Raw | ConvertFrom-Json
                $after=Sample $owned
                $result[$kind]=@{observed_ms=$elapsed;producer_ms=$producer.producer_ms;mib_per_second=($producer.bytes/1MB)/($elapsed/1000);cpu_ms=$after.cpu_ms-$before.cpu_ms;memory=$after}
            }
            $latencies=@()
            for($k=0;$k -lt 20;$k++) {
                $latencies+=[BenchTitle]::Roundtrip($window,"BENCH_KEY_${k}_END")
            }
            $result.input_title_roundtrip_ms=$latencies
            $rows.Add([pscustomobject]$result)
            $rows | ConvertTo-Json -Depth 8 | Set-Content "$root/results.json"
            Write-Host "$run $mode done: idle private $([math]::Round($result.idle.private_mib,1)) MiB; ASCII $([math]::Round($result.ascii.mib_per_second,2)) MiB/s; Unicode $([math]::Round($result.unicode.mib_per_second,2)) MiB/s"
        } catch {
            $_ | Out-String | Set-Content "$dir/failure.txt"
            throw
        } finally {
            if($gui -and !$gui.HasExited){$gui.Kill();$gui.WaitForExit()}
            if($broker -and !$broker.HasExited){ & "$Bin/yuurei-mux.exe" stop $name 2>>"$dir/stop.log" | Out-Null; if(!$broker.WaitForExit(5000)){$broker.Kill();$broker.WaitForExit()} }
            if($shellProcess){$shellProcess.Refresh();if(!$shellProcess.HasExited){$shellProcess.Kill()};$shellProcess.Dispose()}
            if($gui){$gui.Dispose()}
            if($broker){$broker.Dispose()}
        }
    }
}
Write-Host "Artifacts: $root"
