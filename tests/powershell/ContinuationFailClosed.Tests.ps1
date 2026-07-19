$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Contract = Join-Path $Root 'scripts\execution-contract.ps1'
$AutoContinuation = Join-Path $Root 'scripts\auto-continuation.ps1'
$SmartNext = Join-Path $Root 'scripts\smart-next.ps1'

. (Join-Path $Root 'scripts\common.ps1')

function Write-TestJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Initialize-ContinuationState([string]$StateRoot) {
  $version = [string](Get-SuperBrainManifest $Root).version
  Write-TestJson (Join-Path $StateRoot 'workspace\last-verify-package.json') ([pscustomobject]@{
    ok = $true
    version = $version
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  })
  Write-TestJson (Join-Path $StateRoot 'workspace\skill-capability-map.json') ([pscustomobject]@{
    schema = 'super-brain.skill-capability-map.v1'
    capabilities = @()
  })
}

function Set-AmbiguousContract([string]$StateRoot,[string]$WorkspaceKey,[string]$TaskId) {
  @(& $Contract -Action Set -TaskId $TaskId -WorkspaceKey $WorkspaceKey -FocusId 'main-line' -FocusLabel 'Main line' -TopicKeys @('shared-anchor') -NextAction 'implement old main action' -StateRoot $StateRoot -NoExit -Json) | Out-Null
  @(& $Contract -Action Set -TaskId $TaskId -WorkspaceKey $WorkspaceKey -FocusId 'side-line' -FocusLabel 'Side line' -TopicKeys @('shared-anchor') -NextAction 'implement old side action' -StateRoot $StateRoot -NoExit -Json) | Out-Null
}

