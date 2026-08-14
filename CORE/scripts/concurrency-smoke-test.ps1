param(
  [int]$Workers = 8,
  [int]$TimeoutSeconds = 30,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$tmpRoot = Join-Path $workspace 'concurrency-smoke'
if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$jsonPath = Join-Path $tmpRoot 'shared.json'
$jsonWorkers = @()
for ($i = 1; $i -le $Workers; $i++) {
  $command = @"
. '$PSScriptRoot\common.ps1'
Write-JsonUtf8NoBom '$jsonPath' ([pscustomobject]@{ ok=`$true; worker=$i; payload=('x' * 2000); checkedAt=(Get-Date).ToString('o') }) 6
"@
  $jsonWorkers += Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $command) -PassThru -WindowStyle Hidden
}

$appendPath = Join-Path $tmpRoot 'graph.jsonl'
$appendWorkers = @()
for ($i = 1; $i -le $Workers; $i++) {
  $command = @"
. '$PSScriptRoot\common.ps1'
Add-Utf8LineLocked '$appendPath' (([ordered]@{ worker=$i; ok=`$true; time=(Get-Date).ToString('o') } | ConvertTo-Json -Compress))
"@
  $appendWorkers += Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $command) -PassThru -WindowStyle Hidden
}

$all = @($jsonWorkers + $appendWorkers)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline -and @($all | Where-Object { -not $_.HasExited }).Count -gt 0) {
  Start-Sleep -Milliseconds 100
}
foreach ($p in @($all | Where-Object { -not $_.HasExited })) {
  try { Stop-Process -Id $p.Id -Force } catch {}
}
$exitCodes = @($all | ForEach-Object { $_.Refresh(); $_.ExitCode })
$processOk = @($exitCodes | Where-Object { $_ -ne 0 }).Count -eq 0

$jsonOk = $false
try {
  $parsed = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $jsonOk = ($parsed.ok -eq $true -and $parsed.payload.Length -eq 2000)
} catch { $jsonOk = $false }

$appendOk = $false
$lineCount = 0
try {
  $lines = @(Get-Content -LiteralPath $appendPath -Encoding UTF8)
  $lineCount = $lines.Count
  $bad = 0
  foreach ($line in $lines) {
    try { $null = $line | ConvertFrom-Json } catch { $bad++ }
  }
  $appendOk = ($lineCount -eq $Workers -and $bad -eq 0)
} catch { $appendOk = $false }

$lockLeftovers = @(Get-ChildItem -LiteralPath $tmpRoot -Filter '*.lock' -Force -ErrorAction SilentlyContinue)
$locksOk = ($lockLeftovers.Count -eq 0)

$result = [pscustomobject]@{
  ok = ($processOk -and $jsonOk -and $appendOk -and $locksOk)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  workers = $Workers
  processOk = $processOk
  jsonOk = $jsonOk
  appendOk = $appendOk
  appendLines = $lineCount
  locksOk = $locksOk
  exitCodes = @($exitCodes)
  path = $tmpRoot
}

$statusPath = Join-Path $workspace 'last-concurrency-smoke.json'
Write-JsonUtf8NoBom $statusPath $result 8
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "CONCURRENCY_SMOKE ok=$($result.ok) workers=$Workers appendLines=$lineCount status=$statusPath" }
if ($result.ok) { exit 0 }
exit 1
