$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Core = Join-Path $Root 'scripts\internal\user-adaptation-core.ps1'
$Hook = Join-Path $Root 'scripts\codex-user-prompt-hook.ps1'
$Preflight = Join-Path $Root 'scripts\cognitive-preflight.ps1'
$Maintenance = Join-Path $Root 'scripts\post-task-maintenance.ps1'
$Observer = Join-Path $Root 'scripts\user-adaptation-observer.ps1'
$TaskVerification = Join-Path $Root 'scripts\task-verification.ps1'

. (Join-Path $Root 'scripts\common.ps1')
. $Core

function Add-TestAdaptationObservation {
  param(
    [string]$WorkspaceRoot,
    [string]$HabitKey,
    [string]$Value,
    [string]$TaskId,
    [string]$Context = 'general',
    [string]$Signal = 'Support',
    [string]$Source = 'repeated_behavior',
    [string]$Scope = 'global',
    [string]$ScopeKey = '',
    [string]$EvidenceRef = ''
  )
  Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -TaskId $TaskId -Context $Context -Signal $Signal -Source $Source -Scope $Scope -ScopeKey $ScopeKey -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot
}

function Set-TestAdaptationPreference {
  param(
    [string]$WorkspaceRoot,
    [string]$HabitKey,
    [string]$Value,
    [string]$Scope = 'global',
    [string]$ScopeKey = '',
    [string]$Context = 'general',
    [string]$TaskId = 'explicit-test'
  )
  $null = Add-TestAdaptationObservation -WorkspaceRoot $WorkspaceRoot -HabitKey $HabitKey -Value $Value -TaskId $TaskId -Context $Context -Source explicit_user -Scope $Scope -ScopeKey $ScopeKey -EvidenceRef "$TaskId|$Scope|$ScopeKey|$HabitKey|$Value"
  Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot
}

