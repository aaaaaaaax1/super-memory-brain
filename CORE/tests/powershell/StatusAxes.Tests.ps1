Describe 'Super Brain status axes' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $autoCheck = Join-Path $root 'scripts\auto-check.ps1'
  }

  function Invoke-AutoCheckFixture([hashtable]$State,[int]$MaxAgeMinutes = 60) {
    $stateRoot = Join-Path $TestDrive ('status-axes-' + [guid]::NewGuid().ToString('n'))
    $workspace = Join-Path $stateRoot 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $workspace 'super-brain-state.json'),
      ($State | ConvertTo-Json -Depth 8),
      [System.Text.UTF8Encoding]::new($false)
    )
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $text = @(& $autoCheck -MaxAgeMinutes $MaxAgeMinutes -Json 2>&1) -join "`n"
      return $text | ConvertFrom-Json
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }

  It 'keeps a healthy core visible when package verification failed' {
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $result = Invoke-AutoCheckFixture @{
      schema = 'super-brain.state.v2'; ok = $true; legacyOkMeaning = 'core_available'; coreAvailable = $true
      updatedAt = $now; lastVerifyOk = $false
      verification = @{ state = 'failed'; passed = $false; checkedAt = $now; requiredForCore = $false }
    }

    $result.ok | Should Be $false
    $result.okScope | Should Be 'strict_cache_verification'
    $result.coreAvailable | Should Be $true
    $result.cacheReady | Should Be $false
    $result.verification.state | Should Be 'failed'
    $result.staleReason | Should Be 'last_verify_not_ok'
  }

  It 'does not refresh an old successful verification merely by rewriting state' {
    $now = [DateTimeOffset]::UtcNow
    $result = Invoke-AutoCheckFixture @{
      schema = 'super-brain.state.v2'; ok = $true; legacyOkMeaning = 'core_available'; coreAvailable = $true
      updatedAt = $now.ToString('o'); lastVerifyOk = $true
      verification = @{ state = 'passed'; passed = $true; checkedAt = $now.AddMinutes(-61).ToString('o'); requiredForCore = $false }
    } 60

    $result.ok | Should Be $false
    $result.cacheReady | Should Be $false
    $result.staleReason | Should Be 'verify_stale'
  }

  It 'rejects a future verification timestamp from the cache fast path' {
    $now = [DateTimeOffset]::UtcNow
    $result = Invoke-AutoCheckFixture @{
      schema = 'super-brain.state.v2'; ok = $true; legacyOkMeaning = 'core_available'; coreAvailable = $true
      updatedAt = $now.ToString('o'); lastVerifyOk = $true
      verification = @{ state = 'passed'; passed = $true; checkedAt = $now.AddMinutes(6).ToString('o'); requiredForCore = $false }
    }

    $result.ok | Should Be $false
    $result.cacheReady | Should Be $false
    $result.staleReason | Should Be 'verify_from_future'
  }
}
