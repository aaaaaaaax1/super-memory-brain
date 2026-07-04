param(
  [switch]$Json,
  [string]$Summary = '',
  [string]$TaskId = '',
  [string[]]$Evidence = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$queuePath = Join-Path $workspace 'self-improvement-queue.json'
$lastPath = Join-Path $workspace 'last-self-improvement-queue.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Limit-Text([string]$Value, [int]$Max = 420) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Read-WorkspaceJson([string]$Name) {
  $p = Join-Path $workspace $Name
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Read-Queue {
  if (Test-Path -LiteralPath $queuePath) {
    try { return Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.self-improvement-queue.v1'
    version = [string]$manifest.version
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    updatedAt = ''
    items = @()
  }
}

function New-QueueId([string]$Kind, [string]$Title, [string]$EvidenceText) {
  $seed = "$Kind|$Title|$EvidenceText"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))[0..5] | ForEach-Object { $_.ToString('x2') })
  return 'improve-' + $hash
}

function Add-Candidate([System.Collections.ArrayList]$Items, [string]$Kind, [string]$Title, [string]$Problem, [string]$Expected, [string]$EvidenceText, [string]$Priority, [string]$Source) {
  $id = New-QueueId $Kind $Title $EvidenceText
  $existing = @($Items | Where-Object { $_.id -eq $id })
  if ($existing.Count -gt 0) {
    foreach ($item in $existing) {
      $item.lastSeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      $item.seenCount = [int]$item.seenCount + 1
      if ($EvidenceText -and @($item.evidence) -notcontains $EvidenceText) { $item.evidence = @(@($item.evidence) + @($EvidenceText) | Select-Object -Unique) }
    }
    return $false
  }
  $candidate = [pscustomobject]@{
    id = $id
    kind = $Kind
    title = Limit-Text $Title 140
    status = 'candidate'
    priority = $Priority
    problem = Limit-Text $Problem 520
    expected = Limit-Text $Expected 520
    evidence = @(@($Evidence) + @($EvidenceText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Select-Object -First 10)
    source = $Source
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    lastSeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    seenCount = 1
    safety = [pscustomobject]@{
      candidateOnly = $true
      noAutomaticSkillMutation = $true
      noExternalPublish = $true
      requiresEvidenceBeforePromotion = $true
      requiresConfirmationForRuleOrSkillChange = $true
    }
    nextAction = 'Review evidence, verify scope, then promote through reflection-promotion or skill-evolution only when approved and safe.'
  }
  [void]$Items.Add($candidate)
  return $true
}

$queue = Read-Queue
$items = New-Object System.Collections.ArrayList
foreach ($item in @($queue.items)) { [void]$items.Add($item) }
$added = 0

$hygiene = Read-WorkspaceJson 'last-memory-hygiene.json'
$lifecycle = Read-WorkspaceJson 'last-workspace-lifecycle.json'
$doctor = $null
try { $doctor = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json | ConvertFrom-Json } catch {}
$reflection = $null
$reflectionSummary = if ([string]::IsNullOrWhiteSpace($Summary)) { 'post-task self-improvement queue scan' } else { $Summary }
try { $reflection = & (Join-Path $PSScriptRoot 'reflection-promotion.ps1') -Mode Preview -TriggerType manual -Summary $reflectionSummary -Evidence (($Evidence + @('self-improvement-queue.ps1')) -join '; ') -Scope 'super-memory-brain' -Json | ConvertFrom-Json } catch {}

if ($hygiene) {
  if ([int]$hygiene.requiresConfirmation -gt 0) {
    if (Add-Candidate $items 'hygiene_confirmation' 'Memory hygiene found items requiring confirmation' 'Automatic memory hygiene found private-pattern or other unsafe items that cannot be fixed automatically.' 'Keep safe automatic fixes running, but surface high-risk memory cleanup as explicit confirmation work.' ('last-memory-hygiene.json requiresConfirmation=' + [string]$hygiene.requiresConfirmation) 'high' 'auto-hygiene-runner.ps1') { $added += 1 }
  }
  if ($hygiene.before -and $hygiene.after -and [int]$hygiene.after.tooLongCount -gt 0) {
    if (Add-Candidate $items 'hygiene_gap' 'Long memory entries remain after hygiene scan' 'Some memory entries are still above the configured compactness budget.' 'Compress low-risk long memories with original evidence archived, and leave risky entries for confirmation.' ('last-memory-hygiene.json tooLongAfter=' + [string]$hygiene.after.tooLongCount) 'medium' 'auto-hygiene-runner.ps1') { $added += 1 }
  }
}

if ($lifecycle) {
  if ([int]$lifecycle.requiresConfirmation -gt 0) {
    if (Add-Candidate $items 'lifecycle_confirmation' 'Workspace lifecycle found items requiring confirmation' 'Workspace cleanup found parse failures, old evidence drafts, or private-risk artifacts that must not be changed automatically.' 'Track them as candidates and require explicit confirmation before moving or deleting evidence.' ('last-workspace-lifecycle.json requiresConfirmation=' + [string]$lifecycle.requiresConfirmation) 'medium' 'workspace-lifecycle-manager.ps1') { $added += 1 }
  }
  if ([int]$lifecycle.errorCount -gt 0) {
    if (Add-Candidate $items 'lifecycle_error' 'Workspace lifecycle maintenance had errors' 'Automatic lifecycle maintenance did not fully complete.' 'Fix the lifecycle maintenance script or the underlying artifact so safe maintenance remains automatic.' ('last-workspace-lifecycle.json errorCount=' + [string]$lifecycle.errorCount) 'high' 'workspace-lifecycle-manager.ps1') { $added += 1 }
  }
}

if ($doctor -and $doctor.riskSummary -and [int]$doctor.riskSummary.total -gt 0) {
  if (Add-Candidate $items 'doctor_risk' 'Doctor still reports risks after maintenance' 'Health risks remain after the maintenance loop.' 'Turn recurring doctor risks into specific guarded fixes rather than requiring the user to ask again.' ('doctor risk total=' + [string]$doctor.riskSummary.total + ' high=' + [string]$doctor.riskSummary.high) 'high' 'doctor.ps1') { $added += 1 }
}

if ($reflection -and $reflection.candidates) {
  foreach ($candidate in @($reflection.candidates | Select-Object -First 6)) {
    $kind = if ($candidate.candidateType) { [string]$candidate.candidateType } else { 'reflection_candidate' }
    $priority = if ([double]$candidate.confidence -ge 0.82) { 'high' } elseif ([double]$candidate.confidence -ge 0.72) { 'medium' } else { 'low' }
    if ($candidate.target -ne 'none') {
      if (Add-Candidate $items $kind ([string]$candidate.title) ([string]$candidate.summary) 'Promote only through governed reflection, learning, or skill evolution gates after evidence and scope checks.' ([string]$candidate.id) $priority 'reflection-promotion.ps1') { $added += 1 }
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($Summary) -and ($Summary -match '(?i)(auto|automatic|hygiene|maintenance|compress|compression|continuation|resume|stale memory|do not remind|repeat remind|overlong memory|memory not updated)')) {
  if (Add-Candidate $items 'user_feedback' 'User feedback should become an automation guard' $Summary 'Do not make the user repeatedly remind Super Brain about proactive safe maintenance and compaction-safe continuation.' (($Evidence + @('visible user feedback')) -join '; ') 'high' 'visible_context') { $added += 1 }
}

$queue | Add-Member -MemberType NoteProperty -Name ok -Value $true -Force
$queue | Add-Member -MemberType NoteProperty -Name version -Value ([string]$manifest.version) -Force
$queue | Add-Member -MemberType NoteProperty -Name updatedAt -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
$queue | Add-Member -MemberType NoteProperty -Name items -Value (@($items | Sort-Object @{ Expression = { if ($_.status -eq 'candidate') { 0 } else { 1 } } }, @{ Expression = { switch ($_.priority) { 'high' { 0 } 'medium' { 1 } default { 2 } } } }, createdAt)) -Force
$queue | Add-Member -MemberType NoteProperty -Name summary -Value ([pscustomobject]@{
  total = @($queue.items).Count
  high = @($queue.items | Where-Object { $_.priority -eq 'high' }).Count
  medium = @($queue.items | Where-Object { $_.priority -eq 'medium' }).Count
  low = @($queue.items | Where-Object { $_.priority -eq 'low' }).Count
  added = $added
}) -Force
Write-JsonUtf8NoBom $queuePath $queue 14
$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.self-improvement-queue-result.v1'
  version = [string]$manifest.version
  queuePath = $queuePath
  total = $queue.summary.total
  added = $added
  high = $queue.summary.high
  medium = $queue.summary.medium
  low = $queue.summary.low
  recent = @($queue.items | Select-Object -First 8)
}
Write-JsonUtf8NoBom $lastPath $result 12
if ($Json) { Get-Content -LiteralPath $lastPath -Raw -Encoding UTF8 } else {
  Write-Host "SELF_IMPROVEMENT_QUEUE ok=True total=$($result.total) added=$($result.added) high=$($result.high) path=$queuePath"
}
exit 0
