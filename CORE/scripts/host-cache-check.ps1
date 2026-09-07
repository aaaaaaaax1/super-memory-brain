[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$CodexSkills = '',
  [string]$ZCodeSkills = '',
  [string]$MemoryRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\','/')
$manifest = Get-SuperBrainManifest $Root
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\','/')
if ([string]::IsNullOrWhiteSpace($CodexSkills)) { $CodexSkills = Join-Path $CodexHome 'skills' }
if ([string]::IsNullOrWhiteSpace($ZCodeSkills)) { $ZCodeSkills = Join-Path $env:USERPROFILE '.zcode\skills' }
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$MemoryRoot = [IO.Path]::GetFullPath($MemoryRoot).TrimEnd('\','/')
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-host-cache-check.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function File-HashShort([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0, 12) } catch { return '' }
}

function Read-Text([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } catch { return '' }
}

function Test-TextHasPath([string]$Text,[string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
  foreach ($variant in @($full,$full.Replace('\','\\'),$full.Replace('\','/')) | Select-Object -Unique) {
    $offset = 0
    while ($offset -lt $Text.Length) {
      $index = $Text.IndexOf($variant,$offset,[StringComparison]::OrdinalIgnoreCase)
      if ($index -lt 0) { break }
      $beforeOk = ($index -eq 0 -or $Text[$index - 1] -notmatch '[A-Za-z0-9._-]')
      $afterIndex = $index + $variant.Length
      $afterOk = ($afterIndex -ge $Text.Length -or $Text[$afterIndex] -match '[\\/"''\s,\]]')
      if ($beforeOk -and $afterOk) { return $true }
      $offset = $index + 1
    }
  }
  return $false
}

function Get-CodexMcpTableText([string]$Text,[string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Name)) { return '' }
  $lines = @($Text -split "`r?`n")
  $escaped = [regex]::Escape($Name)
  $tablePattern = '^\s*\[mcp_servers\.(?:"' + $escaped + '"|' + $escaped + ')\]\s*$'
  $start = -1
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match $tablePattern) { $start = $index; break }
  }
  if ($start -lt 0) { return '' }
  $end = $lines.Count
  $sectionPrefix = 'mcp_servers.' + $Name
  for ($index = $start + 1; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match '^\s*\[(?<section>[^\]]+)\]\s*$') {
      $section = [string]$Matches['section']
      if ($section -ne $sectionPrefix -and -not $section.StartsWith($sectionPrefix + '.', [StringComparison]::OrdinalIgnoreCase)) {
        $end = $index
        break
      }
    }
  }
  return ($lines[$start..($end - 1)] -join "`n")
}

