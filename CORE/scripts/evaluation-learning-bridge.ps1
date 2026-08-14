[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet('Preview','Stage','Status')]
  [string]$Action = 'Preview',
  [string]$AggregatePath = '',
  [string]$WorkspaceRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$lastPath = Join-Path $workspace 'last-evaluation-learning-bridge.json'

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CompactHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Read-BridgeJson([string]$Path, [string]$Code) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "${Code}: file is missing." }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "${Code}: file is invalid." }
}

function Get-CurrentPhase6Binding {
  return [pscustomobject][ordered]@{
    schema = 'super-brain.memory-e2e-binding.v1'
    packageVersion = [string]$manifest.version
    manifestSha256 = Get-FileSha256 (Join-Path $Root 'manifest.json')
    brainCoreSha256 = Get-FileSha256 (Join-Path $Root 'runtime\brain_core.py')
    phase6RuntimeSha256 = Get-FileSha256 (Join-Path $Root 'runtime\phase6_memory_eval.py')
    writeMemorySha256 = Get-FileSha256 (Join-Path $Root 'scripts\write-memory.ps1')
    memoryPolicySha256 = Get-FileSha256 (Join-Path $Root 'memory-policy.json')
  }
}

function Assert-CurrentBinding($Binding) {
  if (-not $Binding -or [string]$Binding.schema -ne 'super-brain.memory-e2e-binding.v1') { throw 'EVALUATION_BINDING_INVALID: aggregate has no Phase 6 binding.' }
  $current = Get-CurrentPhase6Binding
  foreach ($name in @('packageVersion','manifestSha256','brainCoreSha256','phase6RuntimeSha256','writeMemorySha256','memoryPolicySha256')) {
    if ([string]$Binding.$name -ne [string]$current.$name) { throw "EVALUATION_BINDING_STALE: $name no longer matches the current package." }
  }
  return $current
}

function Get-UnmetGateIds($Aggregate) {
  $ids = New-Object System.Collections.ArrayList
  foreach ($value in @($Aggregate.unmetGateIds)) {
    $id = [string]$value
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$') { throw 'EVALUATION_GATE_ID_INVALID: aggregate contains an unsafe gate identifier.' }
    if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
  }
  if ($Aggregate.twoFreshSealedE2EAtLeast90 -ne $true -and $ids.Count -eq 0) { [void]$ids.Add('phase6_e2e_gate_unmet') }
  return @($ids | Sort-Object)
}

function New-BridgeResult([string]$Disposition, [string]$AggregateHash = '', [string[]]$Signals = @(), $Proposal = $null) {
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.evaluation-learning-bridge.v1'
    action = $Action
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    disposition = $Disposition
    aggregateSha256 = $AggregateHash
    signals = @($Signals)
    proposal = $Proposal
    safety = [pscustomobject]@{
      stagedOnly = $true
      noAutomaticRuleMutation = $true
      noAutomaticHotRefresh = $true
      rawCasePayloadStored = $false
      rawAnswerStored = $false
    }
  }
}

