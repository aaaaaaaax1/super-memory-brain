param(
  [string[]]$SkillRoots = @(),
  [switch]$AllKnown,
  [switch]$NoBackup,
  [switch]$IncludeZCode,
  [string[]]$Extensions = @(),
  [switch]$ReportOnly,
  [switch]$DryRun,
  [string[]]$SkillNames = @(),
  [switch]$RebindPackageRoot,
  [switch]$SkipGlobalStartup,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$StatusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-hot-refresh.json'
$RuntimeInstallPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-runtime-install.json'
$RuntimeBindingPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'runtime-state\mcp-runtime-binding.json'
$ManifestPath = Join-Path $Root 'manifest.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$PackageVersion = [string]$Manifest.version
$McpRuntimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installBackupRoot = Get-SuperBrainInstallBackupRoot $Root
$results = @()
$ok = $true
$ReportOnlyMode = ($ReportOnly -or $DryRun)

function Write-Log([string]$Message) {
  if (-not $Json) { Write-Host $Message }
}

function Add-Result(
  [string]$SkillRoot,
  [string]$SkillName,
  [bool]$Success,
  [string]$Message,
  [string]$Action = '',
  [string]$Source = '',
  [string]$Destination = '',
  [object]$Extra = $null
) {
  $entry = [ordered]@{
    skillRoot = $SkillRoot
    skillName = $SkillName
    ok = $Success
    action = $Action
    message = $Message
    source = $Source
    destination = $Destination
  }
  if ($null -ne $Extra) {
    foreach ($prop in $Extra.PSObject.Properties) {
      $entry[$prop.Name] = $prop.Value
    }
  }
  $script:results += [pscustomobject]$entry
  if (-not $Success) { $script:ok = $false }
}

function Get-KnownSkillRoots {
  $seedRoots = @(Join-Path $env:USERPROFILE '.codex\skills')
  if ($IncludeZCode) { $seedRoots += (Join-Path $env:USERPROFILE '.zcode\skills') }
  return @(Get-SuperBrainInstalledSkillRoots -SeedRoots $seedRoots -Root $Root)
}

function Get-InstalledPackageRootState([string]$SkillDir) {
  $marker = Join-Path $SkillDir 'package-root.txt'
  if (-not (Test-Path $marker)) {
    return [pscustomobject]@{ current=$false; rebindEligible=$false; actual=''; marker=$marker; code='package_root_marker_missing' }
  }
  try {
    $actual = ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)).Trim()
    $current = (Get-NormalizedSuperBrainRoot $actual) -eq (Get-NormalizedSuperBrainRoot $Root)
    # A one-time CORE migration leaves the marker at this package's outer
    # workspace root. Only that exact stale-root form may be explicitly rebound.
    $legacyWorkspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root
    $rebindEligible = (-not $current) -and (Test-SuperBrainSamePath $actual $legacyWorkspaceRoot)
    return [pscustomobject]@{ current=$current; rebindEligible=$rebindEligible; actual=$actual; marker=$marker; code=if($current){'package_root_current'}elseif($rebindEligible){'core_migration_rebind_eligible'}else{'package_root_foreign'} }
  } catch {
    return [pscustomobject]@{ current=$false; rebindEligible=$false; actual=''; marker=$marker; code='package_root_marker_invalid' }
  }
}

function Get-MemoryRootForSkill([string]$SkillDir) {
  # Installed markers are outputs, never root-selection inputs.  An old marker
  # may identify migration evidence, but hot refresh always rewrites it to the
  # package's one current stateRoot/shared authority.
  return Get-SuperBrainActiveMemoryRoot $Root
}

function Get-SkillMdInfo([string]$SkillDir) {
  $path = Join-Path $SkillDir 'SKILL.md'
  if (-not (Test-Path -LiteralPath $path)) {
    return [pscustomobject]@{ path = $path; exists = $false; bytes = $null; sha256 = $null }
  }
  $item = Get-Item -LiteralPath $path
  return [pscustomobject]@{
    path = $path
    exists = $true
    bytes = $item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  }
}

