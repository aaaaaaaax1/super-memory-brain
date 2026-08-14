param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$MemoryRoot = "",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$IncludeZCode,
  [switch]$Isolated,
  [switch]$Json,
  [switch]$DetailedJson
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$MemoryScripts = Get-SuperBrainRuntimePythonPath $Root
$ok = $true
$checks = @()
$adapterChecks = @()

function Add-Check([string]$Name, [string]$Path) {
  $exists = Test-Path $Path
  if (-not $exists) { $script:ok = $false }
  $script:checks += [pscustomobject]@{
    name = $Name
    ok = $exists
    path = $Path
  }
}

# Adapter state has one authority: startup-check.ps1.  Recomputing it here
# previously made a non-existent Codex host look like a broken required entry
# and let status disagree with the startup gate.
Add-Check 'Package memory root' $MemoryRoot
Add-Check 'NexSandglass runtime log' (Join-Path $MemoryScripts 'sandglass_log.py')
Add-Check 'NexSandglass runtime vault' (Join-Path $MemoryScripts 'sandglass_vault.py')

$startupCheck = $null
$startupStrictOk = $false
$startupCoreAvailable = $false
$hookChecks = @()
$runtimeChecks = @()
try {
  # Array splatting turns parameter-looking strings into positional values in
  # Windows PowerShell.  A hashtable preserves the named startup contract.
  $startupArgs = @{
    ZCodeSkills = $ZCodeSkills
    CodexSkills = $CodexSkills
    MemoryRoot = $MemoryRoot
    Json = $true
  }
  if ($IncludeZCode) { $startupArgs.IncludeZCode = $true }
  if ($Isolated) { $startupArgs.Isolated = $true }
  $startupJsonText = (@(& (Join-Path $PSScriptRoot 'startup-check.ps1') @startupArgs 2>&1) -join "`n").Trim()
  $startupCheck = $startupJsonText | ConvertFrom-Json
  $startupStrictOk = if ($startupCheck.PSObject.Properties['strictOk']) { [bool]$startupCheck.strictOk } else { [bool]$startupCheck.ok }
  $startupCoreAvailable = if ($startupCheck.PSObject.Properties['coreAvailable']) { [bool]$startupCheck.coreAvailable } else { [bool]$startupCheck.ok }
  $runtimeChecks = @($startupCheck.runtimeChecks)
  $adapterChecks = @($startupCheck.adapterChecks)
  if (-not $startupCoreAvailable) { $ok = $false }
  if (-not $startupStrictOk) { $ok = $false }
} catch {
  $startupCheck = [pscustomobject]@{ ok = $false; strictOk = $false; coreAvailable = $false; error = $_.Exception.Message }
  $ok = $false
}

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$recentMemoryCount = 0
$recentMemoryOk = $false
$recentMemoryError = ''
try {
  $recentMemoryCountText = python -c "from sandglass_vault import recent; r=recent(3); print(len(r) if hasattr(r, '__len__') else 0)"
  if ($LASTEXITCODE -ne 0) { $ok = $false } else {
    $recentMemoryOk = $true
    $recentMemoryCount = [int](([string]$recentMemoryCountText).Trim())
  }
} catch {
  $recentMemoryError = $_.Exception.Message
  $ok = $false
}

$bindingPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'session-binding.json'
$sessionBinding = $null
if (Test-Path $bindingPath) {
  try {
    $binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expired = $true
    try { $expired = ([datetime]::Parse([string]$binding.expiresAt) -lt (Get-Date)) } catch {}
    $sessionBinding = [pscustomObject]@{
      exists = $true
      active = ([string]$binding.status -eq 'active' -and -not $expired -and [string]$binding.packageVersion -eq [string](Get-SuperBrainManifest $Root).version -and (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $MemoryRoot))
      status = $binding.status
      bindingId = $binding.bindingId
      sessionId = $binding.sessionId
      taskId = $binding.taskId
      expiresAt = $binding.expiresAt
      expired = $expired
      packageVersion = $binding.packageVersion
      packageVersionMatch = ([string]$binding.packageVersion -eq [string](Get-SuperBrainManifest $Root).version)
      memoryRootMatch = (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $MemoryRoot)
      path = $bindingPath
    }
  } catch { $sessionBinding = [pscustomobject]@{ exists=$true; active=$false; status='parse_failed'; error=$_.Exception.Message; path=$bindingPath } }
} else { $sessionBinding = [pscustomobject]@{ exists=$false; active=$false; status='missing'; path=$bindingPath } }

