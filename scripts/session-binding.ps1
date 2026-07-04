param(
  [ValidateSet('Bind','Refresh','Get','Clear','Expire')]
  [string]$Action = 'Get',
  [string]$SessionId = '',
  [string]$TaskId = '',
  [string]$Query = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [int]$TtlMinutes = 180,
  [int]$MaxTokens = 400,
  [int]$TopK = 3,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$Manifest = Get-SuperBrainManifest $Root
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$bindingPath = Join-Path $workspace 'session-binding.json'

function New-SessionBindingResult([bool]$Ok, [string]$Status, [string]$Reason, [object]$Binding = $null) {
  return [pscustomobject]@{
    ok = $Ok
    action = $Action
    status = $Status
    reason = $Reason
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    path = $bindingPath
    binding = $Binding
  }
}

function Read-SessionBindingRaw {
  if (-not (Test-Path $bindingPath)) { return $null }
  try { return Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return [pscustomobject]@{ ok=$false; status='parse_failed'; error=$_.Exception.Message } }
}

function Test-PrivatePattern([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return ($Text -match '(?i)(api[_-]?key|client[_-]?secret|password\s*[=:]|access[_-]?token\s*[=:]|refresh[_-]?token\s*[=:]|bearer\s+[A-Za-z0-9._-]+|sk-[A-Za-z0-9])')
}

function Get-BindingHealth($Binding) {
  $now = Get-Date
  $expired = $false
  if ($Binding -and $Binding.expiresAt) {
    try { $expired = ([datetime]::Parse([string]$Binding.expiresAt) -lt $now) } catch { $expired = $true }
  }
  $versionMatch = ($Binding -and ([string]$Binding.packageVersion -eq [string]$Manifest.version))
  $rootMatch = ($Binding -and (Test-SuperBrainSamePath ([string]$Binding.memoryRoot) $MemoryRoot))
  $rawRisk = $false
  if ($Binding) {
    $rawRisk = (Test-PrivatePattern ([string]$Binding.query)) -or (Test-PrivatePattern ($Binding | ConvertTo-Json -Depth 12 -Compress))
  }
  return [pscustomobject]@{
    active = ($Binding -and [string]$Binding.status -eq 'active' -and -not $expired -and $versionMatch -and $rootMatch -and -not $rawRisk)
    expired = $expired
    packageVersionMatch = $versionMatch
    memoryRootMatch = $rootMatch
    rawContentRisk = $rawRisk
  }
}

if ($Action -eq 'Clear') {
  if (Test-Path $bindingPath) { Remove-Item -LiteralPath $bindingPath -Force }
  $result = New-SessionBindingResult $true 'cleared' 'user_or_script_clear' $null
  if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SESSION_BINDING_CLEARED path=$bindingPath" }
  exit 0
}

if ($Action -eq 'Expire') {
  $binding = Read-SessionBindingRaw
  if ($binding) {
    $binding.status = 'expired'
    $binding.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $binding.expiresAt = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss')
    Write-JsonUtf8NoBom $bindingPath $binding 12
  }
  $result = New-SessionBindingResult $true 'expired' 'explicit_expire' $binding
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SESSION_BINDING_EXPIRED path=$bindingPath" }
  exit 0
}

if ($Action -eq 'Get') {
  $binding = Read-SessionBindingRaw
  if (-not $binding) {
    $result = New-SessionBindingResult $true 'missing' 'no_session_binding' $null
  } elseif ($binding.status -eq 'parse_failed') {
    $result = New-SessionBindingResult $false 'parse_failed' $binding.error $binding
  } else {
    $health = Get-BindingHealth $binding
    $binding | Add-Member -NotePropertyName health -NotePropertyValue $health -Force
    $result = New-SessionBindingResult $true ($(if ($health.active) { 'active' } else { 'inactive' })) 'session_binding_loaded' $binding
  }
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SESSION_BINDING_$($result.status.ToUpperInvariant()) path=$bindingPath" }
  exit 0
}

if ($MemoryMode -eq 'off') {
  $result = New-SessionBindingResult $true 'skipped' 'memory:off' $null
  if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SESSION_BINDING_SKIPPED memory=off" }
  exit 0
}

if ($TtlMinutes -le 0) { $TtlMinutes = 180 }
if ($MaxTokens -le 0) { $MaxTokens = 400 }
if ($TopK -le 0) { $TopK = 3 }
$now = Get-Date
$bindingId = 'bind-' + $now.ToString('yyyyMMdd-HHmmss')
if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = 'current-session' }
if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = 'current-task' }
$cleanQuery = ($Query -replace '\s+', ' ').Trim()
if ($cleanQuery.Length -gt [Math]::Max(80, $MaxTokens * 4)) { $cleanQuery = $cleanQuery.Substring(0, [Math]::Max(80, $MaxTokens * 4)) + '...' }
if (Test-PrivatePattern $cleanQuery) { $cleanQuery = '[REDACTED_PRIVATE_PATTERN]' }