function Get-SkillVersion([string]$Path) {
  $text = Read-Text $Path
  if ([string]::IsNullOrWhiteSpace($text)) { return '' }
  $match = [regex]::Match($text, 'Package Version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
  if ($match.Success) { return $match.Groups[1].Value }
  $match = [regex]::Match($text, '##\s+([0-9]+\.[0-9]+\.[0-9]+)')
  if ($match.Success) { return $match.Groups[1].Value }
  return ''
}

function New-HostAdapterResult([string]$Name,[string]$SkillsRoot,[bool]$Required) {
  $skillPath = Join-Path $SkillsRoot 'super-memory-brain\SKILL.md'
  $packageRootMarker = Join-Path $SkillsRoot 'super-memory-brain\package-root.txt'
  $memoryRootMarker = Join-Path $SkillsRoot 'super-memory-brain\memory-root.txt'
  $sourceSkill = Join-Path $Root 'super-memory-brain\SKILL.md'
  $sourceHash = File-HashShort $sourceSkill
  $skillHash = File-HashShort $skillPath
  $packageRoot = (Read-Text $packageRootMarker).Trim()
  $memoryRoot = (Read-Text $memoryRootMarker).Trim()
  $exists = Test-Path -LiteralPath $skillPath -PathType Leaf
  $contentMatches = ($exists -and $sourceHash -ne '' -and $sourceHash -eq $skillHash)
  $packageRootMatches = ($packageRoot -eq $Root)
  $memoryRootMatches = ($memoryRoot -eq $MemoryRoot)
  return [pscustomobject]@{
    host = $Name
    required = $Required
    skillPath = $skillPath
    exists = $exists
    version = Get-SkillVersion $skillPath
    expectedVersion = [string]$manifest.version
    hash = $skillHash
    sourceHash = $sourceHash
    contentMatches = $contentMatches
    packageRootMarker = $packageRootMarker
    packageRoot = $packageRoot
    packageRootMatches = $packageRootMatches
    memoryRootMarker = $memoryRootMarker
    memoryRoot = $memoryRoot
    memoryRootMatches = $memoryRootMatches
    installedFresh = ($exists -and $contentMatches -and $packageRootMatches -and $memoryRootMatches)
  }
}

function Get-H7McpBinding([string]$CodexHomePath) {
  $configPath = Join-Path $CodexHomePath 'config.toml'
  $configText = Read-Text $configPath
  # The launcher is the only current MCP entry.  The direct brain_mcp entry
  # remains a narrowly recognized migration signature so this read-only
  # report can explain an old installation without calling it current.
  $launcher = Join-Path $Root 'runtime\local_mcp_launcher.py'
  $legacyBrainMcp = Join-Path $Root 'runtime\brain_mcp.py'
  $serverDeclared = $configText -match '(?m)^\s*\[mcp_servers\.(?:"super-memory-brain"|super-memory-brain)\]\s*$'
  $tableText = Get-CodexMcpTableText $configText 'super-memory-brain'
  $argsMatch = [regex]::Match($tableText, '(?mi)^\s*args\s*=\s*\[\s*["''](?<entry>[^"'']+)["'']')
  $entryPath = if ($argsMatch.Success) { [string]$argsMatch.Groups['entry'].Value } else { '' }
  $argsLine = if ($argsMatch.Success) { [string]($tableText -split "`r?`n" | Where-Object { $_ -match '(?mi)^\s*args\s*=' } | Select-Object -First 1) } else { '' }
  # Classify the executable from the actual args array, not from an arbitrary
  # comment or environment value elsewhere in the TOML table.
  $launcherMatches = Test-TextHasPath $entryPath $launcher
  $legacyBrainMcpMatches = Test-TextHasPath $entryPath $legacyBrainMcp
  $brainMcpMatches = $launcherMatches -or $legacyBrainMcpMatches
  # Bind the roots to the launcher argument line itself.  Looking only at an
  # env value or a comment can make a malformed args array appear healthy.
  $packageRootMatches = Test-TextHasPath $argsLine $Root
  $memoryRootMatches = Test-TextHasPath $argsLine $MemoryRoot
  $argumentContractPresent = ($argsMatch.Success -and $argsLine -match '(?i)--package-root' -and $argsLine -match '(?i)--memory-root')
  $expectedRuntimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
  $runtimeIdentityMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_RUNTIME_IDENTITY\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredRuntimeIdentity = if ($runtimeIdentityMatch.Success) { [string]$runtimeIdentityMatch.Groups['value'].Value } else { '' }
  $transportMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_MCP_TRANSPORT\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredTransport = if ($transportMatch.Success) { [string]$transportMatch.Groups['value'].Value } else { '' }
  $epochMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_MCP_REGISTRATION_EPOCH\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredEpoch = if ($epochMatch.Success) { [string]$epochMatch.Groups['value'].Value } else { '' }
  $runtimeIdentityMatches = (-not [string]::IsNullOrWhiteSpace($registeredRuntimeIdentity)) -and ($registeredRuntimeIdentity -eq $expectedRuntimeIdentity)
  $transportMatches = ($registeredTransport -eq 'codex_registered_v1')
  $registrationEpochPresent = (-not [string]::IsNullOrWhiteSpace($registeredEpoch))
  $staticBindingOk = ((Test-Path -LiteralPath $configPath -PathType Leaf) -and $serverDeclared -and $brainMcpMatches -and $packageRootMatches -and $memoryRootMatches -and $argumentContractPresent -and $runtimeIdentityMatches -and $transportMatches -and $registrationEpochPresent)
  $currentBindingOk = ($staticBindingOk -and $launcherMatches)
  $migrationRequired = [bool]($staticBindingOk -and $legacyBrainMcpMatches -and -not $launcherMatches)
  $state = if ($currentBindingOk) { 'configured_current' } elseif ($migrationRequired) { 'migration_required' } else { 'stale' }
  return [pscustomobject]@{
    ok = $staticBindingOk
    staticBindingOk = $staticBindingOk
    currentBindingOk = $currentBindingOk
    migrationRequired = $migrationRequired
    state = $state
    configPath = $configPath
    serverDeclared = [bool]$serverDeclared
    launcherPath = $launcher
    legacyBrainMcpPath = $legacyBrainMcp
    entryPath = $entryPath
    argsLine = $argsLine
    brainMcpPath = $legacyBrainMcp
    brainMcpMatches = $brainMcpMatches
    launcherMatches = $launcherMatches
    legacyBrainMcpMatches = $legacyBrainMcpMatches
    packageRootMatches = $packageRootMatches
    memoryRootMatches = $memoryRootMatches
    argumentContractPresent = [bool]$argumentContractPresent
    expectedRuntimeIdentity = $expectedRuntimeIdentity
    registeredRuntimeIdentity = $registeredRuntimeIdentity
    runtimeIdentityMatches = $runtimeIdentityMatches
    transportMatches = $transportMatches
    registrationEpochPresent = $registrationEpochPresent
  }
}

function Get-H7RetiredTransportGuard([string]$CodexHomePath) {
  $retirementScript = Join-Path $Root 'scripts\retire-codex-super-brain-hooks.ps1'
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $retirementScript -CodexHome $CodexHomePath -Json 2>&1)
  $exitCode = $LASTEXITCODE
  $raw = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
  if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{ ok=$false; reportOnly=$true; state='unavailable'; configurationChanged=$false; superBrainArtifactPresent=$false; otherHooksPreserved=$false; code='H7_RETIREMENT_REPORT_UNAVAILABLE' }
  }
  try { $report = $raw | ConvertFrom-Json } catch {
    return [pscustomobject]@{ ok=$false; reportOnly=$true; state='unavailable'; configurationChanged=$false; superBrainArtifactPresent=$false; otherHooksPreserved=$false; code='H7_RETIREMENT_REPORT_INVALID' }
  }
  $reportOnly = ([string]$report.mode -eq 'report')
  $clean = ($report.ok -eq $true -and $reportOnly -and $report.configurationChanged -ne $true -and $report.superBrainArtifactPresent -ne $true -and $report.otherHooksPreserved -eq $true)
  return [pscustomobject]@{
    ok = $clean
    reportOnly = $reportOnly
    state = if($clean){'absent'}elseif($report.configurationChanged -eq $true -or $report.superBrainArtifactPresent -eq $true){'conflict'}else{'unavailable'}
    configurationChanged = [bool]$report.configurationChanged
    superBrainArtifactPresent = [bool]$report.superBrainArtifactPresent
    otherHooksPreserved = [bool]$report.otherHooksPreserved
    code = if($clean){'H7_RETIRED_TRANSPORT_GUARD_CURRENT'}elseif($report.configurationChanged -eq $true -or $report.superBrainArtifactPresent -eq $true){'H7_RETIRED_TRANSPORT_CONFLICT'}else{'H7_RETIREMENT_REPORT_UNAVAILABLE'}
  }
}

