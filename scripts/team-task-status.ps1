param(
  [string]$TeamTaskId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'
$indexPath = Join-Path $workspace 'team-task-index.json'

if ($TeamTaskId) {
  $path = Join-Path $teamRoot "$TeamTaskId.json"
  if (-not (Test-Path $path)) { throw "Team task not found: $TeamTaskId" }
  $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $delegations = @($record.delegations)
  $result = [pscustomobject]@{
    ok = $true
    mode = 'single'
    teamTaskId = $record.teamTaskId
    userGoal = $record.userGoal
    dispatchLevel = $record.dispatchLevel
    teamTemplateId = if ($record.teamTemplate) { $record.teamTemplate.id } else { $null }
    teamTemplateName = if ($record.teamTemplate) { $record.teamTemplate.name } else { $null }
    roles = if ($record.teamTemplate) { @($record.teamTemplate.roles) } else { @() }
    delegationCount = @($delegations).Count
    codeCapableDelegationCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' }).Count
    unreviewedCodeChangeCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' -and (-not $_.review -or $_.review.commanderReviewed -ne $true) }).Count
    driftRiskCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' -and $_.driftGuard -and $_.driftGuard.status -eq 'out_of_scope' }).Count
    decisionStatus = $record.commanderDecision.status
    verificationStatus = $record.verification.status
    updatedAt = $record.updatedAt
    path = $path
  }
} else {
  if (-not (Test-Path $indexPath)) { & (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null }
  $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $result = [pscustomobject]@{
    ok = $true
    mode = 'index'
    count = $index.count
    updatedAt = $index.updatedAt
    recent = @($index.recent | Select-Object -First 5)
    path = $indexPath
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  if ($result.mode -eq 'single') {
    Write-Host "TEAM_TASK_STATUS id=$($result.teamTaskId) level=$($result.dispatchLevel) template=$($result.teamTemplateName) delegations=$($result.delegationCount) codeCapable=$($result.codeCapableDelegationCount) unreviewed=$($result.unreviewedCodeChangeCount) drift=$($result.driftRiskCount) decision=$($result.decisionStatus) verification=$($result.verificationStatus)"
  } else {
    Write-Host "TEAM_TASK_STATUS count=$($result.count) updatedAt=$($result.updatedAt)"
    foreach ($item in @($result.recent)) { Write-Host "TEAM_TASK_RECENT id=$($item.teamTaskId) level=$($item.dispatchLevel) template=$($item.teamTemplateName) decision=$($item.decisionStatus) goal=$($item.userGoal)" }
  }
}
exit 0
