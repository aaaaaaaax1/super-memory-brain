param(
  [ValidateSet('T0','T1','T2','T3')]
  [string]$Tier = '',
  [switch]$IncludeInternal,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$entries = @($manifest.scriptMetadata)
if (-not $IncludeInternal) {
  $entries = @($entries | Where-Object { $_.internal -ne $true })
}
if (-not [string]::IsNullOrWhiteSpace($Tier)) {
  $entries = @($entries | Where-Object { $_.tier -eq $Tier })
}

$result = [pscustomobject]@{
  version = $manifest.version
  tiers = $manifest.scriptTiers
  includeInternal = [bool]$IncludeInternal
  filterTier = if ([string]::IsNullOrWhiteSpace($Tier)) { $null } else { $Tier }
  scripts = @($entries | Sort-Object tier,path | ForEach-Object {
    [pscustomobject]@{
      path = $_.path
      tier = $_.tier
      manualOnly = [bool]$_.manualOnly
      internal = [bool]$_.internal
      dangerousSwitches = @($_.dangerousSwitches)
      notes = $_.notes
    }
  })
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Host "SCRIPT_TIERS version=$($result.version) count=$($result.scripts.Count) includeInternal=$($result.includeInternal) tier=$($result.filterTier)"
  foreach ($group in @($result.scripts | Group-Object tier | Sort-Object Name)) {
    Write-Host "[$($group.Name)] $($manifest.scriptTiers.$($group.Name))"
    foreach ($script in @($group.Group | Sort-Object path)) {
      $flags = @()
      if ($script.manualOnly) { $flags += 'manual' }
      if ($script.internal) { $flags += 'internal' }
      if ($script.dangerousSwitches.Count -gt 0) { $flags += ('switches=' + ($script.dangerousSwitches -join ',')) }
      $flagText = if ($flags.Count -gt 0) { ' ' + ($flags -join ';') } else { '' }
      Write-Host "  - $($script.path)$flagText"
    }
  }
}

exit 0
