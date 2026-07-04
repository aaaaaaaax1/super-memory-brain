param(
  [string]$Query = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [int]$MaxTokens = 600,
  [int]$TopK = 2,
  [string]$SessionId = '',
  [string]$TaskId = '',
  [int]$TtlMinutes = 180,
  [switch]$BindSession,
  [switch]$Deep,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statusPath = Join-Path $workspace 'last-session-restore.json'

$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($MaxTokens -le 0) { $MaxTokens = 600 }
if ($TopK -le 0) { $TopK = 2 }
if ($MemoryMode -eq 'off') {
  $result = [pscustomobject]@{
    ok = $true
    memoryMode = $MemoryMode
    skipped = $true
    reason = 'memory:off'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    tokenBudget = 0
    sessionBinding = [pscustomobject]@{ ok=$true; status='skipped'; reason='memory:off' }
  }
  Write-JsonUtf8NoBom $statusPath $result 8
  if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SESSION_RESTORE_SKIPPED memory=off status=$statusPath" }
  exit 0
}

$state = $null
$statePath = Join-Path $workspace 'super-brain-state.json'
if (Test-Path $statePath) {
  try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$lastSnapshot = $null
$snapshotPath = Join-Path $workspace 'last-status-snapshot.json'
if (Test-Path $snapshotPath) {
  try { $lastSnapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$statusCard = $null
$statusCardPath = Join-Path $workspace 'status-card.json'
if (Test-Path $statusCardPath) {
  try { $statusCard = Get-Content -LiteralPath $statusCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$activeCheckpoint = $null
$checkpointPath = Join-Path $workspace 'active-checkpoint.json'
if (Test-Path $checkpointPath) {
  try { $activeCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$experienceIndex = ''
$experienceIndexPath = Join-Path $workspace 'experience-index.md'
$experienceIndexCount = 0
if (Test-Path $experienceIndexPath) {
  $experienceTitles = @()
  foreach ($line in Get-Content -LiteralPath $experienceIndexPath -Encoding UTF8) {
    if ($line -match '^###\s+(.+)$') {
      $experienceIndexCount += 1
      if ($experienceTitles.Count -lt 3) { $experienceTitles += $Matches[1] }
    }
  }
  if ($experienceTitles.Count -gt 0) {
    $experienceIndex = 'experience-index available: ' + ($experienceTitles -join '; ')
  } elseif ($experienceIndexCount -gt 0) {
    $experienceIndex = "experience-index entries=$experienceIndexCount"
  }
}
$profileCard = $null
$profileCardPath = Join-Path $workspace 'profile-card.json'
if (Test-Path $profileCardPath) {
  try { $profileCard = Get-Content -LiteralPath $profileCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$profileIntent = $false
if (-not [string]::IsNullOrWhiteSpace($Query)) {
  $lowerForProfile = $Query.ToLowerInvariant()
  foreach ($trigger in @($policy.retrieval.hybrid.profileIntentTriggers + $policy.retrieval.hybrid.personaIntentTriggers)) {
    if ($lowerForProfile.Contains(([string]$trigger).ToLowerInvariant())) { $profileIntent = $true; break }
  }
}
if (($profileIntent -or $MemoryMode -eq 'force') -and -not $profileCard) {
  try {
    $profileOutput = @(& (Join-Path $PSScriptRoot 'profile-card.ps1') -Refresh -MaxTokens 180 -Json 2>&1)
    $profileCard = (($profileOutput -join "`n") | ConvertFrom-Json)
  } catch {}
}

$shouldRecall = $Deep -or $MemoryMode -eq 'force'
$hasExplicitSessionId = -not [string]::IsNullOrWhiteSpace($SessionId)
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$continueWord = U @(0x7EE7,0x7EED)
$connectWord = U @(0x63A5,0x7740)
$fastResumeWord = U @(0x5FEB,0x901F,0x7EED,0x63A5)
$continueDoingWord = $continueWord + (U @(0x505A))
$fastSessionPattern = '(?i)(^|\s)(' + [regex]::Escape($continueWord) + '|' + [regex]::Escape($connectWord) + '|' + [regex]::Escape($fastResumeWord) + '|resume|continue)\s+#?sess[_-][A-Za-z0-9._-]+|(^|\s)#?sess[_-][A-Za-z0-9._-]+'
$fastSessionResume = $hasExplicitSessionId -and ($Query -match $fastSessionPattern)
if ($fastSessionResume -and -not $BindSession) { $BindSession = $true }
if (-not [string]::IsNullOrWhiteSpace($Query) -and -not $fastSessionResume) {
  $lower = $Query.ToLowerInvariant()
  $continuationOnly = $lower.Trim() -in @($continueWord,$connectWord,$continueDoingWord,'continue','resume')
  foreach ($trigger in @($policy.retrieval.keywordTriggers + $policy.retrieval.semanticTriggers)) {
    if ($lower.Contains(([string]$trigger).ToLowerInvariant())) { $shouldRecall = $true; break }
  }
  if ($continuationOnly -and -not $Deep -and $MemoryMode -ne 'force') { $shouldRecall = $false }
}
if ($fastSessionResume -and -not $Deep -and $MemoryMode -ne 'force') { $shouldRecall = $false }

$recall = @()
if ($shouldRecall) {
  $defaultRecallQuery = $continueWord + ' ' + (U @(0x4E0A,0x6B21)) + ' ' + (U @(0x6700,0x8FD1)) + ' ' + (U @(0x4F1A,0x8BDD)) + ' ' + (U @(0x8BB0,0x5FC6)) + ' ' + (U @(0x504F,0x597D)) + ' ' + (U @(0x9879,0x76EE))
  $recallQuery = if ([string]::IsNullOrWhiteSpace($Query)) { $defaultRecallQuery } else { $Query }
  $recallOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $recallQuery -TopK $TopK -MaxTokens ([Math]::Max(200, $MaxTokens - 300)) -MemoryMode $MemoryMode -Json 2>&1)
  try { $recall = (($recallOutput -join "`n") | ConvertFrom-Json) } catch { $recall = @() }
}

$sessionBinding = $null
if ($BindSession) {
  try {
    $bindingOutput = @(& (Join-Path $PSScriptRoot 'session-binding.ps1') -Action Bind -MemoryMode $MemoryMode -TtlMinutes $TtlMinutes -MaxTokens $MaxTokens -TopK $TopK -Query $Query -SessionId $SessionId -TaskId $TaskId -Json 2>&1)
    $sessionBinding = (($bindingOutput -join "`n") | ConvertFrom-Json)
  } catch {
    $sessionBinding = [pscustomobject]@{ ok=$false; status='error'; reason=$_.Exception.Message }
  }
} else {
  try {
    $bindingOutput = @(& (Join-Path $PSScriptRoot 'session-binding.ps1') -Action Get -Json 2>&1)
    $loadedBinding = (($bindingOutput -join "`n") | ConvertFrom-Json)
    if ($loadedBinding.binding -and $loadedBinding.binding.health -and $loadedBinding.binding.health.active -eq $true) { $sessionBinding = $loadedBinding }
  } catch {}
}

function New-CompactEvidenceCard([object]$Card) {
  if (-not $Card) { return $null }
  $claim = [string]$Card.claim
  if ($claim.Length -gt 180) { $claim = $claim.Substring(0, 180) + '...' }
  $evidenceCard = [ordered]@{
    sourceType = [string]$Card.sourceType
    claim = $claim
    whyRelevant = [string]$Card.whyRelevant
    confidence = $Card.confidence
    tags = @($Card.tags)
    tokenEstimate = $Card.tokenEstimate
  }
  if ($Deep) {
    $snippet = [string]$Card.snippet
    if ([string]::IsNullOrWhiteSpace($snippet)) { $snippet = $claim }
    if ($snippet.Length -gt 220) { $snippet = $snippet.Substring(0, 220) + '...' }
    $evidenceCard.snippet = $snippet
  }
  return [pscustomobject]$evidenceCard
}

function New-CompactCheckpoint([object]$Checkpoint) {
  if (-not $Checkpoint) { return $null }
  return [pscustomobject]@{
    taskId = [string]$Checkpoint.taskId
    sessionId = [string]$Checkpoint.sessionId
    status = [string]$Checkpoint.status
    goal = [string]$Checkpoint.goal
    currentPhase = [string]$Checkpoint.currentPhase
    completedSteps = @($Checkpoint.completedSteps | Select-Object -First 6)
    pendingSteps = @($Checkpoint.pendingSteps | Select-Object -First 6)
    currentStep = [string]$Checkpoint.currentStep
    nextAction = [string]$Checkpoint.nextAction
    changedFiles = @($Checkpoint.changedFiles | Select-Object -First 6)
    verificationCommands = @($Checkpoint.verificationCommands | Select-Object -First 4)
    verificationResults = @($Checkpoint.verificationResults | Select-Object -First 4)
    waitingForUser = [bool]$Checkpoint.waitingForUser
    updatedAt = if ($Checkpoint.updatedAt) { [string]$Checkpoint.updatedAt } else { [string]$Checkpoint.timestamp }
    checkedAt = [string]$Checkpoint.checkedAt
    blockers = @($Checkpoint.blockers | Select-Object -First 2)
  }
}

$statusCardNextAction = ''
if ($activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $statusCardNextAction = [string]$activeCheckpoint.nextAction
} elseif ($statusCard) {
  $statusCardNextAction = [string]$statusCard.nextAction
}

$lightPacket = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  memoryMode = $MemoryMode
  packageRoot = $Root
  memoryRoot = $MemoryRoot
  tokenBudget = $MaxTokens
  recallTriggered = $shouldRecall
  state = if ($state) { [pscustomobject]@{ version=$state.version; ok=$state.ok; hookOk=$state.hookOk; lastVerifyOk=$state.lastVerifyOk; updatedAt=$state.updatedAt } } else { $null }
  statusCard = if ($statusCard) { [pscustomobject]@{ version=$statusCard.version; ok=$statusCard.ok; packageOk=$statusCard.packageOk; verifyOk=$statusCard.verifyOk; updatedAt=$statusCard.updatedAt; risksCount=$statusCard.risksCount; nextAction=$statusCardNextAction } } else { $null }
  activeCheckpoint = if ($activeCheckpoint) { New-CompactCheckpoint $activeCheckpoint } else { $null }
  lastSnapshot = if ($lastSnapshot) { [pscustomobject]@{ summary=$lastSnapshot.summary; nextAction=$lastSnapshot.nextAction; checkedAt=$lastSnapshot.checkedAt } } else { $null }
  experienceIndexPreview = $experienceIndex
  profileCard = if ($profileIntent -or $MemoryMode -eq 'force') { $profileCard } else { $null }
  sessionBinding = $sessionBinding
  fastSessionResume = $fastSessionResume
  resumePriority = if ($fastSessionResume) { @('currentVisibleContext','currentTodoCheckpoint','explicitSessionBinding','statusCard','superBrainState','lastSnapshots') } else { @() }
  evidenceCards = @($recall | ForEach-Object {
    $card = if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
    New-CompactEvidenceCard $card
  } | Where-Object { $_ -ne $null })
  nextAction = if ($fastSessionResume) { 'Fast session resume: use the explicit session binding, status card, checkpoint, and current visible context first; do not run deep recall unless details are missing.' } elseif ($shouldRecall) { 'Use evidenceCards only if relevant; do not inject raw memory beyond the token budget.' } else { 'No deep recall needed unless the user asks for continuity, memory, preferences, or previous-session context.' }
}
Write-JsonUtf8NoBom $statusPath $lightPacket 10

if ($Json) {
  $lightPacket | ConvertTo-Json -Depth 12
} else {
  Write-Host "SESSION_RESTORE_OK triggered=$shouldRecall budget=$MaxTokens cards=$(@($lightPacket.evidenceCards).Count) status=$statusPath"
}
