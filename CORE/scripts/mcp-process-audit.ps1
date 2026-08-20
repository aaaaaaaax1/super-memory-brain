[CmdletBinding(PositionalBinding=$false)]
param(
  # This command is intentionally diagnostic-only.  It inspects process
  # metadata and never changes configuration, starts a worker, or terminates
  # a process.  PackageRoot is explicit so an audit can be run for an
  # isolated checkout without relying on the caller's current directory.
  [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
  [ValidateRange(0,86400)][int]$OrphanAfterSeconds = 300,
  # Tests and restricted environments may provide a bounded process snapshot.
  # This is an input fixture only; no state is written by the command.
  [string]$ProcessRecordsJson = '',
  [string]$ProcessRecordsPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$schema = 'super-brain.mcp-process-audit.v1'
$checkedAt = [DateTime]::UtcNow

function Normalize-PathText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  try {
    return ([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Value))).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)).ToLowerInvariant()
  } catch {
    return $Value.Trim().Replace('/','\').TrimEnd('\').ToLowerInvariant()
  }
}

function Convert-ToInt64OrNull([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [Int64]$Value } catch { return $null }
}

function Convert-ToDateTimeUtc([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
  $text = [string]$Value
  # Win32 CIM/DMTF creation dates are yyyyMMddHHmmss.ffffff+000.  Parse the
  # stable first fourteen fields and keep the result conservative (local
  # machine offset is applied only when the DMTF suffix provides one).
  if ($text -match '^(?<date>\d{14})(?:\.\d+)?(?<offset>[+-]\d{3})?') {
    try {
      $base = [DateTime]::ParseExact($Matches.date,'yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal)
      if ($Matches.offset -and $Matches.offset -ne '+000') {
        $minutes = [int]$Matches.offset.Substring(1,3)
        if ($Matches.offset.StartsWith('-')) { $minutes = -$minutes }
        return ([DateTimeOffset]::new($base,[TimeSpan]::FromMinutes($minutes))).UtcDateTime
      }
      return $base.ToUniversalTime()
    } catch { return $null }
  }
  try { return ([DateTimeOffset]::Parse($text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal)).UtcDateTime } catch { return $null }
}

function Get-CommandLine([object]$Record) {
  foreach ($name in @('commandLine','CommandLine','cmdline','CmdLine')) {
    if ($Record.PSObject.Properties[$name]) { return [string]$Record.$name }
  }
  return ''
}

function Get-Field([object]$Record,[string[]]$Names) {
  foreach ($name in $Names) {
    if ($Record.PSObject.Properties[$name]) { return $Record.$name }
  }
  return $null
}

function Get-ProcessRecords {
  param([string]$FixtureJson)
  if (-not [string]::IsNullOrWhiteSpace($FixtureJson)) {
    try {
      $parsed = $FixtureJson | ConvertFrom-Json
      if ($parsed -is [System.Array]) { return [pscustomobject]@{ available=$true; method='fixture'; records=@($parsed); error='' } }
      if ($parsed -and $parsed.PSObject.Properties['records']) { return [pscustomobject]@{ available=$true; method='fixture'; records=@($parsed.records); error='' } }
      # ConvertFrom-Json returns one PSCustomObject (rather than an array)
      # when a fixture contains exactly one process record.
      if ($parsed -and ($parsed.PSObject.Properties['processId'] -or $parsed.PSObject.Properties['ProcessId'] -or $parsed.PSObject.Properties['pid'] -or $parsed.PSObject.Properties['Pid'])) {
        return [pscustomobject]@{ available=$true; method='fixture'; records=@($parsed); error='' }
      }
      return [pscustomobject]@{ available=$false; method='fixture'; records=@(); error='MCP_PROCESS_AUDIT_FIXTURE_INVALID' }
    } catch {
      return [pscustomobject]@{ available=$false; method='fixture'; records=@(); error='MCP_PROCESS_AUDIT_FIXTURE_INVALID' }
    }
  }

  # Win32_Process supplies parent PID, command line, creation time, and
  # memory counters in one read-only query.  A WMI fallback keeps the audit
  # usable on older Windows PowerShell installations.
  try {
    $items = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    return [pscustomobject]@{ available=$true; method='Win32_Process'; records=$items; error='' }
  } catch {
    try {
      $items = @(Get-WmiObject -Class Win32_Process -ErrorAction Stop)
      return [pscustomobject]@{ available=$true; method='Win32_Process_WMI'; records=$items; error='' }
    } catch {
      return [pscustomobject]@{ available=$false; method='unavailable'; records=@(); error='MCP_PROCESS_AUDIT_PROCESS_QUERY_UNAVAILABLE' }
    }
  }
}

function Extract-PackageRoot([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
  # Registration passes --package-root as a separate argument.  Support both
  # quoted and unquoted values while avoiding arbitrary command-line parsing.
  $match = [regex]::Match($CommandLine,'(?i)(?:^|\s)--package-root(?:=|\s+)(?:"([^"]+)"|''([^'']+)''|([^\s]+))')
  if (-not $match.Success) { return '' }
  foreach ($index in 1..3) { if (-not [string]::IsNullOrWhiteSpace($match.Groups[$index].Value)) { return $match.Groups[$index].Value } }
  return ''
}

function Test-PathInRoot([string]$Path,[string]$Root) {
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
  $normalized = Normalize-PathText $Path
  return ($normalized -eq $Root -or $normalized.StartsWith($Root + '\'))
}

$normalizedRoot = Normalize-PathText $PackageRoot
$entryName = 'brain_mcp.py'
$fixtureText = $ProcessRecordsJson
if ([string]::IsNullOrWhiteSpace($fixtureText) -and -not [string]::IsNullOrWhiteSpace($ProcessRecordsPath)) {
  try { $fixtureText = Get-Content -LiteralPath $ProcessRecordsPath -Raw -Encoding UTF8 } catch { $fixtureText = '' }
}
$collection = Get-ProcessRecords $fixtureText
$allRecords = @($collection.records)
$byPid = @{}
foreach ($record in $allRecords) {
  $pidValue = Convert-ToInt64OrNull (Get-Field $record @('processId','ProcessId','pid','Pid','Id'))
  if ($null -ne $pidValue -and $pidValue -gt 0) { $byPid[[string]$pidValue] = $record }
}

$candidates = @()
foreach ($record in $allRecords) {
  $pidValue = Convert-ToInt64OrNull (Get-Field $record @('processId','ProcessId','pid','Pid','Id'))
  if ($null -eq $pidValue -or $pidValue -le 0) { continue }
  $parentValue = Convert-ToInt64OrNull (Get-Field $record @('parentProcessId','ParentProcessId','parentPid','ParentPid'))
  $name = [string](Get-Field $record @('name','Name','processName','ProcessName'))
  $commandLine = Get-CommandLine $record
  $executable = [string](Get-Field $record @('executablePath','ExecutablePath','path','Path'))
  $entryMatch = ($commandLine -match '(?i)(^|[\\/\s"''])brain_mcp\.py(?:[\s"'']|$)' -or $executable -match '(?i)[\\/]brain_mcp\.py$')
  if (-not $entryMatch) { continue }

  $argumentRootRaw = Extract-PackageRoot $commandLine
  $argumentRoot = Normalize-PathText $argumentRootRaw
  $entryInCurrentRoot = (Test-PathInRoot $executable $normalizedRoot)
  $commandMentionsCurrentRoot = (-not [string]::IsNullOrWhiteSpace($normalizedRoot) -and (Normalize-PathText $commandLine).Contains($normalizedRoot))
  $isCurrentPackage = ($argumentRoot -eq $normalizedRoot -or $entryInCurrentRoot -or $commandMentionsCurrentRoot)
  $scope = if ($isCurrentPackage) { 'current_package' } elseif ($argumentRoot) { 'foreign_package' } else { 'unknown_package' }

  $start = Convert-ToDateTimeUtc (Get-Field $record @('creationDate','CreationDate','startTime','StartTime','createdAt','CreatedAt'))
  $ageSeconds = $null
  if ($null -ne $start) { $ageSeconds = [Math]::Max(0,[int][Math]::Floor(($checkedAt - $start).TotalSeconds)) }
  $memory = Convert-ToInt64OrNull (Get-Field $record @('privateMemoryBytes','PrivateMemoryBytes','privatePageCount','PrivatePageCount','PrivatePageFileUsage'))
  $workingSet = Convert-ToInt64OrNull (Get-Field $record @('workingSetBytes','WorkingSetBytes','workingSetSize','WorkingSetSize','WorkingSet64'))
  $cwd = [string](Get-Field $record @('cwd','Cwd','currentDirectory','CurrentDirectory','workingDirectory','WorkingDirectory'))
  $parentState = 'unavailable'
  if ($null -eq $parentValue -or $parentValue -le 0) { $parentState = 'unavailable' }
  elseif ($parentValue -eq $pidValue) { $parentState = 'self' }
  elseif ($byPid.ContainsKey([string]$parentValue)) { $parentState = 'active' }
  elseif ($collection.available) { $parentState = 'missing' }
  $possibleOrphan = ($isCurrentPackage -and $parentState -eq 'missing' -and $null -ne $ageSeconds -and $ageSeconds -ge $OrphanAfterSeconds)
  $stale = ($scope -eq 'foreign_package')
  $state = if ($stale) { 'stale_foreign_package' } elseif ($possibleOrphan) { 'possible_orphan' } else { 'active_or_unverified' }
  $cwdSource = if ($cwd) { 'process_record' } else { 'unavailable' }
  if (-not $cwd -and $argumentRoot) { $cwdSource = 'package_root_argument_only' }
  $candidates += [pscustomobject]@{
    pid = [int64]$pidValue
    parentPid = if ($null -ne $parentValue) { [int64]$parentValue } else { $null }
    parentState = $parentState
    name = $name
    executablePath = $executable
    cwd = $cwd
    cwdSource = $cwdSource
    packageRootArgument = if ($argumentRoot) { $argumentRoot } else { $null }
    scope = $scope
    state = $state
    stale = [bool]$stale
    possibleOrphan = [bool]$possibleOrphan
    orphanReason = if ($possibleOrphan) { 'parent_missing_and_age_threshold_exceeded' } elseif ($parentState -eq 'missing') { 'parent_missing_but_age_or_scope_unverified' } else { $null }
    startTime = if ($start) { $start.ToString('o') } else { $null }
    ageSeconds = $ageSeconds
    privateMemoryBytes = $memory
    workingSetBytes = $workingSet
    # Command lines are used only for local matching.  Do not echo them: a
    # future process may contain credentials or other sensitive arguments.
    commandLinePresent = -not [string]::IsNullOrWhiteSpace($commandLine)
    identityState = 'unverified_process_metadata_only'
    action = 'report_only'
  }
}

$current = @($candidates | Where-Object { $_.scope -eq 'current_package' })
$possible = @($current | Where-Object { $_.possibleOrphan -eq $true })
$stale = @($candidates | Where-Object { $_.stale -eq $true })
$result = [pscustomobject]@{
  schema = $schema
  ok = [bool]$collection.available
  available = [bool]$collection.available
  code = if ($collection.available) { 'MCP_PROCESS_AUDIT_CURRENT' } else { [string]$collection.error }
  checkedAt = $checkedAt.ToString('o')
  packageRoot = $normalizedRoot
  entrypoint = $entryName
  collectionMethod = [string]$collection.method
  readOnly = $true
  mutation = 'none'
  canTerminate = $false
  orphanAfterSeconds = $OrphanAfterSeconds
  counts = [pscustomobject]@{
    allBrainMcpCandidates = @($candidates).Count
    currentPackage = @($current).Count
    possibleOrphan = @($possible).Count
    staleForeignPackage = @($stale).Count
    parentMissing = @($current | Where-Object { $_.parentState -eq 'missing' }).Count
    parentUnverifiable = @($current | Where-Object { $_.parentState -in @('unavailable','self') }).Count
  }
  processes = @($current)
  foreignProcesses = @($stale)
  notes = @(
    'Each active MCP stdio connection may have one process; multiple current-package processes are not automatically an error.',
    'A possible orphan is report-only. Parent absence can be caused by permission limits or an intentional detached connection; no process is terminated.',
    'Runtime identity and dialogue/session ownership are not available from Win32_Process metadata and remain unverified.'
  )
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12 -Compress
} else {
  Write-Host "MCP_PROCESS_AUDIT available=$($result.available) current=$($result.counts.currentPackage) possibleOrphan=$($result.counts.possibleOrphan) staleForeign=$($result.counts.staleForeignPackage) readOnly=True"
  foreach ($process in @($result.processes)) {
    Write-Host "PID=$($process.pid) parent=$($process.parentPid) parentState=$($process.parentState) state=$($process.state) memoryBytes=$($process.privateMemoryBytes) cwdSource=$($process.cwdSource)"
  }
}
exit 0
