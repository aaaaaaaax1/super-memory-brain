[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Write','Read','Validate')][string]$Action = 'Read',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [string]$SessionId = '',
  [string]$TaskInstanceId = '',
  [string]$PackageVersion = '',
  [int]$ContractRevision = 0,
  [string]$PlanFingerprint = '',
  [string]$LatestInstructionHash = '',
  [string]$AssistantProgressHash = '',
  [string]$CurrentPhase = '',
  [string]$CurrentStep = '',
  [string]$NextAction = '',
  [string]$ReturnPointJson = '',
  [string]$ReturnPointJsonBase64 = '',
  [string]$StateHash = '',
  [string]$ActivationId = '',
  [string]$Source = 'recovery-checkpoint.ps1',
  [int]$ExpectedRevision = -1,
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryBase = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-SuperBrainMemoryBaseRoot $Root } else { [IO.Path]::GetFullPath($StateRoot) }
$workspaceValue = Get-SuperBrainWorkspaceKey $WorkspaceKey
$sessionSource = if (-not [string]::IsNullOrWhiteSpace($SessionKey)) { [string]$SessionKey } else { [string]$SessionId }
$sessionValue = Get-SuperBrainLocalSessionKey $sessionSource
$taskValue = ([string]$TaskId).Trim()
$taskInstanceValue = ([string]$TaskInstanceId).Trim()
$checkpointRoot = Join-Path $memoryBase 'workspace\runtime-state\recovery-checkpoints'

function Limit-Text([string]$Value,[int]$Max=260) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Get-RecoveryScopeRef {
  return Get-SuperBrainStableHash (([ordered]@{ workspaceKey=$workspaceValue; ownerSessionKey=$sessionValue; taskId=$taskValue; taskInstanceId=$taskInstanceValue } | ConvertTo-Json -Depth 6 -Compress)) 64
}

function Get-RecoveryPath {
  if ([string]::IsNullOrWhiteSpace($taskValue) -or [string]::IsNullOrWhiteSpace($workspaceValue) -or [string]::IsNullOrWhiteSpace($sessionValue)) { return '' }
  return Join-Path $checkpointRoot ((Get-RecoveryScopeRef) + '.json')
}

function Read-RecoveryJson([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-RecoveryHash([object]$Value,[string]$Field='checkpointHash') {
  $body = [ordered]@{}
  foreach ($property in $Value.PSObject.Properties) {
    if ([string]$property.Name -notin @($Field,'checkpointHash','updatedAt','writtenAt')) { $body[$property.Name] = $property.Value }
  }
  return Get-SuperBrainStableHash (($body | ConvertTo-Json -Depth 16 -Compress)) 64
}

function Get-RecoveryContentFingerprint([object]$Value) {
  if (-not $Value) { return '' }
  # Identity/timestamp fields are deliberately excluded so a repeated compact
  # of the same verified state is a replay, not a new checkpoint revision.
  $body = [ordered]@{
    schema = [string]$Value.schema
    taskId = [string]$Value.taskId
    taskInstanceId = [string]$Value.taskInstanceId
    workspaceKey = [string]$Value.workspaceKey
    ownerSessionKey = [string]$Value.ownerSessionKey
    packageVersion = [string]$Value.packageVersion
    contractRevision = [int]$Value.contractRevision
    planFingerprint = [string]$Value.planFingerprint
    latestInstructionHash = [string]$Value.latestInstructionHash
    assistantProgressHash = [string]$Value.assistantProgressHash
    currentPhase = [string]$Value.currentPhase
    currentStep = [string]$Value.currentStep
    nextAction = [string]$Value.nextAction
    returnPoint = $Value.returnPoint
    stateHash = [string]$Value.stateHash
    activationId = [string]$Value.activationId
    source = [string]$Value.source
    rawPromptStored = [bool]$Value.rawPromptStored
    rawTranscriptStored = [bool]$Value.rawTranscriptStored
  }
  return Get-SuperBrainStableHash (($body | ConvertTo-Json -Depth 16 -Compress)) 64
}

function Write-RecoveryAtomic([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temp = Join-Path $parent ('.recovery-checkpoint-' + [guid]::NewGuid().ToString('n') + '.tmp')
  [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
  try {
    if (Test-Path -LiteralPath $Path) {
      try { [IO.File]::Replace($temp,$Path,$null,$true) }
      catch { Move-Item -LiteralPath $temp -Destination $Path -Force }
    } else {
      Move-Item -LiteralPath $temp -Destination $Path -Force
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Write-RecoveryResult([object]$Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 16 -Compress }
  else { Write-Host "RECOVERY_CHECKPOINT action=$Action status=$($Value.status) code=$($Value.code) path=$($Value.path)" }
  exit $ExitCode
}

if ([string]::IsNullOrWhiteSpace($taskValue) -or [string]::IsNullOrWhiteSpace($workspaceValue) -or [string]::IsNullOrWhiteSpace($sessionValue)) {
  Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='scope_required'; code='RECOVERY_CHECKPOINT_SCOPE_REQUIRED'; path=''; rawPromptStored=$false; rawTranscriptStored=$false }) 1
}

$path = Get-RecoveryPath
$current = Read-RecoveryJson $path

if ($Action -eq 'Read') {
  if (-not $current) { Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='missing'; code='RECOVERY_CHECKPOINT_MISSING'; path=$path; rawPromptStored=$false; rawTranscriptStored=$false }) 1 }
  Write-RecoveryResult ([pscustomobject]@{ ok=$true; schema='super-brain.recovery-checkpoint.v1'; status='current'; code='RECOVERY_CHECKPOINT_READ'; path=$path; checkpoint=$current; rawPromptStored=$false; rawTranscriptStored=$false }) 0
}

if ($Action -eq 'Validate') {
  if (-not $current) { Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='missing'; code='RECOVERY_CHECKPOINT_MISSING'; path=$path; rawPromptStored=$false; rawTranscriptStored=$false }) 1 }
  $expectedHash = Get-RecoveryHash $current
  $valid = ([string]$current.schema -eq 'super-brain.recovery-checkpoint.v1' -and
    [string]$current.taskId -eq $taskValue -and
    (Test-SuperBrainWorkspaceKey ([string]$current.workspaceKey) $workspaceValue) -and
    [string]$current.ownerSessionKey -eq $sessionValue -and
    [string]$current.packageVersion -eq [string]$manifest.version -and
    [string]$current.checkpointHash -eq $expectedHash)
  $code = if ($valid) { 'RECOVERY_CHECKPOINT_CURRENT' } else { 'RECOVERY_CHECKPOINT_INVALID' }
  Write-RecoveryResult ([pscustomobject]@{ ok=$valid; schema='super-brain.recovery-checkpoint.v1'; status=if($valid){'current'}else{'invalid'}; code=$code; path=$path; checkpoint=$current; expectedHash=$expectedHash; rawPromptStored=$false; rawTranscriptStored=$false }) $(if($valid){0}else{1})
}

