# Run using Windows PowerShell 5.1, the runtime used by the updater.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../src/apprt/win32/update-helper.ps1" -Request unused
$testRoot = Join-Path $env:TEMP ('yuurei-updater-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
function Wait-Running($Process, [string]$Executable) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (!(Test-Running $Executable)) {
        if ($Process.HasExited) { throw "Fixture exited before becoming observable: $($Process.ExitCode)" }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Fixture process did not become observable.' }
        Start-Sleep -Milliseconds 50
    }
}
function Make-Archive([string]$Path, $Entries) {
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($pair in $Entries) {
            $entry = $zip.CreateEntry($pair[0])
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes($pair[1])
                $stream.Write($bytes,0,$bytes.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
function Make-Installation([string]$Name) {
    $root = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'bin'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'share'))
    [IO.File]::Copy($script:oldExe, (Join-Path $root 'bin/ghostty.exe'))
    foreach ($file in @('bin/conpty.dll','bin/OpenConsole.exe','bin/yuurei-defterm-proxy.dll','share/theme','LICENSE','README.md','THIRD_PARTY_NOTICES.md','user-custom-file')) {
        [IO.File]::WriteAllText((Join-Path $root $file), 'original')
    }
    return $root
}

Assert ((Get-ReleaseVersion 'v0.2.17') -gt (Get-ReleaseVersion 'v0.2.9')) 'Version ordering is lexical.'
foreach ($tag in @('v0.2.17-beta','v01.2.3','../../x','v1.2','1.2.3')) { Reject { Get-ReleaseVersion $tag } "Accepted $tag" }
foreach ($relative in @('../escape','bin/../../escape','C:/escape','bin/a:stream','bin/CON','bin/name.','bin/name ','bin\escape','bin/a?b')) {
    Reject { Get-Within $testRoot $relative } "Accepted unsafe path $relative"
}
$outside = Join-Path $testRoot 'outside'
$linkedRoot = Join-Path $testRoot 'linked'
[void][IO.Directory]::CreateDirectory($outside)
[void][IO.Directory]::CreateDirectory($linkedRoot)
New-Item -ItemType Junction -Path (Join-Path $linkedRoot 'bin') -Target $outside | Out-Null
Reject { Get-Within $linkedRoot 'bin/escape' } 'Accepted a junction in the installation path.'
$badZip = Join-Path $testRoot 'traversal.zip'
Make-Archive $badZip @(@('yuurei-v0.2.17-windows-x64/bin/../../escape','bad'))
Reject { Get-PackageFiles $badZip 'v0.2.17' } 'Accepted zip traversal.'
$duplicateZip = Join-Path $testRoot 'duplicate.zip'
Make-Archive $duplicateZip @(@('yuurei-v0.2.17-windows-x64/bin/a','one'),@('yuurei-v0.2.17-windows-x64/bin/A','two'))
Reject { Get-PackageFiles $duplicateZip 'v0.2.17' } 'Accepted case-insensitive duplicate.'

$oldExe = Join-Path $testRoot 'old.exe'
Add-Type -TypeDefinition @'
using System.Reflection;
[assembly: AssemblyFileVersion("0.2.16")]
[assembly: AssemblyInformationalVersion("0.2.16")]
public class UpdateFixture { public static void Main() { System.Threading.Thread.Sleep(60000); } }
'@ -OutputAssembly $oldExe -OutputType WindowsApplication
$newExe = Join-Path $testRoot 'new.exe'
Add-Type -TypeDefinition @'
using System.Reflection;
[assembly: AssemblyFileVersion("0.2.17")]
[assembly: AssemblyInformationalVersion("0.2.17")]
public class NewUpdateFixture { public static void Main() {} }
'@ -OutputAssembly $newExe -OutputType WindowsApplication
$package = Join-Path $testRoot 'yuurei-v0.2.17-windows-x64'
[void][IO.Directory]::CreateDirectory((Join-Path $package 'bin'))
[void][IO.Directory]::CreateDirectory((Join-Path $package 'share'))
[IO.File]::Copy($newExe, (Join-Path $package 'bin/ghostty.exe'))
foreach ($file in @('bin/conpty.dll','bin/OpenConsole.exe','bin/yuurei-defterm-proxy.dll','share/theme','LICENSE','README.md','THIRD_PARTY_NOTICES.md')) {
    [IO.File]::WriteAllText((Join-Path $package $file), 'updated')
}
$cache = Join-Path $testRoot 'cache'
[void][IO.Directory]::CreateDirectory($cache)
$zip = Join-Path $cache 'v0.2.17.zip'
Compress-Archive -LiteralPath $package -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$pending = @{tag='v0.2.17'; sha256=$hash}
$files = @(Get-PackageFiles $zip 'v0.2.17')
Assert ($files.Count -eq 8) 'Unexpected extracted file count.'
Reject { Assert-Pending @{tag='v0.2.17';sha256=('0'*64)} $cache } 'Accepted checksum mismatch.'

$install = Make-Installation 'install space 日本語'
Assert (Install-Package $pending $cache $install) 'Installation failed.'
Assert ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install 'bin/ghostty.exe')).ProductVersion -eq '0.2.17') 'Executable version not updated.'
Assert ([IO.File]::ReadAllText((Join-Path $install 'share/theme')) -eq 'updated') 'Resources not updated.'
Assert ([IO.File]::ReadAllText((Join-Path $install 'user-custom-file')) -eq 'original') 'Custom file changed.'
Assert ([IO.File]::Exists((Join-Path $install '.yuurei-update/backup/bin/ghostty.exe'))) 'Backup missing.'
# Simulate loss of power after replacing the executable but before marking
# the transaction complete. Recovery must run even though the new version is
# already present, then preserve the original version in the next backup.
$journalPath = Join-Path $install '.yuurei-update/journal.json'
$interrupted = Read-Json $journalPath
$interrupted.complete = $false
Write-JsonAtomic $journalPath $interrupted
Assert (Install-Package $pending $cache $install) 'Interrupted transaction recovery failed.'
Assert ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install '.yuurei-update/backup/bin/ghostty.exe')).ProductVersion -eq '0.2.16') 'Recovery backed up a partially installed version.'
Assert (Install-Package $pending $cache $install) 'Repeat installation failed.'

