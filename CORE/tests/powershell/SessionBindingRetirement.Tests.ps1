$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bindingScript = Join-Path $root 'scripts\session-binding.ps1'
$recallScript = Join-Path $root 'scripts\recall-search.ps1'

function Invoke-RetiredBinding([string]$StateRoot,[string[]]$Arguments) {
  $oldState = $env:SUPER_BRAIN_STATE_ROOT
  $oldRuntime = $env:SUPER_BRAIN_RUNTIME_DISABLE
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:SUPER_BRAIN_RUNTIME_DISABLE = '1'
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bindingScript @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    if ($null -eq $oldRuntime) { Remove-Item Env:\SUPER_BRAIN_RUNTIME_DISABLE -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_RUNTIME_DISABLE = $oldRuntime }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Retired global session binding compatibility surface' {
  It 'never creates, refreshes, expires, or clears the legacy global binding' {
    $stateRoot = Join-Path $TestDrive 'retired-binding'
    $workspace = Join-Path $stateRoot 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $bindingPath = Join-Path $workspace 'session-binding.json'
    $legacy = [pscustomobject]@{
      ok=$true; bindingId='legacy-binding'; sessionId='legacy-session'; taskId='legacy-task'
      workspaceKey='ws-aaaaaaaaaaaaaaaaaaaaaaaa'; agent='zcode'; platform='zcode'
      status='active'; query='legacy-only-needle-6b'; currentStep='stale step'; nextAction='stale action'
      packageVersion='legacy'; memoryRoot='legacy'; expiresAt=(Get-Date).AddHours(1).ToString('o')
      evidenceCards=@([pscustomobject]@{claim='legacy-only-needle-6b'})
    }
    [IO.File]::WriteAllText($bindingPath,($legacy|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash

    foreach ($action in @('Get','Bind','Refresh','Expire','Clear')) {
      $arguments = @('-Action',$action,'-SessionId','new-session','-TaskId','new-task','-Query','new query','-Json')
      $result = Invoke-RetiredBinding $stateRoot $arguments
      $result.exitCode | Should Be 0
      $result.value.ok | Should Be $true
      $result.value.status | Should Be 'retired_legacy_present'
      $result.value.authorizationState | Should Be 'non_authorizing'
      $result.value.writePerformed | Should Be $false
      $result.value.binding | Should BeNullOrEmpty
      $result.value.legacyBinding.taskId | Should Be 'legacy-task'
      (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash | Should Be $beforeHash
    }
  }

  It 'does not inject a legacy binding into recall results' {
    $stateRoot = Join-Path $TestDrive 'retired-recall'
    $workspace = Join-Path $stateRoot 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $bindingPath = Join-Path $workspace 'session-binding.json'
    $legacy = [pscustomobject]@{
      bindingId='legacy-recall'; sessionId='legacy-session'; taskId='legacy-task'
      workspaceKey='ws-bbbbbbbbbbbbbbbbbbbbbbbb'; status='active'; query='legacy-only-needle-6b'
      nextAction='legacy-only-needle-6b'; expiresAt=(Get-Date).AddHours(1).ToString('o')
      packageVersion='legacy'; memoryRoot='legacy'; evidenceCards=@([pscustomobject]@{claim='legacy-only-needle-6b'})
    }
    [IO.File]::WriteAllText($bindingPath,($legacy|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    $oldRuntime = $env:SUPER_BRAIN_RUNTIME_DISABLE
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_RUNTIME_DISABLE = '1'
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recallScript -Query 'legacy-only-needle-6b' -MemoryMode force -Layer session -Legacy -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
      if ($null -eq $oldRuntime) { Remove-Item Env:\SUPER_BRAIN_RUNTIME_DISABLE -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_RUNTIME_DISABLE = $oldRuntime }
    }
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $exitCode | Should Be 0
    $text | Should Not Match 'session-binding\.json|temporary_session_binding|legacy-only-needle-6b'
    $text | Should Not Match 'Traceback|ModuleNotFoundError'
  }
}