if ($Action -eq 'Status') {
  $last = if (Test-Path -LiteralPath $lastPath) { Read-BridgeJson $lastPath 'BRIDGE_STATUS_INVALID' } else { $null }
  $result = New-BridgeResult 'status' '' @() $null
  $lastDisposition = if ($last) { [string]$last.disposition } else { '' }
  $result | Add-Member -NotePropertyName hasLastResult -NotePropertyValue ([bool]$last) -Force
  $result | Add-Member -NotePropertyName lastDisposition -NotePropertyValue $lastDisposition -Force
} else {
  if ([string]::IsNullOrWhiteSpace($AggregatePath)) { throw 'AGGREGATE_PATH_REQUIRED: Preview or Stage requires -AggregatePath.' }
  $fullAggregatePath = [IO.Path]::GetFullPath($AggregatePath)
  $aggregate = Read-BridgeJson $fullAggregatePath 'AGGREGATE_INVALID'
  if ([string]$aggregate.schema -ne 'super-brain.memory-e2e-aggregate.v1' -or [string]$aggregate.status -ne 'internal_acceptance_only') { throw 'AGGREGATE_SCHEMA_INVALID: expected a Phase 6 internal aggregate.' }
  if ($aggregate.rawCasePayloadStored -ne $false -or $aggregate.objectiveIntelligenceScore -ne $false) { throw 'AGGREGATE_PRIVACY_OR_SCOPE_INVALID: aggregate cannot enter the learning bridge.' }
  if ($aggregate.fresh -ne $true) { throw 'AGGREGATE_STALE: only fresh Phase 6 aggregates can stage learning.' }
  if ([int]$aggregate.reportCount -lt 2 -or @($aggregate.holdoutSetHashes).Count -lt 2 -or @($aggregate.familySetHashes).Count -lt 2) { throw 'AGGREGATE_INCOMPLETE: two distinct sealed report and family sets are required.' }
  if (@($aggregate.holdoutSetHashes | Select-Object -Unique).Count -ne @($aggregate.holdoutSetHashes).Count -or @($aggregate.familySetHashes | Select-Object -Unique).Count -ne @($aggregate.familySetHashes).Count) { throw 'AGGREGATE_REUSE_DETECTED: reused holdout or family evidence cannot drive learning.' }
  [void](Assert-CurrentBinding $aggregate.evidenceBinding)
  $signals = Get-UnmetGateIds $aggregate
  $aggregateHash = Get-FileSha256 $fullAggregatePath

  if ($aggregate.twoFreshSealedE2EAtLeast90 -eq $true -and $signals.Count -eq 0) {
    $result = New-BridgeResult 'healthy_no_proposal' $aggregateHash @() $null
  } else {
    $fingerprint = Get-CompactHash ($aggregateHash + '|' + (($signals | Sort-Object) -join '|') + '|' + [string]$aggregate.bindingHash)
    $proposalId = 'phase6-learning-' + $fingerprint.Substring(0,16)
    $evidence = 'aggregateSha256=' + $aggregateHash + '; bindingHash=' + [string]$aggregate.bindingHash + '; unmet=' + ($signals -join ',')
    $proposalText = 'Investigate the unmet Phase 6 memory E2E gates with a minimal reproducible replay. Do not train on consumed holdouts, change hot routing, or mutate rules until a separate governed validation artifact exists.'
    if ($Action -eq 'Preview') {
      $proposal = [pscustomobject]@{ id=$proposalId; status='staged_preview'; evidenceFingerprint=$fingerprint; rawCasePayloadStored=$false }
      $result = New-BridgeResult 'preview_only' $aggregateHash $signals $proposal
    } else {
      $raw = @(& (Join-Path $PSScriptRoot 'skill-evolution.ps1') -Mode Propose -ProposalId $proposalId -Title 'Phase 6 memory E2E gate needs a bounded repair proposal' -Affected 'runtime/phase6_memory_eval.py; tests/phase6_memory_eval_regression.py' -Proposal $proposalText -Evidence $evidence -Source 'evaluation-learning-bridge.ps1' -EvidenceFingerprint $fingerprint -WorkspaceRoot $workspace -Json 2>&1)
      $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
      if ($LASTEXITCODE -ne 0) { throw "SKILL_EVOLUTION_STAGE_FAILED: $text" }
      try { $proposal = $text | ConvertFrom-Json } catch { throw 'SKILL_EVOLUTION_STAGE_INVALID: skill evolution returned invalid JSON.' }
      if ($proposal.ok -ne $true -or [string]$proposal.status -ne 'staged' -or [string]$proposal.id -ne $proposalId) { throw 'SKILL_EVOLUTION_STAGE_REJECTED: the proposal was not staged.' }
      $result = New-BridgeResult 'staged_only' $aggregateHash $signals ([pscustomobject]@{ id=[string]$proposal.id; status=[string]$proposal.status; reused=($proposal.reused -eq $true); rawCasePayloadStored=$false })
    }
  }
}

if ($Action -eq 'Stage') {
  if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
  Write-JsonUtf8NoBom $lastPath $result 10
}

if ($Json) { $result | ConvertTo-Json -Depth 12 }
else { Write-Host "EVALUATION_LEARNING_BRIDGE action=$($result.action) disposition=$($result.disposition) signals=$(@($result.signals).Count)" }
