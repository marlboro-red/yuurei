# Runs only while checking, downloading, or installing an update. Windows
# PowerShell 5.1 is included with Windows; no service or scheduled task is used.
param([Parameter(Mandatory=$true)][string]$Request)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-JsonAtomic($Path, $Value) {
    $tmp = $Path + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $Path) }
}
function Read-Json($Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
function Get-Sha256([string]$Path) {
    # Do not depend on Get-FileHash's script module: a terminal launched from
    # PowerShell 7 can inherit a PSModulePath incompatible with Windows PS 5.1.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Get-ReleaseVersion([string]$Tag) {
    if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Invalid release version.' }
    return [version]$Tag.Substring(1)
}
function Assert-PlainPath([string]$Path) {
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if ([IO.File]::Exists($item) -or [IO.Directory]::Exists($item)) {
            if (([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Update paths cannot contain links or junctions.' }
        }
        $item = [IO.Path]::GetDirectoryName($item)
    }
}
function Remove-Transaction([string]$Root, [string]$Directory) {
    $expected = [IO.Path]::GetFullPath((Join-Path $Root '.yuurei-update'))
    $full = [IO.Path]::GetFullPath($Directory)
    if ($full -ine $expected -and !$full.StartsWith($expected + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid transaction cleanup path.' }
    Assert-PlainPath $full
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($full)) {
        Assert-PlainPath $entry
        if ([IO.Directory]::Exists($entry)) { Remove-Transaction $Root $entry }
        else { [IO.File]::Delete($entry) }
    }
    [IO.Directory]::Delete($full)
}
function Get-Within([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.Contains('\') -or
        $Relative -match '(^|/)\.\.?(/|$)' -or $Relative -match '[\x00-\x1f]') { throw 'Unsafe package path.' }
    foreach ($part in $Relative.Split('/')) {
        if ($part -and ($part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '[<>"|?*]' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)')) { throw 'Unsafe Windows filename.' }
    }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escapes its root.' }
    Assert-PlainPath $full
    return $full
}
function Get-Remote([string]$Url, [long]$Limit, [string]$Destination = '') {
    # Follow only HTTPS redirects to GitHub's release delivery hosts. Never
    # disable certificate validation or forward credentials to these requests.
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('yuurei-updater')
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
    try {
        for ($redirect = 0; $redirect -lt 6; $redirect++) {
            $uri = [uri]$Url
            if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
                $uri.Host -notin @('api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')) { throw 'Unexpected download URL.' }
            $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                    $Url = [uri]::new($uri, $response.Headers.Location).AbsoluteUri
                    continue
                }
                [void]$response.EnsureSuccessStatusCode()
                if ($response.Content.Headers.ContentLength -gt $Limit) { throw 'Download exceeds size limit.' }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $output = if ($Destination) { [IO.File]::Create($Destination) } else { [IO.MemoryStream]::new() }
                try {
                    $buffer = New-Object byte[] 65536
                    [long]$total = 0
                    while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total += $read
                        if ($total -gt $Limit) { throw 'Download exceeds size limit.' }
                        $output.Write($buffer, 0, $read)
                    }
                    if (!$Destination) { return [Text.Encoding]::UTF8.GetString($output.ToArray()) }
                    return
                } finally { $output.Dispose(); $inputStream.Dispose() }
            } finally { $response.Dispose() }
        }
        throw 'Too many download redirects.'
    } finally { $cancel.Dispose(); $client.Dispose(); $handler.Dispose() }
}
function Get-PackageFiles([string]$Zip, [string]$Tag, [string]$Destination = '') {
    [void](Get-ReleaseVersion $Tag)
    $prefix = "yuurei-$Tag-windows-x64/"
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = [Collections.Generic.List[string]]::new()
        [long]$expanded = 0
        if ($archive.Entries.Count -gt 20000) { throw 'Too many package entries.' }
        foreach ($entry in $archive.Entries) {
            # Compress-Archive on Windows emits backslash separators.
            $name = $entry.FullName.Replace('\','/')
            if (!$name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Unexpected package root.' }
            $relative = $name.Substring($prefix.Length)
            if (!$relative) { continue }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Package contains a symbolic link.' }
            if ($relative -cnotmatch '^(bin/|share/|LICENSE$|README\.md$|THIRD_PARTY_NOTICES\.md$)') { throw 'Unexpected package contents.' }
            $target = Get-Within $(if ($Destination) { $Destination } else { [IO.Path]::GetTempPath().TrimEnd('\') }) $relative
            if (!$names.Add($relative.TrimEnd('/'))) { throw 'Duplicate package path.' }
            $expanded += $entry.Length
            if ($expanded -gt 536870912) { throw 'Expanded package exceeds size limit.' }
            if ($name.EndsWith('/')) { continue }
            $files.Add($relative)
            if ($Destination) {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
        foreach ($required in @('bin/ghostty.exe','bin/conpty.dll','bin/OpenConsole.exe','bin/yuurei-defterm-proxy.dll','LICENSE','README.md','THIRD_PARTY_NOTICES.md')) {
            if (!$files.Contains($required)) { throw "Package is missing $required." }
        }
        if (!($files | Where-Object { $_.StartsWith('share/') })) { throw 'Package has no resources.' }
        return $files.ToArray()
    } finally { $archive.Dispose() }
}
function Assert-Pending($Pending, [string]$Cache) {
    [void](Get-ReleaseVersion $Pending.tag)
    if ($Pending.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid update checksum.' }
    $zip = Get-Within $Cache ($Pending.tag + '.zip')
    if ([IO.FileInfo]::new($zip).Length -gt 268435456) { throw 'Cached update exceeds size limit.' }
    if ((Get-Sha256 $zip) -cne $Pending.sha256) { throw 'Update checksum mismatch.' }
    return $zip
}
function Test-Running([string]$Executable) {
    $canonical = [IO.Path]::GetFullPath($Executable)
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('ghostty')) {
        try {
            # Windows PowerShell's full-path normalization expands existing
            # DOS 8.3 aliases. Compare both sides in the same representation.
            if ([IO.Path]::GetFullPath($process.MainModule.FileName) -ieq $canonical) { return $true }
        } catch {
            # Unknown/inaccessible instances are conservatively treated as busy.
            if (!$process.HasExited) { return $true }
        } finally { $process.Dispose() }
    }
    return $false
}
function Undo-Transaction([string]$Root, [string]$Transaction) {
    $journalPath = Join-Path $Transaction 'journal.json'
    if (![IO.File]::Exists($journalPath)) { return }
    $journal = Read-Json $journalPath
    if ($journal.complete) { return }
    foreach ($entry in @($journal.files) | Sort-Object { $_.relative -eq 'bin/ghostty.exe' }) {
        $target = Get-Within $Root $entry.relative
        $backup = Get-Within (Join-Path $Transaction 'backup') $entry.relative
        if ($entry.existed) {
            if ([IO.File]::Exists($backup)) {
                if ([IO.File]::Exists($target) -and
                    (Get-Sha256 $backup) -eq (Get-Sha256 $target)) { continue }
                $restore = $target + '.yuurei-restore'
                Assert-PlainPath $restore
                [IO.File]::Copy($backup, $restore, $true)
                if ([IO.File]::Exists($target)) { [IO.File]::Replace($restore, $target, [NullString]::Value) }
                else { [IO.File]::Move($restore, $target) }
            }
        } elseif ([IO.File]::Exists($target)) {
            # Only remove a newly-created file if it still matches this update.
            if ((Get-Sha256 $target) -ieq $entry.sha256) { [IO.File]::Delete($target) }
        }
    }
    $journal.complete = $true
    Write-JsonAtomic $journalPath $journal
}
function Install-Package($Pending, [string]$Cache, [string]$Root) {
    $exe = Join-Path $Root 'bin/ghostty.exe'
    if (Test-Running $exe) { return $false }
    Assert-PlainPath $Root
    # Cross-process/session lock, including users with different cache roots.
    $lock = [IO.File]::Open((Join-Path $Root '.yuurei-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        if (Test-Running $exe) { return $false }
        $transaction = Join-Path $Root '.yuurei-update'
        Assert-PlainPath $transaction
        if ([IO.Directory]::Exists($transaction)) {
            Undo-Transaction $Root $transaction
            # This exact, validated updater-owned directory is the only tree removed.
            Remove-Transaction $Root $transaction
        }
        $zip = Assert-Pending $Pending $Cache
        $version = Get-ReleaseVersion $Pending.tag
        if ([version]([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion) -ge $version) { return $true }
        $stage = Join-Path $transaction 'stage'
        [void][IO.Directory]::CreateDirectory($stage)
        $files = @(Get-PackageFiles $zip $Pending.tag $stage)
        if ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage 'bin/ghostty.exe')).ProductVersion -ne $version.ToString()) { throw 'Package version does not match its release.' }
        $journal = @{ complete = $false; files = @() }
        foreach ($relative in $files) {
            $target = Get-Within $Root $relative
            $source = Get-Within $stage $relative
            $exists = [IO.File]::Exists($target)
            if ($exists) {
                $backup = Get-Within (Join-Path $transaction 'backup') $relative
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))
                [IO.File]::Copy($target, $backup, $false)
            }
            $journal.files += @{ relative = $relative; existed = $exists; sha256 = (Get-Sha256 $source) }
        }
        Write-JsonAtomic (Join-Path $transaction 'journal.json') $journal
        try {
            foreach ($entry in $journal.files | Sort-Object { $_.relative -eq 'bin/ghostty.exe' }) {
                if ($entry.relative.StartsWith('bin/') -and (Test-Running $exe)) { throw 'Yuurei started during installation. Update postponed.' }
                $target = Get-Within $Root $entry.relative
                $source = Get-Within $stage $entry.relative
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                if ($entry.existed) { [IO.File]::Replace($source, $target, [NullString]::Value) }
                else { [IO.File]::Move($source, $target) }
            }
            $journal.complete = $true
            Write-JsonAtomic (Join-Path $transaction 'journal.json') $journal
        } catch {
            Undo-Transaction $Root $transaction
            throw
        }
        # Keep the previous files until the next update, allowing recovery and
        # avoiding recursive cleanup on the successful installation path.
        return $true
    } finally { $lock.Dispose() }
}
function Invoke-Update($Job) {
    $root = [IO.Path]::GetFullPath($Job.root)
    $cache = [IO.Path]::GetFullPath($Job.cache)
    Assert-PlainPath $root
    Assert-PlainPath $cache
    $current = Get-ReleaseVersion $Job.current
    $pendingPath = Join-Path $cache 'pending.json'
    if ($Job.mode -eq 'install') {
        # Waiting before taking the lock lets the last closing host perform
        # installation even when several hosts exit at the same time.
        $parent = $null
        try { $parent = [Diagnostics.Process]::GetProcessById($Job.parent) } catch [ArgumentException] {}
        if ($parent) {
            try { if (!$parent.WaitForExit(120000)) { return @{state='ready'; message='Update postponed: Yuurei is still running.'} } }
            finally { $parent.Dispose() }
        }
    }
    $lock = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try { $lock = [IO.File]::Open((Join-Path $cache 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch [IO.IOException] {
            if ($Job.mode -ne 'install') { return @{state='idle'; message='Another Yuurei instance is checking for updates.'} }
            Start-Sleep -Milliseconds 500
        }
    }
    if (!$lock) { throw 'Another update operation is still running.' }
    try {
        if ($Job.mode -eq 'install') {
            # Wait for this host to finish normal shell/session teardown. Never
            # terminate it or any other Yuurei process to perform an update.
            if (![IO.File]::Exists($pendingPath)) { return @{state='idle'; message='No pending update.'} }
            $pending = Read-Json $pendingPath
            if ($Job.manual) {
                # Preserve explicit consent when another isolated host remains
                # open; that host can apply the update on its later exit.
                Write-JsonAtomic $pendingPath @{tag=$pending.tag;sha256=$pending.sha256;manual=$true}
            }
            if (Install-Package $pending $cache $root) {
                [IO.File]::Delete($pendingPath)
                [IO.File]::Delete((Get-Within $cache ($pending.tag + '.zip')))
                return @{state='idle'; message='Update installed.'}
            }
            return @{state='ready'; message='Update will install after all Yuurei instances close.'}
        }
        if ($Job.mode -notin @('check','download','automatic')) { throw 'Unknown update operation.' }
        if ([IO.File]::Exists($pendingPath)) {
            $pending = Read-Json $pendingPath
            if ((Get-ReleaseVersion $pending.tag) -gt $current) {
                [void](Assert-Pending $pending $cache)
                $installResult = Join-Path $cache 'install-result.json'
                if ([IO.File]::Exists($installResult)) {
                    $lastInstall = Read-Json $installResult
                    if ($lastInstall.state -eq 'failed') { return @{state='ready'; message=($lastInstall.message + ' Will retry on exit.')} }
                }
                return @{state='ready'; message=($pending.tag + ' ready. Installs after all Yuurei instances close.')}
            }
        }
        $stamp = Join-Path $cache 'last-check'
        if ($Job.mode -eq 'automatic' -and [IO.File]::Exists($stamp) -and
            ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($stamp)).TotalHours -lt 24) {
            return @{state='idle'; message='Automatic update checks are enabled.'}
        }
        # Record attempts too, so network failures do not cause a request storm.
        [IO.File]::WriteAllText($stamp, '')
        $release = (Get-Remote 'https://api.github.com/repos/marlboro-red/yuurei/releases/latest' 1048576) | ConvertFrom-Json
        if ($release.draft -or $release.prerelease) { throw 'Expected a stable published release.' }
        $version = Get-ReleaseVersion $release.tag_name
        if ($version -le $current) { return @{state='idle'; message='Yuurei is up to date.'} }
        if ($Job.mode -eq 'check') { return @{state='available'; message=($release.tag_name + ' is available.')} }
        $name = 'yuurei-' + $release.tag_name + '-windows-x64.zip'
        $base = 'https://github.com/marlboro-red/yuurei/releases/download/' + $release.tag_name + '/'
        $assets = @($release.assets | Where-Object { $_.name -ceq $name -and $_.browser_download_url -ceq ($base + $name) -and $_.state -eq 'uploaded' })
        $checksums = @($release.assets | Where-Object { $_.name -ceq ($name + '.sha256') -and $_.browser_download_url -ceq ($base + $name + '.sha256') -and $_.state -eq 'uploaded' })
        if ($assets.Count -ne 1 -or $checksums.Count -ne 1 -or $assets[0].size -gt 268435456) { throw 'Release package is incomplete.' }
        $checksum = (Get-Remote ($base + $name + '.sha256') 1024).Trim()
        if ($checksum -cnotmatch ('^([a-f0-9]{64})  ' + [regex]::Escape($name) + '$')) { throw 'Invalid published checksum.' }
        $hash = $Matches[1]
        $zip = Join-Path $cache ($release.tag_name + '.zip')
        Assert-PlainPath $zip
        $partial = $zip + '.partial'
        Assert-PlainPath $partial
        try {
            Get-Remote ($base + $name) 268435456 $partial
            if ((Get-Sha256 $partial) -cne $hash) { throw 'Downloaded update checksum mismatch.' }
            [void](Get-PackageFiles $partial $release.tag_name)
            if ([IO.File]::Exists($zip)) { [IO.File]::Replace($partial, $zip, [NullString]::Value) }
            else { [IO.File]::Move($partial, $zip) }
        } finally { if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) } }
        Write-JsonAtomic $pendingPath @{tag=$release.tag_name; sha256=$hash; manual=($Job.mode -eq 'download')}
        $installResult = Join-Path $cache 'install-result.json'
        if ([IO.File]::Exists($installResult)) { [IO.File]::Delete($installResult) }
        return @{state='ready'; message=($release.tag_name + ' ready. Installs after all Yuurei instances close.')}
    } finally { $lock.Dispose() }
}

# Dot-sourcing allows offline transaction tests to exercise the production
# functions without introducing a test URL or trust bypass into the updater.
if ($MyInvocation.InvocationName -ne '.') {
    $job = Read-Json $Request
    try { $result = Invoke-Update $job }
    catch { $result = @{state='failed'; message=('Update failed: ' + $_.Exception.Message)} }
    if ($job.mode -eq 'install') { Write-JsonAtomic (Join-Path $job.cache 'install-result.json') $result }
    Write-JsonAtomic (Join-Path ([IO.Path]::GetDirectoryName($Request)) 'result.json') $result
    if ($job.mode -eq 'install') {
        $directory = [IO.Path]::GetDirectoryName($Request)
        $cachePrefix = [IO.Path]::GetFullPath($job.cache).TrimEnd('\') + '\'
        if ($directory.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($directory) -match '^job-[0-9]+$') {
            Assert-PlainPath $directory
            foreach ($name in @('request.json','result.json','update-helper.ps1')) { [IO.File]::Delete((Join-Path $directory $name)) }
            [IO.Directory]::Delete($directory)
        }
    }
}
