param(
  [string[]]$SkillRoots = @(),
  [switch]$AllKnown,
  [switch]$NoBackup,
  [string[]]$Extensions = @(),
  [switch]$ReportOnly,
  [switch]$DryRun,
  [string[]]$SkillNames = @(),
  [switch]$SkipGlobalStartup,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$StatusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-hot-refresh.json'
$ManifestPath = Join-Path $Root 'manifest.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$PackageVersion = [string]$Manifest.version
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
  $seedRoots = @(
    Join-Path $env:USERPROFILE '.zcode\skills'
    Join-Path $env:USERPROFILE '.codex\skills'
  )
  return @(Get-SuperBrainInstalledSkillRoots -SeedRoots $seedRoots -Root $Root)
}

function Test-InstalledForCurrentPackage([string]$SkillDir) {
  $marker = Join-Path $SkillDir 'package-root.txt'
  if (-not (Test-Path $marker)) { return $false }
  try {
    $actual = ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)).Trim()
    return ((Get-NormalizedSuperBrainRoot $actual) -eq (Get-NormalizedSuperBrainRoot $Root))
  } catch {
    return $false
  }
}

function Get-MemoryRootForSkill([string]$SkillDir) {
  $existing = Read-SuperBrainMemoryRootMarker $SkillDir
  if (-not [string]::IsNullOrWhiteSpace($existing)) { return $existing }
  return Get-SuperBrainSharedMemoryRoot $Root
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
  $items = @(Get-SuperBrainSourceItems $ExtensionPaths)
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
  if (-not (Test-InstalledForCurrentPackage $dest)) {
    Add-Result $SkillRoot $Item.name $false 'installed skill does not point to current package-root.txt' 'validate-skill' $source $dest
    return
  }

  $memoryRoot = Get-MemoryRootForSkill $dest
  $sourceInfo = Get-SkillMdInfo $source
  $destInfo = Get-SkillMdInfo $dest
  $wouldChange = ($sourceInfo.sha256 -ne $destInfo.sha256)
  $extra = [pscustomobject]@{
    memoryRoot = $memoryRoot
    sourceSkillMd = $sourceInfo.path
    destinationSkillMd = $destInfo.path
    sourceBytes = $sourceInfo.bytes
    destinationBytes = $destInfo.bytes
    sourceSha256 = $sourceInfo.sha256
    destinationSha256 = $destInfo.sha256
    wouldChange = $wouldChange
  }

  if ($ReportOnlyMode) {
    Add-Result $SkillRoot $Item.name $true "would refresh memory=$memoryRoot" 'report-skill' $source $dest $extra
    Write-Log "HOT_REFRESH_REPORT_SKILL version=$PackageVersion root=$SkillRoot skill=$($Item.name) wouldChange=$wouldChange"
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
  Add-Result $SkillRoot $Item.name $true "refreshed memory=$memoryRoot" 'refresh-skill' $source $dest $extra
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

try {
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
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    skillNames = @($SkillNames)
    skipGlobalStartup = [bool]$SkipGlobalStartup
    results = $results
    note = $(if ($ReportOnlyMode) {
      'Report-only mode does not copy skills, write markers, initialize memory runtime, write status JSON, or update global startup.'
    } else {
      'Hot refresh scans installed Super Brain agent skill roots, updates selected skill files, package/memory root markers, memory runtime files, and unless skipped each agent global startup bootstrap; open a new agent session if the agent caches skill content.'
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
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    error = $_.Exception.Message
    skillNames = @($SkillNames)
    skipGlobalStartup = [bool]$SkipGlobalStartup
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
