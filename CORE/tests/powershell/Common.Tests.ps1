Describe 'Super Memory Brain common helpers' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
  }

  It 'resolves an explicit hook path' {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) 'super-brain-hook-test'
    Get-SuperBrainHookPath $temp | Should Be ([System.IO.Path]::GetFullPath($temp))
  }

  It 'resolves CORE layout entries relative to CORE and rejects workspace escape' {
    $workspace = Join-Path $TestDrive 'portable-layout'
    $core = Join-Path $workspace 'CORE'
    $state = Join-Path $workspace 'private-state'
    $archive = Join-Path $workspace 'private-archive'
    # The Pester runner deliberately provides SUPER_BRAIN_STATE_ROOT for
    # state isolation.  This assertion exercises portable layout resolution,
    # so remove that fixture override only for the duration of this case.
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $previousArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue
      Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Force -Path $core,$state,$archive | Out-Null
      Write-Utf8NoBom (Join-Path $core 'runtime-layout.json') (@{
        schema='super-brain.runtime-layout.v1';sourceRoot='..';runtimeRoot='.';stateRoot='../private-state';archiveRoot='../private-archive'
      } | ConvertTo-Json -Compress)

      (Get-SuperBrainRuntimeWorkspaceRoot $core) | Should Be ([IO.Path]::GetFullPath($workspace))
      (Get-SuperBrainMemoryBaseRoot $core) | Should Be ([IO.Path]::GetFullPath($state))
      (Get-SuperBrainArchiveRoot $core) | Should Be ([IO.Path]::GetFullPath($archive))
      { Resolve-SuperBrainRuntimeLayoutPath $core '../../unrelated-state' } | Should Throw
    } finally {
      if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
      if ($null -eq $previousArchiveRoot) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue }
      else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $previousArchiveRoot }
    }
  }

  It 'keeps the PowerShell MCP path hash compatible with the Python runtime contract' {
    $actual = Get-SuperBrainMcpPathHash $root
    $expected = Get-SuperBrainStableHash ((Get-NormalizedSuperBrainRoot $root).ToLowerInvariant()) 64

    $actual | Should Be $expected
    $actual | Should Match '^[a-f0-9]{64}$'
  }

  It 'writes UTF-8 without BOM' {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-nobom-' + [guid]::NewGuid().ToString() + '.json')
    Write-Utf8NoBom $path '{"ok":true}'
    try {
      $bytes = [System.IO.File]::ReadAllBytes($path)
      (($bytes.Length -ge 3) -and ($bytes[0] -eq 239) -and ($bytes[1] -eq 187) -and ($bytes[2] -eq 191)) | Should Be $false
    } finally {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
  }

  It 'emits canonical governance timestamps in UTC' {
    $timestamp = Get-SuperBrainUtcTimestamp
    $instant = [DateTimeOffset]::Parse($timestamp, [Globalization.CultureInfo]::InvariantCulture)

    $instant.Offset.TotalMinutes | Should Be 0
    $timestamp | Should Match '(Z|\+00:00)$'
  }

  It 'calculates p50 and p95 across the complete sample set' {
    Get-SuperBrainPercentileMs -Samples @(10,20,30,40) -Percentile 0.50 | Should Be 20
    Get-SuperBrainPercentileMs -Samples @(10,20,30,40) -Percentile 0.95 | Should Be 40
  }

  It 'drains bounded owned-process output without pipe deadlock' {
    $scriptPath = Join-Path $TestDrive 'emit-large-output.ps1'
    $line = 'x' * 512
    Write-Utf8NoBom $scriptPath ("for(`$index = 0; `$index -lt 1200; `$index++) { [Console]::Out.WriteLine('$line') }")
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath.Replace('"','\"') + '"'

    $outcome = Invoke-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine $argumentLine -TimeoutSeconds 12

    $outcome.started | Should Be $true
    $outcome.timedOut | Should Be $false
    $outcome.processExited | Should Be $true
    $outcome.exitCode | Should Be 0
    $outcome.stdout.Length | Should BeGreaterThan 600000
  }

  It 'bounds timeout cleanup for an owned process' {
    $scriptPath = Join-Path $TestDrive 'sleep-owned-process.ps1'
    Write-Utf8NoBom $scriptPath 'Start-Sleep -Seconds 20'
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath.Replace('"','\"') + '"'

    $outcome = Invoke-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine $argumentLine -TimeoutSeconds 1

    $outcome.timedOut | Should Be $true
    $outcome.durationMs | Should BeLessThan 8000
    $outcome.processExited | Should Be $true
  }

  It 'does not classify process-environment cleanup as a persistent T0 mutation' {
    $scriptPath = Join-Path $TestDrive 'environment-cleanup.ps1'
    Write-Utf8NoBom $scriptPath 'Remove-Item Env:\TEMP_FLAG -ErrorAction SilentlyContinue'

    $analysis = Test-SuperBrainPersistentScriptMutation $scriptPath

    $analysis.ok | Should Be $true
    @($analysis.mutations).Count | Should Be 0
  }

  It 'detects a persistent filesystem write in a T0 mutation analysis' {
    $scriptPath = Join-Path $TestDrive 'persistent-write.ps1'
    Write-Utf8NoBom $scriptPath "Set-Content -LiteralPath (Join-Path `$env:TEMP 'mutation.txt') -Value 'x'"

    $analysis = Test-SuperBrainPersistentScriptMutation $scriptPath

    $analysis.ok | Should Be $true
    @($analysis.mutations).Count | Should Be 1
    $analysis.mutations[0].command | Should Be 'Set-Content'
  }

  It 'analyzes a batch launcher without parsing it as PowerShell' {
    $scriptPath = Join-Path $TestDrive 'launcher.bat'
    Write-Utf8NoBom $scriptPath ("@echo off" + [Environment]::NewLine + 'powershell.exe -NoProfile -File "%~dp0bootstrap.ps1"')

    $analysis = Test-SuperBrainPersistentScriptMutation $scriptPath

    $analysis.ok | Should Be $true
    $analysis.code | Should Be 'SUPER_BRAIN_LAUNCHER_MUTATION_ANALYSIS_CURRENT'
    $analysis.language | Should Be 'bat'
    @($analysis.mutations).Count | Should Be 0
  }

  It 'detects a destructive command in a batch launcher' {
    $scriptPath = Join-Path $TestDrive 'unsafe-launcher.bat'
    Write-Utf8NoBom $scriptPath ("@echo off" + [Environment]::NewLine + 'del "%TEMP%\unsafe.txt"')

    $analysis = Test-SuperBrainPersistentScriptMutation $scriptPath

    $analysis.ok | Should Be $true
    @($analysis.mutations).Count | Should Be 1
  }

  It 'keeps the external bootstrap thin and delegates behavioral policy to Super Brain' {
    $block = Get-SuperBrainGlobalStartupBlock
    (Get-SuperBrainGlobalStartupMaxChars) | Should Be 0
    $block.Contains('## Super Memory Brain Bootstrap') | Should Be $true
    $block.Contains('Entry: explicit Super Brain/G1') | Should Be $true
    $block.Contains('semantic governed task intent') | Should Be $true
    $block.Contains('literal naming is not required') | Should Be $true
    $block.Contains('Git workflow trigger') | Should Be $true
    $block.Contains('Authority: bootstrap only') | Should Be $true
    $block.Contains('super-brain-rules.json') | Should Be $true
    $block.Contains('must never duplicate or override') | Should Be $true
    $block.Contains('Safety: Host transport is permanently retired') | Should Be $true
    $block.Contains('same H7 CLI') | Should Be $true
    $block.Contains('Never use Hook/P7') | Should Be $true
    $block.Contains('Host transport is permanently retired') | Should Be $true
    $block.Contains('current cwd') | Should Be $true
    $block.Contains('Compaction:') | Should Be $false
    $block.Contains('Stage receipt') | Should Be $false
    $block.Contains('checkpoint wins') | Should Be $false
  }

  It 'keeps H7 core readiness independent of an optional skill adapter' {
    $full = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $true -MemoryRootReady $true -McpBindingReady $true -McpFunctionalReady $true -ActivationCoreReady $true
    $full.ok | Should Be $true
    $full.coreRuntimeReady | Should Be $true
    $full.adapterState | Should Be 'ready'
    $full.availability | Should Be 'full'
    $full.transport | Should Be 'h7_mcp'
    $full.action | Should Be 'ready'

    $cliFallback = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $true -MemoryRootReady $true -McpBindingReady $false -McpFunctionalReady $false -ActivationCoreReady $true -CliRuntimeReady $true
    $cliFallback.ok | Should Be $true
    $cliFallback.coreRuntimeReady | Should Be $true
    $cliFallback.availability | Should Be 'full'
    $cliFallback.transport | Should Be 'h7_cli'
    $cliFallback.action | Should Be 'ready'

    $adapterMissing = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $false -MemoryRootReady $true -McpBindingReady $true -McpFunctionalReady $true -ActivationCoreReady $true
    $adapterMissing.ok | Should Be $true
    $adapterMissing.coreRuntimeReady | Should Be $true
    $adapterMissing.adapterRequired | Should Be $false
    $adapterMissing.adapterState | Should Be 'optional_missing'
    $adapterMissing.availability | Should Be 'full'
    $adapterMissing.action | Should Be 'ready'

    $coreBlocked = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $false -MemoryRootReady $true -McpBindingReady $false -McpFunctionalReady $false -ActivationCoreReady $false
    $coreBlocked.ok | Should Be $false
    $coreBlocked.coreRuntimeReady | Should Be $false
    $coreBlocked.action | Should Be 'repair_mcp_on_first_load'
  }

  It 'keeps recovery rules in the Super Brain adapter rather than the external bootstrap' {
    $block = Get-SuperBrainGlobalStartupBlock $root
    $skill = Get-Content -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Raw -Encoding UTF8

    $block.Contains('Authority: bootstrap only') | Should Be $true
    $block.Contains('Host transport is permanently retired') | Should Be $true
    $block.Contains('Compaction:') | Should Be $false
    $skill.Contains('sole behavioral-policy') | Should Be $true
    $skill.Contains('Host transport is permanently retired') | Should Be $true
    $skill.Contains('Summaries, handoffs, memory, checkpoints, old receipts') | Should Be $true
    $skill.Contains('local cwd/session scope') | Should Be $true
    $skill | Should Match 'scope-bound\s+runtime/checkpoint evidence'
    $skill.Contains('bare `continue`') | Should Be $true
    $skill.Contains('Ordinary continuous work') | Should Be $true
    $skill.Contains('actual continuation result') | Should Be $true
    $skill | Should Match 'verified mapped phase,\s+current\s+step,\s+and next action'
    $skill.Contains('Do not emit raw commentary as a standalone substitute') | Should Be $true
    $skill.Contains('then actually continues it.') | Should Be $true
    $skill.Contains('do not turn every intermediate update') | Should Be $true
    $skill.Contains('Reserve phase/status presentation') | Should Be $true
    $skill.Contains('The local projection does not mutate the contract') | Should Be $true
    $skill.Contains('Delivery efficiency is an execution invariant') | Should Be $true
    $skill.Contains('MCP transport is unavailable') | Should Be $true
  }

  It 'renders global CJK workflow triggers from character codes without mojibake' {
    $block = Get-SuperBrainGlobalStartupBlock
    $gitHow = -join [char[]]@(24590,20040,20889)
    $gitWhat = -join [char[]]@(21602)
    $howCommit = -join [char[]]@(24590,20040,25552,20132)
    $mojibake = -join [char[]]@(37806,24221,31646)

    (Get-SuperBrainGlobalStartupMaxChars) | Should Be 0
    $block.Contains('`git' + $gitHow + '`') | Should Be $true
    $block.Contains('`git' + $gitWhat + '`') | Should Be $true
    $block.Contains('`' + $howCommit + '`') | Should Be $true
    $block.Contains($mojibake) | Should Be $false
    $block.Contains('Authority: bootstrap only') | Should Be $true
  }

  It 'falls back to the canonical shared root when the persisted active root is no longer a memory root' {
    $stateRoot = Join-Path $TestDrive 'stale-active-root'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $staleRoot = Join-Path $stateRoot 'workspace\installer-isolated\memory'
    New-Item -ItemType Directory -Force -Path (Join-Path $sharedRoot 'scripts'),$staleRoot,(Join-Path $stateRoot 'workspace') | Out-Null
    Write-Utf8NoBom (Join-Path $sharedRoot 'sandglass.txt') '2026-07-26 00:00:00 | system | [CURRENT][VERIFIED] shared fixture'
    $policy = [pscustomobject]@{
      initialized = $true
      mode = 'shared'
      activeRoot = $staleRoot
      sharedRoot = $sharedRoot
      agentsRoot = Join-Path $stateRoot 'agents'
      groupsRoot = Join-Path $stateRoot 'groups'
      members = @('all-agents')
    }
    Write-JsonUtf8NoBom (Join-Path $stateRoot 'workspace\memory-sharing-policy.json') $policy 6

    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      (Get-SuperBrainActiveMemoryRoot $root) | Should Be ([System.IO.Path]::GetFullPath($sharedRoot))
      { Assert-SuperBrainMemoryWriteAllowed $root $sharedRoot 'fixture write' } | Should Not Throw
      { Assert-SuperBrainMemoryWriteAllowed $root $staleRoot 'fixture write' } | Should Throw
    } finally {
      if ($null -eq $previousStateRoot) {
        Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue
      } else {
        $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot
      }
    }
  }

  It 'treats a reverse supersession pointer as evidence, not an ADR schema root' {
    $policy = [pscustomobject]@{
      adr = [pscustomobject]@{
        statuses = @('proposed','accepted','deprecated','superseded','rejected')
        currentStatuses = @('proposed','accepted')
        requiredRelations = @('decides','has_title','has_status','has_context','has_consequence')
      }
    }
    $tags = '[DECISION][ADR][CURRENT][VERIFIED]'
    $nodes = @(
      [pscustomobject]@{ subject='decision:new'; relation='decides'; object='new behavior'; tags=$tags },
      [pscustomobject]@{ subject='decision:new'; relation='has_title'; object='New behavior'; tags=$tags },
      [pscustomobject]@{ subject='decision:new'; relation='has_status'; object='accepted'; tags=$tags },
      [pscustomobject]@{ subject='decision:new'; relation='has_context'; object='context'; tags=$tags },
      [pscustomobject]@{ subject='decision:new'; relation='has_consequence'; object='consequence'; tags=$tags },
      [pscustomobject]@{ subject='decision:new'; relation='supersedes'; object='decision:legacy'; tags=$tags },
      [pscustomobject]@{ subject='decision:legacy'; relation='superseded_by'; object='decision:new'; tags='[DECISION][ADR][STALE][VERIFIED]' }
    )

    $state = Get-SuperBrainAdrState -DecisionNodes $nodes -Policy $policy

    $state.ok | Should Be $true
    $state.subjectCount | Should Be 1
    $state.schemaIssueCount | Should Be 0
  }
}
