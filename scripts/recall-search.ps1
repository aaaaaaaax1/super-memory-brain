param(
  [Parameter(Mandatory=$true)]
  [string]$Query,
  [int]$Limit = 0,
  [int]$TopK = 0,
  [int]$MaxTokens = 0,
  [ValidateSet('all','profile','project','decision','task','session')]
  [string]$Layer = 'all',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [switch]$NoSummaryFirst,
  [switch]$Legacy,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$MemoryBase = Get-SuperBrainMemoryBaseRoot $Root
$Policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if ($MemoryMode -eq 'off') {
  if ($Json) { '[]' } else { Write-Host 'MEMORY_OFF retrieval skipped' }
  exit 0
}

if ($TopK -le 0) { $TopK = [int]$Policy.retrieval.top_k }
if ($Limit -gt 0) { $TopK = $Limit }
if ($MaxTokens -le 0) { $MaxTokens = [int]$Policy.retrieval.max_tokens }
$candidateLimit = [Math]::Max($TopK * 4, $TopK)
$maxChars = [Math]::Max($MaxTokens * 4, 1)
$injectConfidence = [double]$Policy.retrieval.confidence.inject
$summaryConfidence = [double]$Policy.retrieval.confidence.summaryOnly
$hybrid = $Policy.retrieval.hybrid
$recencyPolicy = $Policy.retrieval.recency
$contextBudget = $Policy.retrieval.contextBudget
$cardSnippetTokens = if ($contextBudget -and $contextBudget.PSObject.Properties['cardSnippetTokens']) { [int]$contextBudget.cardSnippetTokens } else { 72 }
$evidenceTokens = if ($contextBudget -and $contextBudget.PSObject.Properties['evidenceTokens']) { [int]$contextBudget.evidenceTokens } else { $MaxTokens }
$cardSnippetChars = [Math]::Max(80, ($cardSnippetTokens * 4))
$maxEvidenceCards = if ($contextBudget -and $contextBudget.PSObject.Properties['maxEvidenceCards']) { [Math]::Max(1, [int]$contextBudget.maxEvidenceCards) } else { 6 }
if ($contextBudget -and [bool]$contextBudget.enabled) {
  $budgetTokens = [Math]::Min($MaxTokens, $evidenceTokens)
  $maxChars = [Math]::Max($budgetTokens * 4, 1)
}

$runtimeCli = Join-Path $Root 'runtime\brain_cli.py'
$runtimeDisabled = $Legacy -or $NoSummaryFirst -or $env:SUPER_BRAIN_RUNTIME_DISABLE -eq '1'
if (-not $runtimeDisabled -and (Test-Path -LiteralPath $runtimeCli)) {
  try {
    $runtimeOutput = @(& python $runtimeCli --package-root $Root --memory-root $MemoryRoot --base64 recall --query $Query --top-k $TopK --max-tokens $MaxTokens --layer $Layer 2>$null)
    $runtimeEncoded = (($runtimeOutput | ForEach-Object { [string]$_ }) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($runtimeEncoded)) {
      $runtimeText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($runtimeEncoded))
      $runtimeParsed = $runtimeText | ConvertFrom-Json
      if ($Json) {
        Write-Output $runtimeText
      } else {
        foreach ($item in @($runtimeParsed)) { Write-Host ($item | ConvertTo-Json -Compress -Depth 8) }
      }
      exit 0
    }
  } catch {
    Write-Verbose "Super Brain runtime fallback: $($_.Exception.Message)"
  }
}

function Test-IntentTrigger([string]$Text, [object[]]$Triggers) {
  $lower = $Text.ToLowerInvariant()
  foreach ($trigger in @($Triggers)) {
    if ($lower.Contains(([string]$trigger).ToLowerInvariant())) { return $true }
  }
  return $false
}

