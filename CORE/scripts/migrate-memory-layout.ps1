[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Plan','Stage','Import','Verify','Cutover','RollbackAdapter','Status')]
  [string]$Action = 'Plan',
  [string]$ImportRoot = '',
  [string]$EpochId = '',
  [string]$AdapterName = 'legacy-memory-layout',
  [ValidateSet('Merge','Overwrite')]
  [string]$Mode = 'Merge',
  [string]$StateRoot = '',
  [switch]$Apply,
  [switch]$CleanupImport,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$brainControl = Join-Path $Root 'runtime\brain_control.py'

function Write-MigrationResult([object]$Value) {
  if ($Json) {
    $Value | ConvertTo-Json -Depth 20
    return
  }
  Write-Host "MIGRATION action=$($Value.action) epoch=$($Value.epochId) status=$($Value.status) manifest=$($Value.manifestHash)"
  if ($Value.PSObject.Properties['recordCounts']) {
    $pairs = @($Value.recordCounts.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
    Write-Host "MIGRATION_RECORDS $pairs"
  }
  if ($Value.PSObject.Properties['guard']) { Write-Host "MIGRATION_GUARD $($Value.guard)" }
}

function Invoke-MigrationControl([string]$ControlAction,[object]$Request) {
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) { throw 'MIGRATION_PYTHON_MISSING' }
  if (-not (Test-Path -LiteralPath $brainControl -PathType Leaf)) { throw 'MIGRATION_BRAIN_CONTROL_MISSING' }
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 20 -Compress)))
  $raw = @(& $python.Source -X utf8 -B $brainControl --state-root $effectiveStateRoot $ControlAction --request-base64 $encoded 2>&1)
  $exitCode = $LASTEXITCODE
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'MIGRATION_EMPTY_CONTROL_RESPONSE' }
  try { $result = $text | ConvertFrom-Json } catch { throw "MIGRATION_INVALID_CONTROL_RESPONSE $text" }
  if ($exitCode -ne 0 -or $result.ok -ne $true) {
    $code = if ($result.PSObject.Properties['code']) { [string]$result.code } else { 'MIGRATION_CONTROL_FAILED' }
    $error = if ($result.PSObject.Properties['error']) { [string]$result.error } else { $text }
    throw "$code $error"
  }
  return $result
}

function Resolve-ImportMemoryRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $Path }
  $nested = Join-Path $Path 'memory'
  if (Test-Path -LiteralPath $nested -PathType Container) {
    $rootItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'memory' })
    if ($rootItems.Count -eq 0) {
      Write-Host "MIGRATION_IMPORT_NESTED_MEMORY detected=$nested"
      return $nested
    }
  }
  return $Path
}

function Get-LegacyMigrationSources {
  if (-not [string]::IsNullOrWhiteSpace($ImportRoot)) {
    $resolved = Resolve-ImportMemoryRoot $ImportRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "MIGRATION_IMPORT_ROOT_MISSING $resolved" }
    return @([IO.Path]::GetFullPath($resolved))
  }
  $baseRoot = [IO.Path]::GetFullPath((Get-SuperBrainMemoryBaseRoot $Root))
  $candidates = @(
    (Join-Path $Root 'memory'),
    (Join-Path $Root 'memory-zcode'),
    (Join-Path $Root 'memory-codex')
  )
  $sources = @()
  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
    $full = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).Path)
    if ($full -eq $baseRoot -or $baseRoot.StartsWith($full + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
      Write-Host "MIGRATION_SKIP_ACTIVE_OR_PARENT path=$full"
      continue
    }
    $sources += $full
  }
  return @($sources | Select-Object -Unique)
}

if ([string]::IsNullOrWhiteSpace($StateRoot)) {
  $effectiveStateRoot = [IO.Path]::GetFullPath((Get-SuperBrainMemoryBaseRoot $Root))
} else {
  $effectiveStateRoot = [IO.Path]::GetFullPath($StateRoot)
}

if ($CleanupImport) {
  throw 'MIGRATION_CLEANUP_PREVIEW_ONLY Legacy roots are never deleted by this command. Run cleanup only after a verified epoch and an explicit separate confirmation.'
}

if ($Mode -ne 'Merge') {
  Write-Host "MIGRATION_LEGACY_MODE_IGNORED mode=$Mode direct overwrite is retired; use the staged hash-bound migration path."
}

$mutating = $Action -in @('Stage','Import','Verify','Cutover','RollbackAdapter')
if ($mutating -and -not $Apply) {
  throw "MIGRATION_APPLY_REQUIRED action=$Action"
}

$sources = Get-LegacyMigrationSources
if ($Action -in @('Plan','Stage') -and $sources.Count -eq 0) {
  $empty = [pscustomobject]@{ok=$true;schema='super-brain.legacy-migration.v1';action=$Action.ToLowerInvariant();applied=$false;sourceCount=0;plannedCount=0;quarantinedCount=0;ignoredCount=0;guard='No legacy source roots were found. Nothing was scanned, copied, deleted, or switched.'}
  Write-MigrationResult $empty
  exit 0
}

switch ($Action) {
  'Plan' {
    Write-MigrationResult (Invoke-MigrationControl 'migration-plan' ([ordered]@{sourceRoots=@($sources)}))
  }
  'Stage' {
    $plan = Invoke-MigrationControl 'migration-plan' ([ordered]@{sourceRoots=@($sources)})
    $request = [ordered]@{sourceRoots=@($sources);expectedPlanFingerprint=[string]$plan.planFingerprint}
    if (-not [string]::IsNullOrWhiteSpace($EpochId)) { $request.epochId=$EpochId }
    Write-MigrationResult (Invoke-MigrationControl 'migration-stage' $request)
  }
  'Status' {
    if ([string]::IsNullOrWhiteSpace($EpochId)) { throw 'MIGRATION_EPOCH_REQUIRED action=Status' }
    Write-MigrationResult (Invoke-MigrationControl 'migration-status' ([ordered]@{epochId=$EpochId}))
  }
  default {
    if ([string]::IsNullOrWhiteSpace($EpochId)) { throw "MIGRATION_EPOCH_REQUIRED action=$Action" }
    $status = Invoke-MigrationControl 'migration-status' ([ordered]@{epochId=$EpochId})
    $request = [ordered]@{epochId=$EpochId;expectedManifestHash=[string]$status.manifestHash}
    if ($Action -in @('Cutover','RollbackAdapter')) { $request.adapterName=$AdapterName }
    $controlAction = switch ($Action) {
      'Import' { 'migration-import' }
      'Verify' { 'migration-verify' }
      'Cutover' { 'migration-cutover' }
      'RollbackAdapter' { 'migration-rollback-adapter' }
    }
    Write-MigrationResult (Invoke-MigrationControl $controlAction $request)
  }
}
