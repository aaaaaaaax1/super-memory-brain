param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'
$indexPath = Join-Path $workspace 'team-task-index.json'
New-Item -ItemType Directory -Force -Path $teamRoot | Out-Null

$items = @()
foreach ($file in @(Get-ChildItem -LiteralPath $teamRoot -Filter 'team-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
  try {
    $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $delegations = @($record.delegations)
    $codeCapableCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' }).Count
    $unreviewedCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' -and (-not $_.review -or $_.review.commanderReviewed -ne $true) }).Count
    $driftCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' -and $_.driftGuard -and $_.driftGuard.status -eq 'out_of_scope' }).Count
    $items += [pscustomobject]@{
      teamTaskId = $record.teamTaskId
      userGoal = $record.userGoal
      dispatchLevel = $record.dispatchLevel
      teamTemplateId = if ($record.teamTemplate) { $record.teamTemplate.id } else { $null }
      teamTemplateName = if ($record.teamTemplate) { $record.teamTemplate.name } else { $null }
      roleCount = if ($record.teamTemplate) { @($record.teamTemplate.roles).Count } else { 0 }
      codeCapableDelegationCount = $codeCapableCount
      unreviewedCodeChangeCount = $unreviewedCount
      driftRiskCount = $driftCount
      decisionStatus = $record.commanderDecision.status
      verificationStatus = $record.verification.status
      updatedAt = $record.updatedAt
      path = $file.FullName
    }
  } catch {}
}

$index = [pscustomobject]@{
  schemaVersion = '1.0'
  updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  count = @($items).Count
  recent = @($items | Select-Object -First 20)
}

Write-JsonUtf8NoBom $indexPath $index 8

if ($Json) { $index | ConvertTo-Json -Depth 8 } else { Write-Host "TEAM_TASK_INDEX_OK count=$($index.count) path=$indexPath" }
exit 0
