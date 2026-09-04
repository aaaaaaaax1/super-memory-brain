Describe 'Super Memory Brain package manifest' {
  It 'parses manifest and includes core automation scripts' {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    [string]::IsNullOrWhiteSpace($manifest.version) | Should Be $false
    @($manifest.scripts) -contains 'ci.ps1' | Should Be $true
    @($manifest.scripts) -contains 'common.ps1' | Should Be $true
    @($manifest.scripts) -contains 'engineering-decision-gate.ps1' | Should Be $true
    @($manifest.scripts) -contains 'technology-decision.ps1' | Should Be $true
    @($manifest.scripts) -contains 'codex-user-prompt-hook.ps1' | Should Be $true
    @($manifest.scripts) -contains 'install-codex-user-prompt-hook.ps1' | Should Be $true
    @($manifest.scripts) -contains 'install-codex-stop-hook.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\codex-hook-host-state.ps1' | Should Be $true
    @($manifest.legacyCompatibilityFiles) -contains 'runtime\codex_prompt_hook_dispatcher.py' | Should Be $true
    @($manifest.legacyCompatibilityFiles) -contains 'runtime\codex_stop_hook.py' | Should Be $true
    @($manifest.legacyCompatibilityFiles) -contains 'runtime\codex_stop_hook_dispatcher.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\turn_close_dispatcher.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\work_dag.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\run_observability.py' | Should Be $true
    @($manifest.scripts) -contains 'script-call-contract.ps1' | Should Be $true
    @($manifest.scripts) -contains 'routing-kernel.ps1' | Should Be $true
    @($manifest.scripts) -contains 'task-link-store.ps1' | Should Be $true
    @($manifest.scripts) -contains 'task-state-store.ps1' | Should Be $true
    @($manifest.scripts) -contains 'execution-contract.ps1' | Should Be $true
    @($manifest.scripts) -contains 'work-dag.ps1' | Should Be $true
    @($manifest.scripts) -contains 'intelligence-eval.ps1' | Should Be $true
    @($manifest.scripts) -contains 'phase6-memory-eval.ps1' | Should Be $true
    @($manifest.scripts) -contains 'evaluation-learning-bridge.ps1' | Should Be $true
    @($manifest.scripts) -contains 'autonomy-evidence-ledger.ps1' | Should Be $true
    @($manifest.scripts) -contains 'objective-benchmark.ps1' | Should Be $true
    @($manifest.scripts) -contains 'user-adaptation.ps1' | Should Be $true
    @($manifest.scripts) -contains 'user-adaptation-observer.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\user-adaptation-core.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\hook-runtime-common.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\runtime-wake-core.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\install-transaction.ps1' | Should Be $true
    @($manifest.scripts) -contains 'install-runtime.ps1' | Should Be $true
    @($manifest.scripts) -contains 'runtime-eval.ps1' | Should Be $true
    @($manifest.scripts) -contains 'mcp-process-audit.ps1' | Should Be $true
    @($manifest.scripts) -contains 'runtime-status.ps1' | Should Be $true
    @($manifest.scripts) -contains 'absorbed-capability-route.ps1' | Should Be $true
    @($manifest.modules) -contains 'skill-pool-router' | Should Be $true
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'engineering-decision-gate.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'technology-decision.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'codex-user-prompt-hook.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'install-codex-stop-hook.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'routing-kernel.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'task-link-store.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'task-state-store.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'execution-contract.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'work-dag.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'intelligence-eval.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'evaluation-learning-bridge.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'autonomy-evidence-ledger.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'objective-benchmark.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'user-adaptation.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'user-adaptation-observer.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'internal\user-adaptation-core.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'internal\hook-runtime-common.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'internal\runtime-wake-core.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'internal\install-transaction.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'install-runtime.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'runtime-eval.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'mcp-process-audit.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'runtime-status.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'absorbed-capability-route.ps1' }).tier | Should Be 'T0'
    @($manifest.scriptGroups.startup) -contains 'retire-codex-super-brain-hooks.ps1' | Should Be $true
    @($manifest.scriptGroups.compatibility) -contains 'codex-user-prompt-hook.ps1' | Should Be $true
    @($manifest.scriptGroups.compatibility) -contains 'install-codex-stop-hook.ps1' | Should Be $true
    @($manifest.scriptGroups.memory) -contains 'user-adaptation.ps1' | Should Be $true
    @($manifest.scriptGroups.memory) -contains 'user-adaptation-observer.ps1' | Should Be $true
    @($manifest.runtimeFiles) -contains 'sandglass_vault.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\brain_mcp.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\core_rule_registry.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\turn_intent.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\failure_loop_guard.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\local_scope_adapter.py' | Should Be $true
    $manifest.coreRuleRegistry.path | Should Be 'super-brain-rules.json'
    $manifest.coreRuleRegistry.schema | Should Be 'super-brain.core-rule-registry.v1'
    $manifest.coreRuleRegistry.hashAlgorithm | Should Be 'sha256(canonical-json-without-payloadHash)'
    @($manifest.coreRuleRegistry.requiredRuleIds) -contains 'SB-H7-ACTIVATION-001' | Should Be $true
    @($manifest.coreRuleRegistry.requiredRuleIds) -contains 'SB-PROGRESS-TRUTH-001' | Should Be $true
    @($manifest.coreRuleRegistry.requiredRuleIds) -contains 'SB-RUNTIME-ADAPTER-INDEPENDENCE-001' | Should Be $true
    @($manifest.legacyCompatibilityFiles) -contains 'runtime\codex_prompt_hook.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\codex_stop_hook.py' | Should Be $false
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\turn_close_dispatcher.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\work_dag.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\run_observability.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\work-dag.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\turn_intent.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\failure_loop_guard.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\routing-kernel.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\internal\hook-runtime-common.ps1' | Should Be $false
    @($manifest.legacyCompatibilityFiles) -contains 'scripts\internal\hook-runtime-common.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\internal\runtime-wake-core.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'runtime\codex_prompt_hook.py' | Should Be $false
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\why-plan.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\absorbed-capability-route.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\autonomy-evidence-ledger.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'intelligence-policy.json' | Should Be $true
  }
}
