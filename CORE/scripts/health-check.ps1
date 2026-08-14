param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$MemoryRoot = "",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$HookPath = "",
  [switch]$IncludeZCode,
  [switch]$Isolated,
  [switch]$SkipRuntime
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$MemoryScripts = Get-SuperBrainRuntimePythonPath $Root
$codexHome = [IO.Path]::GetFullPath((Split-Path -Parent $CodexSkills))
$ok = $true

function Check-Path([string]$Path) {
  if (Test-Path $Path) { Write-Host "OK $Path" } else { Write-Host "MISSING $Path"; $script:ok = $false }
}

$paths = @(
  (Join-Path $MemoryScripts 'sandglass_log.py'),
  (Join-Path $MemoryScripts 'sandglass_vault.py'),
  (Join-Path $MemoryScripts 'sandglass_mcp.py')
)
foreach ($path in $paths) { Check-Path $path }

$startupArguments = @{
  ZCodeSkills = $ZCodeSkills
  CodexSkills = $CodexSkills
  MemoryRoot = $MemoryRoot
  Json = $true
}
if (-not [string]::IsNullOrWhiteSpace($HookPath)) { $startupArguments.HookPath = $HookPath }
if ($IncludeZCode) { $startupArguments.IncludeZCode = $true }
if ($Isolated) { $startupArguments.Isolated = $true }
$startupJsonText = (@(& (Join-Path $PSScriptRoot 'startup-check.ps1') @startupArguments 2>&1) -join "`n").Trim()
$startupCheck = $null
try {
  $startupCheck = $startupJsonText | ConvertFrom-Json
  $startupCoreAvailable = if ($startupCheck.PSObject.Properties['coreAvailable']) { [bool]$startupCheck.coreAvailable } else { [bool]$startupCheck.ok }
  if (-not $startupCoreAvailable) {
    Write-Host 'MISSING core startup readiness'
    $ok = $false
  } elseif (-not $startupCheck.retiredTransportGuard -or [string]$startupCheck.retiredTransportGuard.state -ne 'ready') {
    $guardCode = if ($startupCheck.retiredTransportGuard) { [string]$startupCheck.retiredTransportGuard.code } else { 'H7_RETIRED_TRANSPORT_GUARD_UNAVAILABLE' }
    Write-Host "MISSING H7 retired transport guard code=$guardCode"
    $ok = $false
  } else {
    Write-Host "OK H7 retired transport guard code=$($startupCheck.retiredTransportGuard.code)"
  }
  $adapterState = if ($startupCheck.PSObject.Properties['adapterState']) { [string]$startupCheck.adapterState } else { '' }
  if ($adapterState -eq 'ready') {
    Write-Host 'OK Codex primary entry adapter'
  } elseif ($adapterState -eq 'not_installed') {
    Write-Host 'ENTRY_ADAPTER_NOT_INSTALLED'
  } else {
    $entryFailures = @($startupCheck.adapterChecks | Where-Object { $_.optional -ne $true -and $_.ok -ne $true } | ForEach-Object { [string]$_.name })
    Write-Host "MISSING Codex primary entry adapter state=$adapterState checks=$($entryFailures -join ',')"
    $ok = $false
  }
} catch {
  Write-Host "MISSING core startup readiness: $($_.Exception.Message)"
  $ok = $false
}

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$recentCount = 0
try {
  $recentCountText = python -c "from sandglass_vault import recent; r=recent(3); print(len(r) if hasattr(r, '__len__') else 0)"
  if ($LASTEXITCODE -ne 0) { Write-Host 'MISSING NexSandglass python runtime'; $ok = $false } else {
    $recentCount = [int](([string]$recentCountText).Trim())
    Write-Host "OK NexSandglass recent count=$recentCount rawSuppressed=True"
  }
} catch {
  Write-Host "MISSING NexSandglass python runtime: $($_.Exception.Message)"
  $ok = $false
}

if (-not $SkipRuntime) {
  & (Join-Path $PSScriptRoot 'runtime-status.ps1') -CodexHome $codexHome -MemoryRoot $MemoryRoot
  if ($LASTEXITCODE -ne 0) { Write-Host 'MISSING local runtime/MCP registration'; $ok = $false }
}

if ($ok) { Write-Host 'HEALTH_CHECK_OK' } else { Write-Host 'HEALTH_CHECK_FAILED'; exit 1 }