$codexAdapter = New-HostAdapterResult 'codex' $CodexSkills $true
$zcodeInstalled = Test-Path -LiteralPath $ZCodeSkills -PathType Container
$zcodeAdapter = New-HostAdapterResult 'zcode' $ZCodeSkills $false
$requiredAdapterFailures = @($codexAdapter | Where-Object { $_.installedFresh -ne $true })
$optionalAdapterFailures = if ($zcodeInstalled -and $zcodeAdapter.installedFresh -ne $true) { @($zcodeAdapter) } else { @() }
$mcpBinding = Get-H7McpBinding $CodexHome
$retiredTransportGuard = Get-H7RetiredTransportGuard $CodexHome
$adapterOk = ($requiredAdapterFailures.Count -eq 0)
$ok = ($adapterOk -and $mcpBinding.ok -and $retiredTransportGuard.ok)

$currentSessionCacheRisk = if (-not $mcpBinding.staticBindingOk) {
  'h7_mcp_binding_stale'
} elseif (-not $retiredTransportGuard.ok) {
  'retired_transport_conflict'
} elseif ($mcpBinding.migrationRequired) {
  'h7_mcp_binding_migration_required'
} elseif (-not $adapterOk) {
  'adapter_stale'
} else {
  'live_mcp_identity_unobserved'
}

