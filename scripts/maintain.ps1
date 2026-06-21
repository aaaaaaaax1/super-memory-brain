param(
  [switch]$Json,
  [switch]$ApplySafe,
  [switch]$ApplyConfirmed,
  [int]$BackupKeep = 10,
  [int]$BackupMaxAgeDays = 0
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot

if ($ApplySafe -and $ApplyConfirmed) {
  Write-Host 'MAINTAIN_FAILED reason=ApplySafe_and_ApplyConfirmed_are_mutually_exclusive'
  exit 1
}

$steps = @()
function Add-Step([string]$Name, [string]$Mode, [bool]$Ok, [int]$ExitCode, [string[]]$Output) {
  $script:steps += [pscustomobject]@{
    name = $Name
    mode = $Mode
    ok = $Ok
    exitCode = $ExitCode
    output = @($Output)
  }
}

function Run-Step([string]$Name, [string]$Mode, [scriptblock]$Command) {
  Write-Host "MAINTAIN_RUN mode=$Mode step=$Name"
  $output = @(& $Command *>&1 | ForEach-Object { $_.ToString() })
  $exitCode = $LASTEXITCODE
  $ok = ($exitCode -eq 0)
  Add-Step $Name $Mode $ok $exitCode $output
  foreach ($line in $output) { Write-Host $line }
  return $ok
}

function Run-Step-Quiet([string]$Name, [string]$Mode, [scriptblock]$Command) {
  $output = @(& $Command *>&1 | ForEach-Object { $_.ToString() })
  $exitCode = $LASTEXITCODE
  $ok = ($exitCode -eq 0)
  Add-Step $Name $Mode $ok $exitCode $output
  return $ok
}

$mode = 'Plan'
if ($ApplySafe) { $mode = 'ApplySafe' }
if ($ApplyConfirmed) { $mode = 'ApplyConfirmed' }

if ($Json) {
  $runner = ${function:Run-Step-Quiet}
} else {
  $runner = ${function:Run-Step}
  Write-Host "MAINTAIN_START mode=$mode package=$Root"
}

$ok = $true

if (-not $Json) { Write-Host 'MAINTAIN_PLAN_READ_ONLY' }
if (-not (& $runner 'summary' 'read' { & (Join-Path $PSScriptRoot 'summary.ps1') })) { $ok = $false }
if (-not (& $runner 'doctor' 'read' { & (Join-Path $PSScriptRoot 'doctor.ps1') })) { $ok = $false }
if (-not (& $runner 'memory-health' 'read' { & (Join-Path $PSScriptRoot 'memory-health.ps1') })) { $ok = $false }
if (-not (& $runner 'compact-report' 'read' { & (Join-Path $PSScriptRoot 'compact-report.ps1') })) { $ok = $false }
if (-not (& $runner 'encoding-check' 'read' { & (Join-Path $PSScriptRoot 'encoding-check.ps1') })) { $ok = $false }
if (-not (& $runner 'graph-normalize' 'read' { & (Join-Path $PSScriptRoot 'graph-normalize.ps1') })) { $ok = $false }
if (-not (& $runner 'backup-retention' 'read' { & (Join-Path $PSScriptRoot 'backup-retention.ps1') -Keep $BackupKeep -MaxAgeDays $BackupMaxAgeDays })) { $ok = $false }

if ($ApplySafe) {
  if (-not $Json) { Write-Host 'MAINTAIN_APPLY_SAFE' }
  if (-not (& $runner 'encoding-check-fix' 'safe' { & (Join-Path $PSScriptRoot 'encoding-check.ps1') -Fix })) { $ok = $false }
  if (-not (& $runner 'graph-normalize-fix' 'safe' { & (Join-Path $PSScriptRoot 'graph-normalize.ps1') -Fix })) { $ok = $false }
  if (-not (& $runner 'update-state' 'safe' { & (Join-Path $PSScriptRoot 'update-state.ps1') })) { $ok = $false }
  if (-not (& $runner 'compact-apply-whatif' 'safe' { & (Join-Path $PSScriptRoot 'compact-apply.ps1') -WhatIfOnly })) { $ok = $false }
}

if ($ApplyConfirmed) {
  if (-not $Json) { Write-Host 'MAINTAIN_APPLY_CONFIRMED' }
  if (-not (& $runner 'repair-hook' 'confirmed' { & (Join-Path $PSScriptRoot 'repair-hook.ps1') -PackageRoot $Root })) { $ok = $false }
  if (-not (& $runner 'compact-apply-force' 'confirmed' { & (Join-Path $PSScriptRoot 'compact-apply.ps1') -Force })) { $ok = $false }
  if (-not (& $runner 'backup-retention-apply' 'confirmed' { & (Join-Path $PSScriptRoot 'backup-retention.ps1') -Keep $BackupKeep -MaxAgeDays $BackupMaxAgeDays -Apply })) { $ok = $false }
  if (-not (& $runner 'verify-package' 'confirmed' { & (Join-Path $PSScriptRoot 'verify-package.ps1') -Integration })) { $ok = $false }
}

$safeActions = @('encoding-check.ps1 -Fix','graph-normalize.ps1 -Fix','update-state.ps1','compact-apply.ps1 -WhatIfOnly')
$confirmedActions = @('repair-hook.ps1','compact-apply.ps1 -Force','backup-retention.ps1 -Apply','verify-package.ps1 -Integration')
$result = [pscustomobject]@{
  ok = $ok
  mode = $mode
  packageRoot = $Root
  safeActions = $safeActions
  confirmedActions = $confirmedActions
  steps = $steps
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  $status = if ($ok) { 'OK' } else { 'NEEDS_ACTION' }
  Write-Host "MAINTAIN_PLAN status=$status mode=$mode safeActions=$($safeActions.Count) confirmedActions=$($confirmedActions.Count)"
  if ($ApplySafe) {
    if ($ok) { Write-Host 'MAINTAIN_APPLY_SAFE_OK' } else { Write-Host 'MAINTAIN_APPLY_SAFE_FAILED' }
  } elseif ($ApplyConfirmed) {
    if ($ok) { Write-Host 'MAINTAIN_APPLY_CONFIRMED_OK' } else { Write-Host 'MAINTAIN_APPLY_CONFIRMED_FAILED' }
  } else {
    if ($ok) { Write-Host 'MAINTAIN_OK' } else { Write-Host 'MAINTAIN_NEEDS_ACTION' }
  }
}

if (-not $ok) { exit 1 }
exit 0
