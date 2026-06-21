param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'

$codeCapable = 0
$unreviewed = 0
$driftRisk = 0
$blockedScope = 0
$missingAuth = 0
$recentRisky = @()

foreach ($file in @(Get-ChildItem -LiteralPath $teamRoot -Filter 'team-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
  try { $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  $delegations = @($record.delegations)
  for ($i = 0; $i -lt $delegations.Count; $i++) {
    $delegation = $delegations[$i]
    if ($delegation.mode -ne 'code-capable') { continue }
    $codeCapable += 1
    $riskReasons = @()
    if (-not $delegation.authorization) { $missingAuth += 1; $riskReasons += 'missing_authorization' }
    elseif (@($delegation.authorization.allowedFiles).Count -eq 0 -or @($delegation.authorization.forbiddenFiles).Count -eq 0 -or @($delegation.authorization.verificationCommands).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$delegation.authorization.rollback)) {
      $missingAuth += 1
      $riskReasons += 'incomplete_authorization'
    }
    if (-not $delegation.review -or $delegation.review.commanderReviewed -ne $true) { $unreviewed += 1; $riskReasons += 'unreviewed' }
    if ($delegation.driftGuard -and $delegation.driftGuard.status -eq 'out_of_scope') { $driftRisk += 1; $riskReasons += 'out_of_scope' }
    if ($delegation.driftGuard -and $delegation.driftGuard.status -eq 'blocked_scope_expansion_requested') { $blockedScope += 1; $riskReasons += 'blocked_scope_expansion_requested' }
    if ($riskReasons.Count -gt 0) {
      $recentRisky += [pscustomobject]@{
        teamTaskId = $record.teamTaskId
        delegationIndex = $i
        role = $delegation.role
        task = $delegation.task
        risks = @($riskReasons)
        path = $file.FullName
      }
    }
  }
}

$result = [pscustomobject]@{
  ok = ($unreviewed -eq 0 -and $driftRisk -eq 0 -and $missingAuth -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  codeCapableDelegationCount = $codeCapable
  unreviewedCodeChangeCount = $unreviewed
  driftRiskCount = $driftRisk
  blockedScopeExpansionCount = $blockedScope
  authorizationMissingCount = $missingAuth
  recentRisky = @($recentRisky | Select-Object -First 10)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "TEAM_TASK_AUDIT codeCapable=$codeCapable unreviewed=$unreviewed drift=$driftRisk missingAuth=$missingAuth blocked=$blockedScope"
  foreach ($risk in @($result.recentRisky)) { Write-Host "TEAM_TASK_AUDIT_RISK id=$($risk.teamTaskId) index=$($risk.delegationIndex) role=$($risk.role) risks=$(@($risk.risks) -join ',')" }
}
if (-not $result.ok) { exit 1 }
exit 0
