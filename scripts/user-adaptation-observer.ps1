[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Preview','Apply')]
  [string]$Mode = 'Preview',
  [string[]]$Signals = @(),
  [ValidateSet('general','coding','debugging','planning','review','design','release')]
  [string]$Context = 'general',
  [ValidateSet('accepted_outcome','user_correction')]
  [string]$Source = 'accepted_outcome',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$WorkflowKey = '',
  [string]$CorrectionCandidateId = '',
  [string]$WorkspaceRoot = '',
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\user-adaptation-core.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$outPath = Join-Path $workspace 'last-user-adaptation-observer.json'

function Write-ObserverResult($Value,[int]$ExitCode=0) {
  if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
  Write-JsonUtf8NoBom $outPath $Value 12
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 }
  else { Write-Host "USER_ADAPTATION_OBSERVER mode=$($Value.mode) ok=$($Value.ok) applied=$($Value.appliedCount)" }
  $script:ObserverExitCode = $ExitCode
}

try {
  $policy = Get-UserAdaptationPolicy $Root
  $observerPolicy = $policy.verifiedOutcomeObservation
  if (-not $observerPolicy -or $observerPolicy.enabled -ne $true) { throw 'USER_ADAPTATION_OBSERVER_POLICY_MISSING_OR_DISABLED' }
  if (@($observerPolicy.allowedSources) -notcontains $Source) { throw 'USER_ADAPTATION_OBSERVER_SOURCE_BLOCKED' }
  if ([string]::IsNullOrWhiteSpace($TaskId) -or $TaskId -notmatch '^[A-Za-z0-9._-]{1,120}$') { throw 'USER_ADAPTATION_OBSERVER_TASK_ID_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { $WorkspaceKey = Get-SuperBrainWorkspaceKey }
  $WorkspaceKey = $WorkspaceKey.ToLowerInvariant()
  if ($WorkspaceKey -notmatch '^ws-[0-9a-f]{24}$') { throw 'USER_ADAPTATION_OBSERVER_WORKSPACE_KEY_INVALID' }

  $signalItems = New-Object Collections.ArrayList
  foreach ($rawSignal in @($Signals | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    $normalized = ([string]$rawSignal).Trim().ToLowerInvariant()
    if ($normalized -notmatch '^([a-z_]+)=([a-z_]+)$') { throw 'USER_ADAPTATION_OBSERVER_SIGNAL_INVALID' }
    $rule = Get-UserAdaptationHabitRule $policy $Matches[1] $Matches[2]
    [void]$signalItems.Add([pscustomobject]@{ habitKey=$rule.habitKey; value=$rule.value })
  }
  if ($signalItems.Count -eq 0) { throw 'USER_ADAPTATION_OBSERVER_SIGNALS_REQUIRED' }
  if ($signalItems.Count -gt [int]$observerPolicy.maxSignalsPerTask) { throw 'USER_ADAPTATION_OBSERVER_SIGNAL_BUDGET_EXCEEDED' }

  $verificationPath = Join-Path $workspace 'last-task-verification.json'
  $verification = $null
  if (Test-Path -LiteralPath $verificationPath) {
    try { $verification = Get-Content -LiteralPath $verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $verificationMatch = ($verification -and $verification.ok -eq $true -and [string]$verification.taskId -eq $TaskId -and [string]$verification.workspaceKey -eq $WorkspaceKey)
  if ($Mode -eq 'Apply' -and -not $verificationMatch) { throw 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED' }

  $correctionVerified = $true
  if ($Source -eq 'user_correction') {
    if ([string]::IsNullOrWhiteSpace($CorrectionCandidateId) -or $CorrectionCandidateId -notmatch '^correction-[a-z0-9_-]{1,100}$') { throw 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED' }
    $correctionPath = Join-Path $workspace "reflection\correction-candidates\$($CorrectionCandidateId.ToLowerInvariant()).json"
    $correction = $null
    if (Test-Path -LiteralPath $correctionPath) { try { $correction = Get-Content -LiteralPath $correctionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $correctionVerified = ($correction -and [string]$correction.candidateId -eq $CorrectionCandidateId.ToLowerInvariant() -and [string]$correction.status -eq 'closed' -and $correction.rawPromptStored -ne $true)
    if ($Mode -eq 'Apply' -and -not $correctionVerified) { throw 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED' }
  }

  if (-not [string]::IsNullOrWhiteSpace($WorkflowKey) -and $WorkflowKey -notmatch '^[A-Za-z0-9._-]{1,48}$') { throw 'USER_ADAPTATION_OBSERVER_WORKFLOW_KEY_INVALID' }
  $scope = if ([string]::IsNullOrWhiteSpace($WorkflowKey)) { 'project' } else { 'workflow' }
  $scopeKey = if ($scope -eq 'project') { $WorkspaceKey } else { "$WorkspaceKey`:$($WorkflowKey.ToLowerInvariant())" }
  $observations = @()
  if ($Mode -eq 'Apply') {
    foreach ($signal in @($signalItems)) {
      $evidenceRef = "verified-outcome|$TaskId|$WorkspaceKey|$Context|$Source|$($signal.habitKey)|$($signal.value)|$([string]$verification.checkedAt)"
      $observations += Add-UserAdaptationObservation -Root $Root -HabitKey $signal.habitKey -Value $signal.value -Signal Support -Source $Source -Scope $scope -ScopeKey $scopeKey -Context $Context -TaskId $TaskId -EvidenceRef $evidenceRef -WorkspaceRoot $workspace
    }
  }
  $result = [pscustomobject]@{
    ok = $true
    schema = 'super-brain.user-adaptation-observer.v1'
    checkedAt = (Get-Date).ToString('o')
    mode = $Mode
    taskId = $TaskId
    workspaceKey = $WorkspaceKey
    verificationMatch = [bool]$verificationMatch
    correctionVerified = [bool]$correctionVerified
    source = $Source
    scope = $scope
    scopeKey = $scopeKey
    context = $Context
    signalCount = $signalItems.Count
    signals = @($signalItems)
    appliedCount = @($observations | Where-Object { $_.duplicate -ne $true }).Count
    duplicateCount = @($observations | Where-Object { $_.duplicate -eq $true }).Count
    rawPromptStored = $false
    inference = [pscustomobject]@{ fromSummary=$false; fromTranscript=$false; fromAppliedPacket=$false }
  }
  Write-ObserverResult $result 0
} catch {
  Write-ObserverResult ([pscustomobject]@{ok=$false;schema='super-brain.user-adaptation-observer-error.v1';mode=$Mode;taskId=$TaskId;appliedCount=0;error=$_.Exception.Message;rawPromptStored=$false}) 1
}
if (-not $NoExit) { exit $script:ObserverExitCode }
