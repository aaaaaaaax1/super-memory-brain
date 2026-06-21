param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$indexPath = Join-Path $workspace 'team-task-index.json'

if (-not (Test-Path $indexPath)) { & (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null }
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($index.recent)

$verified = @($items | Where-Object { $_.decisionStatus -eq 'verified' -and $_.verificationStatus -eq 'verified' })
$blocked = @($items | Where-Object { $_.unreviewedCodeChangeCount -gt 0 -or $_.driftRiskCount -gt 0 -or $_.decisionStatus -notin @('verified','accepted') -or $_.verificationStatus -notin @('verified','passed') })
$templateGroups = @($items | Group-Object -Property teamTemplateId | ForEach-Object {
  $templateId = if ([string]::IsNullOrWhiteSpace([string]$_.Name)) { 'none' } else { [string]$_.Name }
  $groupItems = @($_.Group)
  $groupVerified = @($groupItems | Where-Object { $_.decisionStatus -eq 'verified' -and $_.verificationStatus -eq 'verified' })
  [pscustomobject]@{
    templateId = $templateId
    count = $groupItems.Count
    verifiedCount = $groupVerified.Count
    verifiedRate = if ($groupItems.Count -gt 0) { [math]::Round($groupVerified.Count / $groupItems.Count, 3) } else { 0 }
  }
})
$levelGroups = @($items | Group-Object -Property dispatchLevel | ForEach-Object {
  [pscustomobject]@{ dispatchLevel = [string]$_.Name; count = @($_.Group).Count }
})

$recommendations = @()
if ($items.Count -eq 0) {
  $recommendations += 'No team-task history yet; keep direct routing for simple tasks and require explicit evidence before team dispatch.'
} else {
  if (@($items | Where-Object { $_.dispatchLevel -eq 'review_board' }).Count -gt 0 -and $blocked.Count -eq 0) {
    $recommendations += 'Review-board dispatch is stable in current history; keep it for architecture, logic-safety, memory-sensitive, and repeated-failure work.'
  }
  if (@($items | Where-Object { $_.teamTemplateId -eq 'review-team' }).Count -gt 0) {
    $recommendations += 'Review Team has verified evidence in history; prefer it for code-capable or high-risk coordination.'
  }
  if (@($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.teamTemplateId) }).Count -gt 0) {
    $recommendations += 'Older tasks without templates exist; use template selection for new non-direct team tasks to improve role clarity.'
  }
  if ($blocked.Count -gt 0) {
    $recommendations += 'History contains unresolved or risky team tasks; require review gate before accepting future code-capable delegation.'
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  teamTaskCount = $items.Count
  verifiedCount = $verified.Count
  blockedCount = $blocked.Count
  templateStats = @($templateGroups)
  dispatchLevelStats = @($levelGroups)
  recommendations = @($recommendations)
  evidence = @('team-task-index.json','team-task-status.ps1','team-template-select.ps1','team-task-review-gate.ps1')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "DISPATCH_LEARNING taskCount=$($result.teamTaskCount) verified=$($result.verifiedCount) blocked=$($result.blockedCount)"
  foreach ($item in @($result.recommendations)) { Write-Host "RECOMMEND $item" }
}
exit 0
