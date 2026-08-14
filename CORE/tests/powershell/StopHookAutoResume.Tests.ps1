$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Contract = Join-Path $Root 'scripts\execution-contract.ps1'
$NativeUserPromptHook = Join-Path $Root 'runtime\codex_prompt_hook.py'
$DispatcherSource = Join-Path $Root 'runtime\codex_stop_hook_dispatcher.py'
$HandlerSource = Join-Path $Root 'runtime\codex_stop_hook.py'
$Python = Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1

. (Join-Path $Root 'scripts\common.ps1')

function Invoke-StopHookContract([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Contract @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{
    exitCode = $exitCode
    value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    text = $text
  }
}

function New-StopHookTestScope {
  $base = Join-Path $TestDrive ('stop-hook-' + [guid]::NewGuid().ToString('n'))
  $workspace = Join-Path $base 'user-workspace'
  $stateRoot = Join-Path $base 'state'
  $codexHome = Join-Path $base 'codex-home'
  $stableRoot = Join-Path $codexHome 'hooks\super-memory-brain'
  New-Item -ItemType Directory -Force -Path $workspace,$stateRoot,$stableRoot | Out-Null

  $stableDispatcher = Join-Path $stableRoot 'codex_stop_hook_dispatcher.py'
  Copy-Item -LiteralPath $DispatcherSource -Destination $stableDispatcher -Force
  $handlerHash = (Get-FileHash -LiteralPath $HandlerSource -Algorithm SHA256).Hash.ToLowerInvariant()
  $handlerConfig = [ordered]@{
    schema = 'super-brain.stop-hook-handler-config.v1'
    generation = 'sg-test-' + [guid]::NewGuid().ToString('n')
    handlerPath = [IO.Path]::GetFullPath($HandlerSource)
    handlerSha256 = $handlerHash
    packageRoot = [IO.Path]::GetFullPath($Root)
    stateRoot = [IO.Path]::GetFullPath($stateRoot)
    stableDispatcherPath = [IO.Path]::GetFullPath($stableDispatcher)
    rawPromptStored = $false
  }
  [IO.File]::WriteAllText((Join-Path $stableRoot 'stop-handler.json'),($handlerConfig | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{
    workspace = [IO.Path]::GetFullPath($workspace)
    workspaceKey = Get-SuperBrainWorkspaceKey $workspace
    stateRoot = [IO.Path]::GetFullPath($stateRoot)
    codexHome = [IO.Path]::GetFullPath($codexHome)
    stableDispatcher = [IO.Path]::GetFullPath($stableDispatcher)
  }
}

function Get-StopHookStateDigest([string]$StateRoot) {
  if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) { return '' }
  $entries = @(
    Get-ChildItem -LiteralPath $StateRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
      $relative = $_.FullName.Substring($StateRoot.Length).TrimStart('\')
      $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      $relative + '|' + $hash
    }
  )
  return $entries -join "`n"
}

function Invoke-StopDispatcher([string]$CodexHome,[string]$Workspace,[hashtable]$Payload) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = [string]$Python.Source
  $start.Arguments = '-X utf8 -B "' + $DispatcherSource + '" --codex-home "' + $CodexHome + '"'
  $start.WorkingDirectory = $Workspace
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = [Diagnostics.Process]::Start($start)
  $input = ($Payload | ConvertTo-Json -Depth 8 -Compress)
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($input)
  $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
  $process.StandardInput.BaseStream.Flush()
  $process.StandardInput.Close()
  $output = $process.StandardOutput.ReadToEnd()
  $errorText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  return [pscustomobject]@{
    exitCode = $process.ExitCode
    output = $output.Trim()
    error = $errorText
    value = if ([string]::IsNullOrWhiteSpace($output)) { $null } else { $output | ConvertFrom-Json }
  }
}

function Invoke-NativeUserPromptLifecycleHook([string]$StateRoot,[string]$Workspace,[string]$WorkspaceKey,[hashtable]$Payload) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = [string]$Python.Source
  $start.Arguments = '-X utf8 -B "' + $NativeUserPromptHook + '" --package-root "' + $Root + '"'
  $start.WorkingDirectory = $Workspace
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.EnvironmentVariables['SUPER_BRAIN_STATE_ROOT'] = $StateRoot
  $start.EnvironmentVariables['SUPER_BRAIN_WORKSPACE_KEY'] = $WorkspaceKey
  $process = [Diagnostics.Process]::Start($start)
  $input = ($Payload | ConvertTo-Json -Depth 8 -Compress)
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($input)
  $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
  $process.StandardInput.BaseStream.Flush()
  $process.StandardInput.Close()
  $output = $process.StandardOutput.ReadToEnd()
  $errorText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  return [pscustomobject]@{
    exitCode = $process.ExitCode
    output = $output.Trim()
    error = $errorText
    value = if ([string]::IsNullOrWhiteSpace($output)) { $null } else { $output | ConvertFrom-Json }
  }
}

