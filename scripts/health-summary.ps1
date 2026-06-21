param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}

$dashboard = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Json 6>$null) 'super-brain-dashboard.ps1'
$doctor = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'doctor.ps1') -Json 6>$null) 'doctor.ps1'
$smartNext = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'smart-next.ps1') -Json 6>$null) 'smart-next.ps1'

$summaryLines = @(
  "version=$($dashboard.version)",
  "ready=$($dashboard.ok)",
  "verify=$($dashboard.verify.ok)",
  "hotRefresh=$($dashboard.hotRefresh.ok)",
  "privacy=$($dashboard.privacy.ok)",
  "reviewGate=$($dashboard.reviewGate.ok)",
  "risks=$(@($dashboard.risks).Count)",
  "next=$($smartNext.nextAction)"
)

$result = [pscustomobject]@{
  ok = ($dashboard.ok -eq $true -and $doctor.ok -eq $true)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  ready = $dashboard.ok
  summary = ($summaryLines -join '; ')
  risks = @($dashboard.risks)
  riskSummary = $doctor.riskSummary
  nextAction = $smartNext.nextAction
  recentTask = $dashboard.task.summary
  commands = @('scripts\smart-next.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json','scripts\doctor.ps1 -Json')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "HEALTH_SUMMARY $($result.summary)"
  if (@($result.risks).Count -gt 0) { foreach ($risk in @($result.risks)) { Write-Host "RISK $risk" } }
}
if (-not $result.ok) { exit 1 }
exit 0
