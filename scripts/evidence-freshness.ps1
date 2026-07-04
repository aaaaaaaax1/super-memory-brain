param(
  [string]$LogPath = '',
  [string]$RequiredVersion = '',
  [int]$MaxAgeMinutes = 30,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-evidence-freshness.json'
$manifest = Get-SuperBrainManifest $Root
if ([string]::IsNullOrWhiteSpace($RequiredVersion)) { $RequiredVersion = [string]$manifest.version }

$candidates = @()
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
  $candidates += [System.IO.Path]::GetFullPath($LogPath)
} else {
  foreach ($name in @('last-ci.json','last-verify-package.json','last-status-snapshot.json','last-task-verification.json','status-card.json','super-brain-state.json')) {
    $candidate = Join-Path $workspace $name
    if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
  }
}

$items = @($candidates | ForEach-Object {
  $path = $_
  $exists = Test-Path -LiteralPath $path
  $ageMinutes = $null
  $fileVersion = ''
  $freshTime = $false
  $freshVersion = $false
  $reason = @()
  if ($exists) {
    $item = Get-Item -LiteralPath $path
    $ageMinutes = [Math]::Round(((Get-Date) - $item.LastWriteTime).TotalMinutes, 2)
    $freshTime = ($ageMinutes -le $MaxAgeMinutes)
    if (-not $freshTime) { $reason += "older_than_${MaxAgeMinutes}m" }
    try {
      $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $json = $raw | ConvertFrom-Json
      foreach ($prop in @('version','packageVersion')) {
        if ($json.PSObject.Properties.Name -contains $prop -and -not [string]::IsNullOrWhiteSpace([string]$json.$prop)) { $fileVersion = [string]$json.$prop; break }
      }
    } catch {}
    $freshVersion = ([string]::IsNullOrWhiteSpace($RequiredVersion) -or [string]::IsNullOrWhiteSpace($fileVersion) -or $fileVersion -eq $RequiredVersion)
    if (-not $freshVersion) { $reason += "version_mismatch:$fileVersion" }
  } else {
    $reason += 'missing'
  }
  [pscustomobject]@{
    path = $path
    exists = $exists
    ageMinutes = $ageMinutes
    maxAgeMinutes = $MaxAgeMinutes
    requiredVersion = $RequiredVersion
    version = $fileVersion
    fresh = ($exists -and $freshTime -and $freshVersion)
    reason = @($reason)
  }
})

$result = [pscustomobject]@{
  ok = (@($items | Where-Object { -not $_.fresh }).Count -eq 0 -and @($items).Count -gt 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  requiredVersion = $RequiredVersion
  maxAgeMinutes = $MaxAgeMinutes
  items = @($items)
  guard = 'Do not use stale logs/snapshots as current-site evidence. If no fresh item exists, state unknown and refresh evidence first.'
  nextAction = if (@($items | Where-Object { $_.fresh }).Count -gt 0) { 'Use only fresh evidence items for current conclusions.' } else { 'Refresh live evidence before making current-state conclusions.' }
}
Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { if ($result.ok) { Write-Host "EVIDENCE_FRESHNESS_OK path=$outPath" } else { Write-Host "EVIDENCE_FRESHNESS_NEEDS_REFRESH path=$outPath"; exit 1 } }
