param(
  [Parameter(Mandatory=$true)]
  [string]$Id,
  [Parameter(Mandatory=$true)]
  [string]$Title,
  [string[]]$Triggers = @(),
  [ValidateSet('project','shared')]
  [string]$Scope = 'project',
  [string[]]$Symptoms = @(),
  [string[]]$Do = @(),
  [string[]]$Dont = @(),
  [string[]]$Evidence = @(),
  [string]$RecallQuery = '',
  [ValidateSet('draft','active','stale','rejected')]
  [string]$Status = 'active',
  [ValidateRange(0,1)]
  [double]$Confidence = 0.7,
  [ValidateRange(0,100)]
  [int]$VerifiedUses = 0,
  [switch]$ConfirmShared,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$experienceRoot = Join-Path $workspace 'experiences'
$indexPath = Join-Path $workspace 'experience-index.md'
$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sharedPolicy = $policy.collaboration.sharedExperience
$maxEntries = if($sharedPolicy -and $sharedPolicy.maxEntries){[int]$sharedPolicy.maxEntries}else{80}
$maxIndexChars = if($sharedPolicy -and $sharedPolicy.maxChars){[int]$sharedPolicy.maxChars}else{50000}
$promotionThreshold = if($sharedPolicy -and $sharedPolicy.promoteAfterVerifiedUses){[int]$sharedPolicy.promoteAfterVerifiedUses}else{2}
if($Scope -eq 'shared' -and -not $ConfirmShared){throw 'Shared experience requires -ConfirmShared.'}
if($Scope -eq 'shared' -and $VerifiedUses -lt $promotionThreshold){throw "Shared experience requires VerifiedUses >= $promotionThreshold."}
if (-not (Test-Path $experienceRoot)) { New-Item -ItemType Directory -Force -Path $experienceRoot | Out-Null }
if (-not (Test-Path $indexPath)) {
  Write-Utf8NoBom $indexPath "# Experience Index`n`nPurpose: lightweight titles and triggers for reusable project lessons. Keep long details in memory; use this index to quickly decide which experience to recall.`n`n## Usage`n`n1. When a task resembles a listed trigger, search memory for the experience title before changing direction.`n2. Use the index as a routing table, not as hard rules.`n3. Keep entries short: title, triggers, scope, recall query, evidence paths.`n`n## Entries`n"
}

$safeId = ($Id -replace '[^A-Za-z0-9._-]','-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeId)) { throw 'Experience Id must contain at least one safe character.' }
$path = Join-Path $experienceRoot ($safeId + '.json')
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$existing = $null
if (Test-Path $path) {
  try { $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$createdAt = if ($existing -and $existing.createdAt) { [string]$existing.createdAt } else { $now }
if ([string]::IsNullOrWhiteSpace($RecallQuery)) { $RecallQuery = (($Triggers + $Symptoms + @($Title)) -join ' ') }
if(-not $existing -and @(Get-ChildItem -LiteralPath $experienceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -ge $maxEntries){throw "Experience capacity reached: maxEntries=$maxEntries"}

$experience = [pscustomobject]@{
  id = $safeId
  title = $Title
  status = $Status
  scope = $Scope
  triggers = @($Triggers)
  symptoms = @($Symptoms)
  do = @($Do)
  dont = @($Dont)
  evidence = @($Evidence)
  recallQuery = $RecallQuery
  confidence = [Math]::Round($Confidence, 2)
  verifiedUses = $VerifiedUses
  createdAt = $createdAt
  updatedAt = $now
  lastVerifiedAt = if ($Status -eq 'active') { $now } else { '' }
}
$indexText = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
$entryHeader = "### $safeId"
$entry = @"
### $safeId

- Title: $Title
- Status: $Status
- Confidence: $([Math]::Round($Confidence, 2))
- Verified Uses: $VerifiedUses
- Triggers: $((@($Triggers) | ForEach-Object { "``$_``" }) -join ', ')
- Scope: $Scope
- Recall Query: ``$RecallQuery``
- Evidence Paths: $((@($Evidence) | ForEach-Object { "``$_``" }) -join ', ')
- Structured File: ``memory/workspace/experiences/$safeId.json``
"@

$pattern = '(?ms)^### ' + [regex]::Escape($safeId) + '\s+.*?(?=^### |\z)'
if ([regex]::IsMatch($indexText, $pattern)) {
  $indexText = [regex]::Replace($indexText, $pattern, $entry.TrimEnd() + "`n`n")
} else {
  if (-not $indexText.EndsWith("`n")) { $indexText += "`n" }
  $indexText += "`n" + $entry.TrimEnd() + "`n"
}
if($indexText.Length -gt $maxIndexChars){throw "Experience index capacity reached: maxChars=$maxIndexChars"}
Write-JsonUtf8NoBom $path $experience 8
Write-Utf8NoBom $indexPath $indexText

$result = [pscustomobject]@{ ok = $true; id = $safeId; scope = $Scope; verifiedUses = $VerifiedUses; capacity = [pscustomobject]@{ maxEntries=$maxEntries; maxIndexChars=$maxIndexChars }; path = $path; index = $indexPath }
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { Write-Host "WRITE_EXPERIENCE_OK id=$safeId path=$path" }
