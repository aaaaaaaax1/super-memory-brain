Describe 'Execution-state resume regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps product-manager intent gate and task-status semantics in the entry skill' {
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $skillText.Contains('Product-manager intent gate') | Should Be $true
    $skillText.Contains('Current-session task status rule') | Should Be $true
    $skillText.Contains('Execution-state checkpoint rule') | Should Be $true
    $skillText.Contains('OCR/log/code noise isolation rule') | Should Be $true
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
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    foreach ($marker in @('Cross-agent/session task identity index rule','compact task status table','sessionName','agentId')) {
      $skillText.Contains($marker) | Should Be $true
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
    foreach ($marker in @('agent_bridge_channel','WaitConnect','WaitInbox','SendAndWait','Action Close','agent_bridge_channel_open_no_auto_close','do not create or launch a nested agent','skill-capability-map.ps1','orc_auto_composition_route','intent_plus_capability_map_not_user_menu','orcComposition','routePlan','dashboardOk','dashboardRisks','blockingConditions','completionSkillAudit','before_completion_skill_audit','missingRoles','evidence_grounding','engineering_decision','engineering-decision-gate.ps1','real_user_path_verifier','version_record_keeper','cache_freshness_checker')) { $smartText.Contains($marker) | Should Be $true }
  }
  It 'keeps cognitive execution preflight as memory-driven control layer' {
    $cognitivePath = Join-Path $root 'scripts\cognitive-preflight.ps1'
    Test-Path -LiteralPath $cognitivePath | Should Be $true
    $cognitiveText = Get-Content -LiteralPath $cognitivePath -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.cognitive-preflight.v1','memory_driven_execution_control','user_hard_rule','similar_experience','driftGuards','mustPreserve','noTodoWriteInZCode','idle_as_blocked','nested_agent_launch','using_stale_memory_over_live_evidence','skipping_reflection_after_user_correction','procedure-cards\agent-bridge-channel.json','procedure_memory','rule_skill_fusion','skill:ponytail','skill:grill-me','overengineering_without_ponytail_check','plan_without_grill_me_challenge','rule-skill-fusion','partial_progress_reported_as_final_completion','rule_skill_fusion_strategy','dynamic-rule-skill-fusion-strategy','pre_action_constraint_not_applied','challenge_gate_not_applied','review_verifier_skipped_before_completion','engineering_judgment','FACT','INFERENCE','UNKNOWN','unsupported_optimal_claim','engineering-decision-gate.ps1')) { $cognitiveText.Contains($marker) | Should Be $true }
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    foreach ($marker in @('Cognitive execution loop rule','cognitive-preflight.ps1','cognitive-enforce.ps1','runtime-drift-checkpoint.ps1','reflection-promotion.ps1','semantic memory','episodic memory','procedural memory','working memory','DRIFT_DETECTED','Self-learning loop rule','Unfinished-task progress-only rule','Engineering judgment rule','engineering-decision-gate.ps1','FACT / INFERENCE / UNKNOWN')) { $skillText.Contains($marker) | Should Be $true }
  }
  It 'keeps 0.5.71 cognitive enforcement and self-learning guards' {
    $enforceText = Get-Content -LiteralPath (Join-Path $root 'scripts\cognitive-enforce.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.cognitive-enforce.v1','last-cognitive-enforce.json','AllowMissingPreflight','fresh query-matched cognitive preflight','cognitive-preflight-query-match','engineering-decision-gate','mustPreserve','driftGuards')) { $enforceText.Contains($marker) | Should Be $true }
    $driftText = Get-Content -LiteralPath (Join-Path $root 'scripts\runtime-drift-checkpoint.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.runtime-drift-checkpoint.v1','runtime-drift-checkpoint.json','last-runtime-drift-checkpoint.json','DRIFT_DETECTED','unresolvedDrift','BeforeCompletion','nested_agent_launch','reply_as_goal_completed')) { $driftText.Contains($marker) | Should Be $true }
    $promotionText = Get-Content -LiteralPath (Join-Path $root 'scripts\reflection-promotion.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.reflection-promotion.v1','Analyze','Preview','Apply','defaultNoDurableWrite','privacyCheck','duplicateCheck','confidenceThreshold','noDirectSkillMutation','skill-evolution.ps1','learn-memory.ps1','completionSkillAudit','skill_proficiency_self_learning_loop','missing_skill_role','skill_proficiency_success_sample','evidence_grounding','engineering_decision','real_user_path_verifier','version_record_keeper','cache_freshness_checker')) { $promotionText.Contains($marker) | Should Be $true }
    $cardText = Get-Content -LiteralPath (Join-Path $root 'memory\workspace\procedure-cards\agent-bridge-channel.json') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.procedure-card.v1','nested_agent_launch','idle_as_blocked','auto_close_without_explicit_close','WaitInbox until explicit Close')) { $cardText.Contains($marker) | Should Be $true }
    $completionText = Get-Content -LiteralPath (Join-Path $root 'scripts\completion-guard.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('last-runtime-drift-checkpoint.json','runtime-drift-checkpoint','unresolvedDrift','smart-next.ps1','completion skill audit verify test regression before completion','completion-skill-audit','completionSkillAudit','missing_completion_skill_audit','RequireEngineeringDecision','engineering-decision-gate','discriminatingTestEvidence','evidence_grounding','engineering_decision','real_user_path_verifier','version_record_keeper','cache_freshness_checker')) { $completionText.Contains($marker) | Should Be $true }
  }
  It 'keeps skill capability map for ORC skill synergy' {
    $mapPath = Join-Path $root 'memory\workspace\skill-capability-map.json'
    Test-Path -LiteralPath $mapPath | Should Be $true
    $mapText = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.skill-capability-map.v1','ponytail','grill-me','agent-bridge','browser-act','skill-evolution-loop','pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','engineering-decision-gate','real_user_path_verifier','version_record_keeper','cache_freshness_checker','current_task_guard','rules_as_execution_constraints')) { $mapText.Contains($marker) | Should Be $true }
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\skill-capability-map.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('super-brain.skill-capability-map.result.v1','category','role','triggers','applyAt','verification','IncludeAuditHints','cannotDo','stopCondition','extension-capability-map.ps1','extension-capability-map.json','List','Detail','NoExtensions','extension capabilities','do not force the user to remember skill names')) { $scriptText.Contains($marker) | Should Be $true }
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
    foreach ($marker in @('executionHardGate','goal-route-lock.ps1','accepted-constraints-preflight.ps1','cognitive-preflight.ps1','runtime-drift-checkpoint.ps1','task-verification.ps1','reflection-promotion.ps1','agent-bridge-channel.ps1','rule_auto_application','current_task_detection','real_user_path_acceptance','self_learning_loop_hook','multi_agent_non_regression','compact_report_discipline','rule_skill_fusion','ponytail_minimal_safe_change','grill_me_challenge_and_acceptance','rules_as_execution_constraints_not_menu_calls','dynamic_rule_skill_fusion_strategy_from_capability_map','pre_action_constraint','challenge_gate','review_verifier','reviewVerifier')) { $executorText.Contains($marker) | Should Be $true }
    $e2eText = Get-Content -LiteralPath (Join-Path $root 'scripts\autonomous-executor-e2e.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('superbrain_optimization_execution_control_hard_gate','six_self_assessment_capabilities_are_tracked','rule_skills_are_fused_as_execution_constraints','routeLockOk','acceptedConstraintsOk','cognitivePreflightOk','runtimeDriftOk')) { $e2eText.Contains($marker) | Should Be $true }
  }
}

