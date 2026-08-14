$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$restoreScript = Join-Path $root 'scripts\session-restore.ps1'

function Write-FreshnessTestJson([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-FreshnessRestore([string]$StateRoot,[string]$TaskId,[string]$WorkspaceKey,[string]$SessionId) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restoreScript -Query 'continue' -TaskId $TaskId -WorkspaceKey $WorkspaceKey -SessionId $SessionId -Json 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=if($text){$text|ConvertFrom-Json}else{$null} }
}

Describe 'Recovery checkpoint freshness guard' {
  It 'withholds explicit version-mismatched and expired checkpoint actions' {
    $version = (Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    foreach ($case in @(
      [pscustomobject]@{ name='version'; version='0.0.0-old'; timestamp=(Get-Date).ToString('o'); reason='package_version_mismatch'; marker='STALE_VERSION_ACTION_MUST_NOT_LEAK'; stepMarker='STALE_VERSION_STEP_MUST_NOT_LEAK' },
      [pscustomobject]@{ name='expired'; version=$version; timestamp=(Get-Date).AddDays(-8).ToString('o'); reason='expired'; marker='EXPIRED_ACTION_MUST_NOT_LEAK'; stepMarker='EXPIRED_STEP_MUST_NOT_LEAK' }
    )) {
      $state = Join-Path $TestDrive ('freshness-' + $case.name)
      $workspaceKey = 'ws-freshness-' + $case.name + '-aaaaaaaa'
      $taskId = 'task-freshness-' + $case.name
      $checkpointPath = Join-Path $state ('workspace\runtime-state\checkpoints\active\' + $taskId + '.json')
      Write-FreshnessTestJson $checkpointPath ([pscustomobject]@{
        status='active'; taskId=$taskId; workspaceKey=$workspaceKey; version=$case.version
        timestamp=$case.timestamp; currentPhase='old'; currentStep=$case.stepMarker; nextAction=$case.marker
      })

      $result = Invoke-FreshnessRestore $state $taskId $workspaceKey ('sid-freshness-' + $case.name)
      $result.exitCode | Should Be 0
      $result.value.checkpointSelection.state | Should Be 'stale'
      $result.value.checkpointSelection.staleReason | Should Be $case.reason
      $result.value.checkpointSelection.stalePhase | Should Be 'old'
      $result.value.activeCheckpoint | Should BeNullOrEmpty
      $result.text.Contains($case.marker) | Should Be $false
      $result.text.Contains($case.stepMarker) | Should Be $false
    }
  }

  It 'keeps a current, same-version checkpoint available as locator evidence' {
    $state = Join-Path $TestDrive 'freshness-current'
    $workspaceKey = 'ws-freshness-current-aaaaaaaa'
    $taskId = 'task-freshness-current'
    $version = (Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    $checkpointPath = Join-Path $state ('workspace\runtime-state\checkpoints\active\' + $taskId + '.json')
    Write-FreshnessTestJson $checkpointPath ([pscustomobject]@{
      status='active'; taskId=$taskId; workspaceKey=$workspaceKey; version=$version
      timestamp=(Get-Date).ToString('o'); currentPhase='current'; currentStep='current'; nextAction='current locator action'
    })

    $result = Invoke-FreshnessRestore $state $taskId $workspaceKey 'sid-freshness-current'
    $result.exitCode | Should Be 0
    $result.value.checkpointSelection.state | Should Be 'relevant'
    $result.value.activeCheckpoint.nextAction | Should Be 'current locator action'
  }
}