function Select-SourceItems([string[]]$Names, [string[]]$ExtensionPaths) {
  $requestedExtensions = @($ExtensionPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($requestedExtensions.Count -gt 0) {
    $message = 'ABSORBED_PROVENANCE_ONLY_NO_STANDALONE_INSTALL: -Extensions selects package-owned cold provenance only, not host skills. Requested: ' + ($requestedExtensions -join ', ') + '. Refresh super-memory-brain without -Extensions.'
    Add-Result '' '' $false $message 'reject-extension-host-selector' ($requestedExtensions -join ', ')
    throw $message
  }

  $items = @(Get-SuperBrainHostAdapterItems)
  if ($Names.Count -eq 0) { return @($items) }

  $byName = @{}
  foreach ($item in $items) {
    $byName[([string]$item.name).ToLowerInvariant()] = $item
  }

  $missing = @()
  $selected = @()
  $seen = @{}
  foreach ($name in $Names) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = $name.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (-not $byName.ContainsKey($key)) {
      $missing += $name
      continue
    }
    $selected += $byName[$key]
  }

  if ($missing.Count -gt 0) {
    $message = 'Unknown SkillNames: ' + ($missing -join ', ')
    Add-Result '' '' $false $message 'validate-skill-names'
    throw $message
  }

  return @($selected)
}

function Refresh-MemoryRuntime([string]$MemoryRoot, [string]$Scope, [string[]]$Members) {
  if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { return }
  if ($ReportOnlyMode) { return }
  $MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'hot-refresh-memory-runtime'
  Initialize-SuperBrainMemoryRoot $MemoryRoot $Root $Scope $Members
  Write-Log "HOT_REFRESH_MEMORY_OK version=$PackageVersion memory=$MemoryRoot scope=$Scope"
}

function Refresh-Skill([string]$SkillRoot, [object]$Item) {
  $source = Join-Path $Root $Item.source
  $dest = Join-Path $SkillRoot $Item.name
  if (-not (Test-Path $dest)) {
    Add-Result $SkillRoot $Item.name $false 'missing installed skill directory' 'validate-skill' $source $dest
    return
  }
  $packageRootState = Get-InstalledPackageRootState $dest
  $packageRootRebound = $false
  if (-not $packageRootState.current) {
    if (-not $RebindPackageRoot) {
      Add-Result $SkillRoot $Item.name $false 'installed skill does not point to current package-root.txt' 'validate-skill' $source $dest ([pscustomobject]@{ packageRootState=$packageRootState.code; priorPackageRoot=$packageRootState.actual; rebindRequiresExplicitApproval=$true })
      return
    }
    if (-not $packageRootState.rebindEligible) {
      Add-Result $SkillRoot $Item.name $false 'installed skill package-root.txt is not an eligible pre-CORE workspace root' 'validate-skill' $source $dest ([pscustomobject]@{ packageRootState=$packageRootState.code; priorPackageRoot=$packageRootState.actual; rebindRequiresExplicitApproval=$true })
      return
    }
    $packageRootRebound = $true
  }
  if (-not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
    Add-Result $SkillRoot $Item.name $false 'installed skill is missing SKILL.md' 'validate-skill' $source $dest
    return
  }

  $memoryRoot = Get-MemoryRootForSkill $dest
  $sourceInfo = Get-SkillMdInfo $source
  $destInfo = Get-SkillMdInfo $dest
  $wouldChange = ($sourceInfo.sha256 -ne $destInfo.sha256)
  $reportExtra = [pscustomobject]@{
    memoryRoot = $memoryRoot
    sourceSkillMd = $sourceInfo.path
    destinationSkillMd = $destInfo.path
    sourceBytes = $sourceInfo.bytes
    destinationBytes = $destInfo.bytes
    sourceSha256 = $sourceInfo.sha256
    destinationSha256 = $destInfo.sha256
    wouldChange = $wouldChange
    packageRootRebound = $packageRootRebound
    priorPackageRoot = [string]$packageRootState.actual
  }

  if ($ReportOnlyMode) {
    $reportMessage = if ($packageRootRebound) { "would rebind package root and refresh memory=$memoryRoot" } else { "would refresh memory=$memoryRoot" }
    Add-Result $SkillRoot $Item.name $true $reportMessage 'report-skill' $source $dest $reportExtra
    Write-Log "HOT_REFRESH_REPORT_SKILL version=$PackageVersion root=$SkillRoot skill=$($Item.name) wouldChange=$wouldChange packageRootRebound=$packageRootRebound"
    return
  }

  Refresh-MemoryRuntime $memoryRoot 'hot-refresh' @($Item.name)
  if (-not $NoBackup) {
    $backup = Join-Path $installBackupRoot ("install-backup-$timestamp\hot-refresh\$($SkillRoot -replace '[:\\/ ]','_')\$($Item.name)")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
  }
  Remove-Item -LiteralPath $dest -Recurse -Force
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
  Write-SuperBrainPackageRootMarker $dest $Root
  Write-SuperBrainMemoryRootMarker $dest $memoryRoot
  $appliedDestInfo = Get-SkillMdInfo $dest
  $appliedExtra = [pscustomobject]@{
    memoryRoot = $memoryRoot
    sourceSkillMd = $sourceInfo.path
    destinationSkillMd = $appliedDestInfo.path
    sourceBytes = $sourceInfo.bytes
    destinationBytes = $appliedDestInfo.bytes
    sourceSha256 = $sourceInfo.sha256
    destinationSha256 = $appliedDestInfo.sha256
    changed = $wouldChange
    wouldChange = $false
    packageRootRebound = $packageRootRebound
    priorPackageRoot = [string]$packageRootState.actual
  }
  Add-Result $SkillRoot $Item.name $true "refreshed memory=$memoryRoot" 'refresh-skill' $source $dest $appliedExtra
  Write-Log "HOT_REFRESH_SKILL_OK version=$PackageVersion root=$SkillRoot skill=$($Item.name) memory=$memoryRoot"
}

