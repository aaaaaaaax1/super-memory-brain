param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryPath = Join-Path (Get-SuperBrainActiveMemoryRoot $Root) 'sandglass.txt'
if (-not (Test-Path $memoryPath)) { throw "Missing memory file: $memoryPath" }

$lines = @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
$seen = @{}
$duplicates = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  $line = $lines[$i]
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $key = $line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| ', ''
  if ($seen.ContainsKey($key)) {
    $duplicates += [pscustomobject]@{ line = $i + 1; firstLine = $seen[$key]; text = $key }
  } else {
    $seen[$key] = $i + 1
  }
}

$report = [pscustomobject]@{
  memory = $memoryPath
  totalLines = $lines.Count
  duplicateCount = $duplicates.Count
  duplicates = $duplicates
}

if ($Json) {
  $report | ConvertTo-Json -Depth 5
} else {
  Write-Host "COMPACT_REPORT memory=$memoryPath totalLines=$($report.totalLines) duplicateCount=$($report.duplicateCount)"
  foreach ($d in $duplicates | Select-Object -First 20) {
    Write-Host "DUP line=$($d.line) firstLine=$($d.firstLine) text=$($d.text)"
  }
  if ($duplicates.Count -gt 20) { Write-Host "DUP_MORE count=$($duplicates.Count - 20)" }
}

exit 0
