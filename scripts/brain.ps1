param(
  [ValidateSet('status','next','intent','release','scorecard','dispatch','optimize','ci','help')]
  [string]$Command = 'status',
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'

function Convert-BrainJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { throw "No JSON output from $ScriptName" }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}

$inputText = (($Text -join ' ').Trim())
$result = $null
switch ($Command) {
  'status' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'health-summary.ps1') -Json 6>$null) 'health-summary.ps1' }
  'next' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'smart-next.ps1') $inputText -Json 6>$null) 'smart-next.ps1' }
  'intent' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') $inputText -Json 6>$null) 'intent-router.ps1' }
  'release' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'release-readiness.ps1') -Json 6>$null) 'release-readiness.ps1' }
  'scorecard' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'agent-scorecard.ps1') -Json 6>$null) 'agent-scorecard.ps1' }
  'dispatch' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'dispatch-learning.ps1') -Json 6>$null) 'dispatch-learning.ps1' }
  'optimize' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'optimize-advisor.ps1') -Json 6>$null) 'optimize-advisor.ps1' }
  'ci' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'health-summary.ps1') -Json 6>$null) 'health-summary.ps1'; $result | Add-Member -NotePropertyName commandHint -NotePropertyValue 'Run scripts\ci.ps1 for full CI.' -Force }
  'help' {
    $result = [pscustomobject]@{
      ok = $true
      commands = @('status','next','intent','release','scorecard','dispatch','optimize','ci','help')
      examples = @('scripts\brain.ps1 status','scripts\brain.ps1 next 继续','scripts\brain.ps1 intent 发包','scripts\brain.ps1 release','scripts\brain.ps1 optimize')
    }
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  if ($Command -eq 'status') {
    Write-Host "BRAIN status version=$($result.version) ready=$($result.ready) risks=$(@($result.risks).Count) next=$($result.nextAction)"
  } elseif ($Command -eq 'next') {
    Write-Host "BRAIN next intent=$($result.intent) action=$($result.nextAction) blockers=$(@($result.blockers).Count)"
  } elseif ($Command -eq 'intent') {
    Write-Host "BRAIN intent=$($result.intent) confidence=$($result.confidence) action=$($result.recommendedAction)"
  } elseif ($Command -eq 'release') {
    Write-Host "BRAIN releaseReady=$($result.ok) version=$($result.version) risks=$(@($result.risks).Count) destination=$($result.shareDestination)"
  } elseif ($Command -eq 'scorecard') {
    foreach ($card in @($result.cards)) { Write-Host "BRAIN scorecard id=$($card.id) score=$($card.score) recommendation=$($card.recommendation)" }
  } elseif ($Command -eq 'dispatch') {
    Write-Host "BRAIN dispatch tasks=$($result.teamTaskCount) verified=$($result.verifiedCount) blocked=$($result.blockedCount)"
    foreach ($item in @($result.recommendations)) { Write-Host "BRAIN recommend $item" }
  } elseif ($Command -eq 'optimize') {
    Write-Host "BRAIN optimize priority=$($result.priority) advice=$($result.adviceCount) ok=$($result.ok)"
    foreach ($item in @($result.topAdvice)) { Write-Host "BRAIN optimize $($item.priority) $($item.code) $($item.title)" }
  } else {
    $result | ConvertTo-Json -Depth 8
  }
}
if ($result.ok -eq $false) { exit 1 }
exit 0
