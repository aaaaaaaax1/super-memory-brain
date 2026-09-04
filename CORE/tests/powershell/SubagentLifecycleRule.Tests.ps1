$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Subagent lifecycle auto-close rule' {
  BeforeAll {
    $skillText = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8
    $workflowText = Get-Content -LiteralPath (Join-Path $root 'references\single-agent-subagent-workflow.md') -Raw -Encoding UTF8
    . (Join-Path $root 'scripts\common.ps1')
    $commonText = Get-Content -LiteralPath (Join-Path $root 'scripts\common.ps1') -Raw -Encoding UTF8
    $taskVerificationText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8
    $maintenancePolicy = Get-Content -LiteralPath (Join-Path $root 'maintenance-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $startupBlock = Get-SuperBrainGlobalStartupBlock $root
  }

  It 'covers completion, failure, interruption, and explicit stop terminal events' {
    foreach ($terminal in @('task_complete','turn_aborted','interrupted','task_failed','no_longer_needed')) {
      $skillText.Contains($terminal) | Should Be $true
      $workflowText.Contains($terminal) | Should Be $true
    }
    foreach ($marker in @('explicitly authorized next action')) {
      $skillText.Contains($marker) | Should Be $true
      $workflowText.Contains($marker) | Should Be $true
    }
    $skillText.Contains('close the child runtime only') | Should Be $true
    $skillText.Contains('never archive, delete, or hide') | Should Be $true
    $workflowText.Contains('close/interrupt the child runtime immediately') | Should Be $true
    $workflowText.Contains('child-only closeout, not') | Should Be $true
    $skillText.Contains('close/archive the child immediately') | Should Be $false
    $workflowText.Contains('close/archive the child immediately') | Should Be $false
    $skillText.Contains('returns its result') | Should Be $true
    $skillText.Contains('silently orphan the child') | Should Be $true
    $workflowText.Contains('returned result') | Should Be $true
    $workflowText.Contains('silently orphaned') | Should Be $true
  }

  It 'denies implicit destructive mutation and protects non-child identities' {
    foreach ($marker in @('exact action', 'complete target set', 'user-visible impact', 'Wildcard expansion', 'stale approval')) {
      $skillText.Contains($marker) | Should Be $true
      $workflowText.Contains($marker) | Should Be $true
    }
    foreach ($vague in @('`continue`', '`maintenance`', '`cleanup`')) {
      $skillText.Contains($vague) | Should Be $true
      $workflowText.Contains($vague) | Should Be $true
    }
    $skillText.Contains('Only a verified internal executor/reviewer/verifier agent child') | Should Be $true
    $workflowText.Contains('Only a verified internal executor/reviewer/verifier agent child') | Should Be $true
    $skillText.Contains('Parent, user-owned, MCP, and unknown identities') | Should Be $true
    $workflowText.Contains('Parent, user-owned, MCP, and unknown identities') | Should Be $true
  }

  It 'requires closeout before parent resume and keeps the short router bounded' {
    $workflowText.IndexOf('close/interrupt the child runtime immediately') -lt $workflowText.IndexOf('ResumeParent') | Should Be $true
    # Destructive-mutation policy is authoritative in the versioned registry
    # and the full Super Brain adapter/workflow, not duplicated in the tiny
    # generated bootstrap.  Keep the bootstrap bounded while asserting that
    # its generator remains the single source for the H7 retirement boundary.
    $commonText.Contains('function Get-SuperBrainGlobalStartupBlock') | Should Be $true
    $startupBlock.Contains('H7_HOST_TRANSPORT_RETIRED') | Should Be $true
    $startupBlock.Contains('Guard: delete/archive/unpin/clean/overwrite deny unless exact action/target/impact user-approved or approved-plan-listed') | Should Be $false
    ($startupBlock.Length -lt 1900) | Should Be $true
  }

  It 'keeps post-task maintenance report-only by default' {
    $taskVerificationText.Contains("post-task-maintenance.ps1') -ApplySafe") | Should Be $false
    $taskVerificationText.Contains("post-task-maintenance.ps1') -Summary") | Should Be $true
    $maintenancePolicy.mode | Should Be 'plan_only'
    $maintenancePolicy.mutationAuthorization.default | Should Be 'deny'
    (@($maintenancePolicy.mutationAuthorization.vagueInstructionsNeverAuthorize) -contains 'continue') | Should Be $true
    (@($maintenancePolicy.mutationAuthorization.failClosedOn) -contains 'unknown_identity') | Should Be $true
  }
}
