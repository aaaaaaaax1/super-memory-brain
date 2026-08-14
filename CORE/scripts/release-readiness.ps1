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

function ConvertTo-ReleaseReadinessTimestamp([object]$Value) {
  if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [DateTimeOffset]::Parse([string]$Value).ToUniversalTime() } catch { return $null }
}

function Get-InstallUiRegressionInputHashes {
  $relativeFiles = @(
    'manifest.json',
    'START_HERE.md',
    'install.bat',
    'install-ui.bat',
    'open-ui.bat',
    '..\01-INSTALL-AND-MAINTAIN.vbs',
    '..\02-DAILY-CONTROL-CENTER.vbs',
    'super-memory-brain\SKILL.md',
    'modules\skill-orchestrator\SKILL.md',
    'modules\skill-pool-router\SKILL.md',
    'modules\skill-pool-router\scripts\manage-skill-pool.ps1',
    'modules\skill-pool-router\scripts\skill-catalog.ps1',
    'scripts\install.bat',
    'scripts\install-ui.ps1',
    'scripts\install-menu.ps1',
    'scripts\bootstrap.ps1',
    'scripts\install.ps1',
    'scripts\first-load-bootstrap.ps1',
    'scripts\install-runtime.ps1',
    'scripts\install-codex-user-prompt-hook.ps1',
    'scripts\codex-user-prompt-hook.ps1',
    'scripts\internal\install-transaction.ps1',
    'scripts\internal\codex-hook-host-state.ps1',
    'scripts\internal\hook-runtime-common.ps1',
    'scripts\routing-kernel.ps1',
    'runtime\codex_prompt_hook.py',
    'runtime\codex_prompt_hook_launcher.py',
    'runtime\codex_prompt_hook_dispatcher.py',
    'runtime\brain_ui_server.py',
    'ui\src\main.tsx',
    'ui\src\styles.css',
    'ui\dist\index.html',
    'ui\dist\assets\app.js',
    'ui\dist\assets\app.css',
    'scripts\task-link-store.ps1',
    'scripts\task-state-store.ps1',
    'scripts\script-call-contract.ps1',
    'scripts\completion-guard.ps1',
    'scripts\status-snapshot-writer.ps1',
    'scripts\health-summary.ps1',
    'scripts\brain.ps1',
    'scripts\smoke-test.ps1',
    'scripts\verify-package.ps1',
    'scripts\ci.ps1',
    'scripts\install-agent.ps1',
    'scripts\hot-refresh-skills.ps1',
    'scripts\migrate-memory-layout.ps1',
    'scripts\cleanup-install-backups.ps1',
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

$verifyCheckedAt = if ($lastVerify) { ConvertTo-ReleaseReadinessTimestamp $lastVerify.checkedAt } else { $null }
$ciCheckedAt = if ($lastCi) { ConvertTo-ReleaseReadinessTimestamp $lastCi.checkedAt } else { $null }
$fullCiCurrent = [bool](
  $lastCi -and
  $lastCi.ok -eq $true -and
  $lastCi.skipIntegration -eq $false -and
  [string]$lastCi.version -eq [string]$manifest.version -and
  [string]$lastCi.pesterTier -in @('Core','Full') -and
  $ciCheckedAt -and
  $verifyCheckedAt -and
  $ciCheckedAt -ge $verifyCheckedAt
)

$risks = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true -and $lastVerify.version -eq $manifest.version)) { $risks += 'verify_missing_or_not_current' }
if (-not $fullCiCurrent) { $risks += 'full_ci_missing_stale_or_version_mismatch' }
if (-not ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)) { $risks += 'hot_refresh_missing' }
if (-not $installUiRegressionCurrent) { $risks += 'install_ui_regression_missing_or_stale' }
if ($blockingPrivacyHits.Count -gt 0) { $risks += 'privacy_hits_present' }

$result = [pscustomobject]@{
  ok = ($risks.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  verifyOk = ($lastVerify -and $lastVerify.ok -eq $true)
  fullCiOk = $fullCiCurrent
  fullCiCheckedAt = if ($ciCheckedAt) { $ciCheckedAt.ToString('o') } else { '' }
  verifyCheckedAt = if ($verifyCheckedAt) { $verifyCheckedAt.ToString('o') } else { '' }
  hotRefreshOk = ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)
  installUiRegressionOk = ($lastInstallUiRegression -and $lastInstallUiRegression.ok -eq $true)
  installUiRegressionCurrent = $installUiRegressionCurrent
  privacyOk = ($blockingPrivacyHits.Count -eq 0)
  privacyHitCount = [int]$privacy.hitCount
  blockingPrivacyHitCount = [int]$blockingPrivacyHits.Count
  risks = @($risks)
  recommendation = if ($risks.Count -eq 0) { 'Package-ready for direct Git review.' } else { 'Resolve package, CI, install, or privacy risks before publishing.' }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "RELEASE_READINESS ok=$($result.ok) version=$($result.version) risks=$($risks -join ',')" }
if (-not $result.ok) { exit 1 }
exit 0

