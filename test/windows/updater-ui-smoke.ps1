param(
    [Parameter(Mandatory=$true)][string]$PackageZip,
    [string]$Executable = "$PSScriptRoot/../../zig-out/bin/ghostty.exe"
)
# Requires a build reporting a stable yuurei release tag. The test copies it
# into a disposable portable package and never updates the supplied executable.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UpdateUi {
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f,IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
 public static IntPtr Find(int pid,string cls) {
  IntPtr result=IntPtr.Zero;
  EnumWindows((h,p)=>{uint owner;GetWindowThreadProcessId(h,out owner);var b=new StringBuilder(100);GetClassName(h,b,100);if(owner==pid&&b.ToString()==cls){result=h;return false;}return true;},IntPtr.Zero);
  return result;
 }
}
'@
[void][UpdateUi]::SetThreadDpiAwarenessContext(-4)
function Assert($Value,[string]$Message) { if (!$Value) { throw $Message } }
function Wait-For([scriptblock]$Condition,[string]$Message,[int]$Seconds=30) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    throw $Message
}
function Button-Text($Handle) {
    $text=[Text.StringBuilder]::new(200)
    [void][UpdateUi]::GetWindowText($Handle,$text,$text.Capacity)
    return $text.ToString()
}
$isolation=Join-Path $env:TEMP ('yuurei-updater-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($isolation)
Expand-Archive -LiteralPath $PackageZip -DestinationPath $isolation
$package=Get-ChildItem -LiteralPath $isolation -Directory | Select-Object -First 1
$testExe=Join-Path $package.FullName 'bin/ghostty.exe'
Copy-Item -LiteralPath $Executable -Destination $testExe -Force
$broker = Join-Path (Split-Path $Executable) 'yuurei-mux.exe'
if (Test-Path -LiteralPath $broker) { Copy-Item -LiteralPath $broker -Destination (Join-Path $package.FullName 'bin/yuurei-mux.exe') -Force }
$configRoot=Join-Path $isolation 'config'
[void][IO.Directory]::CreateDirectory((Join-Path $configRoot 'ghostty'))
$config=Join-Path $configRoot 'ghostty/config'
[IO.File]::WriteAllText($config,"command = cmd.exe`nkeybind = f12=open_config`nwindows-auto-update = true`nwindows-restore-session = false`nconfirm-close-surface = false`nwindow-theme = dark`n")
$app=Start-Process -FilePath $testExe -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$configRoot;LOCALAPPDATA=$configRoot;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError (Join-Path $isolation 'stderr.log')
$other = $null
try {
    Wait-For { [UpdateUi]::Find($app.Id,'ghostty') -ne 0 } 'Terminal did not appear.'
    $terminal=[UpdateUi]::Find($app.Id,'ghostty')
    [void][UpdateUi]::PostMessageW($terminal,0x100,0x7B,0)
    Wait-For { [UpdateUi]::Find($app.Id,'ghostty-settings') -ne 0 } 'Settings did not appear.'
    $settings=[UpdateUi]::Find($app.Id,'ghostty-settings')
    [void][UpdateUi]::SendMessageW([UpdateUi]::GetDlgItem($settings,24),0xF5,0,0)
    $button=[UpdateUi]::GetDlgItem($settings,16)
    Assert ([UpdateUi]::IsWindowVisible($button)) 'Update button is hidden.'
    Assert ([UpdateUi]::IsWindowEnabled($button)) 'Update button is disabled; use a release-tagged, unelevated build.'
    # Allow the startup timer to perform the automatic check; no click starts it.
    Wait-For { (Get-ChildItem -LiteralPath $configRoot -Recurse -Filter result.json).Count -gt 0 } 'Updater did not report a result.' 100
    Wait-For { (Button-Text $button) -eq 'Check for updates' } 'Updater did not finish checking.'
    $resultFile=Get-ChildItem -LiteralPath $configRoot -Recurse -Filter result.json | Select-Object -First 1
    $result=[IO.File]::ReadAllText($resultFile.FullName) | ConvertFrom-Json
    Assert ($result.state -eq 'idle' -and $result.message -eq 'Yuurei is up to date.') "Unexpected check result: $($result.message)"
    $autoUpdate = @(100..140 | ForEach-Object { [UpdateUi]::GetDlgItem($settings,$_) } | Where-Object { $_ -ne 0 -and (Button-Text $_) -eq 'Automatic updates' })
    Assert ($autoUpdate.Count -eq 1) 'Automatic update toggle missing.'
    [void][UpdateUi]::SendMessageW($autoUpdate[0],0xF5,0,0)
    [void][UpdateUi]::SendMessageW([UpdateUi]::GetDlgItem($settings,11),0xF5,0,0)
    Assert ([IO.File]::ReadAllText($config).Contains('windows-auto-update = false')) 'Automatic update toggle did not save.'
    $cache=$resultFile.Directory.Parent.FullName
    $rect=New-Object UpdateUi+Rect
    [void][UpdateUi]::GetWindowRect($settings,[ref]$rect)
    $bitmap=[Drawing.Bitmap]::new($rect.right-$rect.left,$rect.bottom-$rect.top)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $dc=$graphics.GetHdc()
    try { [void][UpdateUi]::PrintWindow($settings,$dc,2) }
    finally { $graphics.ReleaseHdc($dc);$graphics.Dispose() }
    try { $bitmap.Save((Join-Path $isolation 'updates.png')) } finally { $bitmap.Dispose() }

    # Seed a locally-built future fixture into this test installation's private
    # cache. No production URL, checksum bypass, or test hook is added to Yuurei.
    $fixture=Join-Path $isolation 'yuurei-v99.0.0-windows-x64'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'bin'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'share'))
    $fixtureScript=Join-Path $isolation 'fixture.ps1'
    @'
