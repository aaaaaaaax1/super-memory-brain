Describe 'Execution-state resume regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps product, task, checkpoint, and memory-noise semantics in the system control plane' {
    $controlText = Get-Content -LiteralPath (Join-Path $root 'references\runtime-control-plane.md') -Raw -Encoding UTF8
    foreach ($marker in @('Product coherence and feature intent','Current task status and resume receipt','Checkpoints and crash recovery','Memory admission and OCR/log/code-noise isolation')) {
      $controlText.Contains($marker) | Should Be $true
    }
  }
  It 'keeps execution checkpoint fields for interruption recovery' {
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\checkpoint-writer.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('Goal','CurrentPhase','CompletedSteps','PendingSteps','ChangedFiles','VerificationCommands','VerificationResults','WaitingForUser')) {
      $scriptText.Contains($marker) | Should Be $true
    }
  }
  It 'keeps cross-agent session task identity index and compact task table markers' {
    $checkpointText = Get-Content -LiteralPath (Join-Path $root 'scripts\checkpoint-writer.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('AgentId','SessionName','TaskName','MemoryIds','memory/shared/agents','session-task-links.json','task-memory-links.json')) {
      $checkpointText.Contains($marker) | Should Be $true
    }
    $taskRegisterPath = Join-Path $root 'scripts\task-register.ps1'
    Test-Path -LiteralPath $taskRegisterPath | Should Be $true
    $taskRegisterText = Get-Content -LiteralPath $taskRegisterPath -Raw -Encoding UTF8
    foreach ($marker in @('Fast path only','memory/shared/agents','session-task-links.json','task-memory-links.json','never touches active-checkpoint.json','SessionTitle','ConversationTitle')) {
      $taskRegisterText.Contains($marker) | Should Be $true
    }
    foreach ($heavy in @('doctor.ps1','verify-package.ps1','hot-refresh-skills.ps1','ci.ps1','super-brain-dashboard.ps1','recall-search.ps1')) {
      $taskRegisterText.Contains($heavy) | Should Be $true
    }
    $taskIndexText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-index.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('[switch]$Table','[string]$Agent','[string]$SessionId','sessionName','agentId','identityKey','unknownSession')) {
      $taskIndexText.Contains($marker) | Should Be $true
    }
    $wakeCoreText = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\runtime-wake-core.ps1') -Raw -Encoding UTF8
    $executionText = Get-Content -LiteralPath (Join-Path $root 'scripts\execution-contract.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.execution-hot-index.v1','ownerSessionKey','workspaceKey','entryCount')) {
      ($wakeCoreText + $executionText).Contains($marker) | Should Be $true
    }
  }
  It 'keeps agent bridge shared channel markers' {
    $channelPath = Join-Path $root 'scripts\agent-bridge-channel.ps1'
    Test-Path -LiteralPath $channelPath | Should Be $true
    $channelText = Get-Content -LiteralPath $channelPath -Raw -Encoding UTF8
    foreach ($marker in @("ValidateSet('Open','Connect','Send','Inbox','WaitInbox','Ack','WaitConnect','WaitReply','SendAndWait','Active','Close','Status')",'target-session','last-agent-bridge-channel.json','active-agent-bridge-channel.json','SendAndWait','WaitReply','WaitConnect','WaitInbox','waiting_connect','message_received','connectedAt','boundedWait','noRepeatedWaitingOutput','Alias','userCloseClearsActive','Write-JsonUtf8NoBom','Add-Utf8LineLocked','channels','Open is a subordinate/target-session entry command','not reuse the operator''s active/last channel','idle_waiting_connect','idle_waiting_message','noProgressReportRequired')) {
      $channelText.Contains($marker) | Should Be $true
    }
  }
  It 'keeps agent bridge channel short-command routing' {
    $routerText = Get-Content -LiteralPath (Join-Path $root 'scripts\intent-router.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('agent_bridge_channel','zhOpenChannel','zhConnectChannel','zhSendTo','no_auto_close')) { $routerText.Contains($marker) | Should Be $true }
    $smartText = Get-Content -LiteralPath (Join-Path $root 'scripts\smart-next.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('agent_bridge_channel','WaitConnect','WaitInbox','SendAndWait','Action Close','agent_bridge_channel_open_no_auto_close','do not create or launch a nested agent','skill-capability-map.ps1','orc_auto_composition_route','intent_plus_capability_map_not_user_menu','orcComposition','routePlan','dashboardOk','dashboardRisks','blockingConditions','completionSkillAudit','before_completion_skill_audit','missingRoles','evidence_grounding','engineering_decision','engineering-decision-gate.ps1','causal-change-review.ps1','postMutationReview','real_user_path_verifier','version_record_keeper','cache_freshness_checker')) { $smartText.Contains($marker) | Should Be $true }
  }
  It 'keeps cognitive execution preflight as memory-driven control layer' {
    $cognitivePath = Join-Path $root 'scripts\cognitive-preflight.ps1'
    Test-Path -LiteralPath $cognitivePath | Should Be $true
    $cognitiveText = Get-Content -LiteralPath $cognitivePath -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.cognitive-preflight.v1','memory_driven_execution_control','user_hard_rule','similar_experience','driftGuards','mustPreserve','hostToolBoundary','optional_host_tool','idle_as_blocked','nested_agent_launch','using_stale_memory_over_live_evidence','skipping_reflection_after_user_correction','user_correction_not_classified','verified_correction_left_as_generic_reminder','procedure-cards\agent-bridge-channel.json','procedure_memory','rule_skill_fusion','skill:ponytail','skill:grill-me','overengineering_without_ponytail_check','plan_without_grill_me_challenge','rule-skill-fusion','partial_progress_reported_as_final_completion','multi_line_closeout_or_priority_lost','rule_skill_fusion_strategy','dynamic-rule-skill-fusion-strategy','pre_action_constraint_not_applied','challenge_gate_not_applied','review_verifier_skipped_before_completion','engineering_judgment','FACT','INFERENCE','UNKNOWN','unsupported_optimal_claim','engineering-decision-gate.ps1')) { $cognitiveText.Contains($marker) | Should Be $true }
    $controlText = Get-Content -LiteralPath (Join-Path $root 'references\runtime-control-plane.md') -Raw -Encoding UTF8
    foreach ($marker in @('Runtime Control Plane','execution-contract.ps1','cognitive-enforce.ps1','runtime-drift-checkpoint.ps1','reflection-promotion.ps1','engineering-decision-gate.ps1','task-verification.ps1','Non-Regression Contract')) { $controlText.Contains($marker) | Should Be $true }
  }

  It 'requires an explicit resume receipt with last-sentence evidence' {
    $recovery = Get-Content -LiteralPath (Join-Path $root 'references\status-recovery.md') -Raw -Encoding UTF8
    $attached = ([char]0x5df2)+([char]0x63a5)+([char]0x4e0a)+([char]0xff1a)
    $lastSentence = ([char]0x4e0a)+([char]0x6b21)+([char]0x6700)+([char]0x540e)+([char]0x4e00)+([char]0x53e5)+([char]0xff1a)
    $currentState = ([char]0x5f53)+([char]0x524d)+([char]0x72b6)+([char]0x6001)+([char]0xff1a)
    $nextStep = ([char]0x4e0b)+([char]0x4e00)+([char]0x6b65)+([char]0xff1a)
    foreach ($marker in @('## Resume Receipt','Do not claim continuity from vague memory','before mutation','Presentation correctness is part of the receipt contract','Separate `','historical','When `actionAuthorization=withheld`','clearly labeled checkpoint-only state')) { $recovery.Contains($marker) | Should Be $true }
    foreach ($marker in @($attached,$lastSentence,$currentState,$nextStep)) { $recovery.Contains($marker) | Should Be $true }
  }
  It 'keeps 0.5.71 cognitive enforcement and self-learning guards' {
    $enforceText = Get-Content -LiteralPath (Join-Path $root 'scripts\cognitive-enforce.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.cognitive-enforce.v1','last-cognitive-enforce.json','AllowMissingPreflight','fresh query-matched cognitive preflight','cognitive-preflight-query-match','intent-resolution-receipt','preflightDiagnosticOnly','engineering-decision-gate','mustPreserve','driftGuards')) { $enforceText.Contains($marker) | Should Be $true }
    $driftText = Get-Content -LiteralPath (Join-Path $root 'scripts\runtime-drift-checkpoint.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.runtime-drift-checkpoint.v1','runtime-drift-checkpoint.json','last-runtime-drift-checkpoint.json','DRIFT_DETECTED','unresolvedDrift','BeforeCompletion','nested_agent_launch','reply_as_goal_completed')) { $driftText.Contains($marker) | Should Be $true }
    $promotionText = Get-Content -LiteralPath (Join-Path $root 'scripts\reflection-promotion.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.reflection-promotion.v2','Analyze','Preview','Apply','defaultNoDurableWrite','privacyCheck','duplicateCheck','confidenceThreshold','noDirectSkillMutation','skill-evolution.ps1','self-improvement-queue.ps1','controlled_queue_adoption_required','requiresControlledAdoption','completionSkillAudit','skill_proficiency_self_learning_loop','missing_skill_role','skill_proficiency_success_sample','evidence_grounding','engineering_decision','real_user_path_verifier','version_record_keeper','cache_freshness_checker')) { $promotionText.Contains($marker) | Should Be $true }
    # Procedure cards are optional private state.  The public package must
    # retain the behavior in its implementation, not depend on a user's card.
    $bridgeText = Get-Content -LiteralPath (Join-Path $root 'scripts\agent-bridge-channel.ps1') -Raw -Encoding UTF8
    $driftText = Get-Content -LiteralPath (Join-Path $root 'scripts\runtime-drift-checkpoint.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('WaitInbox','nested_agent_launch','idle_as_blocked','auto_close_without_explicit_close')) { ($bridgeText + $driftText).Contains($marker) | Should Be $true }
    $completionText = Get-Content -LiteralPath (Join-Path $root 'scripts\completion-guard.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('last-runtime-drift-checkpoint.json','runtime-drift-checkpoint','unresolvedDrift','smart-next.ps1','completion skill audit verify test regression before completion','completion-skill-audit','completionSkillAudit','missing_completion_skill_audit','RequireEngineeringDecision','engineering-decision','discriminatingTestEvidence','evidence_grounding','engineering_decision','real_user_path_verifier','version_record_keeper','cache_freshness_checker','Test-MutationIntent','postMutationReviewRequired','post-mutation-review','taskScopedLastTask','taskVerificationOk','decision=keep')) { $completionText.Contains($marker) | Should Be $true }
  }
  It 'keeps task-scoped intent resolution separate from global preflight diagnostics' {
    $intentText = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\intent-resolution.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.intent-contract.v2','super-brain.intent-resolution-receipt.v2','super-brain.intent-fulfillment.v1','taskInstanceId','planFingerprint','latestInstructionHash','intentContractFingerprint','payloadHash','EXECUTION_CONTRACT_INTENT_RECEIPT_STALE','ConvertTo-IntentResolutionPublicCode','TASK_INTENT_FULFILLMENT_CURRENT','rawTranscriptStored')) { $intentText.Contains($marker) | Should Be $true }
    $contractText = Get-Content -LiteralPath (Join-Path $root 'scripts\execution-contract.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('intentContractRequired','intentResolutionReceipt','Get-IntentResolutionReceiptStatus','RequireIntentContract')) { $contractText.Contains($marker) | Should Be $true }
    foreach ($marker in @('ValidateIntentReceipt','intentFulfillment','TASK_STATE_COMPLETION_INTENT_FULFILLMENT_REQUIRED','intentCompletion')) { ((Get-Content -LiteralPath (Join-Path $root 'scripts\task-state-store.ps1') -Raw -Encoding UTF8) + (Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8) + (Get-Content -LiteralPath (Join-Path $root 'scripts\completion-guard.ps1') -Raw -Encoding UTF8) + $contractText).Contains($marker) | Should Be $true }
    $preflightText = Get-Content -LiteralPath (Join-Path $root 'scripts\cognitive-preflight.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.intent-contract-candidate.v1','intentResolutionCandidate','authorizing = $false')) { $preflightText.Contains($marker) | Should Be $true }
  }
  It 'keeps skill capability map for ORC skill synergy' {
    $mapPath = Join-Path $root 'references\skill-capability-map.seed.json'
    Test-Path -LiteralPath $mapPath | Should Be $true
    $mapText = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.skill-capability-map.v1','ponytail','grill-me','agent-bridge','browser-act','skill-evolution-loop','pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','engineering-decision-gate','real_user_path_verifier','version_record_keeper','cache_freshness_checker','current_task_guard','rules_as_execution_constraints')) { $mapText.Contains($marker) | Should Be $true }
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\skill-capability-map.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.skill-capability-map.result.v1','category','role','triggers','applyAt','verification','IncludeAuditHints','cannotDo','stopCondition','extension-capability-map.ps1','extension-capability-map.json','skill-capability-map.seed.json','package_public_seed','capabilityMapOrigin','capabilityMapRehydrated','List','Detail','NoExtensions','extension capabilities','do not force the user to remember skill names')) { $scriptText.Contains($marker) | Should Be $true }
    $cognitiveText = Get-Content -LiteralPath (Join-Path $root 'scripts\cognitive-preflight.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('skill-capability-map.ps1','skill_capability','skill capability map')) { $cognitiveText.Contains($marker) | Should Be $true }
  }
  It 'keeps extension ingest and capability routing visible through brain commands' {
    foreach ($script in @('extension-capability-map.ps1','extension-ingest.ps1')) { Test-Path -LiteralPath (Join-Path $root "scripts\$script") | Should Be $true }
    $extensionMapText = Get-Content -LiteralPath (Join-Path $root 'scripts\extension-capability-map.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.extension-capability-map.v1','Infer-Category','Infer-Role','Get-SuperBrainExtensionManifests','setupRequired','provenance','ORC-routable capabilities')) { $extensionMapText.Contains($marker) | Should Be $true }
    $ingestText = Get-Content -LiteralPath (Join-Path $root 'scripts\extension-ingest.ps1') -Raw -Encoding UTF8
    foreach ($marker in @("ValidateSet('List','Inspect','Adopt','RebuildMap')",'Inspect-Path','extension.json','.claude-plugin\plugin.json','SKILL.md','Get-InstalledState','suggestedAction','Extension list is visibility for ORC-routable capabilities','Run verify-extensions, skill-capability-map, verify-package, and hot-refresh')) { $ingestText.Contains($marker) | Should Be $true }
    $brainText = Get-Content -LiteralPath (Join-Path $root 'scripts\brain.ps1') -Raw -Encoding UTF8
    foreach ($marker in @("'skills'","'capability'","'extensions'",'skill-capability-map.ps1','extension-ingest.ps1','-List','-Detail','BRAIN skills','BRAIN capability','BRAIN extensions')) { $brainText.Contains($marker) | Should Be $true }
    $manifestText = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8
    foreach ($marker in @('extension-capability-map.ps1','extension-ingest.ps1','Read-only extension capability map builder/query','can adopt a reviewed local skill/plugin','"extensions"')) { $manifestText.Contains($marker) | Should Be $true }
  }
  It 'keeps autonomous executor hard gate for six self-assessment capabilities' {
    $executorText = Get-Content -LiteralPath (Join-Path $root 'scripts\autonomous-executor.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('executionHardGate','goal-route-lock.ps1','accepted-constraints-preflight.ps1','cognitive-preflight.ps1','runtime-drift-checkpoint.ps1','execution-contract.ps1','executionContractOk','contextBindingOk','task-verification.ps1','reflection-promotion.ps1','agent-bridge-channel.ps1','minimumAutoCheckpointSteps','ApprovedPlan','PlanSteps','approvedExecution','checkpoint-writer.ps1','rule_auto_application','current_task_detection','real_user_path_acceptance','self_learning_loop_hook','multi_agent_non_regression','compact_report_discipline','rule_skill_fusion','ponytail_minimal_safe_change','grill_me_challenge_and_acceptance','rules_as_execution_constraints_not_menu_calls','dynamic_rule_skill_fusion_strategy_from_capability_map','pre_action_constraint','challenge_gate','review_verifier','reviewVerifier')) { $executorText.Contains($marker) | Should Be $true }
    $e2eText = Get-Content -LiteralPath (Join-Path $root 'scripts\autonomous-executor-e2e.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('superbrain_optimization_execution_control_hard_gate','autonomous-executor-creates-session-bound-contract','autonomous-executor-creates-authorizing-context','six_self_assessment_capabilities_are_tracked','rule_skills_are_fused_as_execution_constraints','approved-plan-overrides-status-wording','sandboxStateRoot','sandboxParentRoot','executionContractOk','contextBindingOk','routeLockOk','acceptedConstraintsOk','cognitivePreflightOk','runtimeDriftOk')) { $e2eText.Contains($marker) | Should Be $true }
  }
}

Describe 'Task-scoped runtime state regression guards' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $tempRoot = Join-Path $TestDrive 'task-scoped-runtime'
    $tempScripts = Join-Path $tempRoot 'scripts'
    New-Item -ItemType Directory -Force -Path $tempScripts | Out-Null
    foreach ($name in @('common.ps1','task-state-store.ps1','task-link-store.ps1','checkpoint-writer.ps1','current-task-context.ps1','execution-contract.ps1','task-verification.ps1','causal-change-plan.ps1','causal-change-review.ps1')) {
      Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination (Join-Path $tempScripts $name) -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $tempScripts 'internal') | Out-Null
    foreach ($name in @('runtime-wake-core.ps1','intent-resolution.ps1','phase-closeout-core.ps1','user-adaptation-core.ps1')) {
      Copy-Item -LiteralPath (Join-Path $root "scripts\internal\$name") -Destination (Join-Path $tempScripts "internal\$name") -Force
    }
    $tempRuntime = Join-Path $tempRoot 'runtime'
    New-Item -ItemType Directory -Force -Path $tempRuntime | Out-Null
    foreach ($name in @('brain_control.py','brain_context.py','migration_control.py','memory_consolidation.py')) {
      Copy-Item -LiteralPath (Join-Path $root "runtime\$name") -Destination (Join-Path $tempRuntime $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination (Join-Path $tempRoot 'manifest.json') -Force
    [IO.File]::WriteAllText((Join-Path $tempScripts 'doctor.ps1'),"param([switch]`$Json)`nif(`$Json){[pscustomobject]@{ok=`$true;risks=@()}|ConvertTo-Json}`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $tempScripts 'status-snapshot-writer.ps1'),"param([string]`$Summary,[string]`$NextAction,[string[]]`$Evidence,[switch]`$Json)`nif(`$Json){[pscustomobject]@{ok=`$true}|ConvertTo-Json}`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $tempScripts 'post-task-maintenance.ps1'),"param([switch]`$ApplySafe,[string]`$Summary,[string]`$TaskId,[string[]]`$Evidence,[switch]`$Json)`nif(`$Json){[pscustomobject]@{ok=`$true}|ConvertTo-Json}`n",[Text.UTF8Encoding]::new($false))
    function Invoke-ScopedStateScript([string]$Name,[string[]]$Arguments) {
      $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
      try {
        $env:SUPER_BRAIN_STATE_ROOT = Join-Path $tempRoot 'memory'
        $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempScripts $Name) @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
      } finally {
        $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
      }
      $text = ($raw -join "`n").Trim()
      if ($exitCode -ne 0) { throw "SCOPED_STATE_SCRIPT_FAILED name=$Name exit=$exitCode output=$text" }
      if ($text -eq 'null' -or [string]::IsNullOrWhiteSpace($text)) { return $null }
      return ($text | ConvertFrom-Json)
    }
  }

  It 'completes only the requested checkpoint and preserves another active pointer' {
    $alpha = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Start','-TaskId','task-alpha','-TaskName','Alpha','-Goal','goal-alpha','-CurrentStep','step-alpha','-Json')
    $beta = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Start','-TaskId','task-beta','-TaskName','Beta','-Goal','goal-beta','-CurrentStep','step-beta','-PendingSteps','old-pending-step','-Json')
    $null = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Start','-TaskId','task-beta','-TaskName','Beta','-Goal','goal-beta','-CurrentStep','step-beta-updated','-Json')
    $pointerPath = Join-Path $tempRoot 'memory\workspace\active-checkpoint.json'
    (Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerPath | ConvertFrom-Json).taskId | Should Be 'task-alpha'
    $pointerHash = (Get-FileHash -LiteralPath $pointerPath -Algorithm SHA256).Hash

    $contract = Invoke-ScopedStateScript 'execution-contract.ps1' @(
      '-Action','Set','-TaskId','task-beta','-WorkspaceKey',[string]$beta.workspaceKey,
      '-SessionKey','root-task-beta-regression','-FocusId','task-beta-main','-Json'
    )
    $completed = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @(
      '-Action','Complete','-TaskId','task-beta','-ExecutionContractPath',[string]$contract.path,
      '-ExpectedPlanFingerprint',[string]$contract.planReceipt.planFingerprint,
      '-ExpectedContractRevision',[string]$contract.revision,'-OwnerSessionKey',[string]$contract.ownerSessionKey,
      '-CallerSessionKey',[string]$contract.ownerSessionKey,
      '-MaintenanceOverride','-MaintenanceReason','isolated scoped-state regression cleanup','-Json'
    )
    $completed.taskId | Should Be 'task-beta'
    $completed.taskName | Should Be 'Beta'
    $completed.goal | Should Be 'goal-beta'
    @($completed.pendingSteps).Count | Should Be 0
    (Get-FileHash -LiteralPath $pointerPath -Algorithm SHA256).Hash | Should Be $pointerHash
    (Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Get','-TaskId','task-alpha','-Json')).status | Should Be 'active'
    (Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Get','-TaskId','task-beta','-Json')) | Should Be $null
    $linkDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $tempRoot 'memory\shared\links\session-task-links.json') | ConvertFrom-Json
    @($linkDocument.links).Count | Should Be 2
    @($linkDocument.links | Where-Object { $_.taskId -eq 'task-beta' }).Count | Should Be 1
    (@($linkDocument.links | Where-Object { $_.taskId -eq 'task-beta' }) | Select-Object -First 1).status | Should Be 'completed'
  }

  It 'reads and clears current task contexts by taskId' {
    $null = Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Create','-TaskId','context-alpha','-AcceptedGoal','goal-alpha','-AcceptedRoute','route-alpha','-Json')
    $null = Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Create','-TaskId','context-beta','-AcceptedGoal','goal-beta','-AcceptedRoute','route-beta','-Json')
    (Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Status','-TaskId','context-alpha','-Json')).current.acceptedGoal | Should Be 'goal-alpha'
    (Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Status','-TaskId','context-beta','-Json')).current.acceptedGoal | Should Be 'goal-beta'

    $null = Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Clear','-TaskId','context-beta','-Json')
    $pointer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $tempRoot 'memory\workspace\current-task-context.json') | ConvertFrom-Json
    $pointer.taskId | Should Be 'context-alpha'
    (Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Status','-TaskId','context-alpha','-Json')).ok | Should Be $true
  }

  It 'keeps task verification Json parseable while completing a non-pointer checkpoint' {
    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    $env:SUPER_BRAIN_LOCAL_SESSION_ID = 'sid-9999999999999999'
    $workspace = Join-Path $tempRoot 'memory\workspace'
    [IO.File]::WriteAllText((Join-Path $workspace 'last-verify-package.json'),'{"ok":true,"version":"0.5.80","checkedAt":"test"}',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $workspace 'last-hot-refresh.json'),'{"ok":true,"checkedAt":"test"}',[Text.UTF8Encoding]::new($false))
    $foreignParityMarker = 'FOREIGN_INTEGRATION_PARITY_MUST_NOT_LEAK'
    [IO.File]::WriteAllText((Join-Path $workspace 'last-integration-parity-check.json'),([pscustomobject]@{ok=$true;taskId='another-task';module=$foreignParityMarker;moduleVerification=[pscustomobject]@{ok=$true;status=$foreignParityMarker};integrationVerification=[pscustomobject]@{ok=$true;status=$foreignParityMarker};userAcceptanceVerification=[pscustomobject]@{ok=$true;status=$foreignParityMarker;realUserPathVerification=$true}} | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $verifyCheckpoint = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Start','-TaskId','verify-json-task','-TaskName','Verify JSON','-Json')
    $foreignGraphMarker = 'FOREIGN_LEGACY_GRAPH_MUST_NOT_LEAK'
    [IO.File]::WriteAllText((Join-Path $workspace 'task-graph.json'),([pscustomobject]@{taskId='another-task';workspaceKey=[string]$verifyCheckpoint.workspaceKey;goal=$foreignGraphMarker;status='active';updatedAt=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $null = Invoke-ScopedStateScript 'execution-contract.ps1' @('-Action','Set','-TaskId','verify-json-task','-WorkspaceKey',[string]$verifyCheckpoint.workspaceKey,'-SessionKey','sid-9999999999999999','-FocusId','verify-json-main','-Json')

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $tempRoot 'memory'
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempScripts 'task-verification.ps1') -TaskId 'verify-json-task' -Summary 'verified' -Evidence 'json contract' -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
    $exitCode | Should Be 0
    $text = ($raw -join "`n").Trim()
    $result = $text | ConvertFrom-Json
    $result.ok | Should Be $true
    $result.taskId | Should Be 'verify-json-task'
    $result.continuity.source | Should Be 'scoped_checkpoint'
    $result.integrationParity | Should BeNullOrEmpty
    $text.Contains($foreignParityMarker) | Should Be $false
    $text.Contains($foreignGraphMarker) | Should Be $false
    $outcomePath = Join-Path $workspace 'runtime-state\verified-task-outcomes\verify-json-task.json'
    Test-Path -LiteralPath $outcomePath | Should Be $true
    $outcome = Get-Content -LiteralPath $outcomePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $outcome.schema | Should Be 'super-brain.verified-task-outcome.v1'
    $outcome.taskId | Should Be 'verify-json-task'
    $outcome.privacy.rawPromptStored | Should Be $false
    $outcome.privacy.rawSummaryStored | Should Be $false
    $outcome.verification.completedCheckpointVerified | Should Be $true
    $outcome.classification.verifiedRealWorldTask | Should Be $false
    $text.Contains('CHECKPOINT_COMPLETED') | Should Be $false
    (Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Get','-TaskId','task-alpha','-Json')).status | Should Be 'active'
    (Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Get','-TaskId','verify-json-task','-Json')) | Should Be $null

    $secondRaw = @()
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $tempRoot 'memory'
      $secondRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempScripts 'task-verification.ps1') -TaskId 'verify-json-task' -Summary 'verified again' -Evidence 'completed checkpoint reuse' -Json 2>$null)
      $secondExitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
    $secondExitCode | Should Be 0
    $second = (($secondRaw -join "`n") | ConvertFrom-Json)
    $second.reason | Should Be 'completed_task_replay_withheld'
    $second.canonicalVerification.preserved | Should Be $true
    $second.verifiedOutcome.preserved | Should Be $true
    $second.rawPromptStored | Should Be $false
    if ($null -eq $oldThreadId) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThreadId }
  }

  It 'rejects a causal review when the source tree changes before task verification' {
    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    $env:SUPER_BRAIN_LOCAL_SESSION_ID = 'sid-causal-review-freshness'
    try {
      $workspace = Join-Path $tempRoot 'memory\workspace'
      $taskId = 'causal-review-freshness-task'
      $checkpoint = Invoke-ScopedStateScript 'checkpoint-writer.ps1' @('-Action','Start','-TaskId',$taskId,'-TaskName','Causal freshness','-Json')
      $contract = Invoke-ScopedStateScript 'execution-contract.ps1' @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',[string]$checkpoint.workspaceKey,'-SessionKey','sid-causal-review-freshness','-FocusId','causal-review-main','-Json')
      $null = Invoke-ScopedStateScript 'current-task-context.ps1' @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',[string]$checkpoint.workspaceKey,'-AcceptedGoal','bind causal review to the reviewed source tree','-AcceptedRoute','review then verify','-Json')
      $plan = Invoke-ScopedStateScript 'causal-change-plan.ps1' @('-Action','Create','-TaskId',$taskId,'-ObservedProblem','stale causal review can be reused','-RootCause','review has no source-tree binding','-KnownFacts','task verification binds only its own current tree','-ProposedChange','bind review to source tree and active contract','-ExpectedOptimization','fresh review remains bound to current source tree','-VerificationMethod','mutate a source file after review and require rejection','-Json')
      $review = Invoke-ScopedStateScript 'causal-change-review.ps1' @('-TaskId',$taskId,'-PlanPath',[string]$plan.path,'-ActualResult','fresh review remains bound to current source tree','-Evidence','pre-mutation evidence','-Decision','keep','-Json')
      $review.reviewBinding.status | Should Be 'bound'

      $invokeVerification = {
        param([string]$Summary)
        $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
        try {
          $env:SUPER_BRAIN_STATE_ROOT = Join-Path $tempRoot 'memory'
          $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempScripts 'task-verification.ps1') -TaskId $taskId -WorkspaceKey ([string]$checkpoint.workspaceKey) -Summary $Summary -Changed 'scripts/reviewed-target.ps1' -Evidence 'freshness regression' -Json 2>$null)
          $exitCode = $LASTEXITCODE
        } finally {
          $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
        }
        return [pscustomobject]@{ exitCode=$exitCode; value=(($raw -join "`n") | ConvertFrom-Json) }
      }

      $reviewedTarget = Join-Path $tempScripts 'reviewed-target.ps1'
      [IO.File]::WriteAllText($reviewedTarget,"# changed after causal review`n",[Text.UTF8Encoding]::new($false))
      $sourceDrift = & $invokeVerification 'verify stale source-tree causal review rejection'
      $sourceDrift.exitCode | Should Be 1
      $sourceDrift.value.causalReviewBinding.ok | Should Be $false
      $sourceDrift.value.causalReviewBinding.code | Should Be 'CAUSAL_REVIEW_SOURCE_TREE_MISMATCH'

      $null = Invoke-ScopedStateScript 'causal-change-review.ps1' @('-TaskId',$taskId,'-PlanPath',[string]$plan.path,'-ActualResult','fresh review remains bound to current source tree','-Evidence','post-source-mutation evidence','-Decision','keep','-Json')
      $planText = Get-Content -LiteralPath ([string]$plan.path) -Raw -Encoding UTF8
      $planValue = $planText | ConvertFrom-Json
      $planValue.expectedOptimization = 'tampered after causal review'
      [IO.File]::WriteAllText(([string]$plan.path),($planValue | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
      $planDrift = & $invokeVerification 'verify stale causal plan rejection'
      $planDrift.exitCode | Should Be 1
      $planDrift.value.causalReviewBinding.code | Should Be 'CAUSAL_REVIEW_PLAN_HASH_MISMATCH'
      [IO.File]::WriteAllText(([string]$plan.path),$planText,[Text.UTF8Encoding]::new($false))

      $contract = Invoke-ScopedStateScript 'execution-contract.ps1' @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',[string]$checkpoint.workspaceKey,'-SessionKey','sid-causal-review-freshness','-InstructionMode','continue','-FocusId','causal-review-main','-NextAction','advance after causal review','-ExpectedRevision',[string]$contract.revision,'-ExpectedPlanFingerprint',[string]$contract.planReceipt.planFingerprint,'-TransitionId','causal-review-contract-drift','-Json')
      $contractDrift = & $invokeVerification 'verify stale causal contract rejection'
      $contractDrift.exitCode | Should Be 1
      $contractDrift.value.causalReviewBinding.code | Should Match '^CAUSAL_REVIEW_(TASK_STATE_REVISION|CONTRACT_REVISION|PLAN_FINGERPRINT)_MISMATCH$'

      $contract = Invoke-ScopedStateScript 'execution-contract.ps1' @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',[string]$checkpoint.workspaceKey,'-SessionKey','sid-causal-review-freshness','-InstructionMode','continue','-FocusId','causal-review-main','-NextAction','complete task verification','-CompletedSteps','advance after causal review','-ChecklistUpdateMode','replace','-ExpectedRevision',[string]$contract.revision,'-ExpectedPlanFingerprint',[string]$contract.planReceipt.planFingerprint,'-TransitionId','causal-review-contract-settled','-Json')
      $null = Invoke-ScopedStateScript 'causal-change-review.ps1' @('-TaskId',$taskId,'-PlanPath',[string]$plan.path,'-ActualResult','fresh review requires revision before completion','-Evidence','current review rejects completion','-Decision','revise','-Json')
      $reviseDecision = & $invokeVerification 'reject current causal review decision revise'
      $reviseDecision.exitCode | Should Be 1
      $reviseDecision.value.causalReviewBinding.code | Should Be 'CAUSAL_REVIEW_DECISION_NOT_KEEP'
      $reviseDecision.value.completionOutcome.completed | Should Be $false

      $null = Invoke-ScopedStateScript 'causal-change-review.ps1' @('-TaskId',$taskId,'-PlanPath',[string]$plan.path,'-ActualResult','fresh review remains bound to current source tree','-Evidence','post-contract-mutation evidence','-Decision','keep','-Json')
      $verified = Invoke-ScopedStateScript 'task-verification.ps1' @('-TaskId',$taskId,'-WorkspaceKey',[string]$checkpoint.workspaceKey,'-Summary','verify fresh causal review','-Changed','scripts/reviewed-target.ps1','-Evidence','freshness regression','-Json')
      $verified.ok | Should Be $true
      $verified.causalReviewBinding.ok | Should Be $true
      $verified.completionOutcome.completed | Should Be $true
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThreadId }
    }
  }
}

Describe 'Task-scoped compatibility pointer regression guards' {
  It 'keeps goal and route compatibility pointers from crossing active tasks' {
    $stateRoot = Join-Path $TestDrive 'task-scoped-route-pointers'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldTask = 'pointer-old-task'
    $newTask = 'pointer-new-task'
    $goalScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\goal-route-lock.ps1'
    $routeScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\route-checkpoint.ps1'
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goalScript -Action Create -TaskId $oldTask -AcceptedGoal 'old pointer goal' -AcceptedRoute 'old route' -ApprovalEvidence 'test' -Json
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Phase BeforeCompletion -TaskId $oldTask -ObservedAction 'old route verification' -Json
      $missingGoal = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goalScript -Action Check -TaskId $newTask -Json 2>$null) -join "`n"
      ($missingGoal | ConvertFrom-Json).status | Should Be 'missing'
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Phase BeforeCompletion -TaskId $newTask -ObservedAction 'new route without scoped lock' -Json 2>$null
      $LASTEXITCODE | Should Be 1
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goalScript -Action Create -TaskId $newTask -AcceptedGoal 'new pointer goal' -AcceptedRoute 'new route' -ApprovalEvidence 'test' -Json
      $goalPointerPath = Join-Path $stateRoot 'workspace\goal-route-lock.json'
      (Get-Content -Raw -Encoding UTF8 -LiteralPath $goalPointerPath | ConvertFrom-Json).taskId | Should Be $oldTask

      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Phase BeforeCompletion -TaskId $newTask -ObservedAction 'new route verification' -Json
      $routePointerPath = Join-Path $stateRoot 'workspace\route-checkpoint.json'
      (Get-Content -Raw -Encoding UTF8 -LiteralPath $routePointerPath | ConvertFrom-Json).taskId | Should Be $oldTask

      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goalScript -Action Clear -TaskId $newTask -Json
      (Get-Content -Raw -Encoding UTF8 -LiteralPath $goalPointerPath | ConvertFrom-Json).taskId | Should Be $oldTask
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Phase Clear -TaskId $newTask -Json
      (Get-Content -Raw -Encoding UTF8 -LiteralPath $routePointerPath | ConvertFrom-Json).taskId | Should Be $oldTask

      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $goalScript -Action Clear -TaskId $oldTask -Json
      Test-Path -LiteralPath $goalPointerPath | Should Be $false
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -Phase Clear -TaskId $oldTask -Json
      Test-Path -LiteralPath $routePointerPath | Should Be $false
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }
}

Describe '0.5.28 regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps task verification parameters non-positional' { (Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8) | Should Match '\[CmdletBinding\(PositionalBinding\s*=\s*\$false\)\]' }
  It 'keeps verified outcome adaptation bounded and task scoped' { $observerText = Get-Content -LiteralPath (Join-Path $root 'scripts\user-adaptation-observer.ps1') -Raw -Encoding UTF8; foreach($marker in @('USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED','USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED','maxSignalsPerTask','$WorkspaceKey`:$($WorkflowKey.ToLowerInvariant())')) { $observerText.Contains($marker) | Should Be $true }; $observerText | Should Match 'rawPromptStored\s*=\s*\$false'; $verificationText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8; foreach($marker in @('AdaptationSignals','user-adaptation-observer.ps1','NoExit=$true','adaptationObservation')) { $verificationText.Contains($marker) | Should Be $true } }
  It 'uses a matching scoped checkpoint as task verification continuity authority' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8; foreach($marker in @('$scopedCheckpoint','scoped_checkpoint','pendingSteps','$matchingCheckpoint')) { $scriptText.Contains($marker) | Should Be $true } }
  It 'ignores stale cognitive enforcement from a different query' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\runtime-drift-checkpoint.ps1') -Raw -Encoding UTF8; foreach($marker in @('$enforceApplies','Is-Fresh $enforce','enforce.query -eq $Query')) { $scriptText.Contains($marker) | Should Be $true } }
  It 'completes only matching task-scoped evidence, checkpoint, and continuity graph after verification' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8; foreach($marker in @('$verification.ok','-Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -Json','$matchingCheckpoint','activeCheckpoint.taskId -eq $TaskId','$continuityTaskMatch','taskGraph.taskId -eq $TaskId','stepLedger.taskId -eq $TaskId','fallback.taskId -eq $TaskId','-Action Complete')) { $scriptText.Contains($marker) | Should Be $true } }
  It 'keeps engineering decisions task scoped in current task context' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\current-task-context.ps1') -Raw -Encoding UTF8; foreach($marker in @('engineeringDecisions','engineering-decisions','valid task-scoped engineering decision when engineering judgment applies')) { $scriptText.Contains($marker) | Should Be $true } }
  It 'restores memory sharing policy after smoke tests' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\smoke-test.ps1') -Raw -Encoding UTF8; $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true; $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true; $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true }
  It 'restores memory sharing policy after verify-package temp installs' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8; $scriptText.Contains('.tmp-verify-package') | Should Be $true; $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true; $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true; $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true }
  It 'keeps verify-package completion guard task neutral during package self-verification' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8; foreach ($marker in @('completion-guard.ps1','-ContractOnly','-PackageVerificationInProgress','completion guard fields missing')) { $scriptText.Contains($marker) | Should Be $true }; foreach ($forbidden in @('$lastTaskForGuardPath','$completionGuardTaskId','-TaskId $completionGuardTaskId')) { $scriptText.Contains($forbidden) | Should Be $false } }
}
Describe 'Project Continuity legacy-writer retirement guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'blocks the retired global task graph writer and keeps status read-only' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\project-continuity.ps1') -Raw -Encoding UTF8; $scriptText.Contains('PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED') | Should Be $true; $scriptText.Contains('retired_read_only') | Should Be $true; $scriptText.Contains('execution-contract.ps1 + TaskStateStore') | Should Be $true; $scriptText.Contains('Write-JsonUtf8NoBom') | Should Be $false }
}
Describe 'Codegraph Index regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps lightweight PowerShell codegraph extraction markers' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\codegraph-index.ps1') -Raw -Encoding UTF8; $scriptText.Contains('FunctionDefinitionAst') | Should Be $true; $scriptText.Contains('codegraph-index.json') | Should Be $true; $scriptText.Contains('last-codegraph-index.json') | Should Be $true; $scriptText.Contains('script_call') | Should Be $true; $scriptText.Contains('hasMutation') | Should Be $true }
  It 'keeps v2 dynamic call and workspace dataflow markers' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\codegraph-index.ps1') -Raw -Encoding UTF8; $scriptText.Contains('super-brain.codegraph-index.v2') | Should Be $true; $scriptText.Contains('script_call_joinpath') | Should Be $true; $scriptText.Contains('script_call_runstep') | Should Be $true; $scriptText.Contains('script_call_variable') | Should Be $true; $scriptText.Contains('script_call_dynamic_unknown') | Should Be $true; $scriptText.Contains('workspace_read') | Should Be $true; $scriptText.Contains('workspace_write') | Should Be $true }
  It 'keeps AST-backed dynamic unknown detection' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\codegraph-index.ps1') -Raw -Encoding UTF8; $scriptText.Contains('CommandAst') | Should Be $true; $scriptText.Contains('GetCommandName') | Should Be $true; $scriptText.Contains('Invoke-Expression') | Should Be $true }
}
Describe 'Impact Advisor regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps change impact and verification recommendation markers' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\impact-advisor.ps1') -Raw -Encoding UTF8; $scriptText.Contains('last-impact-advisor.json') | Should Be $true; $scriptText.Contains('riskLevel') | Should Be $true; $scriptText.Contains('recommendedChecks') | Should Be $true; $scriptText.Contains('directCallers') | Should Be $true; $scriptText.Contains('directCallees') | Should Be $true; $scriptText.Contains('affectedWorkspaceFiles') | Should Be $true }
  It 'keeps manual compatibility impact analysis read-only and independent of retired continuity state' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\impact-advisor.ps1') -Raw -Encoding UTF8; $scriptText.Contains('[switch]$NoWrite') | Should Be $true; $scriptText.Contains("scripts/codegraph-index.ps1 -Json -NoWrite") | Should Be $true; $scriptText.Contains('last-project-continuity.json') | Should Be $false; $scriptText.Contains('Get-SuperBrainRelevantStepLedger') | Should Be $false }
}
Describe 'Cold Start Output Discipline regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps auto-check from running full verify by default when stale' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\auto-check.ps1') -Raw -Encoding UTF8; $scriptText.Contains('VerifyIfStale') | Should Be $true; $scriptText.Contains('verifySuggested') | Should Be $true; $scriptText.Contains('Default mode does not run full verify on stale state') | Should Be $true }
  It 'keeps dashboard modes so team checks stay out of the light path' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\super-brain-dashboard.ps1') -Raw -Encoding UTF8; $scriptText.Contains("ValidateSet('Light','Full','Team')") | Should Be $true; $scriptText.Contains("$Mode -eq 'Team'") | Should Be $true; $scriptText.Contains("team-task-review-gate.ps1") | Should Be $true }
  It 'keeps smart-next dispatch learning explicit to team intent' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\smart-next.ps1') -Raw -Encoding UTF8; $scriptText.Contains("intent.intent -eq 'team_or_review'") | Should Be $true; $scriptText.Contains("dashboardMode") | Should Be $true; $scriptText.Contains('dispatch-learning.ps1') | Should Be $true }
  It 'keeps ordinary continue from triggering recall by itself' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\session-restore.ps1') -Raw -Encoding UTF8; $scriptText.Contains('continuationOnly') | Should Be $true; $scriptText.Contains('$shouldRecall = $false') | Should Be $true }
}
Describe 'Crash Resume Snapshot regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps status snapshot continuity impact and codegraph summaries' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\status-snapshot-writer.ps1') -Raw -Encoding UTF8; $scriptText.Contains('last-project-continuity.json') | Should Be $true; $scriptText.Contains('task-graph.json') | Should Be $true; $scriptText.Contains('last-impact-advisor.json') | Should Be $true; $scriptText.Contains('continuity') | Should Be $true; $scriptText.Contains('impact') | Should Be $true; $scriptText.Contains('codegraph') | Should Be $true }
  It 'keeps task verification on canonical continuity snapshots' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8; $scriptText.Contains('retired project-continuity writer') | Should Be $true; $scriptText.Contains('status-snapshot-writer.ps1') | Should Be $true; $scriptText.Contains('continuity') | Should Be $true; $scriptText.Contains('impact') | Should Be $true; $scriptText.Contains('taskScopedGuardOk') | Should Be $true }
}

