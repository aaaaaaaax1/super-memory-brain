param(
  [ValidateSet('Status','Upsert','Complete','Block','Skip','Clear')]
  [string]$Action = 'Status',
  [string]$TaskId = '',
  [string]$Goal = '',
  [string]$StepId = '',
  [string]$Step = '',
  [string]$Phase = '',
  [string]$NextAction = '',
  [string[]]$Evidence = @(),
  [string[]]$RelatedFiles = @(),
  [string[]]$VerificationCommands = @(),
  [string[]]$VerificationResults = @(),
  [string[]]$Blockers = @(),
  [string]$Reason = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$ledgerPath = Join-Path $workspace 'step-ledger.json'
$statusPath = Join-Path $workspace 'last-step-ledger.json'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Limit-Text([string]$Text, [int]$Max = 220) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ($Text -replace '\s+', ' ').Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}
function Limit-List([string[]]$Items, [int]$MaxItems = 12, [int]$MaxChars = 180) {
  return @(@($Items) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars })
}
function Read-Ledger {
  if (Test-Path -LiteralPath $ledgerPath) {
    try { return Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{
    schema = 'super-brain.step-ledger.v3'
    updatedAt = ''
    version = [string]$manifest.version
    taskId = ''
    goal = ''
    steps = @()
    openSteps = @()
    completedSteps = @()
    blockedSteps = @()
    skippedSteps = @()
    guard = 'Before completion, open/blocked steps must be completed, skipped with reason, or explicitly reported as remaining.'
  }
}
function Ensure-Ledger($Ledger) {
  if (-not $Ledger.PSObject.Properties['schema']) { $Ledger | Add-Member -NotePropertyName schema -NotePropertyValue 'super-brain.step-ledger.v3' -Force }
  $Ledger.schema = 'super-brain.step-ledger.v3'
  foreach ($name in @('steps','openSteps','completedSteps','blockedSteps','skippedSteps')) {
    if (-not $Ledger.PSObject.Properties[$name]) { $Ledger | Add-Member -NotePropertyName $name -NotePropertyValue @() -Force }
  }
  if (-not $Ledger.PSObject.Properties['guard']) { $Ledger | Add-Member -NotePropertyName guard -NotePropertyValue 'Before completion, open/blocked steps must be completed, skipped with reason, or explicitly reported as remaining.' -Force }
  return $Ledger
}
function New-StepId { return 'step-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')) }
function New-Step([string]$Id, [string]$Status) {
  if ([string]::IsNullOrWhiteSpace($Id)) { $Id = New-StepId }
  return [pscustomobject]@{
    stepId = Limit-Text $Id 120
    step = Limit-Text $Step 260
    status = $Status
    phase = Limit-Text $Phase 120
    evidence = @(Limit-List $Evidence 12 180)
    relatedFiles = @(Limit-List $RelatedFiles 12 180)
    verificationCommands = @(Limit-List $VerificationCommands 8 180)
    verificationResults = @(Limit-List $VerificationResults 8 180)
    blockers = @(Limit-List $Blockers 8 180)
    reason = Limit-Text $Reason 220
    nextAction = Limit-Text $NextAction 220
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
}
function Merge-Unique($Existing, [string[]]$Incoming, [int]$MaxItems = 12, [int]$MaxChars = 180) {
  return @(Limit-List @(@($Existing) + @($Incoming)) $MaxItems $MaxChars | Select-Object -Unique)
}
function Update-Buckets($Ledger) {
  $Ledger.openSteps = @($Ledger.steps | Where-Object { $_.status -in @('open','active','in_progress') })
  $Ledger.completedSteps = @($Ledger.steps | Where-Object { $_.status -eq 'completed' })
  $Ledger.blockedSteps = @($Ledger.steps | Where-Object { $_.status -eq 'blocked' })
  $Ledger.skippedSteps = @($Ledger.steps | Where-Object { $_.status -eq 'skipped' })
  return $Ledger
}
function Find-StepIndex($Steps, [string]$Id, [string]$Text) {
  for ($i = 0; $i -lt @($Steps).Count; $i++) {
    if (-not [string]::IsNullOrWhiteSpace($Id) -and [string]$Steps[$i].stepId -eq $Id) { return $i }
    if ([string]::IsNullOrWhiteSpace($Id) -and -not [string]::IsNullOrWhiteSpace($Text) -and [string]$Steps[$i].step -eq (Limit-Text $Text 260)) { return $i }
  }
  return -1
}

$ledger = Ensure-Ledger (Read-Ledger)
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $ledger.taskId = Limit-Text $TaskId 120 }
if (-not [string]::IsNullOrWhiteSpace($Goal)) { $ledger.goal = Limit-Text $Goal 360 }

