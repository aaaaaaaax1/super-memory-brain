[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Mandatory=$true)][string]$InputText,
  [string]$Title = 'Session Compact Note',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$SessionId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$taskIdValue = ([string]$TaskId).Trim()
$workspaceKeyValue = if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { '' } else { Get-SuperBrainWorkspaceKey $WorkspaceKey }

function Limit-CompactText([string]$Value,[int]$Max = 280) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ($Value -replace '\s+',' ').Trim()
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Write-CompactResult([object]$Result) {
  if ($Json) { $Result | ConvertTo-Json -Depth 10 }
  else { Write-Host "SESSION_COMPACT status=$($Result.status) path=$($Result.path)" }
}

function New-CompactionRecoveryCheckpoint {
  $restoreScript = Join-Path $PSScriptRoot 'session-restore.ps1'
  $checkpointScript = Join-Path $PSScriptRoot 'recovery-checkpoint.ps1'
  if (-not (Test-Path -LiteralPath $restoreScript) -or -not (Test-Path -LiteralPath $checkpointScript)) {
    return [pscustomobject]@{ ok=$false; code='SESSION_COMPACT_RECOVERY_RUNTIME_MISSING'; checkpoint=$null }
  }
  try {
    $restoreRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restoreScript -TaskId $taskIdValue -WorkspaceKey $workspaceKeyValue -SessionId $SessionId -Json 2>&1)
    $restoreExit = $LASTEXITCODE
    $restoreText = ($restoreRaw | ForEach-Object { [string]$_ }) -join "`n"
    $restore = if ($restoreText) { ConvertFrom-SuperBrainJsonOutput $restoreText 'session compaction recovery state' } else { $null }
    if ($restoreExit -ne 0 -or -not $restore -or $restore.ok -ne $true) {
      return [pscustomobject]@{ ok=$false; code='SESSION_COMPACT_RECOVERY_STATE_UNAVAILABLE'; checkpoint=$null; restoreCode=$restoreExit }
    }
    $anchor = $restore.instructionAnchor
    $receipt = $restore.continuationReceipt
    $resolution = $restore.executionResolution
    $resume = $restore.resumeReceipt
    $active = $restore.activeCheckpoint
    $instructionHash = if ($anchor -and $anchor.contentHash) { [string]$anchor.contentHash } elseif ($restore.latestUserInstruction) { Get-SuperBrainStableHash ([string]$restore.latestUserInstruction) 64 } else { '' }
    $progressHash = if ($receipt -and $receipt.stateHash) { [string]$receipt.stateHash } elseif ($receipt -and $receipt.payloadHash) { [string]$receipt.payloadHash } elseif ($receipt -and $receipt.receiptHash) { [string]$receipt.receiptHash } else { '' }
    $contractRevision = if ($resolution -and $resolution.contractRevision) { [int]$resolution.contractRevision } elseif ($receipt -and $receipt.contractRevision) { [int]$receipt.contractRevision } else { 0 }
    $planFingerprint = if ($receipt -and $receipt.planFingerprint) { [string]$receipt.planFingerprint } else { '' }
    $currentPhase = if ($resume -and $resume.currentPhase) { [string]$resume.currentPhase } elseif ($active -and $active.currentPhase) { [string]$active.currentPhase } else { '' }
    $currentStep = if ($resume -and $resume.currentStep) { [string]$resume.currentStep } elseif ($active -and $active.currentStep) { [string]$active.currentStep } else { '' }
    $nextAction = if ($resolution -and [string]$resolution.actionAuthorization -eq 'allowed' -and $restore.nextAction) { [string]$restore.nextAction } elseif ($active -and $active.nextAction) { [string]$active.nextAction } else { '' }
    $returnPointJson = if ($resume -and $resume.returnPoint) { $resume.returnPoint | ConvertTo-Json -Depth 8 -Compress } else { '' }
    $returnPointBase64 = if (-not [string]::IsNullOrWhiteSpace($returnPointJson)) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($returnPointJson)) } else { '' }
    $stateHash = Get-SuperBrainStableHash (([ordered]@{ taskId=$taskIdValue; workspaceKey=$workspaceKeyValue; instructionHash=$instructionHash; progressHash=$progressHash; contractRevision=$contractRevision; currentPhase=$currentPhase; currentStep=$currentStep; nextAction=$nextAction; returnPoint=$returnPointJson } | ConvertTo-Json -Depth 10 -Compress)) 64
    $checkpointArgs = @('-Action','Write','-TaskId',$taskIdValue,'-WorkspaceKey',$workspaceKeyValue,'-SessionKey',(Get-SuperBrainHostSessionKey $SessionId),'-ContractRevision',[string]$contractRevision,'-StateHash',$stateHash,'-Source','session-compact.ps1','-Json')
    if ($resolution -and -not [string]::IsNullOrWhiteSpace([string]$resolution.taskInstanceId)) { $checkpointArgs += @('-TaskInstanceId',[string]$resolution.taskInstanceId) }
    if (-not [string]::IsNullOrWhiteSpace($planFingerprint)) { $checkpointArgs += @('-PlanFingerprint',$planFingerprint) }
    if (-not [string]::IsNullOrWhiteSpace($instructionHash)) { $checkpointArgs += @('-LatestInstructionHash',$instructionHash) }
    if (-not [string]::IsNullOrWhiteSpace($progressHash)) { $checkpointArgs += @('-AssistantProgressHash',$progressHash) }
    if (-not [string]::IsNullOrWhiteSpace($currentPhase)) { $checkpointArgs += @('-CurrentPhase',$currentPhase) }
    if (-not [string]::IsNullOrWhiteSpace($currentStep)) { $checkpointArgs += @('-CurrentStep',$currentStep) }
    if (-not [string]::IsNullOrWhiteSpace($nextAction)) { $checkpointArgs += @('-NextAction',$nextAction) }
    if (-not [string]::IsNullOrWhiteSpace($returnPointBase64)) { $checkpointArgs += @('-ReturnPointJsonBase64',$returnPointBase64) }
    $checkpointRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checkpointScript @checkpointArgs 2>&1)
    $checkpointExit = $LASTEXITCODE
    $checkpointText = ($checkpointRaw | ForEach-Object { [string]$_ }) -join "`n"
    $checkpoint = if ($checkpointText) { ConvertFrom-SuperBrainJsonOutput $checkpointText 'session compaction recovery checkpoint' } else { $null }
    if ($checkpointExit -ne 0 -or -not $checkpoint -or $checkpoint.ok -ne $true) {
      return [pscustomobject]@{ ok=$false; code='SESSION_COMPACT_RECOVERY_CHECKPOINT_FAILED'; checkpoint=$checkpoint; restore=$restore }
    }
    return [pscustomobject]@{ ok=$true; code='SESSION_COMPACT_RECOVERY_CHECKPOINT_COMMITTED'; checkpoint=$checkpoint; restore=$restore }
  } catch {
    return [pscustomobject]@{ ok=$false; code='SESSION_COMPACT_RECOVERY_CHECKPOINT_UNEXPECTED'; checkpoint=$null; error=$_.Exception.Message }
  }
}

