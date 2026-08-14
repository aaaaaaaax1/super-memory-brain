param(
  [string]$Query = '',
  [string]$Scope = '',
  [int]$MaxConstraints = 6,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-accepted-constraints-preflight.json'
$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$preflightPolicy = $policy.preflight
if ($MaxConstraints -le 0) { $MaxConstraints = if ($preflightPolicy -and $preflightPolicy.maxConstraints) { [int]$preflightPolicy.maxConstraints } else { 6 } }
$maxClaimChars = if ($preflightPolicy -and $preflightPolicy.maxClaimChars) { [int]$preflightPolicy.maxClaimChars } else { 160 }

function Limit-Text([string]$Text, [int]$Max = 160) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim() -replace '\s+', ' '
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Get-StableId([string]$Prefix, [string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    return "${Prefix}:$hash"
  } finally { $sha.Dispose() }
}

function Add-Constraint([System.Collections.ArrayList]$List, [string]$Kind, [string]$Claim, [string]$SourceType, [string]$Status, [double]$Confidence, [string]$Source = '') {
  $short = Limit-Text $Claim $maxClaimChars
  if ([string]::IsNullOrWhiteSpace($short)) { return }
  foreach ($existing in @($List)) {
    if ([string]$existing.claim -eq $short) { return }
  }
  if ($List.Count -ge $MaxConstraints) { return }
  [void]$List.Add([pscustomobject]@{
    id = Get-StableId $Kind ($short + '|' + $SourceType + '|' + $Source)
    kind = $Kind
    claim = $short
    sourceType = $SourceType
    source = Limit-Text $Source 180
    status = $Status
    confidence = [Math]::Round($Confidence, 4)
    hard = $true
  })
}

$constraints = [System.Collections.ArrayList]::new()

try {
  $decisionArgs = @('-TopK', $MaxConstraints, '-MaxTokens', 700, '-CurrentOnly', '-Status', 'accepted', '-Json')
  if (-not [string]::IsNullOrWhiteSpace($Query)) { $decisionArgs = @('-Query', $Query) + $decisionArgs }
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $decisionArgs = @('-Scope', $Scope) + $decisionArgs }
  $decisionOutput = @(& (Join-Path $PSScriptRoot 'decision-search.ps1') @decisionArgs 2>&1)
  $decisions = (($decisionOutput -join "`n") | ConvertFrom-Json)
  foreach ($item in @($decisions)) {
    $claim = if ($item.decision) { [string]$item.decision } elseif ($item.text) { [string]$item.text } elseif ($item.title) { [string]$item.title } else { [string]$item }
    Add-Constraint $constraints 'accepted_decision' $claim 'decision' 'accepted' 0.9 ([string]$item.source)
  }
} catch {}

try {
  $recallQuery = if ([string]::IsNullOrWhiteSpace($Query)) { 'accepted constraints preserve requirements accepted decisions structure baseline' } else { $Query }
  $recallOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $recallQuery -TopK $MaxConstraints -MaxTokens 700 -Json 2>&1)
  $items = (($recallOutput -join "`n") | ConvertFrom-Json)
  foreach ($item in @($items)) {
    $card = if ($item.evidenceCard) { $item.evidenceCard } else { $item }
    $tags = @($card.tags)
    $tagText = ($tags -join ' ')
    $isAccepted = ($tagText.Contains('[CURRENT]') -or $tagText.Contains('[VERIFIED]') -or $tagText.Contains('[DECISION]') -or $tagText.Contains('[ADR]') -or $tagText.Contains('[TASK]'))
    if (-not $isAccepted) { continue }
    $claim = if ($card.claim) { [string]$card.claim } elseif ($item.text) { [string]$item.text } else { [string]$item }
    $confidence = if ($card.confidence) { [double]$card.confidence } elseif ($item.confidence) { [double]$item.confidence } else { 0.6 }
    Add-Constraint $constraints 'accepted_memory' $claim ([string]$card.sourceType) 'current_verified' $confidence ([string]$item.source)
  }
} catch {}

try {
  $checkpointPath = Join-Path $workspace 'active-checkpoint.json'
  if (Test-Path $checkpointPath) {
    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($claim in @($checkpoint.acceptedConstraints)) {
      Add-Constraint $constraints 'active_checkpoint' ([string]$claim) 'checkpoint' ([string]$checkpoint.status) 0.85 $checkpointPath
    }
  }
} catch {}

try {
  $bindingPath = Join-Path $workspace 'session-binding.json'
  if (Test-Path $bindingPath) {
    $binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($card in @($binding.evidenceCards)) {
      $claim = if ($card.claim) { [string]$card.claim } elseif ($card.summary) { [string]$card.summary } else { '' }
      Add-Constraint $constraints 'session_binding' $claim 'sessionBinding' ([string]$binding.status) 0.78 $bindingPath
    }
  }
} catch {}

$mustPreserve = @($constraints | Select-Object -First $MaxConstraints | ForEach-Object { $_.claim })
$mustNotViolate = @($mustPreserve | ForEach-Object { "Do not violate accepted constraint: $_" })
$conflicts = @()
$guardMaterial = (($mustPreserve + $mustNotViolate) -join '|')
$guardHash = if ([string]::IsNullOrWhiteSpace($guardMaterial)) { '' } else { (Get-StableId 'guard' $guardMaterial) }

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $Query 220
  scope = Limit-Text $Scope 120
  required = (@($constraints).Count -gt 0)
  constraints = @($constraints)
  mustPreserve = @($mustPreserve)
  mustNotViolate = @($mustNotViolate)
  conflicts = @($conflicts)
  guardHash = $guardHash
  noTail = [pscustomobject]@{ rawTranscript=$false; longSnippet=$false; historyTail=$false }
  nextAction = if (@($constraints).Count -gt 0) { 'Apply these accepted constraints before editing; ask before changing them.' } else { 'No accepted constraints found for this query; proceed with normal evidence checks.' }
}

Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "ACCEPTED_CONSTRAINTS_PREFLIGHT ok=$($result.ok) required=$($result.required) constraints=$(@($constraints).Count) path=$outPath" }
exit 0
