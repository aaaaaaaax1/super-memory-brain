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
$bindingPath = Join-Path $workspace 'session-binding.json'

function Read-LegacySessionBinding {
  if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
    return [pscustomobject]@{ parseFailed=$true; parseError=$_.Exception.Message }
  }
}

function Test-PrivatePattern([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return ($Text -match '(?i)(api[_-]?key|client[_-]?secret|password\s*[=:]|access[_-]?token\s*[=:]|refresh[_-]?token\s*[=:]|bearer\s+[A-Za-z0-9._-]+|sk-[A-Za-z0-9])')
}

function New-LegacyBindingSummary([object]$Binding) {
  if (-not $Binding) { return $null }
  if ($Binding.PSObject.Properties['parseFailed'] -and $Binding.parseFailed -eq $true) {
    return [pscustomobject]@{
      present=$true; readable=$false; status='parse_failed'; authorizing=$false
      reason='legacy_global_binding_is_read_only_and_cannot_authorize_continuity'
    }
  }
  $expired = $true
  try { $expired = ([datetime]::Parse([string]$Binding.expiresAt) -lt (Get-Date)) } catch {}
  $versionMatch = ([string]$Binding.packageVersion -eq [string]$Manifest.version)
  $rootMatch = Test-SuperBrainSamePath ([string]$Binding.memoryRoot) $MemoryRoot
  $rawRisk = Test-PrivatePattern ($Binding | ConvertTo-Json -Depth 12 -Compress)
  return [pscustomobject]@{
    present=$true
    readable=$true
    bindingId=[string]$Binding.bindingId
    sessionId=[string]$Binding.sessionId
    taskId=[string]$Binding.taskId
    workspaceKey=if($Binding.PSObject.Properties['workspaceKey']){[string]$Binding.workspaceKey}else{''}
    status=[string]$Binding.status
    updatedAt=[string]$Binding.updatedAt
    expiresAt=[string]$Binding.expiresAt
    expired=$expired
    packageVersionMatch=$versionMatch
    memoryRootMatch=$rootMatch
    rawContentRisk=$rawRisk
    authorizing=$false
    sourceClass='legacy_read_only_migration_evidence'
    reason='legacy_global_binding_is_read_only_and_cannot_authorize_continuity'
  }
}

$legacy = Read-LegacySessionBinding
$legacySummary = New-LegacyBindingSummary $legacy
$status = if ($legacySummary) { 'retired_legacy_present' } else { 'retired' }
$reason = if ($MemoryMode -eq 'off') {
  'memory:off; global session binding is retired and no write was attempted'
} elseif ($Action -in @('Bind','Refresh')) {
  'global session binding write retired; use the current H7 workspace/session/task scoped execution contract'
} elseif ($Action -in @('Clear','Expire')) {
  'legacy global binding is migration evidence and remains read-only; no destructive mutation was performed'
} else {
  'global session binding retired; legacy metadata is diagnostic-only'
}

$result = [pscustomobject]@{
  ok=$true
  action=$Action
  status=$status
  reason=$reason
  checkedAt=Get-SuperBrainUtcTimestamp
  path=$bindingPath
  binding=$null
  legacyBinding=$legacySummary
  authoritativeSource='h7_scoped_execution_contract'
  authorizationState='non_authorizing'
  writePerformed=$false
  requestedScope=[pscustomobject]@{
    sessionId=[string]$SessionId
    taskId=[string]$TaskId
    memoryMode=$MemoryMode
  }
  guards=[pscustomobject]@{
    noRawChat=$true
    noSecrets=$true
    currentUserInstructionWins=$true
    legacyBindingReadOnly=$true
    legacyBindingCannotAuthorize=$true
    noGlobalSessionBindingWrite=$true
    h7ScopedContractRequired=$true
  }
}

# Compatibility markers retained for package introspection while the old writer
# is retired: bindingId, expiresAt, TtlMinutes, MaxTokens, TopK,
# Write-JsonUtf8NoBom. This script intentionally never calls the writer.
if ($Json) { $result | ConvertTo-Json -Depth 10 }
else { Write-Host "SESSION_BINDING_RETIRED action=$Action legacyPresent=$([bool]$legacySummary) authoritativeSource=$($result.authoritativeSource)" }
exit 0