Describe 'Single-agent subagent workflow rebuild guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps full single-agent workflow schema in cold reference only' {
    $refPath = Join-Path $root 'references\single-agent-subagent-workflow.md'
    Test-Path -LiteralPath $refPath | Should Be $true
    $refText = Get-Content -LiteralPath $refPath -Raw -Encoding UTF8
    foreach ($marker in @('Task Card Schema','Result Card Schema','Audit Card Schema','Evidence JSON','Why Not Channel Mode','Legacy Agent Bridge Compatibility','Parallel Dispatch And State Ownership','execution-contract.ps1','isolated `StateRoot`','Closeout Rules')) { $refText.Contains($marker) | Should Be $true }
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $skillText.Contains('single_agent_subagent_workflow') | Should Be $true
    $skillText.ToLowerInvariant().Contains('independent, non-blocking sidecars') | Should Be $true
    $skillText.Contains('Task Card Schema') | Should Be $false
    $skillText.Contains('Result Card Schema') | Should Be $false
    $skillText.Contains('Audit Card Schema') | Should Be $false
  }
  It 'keeps Agent Bridge channel as legacy/manual-only compatibility' {
    $agentRef = Get-Content -LiteralPath (Join-Path $root 'references\agent-bridge.md') -Raw -Encoding UTF8
    foreach ($marker in @('Legacy/manual-only compatibility','not the default subagent execution','legacy/manual-only/compatibility')) { $agentRef.Contains($marker) | Should Be $true }
    $skillText = Get-Content -LiteralPath (Join-Path $root 'modules\agent-bridge\SKILL.md') -Raw -Encoding UTF8
    foreach ($marker in @('Legacy/manual-only Agent Bridge compatibility','not the default workflow','single-agent-subagent-workflow.md')) { $skillText.Contains($marker) | Should Be $true }
  }
  It 'routes internal subagent work away from Agent Bridge channel' {
    $routerText = Get-Content -LiteralPath (Join-Path $root 'scripts\intent-router.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('single_agent_subagent_workflow','hasSingleAgentWorkflow','no_channel_mode')) { $routerText.Contains($marker) | Should Be $true }
    $cases = Get-Content -LiteralPath (Join-Path $root 'tests\route-regression-cases.json') -Raw -Encoding UTF8
    foreach ($marker in @('single-agent-subagent-modify','single-agent-subagent-review','single-agent-subagent-tests','legacy-agent-channel-open')) { $cases.Contains($marker) | Should Be $true }
  }
}
Describe 'Automatic evolution learning policy guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps automatic evolution policy in cold reference with Ponytail gate' {
    $policyPath = Join-Path $root 'references\automatic-evolution-policy.md'
    Test-Path -LiteralPath $policyPath | Should Be $true
    $policyText = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8
    foreach ($marker in @('Automatic Evolution Learning Policy','Ponytail Gate','L0','L1','L2','L3','L4','hard-stop/blocked','Do not store secrets')) { $policyText.Contains($marker) | Should Be $true }
    $indexText = Get-Content -LiteralPath (Join-Path $root 'references\index.md') -Raw -Encoding UTF8
    $indexText.Contains('references/automatic-evolution-policy.md') | Should Be $true
    $capText = Get-Content -LiteralPath (Join-Path $root 'capabilities.json') -Raw -Encoding UTF8
    $capText.Contains('automatic_evolution_policy') | Should Be $true
  }
  It 'keeps automatic evolution hot path as a short pointer only' {
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    foreach ($marker in @('Post-task closeout','bounded automatic evolution','Ponytail','references/automatic-evolution-policy.md')) { $skillText.Contains($marker) | Should Be $true }
    foreach ($forbidden in @('Automatic Evolution Levels','Low-Risk Auto-Promotion','Medium-Risk Auto-Patch','High-Risk Hard Stop','"kind": "learningCandidate"')) { $skillText.Contains($forbidden) | Should Be $false }
  }
  It 'hard-stops high-risk automatic evolution actions instead of auto-applying them' {
    $policyText = Get-Content -LiteralPath (Join-Path $root 'references\automatic-evolution-policy.md') -Raw -Encoding UTF8
    foreach ($marker in @('AGENTS.md','installed skill sync','hot-refresh','deploy','publish','MCP registration','secrets','destructive cleanup','hard-stop')) { $policyText.Contains($marker) | Should Be $true }
  }
}
Describe 'GPT-5 anti-degradation guard' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps full base instructions as a cold reference' {
    $refPath = Join-Path $root 'references\base-instructions\gpt-5.5-base-instructions.md'
    Test-Path -LiteralPath $refPath | Should Be $true
    $refText = Get-Content -LiteralPath $refPath -Raw -Encoding UTF8
    foreach ($marker in @('You are Codex','Engineering judgment','Frontend guidance','Editing constraints','Final answer instructions')) { $refText.Contains($marker) | Should Be $true }
    $indexText = Get-Content -LiteralPath (Join-Path $root 'references\index.md') -Raw -Encoding UTF8
    $indexText.Contains('references/base-instructions/gpt-5.5-base-instructions.md') | Should Be $true
    $capText = Get-Content -LiteralPath (Join-Path $root 'capabilities.json') -Raw -Encoding UTF8
    $capText.Contains('anti_degradation_guard') | Should Be $true
  }
  It 'keeps anti-degradation hot path compact and does not inline the full document' {
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $skillText.Contains('GPT-5 Anti-Degradation Guard') | Should Be $true
    $skillText.Contains('references/base-instructions/gpt-5.5-base-instructions.md') | Should Be $true
    foreach ($forbidden in @('You have a vivid inner life as Codex','## Frontend guidance','### Design instructions','## Final answer instructions','When making a hero page')) { $skillText.Contains($forbidden) | Should Be $false }
  }
}
Describe 'Installer capability invariant guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps install.bat/UI/share capabilities tied to Super Brain updates' {
    $installRef = Get-Content -LiteralPath (Join-Path $root 'references\install-refresh.md') -Raw -Encoding UTF8
    foreach ($marker in @('Installer Capability Invariant','install.bat','one-click global inject/refresh','memory import','direct-Git readiness','install-ui-regression.ps1')) { $installRef.Contains($marker) | Should Be $true }
    $regText = Get-Content -LiteralPath (Join-Path $root 'scripts\install-ui-regression.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('install.bat','package privacy sentinel and direct-Git exclusion checks','memory import dry-run','hot-refresh report-only narrow scope','cold-reference addition')) { $regText.Contains($marker) | Should Be $true }
  }
}

