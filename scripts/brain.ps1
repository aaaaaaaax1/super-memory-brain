param(
  [ValidateSet('status','next','intent','release','scorecard','dispatch','optimize','technology','ci','skills','capability','extensions','help')]
  [string]$Command = 'status',
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$AllowActiveCheckpoint,
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
  'status' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'health-summary.ps1') -Json -AllowActiveCheckpoint:$AllowActiveCheckpoint 6>$null) 'health-summary.ps1' }
  'next' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'smart-next.ps1') $inputText -Json 6>$null) 'smart-next.ps1' }
  'intent' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $inputText -Json 6>$null) 'intent-router.ps1' }
  'release' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'release-readiness.ps1') -Json 6>$null) 'release-readiness.ps1' }
  'scorecard' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'agent-scorecard.ps1') -Json 6>$null) 'agent-scorecard.ps1' }
  'dispatch' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'dispatch-learning.ps1') -Json 6>$null) 'dispatch-learning.ps1' }
  'optimize' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'optimize-advisor.ps1') -Json 6>$null) 'optimize-advisor.ps1' }
  'technology' {
    if ([string]::IsNullOrWhiteSpace($inputText)) { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'technology-decision.ps1') -Action Questionnaire -Json 6>$null) 'technology-decision.ps1' }
    elseif ($inputText -eq 'validate') { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'technology-decision.ps1') -Action Validate -Json 6>$null) 'technology-decision.ps1' }
    else { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'technology-decision.ps1') -Action Catalog -Query $inputText -Json 6>$null) 'technology-decision.ps1' }
  }
  'ci' { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'health-summary.ps1') -Json -AllowActiveCheckpoint:$AllowActiveCheckpoint 6>$null) 'health-summary.ps1'; $result | Add-Member -NotePropertyName commandHint -NotePropertyValue 'Run scripts\ci.ps1 for full CI.' -Force }
  'skills' {
    if([string]::IsNullOrWhiteSpace($inputText)){ $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -List -TopK 200 -Json 6>$null) 'skill-capability-map.ps1' }
    else { $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -TopK 24 -Json 6>$null) 'skill-capability-map.ps1' }
  }
  'capability' {
    $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Name $inputText -Detail -TopK 12 -Json 6>$null) 'skill-capability-map.ps1'
  }
  'extensions' {
    $result = Convert-BrainJson @(& (Join-Path $PSScriptRoot 'extension-ingest.ps1') -Action List -Json 6>$null) 'extension-ingest.ps1'
  }
  'help' {
    $result = [pscustomobject]@{
      ok = $true
      commands = @('status','next','intent','release','scorecard','dispatch','optimize','technology','ci','skills','capability','extensions','help')
      examples = @('scripts\brain.ps1 status','scripts\brain.ps1 next continue','scripts\brain.ps1 intent release','scripts\brain.ps1 release','scripts\brain.ps1 optimize','scripts\brain.ps1 technology','scripts\brain.ps1 technology database','scripts\brain.ps1 skills','scripts\brain.ps1 skills browser','scripts\brain.ps1 capability browser-act','scripts\brain.ps1 extensions')
      guard = 'Skills are visible for inspection but ORC still routes by intent/capability; do not force manual skill menu usage.'
    }
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 14
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
  } elseif ($Command -eq 'technology') {
    Write-Host "BRAIN technology action=$($result.action) ok=$($result.ok)"
  } elseif ($Command -eq 'skills') {
    Write-Host "BRAIN skills count=$($result.count) total=$($result.totalKnown) view=$($result.view)"
    foreach($cap in @($result.capabilities | Select-Object -First 30)){ Write-Host "BRAIN skill name=$($cap.name) role=$($cap.role) category=$($cap.category)" }
  } elseif ($Command -eq 'capability') {
    foreach($cap in @($result.capabilities)){ Write-Host "BRAIN capability name=$($cap.name) role=$($cap.role) category=$($cap.category) triggers=$((@($cap.triggers)|Select-Object -First 6)-join ',')" }
  } elseif ($Command -eq 'extensions') {
    Write-Host "BRAIN extensions count=$($result.count)"
    foreach($ext in @($result.extensions)){ Write-Host "BRAIN extension id=$($ext.id) skills=$($ext.skillCount) defaultEnabled=$($ext.defaultEnabled)" }
  } else {
    $result | ConvertTo-Json -Depth 8
  }
}
if ($result.ok -eq $false) { exit 1 }
exit 0