$busy = Make-Installation 'busy'
$process = Start-Process -FilePath (Join-Path $busy 'bin/ghostty.exe') -WindowStyle Hidden -PassThru
try {
    Wait-Running $process (Join-Path $busy 'bin/ghostty.exe')
    Assert (Test-Running ([IO.Path]::GetFullPath((Join-Path $busy 'bin/ghostty.exe')))) 'Running-process detection depends on short versus long path spelling.'
    Assert (!(Install-Package $pending $cache $busy)) 'Updated a running instance.'
    Assert ([IO.File]::ReadAllText((Join-Path $busy 'share/theme')) -eq 'original') 'Busy installation changed.'
} finally { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue; $process.WaitForExit(); $process.Dispose() }

$rollback = Make-Installation 'rollback'
$locked = [IO.File]::Open((Join-Path $rollback 'share/theme'), 'Open', 'Read', 'Read')
try { Reject { Install-Package $pending $cache $rollback } 'Locked-file installation unexpectedly succeeded.' }
finally { $locked.Dispose() }
Undo-Transaction $rollback (Join-Path $rollback '.yuurei-update')
Assert ([IO.File]::ReadAllText((Join-Path $rollback 'bin/conpty.dll')) -eq 'original') 'Rollback did not restore a replaced file.'
Assert ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $rollback 'bin/ghostty.exe')).ProductVersion -eq '0.2.16') 'Rollback changed executable.'
Assert (Install-Package $pending $cache $rollback) 'Retry after rollback failed.'

# Exercise checking, download verification, throttling, and pending recovery
# without network access. Only the transport is replaced in this test process.
$script:httpCount = 0
$script:fixtureZip = $zip
$script:fixtureHash = $hash
function Get-Remote([string]$Url, [long]$Limit, [string]$Destination = '') {
    $script:httpCount++
    $name = 'yuurei-v0.2.17-windows-x64.zip'
    $base = 'https://github.com/marlboro-red/yuurei/releases/download/v0.2.17/'
    if ($Url.EndsWith('/latest')) {
        return (@{tag_name='v0.2.17';draft=$false;prerelease=$false;assets=@(
            @{name=$name;browser_download_url=($base+$name);state='uploaded';size=123},
            @{name=($name+'.sha256');browser_download_url=($base+$name+'.sha256');state='uploaded';size=120}
        )} | ConvertTo-Json -Depth 5)
    }
    if ($Url.EndsWith('.sha256')) { return "$script:fixtureHash  $name" }
    [IO.File]::Copy($script:fixtureZip, $Destination, $true)
}
$flowCache = Join-Path $testRoot 'flow'
[void][IO.Directory]::CreateDirectory($flowCache)
$job = @{root=$busy;cache=$flowCache;current='v0.2.16';mode='check';parent=2147483647;manual=$false}
Assert ((Invoke-Update $job).state -eq 'available') 'Manual check failed.'
$job.mode = 'automatic'
$before = $script:httpCount
Assert ((Invoke-Update $job).state -eq 'idle') 'Automatic throttle failed.'
Assert ($script:httpCount -eq $before) 'Throttled check used network.'
$job.mode = 'download'
$script:fixtureHash = '0'*64
Reject { Invoke-Update $job } 'Accepted a corrupted download.'
Assert (![IO.File]::Exists((Join-Path $flowCache 'pending.json'))) 'Corrupted download was scheduled.'
$script:fixtureHash = $hash
Assert ((Invoke-Update $job).state -eq 'ready') 'Download failed.'
Assert ([IO.File]::Exists((Join-Path $flowCache 'pending.json'))) 'Pending update missing.'
Assert ((Read-Json (Join-Path $flowCache 'pending.json')).manual) 'Manual download permission was not persisted.'
$before = $script:httpCount
Assert ((Invoke-Update $job).state -eq 'ready') 'Pending update not recovered.'
Assert ($script:httpCount -eq $before) 'Pending update used network.'
$job.mode = 'install'
$job.manual = $true
$process = Start-Process -FilePath (Join-Path $busy 'bin/ghostty.exe') -WindowStyle Hidden -PassThru
try {
    Wait-Running $process (Join-Path $busy 'bin/ghostty.exe')
    $deferredResult = Invoke-Update $job
    Assert ($deferredResult.state -eq 'ready') ("Installation did not defer for another host: " + ($deferredResult | ConvertTo-Json -Compress) + "; fixture exited=$($process.HasExited); root=$($job.root); pending=$([IO.File]::Exists((Join-Path $flowCache 'pending.json')))")
    Assert ((Read-Json (Join-Path $flowCache 'pending.json')).manual) 'Deferred install lost explicit permission.'
} finally { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue; $process.WaitForExit(); $process.Dispose() }
$job.manual = $false
Assert ((Invoke-Update $job).message -eq 'Update installed.') 'Deferred installation failed.'
Assert (![IO.File]::Exists((Join-Path $flowCache 'pending.json'))) 'Installed pending marker retained.'
Write-Output "Updater tests passed. Artifacts: $testRoot"
