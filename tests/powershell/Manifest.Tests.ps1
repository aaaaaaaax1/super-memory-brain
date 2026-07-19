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
    @($manifest.scripts) -contains 'script-call-contract.ps1' | Should Be $true
    @($manifest.scripts) -contains 'routing-kernel.ps1' | Should Be $true
    @($manifest.scripts) -contains 'task-link-store.ps1' | Should Be $true
    @($manifest.scripts) -contains 'task-state-store.ps1' | Should Be $true
    @($manifest.scripts) -contains 'execution-contract.ps1' | Should Be $true
    @($manifest.scripts) -contains 'intelligence-eval.ps1' | Should Be $true
    @($manifest.scripts) -contains 'autonomy-evidence-ledger.ps1' | Should Be $true
    @($manifest.scripts) -contains 'objective-benchmark.ps1' | Should Be $true
    @($manifest.scripts) -contains 'user-adaptation.ps1' | Should Be $true
    @($manifest.scripts) -contains 'user-adaptation-observer.ps1' | Should Be $true
    @($manifest.scripts) -contains 'internal\user-adaptation-core.ps1' | Should Be $true
    @($manifest.scripts) -contains 'install-runtime.ps1' | Should Be $true
    @($manifest.scripts) -contains 'runtime-eval.ps1' | Should Be $true
    @($manifest.scripts) -contains 'runtime-status.ps1' | Should Be $true
    @($manifest.modules) -contains 'skill-pool-router' | Should Be $true
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'engineering-decision-gate.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'technology-decision.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'codex-user-prompt-hook.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'routing-kernel.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'task-link-store.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'task-state-store.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'execution-contract.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'intelligence-eval.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'autonomy-evidence-ledger.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'objective-benchmark.ps1' }).tier | Should Be 'T1'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'user-adaptation.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'user-adaptation-observer.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'internal\user-adaptation-core.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'install-runtime.ps1' }).tier | Should Be 'T2'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'runtime-eval.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'runtime-status.ps1' }).tier | Should Be 'T0'
    @($manifest.scriptGroups.startup) -contains 'codex-user-prompt-hook.ps1' | Should Be $true
    @($manifest.scriptGroups.memory) -contains 'user-adaptation.ps1' | Should Be $true
    @($manifest.scriptGroups.memory) -contains 'user-adaptation-observer.ps1' | Should Be $true
    @($manifest.runtimeFiles) -contains 'sandglass_vault.py' | Should Be $true
    @($manifest.nativeRuntimeFiles) -contains 'runtime\brain_mcp.py' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\routing-kernel.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\why-plan.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'scripts\autonomy-evidence-ledger.ps1' | Should Be $true
    @($manifest.intelligenceBehaviorFiles) -contains 'intelligence-policy.json' | Should Be $true
  }
}