if ([string]::IsNullOrWhiteSpace($taskIdValue) -or [string]::IsNullOrWhiteSpace($workspaceKeyValue)) {
  $result = [pscustomobject]@{
    ok = $false; schema = 'super-brain.historical-session-note.v2'; status = 'scope_required'
    code = 'SESSION_COMPACT_TASK_SCOPE_REQUIRED'; taskId = $taskIdValue; workspaceKey = $workspaceKeyValue
    guard = 'Historical compaction is task/workspace scoped. The retired global session-notes.md path cannot accept new writes.'
    path = ''
  }
  Write-CompactResult $result
  exit 1
}

if ([Text.Encoding]::UTF8.GetByteCount($InputText) -gt 24000) {
  $result = [pscustomobject]@{
    ok = $false; schema = 'super-brain.historical-session-note.v2'; status = 'input_too_large'
    code = 'SESSION_COMPACT_INPUT_LIMIT'; taskId = $taskIdValue; workspaceKey = $workspaceKeyValue
    guard = 'Do not archive raw long transcripts or streams. Supply a bounded compact source instead.'; path = ''
  }
  Write-CompactResult $result
  exit 1
}

$sensitivePattern = '(?i)(?:api[_-]?key\s*[:=]|authorization\s*[:=]|bearer\s+[a-z0-9._-]{12,}|\bsk-[a-z0-9]{12,}|password\s*[:=])'
if ($InputText -match $sensitivePattern) {
  $result = [pscustomobject]@{
    ok = $false; schema = 'super-brain.historical-session-note.v2'; status = 'sensitive_input_rejected'
    code = 'SESSION_COMPACT_SENSITIVE_INPUT_REJECTED'; taskId = $taskIdValue; workspaceKey = $workspaceKeyValue
    guard = 'Historical compaction never stores credentials, authorization material, or raw secret-bearing streams.'; path = ''
  }
  Write-CompactResult $result
  exit 1
}

