Describe 'Super Brain unified memory and absorbed capability sources' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $install = Join-Path $root 'scripts\install.ps1'
    $memoryMode = Join-Path $root 'scripts\memory-mode.ps1'
    $capabilityMap = Join-Path $root 'scripts\skill-capability-map.ps1'
  }

  It 'keeps legacy split mode on one root and routes cold sources without standalone installation' {
    $stateRoot = Join-Path $TestDrive 'state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $zcodeSkills = Join-Path $TestDrive 'zcode\skills'
    $codexSkills = Join-Path $TestDrive 'codex\skills'
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $installOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $install -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -Neurobase $sharedRoot -IncludeZCode -SkipRuntime -SkipHealthCheck -NoBackup 2>&1)
      $LASTEXITCODE | Should Be 0
      foreach ($path in @(
        (Join-Path $zcodeSkills 'super-memory-brain\SKILL.md'),
        (Join-Path $codexSkills 'super-memory-brain\SKILL.md')
      )) { (Test-Path -LiteralPath $path) | Should Be $true }
      foreach ($path in @(
        (Join-Path $zcodeSkills 'ponytail\SKILL.md'),
        (Join-Path $codexSkills 'ponytail\SKILL.md'),
        (Join-Path $zcodeSkills 'grill-me\SKILL.md'),
        (Join-Path $codexSkills 'grill-me\SKILL.md')
      )) { (Test-Path -LiteralPath $path) | Should Be $false }

      $modeOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $memoryMode -Mode SplitMemory -Target Both -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills 2>&1)
      $LASTEXITCODE | Should Be 0
      (($modeOutput -join "`n") -like '*MEMORY_MODE_RETIRED requested=SplitMemory resolved=Shared*') | Should Be $true
      $expected = [IO.Path]::GetFullPath($sharedRoot)
      ((Get-Content -LiteralPath (Join-Path $zcodeSkills 'super-memory-brain\memory-root.txt') -Raw -Encoding UTF8).Trim()) | Should Be $expected
      ((Get-Content -LiteralPath (Join-Path $codexSkills 'super-memory-brain\memory-root.txt') -Raw -Encoding UTF8).Trim()) | Should Be $expected
      (Test-Path -LiteralPath (Join-Path $stateRoot 'agents\zcode')) | Should Be $false
      (Test-Path -LiteralPath (Join-Path $stateRoot 'agents\codex')) | Should Be $false

      foreach ($name in @('ponytail','grill-me')) {
        $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capabilityMap -Name $name -Detail -Json 2>&1)
        $LASTEXITCODE | Should Be 0
        $result = ($raw -join "`n") | ConvertFrom-Json
        $result.count | Should BeGreaterThan 0
        $capability = @($result.capabilities | Select-Object -First 1)[0]
        $capability.executionOwner | Should Be 'super-memory-brain'
        $capability.sourceKind | Should Be 'absorbed_package_capability_source'
        $capability.standaloneInstall | Should Be $false
      }
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }
}
