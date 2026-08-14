$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ContextScript = Join-Path $Root 'scripts\current-task-context.ps1'
$ContractScript = Join-Path $Root 'scripts\execution-contract.ps1'

. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\internal\hook-runtime-common.ps1')

function Invoke-ScopedContext([string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ContextScript @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n").Trim()
  return [pscustomobject]@{
    exitCode = $exitCode
    value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    text = $text
  }
}

Describe 'Current task context workspace projection' {
  It 'writes task context timestamps in UTC' {
    $stateRoot = Join-Path $TestDrive 'context-utc-timestamps'
    $created = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-context-utc','-WorkspaceKey','ws-utc444444444444444444444',
      '-SessionId','session-utc','-AcceptedGoal','verify UTC context','-AcceptedRoute','write a scoped context','-Json'
    ) $stateRoot

    $created.exitCode | Should Be 0
    ([DateTimeOffset]::Parse([string]$created.value.checkedAt)).Offset.TotalMinutes | Should Be 0
    ([DateTimeOffset]::Parse([string]$created.value.expiresAt)).Offset.TotalMinutes | Should Be 0
  }

  It 'keeps the compatibility pointer scoped and rejects a foreign workspace task' {
    $stateRoot = Join-Path $TestDrive 'context-scope'
    $workspaceA = 'ws-a11111111111111111111111'
    $workspaceB = 'ws-b22222222222222222222222'

    $createdA = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-context-a','-WorkspaceKey',$workspaceA,
      '-SessionId','session-a','-AcceptedGoal','goal a','-AcceptedRoute','route a','-Json'
    ) $stateRoot
    $createdA.exitCode | Should Be 0

    $createdB = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-context-b','-WorkspaceKey',$workspaceB,
      '-SessionId','session-b','-AcceptedGoal','goal b','-AcceptedRoute','route b','-Json'
    ) $stateRoot
    $createdB.exitCode | Should Be 0

    $statusA = Invoke-ScopedContext @('-Action','Status','-WorkspaceKey',$workspaceA,'-Json') $stateRoot
    $statusB = Invoke-ScopedContext @('-Action','Status','-WorkspaceKey',$workspaceB,'-Json') $stateRoot
    $statusA.exitCode | Should Be 0
    $statusB.exitCode | Should Be 0
    $statusA.value.current.taskId | Should Be 'task-context-a'
    $statusB.value.current.taskId | Should Be 'task-context-b'

    $foreign = Invoke-ScopedContext @('-Action','Status','-TaskId','task-context-b','-WorkspaceKey',$workspaceA,'-Json') $stateRoot
    $foreign.exitCode | Should Be 1
    $foreign.value.status | Should Be 'missing'
    $foreign.value.current | Should BeNullOrEmpty

    $pointerRoot = Join-Path $stateRoot 'workspace\guard-state\current-task-context-pointers'
    $pointerA = Get-SuperBrainCanonicalTaskPath $pointerRoot $workspaceA '.json'
    $pointerB = Get-SuperBrainCanonicalTaskPath $pointerRoot $workspaceB '.json'
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerA | ConvertFrom-Json).taskId | Should Be 'task-context-a'
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerB | ConvertFrom-Json).taskId | Should Be 'task-context-b'

    $legacy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stateRoot 'workspace\current-task-context.json') | ConvertFrom-Json
    $legacy.taskId | Should Be 'task-context-a'
  }

  It 'does not authorize expired or version-mismatched workspace pointers in the prompt hook' {
    $stateRoot = Join-Path $TestDrive 'context-freshness'
    $workspaceKey = 'ws-c33333333333333333333333'
    $sessionKey = 'sid-c333333333333333333333333'
    $contractRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ContractScript -Action Set -TaskId 'task-context-freshness' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'context-line' -NextAction 'verify pointer freshness' -StateRoot $stateRoot -Json 2>$null)
    $LASTEXITCODE | Should Be 0
    $contractValue = (($contractRaw -join "`n") | ConvertFrom-Json)
    $contractValue.ok | Should Be $true
    $created = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-context-freshness','-WorkspaceKey',$workspaceKey,
      '-SessionId',$sessionKey,'-AcceptedGoal','verify pointer freshness','-AcceptedRoute','fresh pointer only','-Json'
    ) $stateRoot
    $created.exitCode | Should Be 0
    $workspaceRoot = Join-Path $stateRoot 'workspace'
    $pointerPath = [string]$created.value.workspacePointerPath
    $originalPointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $originalContractText = Get-Content -LiteralPath $contractValue.path -Raw -Encoding UTF8
    $packageVersion = [string](Get-SuperBrainManifest $Root).version
    $created.value.bindingState | Should Be 'bound'
    $created.value.authorizationState | Should Be 'authorizing'
    (Get-SuperBrainHookCurrentTaskContext $workspaceRoot $workspaceKey $packageVersion $sessionKey).taskId | Should Be 'task-context-freshness'

    $expired = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expired.expiresAt = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss')
    Write-JsonUtf8NoBom $pointerPath $expired 12
    Get-SuperBrainHookCurrentTaskContext $workspaceRoot $workspaceKey $packageVersion $sessionKey | Should BeNullOrEmpty

    $expired.expiresAt = (Get-Date).AddHours(1).ToString('yyyy-MM-dd HH:mm:ss')
    $expired.version = '0.0.0-stale'
    Write-JsonUtf8NoBom $pointerPath $expired 12
    Get-SuperBrainHookCurrentTaskContext $workspaceRoot $workspaceKey $packageVersion $sessionKey | Should BeNullOrEmpty

    Write-JsonUtf8NoBom $pointerPath $originalPointer 12
    $tamperedContract = $originalContractText | ConvertFrom-Json
    $tamperedContract.revision = [int]$tamperedContract.revision + 1
    Write-JsonUtf8NoBom $contractValue.path $tamperedContract 12
    Get-SuperBrainHookCurrentTaskContext $workspaceRoot $workspaceKey $packageVersion $sessionKey | Should BeNullOrEmpty

    [IO.File]::WriteAllText([string]$contractValue.path,$originalContractText,[Text.UTF8Encoding]::new($false))
    $wrongTaskStateRevision = $originalPointer | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $wrongTaskStateRevision.taskStateRevision = [int]$wrongTaskStateRevision.taskStateRevision + 1
    Write-JsonUtf8NoBom $pointerPath $wrongTaskStateRevision 12
    Get-SuperBrainHookCurrentTaskContext $workspaceRoot $workspaceKey $packageVersion $sessionKey | Should BeNullOrEmpty
  }

  It 'keeps a context without an exact contract as locator-only and non-authorizing' {
    $stateRoot = Join-Path $TestDrive 'locator-only'
    $workspaceKey = 'ws-252525252525252525252525'
    $created = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-context-locator-only','-WorkspaceKey',$workspaceKey,
      '-SessionId','session-locator-only','-AcceptedGoal','locate historical task only','-AcceptedRoute','do not authorize mutation','-Json'
    ) $stateRoot
    $created.exitCode | Should Be 0
    $created.value.bindingState | Should Be 'locator_only'
    $created.value.authorizationState | Should Be 'locator_only_non_authorizing'
    $created.value.contractRevision | Should Be 0
    $created.value.planFingerprint | Should BeNullOrEmpty
  }

  It 'binds canonical plan identity into the authorizing context projection' {
    $stateRoot = Join-Path $TestDrive 'canonical-context-binding'
    $workspaceKey = 'ws-canonical-context-202607'
    $sessionKey = 'sid-canonical-context-202607'
    $contractRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ContractScript -Action Set -TaskId 'task-canonical-context' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'canonical-main' -NextAction 'resume canonical phase' -CurrentPhase 'Phase 8' -CurrentStep 'reverse audit repair' -LastConfirmedSentence 'P1 fixes are verified.' -Evidence 'P1 evidence' -VerificationResults 'P1 verification' -PendingSteps 'resume canonical phase' -EnableCanonicalPlan -RequireStructuralGuards -StateRoot $stateRoot -Json 2>$null)
    $LASTEXITCODE | Should Be 0
    $contractValue = (($contractRaw -join "`n") | ConvertFrom-Json)

    $created = Invoke-ScopedContext @(
      '-Action','Create','-TaskId','task-canonical-context','-WorkspaceKey',$workspaceKey,
      '-SessionId',$sessionKey,'-AcceptedGoal','keep the canonical plan bound','-AcceptedRoute','canonical contract only','-Json'
    ) $stateRoot
    $created.exitCode | Should Be 0
    $created.value.bindingState | Should Be 'bound'
    $created.value.canonicalPlanId | Should Be $contractValue.canonicalPlan.planId
    [int]$created.value.canonicalGeneration | Should Be 1
    $created.value.canonicalFingerprint | Should Be $contractValue.canonicalPlan.currentFingerprint
    $created.value.compatibilityEpoch | Should Be 'context-contract-v2'
    $created.value.continuityReceipt.source | Should Be 'execution_contract'
    $created.value.continuityReceipt.phase | Should Be 'Phase 8'
    $created.value.continuityReceipt.currentStep | Should Be 'reverse audit repair'
    $created.value.continuityReceipt.taskNextAction | Should Be 'resume canonical phase'
    $created.value.continuityReceipt.lastConfirmedSentence | Should Be 'P1 fixes are verified.'
    (@($created.value.continuityReceipt.evidence) -contains 'P1 evidence') | Should Be $true
    (@($created.value.continuityReceipt.verificationResults) -contains 'P1 verification') | Should Be $true
    $created.value.taskStateSource | Should Be 'continuity_receipt'
    $created.value.taskPhase | Should Be 'Phase 8'
    $created.value.taskCurrentStep | Should Be 'reverse audit repair'
    $created.value.taskNextAction | Should Be 'resume canonical phase'
    $created.value.taskLastConfirmedSentence | Should Be 'P1 fixes are verified.'
    (@($created.value.taskEvidence) -contains 'P1 evidence') | Should Be $true
    (@($created.value.taskVerificationResults) -contains 'P1 verification') | Should Be $true
    $created.value.guardStatePaths.goalRouteLock | Should Be (Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'workspace\guard-state\goal-route-locks') 'task-canonical-context' '.json')
    $created.value.guardStatePaths.routeCheckpoint | Should Be (Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'workspace\guard-state\route-checkpoints') 'task-canonical-context' '.json')
  }
}