Describe 'Continuation fail-closed behavior' {
  It 'withholds every stale implementation action for ambiguous and unknown affinity' {
    $stateRoot = Join-Path $TestDrive 'auto-affinity-state'
    $workspaceKey = 'ws-a11111111111111111111111'
    Initialize-ContinuationState $stateRoot
    Set-AmbiguousContract $stateRoot $workspaceKey 'task-auto-affinity'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      foreach ($case in @(
        [pscustomobject]@{ text='shared-anchor needs repair'; affinity='ambiguous' },
        [pscustomobject]@{ text='a completely unmapped request'; affinity='unknown' }
      )) {
        $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoContinuation -WorkspaceKey $workspaceKey -VisibleUserInstruction $case.text -AllowStaleVerify -Json 2>$null)
        $exitCode = $LASTEXITCODE
        $result = (($raw -join "`n") | ConvertFrom-Json)
        $serialized = $result | ConvertTo-Json -Depth 12

        $exitCode | Should Be 0
        $result.executionResolution.latestMessageClassification.topicAffinity | Should Be $case.affinity
        $result.mutationAuthorized | Should Be $false
        $result.nextAction | Should Match 'confirm|reconcile|withheld'
        $serialized.Contains('implement old main action') | Should Be $false
        $serialized.Contains('implement old side action') | Should Be $false
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'propagates the explicit workspace key and cannot route ambiguity into implementation commands' {
    $stateRoot = Join-Path $TestDrive 'smart-affinity-state'
    $workspacePath = Join-Path $TestDrive 'explicit-smart-workspace'
    $workspaceKey = Get-SuperBrainWorkspaceKey $workspacePath
    Initialize-ContinuationState $stateRoot
    Set-AmbiguousContract $stateRoot $workspaceKey 'task-smart-affinity'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = 'ws-ffffffffffffffffffffffff'
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SmartNext -Workspace $workspacePath -Text 'fix shared-anchor now' -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $serialized = $result | ConvertTo-Json -Depth 12

      $exitCode | Should Be 0
      $result.workspaceKey | Should Be $workspaceKey
      $result.executionResolution.workspaceKey | Should Be $workspaceKey
      $result.latestMessageClassification.topicAffinity | Should Be 'ambiguous'
      $result.workLineMutationAuthorized | Should Be $false
      @($result.commands).Count | Should Be 0
      @($result.orcComposition.routePlan).Count | Should Be 0
      $result.nextAction | Should Match 'confirm|reconcile|withheld'
      $serialized.Contains('implement old main action') | Should Be $false
      $serialized.Contains('implement old side action') | Should Be $false
      $serialized.Contains('Implement the focused feature') | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'bounds large smart-next input and output collections' {
    $stateRoot = Join-Path $TestDrive 'smart-large-input-state'
    $workspacePath = Join-Path $TestDrive 'smart-large-input-workspace'
    $sentinel = 'RAW_INPUT_TAIL_MUST_NOT_ECHO'
    $largeInput = 'fix ' + ('x' * 12000) + $sentinel
    Initialize-ContinuationState $stateRoot
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SmartNext -Workspace $workspacePath -Text $largeInput -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $serialized = $result | ConvertTo-Json -Depth 12

      $exitCode | Should Be 0
      ([string]$result.input).Length -le 1200 | Should Be $true
      ([string]$result.workspace).Length -le 260 | Should Be $true
      $serialized.Contains($sentinel) | Should Be $false
      @($result.commands).Count -le 12 | Should Be $true
      @($result.why).Count -le 12 | Should Be $true
      @($result.dashboardRisks).Count -le 6 | Should Be $true
      @($result.blockingConditions).Count -le 6 | Should Be $true
      @($result.orcComposition.routePlan).Count -le 12 | Should Be $true
      @($result.dispatchRecommendations).Count -le 3 | Should Be $true
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'withholds recursive actions from every foreign-session continuation consumer' {
    $stateRoot = Join-Path $TestDrive 'foreign-session-consumers'
    $workspacePath = Join-Path $TestDrive 'foreign-session-workspace'
    $workspaceKey = Get-SuperBrainWorkspaceKey $workspacePath
    $taskId = 'task-foreign-session-consumers'
    $ownerSession = 'owner-session-consumers'
    $foreignSession = 'foreign-session-consumers'
    $sentinels = @(
      'FOREIGN_MAIN_ACTION_SENTINEL',
      'FOREIGN_PARTIAL_ACTION_SENTINEL',
      'FOREIGN_SIDE_ACTION_SENTINEL',
      'FOREIGN_ASSISTANT_COMMITMENT_SENTINEL',
      'FOREIGN_CHECKPOINT_ACTION_SENTINEL',
      'FOREIGN_PENDING_STEP_SENTINEL',
      'FOREIGN_VERIFY_COMMAND_SENTINEL',
      'FOREIGN_STATUS_ACTION_SENTINEL',
      'FOREIGN_SNAPSHOT_ACTION_SENTINEL'
    )
    Initialize-ContinuationState $stateRoot
    @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $ownerSession -FocusId 'foreign-main' -FocusLabel 'Foreign main' -NextAction $sentinels[0] -AssistantCommitment $sentinels[3] -StateRoot $stateRoot -NoExit -Json) | Out-Null
    @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $ownerSession -InstructionMode side_branch -FocusId 'foreign-partial' -FocusLabel 'Foreign partial' -NextAction $sentinels[1] -StateRoot $stateRoot -NoExit -Json) | Out-Null
    @(& $Contract -Action ResumeParent -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $ownerSession -BranchStatus partial -StateRoot $stateRoot -NoExit -Json) | Out-Null
    @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $ownerSession -InstructionMode side_branch -FocusId 'foreign-side' -FocusLabel 'Foreign side' -NextAction $sentinels[2] -AssistantCommitment $sentinels[3] -StateRoot $stateRoot -NoExit -Json) | Out-Null

    Write-TestJson (Join-Path $stateRoot 'workspace\current-task-context.json') ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='active'; stale=$false; expiresAt=(Get-Date).AddHours(2).ToString('o') })
    $checkpointPath = Join-Path $stateRoot ('workspace\runtime-state\checkpoints\active\' + $taskId + '.json')
    Write-TestJson $checkpointPath ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='active'; currentPhase='foreign-phase'; currentStep='foreign-state-only'; nextAction=$sentinels[4]; pendingSteps=@($sentinels[5]); verificationCommands=@($sentinels[6]); updatedAt=(Get-Date).ToString('o') })
    Write-TestJson (Join-Path $stateRoot 'workspace\status-card.json') ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; ok=$true; nextAction=$sentinels[7]; updatedAt=(Get-Date).ToString('o') })
    Write-TestJson (Join-Path $stateRoot 'workspace\last-status-snapshot.json') ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; summary='foreign status only'; nextAction=$sentinels[8]; checkedAt=(Get-Date).ToString('o') })

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $resolve = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Contract -Action Resolve -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $foreignSession -StateRoot $stateRoot -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $dashboard = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\super-brain-dashboard.ps1') -WorkspaceKey $workspaceKey -SessionKey $foreignSession -AllowStaleVerify -AllowActiveCheckpoint -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $continuation = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoContinuation -WorkspaceKey $workspaceKey -SessionKey $foreignSession -AllowStaleVerify -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $restore = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\session-restore.ps1') -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $foreignSession -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $smart = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SmartNext -Workspace $workspacePath -SessionKey $foreignSession -Text 'continue foreign task' -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $ordinarySmart = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SmartNext -Workspace $workspacePath -SessionKey $foreignSession -Text 'build an unrelated local calculator feature' -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $enforce = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\cognitive-enforce.ps1') -Query 'general task' -Phase BeforeMutation -TaskId $taskId -ProposedWorkId 'foreign-side' -SessionKey $foreignSession -Json 2>$null) -join "`n") | ConvertFrom-Json)

      $resolve.sessionAccess | Should Be 'foreign'
      $resolve.actionAuthorization | Should Be 'withheld'
      $resolve.canResumeParent | Should Be $false
      $dashboard.executionResolutionStatus | Should Be 'no_contract'
      $dashboard.executionResolution.actionAuthorization | Should Be 'not_applicable'
      $dashboard.mutationAuthorized | Should Be $false
      $continuation.executionResolutionStatus | Should Be 'no_contract'
      $continuation.actionWithheld | Should Be $true
      $restore.executionResolution.sessionAccess | Should Be 'foreign'
      $restore.recoveryPoint.source | Should Be 'execution_contract_action_withheld'
      $smart.workLineMutationAuthorized | Should Be $false
      @($smart.commands).Count | Should Be 0
      $ordinarySmart.actionWithheld | Should Be $false
      @($ordinarySmart.commands).Count | Should BeGreaterThan 0
      $enforce.executionContract.required | Should Be $true
      $enforce.executionContract.ok | Should Be $false
      $enforce.executionContract.code | Should Be 'EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'

      $payloads = [ordered]@{resolve=$resolve;dashboard=$dashboard;continuation=$continuation;restore=$restore;smart=$smart;ordinarySmart=$ordinarySmart;enforce=$enforce}
      foreach ($payloadName in @($payloads.Keys)) {
        $serialized = $payloads[$payloadName] | ConvertTo-Json -Depth 12
        foreach ($sentinel in $sentinels) {
          if ($serialized.Contains($sentinel)) { throw "payload=$payloadName leaked sentinel=$sentinel" }
        }
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'preserves the exact Chinese Agent Bridge alias in Windows PowerShell 5.1' {
    $stateRoot = Join-Path $TestDrive 'smart-ps5-alias-state'
    $workspacePath = Join-Path $TestDrive 'smart-ps5-alias-workspace'
    $alias = (-join (@(23376) | ForEach-Object { [char]$_ })) + 'agent'
    $prompt = (-join (@(25171,24320,23376) | ForEach-Object { [char]$_ })) + 'agent' + (-join (@(36890,36947) | ForEach-Object { [char]$_ }))
    Initialize-ContinuationState $stateRoot
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SmartNext -Workspace $workspacePath -Text $prompt -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $openCommand = [string](@($result.commands | Where-Object { [string]$_ -match 'agent-bridge-channel\.ps1 -Action Open' } | Select-Object -First 1))

      $exitCode | Should Be 0
      $result.intent | Should Be 'agent_bridge_channel'
      $openCommand.Contains('-Alias "' + $alias + '"') | Should Be $true
      $openCommand.Contains($alias) | Should Be $true
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'fails closed across every consumer when execution-contract resolution errors' {
    $stateRoot = Join-Path $TestDrive 'resolver-error-consumers'
    $workspaceKey = 'ws-f70707070707070707070707'
    $taskId = 'task-resolver-error-consumers'
    $session = 'root-resolver-error'
    $summarySentinel = 'FAILED_RESOLVER_SUMMARY_MUST_NOT_LEAK'
    Initialize-ContinuationState $stateRoot
    $createdRaw = @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $session -FocusId 'resolver-line' -NextAction 'FAILED_RESOLVER_ACTION_MUST_NOT_LEAK' -StateRoot $stateRoot -NoExit -Json)
    $created = (($createdRaw -join "`n") | ConvertFrom-Json)
    Write-TestJson (Join-Path $stateRoot 'workspace\current-task-context.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceKey;status='active'})
    Write-TestJson (Join-Path $stateRoot 'workspace\last-task-verification.json') ([pscustomobject]@{ok=$true;taskId=$taskId;workspaceKey=$workspaceKey;summary=$summarySentinel})
    $broken = Get-Content -LiteralPath $created.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $broken.revision = 'not-an-integer'
    Write-TestJson $created.path $broken

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $dashboard = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\super-brain-dashboard.ps1') -WorkspaceKey $workspaceKey -SessionKey $session -AllowStaleVerify -AllowActiveCheckpoint -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $continuation = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoContinuation -WorkspaceKey $workspaceKey -SessionKey $session -AllowStaleVerify -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $restore = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\session-restore.ps1') -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $session -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $enforce = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\cognitive-enforce.ps1') -Query 'general task' -Phase BeforeMutation -TaskId $taskId -ProposedWorkId 'resolver-line' -SessionKey $session -AllowMissingPreflight -Json 2>$null) -join "`n") | ConvertFrom-Json)

      $dashboard.executionResolutionStatus | Should Be 'failed'
      $dashboard.executionResolutionFailureCode | Should Be 'EXECUTION_CONTRACT_ERROR'
      $dashboard.nextActionSource | Should Be 'execution_resolution_failed'
      $dashboard.mutationAuthorized | Should Be $false
      $dashboard.task.summary | Should BeNullOrEmpty
      $continuation.executionResolutionStatus | Should Be 'failed'
      $continuation.continuationState | Should Be 'resolver_failed'
      $continuation.actionWithheld | Should Be $true
      $continuation.mutationAuthorized | Should Be $false
      $restore.executionResolutionStatus | Should Be 'failed'
      $restore.recoveryPoint.source | Should Be 'execution_contract_resolution_failed'
      $restore.nextAction | Should Match 'resolution failed'
      $enforce.ok | Should Be $false
      $enforce.executionContract.status | Should Be 'resolver_failed'
      $enforce.executionContract.code | Should Be 'EXECUTION_CONTRACT_ERROR'
      foreach ($payload in @($dashboard,$continuation,$restore,$enforce)) {
        (($payload | ConvertTo-Json -Depth 12).Contains($summarySentinel)) | Should Be $false
        (($payload | ConvertTo-Json -Depth 12).Contains('FAILED_RESOLVER_ACTION_MUST_NOT_LEAK')) | Should Be $false
      }
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'keeps a successful no-contract result nonblocking without authorizing mutation' {
    $stateRoot = Join-Path $TestDrive 'no-contract-consumers'
    $workspaceKey = 'ws-f80808080808080808080808'
    $session = 'root-no-contract-consumers'
    Initialize-ContinuationState $stateRoot
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $dashboard = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\super-brain-dashboard.ps1') -WorkspaceKey $workspaceKey -SessionKey $session -AllowStaleVerify -AllowActiveCheckpoint -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $continuation = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoContinuation -WorkspaceKey $workspaceKey -SessionKey $session -AllowStaleVerify -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $restore = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\session-restore.ps1') -WorkspaceKey $workspaceKey -SessionKey $session -Json 2>$null) -join "`n") | ConvertFrom-Json)
      $enforce = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\cognitive-enforce.ps1') -Query 'general task' -Phase BeforeMutation -SessionKey $session -AllowMissingPreflight -Json 2>$null) -join "`n") | ConvertFrom-Json)

      $dashboard.executionResolutionStatus | Should Be 'no_contract'
      $dashboard.mutationAuthorized | Should Be $false
      $dashboard.nextActionSource | Should Not Be 'execution_resolution_failed'
      $continuation.executionResolutionStatus | Should Be 'no_contract'
      $continuation.continuationState | Should Be 'no_contract'
      $continuation.actionWithheld | Should Be $false
      $continuation.mutationAuthorized | Should Be $false
      $restore.executionResolutionStatus | Should Be 'no_contract'
      $restore.recoveryPoint.source | Should Be 'none'
      $enforce.ok | Should Be $true
      $enforce.executionContract.status | Should Be 'no_contract'
      $enforce.executionContract.required | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }
}
