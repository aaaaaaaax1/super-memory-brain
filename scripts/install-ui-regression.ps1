param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryBase = Get-SuperBrainMemoryBaseRoot $Root
$Workspace = Join-Path $MemoryBase 'workspace'

function Get-InstallUiRegressionInputHashes {
  $relativeFiles = @(
    'manifest.json',
    'install.bat',
    'FRIEND_INSTALL.md',
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
    'scripts\install-codex-user-prompt-hook.ps1',
    'scripts\codex-user-prompt-hook.ps1',
    'scripts\routing-kernel.ps1',
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

function Invoke-RegressionScript([string]$ScriptName, [hashtable]$ScriptParams = @{}) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  if (-not (Test-Path $scriptPath)) {
    return [pscustomobject]@{ name = $ScriptName; ok = $false; exitCode = -1; parsed = $null; raw = 'script_missing' }
  }

  $global:LASTEXITCODE = 0
  $output = @(& $scriptPath @ScriptParams 2>&1 6>&1)
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  $parsed = $null
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    try { $parsed = $text | ConvertFrom-Json } catch {}
  }

  return [pscustomobject]@{
    name = $ScriptName
    ok = ($exitCode -eq 0 -and (($null -eq $parsed) -or $parsed.ok -eq $true))
    exitCode = $exitCode
    parsed = $parsed
    raw = $text
  }
}

function Test-AstParse([string]$ScriptName) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  if (-not (Test-Path $scriptPath)) {
    return [pscustomobject]@{ name = $ScriptName; ok = $false; errorCount = 1; errors = @('script_missing') }
  }

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
  return [pscustomobject]@{
    name = $ScriptName
    ok = (@($errors).Count -eq 0)
    errorCount = @($errors).Count
    errors = @($errors | ForEach-Object { $_.Message })
  }
}

function New-Check([string]$Name, [bool]$Ok, [object]$Detail) {
  return [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail }
}

$uiScripts = @(
  'install-ui.ps1',
  'install-menu.ps1',
  'bootstrap.ps1',
  'install.ps1',
  'install-agent.ps1',
  'health-check.ps1',
  'cleanup-install-backups.ps1',
  'migrate-memory-layout.ps1',
  'release-share.ps1',
  'release-private.ps1',
  'hot-refresh-skills.ps1',
  'repair-hook.ps1',
  'brain.ps1',
  'health-summary.ps1',
  'intent-router.ps1',
  'agent-scorecard.ps1',
  'dispatch-learning.ps1',
  'release-readiness.ps1',
  'verify-share.ps1',
  'prepare-share.ps1'
)

$checks = @()

$paths = Invoke-RegressionScript 'check-install-ui-paths.ps1' -ScriptParams @{ Json = $true }
$checks += New-Check 'install_ui_paths' $paths.ok $paths

$ast = @($uiScripts | ForEach-Object { Test-AstParse $_ })
$checks += New-Check 'ui_script_ast_parse' (@($ast | Where-Object { $_.ok -ne $true }).Count -eq 0) $ast

$health = Invoke-RegressionScript 'health-check.ps1'
$checks += New-Check 'health_check' $health.ok $health

$shareDestination = Join-Path $Workspace 'install-ui-regression-share'
$verifyShare = Invoke-RegressionScript 'verify-share.ps1' -ScriptParams @{ Destination = $shareDestination }
$checks += New-Check 'verify_share_package' $verifyShare.ok $verifyShare

$importRoot = Join-Path $MemoryBase 'merge-overlay'
$memoryImport = Invoke-RegressionScript 'migrate-memory-layout.ps1' -ScriptParams @{ ImportRoot = $importRoot; Mode = 'Merge' }
$checks += New-Check 'memory_import_dry_run' ($memoryImport.exitCode -eq 0 -and $memoryImport.raw -match 'MIGRATE_DRY_RUN') $memoryImport

$cleanup = Invoke-RegressionScript 'cleanup-install-backups.ps1' -ScriptParams @{ Keep = 1 }
$checks += New-Check 'cleanup_backups_dry_run' ($cleanup.exitCode -eq 0 -and $cleanup.raw -match 'INSTALL_BACKUP_CLEANUP_DRY_RUN') $cleanup

$codexRoot = Join-Path $env:USERPROFILE '.codex\skills'
$zcodeRoot = Join-Path $env:USERPROFILE '.zcode\skills'
$hotRefresh = Invoke-RegressionScript 'hot-refresh-skills.ps1' -ScriptParams @{
  SkillRoots = @($codexRoot, $zcodeRoot)
  SkillNames = @('super-memory-brain', 'skill-orchestrator')
  SkipGlobalStartup = $true
  ReportOnly = $true
  Json = $true
}
$hotRefreshOk = $hotRefresh.ok
if ($hotRefresh.parsed) {
  $targets = @($hotRefresh.parsed.results | ForEach-Object { $_.skillName } | Sort-Object -Unique)
  $hotRefreshOk = $hotRefreshOk -and
    ($hotRefresh.parsed.mode -eq 'report-only') -and
    ($hotRefresh.parsed.skipGlobalStartup -eq 2) -and
    ($targets -contains 'super-memory-brain') -and
    ($targets -contains 'skill-orchestrator') -and
    ($targets -notcontains 'plusunm-g1') -and
    ($targets -notcontains 'nexsandglass-dedicated-memory')
} else {
  $hotRefreshOk = $false
}
$checks += New-Check 'hot_refresh_report_only' $hotRefreshOk $hotRefresh

$failed = @($checks | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  rule = 'Every Super Brain update, especially major versions, plus any version bump, extension/skill/cold-reference addition, or install/share/UI/manifest change must keep install.bat/UI capabilities current and pass install UI regression before completion.'
  coverage = @(
    'install.bat UI paths',
    'share package verification and privacy shape',
    'memory import dry-run',
    'cleanup backup dry-run',
    'health-check/global inject readiness',
    'hot-refresh report-only narrow scope',
    'release readiness input'
  )
  inputHashes = @(Get-InstallUiRegressionInputHashes)
  checks = @($checks)
  failed = @($failed | ForEach-Object { $_.name })
}

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Workspace 'last-install-ui-regression.json') -Encoding UTF8

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "INSTALL_UI_REGRESSION ok=$($result.ok) failed=$($result.failed -join ',')"
}

if (-not $result.ok) { exit 1 }
exit 0


