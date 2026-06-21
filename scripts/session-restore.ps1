param(
  [string]$Query = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [int]$MaxTokens = 800,
  [int]$TopK = 3,
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
if ($MaxTokens -le 0) { $MaxTokens = 800 }
if ($TopK -le 0) { $TopK = 3 }
if ($MemoryMode -eq 'off') {
  $result = [pscustomobject]@{
    ok = $true
    memoryMode = $MemoryMode
    skipped = $true
    reason = 'memory:off'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    tokenBudget = 0
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
$activeCheckpoint = $null
$checkpointPath = Join-Path $workspace 'active-checkpoint.json'
if (Test-Path $checkpointPath) {
  try { $activeCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$experienceIndex = ''
$experienceIndexPath = Join-Path $workspace 'experience-index.md'
if (Test-Path $experienceIndexPath) {
  $experienceIndex = (Get-Content -LiteralPath $experienceIndexPath -Raw -Encoding UTF8)
  if ($experienceIndex.Length -gt 1200) { $experienceIndex = $experienceIndex.Substring(0, 1200) + '...' }
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
if (-not [string]::IsNullOrWhiteSpace($Query)) {
  $lower = $Query.ToLowerInvariant()
  foreach ($trigger in @($policy.retrieval.keywordTriggers + $policy.retrieval.semanticTriggers)) {
    if ($lower.Contains(([string]$trigger).ToLowerInvariant())) { $shouldRecall = $true; break }
  }
}

$recall = @()
if ($shouldRecall) {
  $recallQuery = if ([string]::IsNullOrWhiteSpace($Query)) { '继续 上次 最近 会话 记忆 偏好 项目' } else { $Query }
  $recallOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $recallQuery -TopK $TopK -MaxTokens ([Math]::Max(200, $MaxTokens - 300)) -MemoryMode $MemoryMode -Json 2>&1)
  try { $recall = (($recallOutput -join "`n") | ConvertFrom-Json) } catch { $recall = @() }
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
  activeCheckpoint = if ($activeCheckpoint) { $activeCheckpoint } else { $null }
  lastSnapshot = if ($lastSnapshot) { [pscustomobject]@{ summary=$lastSnapshot.summary; nextAction=$lastSnapshot.nextAction; checkedAt=$lastSnapshot.checkedAt } } else { $null }
  experienceIndexPreview = $experienceIndex
  profileCard = if ($profileIntent -or $MemoryMode -eq 'force') { $profileCard } else { $null }
  evidenceCards = @($recall | ForEach-Object { if ($_.evidenceCard) { $_.evidenceCard } else { $_ } })
  nextAction = if ($shouldRecall) { 'Use evidenceCards only if relevant; do not inject raw memory beyond the token budget.' } else { 'No deep recall needed unless the user asks for continuity, memory, preferences, or previous-session context.' }
}
Write-JsonUtf8NoBom $statusPath $lightPacket 10

if ($Json) {
  $lightPacket | ConvertTo-Json -Depth 12
} else {
  Write-Host "SESSION_RESTORE_OK triggered=$shouldRecall budget=$MaxTokens cards=$(@($lightPacket.evidenceCards).Count) status=$statusPath"
}