$recovery = New-CompactionRecoveryCheckpoint
if (-not $recovery.ok) {
  $result = [pscustomobject]@{
    ok = $false; schema = 'super-brain.historical-session-note.v2'; status = 'recovery_checkpoint_failed'
    code = [string]$recovery.code; taskId = $taskIdValue; workspaceKey = $workspaceKeyValue
    guard = 'Context compaction is withheld until the scoped recovery checkpoint is atomically committed.'
    recoveryCheckpoint = $recovery.checkpoint; error = if($recovery.PSObject.Properties['error']){[string]$recovery.error}else{''}; path = ''
  }
  Write-CompactResult $result
  exit 1
}

$lines = @($InputText -split '[\r\n]+' | ForEach-Object { Limit-CompactText ([string]$_) 280 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$important = @($lines | Where-Object { $_ -match '(?i)\b(error|failed|missing|verified|done|decision|todo|next|blocked|path|version)\b' } | Select-Object -First 12)
if ($important.Count -eq 0) { $important = @($lines | Select-Object -First 10) }

$archiveRoot = Join-Path (Get-SuperBrainWritableArchiveRoot $Root) 'historical-session-notes'
$taskArchiveRoot = Join-Path $archiveRoot (Get-SuperBrainCanonicalTaskToken (Get-SuperBrainTaskWorkspaceToken $taskIdValue $workspaceKeyValue))
if (-not (Test-Path -LiteralPath $taskArchiveRoot)) { New-Item -ItemType Directory -Force -Path $taskArchiveRoot | Out-Null }
$checkpointRecord = if ($recovery.checkpoint -and $recovery.checkpoint.checkpoint) { $recovery.checkpoint.checkpoint } else { $null }
$sourceHash = Get-SuperBrainStableHash $InputText 64
$checkpointHash = if ($checkpointRecord) { [string]$checkpointRecord.checkpointHash } else { '' }
$noteFingerprintPayload = [ordered]@{
  taskId = $taskIdValue
  workspaceKey = $workspaceKeyValue
  sessionKey = Get-SuperBrainHostSessionKey $SessionId
  title = Limit-CompactText $Title 160
  sourceHash = $sourceHash
  checkpointHash = $checkpointHash
}
$noteFingerprint = Get-SuperBrainStableHash (($noteFingerprintPayload | ConvertTo-Json -Depth 8 -Compress)) 32
$noteId = 'note-' + $noteFingerprint
$path = Join-Path $taskArchiveRoot ($noteId + '.json')
$idempotent = $false
$record = $null
if (Test-Path -LiteralPath $path) {
  try {
    $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$existing.schema -eq 'super-brain.historical-session-note.v2' -and
        [string]$existing.taskId -eq $taskIdValue -and
        (Test-SuperBrainWorkspaceKey ([string]$existing.workspaceKey) $workspaceKeyValue) -and
        [string]$existing.sourceHash -eq $sourceHash -and
        [string]$existing.checkpointHash -eq $checkpointHash) {
      $record = $existing
      $idempotent = $true
    }
  } catch {}
}
if (-not $idempotent) {
  $capturedAt = Get-SuperBrainUtcTimestamp
  $record = [pscustomobject]@{
    schema = 'super-brain.historical-session-note.v2'
    noteId = $noteId
    taskId = $taskIdValue
    workspaceKey = $workspaceKeyValue
    sessionKey = Get-SuperBrainHostSessionKey $SessionId
    title = Limit-CompactText $Title 160
    capturedAt = $capturedAt
    sourceHash = $sourceHash
    checkpointHash = $checkpointHash
    importantLines = @($important)
    historicalOnly = $true
    nonAuthorizing = $true
    retention = 'archive_only'
    guard = 'Historical note only. It cannot authorize continuation, mutation, completion, decision application, or a current task claim.'
  }
  Write-JsonUtf8NoBom $path $record 10
}
$result = [pscustomobject]@{
  ok = $true; schema = [string]$record.schema; status = 'archived_historical_only'; code = if($idempotent){'SESSION_COMPACT_IDEMPOTENT'}else{'SESSION_COMPACT_ARCHIVED'}; idempotent = $idempotent; taskId = $taskIdValue; workspaceKey = $workspaceKeyValue
  noteId = [string]$record.noteId; historicalOnly = $true; nonAuthorizing = $true; path = $path; artifactHash = Get-SuperBrainFileSha256 $path
  lineCount = @($important).Count; guard = [string]$record.guard
  recoveryCheckpoint = if ($recovery.checkpoint) { [pscustomobject]@{ checkpointId=[string]$recovery.checkpoint.checkpoint.checkpointId; checkpointHash=[string]$recovery.checkpoint.checkpoint.checkpointHash; checkpointRevision=[int]$recovery.checkpoint.checkpoint.checkpointRevision; path=[string]$recovery.checkpoint.path } } else { $null }
}
Write-CompactResult $result