Describe '0.5.28 regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps task verification parameters non-positional' { (Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8) | Should Match '\[CmdletBinding\(PositionalBinding\s*=\s*\$false\)\]' }
  It 'keeps engineering decisions task scoped in current task context' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\current-task-context.ps1') -Raw -Encoding UTF8; foreach($marker in @('engineeringDecisions','engineering-decisions','valid task-scoped engineering decision when engineering judgment applies')) { $scriptText.Contains($marker) | Should Be $true } }
  It 'restores memory sharing policy after smoke tests' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\smoke-test.ps1') -Raw -Encoding UTF8; $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true; $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true; $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true }
  It 'restores memory sharing policy after verify-package temp installs' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8; $scriptText.Contains('.tmp-verify-package') | Should Be $true; $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true; $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true; $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true }
  It 'keeps verify-package completion guard task scoped' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8; foreach ($marker in @('last-task-verification.json','$completionGuardTaskId','completion-guard.ps1','-TaskId $completionGuardTaskId','completion guard fields missing')) { $scriptText.Contains($marker) | Should Be $true } }
}
Describe 'Project Graph Continuity regression guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps task graph, step ledger, and candidate finding isolation in project-continuity' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\project-continuity.ps1') -Raw -Encoding UTF8; $scriptText.Contains('task-graph.json') | Should Be $true; $scriptText.Contains('agent-findings') | Should Be $true; $scriptText.Contains('SkipStep') | Should Be $true; $scriptText.Contains('AdmitFinding') | Should Be $true; $scriptText.Contains('RejectFinding') | Should Be $true; $scriptText.Contains('candidate-only') | Should Be $true; $scriptText.Contains('Commander admission') | Should Be $true }
  It 'keeps crash-safe task lifecycle actions' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\project-continuity.ps1') -Raw -Encoding UTF8; $scriptText.Contains('CompleteTask') | Should Be $true; $scriptText.Contains('ArchiveTask') | Should Be $true; $scriptText.Contains('ClearTask') | Should Be $true; $scriptText.Contains('last-completed-task-graph.json') | Should Be $true; $scriptText.Contains('task-archive') | Should Be $true }
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
  It 'keeps task verification auto continuity snapshot support' { $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8; $scriptText.Contains('project-continuity.ps1') | Should Be $true; $scriptText.Contains('CompleteTask') | Should Be $true; $scriptText.Contains('status-snapshot-writer.ps1') | Should Be $true; $scriptText.Contains('continuity') | Should Be $true; $scriptText.Contains('impact') | Should Be $true; $scriptText.Contains('taskScopedGuardOk') | Should Be $true }
}