if ($Action -eq 'Clear') {
  $ledger.steps = @(); $ledger.openSteps = @(); $ledger.completedSteps = @(); $ledger.blockedSteps = @(); $ledger.skippedSteps = @()
} elseif ($Action -ne 'Status') {
  $status = if ($Action -eq 'Complete') { 'completed' } elseif ($Action -eq 'Block') { 'blocked' } elseif ($Action -eq 'Skip') { 'skipped' } else { 'open' }
  $idx = Find-StepIndex @($ledger.steps) $StepId $Step
  if ($idx -lt 0) {
    if ([string]::IsNullOrWhiteSpace($Step)) { throw 'Step is required when creating a ledger entry.' }
    $ledger.steps = @(@($ledger.steps) + @(New-Step $StepId $status))
  } else {
    $entry = $ledger.steps[$idx]
    $entry.status = $status
    if (-not [string]::IsNullOrWhiteSpace($Step)) { $entry.step = Limit-Text $Step 260 }
    if (-not [string]::IsNullOrWhiteSpace($Phase)) { $entry.phase = Limit-Text $Phase 120 }
    if (-not [string]::IsNullOrWhiteSpace($NextAction)) { $entry.nextAction = Limit-Text $NextAction 220 }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $entry.reason = Limit-Text $Reason 220 }
    $entry.evidence = @(Merge-Unique $entry.evidence $Evidence 12 180)
    $entry.relatedFiles = @(Merge-Unique $entry.relatedFiles $RelatedFiles 12 180)
    $entry.verificationCommands = @(Merge-Unique $entry.verificationCommands $VerificationCommands 8 180)
    $entry.verificationResults = @(Merge-Unique $entry.verificationResults $VerificationResults 8 180)
    $entry.blockers = @(Merge-Unique $entry.blockers $Blockers 8 180)
    $entry.updatedAt = $now
    $ledger.steps[$idx] = $entry
  }
}
$ledger.updatedAt = $now
$ledger.version = [string]$manifest.version
$ledger = Update-Buckets $ledger
Write-JsonUtf8NoBom $ledgerPath $ledger 12

$result = [pscustomobject]@{
  ok = $true
  action = $Action
  checkedAt = $now
  version = [string]$manifest.version
  taskId = [string]$ledger.taskId
  goal = [string]$ledger.goal
  counts = [pscustomobject]@{ open=@($ledger.openSteps).Count; blocked=@($ledger.blockedSteps).Count; completed=@($ledger.completedSteps).Count; skipped=@($ledger.skippedSteps).Count; total=@($ledger.steps).Count }
  nextAction = if (@($ledger.openSteps).Count -gt 0) { [string]$ledger.openSteps[0].nextAction } elseif (@($ledger.blockedSteps).Count -gt 0) { 'Resolve or skip blocked steps before completion.' } else { 'No open step.' }
  ledgerPath = $ledgerPath
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 8
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "STEP_LEDGER action=$Action open=$($result.counts.open) blocked=$($result.counts.blocked) completed=$($result.counts.completed) skipped=$($result.counts.skipped) status=$statusPath" }
exit 0
