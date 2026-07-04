param(
  [string]$Module = '',
  [string]$SnapshotPath = '',
  [string]$CurrentEntrypoint = '',
  [string[]]$CurrentInputs = @(),
  [string[]]$CurrentDependencies = @(),
  [string[]]$CurrentStateAssumptions = @(),
  [string]$IntegrationCommand = '',
  [string[]]$UserAcceptanceEvidence = @(),
  [switch]$ModuleSmokeOk,
  [switch]$IntegrationSmokeOk,
  [switch]$UserAcceptanceOk,
  [string]$TaskId = '',
  [switch]$AllowMissingSnapshot,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$moduleRoot = Join-Path $workspace 'verified-modules'
$scopeRoot = Join-Path $workspace 'guard-state'
$taskParityRoot = Join-Path $scopeRoot 'integration-parity-check'
foreach ($dir in @($workspace,$taskParityRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$outPath = Join-Path $workspace 'last-integration-parity-check.json'
function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Read-CurrentTaskId {
  $contextPath = Join-Path $workspace 'current-task-context.json'
  if (Test-Path -LiteralPath $contextPath) {
    try {
      $ctx = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($ctx -and [string]$ctx.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$ctx.taskId)) { return [string]$ctx.taskId }
    } catch {}
  }
  return ''
}
function Get-TaskParityPath([string]$Value) { $safe=Safe-TaskId $Value; if([string]::IsNullOrWhiteSpace($safe)){ return '' }; return (Join-Path $taskParityRoot ($safe + '.json')) }
if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = Read-CurrentTaskId }
function Add-Drift($List,[string]$Code,[string]$Evidence,[string]$Severity='high'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 500 }) }
function Test-ConcreteAcceptanceEvidence([string[]]$EvidenceItems) {
  foreach($item in @($EvidenceItems)) {
    if([string]::IsNullOrWhiteSpace($item)){ continue }
    $v = $item.Trim()
    $lower = $v.ToLowerInvariant()
    if($lower -match 'command|cmd:|powershell|pwsh|bash|日志|log|screenshot|截图|ui path|ui路径|页面路径|actual output|实际输出|stdout|stderr|exitcode|exit code|result path|结果路径|output path|artifact|evidence file|\.json|\.log|\.png|\.jpg|\.jpeg|\.webp'){ return $true }
    if($v -match '^[A-Za-z]:\\.+'){ return $true }
  }
  return $false
}
function Read-Snapshot {
  if(-not [string]::IsNullOrWhiteSpace($SnapshotPath) -and (Test-Path -LiteralPath $SnapshotPath)){ return Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  if(-not [string]::IsNullOrWhiteSpace($Module) -and (Test-Path -LiteralPath $moduleRoot)){
    $safe=(($Module -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
    $match=Get-ChildItem -LiteralPath $moduleRoot -Filter "$safe*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if($match){ return Get-Content -LiteralPath $match.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
  }
  return $null
}
$snapshot=Read-Snapshot
$drifts=New-Object System.Collections.ArrayList
if(-not $snapshot){ if(-not $AllowMissingSnapshot){ Add-Drift $drifts 'missing_verified_module_snapshot' 'No verified module snapshot found; cannot prove original verification contract.' 'medium' } }
else{
  if(-not [string]::IsNullOrWhiteSpace($CurrentEntrypoint) -and $CurrentEntrypoint -ne [string]$snapshot.entrypoint){ Add-Drift $drifts 'module_context_changed' "entrypoint changed from [$($snapshot.entrypoint)] to [$CurrentEntrypoint]" }
  foreach($dep in @($snapshot.dependencies)){ if(-not [string]::IsNullOrWhiteSpace($dep) -and @($CurrentDependencies).Count -gt 0 -and ($CurrentDependencies -notcontains [string]$dep)){ Add-Drift $drifts 'dependency_changed' "verified dependency missing in current context: $dep" 'medium' } }
  foreach($state in @($snapshot.stateAssumptions)){ if(-not [string]::IsNullOrWhiteSpace($state) -and @($CurrentStateAssumptions).Count -gt 0 -and ($CurrentStateAssumptions -notcontains [string]$state)){ Add-Drift $drifts 'state_assumption_changed' "verified state assumption missing in current context: $state" 'medium' } }
}
$combined=(($CurrentEntrypoint,$IntegrationCommand,($CurrentInputs -join ' '),($CurrentDependencies -join ' ')) -join ' ').ToLowerInvariant()
if($combined -match 'glue|scatter|零散|拼装|临时|绕一下|adapter adapter|copy.*logic'){ Add-Drift $drifts 'scattered_assembly' 'Current integration text suggests scattered assembly/glue changes instead of preserving verified module boundary.' }
if($ModuleSmokeOk -and (-not $IntegrationSmokeOk -or -not $UserAcceptanceOk)){ Add-Drift $drifts 'missing_acceptance_path' 'module smoke OK exists, but integration smoke OK or user-facing acceptance OK is missing.' 'medium' }
if($UserAcceptanceOk -and @($UserAcceptanceEvidence).Count -eq 0){ Add-Drift $drifts 'missing_user_acceptance_evidence' 'UserAcceptanceOk requires concrete evidence such as command, log, screenshot, UI path, or actual output.' 'high' }
elseif($UserAcceptanceOk -and -not (Test-ConcreteAcceptanceEvidence $UserAcceptanceEvidence)){ Add-Drift $drifts 'weak_user_acceptance_evidence' 'UserAcceptanceEvidence must include a concrete command, log, screenshot/image, UI path, result path, exit code, stdout/stderr, or actual output evidence.' 'high' }
$unresolved=($drifts.Count -gt 0)
$parityPath = Get-TaskParityPath $TaskId
if ([string]::IsNullOrWhiteSpace($parityPath)) { $parityPath = $outPath }
$result=[pscustomobject]@{
  ok=(-not $unresolved); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.integration-parity-check.v1'; version=(Get-SuperBrainManifest $Root).version
  module=if($snapshot){$snapshot.module}else{$Module}; snapshotHash=if($snapshot){$snapshot.snapshotHash}else{''}; taskId=Limit-Text $TaskId 120; currentEntrypoint=Limit-Text $CurrentEntrypoint 360; integrationCommand=Limit-Text $IntegrationCommand 700
  moduleVerification=[pscustomobject]@{ status=if($ModuleSmokeOk){'module smoke OK'}else{'missing module smoke OK'}; ok=[bool]$ModuleSmokeOk }
  integrationVerification=[pscustomobject]@{ status=if($IntegrationSmokeOk){'integration smoke OK'}else{'missing integration smoke OK'}; ok=[bool]$IntegrationSmokeOk }
  userAcceptanceVerification=[pscustomobject]@{ status=if($UserAcceptanceOk){'user-facing acceptance OK'}else{'missing user-facing acceptance OK'}; ok=[bool]$UserAcceptanceOk; realUserPathVerification=([bool]$UserAcceptanceOk -and (Test-ConcreteAcceptanceEvidence $UserAcceptanceEvidence)); evidence=@($UserAcceptanceEvidence | ForEach-Object { Limit-Text $_ 500 }) }
  drifts=@($drifts); unresolvedIntegrationDrift=$unresolved
  candidateSignals=@($drifts | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind=if($_.code -eq 'missing_acceptance_path'){'false_completion'}elseif($_.code -eq 'scattered_assembly'){'scattered_assembly'}else{'integration_drift'}; severity=$_.severity; code=$_.code; expectedInvariant='A verified module must preserve its verified contract when promoted into the main system; module smoke, integration smoke, and user-facing acceptance are distinct.'; observedViolation=$_.evidence; evidence=@('last-integration-parity-check.json','verified-modules') } })
  guard='INTEGRATION_DRIFT_DETECTED means module verification no longer proves main-system behavior; re-run integration and real-user-path acceptance evidence before completion.'; nextAction=if($unresolved){'Report INTEGRATION_DRIFT_DETECTED and re-verify integration parity before claiming completion.'}else{'Integration parity holds; keep module/integration/user acceptance evidence separate.'}; path=$parityPath
}
Write-JsonUtf8NoBom $parityPath $result 12
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "INTEGRATION_PARITY_CHECK ok=$($result.ok) drifts=$(@($drifts).Count) path=$outPath"}
if(-not $result.ok){exit 1}; exit 0