function Get-AliasTerms([string]$Text) {
  function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
  $lower = $Text.ToLowerInvariant()
  $aliasGroups = @(
    @((U @(0x8D85,0x7EA7,0x5927,0x8111)),(U @(0x5927,0x8111)),(U @(0x8111,0x5B50)),'super brain','g1','super-memory-brain'),
    @((U @(0x4E0D,0x56DE,0x590D)),(U @(0x6CA1,0x53CD,0x5E94)),(U @(0x4E0D,0x5728)),(U @(0x65AD,0x4E86)),(U @(0x574F,0x4E86)),(U @(0x5931,0x7075)),'fault','broken','not working'),
    @('github',(U @(0x516C,0x5F00,0x7248)),(U @(0x5206,0x4EAB,0x5305)),'release','zip',(U @(0x4E0A,0x4F20)),(U @(0x53D1,0x5E03))),
    @((U @(0x8FD8,0x8BB0,0x5F97)),(U @(0x4E0A,0x6B21)),(U @(0x4E4B,0x524D)),(U @(0x53E6,0x4E00,0x4E2A,0x4F1A,0x8BDD)),(U @(0x7EE7,0x7EED)),'remember','previous','resume','continue')
  )
  if ($Policy.retrieval.PSObject.Properties['aliasNormalization']) {
    $aliasGroups = @($Policy.retrieval.aliasNormalization.groups)
  }
  $aliases = @()
  foreach ($group in @($aliasGroups)) {
    $matched = $false
    foreach ($alias in @($group)) {
      if ($lower.Contains(([string]$alias).ToLowerInvariant())) { $matched = $true; break }
    }
    if ($matched) { $aliases += @($group) }
  }
  return @($aliases | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-PolicyNumber($Object, [string]$Name, [double]$Default) {
  if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return [double]$Object.PSObject.Properties[$Name].Value }
  return $Default
}

function Get-LayerTag([string]$LayerName) {
  if ($LayerName -eq 'all') { return '' }
  return [string]$Policy.layers.tagMap.$LayerName
}

function Get-ItemText($Item) {
  if ($Item -is [array] -and $Item.Count -ge 3) { return [string]$Item[2] }
  if ($null -ne $Item -and $Item.PSObject.Properties['text']) { return [string]$Item.text }
  return [string]$Item
}

function Get-ItemSource($Item, [string]$Fallback) {
  if ($Item -is [array] -and $Item.Count -ge 2) { return ([string]$Item[0] + ':' + [string]$Item[1]) }
  if ($null -ne $Item -and $Item.PSObject.Properties['source']) { return [string]$Item.source }
  return $Fallback
}

function Get-QueryTerms([string]$Text) {
  return @($Text.ToLowerInvariant() -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
}

function Get-RecallCoreText([string]$Text) {
  function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $clean = $Text.Normalize([System.Text.NormalizationForm]::FormKC).ToLowerInvariant()
  $clean = [regex]::Replace($clean, '[\p{P}\p{S}]+', ' ')
  $zhAnotherSession = U @(21478,19968,20010,20250,35805)
  $zhRemember = U @(36824,35760,24471)
  $zhLast = U @(19978,27425)
  $zhBefore = U @(20043,21069)
  $zhContinue = U @(32487,32493)
  $zhContinueDoing = U @(25509,30528,20570)
  $zhRememberShort = U @(35760,24471)
  $zhSession = U @(20250,35805)
  $zhTask = U @(20219,21153)
  $zhHistory = U @(21382,21490)
  $zhThat = U @(37027,20010)
  $zhThis = U @(36825,20010)
  $zhNow = U @(29616,22312)
  $zhCurrent = U @(30446,21069)
  $zhWhat = U @(20160,20040)
  $zhHow = U @(24590,20040)
  $zhHow2 = U @(22914,20309)
  $zhShould = U @(24212,35813)
  $zhWhether = U @(26159,21542)
  $zhIsIt = U @(26159,19981,26159)
  $zhWhich = U @(21738,20010)
  $zhPlease = U @(35831)
  $zhBrief = U @(19968,19979)
  $zhQuestion = U @(21527)
  $zhQuestion2 = U @(21602)
  $routingPhrases = @(
    'do you remember','another session','previous session','last session','previous task','last task','last time',
    'continue','resume','previous','remember','recall','session','task','history','historical','another',
    'please','tell me','can you','could you','from','about','with','into','this','that','the','your','my','now','currently','what','which','how',
    $zhAnotherSession,$zhRemember,$zhLast,$zhBefore,$zhContinue,$zhContinueDoing,$zhRememberShort,
    $zhSession,$zhHistory,$zhThat,$zhThis,$zhNow,$zhCurrent,$zhWhat,$zhHow,$zhHow2,$zhShould,
    $zhWhether,$zhIsIt,$zhWhich,$zhPlease,$zhBrief,$zhQuestion,$zhQuestion2
  ) | Sort-Object Length -Descending
  foreach ($phrase in $routingPhrases) { $clean = $clean.Replace(([string]$phrase).ToLowerInvariant(), ' ') }
  return ([regex]::Replace($clean, '\s+', ' ')).Trim()
}

function Get-SemanticAliasTerms([string]$Text) {
  $terms = New-Object System.Collections.ArrayList
  if (-not $Policy.retrieval.PSObject.Properties['semanticAliasGroups']) { return @() }
  $lower = $Text.ToLowerInvariant()
  foreach ($group in @($Policy.retrieval.semanticAliasGroups)) {
    $matched = $false
    foreach ($alias in @($group)) {
      $value = ([string]$alias).ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($value) -and $lower.Contains($value)) { $matched = $true; break }
    }
    if ($matched) {
      foreach ($alias in @($group)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { [void]$terms.Add(([string]$alias).ToLowerInvariant()) }
      }
    }
  }
  return @($terms | Select-Object -Unique)
}

function Get-RelevanceTerms([string]$Text) {
  $clean = Get-RecallCoreText $Text

  $terms = New-Object System.Collections.ArrayList
  foreach ($term in @(Get-QueryTerms $clean)) {
    $value = ([string]$term).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if ($value -match '[\u4e00-\u9fff]') {
      if ($value.Length -ge 2) { [void]$terms.Add($value) }
      if ($value.Length -gt 2) {
        for ($index = 0; $index -le ($value.Length - 2); $index += 2) {
          [void]$terms.Add($value.Substring($index, 2))
          if ($terms.Count -ge 16) { break }
        }
      }
    } elseif ($value.Length -ge 3) {
      [void]$terms.Add($value)
    }
  }
  return @($terms | Select-Object -Unique)
}

function Test-HistoricalRecallQuery([string]$Text) {
  function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
  return Test-IntentTrigger $Text @(
    'previous task','last task','previous session','last session','last time','another session',
    'remember last','remember previous',
    (U @(19978,27425)),(U @(20043,21069)),(U @(21478,19968,20010,20250,35805))
  )
}

function Get-Tags([string]$Text) {
  $tags = @()
  foreach ($match in [regex]::Matches($Text, '\[[A-Z_]+\]')) { $tags += $match.Value }
  return @($tags | Select-Object -Unique)
}

function Get-LayerFromText([string]$Text) {
  foreach ($layerName in @($Policy.layers.allowed)) {
    $tag = [string]$Policy.layers.tagMap.$layerName
    if ($Text.Contains($tag)) { return $layerName }
  }
  if ($Text.Contains('[DECISION]') -or $Text.Contains('[ADR]')) { return 'decision' }
  return 'project'
}

function Test-Expired([string]$Text) {
  $expires = [regex]::Match($Text, 'expires=(\d{4}-\d{2}-\d{2})')
  if (-not $expires.Success) { return $false }
  try { return ([datetime]::Parse($expires.Groups[1].Value) -lt (Get-Date).Date) } catch { return $true }
}

function Get-TextTimestamp([string]$Text) {
  $patterns = @(
    'timestamp=(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?)',
    'updatedAt=(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?)',
    'checkedAt=(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?)'
  )
  foreach ($pattern in $patterns) {
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
      try { return [datetime]::Parse($match.Groups[1].Value) } catch {}
    }
  }
  return $null
}

