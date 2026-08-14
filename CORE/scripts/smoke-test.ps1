param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$Neurobase = ""
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Neurobase)) {
  $Neurobase = Get-SuperBrainSharedMemoryRoot $Root
}

$tmpRoot = Join-Path $Root '.tmp-smoke-test'
if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
$installZ = Join-Path $tmpRoot 'zcode-skills'
$installC = Join-Path $tmpRoot 'codex-skills'
$tmpStateRoot = Join-Path $tmpRoot 'state'
$tmpMemory = Join-Path $tmpStateRoot 'shared'
$tmpArchive = Join-Path $tmpStateRoot 'archive'
$tmpInstallBackups = Join-Path $tmpRoot 'install-backups'

function Get-FileFingerprint([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ exists = $false; sha256 = '' }
  }
  return [pscustomobject]@{
    exists = $true
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Assert-UnchangedFile([string]$Name, [object]$Before, [string]$Path) {
  $after = Get-FileFingerprint $Path
  if ([bool]$Before.exists -ne [bool]$after.exists -or [string]$Before.sha256 -ne [string]$after.sha256) {
    throw "smoke fixture mutated user-scoped file: $Name"
  }
}

# The package has one memory authority per state root: ``stateRoot/shared``.
# A smoke fixture therefore switches the *process-local* state root before
# invoking any installation or health script, instead of passing a retired
# arbitrary ``...\\memory`` override.  Preserve all caller environment values
# and restore them in ``finally`` so this test never mutates the user's live
# Super Brain state or shell configuration.
$savedEnvironment = @{}
foreach ($name in @('SUPER_BRAIN_STATE_ROOT','SUPER_BRAIN_ARCHIVE_ROOT','NEXSANDBASE_HOME','PYTHONPATH')) {
  $entry = Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
  $savedEnvironment[$name] = if ($null -eq $entry) { $null } else { [string]$entry.Value }
}
$env:SUPER_BRAIN_STATE_ROOT = $tmpStateRoot
$env:SUPER_BRAIN_ARCHIVE_ROOT = $tmpArchive

# This fixture is deliberately package-local.  Runtime/MCP registration has a
# separate contract replay and must never be exercised by an installer smoke
# test, even through a temporary Codex root.  Fingerprint the only user-scoped
# entry/config files that this path could accidentally reach so a future route
# regression fails closed without reading or reporting their contents.
$userCodexHome = Join-Path $env:USERPROFILE '.codex'
$userCodexConfigBefore = Get-FileFingerprint (Join-Path $userCodexHome 'config.toml')
$userCodexStartupBefore = Get-FileFingerprint (Join-Path $userCodexHome 'AGENTS.md')

try {
  & (Join-Path $PSScriptRoot 'install.ps1') -ZCodeSkills $installZ -CodexSkills $installC -Neurobase $tmpMemory -Isolated -NoBackup -SkipRuntime -InstallBackupRoot $tmpInstallBackups
  if ($LASTEXITCODE -ne 0) { throw 'smoke install failed' }

  & (Join-Path $PSScriptRoot 'health-check.ps1') -ZCodeSkills $installZ -CodexSkills $installC -MemoryRoot $tmpMemory -Isolated -SkipRuntime
  if ($LASTEXITCODE -ne 0) { throw 'smoke health failed' }

  $statusJson = & (Join-Path $PSScriptRoot 'status.ps1') -ZCodeSkills $installZ -CodexSkills $installC -MemoryRoot $tmpMemory -Isolated -Json
  if ($LASTEXITCODE -ne 0) { throw 'smoke status failed' }
  $statusJson | ConvertFrom-Json | Out-Null

  $env:NEXSANDBASE_HOME = $tmpMemory
  $env:PYTHONPATH = Get-SuperBrainRuntimePythonPath $Root
  python -c "from sandglass_vault import recent; print(recent(1))"
  if ($LASTEXITCODE -ne 0) { throw 'smoke python runtime failed' }

  Assert-UnchangedFile 'Codex config' $userCodexConfigBefore (Join-Path $userCodexHome 'config.toml')
  Assert-UnchangedFile 'Codex bootstrap' $userCodexStartupBefore (Join-Path $userCodexHome 'AGENTS.md')

  Write-Host 'SMOKE_TEST_OK'
} finally {
  foreach ($name in $savedEnvironment.Keys) {
    $path = 'Env:' + $name
    if ($null -eq $savedEnvironment[$name]) {
      Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    } else {
      Set-Item -LiteralPath $path -Value $savedEnvironment[$name]
    }
  }
  if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}
