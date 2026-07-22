# Software photon-proxy latency benchmark: foreground the target, inject a
# real keystroke via keybd_event, poll a small screen region until pixels
# change. The capture reflects the composed desktop, so this approximates
# keyboard-to-photon minus scanout — comparable across terminals.
param(
  [Int64]$Hwnd,
  [int]$RegionX, [int]$RegionY, [int]$RegionW = 400, [int]$RegionH = 50,
  [int]$Samples = 15,
  [string]$Label = "test",
  [int]$SettleMs = 600,
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
  public static bool Differs(Bitmap a, Bitmap b) {
    var r = new Rectangle(0, 0, a.Width, a.Height);
    var da = a.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var db = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try {
      int n = da.Stride * da.Height;
      var ba = new byte[n]; var bb = new byte[n];
      Marshal.Copy(da.Scan0, ba, 0, n); Marshal.Copy(db.Scan0, bb, 0, n);
      for (int i = 0; i < n; i++) if (ba[i] != bb[i]) return true;
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
$sw = [System.Diagnostics.Stopwatch]::new()
for ($i = 0; $i -lt $Samples; $i++) {
  Start-Sleep -Milliseconds $SettleMs
  if (-not [PB]::ForceForeground([IntPtr]$Hwnd)) { $skipped++; continue }
  $gA.CopyFromScreen($RegionX, $RegionY, 0, 0, $bmpA.Size)

  $sw.Restart()
  [PB]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)        # 'a' down
  [PB]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)        # 'a' up

  $dt = -1
  while ($sw.ElapsedMilliseconds -lt 1200) {
    $gB.CopyFromScreen($RegionX, $RegionY, 0, 0, $bmpB.Size)
    $t = $sw.Elapsed.TotalMilliseconds
    if ([PB]::Differs($bmpA, $bmpB)) { $dt = $t; break }
  }
  if ($dt -ge 0) { $results += [Math]::Round($dt, 1) }

  if ($DumpBitmaps -and $i -eq 0) {
    $bmpA.Save("$env:TEMP\bench-A.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmpB.Save("$env:TEMP\bench-B.png", [System.Drawing.Imaging.ImageFormat]::Png)
  }

  Start-Sleep -Milliseconds 150
  [PB]::keybd_event(0x08, 0, 0, [UIntPtr]::Zero)        # backspace down
  [PB]::keybd_event(0x08, 0, 2, [UIntPtr]::Zero)        # backspace up
}

$sorted = @($results | Sort-Object)
if ($sorted.Count -eq 0) { "[$Label] NO PIXEL CHANGES DETECTED skipped=$skipped of $Samples"; exit 1 }
# [math]::Floor, not [int]: PowerShell's [int] cast banker's-rounds, so
# n=15 indexed the 9th sample instead of the true median (index 7).
$median = $sorted[[math]::Floor($sorted.Count / 2)]
"[$Label] keyboard-to-pixels: n=$($sorted.Count) skipped=$skipped median=$($median)ms samples: $($sorted -join ', ')"
