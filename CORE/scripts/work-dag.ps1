[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Seed','Refresh','Get','Validate')]
  [string]$Action = 'Get',
  [Parameter(Mandatory=$true)][string]$TaskId,
  [Parameter(Mandatory=$true)][string]$WorkspaceKey,
  [Parameter(Mandatory=$true)][string]$SessionKey,
  [string]$DefinitionBase64 = '',
  [int]$ExpectedDagRevision = -1,
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-SuperBrainMemoryBaseRoot $Root } else { [IO.Path]::GetFullPath($StateRoot) }
$contractScript = Join-Path $PSScriptRoot 'execution-contract.ps1'
$runtime = Join-Path $Root 'runtime\work_dag.py'

function Invoke-WorkDagContractGet {
  $raw = @(& $contractScript -Action Get -TaskId $TaskId -WorkspaceKey $WorkspaceKey -SessionKey $SessionKey -StateRoot $memoryBase -Json 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'H7_WORK_DAG_CONTRACT_EMPTY' }
  try { return $text | ConvertFrom-Json -ErrorAction Stop } catch { throw 'H7_WORK_DAG_CONTRACT_PARSE_FAILED' }
}

function ConvertTo-WorkDagContractView {
  param([Parameter(Mandatory=$true)]$Contract)
  # The execution contract may contain bounded evidence and historical
  # receipts.  The Python DAG projection owns neither, and putting the whole
  # object into a Base64 command-line argument can exceed the Windows command
  # limit.  Transmit only the canonical H7 fields that `work_dag.py` validates.
  $items = @(
    @($Contract.canonicalPlan.items) | ForEach-Object {
      [ordered]@{
        itemId = [string]$_.itemId
        label = [string]$_.label
        status = [string]$_.status
        ordinal = [int]$_.ordinal
      }
    }
  )
  return [ordered]@{
    ok = $true
    taskId = [string]$Contract.taskId
    taskInstanceId = [string]$Contract.taskInstanceId
    workspaceKey = [string]$Contract.workspaceKey
    ownerSessionKey = [string]$Contract.ownerSessionKey
    revision = [int]$Contract.revision
    planReceipt = [ordered]@{ planFingerprint = [string]$Contract.planReceipt.planFingerprint }
    canonicalPlan = [ordered]@{ items = $items }
  }
}

try {
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'H7_WORK_DAG_RUNTIME_UNAVAILABLE' }
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($null -eq $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
  if ($null -eq $python) { throw 'H7_WORK_DAG_PYTHON_UNAVAILABLE' }
  $contract = Invoke-WorkDagContractGet
  if ($contract.ok -ne $true) { throw ('H7_WORK_DAG_CONTRACT_UNAVAILABLE:' + [string]$contract.code) }
  $safeName = Get-SuperBrainStableHash (([string]$TaskId) + '|' + ([string]$WorkspaceKey)) 48
  $dagRoot = Join-Path $memoryBase 'workspace\runtime-state\work-dags'
  if (-not (Test-Path -LiteralPath $dagRoot)) { New-Item -ItemType Directory -Force -Path $dagRoot | Out-Null }
  $statePath = Join-Path $dagRoot ($safeName + '.json')
  $dagContract = ConvertTo-WorkDagContractView -Contract $contract
  $contractJson = $dagContract | ConvertTo-Json -Depth 8 -Compress
  $contractB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($contractJson))
  $arguments = @('-X','utf8','-B',$runtime,'--action',$Action.ToLowerInvariant(),'--state-path',$statePath,'--contract-base64',$contractB64,'--expected-dag-revision',([string]$ExpectedDagRevision))
  if (-not [string]::IsNullOrWhiteSpace($DefinitionBase64)) { $arguments += @('--definition-base64',$DefinitionBase64) }
  $raw = @(& $python.Source @arguments 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  try { $result = $text | ConvertFrom-Json -ErrorAction Stop } catch { throw 'H7_WORK_DAG_RUNTIME_PARSE_FAILED' }
  $result | Add-Member -NotePropertyName taskId -NotePropertyValue $TaskId -Force
  $result | Add-Member -NotePropertyName workspaceKey -NotePropertyValue $WorkspaceKey -Force
  $result | Add-Member -NotePropertyName stateAuthority -NotePropertyValue 'h7_canonical_plan_only' -Force
  $result | Add-Member -NotePropertyName backgroundWorkers -NotePropertyValue $false -Force
  $result | Add-Member -NotePropertyName rawPromptStored -NotePropertyValue $false -Force
  $result | Add-Member -NotePropertyName rawTranscriptStored -NotePropertyValue $false -Force
  if ($Json) { $result | ConvertTo-Json -Depth 20 } else { Write-Host "WORK_DAG action=$Action ok=$($result.ok) code=$($result.code)" }
  if ($result.ok -ne $true) { exit 1 }
  exit 0
} catch {
  $failure = [pscustomobject]@{ ok=$false; action=$Action; code=$_.Exception.Message; taskId=$TaskId; workspaceKey=$WorkspaceKey; stateAuthority='h7_canonical_plan_only'; backgroundWorkers=$false; rawPromptStored=$false; rawTranscriptStored=$false }
  if ($Json) { $failure | ConvertTo-Json -Depth 8 } else { Write-Host "WORK_DAG_FAILED $($_.Exception.Message)" }
  exit 1
}