$coreAvailable = [bool]($startupCoreAvailable -and $recentMemoryOk)
$adapterFailures = @($adapterChecks | Where-Object { $_.optional -ne $true -and $_.ok -ne $true })
$adapterAvailable = if ($startupCheck -and $startupCheck.PSObject.Properties['adapterAvailable']) { [bool]$startupCheck.adapterAvailable } else { ($adapterFailures.Count -eq 0) }
$adapterState = if ($startupCheck -and $startupCheck.PSObject.Properties['adapterState']) { [string]$startupCheck.adapterState } elseif ($adapterAvailable) { 'ready' } else { 'withheld' }
$retiredTransportGuard = if ($startupCheck -and $startupCheck.PSObject.Properties['retiredTransportGuard']) {
  $startupCheck.retiredTransportGuard
} else {
  [pscustomobject]@{
    schema='super-brain.retired-transport-guard.v1'
    state='unknown'
    code='H7_RETIRED_TRANSPORT_GUARD_UNAVAILABLE'
    requiredForCore=$true
    h7Transport=[pscustomobject]@{ mode='hookless_turn_runtime'; primary='mcp'; fallback='same_h7_cli'; entryAvailable=$false }
    superBrainHookRegistration=[pscustomobject]@{ state='unverifiable'; registered=$null; configurationReadable=$false }
    actionAuthorization='not_authorizing'
    legacyDependency='none'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }
}
$turnRuntime = if ($startupCheck -and $startupCheck.PSObject.Properties['turnRuntime']) { $startupCheck.turnRuntime } else { [pscustomobject]@{ available=$false; state='unknown'; mode=''; requiredForCore=$true } }

if ($Json -or $DetailedJson) {
  if ($DetailedJson) {
    [pscustomobject]@{
      ok = $ok
      coreAvailable = $coreAvailable
      turnRuntime = $turnRuntime
      retiredTransportGuard = $retiredTransportGuard
      packageRoot = $Root
      memoryRoot = $MemoryRoot
      checks = $checks
      adapterChecks = $adapterChecks
      adapterAvailable = $adapterAvailable
      adapterState = $adapterState
      hookChecks = $hookChecks
      runtimeChecks = $runtimeChecks
      startupCheck = $startupCheck
      sessionBinding = $sessionBinding
      recentMemory = [pscustomobject]@{ ok=$recentMemoryOk; count=$recentMemoryCount; rawSuppressed=$true; error=$recentMemoryError }
    } | ConvertTo-Json -Depth 5
  } else {
    $failedChecks = @($checks | Where-Object { $_.ok -ne $true } | Select-Object -First 8 | ForEach-Object { [string]$_.name })
    $failedRuntimeChecks = @($runtimeChecks | Where-Object { $_.ok -ne $true } | Select-Object -First 8 | ForEach-Object { [string]$_.name })
    [pscustomobject]@{
      ok = $ok
      coreAvailable = $coreAvailable
      turnRuntime = $turnRuntime
      retiredTransportGuard = $retiredTransportGuard
      packageRoot = $Root
      memoryRoot = $MemoryRoot
      checkCount = @($checks).Count
      failedCheckCount = $failedChecks.Count
      failedChecks = @($failedChecks)
      adapterCheckCount = @($adapterChecks).Count
      adapterFailureCount = @($adapterFailures).Count
      adapterState = $adapterState
      hookCheckCount = 0
      failedHookCheckCount = 0
      failedHookChecks = @()
      runtimeCheckCount = @($runtimeChecks).Count
      failedRuntimeCheckCount = $failedRuntimeChecks.Count
      failedRuntimeChecks = @($failedRuntimeChecks)
      startupOk = if ($startupCheck) { $startupCheck.ok } else { $null }
      startupStrictOk = $startupStrictOk
      sessionBinding = [pscustomobject]@{ exists=$sessionBinding.exists; active=$sessionBinding.active; status=$sessionBinding.status; path=$sessionBinding.path }
      recentMemory = [pscustomobject]@{ ok=$recentMemoryOk; count=$recentMemoryCount; rawSuppressed=$true; error=$recentMemoryError }
      detail = 'Use -DetailedJson for full checks.'
    } | ConvertTo-Json -Depth 5
  }
} else {
  foreach ($check in $checks) {
    if ($check.ok) { Write-Host "$($check.name): OK - $($check.path)" } else { Write-Host "$($check.name): MISSING - $($check.path)" }
  }
  foreach ($check in $runtimeChecks) {
    if ($check.ok) { Write-Host "$($check.name): OK" } else { Write-Host "$($check.name): MISSING" }
  }
  foreach ($check in $adapterChecks) {
    $prefix = if ($check.optional -eq $true) { 'OPTIONAL adapter' } else { 'ENTRY adapter' }
    if ($check.ok) { Write-Host "$prefix $($check.name): OK - $($check.path)" } elseif ([string]$check.state -eq 'stale') { Write-Host "$prefix stale $($check.name) - $($check.path)" } else { Write-Host "$prefix missing $($check.name) - $($check.path)" }
  }
  if ($startupStrictOk) { Write-Host 'Startup core check: OK' } else { Write-Host 'Startup core check: withheld' }
  Write-Host "Core available: $coreAvailable"
  Write-Host "Turn Runtime: $($turnRuntime.state)"
  Write-Host "H7 retired transport guard: state=$($retiredTransportGuard.state) code=$($retiredTransportGuard.code)"
  if ($sessionBinding.exists) { Write-Host "Session binding: status=$($sessionBinding.status) active=$($sessionBinding.active) expiresAt=$($sessionBinding.expiresAt) path=$($sessionBinding.path)" } else { Write-Host "Session binding: missing path=$($sessionBinding.path)" }
	  Write-Host "Recent memory: count=$recentMemoryCount rawSuppressed=True"
  if ($ok) { Write-Host 'STATUS_OK' } else { Write-Host 'STATUS_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0
