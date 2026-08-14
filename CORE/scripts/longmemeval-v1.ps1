[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Status','AcquireHarness','FetchData','Preflight','PrepareAnswerInputs')]
  [string]$Action = 'Status',
  [string]$HarnessRoot = '',
  [string]$DataPath = '',
  [string]$OutputRoot = '',
  [string]$RunId = '',
  [string]$Model = 'gpt-5.6-terra',
  [ValidateSet('low','medium','high','xhigh','max')]
  [string]$ReasoningEffort = 'max',
  [ValidateRange(64,8192)]
  [int]$MaxOutputTokens = 512,
  [ValidateRange(5,300)]
  [int]$TimeoutSeconds = 180,
  [ValidateRange(1,20)]
  [int]$BatchSize = 5,
  [ValidateRange(1,1)]
  [int]$MaxBatchAttempts = 1,
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$stateRoot = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $stateRoot 'workspace'
$externalRoot = Join-Path $workspace 'external-harness'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Join-Path $externalRoot 'LongMemEval' }
if ([string]::IsNullOrWhiteSpace($DataPath)) { $DataPath = Join-Path $externalRoot 'LongMemEval-data\longmemeval_s_cleaned.json' }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $workspace 'phase8-longmemeval-v1' }
$HarnessRoot = [IO.Path]::GetFullPath($HarnessRoot)
$DataPath = [IO.Path]::GetFullPath($DataPath)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$Runtime = Join-Path $Root 'runtime\longmemeval_v1_input.py'
$officialRepo = 'https://github.com/xiaowu0162/LongMemEval'
$officialCommit = '9e0b455f4ef0e2ab8f2e582289761153549043fc'

function Write-LmeV1Result($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 24 }
  elseif ($Value.ok) { Write-Host "LONGMEMEVAL_V1 action=$Action status=$($Value.status)" }
  else { Write-Host "LONGMEMEVAL_V1_FAILED code=$($Value.code)" }
  exit $ExitCode
}

function Get-LmeV1Python {
  $candidates = New-Object Collections.ArrayList
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) { [void]$candidates.Add([string]$python.Source) }
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    try {
      $candidate = @(& $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1)[0]
      if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { [void]$candidates.Add([string]$candidate) }
    } catch {}
  }
  foreach ($candidate in @($candidates | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      # Windows PowerShell strips embedded double quotes in native -c arguments.
      $version = @(& $candidate -c 'import sys; print(''%d.%d'' % sys.version_info[:2])' 2>$null | Select-Object -Last 1)[0]
      if ([string]$version -match '^3\.(1[0-9]|[2-9][0-9])$') { return [IO.Path]::GetFullPath($candidate) }
    } catch {}
  }
  throw 'LME_V1_PYTHON_REQUIRED|Python 3.10 or newer is required for the isolated input preparer.'
}

function Invoke-LmeV1Python([string]$Python,[string]$RuntimeAction,[switch]$Write) {
  $arguments = @(
    $Runtime,
    '--action',$RuntimeAction,
    '--package-root',$Root,
    '--harness-root',$HarnessRoot,
    '--data-path',$DataPath,
    '--output-root',$OutputRoot,
    '--model',$Model,
    '--reasoning-effort',$ReasoningEffort,
    '--max-output-tokens',$MaxOutputTokens,
    '--timeout-seconds',$TimeoutSeconds,
    '--batch-size',$BatchSize,
    '--max-batch-attempts',$MaxBatchAttempts
  )
  if (-not [string]::IsNullOrWhiteSpace($RunId)) { $arguments += @('--run-id',$RunId) }
  if ($Write) { $arguments += '--apply' }
  $raw = @(& $Python @arguments 2>$null)
  $text = ($raw -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'LME_V1_RUNTIME_NO_RESULT|The isolated input preparer produced no JSON result.' }
  try { return ($text | ConvertFrom-Json) }
  catch { throw 'LME_V1_RUNTIME_RESULT_INVALID|The isolated input preparer returned invalid JSON.' }
}

function Get-LmeV1HarnessState {
  $present = Test-Path -LiteralPath (Join-Path $HarnessRoot 'README.md') -PathType Leaf
  $head = ''
  $dirty = $true
  if ($present) {
    try {
      $head = [string](@(& git -C $HarnessRoot rev-parse HEAD 2>$null | Select-Object -Last 1)[0]).Trim()
      $dirty = -not [string]::IsNullOrWhiteSpace([string](@(& git -C $HarnessRoot status --porcelain 2>$null) -join "`n"))
    } catch {}
  }
  return [pscustomobject]@{ path=$HarnessRoot; present=$present; expectedCommit=$officialCommit; actualCommit=$head; clean=(-not $dirty); pinned=($present -and -not $dirty -and $head -eq $officialCommit) }
}

