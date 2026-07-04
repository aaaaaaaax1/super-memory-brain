param(
  [ValidateSet('Capture','Propose','Validate','List')]
  [string]$Mode = 'List',
  [string]$Title = '',
  [string]$Trigger = '',
  [string]$Expected = '',
  [string]$Actual = '',
  [string]$Evidence = '',
  [string]$Affected = '',
  [string]$Proposal = '',
  [string]$ProposalId = '',
  [switch]$Pass,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$evolutionRoot = Join-Path $workspace 'skill-evolution'
$failureRoot = Join-Path $evolutionRoot 'failures'
$proposalRoot = Join-Path $evolutionRoot 'proposals'
$indexPath = Join-Path $evolutionRoot 'index.json'
New-Item -ItemType Directory -Force -Path $failureRoot,$proposalRoot | Out-Null

function New-EvolutionId([string]$Prefix) {
  return ('{0}-{1}' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Read-Index {
  if (Test-Path $indexPath) {
    try { return Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ ok=$true; updatedAt=''; failures=@(); proposals=@() }
}

function Write-Index([object]$Index) {
  $Index.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-JsonUtf8NoBom $indexPath $Index 10
}

function Sanitize-Text([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $clean = [string]$Text
  $secretPattern = "(?i)(api[_-]?key|password|token|cookie|secret)\s*[:=]\s*\S+"
  $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, $secretPattern, '$1=<redacted>')
  if ($clean.Length -gt 1200) { $clean = $clean.Substring(0, 1200) + '...' }
  return $clean
}

$index = Read-Index

if ($Mode -eq 'Capture') {
  $id = New-EvolutionId 'FAIL'
  $item = [pscustomobject]@{
    id = $id
    status = 'captured'
    title = (Sanitize-Text $Title)
    trigger = (Sanitize-Text $Trigger)
    expected = (Sanitize-Text $Expected)
    actual = (Sanitize-Text $Actual)
    evidence = (Sanitize-Text $Evidence)
    affected = (Sanitize-Text $Affected)
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    privacy = 'redacted; compact evidence only; no raw transcript harvesting'
  }
  $path = Join-Path $failureRoot ($id + '.json')
  Write-JsonUtf8NoBom $path $item 8
  $index.failures = @($index.failures) + @([pscustomobject]@{ id=$id; title=$item.title; path=$path; status='captured' })
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$id; path=$path; status='captured'; next='Create a bounded proposal with -Mode Propose.' }
}
elseif ($Mode -eq 'Propose') {
  $id = if ([string]::IsNullOrWhiteSpace($ProposalId)) { New-EvolutionId 'PROP' } else { $ProposalId }
  $item = [pscustomobject]@{
    id = $id
    status = 'staged'
    title = (Sanitize-Text $Title)
    affected = (Sanitize-Text $Affected)
    proposal = (Sanitize-Text $Proposal)
    validationGate = [pscustomobject]@{
      failureFixed = $false
      criticalBehaviorPreserved = $false
      noExtraVerbosity = $false
      noPrivacyRegression = $false
      noBroadAutoMutation = $false
    }
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    adoption = 'Requires user approval or an already-approved rule-edit task before mutating skill files.'
  }
  $path = Join-Path $proposalRoot ($id + '.json')
  Write-JsonUtf8NoBom $path $item 10
  $index.proposals = @($index.proposals) + @([pscustomobject]@{ id=$id; title=$item.title; path=$path; status='staged' })
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$id; path=$path; status='staged'; next='Run -Mode Validate after evidence exists; apply only after approval.' }
}
elseif ($Mode -eq 'Validate') {
  if ([string]::IsNullOrWhiteSpace($ProposalId)) { throw 'ProposalId is required for Validate.' }
  $path = Join-Path $proposalRoot ($ProposalId + '.json')
  if (-not (Test-Path $path)) { throw "Proposal not found: $ProposalId" }
  $item = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $item.status = if ($Pass) { 'validated' } else { 'failed' }
  $item.validatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $item.validationEvidence = (Sanitize-Text $Evidence)
  if ($Pass) {
    $item.validationGate.failureFixed = $true
    $item.validationGate.criticalBehaviorPreserved = $true
    $item.validationGate.noExtraVerbosity = $true
    $item.validationGate.noPrivacyRegression = $true
    $item.validationGate.noBroadAutoMutation = $true
  }
  Write-JsonUtf8NoBom $path $item 10
  foreach ($p in @($index.proposals)) { if ($p.id -eq $ProposalId) { $p.status = $item.status } }
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$ProposalId; path=$path; status=$item.status }
}
else {
  $result = [pscustomobject]@{
    ok = $true
    mode = $Mode
    indexPath = $indexPath
    failureCount = @($index.failures).Count
    proposalCount = @($index.proposals).Count
    recentFailures = @($index.failures | Select-Object -Last 5)
    recentProposals = @($index.proposals | Select-Object -Last 5)
  }
}

if ($Json) { $result | ConvertTo-Json -Depth 10 } else {
  Write-Host "SKILL_EVOLUTION_$($Mode.ToUpperInvariant()) ok=$($result.ok) status=$($result.status) id=$($result.id)"
  if ($result.path) { Write-Host "PATH $($result.path)" }
}
exit 0