function Get-AgeDays([Nullable[datetime]]$Timestamp) {
  if ($null -eq $Timestamp) { return 9999.0 }
  return [Math]::Max(0.0, ((Get-Date) - ([datetime]$Timestamp)).TotalDays)
}

function Get-RecencyBoost([string]$Text, [string]$SourceType, [Nullable[datetime]]$Timestamp) {
  if (-not [bool]$recencyPolicy.enabled) { return 0.0 }
  $ageDays = Get-AgeDays $Timestamp
  $halfLife = [Math]::Max(1.0, (Get-PolicyNumber $recencyPolicy 'halfLifeDays' 14.0))
  $maxBoost = [Math]::Max(0.0, (Get-PolicyNumber $recencyPolicy 'maxBoost' 0.22))
  $recencyScore = [Math]::Pow(0.5, ($ageDays / $halfLife))
  $boost = $recencyScore * $maxBoost
  if ($SourceType -eq 'recent') { $boost += (Get-PolicyNumber $recencyPolicy 'recentSourceBoost' 0.08) }
  if ($SourceType -eq 'state') { $boost += (Get-PolicyNumber $recencyPolicy 'currentSourceBoost' 0.05) }
  if ($Text.Contains('[SESSION]')) { $boost += (Get-PolicyNumber $recencyPolicy 'sessionBoost' 0.12) }
  if ($Text.Contains('[TASK]')) { $boost += (Get-PolicyNumber $recencyPolicy 'taskBoost' 0.10) }
  if ($boost -gt $maxBoost) { $boost = $maxBoost }
  return [Math]::Round($boost, 4)
}

function Get-IntentBoost([string]$Text, [string]$SourceType) {
  $boost = 0.0
  $profileIntent = Test-IntentTrigger $Query @($hybrid.profileIntentTriggers)
  $experienceIntent = Test-IntentTrigger $Query @($hybrid.experienceIntentTriggers)
  $personaIntent = Test-IntentTrigger $Query @($hybrid.personaIntentTriggers)
  if ($Text.Contains('[PROFILE]')) { $boost += (Get-PolicyNumber $hybrid.boosts 'profile' 0.08) }
  if ($Text.Contains('[SESSION]')) { $boost += (Get-PolicyNumber $hybrid.boosts 'session' 0.06) }
  if ($Text.Contains('[TASK]')) { $boost += (Get-PolicyNumber $hybrid.boosts 'task' 0.05) }
  if ($SourceType -eq 'persona') { $boost += (Get-PolicyNumber $hybrid.boosts 'persona' 0.09) }
  if ($Text.ToLowerInvariant().Contains('experience')) { $boost += (Get-PolicyNumber $hybrid.boosts 'experience' 0.07) }
  if ($profileIntent -and ($Text.Contains('[PROFILE]') -or $SourceType -eq 'persona')) { $boost += (Get-PolicyNumber $recencyPolicy 'profileIntentBoost' 0.12) }
  if ($experienceIntent -and $Text.ToLowerInvariant().Contains('experience')) { $boost += (Get-PolicyNumber $recencyPolicy 'experienceIntentBoost' 0.08) }
  if ($personaIntent -and $SourceType -eq 'persona') { $boost += (Get-PolicyNumber $recencyPolicy 'personaIntentBoost' 0.08) }
  return [Math]::Round($boost, 4)
}

function Get-MatchStrength([string]$Text, [object[]]$Terms) {
  $lowerText = $Text.ToLowerInvariant()
  $lowerQuery = $Query.ToLowerInvariant()
  $score = 0.0
  if (-not [string]::IsNullOrWhiteSpace($lowerQuery) -and $lowerText.Contains($lowerQuery)) { $score += (Get-PolicyNumber $hybrid.boosts 'exactQuery' 0.15) }
  foreach ($term in $Terms) {
    if ($lowerText.Contains([string]$term)) { $score += (Get-PolicyNumber $hybrid.boosts 'termMatch' 0.04) }
  }
  return $score
}