function Invoke-LmeV1AcquireHarness {
  $state = Get-LmeV1HarnessState
  if ($state.pinned) {
    return [pscustomobject]@{ ok=$true; action='AcquireHarness'; status='official_harness_ready'; harness=$state; changed=$false; modelRequestCount=0 }
  }
  if (-not $Apply) {
    return [pscustomobject]@{ ok=$false; action='AcquireHarness'; code='LME_V1_APPLY_REQUIRED'; status='preview_only'; harness=$state; nextAction='Rerun AcquireHarness -Apply to clone the pinned official source into private state.'; modelRequestCount=0 }
  }
  if (Test-Path -LiteralPath $HarnessRoot) {
    throw 'LME_V1_HARNESS_CONFLICT|Existing official harness is missing, dirty, or pinned to another commit; refusing to overwrite it.'
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HarnessRoot) | Out-Null
  & git clone --filter=blob:none --no-checkout $officialRepo $HarnessRoot
  if ($LASTEXITCODE -ne 0) { throw 'LME_V1_HARNESS_CLONE_FAILED|Could not clone the official LongMemEval repository.' }
  & git -C $HarnessRoot fetch --depth 1 origin $officialCommit
  if ($LASTEXITCODE -ne 0) { throw 'LME_V1_HARNESS_FETCH_FAILED|Could not fetch the pinned LongMemEval commit.' }
  & git -C $HarnessRoot checkout --detach $officialCommit
  if ($LASTEXITCODE -ne 0) { throw 'LME_V1_HARNESS_PIN_FAILED|Could not select the pinned LongMemEval commit.' }
  $state = Get-LmeV1HarnessState
  if (-not $state.pinned) { throw 'LME_V1_HARNESS_VERIFY_FAILED|The acquired LongMemEval checkout is not clean and pinned.' }
  return [pscustomobject]@{ ok=$true; action='AcquireHarness'; status='official_harness_ready'; harness=$state; changed=$true; modelRequestCount=0 }
}

try {
  $result = switch ($Action) {
    'AcquireHarness' { Invoke-LmeV1AcquireHarness }
    'Status' { Invoke-LmeV1Python (Get-LmeV1Python) 'status' }
    'FetchData' {
      if (-not $Apply) { [pscustomobject]@{ ok=$false; action='FetchData'; code='LME_V1_APPLY_REQUIRED'; status='preview_only'; nextAction='Rerun FetchData -Apply to download official s_cleaned into private state.'; modelRequestCount=0 } }
      else { Invoke-LmeV1Python (Get-LmeV1Python) 'fetch-data' -Write }
    }
    'Preflight' { Invoke-LmeV1Python (Get-LmeV1Python) 'preflight' }
    'PrepareAnswerInputs' {
      if (-not $Apply) { [pscustomobject]@{ ok=$false; action='PrepareAnswerInputs'; code='LME_V1_APPLY_REQUIRED'; status='preview_only'; nextAction='Rerun PrepareAnswerInputs -Apply with an explicit RunId.'; modelRequestCount=0 } }
      elseif ([string]::IsNullOrWhiteSpace($RunId)) { [pscustomobject]@{ ok=$false; action='PrepareAnswerInputs'; code='LME_V1_RUN_ID_REQUIRED'; status='blocked'; nextAction='Provide an explicit RunId for the immutable private preparation directory.'; modelRequestCount=0 } }
      else { Invoke-LmeV1Python (Get-LmeV1Python) 'prepare' -Write }
    }
  }
  $resultExitCode = if ($result.ok) { 0 } else { 1 }
  Write-LmeV1Result $result $resultExitCode
} catch {
  $parts = $_.Exception.Message -split '\|',2
  $code = if ($parts.Count -eq 2) { [string]$parts[0] } else { 'LME_V1_FAILED' }
  $message = if ($parts.Count -eq 2) { [string]$parts[1] } else { [string]$_.Exception.Message }
  Write-LmeV1Result ([pscustomobject]@{ ok=$false; action=$Action; code=$code; message=$message; modelRequestCount=0 }) 1
}