function Write-TestAdaptationJson([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Write-JsonUtf8NoBom $Path $Value 12
}

function Set-TestVerifiedOutcome {
  param([string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey,[bool]$Ok=$true)
  Write-TestAdaptationJson (Join-Path $WorkspaceRoot 'last-task-verification.json') ([pscustomobject]@{
    ok=$Ok
    taskId=$TaskId
    workspaceKey=$WorkspaceKey
    checkedAt='2026-07-16 15:00:00'
  })
}

function Invoke-TestAdaptationObserver {
  param(
    [string]$WorkspaceRoot,
    [string]$TaskId,
    [string]$WorkspaceKey,
    [string[]]$Signals,
    [string]$Mode='Apply',
    [string]$Context='coding',
    [string]$Source='accepted_outcome',
    [string]$WorkflowKey='',
    [string]$CorrectionCandidateId=''
  )
  $arguments = @{Mode=$Mode;TaskId=$TaskId;WorkspaceKey=$WorkspaceKey;Signals=$Signals;Context=$Context;Source=$Source;WorkspaceRoot=$WorkspaceRoot;NoExit=$true;Json=$true}
  if (-not [string]::IsNullOrWhiteSpace($WorkflowKey)) { $arguments.WorkflowKey = $WorkflowKey }
  if (-not [string]::IsNullOrWhiteSpace($CorrectionCandidateId)) { $arguments.CorrectionCandidateId = $CorrectionCandidateId }
  return ((@(& $Observer @arguments) -join "`n") | ConvertFrom-Json)
}

Describe 'Governed user adaptation' {
  BeforeEach {
    $script:AdaptationWorkspace = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $script:AdaptationWorkspace | Out-Null
  }

  It 'promotes inferred preferences only after three tasks and two contexts' {
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-2 coding
    (Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).activePreferenceCount | Should Be 0

    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-3 debugging
    $result = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $result.activePreferenceCount | Should Be 1
    $profile = Read-UserAdaptationJson (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).profile (New-UserAdaptationStoreDefaults).profile
    $profile.entries[0].source | Should Be 'inferred'
    [double]$profile.entries[0].confidence -ge 0.78 | Should Be $true
  }

  It 'promotes an explicit preference immediately' {
    $result = Set-TestAdaptationPreference $script:AdaptationWorkspace reasoning_style evidence_first
    $result.activePreferenceCount | Should Be 1
    $result.promotedPreferenceIds.Count | Should Be 1
    $profile = Read-UserAdaptationJson (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).profile (New-UserAdaptationStoreDefaults).profile
    [double]$profile.entries[0].confidence | Should Be 0.99
  }

  It 'applies workflow over project over global and isolates projects' {
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail concise global '' general global-pref
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail detailed project ws-alpha coding project-pref
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace response_detail balanced workflow code-review review workflow-pref

    $workflow = Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey ws-alpha -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace
    $workflow.preferences[0].scope | Should Be 'workflow'
    $workflow.preferences[0].value | Should Be 'balanced'

    $project = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey ws-alpha -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace
    $project.preferences[0].scope | Should Be 'project'
    $project.preferences[0].value | Should Be 'detailed'

    $foreign = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey ws-beta -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace
    $foreign.preferences[0].scope | Should Be 'global'
    $foreign.preferences[0].value | Should Be 'concise'
  }

  It 'applies problem-complete verification only to problem-review contexts' {
    $null = Set-TestAdaptationPreference $script:AdaptationWorkspace verification_depth problem_complete
    $coding = Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceRoot $script:AdaptationWorkspace
    $debugging = Get-UserAdaptationPacket -Root $Root -Context debugging -WorkspaceRoot $script:AdaptationWorkspace
    $review = Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceRoot $script:AdaptationWorkspace
    $coding.applies | Should Be $false
    $debugging.preferences[0].value | Should Be 'problem_complete'
    $review.preferences[0].value | Should Be 'problem_complete'
  }

  It 'keeps low-confidence and contradicted signals silent' {
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-2 debugging
    $low = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $low.activePreferenceCount | Should Be 0

    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail concise task-3 coding
    $null = Add-TestAdaptationObservation $script:AdaptationWorkspace response_detail detailed task-4 general
    $conflicted = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $conflicted.activePreferenceCount | Should Be 0
    (Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'supports disable, enable, confirmed forget, and tombstone blocking' {
    $set = Set-TestAdaptationPreference $script:AdaptationWorkspace proactivity material_only
    $preferenceId = [string]$set.promotedPreferenceIds[0]
    (Set-UserAdaptationEnabled -Root $Root -Enabled $false -WorkspaceRoot $script:AdaptationWorkspace).enabled | Should Be $false
    (Get-UserAdaptationPacket -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
    (Set-UserAdaptationEnabled -Root $Root -Enabled $true -WorkspaceRoot $script:AdaptationWorkspace).enabled | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $true

    (Remove-UserAdaptationPreference -Root $Root -PreferenceId $preferenceId -WorkspaceRoot $script:AdaptationWorkspace).found | Should Be $true
    $null = Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey proactivity -Value material_only -TaskId explicit-again -Source explicit_user -EvidenceRef explicit-again
    (Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).activePreferenceCount | Should Be 0
  }

  It 'enforces observation and packet budgets' {
    for ($i = 1; $i -le 205; $i++) {
      $null = Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -TaskId "task-$i" -Context coding -EvidenceRef "budget-$i"
    }
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 200

    $packetWorkspace = Join-Path $TestDrive 'packet-budget'
    $preferences = @(
      @('response_detail','balanced'),
      @('reasoning_style','evidence_first'),
      @('proactivity','material_only'),
      @('small_change_autonomy','auto'),
      @('structural_change_autonomy','discuss'),
      @('verification_depth','risk_based'),
      @('feature_thinking','integrated'),
      @('clarification_style','infer_then_confirm')
    )
    foreach ($preference in $preferences) { $null = Set-TestAdaptationPreference $packetWorkspace $preference[0] $preference[1] global '' general ("explicit-" + $preference[0]) }
    $packet = Get-UserAdaptationPacket -Root $Root -Context general -WorkspaceRoot $packetWorkspace
    $packet.directiveCount -le 3 | Should Be $true
    $packet.tokenEstimate -le 120 | Should Be $true
  }

  It 'stores no raw evidence or prompt sentinel' {
    $sentinel = 'RAW-PROMPT-SENTINEL-DO-NOT-STORE-7f42'
    $null = Add-TestAdaptationObservation -WorkspaceRoot $script:AdaptationWorkspace -HabitKey response_detail -Value concise -TaskId safe-task -Source explicit_user -EvidenceRef $sentinel
    $null = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace
    $text = @(Get-ChildItem -LiteralPath (Get-UserAdaptationPaths $Root $script:AdaptationWorkspace).directory -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    $text.Contains($sentinel) | Should Be $false
    ($text.Contains('"rawPromptStored":  false') -or $text.Contains('"rawPromptStored":false')) | Should Be $true
  }

  It 'reports strong hook signals in test mode without mutating adaptation state' {
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $stateRoot = Join-Path $TestDrive 'hook-test-mode'
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $result = (& $Hook -TestPrompt 'Going forward, I prefer concise answers by default.' | ConvertFrom-Json)
      $result.hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true
      (Test-Path (Join-Path $stateRoot 'workspace\user-adaptation')) | Should Be $false
      $hookState = Get-Content -LiteralPath (Join-Path $stateRoot 'workspace\last-codex-user-prompt-hook.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $hookState.adaptationCapture.mode | Should Be 'test'
      $hookState.adaptationCapture.mutated | Should Be $false
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'captures a real hook preference and exposes it only through relevant preflight' {
    $stateRoot = Join-Path $TestDrive 'hook-apply-mode'
    $prompt = 'From now on, I prefer concise answers by default.'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Hook`""
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['SUPER_BRAIN_STATE_ROOT'] = $stateRoot
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Write((@{prompt=$prompt} | ConvertTo-Json -Compress))
    $process.StandardInput.Close()
    $hookOutput = $process.StandardOutput.ReadToEnd()
    $hookError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $process.ExitCode | Should Be 0
    ($hookOutput | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('USER_ADAPTATION_SIGNAL') | Should Be $true

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $preflight = (& $Preflight -Query 'implement a small code module' -Json | ConvertFrom-Json)
      $preflight.userAdaptation.directiveCount | Should Be 1
      @($preflight.cards | Where-Object { $_.kind -eq 'user_adaptation' }).Count | Should Be 1
      $stored = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
      $stored.Contains($prompt) | Should Be $false
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'keeps maintenance read-only in plan mode and synthesizes only with ApplySafe' {
    $stateRoot = Join-Path $TestDrive 'maintenance-integration'
    $workspace = Join-Path $stateRoot 'workspace'
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-1 coding
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-2 coding
    $null = Add-TestAdaptationObservation $workspace response_detail concise task-3 debugging
    $profilePath = (Get-UserAdaptationPaths $Root $workspace).profile
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $plan = (& $Maintenance -Summary 'adaptation integration test' -Json | ConvertFrom-Json)
      ($plan.steps | Where-Object { $_.name -eq 'user-adaptation' }).rawPreview.Contains('"action":  "Status"') | Should Be $true
      (Test-Path $profilePath) | Should Be $false

      $apply = (& $Maintenance -Summary 'adaptation integration test' -ApplySafe -Json | ConvertFrom-Json)
      ($apply.steps | Where-Object { $_.name -eq 'user-adaptation' }).rawPreview.Contains('"action":  "Synthesize"') | Should Be $true
      (Test-Path $profilePath) | Should Be $true
      (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $workspace).activePreferenceCount | Should Be 1
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }

  It 'previews verified outcome signals without mutating adaptation state' {
    $workspaceKey = 'ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    $result = Invoke-TestAdaptationObserver $script:AdaptationWorkspace preview-task $workspaceKey @('response_detail=concise') Preview
    $result.ok | Should Be $true
    $result.verificationMatch | Should Be $false
    $result.appliedCount | Should Be 0
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'rejects missing and mismatched verification artifacts' {
    $workspaceKey = 'ws-bbbbbbbbbbbbbbbbbbbbbbbb'
    $missing = Invoke-TestAdaptationObserver $script:AdaptationWorkspace missing-task $workspaceKey @('response_detail=concise')
    $missing.ok | Should Be $false
    $missing.error | Should Be 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED'

    Set-TestVerifiedOutcome $script:AdaptationWorkspace another-task $workspaceKey
    $mismatched = Invoke-TestAdaptationObserver $script:AdaptationWorkspace expected-task $workspaceKey @('response_detail=concise')
    $mismatched.ok | Should Be $false
    $mismatched.error | Should Be 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED'
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'isolates learned project and workflow preferences by workspace' {
    $workspaceKey = 'ws-cccccccccccccccccccccccc'
    $foreignKey = 'ws-dddddddddddddddddddddddd'
    foreach ($sample in @(@('project-1','coding'),@('project-2','debugging'),@('project-3','coding'))) {
      Set-TestVerifiedOutcome $script:AdaptationWorkspace $sample[0] $workspaceKey
      (Invoke-TestAdaptationObserver $script:AdaptationWorkspace $sample[0] $workspaceKey @('response_detail=concise') Apply $sample[1]).ok | Should Be $true
    }
    foreach ($sample in @(@('workflow-1','review'),@('workflow-2','coding'),@('workflow-3','review'))) {
      Set-TestVerifiedOutcome $script:AdaptationWorkspace $sample[0] $workspaceKey
      (Invoke-TestAdaptationObserver $script:AdaptationWorkspace $sample[0] $workspaceKey @('reasoning_style=evidence_first') Apply $sample[1] accepted_outcome code-review).scopeKey | Should Be "$workspaceKey`:code-review"
    }
    $null = Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $script:AdaptationWorkspace

    (@((Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $workspaceKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace).preferences.value) -contains 'concise') | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -Context coding -WorkspaceKey $foreignKey -WorkflowKey other -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
    (@((Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey $workspaceKey -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace).preferences.value) -contains 'evidence_first') | Should Be $true
    (Get-UserAdaptationPacket -Root $Root -Context review -WorkspaceKey $foreignKey -WorkflowKey code-review -WorkspaceRoot $script:AdaptationWorkspace).applies | Should Be $false
  }

  It 'enforces the three-signal task budget' {
    $workspaceKey = 'ws-eeeeeeeeeeeeeeeeeeeeeeee'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace budget-task $workspaceKey
    $accepted = Invoke-TestAdaptationObserver $script:AdaptationWorkspace budget-task $workspaceKey @('response_detail=concise','reasoning_style=evidence_first','proactivity=material_only')
    $accepted.ok | Should Be $true
    $accepted.appliedCount | Should Be 3

    Set-TestVerifiedOutcome $script:AdaptationWorkspace overflow-task $workspaceKey
    $rejected = Invoke-TestAdaptationObserver $script:AdaptationWorkspace overflow-task $workspaceKey @('response_detail=concise','reasoning_style=evidence_first','proactivity=material_only','verification_depth=risk_based')
    $rejected.ok | Should Be $false
    $rejected.error | Should Be 'USER_ADAPTATION_OBSERVER_SIGNAL_BUDGET_EXCEEDED'
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 3
  }

  It 'rejects freeform and unknown adaptation signals' {
    $workspaceKey = 'ws-ffffffffffffffffffffffff'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace invalid-task $workspaceKey
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace invalid-task $workspaceKey @('response_detail=concise because it worked')).error | Should Be 'USER_ADAPTATION_OBSERVER_SIGNAL_INVALID'
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace invalid-task $workspaceKey @('personality=engineer')).error | Should Be 'USER_ADAPTATION_HABIT_KEY_INVALID'
    (Test-Path (Join-Path $script:AdaptationWorkspace 'user-adaptation\observations.json')) | Should Be $false
  }

  It 'requires a closed correction candidate before learning from correction' {
    $workspaceKey = 'ws-111111111111111111111111'
    $candidateId = 'correction-adaptation-test'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace correction-task $workspaceKey
    $candidatePath = Join-Path $script:AdaptationWorkspace "reflection\correction-candidates\$candidateId.json"
    Write-TestAdaptationJson $candidatePath ([pscustomobject]@{candidateId=$candidateId;status='pending_verification';rawPromptStored=$false})
    $pending = Invoke-TestAdaptationObserver $script:AdaptationWorkspace correction-task $workspaceKey @('feature_thinking=integrated') Apply coding user_correction '' $candidateId
    $pending.ok | Should Be $false
    $pending.error | Should Be 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED'

    Write-TestAdaptationJson $candidatePath ([pscustomobject]@{candidateId=$candidateId;status='closed';rawPromptStored=$false})
    $closed = Invoke-TestAdaptationObserver $script:AdaptationWorkspace correction-task $workspaceKey @('feature_thinking=integrated') Apply coding user_correction '' $candidateId
    $closed.ok | Should Be $true
    $closed.correctionVerified | Should Be $true
    $closed.appliedCount | Should Be 1
  }

  It 'deduplicates repeated observations from the same verified task' {
    $workspaceKey = 'ws-222222222222222222222222'
    Set-TestVerifiedOutcome $script:AdaptationWorkspace duplicate-task $workspaceKey
    (Invoke-TestAdaptationObserver $script:AdaptationWorkspace duplicate-task $workspaceKey @('response_detail=balanced')).appliedCount | Should Be 1
    $duplicate = Invoke-TestAdaptationObserver $script:AdaptationWorkspace duplicate-task $workspaceKey @('response_detail=balanced')
    $duplicate.appliedCount | Should Be 0
    $duplicate.duplicateCount | Should Be 1
    (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $script:AdaptationWorkspace).observationCount | Should Be 1
  }

  It 'records optional signals through successful task verification' {
    $stateRoot = Join-Path $TestDrive 'task-verification-adaptation'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-verification-adaptation'
    $workspaceKey = 'ws-333333333333333333333333'
    Write-TestAdaptationJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version='test';checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;checkedAt='test'})
    Write-TestAdaptationJson (Join-Path $workspace 'last-causal-change-review.json') ([pscustomobject]@{ok=$true;taskId=$taskId;gaps=@();expectedVsActual=[pscustomobject]@{decision='accepted'}})
    Write-TestAdaptationJson (Join-Path $workspace 'last-integration-contract-replay.json') ([pscustomobject]@{ok=$true;taskId=$taskId;unresolvedBehaviorMismatch=$false;mismatches=@()})
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskVerification -TaskId $taskId -WorkspaceKey $workspaceKey -Summary 'verified adaptation bridge' -Evidence 'focused integration test' -AdaptationSignals 'reasoning_style=evidence_first' -AdaptationContext coding -Json 2>$null)
      $LASTEXITCODE | Should Be 0
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $true
      $result.adaptationObservation.ok | Should Be $true
      $result.adaptationObservation.appliedCount | Should Be 1
      (Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $workspace).observationCount | Should Be 1
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
}
