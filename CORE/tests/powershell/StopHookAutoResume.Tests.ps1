$Root = Split-Path -Parent (Split-Path $PSScriptRoot)
$Python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

Describe 'Retired P7 Stop compatibility' {
  It 'returns an empty response for a stale stop-hook invocation' {
    $raw = @('{"session_id":"sid-ffffffffffffffff","prompt":"RAW_STOP_PROMPT_SENTINEL"}' | & $Python -X utf8 -B (Join-Path $Root 'runtime\codex_stop_hook_dispatcher.py'))
    $LASTEXITCODE | Should Be 0
    ($raw -join "`n") | Should Be '{}'
    ($raw -join "`n") | Should Not Match 'RAW_STOP_PROMPT_SENTINEL'
  }

  It 'reports the H7 replacement explicitly when asked for compatibility metadata' {
    $raw = @(& $Python -X utf8 -B (Join-Path $Root 'runtime\codex_stop_hook_dispatcher.py') --describe)
    $LASTEXITCODE | Should Be 0
    $value = (($raw -join "`n") | ConvertFrom-Json)
    $value.ok | Should Be $true
    $value.state | Should Be 'retired'
    $value.replacement | Should Be 'H7 brain_turn'
  }

  It 'keeps the legacy stop-handler shim fail-open and side-effect free' {
    $stateRoot = Join-Path $TestDrive 'retired-stop-state'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @('{"prompt":"RAW_STOP_PROMPT_SENTINEL"}' | & $Python -X utf8 -B (Join-Path $Root 'runtime\codex_stop_hook.py'))
      $LASTEXITCODE | Should Be 0
      ($raw -join "`n") | Should Be '{}'
      (Test-Path -LiteralPath $stateRoot) | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }
}
