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
$policyPath = Get-SuperBrainSharingPolicyPath $Root
$hadPolicy = Test-Path $policyPath
$originalPolicy = if ($hadPolicy) { Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 } else { $null }
if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
$installZ = Join-Path $tmpRoot 'zcode-skills'
$installC = Join-Path $tmpRoot 'codex-skills'
$tmpMemory = Join-Path $tmpRoot 'memory'

try {
  & (Join-Path $PSScriptRoot 'install.ps1') -ZCodeSkills $installZ -CodexSkills $installC -Neurobase $tmpMemory
  if ($LASTEXITCODE -ne 0) { throw 'smoke install failed' }

  & (Join-Path $PSScriptRoot 'health-check.ps1') -ZCodeSkills $installZ -CodexSkills $installC -MemoryRoot $tmpMemory
  if ($LASTEXITCODE -ne 0) { throw 'smoke health failed' }

  $statusJson = & (Join-Path $PSScriptRoot 'status.ps1') -ZCodeSkills $installZ -CodexSkills $installC -MemoryRoot $tmpMemory -Json
  if ($LASTEXITCODE -ne 0) { throw 'smoke status failed' }
  $statusJson | ConvertFrom-Json | Out-Null

  $env:NEXSANDBASE_HOME = $tmpMemory
  $env:PYTHONPATH = Join-Path $tmpMemory 'scripts'
  python -c "from sandglass_vault import recent; print(recent(1))"
  if ($LASTEXITCODE -ne 0) { throw 'smoke python runtime failed' }

  Write-Host 'SMOKE_TEST_OK'
} finally {
  if ($hadPolicy) {
    Write-Utf8NoBom $policyPath $originalPolicy
  } elseif (Test-Path $policyPath) {
    Remove-Item -LiteralPath $policyPath -Force
  }
  if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}