function New-StopPayload([string]$SessionKey,[string]$Workspace,[bool]$StopHookActive=$false) {
  return [ordered]@{
    session_id = $SessionKey
    cwd = $Workspace
    stop_hook_active = $StopHookActive
    ui_marker = '状态问答：用户级 UTF-8 模拟'
    raw_user_text = 'RAW_USER_TEXT_MUST_NOT_BE_ECHOED'
  }
}

Describe 'Codex Stop hook automatic workline continuation' {
  It 'simulates the full user path: pre-turn gate, status reply stop, and one continuation' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-full-user-path'
    $prompt = 'What is the current progress?'
    $created = Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-full-user-path','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','approved-main','-FocusLabel','Approved main line',
      '-LatestUserInstruction',$prompt,'-AssistantCommitment','Answer the status question, then continue the approved work.',
      '-CurrentPhase','Stage 1','-CurrentStep','exercise the full lifecycle seam',
      '-NextAction','run the next approved local verification','-PendingSteps','run the next approved local verification',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $created.exitCode | Should Be 0

    $preTurn = Invoke-NativeUserPromptLifecycleHook $scope.stateRoot $scope.workspace $scope.workspaceKey ([ordered]@{
      session_id = $session
      cwd = $scope.workspace
      prompt = $prompt
      ui_marker = '状态问答：用户级 UTF-8 模拟'
    })
    $context = [string]$preTurn.value.hookSpecificOutput.additionalContext
    $preTurn.exitCode | Should Be 0
    $preTurn.error | Should BeNullOrEmpty
    $context.Contains('turnCompletionGate=required') | Should Be $true
    $context.Contains('close=authorized-action-or-NoAutomaticAction') | Should Be $true

    $reconciled = Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-full-user-path','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','approved-main','-FocusLabel','Approved main line',
      '-LatestUserInstruction',$prompt,'-AssistantCommitment','Answer the status question, then continue the approved work.',
      '-CurrentPhase','Stage 1','-CurrentStep','status request reconciled before continuation',
      '-NextAction','run the next approved local verification','-PendingSteps','run the next approved local verification',
      '-ExpectedRevision',[string]$created.value.revision,'-ExpectedPlanFingerprint',[string]$created.value.planReceipt.planFingerprint,
      '-TransitionId','stop-full-user-path-reconcile','-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $reconciled.exitCode | Should Be 0
    $resolvedBeforeStop = Invoke-StopHookContract @(
      '-Action','Resolve','-TaskId','task-stop-full-user-path','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $resolvedBeforeStop.exitCode | Should Be 0
    $resolvedBeforeStop.value.actionAuthorization | Should Be 'allowed'
    $resolvedBeforeStop.value.claimAllowed | Should Be $true

    $stop = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $contractHashBeforeLifecycle = (Get-FileHash -LiteralPath $reconciled.value.path -Algorithm SHA256).Hash
    $lifecycle = Invoke-NativeUserPromptLifecycleHook $scope.stateRoot $scope.workspace $scope.workspaceKey ([ordered]@{
      session_id = $session
      cwd = $scope.workspace
      prompt = [string]$stop.value.reason
    })
    $contractHashAfterLifecycle = (Get-FileHash -LiteralPath $reconciled.value.path -Algorithm SHA256).Hash
    $continued = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace $true)
    $stop.exitCode | Should Be 0
    $stop.value.decision | Should Be 'block'
    $stop.value.reason | Should Match 'run the next approved local verification'
    $lifecycle.exitCode | Should Be 0
    ([string]$lifecycle.value.hookSpecificOutput.additionalContext).Contains('SUPER_BRAIN_LIFECYCLE_CONTINUATION') | Should Be $true
    ([string]$lifecycle.value.hookSpecificOutput.additionalContext).Contains('actionAuthorization=allowed') | Should Be $true
    ([string]$lifecycle.value.hookSpecificOutput.additionalContext).Contains('authorizedNextAction=run the next approved local verification') | Should Be $true
    $contractHashBeforeLifecycle | Should Be $contractHashAfterLifecycle
    $continued.exitCode | Should Be 0
    $continued.output | Should Be '{}'

    $telemetry = Get-ChildItem -LiteralPath $scope.stateRoot -Recurse -Filter '*.json' -File |
      Where-Object { $_.FullName -match 'prompt-hook-telemetry' } | Select-Object -First 1
    $telemetry | Should Not BeNullOrEmpty
    $telemetryText = Get-Content -Raw -Encoding UTF8 -LiteralPath $telemetry.FullName
    $telemetryText.Contains($prompt) | Should Be $false
    $telemetryState = $telemetryText | ConvertFrom-Json
    $telemetryState.rawPromptStored | Should Be $false
    $telemetryState.executionContractCapture.lifecycleContinuation | Should Be $true
  }

  It 'simulates a user status request and blocks terminal completion without changing state' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-user-level'
    $created = Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-user-level','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','approved-main','-FocusLabel','Approved main line',
      '-LatestUserInstruction','What is the current progress?','-AssistantCommitment','Answer the status question, then continue the approved work.',
      '-CurrentPhase','Stage 1','-CurrentStep','simulate a real user status request',
      '-NextAction','run the next approved local verification','-PendingSteps','run the next approved local verification',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )

    $created.exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.error | Should BeNullOrEmpty
    $result.value.decision | Should Be 'block'
    $result.value.reason | Should Match 'status-only'
    $result.value.reason | Should Match 'run the next approved local verification'
    $result.value.reason.Contains('RAW_USER_TEXT_MUST_NOT_BE_ECHOED') | Should Be $false
    $before | Should Be $after
  }

  It 'never recursively re-blocks the continuation turn' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-recursion'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-recursion','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','approved-main','-NextAction','finish the bounded local check',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace $true)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $before | Should Be $after
  }

  It 'fails open for a foreign session and does not leak the protected next action' {
    $scope = New-StopHookTestScope
    $owner = 'sid-stop-owner'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-foreign','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$owner,
      '-InstructionMode','continue','-FocusId','private-main','-NextAction','FOREIGN_STOP_ACTION_SENTINEL',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload 'sid-stop-foreign' $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $result.output.Contains('FOREIGN_STOP_ACTION_SENTINEL') | Should Be $false
    $before | Should Be $after
  }

  It 'fails open when the current action explicitly needs user input' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-user-input'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-user-input','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','user-input-main','-NextAction','No automatic action: waiting for the user to choose a deployment target.',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $before | Should Be $after
  }

  It 'fails open when a newer user instruction still requires reconciliation' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-reconcile'
    $taskId = 'task-stop-reconcile'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','reconcile-main','-NextAction','RECONCILE_ACTION_SENTINEL',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    (Invoke-StopHookContract @(
      '-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-UserInstruction','please reconcile this newer status question','-RequiresReconciliation',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $result.output.Contains('RECONCILE_ACTION_SENTINEL') | Should Be $false
    $before | Should Be $after
  }

  It 'treats a bare user stop as a terminal control signal' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-explicit-stop'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-explicit-stop','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','stoppable-main','-LatestUserInstruction','stop',
      '-NextAction','EXPLICIT_STOP_ACTION_SENTINEL','-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $result.output.Contains('EXPLICIT_STOP_ACTION_SENTINEL') | Should Be $false
    $before | Should Be $after
  }

  It 'fails open when the contract records a concrete blocker despite a specific next action' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-blocker'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-blocker','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','blocked-main','-NextAction','run a local verification after the blocker clears',
      '-Blockers','waiting for explicit user authorization','-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $before | Should Be $after
  }

  It 'continues when an unrelated P7 evidence wait is explicitly nonblocking for core work' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-nonblocking-evidence'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-nonblocking-evidence','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','core-main','-NextAction','NONBLOCKING_CORE_ACTION_SENTINEL',
      '-Blockers','P7 awaits a real host receipt; it does not block core continuity.',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.value.decision | Should Be 'block'
    $result.value.reason | Should Match 'NONBLOCKING_CORE_ACTION_SENTINEL'
    $before | Should Be $after
  }

  It 'uses the payload cwd instead of a stale inherited workspace key' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-cwd-boundary'
    (Invoke-StopHookContract @(
      '-Action','Set','-TaskId','task-stop-cwd-boundary','-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','cwd-bound-main','-NextAction','CWD_BOUND_ACTION_SENTINEL',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )).exitCode | Should Be 0
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_WORKSPACE_KEY = 'ws-stale-inherited-workspace-key'
      $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
      $result.exitCode | Should Be 0
      $result.value.decision | Should Be 'block'
      $result.value.reason | Should Match 'CWD_BOUND_ACTION_SENTINEL'
    } finally {
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'fails open when the payload scope resolves to two active tasks' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-ambiguous'
    foreach ($task in @(
      [pscustomobject]@{id='task-stop-ambiguous-a';action='AMBIGUOUS_ACTION_A_SENTINEL'},
      [pscustomobject]@{id='task-stop-ambiguous-b';action='AMBIGUOUS_ACTION_B_SENTINEL'}
    )) {
      (Invoke-StopHookContract @(
        '-Action','Set','-TaskId',$task.id,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
        '-InstructionMode','continue','-FocusId',$task.id,'-NextAction',$task.action,
        '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
      )).exitCode | Should Be 0
    }
    foreach ($path in @(
      (Join-Path $scope.stateRoot 'workspace\current-task-context.json'),
      (Join-Path $scope.stateRoot 'workspace\guard-state\current-task-context-pointers'),
      (Join-Path $scope.stateRoot 'workspace\runtime-state\execution-hot-index')
    )) {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    $before = Get-StopHookStateDigest $scope.stateRoot
    $result = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $after = Get-StopHookStateDigest $scope.stateRoot

    $result.exitCode | Should Be 0
    $result.output | Should Be '{}'
    $result.output.Contains('AMBIGUOUS_ACTION_A_SENTINEL') | Should Be $false
    $result.output.Contains('AMBIGUOUS_ACTION_B_SENTINEL') | Should Be $false
    $before | Should Be $after
  }

  It 'keeps a side branch unchanged, then resumes the parent through the authoritative contract' {
    $scope = New-StopHookTestScope
    $session = 'sid-stop-parent-return'
    $taskId = 'task-stop-parent-return'
    $root = Invoke-StopHookContract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','continue','-FocusId','root-main','-FocusLabel','Root main line','-NextAction','ROOT_NEXT_ACTION_SENTINEL',
      '-PendingSteps','ROOT_NEXT_ACTION_SENTINEL','-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $side = Invoke-StopHookContract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-InstructionMode','side_branch','-FocusId','status-side','-FocusLabel','Status side branch','-NextAction','SIDE_NEXT_ACTION_SENTINEL',
      '-PendingSteps','SIDE_NEXT_ACTION_SENTINEL','-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $root.exitCode | Should Be 0
    $side.exitCode | Should Be 0
    $beforeStop = Get-StopHookStateDigest $scope.stateRoot
    $sideStop = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $afterStop = Get-StopHookStateDigest $scope.stateRoot

    $sideStop.exitCode | Should Be 0
    $sideStop.value.decision | Should Be 'block'
    $sideStop.value.reason | Should Match 'SIDE_NEXT_ACTION_SENTINEL'
    $beforeStop | Should Be $afterStop

    $resumed = Invoke-StopHookContract @(
      '-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$scope.workspaceKey,'-SessionKey',$session,
      '-BranchStatus','completed','-CompletionEvidence','status response delivered and verified',
      '-StateRoot',$scope.stateRoot,'-NoExit','-Json'
    )
    $resumed.exitCode | Should Be 0
    $resumed.value.focusId | Should Be 'root-main'
    @($resumed.value.returnStack).Count | Should Be 0
    $resumed.value.nextAction | Should Be 'ROOT_NEXT_ACTION_SENTINEL'

    $rootStop = Invoke-StopDispatcher $scope.codexHome $scope.workspace (New-StopPayload $session $scope.workspace)
    $rootStop.exitCode | Should Be 0
    $rootStop.value.decision | Should Be 'block'
    $rootStop.value.reason | Should Match 'ROOT_NEXT_ACTION_SENTINEL'
    $rootStop.value.reason.Contains('SIDE_NEXT_ACTION_SENTINEL') | Should Be $false
  }
}
