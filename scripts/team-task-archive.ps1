param(
  [int]$KeepRecent = 5,
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$teamRoot = Join-Path $workspace 'team-tasks'
$archiveRoot = Join-Path $workspace 'team-tasks-archive'
$statusPath = Join-Path $workspace 'last-team-task-archive.json'
if (-not (Test-Path $archiveRoot)) { New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null }

$items = @()
if (Test-Path -LiteralPath $teamRoot) {
  $items = @(Get-ChildItem -LiteralPath $teamRoot -Filter '*.json' | Sort-Object LastWriteTime -Descending)
}
$toKeep = @($items | Select-Object -First $KeepRecent)
$toArchive = @($items | Select-Object -Skip $KeepRecent)
$archived = @()
foreach ($file in $toArchive) {
  $dest = Join-Path $archiveRoot $file.Name
  if ($Apply) { Move-Item -LiteralPath $file.FullName -Destination $dest -Force }
  $archived += [pscustomobject]@{ source=$file.FullName; destination=$dest; applied=[bool]$Apply }
}
$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  apply = [bool]$Apply
  keepRecent = $KeepRecent
  total = $items.Count
  keep = $toKeep.Count
  archiveCandidates = $toArchive.Count
  archived = @($archived)
  note = if ($Apply) { 'Archived old team-task files.' } else { 'Dry run only. Use -Apply to move old team-task files.' }
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 8
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "TEAM_TASK_ARCHIVE total=$($result.total) candidates=$($result.archiveCandidates) apply=$Apply status=$statusPath" }
exit 0