Describe 'Single-agent subagent workflow rebuild guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps full single-agent workflow schema in cold reference only' {
    $refPath = Join-Path $root 'references\single-agent-subagent-workflow.md'
    Test-Path -LiteralPath $refPath | Should Be $true
    $refText = Get-Content -LiteralPath $refPath -Raw -Encoding UTF8
    foreach ($marker in @('Task Card Schema','Result Card Schema','Audit Card Schema','Evidence JSON','Why Not Channel Mode','Legacy Agent Bridge Compatibility','Closeout Rules')) { $refText.Contains($marker) | Should Be $true }
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $skillText.Contains('single_agent_subagent_workflow') | Should Be $true
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
    $skillText.Contains('post-task closeout may run bounded automatic evolution through Ponytail gate') | Should Be $true
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
Describe 'Share package reference inclusion guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps prepare-share copying cold references into public share packages' {
    $prepareText = Get-Content -LiteralPath (Join-Path $root 'scripts\prepare-share.ps1') -Raw -Encoding UTF8
    foreach ($marker in @("'references'", "'extensions'", "'modules'")) { $prepareText.Contains($marker) | Should Be $true }
    $verifyText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-share.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('references\index.md','references\single-agent-subagent-workflow.md','references\automatic-evolution-policy.md','references\base-instructions\gpt-5.5-base-instructions.md')) { $verifyText.Contains($marker) | Should Be $true }
  }
}
Describe 'Installer capability invariant guards' {
  BeforeAll { $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  It 'keeps install.bat/UI/share capabilities tied to Super Brain updates' {
    $installRef = Get-Content -LiteralPath (Join-Path $root 'references\install-refresh.md') -Raw -Encoding UTF8
    foreach ($marker in @('Installer Capability Invariant','install.bat','one-click global inject/refresh','memory import','share package generation','install-ui-regression.ps1')) { $installRef.Contains($marker) | Should Be $true }
    $regText = Get-Content -LiteralPath (Join-Path $root 'scripts\install-ui-regression.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('install.bat','share package verification and privacy shape','memory import dry-run','hot-refresh report-only narrow scope','cold-reference addition')) { $regText.Contains($marker) | Should Be $true }
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
    $result = (& (Join-Path $root 'scripts\intent-router.ps1') -Text $prompt -Workspace 'G:\Atoapi' -Json) | ConvertFrom-Json
    $result.intent | Should Be 'workflow_preference_recall'
    $result.workflowPreference.decisionKey | Should Be 'git-ui-commit-response'
    $result.workflowPreference.normalizedInput | Should Be $gitHow
  }

  It 'does not apply a project-scoped workflow preference outside its scope' {
    $result = (& (Join-Path $root 'scripts\intent-router.ps1') -Text $gitHow -Workspace 'G:\OtherProject' -Json) | ConvertFrom-Json
    $result.intent | Should Be 'general_task'
  }

  It 'resolves the exact current verified response contract through smart next' {
    $result = (& (Join-Path $root 'scripts\smart-next.ps1') -Text $gitHow -Workspace 'G:\Atoapi' -Json) | ConvertFrom-Json
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

  It 'keeps one canonical startup block with workflow and G1 hot guards' {
    $commonText = Get-Content -LiteralPath (Join-Path $root 'scripts\common.ps1') -Raw -Encoding UTF8
    foreach ($marker in @('legacyPattern','Workflow trigger hot index','decision_key=git-ui-commit-response','G1 visibility','PACKAGE_ROOT_MARKER_SOURCE_MISSING','PACKAGE_ROOT_MARKER_VERIFY_FAILED')) {
      $commonText.Contains($marker) | Should Be $true
    }
  }
}
