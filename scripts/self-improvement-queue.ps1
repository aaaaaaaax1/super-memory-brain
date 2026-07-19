param(
  [ValidateSet('Status','Collect','Maintain','Resolve')]
  [string]$Action = 'Status',
  [switch]$Json,
  [string]$Summary = '',
  [string]$TaskId = '',
  [string[]]$Evidence = @(),
  [string]$WorkspaceRoot = '',
  [int]$MaxActive = 32,
  [int]$ArchiveAfterDays = 14,
  [string]$CandidateId = '',
  [ValidateSet('resolved','adopted','rejected','duplicate','superseded','blocked')]
  [string]$Resolution = 'resolved',
  [string[]]$ResolutionEvidence = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$queuePath = Join-Path $workspace 'self-improvement-queue.json'
$lastPath = Join-Path $workspace 'last-self-improvement-queue.json'
$archiveRoot = Join-Path $workspace 'archive\self-improvement'
$reflectionRoot = Join-Path $workspace 'reflection\candidates'
if ($MaxActive -lt 8) { $MaxActive = 8 }
if ($ArchiveAfterDays -lt 1) { $ArchiveAfterDays = 1 }

function Limit-Text([string]$Value, [int]$Max = 420) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $normalized = $Value.Trim() -replace '\s+', ' '
  if ($normalized.Length -gt $Max) { return $normalized.Substring(0, $Max) + '...' }
  return $normalized
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function New-Queue {
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.self-improvement-queue.v2'
    version = [string]$manifest.version
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    updatedAt = ''
    items = @()
  }
}

function Read-Queue {
  $queue = Read-JsonFile $queuePath
  if (-not $queue) { return New-Queue }
  return $queue
}

function Get-CompactHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..11] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-FamilyKey([string]$Kind, [string]$Title, [string]$Source, [string]$Target = '', [string]$Scope = '') {
  return 'improvement-' + (Get-CompactHash (($Kind.Trim().ToLowerInvariant()) + '|' + ($Title.Trim().ToLowerInvariant()) + '|' + ($Source.Trim().ToLowerInvariant()) + '|' + ($Target.Trim().ToLowerInvariant()) + '|' + ($Scope.Trim().ToLowerInvariant())))
}

function Get-ItemFamilyKey($Item) {
  if ($Item.PSObject.Properties['familyKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.familyKey)) { return [string]$Item.familyKey }
  $target = if ($Item.PSObject.Properties['target']) { [string]$Item.target } else { '' }
  $scope = if ($Item.PSObject.Properties['scope']) { [string]$Item.scope } else { '' }
  return Get-FamilyKey ([string]$Item.kind) ([string]$Item.title) ([string]$Item.source) $target $scope
}

function Get-PriorityRank([string]$Priority) {
  switch ($Priority) { 'high' { return 0 }; 'medium' { return 1 }; default { return 2 } }
}

function Get-StatusRank([string]$Status) {
  switch ($Status) { 'candidate' { return 0 }; 'blocked' { return 1 }; default { return 2 } }
}

function Test-PrivateText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -match '(?i)(api[_-]?key|password|passwd|token|cookie|secret|private[_-]?key|authorization:)')
}

