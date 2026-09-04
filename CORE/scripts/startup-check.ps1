param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = "",
  [string]$HookPath = "",
  [int]$MaxStartupRuleChars = 320,
  [switch]$IncludeZCode,
  [switch]$Isolated,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$defaultZCodeSkills = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.zcode\skills'))
$defaultCodexSkills = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\skills'))
$targetZCodeSkills = [IO.Path]::GetFullPath($ZCodeSkills)
$targetCodexSkills = [IO.Path]::GetFullPath($CodexSkills)
$zcodeHostPresent = $IncludeZCode -and ((Test-Path -LiteralPath (Split-Path -Parent $targetZCodeSkills)) -or (Test-Path -LiteralPath $targetZCodeSkills))
$codexHostPresent = (Test-Path -LiteralPath (Split-Path -Parent $targetCodexSkills)) -or (Test-Path -LiteralPath $targetCodexSkills)
$isolationMode = [bool]$Isolated -or
  ($IncludeZCode -and -not $targetZCodeSkills.Equals($defaultZCodeSkills,[StringComparison]::OrdinalIgnoreCase)) -or
  -not $targetCodexSkills.Equals($defaultCodexSkills,[StringComparison]::OrdinalIgnoreCase)
if (-not [string]::IsNullOrWhiteSpace($HookPath)) {
  $HookPath = Get-SuperBrainHookPath $HookPath
} elseif (-not $isolationMode) {
  try { $HookPath = Get-SuperBrainHookPath '' } catch { $HookPath = '' }
}

$ok = $true
$checks = @()
$adapterChecks = @()
$hookChecks = @()
$runtimeChecks = @()
$configChecks = @()