$recommendedAction = if (-not $mcpBinding.staticBindingOk) {
  'Run install-runtime.ps1 for the intended Codex home, then rerun this read-only H7 binding report.'
} elseif (-not $retiredTransportGuard.ok) {
  'H7 is blocked by a stale Super Brain Hook registration or artifact. After H7 binding is verified, explicitly authorize retire-codex-super-brain-hooks.ps1 -Apply; this report does not change configuration.'
} elseif ($mcpBinding.migrationRequired) {
  'The static H7 binding is a legacy direct brain_mcp entry. Keep this report read-only; explicitly run the approved install-runtime.ps1 migration when you are ready to switch to local_mcp_launcher.py.'
} elseif (-not $adapterOk) {
  'Run hot-refresh-skills.ps1 -AllKnown, then open a new Codex task only if this chat loaded older adapter text.'
} else {
  'Static H7 MCP binding, the Super Brain adapter, and the retired-transport guard are current. A governed turn must still obtain brain_status/runtimeIdentity=current from the live MCP process before it uses MCP execution.'
}

$result = [pscustomobject]@{
  ok = $ok
  staticOk = $ok
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  packageRoot = $Root
  memoryRoot = $MemoryRoot
  h7 = [pscustomobject]@{
    mcpBinding = $mcpBinding
    adapter = [pscustomobject]@{
      ok = $adapterOk
      required = @($codexAdapter)
      optional = @($zcodeAdapter)
      optionalPresent = $zcodeInstalled
      requiredFailures = @($requiredAdapterFailures | ForEach-Object { $_.host })
      optionalFailures = @($optionalAdapterFailures | ForEach-Object { $_.host })
    }
    retiredTransportGuard = $retiredTransportGuard
  }
  currentSessionCacheRisk = $currentSessionCacheRisk
  mcpStaticBindingOk = [bool]$mcpBinding.staticBindingOk
  mcpCurrentBindingOk = [bool]$mcpBinding.currentBindingOk
  mcpMigrationRequired = [bool]$mcpBinding.migrationRequired
  mcpExecutionReady = $false
  mcpExecutionState = 'runtime_probe_required'
  mcpExecutionProbe = 'Call registered brain_status and require runtimeIdentity.state=current plus liveMcpHandshake.state=current.'
  loadedSkillLimitation = 'The report verifies installed adapter files and H7 MCP binding, but cannot inspect adapter text already loaded into this chat context.'
  liveMcpIdentityLimitation = 'This static report cannot inspect the already-running MCP process. The governed H7 adapter must require brain_status.runtimeIdentity.state=current before using MCP execution; otherwise it uses the same package H7 CLI or repairs the one MCP registration.'
  newSessionPrompt = 'Open a new Codex task only when this chat began before a successful Super Brain adapter refresh.'
  note = 'This is a read-only H7 MCP/adapter cache report. It never installs, repairs, or re-registers a retired Super Brain Hook or MCP server.'
  recommendedAction = $recommendedAction
  statusPath = $statusPath
}

Write-JsonUtf8NoBom $statusPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "HOST_CACHE_CHECK staticOk=$($result.staticOk) mcpExecution=$($result.mcpExecutionState) risk=$($result.currentSessionCacheRisk) status=$statusPath" }
if (-not $result.ok) { exit 1 }
exit 0
