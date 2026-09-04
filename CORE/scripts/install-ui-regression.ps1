param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryBase = Get-SuperBrainMemoryBaseRoot $Root
$Workspace = Join-Path $MemoryBase 'workspace'
New-Item -ItemType Directory -Force -Path $Workspace,(Join-Path $MemoryBase 'shared') | Out-Null

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
    'references\local-mcp-adapter.md',
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

function Test-ControlCenterAccessibilityContract {
  $mainPath = Join-Path $Root 'ui\src\main.tsx'
  $stylesPath = Join-Path $Root 'ui\src\styles.css'
  $serverPath = Join-Path $Root 'runtime\brain_ui_server.py'
  $missing = @()
  foreach ($path in @($mainPath,$stylesPath,$serverPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += ('missing=' + $path) }
  }
  if ($missing.Count -gt 0) { return [pscustomobject]@{ ok=$false; missing=@($missing); checks=@() } }

  $main = [System.IO.File]::ReadAllText($mainPath,[System.Text.Encoding]::UTF8)
  $styles = [System.IO.File]::ReadAllText($stylesPath,[System.Text.Encoding]::UTF8)
  $server = [System.IO.File]::ReadAllText($serverPath,[System.Text.Encoding]::UTF8)
  $starmapLabel = -join @(0x8BB0,0x5FC6,0x661F,0x56FE | ForEach-Object { [char]$_ })
  # Keep the source ASCII-only: Windows PowerShell 5.1 treats UTF-8 scripts
  # without a BOM as ANSI, which can corrupt Chinese literals before parsing.
  $memoryCategoryLabels = @(
    (-join @(0x504F,0x597D,0x4E0E,0x6027,0x683C | ForEach-Object { [char]$_ })),
    (-join @(0x51B3,0x7B56,0x4E0E,0x6D41,0x7A0B | ForEach-Object { [char]$_ })),
    (-join @(0x81EA,0x6211,0x5B66,0x4E60 | ForEach-Object { [char]$_ }))
  )
  $memoryCategoryKeys = @('key: "memory"', 'key: "preference"', 'key: "experience"', 'key: "decision-procedure"', 'key: "learning"')
  $hasAllMemoryCategoryLabels = @($memoryCategoryLabels | Where-Object { -not $main.Contains($_) }).Count -eq 0
  $hasAllMemoryCategoryKeys = @($memoryCategoryKeys | Where-Object { -not $main.Contains($_) }).Count -eq 0
  $primaryNavigation = [regex]::Match($main, 'const primaryNavigation = \[[\s\S]*?\n    \];')
  $consoleHasNoProfileEntry = ($primaryNavigation.Success -and -not $primaryNavigation.Value.Contains('profile'))
  $checks = @(
    [pscustomobject]@{ name='semantic_navigation'; ok=($main.Contains('aria-current') -and $main.Contains('aria-label')) },
    [pscustomobject]@{ name='live_updates'; ok=$main.Contains('aria-live') },
    [pscustomobject]@{ name='keyboard_search'; ok=$main.Contains('onKeyDown') },
    [pscustomobject]@{ name='starmap_label'; ok=($main.Contains('renderer.domElement.setAttribute') -and $main.Contains($starmapLabel)) },
    [pscustomobject]@{ name='starmap_deselect'; ok=($main.Contains('clearStarmapSelection') -and $main.Contains('event.key === "Escape"') -and $main.Contains('onSelectRef.current(null)')) },
    [pscustomobject]@{ name='starmap_node_title'; ok=$main.Contains('createStarmapNodeLabel') },
    [pscustomobject]@{ name='starmap_single_title'; ok=($main.Contains('createStarmapNodeLabel') -and $main.Contains('element.className = "starmap-node-label"') -and -not $main.Contains('node.kind === "task" || graph.nodes.length === 1') -and -not $main.Contains('className: "starmap-single-node"') -and $main.Contains('selectableNodes.length > 0')) },
    [pscustomobject]@{ name='starmap_label_bounds'; ok=($main.Contains('const labelX = Math.max') -and $main.Contains('const labelY = Math.max')) },
    [pscustomobject]@{ name='starmap_selection_focus'; ok=($main.Contains('const selectedPosition = props.selectedKey') -and $main.Contains('const focusTarget = new THREE.Vector3') -and $main.Contains('cameraState.target.lerp(focusTarget')) },
    [pscustomobject]@{ name='starmap_full_height'; ok=$styles.Contains('height: 100dvh') },
    [pscustomobject]@{ name='memory_category_grouping'; ok=($main.Contains('MEMORY_CATEGORIES') -and $hasAllMemoryCategoryLabels -and $hasAllMemoryCategoryKeys -and $main.Contains('kinds: ["decision", "procedure"]')) },
    [pscustomobject]@{ name='timeline_explicit_actions'; ok=($main.Contains('timeline-entry-actions') -and $main.Contains('onClick: () => props.onOpen(item)') -and $main.Contains('event.stopPropagation(); props.onTrash(item);') -and $server.Contains('cardRef')) },
    [pscustomobject]@{ name='managed_recycle_bin'; ok=($main.Contains('function ManagedRecycleBin') -and $main.Contains('recycle-bin-select-all') -and $main.Contains('deleteTrashedCards') -and $main.Contains('lifecycles: ["trashed"]')) },
    [pscustomobject]@{ name='trash_delete_acknowledgement'; ok=($main.Contains('deleteAcknowledged: true') -and $server.Contains('BRAIN_UI_TRASH_DELETE_ACKNOWLEDGEMENT_REQUIRED')) },
    [pscustomobject]@{ name='console_profile_navigation_removed'; ok=$consoleHasNoProfileEntry },
    [pscustomobject]@{ name='visible_focus'; ok=$styles.Contains('button:focus-visible') },
    [pscustomobject]@{ name='motion_reduction'; ok=$styles.Contains('@media (prefers-reduced-motion: reduce)') },
    [pscustomobject]@{ name='mobile_layout'; ok=$styles.Contains('@media (max-width: 760px)') },
    [pscustomobject]@{ name='long_text_wrap'; ok=$styles.Contains('overflow-wrap: anywhere') },
    [pscustomobject]@{ name='loopback_capability'; ok=($server.Contains('COOKIE_NAME') -and $server.Contains('BRAIN_UI_ORIGIN_REJECTED')) }
  )
  return [pscustomobject]@{ ok=(@($checks | Where-Object { $_.ok -ne $true }).Count -eq 0); missing=@($missing); checks=@($checks) }
}

