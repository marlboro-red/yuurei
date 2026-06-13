# Move a window to a fixed spot and screenshot that screen rect for region picking.
param([Int64]$Hwnd, [string]$Out)
Add-Type @'
using System; using System.Runtime.InteropServices;
public class SH {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
}
'@ -ErrorAction SilentlyContinue
[SH]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type -AssemblyName System.Drawing
[SH]::MoveWindow([IntPtr]$Hwnd, 100, 100, 1000, 600, $true) | Out-Null
[SH]::SetForegroundWindow([IntPtr]$Hwnd) | Out-Null
Start-Sleep -Milliseconds 800
$bmp = New-Object System.Drawing.Bitmap 1000, 600
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(100, 100, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out"