function Get-DateValue([object]$Value, [datetime]$Fallback = [datetime]::MinValue) {
  $parsed = [datetime]::MinValue
  if ($null -ne $Value -and [datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
  return $Fallback
}

function Merge-FamilyItems([object[]]$Items) {
  $families = New-Object System.Collections.ArrayList
  foreach ($group in @($Items | Group-Object { Get-ItemFamilyKey $_ })) {
    $members = @($group.Group | Sort-Object @{Expression={ Get-DateValue $_.lastSeenAt (Get-DateValue $_.createdAt) };Descending=$true})
    $latest = $members[0]
    $createdValues = @($members | ForEach-Object { Get-DateValue $_.createdAt } | Where-Object { $_ -ne [datetime]::MinValue })
    $lastValues = @($members | ForEach-Object { Get-DateValue $_.lastSeenAt (Get-DateValue $_.createdAt) } | Where-Object { $_ -ne [datetime]::MinValue })
    $latest | Add-Member -NotePropertyName familyKey -NotePropertyValue ([string]$group.Name) -Force
    $latest | Add-Member -NotePropertyName status -NotePropertyValue $(if (@($members | Where-Object { [string]$_.status -eq 'candidate' }).Count -gt 0) { 'candidate' } elseif (@($members | Where-Object { [string]$_.status -eq 'blocked' }).Count -gt 0) { 'blocked' } else { [string]$latest.status }) -Force
    $latest | Add-Member -NotePropertyName createdAt -NotePropertyValue $(if ($createdValues.Count -gt 0) { ($createdValues | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    $latest | Add-Member -NotePropertyName lastSeenAt -NotePropertyValue $(if ($lastValues.Count -gt 0) { ($lastValues | Sort-Object -Descending | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    $latest | Add-Member -NotePropertyName seenCount -NotePropertyValue ([int](@($members | ForEach-Object { if ($_.seenCount) { [int]$_.seenCount } else { 1 } } | Measure-Object -Sum).Sum)) -Force
    $latest | Add-Member -NotePropertyName evidence -NotePropertyValue @($members | ForEach-Object { @($_.evidence) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16) -Force
    $latest | Add-Member -NotePropertyName sampleIds -NotePropertyValue @($members | ForEach-Object { @($_.sampleIds) + @($_.sampleId) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16) -Force
    $latest | Add-Member -NotePropertyName mergedInstanceCount -NotePropertyValue $members.Count -Force
    [void]$families.Add($latest)
  }
  return @($families)
}

function Add-OrUpdateFamily([System.Collections.ArrayList]$Items, [string]$Kind, [string]$Title, [string]$Problem, [string]$Expected, [string[]]$EvidenceItems, [string]$Priority, [string]$Source, [string]$Target = '', [string]$Scope = '') {
  $familyKey = Get-FamilyKey $Kind $Title $Source $Target $Scope
  $existing = @($Items | Where-Object { (Get-ItemFamilyKey $_) -eq $familyKey } | Select-Object -First 1)
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($existing.Count -gt 0) {
    $item = $existing[0]
    $item.lastSeenAt = $now
    $item.seenCount = $(if ($item.seenCount) { [int]$item.seenCount + 1 } else { 2 })
    $item.problem = Limit-Text $Problem 520
    $item.expected = Limit-Text $Expected 520
    $item.evidence = @(@($item.evidence) + @($EvidenceItems) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16)
    return $false
  }
  $candidate = [pscustomobject]@{
    id = 'improve-' + $familyKey.Substring($familyKey.Length - 12)
    familyKey = $familyKey
    kind = $Kind
    title = Limit-Text $Title 140
    status = 'candidate'
    priority = $Priority
    problem = Limit-Text $Problem 520
    expected = Limit-Text $Expected 520
    evidence = @($EvidenceItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16)
    source = $Source
    target = $Target
    scope = $Scope
    createdAt = $now
    lastSeenAt = $now
    seenCount = 1
    mergedInstanceCount = 1
    safety = [pscustomobject]@{ candidateOnly=$true; noAutomaticSkillMutation=$true; noExternalPublish=$true; requiresEvidenceBeforePromotion=$true; requiresConfirmationForRuleOrSkillChange=$true }
    nextAction = 'Verify reuse and scope, then close as adopted, rejected, duplicate, superseded, or blocked through a governed learning action.'
  }
  [void]$Items.Add($candidate)
  return $true
}

function Get-QueueSummary([object[]]$Items, [int]$Added = 0, [int]$Archived = 0, [int]$Merged = 0) {
  return [pscustomobject]@{
    total = @($Items).Count
    active = @($Items | Where-Object { [string]$_.status -in @('candidate','blocked') }).Count
    candidate = @($Items | Where-Object { [string]$_.status -eq 'candidate' }).Count
    blocked = @($Items | Where-Object { [string]$_.status -eq 'blocked' }).Count
    high = @($Items | Where-Object { $_.priority -eq 'high' }).Count
    medium = @($Items | Where-Object { $_.priority -eq 'medium' }).Count
    low = @($Items | Where-Object { $_.priority -eq 'low' }).Count
    added = $Added
    archived = $Archived
    merged = $Merged
    maxActive = $MaxActive
    overBudget = (@($Items | Where-Object { [string]$_.status -in @('candidate','blocked') }).Count -gt $MaxActive)
  }
}

function Write-Archive([object[]]$QueueItems, [object[]]$ReflectionItems, [string]$Reason) {
  if (@($QueueItems).Count -eq 0 -and @($ReflectionItems).Count -eq 0) { return $null }
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $path = Join-Path $archiveRoot ("candidates-$stamp.json")
  $archive = [pscustomobject]@{
    schema = 'super-brain.self-improvement-archive.v1'
    archivedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    reason = $Reason
    sourceQueue = $queuePath
    queueItems = @($QueueItems)
    reflectionItems = @($ReflectionItems)
    restore = 'Copy selected queueItems back into self-improvement-queue.json or reflectionItems back to reflection/candidates after review.'
  }
  Write-JsonUtf8NoBom $path $archive 16
  return $path
}

function Read-ReflectionCandidates {
  $rows = New-Object System.Collections.ArrayList
  foreach ($file in @(Get-ChildItem -LiteralPath $reflectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $candidate = Read-JsonFile $file.FullName
    if ($candidate) { [void]$rows.Add([pscustomobject]@{ path=$file.FullName; lastWriteTime=$file.LastWriteTime; value=$candidate }) }
  }
  return @($rows)
}

function Sync-ReflectionLifecycle([System.Collections.ArrayList]$Items, [object[]]$ReflectionRows) {
  $changed = 0
  $terminalStatuses = @('resolved','adopted','rejected','duplicate','superseded','blocked','closed')
  foreach ($item in @($Items | Where-Object { [string]$_.source -eq 'reflection-promotion.ps1' })) {
    $matches = @($ReflectionRows | Where-Object {
      [string]$_.value.title -eq [string]$item.title -and
      ([string]::IsNullOrWhiteSpace([string]$item.target) -or [string]$_.value.target -eq [string]$item.target) -and
      ([string]::IsNullOrWhiteSpace([string]$item.scope) -or [string]$_.value.scope -eq [string]$item.scope) -and
      $_.value.lifecycle -and [string]$_.value.lifecycle.status -in $terminalStatuses
    } | Sort-Object { Get-DateValue $_.value.lifecycle.lastSeenAt $_.lastWriteTime } -Descending)
    if ($matches.Count -eq 0) { continue }
    $match = $matches[0]
    $item.status = if ([string]$match.value.lifecycle.status -eq 'closed') { 'resolved' } else { [string]$match.value.lifecycle.status }
    $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @('reflection-candidate:' + [string]$match.value.id, 'reflection-status:' + [string]$match.value.lifecycle.status) -Force
    $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'reflection-promotion.ps1' -Force
    $changed++
  }
  return $changed
}

$queue = Read-Queue
$originalItems = @($queue.items)
$mergedItems = @(Merge-FamilyItems $originalItems)
$mergeCount = [Math]::Max(0, $originalItems.Count - $mergedItems.Count)
$mergedSourceItems = @($originalItems | Group-Object { Get-ItemFamilyKey $_ } | Where-Object { $_.Count -gt 1 } | ForEach-Object { @($_.Group) })
$items = New-Object System.Collections.ArrayList
foreach ($item in $mergedItems) { [void]$items.Add($item) }
$added = 0
$archived = 0
$archivePath = ''
$reflectionArchived = 0
$sideEffectFree = ($Action -eq 'Status')
$resolved = 0

if ($Action -eq 'Resolve') {
  if ([string]::IsNullOrWhiteSpace($CandidateId)) { throw 'CANDIDATE_ID_REQUIRED: Resolve requires -CandidateId.' }
  if (@($ResolutionEvidence | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw 'RESOLUTION_EVIDENCE_REQUIRED: Resolve requires compact verified evidence.' }
  if (Test-PrivateText (($ResolutionEvidence -join '; '))) { throw 'RESOLUTION_PRIVACY_GATE: evidence contains secret-like material.' }
  $matches = @($items | Where-Object { [string]$_.id -eq $CandidateId -or [string](Get-ItemFamilyKey $_) -eq $CandidateId })
  if ($matches.Count -ne 1) { throw "CANDIDATE_NOT_FOUND_OR_AMBIGUOUS id=$CandidateId matches=$($matches.Count)" }
  $item = $matches[0]
  $item.status = $Resolution
  $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
  $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @($ResolutionEvidence | ForEach-Object { Limit-Text ([string]$_) 360 } | Select-Object -Unique | Select-Object -First 8) -Force
  $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'self-improvement-queue.ps1:Resolve' -Force
  $resolved = 1
}

if ($Action -in @('Collect','Maintain')) {
  $hygiene = Read-JsonFile (Join-Path $workspace 'last-memory-hygiene.json')
  $lifecycle = Read-JsonFile (Join-Path $workspace 'last-workspace-lifecycle.json')
  $doctor = $null
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    try { $doctor = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json | ConvertFrom-Json } catch {}
  }
  $reflection = $null
  $reflectionSummary = if ([string]::IsNullOrWhiteSpace($Summary)) { 'post-task self-improvement queue scan' } else { $Summary }
  try { $reflection = & (Join-Path $PSScriptRoot 'reflection-promotion.ps1') -Mode Preview -TriggerType manual -Summary $reflectionSummary -Evidence (($Evidence + @('self-improvement-queue.ps1')) -join '; ') -Scope 'super-memory-brain' -WorkspaceRoot $workspace -Json | ConvertFrom-Json } catch {}

  if ($hygiene -and [int]$hygiene.requiresConfirmation -gt 0) {
    if (Add-OrUpdateFamily $items 'hygiene_confirmation' 'Memory hygiene found items requiring confirmation' 'Automatic memory hygiene found unsafe items that cannot be changed automatically.' 'Surface only current high-risk cleanup work for explicit confirmation.' @('last-memory-hygiene.json requiresConfirmation=' + [string]$hygiene.requiresConfirmation) 'high' 'auto-hygiene-runner.ps1') { $added++ }
  }
  if ($hygiene -and $hygiene.after -and [int]$hygiene.after.tooLongCount -gt 0) {
    if (Add-OrUpdateFamily $items 'hygiene_gap' 'Long memory entries remain after hygiene scan' 'Some memory entries remain above the compactness budget.' 'Compress low-risk long memories with archived evidence and leave risky entries for confirmation.' @('last-memory-hygiene.json tooLongAfter=' + [string]$hygiene.after.tooLongCount) 'medium' 'auto-hygiene-runner.ps1') { $added++ }
  }
  if ($lifecycle -and [int]$lifecycle.requiresConfirmation -gt 0) {
    if (Add-OrUpdateFamily $items 'lifecycle_confirmation' 'Workspace lifecycle found items requiring confirmation' 'Workspace cleanup found artifacts that must not be changed automatically.' 'Track one current family and require explicit confirmation before moving or deleting evidence.' @('last-workspace-lifecycle.json requiresConfirmation=' + [string]$lifecycle.requiresConfirmation) 'medium' 'workspace-lifecycle-manager.ps1') { $added++ }
  }
  if ($lifecycle -and [int]$lifecycle.errorCount -gt 0) {
    if (Add-OrUpdateFamily $items 'lifecycle_error' 'Workspace lifecycle maintenance had errors' 'Automatic lifecycle maintenance did not fully complete.' 'Fix the current lifecycle failure so safe maintenance remains automatic.' @('last-workspace-lifecycle.json errorCount=' + [string]$lifecycle.errorCount) 'high' 'workspace-lifecycle-manager.ps1') { $added++ }
  }
  if ($doctor -and $doctor.riskSummary -and [int]$doctor.riskSummary.total -gt 0) {
    $riskCodes = @($doctor.risks | ForEach-Object { [string]$_.code } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (Add-OrUpdateFamily $items 'doctor_risk' 'Doctor still reports risks after maintenance' 'Health risks remain after the maintenance loop.' 'Turn recurring current doctor risks into specific guarded fixes.' @('doctor risk codes=' + ($riskCodes -join ',')) 'high' 'doctor.ps1') { $added++ }
  }
  if ($reflection -and $reflection.candidates) {
    foreach ($candidate in @($reflection.candidates | Where-Object { $_.target -ne 'none' -and $_.lifecycle.status -eq 'candidate' } | Select-Object -First 6)) {
      $kind = if ($candidate.candidateType) { [string]$candidate.candidateType } else { 'reflection_candidate' }
      $priority = if ([double]$candidate.confidence -ge 0.82) { 'high' } elseif ([double]$candidate.confidence -ge 0.72) { 'medium' } else { 'low' }
      if (Add-OrUpdateFamily $items $kind ([string]$candidate.title) ([string]$candidate.summary) 'Promote only through governed learning gates after evidence and scope checks.' @([string]$candidate.sampleId) $priority 'reflection-promotion.ps1' ([string]$candidate.target) ([string]$candidate.scope)) { $added++ }
    }
  }
}

if ($Action -eq 'Maintain') {
  $now = Get-Date
  $reflectionRows = Read-ReflectionCandidates
  $resolved += Sync-ReflectionLifecycle $items $reflectionRows
  $sorted = @($items | Sort-Object @{Expression={Get-StatusRank ([string]$_.status)}}, @{Expression={Get-PriorityRank ([string]$_.priority)}}, @{Expression={[int]$_.seenCount};Descending=$true}, @{Expression={Get-DateValue $_.lastSeenAt};Descending=$true})
  $keep = New-Object System.Collections.ArrayList
  $archiveItems = New-Object System.Collections.ArrayList
  foreach ($item in $sorted) {
    $isClosed = [string]$item.status -in @('resolved','adopted','rejected','duplicate','superseded','closed')
    $ageDays = ($now - (Get-DateValue $item.lastSeenAt (Get-DateValue $item.createdAt $now))).TotalDays
    $staleSingle = ($ageDays -ge $ArchiveAfterDays -and [int]$item.seenCount -le 1 -and [string]$item.priority -ne 'high')
    $overBudget = (@($keep | Where-Object { [string]$_.status -in @('candidate','blocked') }).Count -ge $MaxActive -and [string]$item.status -in @('candidate','blocked'))
    if ($isClosed -or $staleSingle -or $overBudget) { [void]$archiveItems.Add($item) } else { [void]$keep.Add($item) }
  }

  $reflectionKeepByFamily = @{}
  $reflectionArchive = New-Object System.Collections.ArrayList
  foreach ($row in @($reflectionRows | Sort-Object { Get-DateValue $_.value.lifecycle.lastSeenAt $_.lastWriteTime } -Descending)) {
    $family = if ($row.value.familyKey) { [string]$row.value.familyKey } else { ([string]$row.value.target + '|' + [string]$row.value.title + '|' + [string]$row.value.scope) }
    $closed = ($row.value.lifecycle -and [string]$row.value.lifecycle.status -in @('adopted','rejected','duplicate','superseded','closed','blocked'))
    if ($closed -or $reflectionKeepByFamily.ContainsKey($family)) {
      [void]$reflectionArchive.Add([pscustomobject]@{ path=$row.path; value=$row.value })
    } else {
      $reflectionKeepByFamily[$family] = $true
    }
  }
  $queueArchiveItems = @(@($mergedSourceItems) + @($archiveItems))
  $archivePath = Write-Archive $queueArchiveItems @($reflectionArchive) 'bounded lifecycle maintenance; merged source instances, duplicate, closed, stale singleton, or active-budget overflow'
  if ($archivePath) {
    foreach ($row in $reflectionArchive) { Remove-Item -LiteralPath $row.path -Force }
    $reflectionArchived = @($reflectionArchive).Count
  }
  $archived = @($queueArchiveItems).Count
  $items = $keep
}

$sortedItems = @($items | Sort-Object @{Expression={Get-StatusRank ([string]$_.status)}}, @{Expression={Get-PriorityRank ([string]$_.priority)}}, @{Expression={[int]$_.seenCount};Descending=$true}, @{Expression={Get-DateValue $_.lastSeenAt};Descending=$true})
$queueSummary = Get-QueueSummary $sortedItems $added $archived $mergeCount

if ($Action -ne 'Status') {
  if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
  $queue | Add-Member -NotePropertyName ok -NotePropertyValue $true -Force
  $queue | Add-Member -NotePropertyName schema -NotePropertyValue 'super-brain.self-improvement-queue.v2' -Force
  $queue | Add-Member -NotePropertyName version -NotePropertyValue ([string]$manifest.version) -Force
  $queue | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
  $queue | Add-Member -NotePropertyName items -NotePropertyValue $sortedItems -Force
  $queue | Add-Member -NotePropertyName summary -NotePropertyValue $queueSummary -Force
  Write-JsonUtf8NoBom $queuePath $queue 16
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.self-improvement-queue-result.v2'
  version = [string]$manifest.version
  action = $Action
  sideEffectFree = $sideEffectFree
  queuePath = $queuePath
  total = $queueSummary.total
  active = $queueSummary.active
  candidate = $queueSummary.candidate
  blocked = $queueSummary.blocked
  added = $added
  merged = $mergeCount
  archived = $archived
  resolved = $resolved
  reflectionArchived = $reflectionArchived
  high = $queueSummary.high
  medium = $queueSummary.medium
  low = $queueSummary.low
  maxActive = $MaxActive
  overBudget = $queueSummary.overBudget
  archivePath = $archivePath
  recent = @($sortedItems | Select-Object -First 8)
  guard = if ($Action -eq 'Status') { 'Status is read-only: no doctor, reflection generation, queue write, last-result write, or archive mutation.' } else { 'Candidates are family-deduplicated and bounded; maintenance archives instead of deleting evidence.' }
}

if ($Action -ne 'Status') { Write-JsonUtf8NoBom $lastPath $result 12 }
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SELF_IMPROVEMENT_QUEUE action=$Action ok=True total=$($result.total) active=$($result.active) added=$added merged=$mergeCount archived=$archived" }
exit 0
