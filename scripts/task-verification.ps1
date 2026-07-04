[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Summary = '',
  [string[]]$Changed = @(),
  [string[]]$Commands = @(),
  [string[]]$Risks = @(),
  [string[]]$Evidence = @(),
  [string[]]$NextSteps = @(),
  [string]$TaskId = '',
  [string]$TeamTaskId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$path = Join-Path $workspace 'last-task-verification.json'

function Read-WorkspaceJson([string]$Name) { $candidate = Join-Path $workspace $Name; if (-not (Test-Path $candidate)) { return $null }; try { Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Read-TaskScopedJson([string]$RelativeDir,[string]$FallbackName) {
  $safe = Safe-TaskId $TaskId
  if (-not [string]::IsNullOrWhiteSpace($safe)) {
    $root = Join-Path (Join-Path $workspace 'guard-state') $RelativeDir
    $candidate = Join-Path $root ($safe + '.json')
    if (Test-Path -LiteralPath $candidate) { try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $taskDir = Join-Path $root $safe
    if (Test-Path -LiteralPath $taskDir) { $latest = Get-ChildItem -LiteralPath $taskDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($latest) { try { return Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} } }
  }
  return Read-WorkspaceJson $FallbackName
}
function Test-TaskScopedEvidence($Obj) { if ([string]::IsNullOrWhiteSpace($TaskId) -or -not $Obj) { return $true }; return ([string]$Obj.taskId -eq $TaskId) }
function Limit-List([object[]]$Items, [int]$Max = 8) { @($Items | Select-Object -First $Max) }

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastRelease = Read-WorkspaceJson 'last-release.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$constraintPreflight = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$taskGraph = Read-WorkspaceJson 'task-graph.json'
$stepLedger = Read-WorkspaceJson 'step-ledger.json'
$projectContinuity = Read-WorkspaceJson 'last-project-continuity.json'
$impact = Read-WorkspaceJson 'last-impact-advisor.json'
$teamTask = $null
if ($TeamTaskId) { $teamPath = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"; if (Test-Path $teamPath) { try { $teamTask = Get-Content -LiteralPath $teamPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $teamTask = $null } } }
$lastDoctor = $null; $doctorRiskSummary = $null; $doctorRisks = @()
try { $doctorJson = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json; if ($LASTEXITCODE -eq 0) { $lastDoctor = $doctorJson | ConvertFrom-Json; $doctorRiskSummary = $lastDoctor.riskSummary; $doctorRisks = @($lastDoctor.risks) } } catch {}
$constraintConflicts = if ($constraintPreflight) { @($constraintPreflight.conflicts) } else { @() }
$constraintsPreserved = (-not $constraintPreflight) -or ($constraintPreflight.ok -eq $true -and $constraintConflicts.Count -eq 0)
$openSteps = if ($stepLedger) { @($stepLedger.openSteps) } else { @() }
$continuitySummary = [pscustomobject]@{ taskId=if($taskGraph){$taskGraph.taskId}else{''}; taskStatus=if($taskGraph){$taskGraph.status}else{''}; goal=if($taskGraph){$taskGraph.goal}else{''}; openStepCount=@($openSteps).Count; completedCount=if($stepLedger){@($stepLedger.completedSteps).Count}else{0}; skippedCount=if($stepLedger){@($stepLedger.skippedSteps).Count}else{0}; candidateFindings=if($projectContinuity -and $projectContinuity.findingCounts){[int]$projectContinuity.findingCounts.candidate}else{0}; nextAction=if($projectContinuity){$projectContinuity.nextAction}else{''} }
$impactSummary = [pscustomobject]@{ riskLevel=if($impact){$impact.riskLevel}else{''}; affectedScripts=if($impact){@(Limit-List @($impact.affectedScripts) 10)}else{@()}; recommendedChecks=if($impact){@(Limit-List @($impact.recommendedChecks) 10)}else{@()} }
$integrationParity = Read-WorkspaceJson 'last-integration-parity-check.json'
$causalReview = Read-TaskScopedJson 'change-causality-reviews' 'last-causal-change-review.json'
$contractReplay = Read-TaskScopedJson 'integration-contract-replay' 'last-integration-contract-replay.json'
$taskScopedGuardOk = (Test-TaskScopedEvidence $causalReview) -and (Test-TaskScopedEvidence $contractReplay)
$moduleVerification = if ($integrationParity -and $integrationParity.moduleVerification) { $integrationParity.moduleVerification } else { [pscustomobject]@{ status='unknown module smoke OK'; ok=$null } }
$integrationVerification = if ($integrationParity -and $integrationParity.integrationVerification) { $integrationParity.integrationVerification } else { [pscustomobject]@{ status='unknown integration smoke OK'; ok=$null } }
$userAcceptanceVerification = if ($integrationParity -and $integrationParity.userAcceptanceVerification) { $integrationParity.userAcceptanceVerification } else { [pscustomobject]@{ status='unknown user-facing acceptance OK'; ok=$null; realUserPathVerification=$false } }
$verification = [pscustomobject]@{
  ok = (((($lastVerify -and $lastVerify.ok -eq $true) -or $taskScopedGuardOk) -and ($lastHotRefresh -and $lastHotRefresh.ok -eq $true) -and ($null -eq $lastDoctor -or $lastDoctor.ok -eq $true -or $taskScopedGuardOk) -and $constraintsPreserved -and $taskScopedGuardOk))
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = (Get-SuperBrainManifest $Root).version
  taskId = $TaskId
  summary = $Summary
  changed = @($Changed)
  commands = @($Commands)
  risks = @($Risks)
  evidence = @($Evidence)
  nextSteps = @($NextSteps)
  continuity = $continuitySummary
  impact = $impactSummary
  moduleVerification = $moduleVerification
  integrationVerification = $integrationVerification
  userAcceptanceVerification = $userAcceptanceVerification
  integrationParity = if ($integrationParity) { [pscustomobject]@{ ok=$integrationParity.ok; unresolvedIntegrationDrift=$integrationParity.unresolvedIntegrationDrift; drifts=@($integrationParity.drifts | Select-Object -First 10) } } else { $null }
  causalReview = if ($causalReview) { [pscustomobject]@{ ok=$causalReview.ok; taskId=$causalReview.taskId; taskScoped=(Test-TaskScopedEvidence $causalReview); gaps=@($causalReview.gaps).Count; decision=$causalReview.expectedVsActual.decision } } else { $null }
  integrationContractReplay = if ($contractReplay) { [pscustomobject]@{ ok=$contractReplay.ok; taskId=$contractReplay.taskId; taskScoped=(Test-TaskScopedEvidence $contractReplay); unresolvedBehaviorMismatch=$contractReplay.unresolvedBehaviorMismatch; mismatches=@($contractReplay.mismatches).Count } } else { $null }
  taskScopedGuardOk = $taskScopedGuardOk
  teamTask = if ($teamTask) { [pscustomobject]@{ teamTaskId=$teamTask.teamTaskId; dispatchLevel=$teamTask.dispatchLevel; delegationCount=@($teamTask.delegations).Count; decisionStatus=$teamTask.commanderDecision.status; verificationStatus=$teamTask.verification.status } } else { $null }
  constraintPreflight = if ($constraintPreflight) { [pscustomobject]@{ ok=$constraintPreflight.ok; checkedAt=$constraintPreflight.checkedAt; required=$constraintPreflight.required; guardHash=$constraintPreflight.guardHash; constraintCount=@($constraintPreflight.constraints).Count } } else { $null }
  constraintsPreserved = $constraintsPreserved
  constraintConflicts = @($constraintConflicts | Select-Object -First 10)
  doctor = if ($lastDoctor) { [pscustomobject]@{ ok=$lastDoctor.ok; riskSummary=$doctorRiskSummary; risks=@($doctorRisks | Select-Object -First 10) } } else { $null }
  lastVerify = if ($lastVerify) { [pscustomobject]@{ ok=$lastVerify.ok; checkedAt=$lastVerify.checkedAt; version=$lastVerify.version } } else { $null }
  lastRelease = if ($lastRelease) { [pscustomobject]@{ ok=$lastRelease.ok; checkedAt=$lastRelease.checkedAt; destination=$lastRelease.destination } } else { $null }
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt } } else { $null }
}
if ($verification.ok) {
  try { & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Complete -Source 'task-verification.ps1' -CurrentStep $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence) | Out-Null } catch {}
  if (@($openSteps).Count -eq 0 -and $taskGraph -and $taskGraph.status -eq 'active') { try { & (Join-Path $PSScriptRoot 'project-continuity.ps1') -Action CompleteTask -Evidence (($Evidence + @($Summary)) -join '; ') | Out-Null } catch {} }
  try { & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -Summary $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
  try { & (Join-Path $PSScriptRoot 'post-task-maintenance.ps1') -ApplySafe -Summary $Summary -TaskId $TaskId -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
}
Write-JsonUtf8NoBom $path $verification 10
if ($Json) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 } else { Write-Host "TASK_VERIFICATION_OK path=$path ok=$($verification.ok)" }
if (-not $verification.ok) { exit 1 }
exit 0
