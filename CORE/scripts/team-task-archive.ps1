param(
  [int]$KeepRecent = 5,
  [switch]$Apply,
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'team-task-common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Get-TeamTaskWorkspace $Root $StateRoot
$teamRoot = Join-Path $workspace 'team-tasks'
$archiveRoot = Join-Path $workspace 'team-tasks-archive'
$statusPath = Join-Path $workspace 'last-team-task-archive.json'
if (-not (Test-Path $archiveRoot)) { New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null }

$items = @(Get-TeamTaskRecordFilesStable $teamRoot)
$toKeep = @($items | Select-Object -First $KeepRecent)
$toArchive = @($items | Select-Object -Skip $KeepRecent)
$archived = @()
$conflicts = @()
foreach ($file in $toArchive) {
  $dest = Join-Path $archiveRoot $file.Name
  if (-not $Apply) {
    $archived += [pscustomobject]@{ source=$file.FullName; destination=$dest; applied=$false; status='planned' }
    continue
  }

  $expectedLastWriteTimeUtc = $file.LastWriteTimeUtc
  $moveResult = Invoke-TeamTaskRecordLock $file.FullName {
    if (-not (Test-Path -LiteralPath $file.FullName -PathType Leaf)) {
      return [pscustomobject]@{ applied=$false; status='missing_after_scan'; reason='record_missing_after_stable_scan' }
    }
    $liveFile = Get-Item -LiteralPath $file.FullName
    if ($liveFile.LastWriteTimeUtc -ne $expectedLastWriteTimeUtc) {
      return [pscustomobject]@{ applied=$false; status='changed_after_scan'; reason='record_changed_after_stable_scan' }
    }
    Move-Item -LiteralPath $file.FullName -Destination $dest -Force
    return [pscustomobject]@{ applied=$true; status='archived'; reason='' }
  }
  $archived += [pscustomobject]@{ source=$file.FullName; destination=$dest; applied=[bool]$moveResult.applied; status=[string]$moveResult.status }
  if (-not $moveResult.applied) {
    $conflicts += [pscustomobject]@{ source=$file.FullName; destination=$dest; status=[string]$moveResult.status; reason=[string]$moveResult.reason }
  }
}
$result = [pscustomobject]@{
  ok = ($conflicts.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  apply = [bool]$Apply
  keepRecent = $KeepRecent
  total = $items.Count
  keep = $toKeep.Count
  archiveCandidates = $toArchive.Count
  archived = @($archived)
  conflictCount = $conflicts.Count
  conflicts = @($conflicts)
  note = if ($Apply -and $conflicts.Count -eq 0) { 'Archived old stable team-task files.' } elseif ($Apply) { 'Archive stopped with concurrent-state conflicts; no success claim is valid.' } else { 'Dry run only. Use -Apply to move old team-task files.' }
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 8
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "TEAM_TASK_ARCHIVE total=$($result.total) candidates=$($result.archiveCandidates) conflicts=$($result.conflictCount) apply=$Apply status=$statusPath" }
if (-not $result.ok) { exit 1 }
exit 0