$checkpoint = $null
$checkpointPath = Join-Path $workspace 'active-checkpoint.json'
if (Test-Path $checkpointPath) {
  try { $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$evidenceCards = @()
if (-not [string]::IsNullOrWhiteSpace($cleanQuery)) {
  $evidenceCards += [pscustomobject]@{
    source = 'session-binding.ps1'
    sourceType = 'sessionBinding'
    claim = $cleanQuery
    whyRelevant = 'temporary_session_binding_query'
    confidence = 0.75
    layer = 'session'
    tags = @('[SESSION]','[SUMMARY]')
    tokenEstimate = [Math]::Ceiling($cleanQuery.Length / 4)
  }
}
if ($checkpoint) {
  $evidenceCards += [pscustomobject]@{
    source = 'memory\workspace\active-checkpoint.json'
    sourceType = 'sessionBinding'
    claim = "checkpoint taskId=$($checkpoint.taskId) status=$($checkpoint.status) currentStep=$($checkpoint.currentStep) nextAction=$($checkpoint.nextAction)"
    whyRelevant = 'temporary_session_binding_checkpoint'
    confidence = 0.82
    layer = 'session'
    tags = @('[SESSION]','[TASK]','[SUMMARY]')
    tokenEstimate = 48
  }
}

$binding = [pscustomobject]@{
  ok = $true
  bindingId = $bindingId
  sessionId = $SessionId
  taskId = $TaskId
  agent = 'zcode'
  platform = 'zcode'
  packageVersion = [string]$Manifest.version
  packageRoot = (Get-NormalizedSuperBrainRoot $Root)
  memoryRoot = (Get-NormalizedSuperBrainRoot $MemoryRoot)
  createdAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
  updatedAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
  expiresAt = $now.AddMinutes($TtlMinutes).ToString('yyyy-MM-dd HH:mm:ss')
  ttlMinutes = $TtlMinutes
  status = 'active'
  scope = 'temporary_workspace_only'
  memoryMode = $MemoryMode
  query = $cleanQuery
  currentStep = if ($checkpoint) { [string]$checkpoint.currentStep } else { 'session_binding_created' }
  nextAction = if ($checkpoint) { [string]$checkpoint.nextAction } else { 'Use binding evidence only when the current user asks for continuity or the bound session.' }
  boundCheckpoint = if ($checkpoint) { [pscustomobject]@{ taskId=$checkpoint.taskId; status=$checkpoint.status; currentStep=$checkpoint.currentStep; nextAction=$checkpoint.nextAction } } else { $null }
  evidenceCards = @($evidenceCards)
  guards = [pscustomobject]@{
    noRawChat = $true
    noSecrets = $true
    fastSessionResume = ($SessionId -match '^#?sess[_-][A-Za-z0-9._-]+')
    noDefaultDeepRecall = $true
    sessionIdSummaryOnly = ($SessionId -match '^#?sess[_-][A-Za-z0-9._-]+')
    memoryOffRespected = $true
    staleBindingIgnored = $true
    activeRootMatched = $true
    currentUserInstructionWins = $true
  }
}
Write-JsonUtf8NoBom $bindingPath $binding 12
$result = New-SessionBindingResult $true 'active' 'session_binding_written' $binding
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SESSION_BINDING_OK id=$bindingId expiresAt=$($binding.expiresAt) path=$bindingPath" }
