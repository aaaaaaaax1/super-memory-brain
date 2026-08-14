param(
  [string]$Query = '',
  [int]$TopK = 5,
  [switch]$IncludeDelegations,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'

function Test-TeamTaskMatch([object]$Record, [string]$Needle) {
  if ([string]::IsNullOrWhiteSpace($Needle)) { return $true }
  $normalizedNeedle = $Needle.ToLowerInvariant()
  $keywords = @($normalizedNeedle)
  if ($normalizedNeedle -match 'subagent|agent team|team memory|review gate|drift guard|commander review|team-task|authorization|roadmap|road map|0\.5\.20|0\.5\.21|0\.5\.22|0\.5\.23') {
    $keywords += @('subagent','agent team','team memory','review gate','drift guard','commander review','team-task','authorization','roadmap','template','retrieval','commander','code-capable')
  }
  $haystackParts = @(
    $Record.teamTaskId,
    $Record.userGoal,
    $Record.dispatchLevel,
    $Record.dispatchReason,
    $Record.commanderDecision.status,
    $Record.commanderDecision.reason,
    $Record.verification.status,
    $Record.verification.evidence,
    @($Record.delegations | ForEach-Object { $_.role; $_.task; $_.status; $_.findings; $_.evidence; $_.recommendation })
  )
  if ($Record.teamTemplate) { $haystackParts += @($Record.teamTemplate.id, $Record.teamTemplate.name, $Record.teamTemplate.roles) }
  $haystack = ($haystackParts -join ' ').ToLowerInvariant()
  foreach ($keyword in $keywords) {
    if (-not [string]::IsNullOrWhiteSpace($keyword) -and $haystack.Contains($keyword)) { return $true }
  }
  return $false
}

function Get-MatchScore([object]$Record, [string]$Needle) {
  if ([string]::IsNullOrWhiteSpace($Needle)) { return 1.0 }
  $score = 0.0
  $lower = $Needle.ToLowerInvariant()
  foreach ($field in @($Record.teamTaskId, $Record.userGoal, $Record.dispatchLevel, $Record.commanderDecision.reason)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$field) -and ([string]$field).ToLowerInvariant().Contains($lower)) { $score += 0.35 }
  }
  foreach ($delegation in @($Record.delegations)) {
    $text = @($delegation.role, $delegation.task, $delegation.findings, $delegation.evidence, $delegation.recommendation) -join ' '
    if ($text.ToLowerInvariant().Contains($lower)) { $score += 0.2 }
  }
  if ($Record.verification.status -eq 'verified') { $score += 0.1 }
  if ($Record.commanderDecision.status -eq 'verified') { $score += 0.1 }
  return [Math]::Round([Math]::Min($score, 1.0), 3)
}

$items = @()
foreach ($file in @(Get-ChildItem -LiteralPath $teamRoot -Filter 'team-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
  try { $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  if (-not (Test-TeamTaskMatch $record $Query)) { continue }
  $delegations = @($record.delegations)
  $teamTemplateId = $null
  $teamTemplateName = $null
  if ($record.teamTemplate) {
    $teamTemplateId = $record.teamTemplate.id
    $teamTemplateName = $record.teamTemplate.name
  }
  $item = [ordered]@{
    teamTaskId = $record.teamTaskId
    userGoal = $record.userGoal
    dispatchLevel = $record.dispatchLevel
    dispatchReason = @($record.dispatchReason)
    teamTemplateId = $teamTemplateId
    teamTemplateName = $teamTemplateName
    codeCapableDelegationCount = @($delegations | Where-Object { $_.mode -eq 'code-capable' }).Count
    commanderDecisionStatus = $record.commanderDecision.status
    verificationStatus = $record.verification.status
    memoryAdmission = $record.memoryAdmission.reason
    updatedAt = $record.updatedAt
    score = Get-MatchScore $record $Query
    path = $file.FullName
  }
  if ($IncludeDelegations) {
    $item.delegations = @($delegations | ForEach-Object {
      $reviewResult = $null
      $driftStatus = $null
      if ($_.review) { $reviewResult = $_.review.result }
      if ($_.driftGuard) { $driftStatus = $_.driftGuard.status }
      [pscustomobject]@{
        role = $_.role
        task = $_.task
        status = $_.status
        mode = $_.mode
        findings = @($_.findings | Select-Object -First 3)
        evidence = @($_.evidence | Select-Object -First 5)
        recommendation = $_.recommendation
        reviewResult = $reviewResult
        driftStatus = $driftStatus
      }
    })
  }
  $items += [pscustomobject]$item
}

$items = @($items | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'updatedAt'; Descending = $true } | Select-Object -First $TopK)
$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  query = $Query
  topK = $TopK
  count = @($items).Count
  results = @($items)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  Write-Host "TEAM_MEMORY_RETRIEVAL query=$Query count=$($result.count)"
  foreach ($item in @($items)) { Write-Host "TEAM_MEMORY_RESULT id=$($item.teamTaskId) score=$($item.score) decision=$($item.commanderDecisionStatus) verification=$($item.verificationStatus) goal=$($item.userGoal)" }
}
exit 0