function Add-Check([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  if (-not $exists) { $script:ok = $false }
  $script:checks += [pscustomobject]@{ name=$Name; ok=$exists; path=$Path }
}

function Add-AdapterCheck([string]$Name, [string]$Path, [string]$SourcePath = '', [switch]$Required) {
  $exists = Test-Path -LiteralPath $Path -PathType Leaf
  $sourceExists = [string]::IsNullOrWhiteSpace($SourcePath) -or (Test-Path -LiteralPath $SourcePath -PathType Leaf)
  $installedHash = if ($exists) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
  $sourceHash = if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and $sourceExists) { (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
  $fresh = $exists -and $sourceExists -and ([string]::IsNullOrWhiteSpace($SourcePath) -or $installedHash -eq $sourceHash)
  $state = if (-not $exists) { 'missing' } elseif (-not $sourceExists) { 'source_missing' } elseif (-not [string]::IsNullOrWhiteSpace($SourcePath) -and $installedHash -ne $sourceHash) { 'stale' } else { 'ready' }
  if ($Required -and -not $fresh) { $script:ok = $false }
  $script:adapterChecks += [pscustomobject]@{ name=$Name; ok=$fresh; path=$Path; sourcePath=$SourcePath; state=$state; installedSha256=$installedHash; sourceSha256=$sourceHash; optional=(-not $Required) }
}

function Add-MarkerCheck([string]$Name, [object]$Result) {
  if (-not $Result.ok) { $script:ok = $false }
  $script:checks += [pscustomobject]@{ name=$Name; ok=$Result.ok; path=$Result.marker; actual=$Result.actual; expected=$Result.expected }
}

function Add-AdapterMarkerCheck([string]$Name, [object]$Result, [switch]$Required) {
  if ($Required -and -not $Result.ok) { $script:ok = $false }
  $script:adapterChecks += [pscustomobject]@{ name=$Name; ok=$Result.ok; path=$Result.marker; actual=$Result.actual; expected=$Result.expected; optional=(-not $Required) }
}

function Add-OptionalHostStartupCheck([string]$Name, [object]$Result = $null, [string]$SkippedReason = '') {
  if ($null -eq $Result) {
    $script:adapterChecks += [pscustomobject]@{
      name=$Name; ok=$true; path=''; expected=''; state='not_installed'; optional=$true; skipped=$true; reason=$SkippedReason; failed=@()
    }
    return
  }
  $missingTarget = @($Result.failed | Where-Object { [string]$_.reason -eq 'startup_target_missing' }).Count -gt 0
  $state = if ($Result.ok) { 'ready' } elseif ($missingTarget) { 'missing' } else { 'stale' }
  $script:adapterChecks += [pscustomobject]@{
    name=$Name
    ok=[bool]$Result.ok
    path=($Result.paths -join '; ')
    expected=($Result.expected -join '; ')
    state=$state
    optional=$true
    skipped=[bool]$Result.skipped
    reason=[string]$Result.reason
    failed=@($Result.failed)
  }
}

function Add-ConfigCheck([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  $script:configChecks += [pscustomobject]@{ name=$Name; ok=$exists; path=$Path }
}

function Add-RuntimeCheck([string]$Name, [bool]$Found, [string]$Reason = '') {
  if (-not $Found) { $script:ok = $false }
  $script:runtimeChecks += [pscustomobject]@{ name=$Name; ok=$Found; reason=$Reason }
}

function Test-ConfigHasPath([string]$Text,[string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
  foreach ($variant in @($full,$full.Replace('\','\\'),$full.Replace('\','/')) | Select-Object -Unique) {
    if ($Text.IndexOf($variant,[StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
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

function Get-PrimaryCodexMcpStaticBinding([string]$CodexHomePath) {
  $configPath = Join-Path $CodexHomePath 'config.toml'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return [pscustomobject]@{ state='not_configured'; ok=$true; configured=$false; configPath=$configPath; code='H7_MCP_NOT_CONFIGURED_CLI_EQUIVALENT_AVAILABLE'; runtimeIdentityMatches=$true }
  }
  try { $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } catch {
    return [pscustomobject]@{ state='stale'; ok=$false; configured=$true; configPath=$configPath; code='H7_MCP_CONFIG_UNREADABLE'; runtimeIdentityMatches=$false }
  }
  $declared = $configText -match '(?m)^\s*\[mcp_servers\.(?:"super-memory-brain"|super-memory-brain)\]\s*$'
  if (-not $declared) {
    return [pscustomobject]@{ state='not_configured'; ok=$true; configured=$false; configPath=$configPath; code='H7_MCP_NOT_CONFIGURED_CLI_EQUIVALENT_AVAILABLE'; runtimeIdentityMatches=$true }
  }
  $tableText = Get-CodexMcpTableText $configText 'super-memory-brain'
  if ([string]::IsNullOrWhiteSpace($tableText)) {
    return [pscustomobject]@{ state='stale'; ok=$false; configured=$true; configPath=$configPath; code='H7_MCP_TABLE_UNREADABLE'; runtimeIdentityMatches=$false }
  }
  $runtimeIdentityMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_RUNTIME_IDENTITY\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredIdentity = if ($runtimeIdentityMatch.Success) { [string]$runtimeIdentityMatch.Groups['value'].Value } else { '' }
  $transportMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_MCP_TRANSPORT\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredTransport = if ($transportMatch.Success) { [string]$transportMatch.Groups['value'].Value } else { '' }
  $epochMatch = [regex]::Match($tableText, '(?mi)^\s*SUPER_BRAIN_MCP_REGISTRATION_EPOCH\s*=\s*["''](?<value>[^"'']+)["'']\s*$')
  $registeredEpoch = if ($epochMatch.Success) { [string]$epochMatch.Groups['value'].Value } else { '' }
  $expectedIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
  # The current registration launches the host-neutral local scope adapter;
  # keep the direct brain_mcp path as a narrow migration-compatible signature
  # because existing installed entries may still be awaiting one explicit
  # refresh.  Both paths are package-owned and are checked against the same
  # package/memory/identity contract below.
  $launcherMatches = Test-ConfigHasPath $tableText (Join-Path $Root 'runtime\local_mcp_launcher.py')
  $legacyBrainMcpMatches = Test-ConfigHasPath $tableText (Join-Path $Root 'runtime\brain_mcp.py')
  $brainMcpMatches = $launcherMatches -or $legacyBrainMcpMatches
  $packageRootMatches = Test-ConfigHasPath $tableText $Root
  $memoryRootMatches = Test-ConfigHasPath $tableText $MemoryRoot
  $argumentContractPresent = ($tableText -match '(?i)--package-root') -and ($tableText -match '(?i)--memory-root')
  $identityMatches = ($registeredIdentity -eq $expectedIdentity)
  $transportMatches = ($registeredTransport -eq 'codex_registered_v1')
  $epochPresent = (-not [string]::IsNullOrWhiteSpace($registeredEpoch))
  $bindingOk = ($brainMcpMatches -and $packageRootMatches -and $memoryRootMatches -and $argumentContractPresent -and $identityMatches -and $transportMatches -and $epochPresent)
  return [pscustomobject]@{
    state=if($bindingOk){'configured_current'}else{'stale'}; ok=$bindingOk; configured=$true; configPath=$configPath
    code=if($bindingOk){'H7_MCP_STATIC_CONFIG_CURRENT'}else{'H7_MCP_STATIC_BINDING_STALE'}
    brainMcpMatches=$brainMcpMatches; launcherMatches=$launcherMatches; legacyBrainMcpMatches=$legacyBrainMcpMatches; packageRootMatches=$packageRootMatches; memoryRootMatches=$memoryRootMatches; argumentContractPresent=$argumentContractPresent
    expectedRuntimeIdentity=$expectedIdentity; registeredRuntimeIdentity=$registeredIdentity; runtimeIdentityMatches=$identityMatches; transportMatches=$transportMatches; registrationEpochPresent=$epochPresent
  }
}

$sourceAdapterSkill = Join-Path $Root 'super-memory-brain\SKILL.md'
if ($IncludeZCode) { Add-AdapterCheck 'ZCode super-memory-brain skill' (Join-Path $ZCodeSkills 'super-memory-brain\SKILL.md') $sourceAdapterSkill }
if ($codexHostPresent) {
  Add-AdapterCheck 'Codex super-memory-brain skill' (Join-Path $CodexSkills 'super-memory-brain\SKILL.md') $sourceAdapterSkill -Required
} else {
  $adapterChecks += [pscustomobject]@{ name='Codex super-memory-brain skill'; ok=$true; path=''; sourcePath=$sourceAdapterSkill; state='not_installed'; installedSha256=''; sourceSha256=''; optional=$true; skipped=$true; reason='Codex host is not installed yet.' }
}
$codexHome = Split-Path -Parent $CodexSkills
$mcpBinding = Get-PrimaryCodexMcpStaticBinding $codexHome
if ($mcpBinding.state -eq 'stale') { $script:ok = $false }
$configChecks += [pscustomobject]@{ name='Codex H7 MCP static binding'; ok=[bool]$mcpBinding.ok; state=[string]$mcpBinding.state; code=[string]$mcpBinding.code; path=[string]$mcpBinding.configPath; runtimeIdentityMatches=[bool]$mcpBinding.runtimeIdentityMatches; transportMatches=[bool]$mcpBinding.transportMatches; registrationEpochPresent=[bool]$mcpBinding.registrationEpochPresent }
$turnRuntimePath = Join-Path $Root 'runtime\turn_runtime.py'
$turnRuntimeEntryAvailable = Test-Path -LiteralPath $turnRuntimePath -PathType Leaf
Add-Check 'H7 Turn Runtime entry' $turnRuntimePath
$hookConfigPath = Join-Path $codexHome 'hooks.json'
$superBrainHookRegistered = $false
$hookConfigReadable = $true
if (Test-Path -LiteralPath $hookConfigPath -PathType Leaf) {
  try {
    $hookConfigText = Get-Content -LiteralPath $hookConfigPath -Raw -Encoding UTF8
    $superBrainHookRegistered = $hookConfigText -match '(?i)super-memory-brain|codex_prompt_hook|codex_stop_hook'
  } catch {
    $hookConfigReadable = $false
  }
}
$retiredTransportGuardCode = if (-not $turnRuntimeEntryAvailable) {
  'H7_RUNTIME_ENTRY_MISSING'
} elseif (-not $hookConfigReadable) {
  'H7_SUPER_BRAIN_HOOK_REGISTRATION_UNVERIFIABLE'
} elseif ($superBrainHookRegistered) {
  'H7_SUPER_BRAIN_HOOK_REGISTRATION_CONFLICT'
} else {
  'H7_RETIRED_TRANSPORT_GUARD_CURRENT'
}
$retiredTransportGuardState = if ($retiredTransportGuardCode -eq 'H7_RETIRED_TRANSPORT_GUARD_CURRENT') { 'ready' } else { 'withheld' }
$retiredTransportRegistrationState = if (-not $hookConfigReadable) { 'unverifiable' } elseif ($superBrainHookRegistered) { 'conflict' } else { 'absent' }
$retiredTransportGuard = [pscustomobject]@{
  schema = 'super-brain.retired-transport-guard.v1'
  state = $retiredTransportGuardState
  code = $retiredTransportGuardCode
  requiredForCore = $true
  h7Transport = [pscustomobject]@{
    mode = 'hookless_turn_runtime'
    primary = 'mcp'
    fallback = 'same_h7_cli'
    entryAvailable = $turnRuntimeEntryAvailable
  }
  superBrainHookRegistration = [pscustomobject]@{
    state = $retiredTransportRegistrationState
    registered = if ($hookConfigReadable) { $superBrainHookRegistered } else { $null }
    configurationReadable = $hookConfigReadable
  }
  actionAuthorization = 'not_authorizing'
  legacyDependency = 'none'
  rawPromptStored = $false
  rawTranscriptStored = $false
}
Add-RuntimeCheck 'H7 retired transport guard' ($retiredTransportGuardState -eq 'ready') 'H7 accepts only MCP or the same H7 CLI; a Super Brain Hook registration or unreadable registration file blocks core readiness.'
$checks += [pscustomobject]@{ name='Retired transport artifact audit'; ok=$true; path=(Join-Path $codexHome 'hooks\super-memory-brain'); skipped=$true; reason='report-only; active Super Brain lifecycle is H7.' }
Add-Check 'Package memory root' $MemoryRoot
$checks += [pscustomobject]@{ name='H7 lifecycle route'; ok=$true; path=''; skipped=$true; reason='global AGENTS and H7 MCP/CLI are the supported Super Brain route' }
if ($IncludeZCode -and $zcodeHostPresent) {
  $zcodeGlobalStartup = Test-SuperBrainGlobalStartup $ZCodeSkills
  Add-OptionalHostStartupCheck 'ZCode global startup bootstrap' $zcodeGlobalStartup
} else {
  Add-OptionalHostStartupCheck 'ZCode global startup bootstrap' $null 'ZCode is an optional host adapter and is not installed.'
}
if ($codexHostPresent) {
  $codexGlobalStartup = Test-SuperBrainGlobalStartup $CodexSkills
  if (-not $codexGlobalStartup.ok) { $script:ok = $false }
  $checks += [pscustomobject]@{ name='Codex global startup bootstrap'; ok=$codexGlobalStartup.ok; path=($codexGlobalStartup.paths -join '; '); expected=($codexGlobalStartup.expected -join '; ') }
} else {
  $checks += [pscustomobject]@{ name='Codex global startup bootstrap'; ok=$true; path=''; skipped=$true; reason='Codex host is not installed yet; package verification remains source-only.' }
}
if (-not $isolationMode) {
  $startupSeedRoots = @($CodexSkills)
  if ($IncludeZCode) { $startupSeedRoots += $ZCodeSkills }
  $installedStartupRoots = @(Get-SuperBrainInstalledSkillRoots -SeedRoots $startupSeedRoots -Root $Root)
  foreach ($skillRoot in $installedStartupRoots) {
    if ($IncludeZCode -and (Get-NormalizedSuperBrainRoot $skillRoot) -eq (Get-NormalizedSuperBrainRoot $ZCodeSkills)) { continue }
    if ((Get-NormalizedSuperBrainRoot $skillRoot) -eq (Get-NormalizedSuperBrainRoot $CodexSkills)) { continue }
    $agentHome = Get-SuperBrainAgentHomeFromSkillRoot $skillRoot
    # A copied skill folder does not prove that this agent has an active startup file.
    # Only an existing host instruction file is a core routing requirement.
    $agentStartup = Test-SuperBrainGlobalStartup $skillRoot -OptionalWhenNoHostTarget
    if (-not $agentStartup.ok) { $script:ok = $false }
    $checks += [pscustomobject]@{ name="Installed agent global startup bootstrap ($agentHome)"; ok=$agentStartup.ok; path=($agentStartup.paths -join '; '); expected=($agentStartup.expected -join '; '); skipped=[bool]$agentStartup.skipped; reason=[string]$agentStartup.reason }
  }
}

foreach ($skillName in Get-SuperBrainSkillNames) {
  if ($IncludeZCode) {
    Add-AdapterMarkerCheck "ZCode $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $ZCodeSkills $skillName) $Root)
    Add-AdapterMarkerCheck "ZCode $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $ZCodeSkills $skillName))
  }
  if ($codexHostPresent) {
    Add-AdapterMarkerCheck "Codex $skillName package root" (Test-SuperBrainPackageRootMarker (Join-Path $CodexSkills $skillName) $Root) -Required
    Add-AdapterMarkerCheck "Codex $skillName memory root" (Test-SuperBrainMemoryRootMarker (Join-Path $CodexSkills $skillName)) -Required
  }
}

if (-not $isolationMode) {
  if ($IncludeZCode -and $zcodeHostPresent) {
    Add-ConfigCheck 'ZCode CLI config' "$env:USERPROFILE\.zcode\cli\config.json"
    Add-ConfigCheck 'ZCode v2 settings' "$env:USERPROFILE\.zcode\v2\setting.json"
    Add-ConfigCheck 'ZCode v2 config' "$env:USERPROFILE\.zcode\v2\config.json"
  } elseif ($IncludeZCode) {
    $configChecks += [pscustomobject]@{ name='ZCode host configuration'; ok=$true; path=''; skipped=$true; reason='ZCode host is not installed.' }
  }
  if ($codexHostPresent) { Add-ConfigCheck 'Codex config' "$env:USERPROFILE\.codex\config.toml" }
}

$activation = $null
$activationCode = 'ACTIVATION_NOT_EVALUATED_BY_STARTUP'
$fullBrainActive = $false

if ($Json) {
  $coreFailures = @($checks | Where-Object { $_.ok -ne $true }) + @($runtimeChecks | Where-Object { $_.ok -ne $true })
  $requiredAdapterFailures = @($adapterChecks | Where-Object { $_.optional -ne $true -and $_.ok -ne $true })
  $optionalAdapterFailures = @($adapterChecks | Where-Object { $_.optional -eq $true -and $_.ok -ne $true })
  $coreAvailable = ($coreFailures.Count -eq 0)
  $adapterAvailable = ($codexHostPresent -and $requiredAdapterFailures.Count -eq 0 -and $mcpBinding.state -ne 'stale')
  $axes = [pscustomobject]@{
    coreAvailable = $coreAvailable
    turnRuntime = [pscustomobject]@{
      available = ($turnRuntimeEntryAvailable -and $retiredTransportGuardState -eq 'ready')
      state = if ($turnRuntimeEntryAvailable -and $retiredTransportGuardState -eq 'ready') { 'available' } else { 'withheld' }
      mode = 'hookless_turn_runtime'
      requiredForCore = $true
      failedChecks = @($runtimeChecks | Where-Object { $_.ok -ne $true } | ForEach-Object { [string]$_.name })
    }
    retiredTransportGuard = $retiredTransportGuard
    activation = [pscustomobject]@{
      state = 'not_evaluated'
      fullBrainActive = $false
      code = $activationCode
      activationId = ''
      receiptHash = ''
      coreReady = $coreAvailable
      rawPromptStored = $false
    }
  }
  $adapterState = if (-not $codexHostPresent) { 'not_installed' } elseif ($adapterAvailable) { 'ready' } else { 'withheld' }
  [pscustomobject]@{ ok=$ok; strictOk=$ok; coreAvailable=$axes.coreAvailable; adapterAvailable=$adapterAvailable; adapterState=$adapterState; entryAdapterRequired=$codexHostPresent; includeZCode=$IncludeZCode; adapterCheckCount=@($adapterChecks).Count; adapterFailureCount=@($requiredAdapterFailures).Count; adapterChecks=$adapterChecks; optionalAdapterFailures=@($optionalAdapterFailures | ForEach-Object { [string]$_.name }); fullBrainActive=$axes.activation.fullBrainActive; activation=$axes.activation; turnRuntime=$axes.turnRuntime; retiredTransportGuard=$axes.retiredTransportGuard; mcpBinding=$mcpBinding; mcpExecutionReady=$false; mcpExecutionState='runtime_probe_required'; mcpExecutionProbe='Call registered brain_status and require runtimeIdentity.state=current plus liveMcpHandshake.state=current.'; packageRoot=$Root; memoryRoot=$MemoryRoot; hookPath=''; isolationMode=$isolationMode; checks=$checks; hookChecks=$hookChecks; runtimeChecks=$runtimeChecks; configChecks=$configChecks } | ConvertTo-Json -Depth 8
} else {
  foreach ($check in $checks) { if ($check.ok) { Write-Host "OK $($check.name) - $($check.path)" } else { Write-Host "MISSING $($check.name) - $($check.path) actual=$($check.actual) expected=$($check.expected)" } }
  foreach ($check in $adapterChecks) {
    $prefix = if ($check.optional -eq $true) { 'OPTIONAL adapter' } else { 'ENTRY adapter' }
    if ($check.ok) { Write-Host "OK $prefix $($check.name) - $($check.path)" } elseif ([string]$check.state -eq 'stale') { Write-Host "$prefix stale $($check.name) - $($check.path) source=$($check.sourcePath)" } else { Write-Host "$prefix missing $($check.name) - $($check.path)" }
  }
  foreach ($check in $runtimeChecks) { if ($check.ok) { Write-Host "OK $($check.name)" } else { Write-Host "MISSING $($check.name)" } }
  foreach ($check in $configChecks) { if ($check.ok) { Write-Host "OK $($check.name) - $($check.path)" } else { Write-Host "MISSING $($check.name) - $($check.path)" } }
  $coreFailures = @($checks | Where-Object { $_.ok -ne $true }) + @($runtimeChecks | Where-Object { $_.ok -ne $true })
  if ($coreFailures.Count -eq 0) { Write-Host 'CORE_AVAILABLE' } else { Write-Host 'CORE_WITHHELD' }
  $requiredAdapterFailures = @($adapterChecks | Where-Object { $_.optional -ne $true -and $_.ok -ne $true })
  if (-not $codexHostPresent) { Write-Host 'ENTRY_ADAPTER_NOT_INSTALLED' } elseif ($requiredAdapterFailures.Count -eq 0) { Write-Host 'ENTRY_ADAPTER_READY' } else { Write-Host 'ENTRY_ADAPTER_WITHHELD' }
  Write-Host 'TURN_RUNTIME_HOOKLESS'
  Write-Host "H7_RETIRED_TRANSPORT_GUARD state=$($retiredTransportGuard.state) code=$($retiredTransportGuard.code)"
  Write-Host "ACTIVATION_NOT_EVALUATED_BY_STARTUP state=$activationCode"
  if ($ok) { Write-Host 'STARTUP_CHECK_OK' } else { Write-Host 'STARTUP_CHECK_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0

