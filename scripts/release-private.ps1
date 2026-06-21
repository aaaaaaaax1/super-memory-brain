param(
  [string]$Destination = ""
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$StatusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-release.json'
if ([string]::IsNullOrWhiteSpace($Destination)) {
  $Destination = Join-Path (Split-Path -Parent $Root) ('super-memory-brain-package-private-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-ReleaseStatus([bool]$Ok, [string]$Message, [string]$OutputPath = $Destination) {
  Write-JsonUtf8NoBom $StatusPath ([pscustomobject]@{
    ok = $Ok
    kind = 'private'
    includesMemory = $true
    destination = if ($Ok -or (Test-Path $OutputPath)) { $OutputPath } else { '' }
    message = $Message
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }) 6
}

function Test-ReleasePrerequisites {
  Get-SuperBrainManifest $Root | Out-Null
}

try {
  Test-ReleasePrerequisites

  if (Test-Path $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
  Copy-Item -LiteralPath $Root -Destination $Destination -Recurse -Force
  Write-ReleaseStatus $true 'Private release includes memory. Do not share unless intended.'
  Write-Host "RELEASE_PRIVATE_OK $Destination"
  Write-Host 'Private release includes memory/. Do not share unless intended.'
} catch {
  Write-ReleaseStatus $false $_.Exception.Message
  throw
}