function New-Check([string]$Name, [bool]$Ok, [object]$Detail) {
  return [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail }
}

$uiScripts = @(
  'install-ui.ps1',
  'install-menu.ps1',
  'bootstrap.ps1',
  'install.ps1',
  'first-load-bootstrap.ps1',
  'install-runtime.ps1',
  'install-codex-user-prompt-hook.ps1',
  'internal\install-transaction.ps1',
  'internal\codex-hook-host-state.ps1',
  'install-agent.ps1',
  'health-check.ps1',
  'cleanup-install-backups.ps1',
  'migrate-memory-layout.ps1',
  'hot-refresh-skills.ps1',
  'repair-hook.ps1',
  'brain.ps1',
  'health-summary.ps1',
  'intent-router.ps1',
  'agent-scorecard.ps1',
  'dispatch-learning.ps1',
  'release-readiness.ps1',
  'health-summary.ps1',
  'smart-next.ps1'
)

$checks = @()

$paths = Invoke-RegressionScript 'check-install-ui-paths.ps1' -ScriptParams @{ Json = $true }
$checks += New-Check 'install_ui_paths' $paths.ok $paths

$ast = @($uiScripts | ForEach-Object { Test-AstParse $_ })
$checks += New-Check 'ui_script_ast_parse' (@($ast | Where-Object { $_.ok -ne $true }).Count -eq 0) $ast

$accessibility = Test-ControlCenterAccessibilityContract
$checks += New-Check 'control_center_accessibility_contract' $accessibility.ok $accessibility

$health = Invoke-RegressionScript 'smoke-test.ps1'
$checks += New-Check 'health_check' $health.ok $health

$importRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-install-ui-import-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $importRoot | Out-Null
try {
  $memoryImport = Invoke-RegressionScript 'migrate-memory-layout.ps1' -ScriptParams @{ ImportRoot = $importRoot; Mode = 'Merge' }
  $checks += New-Check 'memory_import_dry_run' ($memoryImport.exitCode -eq 0 -and $memoryImport.raw -match 'MIGRATION action=plan' -and $memoryImport.raw -match 'MIGRATION_GUARD') $memoryImport
} finally {
  Remove-Item -LiteralPath $importRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$cleanup = Invoke-RegressionScript 'cleanup-install-backups.ps1' -ScriptParams @{ Keep = 1 }
$checks += New-Check 'cleanup_backups_dry_run' ($cleanup.exitCode -eq 0 -and $cleanup.raw -match 'INSTALL_BACKUP_CLEANUP_DRY_RUN') $cleanup

$reportSkillRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-hot-refresh-report-' + [guid]::NewGuid().ToString('n'))
$reportSkillDir = Join-Path $reportSkillRoot 'super-memory-brain'
New-Item -ItemType Directory -Force -Path $reportSkillDir | Out-Null
try {
  Copy-Item -LiteralPath (Join-Path $Root 'super-memory-brain\SKILL.md') -Destination (Join-Path $reportSkillDir 'SKILL.md') -Force
  Write-SuperBrainPackageRootMarker $reportSkillDir $Root
  $hotRefresh = Invoke-RegressionScript 'hot-refresh-skills.ps1' -ScriptParams @{
    SkillRoots = @($reportSkillRoot)
    SkillNames = @('super-memory-brain')
    SkipGlobalStartup = $true
    ReportOnly = $true
    Json = $true
  }
  $hotRefreshOk = $hotRefresh.ok
  if ($hotRefresh.parsed) {
    $targets = @($hotRefresh.parsed.results | ForEach-Object { $_.skillName } | Sort-Object -Unique)
    $hotRefreshOk = $hotRefreshOk -and
      ($hotRefresh.parsed.mode -eq 'report-only') -and
      ([bool]$hotRefresh.parsed.skipGlobalStartup) -and
      ($targets -contains 'super-memory-brain') -and
      ($targets -notcontains 'skill-orchestrator') -and
      ($targets -notcontains 'plusunm-g1') -and
      ($targets -notcontains 'nexsandglass-dedicated-memory') -and
      ($targets -notcontains 'skill-evolution-loop') -and
      ($targets -notcontains 'skill-pool-router')
  } else {
    $hotRefreshOk = $false
  }
  $checks += New-Check 'hot_refresh_report_only' $hotRefreshOk $hotRefresh
} finally {
  Remove-Item -LiteralPath $reportSkillRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($checks | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = Get-SuperBrainUtcTimestamp
  packageRoot = $Root
  rule = 'Every Super Brain update, especially major versions, plus any version bump, extension/skill/cold-reference addition, or install/UI/manifest change must keep install.bat/UI capabilities current and pass install UI regression before completion.'
  coverage = @(
    'install.bat UI paths',
    'package privacy sentinel and direct-Git exclusion checks',
    'memory import dry-run',
    'cleanup backup dry-run',
    'isolated installer health-check and runtime readiness',
    'transactional bootstrap and first-load/runtime parse coverage',
    'hot-refresh report-only narrow scope',
    'package readiness input'
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


