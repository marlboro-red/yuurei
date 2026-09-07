# Exercise the capture comparator without focusing windows or injecting input.
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'photon-bench.ps1') -Raw
$match = [regex]::Match($source, "(?s)Add-Type @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Capture comparator source not found.' }
Add-Type -TypeDefinition $match.Groups[1].Value -ReferencedAssemblies System.Drawing
$a = [Drawing.Bitmap]::new(8, 8)
$b = [Drawing.Bitmap]::new(8, 8)
try {
  if ([PB]::Differs($a, $b, 0, 0, 0, 0, 1)) { throw 'Identical frames differ.' }
  $b.SetPixel(2, 3, [Drawing.Color]::White)
  if (-not [PB]::Differs($a, $b, 0, 0, 0, 0, 1)) { throw 'Missed a changed pixel.' }
  if ([PB]::Differs($a, $b, 2, 3, 1, 1, 1)) { throw 'Ignored cursor region counted.' }
  if ([PB]::Differs($a, $b, 0, 0, 0, 0, 2)) { throw 'Pixel threshold not respected.' }
  $b.SetPixel(4, 5, [Drawing.Color]::Red)
  if (-not [PB]::Differs($a, $b, 0, 0, 0, 0, 2)) { throw 'Missed second pixel.' }
  'Photon comparator tests passed.'
} finally { $a.Dispose(); $b.Dispose() }
