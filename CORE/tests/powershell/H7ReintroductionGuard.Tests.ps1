$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts\common.ps1')

function New-H7CacheFixture([string]$Base) {
  $codexHome = Join-Path $Base 'codex-home'
  $codexSkills = Join-Path $codexHome 'skills'
  $zcodeSkills = Join-Path $Base 'zcode-skills'
  $memoryRoot = Join-Path $Base 'memory-root'
  $adapter = Join-Path $codexSkills 'super-memory-brain'
  New-Item -ItemType Directory -Force -Path $adapter,$memoryRoot | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'super-memory-brain\SKILL.md') -Destination (Join-Path $adapter 'SKILL.md') -Force
  [IO.File]::WriteAllText((Join-Path $adapter 'package-root.txt'),($Root + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $adapter 'memory-root.txt'),($memoryRoot + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  $brainMcp = Join-Path $Root 'runtime\brain_mcp.py'
  $runtimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
  $config = @"
[mcp_servers.super-memory-brain]
command = 'python'
args = ['$brainMcp', '--package-root', '$Root', '--memory-root', '$memoryRoot']

[mcp_servers.super-memory-brain.env]
SUPER_BRAIN_PACKAGE_ROOT = '$Root'
NEXSANDBASE_HOME = '$memoryRoot'
SUPER_BRAIN_RUNTIME_IDENTITY = '$runtimeIdentity'
"@
  [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'),$config,[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ codexHome=$codexHome; codexSkills=$codexSkills; zcodeSkills=$zcodeSkills; memoryRoot=$memoryRoot; configPath=(Join-Path $codexHome 'config.toml') }
}

function Invoke-H7CacheFixture([object]$Fixture) {
  $script = Join-Path $Root 'scripts\host-cache-check.ps1'
  return @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -CodexHome $Fixture.codexHome -CodexSkills $Fixture.codexSkills -ZCodeSkills $Fixture.zcodeSkills -MemoryRoot $Fixture.memoryRoot -Json 2>&1)
}

Describe 'H7 retired transport reintroduction guards' {
  It 'keeps retired root migration and legacy-root shims out of the active package' {
    Test-Path -LiteralPath (Join-Path $Root 'scripts\root-layout-migration.ps1') | Should Be $false
    Test-Path -LiteralPath (Join-Path $Root 'runtime\legacy_root_codex_prompt_hook.py') | Should Be $false
    Test-Path -LiteralPath (Join-Path $Root 'runtime\legacy_root_codex_user_prompt_hook.ps1') | Should Be $false
  }

  It 'reports a current H7 MCP binding without writing the isolated Codex configuration' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state'
      $fixture = New-H7CacheFixture (Join-Path $TestDrive 'ready')
      $configBefore = Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256
      $raw = Invoke-H7CacheFixture $fixture
      $LASTEXITCODE | Should Be 0
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $true
      $result.h7.mcpBinding.ok | Should Be $true
      $result.h7.adapter.ok | Should Be $true
      $result.h7.retiredTransportGuard.ok | Should Be $true
      $result.h7.retiredTransportGuard.reportOnly | Should Be $true
      $result.h7.retiredTransportGuard.state | Should Be 'absent'
      $result.PSObject.Properties['codexHook'] | Should Be $null
      (Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256).Hash | Should Be $configBefore.Hash
      (Test-Path -LiteralPath (Join-Path $fixture.codexHome 'hooks.json')) | Should Be $false
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }

  It 'fails closed on a stale Super Brain Hook without mutating the isolated hook or config files' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state'
      $fixture = New-H7CacheFixture (Join-Path $TestDrive 'conflict')
      $hooksPath = Join-Path $fixture.codexHome 'hooks.json'
      $hooks = [pscustomobject]@{
        hooks = [pscustomobject]@{
          UserPromptSubmit = @(
            [pscustomobject]@{ type='command'; command='python C:\legacy\super-memory-brain\dispatcher.py'; statusMessage='Super Brain legacy' },
            [pscustomobject]@{ type='command'; command='echo unrelated-hook'; statusMessage='Other integration' }
          )
        }
      }
      [IO.File]::WriteAllText($hooksPath,($hooks | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
      $configBefore = Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256
      $hooksBefore = Get-FileHash -LiteralPath $hooksPath -Algorithm SHA256
      $raw = Invoke-H7CacheFixture $fixture
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $false
      $result.h7.mcpBinding.ok | Should Be $true
      $result.h7.retiredTransportGuard.ok | Should Be $false
      $result.h7.retiredTransportGuard.reportOnly | Should Be $true
      $result.h7.retiredTransportGuard.state | Should Be 'conflict'
      $result.currentSessionCacheRisk | Should Be 'retired_transport_conflict'
      $result.recommendedAction | Should Match 'retire-codex-super-brain-hooks.ps1 -Apply'
      (Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256).Hash | Should Be $configBefore.Hash
      (Get-FileHash -LiteralPath $hooksPath -Algorithm SHA256).Hash | Should Be $hooksBefore.Hash
      $after = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
      @($after.hooks.UserPromptSubmit).Count | Should Be 2
      @($after.hooks.UserPromptSubmit | Where-Object { $_.command -eq 'echo unrelated-hook' }).Count | Should Be 1
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    }
  }
}
