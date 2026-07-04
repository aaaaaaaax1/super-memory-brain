param(
  [string]$OpenReverseLabPath = '',
  [string]$OpenTgtyLabPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Resolve-CandidatePath([string]$Explicit, [string[]]$Candidates) {
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
  foreach ($candidate in $Candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $Candidates[0]
}

function Get-GitRemote([string]$Path) {
  if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return '' }
  try {
    $remote = & git -C $Path remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0) { return ($remote | Select-Object -First 1) }
  } catch {}
  return ''
}

function Find-OpenReverseLabFromPath {
  $pathValue = [Environment]::GetEnvironmentVariable('PATH')
  if ([string]::IsNullOrWhiteSpace($pathValue)) { return '' }
  foreach ($entry in $pathValue -split ';') {
    if ($entry -match 'open-reverselab[\\/]tools[\\/]bin$') {
      $bin = [System.IO.Path]::GetFullPath($entry)
      return (Split-Path -Parent (Split-Path -Parent $bin))
    }
  }
  return ''
}

$homeRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'ReverseLab'
$pathDetectedOpenReverse = Find-OpenReverseLabFromPath
$openReverseCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($pathDetectedOpenReverse)) { $openReverseCandidates += $pathDetectedOpenReverse }
$openReverseCandidates += (Join-Path $homeRoot 'open-reverselab')
$openReverse = Resolve-CandidatePath $OpenReverseLabPath @(
  $openReverseCandidates
)
$openTgty = Resolve-CandidatePath $OpenTgtyLabPath @(
  'G:\Ai\agens\Open-tgtylab',
  (Join-Path $homeRoot 'Open-tgtylab')
)

$openReverseTools = @(
  'tools\bin\ai_context.bat',
  'tools\bin\ai_tool.bat',
  'tools\bin\ai_toolcheck.bat',
  'tools\bin\mitmdump.bat'
)

$openTgtyFiles = @(
  'README.md',
  'tools\skills\mcp\ReverseLabToolsMCP\reverse_lab_tools_mcp.py',
  '.mcp.json'
)

$result = [ordered]@{
  ok = $true
  checkedAt = (Get-Date).ToString('s')
  openReverseLab = [ordered]@{
    path = $openReverse
    exists = (Test-Path -LiteralPath $openReverse)
    remote = Get-GitRemote $openReverse
    expectedRemote = 'https://github.com/LING71671/open-reverselab.git'
    files = @($openReverseTools | ForEach-Object {
      [pscustomobject]@{ path = $_; exists = (Test-Path -LiteralPath (Join-Path $openReverse $_)) }
    })
  }
  openTgtyLab = [ordered]@{
    path = $openTgty
    exists = (Test-Path -LiteralPath $openTgty)
    remote = Get-GitRemote $openTgty
    expectedRemote = 'https://github.com/GeniusHu-tgty/Open-tgtylab.git'
    files = @($openTgtyFiles | ForEach-Object {
      [pscustomobject]@{ path = $_; exists = (Test-Path -LiteralPath (Join-Path $openTgty $_)) }
    })
  }
  commands = [ordered]@{
    git = [bool](Get-Command git -ErrorAction SilentlyContinue)
    python = [bool](Get-Command python -ErrorAction SilentlyContinue)
    uv = [bool](Get-Command uv -ErrorAction SilentlyContinue)
  }
  mcp = [ordered]@{
    expectedServerName = 'reverse_lab_tools'
    note = 'If mcp__reverse_lab_tools tools are not exposed in the agent, register the MCP server from Open-tgtylab or open-reverselab after user approval.'
  }
}

$missing = @()
if (-not $result.openReverseLab.exists) { $missing += 'open-reverselab repo' }
if (-not $result.openTgtyLab.exists) { $missing += 'Open-tgtylab repo' }
foreach ($f in @($result.openReverseLab.files)) { if (-not $f.exists) { $missing += "open-reverselab/$($f.path)" } }
foreach ($f in @($result.openTgtyLab.files)) { if (-not $f.exists) { $missing += "Open-tgtylab/$($f.path)" } }
$result['missing'] = @($missing)
$result['ready'] = (@($missing).Count -eq 0)

if ($Json) { [pscustomobject]$result | ConvertTo-Json -Depth 8 }
else {
  Write-Host "REVERSELAB_STATUS ready=$($result.ready) missing=$(@($missing).Count)"
  Write-Host "open-reverselab=$openReverse"
  Write-Host "Open-tgtylab=$openTgty"
}
