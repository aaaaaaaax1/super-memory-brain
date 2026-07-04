param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Read-WorkspaceJson([string]$Name) {
  $candidate = Join-Path $workspace $Name
  if (-not (Test-Path $candidate)) { return $null }
  try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-InstallUiRegressionInputHashes {
  $relativeFiles = @(
    'manifest.json',
    'super-memory-brain\SKILL.md',
    'modules\skill-orchestrator\SKILL.md',
    'scripts\install.bat',
    'scripts\install-ui.ps1',
    'scripts\install-menu.ps1',
    'scripts\install.ps1',
    'scripts\install-agent.ps1',
    'scripts\hot-refresh-skills.ps1',
    'scripts\migrate-memory-layout.ps1',
    'scripts\cleanup-install-backups.ps1',
    'scripts\prepare-share.ps1',
    'scripts\verify-share.ps1',
    'scripts\release-share.ps1',
    'scripts\release-private.ps1',
    'references\install-refresh.md',
    'references\maintenance-release.md',
    'references\index.md',
    'references\single-agent-subagent-workflow.md',
    'references\automatic-evolution-policy.md',
    'references\base-instructions\gpt-5.5-base-instructions.md'
  )
  $extensionFiles = @()
  $extensionsRoot = Join-Path $Root 'extensions'
  if (Test-Path $extensionsRoot) {
    $extensionFiles = @(Get-ChildItem -LiteralPath $extensionsRoot -Recurse -File -Filter 'extension.json' | ForEach-Object {
      $_.FullName.Substring($Root.Length + 1)
    })
  }
  $all = @($relativeFiles + $extensionFiles | Sort-Object -Unique)
  return @($all | ForEach-Object {
    $path = Join-Path $Root $_
    [pscustomobject]@{
      path = $_
      exists = (Test-Path $path)
      sha256 = if (Test-Path $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { '' }
    }
  })
}

$manifest = Get-SuperBrainManifest $Root
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastCi = Read-WorkspaceJson 'last-ci.json'
$lastRelease = Read-WorkspaceJson 'last-release.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$lastInstallUiRegression = Read-WorkspaceJson 'last-install-ui-regression.json'
$privacyJson = & (Join-Path $PSScriptRoot 'privacy-hit-locator.ps1') -Json
$privacy = $privacyJson | ConvertFrom-Json
$blockingPrivacyHits = @(@($privacy.hits) | Where-Object { $_.likelyFalsePositive -ne $true })
$currentInstallUiHashes = @(Get-InstallUiRegressionInputHashes)
$installUiRegressionCurrent = $false
if ($lastInstallUiRegression -and $lastInstallUiRegression.ok -eq $true -and $lastInstallUiRegression.inputHashes) {
  $oldHashes = @($lastInstallUiRegression.inputHashes) | ConvertTo-Json -Depth 8 -Compress
  $newHashes = @($currentInstallUiHashes) | ConvertTo-Json -Depth 8 -Compress
  $installUiRegressionCurrent = ($oldHashes -eq $newHashes)
}

$risks = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true -and $lastVerify.version -eq $manifest.version)) { $risks += 'verify_missing_or_not_current' }
if (-not ($lastCi -and $lastCi.ok -eq $true -and $lastCi.skipIntegration -eq $false)) { $risks += 'full_ci_missing_or_skipped' }
if (-not ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)) { $risks += 'hot_refresh_missing' }
if (-not $installUiRegressionCurrent) { $risks += 'install_ui_regression_missing_or_stale' }
if ($blockingPrivacyHits.Count -gt 0) { $risks += 'privacy_hits_present' }
$releaseCurrent = $false
if ($lastRelease -and $lastRelease.ok -eq $true -and $lastRelease.includesMemory -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$lastRelease.destination)) {
  $releaseManifestPath = Join-Path ([string]$lastRelease.destination) 'manifest.json'
  if (Test-Path $releaseManifestPath) {
    try { $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; $releaseCurrent = ($releaseManifest.version -eq $manifest.version) } catch {}
  }
}
if (-not $releaseCurrent) { $risks += 'share_release_missing_or_stale' }

$result = [pscustomobject]@{
  ok = ($risks.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  verifyOk = ($lastVerify -and $lastVerify.ok -eq $true)
  fullCiOk = ($lastCi -and $lastCi.ok -eq $true -and $lastCi.skipIntegration -eq $false)
  hotRefreshOk = ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)
  installUiRegressionOk = ($lastInstallUiRegression -and $lastInstallUiRegression.ok -eq $true)
  installUiRegressionCurrent = $installUiRegressionCurrent
  privacyOk = ($blockingPrivacyHits.Count -eq 0)
  privacyHitCount = [int]$privacy.hitCount
  blockingPrivacyHitCount = [int]$blockingPrivacyHits.Count
  shareReleaseCurrent = $releaseCurrent
  shareDestination = if ($lastRelease) { $lastRelease.destination } else { '' }
  risks = @($risks)
  recommendation = if ($risks.Count -eq 0) { 'Release-ready.' } else { 'Resolve risks before sharing externally.' }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "RELEASE_READINESS ok=$($result.ok) version=$($result.version) risks=$($risks -join ',')" }
if (-not $result.ok) { exit 1 }
exit 0

