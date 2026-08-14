param(
  [Parameter(Mandatory=$true)]
  [string]$Id,
  [Parameter(Mandatory=$true)]
  [string]$Title,
  [ValidateSet('method','pitfall')]
  [string]$Kind = 'method',
  [string[]]$Triggers = @(),
  [ValidateSet('project','shared')]
  [string]$Scope = 'project',
  [string[]]$Symptoms = @(),
  [string[]]$Do = @(),
  [string[]]$Dont = @(),
  [string[]]$Evidence = @(),
  [string]$RootCause = '',
  [Alias('PreventionGate')]
  [string[]]$PreventionGates = @(),
  [ValidateRange(-1,365)]
  [int]$RevalidateAfterDays = -1,
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
$pitfallPolicy = $policy.userAdaptation.evolution.experienceTransfer.pitfallExperience
$maxEntries = if($sharedPolicy -and $sharedPolicy.maxEntries){[int]$sharedPolicy.maxEntries}else{80}
$maxIndexChars = if($sharedPolicy -and $sharedPolicy.maxChars){[int]$sharedPolicy.maxChars}else{50000}
$promotionThreshold = if($sharedPolicy -and $sharedPolicy.promoteAfterVerifiedUses){[int]$sharedPolicy.promoteAfterVerifiedUses}else{2}
$defaultPitfallRevalidationDays = if($pitfallPolicy -and $pitfallPolicy.defaultRevalidationDays){[int]$pitfallPolicy.defaultRevalidationDays}else{90}
$maxPitfallRevalidationDays = if($pitfallPolicy -and $pitfallPolicy.maxRevalidationDays){[int]$pitfallPolicy.maxRevalidationDays}else{365}

function Get-CompactExperienceText([string]$Value, [int]$Max = 320) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = $Value.Trim() -replace '\s+', ' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0, $Max) + '...' }
  return $clean
}

function Get-CompactExperienceList([string[]]$Values, [int]$MaxItems = 4) {
  return @($Values | ForEach-Object { Get-CompactExperienceText ([string]$_) 240 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique -First $MaxItems)
}

if ($Kind -eq 'pitfall') {
  $RootCause = Get-CompactExperienceText $RootCause 420
  $PreventionGates = Get-CompactExperienceList $PreventionGates 4
  if ([string]::IsNullOrWhiteSpace($RootCause)) { throw 'PITFALL_ROOT_CAUSE_REQUIRED: a pitfall needs a compact, evidence-backed root cause.' }
  if (@($PreventionGates).Count -eq 0) { throw 'PITFALL_PREVENTION_GATE_REQUIRED: a pitfall needs at least one prevention gate.' }
  if (@($Evidence | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw 'PITFALL_EVIDENCE_REQUIRED: a pitfall needs a compact evidence reference.' }
  if ($RevalidateAfterDays -lt 0) { $RevalidateAfterDays = $defaultPitfallRevalidationDays }
  if ($RevalidateAfterDays -gt $maxPitfallRevalidationDays) { throw "PITFALL_REVALIDATION_TOO_LONG: maximum is $maxPitfallRevalidationDays days." }
} else {
  $RootCause = ''
  $PreventionGates = @()
  if ($RevalidateAfterDays -lt 0) { $RevalidateAfterDays = 0 }
}

if($Scope -eq 'shared' -and -not $ConfirmShared){throw 'Shared experience requires -ConfirmShared.'}
if($Scope -eq 'shared' -and $VerifiedUses -lt $promotionThreshold){throw "Shared experience requires VerifiedUses >= $promotionThreshold."}
if (-not (Test-Path $experienceRoot)) { New-Item -ItemType Directory -Force -Path $experienceRoot | Out-Null }
if (-not (Test-Path $indexPath)) {
  Write-Utf8NoBom $indexPath "# Experience Index`n`nPurpose: lightweight titles and triggers for reusable project lessons. Keep long details in memory; use this index to quickly decide which experience to recall.`n`n## Usage`n`n1. When a task resembles a listed trigger, search memory for the experience title before changing direction.`n2. Use the index as a routing table, not as hard rules.`n3. Keep entries short: title, triggers, scope, recall query, evidence paths.`n`n## Entries`n"
}

$safeId = ($Id -replace '[^A-Za-z0-9._-]','-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeId)) { throw 'Experience Id must contain at least one safe character.' }
$path = Join-Path $experienceRoot ($safeId + '.json')
$nowDate = Get-Date
$now = $nowDate.ToString('yyyy-MM-dd HH:mm:ss')
$existing = $null
if (Test-Path $path) {
  try { $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$createdAt = if ($existing -and $existing.createdAt) { [string]$existing.createdAt } else { $now }
if ([string]::IsNullOrWhiteSpace($RecallQuery)) { $RecallQuery = (($Triggers + $Symptoms + @($Title)) -join ' ') }
if(-not $existing -and @(Get-ChildItem -LiteralPath $experienceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -ge $maxEntries){throw "Experience capacity reached: maxEntries=$maxEntries"}
$revalidation = [pscustomobject]@{
  required = ($Kind -eq 'pitfall')
  cadenceDays = if($Kind -eq 'pitfall'){$RevalidateAfterDays}else{0}
  dueAt = if($Kind -eq 'pitfall'){$nowDate.AddDays($RevalidateAfterDays).ToString('yyyy-MM-dd HH:mm:ss')}else{''}
  status = if($Kind -eq 'pitfall'){'current'}else{'not_applicable'}
}
$pitfallIndexLines = if ($Kind -eq 'pitfall') {
@"
- Root Cause: $RootCause
- Prevention Gates: $((@($PreventionGates) | ForEach-Object { "``$_``" }) -join ', ')
- Revalidation: $($revalidation.status); due ``$($revalidation.dueAt)``; cadenceDays=$($revalidation.cadenceDays)
"@
} else { '' }

$experience = [pscustomobject]@{
  schema = 'super-brain.experience.v2'
  id = $safeId
  title = $Title
  kind = $Kind
  status = $Status
  scope = $Scope
  triggers = @($Triggers)
  symptoms = @($Symptoms)
  do = @($Do)
  dont = @($Dont)
  evidence = @($Evidence)
  rootCause = $RootCause
  preventionGates = @($PreventionGates)
  revalidation = $revalidation
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
- Kind: $Kind
- Status: $Status
- Confidence: $([Math]::Round($Confidence, 2))
- Verified Uses: $VerifiedUses
- Triggers: $((@($Triggers) | ForEach-Object { "``$_``" }) -join ', ')
- Scope: $Scope
- Recall Query: ``$RecallQuery``
- Evidence Paths: $((@($Evidence) | ForEach-Object { "``$_``" }) -join ', ')
$pitfallIndexLines
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

$result = [pscustomobject]@{ ok = $true; id = $safeId; kind=$Kind; scope = $Scope; verifiedUses = $VerifiedUses; revalidation=$revalidation; capacity = [pscustomobject]@{ maxEntries=$maxEntries; maxIndexChars=$maxIndexChars }; path = $path; index = $indexPath }
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { Write-Host "WRITE_EXPERIENCE_OK id=$safeId path=$path" }
