param(
  [string]$Destination = "",
  [switch]$QuietVerify
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$StatusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-release.json'
if ([string]::IsNullOrWhiteSpace($Destination)) {
  $Destination = Join-Path (Split-Path -Parent $Root) ('super-memory-brain-package-share-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-ReleaseStatus([bool]$Ok, [string]$Message, [string]$OutputPath = $Destination) {
  Write-JsonUtf8NoBom $StatusPath ([pscustomobject]@{
    ok = $Ok
    kind = 'share'
    includesMemory = $false
    destination = if ($Ok -or (Test-Path $OutputPath)) { $OutputPath } else { '' }
    message = $Message
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }) 6
}

function Test-ReleasePrerequisites {
  foreach ($script in @('prepare-share.ps1','verify-share.ps1')) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $script))) { throw "Missing release script: $script" }
  }
  Get-SuperBrainManifest $Root | Out-Null
}

try {
  Test-ReleasePrerequisites

  & (Join-Path $PSScriptRoot 'prepare-share.ps1') -Destination $Destination
  if (-not $?) { Write-ReleaseStatus $false 'Share preparation failed.'; exit 1 }

  if ($QuietVerify) {
    & (Join-Path $PSScriptRoot 'verify-share.ps1') -Destination $Destination -SkipPrepare *> $null
    $verifyExitCode = $LASTEXITCODE
    if ($verifyExitCode -ne 0) {
      & (Join-Path $PSScriptRoot 'verify-share.ps1') -Destination $Destination -SkipPrepare
      Write-ReleaseStatus $false 'Share verification failed.'
      exit $verifyExitCode
    }
    Write-Host 'VERIFY_SHARE_OK'
  } else {
    & (Join-Path $PSScriptRoot 'verify-share.ps1') -Destination $Destination -SkipPrepare
    if ($LASTEXITCODE -ne 0) { Write-ReleaseStatus $false 'Share verification failed.'; exit $LASTEXITCODE }
  }

  Write-ReleaseStatus $true 'Share release excludes private memory files.'
  Write-Host "RELEASE_SHARE_OK $Destination"
  Write-Host "PUBLIC_SAFE_PACKAGE $Destination"
  Write-Host 'INCLUDES_MEMORY false'
  Write-Host 'VERIFY_STATUS ok'
  Write-Host 'Upload only this generated share directory to GitHub. Do not upload the live package root or any private release output.'
  Write-Host 'Share release excludes private memory files.'
} catch {
  Write-ReleaseStatus $false $_.Exception.Message
  throw
}