function Get-CompactSnippet([string]$Text) {
  $clean = ($Text -replace '\s+', ' ').Trim()
  if ($clean.Length -le $cardSnippetChars) { return $clean }
  return $clean.Substring(0, $cardSnippetChars) + '...'
}

function New-EvidenceCard([string]$Text, [string]$Source, [string]$SourceType, [string]$Reason, [string]$Layer, [double]$Confidence, [double]$AgeDays, [double]$RecencyScore, [string]$RecallPriority, [object[]]$Tags) {
  $claim = Get-CompactSnippet $Text
  return [pscustomobject]@{
    source = $Source
    sourceType = $SourceType
    claim = $claim
    whyRelevant = $Reason
    confidence = [Math]::Round($Confidence, 4)
    lastVerified = if ($Text.Contains('[VERIFIED]')) { 'verified' } else { 'unverified' }
    layer = $Layer
    tags = @($Tags)
    ageDays = [Math]::Round($AgeDays, 2)
    recencyScore = $RecencyScore
    recallPriority = $RecallPriority
    snippet = $claim
    tokenEstimate = [Math]::Ceiling($claim.Length / 4)
  }
}

function Get-SourcePriority([string]$Source, [string]$Reason) {
  if ($Reason -ne 'state_recall_priority') { return 1000 }
  $normalized = $Source.Replace('/', '\').ToLowerInvariant()
  switch ($normalized) {
    'memory\workspace\status-card.json' { return 10 }
    'memory\workspace\super-brain-state.json' { return 20 }
    'current_baseline.md' { return 30 }
    'manifest.json' { return 40 }
    'changelog.md' { return 50 }
    default { return 100 }
  }
}

function Get-CandidateScore([string]$Text, [string]$SourceType, [object[]]$Terms, [Nullable[datetime]]$Timestamp) {
  $score = Get-PolicyNumber $hybrid.sourceWeights $SourceType 0.4
  if ($Text.Contains('[SUMMARY]')) { $score += (Get-PolicyNumber $hybrid.boosts 'summary' 0.12) }
  if ($Text.Contains('[CURRENT]')) { $score += (Get-PolicyNumber $hybrid.boosts 'current' 0.1) }
  if ($Text.Contains('[VERIFIED]')) { $score += (Get-PolicyNumber $hybrid.boosts 'verified' 0.08) }
  if ($Text.Contains('[ADR]')) { $score += (Get-PolicyNumber $hybrid.boosts 'adr' 0.08) }
  if ($Text.Contains('[DECISION]')) { $score += (Get-PolicyNumber $hybrid.boosts 'decision' 0.06) }
  $score += Get-MatchStrength $Text $Terms
  $score += Get-IntentBoost $Text $SourceType
  $score += Get-RecencyBoost $Text $SourceType $Timestamp
  if ($Text.Contains('[NEGATIVE_FEEDBACK]')) { $score -= (Get-PolicyNumber $hybrid.penalties 'negativeFeedback' 0.22) }
  if ($Text.Contains('[STALE]')) { $score -= (Get-PolicyNumber $hybrid.penalties 'stale' 0.3) }
  if (Test-Expired $Text) { $score -= (Get-PolicyNumber $hybrid.penalties 'expired' 0.35) }
  if ((Get-Tags $Text).Count -eq 0) { $score -= (Get-PolicyNumber $hybrid.penalties 'untagged' 0.05) }
  if ($score -lt 0) { return 0.0 }
  if ($score -gt 1) { return 1.0 }
  return [Math]::Round($score, 4)
}

function Get-CandidateIdentityKey([string]$Text) {
  foreach ($pattern in @('(?i)\bdecision:([a-z0-9._-]+)','(?i)\bdecision_key=([a-z0-9._-]+)','(?i)\bkey=([a-z0-9._-]+)')) {
    $match = [regex]::Match($Text,$pattern)
    if ($match.Success) { return 'decision:' + $match.Groups[1].Value.ToLowerInvariant() }
  }
  return ''
}

function Get-GraphRelationPriority([string]$Text,[string]$SourceType) {
  if ($SourceType -ne 'graph') { return 50 }
  if ($Text -match '(?i)\sdecides\s') { return 0 }
  if ($Text -match '(?i)\shas_title\s') { return 10 }
  if ($Text -match '(?i)\shas_context\s') { return 20 }
  if ($Text -match '(?i)\shas_consequence\s') { return 30 }
  if ($Text -match '(?i)\saffects\s') { return 40 }
  return 45
}

function Get-CalibratedConfidence([string]$Text,[string]$SourceType,[int]$MatchedCount,[int]$RequiredCount,[bool]$ExactMatch,[bool]$IntentAuthoritative) {
  $confidence = (Get-PolicyNumber $hybrid.sourceWeights $SourceType 0.4) * 0.35
  if ($Text.Contains('[CURRENT]')) { $confidence += 0.08 }
  if ($Text.Contains('[VERIFIED]')) { $confidence += 0.08 }
  if ($Text.Contains('[SUMMARY]')) { $confidence += 0.04 }
  if ($Text.Contains('[DECISION]') -or $Text.Contains('[ADR]')) { $confidence += 0.05 }
  if ($Text.Contains('[PROFILE]')) { $confidence += 0.04 }
  if ($ExactMatch) { $confidence += 0.35 }
  if ($MatchedCount -gt 0) {
    $confidence += [Math]::Min(0.30, $MatchedCount * 0.10)
    $confidence += 0.12 * [Math]::Min(1.0, ($MatchedCount / [double][Math]::Max(1,$RequiredCount)))
  } elseif ($IntentAuthoritative) {
    $confidence += 0.18
  }
  return [Math]::Round([Math]::Min(0.98,[Math]::Max(0.0,$confidence)),4)
}

function New-Candidate([string]$Text, [string]$Source, [string]$SourceType, [string]$Reason, [object[]]$Terms) {
  $timestamp = Get-TextTimestamp $Text
  $ageDays = Get-AgeDays $timestamp
  $recencyScore = Get-RecencyBoost $Text $SourceType $timestamp
  $score = Get-CandidateScore $Text $SourceType $Terms $timestamp
  $lowerText = $Text.ToLowerInvariant()
  $matchedRelevanceTerms = @($relevanceTerms | Where-Object { $lowerText.Contains(([string]$_).ToLowerInvariant()) })
  $exactMatch = (-not [string]::IsNullOrWhiteSpace($coreQuery) -and $lowerText.Contains($coreQuery.ToLowerInvariant()))
  $profileIntent = Test-IntentTrigger $Query @(@($hybrid.profileIntentTriggers) + @($hybrid.personaIntentTriggers))
  $experienceIntent = Test-IntentTrigger $Query @($hybrid.experienceIntentTriggers)
  $historicalTaskEvidence = (
    (Test-HistoricalRecallQuery $Query) -and
    ($Text.Contains('[TASK]') -or $Text.Contains('[SESSION]')) -and
    $Text.Contains('[CURRENT]') -and
    $Text.Contains('[VERIFIED]')
  )
  $requiredMatchCount = if ($relevanceTerms.Count -le 0) { 0 } elseif ($relevanceTerms.Count -le 2) { 1 } else { [Math]::Min(3,[Math]::Max(2,[Math]::Ceiling($relevanceTerms.Count * 0.15))) }
  $intentAuthoritative = (
    $Reason -eq 'temporary_session_binding' -or
    $Reason -eq 'state_recall_priority' -or
    ($Reason -eq 'persona_recall_priority' -and $profileIntent) -or
    ($Reason -eq 'experience_index_recall' -and $experienceIntent -and $relevanceTerms.Count -eq 0) -or
    $historicalTaskEvidence
  )
  $relevanceOk = ($exactMatch -or ($requiredMatchCount -gt 0 -and $matchedRelevanceTerms.Count -ge $requiredMatchCount) -or $intentAuthoritative)
  $confidence = Get-CalibratedConfidence $Text $SourceType $matchedRelevanceTerms.Count $requiredMatchCount $exactMatch $intentAuthoritative
  $candidateText = if ($contextBudget -and [bool]$contextBudget.enabled) { Get-CompactSnippet $Text } else { $Text }
  if ($confidence -lt $injectConfidence -and -not $candidateText.Contains('[SUMMARY]') -and $candidateText.Length -gt 320) {
    $candidateText = $candidateText.Substring(0, 320) + '...'
  }
  $layerName = Get-LayerFromText $Text
  $tags = @(Get-Tags $Text)
  $priority = if ($Text.Contains('[PROFILE]')) { 'profile' } elseif ($Text.Contains('[SESSION]')) { 'session' } elseif ($Text.Contains('[TASK]')) { 'task' } else { $SourceType }
  $sourcePriority = Get-SourcePriority $Source $Reason
  $identityKey = Get-CandidateIdentityKey $Text
  $relationPriority = Get-GraphRelationPriority $Text $SourceType
  $evidenceCard = New-EvidenceCard $Text $Source $SourceType $Reason $layerName $confidence $ageDays $recencyScore $priority $tags
  $evidenceCard | Add-Member -NotePropertyName relevanceStatus -NotePropertyValue $(if ($relevanceOk) { 'matched' } else { 'unmatched' })
  $evidenceCard | Add-Member -NotePropertyName matchedTerms -NotePropertyValue @($matchedRelevanceTerms)
  $evidenceCard | Add-Member -NotePropertyName requiredMatchCount -NotePropertyValue $requiredMatchCount
  $evidenceCard | Add-Member -NotePropertyName sourcePriority -NotePropertyValue $sourcePriority
  return [pscustomobject]@{
    text = $candidateText
    evidenceCard = $evidenceCard
    source = $Source
    sourceType = $SourceType
    layer = $layerName
    tags = @($tags)
    score = $score
    confidence = $confidence
    reason = $Reason
    ageDays = [Math]::Round($ageDays, 2)
    recencyScore = $recencyScore
    recallPriority = $priority
    tokenEstimate = [Math]::Ceiling($candidateText.Length / 4)
    relevanceOk = $relevanceOk
    matchedTerms = @($matchedRelevanceTerms)
    requiredMatchCount = $requiredMatchCount
    matchedTermCount = $matchedRelevanceTerms.Count
    exactMatch = $exactMatch
    identityKey = $identityKey
    relationPriority = $relationPriority
    sourcePriority = $sourcePriority
  }
}

function Add-Candidate([object[]]$Candidates, [object]$Candidate) {
  if (-not $Candidate.relevanceOk) { return @($Candidates) }
  if (([string]$Candidate.text).Contains('[STALE]') -or (Test-Expired ([string]$Candidate.text))) { return @($Candidates) }
  if ($Candidate.confidence -lt $summaryConfidence) { return @($Candidates) }
  $layerTag = Get-LayerTag $Layer
  if (-not [string]::IsNullOrWhiteSpace($layerTag) -and -not ([string]$Candidate.text).Contains($layerTag)) { return @($Candidates) }
  $key = ([string]$Candidate.text).ToLowerInvariant()
  foreach ($existing in $Candidates) {
    if (([string]$existing.text).ToLowerInvariant() -eq $key) { return @($Candidates) }
  }
  return @($Candidates + $Candidate)
}

function Test-StateQuery([string]$Text, [object[]]$Terms) {
  $lower = $Text.ToLowerInvariant()
  $explicitArtifacts = @('baseline','manifest','changelog','current_baseline','package version')
  foreach ($artifact in $explicitArtifacts) { if ($lower.Contains($artifact)) { return $true } }
  foreach ($term in $Terms) {
    if (@('version','baseline','manifest','changelog') -contains $term) { return $true }
  }
  $superBrainSubject = $lower.Contains('super-memory-brain') -or $lower.Contains('super brain') -or $lower.Contains('superbrain') -or $lower.Contains(([string](-join (@(36229,32423,22823,33041) | ForEach-Object { [char]$_ }))).ToLowerInvariant())
  if (-not $superBrainSubject) { return $false }
  foreach ($trigger in @($hybrid.stateTriggers)) {
    if ($lower.Contains(([string]$trigger).ToLowerInvariant())) { return $true }
  }
  return $false
}

function Get-FileSnippet([string]$RelativePath, [object[]]$Terms) {
  $path = Join-Path $Root $RelativePath
  if (-not (Test-Path $path)) { return '' }
  $item = Get-Item -LiteralPath $path
  $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $index = -1
  foreach ($term in $Terms) {
    $found = $text.ToLowerInvariant().IndexOf(([string]$term).ToLowerInvariant())
    if ($found -ge 0 -and ($index -lt 0 -or $found -lt $index)) { $index = $found }
  }
  if ($index -lt 0) { $index = 0 }
  $start = [Math]::Max(0, $index - 220)
  $length = [Math]::Min(600, $text.Length - $start)
  $snippet = $text.Substring($start, $length).Trim()
  $timestamp = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
  return "[PROJECT][CURRENT][VERIFIED][SUMMARY] $RelativePath timestamp=$timestamp $snippet"
}

function Get-ExperienceSnippets([object[]]$Terms) {
  $snippets = @()
  $indexPath = Join-Path (Join-Path $MemoryBase 'workspace') 'experience-index.md'
  if (Test-Path $indexPath) {
    $indexText = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
    $lowerIndex = $indexText.ToLowerInvariant()
    $matched = $lowerIndex.Contains($Query.ToLowerInvariant())
    foreach ($term in $Terms) { if ($lowerIndex.Contains([string]$term)) { $matched = $true; break } }
    if ($matched) { $snippets += "[PROJECT][CURRENT][VERIFIED][SUMMARY] experience-index.md $($indexText.Substring(0, [Math]::Min(600, $indexText.Length)).Trim())" }
  }
  $experienceRoot = Join-Path (Join-Path $MemoryBase 'workspace') 'experiences'
  if (Test-Path $experienceRoot) {
    foreach ($file in @(Get-ChildItem -LiteralPath $experienceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try { $experience = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
      $experienceText = "$($experience.id) $($experience.title) $($experience.status) $($experience.scope) $(@($experience.triggers) -join ' ') $(@($experience.symptoms) -join ' ') $($experience.recallQuery) timestamp=$($experience.updatedAt)"
      $lowerExperience = $experienceText.ToLowerInvariant()
      $matched = $lowerExperience.Contains($Query.ToLowerInvariant())
      foreach ($term in $Terms) { if ($lowerExperience.Contains([string]$term)) { $matched = $true; break } }
      if ($matched) {
        $snippets += "[PROJECT][CURRENT][VERIFIED][SUMMARY] experience $($experience.id) title=$($experience.title) status=$($experience.status) confidence=$($experience.confidence) recallQuery=$($experience.recallQuery) updatedAt=$($experience.updatedAt) evidence=$(@($experience.evidence) -join ',')"
      }
    }
  }
  return @($snippets)
}

function Get-PersonaSnippets([object[]]$Terms) {
  $snippets = @()
  $personaPath = Join-Path (Join-Path $MemoryRoot 'persona') 'persona.md'
  if (-not (Test-Path $personaPath)) { return @() }
  $text = Get-Content -LiteralPath $personaPath -Raw -Encoding UTF8
  $lower = $text.ToLowerInvariant()
  $matched = Test-IntentTrigger $Query @($hybrid.personaIntentTriggers)
  if (-not $matched) {
    $matched = $lower.Contains($Query.ToLowerInvariant())
    foreach ($term in $Terms) { if ($lower.Contains([string]$term)) { $matched = $true; break } }
  }
  if ($matched) {
    $snippet = $text.Substring(0, [Math]::Min(600, $text.Length)).Trim()
    $snippets += "[PROFILE][CURRENT][VERIFIED][SUMMARY] persona\persona.md $snippet"
  }
  return @($snippets)
}

function Test-SessionBindingQuery([string]$Text, [object[]]$Terms) {
  $lower = $Text.ToLowerInvariant()
  foreach ($needle in @('session','bind','previous','continue','resume','remember','recall','binding','workspace')) {
    if ($lower.Contains($needle.ToLowerInvariant())) { return $true }
  }
  foreach ($term in $Terms) {
    if (@('session','bind','previous','continue','resume') -contains $term) { return $true }
  }
  return $false
}

function Get-SessionBindingSnippets([object[]]$Terms) {
  $snippets = @()
  if ($MemoryMode -eq 'off') { return @() }
  if (-not (Test-SessionBindingQuery $Query $Terms) -and $Layer -ne 'session' -and $MemoryMode -ne 'force') { return @() }
  $bindingPath = Join-Path (Join-Path $MemoryBase 'workspace') 'session-binding.json'
  if (-not (Test-Path $bindingPath)) { return @() }
  try { $binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
  if (-not $binding -or [string]$binding.status -ne 'active') { return @() }
  $expired = $false
  try { $expired = ([datetime]::Parse([string]$binding.expiresAt) -lt (Get-Date)) } catch { $expired = $true }
  if ($expired) { return @() }
  $manifestVersion = [string](Get-SuperBrainManifest $Root).version
  if ([string]$binding.packageVersion -ne $manifestVersion) { return @() }
  if (-not (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $MemoryRoot)) { return @() }
  $cards = @($binding.evidenceCards | Select-Object -First 3)
  $cardText = ($cards | ForEach-Object { [string]$_.claim }) -join ' | '
  $snippet = "[SESSION][CURRENT][VERIFIED][SUMMARY] session-binding.json bindingId=$($binding.bindingId) sessionId=$($binding.sessionId) taskId=$($binding.taskId) expiresAt=$($binding.expiresAt) nextAction=$($binding.nextAction) evidence=$cardText"
  if ($snippet.Length -gt 900) { $snippet = $snippet.Substring(0, 900) + '...' }
  $snippets += $snippet
  return @($snippets)
}

$coreQuery = Get-RecallCoreText $Query
$queryTerms = @(Get-QueryTerms $coreQuery)
$aliasTerms = @(Get-AliasTerms $Query)
$semanticAliasTerms = @(Get-SemanticAliasTerms ($Query + ' ' + $coreQuery))
$semanticAliasRelevanceTerms = @($semanticAliasTerms | ForEach-Object { Get-RelevanceTerms ([string]$_) })
$relevanceTerms = @((@(Get-RelevanceTerms $coreQuery) + $semanticAliasRelevanceTerms) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
$terms = @(($queryTerms + $aliasTerms + $semanticAliasTerms + $relevanceTerms) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
$isProfileQuery = Test-IntentTrigger $Query @(@($hybrid.profileIntentTriggers) + @($hybrid.personaIntentTriggers) + @((-join (@(20559,22909) | ForEach-Object { [char]$_ })),(-join (@(20064,24815) | ForEach-Object { [char]$_ })),(-join (@(39118,26684) | ForEach-Object { [char]$_ }))))
$searchQueries = @($Query,$coreQuery)
if ($semanticAliasTerms.Count -gt 0) { $searchQueries += ($semanticAliasTerms -join ' ') }
$searchQueries = @($searchQueries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
$candidates = @()

foreach ($snippet in @(Get-SessionBindingSnippets $terms)) {
  if (-not [string]::IsNullOrWhiteSpace($snippet)) {
    $candidate = New-Candidate $snippet 'memory\workspace\session-binding.json' 'sessionBinding' 'temporary_session_binding' $terms
    $candidates = Add-Candidate $candidates $candidate
  }
}

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$queryJson = ConvertTo-Json -InputObject @($searchQueries) -Compress
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($queryJson))
$code = "import base64,json; from sandglass_vault import search; qs=json.loads(base64.b64decode('$b64').decode('utf-8')); items=[item for q in qs for item in search(q)[:$candidateLimit]]; dedup=list({str(item[0]):item for item in items}.values()); print(json.dumps(dedup[:$($candidateLimit * 2)]))"
try {
  $result = (& python -c $code) -join "`n"
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($result)) {
    $parsedSearch = $result | ConvertFrom-Json
    foreach ($item in @($parsedSearch)) {
      $text = Get-ItemText $item
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $candidate = New-Candidate $text (Get-ItemSource $item 'sandglass') 'sandglass' 'sandglass_search' $terms
      $candidates = Add-Candidate $candidates $candidate
    }
  }
} catch {}

$graphPath = Join-Path $MemoryBase 'graph.jsonl'
if (Test-Path $graphPath) {
  $lineNumber = 0
  foreach ($line in @(Get-Content -LiteralPath $graphPath -Encoding UTF8)) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $node = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { continue }
    $graphText = "$($node.subject) $($node.relation) $($node.object) $($node.evidence) $($node.tags)"
    $lowerGraph = $graphText.ToLowerInvariant()
    $matched = $lowerGraph.Contains($Query.ToLowerInvariant())
    foreach ($term in $terms) { if ($lowerGraph.Contains([string]$term)) { $matched = $true; break } }
    if (-not $matched -and -not (Test-StateQuery $Query $terms)) { continue }
    $candidate = New-Candidate $graphText ("memory\\graph.jsonl:$lineNumber") 'graph' 'graph_decision_or_lineage' $terms
    $candidates = Add-Candidate $candidates $candidate
  }
}

if (Test-StateQuery $Query $terms) {
  foreach ($relativePath in @('memory\workspace\status-card.json','memory\workspace\super-brain-state.json','CURRENT_BASELINE.md','manifest.json','CHANGELOG.md')) {
    $snippet = Get-FileSnippet $relativePath $terms
    if (-not [string]::IsNullOrWhiteSpace($snippet)) {
      $candidate = New-Candidate $snippet $relativePath 'state' 'state_recall_priority' $terms
      $candidates = Add-Candidate $candidates $candidate
    }
  }
}

foreach ($snippet in @(Get-ExperienceSnippets $terms)) {
  if (-not [string]::IsNullOrWhiteSpace($snippet)) {
    $candidate = New-Candidate $snippet 'memory\workspace\experience-index.md' 'state' 'experience_index_recall' $terms
    $candidates = Add-Candidate $candidates $candidate
  }
}

foreach ($snippet in @(Get-PersonaSnippets $terms)) {
  if (-not [string]::IsNullOrWhiteSpace($snippet)) {
    $candidate = New-Candidate $snippet 'persona\persona.md' 'persona' 'persona_recall_priority' $terms
    $candidates = Add-Candidate $candidates $candidate
  }
}

if ($candidates.Count -lt $TopK -and [bool]$hybrid.fallbackRecentWhenBelowTopK) {
  $recentCode = "import json; from sandglass_vault import recent; print(json.dumps(recent($candidateLimit)))"
  try {
    $recentResult = (& python -c $recentCode) -join "`n"
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($recentResult)) {
      $parsedRecent = $recentResult | ConvertFrom-Json
      foreach ($item in @($parsedRecent)) {
        $text = Get-ItemText $item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $candidate = New-Candidate $text (Get-ItemSource $item 'recent') 'recent' 'recent_fallback' $terms
        $candidates = Add-Candidate $candidates $candidate
      }
    }
  } catch {}
}

$summaryFirst = ([bool]$Policy.retrieval.summaryFirst -and -not $NoSummaryFirst)
$isStateQuery = Test-StateQuery $Query $terms
if ($summaryFirst) {
  $candidates = @($candidates | Sort-Object @{ Expression = { if ($isStateQuery) { [string]$_.reason -ne 'state_recall_priority' } else { [string]$_.sourceType -ne 'sessionBinding' } } }, @{ Expression = { if ($isStateQuery) { [int]$_.sourcePriority } else { if ($_.exactMatch) { 0 } else { 1 } } } }, @{ Expression = { if ($isStateQuery -or -not $isProfileQuery) { 0 } else { if (([string]$_.text).Contains('[PROFILE]')) { 0 } else { 1 } } } }, @{ Expression = { if ($isStateQuery) { 0 } else { if (([string]$_.text).Contains('[CURRENT]')) { 0 } else { 1 } } } }, @{ Expression = 'matchedTermCount'; Descending = $true }, @{ Expression = { if ($isStateQuery) { 0 } else { [int]$_.relationPriority } } }, @{ Expression = { -not ([string]$_.text).Contains('[SUMMARY]') } }, @{ Expression = 'confidence'; Descending = $true }, @{ Expression = 'score'; Descending = $true })
} else {
  $candidates = @($candidates | Sort-Object @{ Expression = { if ($isStateQuery) { [string]$_.reason -ne 'state_recall_priority' } else { [string]$_.sourceType -ne 'sessionBinding' } } }, @{ Expression = { if ($isStateQuery) { [int]$_.sourcePriority } else { if ($_.exactMatch) { 0 } else { 1 } } } }, @{ Expression = { if ($isStateQuery -or -not $isProfileQuery) { 0 } else { if (([string]$_.text).Contains('[PROFILE]')) { 0 } else { 1 } } } }, @{ Expression = { if ($isStateQuery) { 0 } else { if (([string]$_.text).Contains('[CURRENT]')) { 0 } else { 1 } } } }, @{ Expression = 'matchedTermCount'; Descending = $true }, @{ Expression = { if ($isStateQuery) { 0 } else { [int]$_.relationPriority } } }, @{ Expression = 'confidence'; Descending = $true }, @{ Expression = 'score'; Descending = $true })
}

$selected = @()
$selectedIdentityKeys = @{}
$usedChars = 0
$effectiveTopK = if ($contextBudget -and [bool]$contextBudget.enabled) { [Math]::Min($TopK, $maxEvidenceCards) } else { $TopK }
foreach ($candidate in $candidates) {
  if ($selected.Count -ge $effectiveTopK) { break }
  $identityKey = [string]$candidate.identityKey
  if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $selectedIdentityKeys.ContainsKey($identityKey)) { continue }
  $budgetText = if ($contextBudget -and [bool]$contextBudget.enabled -and $candidate.evidenceCard) { [string]$candidate.evidenceCard.snippet } else { [string]$candidate.text }
  $nextChars = $usedChars + $budgetText.Length
  if ($nextChars -gt $maxChars -and $selected.Count -gt 0) { break }
  $selected += $candidate
  if (-not [string]::IsNullOrWhiteSpace($identityKey)) { $selectedIdentityKeys[$identityKey] = $true }
  $usedChars = $nextChars
}

if ($Json) {
  if ($selected.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($selected) -Depth 8 -Compress }
} else {
  foreach ($item in $selected) {
    Write-Host ($item | ConvertTo-Json -Compress -Depth 8)
  }
}