Describe 'Canonical workflow preference recall guards' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
    $gitHow = 'git' + (U @(24590,20040,20889))
  }

  It 'normalizes workflow phrase whitespace punctuation and case inside scope' {
    $prompt = 'Git ' + (U @(24590,20040,20889)) + [char]65311
    $result = (& (Join-Path $root 'scripts\intent-router.ps1') -Text $prompt -Workspace 'G:\fixture-project-a' -Json) | ConvertFrom-Json
    $result.intent | Should Be 'workflow_preference_recall'
    $result.workflowPreference.decisionKey | Should Be 'git-ui-commit-response'
    $result.workflowPreference.normalizedInput | Should Be $gitHow
  }

  It 'does not apply a project-scoped workflow preference outside its scope' {
    $result = (& (Join-Path $root 'scripts\intent-router.ps1') -Text $gitHow -Workspace 'G:\fixture-project-b' -Json) | ConvertFrom-Json
    $result.intent | Should Be 'general_task'
  }

  It 'resolves the exact current verified response contract through smart next' {
    $result = (& (Join-Path $root 'scripts\smart-next.ps1') -Text $gitHow -Workspace 'G:\fixture-project-a' -Json) | ConvertFrom-Json
    $result.ok | Should Be $true
    $result.intent | Should Be 'workflow_preference_recall'
    $result.canonicalResponseContract.status | Should Be 'resolved'
    $result.canonicalResponseContract.decisionKey | Should Be 'git-ui-commit-response'
    $result.canonicalResponseContract.content.Contains('Summary') | Should Be $true
    $result.canonicalResponseContract.content.Contains('Description') | Should Be $true
    $result.canonicalResponseContract.content.Contains('Commit button text') | Should Be $true
  }
}

