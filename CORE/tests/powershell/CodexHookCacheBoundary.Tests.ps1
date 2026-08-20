$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts\common.ps1')

function New-H7CodexCacheFixture([string]$Base,[string]$ConfiguredMemoryRoot = '') {
  $codexHome = Join-Path $Base 'codex-home'
  $codexSkills = Join-Path $codexHome 'skills'
  $zcodeSkills = Join-Path $Base 'zcode-skills'
  $memoryRoot = Join-Path $Base 'memory-root'
  $adapter = Join-Path $codexSkills 'super-memory-brain'
  New-Item -ItemType Directory -Force -Path $adapter,$memoryRoot | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'super-memory-brain\SKILL.md') -Destination (Join-Path $adapter 'SKILL.md') -Force
  [IO.File]::WriteAllText((Join-Path $adapter 'package-root.txt'),($Root + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $adapter 'memory-root.txt'),($memoryRoot + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  $boundMemoryRoot = if([string]::IsNullOrWhiteSpace($ConfiguredMemoryRoot)){$memoryRoot}else{$ConfiguredMemoryRoot}
  $brainMcp = Join-Path $Root 'runtime\brain_mcp.py'
  $runtimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
  $config = @"
[mcp_servers.super-memory-brain]
command = 'python'
args = ['$brainMcp', '--package-root', '$Root', '--memory-root', '$boundMemoryRoot']

[mcp_servers.super-memory-brain.env]
SUPER_BRAIN_PACKAGE_ROOT = '$Root'
NEXSANDBASE_HOME = '$boundMemoryRoot'
SUPER_BRAIN_RUNTIME_IDENTITY = '$runtimeIdentity'
SUPER_BRAIN_MCP_TRANSPORT = 'codex_registered_v1'
SUPER_BRAIN_MCP_REGISTRATION_EPOCH = 'test-registration-epoch'
"@
  $configPath = Join-Path $codexHome 'config.toml'
  [IO.File]::WriteAllText($configPath,$config,[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ codexHome=$codexHome; codexSkills=$codexSkills; zcodeSkills=$zcodeSkills; memoryRoot=$memoryRoot; configPath=$configPath }
}

function Invoke-H7CodexCacheCheck([object]$Fixture) {
  return @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\host-cache-check.ps1') -CodexHome $Fixture.codexHome -CodexSkills $Fixture.codexSkills -ZCodeSkills $Fixture.zcodeSkills -MemoryRoot $Fixture.memoryRoot -Json 2>&1)
}

Describe 'H7 MCP cache boundary guards' {
  It 'accepts a current H7 MCP and adapter binding without requiring an optional ZCode adapter' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state-ready'
      $fixture = New-H7CodexCacheFixture (Join-Path $TestDrive 'ready')
      $configBefore = Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256
      $raw = Invoke-H7CodexCacheCheck $fixture
      $LASTEXITCODE | Should Be 0
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $true
      $result.h7.mcpBinding.ok | Should Be $true
      $result.h7.adapter.ok | Should Be $true
      $result.h7.adapter.optionalPresent | Should Be $false
      $result.h7.retiredTransportGuard.state | Should Be 'absent'
      $result.PSObject.Properties['codexHook'] | Should Be $null
      (Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256).Hash | Should Be $configBefore.Hash
    } finally {
      if($null -eq $previousStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$previousStateRoot}
    }
  }

  It 'fails closed for a stale Super Brain Hook registration and only reports the conflict' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state-conflict'
      $fixture = New-H7CodexCacheFixture (Join-Path $TestDrive 'conflict')
      $hooksPath = Join-Path $fixture.codexHome 'hooks.json'
      $superBrainHook = [pscustomobject]@{type='command';command='python C:\legacy\super-memory-brain\dispatcher.py';statusMessage='Super Brain legacy'}
      $unrelatedHook = [pscustomobject]@{type='command';command='echo unrelated-hook';statusMessage='Other integration'}
      $fixtureHooks = [pscustomobject]@{
        hooks = [pscustomobject]@{
          UserPromptSubmit = @([pscustomobject]@{ hooks=@($superBrainHook,$unrelatedHook) })
        }
      }
      [IO.File]::WriteAllText($hooksPath,($fixtureHooks|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
      $configBefore = Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256
      $hooksBefore = Get-FileHash -LiteralPath $hooksPath -Algorithm SHA256
      $raw = Invoke-H7CodexCacheCheck $fixture
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $false
      $result.h7.mcpBinding.ok | Should Be $true
      $result.h7.retiredTransportGuard.reportOnly | Should Be $true
      $result.h7.retiredTransportGuard.state | Should Be 'conflict'
      $result.h7.retiredTransportGuard.configurationChanged | Should Be $true
      $result.currentSessionCacheRisk | Should Be 'retired_transport_conflict'
      $result.recommendedAction | Should Match 'retire-codex-super-brain-hooks.ps1 -Apply'
      (Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256).Hash | Should Be $configBefore.Hash
      (Get-FileHash -LiteralPath $hooksPath -Algorithm SHA256).Hash | Should Be $hooksBefore.Hash
      $saved = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
      @($saved.hooks.UserPromptSubmit[0].hooks).Count | Should Be 2
    } finally {
      if($null -eq $previousStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$previousStateRoot}
    }
  }

  It 'withholds a malformed H7 MCP memory binding without falling back to retired transport readiness' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state-mismatch'
      $fixture = New-H7CodexCacheFixture (Join-Path $TestDrive 'mismatch') (Join-Path $TestDrive 'different-memory-root')
      $configBefore = Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256
      $raw = Invoke-H7CodexCacheCheck $fixture
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $false
      $result.h7.mcpBinding.ok | Should Be $false
      $result.h7.mcpBinding.memoryRootMatches | Should Be $false
      $result.h7.retiredTransportGuard.state | Should Be 'absent'
      $result.currentSessionCacheRisk | Should Be 'h7_mcp_binding_stale'
      (Get-FileHash -LiteralPath $fixture.configPath -Algorithm SHA256).Hash | Should Be $configBefore.Hash
    } finally {
      if($null -eq $previousStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$previousStateRoot}
    }
  }

  It 'withholds a stale registered runtime identity without changing configuration' {
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $TestDrive 'state-identity'
      $fixture = New-H7CodexCacheFixture (Join-Path $TestDrive 'identity')
      $configBefore = Get-Content -LiteralPath $fixture.configPath -Raw -Encoding UTF8
      $stale = $configBefore -replace '(?m)^SUPER_BRAIN_RUNTIME_IDENTITY\s*=\s*.*$','SUPER_BRAIN_RUNTIME_IDENTITY = ''stale-runtime-identity'''
      [IO.File]::WriteAllText($fixture.configPath,$stale,[Text.UTF8Encoding]::new($false))
      $raw = Invoke-H7CodexCacheCheck $fixture
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.h7.mcpBinding.ok | Should Be $false
      $result.h7.mcpBinding.runtimeIdentityMatches | Should Be $false
      $result.currentSessionCacheRisk | Should Be 'h7_mcp_binding_stale'
      (Get-Content -LiteralPath $fixture.configPath -Raw -Encoding UTF8) | Should Be $stale
    } finally {
      if($null -eq $previousStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$previousStateRoot}
    }
  }
}
