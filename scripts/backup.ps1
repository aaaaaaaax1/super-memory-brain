param(
  [switch]$IncludeWorkspace,
  [string]$DestinationRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainMemoryBaseRoot $root
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
  $DestinationRoot = Join-Path (Get-SuperBrainArchiveRoot $root) 'backups'
}
$DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
$backupRoot = Join-Path $DestinationRoot "backup-$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

$copied = New-Object System.Collections.ArrayList
function Copy-BackupItem([string]$Source,[string]$Destination,[string]$Kind) {
  if (-not (Test-Path -LiteralPath $Source)) { return }
  $parent = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
  [void]$script:copied.Add([pscustomobject]@{ kind=$Kind; source=$Source; destination=$Destination })
}

foreach ($platform in @('zcode','codex')) {
  $skillRoot = Join-Path $env:USERPROFILE ".$platform\skills"
  foreach ($name in @('super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory','skill-evolution-loop','skill-pool-router')) {
    Copy-BackupItem (Join-Path $skillRoot $name) (Join-Path $backupRoot "installed-skills\$platform\$name") 'installed_skill'
  }
}

$memoryDestination = Join-Path $backupRoot 'memory'
New-Item -ItemType Directory -Force -Path $memoryDestination | Out-Null
foreach ($item in @(Get-ChildItem -LiteralPath $memoryRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'workspace' })) {
  Copy-BackupItem $item.FullName (Join-Path $memoryDestination $item.Name) 'memory'
}

$workspace = Join-Path $memoryRoot 'workspace'
$workspaceDestination = Join-Path $memoryDestination 'workspace'
if ($IncludeWorkspace) {
  Copy-BackupItem $workspace $workspaceDestination 'workspace_full'
} elseif (Test-Path -LiteralPath $workspace) {
  New-Item -ItemType Directory -Force -Path $workspaceDestination | Out-Null
  $criticalWorkspaceItems = @(
    'active-checkpoint.json','current-task-context.json','last-current-task-context.json','last-completed-checkpoint.json',
    'status-card.json','super-brain-state.json','task-graph.json','step-ledger.json','team-task-index.json','agent-teams.json',
    'session-binding.json','session-notes.md','experience-index.md','guard-state','runtime-state','team-tasks','task-archive',
    'team-tasks-archive','agent-bridge','procedure-cards','experiences','reflection','skill-evolution','learning-drafts'
  )
  foreach ($name in $criticalWorkspaceItems) {
    Copy-BackupItem (Join-Path $workspace $name) (Join-Path $workspaceDestination $name) 'workspace_critical'
  }
}

$manifest = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.backup.v2'
  version = (Get-SuperBrainManifest $root).version
  packageRoot = $root
  stateRoot = $memoryRoot
  archiveRoot = Get-SuperBrainArchiveRoot $root
  backupRoot = $backupRoot
  includeWorkspace = [bool]$IncludeWorkspace
  generatedWorkspaceExcluded = (-not $IncludeWorkspace)
  copiedCount = $copied.Count
  copied = @($copied)
  restore = 'Copy the selected backup items to their recorded source paths after stopping Super Brain writers.'
}
Write-JsonUtf8NoBom (Join-Path $backupRoot 'backup-manifest.json') $manifest 10
if ($Json) { $manifest | ConvertTo-Json -Depth 10 } else { Write-Host "Backup created: $backupRoot includeWorkspace=$($IncludeWorkspace.IsPresent) copied=$($copied.Count)" }
