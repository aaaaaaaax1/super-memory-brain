param(
  [Parameter(Mandatory=$true)][string]$InputText,
  [string]$Title = 'Session Compact Note'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Workspace = Join-Path $Root 'memory\workspace'
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
$Out = Join-Path $Workspace 'session-notes.md'
$Now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$lines = $InputText -split '[\r\n]+' | Where-Object { $_.Trim() }
$important = @()
foreach ($line in $lines) {
  if ($line -match 'ERROR|FAILED|MISSING|OK|verified|done|path|version|decision|TODO|Next') {
    $important += ('- ' + $line.Trim())
  }
}
if ($important.Count -eq 0) {
  $important = ($lines | Select-Object -First 10 | ForEach-Object { '- ' + $_.Trim() })
}

$noteLines = @(
  "## $Title",
  '',
  "Time: $Now",
  '',
  '### Compact Notes'
) + $important + @(
  '',
  '### Next Step',
  '- Review compact notes and promote only stable facts through write-memory.ps1.',
  ''
)

Add-Content -LiteralPath $Out -Value ($noteLines -join "`n") -Encoding UTF8
Write-Host "SESSION_COMPACT_OK $Out"
