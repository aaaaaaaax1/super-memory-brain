param(
  [Parameter(Mandatory=$true)]
  [string]$Version,
  [Parameter(Mandatory=$true)]
  [string]$Summary,
  [string]$Supersedes = '',
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid semantic version: $Version" }
$manifest = Get-SuperBrainManifest $Root
if ([string]::IsNullOrWhiteSpace($Supersedes)) { $Supersedes = [string]$manifest.version }

$targets = @(
  'manifest.json',
  'CHANGELOG.md',
  'CURRENT_BASELINE.md',
  'BASELINE_HISTORY.md',
  'memory\graph.jsonl'
)
$actions = @()
foreach ($target in $targets) {
  $actions += [pscustomobject]@{ path=$target; action=if ($Apply) { 'update' } else { 'preview' } }
}

function Replace-First([string]$Text, [string]$Pattern, [string]$Replacement) {
  return [regex]::Replace($Text, $Pattern, $Replacement, 1)
}

if ($Apply) {
  $manifestPath = Join-Path $Root 'manifest.json'
  $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
  $manifestText = Replace-First $manifestText '"version"\s*:\s*"[^"]+"' ('"version": "' + $Version + '"')
  Write-Utf8NoBom $manifestPath $manifestText

  $changelogPath = Join-Path $Root 'CHANGELOG.md'
  $changelogText = Get-Content -LiteralPath $changelogPath -Raw -Encoding UTF8
  if ($changelogText -notlike "*## $Version*") {
    $changelogText = $changelogText -replace '^# Changelog\s*', ("# Changelog`n`n## $Version`n`n- $Summary`n`n")
    Write-Utf8NoBom $changelogPath $changelogText
  }

  $baselinePath = Join-Path $Root 'CURRENT_BASELINE.md'
  $baselineText = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8
  $baselineText = $baselineText -replace 'Package Version: \d+\.\d+\.\d+', "Package Version: $Version"
  Write-Utf8NoBom $baselinePath $baselineText

  $historyPath = Join-Path $Root 'BASELINE_HISTORY.md'
  $historyText = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
  if ($historyText -notlike "*## $Version*" ) {
    $historyText = $historyText -replace '^# BASELINE_HISTORY\s*', ("# BASELINE_HISTORY`n`n## $Version`n`nDate: " + (Get-Date -Format 'yyyy-MM-dd') + "`nStatus: [CURRENT][VERIFIED]`nChange:`n- $Summary`nSupersedes: $Supersedes`nRollback: Restore $Supersedes scripts/docs/manifest/baseline if $Version changes need to be disabled temporarily.`n`n")
    $historyText = $historyText -replace ("## " + [regex]::Escape($Supersedes) + "\s+Date:"), ("## $Supersedes`n`nDate:")
    $historyText = $historyText -replace 'Status: \[CURRENT\]\[VERIFIED\]', 'Status: [HISTORY][VERIFIED]'
    $historyText = $historyText -replace ("## " + [regex]::Escape($Version) + "\s+Date:\s+.*?Status: \[HISTORY\]\[VERIFIED\]"), ("## $Version`n`nDate: " + (Get-Date -Format 'yyyy-MM-dd') + "`nStatus: [CURRENT][VERIFIED]")
    Write-Utf8NoBom $historyPath $historyText
  }

  & (Join-Path $PSScriptRoot 'graph-add.ps1') -Subject "v$Version" -Relation 'supersedes' -Object "v$Supersedes" -Evidence 'version-bump.ps1; CHANGELOG.md; BASELINE_HISTORY.md' -Tags '[CURRENT][VERIFIED]' | Out-Null
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  mode = if ($Apply) { 'applied' } else { 'preview' }
  version = $Version
  supersedes = $Supersedes
  summary = $Summary
  actions = @($actions)
  nextSteps = if ($Apply) { @('Run scripts\verify-package.ps1','Run scripts\ci.ps1') } else { @('Re-run with -Apply to update version files') }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "VERSION_BUMP mode=$($result.mode) version=$Version supersedes=$Supersedes" }
exit 0
