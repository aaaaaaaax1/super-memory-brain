$root = Split-Path -Parent (Split-Path $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'

function Invoke-LocalRebindContractJson([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{
    exitCode = $exitCode
    value = if ($text) { $text | ConvertFrom-Json } else { $null }
  }
}

Describe 'Execution-contract local rebind route' {
  It 'allows successor lookup to reach the local control plane without the retiring contract' {
    $stateRoot = Join-Path $TestDrive 'successor-without-contract'
    $taskId = 'task-successor-without-contract'
    $workspaceKey = 'ws-successor-without-contract-424242'
    $sessionKey = 'sid-successor-without-contract-424242'
    $recoveryRef = 'rr-' + ('a' * 32)
    $oldSession = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    try {
      $env:SUPER_BRAIN_LOCAL_SESSION_ID = $sessionKey

      # There is intentionally no execution-contract file in this fixture.
      # A validly-shaped but unknown recoveryRef must therefore reach
      # BrainControl and return its lineage error, rather than being rejected
      # by the old contract lookup gate.
      $consume = Invoke-LocalRebindContractJson @(
        '-Action', 'ConsumeLocalRebind',
        '-TaskId', $taskId,
        '-WorkspaceKey', $workspaceKey,
        '-SessionKey', $sessionKey,
        '-LocalRebindRef', $recoveryRef,
        '-StateRoot', $stateRoot,
        '-Json'
      )
      $consume.exitCode | Should Be 1
      $consume.value.code | Should Be 'BRAIN_CONTROL_LOCAL_REBIND_NOT_FOUND'

      $finalize = Invoke-LocalRebindContractJson @(
        '-Action', 'FinalizeLocalRebind',
        '-TaskId', $taskId,
        '-WorkspaceKey', $workspaceKey,
        '-SessionKey', $sessionKey,
        '-LocalRebindRef', $recoveryRef,
        '-StateRoot', $stateRoot,
        '-Json'
      )
      $finalize.exitCode | Should Be 1
      $finalize.value.code | Should Be 'BRAIN_CONTROL_LOCAL_REBIND_NOT_FOUND'

      # Query-by-command is the metadata-only repair seam for a lost ref and
      # must have the same no-contract behavior.  It must never return a
      # capability or fall back to a legacy contract selector.
      $query = Invoke-LocalRebindContractJson @(
        '-Action', 'QueryLocalRebind',
        '-TaskId', $taskId,
        '-WorkspaceKey', $workspaceKey,
        '-SessionKey', $sessionKey,
        '-LocalRebindTargetCommandId', 'missing-issue-command',
        '-StateRoot', $stateRoot,
        '-Json'
      )
      $query.exitCode | Should Be 1
      $query.value.code | Should Be 'BRAIN_CONTROL_LOCAL_REBIND_NOT_FOUND'

      $revoke = Invoke-LocalRebindContractJson @(
        '-Action', 'RevokeLocalRebind',
        '-TaskId', $taskId,
        '-WorkspaceKey', $workspaceKey,
        '-SessionKey', $sessionKey,
        '-LocalRebindRef', $recoveryRef,
        '-StateRoot', $stateRoot,
        '-Json'
      )
      $revoke.exitCode | Should Be 1
      $revoke.value.code | Should Be 'BRAIN_CONTROL_LOCAL_REBIND_NOT_FOUND'

      # Issue remains contract-gated: the retiring owner must snapshot a
      # complete live contract before a recovery capability can be minted.
      $issue = Invoke-LocalRebindContractJson @(
        '-Action', 'IssueLocalRebind',
        '-TaskId', $taskId,
        '-WorkspaceKey', $workspaceKey,
        '-SessionKey', $sessionKey,
        '-StateRoot', $stateRoot,
        '-Json'
      )
      $issue.exitCode | Should Be 1
      $issue.value.code | Should Be 'EXECUTION_CONTRACT_NOT_FOUND'
    } finally {
      if ($null -eq $oldSession) {
        Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue
      } else {
        $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldSession
      }
    }
  }
}
