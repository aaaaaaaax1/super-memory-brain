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
  'README.md',
  'CHANGELOG.md',
  'CURRENT_BASELINE.md',
  'BASELINE_HISTORY.md',
  'maintenance-policy.json',
  'super-brain-rules.json',
  'tests\memory-recall-tests.json'
)
$actions = @()
foreach ($target in $targets) {
  $actions += [pscustomobject]@{ path=$target; action=if ($Apply) { 'update' } else { 'preview' } }
}

function Replace-First([string]$Text, [string]$Pattern, [string]$Replacement) {
  $regex = New-Object System.Text.RegularExpressions.Regex($Pattern)
  return $regex.Replace($Text, $Replacement, 1)
}

function Get-CoreRuleRegistryRuntimeHash([object]$Registry) {
  # The registry reader is Python and defines the canonical JSON contract.
  # Delegate the release hash to that exact JSON behavior instead of trying to
  # emulate it through PowerShell's extended-object serialization (which can
  # incorrectly expose string metadata such as Length as payload fields).
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) { throw 'VERSION_BUMP_PYTHON_REQUIRED_FOR_CORE_RULE_HASH' }
  $json = $Registry | ConvertTo-Json -Depth 100 -Compress
  $program = @'
import hashlib
import json
import sys

value = json.load(sys.stdin)
value.pop("payloadHash", None)
print(hashlib.sha256(json.dumps(
    value,
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
    allow_nan=False,
).encode("utf-8")).hexdigest())
'@
  $programPath = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($programPath,$program,[Text.UTF8Encoding]::new($false))
    $output = @($json | & $python.Source $programPath 2>&1)
  } finally {
    Remove-Item -LiteralPath $programPath -Force -ErrorAction SilentlyContinue
  }
  if ($LASTEXITCODE -ne 0) { throw ('VERSION_BUMP_CORE_RULE_HASH_FAILED: ' + (($output | ForEach-Object { [string]$_ }) -join "`n")) }
  $hash = (($output | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
  if ($hash -notmatch '^[a-f0-9]{64}$') { throw 'VERSION_BUMP_CORE_RULE_HASH_INVALID' }
  return $hash
}

function Update-CoreRuleRegistryVersion([string]$Path,[string]$TargetVersion) {
  $registry = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $registry.packageVersion = $TargetVersion
  $body = [ordered]@{}
  foreach ($property in $registry.PSObject.Properties) {
    if ($property.Name -ne 'payloadHash') { $body[$property.Name] = $property.Value }
  }
  $registry.payloadHash = Get-CoreRuleRegistryRuntimeHash ([pscustomobject]$body)
  Write-Utf8NoBom $Path ($registry | ConvertTo-Json -Depth 100)
}

if ($Apply) {
  $manifestPath = Join-Path $Root 'manifest.json'
  $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
  $manifestText = Replace-First $manifestText '"version"\s*:\s*"[^"]+"' ('"version": "' + $Version + '"')
  Write-Utf8NoBom $manifestPath $manifestText

  $readmePath = Join-Path $Root 'README.md'
  $readmeText = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
  $readmePattern = '(?m)^(\s*)' + [regex]::Escape($Supersedes) + '(\s*)$'
  $readmeText = Replace-First $readmeText $readmePattern ('${1}' + $Version + '${2}')
  Write-Utf8NoBom $readmePath $readmeText

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

  $maintenancePath = Join-Path $Root 'maintenance-policy.json'
  $maintenanceText = Get-Content -LiteralPath $maintenancePath -Raw -Encoding UTF8
  $maintenanceText = Replace-First $maintenanceText '"version"\s*:\s*"[^"]+"' ('"version": "' + $Version + '"')
  Write-Utf8NoBom $maintenancePath $maintenanceText

  Update-CoreRuleRegistryVersion (Join-Path $Root 'super-brain-rules.json') $Version

  $recallTestsPath = Join-Path $Root 'tests\memory-recall-tests.json'
  $recallTestsText = Get-Content -LiteralPath $recallTestsPath -Raw -Encoding UTF8
  $recallTestsText = Replace-First $recallTestsText ('"' + [regex]::Escape($Supersedes) + '"') ('"' + $Version + '"')
  Write-Utf8NoBom $recallTestsPath $recallTestsText

  $historyPath = Join-Path $Root 'BASELINE_HISTORY.md'
  $historyText = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
  if ($historyText -notlike "*## $Version*" ) {
    $historyText = $historyText -replace '^# BASELINE_HISTORY\s*', ("# BASELINE_HISTORY`n`n## $Version`n`nDate: " + (Get-Date -Format 'yyyy-MM-dd') + "`nStatus: [CURRENT][VERIFIED]`nChange:`n- $Summary`nSupersedes: $Supersedes`nRollback: Restore $Supersedes scripts/docs/manifest/baseline if $Version changes need to be disabled temporarily.`n`n")
    $historyText = $historyText -replace ("## " + [regex]::Escape($Supersedes) + "\s+Date:"), ("## $Supersedes`n`nDate:")
    $historyText = $historyText -replace 'Status: \[CURRENT\]\[VERIFIED\]', 'Status: [HISTORY][VERIFIED]'
    $currentPattern = '(?s)(## ' + [regex]::Escape($Version) + '\s+Date:\s+.*?Status:) \[HISTORY\]\[VERIFIED\]'
    $historyText = Replace-First $historyText $currentPattern '${1} [CURRENT][VERIFIED]'
    Write-Utf8NoBom $historyPath $historyText
  }

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
