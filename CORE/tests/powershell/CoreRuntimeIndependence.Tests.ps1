Describe 'Core runtime independence from host adapters' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
    # This suite exercises a host-free core.  Give it one explicit, initialized
    # state root instead of inheriting a worker's unrelated state root.
    $script:previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $script:previousArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
    $stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('super-brain-core-runtime-' + [guid]::NewGuid().ToString('n'))
    $memoryRoot = Join-Path $stateRoot 'shared'
    New-Item -ItemType Directory -Force -Path $stateRoot,$memoryRoot | Out-Null
    $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
    $env:SUPER_BRAIN_ARCHIVE_ROOT = Join-Path $stateRoot 'archive'
    Initialize-SuperBrainMemoryRoot $memoryRoot $root 'shared' @('all-agents')
    $script:fixture = [pscustomobject]@{
      root = $root
      stateRoot = $stateRoot
      memoryRoot = $memoryRoot
      encoding = [Text.UTF8Encoding]::new($false)
    }
  }

  AfterAll {
    if ($null -eq $script:previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $script:previousStateRoot }
    if ($null -eq $script:previousArchiveRoot) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $script:previousArchiveRoot }
  }

  It 'keeps the H7 core ready when the Codex host is not installed' {
    $zcodeSkills = Join-Path $TestDrive 'host-absent\zcode\skills'
    $codexSkills = Join-Path $TestDrive 'host-absent\codex\skills'

    $startupRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:fixture.root 'scripts\startup-check.ps1') -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -MemoryRoot $script:fixture.memoryRoot -Isolated -Json 2>&1)
    $LASTEXITCODE | Should Be 0
    $startup = (($startupRaw -join [Environment]::NewLine) | ConvertFrom-Json)
    $startup.ok | Should Be $true
    $startup.coreAvailable | Should Be $true
    $startup.adapterAvailable | Should Be $false
    $startup.adapterState | Should Be 'not_installed'
    $startup.entryAdapterRequired | Should Be $false
    $startup.adapterFailureCount | Should Be 0

    $statusRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:fixture.root 'scripts\status.ps1') -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -MemoryRoot $script:fixture.memoryRoot -Isolated -Json 2>&1)
    $LASTEXITCODE | Should Be 0
    $status = (($statusRaw -join [Environment]::NewLine) | ConvertFrom-Json)
    $status.ok | Should Be $true
    $status.coreAvailable | Should Be $true
    $status.adapterState | Should Be 'not_installed'

    $health = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:fixture.root 'scripts\health-check.ps1') -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -MemoryRoot $script:fixture.memoryRoot -Isolated -SkipRuntime 2>&1)
    $LASTEXITCODE | Should Be 0
    (($health -join [Environment]::NewLine) -match 'HEALTH_CHECK_OK') | Should Be $true
    (($health -join [Environment]::NewLine) -match 'ENTRY_ADAPTER_NOT_INSTALLED') | Should Be $true
  }

  It 'withholds a stale Codex primary adapter without withholding the H7 core' {
    $codexSkills = Join-Path $TestDrive 'primary-stale\codex\skills'
    $zcodeSkills = Join-Path $TestDrive 'primary-stale\zcode\skills'
    $agentHome = Split-Path -Parent $codexSkills
    New-Item -ItemType Directory -Force -Path $codexSkills | Out-Null
    [IO.File]::WriteAllText((Join-Path $agentHome 'AGENTS.md'),((Get-SuperBrainGlobalStartupBlock $script:fixture.root) + [Environment]::NewLine),$script:fixture.encoding)
    $staleSkill = Join-Path $codexSkills 'super-memory-brain'
    New-Item -ItemType Directory -Force -Path $staleSkill | Out-Null
    [IO.File]::WriteAllText((Join-Path $staleSkill 'SKILL.md'),"---`nname: stale-super-brain`n---`nstale adapter",$script:fixture.encoding)

    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:fixture.root 'scripts\startup-check.ps1') -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -MemoryRoot $script:fixture.memoryRoot -Isolated -Json 2>&1)
    $LASTEXITCODE | Should Be 1
    $startup = (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
    $stale = @($startup.adapterChecks | Where-Object { [string]$_.name -eq 'Codex super-memory-brain skill' }) | Select-Object -First 1

    $startup.ok | Should Be $false
    $startup.coreAvailable | Should Be $true
    $startup.adapterAvailable | Should Be $false
    $startup.adapterState | Should Be 'withheld'
    $startup.entryAdapterRequired | Should Be $true
    $stale.state | Should Be 'stale'
    $stale.installedSha256 | Should Not Be $stale.sourceSha256
    $stale.optional | Should Be $false
  }

  It 'accepts the current host-neutral local MCP launcher binding' {
    $base = Join-Path $TestDrive 'primary-launcher-current'
    $codexSkills = Join-Path $base 'codex\skills'
    $codexHome = Split-Path -Parent $codexSkills
    $memoryRoot = Join-Path $base 'state\shared'
    $adapter = Join-Path $codexSkills 'super-memory-brain'
    New-Item -ItemType Directory -Force -Path $codexHome,$codexSkills,$adapter,$memoryRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $memoryRoot 'sandglass.txt'),'',$script:fixture.encoding)
    [IO.File]::WriteAllText((Join-Path $codexHome 'AGENTS.md'),((Get-SuperBrainGlobalStartupBlock $script:fixture.root) + [Environment]::NewLine),$script:fixture.encoding)
    Copy-Item -LiteralPath (Join-Path $script:fixture.root 'super-memory-brain\SKILL.md') -Destination (Join-Path $adapter 'SKILL.md') -Force
    Write-SuperBrainPackageRootMarker $adapter $script:fixture.root
    # This is an isolated fixture root, so write its marker directly instead
    # of asking the live-memory guard to rebind the package's canonical root.
    [IO.File]::WriteAllText((Join-Path $adapter 'memory-root.txt'),($memoryRoot + [Environment]::NewLine),$script:fixture.encoding)
    $runtimeIdentity = Get-SuperBrainMcpRuntimeIdentity $script:fixture.root
    $epoch = ('a' * 32)
    $config = @(
      '[mcp_servers.super-memory-brain]',
      "command = 'python'",
      "args = ['$($script:fixture.root)\runtime\local_mcp_launcher.py', '--package-root', '$($script:fixture.root)', '--memory-root', '$memoryRoot']",
      '',
      '[mcp_servers.super-memory-brain.env]',
      "SUPER_BRAIN_PACKAGE_ROOT = '$($script:fixture.root)'",
      "NEXSANDBASE_HOME = '$memoryRoot'",
      "SUPER_BRAIN_RUNTIME_IDENTITY = '$runtimeIdentity'",
      "SUPER_BRAIN_MCP_TRANSPORT = 'codex_registered_v1'",
      "SUPER_BRAIN_MCP_REGISTRATION_EPOCH = '$epoch'",
      "SUPER_BRAIN_MCP_REGISTRATION_SCHEMA = 'super-brain.codex-mcp.v2'"
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'),$config,$script:fixture.encoding)

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      # The isolated marker is valid only when the child observes the same
      # explicit state root that owns the fixture's shared memory directory.
      $env:SUPER_BRAIN_STATE_ROOT = Join-Path $base 'state'
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:fixture.root 'scripts\startup-check.ps1') -CodexSkills $codexSkills -MemoryRoot $memoryRoot -Isolated -Json 2>&1)
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
    $LASTEXITCODE | Should Be 0
    $startup = (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
    $startup.ok | Should Be $true
    $startup.mcpBinding.state | Should Be 'configured_current'
    $startup.mcpBinding.launcherMatches | Should Be $true
    $startup.mcpBinding.legacyBrainMcpMatches | Should Be $false
  }
}