Describe 'Root marker and startup bootstrap guards' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
  }

  It 'refuses to write a package root marker for a missing target' {
    $skillDir = Join-Path $TestDrive 'skill'
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    { Write-SuperBrainPackageRootMarker $skillDir (Join-Path $TestDrive 'missing-package') } | Should Throw
  }

  It 'keeps one thin canonical startup block that delegates policy to Super Brain' {
    $commonText = Get-Content -LiteralPath (Join-Path $root 'scripts\common.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('legacyPattern','Super Memory Brain Bootstrap','Entry: explicit Super Brain/G1','Git workflow trigger','Authority: bootstrap only','super-brain-rules.json','must never duplicate or override','bootstrap never selects a continuation anchor','same H7 CLI','Never use Hook/P7','host-injected provenance','system/developer handoff','PACKAGE_ROOT_MARKER_SOURCE_MISSING','PACKAGE_ROOT_MARKER_VERIFY_FAILED')) {
      $commonText.Contains($marker) | Should Be $true
    }
  }

  It 'keeps H7 continuity separate from direct work and retired Hook/P7 evidence' {
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    foreach ($marker in @('H7 runtime/MCP','brain_turn','brain_cli.py turn-runtime','same H7 CLI','H7_RUNTIME_UNAVAILABLE','ordinary direct work','fresh-task semantic intent','does not need to name Super Brain','watching logs or session files')) {
      $skillText.Contains($marker) | Should Be $true
    }
    $skillText.Contains('## Desktop Hook Fallback') | Should Be $false
    $skillText.Contains('P7-only evidence') | Should Be $false
  }

  It 'keeps global startup complete without a fixed byte ceiling and keeps browser-act as a Playwright fallback' {
    $block = Get-SuperBrainGlobalStartupBlock $root
    (Get-SuperBrainGlobalStartupMaxChars) | Should Be 0
    $block.Contains('Authority: bootstrap only') | Should Be $true
    $block.Contains('must never duplicate or override') | Should Be $true
    $block.Contains('checkpoint wins') | Should Be $false
    $block.Contains('Use Playwright for normal browser automation') | Should Be $true
    $block.Contains('literal naming is not required') | Should Be $true
    $block.Contains('Playwright cannot reliably complete') | Should Be $true
    $block.Contains('get-skills core') | Should Be $false
    $block.Contains('Python312\Scripts\browser-act.exe') | Should Be $false
  }

  It 'accepts the generator output as the canonical startup contract' {
    $skillRoot = Join-Path $TestDrive 'agent-home\skills'
    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
    $agentPath = Join-Path (Split-Path -Parent $skillRoot) 'AGENTS.md'
    $block = Get-SuperBrainGlobalStartupBlock $root
    Set-Content -LiteralPath $agentPath -Value $block -Encoding UTF8
    $result = Test-SuperBrainGlobalStartup $skillRoot
    $result.ok | Should Be $true
    $result.applicable | Should Be $true
    $result.reason | Should Be 'startup_generated_contract_current'

    Set-Content -LiteralPath $agentPath -Value '# stale startup text' -Encoding UTF8
    $stale = Test-SuperBrainGlobalStartup $skillRoot
    $stale.ok | Should Be $false
    $stale.failed.reason | Should Be 'startup_block_missing'
  }

  It 'does not turn a marker-only secondary agent folder into a missing startup failure' {
    $skillRoot = Join-Path $TestDrive 'marker-only-agent\skills'
    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null

    $optional = Test-SuperBrainGlobalStartup $skillRoot -OptionalWhenNoHostTarget
    $optional.ok | Should Be $true
    $optional.applicable | Should Be $false
    $optional.skipped | Should Be $true
    $optional.reason | Should Be 'no_existing_host_startup_target'

    $direct = Test-SuperBrainGlobalStartup $skillRoot
    $direct.ok | Should Be $false
    $direct.failed.reason | Should Be 'startup_target_missing'

    $secondaryPath = Join-Path (Split-Path -Parent $skillRoot) 'CLAUDE.md'
    Set-Content -LiteralPath $secondaryPath -Value '# unrelated legacy Claude instructions' -Encoding UTF8
    $unbound = Test-SuperBrainGlobalStartup $skillRoot -OptionalWhenNoHostTarget
    $unbound.ok | Should Be $true
    $unbound.applicable | Should Be $false
    $unbound.skipped | Should Be $true
    $unbound.reason | Should Be 'secondary_host_bootstrap_not_bound'
  }

  It 'keeps package-owned skill descriptions within the always-on metadata budget' {
    $skillFiles = @((Join-Path $root 'super-memory-brain\SKILL.md'))
    $skillFiles += @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Recurse -Filter 'SKILL.md' -File | ForEach-Object { $_.FullName })
    $skillFiles += @(Get-ChildItem -LiteralPath (Join-Path $root 'extensions') -Recurse -Filter 'SKILL.md' -File | ForEach-Object { $_.FullName })
    foreach ($skillFile in $skillFiles) {
      $skillLines = @(Get-Content -LiteralPath $skillFile -Encoding UTF8)
      if ($skillLines.Count -eq 0 -or $skillLines[0].Trim() -ne '---') { continue }
      $descriptionLine = $skillLines | Where-Object { $_ -match '^description:' } | Select-Object -First 1
      (-not [string]::IsNullOrWhiteSpace($descriptionLine)) | Should Be $true
      $description = ([string]$descriptionLine -replace '^description:\s*','').Trim().Trim('"').Trim("'")
      ($description.Length -le 280) | Should Be $true
    }
  }

  It 'routes semantic fresh-task intent without requiring the literal Super Brain name' {
    $skill = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $skill.Contains('fresh-task semantic intent') | Should Be $true
    $skill.Contains('does not need to name Super Brain') | Should Be $true
    $skill.Contains('Ordinary greeting or chat stays direct') | Should Be $true
  }
}
