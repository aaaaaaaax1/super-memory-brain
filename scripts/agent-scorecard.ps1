param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$indexPath = Join-Path $workspace 'team-task-index.json'
$templatesPath = Join-Path $workspace 'agent-teams.json'
if (-not (Test-Path $indexPath)) { & (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null }
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
$templates = (Get-Content -LiteralPath $templatesPath -Raw -Encoding UTF8 | ConvertFrom-Json).templates

$cards = @()
foreach ($template in @($templates)) {
  $items = @($index.recent | Where-Object { $_.teamTemplateId -eq $template.id })
  $verified = @($items | Where-Object { $_.decisionStatus -eq 'verified' -and $_.verificationStatus -eq 'verified' })
  $risk = @($items | Where-Object { $_.unreviewedCodeChangeCount -gt 0 -or $_.driftRiskCount -gt 0 })
  $usage = $items.Count
  $verifiedRate = if ($usage -gt 0) { [math]::Round($verified.Count / $usage, 3) } else { $null }
  $score = if ($usage -eq 0) { 0.5 } else { [math]::Round((0.65 * $verifiedRate) + (0.25 * [Math]::Min($usage / 3, 1)) - (0.2 * [Math]::Min($risk.Count, 1)), 3) }
  $cards += [pscustomobject]@{
    id = $template.id
    name = $template.name
    purpose = $template.purpose
    roles = @($template.roles)
    triggers = @($template.triggers)
    usageCount = $usage
    verifiedCount = $verified.Count
    riskCount = $risk.Count
    verifiedRate = $verifiedRate
    score = $score
    recommendation = if ($risk.Count -gt 0) { 'Use only with review gate.' } elseif ($usage -eq 0) { 'Available but needs evidence from future tasks.' } elseif ($score -ge 0.75) { 'Preferred for matching triggers.' } else { 'Usable with evidence checks.' }
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  cardCount = $cards.Count
  cards = @($cards | Sort-Object score -Descending)
  evidence = @('agent-teams.json','team-task-index.json','dispatch-learning.ps1')
}

if ($Json) { $result | ConvertTo-Json -Depth 10 } else { foreach ($card in @($result.cards)) { Write-Host "AGENT_SCORECARD id=$($card.id) score=$($card.score) usage=$($card.usageCount) recommendation=$($card.recommendation)" } }
exit 0
