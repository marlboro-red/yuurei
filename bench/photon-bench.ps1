# Software photon-proxy latency benchmark: foreground the target, inject a
# real keystroke via keybd_event, poll a small screen region until pixels
# change. The capture reflects the composed desktop, so this approximates
# keyboard-to-photon minus scanout — comparable across terminals.
param(
  [Int64]$Hwnd,
  [int]$RegionX, [int]$RegionY, [int]$RegionW = 400, [int]$RegionH = 50,
  [ValidateRange(1, 100000)][int]$Samples = 100,
  [string]$Label = "test",
  [int]$SettleMs = 600,
  [ValidateRange(0, 10000)][int]$JitterMs = 100,
  # Relative to the capture region; exclude a blinking cursor or animation.
  [int]$IgnoreX = 0, [int]$IgnoreY = 0,
  [int]$IgnoreW = 0, [int]$IgnoreH = 0,
  [ValidateRange(1, 1000000)][int]$MinChangedPixels = 1,
  [switch]$Json,
  [switch]$DumpBitmaps
)

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging;
public class PB {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static bool ForceForeground(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    uint fgPid; uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(me, fgTid, true);
    bool ok = SetForegroundWindow(h);
    AttachThreadInput(me, fgTid, false);
    return ok && GetForegroundWindow() == h;
  }
  static byte[] ba = new byte[0], bb = new byte[0];
  public static bool Differs(Bitmap a, Bitmap b, int ix, int iy, int iw, int ih, int minimum) {
    var r = new Rectangle(0, 0, a.Width, a.Height);
    var da = a.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var db = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try {
      int n = da.Stride * da.Height;
      if (ba.Length != n) { ba = new byte[n]; bb = new byte[n]; }
      Marshal.Copy(da.Scan0, ba, 0, n); Marshal.Copy(db.Scan0, bb, 0, n);
      int changed = 0;
      for (int y = 0; y < a.Height; y++) for (int x = 0; x < a.Width; x++) {
        if (x >= ix && x < ix + iw && y >= iy && y < iy + ih) continue;
        int i = y * da.Stride + x * 4;
        if ((ba[i] != bb[i] || ba[i+1] != bb[i+1] || ba[i+2] != bb[i+2]) && ++changed >= minimum) return true;
      }
      return false;
    } finally { a.UnlockBits(da); b.UnlockBits(db); }
  }
}
'@ -ReferencedAssemblies System.Drawing -ErrorAction SilentlyContinue
[PB]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type -AssemblyName System.Drawing

$bmpA = New-Object System.Drawing.Bitmap $RegionW, $RegionH
$bmpB = New-Object System.Drawing.Bitmap $RegionW, $RegionH
$gA = [System.Drawing.Graphics]::FromImage($bmpA)
$gB = [System.Drawing.Graphics]::FromImage($bmpB)

[PB]::ForceForeground([IntPtr]$Hwnd) | Out-Null
Start-Sleep -Milliseconds 800

$results = @()
$skipped = 0
$timeouts = 0
$jitter = [System.Random]::new(1729)
$sw = [System.Diagnostics.Stopwatch]::new()
for ($i = 0; $i -lt $Samples; $i++) {
  Start-Sleep -Milliseconds ($SettleMs + $jitter.Next($JitterMs + 1))
  if (-not [PB]::ForceForeground([IntPtr]$Hwnd)) { $skipped++; continue }
  $gA.CopyFromScreen($RegionX, $RegionY, 0, 0, $bmpA.Size)

  $sw.Restart()
  [PB]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)        # 'a' down
  [PB]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)        # 'a' up

  $dt = -1
  while ($sw.ElapsedMilliseconds -lt 1200) {
    $gB.CopyFromScreen($RegionX, $RegionY, 0, 0, $bmpB.Size)
    $t = $sw.Elapsed.TotalMilliseconds
    if ([PB]::Differs($bmpA, $bmpB, $IgnoreX, $IgnoreY, $IgnoreW, $IgnoreH, $MinChangedPixels)) { $dt = $t; break }
  }
  if ($dt -ge 0) { $results += $dt } else { $timeouts++ }

  if ($DumpBitmaps -and $i -eq 0) {
    $bmpA.Save("$env:TEMP\bench-A.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmpB.Save("$env:TEMP\bench-B.png", [System.Drawing.Imaging.ImageFormat]::Png)
  }

  Start-Sleep -Milliseconds 150
  [PB]::keybd_event(0x08, 0, 0, [UIntPtr]::Zero)        # backspace down
  [PB]::keybd_event(0x08, 0, 2, [UIntPtr]::Zero)        # backspace up
}

$sorted = @($results | Sort-Object)
$gA.Dispose(); $gB.Dispose(); $bmpA.Dispose(); $bmpB.Dispose()
if ($sorted.Count -eq 0) { "[$Label] NO PIXEL CHANGES DETECTED skipped=$skipped timeouts=$timeouts of $Samples"; exit 1 }
# [math]::Floor, not [int]: PowerShell's [int] cast banker's-rounds, so
# n=15 indexed the 9th sample instead of the true median (index 7).
$middle = [int][math]::Floor($sorted.Count / 2)
$median = if ($sorted.Count % 2) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
$p95 = $sorted[[math]::Ceiling($sorted.Count * 0.95) - 1]
$p99 = $sorted[[math]::Ceiling($sorted.Count * 0.99) - 1]
$report = [ordered]@{ label = $Label; n = $sorted.Count; skipped = $skipped; timeouts = $timeouts; median_ms = $median; p95_ms = $p95; p99_ms = $p99; samples_ms = $results }
if ($Json) { $report | ConvertTo-Json -Depth 3 } else {
  "[$Label] keyboard-to-pixels: n=$($sorted.Count) skipped=$skipped timeouts=$timeouts median=$([math]::Round($median, 2))ms p95=$([math]::Round($p95, 2))ms p99=$([math]::Round($p99, 2))ms"
}
