[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Status','Refresh')]
  [string]$Action = 'Status',
  [string]$WorkspaceRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
  Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
} else {
  [IO.Path]::GetFullPath($WorkspaceRoot)
}
$path = Join-Path $workspace 'self-model.json'

function Read-Json([string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Limit-Text([string]$Value,[int]$Max=240) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = $Value.Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Property($Value,[string]$Name,$Default='') {
  if ($null -eq $Value -or -not ($Value.PSObject.Properties.Name -contains $Name)) { return $Default }
  return $Value.$Name
}

function Freshness($Value,[int]$Hours) {
  $stamp = ''
  foreach ($name in @('checkedAt','updatedAt','verifiedAt','executedAt','timestamp')) {
    $candidate = [string](Property $Value $name '')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $stamp = $candidate; break }
  }
  $parsed = [datetime]::MinValue
  if ([string]::IsNullOrWhiteSpace($stamp) -or -not [datetime]::TryParse($stamp,[ref]$parsed)) {
    return [pscustomobject]@{ fresh=$false; ageHours=$null; timestamp=$stamp }
  }
  $age = [Math]::Round(((Get-Date) - $parsed).TotalHours,2)
  return [pscustomobject]@{ fresh=($age -ge -0.25 -and $age -le $Hours); ageHours=$age; timestamp=$stamp }
}

$policy = Read-Json (Join-Path $Root 'memory-policy.json')
$settings = if ($policy -and ($policy.PSObject.Properties.Name -contains 'selfModel')) { $policy.selfModel } else { $null }
$maxAgeHours = [Math]::Max(1,[int](Property $settings 'maxAgeHours' 24))
$maxEvidence = [Math]::Max(1,[int](Property $settings 'maxEvidenceItems' 6))
$maxPreferences = [Math]::Max(1,[int](Property $settings 'maxPreferenceItems' 4))

if ($Action -eq 'Status') {
  $snapshot = Read-Json $path
  $fresh = Freshness $snapshot $maxAgeHours
  $declaredEvidenceStatus = if($snapshot){[string](Property $snapshot 'evidenceStatus' 'invalid')}else{'missing'}
  $schemaValid = $snapshot -and [string](Property $snapshot 'schema') -eq 'super-brain.self-model.v1'
  $versionValid = $snapshot -and [string](Property $snapshot 'packageVersion') -eq [string]$manifest.version
  $privacyValid = $snapshot -and (Property $snapshot 'rawPromptStored' $true) -eq $false
  $valid = (
    $schemaValid -and $versionValid -and $privacyValid -and
    $fresh.fresh
  )
  $snapshotStatus = if(-not $snapshot){'missing'}elseif(-not $fresh.fresh){'stale'}elseif(-not $schemaValid -or -not $versionValid -or -not $privacyValid){'invalid'}else{$declaredEvidenceStatus}
  $result = [pscustomobject]@{
    ok=$true; schema='super-brain.self-model-status.v1'; action='Status'
    snapshotExists=($null -ne $snapshot); fresh=$valid
    snapshotStatus=$snapshotStatus; evidenceStatus=$declaredEvidenceStatus
    verificationStatus=if($snapshot){$declaredEvidenceStatus}else{'unknown'}
    checkedAt=(Get-Date).ToString('o'); ageHours=$fresh.ageHours
    evidenceCount=if($snapshot){@((Property $snapshot 'evidence' @())).Count}else{0}
    rawPromptStored=$false; path=$path
  }
  if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SELF_MODEL action=Status exists=$($result.snapshotExists) fresh=$($result.fresh) status=$($result.evidenceStatus)" }
  exit 0
}

if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Path $workspace -Force | Out-Null }
$verify = Read-Json (Join-Path $workspace 'last-verify-package.json')
$verifyFresh = Freshness $verify $maxAgeHours
$verifyOk = (
  $verify -and (Property $verify 'ok' $false) -eq $true -and $verifyFresh.fresh -and
  [string](Property $verify 'version') -eq [string]$manifest.version
)

$context = Read-Json (Join-Path $workspace 'current-task-context.json')
$contextOk = (
  $context -and [string](Property $context 'status') -eq 'active' -and
  [string](Property $context 'version') -eq [string]$manifest.version -and
  -not [string]::IsNullOrWhiteSpace([string](Property $context 'taskId'))
)
if ($contextOk -and -not [string]::IsNullOrWhiteSpace([string](Property $context 'expiresAt'))) {
  $expires = [datetime]::MinValue
  $contextOk = [datetime]::TryParse([string](Property $context 'expiresAt'),[ref]$expires) -and $expires -gt (Get-Date)
}

$taskVerification = Read-Json (Join-Path $workspace 'last-task-verification.json')
$taskFresh = Freshness $taskVerification ([Math]::Max(24,$maxAgeHours * 7))
$taskOk = ($taskVerification -and (Property $taskVerification 'ok' $false) -eq $true -and $taskFresh.fresh)