$currentRevision = if ($current -and $current.PSObject.Properties['checkpointRevision']) { [int]$current.checkpointRevision } else { 0 }
if ($ExpectedRevision -ge 0 -and $currentRevision -ne $ExpectedRevision) {
  Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='cas_mismatch'; code='RECOVERY_CHECKPOINT_CAS_MISMATCH'; path=$path; currentRevision=$currentRevision; expectedRevision=$ExpectedRevision; rawPromptStored=$false; rawTranscriptStored=$false }) 1
}
$returnPoint = $null
if (-not [string]::IsNullOrWhiteSpace($ReturnPointJsonBase64)) {
  try { $ReturnPointJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ReturnPointJsonBase64)) } catch { Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='invalid'; code='RECOVERY_CHECKPOINT_RETURN_POINT_INVALID'; path=$path; rawPromptStored=$false; rawTranscriptStored=$false }) 1 }
}
if (-not [string]::IsNullOrWhiteSpace($ReturnPointJson)) {
  try { $returnPoint = $ReturnPointJson | ConvertFrom-Json } catch { Write-RecoveryResult ([pscustomobject]@{ ok=$false; schema='super-brain.recovery-checkpoint.v1'; status='invalid'; code='RECOVERY_CHECKPOINT_RETURN_POINT_INVALID'; path=$path; rawPromptStored=$false; rawTranscriptStored=$false }) 1 }
}
$body = [ordered]@{
  schema='super-brain.recovery-checkpoint.v1'
  checkpointId='rc-' + [guid]::NewGuid().ToString('n')
  checkpointRevision=($currentRevision + 1)
  taskId=$taskValue
  taskInstanceId=$taskInstanceValue
  workspaceKey=$workspaceValue
  ownerSessionKey=$sessionValue
  packageVersion=[string]$manifest.version
  contractRevision=[int]$ContractRevision
  planFingerprint=([string]$PlanFingerprint).Trim()
  latestInstructionHash=([string]$LatestInstructionHash).Trim().ToLowerInvariant()
  assistantProgressHash=([string]$AssistantProgressHash).Trim().ToLowerInvariant()
  currentPhase=(Limit-Text ([string]$CurrentPhase) 160)
  currentStep=(Limit-Text ([string]$CurrentStep) 260)
  nextAction=(Limit-Text ([string]$NextAction) 360)
  returnPoint=$returnPoint
  stateHash=([string]$StateHash).Trim().ToLowerInvariant()
  activationId=(Limit-Text ([string]$ActivationId) 96)
  source=(Limit-Text $Source 120)
  updatedAt=(Get-SuperBrainUtcTimestamp)
  rawPromptStored=$false
  rawTranscriptStored=$false
}
if ([string]::IsNullOrWhiteSpace([string]$body.stateHash)) {
  $body.stateHash = Get-SuperBrainStableHash (([ordered]@{ taskId=$body.taskId; workspaceKey=$body.workspaceKey; ownerSessionKey=$body.ownerSessionKey; contractRevision=$body.contractRevision; planFingerprint=$body.planFingerprint; latestInstructionHash=$body.latestInstructionHash; assistantProgressHash=$body.assistantProgressHash; currentPhase=$body.currentPhase; currentStep=$body.currentStep; nextAction=$body.nextAction; returnPoint=$body.returnPoint } | ConvertTo-Json -Depth 12 -Compress)) 64
}
$body.checkpointHash = Get-RecoveryHash ([pscustomobject]$body)
if ($current) {
  $currentContentHash = Get-RecoveryContentFingerprint $current
  $incomingContentHash = Get-RecoveryContentFingerprint ([pscustomobject]$body)
  if (-not [string]::IsNullOrWhiteSpace($currentContentHash) -and $currentContentHash -eq $incomingContentHash) {
    Write-RecoveryResult ([pscustomobject]@{
      ok=$true; schema='super-brain.recovery-checkpoint.v1'; status='current'; code='RECOVERY_CHECKPOINT_IDEMPOTENT';
      idempotent=$true; path=$path; checkpoint=$current; rawPromptStored=$false; rawTranscriptStored=$false
    }) 0
  }
}
Write-RecoveryAtomic $path ([pscustomobject]$body)
Write-RecoveryResult ([pscustomobject]@{ ok=$true; schema='super-brain.recovery-checkpoint.v1'; status='committed'; code='RECOVERY_CHECKPOINT_COMMITTED'; idempotent=$false; path=$path; checkpoint=[pscustomobject]$body; rawPromptStored=$false; rawTranscriptStored=$false }) 0
