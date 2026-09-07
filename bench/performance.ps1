#requires -Version 7.0
# Generate deterministic corpora separately, then compare ReleaseFast binaries.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$DataDirectory,
  [switch]$Generate,
  [ValidateRange(1, 10000000)][int]$Lines = 200000,
  [string]$Candidate,
  [string]$Baseline,
  [ValidateRange(3, 1000)][int]$Runs = 9,
  [ValidateRange(0, 20)][int]$Warmups = 2,
  [switch]$ChunkSizes,
  [string]$OutputJson
)
$ErrorActionPreference = 'Stop'
if ($Generate) {
  [void][IO.Directory]::CreateDirectory($DataDirectory)
  $esc = [char]27
  $patterns = [ordered]@{
    ascii = 'The quick brown fox 0123456789 build output repeated for scrollback'
    color = "${esc}[31merror${esc}[0m ${esc}[1;32mbuild output${esc}[0m 0123456789"
    unicode = '日本語 Ελληνικά Кириллица العربية 👻 🚀 combining: é'
  }
  foreach ($kind in $patterns.Keys) {
    $path = Join-Path $DataDirectory ($kind + '.vt')
    if (Test-Path -LiteralPath $path) { throw "Corpus already exists: $path" }
    $writer = [IO.StreamWriter]::new($path, $false, [Text.UTF8Encoding]::new($false), 65536)
    try {
      for ($i = 0; $i -lt $Lines; $i++) {
        $writer.Write($i.ToString('D8', [Globalization.CultureInfo]::InvariantCulture))
        $writer.Write(' ')
        $writer.Write($patterns[$kind])
        $writer.Write("`r`n")
      }
    } finally { $writer.Dispose() }
    Get-FileHash -LiteralPath $path -Algorithm SHA256
  }
  return
}
if (-not $Candidate) { throw 'Specify -Candidate or -Generate.' }
$binaries = [ordered]@{}
if ($Baseline) { $binaries.baseline = (Resolve-Path -LiteralPath $Baseline).Path }
$binaries.candidate = (Resolve-Path -LiteralPath $Candidate).Path
$results = [Collections.Generic.List[object]]::new()
foreach ($corpus in 'ascii', 'color', 'unicode') {
  $data = (Resolve-Path -LiteralPath (Join-Path $DataDirectory ($corpus + '.vt'))).Path
  $cases = @(
    @{ name = 'stream'; args = @('+terminal-stream') },
    @{ name = 'compression-noop'; args = @('+scrollback-compression', '--mode=noop', '--max-scrollback=100000000') },
    @{ name = 'compression-incremental'; args = @('+scrollback-compression', '--mode=incremental', '--max-scrollback=100000000') }
  )
  if ($ChunkSizes) {
    $cases = @(1024, 4096, 16384, 65536 | ForEach-Object {
      @{ name = "stream-$_"; args = @('+terminal-stream', "--chunk-size=$_") }
    })
  }
  foreach ($case in $cases) {
    $samples = @{}
    foreach ($label in $binaries.Keys) { $samples[$label] = [Collections.Generic.List[double]]::new() }
    for ($i = -$Warmups; $i -lt $Runs; $i++) {
      # Alternate order to reduce systematic temperature/order bias. Never run
      # benchmark processes concurrently, or while a build is still running.
      $order = @($binaries.Keys)
      if ($i % 2) { [array]::Reverse($order) }
      foreach ($label in $order) {
        $argsForRun = @($case.args) + @("--data=$data", '--terminal-cols=120', '--terminal-rows=80')
        $watch = [Diagnostics.Stopwatch]::StartNew()
        & $binaries[$label] @argsForRun 2>$null | Out-Null
        $exit = $LASTEXITCODE
        $watch.Stop()
        if ($exit -ne 0) { throw "$label / $($case.name) exited $exit" }
        if ($i -ge 0) { $samples[$label].Add($watch.Elapsed.TotalMilliseconds) }
      }
    }
    foreach ($label in $binaries.Keys) {
      $sorted = @($samples[$label] | Sort-Object)
      $middle = [int][math]::Floor($sorted.Count / 2)
      $median = if ($sorted.Count % 2) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
      $row = [pscustomobject]@{ binary = $label; corpus = $corpus; case = $case.name; median_ms = $median; samples_ms = @($samples[$label]); sha256 = (Get-FileHash -LiteralPath $data).Hash }
      $results.Add($row)
      Write-Host "$label $corpus $($case.name): $([math]::Round($median, 2)) ms"
    }
  }
}
if ($OutputJson) {
  $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputJson -Encoding utf8
} else { $results }
