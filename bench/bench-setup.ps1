# Launch a terminal, find its top-level window, move it to a known spot.
param(
  [string]$Exe,
  [string]$WindowClass,   # e.g. ConsoleWindowClass or GhosttyWindow
  [int]$X = 100, [int]$Y = 100, [int]$W = 1000, [int]$H = 600
)

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public class BS {
  // CharSet.Unicode: the DllImport default is Ansi, which marshals
  // string/StringBuilder as ANSI against these W-suffixed APIs —
  // class-name matching then never succeeds.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  public static IntPtr Found = IntPtr.Zero;
  public static string TargetClass = "";
  public static uint TargetPid = 0;
  public static bool Cb(IntPtr h, IntPtr lp) {
    if (!IsWindowVisible(h)) return true;
    var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
    if (sb.ToString() != TargetClass) return true;
    if (TargetPid != 0) { uint pid; GetWindowThreadProcessId(h, out pid); if (pid != TargetPid) return true; }
    Found = h; return false;
  }
  public static IntPtr FindByClass(string cls, uint pid) {
    Found = IntPtr.Zero; TargetClass = cls; TargetPid = pid;
    EnumWindows(Cb, IntPtr.Zero); return Found;
  }
}
'@ -ErrorAction SilentlyContinue
[BS]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

$proc = Start-Process -FilePath $Exe -PassThru
$hwnd = [IntPtr]::Zero
foreach ($try in 1..40) {
  Start-Sleep -Milliseconds 250
  $hwnd = [BS]::FindByClass($WindowClass, 0)
  if ($hwnd -ne [IntPtr]::Zero) { break }
}
if ($hwnd -eq [IntPtr]::Zero) { "FAIL: window not found"; exit 1 }
[BS]::MoveWindow($hwnd, $X, $Y, $W, $H, $true) | Out-Null
Start-Sleep -Milliseconds 500
"HWND=$hwnd PID=$($proc.Id)"