$profile = Read-Json (Join-Path $workspace 'user-adaptation\profile.json')
$preferenceList = New-Object Collections.ArrayList
if ($profile -and (Property $profile 'rawPromptStored' $false) -ne $true) {
  foreach ($entry in @((Property $profile 'entries' @()))) {
    if ([string](Property $entry 'status') -ne 'active' -or (Property $entry 'rawPromptStored' $false) -eq $true) { continue }
    $habit = Limit-Text ([string](Property $entry 'habitKey')) 60
    $value = Limit-Text ([string](Property $entry 'value')) 80
    if ($habit -and $value) { [void]$preferenceList.Add("$habit=$value") }
  }
}
$preferences = @($preferenceList | Select-Object -Unique -First $maxPreferences)

$reflection = Read-Json (Join-Path $workspace 'last-reflection-promotion.json')
$reflectionSafe = ($reflection -and (Property $reflection 'rawPromptStored' $false) -ne $true)
$reflectionCount = if($reflectionSafe){@((Property $reflection 'candidates' @())).Count}else{0}

$evidenceList = New-Object Collections.ArrayList
if ($verify) { [void]$evidenceList.Add("last-verify-package.json ok=$([bool](Property $verify 'ok' $false)) fresh=$($verifyFresh.fresh)") }
if ($contextOk) { [void]$evidenceList.Add("current-task-context.json active task=$([string](Property $context 'taskId'))") }
if ($taskOk) { [void]$evidenceList.Add("last-task-verification.json ok=true fresh=$($taskFresh.fresh)") }
if ($preferences.Count -gt 0) { [void]$evidenceList.Add("user-adaptation/profile.json activePreferences=$($preferences.Count)") }
if ($reflectionSafe) { [void]$evidenceList.Add("last-reflection-promotion.json candidates=$reflectionCount") }
$evidence = @($evidenceList | Select-Object -Unique -First $maxEvidence)

$capabilityList = New-Object Collections.ArrayList
if ($verifyOk) {
  [void]$capabilityList.Add('package and native runtime verification')
  if ($contextOk) { [void]$capabilityList.Add('governed task continuity state') }
  if ($taskOk) { [void]$capabilityList.Add('verified task outcome tracking') }
  if ($preferences.Count -gt 0) { [void]$capabilityList.Add('governed user adaptation') }
  if ($reflectionSafe) { [void]$capabilityList.Add('evidence-gated reflection') }
}

$state = @($(if($verifyOk){'packageVerification=current'}else{'packageVerification=missing_or_stale'}))
if ($contextOk) { $state += "activeTask=$([string](Property $context 'taskId'))" }
if ($taskOk) { $state += "lastVerifiedTask=$([string](Property $taskVerification 'taskId'))" }
if ($reflectionSafe) { $state += "reflectionCandidates=$reflectionCount" }
$nextAction = if (-not $verifyOk) {
  'Refresh package verification before relying on capability claims.'
} elseif ($contextOk -and [string](Property $context 'nextAction')) {
  Limit-Text ([string](Property $context 'nextAction')) 220
} else {
  'Refresh after the next verified task outcome or safe maintenance.'
}

$snapshot = [pscustomobject]@{
  schema='super-brain.self-model.v1'; packageVersion=[string]$manifest.version
  updatedAt=(Get-Date).ToString('o'); evidenceStatus=if($verifyOk){'verified'}else{'degraded'}
  identity='Super Memory Brain / G1 local control plane'
  role='Route, recall, verify, and learn from governed local evidence.'
  verifiedCapabilities=@($capabilityList | Select-Object -First 5)
  currentState=Limit-Text ($state -join '; ') 420
  userModel=if($preferences.Count -gt 0){Limit-Text ('Governed collaboration preferences: ' + ($preferences -join ', ') + '. Explicit current instructions always win.') 360}else{'No active governed preference snapshot is available.'}
  knownLimits=@(
    'Self-model claims are limited to the listed local evidence.',
    'Missing or stale evidence makes current state unknown.',
    'Memory is evidence, not authority; unknown personal facts remain unknown.',
    'Adaptation never overrides explicit user instructions, safety, or permissions.'
  )
  nextAction=$nextAction; evidence=$evidence
  rawPromptStored=$false; alwaysOnInjection=$false
  source='self-model.ps1'; retention='bounded_evidence_snapshot'
}
Write-JsonUtf8NoBom $path $snapshot 12

$result = [pscustomobject]@{
  ok=$true; schema='super-brain.self-model-status.v1'; action='Refresh'
  snapshotExists=$true; fresh=$true; snapshotStatus=$snapshot.evidenceStatus
  evidenceStatus=$snapshot.evidenceStatus; verificationStatus=$snapshot.evidenceStatus
  checkedAt=(Get-Date).ToString('o'); evidenceCount=@($evidence).Count
  verifiedCapabilityCount=@($snapshot.verifiedCapabilities).Count
  preferenceCount=$preferences.Count; rawPromptStored=$false; path=$path
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SELF_MODEL action=Refresh status=$($result.evidenceStatus) evidence=$($result.evidenceCount) path=$path" }
exit 0
