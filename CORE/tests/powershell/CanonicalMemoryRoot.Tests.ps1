Describe 'Super Brain canonical active memory root' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
    $hotRefresh = Join-Path $root 'scripts\hot-refresh-skills.ps1'
  }

  It 'projects a stale sharing policy to stateRoot shared without exposing legacy live roots' {
    $stateRoot = Join-Path $TestDrive 'policy-state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $policyPath = Join-Path $stateRoot 'workspace\memory-sharing-policy.json'
    New-Item -ItemType Directory -Force -Path $sharedRoot,(Split-Path -Parent $policyPath) | Out-Null
    Write-JsonUtf8NoBom $policyPath ([ordered]@{
      initialized = $true
      mode = 'Agent'
      activeRoot = (Join-Path $stateRoot 'agents\zcode')
      sharedRoot = (Join-Path $stateRoot 'old-shared')
      agentsRoot = (Join-Path $stateRoot 'agents')
      groupsRoot = (Join-Path $stateRoot 'groups')
      updatedAt = '2026-08-09 00:00:00'
    }) 6

    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $policy = Get-SuperBrainSharingPolicy $root
      (Get-SuperBrainActiveMemoryRoot $root) | Should Be ([IO.Path]::GetFullPath($sharedRoot))
      $policy.mode | Should Be 'shared'
      $policy.activeRoot | Should Be ([IO.Path]::GetFullPath($sharedRoot))
      $policy.sharedRoot | Should Be ([IO.Path]::GetFullPath($sharedRoot))
      $policy.rootAuthority | Should Be 'stateRoot/shared'
      $policy.legacyRootsReadOnly | Should Be $true
      $policy.PSObject.Properties['agentsRoot'] | Should BeNullOrEmpty
      $policy.PSObject.Properties['groupsRoot'] | Should BeNullOrEmpty
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }

  It 'rejects arbitrary active roots while allowing an explicit fixture stateRoot shared child' {
    $stateRoot = Join-Path $TestDrive 'fixture-state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $legacyRoot = Join-Path $stateRoot 'agents\zcode'
    New-Item -ItemType Directory -Force -Path $sharedRoot,$legacyRoot | Out-Null

    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      (Resolve-SuperBrainActiveMemoryRoot -Root $root -Candidate $sharedRoot -Operation 'fixture') | Should Be ([IO.Path]::GetFullPath($sharedRoot))
      { Resolve-SuperBrainActiveMemoryRoot -Root $root -Candidate $legacyRoot -Operation 'fixture' } | Should Throw
      { Resolve-SuperBrainActiveMemoryRoot -Root $root -Candidate (Join-Path $TestDrive 'arbitrary-memory') -Operation 'fixture' } | Should Throw
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }

  It 'ignores a stale installed marker and rewrites it to the canonical shared root on hot refresh' {
    $stateRoot = Join-Path $TestDrive 'refresh-state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $legacyRoot = Join-Path $stateRoot 'agents\zcode'
    $archiveRoot = Join-Path $TestDrive 'refresh-archive'
    $skillRoot = Join-Path $TestDrive 'skills'
    $installed = Join-Path $skillRoot 'super-memory-brain'
    New-Item -ItemType Directory -Force -Path $sharedRoot,$legacyRoot,$skillRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'super-memory-brain') -Destination $installed -Recurse -Force
    Write-SuperBrainPackageRootMarker $installed $root
    Write-Utf8NoBom (Join-Path $installed 'memory-root.txt') (([IO.Path]::GetFullPath($legacyRoot)) + "`n")

    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $previousArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_ARCHIVE_ROOT = $archiveRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hotRefresh -SkillRoots $skillRoot -SkillNames super-memory-brain -NoBackup -SkipGlobalStartup -Json 2>&1)
      $LASTEXITCODE | Should Be 0
      $result = ($raw -join "`n") | ConvertFrom-Json
      $result.ok | Should Be $true
      ((Get-Content -LiteralPath (Join-Path $installed 'memory-root.txt') -Raw -Encoding UTF8).Trim()) | Should Be ([IO.Path]::GetFullPath($sharedRoot))
      (Test-Path -LiteralPath (Join-Path $sharedRoot 'sandglass.txt') -PathType Leaf) | Should Be $true
      (Test-Path -LiteralPath (Join-Path $legacyRoot 'sandglass.txt') -PathType Leaf) | Should Be $false
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
      if ($null -eq $previousArchiveRoot) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $previousArchiveRoot }
    }
  }

  It 'requires an explicit eligible CORE migration rebind before refreshing an installed adapter' {
    $stateRoot = Join-Path $TestDrive 'core-migration-state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $archiveRoot = Join-Path $TestDrive 'core-migration-archive'
    $skillRoot = Join-Path $TestDrive 'skills'
    $installed = Join-Path $skillRoot 'super-memory-brain'
    $legacyWorkspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $root
    New-Item -ItemType Directory -Force -Path $sharedRoot,$skillRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'super-memory-brain') -Destination $installed -Recurse -Force
    Write-Utf8NoBom (Join-Path $installed 'package-root.txt') (([IO.Path]::GetFullPath($legacyWorkspaceRoot)) + "`n")
    Write-Utf8NoBom (Join-Path $installed 'memory-root.txt') (([IO.Path]::GetFullPath($sharedRoot)) + "`n")

    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $previousArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_ARCHIVE_ROOT = $archiveRoot

      $withoutRebind = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hotRefresh -SkillRoots $skillRoot -SkillNames super-memory-brain -NoBackup -SkipGlobalStartup -Json 2>&1)
      $LASTEXITCODE | Should Be 1
      $withoutRebindResult = ($withoutRebind -join "`n") | ConvertFrom-Json
      $withoutRebindResult.ok | Should Be $false
      $withoutRebindResult.results[0].packageRootState | Should Be 'core_migration_rebind_eligible'
      ((Get-Content -LiteralPath (Join-Path $installed 'package-root.txt') -Raw -Encoding UTF8).Trim()) | Should Be ([IO.Path]::GetFullPath($legacyWorkspaceRoot))

      $withRebind = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hotRefresh -SkillRoots $skillRoot -SkillNames super-memory-brain -RebindPackageRoot -NoBackup -SkipGlobalStartup -Json 2>&1)
      $LASTEXITCODE | Should Be 0
      $withRebindResult = ($withRebind -join "`n") | ConvertFrom-Json
      $withRebindResult.ok | Should Be $true
      $withRebindResult.results[0].packageRootRebound | Should Be $true
      ((Get-Content -LiteralPath (Join-Path $installed 'package-root.txt') -Raw -Encoding UTF8).Trim()) | Should Be ([IO.Path]::GetFullPath($root))
      (Get-FileHash -LiteralPath (Join-Path $installed 'SKILL.md') -Algorithm SHA256).Hash | Should Be (Get-FileHash -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Algorithm SHA256).Hash
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
      if ($null -eq $previousArchiveRoot) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $previousArchiveRoot }
    }
  }
}
