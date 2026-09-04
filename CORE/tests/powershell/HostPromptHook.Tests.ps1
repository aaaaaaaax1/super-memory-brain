$Root = Split-Path -Parent (Split-Path $PSScriptRoot)
$Python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

Describe 'Retired P7 UserPromptSubmit compatibility' {
  It 'keeps the PowerShell compatibility shim inert' {
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\codex-user-prompt-hook.ps1') -TestPrompt 'RAW_USER_PROMPT_SENTINEL' -TestWorkspace 'C:\foreign' -TestSessionId 'sid-ffffffffffffffff')
    $LASTEXITCODE | Should Be 0
    ($output -join '') | Should Be ''
  }

  It 'returns an empty native prompt envelope without reading or storing input' {
    $stateRoot = Join-Path $TestDrive 'retired-prompt-state'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @('{"prompt":"RAW_USER_PROMPT_SENTINEL"}' | & $Python -X utf8 -B (Join-Path $Root 'runtime\codex_prompt_hook.py'))
      $LASTEXITCODE | Should Be 0
      $value = (($raw -join "`n") | ConvertFrom-Json)
      $value.hookSpecificOutput.hookEventName | Should Be 'UserPromptSubmit'
      $value.hookSpecificOutput.additionalContext | Should Be ''
      ($raw -join "`n") | Should Not Match 'RAW_USER_PROMPT_SENTINEL'
      (Test-Path -LiteralPath $stateRoot) | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'exposes retirement metadata instead of a decision-producing dispatcher' {
    $raw = @(& $Python -X utf8 -B (Join-Path $Root 'runtime\codex_prompt_hook_dispatcher.py') --describe)
    $LASTEXITCODE | Should Be 0
    $value = (($raw -join "`n") | ConvertFrom-Json)
    $value.state | Should Be 'retired'
    $value.replacement | Should Be 'H7 brain_turn'
  }
}
