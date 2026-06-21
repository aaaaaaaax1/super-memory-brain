param(
  [ValidateSet('direct','single_delegate','team_parallel','review_board')][string]$DispatchLevel = 'direct',
  [string[]]$Reason = @(),
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$listJson = & (Join-Path $PSScriptRoot 'team-template-list.ps1') -Json
$config = $listJson | ConvertFrom-Json
$templates = @($config.templates)
$reasonSet = @{}
foreach ($item in @($Reason)) { $reasonSet[[string]$item] = $true }

function Has-Reason([string[]]$Names) {
  foreach ($name in $Names) {
    if ($reasonSet.ContainsKey($name)) { return $true }
  }
  return $false
}

function Get-TemplateById([string]$Id) {
  return @($templates | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

$selected = $null
$selectionReason = 'direct_or_no_template'

if ($DispatchLevel -ne 'direct') {
  if ($DispatchLevel -eq 'review_board' -and (Has-Reason @('architecture_change','logic_safety_required','memory_sensitive','repeated_failure_or_drift'))) {
    $selected = Get-TemplateById 'review-team'
    $selectionReason = 'review_board_high_risk'
  } elseif (Has-Reason @('release','share','hot_refresh')) {
    $selected = Get-TemplateById 'release-team'
    $selectionReason = 'release_or_share'
  } elseif ($DispatchLevel -eq 'team_parallel' -or (Has-Reason @('broad_search','parallelizable','unknown_codebase','docs_scan'))) {
    $selected = Get-TemplateById 'explore-team'
    $selectionReason = 'parallel_or_broad_exploration'
  } elseif (Has-Reason @('verification_required')) {
    $selected = Get-TemplateById 'release-team'
    $selectionReason = 'verification_only'
  } elseif ($DispatchLevel -eq 'single_delegate') {
    $selected = Get-TemplateById 'solo-delegate'
    $selectionReason = 'single_delegate_default'
  }
}

$result = [pscustomobject]@{
  ok = $true
  dispatchLevel = $DispatchLevel
  reasons = @($Reason)
  selectionReason = $selectionReason
  selected = if ($selected) { [pscustomobject]@{ id=$selected.id; name=$selected.name; roles=@($selected.roles); triggers=@($selected.triggers); purpose=$selected.purpose } } else { $null }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  if ($selected) { Write-Host "TEAM_TEMPLATE_SELECTED id=$($selected.id) name=$($selected.name) roles=$(@($selected.roles) -join ',') reason=$selectionReason" } else { Write-Host "TEAM_TEMPLATE_SELECTED none reason=$selectionReason" }
}
exit 0
