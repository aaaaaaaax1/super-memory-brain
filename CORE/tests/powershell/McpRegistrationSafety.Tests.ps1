$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

function New-TestSuperBrainMcpRegistration {
  param(
    [string]$Command = 'python',
    [string[]]$Arguments = @(),
    [bool]$Enabled = $true,
    [hashtable]$Overrides = @{}
  )
  $memoryRoot = Join-Path (Split-Path -Parent $root) 'private-state\shared'
  $runtimeIdentity = 'a' * 64
  $epoch = 'b' * 32
  if ($Arguments.Count -eq 0) {
    $Arguments = @(
      (Join-Path $root 'runtime\local_mcp_launcher.py'),
      '--package-root', $root,
      '--memory-root', $memoryRoot
    )
  }
  $environment = [ordered]@{
    'SUPER_BRAIN_PACKAGE_ROOT' = $root
    'NEXSANDBASE_HOME' = $memoryRoot
    'SUPER_BRAIN_RUNTIME_IDENTITY' = $runtimeIdentity
    'SUPER_BRAIN_MCP_TRANSPORT' = 'codex_registered_v1'
    'SUPER_BRAIN_MCP_REGISTRATION_EPOCH' = $epoch
    'SUPER_BRAIN_MCP_REGISTRATION_SCHEMA' = 'super-brain.codex-mcp.v2'
  }
  foreach ($key in $Overrides.Keys) { $environment[$key] = $Overrides[$key] }
  return [pscustomobject]@{
    enabled = $Enabled
    transport = [pscustomobject]@{
      type = 'stdio'
      command = $Command
      args = @($Arguments)
      env = [pscustomobject]$environment
    }
  }
}

Describe 'MCP registration safety boundary' {
  It 'does not claim a partial same-name stdio entry as Super Brain owned' {
    $foreign = [pscustomobject]@{
      enabled = $true
      transport = [pscustomobject]@{
        type = 'stdio'
        command = 'python'
        args = @('foreign.py')
        env = [pscustomobject]@{ 'SUPER_BRAIN_PACKAGE_ROOT' = $root }
      }
    }
    $assessment = Test-SuperBrainMcpRegistrationContract -Registered $foreign -PackageRoot $root -MemoryRoot (Join-Path (Split-Path -Parent $root) 'private-state\shared')
    $assessment.owned | Should Be $false
    $assessment.current | Should Be $false
  }

  It 'requires the exact package launcher invocation before a no-op is current' {
    $identity = 'a' * 64
    $memoryRoot = Join-Path (Split-Path -Parent $root) 'private-state\shared'
    $valid = New-TestSuperBrainMcpRegistration
    (Test-SuperBrainMcpRegistrationContract -Registered $valid -PackageRoot $root -MemoryRoot $memoryRoot -RuntimeIdentity $identity -RequireEnabled).current | Should Be $true

    $wrongCommand = New-TestSuperBrainMcpRegistration -Command 'node'
    (Test-SuperBrainMcpRegistrationContract -Registered $wrongCommand -PackageRoot $root -MemoryRoot $memoryRoot -RuntimeIdentity $identity -RequireEnabled).current | Should Be $false

    $wrongScript = New-TestSuperBrainMcpRegistration -Arguments @('foreign.py','--package-root',$root,'--memory-root',$memoryRoot)
    (Test-SuperBrainMcpRegistrationContract -Registered $wrongScript -PackageRoot $root -MemoryRoot $memoryRoot -RuntimeIdentity $identity -RequireEnabled).current | Should Be $false

    $wrongOrder = New-TestSuperBrainMcpRegistration -Arguments @((Join-Path $root 'runtime\local_mcp_launcher.py'),'--memory-root',$memoryRoot,'--package-root',$root)
    (Test-SuperBrainMcpRegistrationContract -Registered $wrongOrder -PackageRoot $root -MemoryRoot $memoryRoot -RuntimeIdentity $identity -RequireEnabled).current | Should Be $false

    $extra = New-TestSuperBrainMcpRegistration -Arguments @((Join-Path $root 'runtime\local_mcp_launcher.py'),'--package-root',$root,'--memory-root',$memoryRoot,'--extra')
    (Test-SuperBrainMcpRegistrationContract -Registered $extra -PackageRoot $root -MemoryRoot $memoryRoot -RuntimeIdentity $identity -RequireEnabled).current | Should Be $false
  }

  It 'recognizes only the complete direct-worker legacy signature as owned for migration' {
    $legacy = New-TestSuperBrainMcpRegistration -Arguments @(
      (Join-Path $root 'runtime\brain_mcp.py'),
      '--package-root', $root,
      '--memory-root', (Join-Path (Split-Path -Parent $root) 'private-state\shared')
    ) -Overrides @{ 'SUPER_BRAIN_MCP_REGISTRATION_SCHEMA' = 'super-brain.codex-mcp.v1' }
    $assessment = Test-SuperBrainMcpRegistrationContract -Registered $legacy -PackageRoot $root -MemoryRoot (Join-Path (Split-Path -Parent $root) 'private-state\shared')
    $assessment.owned | Should Be $true
    $assessment.current | Should Be $false
    $assessment.code | Should Be 'MCP_REGISTRATION_OWNED_LEGACY_LAUNCHER_REQUIRED'

    $legacy.transport.args = @('foreign.py','--package-root',$root,'--memory-root',(Join-Path (Split-Path -Parent $root) 'private-state\shared'))
    (Test-SuperBrainMcpRegistrationContract -Registered $legacy -PackageRoot $root -MemoryRoot (Join-Path (Split-Path -Parent $root) 'private-state\shared')).owned | Should Be $false

    $forgedCurrent = New-TestSuperBrainMcpRegistration -Arguments @(
      (Join-Path $root 'runtime\brain_mcp.py'),
      '--package-root', $root,
      '--memory-root', (Join-Path (Split-Path -Parent $root) 'private-state\shared')
    )
    (Test-SuperBrainMcpRegistrationContract -Registered $forgedCurrent -PackageRoot $root -MemoryRoot (Join-Path (Split-Path -Parent $root) 'private-state\shared')).owned | Should Be $false
  }

  It 'serializes every package targeting the same effective Codex configuration' {
    $lockRoot = Join-Path $TestDrive 'mcp-locks'
    $scopeA = Get-SuperBrainMcpConfigurationScopeKey -CodexHome 'C:\Codex\One' -ExplicitCodexHome
    $scopeB = Get-SuperBrainMcpConfigurationScopeKey -CodexHome 'c:\codex\one' -ExplicitCodexHome
    $scopeOther = Get-SuperBrainMcpConfigurationScopeKey -CodexHome 'C:\Codex\Two' -ExplicitCodexHome
    $first = Get-SuperBrainMcpRegistrationLockPath -McpName 'super-memory-brain' -ConfigurationScope $scopeA -LockRoot $lockRoot
    $same = Get-SuperBrainMcpRegistrationLockPath -McpName 'SUPER-MEMORY-BRAIN' -ConfigurationScope $scopeB -LockRoot $lockRoot
    $other = Get-SuperBrainMcpRegistrationLockPath -McpName 'super-memory-brain' -ConfigurationScope $scopeOther -LockRoot $lockRoot
    $first | Should Be $same
    $first | Should Not Be $other
  }
}