function Refresh-GlobalStartup([string]$SkillRoot) {
  $targets = @(Get-SuperBrainGlobalStartupTargets $SkillRoot)
  $extra = [pscustomobject]@{ targets = @($targets) }

  if ($SkipGlobalStartup) {
    Add-Result $SkillRoot '__global_startup__' $true 'skipped by -SkipGlobalStartup' 'skip-global-startup' '' '' $extra
    Write-Log "HOT_REFRESH_GLOBAL_STARTUP_SKIPPED root=$SkillRoot reason=SkipGlobalStartup"
    return
  }

  if ($ReportOnlyMode) {
    Add-Result $SkillRoot '__global_startup__' $true 'would write global startup targets' 'report-global-startup' '' '' $extra
    foreach ($path in $targets) {
      Write-Log "HOT_REFRESH_REPORT_GLOBAL_STARTUP root=$SkillRoot path=$path"
    }
    return
  }

  foreach ($path in @(Write-SuperBrainGlobalStartup $SkillRoot $Root -NoBackup:$NoBackup)) {
    Write-Log "HOT_REFRESH_GLOBAL_STARTUP_OK root=$SkillRoot path=$path"
  }
}

function Write-Status([object]$Status) {
  if (-not $ReportOnlyMode) {
    Write-JsonUtf8NoBom $StatusPath $Status 8
  }

  if ($Json) {
    $Status | ConvertTo-Json -Depth 10
    return
  }

  if ($ReportOnlyMode) {
    if ($Status.ok) {
      Write-Host "HOT_REFRESH_REPORT_OK version=$PackageVersion"
    } else {
      Write-Host "HOT_REFRESH_REPORT_PARTIAL version=$PackageVersion"
    }
    return
  }

  if ($Status.ok) {
    Write-Host "HOT_REFRESH_OK version=$PackageVersion status=$StatusPath"
  } else {
    Write-Host "HOT_REFRESH_PARTIAL version=$PackageVersion status=$StatusPath"
  }
}