param([string]$Exe)
Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("99.0.0")] [assembly: AssemblyInformationalVersion("99.0.0")] public class UpdatedFixture { public static void Main() {} }' -OutputAssembly $Exe -OutputType WindowsApplication
'@ | Set-Content -LiteralPath $fixtureScript
    $fixtureExe=Join-Path $fixture 'bin/ghostty.exe'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -Exe $fixtureExe
    Assert ($LASTEXITCODE -eq 0) 'Fixture compilation failed.'
    foreach ($relative in @('bin/conpty.dll','bin/OpenConsole.exe','bin/yuurei-defterm-proxy.dll','share/test-resource','LICENSE','README.md','THIRD_PARTY_NOTICES.md')) {
        [IO.File]::WriteAllText((Join-Path $fixture $relative),'updater fixture')
    }
    $zip=Join-Path $cache 'v99.0.0.zip'
    Compress-Archive -LiteralPath $fixture -DestinationPath $zip
    @{tag='v99.0.0';sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cache 'pending.json')
    [void][UpdateUi]::SendMessageW($button,0xF5,0,0)
    Wait-For { (Button-Text $button) -eq 'Install on exit' } 'Cached update not offered.'
    Assert (!$app.HasExited) 'Update interrupted the running terminal.'
    [void][UpdateUi]::SendMessageW($button,0xF5,0,0)
    Assert ((Button-Text $button) -eq 'Update ready') 'Install-on-exit action failed.'
    $other=Start-Process -FilePath $testExe -WindowStyle Hidden -PassThru -Environment @{XDG_CONFIG_HOME=$configRoot;LOCALAPPDATA=$configRoot;GHOSTTY_NEW_INSTANCE='1'} -RedirectStandardError (Join-Path $isolation 'other-stderr.log')
    Wait-For { [UpdateUi]::Find($other.Id,'ghostty') -ne 0 } 'Isolated second instance did not appear.'
    $configBefore=[IO.File]::ReadAllText($config)
    [void][UpdateUi]::PostMessageW($settings,0x10,0,0)
    [void][UpdateUi]::PostMessageW($terminal,0x10,0,0)
    Assert ($app.WaitForExit(10000)) 'Terminal did not exit normally.'
    Wait-For { [IO.File]::Exists((Join-Path $cache 'install-result.json')) } 'Installer did not report completion.' 60
    $deferred=[IO.File]::ReadAllText((Join-Path $cache 'install-result.json')) | ConvertFrom-Json
    Assert ($deferred.state -eq 'ready') 'Update was not deferred for the other isolated instance.'
    Assert (!$other.HasExited) 'Update closed another instance.'
    # This instance never checked or downloaded and has automatic updates off.
    # It must still honor the earlier explicit install choice on its final exit.
    [void][UpdateUi]::PostMessageW([UpdateUi]::Find($other.Id,'ghostty'),0x10,0,0)
    Assert ($other.WaitForExit(10000)) 'Second instance did not exit normally.'
    Wait-For { ([IO.File]::ReadAllText((Join-Path $cache 'install-result.json')) | ConvertFrom-Json).message -eq 'Update installed.' } 'Last isolated instance did not apply the pending update.' 60
    $installed=[IO.File]::ReadAllText((Join-Path $cache 'install-result.json')) | ConvertFrom-Json
    Assert ($installed.message -eq 'Update installed.') "Installation failed: $($installed.message)"
    Assert ([Diagnostics.FileVersionInfo]::GetVersionInfo($testExe).ProductVersion -eq '99.0.0') 'Installed executable has wrong version.'
    Assert ([IO.File]::ReadAllText($config) -ceq $configBefore) 'Update modified user configuration.'
    Assert (![IO.File]::Exists((Join-Path $cache 'pending.json'))) 'Pending update was not cleared.'
    Write-Output "Updater UI smoke passed. Artifacts: $isolation"
} finally {
    if (!$app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
    $app.Dispose()
    if ($other) {
        if (!$other.HasExited) { Stop-Process -Id $other.Id -ErrorAction SilentlyContinue }
        $other.Dispose()
    }
}
