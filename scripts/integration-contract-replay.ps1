param(
  [ValidateSet('Run','Status')]
  [string]$Action = 'Run',
  [string]$Module = '',
  [string]$SnapshotPath = '',
  [string]$Input = '',
  [string]$ActualOutput = '',
  [string]$ExpectedOutput = '',
  [string]$IntegratedCommand = '',
  [int]$ExpectedExitCode = 0,
  [string]$TaskId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$moduleRoot = Join-Path $workspace 'verified-modules'
$replayRoot = Join-Path $workspace 'integration-contract-replay'
$scopeRoot = Join-Path $workspace 'guard-state'
$taskReplayRoot = Join-Path $scopeRoot 'integration-contract-replay'
foreach ($dir in @($workspace,$replayRoot,$taskReplayRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$outPath = Join-Path $workspace 'last-integration-contract-replay.json'

function Limit-Text([string]$Value,[int]$Max=700){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Get-Hash([string]$Raw){ $sha=[Security.Cryptography.SHA256]::Create(); -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Raw))[0..7] | ForEach-Object { $_.ToString('x2') }) }
function Add-Mismatch($List,[string]$Code,[string]$Evidence,[string]$Severity='high'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 500 }) }
function Safe-Name([string]$Value){ $v=if([string]::IsNullOrWhiteSpace($Value)){'unnamed-module'}else{$Value}; (($v -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant() }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Get-TaskReplayRoot([string]$Value) { $safe=Safe-TaskId $Value; if([string]::IsNullOrWhiteSpace($safe)){ return $replayRoot }; $dir=Join-Path $taskReplayRoot $safe; if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; return $dir }
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
if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = Read-CurrentTaskId }
function Read-Snapshot {
  if(-not [string]::IsNullOrWhiteSpace($SnapshotPath) -and (Test-Path -LiteralPath $SnapshotPath)){ return Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  if(-not [string]::IsNullOrWhiteSpace($Module) -and (Test-Path -LiteralPath $moduleRoot)){
    $safe=Safe-Name $Module
    $match=Get-ChildItem -LiteralPath $moduleRoot -Filter "$safe*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if($match){ $script:SnapshotPath=$match.FullName; return Get-Content -LiteralPath $match.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
  }
  return $null
}

if($Action -eq 'Status'){
  $latest=Get-ChildItem -LiteralPath (Get-TaskReplayRoot $TaskId) -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $obj=if($latest){try{Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json}catch{$null}}else{$null}
  $result=[pscustomobject]@{ ok=($null -ne $obj); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.integration-contract-replay.v1'; version=(Get-SuperBrainManifest $Root).version; taskId=Limit-Text $TaskId 120; latest=$obj; path=if($latest){$latest.FullName}else{Get-TaskReplayRoot $TaskId} }
  Write-JsonUtf8NoBom $outPath $result 12
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "INTEGRATION_CONTRACT_REPLAY ok=$($result.ok) path=$($result.path)"}
  if(-not $result.ok){exit 1}; exit 0
}

$snapshot=Read-Snapshot
$mismatches=New-Object System.Collections.ArrayList
$commandEvidence = $null
if (-not [string]::IsNullOrWhiteSpace($IntegratedCommand)) {
  try {
    $scriptBlock = [scriptblock]::Create($IntegratedCommand)
    $output = & $scriptBlock 2>&1
    $exitCode = if ($null -ne $global:LASTEXITCODE) { [int]$global:LASTEXITCODE } else { 0 }
    $ActualOutput = (($output | ForEach-Object { [string]$_ }) -join "`n")
    $commandEvidence = [pscustomobject]@{ command=Limit-Text $IntegratedCommand 900; exitCode=$exitCode; expectedExitCode=$ExpectedExitCode; stdout=Limit-Text $ActualOutput 1200 }
    if ($exitCode -ne $ExpectedExitCode) { Add-Mismatch $mismatches 'integration_command_exit_code_mismatch' "expectedExitCode=$ExpectedExitCode actualExitCode=$exitCode" 'high' }
  } catch {
    $commandEvidence = [pscustomobject]@{ command=Limit-Text $IntegratedCommand 900; exitCode=$null; expectedExitCode=$ExpectedExitCode; error=Limit-Text $_.Exception.Message 700 }
    Add-Mismatch $mismatches 'integration_command_failed' $_.Exception.Message 'high'
  }
}
if(-not $snapshot){ Add-Mismatch $mismatches 'missing_verified_module_snapshot' 'No snapshot found; cannot replay behavior contract.' 'medium' }
if([string]::IsNullOrWhiteSpace($ExpectedOutput) -and $snapshot -and @($snapshot.outputs).Count -gt 0){ $ExpectedOutput = [string](@($snapshot.outputs)[0]) }
if([string]::IsNullOrWhiteSpace($ExpectedOutput)){ Add-Mismatch $mismatches 'missing_expected_output' 'ExpectedOutput or snapshot.outputs is required for behavior replay.' 'high' }
if([string]::IsNullOrWhiteSpace($ActualOutput)){ Add-Mismatch $mismatches 'missing_actual_output' 'ActualOutput from integrated path is required for behavior replay.' 'high' }
$normalizedExpected = ($ExpectedOutput.Trim() -replace '\s+',' ')
$normalizedActual = ($ActualOutput.Trim() -replace '\s+',' ')
if(-not [string]::IsNullOrWhiteSpace($normalizedExpected) -and -not [string]::IsNullOrWhiteSpace($normalizedActual) -and $normalizedExpected -ne $normalizedActual){ Add-Mismatch $mismatches 'integration_behavior_mismatch' "expected=[$normalizedExpected] actual=[$normalizedActual]" 'high' }
$id=Get-Hash (($Module,$SnapshotPath,$Input,$ExpectedOutput,$ActualOutput,$IntegratedCommand,$ExpectedExitCode,$TaskId) -join '||')
$replayPath=Join-Path (Get-TaskReplayRoot $TaskId) ($id+'.json')
$result=[pscustomobject]@{
  ok=($mismatches.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.integration-contract-replay.v1'; version=(Get-SuperBrainManifest $Root).version
  replayId=$id; taskId=Limit-Text $TaskId 120; module=if($snapshot){$snapshot.module}else{$Module}; snapshotPath=$SnapshotPath; snapshotHash=if($snapshot){$snapshot.snapshotHash}else{''}
  input=Limit-Text $Input 700; expectedOutput=Limit-Text $ExpectedOutput 900; actualOutput=Limit-Text $ActualOutput 900; integratedCommand=Limit-Text $IntegratedCommand 900; commandEvidence=$commandEvidence; normalizedMatch=($normalizedExpected -eq $normalizedActual -and -not [string]::IsNullOrWhiteSpace($normalizedExpected))
  mismatches=@($mismatches); unresolvedBehaviorMismatch=($mismatches.Count -gt 0)
  candidateSignals=@($mismatches | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind=if($_.code -eq 'integration_behavior_mismatch'){'integration_behavior_mismatch'}else{'integration_contract_gap'}; severity=$_.severity; code=$_.code; expectedInvariant='Integrated behavior should replay the verified module contract or be re-verified as changed behavior.'; observedViolation=$_.evidence; evidence=@('last-integration-contract-replay.json','verified-modules') } })
  guard='INTEGRATION_BEHAVIOR_MISMATCH means the integrated path does not match the verified module contract; do not claim user-facing success until resolved.'
  nextAction=if($mismatches.Count -gt 0){'Fix integration behavior or create a new verified snapshot, then replay the contract again.'}else{'Behavior contract replay matches; use this as integration/user acceptance evidence.'}
  path=$replayPath
}
Write-JsonUtf8NoBom $replayPath $result 12
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "INTEGRATION_CONTRACT_REPLAY ok=$($result.ok) mismatches=$(@($mismatches).Count) path=$replayPath"}
if(-not $result.ok){exit 1}; exit 0