function Read-RefreshJson([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

try {
  $runtimeInstall = Read-RefreshJson $RuntimeInstallPath
  $runtimeBinding = Read-RefreshJson $RuntimeBindingPath
  $mcpRebindRequired = (
    -not $runtimeInstall -or
    [string]$runtimeInstall.runtimeIdentity -ne $McpRuntimeIdentity -or
    -not $runtimeBinding -or
    [string]$runtimeBinding.schema -ne 'super-brain.mcp-runtime-binding.v1' -or
    [string]$runtimeBinding.runtimeIdentity -ne $McpRuntimeIdentity -or
    [string]$runtimeBinding.state -ne 'current'
  )
  $mcpRebindState = if ($mcpRebindRequired) { 'required' } else { 'current' }
  $roots = @($SkillRoots)
  if ($roots.Count -eq 0 -or $AllKnown) { $roots += Get-KnownSkillRoots }
  $roots = @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($roots.Count -eq 0) { throw 'No skill roots specified or detected.' }

  $sourceItems = @(Select-SourceItems $SkillNames $Extensions)
  if ($sourceItems.Count -eq 0) { throw 'No source items selected.' }

  foreach ($skillRoot in $roots) {
    if (-not (Test-Path $skillRoot)) {
      Add-Result $skillRoot '' $false 'skill root missing' 'validate-root'
      continue
    }
    foreach ($item in $sourceItems) {
      Refresh-Skill $skillRoot $item
    }
    Refresh-GlobalStartup $skillRoot
  }

  $status = [pscustomobject]@{
    ok = $ok
    mode = $(if ($ReportOnlyMode) { 'report-only' } else { 'apply' })
    packageRoot = $Root
    version = $PackageVersion
    checkedAt = Get-SuperBrainUtcTimestamp
    skillNames = @($SkillNames)
    rebindPackageRoot = [bool]$RebindPackageRoot
    skipGlobalStartup = [bool]$SkipGlobalStartup
    includeZCode = [bool]$IncludeZCode
    mcpRuntimeIdentity = $McpRuntimeIdentity
    mcpRebindRequired = [bool]$mcpRebindRequired
    mcpRebindState = $mcpRebindState
    results = $results
    note = $(if ($ReportOnlyMode) {
      'Report-only mode does not copy skills, write markers, initialize memory runtime, write status JSON, or update global startup.'
    } else {
      'Hot refresh scans installed Super Brain agent skill roots, updates selected skill files, package/memory root markers, memory runtime files, and unless skipped each agent global startup bootstrap. It never re-registers the global MCP; mcpRebindRequired means run the separately approved runtime install and restart Codex for a live handshake.'
    })
  }
  Write-Status $status
  if (-not $ok) { exit 1 }
} catch {
  $status = [pscustomobject]@{
    ok = $false
    mode = $(if ($ReportOnlyMode) { 'report-only' } else { 'apply' })
    packageRoot = $Root
    version = $PackageVersion
    checkedAt = Get-SuperBrainUtcTimestamp
    error = $_.Exception.Message
    skillNames = @($SkillNames)
    rebindPackageRoot = [bool]$RebindPackageRoot
    skipGlobalStartup = [bool]$SkipGlobalStartup
    includeZCode = [bool]$IncludeZCode
    mcpRuntimeIdentity = $McpRuntimeIdentity
    mcpRebindRequired = $true
    mcpRebindState = 'unknown_due_to_refresh_failure'
    results = $results
  }
  if (-not $ReportOnlyMode) {
    Write-JsonUtf8NoBom $StatusPath $status 8
  }
  if ($Json) {
    $status | ConvertTo-Json -Depth 10
  } elseif ($ReportOnlyMode) {
    Write-Host "HOT_REFRESH_REPORT_FAILED version=$PackageVersion error=$($_.Exception.Message)"
  } else {
    Write-Host "HOT_REFRESH_FAILED version=$PackageVersion error=$($_.Exception.Message)"
  }
  exit 1
}
