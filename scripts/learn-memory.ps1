param(
  [string]$Text = '',
  [string]$TextFile = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'force',
  [ValidateSet('profile','project','decision','task','session','experience')]
  [string]$Layer = 'project',
  [string]$Title = '',
  [string[]]$Tags = @(),
  [string[]]$Evidence = @(),
  [switch]$Preview,
  [switch]$AllowDuplicate,
  [switch]$ConfirmPrivate,
  [switch]$Json,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$RemainingArgs = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
if (@($RemainingArgs).Count -gt 0) {
  $extraTags = @()
  $extraEvidence = @()
  foreach ($arg in @($RemainingArgs)) {
    if ([string]::IsNullOrWhiteSpace($arg)) { continue }
    if ($arg -match '^\[[A-Z_]+\]$') { $extraTags += $arg } else { $extraEvidence += $arg }
  }
  if ($extraTags.Count -gt 0) { $Tags = @($Tags + $extraTags) }
  if ($extraEvidence.Count -gt 0) { $Evidence = @($Evidence + $extraEvidence) }
}
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statusPath = Join-Path $workspace 'last-learn-memory.json'

function Get-CompactText([string]$Value, [int]$MaxChars = 800) {
  $cleanValue = ($Value -replace '\s+', ' ').Trim()
  if ($cleanValue.Length -le $MaxChars) { return $cleanValue }
  return $cleanValue.Substring(0, $MaxChars) + '...'
}

function Get-LearnDecision([string]$LayerName, [object[]]$SimilarItems, [bool]$DuplicateAllowed) {
  $highSimilarity = @($SimilarItems | Where-Object { $_.confidence -ge 0.78 -or $_.score -ge 0.78 })
  if ($highSimilarity.Count -gt 0 -and -not $DuplicateAllowed) { return 'update_or_skip_duplicate' }
  if ($LayerName -eq 'profile') { return 'profile_card_candidate' }
  if ($LayerName -eq 'experience') { return 'write_memory_and_experience' }
  return 'write_memory'
}

if (-not [string]::IsNullOrWhiteSpace($TextFile)) {
  $resolvedTextFile = [System.IO.Path]::GetFullPath($TextFile)
  if (-not (Test-Path -LiteralPath $resolvedTextFile)) { throw "TextFile not found: $resolvedTextFile" }
  $fileText = Get-Content -LiteralPath $resolvedTextFile -Raw -Encoding UTF8
  $Text = $fileText
  if (@($Evidence).Count -eq 0) { $Evidence = @($resolvedTextFile) }
}

if ($MemoryMode -eq 'off') {
  $result = [pscustomobject]@{
    ok = $true
    skipped = $true
    reason = 'memory:off'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
  Write-JsonUtf8NoBom $statusPath $result 8
  if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "LEARN_MEMORY_SKIPPED memory=off status=$statusPath" }
  exit 0
}

$clean = Get-CompactText $Text 900
if ([string]::IsNullOrWhiteSpace($clean)) { throw 'Text cannot be empty.' }
if ([string]::IsNullOrWhiteSpace($Title)) {
  $Title = if ($clean.Length -gt 80) { $clean.Substring(0, 80) } else { $clean }
}

$layerForWrite = if ($Layer -eq 'experience') { 'project' } else { $Layer }
$tagMap = @{
  profile = '[PROFILE]'
  project = '[PROJECT]'
  decision = '[DECISION]'
  task = '[TASK]'
  session = '[SESSION]'
  experience = '[PROJECT]'
}
$allTags = @('[CURRENT]','[VERIFIED]','[SUMMARY]', $tagMap[$Layer]) + $Tags
if ($Layer -eq 'experience') { $allTags += '[EVIDENCE]' }
$prefix = (($allTags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join '')
$evidenceText = if (@($Evidence).Count -gt 0) { ' evidence=' + ((@($Evidence) | ForEach-Object { $_ -replace '\s+', '_' }) -join ',') } else { '' }
$memoryText = "$prefix $Title - $clean timestamp=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) source=learn-memory.ps1$evidenceText"

$similar = @()
$similarOutput = @()
try {
  $similarOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $Title -TopK 5 -MaxTokens 700 -Layer $layerForWrite -MemoryMode auto -Json 2>&1)
  $similar = @(($similarOutput -join "`n") | ConvertFrom-Json)
} catch {
  $similar = @()
}
$similarCards = @($similar | Select-Object -First 5 | ForEach-Object {
  if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
})
$decision = Get-LearnDecision $Layer $similar $AllowDuplicate

$previewObject = [pscustomobject]@{
  ok = $true
  preview = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  title = $Title
  layer = $Layer
  memoryMode = $MemoryMode
  proposedTags = @($allTags | Select-Object -Unique)
  compactSummary = $clean
  proposedMemory = $memoryText
  duplicatePolicy = if ($AllowDuplicate) { 'allow_duplicate' } else { 'block_high_similarity' }
  decision = $decision
  similarCount = @($similarCards).Count
  similarEvidenceCards = @($similarCards)
  wouldWrite = (-not $Preview -and ($AllowDuplicate -or $decision -ne 'update_or_skip_duplicate'))
  nextAction = if ($decision -eq 'update_or_skip_duplicate') { 'Review similarEvidenceCards; rerun with -AllowDuplicate only if this is truly new.' } elseif ($Preview) { 'Rerun without -Preview to write this compact memory.' } else { 'Writing compact governed memory.' }
}

if ($Preview -or ($decision -eq 'update_or_skip_duplicate' -and -not $AllowDuplicate)) {
  Write-JsonUtf8NoBom $statusPath $previewObject 10
  if ($Json) { $previewObject | ConvertTo-Json -Depth 10 } else { Write-Host "LEARN_MEMORY_PREVIEW decision=$decision similar=$(@($similarCards).Count) status=$statusPath" }
  exit 0
}

$writeParams = @{
  Text = $memoryText
  MemoryMode = $MemoryMode
  Layer = $layerForWrite
  Summary = $true
}
if ($ConfirmPrivate) { $writeParams.ConfirmPrivate = $true }
$writeOutput = @(& (Join-Path $PSScriptRoot 'write-memory.ps1') @writeParams 2>&1)
$writeOk = ($LASTEXITCODE -eq 0)

$experience = $null
if ($writeOk -and $Layer -eq 'experience') {
  $id = ('learn-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $experienceOutput = @(& (Join-Path $PSScriptRoot 'write-experience.ps1') -Id $id -Title $Title -Triggers @($Tags) -Scope 'project' -Do @($clean) -Evidence @($Evidence) -RecallQuery $Title -Json 2>&1)
  $experience = ($experienceOutput -join "`n")
}

$profileCard = $null
if ($writeOk -and $Layer -eq 'profile') {
  $profileOutput = @(& (Join-Path $PSScriptRoot 'profile-card.ps1') -Refresh -Json 2>&1)
  $profileCard = ($profileOutput -join "`n")
}

$result = [pscustomobject]@{
  ok = $writeOk
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  title = $Title
  layer = $Layer
  memoryMode = $MemoryMode
  decision = $decision
  similarCount = @($similarCards).Count
  similarEvidenceCards = @($similarCards)
  statusPath = $statusPath
  output = @($writeOutput)
  experience = $experience
  profileCard = $profileCard
  nextAction = if ($writeOk) { 'Use session-restore.ps1 or recall-search.ps1 when continuity is needed.' } else { 'Review write-memory governance output and retry with a stronger summary or ConfirmPrivate if appropriate.' }
}
Write-JsonUtf8NoBom $statusPath $result 10

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  if ($writeOk) { Write-Host "LEARN_MEMORY_OK layer=$Layer similar=$(@($similarCards).Count) status=$statusPath" } else { Write-Host "LEARN_MEMORY_FAILED status=$statusPath"; exit 1 }
}
