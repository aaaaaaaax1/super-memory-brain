param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$ok = $true
$results = @()
$skillNames = @{}
$collisions = @()

function Add-Result([string]$ExtensionId, [string]$Name, [bool]$Success, [string]$Message) {
  $script:results += [pscustomobject]@{
    extensionId = $ExtensionId
    name = $Name
    ok = $Success
    message = $Message
  }
  if (-not $Success) { $script:ok = $false }
}

$coreNames = @(Get-SuperBrainSkillNames)
foreach ($extension in @(Get-SuperBrainExtensionManifests @() $Root)) {
  $extensionId = [string]$extension.id
  if ([string]::IsNullOrWhiteSpace($extensionId)) { Add-Result '' '' $false 'extension id missing'; continue }
  if ([string]::IsNullOrWhiteSpace([string]$extension.sourceRepo)) { Add-Result $extensionId '' $false 'sourceRepo missing' }
  if ([string]::IsNullOrWhiteSpace([string]$extension.sourceCommit)) { Add-Result $extensionId '' $false 'sourceCommit missing' }
  if ([string]::IsNullOrWhiteSpace([string]$extension.license)) { Add-Result $extensionId '' $false 'license missing' }
  if (@($extension.skills).Count -eq 0) { Add-Result $extensionId '' $false 'skills missing' }

  foreach ($skill in @($extension.skills)) {
    $name = [string]$skill.name
    $path = [string]$skill.path
    if ([string]::IsNullOrWhiteSpace($name)) { Add-Result $extensionId '' $false 'skill name missing'; continue }
    if ($coreNames -contains $name) { Add-Result $extensionId $name $false 'skill name conflicts with core skill' }
    if ($skillNames.ContainsKey($name)) { Add-Result $extensionId $name $false "duplicate extension skill name also in $($skillNames[$name])" } else { $skillNames[$name] = $extensionId }
    if ($path -match '(^|/|\\)(deprecated|in-progress|personal)(/|\\|$)') { Add-Result $extensionId $name $false 'excluded category included by default' }
    $skillDir = Join-Path (Split-Path -Parent $extension.manifestPath) $path
    $skillFile = Join-Path $skillDir 'SKILL.md'
    if (-not (Test-Path $skillFile)) { Add-Result $extensionId $name $false 'SKILL.md missing' }
    else {
      $text = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
      if ($text -notmatch '(?m)^name:\s*' -or $text -notmatch '(?m)^description:\s*') { Add-Result $extensionId $name $false 'frontmatter name/description missing' }
      else { Add-Result $extensionId $name $true 'skill verified' }
    }
  }
}

$report = [pscustomobject]@{
  ok = $ok
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  extensionCount = @((Get-SuperBrainExtensionManifests @() $Root)).Count
  skillCount = @($results | Where-Object { $_.message -eq 'skill verified' }).Count
  collisionCount = @($collisions).Count
  collisions = @($collisions)
  results = @($results)
}

if ($Json) { $report | ConvertTo-Json -Depth 8 }
else {
  Write-Host "EXTENSION_VERIFY ok=$($report.ok) extensions=$($report.extensionCount) skills=$($report.skillCount) collisions=$($report.collisionCount)"
  foreach ($collision in @($collisions)) { Write-Host "EXTENSION_COLLISION extension=$($collision.extensionId) skill=$($collision.name) root=$($collision.skillRoot) action=$($collision.action)" }
  foreach ($result in @($results)) {
    $status = if ($result.ok) { 'OK' } else { 'FAILED' }
    Write-Host "EXTENSION_$status extension=$($result.extensionId) skill=$($result.name) $($result.message)"
  }
}
if (-not $ok) { exit 1 }
exit 0
