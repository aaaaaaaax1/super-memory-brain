[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Set','ObserveUser','Get','Resolve','Guard','Clear','ResumeParent','CloseTurn','PrepareMerge','CompleteMerge','ValidatePlanReceipt','ValidateIntentReceipt','BindContext','RebindPackageVersion')]
  [string]$Action = 'Get',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [switch]$RebindSession,
  [string]$FocusId = '',
  [string]$LatestUserInstruction = '',
  [string]$AssistantCommitment = '',
  [string]$LastConfirmedSentence = '',
  [ValidateSet('auto','assistant_commitment','user_confirmation','checkpoint_summary','assistant_visible_reply','user_attested_visible_reply')]
  [string]$LastConfirmedSource = 'auto',
  # H7 supplies this compact assistant-only state through ASCII transport so
  # legacy powershell.exe command-line decoding cannot corrupt Chinese text.
  [string]$ProgressCheckpointBase64 = '',
  # H7 transports a compact, structured project-progress proof separately from
  # the four-field prose checkpoint.  It never contains raw prompts or
  # transcripts; the contract validates it against the live project root.
  [string]$ProjectProgressProofBase64 = '',
  [string]$ProjectRoot = '',
  [string]$NextAction = '',
  [string]$CurrentPhase = '',
  [string]$CurrentStep = '',
  [string]$PhaseCloseoutPath = '',
  # Formal phase transitions are H7-only.  Legacy values remain parseable
  # solely so a caller receives an explicit retirement error instead of a
  # parameter-binding failure or a silent fallback to P7/Hook evidence.
  [ValidateSet('auto','h7_current','host_user_attested','user_authorized_synthetic')]
  [string]$PhaseEvidencePolicy = 'auto',
  [ValidateSet('auto','none','build','package','release','deploy','test')]
  [string]$StageKind = 'auto',
  [string]$DecisionIntentFingerprint = '',
  [string[]]$CompletedSteps = @(),
  [string[]]$PendingSteps = @(),
  [string[]]$Blockers = @(),
  [string[]]$Evidence = @(),
  [string[]]$VerificationResults = @(),
  [string]$StateCardSource = '',
  [string[]]$Constraints = @(),
  [string[]]$InvalidatedWorkItems = @(),
  [ValidateSet('auto','continue','side_branch','replace')]
  [string]$InstructionMode = 'auto',
  [ValidateSet('auto','additive','replace')]
  [string]$ChecklistUpdateMode = 'auto',
  [string[]]$AcceptanceCriteria = @(),
  [ValidateSet('partial','completed')]
  [string]$BranchStatus = 'partial',
  [string]$CompletionEvidence = '',
  [ValidateSet('unknown','ephemeral_insertion','active_work_progressed','side_branch_completed','side_branch_partial','blocked')]
  [string]$TurnOutcome = 'unknown',
  [ValidateSet('unknown','none','stop','replace')]
  [string]$UserControl = 'unknown',
  [switch]$RetainForMerge,
  [string]$MergeIntentId = '',
  [string]$MergeTargetFocusId = '',
  [string]$MergeTargetLabel = '',
  [ValidateSet('auto','direct_parent','root_main','explicit')]
  [string]$MergeTargetScope = 'auto',
  [string[]]$ArtifactRefs = @(),
  [string[]]$InterfaceContracts = @(),
  [string[]]$Dependencies = @(),
  [string[]]$VerificationSteps = @(),
  [string[]]$MergeConditions = @(),
  [string]$MergeIntegrationEvidence = '',
  [string]$FocusLabel = '',
  [string[]]$TopicKeys = @(),
  [ValidateSet('auto','current_contract','latest_explicit_user_instruction','explicit_user','restored_parent')]
  [string]$PrioritySource = 'auto',
  [string]$PriorityReason = '',
  [string]$UserInstruction = '',
  [switch]$RequiresReconciliation,
  [string]$VisibleUserInstruction = '',
  [string]$VisibleAssistantCommitment = '',
  [string]$CheckpointPath = '',
  [string]$ProposedWorkId = '',
  [int]$ExpectedRevision = -1,
  [string]$ExpectedPlanFingerprint = '',
  # A package release changes the manifest version before H7 can see the
  # formerly-current contract.  This narrow action migrates exactly one
  # verified contract across that identity boundary; ordinary Set calls must
  # never use it as a version-mismatch bypass.
  [string]$FromPackageVersion = '',
  [string]$ExpectedVisibleProgressReceiptHash = '',
  [string]$TransitionId = '',
  [switch]$RequireStructuralGuards,
  [string]$IntentContractJson = '',
  [switch]$RequireIntentContract,
  [switch]$EnableCanonicalPlan,
  [string]$CanonicalMutationPath = '',
  [string]$CanonicalSourceManifestPath = '',
  [switch]$RequireCanonicalPlanSource,
  [int]$MaxAgeHours = 168,
  [ValidateSet('none','after_authority','after_prepare','after_materialize','after_commit')]
  [string]$ContinuityFaultPoint = 'none',
  [string]$StateRoot = '',
  [string]$ReceiptContractPath = '',
  [string]$Source = '',
  [string]$ContextAcceptedGoal = '',
  [string[]]$ContextAcceptedRoute = @(),
  [string[]]$ContextNonGoals = @(),
  [string[]]$ContextMustPreserve = @(),
  [string[]]$ContextMustNotDriftTo = @(),
  [string[]]$ContextEvidence = @(),
  [string]$ContextAgentId = '',
  [string]$ContextSessionId = '',
  [string]$ContextPlatform = '',
  [string]$ContextOwnerWorkspace = '',
  [int]$ContextMaxAgeHours = 24,
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\runtime-wake-core.ps1')
. (Join-Path $PSScriptRoot 'internal\intent-resolution.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$phaseCloseoutCore = Join-Path $PSScriptRoot 'internal\phase-closeout-core.ps1'
if (-not (Test-Path -LiteralPath $phaseCloseoutCore -PathType Leaf)) { throw 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_CORE_MISSING' }
. $phaseCloseoutCore
$memoryBase = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-SuperBrainMemoryBaseRoot $Root } else { [IO.Path]::GetFullPath($StateRoot) }
$workspace = Join-Path $memoryBase 'workspace'
$contractRoot = Join-Path $workspace 'runtime-state\execution-contracts'
$pointerPath = Join-Path $workspace 'last-execution-contract.json'
$manifest = Get-SuperBrainManifest $Root
$script:ConstraintsWereBound = $PSBoundParameters.ContainsKey('Constraints')
$script:AcceptanceCriteriaWereBound = $PSBoundParameters.ContainsKey('AcceptanceCriteria')
$script:FocusLabelWasBound = $PSBoundParameters.ContainsKey('FocusLabel')
$script:TopicKeysWereBound = $PSBoundParameters.ContainsKey('TopicKeys')
$script:PrioritySourceWasBound = $PSBoundParameters.ContainsKey('PrioritySource') -and $PrioritySource -ne 'auto'
$script:PriorityReasonWasBound = $PSBoundParameters.ContainsKey('PriorityReason')
$script:FocusIdWasBound = $PSBoundParameters.ContainsKey('FocusId')
$script:LatestUserInstructionWasBound = $PSBoundParameters.ContainsKey('LatestUserInstruction')
$script:NextActionWasBound = $PSBoundParameters.ContainsKey('NextAction')
$script:CurrentPhaseWasBound = $PSBoundParameters.ContainsKey('CurrentPhase')
$script:CurrentStepWasBound = $PSBoundParameters.ContainsKey('CurrentStep')
$script:PhaseCloseoutPathWasBound = $PSBoundParameters.ContainsKey('PhaseCloseoutPath')
$script:PhaseEvidencePolicyWasBound = $PSBoundParameters.ContainsKey('PhaseEvidencePolicy') -and $PhaseEvidencePolicy -ne 'auto'
$script:CompletedStepsWereBound = $PSBoundParameters.ContainsKey('CompletedSteps')
$script:PendingStepsWereBound = $PSBoundParameters.ContainsKey('PendingSteps')
$script:BlockersWereBound = $PSBoundParameters.ContainsKey('Blockers')
$script:EvidenceWereBound = $PSBoundParameters.ContainsKey('Evidence')
$script:VerificationResultsWereBound = $PSBoundParameters.ContainsKey('VerificationResults')
$script:StateCardSourceWasBound = $PSBoundParameters.ContainsKey('StateCardSource')
$script:RetainForMergeWasBound = $PSBoundParameters.ContainsKey('RetainForMerge') -and $RetainForMerge
$script:MergeIntentIdWasBound = $PSBoundParameters.ContainsKey('MergeIntentId')
$script:MergeTargetFocusIdWasBound = $PSBoundParameters.ContainsKey('MergeTargetFocusId')
$script:MergeTargetLabelWasBound = $PSBoundParameters.ContainsKey('MergeTargetLabel')
$script:MergeTargetScopeWasBound = $PSBoundParameters.ContainsKey('MergeTargetScope') -and $MergeTargetScope -ne 'auto'
$script:ArtifactRefsWereBound = $PSBoundParameters.ContainsKey('ArtifactRefs')
$script:InterfaceContractsWereBound = $PSBoundParameters.ContainsKey('InterfaceContracts')
$script:DependenciesWereBound = $PSBoundParameters.ContainsKey('Dependencies')
$script:VerificationStepsWereBound = $PSBoundParameters.ContainsKey('VerificationSteps')
$script:MergeConditionsWereBound = $PSBoundParameters.ContainsKey('MergeConditions')
$script:InstructionModeWasBound = $PSBoundParameters.ContainsKey('InstructionMode') -and $InstructionMode -ne 'auto'
$script:ChecklistUpdateModeWasBound = $PSBoundParameters.ContainsKey('ChecklistUpdateMode') -and $ChecklistUpdateMode -ne 'auto'
$script:LastConfirmedSentenceWasBound = $PSBoundParameters.ContainsKey('LastConfirmedSentence')
$script:ProgressCheckpointBase64WasBound = $PSBoundParameters.ContainsKey('ProgressCheckpointBase64') -and -not [string]::IsNullOrWhiteSpace($ProgressCheckpointBase64)
$script:ProjectProgressProofBase64WasBound = $PSBoundParameters.ContainsKey('ProjectProgressProofBase64') -and -not [string]::IsNullOrWhiteSpace($ProjectProgressProofBase64)
$script:ProjectRootWasBound = $PSBoundParameters.ContainsKey('ProjectRoot') -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)
$script:LastConfirmedSourceWasBound = $PSBoundParameters.ContainsKey('LastConfirmedSource') -and $LastConfirmedSource -ne 'auto'
$script:EnableCanonicalPlanWasBound = $PSBoundParameters.ContainsKey('EnableCanonicalPlan') -and $EnableCanonicalPlan
$script:CanonicalMutationPathWasBound = $PSBoundParameters.ContainsKey('CanonicalMutationPath') -and -not [string]::IsNullOrWhiteSpace($CanonicalMutationPath)
$script:CanonicalSourceManifestPathWasBound = $PSBoundParameters.ContainsKey('CanonicalSourceManifestPath') -and -not [string]::IsNullOrWhiteSpace($CanonicalSourceManifestPath)
$script:RequireCanonicalPlanSourceWasBound = $PSBoundParameters.ContainsKey('RequireCanonicalPlanSource') -and $RequireCanonicalPlanSource
$script:RequiresReconciliationWasBound = $PSBoundParameters.ContainsKey('RequiresReconciliation') -and $RequiresReconciliation
$script:StateRootWasBound = $PSBoundParameters.ContainsKey('StateRoot') -and -not [string]::IsNullOrWhiteSpace($StateRoot)
$script:IntentContractJsonWasBound = $PSBoundParameters.ContainsKey('IntentContractJson') -and -not [string]::IsNullOrWhiteSpace($IntentContractJson)
$script:RequireIntentContractWasBound = $PSBoundParameters.ContainsKey('RequireIntentContract') -and $RequireIntentContract
$script:LatestUserInstructionWasBound = $PSBoundParameters.ContainsKey('LatestUserInstruction')
$script:ForeignContextTaskId = ''
$script:ForeignContextSessionState = ''
$script:ExecutionContractBoundParameterNames = @($PSBoundParameters.Keys)
$script:PackageVersionRebindActive = $false

if ($script:ProgressCheckpointBase64WasBound) {
  try {
    $checkpointJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProgressCheckpointBase64))
    $checkpoint = $checkpointJson | ConvertFrom-Json -ErrorAction Stop
    $checkpointNames = @($checkpoint.PSObject.Properties.Name | Sort-Object)
    $requiredCheckpointNames = @('current_phase','current_step','last_confirmed_sentence','next_action','source')
    if ($checkpointNames.Count -ne $requiredCheckpointNames.Count -or (Compare-Object $checkpointNames $requiredCheckpointNames)) {
      throw 'EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_FIELDS_INVALID'
    }
    foreach ($name in $requiredCheckpointNames) {
      if (-not ($checkpoint.PSObject.Properties.Name -contains $name) -or [string]::IsNullOrWhiteSpace([string]$checkpoint.$name)) {
        throw 'EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_FIELDS_INVALID'
      }
    }
    if ([string]$checkpoint.source -notin @('assistant_visible_reply','user_attested_visible_reply')) {
      throw 'EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_SOURCE_INVALID'
    }
    $checkpointTextLimits = [ordered]@{
      last_confirmed_sentence = 320
      current_phase = 120
      current_step = 220
      next_action = 360
    }
    foreach ($name in $checkpointTextLimits.Keys) {
      $raw = [string]$checkpoint.$name
      $normalizedCheckpointText = ($raw.Trim() -replace '\s+',' ')
      if ($raw.Length -gt [int]$checkpointTextLimits[$name] -or $raw -ne $normalizedCheckpointText -or $raw -match '[\r\n]') {
        throw 'EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_FIELDS_INVALID'
      }
    }
    $LastConfirmedSentence = [string]$checkpoint.last_confirmed_sentence
    $LastConfirmedSource = [string]$checkpoint.source
    $CurrentPhase = [string]$checkpoint.current_phase
    $CurrentStep = [string]$checkpoint.current_step
    $NextAction = [string]$checkpoint.next_action
    $script:LastConfirmedSentenceWasBound = $true
    $script:LastConfirmedSourceWasBound = $true
    $script:CurrentPhaseWasBound = $true
    $script:CurrentStepWasBound = $true
    $script:NextActionWasBound = $true
  } catch {
    $script:ProgressCheckpointDecodeError = $_.Exception.Message
  }
}
$script:ProjectProgressProofInput = $null
$script:ProjectProgressProofDecodeError = ''
if ($script:ProjectProgressProofBase64WasBound) {
  try {
    $projectProgressJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProjectProgressProofBase64))
    $script:ProjectProgressProofInput = $projectProgressJson | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $script:ProjectProgressProofDecodeError = $_.Exception.Message
  }
}
$script:ReturnStackMaxDepth = 4
$script:UnfinishedWorkPlanMaxCount = 12
$script:MergeIntentMaxCount = 6
$script:ActiveChecklistMaxItems = 24
$script:TransitionReceiptMaxCount = 8
$script:CanonicalPlanMaxBytes = 16384
$script:CanonicalSupersessionMaxCount = 4
$script:CanonicalPlanSourceMaxBytes = 65536

function Limit-ContractText([string]$Value,[int]$Max=480) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Protect-Instruction([string]$Value) {
  $clean = Limit-ContractText $Value 480
  if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
  $clean = $clean -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*','Bearer [REDACTED]'
  $clean = $clean -replace '(?i)\bsk-[A-Za-z0-9_-]{8,}\b','[REDACTED_KEY]'
  $clean = $clean -replace '(?i)\b(api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+','$1=[REDACTED]'
  return $clean
}

function Limit-ContractList([object[]]$Items,[int]$MaxItems=12,[int]$MaxChars=220) {
  return @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Limit-ContractText ([string]$_) $MaxChars } | Select-Object -Unique -First $MaxItems)
}

function ConvertTo-ProjectProgressCanonicalValue([object]$Value) {
  # Keep the PowerShell proof hash byte-for-byte compatible with Python's
  # json.dumps(..., ensure_ascii=False, sort_keys=True, separators=(',', ':')).
  # The proof schema intentionally contains only strings, booleans, integers,
  # arrays, and objects, so no host-specific value formatting is admitted.
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [char] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $ordered = [ordered]@{}
    foreach ($name in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      $ordered[$name] = ConvertTo-ProjectProgressCanonicalValue $Value[$name]
    }
    return [pscustomobject]$ordered
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    # Return one array object rather than letting PowerShell unwrap a singleton
    # (or turn an empty array into $null) on the function output stream.
    $items = @($Value | ForEach-Object { ConvertTo-ProjectProgressCanonicalValue $_ })
    return ,$items
  }
  $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property') })
  if ($properties.Count -gt 0) {
    $ordered = [ordered]@{}
    foreach ($property in @($properties | Sort-Object Name)) {
      $ordered[[string]$property.Name] = ConvertTo-ProjectProgressCanonicalValue $property.Value
    }
    return [pscustomobject]$ordered
  }
  return [string]$Value
}

function Get-ProjectProgressPayloadHash([object]$Body) {
  # H7 validates these hashes with Python's canonical JSON serializer.  Windows
  # PowerShell serializes some ordinary text (for example an apostrophe) using
  # HTML escapes, so hashing ConvertTo-Json output directly can create a
  # receipt that the runtime correctly rejects after it has been persisted.
  # Feed the parsed object to the same Python serialization contract instead.
  $canonical = ConvertTo-ProjectProgressCanonicalValue $Body
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) { throw 'EXECUTION_CONTRACT_PYTHON_REQUIRED_FOR_H7_CANONICAL_HASH' }
  $json = $canonical | ConvertTo-Json -Depth 16 -Compress
  $program = @'
import hashlib
import json
import sys

with open(sys.argv[1], encoding='utf-8') as stream:
    value = json.load(stream)
print(hashlib.sha256(json.dumps(
    value,
    ensure_ascii=False,
    sort_keys=True,
    separators=(',', ':'),
    allow_nan=False,
).encode('utf-8')).hexdigest())
'@
  $inputPath = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($inputPath,$json,[Text.UTF8Encoding]::new($false))
    $output = @(& $python.Source -c $program $inputPath 2>&1)
  } finally {
    Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
  }
  if ($LASTEXITCODE -ne 0) {
    throw ('EXECUTION_CONTRACT_H7_CANONICAL_HASH_FAILED: ' + (($output | ForEach-Object { [string]$_ }) -join "`n"))
  }
  $hash = (($output | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
  if ($hash -notmatch '^[a-f0-9]{64}$') { throw 'EXECUTION_CONTRACT_H7_CANONICAL_HASH_INVALID' }
  return $hash
}

function Test-ProjectProgressPropertySet([object]$Value,[string[]]$ExpectedNames) {
  if (-not $Value) { return $false }
  $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
  $expected = @($ExpectedNames | Sort-Object)
  if ($actual.Count -ne $expected.Count) { return $false }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if ($actual[$index] -ne $expected[$index]) { return $false }
  }
  return $true
}

function Get-ProjectProgressRootBinding([string]$ProjectRootValue) {
  if ([string]::IsNullOrWhiteSpace($ProjectRootValue)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_ROOT_REQUIRED'; path=''; rootHash='' }
  }
  try { $path = [IO.Path]::GetFullPath($ProjectRootValue).TrimEnd('\','/') } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_ROOT_INVALID'; path=''; rootHash='' }
  }
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_ROOT_INVALID'; path=''; rootHash='' }
  }
  $normalized = $path.Replace('\','/').ToLowerInvariant()
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_ROOT_CURRENT'; path=$path; rootHash=(Get-SuperBrainStableHash $normalized 64) }
}

function Get-ProjectProgressEvidenceRef([string]$RelativePath,[string]$Sha256) {
  return 'project:file:' + $RelativePath.Replace('\','/') + '@sha256:' + $Sha256.ToLowerInvariant()
}

function Test-ProjectProgressProof(
  [object]$Proof,
  [string]$Phase,
  [string]$CurrentStep,
  [object[]]$CompletedSteps,
  [string]$NextAction,
  [string]$ProjectRootValue = ''
) {
  $result = [ordered]@{ valid=$false; current=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_PROOF_MISSING'; missing=@('project_progress_proof'); proof=$null }
  if (-not $Proof) { return [pscustomobject]$result }
  $expectedNames = @('schema','state','phase','currentStep','completedItems','projectEvidence','verificationResults','nextAction','missing','projectRootHash','rawPromptStored','rawTranscriptStored','payloadHash')
  if (-not (Test-ProjectProgressPropertySet $Proof $expectedNames)) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_PROOF_FIELDS_INVALID'; $result.missing=@('project_progress_proof_fields'); return [pscustomobject]$result
  }
  if ([string]$Proof.schema -ne 'super-brain.project-progress-proof.v1' -or [string]$Proof.state -notin @('current','withheld') -or [string]$Proof.payloadHash -notmatch '^[a-f0-9]{64}$' -or $Proof.rawPromptStored -ne $false -or $Proof.rawTranscriptStored -ne $false) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_PROOF_INVALID'; $result.missing=@('project_progress_proof_integrity'); return [pscustomobject]$result
  }
  $body = [ordered]@{}
  foreach ($name in $expectedNames | Where-Object { $_ -ne 'payloadHash' }) { $body[$name] = $Proof.$name }
  if ([string]$Proof.payloadHash -ne (Get-ProjectProgressPayloadHash $body)) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_HASH_MISMATCH'; $result.missing=@('project_progress_proof_hash'); return [pscustomobject]$result
  }
  $expectedPhase = Limit-ContractText $Phase 120
  $expectedStep = Limit-ContractText $CurrentStep 220
  $expectedNext = Limit-ContractText $NextAction 220
  $expectedStepKeys = @((Limit-ContractList $CompletedSteps $script:ActiveChecklistMaxItems 180) | ForEach-Object { Get-ChecklistStepKey ([string]$_) } | Sort-Object)
  $actualItems = if($Proof.completedItems -is [System.Collections.IEnumerable] -and -not ($Proof.completedItems -is [string])){@($Proof.completedItems)}else{@()}
  $actualStepKeys = @($actualItems | ForEach-Object { if($_ -and $_.PSObject.Properties['itemKey']){[string]$_.itemKey}else{''} } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
  if ([string]$Proof.phase -ne $expectedPhase -or [string]$Proof.currentStep -ne $expectedStep -or [string]$Proof.nextAction -ne $expectedNext -or $actualStepKeys.Count -ne $expectedStepKeys.Count -or (Compare-Object $actualStepKeys $expectedStepKeys)) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_SCOPE_MISMATCH'; $result.missing=@('project_progress_scope'); return [pscustomobject]$result
  }
  $root = Get-ProjectProgressRootBinding $ProjectRootValue
  if ($root.ok -and [string]$Proof.projectRootHash -ne [string]$root.rootHash) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_ROOT_MISMATCH'; $result.missing=@('project_root'); return [pscustomobject]$result
  }
  $evidenceRefs = @{}
  $proofEvidence = if($Proof.projectEvidence -is [System.Collections.IEnumerable] -and -not ($Proof.projectEvidence -is [string])){@($Proof.projectEvidence)}else{@()}
  $proofVerification = if($Proof.verificationResults -is [System.Collections.IEnumerable] -and -not ($Proof.verificationResults -is [string])){@($Proof.verificationResults)}else{@()}
  if ($proofEvidence.Count -gt 16 -or $proofVerification.Count -gt 16 -or $actualItems.Count -gt $script:ActiveChecklistMaxItems) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_PROOF_LIMIT'; $result.missing=@('bounded_project_progress_proof'); return [pscustomobject]$result
  }
  foreach ($entry in $proofEvidence) {
    if (-not (Test-ProjectProgressPropertySet $entry @('kind','relativePath','sha256')) -or [string]$entry.kind -ne 'project_file' -or [string]$entry.sha256 -notmatch '^[a-f0-9]{64}$') {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_INVALID'; $result.missing=@('project_evidence'); return [pscustomobject]$result
    }
    $relative = ([string]$entry.relativePath).Replace('/','\').Trim()
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)' -or $relative -match ':') {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_PATH_INVALID'; $result.missing=@('project_evidence_path'); return [pscustomobject]$result
    }
    $reference = Get-ProjectProgressEvidenceRef ($relative.Replace('\','/')) ([string]$entry.sha256)
    if ($evidenceRefs.ContainsKey($reference)) {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_DUPLICATE'; $result.missing=@('project_evidence_unique'); return [pscustomobject]$result
    }
    if ($root.ok) {
      try {
        $candidate = [IO.Path]::GetFullPath((Join-Path $root.path $relative))
        $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        $rootPrefix = $root.path + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedCandidate.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolvedCandidate -PathType Leaf) -or (Get-FileHash -LiteralPath $resolvedCandidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$entry.sha256) { throw 'proof evidence changed or escaped project root' }
      } catch {
        $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_HASH_MISMATCH'; $result.missing=@('project_evidence_hash'); return [pscustomobject]$result
      }
    }
    $evidenceRefs[$reference] = $true
  }
  $verificationById = @{}
  foreach ($entry in $proofVerification) {
    if (-not (Test-ProjectProgressPropertySet $entry @('id','status')) -or [string]$entry.id -notmatch '^[A-Za-z0-9._:-]{1,120}$' -or [string]$entry.status -notin @('passed','failed','not_run') -or $verificationById.ContainsKey([string]$entry.id)) {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_VERIFICATION_INVALID'; $result.missing=@('verification_result'); return [pscustomobject]$result
    }
    $verificationById[[string]$entry.id] = [string]$entry.status
  }
  foreach ($item in $actualItems) {
    if (-not (Test-ProjectProgressPropertySet $item @('itemKey','evidenceRefs','verificationIds'))) {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID'; $result.missing=@('completed_item'); return [pscustomobject]$result
    }
    $itemEvidence = if($item.evidenceRefs -is [System.Collections.IEnumerable] -and -not ($item.evidenceRefs -is [string])){@($item.evidenceRefs)}else{@()}
    $itemVerifications = if($item.verificationIds -is [System.Collections.IEnumerable] -and -not ($item.verificationIds -is [string])){@($item.verificationIds)}else{@()}
    if ($itemEvidence.Count -eq 0 -or $itemVerifications.Count -eq 0 -or @($itemEvidence | Where-Object { -not $evidenceRefs.ContainsKey([string]$_) }).Count -gt 0 -or @($itemVerifications | Where-Object { -not $verificationById.ContainsKey([string]$_) -or [string]$verificationById[[string]$_] -ne 'passed' }).Count -gt 0) {
      $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_BINDING_INVALID'; $result.missing=@('completed_item_evidence_or_verification'); return [pscustomobject]$result
    }
  }
  if ([string]$Proof.state -eq 'current' -and ($proofEvidence.Count -eq 0 -or @($Proof.missing).Count -ne 0)) {
    $result.code = 'EXECUTION_CONTRACT_PROJECT_PROGRESS_CURRENT_INCOMPLETE'; $result.missing=@('current_project_evidence'); return [pscustomobject]$result
  }
  $result.valid = $true
  $result.current = ([string]$Proof.state -eq 'current' -and @($Proof.missing).Count -eq 0)
  $result.code = if($result.current){'EXECUTION_CONTRACT_PROJECT_PROGRESS_CURRENT'}else{'EXECUTION_CONTRACT_PROJECT_PROGRESS_WITHHELD'}
  $result.missing = @($Proof.missing)
  $result.proof = $Proof
  return [pscustomobject]$result
}

function New-ProjectProgressProof(
  [string]$ProjectRoot,
  [string]$Phase,
  [string]$CurrentStep,
  [object[]]$CompletedSteps,
  [object[]]$Evidence,
  [object[]]$VerificationResults,
  [string]$NextAction,
  [object]$InputProof = $null,
  [object]$ExistingProof = $null
) {
  # This is a contract-owned proof, not a second task store.  A current proof
  # requires a structured H7 input: every reported completed item is bound to
  # an existing project file SHA-256 and a passed verification identifier.
  $phaseValue = Limit-ContractText $Phase 120
  $stepValue = Limit-ContractText $CurrentStep 220
  $nextValue = Limit-ContractText $NextAction 220
  $completed = @(Limit-ContractList $CompletedSteps $script:ActiveChecklistMaxItems 180)
  $root = Get-ProjectProgressRootBinding $ProjectRoot
  if (-not $InputProof) {
    $existing = Test-ProjectProgressProof $ExistingProof $phaseValue $stepValue $completed $nextValue $ProjectRoot
    if ($existing.valid) { return [pscustomobject]@{ ok=$true; code=[string]$existing.code; proof=$existing.proof; evidenceRefs=@($existing.proof.projectEvidence | ForEach-Object { Get-ProjectProgressEvidenceRef ([string]$_.relativePath) ([string]$_.sha256) }); verificationRefs=@($existing.proof.verificationResults | ForEach-Object { 'proof:' + [string]$_.status + ':' + [string]$_.id }) } }
    $missing = @('project_progress_proof')
    if ([string]::IsNullOrWhiteSpace($phaseValue) -or [string]::IsNullOrWhiteSpace($stepValue)) { $missing += 'phase_or_step' }
    if ([string]::IsNullOrWhiteSpace($nextValue)) { $missing += 'next_action' }
    if (-not $root.ok) { $missing += 'project_root' }
    if ($completed.Count -gt 0) { $missing += 'completed_item_evidence'; $missing += 'verification_result_for_completed_work' }
    $body = [ordered]@{
      schema='super-brain.project-progress-proof.v1'; state='withheld'; phase=$phaseValue; currentStep=$stepValue; completedItems=@(); projectEvidence=@(); verificationResults=@(); nextAction=$nextValue; missing=@($missing | Select-Object -Unique); projectRootHash=if($root.ok){[string]$root.rootHash}else{''}; rawPromptStored=$false; rawTranscriptStored=$false
    }
    $body.payloadHash = Get-ProjectProgressPayloadHash $body
    return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_WITHHELD'; proof=[pscustomobject]$body; evidenceRefs=@(); verificationRefs=@() }
  }
  $inputNames = @('schema','phase','currentStep','completedItems','projectEvidence','verificationResults','nextAction')
  if (-not (Test-ProjectProgressPropertySet $InputProof $inputNames) -or [string]$InputProof.schema -ne 'super-brain.project-progress-input.v1') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_INPUT_INVALID'; missing=@('project_progress_input_schema'); proof=$null }
  }
  if (-not $root.ok) { return [pscustomobject]@{ ok=$false; code=[string]$root.code; missing=@('project_root'); proof=$null } }
  if ([string]$InputProof.phase -ne $phaseValue -or [string]$InputProof.currentStep -ne $stepValue -or [string]$InputProof.nextAction -ne $nextValue) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_INPUT_SCOPE_MISMATCH'; missing=@('phase_or_step_or_next_action'); proof=$null }
  }
  $inputEvidence = if($InputProof.projectEvidence -is [System.Collections.IEnumerable] -and -not ($InputProof.projectEvidence -is [string])){@($InputProof.projectEvidence)}else{@()}
  $inputVerification = if($InputProof.verificationResults -is [System.Collections.IEnumerable] -and -not ($InputProof.verificationResults -is [string])){@($InputProof.verificationResults)}else{@()}
  $inputItems = if($InputProof.completedItems -is [System.Collections.IEnumerable] -and -not ($InputProof.completedItems -is [string])){@($InputProof.completedItems)}else{@()}
  if ($inputEvidence.Count -gt 16 -or $inputVerification.Count -gt 16 -or $inputItems.Count -gt $script:ActiveChecklistMaxItems) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_INPUT_LIMIT'; missing=@('bounded_project_progress_input'); proof=$null }
  }
  $evidenceByRef = @{}
  $projectEvidence = @()
  foreach ($entry in $inputEvidence) {
    if (-not (Test-ProjectProgressPropertySet $entry @('kind','relativePath','sha256')) -or [string]$entry.kind -ne 'project_file' -or [string]$entry.sha256 -notmatch '^[a-f0-9]{64}$') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_INVALID'; missing=@('project_evidence'); proof=$null }
    }
    $relative = ([string]$entry.relativePath).Replace('/','\').Trim()
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Length -gt 240 -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)' -or $relative -match ':') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_PATH_INVALID'; missing=@('project_evidence_path'); proof=$null }
    }
    try {
      $candidate = [IO.Path]::GetFullPath((Join-Path $root.path $relative))
      $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
      $rootPrefix = $root.path + [IO.Path]::DirectorySeparatorChar
      if (-not $resolvedCandidate.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolvedCandidate -PathType Leaf)) { throw 'project evidence path is unavailable or escapes the project root' }
      $actualHash = (Get-FileHash -LiteralPath $resolvedCandidate -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_MISSING'; missing=@('project_evidence_file'); proof=$null }
    }
    if ($actualHash -ne [string]$entry.sha256) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_HASH_MISMATCH'; missing=@('project_evidence_hash'); proof=$null }
    }
    $normalized = $relative.Replace('\','/')
    $ref = Get-ProjectProgressEvidenceRef $normalized $actualHash
    if ($evidenceByRef.ContainsKey($ref)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_EVIDENCE_DUPLICATE'; missing=@('project_evidence_unique'); proof=$null } }
    $evidenceByRef[$ref] = $true
    $projectEvidence += [pscustomobject]@{ kind='project_file'; relativePath=$normalized; sha256=$actualHash }
  }
  $verificationById = @{}
  $verificationResults = @()
  foreach ($entry in $inputVerification) {
    if (-not (Test-ProjectProgressPropertySet $entry @('id','status')) -or [string]$entry.id -notmatch '^[A-Za-z0-9._:-]{1,120}$' -or [string]$entry.status -notin @('passed','failed','not_run')) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_VERIFICATION_INVALID'; missing=@('verification_result'); proof=$null }
    }
    $id = [string]$entry.id
    if ($verificationById.ContainsKey($id)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_VERIFICATION_DUPLICATE'; missing=@('verification_result_unique'); proof=$null } }
    $verificationById[$id] = [string]$entry.status
    $verificationResults += [pscustomobject]@{ id=$id; status=[string]$entry.status }
  }
  $expectedStepKeys = @($completed | ForEach-Object { Get-ChecklistStepKey ([string]$_) } | Sort-Object)
  $seenStepKeys = @{}
  $completedItems = @()
  foreach ($entry in $inputItems) {
    if (-not (Test-ProjectProgressPropertySet $entry @('itemKey','evidenceRefs','verificationIds'))) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID'; missing=@('completed_item'); proof=$null }
    }
    $itemKey = Get-ChecklistStepKey ([string]$entry.itemKey)
    $itemEvidence = if($entry.evidenceRefs -is [System.Collections.IEnumerable] -and -not ($entry.evidenceRefs -is [string])){@($entry.evidenceRefs | ForEach-Object { [string]$_ } | Sort-Object -Unique)}else{@()}
    $itemVerifications = if($entry.verificationIds -is [System.Collections.IEnumerable] -and -not ($entry.verificationIds -is [string])){@($entry.verificationIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)}else{@()}
    if ([string]::IsNullOrWhiteSpace($itemKey) -or $itemKey -notin $expectedStepKeys -or $seenStepKeys.ContainsKey($itemKey) -or $itemEvidence.Count -eq 0 -or $itemEvidence.Count -gt 8 -or $itemVerifications.Count -eq 0 -or $itemVerifications.Count -gt 8) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_BINDING_INVALID'; missing=@('completed_item_evidence_or_verification'); proof=$null }
    }
    foreach ($ref in $itemEvidence) { if (-not $evidenceByRef.ContainsKey($ref)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_EVIDENCE_UNKNOWN'; missing=@('completed_item_evidence'); proof=$null } } }
    foreach ($verificationId in $itemVerifications) { if (-not $verificationById.ContainsKey($verificationId) -or [string]$verificationById[$verificationId] -ne 'passed') { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_COMPLETED_ITEM_VERIFICATION_UNPASSED'; missing=@('completed_item_verification'); proof=$null } } }
    $seenStepKeys[$itemKey] = $true
    $completedItems += [pscustomobject]@{ itemKey=$itemKey; evidenceRefs=@($itemEvidence); verificationIds=@($itemVerifications) }
  }
  if ($projectEvidence.Count -eq 0 -or $completedItems.Count -ne $expectedStepKeys.Count) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_BINDING_INCOMPLETE'; missing=@('project_evidence_or_completed_item_binding'); proof=$null }
  }
  $body = [ordered]@{
    schema='super-brain.project-progress-proof.v1'; state='current'; phase=$phaseValue; currentStep=$stepValue; completedItems=@($completedItems | Sort-Object itemKey); projectEvidence=@($projectEvidence | Sort-Object relativePath); verificationResults=@($verificationResults | Sort-Object id); nextAction=$nextValue; missing=@(); projectRootHash=[string]$root.rootHash; rawPromptStored=$false; rawTranscriptStored=$false
  }
  $body.payloadHash = Get-ProjectProgressPayloadHash $body
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_CURRENT'; proof=[pscustomobject]$body; evidenceRefs=@($projectEvidence | ForEach-Object { Get-ProjectProgressEvidenceRef ([string]$_.relativePath) ([string]$_.sha256) }); verificationRefs=@($verificationResults | ForEach-Object { 'proof:' + [string]$_.status + ':' + [string]$_.id }) }
}

function Get-VisibleProgressScopeBindingHash(
  [string]$TaskIdValue,
  [string]$TaskInstanceIdValue,
  [string]$WorkspaceKeyValue,
  [string]$OwnerSessionKeyValue,
  [string]$PackageVersionValue
) {
  if (
    [string]::IsNullOrWhiteSpace($TaskIdValue) -or
    [string]::IsNullOrWhiteSpace($TaskInstanceIdValue) -or
    [string]::IsNullOrWhiteSpace($WorkspaceKeyValue) -or
    [string]::IsNullOrWhiteSpace($OwnerSessionKeyValue) -or
    [string]::IsNullOrWhiteSpace($PackageVersionValue)
  ) { return '' }
  return Get-ProjectProgressPayloadHash ([ordered]@{
    schema='super-brain.visible-progress-scope-binding.v1'
    taskId=[string]$TaskIdValue
    taskInstanceId=[string]$TaskInstanceIdValue
    workspaceKey=([string]$WorkspaceKeyValue).ToLowerInvariant()
    ownerSessionKey=([string]$OwnerSessionKeyValue).ToLowerInvariant()
    packageVersion=[string]$PackageVersionValue
  })
}

function New-VisibleProgressReceipt(
  [string]$Sentence,
  [string]$SourceValue,
  [string]$Phase,
  [string]$CurrentStep,
  [string]$NextAction,
  [object]$ProjectProgressProof,
  [string]$ScopeBindingHash,
  [string]$TransitionIdValue
) {
  # A visible-progress receipt is intentionally a compact hash binding, not a
  # second transcript store.  It proves that the exact assistant progress
  # sentence currently in the contract is the one H7 may recover from.
  $sentenceValue = [string]$Sentence
  $source = [string]$SourceValue
  $phaseValue = [string]$Phase
  $stepValue = [string]$CurrentStep
  $nextValue = [string]$NextAction
  $projectHash = if($ProjectProgressProof -and $ProjectProgressProof.PSObject.Properties['payloadHash']){[string]$ProjectProgressProof.payloadHash}else{''}
  $transition = [string]$TransitionIdValue
  if (
    [string]::IsNullOrWhiteSpace($sentenceValue) -or
    $sentenceValue.Length -gt 320 -or
    $sentenceValue -ne (Limit-ContractText $sentenceValue 320) -or
    $sentenceValue -match '[\r\n]' -or
    $source -notin @('assistant_visible_reply','user_attested_visible_reply') -or
    [string]::IsNullOrWhiteSpace($phaseValue) -or $phaseValue.Length -gt 120 -or $phaseValue -ne (Limit-ContractText $phaseValue 120) -or
    [string]::IsNullOrWhiteSpace($stepValue) -or $stepValue.Length -gt 220 -or $stepValue -ne (Limit-ContractText $stepValue 220) -or
    [string]::IsNullOrWhiteSpace($nextValue) -or $nextValue.Length -gt 360 -or $nextValue -ne (Limit-ContractText $nextValue 360) -or
    $projectHash -notmatch '^[a-f0-9]{64}$' -or
    $ScopeBindingHash -notmatch '^[a-f0-9]{64}$' -or
    $transition -notmatch '^[A-Za-z0-9._:-]{1,120}$'
  ) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_INVALID'; receipt=$null }
  }
  $body = [ordered]@{
    schema = 'super-brain.visible-progress-receipt.v1'
    source = $source
    sentenceHash = Get-SuperBrainStableHash $sentenceValue 64
    currentPhase = $phaseValue
    currentStep = $stepValue
    nextAction = $nextValue
    projectProgressPayloadHash = $projectHash
    scopeBindingHash = [string]$ScopeBindingHash
    transitionId = $transition
    rawPromptStored = $false
    rawTranscriptStored = $false
  }
  $body.payloadHash = Get-ProjectProgressPayloadHash $body
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_CURRENT'; receipt=[pscustomobject]$body }
}

function Test-VisibleProgressReceipt(
  [object]$Receipt,
  [string]$Sentence,
  [string]$SourceValue,
  [string]$Phase,
  [string]$CurrentStep,
  [string]$NextAction,
  [object]$ProjectProgressProof,
  [string]$ExpectedScopeBindingHash
) {
  if (-not $Receipt) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_REQUIRED' } }
  $expectedNames = @('schema','source','sentenceHash','currentPhase','currentStep','nextAction','projectProgressPayloadHash','scopeBindingHash','transitionId','rawPromptStored','rawTranscriptStored','payloadHash')
  if (-not (Test-ProjectProgressPropertySet $Receipt $expectedNames)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_INVALID' } }
  $body = [ordered]@{}
  foreach ($name in $expectedNames | Where-Object { $_ -ne 'payloadHash' }) { $body[$name] = $Receipt.$name }
  $projectHash = if($ProjectProgressProof -and $ProjectProgressProof.PSObject.Properties['payloadHash']){[string]$ProjectProgressProof.payloadHash}else{''}
  if (
    [string]$Receipt.schema -ne 'super-brain.visible-progress-receipt.v1' -or
    [string]$Receipt.source -notin @('assistant_visible_reply','user_attested_visible_reply') -or
    [string]$Receipt.sentenceHash -notmatch '^[a-f0-9]{64}$' -or
    [string]$Receipt.payloadHash -ne (Get-ProjectProgressPayloadHash $body) -or
    $Receipt.rawPromptStored -ne $false -or $Receipt.rawTranscriptStored -ne $false -or
    [string]$Receipt.source -ne [string]$SourceValue -or
    [string]$Receipt.sentenceHash -ne (Get-SuperBrainStableHash ([string]$Sentence) 64) -or
    [string]$Receipt.currentPhase -ne [string]$Phase -or
    [string]$Receipt.currentStep -ne [string]$CurrentStep -or
    [string]$Receipt.nextAction -ne [string]$NextAction -or
    [string]$Receipt.projectProgressPayloadHash -ne $projectHash -or
    [string]$Receipt.projectProgressPayloadHash -notmatch '^[a-f0-9]{64}$' -or
    [string]$Receipt.scopeBindingHash -ne [string]$ExpectedScopeBindingHash -or
    [string]$Receipt.scopeBindingHash -notmatch '^[a-f0-9]{64}$' -or
    [string]$Receipt.transitionId -notmatch '^[A-Za-z0-9._:-]{1,120}$'
  ) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_MISMATCH' }
  }
  # User attestation is a bounded reconciliation source only.  It proves what
  # the user says was last visible, but cannot by itself authorize ordinary
  # continuation until H7 records the next exact assistant-visible reply.
  return [pscustomobject]@{
    ok=$true
    code='EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_CURRENT'
    receipt=$Receipt
    continuationEligible=([string]$Receipt.source -eq 'assistant_visible_reply')
  }
}

function Get-ChecklistStepKey([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return (($Value.Trim() -replace '\s+',' ').ToLowerInvariant())
}

function Get-ChecklistStepList([object[]]$Items,[int]$MaxItems=$script:ActiveChecklistMaxItems,[int]$MaxChars=180) {
  $result = @()
  $seen = @{}
  foreach ($item in @($Items)) {
    $label = Limit-ContractText ([string]$item) $MaxChars
    $key = Get-ChecklistStepKey $label
    if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $result += $label
  }
  if ($result.Count -gt $MaxItems) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CHECKLIST_LIMIT_EXCEEDED'; items=@(); count=$result.Count; maxItems=$MaxItems }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CHECKLIST_OK'; items=@($result); count=$result.Count; maxItems=$MaxItems }
}

function Test-ExplicitChecklistScopeReplacement([string]$Instruction) {
  if ([string]::IsNullOrWhiteSpace($Instruction)) { return $false }
  $text = $Instruction.Trim()
  # Only task/control-plane objects authorize replacing the active scope.
  # Content-level edits such as "replace a path literal" or "replace a
  # string in a file" must remain ordinary work and must not force a
  # canonical-plan mutation envelope.
  return (
    $text -match '(?i)\b(?:replace|supersede|cancel)\b\s+(?:(?:the|this|my|an?)\s+)?(?:(?:active|current|entire|complete|old|prior|previous)\s+)?(?:task|work(?:flow|line|item|package)?|plan|checklist|main\s+plan|canonical(?:\s+plan)?|route|branch|project|scope|stage|phase|parent|flow|goal)' -or
    $text -match '(?i)\breplace\s+only\b[^\r\n]{0,96}\b(?:task|work(?:flow|line|item|package)?|plan|checklist|main\s+plan|canonical(?:\s+plan)?|route|branch|project|scope|stage|phase|parent|flow|goal|item|step)\b' -or
    $text -match '(?i)\bcancel\s+(?:item|step|[A-Z])\b' -or
    $text -match '(?i)\b(?:only\s+do|ignore\s+(?:the\s+)?(?:previous|prior))\b' -or
    $text -match '(?:\u66ff\u6362|\u53d6\u4ee3|\u5e9f\u5f03|\u53d6\u6d88)(?:[^\r\n]{0,24})(?:\u4efb\u52a1|\u8ba1\u5212|\u6e05\u5355|\u5de5\u4f5c\u7ebf|\u4e3b\u7ebf|\u5206\u652f|\u9879\u76ee|\u6d41\u7a0b|\u8303\u56f4)|(?:\u53ea\u505a|\u5ffd\u7565(?:\u4e4b\u524d|\u524d\u9762|\u65e7))'
  )
}

function Test-StructuralGuardsRequired([object]$Contract,[switch]$Force) {
  return ([bool]$Force -or ($Contract -and $Contract.PSObject.Properties['structuralGuardsRequired'] -and $Contract.structuralGuardsRequired -eq $true))
}

function Get-StructuralGuardFailure([object]$Contract,[string]$Operation,[switch]$Force,[switch]$AllowIntentReceiptRefresh,[switch]$AllowCanonicalSourceRefresh) {
  if (-not $AllowCanonicalSourceRefresh) {
    $canonicalSourceStatus = Get-CanonicalPlanSourceStatus $Contract
    if ($canonicalSourceStatus.required -and -not $canonicalSourceStatus.current) {
      return [pscustomobject]@{
        ok = $false
        code = [string]$canonicalSourceStatus.code
        taskId = $TaskId
        workspaceKey = $WorkspaceKey
        operation = $Operation
        canonicalPlanSource = $canonicalSourceStatus
        guard = 'A structural transition cannot use a canonical plan whose bound source receipt, source document, or plan fingerprint is missing, stale, or mismatched.'
      }
    }
  }
  if (-not $AllowIntentReceiptRefresh) {
    $intentStatus = Get-IntentResolutionReceiptStatus $Contract
    if ($intentStatus.required -and -not $intentStatus.current) {
      return [pscustomobject]@{
        ok = $false
        code = [string]$intentStatus.code
        taskId = $TaskId
        workspaceKey = $WorkspaceKey
        operation = $Operation
        missing = @($intentStatus.missing)
        intentResolutionReceipt = $intentStatus.receipt
        guard = 'A structural transition cannot use an intent resolution receipt from another task, session, plan revision, instruction, version, or unresolved product decision.'
      }
    }
  }
  if (-not (Test-StructuralGuardsRequired $Contract -Force:$Force)) { return $null }
  $missing = @()
  if ($ExpectedRevision -lt 0) { $missing += 'ExpectedRevision' }
  if ([string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) { $missing += 'ExpectedPlanFingerprint' }
  if ([string]::IsNullOrWhiteSpace($TransitionId)) { $missing += 'TransitionId' }
  if ($missing.Count -eq 0) { return $null }
  return [pscustomobject]@{
    ok = $false
    code = 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED'
    taskId = $TaskId
    workspaceKey = $WorkspaceKey
    operation = $Operation
    missing = @($missing)
    guard = 'This contract requires caller-bound revision, plan fingerprint, and transition identity for structural mutation.'
  }
}

function Merge-ActiveChecklist(
  [object[]]$ExistingCompleted,
  [object[]]$ExistingPending,
  [object[]]$IncomingCompleted,
  [object[]]$IncomingPending,
  [string]$Mode = 'additive'
) {
  $oldCompleted = Get-ChecklistStepList $ExistingCompleted
  $oldPending = Get-ChecklistStepList $ExistingPending
  $newCompleted = Get-ChecklistStepList $IncomingCompleted
  $newPending = Get-ChecklistStepList $IncomingPending
  foreach ($set in @($oldCompleted,$oldPending,$newCompleted,$newPending)) {
    if (-not $set.ok) { return $set }
  }

  $completed = @()
  $pending = @()
  if ($Mode -ne 'replace') {
    $completed = @($oldCompleted.items)
    $pending = @($oldPending.items)
  }
  foreach ($step in @($newCompleted.items)) {
    $key = Get-ChecklistStepKey $step
    if (@($completed | Where-Object { (Get-ChecklistStepKey ([string]$_)) -eq $key }).Count -eq 0) { $completed += $step }
    $pending = @($pending | Where-Object { (Get-ChecklistStepKey ([string]$_)) -ne $key })
  }
  foreach ($step in @($newPending.items)) {
    $key = Get-ChecklistStepKey $step
    if (@($completed | Where-Object { (Get-ChecklistStepKey ([string]$_)) -eq $key }).Count -gt 0) { continue }
    if (@($pending | Where-Object { (Get-ChecklistStepKey ([string]$_)) -eq $key }).Count -eq 0) { $pending += $step }
  }
  $total = @($completed).Count + @($pending).Count
  if ($total -gt $script:ActiveChecklistMaxItems) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CHECKLIST_LIMIT_EXCEEDED'; items=@(); count=$total; maxItems=$script:ActiveChecklistMaxItems }
  }
  $active = @()
  $ordinal = 1
  foreach ($step in @($completed)) { $active += [pscustomobject]@{ ordinal=$ordinal; status='completed'; label=$step }; $ordinal++ }
  foreach ($step in @($pending)) { $active += [pscustomobject]@{ ordinal=$ordinal; status='pending'; label=$step }; $ordinal++ }
  return [pscustomobject]@{
    ok = $true
    code = 'EXECUTION_CONTRACT_CHECKLIST_OK'
    mode = $Mode
    completedSteps = @($completed)
    pendingSteps = @($pending)
    activeChecklist = @($active)
    supersededSteps = if ($Mode -eq 'replace') { @($oldCompleted.items + $oldPending.items) } else { @() }
  }
}

function Test-ChecklistStateEquivalent(
  [object[]]$ExpectedCompleted,
  [object[]]$ExpectedPending,
  [object[]]$ActualCompleted,
  [object[]]$ActualPending
) {
  $expected = @()
  foreach ($step in @($ExpectedCompleted)) { $expected += ('completed|' + (Get-ChecklistStepKey ([string]$step))) }
  foreach ($step in @($ExpectedPending)) { $expected += ('pending|' + (Get-ChecklistStepKey ([string]$step))) }
  $actual = @()
  foreach ($step in @($ActualCompleted)) { $actual += ('completed|' + (Get-ChecklistStepKey ([string]$step))) }
  foreach ($step in @($ActualPending)) { $actual += ('pending|' + (Get-ChecklistStepKey ([string]$step))) }
  $expected = @($expected | Where-Object { $_ -notmatch '^[a-z]+\|$' } | Sort-Object -Unique)
  $actual = @($actual | Where-Object { $_ -notmatch '^[a-z]+\|$' } | Sort-Object -Unique)
  if ($expected.Count -ne $actual.Count) { return $false }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if ([string]$expected[$index] -ne [string]$actual[$index]) { return $false }
  }
  return $true
}

function Test-CanonicalArrayValue([object]$Value) {
  return ($null -ne $Value -and $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary])
}

function Get-CanonicalPlanFingerprint([object]$Plan) {
  return Get-SuperBrainCanonicalPlanFingerprint $Plan
  if (-not $Plan) { return '' }
  $items = @($Plan.items | Sort-Object { [int]$_.ordinal } | ForEach-Object {
    [ordered]@{
      itemId = Limit-ContractText ([string]$_.itemId) 80
      ordinal = [int]$_.ordinal
      label = Limit-ContractText ([string]$_.label) 180
      status = Limit-ContractText ([string]$_.status) 24
      evidenceRefs = @(Limit-ContractList @($_.evidenceRefs) 6 160)
    }
  })
  $history = @($Plan.supersessionHistory | Select-Object -Last $script:CanonicalSupersessionMaxCount | ForEach-Object {
    [ordered]@{
      planId = Limit-ContractText ([string]$_.planId) 80
      generation = if ($_.PSObject.Properties['generation']) { [int]$_.generation } else { 0 }
      currentFingerprint = Limit-ContractText ([string]$_.currentFingerprint) 32
      itemCount = if ($_.PSObject.Properties['itemCount']) { [int]$_.itemCount } else { 0 }
      supersededAt = Limit-ContractText ([string]$_.supersededAt) 48
      transitionId = Limit-ContractText ([string]$_.transitionId) 120
    }
  })
  $payload = [ordered]@{
    schemaVersion = 1
    planId = Limit-ContractText ([string]$Plan.planId) 80
    generation = [int]$Plan.generation
    rootFocusId = Limit-ContractText ([string]$Plan.rootFocusId) 120
    originFingerprint = Limit-ContractText ([string]$Plan.originFingerprint) 32
    orderConfidence = Limit-ContractText ([string]$Plan.orderConfidence) 32
    approvalSource = Limit-ContractText ([string]$Plan.approvalSource) 48
    approvalInstructionFingerprint = Limit-ContractText ([string]$Plan.approvalInstructionFingerprint) 32
    items = @($items)
    supersessionHistory = @($history)
  }
  return Get-ContinuityFingerprint ($payload | ConvertTo-Json -Depth 10 -Compress)
}

function Complete-CanonicalPlanFingerprint([object]$Plan) {
  $Plan | Add-Member -NotePropertyName currentFingerprint -NotePropertyValue (Get-CanonicalPlanFingerprint $Plan) -Force
  return $Plan
}

function Get-CanonicalPlanProjection([object]$Plan) {
  $active = @()
  $completed = @()
  $pending = @()
  if ($Plan) {
    foreach ($item in @($Plan.items | Sort-Object { [int]$_.ordinal })) {
      $status = [string]$item.status
      $label = Limit-ContractText ([string]$item.label) 180
      $active += [pscustomobject]@{ itemId=[string]$item.itemId; ordinal=[int]$item.ordinal; status=$status; label=$label }
      if ($status -eq 'completed') { $completed += $label }
      elseif ($status -in @('pending','in_progress')) { $pending += $label }
    }
  }
  return [pscustomobject]@{
    activeChecklist = @($active)
    completedSteps = @($completed)
    pendingSteps = @($pending)
    itemCount = @($active).Count
    completedCount = @($active | Where-Object { [string]$_.status -eq 'completed' }).Count
    pendingCount = @($active | Where-Object { [string]$_.status -in @('pending','in_progress') }).Count
    cancelledCount = @($active | Where-Object { [string]$_.status -eq 'cancelled' }).Count
  }
}

function Test-CanonicalPlanState([object]$Plan,[switch]$AllowMissingFingerprint) {
  return Test-SuperBrainCanonicalPlan $Plan -AllowMissingFingerprint:$AllowMissingFingerprint -MaxItems $script:ActiveChecklistMaxItems -MaxBytes $script:CanonicalPlanMaxBytes
  if (-not $Plan) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_REQUIRED'; plan=$null } }
  if (-not $Plan.PSObject.Properties['schemaVersion'] -or [int]$Plan.schemaVersion -ne 1) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SCHEMA_INVALID'; plan=$null }
  }
  $planId = Limit-ContractText ([string]$Plan.planId) 80
  $rootFocusId = Limit-ContractText ([string]$Plan.rootFocusId) 120
  if ([string]::IsNullOrWhiteSpace($planId) -or [string]::IsNullOrWhiteSpace($rootFocusId) -or [int]$Plan.generation -lt 1) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_IDENTITY_INVALID'; plan=$null }
  }
  if (-not $Plan.PSObject.Properties['items'] -or -not (Test-CanonicalArrayValue $Plan.items)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEMS_ARRAY_REQUIRED'; plan=$null }
  }
  $rawItems = @($Plan.items)
  if ($rawItems.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEMS_REQUIRED'; plan=$null } }
  if ($rawItems.Count -gt $script:ActiveChecklistMaxItems) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_LIMIT_EXCEEDED'; count=$rawItems.Count; maxItems=$script:ActiveChecklistMaxItems; plan=$null }
  }
  $items = @()
  $seenIds = @{}
  $expectedOrdinal = 1
  foreach ($rawItem in @($rawItems | Sort-Object { [int]$_.ordinal })) {
    if (-not $rawItem -or -not $rawItem.PSObject.Properties['itemId'] -or -not $rawItem.PSObject.Properties['ordinal'] -or -not $rawItem.PSObject.Properties['label'] -or -not $rawItem.PSObject.Properties['status']) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID'; plan=$null }
    }
    $itemId = Limit-ContractText ([string]$rawItem.itemId) 80
    $label = Limit-ContractText ([string]$rawItem.label) 180
    $labelKey = Get-ChecklistStepKey $label
    $status = Limit-ContractText ([string]$rawItem.status) 24
    $ordinal = [int]$rawItem.ordinal
    if ([string]::IsNullOrWhiteSpace($itemId) -or [string]::IsNullOrWhiteSpace($labelKey) -or $status -notin @('pending','in_progress','completed','cancelled') -or $ordinal -ne $expectedOrdinal -or $seenIds.ContainsKey($itemId)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID'; plan=$null }
    }
    $seenIds[$itemId] = $true
    $items += [pscustomobject]@{
      itemId = $itemId
      ordinal = $ordinal
      label = $label
      status = $status
      evidenceRefs = @(Limit-ContractList $(if($rawItem.PSObject.Properties['evidenceRefs']){@($rawItem.evidenceRefs)}else{@()}) 6 160)
      updatedAt = if ($rawItem.PSObject.Properties['updatedAt']) { Limit-ContractText ([string]$rawItem.updatedAt) 48 } else { '' }
    }
    $expectedOrdinal++
  }
  $history = @()
  if ($Plan.PSObject.Properties['supersessionHistory']) {
    if (-not (Test-CanonicalArrayValue $Plan.supersessionHistory)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_HISTORY_ARRAY_REQUIRED'; plan=$null } }
    foreach ($entry in @($Plan.supersessionHistory | Select-Object -Last $script:CanonicalSupersessionMaxCount)) {
      if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.planId)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_HISTORY_INVALID'; plan=$null } }
      $history += [pscustomobject]@{
        planId = Limit-ContractText ([string]$entry.planId) 80
        generation = if ($entry.PSObject.Properties['generation']) { [int]$entry.generation } else { 0 }
        currentFingerprint = Limit-ContractText ([string]$entry.currentFingerprint) 32
        itemCount = if ($entry.PSObject.Properties['itemCount']) { [int]$entry.itemCount } else { 0 }
        supersededAt = Limit-ContractText ([string]$entry.supersededAt) 48
        transitionId = Limit-ContractText ([string]$entry.transitionId) 120
      }
    }
  }
  $normalized = [pscustomobject]@{
    schemaVersion = 1
    planId = $planId
    generation = [int]$Plan.generation
    rootFocusId = $rootFocusId
    originFingerprint = Limit-ContractText ([string]$Plan.originFingerprint) 32
    currentFingerprint = Limit-ContractText ([string]$Plan.currentFingerprint) 32
    orderConfidence = if ([string]$Plan.orderConfidence -in @('verified','legacy_derived')) { [string]$Plan.orderConfidence } else { 'legacy_derived' }
    approvalSource = Limit-ContractText ([string]$Plan.approvalSource) 48
    approvalInstructionFingerprint = Limit-ContractText ([string]$Plan.approvalInstructionFingerprint) 32
    items = @($items)
    supersessionHistory = @($history)
    createdAt = Limit-ContractText ([string]$Plan.createdAt) 48
    updatedAt = Limit-ContractText ([string]$Plan.updatedAt) 48
  }
  if ($normalized.orderConfidence -eq 'verified' -and $normalized.approvalSource -eq 'user_confirmation' -and [string]::IsNullOrWhiteSpace([string]$normalized.approvalInstructionFingerprint)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_APPROVAL_RECEIPT_REQUIRED'; plan=$null }
  }
  $expectedFingerprint = Get-CanonicalPlanFingerprint $normalized
  if (-not $AllowMissingFingerprint -and ([string]::IsNullOrWhiteSpace([string]$normalized.currentFingerprint) -or [string]$normalized.currentFingerprint -ne $expectedFingerprint)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_FINGERPRINT_MISMATCH'; expectedFingerprint=$expectedFingerprint; actualFingerprint=[string]$normalized.currentFingerprint; plan=$null }
  }
  $normalized.currentFingerprint = $expectedFingerprint
  $json = $normalized | ConvertTo-Json -Depth 12 -Compress
  $byteCount = [Text.Encoding]::UTF8.GetByteCount($json)
  if ($byteCount -gt $script:CanonicalPlanMaxBytes) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_SIZE_EXCEEDED'; byteCount=$byteCount; maxBytes=$script:CanonicalPlanMaxBytes; plan=$null }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CANONICAL_PLAN_OK'; plan=$normalized; byteCount=$byteCount }
}

function New-CanonicalPlanFromChecklist(
  [object[]]$Checklist,
  [string]$RootFocusId,
  [string]$OrderConfidence,
  [string]$ApprovalSource,
  [string]$InstructionValue,
  [int]$Generation = 1,
  [object[]]$SupersessionHistory = @()
) {
  $planId = 'plan-' + (Get-SuperBrainStableHash ($TaskId + '|' + $WorkspaceKey + '|' + $RootFocusId + '|' + $Generation) 24)
  $items = @()
  $ordinal = 1
  foreach ($entry in @($Checklist)) {
    $label = Limit-ContractText (Protect-Instruction ([string]$entry.label)) 180
    $status = if ([string]$entry.status -in @('pending','in_progress','completed','cancelled')) { [string]$entry.status } else { 'pending' }
    $items += [pscustomobject]@{
      itemId = 'item-' + (Get-SuperBrainStableHash ($planId + '|' + $ordinal + '|' + $label) 20)
      ordinal = $ordinal
      label = $label
      status = $status
      evidenceRefs = @()
      updatedAt = (Get-SuperBrainUtcTimestamp)
    }
    $ordinal++
  }
  $instructionFingerprint = if ([string]::IsNullOrWhiteSpace($InstructionValue)) { '' } else { Get-ContinuityFingerprint $InstructionValue }
  $now = (Get-SuperBrainUtcTimestamp)
  $plan = [pscustomobject]@{
    schemaVersion = 1
    planId = $planId
    generation = $Generation
    rootFocusId = Limit-ContractText $RootFocusId 120
    originFingerprint = Get-ContinuityFingerprint (($TaskId + '|' + $WorkspaceKey + '|' + $RootFocusId + '|' + $instructionFingerprint + '|' + $Generation))
    currentFingerprint = ''
    orderConfidence = if ($OrderConfidence -eq 'verified') { 'verified' } else { 'legacy_derived' }
    approvalSource = Limit-ContractText $ApprovalSource 48
    approvalInstructionFingerprint = $instructionFingerprint
    items = @($items)
    supersessionHistory = @($SupersessionHistory | Select-Object -Last $script:CanonicalSupersessionMaxCount)
    createdAt = $now
    updatedAt = $now
  }
  $plan = Complete-CanonicalPlanFingerprint $plan
  return Test-CanonicalPlanState $plan
}

function Read-CanonicalMutationEnvelope([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_PATH_REQUIRED' } }
  $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { '' }
  if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-SuperBrainChildPath $memoryBase $fullPath)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_PATH_OUTSIDE_STATE_ROOT'; path=$fullPath }
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_NOT_FOUND'; path=$fullPath } }
  $file = Get-Item -LiteralPath $fullPath
  if ($file.Length -gt $script:CanonicalPlanMaxBytes) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_SIZE_EXCEEDED'; byteCount=[int64]$file.Length; maxBytes=$script:CanonicalPlanMaxBytes }
  }
  try {
    $raw = [IO.File]::ReadAllText($fullPath,[Text.Encoding]::UTF8)
    $value = $raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_INVALID_JSON'; path=$fullPath }
  }
  if (-not $value -or $value -is [System.Array] -or $value -is [string]) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_OBJECT_REQUIRED'; path=$fullPath }
  }
  $normalizedEnvelope = $value | ConvertTo-Json -Depth 12 -Compress
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_OK'; path=$fullPath; envelope=$value; contentHash=Get-ContinuityFingerprint $normalizedEnvelope }
}

function Get-CanonicalPlanSourceRelativePath([string]$BasePath,[string]$ChildPath) {
  try {
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $child = [IO.Path]::GetFullPath($ChildPath)
    return [Uri]::UnescapeDataString(([Uri]$base).MakeRelativeUri([Uri]$child).ToString()).Replace('/','\')
  } catch {
    return ''
  }
}

function Get-CanonicalPlanSourcePathInfo([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_REQUIRED' }
  }
  $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { '' }
  if ([string]::IsNullOrWhiteSpace($fullPath)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_INVALID' }
  }
  $retiredPackageDocsRoot = [IO.Path]::GetFullPath((Join-Path $Root 'docs'))
  if (Test-SuperBrainChildPath $retiredPackageDocsRoot $fullPath) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PACKAGE_DOCS_RETIRED'; path=$fullPath }
  }
  if ($script:StateRootWasBound) {
    $testRoot = [IO.Path]::GetFullPath((Join-Path $memoryBase 'canonical-sources'))
    if (Test-SuperBrainChildPath $testRoot $fullPath) {
      return [pscustomobject]@{
        ok=$true
        scope='state_test'
        path=$fullPath
        relativePath=((Get-CanonicalPlanSourceRelativePath $memoryBase $fullPath).Replace('\','/'))
      }
    }
  }
  return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_OUTSIDE_ALLOWED_ROOT'; path=$fullPath }
}

function Resolve-CanonicalPlanSourceManifestPath([string]$Scope,[string]$RelativePath) {
  $relative = ([string]$RelativePath).Replace('/','\').Trim()
  if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_INVALID' }
  }
  if ($Scope -eq 'package_docs') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PACKAGE_DOCS_RETIRED' }
  }
  if ($Scope -eq 'state_test' -and $script:StateRootWasBound) {
    if ($relative -notmatch '^(?i:canonical-sources[\\/].+\.json)$') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_INVALID' }
    }
    $path = [IO.Path]::GetFullPath((Join-Path $memoryBase $relative))
    if (-not (Test-SuperBrainChildPath ([IO.Path]::GetFullPath((Join-Path $memoryBase 'canonical-sources'))) $path)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PATH_INVALID' }
    }
    return [pscustomobject]@{ ok=$true; path=$path }
  }
  return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_SCOPE_INVALID' }
}

function Resolve-CanonicalPlanSourceDocumentPath([string]$Scope,[string]$RelativePath) {
  $relative = ([string]$RelativePath).Replace('/','\').Trim()
  if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_PATH_INVALID' }
  }
  if ($Scope -eq 'package_docs') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PACKAGE_DOCS_RETIRED' }
  }
  if ($Scope -eq 'state_test' -and $script:StateRootWasBound) {
    if ($relative -notmatch '^(?i:plans[\\/].+\.md)$') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_PATH_INVALID' }
    }
    $path = [IO.Path]::GetFullPath((Join-Path (Join-Path $memoryBase 'canonical-sources') $relative))
    if (-not (Test-SuperBrainChildPath ([IO.Path]::GetFullPath((Join-Path $memoryBase 'canonical-sources\plans'))) $path)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_PATH_INVALID' }
    }
    return [pscustomobject]@{ ok=$true; path=$path }
  }
  return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_SCOPE_INVALID' }
}

function Read-CanonicalPlanSourceManifest([string]$Path) {
  $location = Get-CanonicalPlanSourcePathInfo $Path
  if (-not $location.ok) { return $location }
  if (-not (Test-Path -LiteralPath $location.path -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_NOT_FOUND'; path=$location.path }
  }
  try {
    $file = Get-Item -LiteralPath $location.path
    if ($file.Length -gt $script:CanonicalPlanSourceMaxBytes) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_SIZE_EXCEEDED'; byteCount=[int64]$file.Length; maxBytes=$script:CanonicalPlanSourceMaxBytes }
    }
    $value = [IO.File]::ReadAllText($location.path,[Text.Encoding]::UTF8) | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_INVALID_JSON'; path=$location.path }
  }
  if (-not $value -or $value -is [System.Array] -or $value -is [string] -or [string]$value.schema -ne 'super-brain.canonical-plan-source.v1') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_SCHEMA_INVALID'; path=$location.path }
  }
  $planId = Limit-ContractText ([string]$value.planId) 80
  $generation = [int]$value.generation
  $fingerprint = ([string]$value.currentFingerprint).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($planId) -or $generation -lt 1 -or $fingerprint -notmatch '^[a-f0-9]{8,64}$' -or -not $value.PSObject.Properties['sourceDocument'] -or -not $value.sourceDocument) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_FIELDS_INVALID'; path=$location.path }
  }
  $documentRelativePath = [string]$value.sourceDocument.relativePath
  $documentHash = ([string]$value.sourceDocument.sha256).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($documentRelativePath) -or $documentHash -notmatch '^[a-f0-9]{64}$') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_INVALID'; path=$location.path }
  }
  $document = Resolve-CanonicalPlanSourceDocumentPath ([string]$location.scope) $documentRelativePath
  if (-not $document.ok -or -not (Test-Path -LiteralPath $document.path -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code=if($document.ok){'EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_MISSING'}else{[string]$document.code}; path=$location.path }
  }
  $actualDocumentHash = (Get-FileHash -LiteralPath $document.path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualDocumentHash -ne $documentHash) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_DOCUMENT_HASH_MISMATCH'; path=$location.path; documentPath=$document.path }
  }
  return [pscustomobject]@{
    ok=$true
    code='EXECUTION_CONTRACT_CANONICAL_SOURCE_OK'
    path=$location.path
    scope=[string]$location.scope
    relativePath=[string]$location.relativePath
    manifest=$value
    manifestSha256=(Get-FileHash -LiteralPath $location.path -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceDocument=[pscustomobject]@{ relativePath=$documentRelativePath.Replace('\','/'); sha256=$documentHash }
  }
}

function New-CanonicalPlanSourceBinding([object]$ManifestRecord,[object]$Plan) {
  $canonical = Test-CanonicalPlanState $Plan
  if (-not $canonical.ok) { return $canonical }
  if (-not $ManifestRecord -or -not $ManifestRecord.ok) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_INVALID' }
  }
  if ([string]$ManifestRecord.manifest.planId -ne [string]$canonical.plan.planId -or [int]$ManifestRecord.manifest.generation -ne [int]$canonical.plan.generation -or [string]$ManifestRecord.manifest.currentFingerprint -ne [string]$canonical.plan.currentFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PLAN_MISMATCH'; planId=[string]$canonical.plan.planId; generation=[int]$canonical.plan.generation; currentFingerprint=[string]$canonical.plan.currentFingerprint }
  }
  return [pscustomobject]@{
    ok=$true
    binding=[pscustomobject]@{
      schema='super-brain.canonical-plan-source-binding.v1'
      scope=[string]$ManifestRecord.scope
      manifestRelativePath=[string]$ManifestRecord.relativePath
      manifestSha256=[string]$ManifestRecord.manifestSha256
      planId=[string]$canonical.plan.planId
      generation=[int]$canonical.plan.generation
      currentFingerprint=[string]$canonical.plan.currentFingerprint
      sourceDocument=$ManifestRecord.sourceDocument
      boundAt=(Get-SuperBrainUtcTimestamp)
    }
  }
}

function Test-InstructionAnchorCanonicalPlanSourceRequirement([object]$Anchor) {
  if (-not $Anchor -or -not $Anchor.PSObject.Properties['signals'] -or -not $Anchor.signals) { return $false }
  if (-not $Anchor.signals.PSObject.Properties['canonicalPlanSourceRequired']) { return $false }
  return [bool]$Anchor.signals.canonicalPlanSourceRequired
}

function Get-CanonicalPlanSourceStatus([object]$Contract,[object]$InstructionAnchor=$null) {
  $plan = if ($Contract -and $Contract.PSObject.Properties['canonicalPlan']) { $Contract.canonicalPlan } else { $null }
  if (-not $plan) {
    return [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_NOT_APPLICABLE' }
  }
  $canonical = Test-CanonicalPlanState $plan
  if (-not $canonical.ok) {
    return [pscustomobject]@{ required=$true; current=$false; code=[string]$canonical.code }
  }
  $required = [bool](
    ($Contract.PSObject.Properties['canonicalPlanSourceRequired'] -and $Contract.canonicalPlanSourceRequired -eq $true) -or
    (Test-InstructionAnchorCanonicalPlanSourceRequirement $InstructionAnchor)
  )
  if (-not $required) {
    return [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_LEGACY_OPTIONAL' }
  }
  if (-not $Contract.PSObject.Properties['canonicalPlanSource'] -or -not $Contract.canonicalPlanSource) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_REQUIRED' }
  }
  $binding = $Contract.canonicalPlanSource
  if ([string]$binding.scope -eq 'package_docs') {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PACKAGE_DOCS_RETIRED' }
  }
  if ([string]$binding.schema -ne 'super-brain.canonical-plan-source-binding.v1' -or [string]$binding.scope -ne 'state_test' -or [string]::IsNullOrWhiteSpace([string]$binding.manifestRelativePath) -or ([string]$binding.manifestSha256).ToLowerInvariant() -notmatch '^[a-f0-9]{64}$') {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_BINDING_INVALID' }
  }
  if ([string]$binding.planId -ne [string]$canonical.plan.planId -or [int]$binding.generation -ne [int]$canonical.plan.generation -or [string]$binding.currentFingerprint -ne [string]$canonical.plan.currentFingerprint) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PLAN_MISMATCH' }
  }
  $manifestPath = Resolve-CanonicalPlanSourceManifestPath ([string]$binding.scope) ([string]$binding.manifestRelativePath)
  if (-not $manifestPath.ok -or -not (Test-Path -LiteralPath $manifestPath.path -PathType Leaf)) {
    return [pscustomobject]@{ required=$true; current=$false; code=if($manifestPath.ok){'EXECUTION_CONTRACT_CANONICAL_SOURCE_NOT_FOUND'}else{[string]$manifestPath.code} }
  }
  $manifestHash = (Get-FileHash -LiteralPath $manifestPath.path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($manifestHash -ne ([string]$binding.manifestSha256).ToLowerInvariant()) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_MANIFEST_HASH_MISMATCH' }
  }
  $record = Read-CanonicalPlanSourceManifest $manifestPath.path
  if (-not $record.ok) {
    return [pscustomobject]@{ required=$true; current=$false; code=[string]$record.code }
  }
  if ([string]$record.manifest.planId -ne [string]$canonical.plan.planId -or [int]$record.manifest.generation -ne [int]$canonical.plan.generation -or [string]$record.manifest.currentFingerprint -ne [string]$canonical.plan.currentFingerprint -or [string]$record.manifestSha256 -ne [string]$binding.manifestSha256) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_PLAN_MISMATCH' }
  }
  return [pscustomobject]@{
    required=$true
    current=$true
    code='EXECUTION_CONTRACT_CANONICAL_SOURCE_CURRENT'
    manifestRelativePath=[string]$binding.manifestRelativePath
    planId=[string]$canonical.plan.planId
    generation=[int]$canonical.plan.generation
    currentFingerprint=[string]$canonical.plan.currentFingerprint
  }
}

function Apply-CanonicalPlanMutation(
  [object]$ExistingPlan,
  [object]$Envelope,
  [string]$LatestInstructionValue,
  [int]$CurrentRevision,
  [string]$ReplacementRootFocusId = ''
) {
  $validated = Test-CanonicalPlanState $ExistingPlan
  if (-not $validated.ok) { return $validated }
  $plan = $validated.plan
  if ([string]$Envelope.schema -ne 'super-brain.canonical-plan-mutation.v1' -or [string]$Envelope.targetScope -ne 'canonical_main') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_SCHEMA_INVALID' }
  }
  $operation = [string]$Envelope.operation
  if ($operation -notin @('append','set_status','cancel_item','replace_canonical')) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_OPERATION_INVALID' } }
  if ([string]::IsNullOrWhiteSpace($TransitionId) -or [string]$Envelope.transitionId -ne [string]$TransitionId) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_TRANSITION_MISMATCH' }
  }
  if ([string]$Envelope.expectedPlanId -ne [string]$plan.planId -or [int]$Envelope.expectedGeneration -ne [int]$plan.generation -or [int]$Envelope.expectedRevision -ne $CurrentRevision -or [string]$Envelope.expectedFingerprint -ne [string]$plan.currentFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_CAS_MISMATCH'; planId=$plan.planId; generation=[int]$plan.generation; revision=$CurrentRevision; fingerprint=$plan.currentFingerprint }
  }
  $instructionFingerprint = if ([string]::IsNullOrWhiteSpace($LatestInstructionValue)) { '' } else { Get-ContinuityFingerprint $LatestInstructionValue }
  if ([string]::IsNullOrWhiteSpace([string]$Envelope.userInstructionFingerprint) -or [string]$Envelope.userInstructionFingerprint -ne $instructionFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_INSTRUCTION_MISMATCH' }
  }
  $approvalSource = [string]$Envelope.approvalSource
  if (($operation -in @('append','cancel_item','replace_canonical') -and $approvalSource -ne 'user_confirmation') -or ($operation -eq 'set_status' -and $approvalSource -notin @('user_confirmation','verified_status_transition'))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_APPROVAL_REQUIRED' }
  }
  if (-not $Envelope.PSObject.Properties['items'] -or -not (Test-CanonicalArrayValue $Envelope.items)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_ITEMS_ARRAY_REQUIRED' }
  }
  if (-not $Envelope.PSObject.Properties['targetItemIds'] -or -not (Test-CanonicalArrayValue $Envelope.targetItemIds)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_TARGETS_ARRAY_REQUIRED' }
  }
  $incomingItems = @($Envelope.items)
  $targetIds = @($Envelope.targetItemIds | ForEach-Object { Limit-ContractText ([string]$_) 80 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $copy = $plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
  if ($operation -eq 'append') {
    if ($incomingItems.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_ITEMS_REQUIRED' } }
    if (@($copy.items).Count + $incomingItems.Count -gt $script:ActiveChecklistMaxItems) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_LIMIT_EXCEEDED'; count=(@($copy.items).Count + $incomingItems.Count); maxItems=$script:ActiveChecklistMaxItems }
    }
    $ordinal = @($copy.items).Count + 1
    foreach ($incoming in $incomingItems) {
      if (-not $incoming -or -not $incoming.PSObject.Properties['label']) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID' } }
      $label = Limit-ContractText (Protect-Instruction ([string]$incoming.label)) 180
      $key = Get-ChecklistStepKey $label
      $status = if ($incoming.PSObject.Properties['status'] -and [string]$incoming.status -in @('pending','in_progress','completed','cancelled')) { [string]$incoming.status } else { 'pending' }
      if ([string]::IsNullOrWhiteSpace($key)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID' } }
      $copy.items = @($copy.items) + @([pscustomobject]@{ itemId='item-' + (Get-SuperBrainStableHash ($copy.planId + '|' + $ordinal + '|' + $label) 20); ordinal=$ordinal; label=$label; status=$status; evidenceRefs=@(); updatedAt=(Get-SuperBrainUtcTimestamp) })
      $ordinal++
    }
  } elseif ($operation -eq 'set_status') {
    $status = [string]$Envelope.status
    if ($targetIds.Count -eq 0 -or $status -notin @('pending','in_progress','completed')) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_STATUS_INVALID' } }
    $evidenceRefs = @(Limit-ContractList $(if($Envelope.PSObject.Properties['evidenceRefs']){@($Envelope.evidenceRefs)}else{@()}) 6 160)
    if ($status -eq 'completed' -and $approvalSource -eq 'verified_status_transition' -and $evidenceRefs.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_STATUS_EVIDENCE_REQUIRED' } }
    foreach ($target in $targetIds) {
      $matches = @($copy.items | Where-Object { [string]$_.itemId -eq $target })
      if ($matches.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_TARGET_NOT_FOUND'; itemId=$target } }
      $matches[0].status = $status
      if ($evidenceRefs.Count -gt 0) { $matches[0].evidenceRefs = @(Limit-ContractList @($matches[0].evidenceRefs + $evidenceRefs) 6 160) }
      $matches[0].updatedAt = (Get-SuperBrainUtcTimestamp)
    }
  } elseif ($operation -eq 'cancel_item') {
    if ($targetIds.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_TARGET_REQUIRED' } }
    foreach ($target in $targetIds) {
      $matches = @($copy.items | Where-Object { [string]$_.itemId -eq $target })
      if ($matches.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_TARGET_NOT_FOUND'; itemId=$target } }
      $matches[0].status = 'cancelled'
      $matches[0].updatedAt = (Get-SuperBrainUtcTimestamp)
    }
  } else {
    if ($incomingItems.Count -eq 0 -or -not (Test-ExplicitChecklistScopeReplacement $LatestInstructionValue)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_REPLACEMENT_APPROVAL_REQUIRED' }
    }
    $replacementChecklist = @()
    foreach ($incoming in $incomingItems) {
      if (-not $incoming -or -not $incoming.PSObject.Properties['label']) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID' } }
      $label = Limit-ContractText (Protect-Instruction ([string]$incoming.label)) 180
      $key = Get-ChecklistStepKey $label
      if ([string]::IsNullOrWhiteSpace($key)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID' } }
      $replacementChecklist += [pscustomobject]@{ label=$label; status=if($incoming.PSObject.Properties['status'] -and [string]$incoming.status -in @('pending','in_progress','completed','cancelled')){[string]$incoming.status}else{'pending'} }
    }
    if ($replacementChecklist.Count -gt $script:ActiveChecklistMaxItems) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_LIMIT_EXCEEDED'; count=$replacementChecklist.Count; maxItems=$script:ActiveChecklistMaxItems } }
    $historyEntry = [pscustomobject]@{ planId=[string]$plan.planId; generation=[int]$plan.generation; currentFingerprint=[string]$plan.currentFingerprint; itemCount=@($plan.items).Count; supersededAt=(Get-SuperBrainUtcTimestamp); transitionId=[string]$TransitionId }
    $history = @(@($plan.supersessionHistory) + @($historyEntry) | Select-Object -Last $script:CanonicalSupersessionMaxCount)
    $replacementRoot = if([string]::IsNullOrWhiteSpace($ReplacementRootFocusId)){[string]$plan.rootFocusId}else{Limit-ContractText $ReplacementRootFocusId 120}
    if($Envelope.PSObject.Properties['rootFocusId'] -and -not[string]::IsNullOrWhiteSpace([string]$Envelope.rootFocusId) -and [string]$Envelope.rootFocusId-ne$replacementRoot){
      return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_REPLACEMENT_ROOT_MISMATCH';expectedRootFocusId=$replacementRoot;actualRootFocusId=[string]$Envelope.rootFocusId}
    }
    $replacement = New-CanonicalPlanFromChecklist $replacementChecklist $replacementRoot 'verified' $approvalSource $LatestInstructionValue ([int]$plan.generation + 1) $history
    if (-not $replacement.ok) { return $replacement }
    return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_APPLIED'; plan=$replacement.plan; operation=$operation }
  }
  $copy.updatedAt = (Get-SuperBrainUtcTimestamp)
  $copy.approvalSource = $approvalSource
  $copy.approvalInstructionFingerprint = $instructionFingerprint
  $copy = Complete-CanonicalPlanFingerprint $copy
  $result = Test-CanonicalPlanState $copy
  if (-not $result.ok) { return $result }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_APPLIED'; plan=$result.plan; operation=$operation }
}

function Test-GenericTopicKey([string]$Value) {
  $normalized = (($Value -replace '[^\p{L}\p{Nd}]+','').Trim()).ToLowerInvariant()
  $cjk = @(
    (-join (@(20219,21153) | ForEach-Object { [char]$_ })),
    (-join (@(24037,20316) | ForEach-Object { [char]$_ })),
    (-join (@(35745,21010) | ForEach-Object { [char]$_ })),
    (-join (@(20027,32447) | ForEach-Object { [char]$_ })),
    (-join (@(25903,32447) | ForEach-Object { [char]$_ })),
    (-join (@(32487,32493) | ForEach-Object { [char]$_ })),
    (-join (@(24674,22797) | ForEach-Object { [char]$_ })),
    (-join (@(24403,21069) | ForEach-Object { [char]$_ })),
    (-join (@(19979,19968,27493) | ForEach-Object { [char]$_ })),
    (-join (@(31995,32479) | ForEach-Object { [char]$_ }))
  )
  return $normalized -in @(
    @('task','work','plan','branch','main','side','continue','resume','current','next','action','audit','system') + $cjk
  )
}

function Limit-TopicKeys([object[]]$Items,[int]$MaxItems=8,[int]$MaxChars=64) {
  $result = @()
  foreach ($item in @($Items)) {
    $value = Limit-ContractText ([string]$item) $MaxChars
    if ([string]::IsNullOrWhiteSpace($value) -or (Test-GenericTopicKey $value)) { continue }
    $letters = ($value -replace '[^\p{L}\p{Nd}]','')
    if ($letters.Length -lt 2) { continue }
    if (-not ($result -contains $value)) { $result += $value }
    if ($result.Count -ge $MaxItems) { break }
  }
  return @($result)
}

function Get-DerivedTopicKeys([string]$FocusId) {
  if ([string]::IsNullOrWhiteSpace($FocusId)) { return @() }
  $parts = @($FocusId -split '[-_.\s]+')
  return @(Limit-TopicKeys $parts 6 48)
}

function Get-DefaultFocusLabel([string]$FocusId) {
  if ([string]::IsNullOrWhiteSpace($FocusId)) { return '' }
  return Limit-ContractText (($FocusId -replace '[-_.]+',' ').Trim()) 120
}

function New-PriorityRecord([string]$Source,[string]$Reason,[int]$ExecutionRank=1) {
  $resolvedSource = if ([string]::IsNullOrWhiteSpace($Source) -or $Source -eq 'auto') { 'current_contract' } else { $Source }
  $resolvedReason = if ([string]::IsNullOrWhiteSpace($Reason)) {
    if ($ExecutionRank -eq 1) { 'current active work line' } else { 'resume after higher execution-order work lines' }
  } else { Limit-ContractText $Reason 180 }
  return [pscustomobject]@{
    executionRank = $ExecutionRank
    source = $resolvedSource
    reason = $resolvedReason
  }
}

function Normalize-TopicMatchText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return (($Value.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+',' ').Trim() -replace '\s+',' ')
}

function Test-TopicKeyMatch([string]$Instruction,[string]$Key) {
  $instructionValue = Normalize-TopicMatchText $Instruction
  $keyValue = Normalize-TopicMatchText $Key
  if ([string]::IsNullOrWhiteSpace($instructionValue) -or [string]::IsNullOrWhiteSpace($keyValue)) { return $false }
  if ($keyValue -match '[a-z]') {
    $pattern = '(?<![\p{L}\p{Nd}])' + [regex]::Escape($keyValue) + '(?![\p{L}\p{Nd}])'
    return [regex]::IsMatch($instructionValue,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
  }
  return $instructionValue.Contains($keyValue)
}

function ConvertTo-ReturnCard($Card) {
  if (-not $Card) { return $null }
  $focusId = Limit-ContractText ([string]$Card.focusId) 120
  $focusLabel = if ($Card.PSObject.Properties['focusLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$Card.focusLabel)) { Limit-ContractText ([string]$Card.focusLabel) 120 } else { Get-DefaultFocusLabel $focusId }
  $topicKeys = if ($Card.PSObject.Properties['topicKeys']) { @(Limit-TopicKeys @($Card.topicKeys)) } else { @(Get-DerivedTopicKeys $focusId) }
  $topicKeySource = if ($Card.PSObject.Properties['topicKeySource'] -and -not [string]::IsNullOrWhiteSpace([string]$Card.topicKeySource)) { [string]$Card.topicKeySource } else { 'focus_id_derived' }
  $prioritySourceValue = if ($Card.PSObject.Properties['prioritySource']) { [string]$Card.prioritySource } elseif ($Card.PSObject.Properties['priority'] -and $Card.priority.PSObject.Properties['source']) { [string]$Card.priority.source } else { 'current_contract' }
  $priorityReasonValue = if ($Card.PSObject.Properties['priorityReason']) { [string]$Card.priorityReason } elseif ($Card.PSObject.Properties['priority'] -and $Card.priority.PSObject.Properties['reason']) { [string]$Card.priority.reason } else { '' }
  return [pscustomobject]@{
    focusId = $focusId
    focusLabel = $focusLabel
    nextAction = Limit-ContractText ([string]$Card.nextAction) 220
    assistantCommitment = Limit-ContractText ([string]$Card.assistantCommitment) 300
    constraints = @(Limit-ContractList @($Card.constraints) 6 160)
    acceptanceCriteria = @(Limit-ContractList @($Card.acceptanceCriteria) 6 160)
    currentPhase = if ($Card.PSObject.Properties['currentPhase']) { Limit-ContractText ([string]$Card.currentPhase) 120 } else { '' }
    currentStep = if ($Card.PSObject.Properties['currentStep']) { Limit-ContractText ([string]$Card.currentStep) 220 } else { '' }
    completedSteps = if ($Card.PSObject.Properties['completedSteps']) { @(Limit-ContractList @($Card.completedSteps) $script:ActiveChecklistMaxItems 180) } else { @() }
    pendingSteps = if ($Card.PSObject.Properties['pendingSteps']) { @(Limit-ContractList @($Card.pendingSteps) $script:ActiveChecklistMaxItems 180) } else { @() }
    blockers = if ($Card.PSObject.Properties['blockers']) { @(Limit-ContractList @($Card.blockers) 6 180) } else { @() }
    evidence = if ($Card.PSObject.Properties['evidence']) { @(Limit-ContractList @($Card.evidence) 8 180) } else { @() }
    verificationResults = if ($Card.PSObject.Properties['verificationResults']) { @(Limit-ContractList @($Card.verificationResults) 6 180) } else { @() }
    projectProgressProof = if ($Card.PSObject.Properties['projectProgressProof'] -and $Card.projectProgressProof) { $Card.projectProgressProof } else { $null }
    visibleProgressReceipt = if ($Card.PSObject.Properties['visibleProgressReceipt'] -and $Card.visibleProgressReceipt) { $Card.visibleProgressReceipt } else { $null }
    topicKeys = @($topicKeys)
    topicKeySource = $topicKeySource
    prioritySource = $prioritySourceValue
    priorityReason = Limit-ContractText $priorityReasonValue 180
    checklistUpdateMode = if ($Card.PSObject.Properties['checklistUpdateMode']) { Limit-ContractText ([string]$Card.checklistUpdateMode) 24 } else { 'additive' }
    lastConfirmedSentence = if ($Card.PSObject.Properties['lastConfirmedSentence']) { Limit-ContractText ([string]$Card.lastConfirmedSentence) 320 } else { '' }
    lastConfirmedSource = if ($Card.PSObject.Properties['lastConfirmedSource']) { Limit-ContractText ([string]$Card.lastConfirmedSource) 48 } else { '' }
    planFingerprint = if ($Card.PSObject.Properties['planFingerprint']) { Limit-ContractText ([string]$Card.planFingerprint) 32 } elseif ($Card.PSObject.Properties['planReceipt'] -and $Card.planReceipt.PSObject.Properties['planFingerprint']) { Limit-ContractText ([string]$Card.planReceipt.planFingerprint) 32 } else { '' }
    canonicalPlanId = if ($Card.PSObject.Properties['canonicalPlanId']) { Limit-ContractText ([string]$Card.canonicalPlanId) 80 } else { '' }
    canonicalGeneration = if ($Card.PSObject.Properties['canonicalGeneration']) { [int]$Card.canonicalGeneration } else { 0 }
    canonicalFingerprint = if ($Card.PSObject.Properties['canonicalFingerprint']) { Limit-ContractText ([string]$Card.canonicalFingerprint) 32 } else { '' }
    canonicalActionFingerprint = if ($Card.PSObject.Properties['canonicalActionFingerprint']) { Limit-ContractText ([string]$Card.canonicalActionFingerprint) 32 } else { '' }
    actionBindingState = if ($Card.PSObject.Properties['actionBindingState']) { Limit-ContractText ([string]$Card.actionBindingState) 48 } else { '' }
    mergeCaptureRequest = if ($Card.PSObject.Properties['mergeCaptureRequest'] -and $Card.mergeCaptureRequest) { $Card.mergeCaptureRequest } else { $null }
    returnCardFingerprintVersion = if ($Card.PSObject.Properties['returnCardFingerprintVersion']) { Limit-ContractText ([string]$Card.returnCardFingerprintVersion) 16 } else { '' }
    returnCardFingerprint = if ($Card.PSObject.Properties['returnCardFingerprint']) { Limit-ContractText ([string]$Card.returnCardFingerprint) 32 } else { '' }
    capturedAt = if ($Card.PSObject.Properties['capturedAt']) { [string]$Card.capturedAt } else { (Get-SuperBrainUtcTimestamp) }
  }
}

function Limit-ReturnStack([object[]]$Items,[int]$MaxDepth=4) {
  $cards = @()
  foreach ($item in @($Items)) {
    $card = ConvertTo-ReturnCard $item
    if ($card -and -not [string]::IsNullOrWhiteSpace([string]$card.focusId)) { $cards += $card }
  }
  if ($cards.Count -le $MaxDepth) { return @($cards) }
  return @($cards | Select-Object -Last $MaxDepth)
}

function Limit-WorkLineIds([object[]]$Items,[int]$MaxItems=12) {
  $ids = @($Items | ForEach-Object {
    if ($_ -is [string]) { Limit-ContractText ([string]$_) 120 }
    elseif ($_ -and $_.PSObject.Properties['focusId']) { Limit-ContractText ([string]$_.focusId) 120 }
  } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($ids.Count -le $MaxItems) { return @($ids) }
  return @($ids | Select-Object -Last $MaxItems)
}

function Limit-MergeEvidenceList([object[]]$Items,[int]$MaxItems=6,[int]$MaxChars=160) {
  $protected = @($Items | ForEach-Object { Protect-Instruction ([string]$_) })
  return @(Limit-ContractList $protected $MaxItems $MaxChars)
}

function Get-MergeIntentList([object]$Value,[string]$Name,[int]$MaxItems=6,[int]$MaxChars=160) {
  if (-not $Value -or -not $Value.PSObject.Properties[$Name]) { return @() }
  return @(Limit-MergeEvidenceList @($Value.$Name) $MaxItems $MaxChars)
}

function Get-MergeIntentReadiness([object]$Intent) {
  $missing = @()
  $completion = if ($Intent -and $Intent.PSObject.Properties['completionEvidence']) { [string]$Intent.completionEvidence } else { '' }
  if ([string]::IsNullOrWhiteSpace($completion)) { $missing += 'completion_evidence' }
  $supportingEvidence = @()
  if ($Intent) {
    $supportingEvidence += @(Get-MergeIntentList $Intent 'artifactRefs' 6 160)
    $supportingEvidence += @(Get-MergeIntentList $Intent 'evidence' 6 160)
    $supportingEvidence += @(Get-MergeIntentList $Intent 'verificationResults' 6 160)
  }
  if ($supportingEvidence.Count -eq 0) { $missing += 'artifact_or_verification_evidence' }
  $verificationSteps = if ($Intent) { @(Get-MergeIntentList $Intent 'verificationSteps' 6 160) } else { @() }
  $verificationResults = if ($Intent) { @(Get-MergeIntentList $Intent 'verificationResults' 6 160) } else { @() }
  if ($verificationSteps.Count -gt 0 -and $verificationResults.Count -eq 0) { $missing += 'verification_results' }
  return [pscustomobject]@{
    ready = ($missing.Count -eq 0)
    state = if ($missing.Count -eq 0) { 'ready' } else { 'needs_evidence' }
    missing = @($missing)
  }
}

function ConvertTo-MergeIntent($Intent) {
  if (-not $Intent) { return $null }
  $sourceFocusId = if ($Intent.PSObject.Properties['sourceFocusId']) { Limit-ContractText ([string]$Intent.sourceFocusId) 120 } elseif ($Intent.PSObject.Properties['focusId']) { Limit-ContractText ([string]$Intent.focusId) 120 } else { '' }
  if ([string]::IsNullOrWhiteSpace($sourceFocusId)) { return $null }
  $sourceFocusLabel = if ($Intent.PSObject.Properties['sourceFocusLabel']) { Limit-ContractText ([string]$Intent.sourceFocusLabel) 120 } elseif ($Intent.PSObject.Properties['focusLabel']) { Limit-ContractText ([string]$Intent.focusLabel) 120 } else { Get-DefaultFocusLabel $sourceFocusId }
  $targetFocusId = if ($Intent.PSObject.Properties['targetFocusId']) { Limit-ContractText ([string]$Intent.targetFocusId) 120 } else { '' }
  $targetFocusLabel = if ($Intent.PSObject.Properties['targetFocusLabel']) { Limit-ContractText ([string]$Intent.targetFocusLabel) 120 } else { Get-DefaultFocusLabel $targetFocusId }
  $capturedAt = if ($Intent.PSObject.Properties['capturedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$Intent.capturedAt)) { [string]$Intent.capturedAt } else { (Get-SuperBrainUtcTimestamp) }
  $sourcePlanFingerprint = if ($Intent.PSObject.Properties['sourcePlanFingerprint']) { Limit-ContractText ([string]$Intent.sourcePlanFingerprint) 32 } else { '' }
  $mergeIntentId = if ($Intent.PSObject.Properties['mergeIntentId'] -and -not [string]::IsNullOrWhiteSpace([string]$Intent.mergeIntentId)) { Limit-ContractText ([string]$Intent.mergeIntentId) 80 } else { 'merge-' + (Get-ContinuityFingerprint ($sourceFocusId + '|' + $targetFocusId + '|' + $sourcePlanFingerprint)) }
  $requestedStatus = if ($Intent.PSObject.Properties['status']) { [string]$Intent.status } else { 'waiting_for_target' }
  $status = if ($requestedStatus -in @('waiting_for_target','ready_for_review','integrated','superseded')) { $requestedStatus } else { 'waiting_for_target' }
  $topicKeys = if ($Intent.PSObject.Properties['topicKeys']) { @(Limit-TopicKeys @($Intent.topicKeys)) } else { @() }
  if ($topicKeys.Count -eq 0) { $topicKeys = @(Get-DerivedTopicKeys $sourceFocusId) }
  $value = [pscustomobject]@{
    schema = 'super-brain.branch-merge-intent.v1'
    mergeIntentId = $mergeIntentId
    status = $status
    sourceFocusId = $sourceFocusId
    sourceFocusLabel = $sourceFocusLabel
    parentFocusId = if ($Intent.PSObject.Properties['parentFocusId']) { Limit-ContractText ([string]$Intent.parentFocusId) 120 } else { '' }
    targetFocusId = $targetFocusId
    targetFocusLabel = $targetFocusLabel
    targetScope = if ($Intent.PSObject.Properties['targetScope'] -and [string]$Intent.targetScope -in @('direct_parent','root_main','explicit')) { [string]$Intent.targetScope } else { 'root_main' }
    trigger = if ($Intent.PSObject.Properties['trigger'] -and -not [string]::IsNullOrWhiteSpace([string]$Intent.trigger)) { Limit-ContractText ([string]$Intent.trigger) 80 } else { 'explicit_merge_after_target' }
    noReimplementation = $true
    sourceObjective = if ($Intent.PSObject.Properties['sourceObjective']) { Limit-ContractText ([string]$Intent.sourceObjective) 220 } elseif ($Intent.PSObject.Properties['nextAction']) { Limit-ContractText ([string]$Intent.nextAction) 220 } else { '' }
    sourceCommitment = if ($Intent.PSObject.Properties['sourceCommitment']) { Limit-ContractText ([string]$Intent.sourceCommitment) 240 } elseif ($Intent.PSObject.Properties['assistantCommitment']) { Limit-ContractText ([string]$Intent.assistantCommitment) 240 } else { '' }
    completedSteps = @(Get-MergeIntentList $Intent 'completedSteps' 6 140)
    pendingSteps = @(Get-MergeIntentList $Intent 'pendingSteps' 4 140)
    artifactRefs = @(Get-MergeIntentList $Intent 'artifactRefs' 6 160)
    interfaceContracts = @(Get-MergeIntentList $Intent 'interfaceContracts' 5 160)
    dependencies = @(Get-MergeIntentList $Intent 'dependencies' 5 140)
    verificationSteps = @(Get-MergeIntentList $Intent 'verificationSteps' 6 140)
    verificationResults = @(Get-MergeIntentList $Intent 'verificationResults' 6 140)
    evidence = @(Get-MergeIntentList $Intent 'evidence' 6 160)
    acceptanceCriteria = @(Get-MergeIntentList $Intent 'acceptanceCriteria' 5 140)
    blockers = @(Get-MergeIntentList $Intent 'blockers' 4 140)
    mergeConditions = @(Get-MergeIntentList $Intent 'mergeConditions' 5 140)
    completionEvidence = if ($Intent.PSObject.Properties['completionEvidence']) { Limit-ContractText ([string]$Intent.completionEvidence) 240 } else { '' }
    sourcePlanFingerprint = $sourcePlanFingerprint
    sourceRevision = if ($Intent.PSObject.Properties['sourceRevision']) { [int]$Intent.sourceRevision } else { 0 }
    topicKeys = @($topicKeys)
    capturedAt = $capturedAt
    integratedAt = if ($Intent.PSObject.Properties['integratedAt']) { [string]$Intent.integratedAt } else { '' }
    integrationEvidence = if ($Intent.PSObject.Properties['integrationEvidence']) { Limit-ContractText ([string]$Intent.integrationEvidence) 240 } else { '' }
  }
  $readiness = Get-MergeIntentReadiness $value
  $value | Add-Member -NotePropertyName evidenceReadiness -NotePropertyValue $readiness.state
  $value | Add-Member -NotePropertyName missingEvidence -NotePropertyValue @($readiness.missing)
  return $value
}

function Limit-MergeIntents([object[]]$Items,[int]$MaxItems=$script:MergeIntentMaxCount) {
  if ($MaxItems -le 0) { return @() }
  $cards = @($Items | ForEach-Object { ConvertTo-MergeIntent $_ } | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.sourceFocusId) })
  $seen = @{}
  $latestFirst = @()
  for ($index = $cards.Count - 1; $index -ge 0; $index--) {
    $key = [string]$cards[$index].sourceFocusId
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $latestFirst += $cards[$index]
  }
  $deduped = @()
  for ($index = $latestFirst.Count - 1; $index -ge 0; $index--) { $deduped += $latestFirst[$index] }
  return @($deduped | Select-Object -Last $MaxItems)
}

function Test-DeferredMergeSignal([string]$Instruction) {
  $text = Limit-ContractText $Instruction 480
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  $waitSignal = $text -match '(?i)(?:\b(?:wait|defer|hold|later)\b|\u7b49\u5f85|\u7a0d\u540e|\u540e\u7eed|\u6682\u7f13|\u5f85)'
  $mergeSignal = $text -match '(?i)(?:\b(?:merge|integrat|wire\s+in|join)\b|\u5408\u5e76|\u6574\u5408|\u63a5\u5165)'
  $mainSignal = $text -match '(?i)(?:\b(?:main|parent)\b|\u4e3b\u7ebf|\u7236\u7ebf)'
  return ($mergeSignal -and ($waitSignal -or $mainSignal))
}

function Get-MergeTargetCard(
  [object[]]$ReturnStack,
  [string]$RequestedTargetFocusId = '',
  [string]$RequestedTargetLabel = '',
  [string]$RequestedScope = 'auto'
) {
  $cards = @(Limit-ReturnStack $ReturnStack)
  $scope = if ($RequestedScope -in @('direct_parent','root_main','explicit')) { $RequestedScope } else { 'root_main' }
  $target = $null
  if (-not [string]::IsNullOrWhiteSpace($RequestedTargetFocusId)) {
    $target = @($cards | Where-Object { [string]$_.focusId -eq [string]$RequestedTargetFocusId } | Select-Object -First 1)
    $target = if (@($target).Count -gt 0) { @($target)[0] } else { [pscustomobject]@{ focusId=$RequestedTargetFocusId; focusLabel=$RequestedTargetLabel } }
    $scope = 'explicit'
  } elseif ($cards.Count -gt 0) {
    $target = if ($scope -eq 'direct_parent') { $cards[-1] } else { $cards[0] }
  }
  if (-not $target) { return $null }
  $label = if (-not [string]::IsNullOrWhiteSpace($RequestedTargetLabel)) { Limit-ContractText $RequestedTargetLabel 120 } elseif ($target.PSObject.Properties['focusLabel']) { Limit-ContractText ([string]$target.focusLabel) 120 } else { Get-DefaultFocusLabel ([string]$target.focusId) }
  return [pscustomobject]@{ focusId=Limit-ContractText ([string]$target.focusId) 120; focusLabel=$label; scope=$scope }
}

function New-MergeCaptureRequest(
  [object]$ExistingRequest,
  [object[]]$ReturnStack,
  [string]$CurrentFocusId,
  [string]$TaskIdValue,
  [bool]$Enable,
  [string]$RequestedTargetFocusId = '',
  [string]$RequestedTargetLabel = '',
  [string]$RequestedScope = 'auto',
  [object[]]$ArtifactValues = @(),
  [object[]]$InterfaceValues = @(),
  [object[]]$DependencyValues = @(),
  [object[]]$VerificationStepValues = @(),
  [object[]]$MergeConditionValues = @(),
  [string]$RequestSource = ''
) {
  $existingRequested = ($ExistingRequest -and $ExistingRequest.PSObject.Properties['requested'] -and $ExistingRequest.requested -eq $true)
  if (-not $Enable -and -not $existingRequested) { return $null }
  $requestedTarget = if (-not [string]::IsNullOrWhiteSpace($RequestedTargetFocusId)) { $RequestedTargetFocusId } elseif ($ExistingRequest -and $ExistingRequest.PSObject.Properties['targetFocusId']) { [string]$ExistingRequest.targetFocusId } else { '' }
  $requestedLabel = if (-not [string]::IsNullOrWhiteSpace($RequestedTargetLabel)) { $RequestedTargetLabel } elseif ($ExistingRequest -and $ExistingRequest.PSObject.Properties['targetFocusLabel']) { [string]$ExistingRequest.targetFocusLabel } else { '' }
  $requestedScopeValue = if ($RequestedScope -in @('direct_parent','root_main','explicit')) { $RequestedScope } elseif ($ExistingRequest -and $ExistingRequest.PSObject.Properties['targetScope']) { [string]$ExistingRequest.targetScope } else { 'root_main' }
  $target = Get-MergeTargetCard $ReturnStack $requestedTarget $requestedLabel $requestedScopeValue
  if (-not $target -or [string]::IsNullOrWhiteSpace([string]$target.focusId)) { return $null }
  $artifactRefs = if ($script:ArtifactRefsWereBound) { @(Limit-MergeEvidenceList $ArtifactValues 6 160) } elseif ($ExistingRequest) { @(Get-MergeIntentList $ExistingRequest 'artifactRefs' 6 160) } else { @() }
  $interfaces = if ($script:InterfaceContractsWereBound) { @(Limit-MergeEvidenceList $InterfaceValues 5 160) } elseif ($ExistingRequest) { @(Get-MergeIntentList $ExistingRequest 'interfaceContracts' 5 160) } else { @() }
  $dependencies = if ($script:DependenciesWereBound) { @(Limit-MergeEvidenceList $DependencyValues 5 140) } elseif ($ExistingRequest) { @(Get-MergeIntentList $ExistingRequest 'dependencies' 5 140) } else { @() }
  $verificationSteps = if ($script:VerificationStepsWereBound) { @(Limit-MergeEvidenceList $VerificationStepValues 6 140) } elseif ($ExistingRequest) { @(Get-MergeIntentList $ExistingRequest 'verificationSteps' 6 140) } else { @() }
  $mergeConditions = if ($script:MergeConditionsWereBound) { @(Limit-MergeEvidenceList $MergeConditionValues 5 140) } elseif ($ExistingRequest) { @(Get-MergeIntentList $ExistingRequest 'mergeConditions' 5 140) } else { @('read_dossier_before_merge','verify_interface_and_dependency_fit','do_not_reimplement_branch') }
  $requestId = if ($ExistingRequest -and $ExistingRequest.PSObject.Properties['requestId'] -and -not [string]::IsNullOrWhiteSpace([string]$ExistingRequest.requestId)) { Limit-ContractText ([string]$ExistingRequest.requestId) 80 } else { 'merge-request-' + (Get-ContinuityFingerprint ($TaskIdValue + '|' + $CurrentFocusId + '|' + [string]$target.focusId)) }
  return [pscustomobject]@{
    requested = $true
    requestId = $requestId
    sourceFocusId = Limit-ContractText $CurrentFocusId 120
    targetFocusId = [string]$target.focusId
    targetFocusLabel = [string]$target.focusLabel
    targetScope = [string]$target.scope
    trigger = 'explicit_merge_after_target'
    noReimplementation = $true
    artifactRefs = @($artifactRefs)
    interfaceContracts = @($interfaces)
    dependencies = @($dependencies)
    verificationSteps = @($verificationSteps)
    mergeConditions = @($mergeConditions)
    requestSource = if (-not [string]::IsNullOrWhiteSpace($RequestSource)) { Limit-ContractText $RequestSource 120 } elseif ($ExistingRequest -and $ExistingRequest.PSObject.Properties['requestSource']) { Limit-ContractText ([string]$ExistingRequest.requestSource) 120 } else { 'assistant_execution_commitment' }
    requestedAt = if ($ExistingRequest -and $ExistingRequest.PSObject.Properties['requestedAt']) { [string]$ExistingRequest.requestedAt } else { (Get-SuperBrainUtcTimestamp) }
  }
}

function New-MergeIntentFromBranch(
  [string]$TaskIdValue,
  [object]$BranchCard,
  [object]$ParentCard,
  [object]$MergeRequest,
  [string]$CompletionEvidenceValue,
  [int]$SourceRevision
) {
  if (-not $BranchCard -or -not $MergeRequest) { return $null }
  $sourceFocusId = Limit-ContractText ([string]$BranchCard.focusId) 120
  if ([string]::IsNullOrWhiteSpace($sourceFocusId)) { return $null }
  $targetFocusId = Limit-ContractText ([string]$MergeRequest.targetFocusId) 120
  if ([string]::IsNullOrWhiteSpace($targetFocusId)) { return $null }
  $requestId = if ($MergeRequest.PSObject.Properties['requestId']) { [string]$MergeRequest.requestId } else { '' }
  $mergeIntentId = 'merge-' + (Get-ContinuityFingerprint ($TaskIdValue + '|' + $sourceFocusId + '|' + $targetFocusId + '|' + $requestId))
  return ConvertTo-MergeIntent ([pscustomobject]@{
    mergeIntentId = $mergeIntentId
    status = 'waiting_for_target'
    sourceFocusId = $sourceFocusId
    sourceFocusLabel = [string]$BranchCard.focusLabel
    parentFocusId = if ($ParentCard) { [string]$ParentCard.focusId } else { '' }
    targetFocusId = $targetFocusId
    targetFocusLabel = [string]$MergeRequest.targetFocusLabel
    targetScope = [string]$MergeRequest.targetScope
    trigger = [string]$MergeRequest.trigger
    sourceObjective = [string]$BranchCard.nextAction
    sourceCommitment = [string]$BranchCard.assistantCommitment
    completedSteps = @($BranchCard.completedSteps)
    pendingSteps = @($BranchCard.pendingSteps)
    artifactRefs = @($MergeRequest.artifactRefs)
    interfaceContracts = @($MergeRequest.interfaceContracts)
    dependencies = @($MergeRequest.dependencies)
    verificationSteps = @($MergeRequest.verificationSteps)
    verificationResults = @($BranchCard.verificationResults)
    evidence = @($BranchCard.evidence)
    acceptanceCriteria = @($BranchCard.acceptanceCriteria)
    blockers = @($BranchCard.blockers)
    mergeConditions = @($MergeRequest.mergeConditions)
    completionEvidence = $CompletionEvidenceValue
    sourcePlanFingerprint = [string]$BranchCard.planFingerprint
    sourceRevision = $SourceRevision
    topicKeys = @($BranchCard.topicKeys)
    capturedAt = (Get-SuperBrainUtcTimestamp)
  })
}

function Limit-UnfinishedWorkPlans([object[]]$Items,[object[]]$RelevantFocusIds=@(),[int]$MaxItems=12) {
  if ($MaxItems -le 0) { return @() }
  $cards = @($Items | ForEach-Object { ConvertTo-ReturnCard $_ } | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.focusId) })
  $seen = @{}
  $latestFirst = @()
  for ($index = $cards.Count - 1; $index -ge 0; $index--) {
    $focusId = [string]$cards[$index].focusId
    if ($seen.ContainsKey($focusId)) { continue }
    $seen[$focusId] = $true
    $latestFirst += $cards[$index]
  }
  $deduped = @()
  for ($index = $latestFirst.Count - 1; $index -ge 0; $index--) { $deduped += $latestFirst[$index] }

  $relevant = @(Limit-WorkLineIds $RelevantFocusIds $MaxItems)
  if ($relevant.Count -gt 0) {
    $selected = @()
    foreach ($focusId in $relevant) {
      $card = @($deduped | Where-Object { [string]$_.focusId -eq [string]$focusId } | Select-Object -Last 1)
      if ($card.Count -gt 0) { $selected += $card[0] }
    }
    return @($selected | Select-Object -Last $MaxItems)
  }
  return @($deduped | Select-Object -Last $MaxItems)
}

function Get-BoundedUnfinishedWorkState([object[]]$Lines,[object[]]$Plans,[object[]]$ExcludedFocusIds=@()) {
  $excluded = @($ExcludedFocusIds | ForEach-Object { Limit-ContractText ([string]$_) 120 } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  $candidatePlans = @(Limit-UnfinishedWorkPlans @($Plans | Where-Object {
    $candidateId = if ($_ -is [string]) { [string]$_ } elseif ($_ -and $_.PSObject.Properties['focusId']) { [string]$_.focusId } else { '' }
    -not ($excluded -contains $candidateId)
  }) @() $script:UnfinishedWorkPlanMaxCount)
  $candidateLines = @($Lines | Where-Object { -not ($excluded -contains [string]$_) }) + @($candidatePlans | ForEach-Object { [string]$_.focusId })
  $boundedLines = @(Limit-WorkLineIds $candidateLines $script:UnfinishedWorkPlanMaxCount)
  $boundedPlans = @(Limit-UnfinishedWorkPlans $candidatePlans $boundedLines $script:UnfinishedWorkPlanMaxCount)
  return [pscustomobject]@{ lines=@($boundedLines); plans=@($boundedPlans) }
}

function New-PlanSummary(
  [string]$FocusId,
  [string]$NextAction,
  [string]$AssistantCommitment,
  [object[]]$Constraints,
  [object[]]$AcceptanceCriteria,
  [string]$FocusLabel = '',
  [object[]]$TopicKeys = @(),
  [string]$TopicKeySource = 'focus_id_derived',
  [string]$PrioritySourceValue = 'current_contract',
  [string]$PriorityReasonValue = '',
  [int]$ExecutionRank = 1
) {
  $action = Limit-ContractText $NextAction 220
  $label = if ([string]::IsNullOrWhiteSpace($FocusLabel)) { Get-DefaultFocusLabel $FocusId } else { Limit-ContractText $FocusLabel 120 }
  $keys = @(Limit-TopicKeys $TopicKeys)
  if ($keys.Count -eq 0) { $keys = @(Get-DerivedTopicKeys $FocusId); $TopicKeySource = 'focus_id_derived' }
  return [pscustomobject]@{
    focusId = Limit-ContractText $FocusId 120
    focusLabel = $label
    nextAction = $action
    assistantCommitment = Limit-ContractText $AssistantCommitment 260
    constraints = @(Limit-ContractList $Constraints 3 140)
    acceptanceCriteria = @(Limit-ContractList $AcceptanceCriteria 3 140)
    topicKeys = @($keys)
    topicKeySource = $TopicKeySource
    priority = New-PriorityRecord $PrioritySourceValue $PriorityReasonValue $ExecutionRank
    hasConcreteNextAction = -not [string]::IsNullOrWhiteSpace($action)
  }
}

function Get-TopicClassification(
  [string]$Instruction,
  [string]$ActiveFocusId,
  [string]$ActiveFocusLabel,
  [object[]]$ActiveTopicKeys,
  [string]$ActiveTopicKeySource,
  [object[]]$ReturnStack,
  [object[]]$UnfinishedWorkPlans,
  [string]$ActiveCurrentStep='',
  [string]$ActiveNextAction='',
  [string]$ActiveAssistantCommitment='',
  [object[]]$MergeIntents=@()
) {
  $empty = [pscustomobject]@{
    mode = 'unclassified'
    topicAffinity = 'unknown'
    targetLineId = ''
    targetLineLabel = ''
    mergeIntentId = ''
    confidence = 'none'
    matchedKeys = @()
    candidateLineIds = @()
    needsClarification = (@($ReturnStack).Count + @($UnfinishedWorkPlans).Count + @($MergeIntents).Count -gt 0)
    recommendedInstructionMode = 'classify'
    reason = 'no unique task-scoped topic key matched'
    rawInstructionStored = $false
  }
  if ([string]::IsNullOrWhiteSpace($Instruction)) { return $empty }

  $trimmed = $Instruction.Trim()
  $continueWord = -join (@(0x7EE7,0x7EED) | ForEach-Object { [char]$_ })
  $connectWord = -join (@(0x63A5,0x7740) | ForEach-Object { [char]$_ })
  $nextStepWord = -join (@(0x4E0B,0x4E00,0x6B65) | ForEach-Object { [char]$_ })
  $proceedNextStepWord = -join (@(0x8FDB,0x884C,0x4E0B,0x4E00,0x6B65) | ForEach-Object { [char]$_ })
  $continueNextStepWord = -join (@(0x7EE7,0x7EED,0x4E0B,0x4E00,0x6B65) | ForEach-Object { [char]$_ })
  $continuationAliases = @($continueWord,$connectWord,$nextStepWord,$proceedNextStepWord,$continueNextStepWord)
  $hasContinuationSignal = ($trimmed -match '(?i)^\s*(continue|resume)\b' -or @($continuationAliases | Where-Object { $trimmed.StartsWith([string]$_) }).Count -gt 0)
  $bareContinuation = ($trimmed -replace '^[\s\p{P}]+|[\s\p{P}]+$','')
  $isBareContinuation = ($bareContinuation -match '(?i)^(continue|resume)$' -or @($continuationAliases | Where-Object { $bareContinuation -eq [string]$_ }).Count -gt 0)

  $candidates = @()
  $candidates += [pscustomobject]@{
    focusId = $ActiveFocusId
    focusLabel = $ActiveFocusLabel
    role = 'active'
    mergeIntentId = ''
    topicKeys = @(Limit-TopicKeys $ActiveTopicKeys)
    topicKeySource = $ActiveTopicKeySource
    currentStep = $ActiveCurrentStep
    nextAction = $ActiveNextAction
    assistantCommitment = $ActiveAssistantCommitment
  }
  foreach ($item in @(Limit-ReturnStack $ReturnStack)) {
    $candidates += [pscustomobject]@{
      focusId = [string]$item.focusId
      focusLabel = [string]$item.focusLabel
      role = 'suspended'
      mergeIntentId = ''
      topicKeys = @($item.topicKeys)
      topicKeySource = [string]$item.topicKeySource
      currentStep = [string]$item.currentStep
      nextAction = [string]$item.nextAction
      assistantCommitment = [string]$item.assistantCommitment
    }
  }
  foreach ($item in @(Limit-UnfinishedWorkPlans $UnfinishedWorkPlans @() $script:UnfinishedWorkPlanMaxCount)) {
    if (@($candidates | Where-Object { [string]$_.focusId -eq [string]$item.focusId }).Count -gt 0) { continue }
    $candidates += [pscustomobject]@{
      focusId = [string]$item.focusId
      focusLabel = [string]$item.focusLabel
      role = 'unfinished'
      mergeIntentId = ''
      topicKeys = @($item.topicKeys)
      topicKeySource = [string]$item.topicKeySource
      currentStep = [string]$item.currentStep
      nextAction = [string]$item.nextAction
      assistantCommitment = [string]$item.assistantCommitment
    }
  }
  foreach ($intent in @(Limit-MergeIntents $MergeIntents | Where-Object { [string]$_.status -in @('waiting_for_target','ready_for_review') })) {
    if (@($candidates | Where-Object { [string]$_.focusId -eq [string]$intent.sourceFocusId }).Count -gt 0) { continue }
    $candidates += [pscustomobject]@{
      focusId = [string]$intent.sourceFocusId
      focusLabel = [string]$intent.sourceFocusLabel
      role = 'merge_waiting'
      mergeIntentId = [string]$intent.mergeIntentId
      topicKeys = @($intent.topicKeys)
      topicKeySource = 'explicit'
      currentStep = 'read merge dossier before integration'
      nextAction = 'prepare merge from retained branch dossier'
      assistantCommitment = 'do not reimplement the retained branch'
    }
  }

  $matches = @()
  foreach ($candidate in @($candidates)) {
    $matchedKeys = @($candidate.topicKeys | Where-Object { Test-TopicKeyMatch $Instruction ([string]$_) } | Select-Object -Unique)
    if ($matchedKeys.Count -eq 0) { continue }
    $explicit = ([string]$candidate.topicKeySource -eq 'explicit')
    $longest = @($matchedKeys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum
    $matches += [pscustomobject]@{
      candidate = $candidate
      matchedKeys = @($matchedKeys)
      score = $(if ($explicit) { 100 } else { 10 }) + ($matchedKeys.Count * 5) + [int]$longest
      confidence = if ($explicit) { 'high' } else { 'medium' }
    }
  }
  if ($matches.Count -eq 0) {
    if (Test-SuperBrainRuntimeWakeContextReply $Instruction) {
      return [pscustomobject]@{
        mode='continue'; topicAffinity='active'; targetLineId=Limit-ContractText $ActiveFocusId 120; targetLineLabel=if([string]::IsNullOrWhiteSpace($ActiveFocusLabel)){Get-DefaultFocusLabel $ActiveFocusId}else{Limit-ContractText $ActiveFocusLabel 120}; confidence='high'; matchedKeys=@('context_reply_signal'); candidateLineIds=@(Limit-ContractText $ActiveFocusId 120); needsClarification=$false; recommendedInstructionMode='continue'; reason='a bounded contextual reply binds to the active work line'; rawInstructionStored=$false
      }
    }
    if (-not $isBareContinuation) {
      $wakeLines = @($candidates | ForEach-Object {
        New-SuperBrainRuntimeWakeLine ([string]$_.focusId) ([string]$_.focusLabel) ([string]$_.role) @() ([string]$_.currentStep) ([string]$_.nextAction) ([string]$_.assistantCommitment)
      })
      $wakeAffinity = Get-SuperBrainRuntimeWakeAffinity $Instruction $wakeLines
      if ([string]$wakeAffinity.topicAffinity -eq 'ambiguous') {
        return [pscustomobject]@{
          mode='ambiguous'; topicAffinity='ambiguous'; targetLineId=''; targetLineLabel=''; confidence='low'; matchedKeys=@($wakeAffinity.matchedTerms); candidateLineIds=@($wakeAffinity.candidateLineIds); needsClarification=$true; recommendedInstructionMode='classify'; reason=[string]$wakeAffinity.reason; rawInstructionStored=$false
        }
      }
      if ([string]$wakeAffinity.topicAffinity -ne 'unknown') {
        $winner = @($candidates | Where-Object { [string]$_.focusId -eq [string]$wakeAffinity.targetLineId } | Select-Object -First 1)
        if ($winner.Count -eq 1) {
          $role = [string]$winner[0].role
          $highConfidence = ([string]$wakeAffinity.confidence -eq 'high')
          return [pscustomobject]@{
            mode=if($role -eq 'active'){'continue'}else{'line_reference'}
            topicAffinity=if($role -eq 'active'){'active'}else{$role+':'+[string]$winner[0].focusId}
            targetLineId=[string]$winner[0].focusId
            targetLineLabel=[string]$winner[0].focusLabel
            mergeIntentId=if($winner[0].PSObject.Properties['mergeIntentId']){[string]$winner[0].mergeIntentId}else{''}
            confidence=[string]$wakeAffinity.confidence
            matchedKeys=@($wakeAffinity.matchedTerms | ForEach-Object { 'derived_state:' + [string]$_ })
            candidateLineIds=@([string]$winner[0].focusId)
            needsClarification=(-not $highConfidence)
            recommendedInstructionMode=if($role -eq 'active'){'continue'}elseif($role -eq 'unfinished'){'side_branch'}elseif($role -eq 'merge_waiting'){'merge_review'}else{'resume_parent'}
            reason=[string]$wakeAffinity.reason
            rawInstructionStored=$false
          }
        }
      }
      if ($hasContinuationSignal) { $empty.reason = 'continuation included a line qualifier, but no unique task-scoped topic key matched' }
      return $empty
    }
    return [pscustomobject]@{
      mode = 'continue'
      topicAffinity = 'active'
      targetLineId = Limit-ContractText $ActiveFocusId 120
      targetLineLabel = if ([string]::IsNullOrWhiteSpace($ActiveFocusLabel)) { Get-DefaultFocusLabel $ActiveFocusId } else { Limit-ContractText $ActiveFocusLabel 120 }
      confidence = 'high'
      matchedKeys = @('continuation_signal')
      candidateLineIds = @(Limit-ContractText $ActiveFocusId 120)
      needsClarification = $false
      recommendedInstructionMode = 'continue'
      reason = 'bare continuation signal binds to the active work line after topic assignment finds no target'
      rawInstructionStored = $false
    }
  }

  $ranked = @($matches | Sort-Object score -Descending)
  $topScore = [int]$ranked[0].score
  $top = @($ranked | Where-Object { [int]$_.score -eq $topScore })
  if ($top.Count -ne 1) {
    return [pscustomobject]@{
      mode = 'ambiguous'
      topicAffinity = 'ambiguous'
      targetLineId = ''
      targetLineLabel = ''
      confidence = 'low'
      matchedKeys = @($top | ForEach-Object { @($_.matchedKeys) } | Select-Object -Unique)
      candidateLineIds = @($top | ForEach-Object { [string]$_.candidate.focusId } | Select-Object -Unique)
      needsClarification = $true
      recommendedInstructionMode = 'classify'
      reason = 'multiple work lines have the same strongest task-scoped topic match'
      rawInstructionStored = $false
    }
  }

  $winner = $top[0]
  $role = [string]$winner.candidate.role
  $highConfidence = ([string]$winner.confidence -eq 'high')
  return [pscustomobject]@{
    mode = if ($role -eq 'active') { 'continue' } else { 'line_reference' }
    topicAffinity = if ($role -eq 'active') { 'active' } else { $role + ':' + [string]$winner.candidate.focusId }
    targetLineId = [string]$winner.candidate.focusId
    targetLineLabel = if ([string]::IsNullOrWhiteSpace([string]$winner.candidate.focusLabel)) { Get-DefaultFocusLabel ([string]$winner.candidate.focusId) } else { [string]$winner.candidate.focusLabel }
    mergeIntentId = if ($winner.candidate.PSObject.Properties['mergeIntentId']) { [string]$winner.candidate.mergeIntentId } else { '' }
    confidence = [string]$winner.confidence
    matchedKeys = @($winner.matchedKeys)
    candidateLineIds = @([string]$winner.candidate.focusId)
    needsClarification = -not $highConfidence
    recommendedInstructionMode = if ($role -eq 'active') { 'continue' } elseif ($role -eq 'unfinished') { 'side_branch' } elseif ($role -eq 'merge_waiting') { 'merge_review' } else { 'resume_parent' }
    reason = if ($highConfidence) { 'one explicit task-scoped topic key set matched uniquely' } else { 'one derived focus-id topic candidate matched; confirm before changing focus' }
    rawInstructionStored = $false
  }
}

function Test-ClassificationBlocksAuthorization([object]$Classification,[string]$Instruction) {
  if (-not $Classification -or [string]::IsNullOrWhiteSpace($Instruction)) { return $false }
  return ($Classification.needsClarification -eq $true -or [string]$Classification.topicAffinity -in @('unknown','ambiguous'))
}

function Test-ClassificationAuthorizesParentResume([object]$Classification,[string]$Instruction,[string]$ActiveFocusId) {
  if (-not $Classification) { return $false }
  if ($Classification.needsClarification -eq $true) { return $false }
  if ([string]$Classification.topicAffinity -ne 'active' -or [string]$Classification.confidence -ne 'high') { return $false }
  if ([string]::IsNullOrWhiteSpace($ActiveFocusId) -or [string]$Classification.targetLineId -ne $ActiveFocusId) { return $false }
  $mode = [string]$Classification.mode
  if ($mode -notin @('continue','side_branch','resume_parent')) { return $false }
  $matchedKeys = @($Classification.matchedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($matchedKeys.Count -eq 0) { return $false }
  if ($mode -eq 'resume_parent' -and -not ($matchedKeys -contains 'return_card')) { return $false }
  if (-not [string]::IsNullOrWhiteSpace($Instruction)) { return $true }
  return ($matchedKeys -contains 'explicit_instruction_mode')
}

function New-WorkLineLineage([object[]]$ReturnCards,[object]$ActivePlan) {
  $cards = @(Limit-ReturnStack @($ReturnCards))
  $lineage = @()
  for ($index = 0; $index -lt $cards.Count; $index++) {
    $card = $cards[$index]
    $lineage += [pscustomobject]@{
      depth = $index
      focusId = [string]$card.focusId
      focusLabel = [string]$card.focusLabel
      parentFocusId = if ($index -gt 0) { [string]$cards[$index - 1].focusId } else { '' }
      childFocusId = if ($index + 1 -lt $cards.Count) { [string]$cards[$index + 1].focusId } else { [string]$ActivePlan.focusId }
      role = if ($index -eq 0) { 'main_line' } else { 'side_branch' }
      status = 'suspended'
      nextAction = Limit-ContractText ([string]$card.nextAction) 220
    }
  }
  $activeDepth = $cards.Count
  $lineage += [pscustomobject]@{
    depth = $activeDepth
    focusId = [string]$ActivePlan.focusId
    focusLabel = [string]$ActivePlan.focusLabel
    parentFocusId = if ($cards.Count -gt 0) { [string]$cards[-1].focusId } else { '' }
    childFocusId = ''
    role = if ($cards.Count -gt 0) { 'side_branch' } else { 'main_line' }
    status = 'active'
    nextAction = Limit-ContractText ([string]$ActivePlan.nextAction) 220
  }
  return @($lineage)
}

function New-WorkLineStatus(
  [string]$ActiveFocusId,
  [object[]]$ReturnStack,
  [object[]]$CompletedWorkLines,
  [object[]]$UnfinishedWorkLines,
  [string]$ActiveNextAction = '',
  [string]$ActiveAssistantCommitment = '',
  [object[]]$ActiveConstraints = @(),
  [object[]]$ActiveAcceptanceCriteria = @(),
  [string]$ActiveFocusLabel = '',
  [object[]]$ActiveTopicKeys = @(),
  [string]$ActiveTopicKeySource = 'focus_id_derived',
  [string]$ActivePrioritySource = 'current_contract',
  [string]$ActivePriorityReason = '',
  [object[]]$UnfinishedWorkPlans = @(),
  [object]$LatestMessageClassification = $null,
  [object[]]$MergeIntents = @(),
  [object]$CanonicalPlan = $null,
  [object[]]$ActiveWorkPackageCompletedSteps = @(),
  [object[]]$ActiveWorkPackagePendingSteps = @()
) {
  $returnCards = @(Limit-ReturnStack @($ReturnStack))
  $suspended = @(Limit-WorkLineIds @($returnCards) 4)
  $completed = @(Limit-WorkLineIds @($CompletedWorkLines) 12)
  $excludedUnfinished = @($ActiveFocusId) + @($returnCards | ForEach-Object { [string]$_.focusId })
  $unfinishedState = Get-BoundedUnfinishedWorkState $UnfinishedWorkLines $UnfinishedWorkPlans $excludedUnfinished
  $unfinished = @($unfinishedState.lines)
  $pendingMergeIntents = @(Limit-MergeIntents $MergeIntents | Where-Object { [string]$_.status -in @('waiting_for_target','ready_for_review') })
  $mergeQueue = @($pendingMergeIntents | ForEach-Object {
    [pscustomobject]@{
      mergeIntentId = [string]$_.mergeIntentId
      sourceFocusId = [string]$_.sourceFocusId
      sourceFocusLabel = [string]$_.sourceFocusLabel
      targetFocusId = [string]$_.targetFocusId
      targetFocusLabel = [string]$_.targetFocusLabel
      status = [string]$_.status
      evidenceReadiness = [string]$_.evidenceReadiness
      missingEvidence = @($_.missingEvidence)
      noReimplementation = $true
      readyForCurrentLine = ([string]$_.targetFocusId -eq [string]$ActiveFocusId)
    }
  })
  $unfinishedCards = @()
  foreach ($unfinishedId in $unfinished) {
    $matchingCard = @($unfinishedState.plans | Where-Object { [string]$_.focusId -eq [string]$unfinishedId } | Select-Object -Last 1)
    if ($matchingCard.Count -gt 0) { $unfinishedCards += $matchingCard[0] }
    else { $unfinishedCards += ConvertTo-ReturnCard ([pscustomobject]@{ focusId=$unfinishedId; capturedAt='' }) }
  }
  $activePlan = New-PlanSummary $ActiveFocusId $ActiveNextAction $ActiveAssistantCommitment $ActiveConstraints $ActiveAcceptanceCriteria $ActiveFocusLabel $ActiveTopicKeys $ActiveTopicKeySource $ActivePrioritySource $ActivePriorityReason 1
  $mainCard = if ($returnCards.Count -gt 0) { $returnCards[0] } else { $null }
  $nextCard = if ($returnCards.Count -gt 0) { $returnCards[-1] } else { $null }
  $mainPlan = if ($mainCard) { New-PlanSummary ([string]$mainCard.focusId) ([string]$mainCard.nextAction) ([string]$mainCard.assistantCommitment) @($mainCard.constraints) @($mainCard.acceptanceCriteria) ([string]$mainCard.focusLabel) @($mainCard.topicKeys) ([string]$mainCard.topicKeySource) ([string]$mainCard.prioritySource) ([string]$mainCard.priorityReason) ($returnCards.Count + 1) } else { $activePlan }
  $nextPlan = if ($nextCard) { New-PlanSummary ([string]$nextCard.focusId) ([string]$nextCard.nextAction) ([string]$nextCard.assistantCommitment) @($nextCard.constraints) @($nextCard.acceptanceCriteria) ([string]$nextCard.focusLabel) @($nextCard.topicKeys) ([string]$nextCard.topicKeySource) ([string]$nextCard.prioritySource) ([string]$nextCard.priorityReason) 2 } else { $activePlan }
  $lineage = @(New-WorkLineLineage $returnCards $activePlan)
  $lineageDepth = [Math]::Max(0,$lineage.Count - 1)
  $directParent = if ($lineage.Count -gt 1) { $lineage[-2] } else { $null }
  $lineagePath = @($lineage | ForEach-Object { [string]$_.focusLabel })

  $suspendedPlans = @()
  $priorityOrder = @([pscustomobject]@{ executionRank=1; focusId=$activePlan.focusId; focusLabel=$activePlan.focusLabel; role=if($returnCards.Count -gt 0){'active_branch'}else{'main_line'}; source=$activePlan.priority.source; reason=$activePlan.priority.reason })
  $rank = 2
  for ($index = $returnCards.Count - 1; $index -ge 0; $index--) {
    $card = $returnCards[$index]
    $plan = New-PlanSummary ([string]$card.focusId) ([string]$card.nextAction) ([string]$card.assistantCommitment) @($card.constraints) @($card.acceptanceCriteria) ([string]$card.focusLabel) @($card.topicKeys) ([string]$card.topicKeySource) ([string]$card.prioritySource) ([string]$card.priorityReason) $rank
    $suspendedPlans += $plan
    $priorityOrder += [pscustomobject]@{ executionRank=$rank; focusId=$plan.focusId; focusLabel=$plan.focusLabel; role=if($index -eq 0){'suspended_main'}else{'suspended_branch'}; source=$plan.priority.source; reason='resume nearest suspended parent after active work' }
    $rank += 1
  }
  $unfinishedPlans = @()
  for ($index = $unfinishedCards.Count - 1; $index -ge 0; $index--) {
    $card = $unfinishedCards[$index]
    $unfinishedReason = 'resume retained unfinished branch after active and suspended work lines'
    $plan = New-PlanSummary ([string]$card.focusId) ([string]$card.nextAction) ([string]$card.assistantCommitment) @($card.constraints) @($card.acceptanceCriteria) ([string]$card.focusLabel) @($card.topicKeys) ([string]$card.topicKeySource) ([string]$card.prioritySource) $unfinishedReason $rank
    $unfinishedPlans += $plan
    $priorityOrder += [pscustomobject]@{ executionRank=$rank; focusId=$plan.focusId; focusLabel=$plan.focusLabel; role='unfinished_branch'; source=$plan.priority.source; reason=$unfinishedReason }
    $rank += 1
  }

  if (-not $LatestMessageClassification) {
    $LatestMessageClassification = Get-TopicClassification '' $ActiveFocusId $ActiveFocusLabel $ActiveTopicKeys $ActiveTopicKeySource $returnCards $unfinishedCards '' '' '' $pendingMergeIntents
  }
  $canonicalProjection = if ($CanonicalPlan) { Get-CanonicalPlanProjection $CanonicalPlan } else { $null }
  $useCanonicalMainChecklist = ($canonicalProjection -and $returnCards.Count -eq 0 -and [string]$ActiveFocusId -eq [string]$CanonicalPlan.rootFocusId)
  $workPackageChecklist = @()
  if ($useCanonicalMainChecklist) {
    $workPackageChecklist = @($canonicalProjection.activeChecklist)
  } else {
    $workPackageOrdinal = 1
    foreach ($step in @(Limit-ContractList $ActiveWorkPackageCompletedSteps $script:ActiveChecklistMaxItems 180)) {
      $workPackageChecklist += [pscustomobject]@{ ordinal=$workPackageOrdinal; status='completed'; label=$step }
      $workPackageOrdinal++
    }
    foreach ($step in @(Limit-ContractList $ActiveWorkPackagePendingSteps $script:ActiveChecklistMaxItems 180)) {
      $workPackageChecklist += [pscustomobject]@{ ordinal=$workPackageOrdinal; status='pending'; label=$step }
      $workPackageOrdinal++
    }
  }
  $workLines = @([pscustomobject]@{ focusId=$activePlan.focusId; focusLabel=$activePlan.focusLabel; role=if($returnCards.Count -gt 0){'active_branch'}else{'main_line'}; status='active'; plan=$activePlan })
  foreach ($plan in $suspendedPlans) {
    $workLines += [pscustomobject]@{ focusId=$plan.focusId; focusLabel=$plan.focusLabel; role=if($plan.focusId -eq $mainPlan.focusId){'main_line'}else{'side_branch'}; status='suspended'; plan=$plan }
  }
  foreach ($plan in $unfinishedPlans) {
    if (@($workLines | Where-Object { [string]$_.focusId -eq [string]$plan.focusId }).Count -eq 0) {
      $workLines += [pscustomobject]@{ focusId=$plan.focusId; focusLabel=$plan.focusLabel; role='side_branch'; status='unfinished'; plan=$plan }
    }
  }

  return [pscustomobject]@{
    canonicalMain = if ($CanonicalPlan) { [pscustomobject]@{
      planId = [string]$CanonicalPlan.planId
      generation = [int]$CanonicalPlan.generation
      rootFocusId = [string]$CanonicalPlan.rootFocusId
      currentFingerprint = [string]$CanonicalPlan.currentFingerprint
      orderConfidence = [string]$CanonicalPlan.orderConfidence
      itemCount = [int]$canonicalProjection.itemCount
      completedCount = [int]$canonicalProjection.completedCount
      pendingCount = [int]$canonicalProjection.pendingCount
      cancelledCount = [int]$canonicalProjection.cancelledCount
    } } else { $null }
    activeWorkPackage = [pscustomobject]@{
      focusId = Limit-ContractText $ActiveFocusId 120
      focusLabel = Limit-ContractText $ActiveFocusLabel 120
      role = if ($returnCards.Count -gt 0) { 'side_branch' } else { 'main_line' }
      status = 'active'
      nextAction = Limit-ContractText $ActiveNextAction 220
      checklistCount = @($workPackageChecklist).Count
      checklist = @($workPackageChecklist)
    }
    mainLine = if ($suspended.Count -gt 0) { [string]$suspended[0] } else { Limit-ContractText $ActiveFocusId 120 }
    activeLine = Limit-ContractText $ActiveFocusId 120
    currentLineCount = $lineage.Count + $unfinishedPlans.Count
    lineageLineCount = $lineage.Count
    unfinishedLineCount = $unfinishedPlans.Count
    pendingMergeIntentCount = $mergeQueue.Count
    pendingMergeIntents = @($mergeQueue)
    completedRecent = @($completed)
    unfinishedLines = @($unfinished)
    suspendedLines = @($suspended)
    lineageDepth = $lineageDepth
    lineagePath = @($lineagePath)
    lineage = @($lineage)
    directParent = if ($directParent) { [pscustomobject]@{ focusId=$directParent.focusId; label=$directParent.focusLabel; depth=[int]$directParent.depth; nextAction=$directParent.nextAction } } else { $null }
    defaultNextLine = if ($suspended.Count -gt 0) { [string]$suspended[-1] } else { Limit-ContractText $ActiveFocusId 120 }
    priorityPolicy = 'latest_explicit_user_priority_then_nearest_suspended_parent'
    prioritySemantics = 'rank 1 is active; suspended parents follow nearest-first; retained unfinished branches follow newest-first'
    priorityOrder = @($priorityOrder)
    activePlan = $activePlan
    mainPlan = $mainPlan
    nextPlan = $nextPlan
    suspendedPlans = @($suspendedPlans)
    unfinishedPlans = @($unfinishedPlans)
    workLines = @($workLines)
    latestMessageClassification = $LatestMessageClassification
    requiresUserDisambiguation = ($LatestMessageClassification.needsClarification -eq $true)
    planRecoveryRequired = -not [bool]$activePlan.hasConcreteNextAction
    userView = [pscustomobject]@{
      main = [pscustomobject]@{ focusId=$mainPlan.focusId; label=$mainPlan.focusLabel; status=if($returnCards.Count -gt 0){'suspended'}else{'active'} }
      current = [pscustomobject]@{ focusId=$activePlan.focusId; label=$activePlan.focusLabel; status='active'; role=if($returnCards.Count -gt 0){'side_branch'}else{'main_line'} }
      currentLineCount = $lineage.Count + $unfinishedPlans.Count
      lineageLineCount = $lineage.Count
      unfinishedLineCount = $unfinishedPlans.Count
      pendingMergeIntentCount = $mergeQueue.Count
      pendingMerges = @($mergeQueue)
      suspended = @($suspendedPlans | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; label=$_.focusLabel; nextAction=$_.nextAction } })
      unfinished = @($unfinishedPlans | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; label=$_.focusLabel; status='unfinished'; role='side_branch'; nextAction=$_.nextAction; executionRank=$_.priority.executionRank } })
      depth = $lineageDepth
      path = @($lineagePath)
      directParent = if ($directParent) { [pscustomobject]@{ focusId=$directParent.focusId; label=$directParent.focusLabel; depth=[int]$directParent.depth; nextAction=$directParent.nextAction } } else { $null }
      priority = @($priorityOrder)
      latestMessage = $LatestMessageClassification
    }
  }
}

function Get-ContinuityFingerprint([object]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return -join ($sha.ComputeHash($bytes)[0..7] | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
}

function Get-TransitionPayloadHash([object]$Value) {
  return Get-ContinuityFingerprint ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Limit-TransitionReceipts([object[]]$Items,[int]$MaxItems=$script:TransitionReceiptMaxCount) {
  $result = @()
  foreach ($item in @($Items)) {
    if (-not $item) { continue }
    $transitionIdValue = Limit-ContractText ([string]$item.transitionId) 120
    if ([string]::IsNullOrWhiteSpace($transitionIdValue)) { continue }
    $record = [pscustomobject]@{
      transitionId = $transitionIdValue
      action = Limit-ContractText ([string]$item.action) 48
      payloadHash = Limit-ContractText ([string]$item.payloadHash) 32
      fromRevision = if ($item.PSObject.Properties['fromRevision']) { [int]$item.fromRevision } else { 0 }
      resultRevision = if ($item.PSObject.Properties['resultRevision']) { [int]$item.resultRevision } elseif ($item.PSObject.Properties['toRevision']) { [int]$item.toRevision } else { 0 }
      fromFocusId = Limit-ContractText ([string]$item.fromFocusId) 120
      toFocusId = Limit-ContractText ([string]$item.toFocusId) 120
      recordedAt = Limit-ContractText ([string]$item.recordedAt) 48
    }
    $result = @($result | Where-Object { [string]$_.transitionId -ne $transitionIdValue }) + @($record)
  }
  if ($result.Count -le $MaxItems) { return @($result) }
  return @($result | Select-Object -Last $MaxItems)
}

function Get-TransitionReceipt([object]$Contract,[string]$TransitionIdValue) {
  if (-not $Contract -or [string]::IsNullOrWhiteSpace($TransitionIdValue)) { return $null }
  $matches = @(Limit-TransitionReceipts $(if($Contract.PSObject.Properties['transitionReceipts']){@($Contract.transitionReceipts)}else{@()}) | Where-Object { [string]$_.transitionId -eq $TransitionIdValue } | Select-Object -Last 1)
  if ($matches.Count -eq 1) { return $matches[0] }
  return $null
}

function Add-TransitionReceipt(
  [object[]]$Items,
  [string]$TransitionIdValue,
  [string]$ActionValue,
  [string]$PayloadHashValue,
  [int]$FromRevision,
  [int]$ResultRevision,
  [string]$FromFocusId,
  [string]$ToFocusId
) {
  $existing = @(Limit-TransitionReceipts $Items)
  if ([string]::IsNullOrWhiteSpace($TransitionIdValue)) { return @($existing) }
  $receipt = [pscustomobject]@{
    transitionId = Limit-ContractText $TransitionIdValue 120
    action = Limit-ContractText $ActionValue 48
    payloadHash = Limit-ContractText $PayloadHashValue 32
    fromRevision = $FromRevision
    resultRevision = $ResultRevision
    fromFocusId = Limit-ContractText $FromFocusId 120
    toFocusId = Limit-ContractText $ToFocusId 120
    recordedAt = (Get-SuperBrainUtcTimestamp)
  }
  return @(Limit-TransitionReceipts (@($existing) + @($receipt)))
}

function New-TransitionReplayResult([object]$Contract,[object]$Receipt) {
  $result = $Contract | Select-Object *
  $result | Add-Member -NotePropertyName idempotentReplay -NotePropertyValue $true -Force
  $result | Add-Member -NotePropertyName replayedTransitionId -NotePropertyValue ([string]$Receipt.transitionId) -Force
  $result | Add-Member -NotePropertyName originalResultRevision -NotePropertyValue ([int]$Receipt.resultRevision) -Force
  return $result
}

function Get-ReturnCardFingerprint(
  [object]$Card,
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue,
  [object[]]$LineageFocusIds,
  [ValidateSet('v1','v2','v3','v4','v5','v6')]
  [string]$FingerprintVersion = 'v3'
) {
  $checklistLimit = if ($FingerprintVersion -in @('v3','v4','v5','v6')) { $script:ActiveChecklistMaxItems } else { 8 }
  $payload = [ordered]@{
    taskId = Limit-ContractText $TaskIdValue 160
    workspaceKey = Limit-ContractText $WorkspaceKeyValue 80
    lineage = @($LineageFocusIds | ForEach-Object { Limit-ContractText ([string]$_) 120 })
    focusId = Limit-ContractText ([string]$Card.focusId) 120
    focusLabel = Limit-ContractText ([string]$Card.focusLabel) 120
    nextAction = Limit-ContractText ([string]$Card.nextAction) 220
    assistantCommitment = Limit-ContractText ([string]$Card.assistantCommitment) 300
    constraints = @(Limit-ContractList @($Card.constraints) 6 160)
    acceptanceCriteria = @(Limit-ContractList @($Card.acceptanceCriteria) 6 160)
    currentPhase = Limit-ContractText ([string]$Card.currentPhase) 120
    currentStep = Limit-ContractText ([string]$Card.currentStep) 220
    completedSteps = @(Limit-ContractList @($Card.completedSteps) $checklistLimit 180)
    pendingSteps = @(Limit-ContractList @($Card.pendingSteps) $checklistLimit 180)
    blockers = @(Limit-ContractList @($Card.blockers) 6 180)
    evidence = @(Limit-ContractList @($Card.evidence) 8 180)
    verificationResults = @(Limit-ContractList @($Card.verificationResults) 6 180)
    topicKeys = @(Limit-TopicKeys @($Card.topicKeys))
    topicKeySource = Limit-ContractText ([string]$Card.topicKeySource) 48
    prioritySource = Limit-ContractText ([string]$Card.prioritySource) 64
    priorityReason = Limit-ContractText ([string]$Card.priorityReason) 180
  }
  if ($FingerprintVersion -in @('v2','v3')) {
    $payload.mergeCaptureRequest = if ($Card.PSObject.Properties['mergeCaptureRequest'] -and $Card.mergeCaptureRequest) { [ordered]@{
      requested = ($Card.mergeCaptureRequest.PSObject.Properties['requested'] -and $Card.mergeCaptureRequest.requested -eq $true)
      requestId = Limit-ContractText ([string]$Card.mergeCaptureRequest.requestId) 80
      sourceFocusId = Limit-ContractText ([string]$Card.mergeCaptureRequest.sourceFocusId) 120
      targetFocusId = Limit-ContractText ([string]$Card.mergeCaptureRequest.targetFocusId) 120
      targetFocusLabel = Limit-ContractText ([string]$Card.mergeCaptureRequest.targetFocusLabel) 120
      targetScope = Limit-ContractText ([string]$Card.mergeCaptureRequest.targetScope) 32
      trigger = Limit-ContractText ([string]$Card.mergeCaptureRequest.trigger) 80
      noReimplementation = ($Card.mergeCaptureRequest.PSObject.Properties['noReimplementation'] -and $Card.mergeCaptureRequest.noReimplementation -eq $true)
      artifactRefs = @(Get-MergeIntentList $Card.mergeCaptureRequest 'artifactRefs' 6 160)
      interfaceContracts = @(Get-MergeIntentList $Card.mergeCaptureRequest 'interfaceContracts' 5 160)
      dependencies = @(Get-MergeIntentList $Card.mergeCaptureRequest 'dependencies' 5 140)
      verificationSteps = @(Get-MergeIntentList $Card.mergeCaptureRequest 'verificationSteps' 6 140)
      mergeConditions = @(Get-MergeIntentList $Card.mergeCaptureRequest 'mergeConditions' 5 140)
      requestSource = Limit-ContractText ([string]$Card.mergeCaptureRequest.requestSource) 120
    } } else { $null }
  }
  if ($FingerprintVersion -in @('v3','v4','v5')) {
    $payload.checklistUpdateMode = Limit-ContractText ([string]$Card.checklistUpdateMode) 24
    $payload.lastConfirmedSentence = Limit-ContractText ([string]$Card.lastConfirmedSentence) 320
    $payload.lastConfirmedSource = Limit-ContractText ([string]$Card.lastConfirmedSource) 48
  }
  if ($FingerprintVersion -in @('v4','v5','v6')) {
    $payload.canonicalPlanId = Limit-ContractText ([string]$Card.canonicalPlanId) 80
    $payload.canonicalGeneration = if ($Card.PSObject.Properties['canonicalGeneration']) { [int]$Card.canonicalGeneration } else { 0 }
    $payload.canonicalFingerprint = Limit-ContractText ([string]$Card.canonicalFingerprint) 32
  }
  if ($FingerprintVersion -in @('v5','v6')) {
    $payload.canonicalActionFingerprint = Limit-ContractText ([string]$Card.canonicalActionFingerprint) 32
    $payload.actionBindingState = Limit-ContractText ([string]$Card.actionBindingState) 48
  }
  if ($FingerprintVersion -eq 'v6') {
    $visible = if($Card.PSObject.Properties['visibleProgressReceipt'] -and $Card.visibleProgressReceipt){$Card.visibleProgressReceipt}else{$null}
    $payload.visibleProgressReceipt = if($visible){[ordered]@{
      source = Limit-ContractText ([string]$visible.source) 48
      sentenceHash = Limit-ContractText ([string]$visible.sentenceHash) 64
      currentPhase = Limit-ContractText ([string]$visible.currentPhase) 120
      currentStep = Limit-ContractText ([string]$visible.currentStep) 220
      nextAction = Limit-ContractText ([string]$visible.nextAction) 220
      projectProgressPayloadHash = Limit-ContractText ([string]$visible.projectProgressPayloadHash) 64
      transitionId = Limit-ContractText ([string]$visible.transitionId) 120
      payloadHash = Limit-ContractText ([string]$visible.payloadHash) 64
    }}else{$null}
  }
  return Get-ContinuityFingerprint ($payload | ConvertTo-Json -Depth 8 -Compress)
}

function Protect-ReturnStackIntegrity(
  [object[]]$Items,
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue,
  [string]$ActiveFocusIdValue = '',
  [switch]$UpgradeLegacy
) {
  $raw = @($Items)
  if ($raw.Count -gt $script:ReturnStackMaxDepth) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_STACK_INVALID'; reason='return_stack_too_deep'; cards=@() }
  }
  $cards = @()
  $lineageIds = @()
  $seen = @{}
  foreach ($item in $raw) {
    $card = ConvertTo-ReturnCard $item
    if (-not $card -or [string]::IsNullOrWhiteSpace([string]$card.focusId)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_STACK_INVALID'; reason='blank_return_focus'; cards=@() }
    }
    $focusIdValue = [string]$card.focusId
    if ($seen.ContainsKey($focusIdValue) -or (-not [string]::IsNullOrWhiteSpace($ActiveFocusIdValue) -and $focusIdValue -eq $ActiveFocusIdValue)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_STACK_INVALID'; reason='duplicate_or_active_focus_in_return_stack'; cards=@() }
    }
    $seen[$focusIdValue] = $true
    $lineageIds += $focusIdValue
    $storedVersion = Limit-ContractText ([string]$card.returnCardFingerprintVersion) 16
    $hasFingerprint = -not [string]::IsNullOrWhiteSpace([string]$card.returnCardFingerprint)
    if ($hasFingerprint -and $storedVersion -notin @('v1','v2','v3','v4','v5','v6')) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_CARD_INVALID'; reason='return_card_fingerprint_version_unsupported'; focusId=$focusIdValue; cards=@() }
    }
    if ($storedVersion -eq 'v1' -and $null -ne $card.mergeCaptureRequest) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_CARD_INVALID'; reason='legacy_merge_capture_unbound'; focusId=$focusIdValue; cards=@() }
    }
    $verificationVersion = if ($hasFingerprint) { $storedVersion } else { 'v3' }
    $expected = Get-ReturnCardFingerprint $card $TaskIdValue $WorkspaceKeyValue $lineageIds $verificationVersion
    if ($hasFingerprint -and [string]$card.returnCardFingerprint -ne $expected) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RETURN_CARD_INVALID'; reason='return_card_fingerprint_mismatch'; focusId=$focusIdValue; cards=@() }
    }
    if ($UpgradeLegacy -or $hasFingerprint) {
      $persistedVersion = if ($UpgradeLegacy) { 'v6' } else { $storedVersion }
      $card.returnCardFingerprintVersion = $persistedVersion
      $card.returnCardFingerprint = Get-ReturnCardFingerprint $card $TaskIdValue $WorkspaceKeyValue $lineageIds $persistedVersion
    }
    $cards += $card
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_RETURN_STACK_OK'; reason=''; cards=@($cards) }
}

function Bind-ReturnStackCanonicalPlan(
  [object[]]$Items,
  [object]$CanonicalPlan,
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue
) {
  if (-not $CanonicalPlan) { return @(Limit-ReturnStack $Items) }
  $cards = @()
  $lineageIds = @()
  foreach ($item in @(Limit-ReturnStack $Items)) {
    $card = ConvertTo-ReturnCard $item
    $lineageIds += [string]$card.focusId
    $previousCanonicalFingerprint = [string]$card.canonicalFingerprint
    if ([string]::IsNullOrWhiteSpace([string]$card.canonicalActionFingerprint)) {
      $card.canonicalActionFingerprint = if(-not[string]::IsNullOrWhiteSpace($previousCanonicalFingerprint)){$previousCanonicalFingerprint}else{[string]$CanonicalPlan.currentFingerprint}
    }
    if ([string]::IsNullOrWhiteSpace([string]$card.actionBindingState)) { $card.actionBindingState='bound' }
    if (-not[string]::IsNullOrWhiteSpace($previousCanonicalFingerprint) -and $previousCanonicalFingerprint-ne[string]$CanonicalPlan.currentFingerprint) {
      $card.actionBindingState='stale_canonical_change'
    }
    $card.canonicalPlanId = [string]$CanonicalPlan.planId
    $card.canonicalGeneration = [int]$CanonicalPlan.generation
    $card.canonicalFingerprint = [string]$CanonicalPlan.currentFingerprint
    $card.returnCardFingerprintVersion = 'v6'
    $card.returnCardFingerprint = Get-ReturnCardFingerprint $card $TaskIdValue $WorkspaceKeyValue $lineageIds 'v6'
    $cards += $card
  }
  return @($cards)
}

function New-PlanFingerprintPayload(
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue,
  [string]$OwnerSessionKeyValue,
  [int]$RevisionValue,
  [string]$FocusIdValue,
  [string]$FocusLabelValue,
  [string]$NextActionValue,
  [string]$CurrentPhaseValue,
  [string]$CurrentStepValue,
  [object[]]$PendingStepsValue,
  [object[]]$ConstraintsValue,
  [object[]]$AcceptanceCriteriaValue,
  [object]$WorkLineStatusValue,
  [object[]]$CompletedStepsValue = @(),
  [ValidateSet('super-brain.plan-receipt.v1','super-brain.plan-receipt.v2','super-brain.plan-receipt.v3')]
  [string]$ReceiptSchema = 'super-brain.plan-receipt.v2',
  [object]$IntentBindingValue = $null
) {
  $checklistLimit = if ($ReceiptSchema -in @('super-brain.plan-receipt.v2','super-brain.plan-receipt.v3')) { $script:ActiveChecklistMaxItems } else { 8 }
  $payload = [ordered]@{
    taskId = Limit-ContractText $TaskIdValue 160
    workspaceKey = Limit-ContractText $WorkspaceKeyValue 80
    ownerSessionKey = Limit-ContractText $OwnerSessionKeyValue 64
    revision = $RevisionValue
    focusId = Limit-ContractText $FocusIdValue 120
    focusLabel = Limit-ContractText $FocusLabelValue 120
    nextAction = Limit-ContractText $NextActionValue 220
    currentPhase = Limit-ContractText $CurrentPhaseValue 120
    currentStep = Limit-ContractText $CurrentStepValue 220
    pendingSteps = @(Limit-ContractList @($PendingStepsValue) $checklistLimit 180)
    constraints = @(Limit-ContractList @($ConstraintsValue) 6 160)
    acceptanceCriteria = @(Limit-ContractList @($AcceptanceCriteriaValue) 6 160)
    lineage = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['lineage']) { @($WorkLineStatusValue.lineage | ForEach-Object { [string]$_.focusId }) } else { @($FocusIdValue) }
  }
  if ($ReceiptSchema -in @('super-brain.plan-receipt.v2','super-brain.plan-receipt.v3')) {
    $payload.completedSteps = @(Limit-ContractList @($CompletedStepsValue) $checklistLimit 180)
  }
  if ($ReceiptSchema -eq 'super-brain.plan-receipt.v3') {
    $canonicalMain = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['canonicalMain']) { $WorkLineStatusValue.canonicalMain } else { $null }
    $payload.canonicalPlanId = if ($canonicalMain) { Limit-ContractText ([string]$canonicalMain.planId) 80 } else { '' }
    $payload.canonicalGeneration = if ($canonicalMain) { [int]$canonicalMain.generation } else { 0 }
    $payload.canonicalFingerprint = if ($canonicalMain) { Limit-ContractText ([string]$canonicalMain.currentFingerprint) 32 } else { '' }
  }
  if ($IntentBindingValue) {
    $payload.intentBinding = [ordered]@{
      intentRevision = [int]$IntentBindingValue.intentRevision
      intentContractFingerprint = Limit-ContractText ([string]$IntentBindingValue.intentContractFingerprint) 64
    }
  }
  return $payload
}

function New-PlanReceipt(
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue,
  [string]$OwnerSessionKeyValue,
  [int]$RevisionValue,
  [string]$FocusIdValue,
  [string]$FocusLabelValue,
  [string]$NextActionValue,
  [string]$CurrentPhaseValue,
  [string]$CurrentStepValue,
  [object[]]$PendingStepsValue,
  [object[]]$ConstraintsValue,
  [object[]]$AcceptanceCriteriaValue,
  [object]$WorkLineStatusValue,
  [string]$LatestInstructionValue,
  [string]$SourceValue,
  [object[]]$CompletedStepsValue = @(),
  [ValidateSet('super-brain.plan-receipt.v1','super-brain.plan-receipt.v2','super-brain.plan-receipt.v3')]
  [string]$ReceiptSchema = 'super-brain.plan-receipt.v2',
  [object]$IntentBindingValue = $null
) {
  $payload = New-PlanFingerprintPayload $TaskIdValue $WorkspaceKeyValue $OwnerSessionKeyValue $RevisionValue $FocusIdValue $FocusLabelValue $NextActionValue $CurrentPhaseValue $CurrentStepValue $PendingStepsValue $ConstraintsValue $AcceptanceCriteriaValue $WorkLineStatusValue $CompletedStepsValue $ReceiptSchema $IntentBindingValue
  $receipt = [pscustomobject]@{
    schema = $ReceiptSchema
    focusId = $payload.focusId
    contractRevision = $RevisionValue
    planFingerprint = Get-ContinuityFingerprint ($payload | ConvertTo-Json -Depth 8 -Compress)
    instructionFingerprint = if ([string]::IsNullOrWhiteSpace($LatestInstructionValue)) { '' } else { Get-ContinuityFingerprint $LatestInstructionValue }
    hierarchyDepth = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['lineageDepth']) { [int]$WorkLineStatusValue.lineageDepth } else { 0 }
    parentFocusId = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['directParent'] -and $WorkLineStatusValue.directParent) { [string]$WorkLineStatusValue.directParent.focusId } else { '' }
    pendingStepCount = @($payload.pendingSteps).Count
    # The fingerprint payload is an OrderedDictionary, so inspect its keys rather than PSObject properties.
    completedStepCount = if ($payload.Contains('completedSteps')) { @($payload['completedSteps']).Count } else { 0 }
    source = Limit-ContractText $SourceValue 120
    capturedAt = (Get-SuperBrainUtcTimestamp)
    rawPlanStored = $false
  }
  if ($IntentBindingValue) {
    $receipt | Add-Member -NotePropertyName intentBinding -NotePropertyValue ([pscustomobject]@{ intentRevision=[int]$IntentBindingValue.intentRevision; intentContractFingerprint=Limit-ContractText ([string]$IntentBindingValue.intentContractFingerprint) 64 }) -Force
  }
  return $receipt
}

function Test-PlanReceiptCurrent([object]$Contract) {
  if (-not $Contract -or -not $Contract.PSObject.Properties['planReceiptRequired'] -or $Contract.planReceiptRequired -ne $true) { return $true }
  if (-not $Contract.PSObject.Properties['planReceipt'] -or -not $Contract.planReceipt) { return $false }
  $receiptSchema = [string]$Contract.planReceipt.schema
  if ($receiptSchema -notin @('super-brain.plan-receipt.v1','super-brain.plan-receipt.v2','super-brain.plan-receipt.v3')) { return $false }
  $workLineStatusValue = if ($Contract.PSObject.Properties['workLineStatus']) { $Contract.workLineStatus } else { $null }
  $intentBindingValue = $null
  if ($Contract.PSObject.Properties['intentContractRequired'] -and $Contract.intentContractRequired -eq $true) {
    if (-not $Contract.PSObject.Properties['intentRevision'] -or [int]$Contract.intentRevision -lt 1 -or -not $Contract.PSObject.Properties['intentContract'] -or [string]$Contract.intentContract.contractFingerprint -notmatch '^[a-f0-9]{64}$') { return $false }
    $intentBindingValue = [pscustomobject]@{ intentRevision=[int]$Contract.intentRevision; intentContractFingerprint=[string]$Contract.intentContract.contractFingerprint }
    if (-not $Contract.planReceipt.PSObject.Properties['intentBinding'] -or [int]$Contract.planReceipt.intentBinding.intentRevision -ne [int]$intentBindingValue.intentRevision -or [string]$Contract.planReceipt.intentBinding.intentContractFingerprint -ne [string]$intentBindingValue.intentContractFingerprint) { return $false }
    if ($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan) {
      if (-not $Contract.canonicalPlan.PSObject.Properties['intentBinding'] -or [int]$Contract.canonicalPlan.intentBinding.intentRevision -ne [int]$intentBindingValue.intentRevision -or [string]$Contract.canonicalPlan.intentBinding.intentContractFingerprint -ne [string]$intentBindingValue.intentContractFingerprint) { return $false }
    }
  } elseif ($Contract.planReceipt.PSObject.Properties['intentBinding']) { return $false }
  $payload = New-PlanFingerprintPayload ([string]$Contract.taskId) ([string]$Contract.workspaceKey) (Get-ContractSessionKey $Contract) ([int]$Contract.revision) ([string]$Contract.focusId) $(if($Contract.PSObject.Properties['focusLabel']){[string]$Contract.focusLabel}else{Get-DefaultFocusLabel ([string]$Contract.focusId)}) ([string]$Contract.nextAction) $(if($Contract.PSObject.Properties['currentPhase']){[string]$Contract.currentPhase}else{''}) $(if($Contract.PSObject.Properties['currentStep']){[string]$Contract.currentStep}else{[string]$Contract.nextAction}) $(if($Contract.PSObject.Properties['pendingSteps']){@($Contract.pendingSteps)}else{@()}) @($Contract.constraints) @($Contract.acceptanceCriteria) $workLineStatusValue $(if($Contract.PSObject.Properties['completedSteps']){@($Contract.completedSteps)}else{@()}) $receiptSchema $intentBindingValue
  $expectedPlan = Get-ContinuityFingerprint ($payload | ConvertTo-Json -Depth 8 -Compress)
  $expectedInstruction = if ([string]::IsNullOrWhiteSpace([string]$Contract.latestUserInstruction)) { '' } else { Get-ContinuityFingerprint ([string]$Contract.latestUserInstruction) }
  return (
    $receiptSchema -in @('super-brain.plan-receipt.v1','super-brain.plan-receipt.v2','super-brain.plan-receipt.v3') -and
    [int]$Contract.planReceipt.contractRevision -eq [int]$Contract.revision -and
    [string]$Contract.planReceipt.focusId -eq [string]$Contract.focusId -and
    [string]$Contract.planReceipt.planFingerprint -eq $expectedPlan -and
    [string]$Contract.planReceipt.instructionFingerprint -eq $expectedInstruction
  )
}

function Validate-PlanReceipt {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_TASK_REQUIRED'; taskId=''; workspaceKey=$WorkspaceKey } }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_WORKSPACE_REQUIRED'; taskId=$TaskId; workspaceKey='' } }
  $contract = $null
  $contractPath = ''
  if (-not [string]::IsNullOrWhiteSpace($ReceiptContractPath)) {
    try { $contractPath = [IO.Path]::GetFullPath($ReceiptContractPath) } catch { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_PATH_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey } }
    if (-not (Test-SuperBrainChildPath $contractRoot $contractPath)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_PATH_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
    $contract = Read-ContractJson $contractPath
  } else {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    $contract = $record.contract
    $contractPath = [string]$record.path
  }
  if (-not $contract) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_CONTRACT_MISSING'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
  if (-not (Test-ContractIdentity $contract $TaskId $WorkspaceKey)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_CONTRACT_IDENTITY_MISMATCH'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
  $validity = Test-ContractCurrent $contract
  if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_CONTRACT_STALE'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; reasons=@($validity.reasons) } }
  if (-not $contract.PSObject.Properties['planReceiptRequired'] -or $contract.planReceiptRequired -ne $true -or -not $contract.PSObject.Properties['planReceipt'] -or -not $contract.planReceipt) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; contractRevision=[int]$contract.revision }
  }
  if ($contract.PSObject.Properties['canonicalPlan'] -and $contract.canonicalPlan -and [string]$contract.planReceipt.schema -ne 'super-brain.plan-receipt.v3') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_RECEIPT_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; contractRevision=[int]$contract.revision }
  }
  if (-not (Test-PlanReceiptCurrent $contract)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_STALE'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; contractRevision=[int]$contract.revision }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_PLAN_RECEIPT_CURRENT'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint; contractHash=Get-SuperBrainFileSha256 $contractPath }
}

function Validate-IntentReceipt {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_TASK_REQUIRED'; taskId=''; workspaceKey=$WorkspaceKey } }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_WORKSPACE_REQUIRED'; taskId=$TaskId; workspaceKey='' } }
  $contract = $null
  $contractPath = ''
  if (-not [string]::IsNullOrWhiteSpace($ReceiptContractPath)) {
    try { $contractPath = [IO.Path]::GetFullPath($ReceiptContractPath) } catch { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_PATH_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey } }
    if (-not (Test-SuperBrainChildPath $contractRoot $contractPath)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_PATH_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
    $contract = Read-ContractJson $contractPath
  } else {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    $contract = $record.contract
    $contractPath = [string]$record.path
  }
  if (-not $contract) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CONTRACT_MISSING'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
  if (-not (Test-ContractIdentity $contract $TaskId $WorkspaceKey)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CONTRACT_IDENTITY_MISMATCH'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath } }
  $status = Get-IntentResolutionReceiptStatus $contract
  if (-not $status.required) {
    return [pscustomobject]@{ ok=$true; required=$false; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; contractHash=Get-SuperBrainFileSha256 $contractPath }
  }
  if (-not $status.current) {
    return [pscustomobject]@{ ok=$false; required=$true; current=$false; code=[string]$status.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; path=$contractPath; missing=@($status.missing); contractHash=Get-SuperBrainFileSha256 $contractPath }
  }
  return [pscustomobject]@{
    ok=$true;required=$true;current=$true;code='EXECUTION_CONTRACT_INTENT_RECEIPT_CURRENT';taskId=$TaskId;workspaceKey=$WorkspaceKey;path=$contractPath
    contractRevision=[int]$contract.revision;intentRevision=[int]$contract.intentRevision;planFingerprint=[string]$contract.planReceipt.planFingerprint
    intentContractFingerprint=[string]$status.receipt.intentContractFingerprint;intentReceiptId=[string]$status.receipt.receiptId;intentReceiptPayloadHash=[string]$status.receipt.payloadHash
    contractHash=Get-SuperBrainFileSha256 $contractPath
  }
}

function New-ContinuityStateCard(
  [string]$TaskIdValue,
  [string]$WorkspaceKeyValue,
  [string]$OwnerSessionKeyValue,
  [int]$RevisionValue,
  [string]$InstructionModeValue,
  [string]$ActiveFocusIdValue,
  [string]$ActiveFocusLabelValue,
  [object]$WorkLineStatusValue,
  [object[]]$ReturnStackValue = @(),
  [string]$CurrentPhaseValue = '',
  [string]$CurrentStepValue = '',
  [object[]]$CompletedStepsValue = @(),
  [object[]]$PendingStepsValue = @(),
  [object[]]$BlockersValue = @(),
  [object[]]$EvidenceValue = @(),
  [object[]]$VerificationResultsValue = @(),
  [string]$NextActionValue = '',
  [string]$AssistantCommitmentValue = '',
  [object[]]$ConstraintsValue = @(),
  [object[]]$AcceptanceCriteriaValue = @(),
  [string]$SourceValue = 'execution-contract.ps1',
  [string]$ChecklistUpdateModeValue = 'additive',
  [string]$LastConfirmedSentenceValue = '',
  [string]$LastConfirmedSourceValue = '',
  [object]$CanonicalPlanValue = $null,
  [object[]]$ActiveWorkPackageCompletedStepsValue = @(),
  [object[]]$ActiveWorkPackagePendingStepsValue = @(),
  [object]$ProjectProgressProofValue = $null
) {
  $returnCards = @(Limit-ReturnStack @($ReturnStackValue) 4)
  $mainLineId = if ($WorkLineStatusValue) { [string]$WorkLineStatusValue.mainLine } else { '' }
  $activeLineId = if ($WorkLineStatusValue) { [string]$WorkLineStatusValue.activeLine } else { $ActiveFocusIdValue }
  if ([string]::IsNullOrWhiteSpace($activeLineId)) { $activeLineId = $ActiveFocusIdValue }
  $parentLineId = if ($returnCards.Count -gt 0) { [string]$returnCards[-1].focusId } else { '' }
  $lineRole = if ($returnCards.Count -gt 0) { 'side_branch' } else { 'main_line' }
  $phase = if (-not [string]::IsNullOrWhiteSpace($CurrentPhaseValue)) { Limit-ContractText $CurrentPhaseValue 120 } else { Limit-ContractText $InstructionModeValue 120 }
  $currentStep = if (-not [string]::IsNullOrWhiteSpace($CurrentStepValue)) { Limit-ContractText $CurrentStepValue 220 } else { Limit-ContractText $NextActionValue 220 }
  $completedSteps = @(Limit-ContractList @($CompletedStepsValue) $script:ActiveChecklistMaxItems 180)
  $pendingSteps = @(Limit-ContractList @($PendingStepsValue) $script:ActiveChecklistMaxItems 180)
  $explicitNoAutomaticAction = -not [string]::IsNullOrWhiteSpace($NextActionValue) -and ([string]$NextActionValue).Trim().StartsWith('No automatic action:', [StringComparison]::OrdinalIgnoreCase)
  if ($pendingSteps.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentStep) -and -not $explicitNoAutomaticAction) { $pendingSteps = @($currentStep) }
  $blockers = @(Limit-ContractList @($BlockersValue) 6 180)
  $evidence = @(Limit-ContractList @($EvidenceValue) 8 180)
  $verificationResults = @(Limit-ContractList @($VerificationResultsValue) 6 180)
  $projectProgress = Test-ProjectProgressProof $ProjectProgressProofValue $phase $currentStep $completedSteps (Limit-ContractText $NextActionValue 220)
  $projectProgressProjection = [pscustomobject]@{
    state = if($projectProgress.current){'current'}else{'withheld'}
    payloadHash = if($projectProgress.proof){[string]$projectProgress.proof.payloadHash}else{''}
    projectRootHash = if($projectProgress.proof){[string]$projectProgress.proof.projectRootHash}else{''}
    completedItemCount = if($projectProgress.proof){@($projectProgress.proof.completedItems).Count}else{0}
    evidenceCount = if($projectProgress.proof){@($projectProgress.proof.projectEvidence).Count}else{0}
    verificationCount = if($projectProgress.proof){@($projectProgress.proof.verificationResults).Count}else{0}
    missing = @($projectProgress.missing | Select-Object -First 8)
  }
  $activeChecklist = @()
  $ordinal = 1
  foreach ($step in @($completedSteps)) { $activeChecklist += [pscustomobject]@{ ordinal=$ordinal; status='completed'; label=$step }; $ordinal++ }
  foreach ($step in @($pendingSteps)) { $activeChecklist += [pscustomobject]@{ ordinal=$ordinal; status='pending'; label=$step }; $ordinal++ }
  $workPackageCompletedSteps = @($completedSteps)
  $workPackagePendingSteps = @($pendingSteps)
  $activeWorkPackageChecklist = @($activeChecklist)
  if ($CanonicalPlanValue) {
    $canonicalProjection = Get-CanonicalPlanProjection $CanonicalPlanValue
    $completedSteps = @($canonicalProjection.completedSteps)
    $pendingSteps = @($canonicalProjection.pendingSteps)
    $activeChecklist = @($canonicalProjection.activeChecklist)
    $canonicalMainActive = ($parentLineId -eq '' -and [string]$ActiveFocusIdValue -eq [string]$CanonicalPlanValue.rootFocusId)
    if ($canonicalMainActive) {
      $workPackageCompletedSteps = @($canonicalProjection.completedSteps)
      $workPackagePendingSteps = @($canonicalProjection.pendingSteps)
      $activeWorkPackageChecklist = @($canonicalProjection.activeChecklist)
    } else {
      $workPackageCompletedSteps = @(Limit-ContractList @($ActiveWorkPackageCompletedStepsValue) $script:ActiveChecklistMaxItems 180)
      $workPackagePendingSteps = @(Limit-ContractList @($ActiveWorkPackagePendingStepsValue) $script:ActiveChecklistMaxItems 180)
      $activeWorkPackageChecklist = @()
      $workOrdinal = 1
      foreach ($step in @($workPackageCompletedSteps)) { $activeWorkPackageChecklist += [pscustomobject]@{ ordinal=$workOrdinal; status='completed'; label=$step }; $workOrdinal++ }
      foreach ($step in @($workPackagePendingSteps)) { $activeWorkPackageChecklist += [pscustomobject]@{ ordinal=$workOrdinal; status='pending'; label=$step }; $workOrdinal++ }
    }
  }
  $priorityOrder = @()
  if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['priorityOrder']) {
    $priorityOrder = @($WorkLineStatusValue.priorityOrder | Select-Object -First 6 | ForEach-Object {
      [pscustomobject]@{
        executionRank = [int]$_.executionRank
        focusId = Limit-ContractText ([string]$_.focusId) 120
        focusLabel = Limit-ContractText ([string]$_.focusLabel) 100
        role = Limit-ContractText ([string]$_.role) 48
        source = Limit-ContractText ([string]$_.source) 64
      }
    })
  }
  $returnCardsForCard = @($returnCards | ForEach-Object {
    [pscustomobject]@{
      focusId = Limit-ContractText ([string]$_.focusId) 120
      focusLabel = Limit-ContractText ([string]$_.focusLabel) 100
      currentPhase = Limit-ContractText ([string]$_.currentPhase) 120
      currentStep = Limit-ContractText ([string]$_.currentStep) 180
      nextAction = Limit-ContractText ([string]$_.nextAction) 180
      completedSteps = @(Limit-ContractList @($_.completedSteps) 4 140)
      pendingSteps = @(Limit-ContractList @($_.pendingSteps) 4 140)
      blockers = @(Limit-ContractList @($_.blockers) 3 140)
      evidence = @(Limit-ContractList @($_.evidence) 4 140)
      verificationResults = @(Limit-ContractList @($_.verificationResults) 3 140)
      capturedAt = Limit-ContractText ([string]$_.capturedAt) 48
    }
  })
  $lineageForCard = @()
  if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['lineage']) {
    $lineageForCard = @($WorkLineStatusValue.lineage | Select-Object -First 5 | ForEach-Object {
      [pscustomobject]@{
        depth = [int]$_.depth
        focusId = Limit-ContractText ([string]$_.focusId) 120
        focusLabel = Limit-ContractText ([string]$_.focusLabel) 100
        parentFocusId = Limit-ContractText ([string]$_.parentFocusId) 120
        childFocusId = Limit-ContractText ([string]$_.childFocusId) 120
        role = Limit-ContractText ([string]$_.role) 48
        status = Limit-ContractText ([string]$_.status) 32
        nextAction = Limit-ContractText ([string]$_.nextAction) 180
      }
    })
  }
  $card = [ordered]@{
    schema = 'super-brain.task-state-card.v1'
    taskId = Limit-ContractText $TaskIdValue 160
    workspaceKey = Limit-ContractText (Get-SuperBrainWorkspaceKey $WorkspaceKeyValue) 64
    ownerSessionKey = Limit-ContractText $OwnerSessionKeyValue 160
    revision = $RevisionValue
    mainLineId = Limit-ContractText $mainLineId 120
    activeLineId = Limit-ContractText $activeLineId 120
    activeLineLabel = Limit-ContractText $ActiveFocusLabelValue 120
    parentLineId = Limit-ContractText $parentLineId 120
    lineRole = $lineRole
    instructionMode = Limit-ContractText $InstructionModeValue 48
    phase = $phase
    currentStep = $currentStep
    completedSteps = @($completedSteps)
    pendingSteps = @($pendingSteps)
    activeChecklist = @($activeChecklist)
    activeChecklistCount = @($activeChecklist).Count
    canonicalPlanId = if ($CanonicalPlanValue) { [string]$CanonicalPlanValue.planId } else { '' }
    canonicalGeneration = if ($CanonicalPlanValue) { [int]$CanonicalPlanValue.generation } else { 0 }
    canonicalFingerprint = if ($CanonicalPlanValue) { [string]$CanonicalPlanValue.currentFingerprint } else { '' }
    activeWorkPackageCompletedSteps = @($workPackageCompletedSteps)
    activeWorkPackagePendingSteps = @($workPackagePendingSteps)
    activeWorkPackageChecklist = @($activeWorkPackageChecklist)
    activeWorkPackageChecklistCount = @($activeWorkPackageChecklist).Count
    checklistUpdateMode = Limit-ContractText $ChecklistUpdateModeValue 24
    blockers = @($blockers)
    evidence = @($evidence)
    verificationResults = @($verificationResults)
    projectProgress = $projectProgressProjection
    nextAction = Limit-ContractText $NextActionValue 220
    assistantCommitment = Limit-ContractText $AssistantCommitmentValue 260
    lastConfirmedSentence = Limit-ContractText $LastConfirmedSentenceValue 320
    lastConfirmedSource = Limit-ContractText $LastConfirmedSourceValue 48
    constraints = @(Limit-ContractList @($ConstraintsValue) 6 160)
    acceptanceCriteria = @(Limit-ContractList @($AcceptanceCriteriaValue) 6 160)
    priorityOrder = @($priorityOrder)
    currentLineCount = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['currentLineCount']) { [int]$WorkLineStatusValue.currentLineCount } else { 1 }
    lineageLineCount = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['lineageLineCount']) { [int]$WorkLineStatusValue.lineageLineCount } else { 1 }
    unfinishedLineCount = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['unfinishedLineCount']) { [int]$WorkLineStatusValue.unfinishedLineCount } else { 0 }
    lineageDepth = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['lineageDepth']) { [int]$WorkLineStatusValue.lineageDepth } else { 0 }
    lineage = @($lineageForCard)
    suspendedLineIds = @($(if ($WorkLineStatusValue) { @(Limit-WorkLineIds @($WorkLineStatusValue.suspendedLines) 4) } else { @() }))
    unfinishedLineIds = @($(if ($WorkLineStatusValue) { @(Limit-WorkLineIds @($WorkLineStatusValue.unfinishedLines) 6) } else { @() }))
    returnStack = @($returnCardsForCard)
    latestMessageClassification = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['latestMessageClassification']) { $WorkLineStatusValue.latestMessageClassification } else { $null }
    source = Limit-ContractText $SourceValue 120
    capturedAt = (Get-SuperBrainUtcTimestamp)
  }
  $fingerprintInput = [ordered]@{
    taskId = $card.taskId
    workspaceKey = $card.workspaceKey
    revision = $card.revision
    mainLineId = $card.mainLineId
    activeLineId = $card.activeLineId
    parentLineId = $card.parentLineId
    phase = $card.phase
    currentStep = $card.currentStep
    nextAction = $card.nextAction
    completedSteps = $card.completedSteps
    pendingSteps = $card.pendingSteps
    canonicalPlanId = $card.canonicalPlanId
    canonicalGeneration = $card.canonicalGeneration
    canonicalFingerprint = $card.canonicalFingerprint
    activeWorkPackageCompletedSteps = $card.activeWorkPackageCompletedSteps
    activeWorkPackagePendingSteps = $card.activeWorkPackagePendingSteps
    checklistUpdateMode = $card.checklistUpdateMode
    evidence = $card.evidence
    verificationResults = $card.verificationResults
    projectProgressHash = [string]$card.projectProgress.payloadHash
    projectProgressState = [string]$card.projectProgress.state
    lastConfirmedSentence = $card.lastConfirmedSentence
    lastConfirmedSource = $card.lastConfirmedSource
    suspendedLineIds = $card.suspendedLineIds
    unfinishedLineIds = $card.unfinishedLineIds
  }
  $card.stateFingerprint = Get-ContinuityFingerprint (($fingerprintInput | ConvertTo-Json -Depth 8 -Compress))
  return [pscustomobject]$card
}

function Get-SafeTaskId([string]$Value) {
  $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ($safe.Length -gt 120) { $safe = $safe.Substring(0,120) }
  return $safe
}

function Get-TaskIdHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Value))[0..7] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-ExecutionSessionKey([string]$Value) {
  return Get-SuperBrainHostSessionKey $Value
}

function Get-ContractSessionKey($Contract) {
  if ($Contract -and $Contract.PSObject.Properties['ownerSessionKey']) { return [string]$Contract.ownerSessionKey }
  return ''
}

function Test-ContractSessionKey($Contract,[string]$Key) {
  $owner = Get-ContractSessionKey $Contract
  if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($Key)) { return $false }
  return [string]::Equals($owner,$Key,[StringComparison]::OrdinalIgnoreCase)
}

function Get-ContractSessionMutationBlock($Contract,[string]$Operation) {
  if (-not $Contract) { return $null }
  $owner = Get-ContractSessionKey $Contract
  if ([string]::IsNullOrWhiteSpace($owner)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_UNBOUND'; taskId=$TaskId; workspaceKey=$WorkspaceKey; operation=$Operation; requestedSessionKey=$SessionKey; guard='This legacy contract has no root-session owner. Explicitly bind or rebind it before mutation.' }
  }
  if ([string]::IsNullOrWhiteSpace($SessionKey)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; operation=$Operation; guard='This mutation requires the owning root Codex session identity.' }
  }
  if (-not (Test-ContractSessionKey $Contract $SessionKey)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; operation=$Operation; ownerSessionKey=$owner; requestedSessionKey=$SessionKey; guard='A different root Codex session owns this contract. Explicitly rebind it through Set before mutation.' }
  }
  return $null
}

function Get-ContractSessionReadState($Contract) {
  if (-not $Contract) { return [pscustomobject]@{ authorized=$false; state='missing'; ownerSessionKey=''; requestedSessionKey=$SessionKey } }
  $owner = Get-ContractSessionKey $Contract
  if ([string]::IsNullOrWhiteSpace($owner)) {
    return [pscustomobject]@{ authorized=$false; state='unbound'; ownerSessionKey=''; requestedSessionKey=$SessionKey }
  }
  if ([string]::IsNullOrWhiteSpace($SessionKey)) { return [pscustomobject]@{ authorized=$false; state='session_required'; ownerSessionKey=$owner; requestedSessionKey='' } }
  if (Test-ContractSessionKey $Contract $SessionKey) { return [pscustomobject]@{ authorized=$true; state='matched'; ownerSessionKey=$owner; requestedSessionKey=$SessionKey } }
  return [pscustomobject]@{ authorized=$false; state='foreign'; ownerSessionKey=$owner; requestedSessionKey=$SessionKey }
}

function Get-ContractForSession {
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  if (-not $contract) { return $null }
  $readState = Get-ContractSessionReadState $contract
  if ($readState.authorized -eq $true) {
    # Prompt observation stores the newest instruction in the append-only
    # anchor control plane. Raw reads must surface that pending anchor too, or
    # a caller can mistakenly present the older contract as current.
    try {
      $anchorStatus = Get-ContractInstructionAnchorStatus $contract $TaskId $WorkspaceKey (Get-ContractSessionKey $contract)
      $anchorPending = (-not $anchorStatus.ok -or ($anchorStatus.required -and -not $anchorStatus.current))
      if ($anchorPending) {
        $view = $contract | Select-Object *
        if ($anchorStatus.anchor) {
          $view | Add-Member -NotePropertyName instructionAnchor -NotePropertyValue $anchorStatus.anchor -Force
          $anchorInstruction = [string]$anchorStatus.anchor.instruction
          if (-not [string]::IsNullOrWhiteSpace($anchorInstruction)) {
            $view | Add-Member -NotePropertyName latestUserInstruction -NotePropertyValue $anchorInstruction -Force
          }
          # Anchor storage intentionally keeps only a narrow classification
          # shape. Rebuild the executable view from the locked contract so a
          # retained merge line still carries merge_review and its intent id.
          $anchorClassification = if($anchorStatus.anchor.PSObject.Properties['classification']){$anchorStatus.anchor.classification}else{$null}
          $anchorMode = if($anchorClassification -and $anchorClassification.PSObject.Properties['mode']){[string]$anchorClassification.mode}else{''}
          $projectionClassification = $null
          # Action preflight is an intentionally narrow route decision. It
          # must not be reclassified as ordinary prose just because the raw
          # contract reader is enriching a pending anchor projection.
          if ($anchorMode -eq 'action_preflight') {
            $projectionClassification = $anchorClassification
          } elseif (-not [string]::IsNullOrWhiteSpace($anchorInstruction)) {
            try {
              $projectionClassification = Get-TopicClassification $anchorInstruction ([string]$contract.focusId) $(if($contract.PSObject.Properties['focusLabel']){[string]$contract.focusLabel}else{''}) $(if($contract.PSObject.Properties['topicKeys']){@($contract.topicKeys)}else{@()}) $(if($contract.PSObject.Properties['topicKeySource']){[string]$contract.topicKeySource}else{'focus_id_derived'}) $(if($contract.PSObject.Properties['returnStack']){@($contract.returnStack)}else{@()}) $(if($contract.PSObject.Properties['unfinishedWorkPlans']){@($contract.unfinishedWorkPlans)}else{@()}) $(if($contract.PSObject.Properties['currentStep']){[string]$contract.currentStep}else{''}) $(if($contract.PSObject.Properties['nextAction']){[string]$contract.nextAction}else{''}) $(if($contract.PSObject.Properties['assistantCommitment']){[string]$contract.assistantCommitment}else{''}) $(if($contract.PSObject.Properties['mergeIntents']){@($contract.mergeIntents)}else{@()})
            } catch {}
          }
          if ($projectionClassification) {
            $view | Add-Member -NotePropertyName latestMessageClassification -NotePropertyValue $projectionClassification -Force
          } elseif ($anchorClassification) {
            $view | Add-Member -NotePropertyName latestMessageClassification -NotePropertyValue $anchorClassification -Force
          }
        }
        $view | Add-Member -NotePropertyName needsReconciliation -NotePropertyValue $true -Force
        $view | Add-Member -NotePropertyName observationProjection -NotePropertyValue 'instruction_anchor_pending' -Force
        return $view
      }
    } catch {
      $view = $contract | Select-Object *
      $view | Add-Member -NotePropertyName needsReconciliation -NotePropertyValue $true -Force
      $view | Add-Member -NotePropertyName observationProjection -NotePropertyValue 'instruction_anchor_status_unavailable' -Force
      return $view
    }
    return $contract
  }
  $code = if ($readState.state -eq 'foreign') { 'EXECUTION_CONTRACT_FOREIGN_SESSION' } elseif ($readState.state -eq 'unbound') { 'EXECUTION_CONTRACT_SESSION_UNBOUND' } else { 'EXECUTION_CONTRACT_SESSION_REQUIRED' }
  return [pscustomobject]@{ ok=$false; code=$code; taskId=$TaskId; workspaceKey=$WorkspaceKey; sessionAccess=$readState.state; guard='Raw contract reads require the owning root Codex session. Use Resolve for a non-executable projection or explicitly rebind after continuity recovery.' }
}

function New-SessionIsolationClassification([string]$State) {
  return [pscustomobject]@{
    mode='session_isolation'; topicAffinity='unknown'; targetLineId=''; targetLineLabel=''; confidence='none'; matchedKeys=@(); candidateLineIds=@(); needsClarification=$true; recommendedInstructionMode='classify'; reason=('execution contract session access is ' + $State); rawInstructionStored=$false
  }
}

function Get-LegacyContractPath([string]$Id) {
  $safe = Get-SafeTaskId $Id
  if ([string]::IsNullOrWhiteSpace($safe)) { return '' }
  if ($Id.Length -gt 120 -or $Id -notmatch '^[A-Za-z0-9._-]+$') {
    if ($safe.Length -gt 96) { $safe = $safe.Substring(0,96).TrimEnd('-') }
    $safe = $safe + '-' + (Get-TaskIdHash $Id)
  }
  return Join-Path $contractRoot ($safe + '.json')
}

function Get-ContractPath([string]$Id,[string]$Key=$WorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Key)) { return '' }
  $safe = Get-SafeTaskId $Id
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'task' }
  # Keep the readable slug short enough for Windows PowerShell/Pester temp roots;
  # the task hash preserves identity even when the slug is truncated.
  if ($safe.Length -gt 36) { $safe = $safe.Substring(0,36).TrimEnd('-') }
  $taskStem = $safe + '-' + (Get-TaskIdHash $Id)
  $normalizedWorkspaceKey = Get-SuperBrainWorkspaceKey $Key
  return Join-Path $contractRoot ($taskStem + '--' + $normalizedWorkspaceKey + '.json')
}

function Read-ContractJson([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Test-ContractIdentity($Contract,[string]$Id,[string]$Key) {
  if (-not $Contract -or [string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Key)) { return $false }
  if (-not $Contract.PSObject.Properties['taskId'] -or -not $Contract.PSObject.Properties['workspaceKey']) { return $false }
  if (-not [string]::Equals([string]$Contract.taskId,$Id,[StringComparison]::Ordinal)) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$Contract.workspaceKey)) { return $false }
  return Test-SuperBrainWorkspaceKey ([string]$Contract.workspaceKey) $Key
}

function Get-BoundContractRecord([string]$Id,[string]$Key) {
  $path = Get-ContractPath $Id $Key
  $contract = Read-ContractJson $path
  if ($contract) {
    return [pscustomobject]@{ contract=if(Test-ContractIdentity $contract $Id $Key){$contract}else{$null}; path=$path; source='scoped'; identityConflict=(-not (Test-ContractIdentity $contract $Id $Key)) }
  }
  $legacyPath = Get-LegacyContractPath $Id
  $legacy = Read-ContractJson $legacyPath
  if ($legacy -and (Test-ContractIdentity $legacy $Id $Key)) {
    return [pscustomobject]@{ contract=$legacy; path=$legacyPath; source='legacy_task_only'; identityConflict=$false }
  }
  return [pscustomobject]@{ contract=$null; path=$path; source='none'; identityConflict=$false }
}

function Read-BoundContract([string]$Id,[string]$Key) {
  return (Get-BoundContractRecord $Id $Key).contract
}

function Remove-MatchingLegacyContract([string]$Id,[string]$Key) {
  $legacyPath = Get-LegacyContractPath $Id
  if ([string]::IsNullOrWhiteSpace($legacyPath) -or -not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return }
  Invoke-SuperBrainFileLock $legacyPath {
    $legacy = Read-ContractJson $legacyPath
    if ($legacy -and (Test-ContractIdentity $legacy $Id $Key)) { Remove-Item -LiteralPath $legacyPath -Force }
  } | Out-Null
}

function Get-CurrentContext {
  return Get-SuperBrainCurrentTaskContext $workspace $WorkspaceKey
}

function Find-WorkspaceContracts([string]$Key) {
  $candidates = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $item = Read-ContractJson $file.FullName
    if ($item) { $candidates += $item }
  }
  $ranked = @($candidates | Where-Object {
    $ownerSessionKey = Get-ContractSessionKey $_
    [string]$_.status -eq 'active' -and
    [string]$_.packageVersion -eq [string]$manifest.version -and
    (Test-SuperBrainWorkspaceKey ([string]$_.workspaceKey) $Key) -and
    ([string]::IsNullOrWhiteSpace($SessionKey) -or (-not [string]::IsNullOrWhiteSpace($ownerSessionKey) -and [string]::Equals($ownerSessionKey,$SessionKey,[StringComparison]::OrdinalIgnoreCase)))
  } | Sort-Object @{Expression={try{[datetime]::Parse([string]$_.updatedAt)}catch{[datetime]::MinValue}};Descending=$true})
  $result = @()
  foreach ($candidate in $ranked) {
    if (@($result | Where-Object { [string]::Equals([string]$_.taskId,[string]$candidate.taskId,[StringComparison]::Ordinal) }).Count -eq 0) { $result += $candidate }
  }
  return @($result)
}

function Resolve-Identity {
  $script:SessionKey = Get-ExecutionSessionKey $SessionKey
  $context = Get-CurrentContext
  $script:WorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($TaskId) -and $context -and [string]$context.status -eq 'active' -and (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) $WorkspaceKey)) {
    $contextTaskId = [string]$context.taskId
    $contextContract = Read-BoundContract $contextTaskId $WorkspaceKey
    $contextSessionRead = Get-ContractSessionReadState $contextContract
    if ($contextSessionRead.authorized -eq $true) {
      $script:TaskId = $contextTaskId
    } elseif ($contextContract) {
      $script:ForeignContextTaskId = $contextTaskId
      $script:ForeignContextSessionState = [string]$contextSessionRead.state
    }
  }
  if ([string]::IsNullOrWhiteSpace($TaskId) -and -not [string]::IsNullOrWhiteSpace($SessionKey)) {
    $hotIndex = Read-SuperBrainRuntimeWakeIndex $memoryBase $SessionKey $WorkspaceKey
    $hotEntries = @(
      if ($hotIndex) {
        @($hotIndex.entries | Where-Object {
          [string]$_.status -eq 'active' -and
          [string]$_.packageVersion -eq [string]$manifest.version -and
          (Test-SuperBrainWorkspaceKey ([string]$_.workspaceKey) $WorkspaceKey) -and
          [string]::Equals([string]$_.ownerSessionKey,$SessionKey,[StringComparison]::OrdinalIgnoreCase)
        })
      }
    )
    if ($hotEntries.Count -eq 1) {
      $hotTaskId = [string]$hotEntries[0].taskId
      $hotContract = Read-BoundContract $hotTaskId $WorkspaceKey
      $hotSessionRead = Get-ContractSessionReadState $hotContract
      if ($hotSessionRead.authorized -eq $true) { $script:TaskId = $hotTaskId }
    } elseif ($hotEntries.Count -gt 1) {
      $script:AmbiguousTaskIds = @($hotEntries | ForEach-Object { [string]$_.taskId } | Select-Object -Unique)
    }
  }
  if ([string]::IsNullOrWhiteSpace($TaskId) -and @($script:AmbiguousTaskIds).Count -eq 0) {
    $matches = @(Find-WorkspaceContracts $WorkspaceKey)
    if ($matches.Count -eq 1) { $script:TaskId = [string]$matches[0].taskId }
    elseif ($matches.Count -gt 1) { $script:AmbiguousTaskIds = @($matches | ForEach-Object { [string]$_.taskId }) }
  }
}

function Write-AtomicJsonUnlocked([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = Join-Path $dir ('.execution-contract-' + [guid]::NewGuid().ToString('n') + '.tmp')
  try {
    [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-ContractProjectionChild([string]$ScriptPath,[hashtable]$ChildParameters) {
  $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $memoryBase
    $ChildParameters['NoExit'] = $true
    $raw = @(& $ScriptPath @ChildParameters 2>&1)
  } finally {
    if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
  }
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  $value = $null
  try { if (-not [string]::IsNullOrWhiteSpace($text)) { $value = $text | ConvertFrom-Json } } catch {}
  $ok = ($value -and $value.ok -eq $true)
  return [pscustomobject]@{ ok=$ok; code=if($ok){'EXECUTION_CONTRACT_CHILD_OK'}else{'EXECUTION_CONTRACT_CHILD_FAILED'}; exitCode=if($ok){0}else{1}; value=$value }
}

function Invoke-ContractTaskStateStore([hashtable]$ChildParameters) {
  $storeScript = Join-Path $PSScriptRoot 'task-state-store.ps1'
  $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $memoryBase
    $ChildParameters['Json'] = $true
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$storeScript)
    foreach ($key in @($ChildParameters.Keys | Sort-Object)) {
      $value = $ChildParameters[$key]
      if ($value -is [bool]) {
        if ($value) { $arguments += ('-' + $key) }
        continue
      }
      if ($null -eq $value) { continue }
      $arguments += ('-' + $key)
      $arguments += [string]$value
    }
    $raw = @(& powershell.exe @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
  }
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  $value = $null
  try { if (-not [string]::IsNullOrWhiteSpace($text)) { $value = $text | ConvertFrom-Json } } catch {}
  $hasOk = ($value -and $value.PSObject.Properties['ok'])
  $ok = ($exitCode -eq 0 -and $value -and ((-not $hasOk) -or $value.ok -eq $true))
  return [pscustomobject]@{ ok=$ok; exitCode=$exitCode; value=$value; text=$text; code=if($ok){'TASK_STATE_STORE_OK'}else{'TASK_STATE_STORE_FAILED'} }
}

function Get-ContractContinuityStagingRoot([string]$Id) {
  $path = Join-Path (Join-Path $workspace 'task-state-store\staging') (Get-SuperBrainCanonicalTaskToken $Id)
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  return $path
}

function Write-ContractContinuityStagingValue([string]$Id,[string]$Name,[object]$Value) {
  $safe = (($Name -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'value' }
  if ($safe.Length -gt 14) { $safe = $safe.Substring(0,14).TrimEnd('-') }
  $path = Join-Path (Get-ContractContinuityStagingRoot $Id) (([guid]::NewGuid().ToString('n').Substring(0,12)) + '-' + $safe + '.json')
  Write-AtomicJsonUnlocked $path $Value
  return $path
}

function New-ContractContinuityCommand([string]$Role,[string]$Operation,[string]$TargetPath,[string]$PayloadPath,[string]$ExpectedHash,[string]$Id,[string]$Key,[bool]$ApplyWhenMissing=$false) {
  return [pscustomobject]@{
    role=$Role; operation=$Operation; targetPath=[IO.Path]::GetFullPath($TargetPath); payloadPath=[IO.Path]::GetFullPath($PayloadPath)
    payloadHash=(Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA256).Hash; expectedTargetHash=$ExpectedHash
    expectedTaskId=$Id; expectedWorkspaceKey=$Key; applyWhenMissing=$ApplyWhenMissing
  }
}

function Get-ContractContinuityPointerExpectedHash([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-ContractContinuityValue([object]$Value) {
  if (-not $Value) { return $null }
  return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Get-ContractContinuityActiveEntity(
  [object]$Projection,
  [string]$Kind,
  [string]$Id,
  [string]$WorkspaceKey
) {
  if (-not $Projection -or -not $Projection.entities -or -not $Projection.entities.PSObject.Properties[$Kind]) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_MISSING'; kind=$Kind }
  }
  $entity = $Projection.entities.$Kind
  if (-not $entity -or [string]$entity.status -notin @('active','running','in_progress')) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_NOT_ACTIVE'; kind=$Kind }
  }
  if ([string]::IsNullOrWhiteSpace([string]$entity.path) -or [string]::IsNullOrWhiteSpace([string]$entity.hash)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_BINDING_MISSING'; kind=$Kind }
  }
  $path = [IO.Path]::GetFullPath([string]$entity.path)
  $expectedPath = if ($Kind -eq 'checkpoint') {
    Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $Id '.json'
  } else {
    Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $memoryBase 'shared\tasks') 'active') $Id '.task.json'
  }
  if (-not [string]::Equals($path,[IO.Path]::GetFullPath($expectedPath),[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_PATH_INVALID'; kind=$Kind; path=$path; expectedPath=$expectedPath }
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not [string]::Equals((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash,[string]$entity.hash,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_HASH_STALE'; kind=$Kind; path=$path }
  }
  $value = Read-ContractJson $path
  if (-not $value -or [string]$value.taskId -ne $Id -or -not (Test-SuperBrainWorkspaceKey ([string]$value.workspaceKey) $WorkspaceKey) -or [string]$value.status -notin @('active','running','in_progress')) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_IDENTITY_MISMATCH'; kind=$Kind; path=$path }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CONTINUITY_ENTITY_CURRENT'; kind=$Kind; path=$path; hash=[string]$entity.hash; value=$value; entity=$entity }
}

function New-ContractContinuityStateProjection(
  [object]$Existing,
  [object]$Contract,
  [int]$TaskStateRevision,
  [string]$ContractHash,
  [string]$Kind,
  [string]$Mutation,
  [switch]$SessionRebind
) {
  $copy = Copy-ContractContinuityValue $Existing
  if (-not $copy) { throw "EXECUTION_CONTRACT_CONTINUITY_${Kind}_VALUE_REQUIRED" }
  $canonicalPlan = if ($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan) { $Contract.canonicalPlan } else { $null }
  $decisionBinding = if ($Contract.PSObject.Properties['decisionBinding'] -and $Contract.decisionBinding) { $Contract.decisionBinding } else { $null }
  $timestamp = (Get-SuperBrainUtcTimestamp)
  $completedSteps = @(Limit-ContractList @($Contract.completedSteps) $script:ActiveChecklistMaxItems 180)
  $pendingSteps = @(Limit-ContractList @($Contract.pendingSteps) $script:ActiveChecklistMaxItems 180)
  $blockers = @(Limit-ContractList @($Contract.blockers) 8 180)
  $evidence = @(Limit-ContractList @($Contract.evidence) 8 180)
  $verificationResults = @(Limit-ContractList @($Contract.verificationResults) 8 180)
  $stageKind = if ($Contract.PSObject.Properties['stageKind']) { [string]$Contract.stageKind } else { '' }
  $decisionStatus = if ($decisionBinding) { [string]$decisionBinding.status } else { '' }
  $decisionDigest = if ($decisionBinding) { [string]$decisionBinding.bindingDigest } else { '' }
  $canonicalPlanId = if ($canonicalPlan) { [string]$canonicalPlan.planId } else { '' }
  $canonicalGeneration = if ($canonicalPlan) { [int]$canonicalPlan.generation } else { 0 }
  $canonicalFingerprint = if ($canonicalPlan) { [string]$canonicalPlan.currentFingerprint } else { '' }
  foreach ($entry in @(
    [pscustomobject]@{ name='taskId'; value=[string]$Contract.taskId },
    [pscustomobject]@{ name='workspaceKey'; value=[string]$Contract.workspaceKey },
    [pscustomobject]@{ name='status'; value='active' },
    [pscustomobject]@{ name='currentPhase'; value=(Limit-ContractText ([string]$Contract.currentPhase) 120) },
    [pscustomobject]@{ name='currentStep'; value=(Limit-ContractText ([string]$Contract.currentStep) 220) },
    [pscustomobject]@{ name='nextAction'; value=(Limit-ContractText ([string]$Contract.nextAction) 220) },
    [pscustomobject]@{ name='completedSteps'; value=@($completedSteps) },
    [pscustomobject]@{ name='pendingSteps'; value=@($pendingSteps) },
    [pscustomobject]@{ name='blockers'; value=@($blockers) },
    [pscustomobject]@{ name='evidence'; value=@($evidence) },
    [pscustomobject]@{ name='verificationResults'; value=@($verificationResults) },
    [pscustomobject]@{ name='taskStateRevision'; value=$TaskStateRevision },
    [pscustomobject]@{ name='contractRevision'; value=[int]$Contract.revision },
    [pscustomobject]@{ name='planFingerprint'; value=[string]$Contract.planReceipt.planFingerprint },
    [pscustomobject]@{ name='taskInstanceId'; value=[string]$Contract.taskInstanceId },
    [pscustomobject]@{ name='ownerSessionKey'; value=[string]$Contract.ownerSessionKey },
    [pscustomobject]@{ name='continuityContractHash'; value=$ContractHash },
    [pscustomobject]@{ name='continuityTransactionKind'; value='contract_continuity' },
    [pscustomobject]@{ name='stageKind'; value=$stageKind },
    [pscustomobject]@{ name='decisionBindingStatus'; value=$decisionStatus },
    [pscustomobject]@{ name='decisionBindingDigest'; value=$decisionDigest },
    [pscustomobject]@{ name='canonicalPlanId'; value=$canonicalPlanId },
    [pscustomobject]@{ name='canonicalGeneration'; value=$canonicalGeneration },
    [pscustomobject]@{ name='canonicalFingerprint'; value=$canonicalFingerprint },
    [pscustomobject]@{ name='updatedAt'; value=$timestamp },
    [pscustomobject]@{ name='source'; value=('execution-contract.ps1:' + (Limit-ContractText $Mutation 80)) }
  )) {
    $copy | Add-Member -NotePropertyName ([string]$entry.name) -NotePropertyValue $entry.value -Force
  }
  if ($SessionRebind) {
    # Normal continuity may use a distinct projection worker/session. A root
    # session handoff is different: it must transfer the concrete owner of all
    # active projections in the same transaction as the contract.
    $copy | Add-Member -NotePropertyName 'sessionId' -NotePropertyValue ([string]$Contract.ownerSessionKey) -Force
  }
  if ($Kind -eq 'checkpoint') {
    $copy | Add-Member -NotePropertyName timestamp -NotePropertyValue $timestamp -Force
  } else {
    $copy | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'ContractContinuity' -Force
  }
  return $copy
}

function Publish-ExecutionContractDirect([object]$Contract) {
  Write-AtomicJsonUnlocked ([string]$Contract.path) $Contract
  Invoke-SuperBrainFileLock $pointerPath { Write-AtomicJsonUnlocked $pointerPath $Contract } | Out-Null
  $hotIndex = Sync-SuperBrainRuntimeWakeEntry $memoryBase $Contract 'EXECUTION_CONTRACT_DIRECT_HOT_INDEX_SYNC'
  return [pscustomobject]@{ ok=$true; state='direct_published'; hotIndex=$hotIndex }
}

function Test-ContractRequiresPlanCheckpoint([object]$Contract) {
  if (-not $Contract -or -not $Contract.PSObject.Properties['canonicalPlan'] -or -not $Contract.canonicalPlan) { return $false }
  $canonical = Test-CanonicalPlanState $Contract.canonicalPlan
  if (-not $canonical.ok) { throw ('EXECUTION_CONTRACT_CANONICAL_PLAN_INVALID_FOR_CHECKPOINT code=' + [string]$canonical.code) }
  return $true
}

function Invoke-AtomicContractContinuity([object]$Contract,[string]$Mutation,[object]$ContextSeed=$null,[switch]$SessionRebind) {
  $contextRoot = Join-Path $workspace 'guard-state\current-task-contexts'
  $contextPath = Get-SuperBrainCanonicalTaskPath $contextRoot ([string]$Contract.taskId) '.json'
  $bootstrapContext = ($null -ne $ContextSeed)
  if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf) -and -not $bootstrapContext) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_MISSING'; state='blocked'; contextPath=$contextPath; guard='A bound current-task context is required before an execution contract can advance through the transactional continuity path.' }
  }
  $context = if ($bootstrapContext) { $ContextSeed } else { Read-ContractJson $contextPath }
  if (-not $context -or [string]$context.taskId -ne [string]$Contract.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) ([string]$Contract.workspaceKey))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_IDENTITY_MISMATCH'; state='blocked'; contextPath=$contextPath }
  }
  if (-not $bootstrapContext -and ([string]$context.bindingState -ne 'bound' -or [string]$context.authorizationState -ne 'authorizing')) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_NOT_AUTHORIZING'; state='blocked'; contextPath=$contextPath }
  }
  foreach ($property in @('agentId','sessionId','platform','workspace')) {
    if (-not $context.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$context.$property)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_OWNER_MISSING'; state='blocked'; contextPath=$contextPath; missing=$property }
    }
  }
  $stateRead = Invoke-ContractTaskStateStore @{ Action='Get'; TaskId=[string]$Contract.taskId }
  if (-not $stateRead.ok -or -not $stateRead.value) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_TASK_STATE_MISSING'; state='blocked'; contextPath=$contextPath; taskState=$stateRead.value; childCode=$stateRead.code }
  }
  $expectedTaskStateRevision = [int]$stateRead.value.revision
  if ($expectedTaskStateRevision -lt 0) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_TASK_STATE_INVALID'; state='blocked'; contextPath=$contextPath }
  }
  $requiresPlanCheckpoint = Test-ContractRequiresPlanCheckpoint $Contract
  # A canonical plan requires an active checkpoint. A non-canonical task may
  # still have one because its current context was bootstrapped as an active
  # bundle; once such a checkpoint is active it is part of the same authority
  # and must advance atomically with the contract rather than being left stale.
  $checkpointEntity = Get-ContractContinuityActiveEntity $stateRead.value 'checkpoint' ([string]$Contract.taskId) ([string]$Contract.workspaceKey)
  $includeCheckpoint = ($checkpointEntity -and $checkpointEntity.ok)
  if ($requiresPlanCheckpoint -and -not $includeCheckpoint) {
    return [pscustomobject]@{ ok=$false; code=[string]$checkpointEntity.code; state='blocked'; kind='checkpoint'; contextPath=$contextPath; entityPath=$checkpointEntity.path; guard='An approved canonical plan can advance only when its active checkpoint is current, canonical, and owned by the same task-state projection.' }
  }
  if (-not $includeCheckpoint -and $checkpointEntity -and [string]$checkpointEntity.code -notin @('EXECUTION_CONTRACT_CONTINUITY_ENTITY_MISSING','EXECUTION_CONTRACT_CONTINUITY_ENTITY_NOT_ACTIVE')) {
    return [pscustomobject]@{ ok=$false; code=[string]$checkpointEntity.code; state='blocked'; kind='checkpoint'; contextPath=$contextPath; entityPath=$checkpointEntity.path; guard='An existing active checkpoint is invalid or stale. Repair it before advancing the bound contract.' }
  }
  $taskCardEntity = Get-ContractContinuityActiveEntity $stateRead.value 'task_card' ([string]$Contract.taskId) ([string]$Contract.workspaceKey)
  if (-not $taskCardEntity.ok) {
    return [pscustomobject]@{ ok=$false; code=[string]$taskCardEntity.code; state='blocked'; kind='task_card'; contextPath=$contextPath; entityPath=$taskCardEntity.path; guard='A bound task can advance only when its active task card is current, canonical, and owned by the same task-state projection.' }
  }
  $routeRoot = Join-Path $workspace 'guard-state\route-checkpoints'
  $routePath = Get-SuperBrainCanonicalTaskPath $routeRoot ([string]$Contract.taskId) '.json'
  $route = if (Test-Path -LiteralPath $routePath -PathType Leaf) { Read-ContractJson $routePath } else { $null }
  if ((Test-Path -LiteralPath $routePath -PathType Leaf) -and (-not $route -or [string]$route.taskId -ne [string]$Contract.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$route.workspaceKey) ([string]$Contract.workspaceKey)) -or [string]$route.bindingState -ne 'bound')) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ROUTE_IDENTITY_MISMATCH'; state='blocked'; contextPath=$contextPath; routePath=$routePath }
  }

  $stagedPaths = New-Object System.Collections.ArrayList
  $transactionInvoked = $false
  try {
    $contractPath = [string]$Contract.path
    $contractPayloadPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'execution-contract' $Contract
    [void]$stagedPaths.Add($contractPayloadPath)
    $contractHash = (Get-FileHash -LiteralPath $contractPayloadPath -Algorithm SHA256).Hash
    $contractFileName = Split-Path -Leaf $contractPath
    $checkpointProjection = $null
    $checkpointPayloadPath = ''
    if ($includeCheckpoint) {
      $checkpointProjection = New-ContractContinuityStateProjection $checkpointEntity.value $Contract ($expectedTaskStateRevision+1) $contractHash 'checkpoint' $Mutation -SessionRebind:$SessionRebind
      $checkpointPayloadPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'active-checkpoint' $checkpointProjection
      [void]$stagedPaths.Add($checkpointPayloadPath)
    }
    $taskCardProjection = New-ContractContinuityStateProjection $taskCardEntity.value $Contract ($expectedTaskStateRevision+1) $contractHash 'task_card' $Mutation -SessionRebind:$SessionRebind
    $taskCardProjection | Add-Member -NotePropertyName sourcePath -NotePropertyValue ([string]$taskCardEntity.path) -Force
    # Task cards predate the contract transaction and may not carry the concrete
    # workspace path. Keep their projection owner aligned with the bound context.
    $taskCardProjection | Add-Member -NotePropertyName workspace -NotePropertyValue ([string]$context.workspace) -Force
    $taskCardPayloadPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'active-task-card' $taskCardProjection
    [void]$stagedPaths.Add($taskCardPayloadPath)
    $contextPreview = Invoke-ContractProjectionChild (Join-Path $PSScriptRoot 'current-task-context.ps1') @{
      Action='Preview'; TaskId=[string]$Contract.taskId; WorkspaceKey=[string]$Contract.workspaceKey; AgentId=[string]$context.agentId; SessionId=if($SessionRebind){[string]$Contract.ownerSessionKey}else{[string]$context.sessionId}
      Platform=[string]$context.platform; OwnerWorkspace=[string]$context.workspace; MaxAgeHours=if($context.PSObject.Properties['maxAgeHours']){[int]$context.maxAgeHours}else{24}; ContractPath=$contractPayloadPath; ContractFileName=$contractFileName; ContractHash=$contractHash
      AcceptedGoal=if($context.PSObject.Properties['acceptedGoal']){[string]$context.acceptedGoal}else{''}; AcceptedRoute=if($context.PSObject.Properties['acceptedRoute']){@($context.acceptedRoute)}else{@()}
      NonGoals=if($context.PSObject.Properties['nonGoals']){@($context.nonGoals)}else{@()}; MustPreserve=if($context.PSObject.Properties['mustPreserve']){@($context.mustPreserve)}else{@()}
      MustNotDriftTo=if($context.PSObject.Properties['mustNotDriftTo']){@($context.mustNotDriftTo)}else{@()}; Evidence=if($context.PSObject.Properties['evidence']){@($context.evidence)}else{@()}
      TaskStateRevisionOverride=($expectedTaskStateRevision+1); Json=$true
    }
    if (-not $contextPreview.ok -or -not $contextPreview.value -or [string]$contextPreview.value.bindingState -ne 'bound' -or [string]$contextPreview.value.authorizationState -ne 'authorizing') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_PREVIEW_FAILED'; state='blocked'; contextPath=$contextPath; childCode=$contextPreview.code; childExitCode=$contextPreview.exitCode }
    }
    $contextPayloadPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'current-context' $contextPreview.value
    [void]$stagedPaths.Add($contextPayloadPath)
    $commands = New-Object System.Collections.ArrayList
    if ($includeCheckpoint) {
      [void]$commands.Add((New-ContractContinuityCommand 'active_checkpoint' 'replace_if_hash' ([string]$checkpointEntity.path) $checkpointPayloadPath ([string]$checkpointEntity.hash) ([string]$Contract.taskId) ([string]$Contract.workspaceKey)))
    }
    [void]$commands.Add((New-ContractContinuityCommand 'active_task_card' 'replace_if_hash' ([string]$taskCardEntity.path) $taskCardPayloadPath ([string]$taskCardEntity.hash) ([string]$Contract.taskId) ([string]$Contract.workspaceKey)))
    if ($includeCheckpoint) {
      $checkpointPointerPath = Join-Path $workspace 'active-checkpoint.json'
      [void]$commands.Add((New-ContractContinuityCommand 'checkpoint_pointer' 'conditional_pointer' $checkpointPointerPath $checkpointPayloadPath (Get-ContractContinuityPointerExpectedHash $checkpointPointerPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $true))
    }
    [void]$commands.Add((New-ContractContinuityCommand 'current_context' 'replace_if_hash' $contextPath $contextPayloadPath (Get-ContractContinuityPointerExpectedHash $contextPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $bootstrapContext))
    $workspacePointerPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-context-pointers') ([string]$Contract.workspaceKey) '.json'
    [void]$commands.Add((New-ContractContinuityCommand 'workspace_context_pointer' 'conditional_pointer' $workspacePointerPath $contextPayloadPath (Get-ContractContinuityPointerExpectedHash $workspacePointerPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $true))
    $legacyContextPointerPath = Join-Path $workspace 'current-task-context.json'
    [void]$commands.Add((New-ContractContinuityCommand 'legacy_context_pointer' 'conditional_pointer' $legacyContextPointerPath $contextPayloadPath (Get-ContractContinuityPointerExpectedHash $legacyContextPointerPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $true))
    if ($route) {
      $routePreview = Invoke-ContractProjectionChild (Join-Path $PSScriptRoot 'route-checkpoint.ps1') @{
        Phase='BeforeMutation'; TaskId=[string]$Contract.taskId; WorkspaceKey=[string]$Contract.workspaceKey; ObservedAction=("execution contract {0} transactional projection revision={1}" -f $Mutation,[int]$Contract.revision)
        AllowMissingGoalLock=$true; Preview=$true; ContractPath=$contractPayloadPath; ContractFileName=$contractFileName; ContractHash=$contractHash; TaskStateRevisionOverride=($expectedTaskStateRevision+1); Json=$true
      }
      if (-not $routePreview.ok -or -not $routePreview.value -or [string]$routePreview.value.bindingState -ne 'bound') {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ROUTE_PREVIEW_FAILED'; state='blocked'; contextPath=$contextPath; routePath=$routePath; childCode=$routePreview.code; childExitCode=$routePreview.exitCode }
      }
      $routePayloadPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'route-checkpoint' $routePreview.value
      [void]$stagedPaths.Add($routePayloadPath)
      [void]$commands.Add((New-ContractContinuityCommand 'route_checkpoint' 'replace_if_hash' $routePath $routePayloadPath (Get-ContractContinuityPointerExpectedHash $routePath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey)))
      $legacyRoutePointerPath = Join-Path $workspace 'route-checkpoint.json'
      [void]$commands.Add((New-ContractContinuityCommand 'route_checkpoint_pointer' 'conditional_pointer' $legacyRoutePointerPath $routePayloadPath (Get-ContractContinuityPointerExpectedHash $legacyRoutePointerPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $true))
    }
    [void]$commands.Add((New-ContractContinuityCommand 'execution_contract' 'replace_if_hash' $contractPath $contractPayloadPath (Get-ContractContinuityPointerExpectedHash $contractPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey)))
    [void]$commands.Add((New-ContractContinuityCommand 'contract_pointer' 'conditional_pointer' $pointerPath $contractPayloadPath (Get-ContractContinuityPointerExpectedHash $pointerPath) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) $true))
    $manifest = [pscustomobject]@{
      schema='super-brain.contract-continuity-manifest.v1'; taskId=[string]$Contract.taskId; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=[string]$Contract.workspaceKey
      packageVersion=[string]$manifest.version; expectedTaskStateRevision=$expectedTaskStateRevision; contractRevision=[int]$Contract.revision; planFingerprint=[string]$Contract.planReceipt.planFingerprint
      mutation=Limit-ContractText $Mutation 80; bootstrapContext=[bool]$bootstrapContext; planCheckpointRequired=[bool]$requiresPlanCheckpoint; checkpointProjectionIncluded=[bool]$includeCheckpoint; commands=@($commands); rawInstructionStored=$false; rawTranscriptStored=$false
    }
    $manifestPath = Write-ContractContinuityStagingValue ([string]$Contract.taskId) 'contract-continuity-manifest' $manifest
    [void]$stagedPaths.Add($manifestPath)
    $transactionInvoked = $true
    $commit = Invoke-ContractTaskStateStore @{ Action='CommitContinuity'; TaskId=[string]$Contract.taskId; ContinuityManifestPath=$manifestPath; Source=('execution-contract.ps1:' + $Mutation); WorkspaceRoot=$workspace; FaultPoint=$ContinuityFaultPoint }
    if (-not $commit.ok) {
      $childCode = if($commit.value -and $commit.value.PSObject.Properties['code'] -and -not [string]::IsNullOrWhiteSpace([string]$commit.value.code)){[string]$commit.value.code}elseif($commit.value -and $commit.value.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$commit.value.error)){[string]$commit.value.error}else{[string]$commit.code}
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_TRANSACTION_FAILED'; taskId=[string]$Contract.taskId; workspaceKey=[string]$Contract.workspaceKey; contractRevision=[int]$Contract.revision; planFingerprint=[string]$Contract.planReceipt.planFingerprint; childCode=$childCode; childExitCode=$commit.exitCode; guard='The continuity transaction did not report committed. Do not claim synchronized continuation; reconcile the prepared TaskStateStore transaction before replaying this transition.' }
    }
    $hotIndex = Sync-SuperBrainRuntimeWakeEntry $memoryBase $Contract 'EXECUTION_CONTRACT_CONTINUITY_HOT_INDEX_SYNC'
    Remove-MatchingLegacyContract ([string]$Contract.taskId) ([string]$Contract.workspaceKey)
    $Contract | Add-Member -NotePropertyName continuityRefresh -NotePropertyValue ([pscustomobject]@{ ok=$true; state='refreshed'; mode=if($bootstrapContext){'bootstrap_transactional'}else{'transactional'}; planCheckpointRequired=[bool]$requiresPlanCheckpoint; checkpointProjectionIncluded=[bool]$includeCheckpoint; contextPath=$contextPath; checkpointPath=if($includeCheckpoint){[string]$checkpointEntity.path}else{''}; taskCardPath=[string]$taskCardEntity.path; routePath=if($route){$routePath}else{''}; contractRevision=[int]$Contract.revision; planFingerprint=[string]$Contract.planReceipt.planFingerprint; transactionId=[string]$commit.value.transactionId; hotIndex=$hotIndex }) -Force
    if ($bootstrapContext) { $Contract | Add-Member -NotePropertyName contextBinding -NotePropertyValue $contextPreview.value -Force }
    return $Contract
  } finally {
    if (-not $transactionInvoked) {
      foreach ($path in @($stagedPaths)) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    }
  }
}

function Bind-ContractContext {
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($WorkspaceKey)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTEXT_BIND_SCOPE_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A context bootstrap must name one task and workspace.' }
  }
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $validity = Test-ContractCurrent $contract
  if (-not $validity.current) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTEXT_BIND_CONTRACT_STALE'; taskId=$TaskId; workspaceKey=$WorkspaceKey; reasons=@($validity.reasons); guard='A context may only bind to the current task-scoped execution contract.' }
  }
  $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $TaskId '.json'
  if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTEXT_BIND_ALREADY_EXISTS'; taskId=$TaskId; workspaceKey=$WorkspaceKey; contextPath=$contextPath; guard='Existing contexts must use the normal continuity refresh path; bootstrap is only for an absent context.' }
  }
  $seed = [pscustomobject]@{
    taskId=$TaskId; workspaceKey=$WorkspaceKey; agentId=$ContextAgentId; sessionId=$ContextSessionId; platform=$ContextPlatform; workspace=$ContextOwnerWorkspace
    acceptedGoal=$ContextAcceptedGoal; acceptedRoute=@($ContextAcceptedRoute); nonGoals=@($ContextNonGoals); mustPreserve=@($ContextMustPreserve); mustNotDriftTo=@($ContextMustNotDriftTo); evidence=@($ContextEvidence); maxAgeHours=$ContextMaxAgeHours
  }
  foreach ($property in @('agentId','sessionId','platform','workspace')) {
    if ([string]::IsNullOrWhiteSpace([string]$seed.$property)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTEXT_BIND_OWNER_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=$property; guard='The bootstrap context owner must match the active checkpoint and task-card owner.' }
    }
  }
  $bound = Invoke-AtomicContractContinuity $contract 'BindContext' $seed
  if (-not $bound -or -not $bound.PSObject.Properties['continuityRefresh'] -or -not $bound.continuityRefresh.ok -or -not $bound.PSObject.Properties['contextBinding'] -or -not $bound.contextBinding) {
    return [pscustomobject]@{ ok=$false; code=if($bound -and $bound.PSObject.Properties['code']){[string]$bound.code}else{'EXECUTION_CONTRACT_CONTEXT_BIND_FAILED'}; taskId=$TaskId; workspaceKey=$WorkspaceKey; continuity=$bound; guard='The initial context did not enter the same recoverable transaction as its contract, checkpoint, and task card.' }
  }
  return [pscustomobject]@{ ok=$true; action='BindContext'; taskId=$TaskId; workspaceKey=$WorkspaceKey; context=$bound.contextBinding; continuityRefresh=$bound.continuityRefresh; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint }
}

function Invoke-ContractContinuityProjectionRefresh([object]$Contract,[string]$Mutation) {
  if (-not $Contract -or [string]$Contract.status -ne 'active') {
    return [pscustomobject]@{ ok=$true; state='not_applicable'; reason='inactive_contract' }
  }
  $contextRoot = Join-Path $workspace 'guard-state\current-task-contexts'
  $contextPath = Get-SuperBrainCanonicalTaskPath $contextRoot ([string]$Contract.taskId) '.json'
  if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$true; state='not_applicable'; reason='context_missing'; contextPath=$contextPath }
  }
  $context = Read-ContractJson $contextPath
  if (-not $context -or [string]$context.taskId -ne [string]$Contract.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) ([string]$Contract.workspaceKey))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_IDENTITY_MISMATCH'; state='blocked'; contextPath=$contextPath }
  }
  if (-not $context.PSObject.Properties['bindingState'] -or [string]$context.bindingState -ne 'bound' -or -not $context.PSObject.Properties['authorizationState'] -or [string]$context.authorizationState -ne 'authorizing') {
    return [pscustomobject]@{ ok=$true; state='not_applicable'; reason='context_non_authorizing'; contextPath=$contextPath }
  }
  foreach ($property in @('agentId','sessionId','platform','workspace')) {
    if (-not $context.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$context.$property)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_OWNER_MISSING'; state='blocked'; contextPath=$contextPath; missing=$property }
    }
  }
  $contextScript = Join-Path $PSScriptRoot 'current-task-context.ps1'
  $contextRefresh = Invoke-ContractProjectionChild $contextScript @{
    Action='Update'; TaskId=[string]$Contract.taskId; WorkspaceKey=[string]$Contract.workspaceKey
    AgentId=[string]$context.agentId; SessionId=[string]$context.sessionId; Platform=[string]$context.platform
    OwnerWorkspace=[string]$context.workspace; MaxAgeHours=24; Json=$true
  }
  if (-not $contextRefresh.ok -or [int]$contextRefresh.value.contractRevision -ne [int]$Contract.revision -or [string]$contextRefresh.value.planFingerprint -ne [string]$Contract.planReceipt.planFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_REFRESH_FAILED'; state='blocked'; contextPath=$contextPath; childCode=$contextRefresh.code; childExitCode=$contextRefresh.exitCode }
  }
  $routeRoot = Join-Path $workspace 'guard-state\route-checkpoints'
  $routePath = Get-SuperBrainCanonicalTaskPath $routeRoot ([string]$Contract.taskId) '.json'
  if (-not (Test-Path -LiteralPath $routePath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$true; state='context_refreshed_route_absent'; contextPath=$contextPath; routePath=$routePath; contractRevision=[int]$Contract.revision }
  }
  $route = Read-ContractJson $routePath
  if (-not $route -or [string]$route.taskId -ne [string]$Contract.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$route.workspaceKey) ([string]$Contract.workspaceKey))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ROUTE_IDENTITY_MISMATCH'; state='blocked'; contextPath=$contextPath; routePath=$routePath }
  }
  if (-not $route.PSObject.Properties['bindingState'] -or [string]$route.bindingState -ne 'bound') {
    return [pscustomobject]@{ ok=$true; state='context_refreshed_route_non_authorizing'; contextPath=$contextPath; routePath=$routePath; contractRevision=[int]$Contract.revision }
  }
  $routeScript = Join-Path $PSScriptRoot 'route-checkpoint.ps1'
  $routeRefresh = Invoke-ContractProjectionChild $routeScript @{
    Phase='BeforeMutation'; TaskId=[string]$Contract.taskId; WorkspaceKey=[string]$Contract.workspaceKey
    ObservedAction=("execution contract {0} projection refresh revision={1}" -f $Mutation,[int]$Contract.revision)
    AllowMissingGoalLock=$true; Json=$true
  }
  if (-not $routeRefresh.ok -or [int]$routeRefresh.value.contractRevision -ne [int]$Contract.revision -or [string]$routeRefresh.value.planFingerprint -ne [string]$Contract.planReceipt.planFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_ROUTE_REFRESH_FAILED'; state='blocked'; contextPath=$contextPath; routePath=$routePath; childCode=$routeRefresh.code; childExitCode=$routeRefresh.exitCode }
  }
  return [pscustomobject]@{ ok=$true; state='refreshed'; contextPath=$contextPath; routePath=$routePath; contractRevision=[int]$Contract.revision; planFingerprint=[string]$Contract.planReceipt.planFingerprint }
}

function Get-ContractContinuationProgressSentence([object]$Contract) {
  if (-not $Contract) { return '' }
  if ($Contract.PSObject.Properties['lastConfirmedSentence'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.lastConfirmedSentence)) {
    return Limit-ContractText ([string]$Contract.lastConfirmedSentence) 320
  }
  if ($Contract.PSObject.Properties['assistantCommitment'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.assistantCommitment)) {
    return Limit-ContractText ([string]$Contract.assistantCommitment) 320
  }
  $parts = @()
  if ($Contract.PSObject.Properties['currentPhase'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.currentPhase)) { $parts += ('phase ' + (Limit-ContractText ([string]$Contract.currentPhase) 80)) }
  if ($Contract.PSObject.Properties['currentStep'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.currentStep)) { $parts += ('current step: ' + (Limit-ContractText ([string]$Contract.currentStep) 180)) }
  if ($Contract.PSObject.Properties['completedSteps'] -and @($Contract.completedSteps).Count -gt 0) { $parts += ('completed=' + [string]@($Contract.completedSteps).Count) }
  if ($Contract.PSObject.Properties['pendingSteps'] -and @($Contract.pendingSteps).Count -gt 0) { $parts += ('pending=' + [string]@($Contract.pendingSteps).Count) }
  if ($parts.Count -eq 0 -and $Contract.PSObject.Properties['nextAction'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.nextAction)) { $parts += ('next planned action: ' + (Limit-ContractText ([string]$Contract.nextAction) 180)) }
  return Limit-ContractText ($parts -join '; ') 320
}

function Write-ContractContinuationReceipt([object]$Contract,[string]$Mutation) {
  if (-not $Contract -or [string]::IsNullOrWhiteSpace([string]$Contract.taskId) -or [string]::IsNullOrWhiteSpace([string]$Contract.workspaceKey) -or [string]::IsNullOrWhiteSpace([string]$Contract.ownerSessionKey)) {
    return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CONTINUATION_RECEIPT_SCOPE_INVALID';receipt=$null}
  }
  $workLine = if ($Contract.PSObject.Properties['workLineStatus']) { $Contract.workLineStatus } else { $null }
  $canonical = if ($workLine -and $workLine.PSObject.Properties['canonicalMain']) { $workLine.canonicalMain } else { $null }
  $providedLastConfirmedSentence = if($Contract.PSObject.Properties['lastConfirmedSentence']){[string]$Contract.lastConfirmedSentence}else{''}
  $lastConfirmedSentence = Get-ContractContinuationProgressSentence $Contract
  $lastConfirmedSource = if($Contract.PSObject.Properties['lastConfirmedSource'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.lastConfirmedSource)){[string]$Contract.lastConfirmedSource}elseif(-not [string]::IsNullOrWhiteSpace($providedLastConfirmedSentence)){'assistant_commitment'}else{'execution_state_projection'}
  # Do not inline these conditional arrays in the receipt object: PowerShell serializes a
  # singleton result from an inline if as a scalar, and the Python boundary rightly rejects it.
  $receiptCompletedSteps = @()
  $receiptPendingSteps = @()
  $receiptEvidence = @()
  if ($Contract.PSObject.Properties['completedSteps']) { $receiptCompletedSteps = @(Limit-ContractList @($Contract.completedSteps) 16 180) }
  if ($Contract.PSObject.Properties['pendingSteps']) { $receiptPendingSteps = @(Limit-ContractList @($Contract.pendingSteps) 24 180) }
  if ($Contract.PSObject.Properties['evidence']) { $receiptEvidence = @(Limit-ContractList @($Contract.evidence) 8 180) }
  $state = [ordered]@{
    latestUserInstruction = if($Contract.PSObject.Properties['latestUserInstruction']){[string]$Contract.latestUserInstruction}else{''}
    lastConfirmedSentence = $lastConfirmedSentence
    lastConfirmedSource = $lastConfirmedSource
    mainLine = if($workLine -and $workLine.PSObject.Properties['mainLine']){[string]$workLine.mainLine}else{[string]$Contract.focusId}
    activeLine = if($workLine -and $workLine.PSObject.Properties['activeLine']){[string]$workLine.activeLine}else{[string]$Contract.focusId}
    currentPhase = if($Contract.PSObject.Properties['currentPhase']){[string]$Contract.currentPhase}else{''}
    currentStep = if($Contract.PSObject.Properties['currentStep']){[string]$Contract.currentStep}else{[string]$Contract.nextAction}
    completedSteps = @($receiptCompletedSteps)
    pendingSteps = @($receiptPendingSteps)
    nextAction = if($Contract.PSObject.Properties['nextAction']){[string]$Contract.nextAction}else{''}
    evidence = @($receiptEvidence)
    returnPoint = [ordered]@{
      focusId=if($Contract.PSObject.Properties['focusId']){[string]$Contract.focusId}else{''}
      focusLabel=if($Contract.PSObject.Properties['focusLabel']){[string]$Contract.focusLabel}else{''}
      resumeFrom=Limit-ContractText $Mutation 80
    }
    canonicalPlan = [ordered]@{
      planId=if($canonical -and $canonical.PSObject.Properties['planId']){[string]$canonical.planId}else{''}
      generation=if($canonical -and $canonical.PSObject.Properties['generation']){[int]$canonical.generation}else{0}
      fingerprint=if($canonical -and $canonical.PSObject.Properties['currentFingerprint']){[string]$canonical.currentFingerprint}elseif($Contract.planReceipt){[string]$Contract.planReceipt.planFingerprint}else{''}
      completedCount=if($canonical -and $canonical.PSObject.Properties['completedCount']){[int]$canonical.completedCount}else{@($Contract.completedSteps).Count}
      pendingCount=if($canonical -and $canonical.PSObject.Properties['pendingCount']){[int]$canonical.pendingCount}else{@($Contract.pendingSteps).Count}
    }
    completedHistoryIsCurrent = $false
  }
  $response = Invoke-SuperBrainRuntimeWakeAnchorControl 'record-continuation-receipt' $memoryBase @{
    taskId=[string]$Contract.taskId
    taskInstanceId=[string]$Contract.taskInstanceId
    workspaceKey=[string]$Contract.workspaceKey
    ownerSessionKey=[string]$Contract.ownerSessionKey
    packageVersion=[string]$Contract.packageVersion
    contractRevision=[int]$Contract.revision
    planFingerprint=if($Contract.planReceipt){[string]$Contract.planReceipt.planFingerprint}else{''}
    instructionAnchor=if($Contract.PSObject.Properties['instructionAnchor']){$Contract.instructionAnchor}else{$null}
    state=$state
    source=('execution-contract.ps1:' + (Limit-ContractText $Mutation 80))
  }
  if (-not $response.ok -or -not $response.receipt) {
    return [pscustomobject]@{ok=$false;code=if($response.code){[string]$response.code}else{'EXECUTION_CONTRACT_CONTINUATION_RECEIPT_WRITE_FAILED'};receipt=$null}
  }
  return [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_CONTINUATION_RECEIPT_RECORDED';receipt=$response.receipt}
}

function Finalize-ContractContinuationReceipt([object]$Result,[string]$Mutation) {
  if (-not $Result -or $Result.ok -ne $true) { return $Result }
  $receipt = Write-ContractContinuationReceipt $Result $Mutation
  if (-not $receipt.ok) {
    # The contract may already be durable while the receipt writer experienced a
    # transient protocol failure. Replaying the idempotent receipt write makes the
    # recovery state whole without advancing the contract a second time.
    $replayed = Write-ContractContinuationReceipt $Result $Mutation
    if ($replayed.ok) {
      $Result | Add-Member -NotePropertyName continuationReceipt -NotePropertyValue $replayed.receipt -Force
      $Result | Add-Member -NotePropertyName continuationReceiptRepair -NotePropertyValue ([pscustomobject]@{attempted=$true;recovered=$true;initialCode=[string]$receipt.code;code='EXECUTION_CONTRACT_CONTINUATION_RECEIPT_REPLAYED'}) -Force
      return $Result
    }
    return [pscustomobject]@{ok=$false;code=[string]$replayed.code;taskId=[string]$Result.taskId;workspaceKey=[string]$Result.workspaceKey;contractCommitted=$true;contractRevision=[int]$Result.revision;planFingerprint=if($Result.planReceipt){[string]$Result.planReceipt.planFingerprint}else{''};continuationReceiptRepair=[pscustomobject]@{attempted=$true;recovered=$false;initialCode=[string]$receipt.code;replayCode=[string]$replayed.code};guard='The contract changed but its authoritative continuation receipt could not be verified after an idempotent replay. Do not claim phase progress; repair the receipt and replay from the current contract.'}
  }
  $Result | Add-Member -NotePropertyName continuationReceipt -NotePropertyValue $receipt.receipt -Force
  return $Result
}

function Complete-ContractContinuityMutation([object]$Contract,[string]$Mutation) {
  $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') ([string]$Contract.taskId) '.json'
  $context = Read-ContractJson $contextPath
  $needsTransactionalContinuity = ($context -and [string]$context.taskId -eq [string]$Contract.taskId -and (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) ([string]$Contract.workspaceKey)) -and [string]$context.bindingState -eq 'bound' -and [string]$context.authorizationState -eq 'authorizing')
  if ($needsTransactionalContinuity) {
    if ($RebindSession) {
      $previous = Read-ContractJson ([string]$Contract.path)
      if (-not $previous -or [string]$previous.taskId -ne [string]$Contract.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$previous.workspaceKey) ([string]$Contract.workspaceKey)) -or [int]$previous.revision -ne ([int]$Contract.revision - 1) -or [string]::IsNullOrWhiteSpace([string]$previous.ownerSessionKey) -or [string]::IsNullOrWhiteSpace([string]$Contract.ownerSessionKey)) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_SESSION_REBIND_PREVIOUS_CONTRACT_REQUIRED'; taskId=[string]$Contract.taskId; workspaceKey=[string]$Contract.workspaceKey; guard='The prior bound contract must be current and identity-matched before a projected task can change root-session owner.' }
      }
      $ownerChanged = -not [string]::Equals([string]$previous.ownerSessionKey,[string]$Contract.ownerSessionKey,[StringComparison]::OrdinalIgnoreCase)
      $hasIntentRebind = ($Contract.PSObject.Properties['intentSessionRebindReceipt'] -and $Contract.intentSessionRebindReceipt)
      if ($ownerChanged -and -not $hasIntentRebind) {
        $taskStateRevision = if ($context.PSObject.Properties['taskStateRevision']) { [int]$context.taskStateRevision } else { -1 }
        $previousPlanFingerprint = if ($previous.PSObject.Properties['planReceipt'] -and $previous.planReceipt) { [string]$previous.planReceipt.planFingerprint } else { '' }
        $issued = Issue-TaskSessionRebindReceipt ([string]$Contract.taskId) ([string]$Contract.taskInstanceId) ([string]$Contract.workspaceKey) ([string]$previous.ownerSessionKey) ([string]$Contract.ownerSessionKey) ([string]$Contract.packageVersion) $taskStateRevision ([int]$previous.revision) $previousPlanFingerprint ('execution-contract.ps1:' + $Mutation)
        if (-not $issued.ok -or -not $issued.receipt) {
          return [pscustomobject]@{ ok=$false; code=if($issued){[string]$issued.code}else{'EXECUTION_CONTRACT_TASK_SESSION_REBIND_ISSUE_FAILED'}; taskId=[string]$Contract.taskId; workspaceKey=[string]$Contract.workspaceKey; guard='A non-intent task may transfer projected root-session ownership only with an immutable task-authority receipt bound to the current task revision, contract revision, and plan fingerprint.' }
        }
        $Contract | Add-Member -NotePropertyName taskSessionRebindReceipt -NotePropertyValue $issued.receipt -Force
      }
    }
    return Finalize-ContractContinuationReceipt (Invoke-AtomicContractContinuity $Contract $Mutation $null -SessionRebind:$RebindSession) $Mutation
  }
  $publish = Publish-ExecutionContractDirect $Contract
  if (-not $publish.ok) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DIRECT_PUBLISH_FAILED'; taskId=[string]$Contract.taskId; workspaceKey=[string]$Contract.workspaceKey; guard='The execution contract could not be published through its non-transactional compatibility path.' }
  }
  Remove-MatchingLegacyContract ([string]$Contract.taskId) ([string]$Contract.workspaceKey)
  $refresh = Invoke-ContractContinuityProjectionRefresh $Contract $Mutation
  if (-not $refresh.ok) {
    return [pscustomobject]@{
      ok=$false; code=[string]$refresh.code; taskId=[string]$Contract.taskId; workspaceKey=[string]$Contract.workspaceKey
      contractCommitted=$true; contractRevision=[int]$Contract.revision; planFingerprint=[string]$Contract.planReceipt.planFingerprint
      continuityRefresh=$refresh; guard='The contract was published through the compatibility path, but its existing continuity projection could not be refreshed. Do not claim synchronized continuation; repair the projection and replay the same transition.'
    }
  }
  $Contract | Add-Member -NotePropertyName continuityRefresh -NotePropertyValue $refresh -Force
  $Contract | Add-Member -NotePropertyName hotIndex -NotePropertyValue $publish.hotIndex -Force
  return Finalize-ContractContinuationReceipt $Contract $Mutation
}

function Test-ContractCurrent($Contract) {
  $reasons = @()
  if (-not $Contract) { $reasons += 'missing' }
  else {
    if ([string]$Contract.schema -ne 'super-brain.execution-contract.v1') { $reasons += 'schema_mismatch' }
    if ([string]$Contract.taskId -ne $TaskId) { $reasons += 'task_mismatch' }
    if($Contract.PSObject.Properties['taskInstanceId']-and[string]$Contract.taskInstanceId-notmatch'^ti-[a-f0-9]{32}$'){$reasons+='task_instance_invalid'}
    if (-not (Test-SuperBrainWorkspaceKey ([string]$Contract.workspaceKey) $WorkspaceKey)) { $reasons += 'workspace_mismatch' }
    if ([string]$Contract.packageVersion -ne [string]$manifest.version) { $reasons += 'version_mismatch' }
    if ([string]$Contract.status -ne 'active') { $reasons += 'inactive' }
    $stageKind = if ($Contract.PSObject.Properties['stageKind']) { [string]$Contract.stageKind } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stageKind)) {
      if ($stageKind -notin @('build','package','release','deploy','test')) { $reasons += 'decision_stage_invalid' }
      elseif (-not $Contract.PSObject.Properties['decisionBinding'] -or -not $Contract.decisionBinding) { $reasons += 'decision_binding_missing' }
      else {
        $binding = $Contract.decisionBinding
        if ([string]$binding.status -notin @('bound','none_applicable') -or [string]::IsNullOrWhiteSpace([string]$binding.bindingDigest) -or [string]::IsNullOrWhiteSpace([string]$binding.path)) { $reasons += 'decision_binding_invalid' }
        elseif ($binding.PSObject.Properties['receiptSchema'] -and [string]$binding.receiptSchema -eq 'super-brain.decision-resolution-receipt.v2' -and ([string]::IsNullOrWhiteSpace([string]$binding.receiptId) -or [string]$binding.packageManifestHash -notmatch '^[a-f0-9]{64}$')) { $reasons += 'decision_binding_integrity_metadata_invalid' }
      }
    }
    $stackIntegrity = Protect-ReturnStackIntegrity $(if($Contract.PSObject.Properties['returnStack']){@($Contract.returnStack)}else{@()}) ([string]$Contract.taskId) ([string]$Contract.workspaceKey) ([string]$Contract.focusId)
    if (-not $stackIntegrity.ok) { $reasons += [string]$stackIntegrity.reason }
    if ($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan) {
      $canonicalState = Test-CanonicalPlanState $Contract.canonicalPlan
      if (-not $canonicalState.ok) { $reasons += [string]$canonicalState.code }
      else {
        foreach ($card in @($stackIntegrity.cards)) {
          if ([string]$card.canonicalPlanId -ne [string]$canonicalState.plan.planId -or [int]$card.canonicalGeneration -ne [int]$canonicalState.plan.generation -or [string]$card.canonicalFingerprint -ne [string]$canonicalState.plan.currentFingerprint -or [string]$card.returnCardFingerprintVersion -notin @('v4','v5','v6')) {
            $reasons += 'canonical_return_card_binding_mismatch'
            break
          }
        }
      }
    }
    try {
      $age = ((Get-Date) - [datetime]::Parse([string]$Contract.updatedAt)).TotalHours
      if ($age -gt $MaxAgeHours) { $reasons += 'stale' }
      if ($age -lt -0.25) { $reasons += 'future_timestamp' }
    } catch { $reasons += 'invalid_timestamp' }
  }
  return [pscustomobject]@{ current=($reasons.Count -eq 0); reasons=@($reasons) }
}

function Get-ContractDecisionStageKind([object]$Existing,[string]$RequestedStage,[string]$CurrentPhaseValue='') {
  if ($RequestedStage -eq 'none') { return '' }
  if ($RequestedStage -ne 'auto') { return $RequestedStage }
  $phase = ([string]$CurrentPhaseValue).Trim().ToLowerInvariant()
  if ($phase -in @('build','package','release','deploy','test')) { return $phase }
  if ($Existing -and $Existing.PSObject.Properties['stageKind'] -and [string]$Existing.stageKind -in @('build','package','release','deploy','test')) { return [string]$Existing.stageKind }
  return ''
}

function Get-ContractEffectiveDecisionStageKind([object]$Existing,[string]$RequestedStage,[string]$CurrentPhaseValue='') {
  $stage = Get-ContractDecisionStageKind $Existing $RequestedStage $CurrentPhaseValue
  if ([string]::IsNullOrWhiteSpace($stage) -or $RequestedStage -ne 'auto') { return $stage }
  $existingStage = if ($Existing -and $Existing.PSObject.Properties['stageKind']) { [string]$Existing.stageKind } else { '' }
  if ($existingStage -in @('build','package','release','deploy','test')) {
    # A prior scoped stage must continue through its receipt validation; do not silently downgrade it.
    return $stage
  }
  $decisionIndexPath = Join-Path (Join-Path $memoryBase 'workspace') 'db\index.json'
  if (-not (Test-Path -LiteralPath $decisionIndexPath -PathType Leaf)) {
    # Ordinary phase labels are not a reason to start a decision resolver before a typed registry exists.
    return ''
  }
  return $stage
}

function Get-ContractDecisionIntentFingerprint([object]$Existing,[object]$IntentContract,[string]$Instruction,[string]$ExplicitFingerprint) {
  if (-not [string]::IsNullOrWhiteSpace($ExplicitFingerprint)) { return Limit-ContractText $ExplicitFingerprint 128 }
  if ($IntentContract -and $IntentContract.PSObject.Properties['contractFingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$IntentContract.contractFingerprint)) { return [string]$IntentContract.contractFingerprint }
  if ($Existing -and $Existing.PSObject.Properties['decisionIntentFingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$Existing.decisionIntentFingerprint) -and -not $script:LatestUserInstructionWasBound) { return [string]$Existing.decisionIntentFingerprint }
  if ([string]::IsNullOrWhiteSpace($Instruction)) { return '' }
  return Get-SuperBrainStableHash ([string]$Instruction) 64
}

function Invoke-ContractDecisionBinding([string]$Mode,[object]$Contract,[string]$CandidateStage,[string]$CandidateIntent,[int]$CandidateRevision,[object]$CandidatePlan) {
  if ([string]::IsNullOrWhiteSpace($CandidateStage)) { return [pscustomobject]@{ ok=$true; status='not_required'; code='DECISION_BINDING_NOT_REQUIRED'; binding=$null } }
  $bindingScript = Join-Path $PSScriptRoot 'decision-binding.ps1'
  if (-not (Test-Path -LiteralPath $bindingScript -PathType Leaf)) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_SCRIPT_MISSING'; binding=$null } }
  $taskInstance = if ($Contract -and $Contract.PSObject.Properties['taskInstanceId']) { [string]$Contract.taskInstanceId } else { '' }
  if ([string]::IsNullOrWhiteSpace($taskInstance) -or $taskInstance -notmatch '^ti-[a-f0-9]{32}$') { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_TASK_INSTANCE_REQUIRED'; binding=$null } }
  $planFingerprint = if ($CandidatePlan -and $CandidatePlan.PSObject.Properties['planFingerprint']) { [string]$CandidatePlan.planFingerprint } else { '' }
  if ([string]::IsNullOrWhiteSpace($planFingerprint)) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_PLAN_FINGERPRINT_REQUIRED'; binding=$null } }
  $args = @{
    Action = $Mode
    TaskId = $TaskId
    TaskInstanceId = $taskInstance
    WorkspaceKey = $WorkspaceKey
    WorklineId = if ($Contract -and $Contract.PSObject.Properties['focusId']) { [string]$Contract.focusId } else { '' }
    StageKind = $CandidateStage
    IntentFingerprint = $CandidateIntent
    ContractRevision = $CandidateRevision
    PlanFingerprint = $planFingerprint
    OwnerSessionKey = if ($Contract -and $Contract.PSObject.Properties['ownerSessionKey']) { [string]$Contract.ownerSessionKey } else { '' }
    StateRoot = $memoryBase
    NoExit = $true
    Json = $true
  }
  if ($Mode -eq 'ValidateReceipt') {
    if (-not $Contract.PSObject.Properties['decisionBinding'] -or -not $Contract.decisionBinding) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_MISSING'; binding=$null } }
    $args.ReceiptPath = [string]$Contract.decisionBinding.path
  }
  try {
    $raw = @(& $bindingScript @args 2>&1)
    $value = ConvertFrom-SuperBrainJsonOutput ($raw -join "`n") ('execution contract decision binding ' + $Mode)
    if (-not $value) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_EMPTY_RESULT'; binding=$null } }
    if ($Mode -eq 'Resolve') {
      $receiptSchema = if($value.PSObject.Properties['schema']){[string]$value.schema}else{''}
      $receiptId = if($value.PSObject.Properties['receiptId']){[string]$value.receiptId}else{''}
      $packageManifestHash = if($value.PSObject.Properties['packageManifestHash']){[string]$value.packageManifestHash}else{''}
      $metadataCurrent = ($receiptSchema -ne 'super-brain.decision-resolution-receipt.v2' -or (-not [string]::IsNullOrWhiteSpace($receiptId) -and $packageManifestHash -match '^[a-f0-9]{64}$'))
      $binding = [pscustomobject]@{ status=[string]$value.status; receiptSchema=$receiptSchema; receiptId=$receiptId; bindingDigest=[string]$value.bindingDigest; path=[string]$value.path; decisionCount=@($value.decisions).Count; stageKind=$CandidateStage; intentFingerprint=$CandidateIntent; contractRevision=$CandidateRevision; planFingerprint=$planFingerprint; packageVersion=[string]$manifest.version; packageManifestHash=$packageManifestHash; rawDecisionBodyStored=$false }
      return [pscustomobject]@{ ok=($value.ok -eq $true -and [string]$value.status -in @('bound','none_applicable') -and $metadataCurrent); status=[string]$value.status; code=if($metadataCurrent){if($value.code){[string]$value.code}else{'DECISION_BINDING_RESOLVED'}}else{'DECISION_BINDING_RECEIPT_INTEGRITY_METADATA_MISSING'}; binding=$binding; reasons=@($value.reasons) }
    }
    $storedBinding = if($Contract.PSObject.Properties['decisionBinding']){$Contract.decisionBinding}else{$null}
    $receiptSchema = if($storedBinding -and $storedBinding.PSObject.Properties['receiptSchema']){[string]$storedBinding.receiptSchema}elseif($value.PSObject.Properties['schema']){[string]$value.schema}else{''}
    $storedReceiptId = if($storedBinding -and $storedBinding.PSObject.Properties['receiptId']){[string]$storedBinding.receiptId}else{''}
    $storedPackageManifestHash = if($storedBinding -and $storedBinding.PSObject.Properties['packageManifestHash']){[string]$storedBinding.packageManifestHash}else{''}
    $currentReceiptId = if($value.PSObject.Properties['receiptId']){[string]$value.receiptId}else{''}
    $currentPackageManifestHash = if($value.PSObject.Properties['packageManifestHash']){[string]$value.packageManifestHash}else{''}
    $metadataCurrent = ($receiptSchema -ne 'super-brain.decision-resolution-receipt.v2' -or (([string]::IsNullOrWhiteSpace($storedReceiptId) -and [string]::IsNullOrWhiteSpace($storedPackageManifestHash)) -or ($storedReceiptId -eq $currentReceiptId -and $storedPackageManifestHash -eq $currentPackageManifestHash)))
    $binding = [pscustomobject]@{ status=[string]$value.status; receiptSchema=$receiptSchema; receiptId=$storedReceiptId; bindingDigest=[string]$value.bindingDigest; path=if($storedBinding){[string]$storedBinding.path}else{''}; decisionCount=if($storedBinding){[int]$storedBinding.decisionCount}else{0}; stageKind=$CandidateStage; intentFingerprint=$CandidateIntent; contractRevision=$CandidateRevision; planFingerprint=$planFingerprint; packageVersion=[string]$manifest.version; packageManifestHash=$storedPackageManifestHash; rawDecisionBodyStored=$false }
    return [pscustomobject]@{ ok=($value.ok -eq $true -and [string]$value.status -in @('bound','none_applicable') -and [string]$value.bindingDigest -eq [string]$binding.bindingDigest -and $metadataCurrent); status=[string]$value.status; code=if($metadataCurrent){[string]$value.code}else{'DECISION_BINDING_RECEIPT_INTEGRITY_METADATA_STALE'}; binding=$binding; reasons=@($value.reasons) }
  } catch {
    return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RUNTIME_FAILED'; binding=$null; reasons=@(Limit-ContractText $_.Exception.Message 180) }
  }
}

function Get-ContractDecisionBindingStatus([object]$Contract) {
  $stage = if ($Contract -and $Contract.PSObject.Properties['stageKind']) { [string]$Contract.stageKind } else { '' }
  if ([string]::IsNullOrWhiteSpace($stage)) { return [pscustomobject]@{ required=$false; current=$true; code='DECISION_BINDING_NOT_REQUIRED'; binding=$null } }
  $intent = if ($Contract.PSObject.Properties['decisionIntentFingerprint']) { [string]$Contract.decisionIntentFingerprint } else { '' }
  $status = Invoke-ContractDecisionBinding 'ValidateReceipt' $Contract $stage $intent ([int]$Contract.revision) $Contract.planReceipt
  return [pscustomobject]@{ required=$true; current=[bool]$status.ok; code=[string]$status.code; status=[string]$status.status; binding=$status.binding; reasons=@($status.reasons) }
}

function Get-ContractPhaseEvidencePolicy([object]$Contract,[string]$Requested='auto',[bool]$RequestedBound=$false) {
  if ($RequestedBound) { return $Requested }
  if ($Contract -and $Contract.PSObject.Properties['phaseEvidencePolicy']) {
    $existing = [string]$Contract.phaseEvidencePolicy
    if ($existing -in @('h7_current','host_user_attested','user_authorized_synthetic')) { return $existing }
  }
  return 'h7_current'
}

function Get-ContractInstructionAnchorStatus([object]$Contract,[string]$Id,[string]$Key,[string]$OwnerSessionKey='') {
  $owner = if ($Contract -and $Contract.PSObject.Properties['ownerSessionKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Contract.ownerSessionKey)) { [string]$Contract.ownerSessionKey } elseif (-not [string]::IsNullOrWhiteSpace($OwnerSessionKey)) { $OwnerSessionKey } else { $SessionKey }
  if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($owner)) {
    return [pscustomobject]@{ok=$true;required=$false;current=$true;code='INSTRUCTION_ANCHOR_NOT_APPLICABLE';anchor=$null}
  }
  return Get-SuperBrainRuntimeWakeInstructionAnchorStatus $memoryBase $Key $owner $Contract $Id
}

function Resolve-ContractInstructionAnchorBinding(
  [object]$Existing,
  [string]$Id,
  [string]$Key,
  [string]$OwnerSessionKey,
  [string]$Instruction,
  [bool]$InstructionWasExplicit,
  [string]$SourceValue
) {
  $status = Get-ContractInstructionAnchorStatus $Existing $Id $Key $OwnerSessionKey
  if (-not $status.ok) {
    return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_RUNTIME_FAILED';anchor=$null;status=$status;guard='The authoritative latest-instruction anchor could not be read. Do not mutate from a stale contract.'}
  }
  if (-not $InstructionWasExplicit) {
    if ($status.required -and -not $status.current) {
      return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_RECONCILIATION_REQUIRED';anchor=$null;status=$status;guard='A newer user instruction exists outside this contract. Reconcile that anchor before any contract mutation.'}
    }
    $bound = if ($Existing -and $Existing.PSObject.Properties['instructionAnchor']) { $Existing.instructionAnchor } else { $null }
    return [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_CURRENT';anchor=$bound;status=$status}
  }
  $protected = Protect-Instruction $Instruction
  if ([string]::IsNullOrWhiteSpace($protected)) {
    return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_EMPTY';anchor=$null;status=$status;guard='An explicit latest instruction must contain a bounded, redacted value.'}
  }
  if ($status.required -and $status.anchor -and [string]$status.anchor.instruction -eq $protected) {
    return [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_BOUND';anchor=$status.anchor;status=$status}
  }
  $classification = [pscustomobject]@{
    mode='explicit_reconciliation';topicAffinity='active';targetLineId=if($Existing){[string]$Existing.focusId}else{''};targetLineLabel=if($Existing -and $Existing.PSObject.Properties['focusLabel']){[string]$Existing.focusLabel}else{''};confidence='high';matchedKeys=@('explicit_latest_instruction');candidateLineIds=@();needsClarification=$false
  }
  $boundAnchor = if ($Existing -and $Existing.PSObject.Properties['instructionAnchor']) { $Existing.instructionAnchor } else { $null }
  $observed = Invoke-SuperBrainRuntimeWakeAnchorControl 'observe-instruction-anchor' $memoryBase @{
    taskId=$Id
    workspaceKey=$Key
    ownerSessionKey=$OwnerSessionKey
    instruction=$protected
    classification=$classification
    signals=@{ deferredMergeRequested=(Test-SuperBrainRuntimeWakeDeferredMergeSignal $protected) }
    source=(Limit-ContractText $SourceValue 120)
    preserveIfPending=$false
    boundAnchor=$boundAnchor
  }
  if (-not $observed.ok -or -not $observed.anchor) {
    return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_WRITE_FAILED';anchor=$null;status=$observed;guard='The newest instruction anchor was not durably recorded, so the execution contract was not changed.'}
  }
  return [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_BOUND';anchor=$observed.anchor;status=$observed}
}

function Test-ContractInstructionAnchorActionAffinity(
  [string]$Instruction,
  [string]$FocusId,
  [string]$FocusLabel,
  [string]$NextAction,
  [string]$AssistantCommitment
) {
  $instructionText = Normalize-TopicMatchText $Instruction
  if ([string]::IsNullOrWhiteSpace($instructionText)) { return $false }
  $instructionFlat = $instructionText -replace ' ',''
  $ignored = @('also','this','that','with','from','into','then','than','check','need','needs','task','work','line','branch','continue','finish','please','about','after','before','current','new','old','user','the','and','for','you','are','not')
  $instructionTerms = @($instructionText -split '\s+' | Where-Object { $_.Length -ge 4 -and $_ -notin $ignored } | Select-Object -Unique)
  foreach ($candidate in @($FocusId,$FocusLabel,$NextAction,$AssistantCommitment)) {
    $candidateText = Normalize-TopicMatchText ([string]$candidate)
    if ([string]::IsNullOrWhiteSpace($candidateText)) { continue }
    $candidateFlat = $candidateText -replace ' ',''
    foreach ($term in @($candidateText -split '\s+' | Where-Object { $_.Length -ge 4 -and $_ -notin $ignored } | Select-Object -Unique)) {
      if ($instructionTerms -contains $term) { return $true }
    }
    foreach ($match in [regex]::Matches($candidateFlat,'[\u4e00-\u9fff]{2,}')) {
      if ($instructionFlat.Contains([string]$match.Value)) { return $true }
    }
  }
  return $false
}

function Test-ContractInstructionAnchorMapping(
  [object]$Anchor,
  [string]$Mode,
  [string]$FocusId,
  [string]$FocusLabel,
  [string]$NextAction,
  [string]$AssistantCommitment
) {
  if (-not $Anchor -or [string]::IsNullOrWhiteSpace([string]$Anchor.instruction)) { return $false }
  $targetLineId = if ($Anchor.PSObject.Properties['classification'] -and $Anchor.classification -and $Anchor.classification.PSObject.Properties['targetLineId']) { [string]$Anchor.classification.targetLineId } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($targetLineId) -and $targetLineId -eq $FocusId) { return $true }
  if ($Mode -eq 'replace' -and (Test-ExplicitChecklistScopeReplacement ([string]$Anchor.instruction))) { return $true }
  if ($Mode -in @('continue','side_branch')) {
    return (Test-ContractInstructionAnchorActionAffinity ([string]$Anchor.instruction) $FocusId $FocusLabel $NextAction $AssistantCommitment)
  }
  return $false
}

function Set-Contract([switch]$ObserveOnly,[object]$PackageVersionRebindPayload=$null) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  if ($PackageVersionRebindPayload) {
    # Keep the rebind's preserved state local to this Set invocation.  Script
    # parameter variables are not safe mutation targets from a nested helper.
    $LastConfirmedSentence = [string]$PackageVersionRebindPayload.lastConfirmedSentence
    $LastConfirmedSource = [string]$PackageVersionRebindPayload.lastConfirmedSource
    $CurrentPhase = [string]$PackageVersionRebindPayload.currentPhase
    $CurrentStep = [string]$PackageVersionRebindPayload.currentStep
    $NextAction = [string]$PackageVersionRebindPayload.nextAction
    $Source = [string]$PackageVersionRebindPayload.source
    $ProjectProgressProofBase64 = [string]$PackageVersionRebindPayload.projectProgressProofBase64
  }
  $contractPath = Get-ContractPath $TaskId $WorkspaceKey
  return Invoke-SuperBrainFileLock $contractPath {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    if ($record.identityConflict) { throw 'EXECUTION_CONTRACT_IDENTITY_MISMATCH' }
    $existing = $record.contract
    $existingSessionKey = Get-ContractSessionKey $existing
    $intentContractInput = $null
    if ($script:IntentContractJsonWasBound) {
      $parsedIntentContract = ConvertTo-IntentResolutionContract $IntentContractJson -RequireCurrentSchema
      if (-not $parsedIntentContract.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$parsedIntentContract.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($parsedIntentContract.missing); guard='A task-level intent contract must be compact, complete, and preserve the requested capability through a governed implementation.' }
      }
      $intentContractInput = $parsedIntentContract.intentContract
    }
    $existingIntentContract = if ($existing -and $existing.PSObject.Properties['intentContract']) { $existing.intentContract } else { $null }
    $existingIntentRequired = [bool]($existing -and $existing.PSObject.Properties['intentContractRequired'] -and $existing.intentContractRequired -eq $true)
    $intentContractRequiredRequested = (-not $ObserveOnly -and ($script:RequireIntentContractWasBound -or $existingIntentRequired -or $null -ne $intentContractInput))
    if ($intentContractRequiredRequested -and $null -eq $intentContractInput -and $null -eq $existingIntentContract) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_CONTRACT_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@('IntentContractJson'); guard='Structural product work requires a task-scoped intent contract before it can receive an executable receipt.' }
    }
    if ($ObserveOnly) {
      if ([string]::IsNullOrWhiteSpace($SessionKey)) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Automatic user-prompt observation requires a root Codex session identity.' }
      }
      if ([string]::IsNullOrWhiteSpace($existingSessionKey)) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_UNBOUND'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='This legacy contract has no root-session owner. Explicitly Set it with RebindSession before automatic prompt observation.' }
      }
      if (-not (Test-ContractSessionKey $existing $SessionKey)) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_FOREIGN_SESSION'; taskId=$TaskId; workspaceKey=$WorkspaceKey; ownerSessionKey=$existingSessionKey; requestedSessionKey=$SessionKey; guard='A different Codex root session owns this execution contract; automatic prompt observation was ignored.' }
      }
    }
    if (-not $ObserveOnly -and -not $existing -and [string]::IsNullOrWhiteSpace($SessionKey) -and -not $RebindSession) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Creating an execution contract requires a root Codex session identity.' }
    }
    if (-not $ObserveOnly -and $existing -and [string]::IsNullOrWhiteSpace($existingSessionKey) -and -not $RebindSession) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; requestedSessionKey=$SessionKey; guard='This legacy contract is unbound. Use RebindSession with a concrete root session identity before updating it.' }
    }
    if (-not $ObserveOnly -and $existing -and -not [string]::IsNullOrWhiteSpace($existingSessionKey) -and [string]::IsNullOrWhiteSpace($SessionKey) -and -not $RebindSession) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; ownerSessionKey=$existingSessionKey; guard='Updating a bound execution contract requires its owning root Codex session identity.' }
    }
    if (-not $ObserveOnly -and $existing -and -not [string]::IsNullOrWhiteSpace($existingSessionKey) -and -not [string]::IsNullOrWhiteSpace($SessionKey) -and -not (Test-ContractSessionKey $existing $SessionKey) -and -not $RebindSession) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; ownerSessionKey=$existingSessionKey; requestedSessionKey=$SessionKey; guard='A different Codex root session owns this contract. Use RebindSession only after explicit continuity recovery.' }
    }
    if ($RebindSession -and [string]::IsNullOrWhiteSpace($SessionKey)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_SESSION_REBIND_KEY_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='RebindSession requires a concrete root session identity.' }
    }
    if ($ObserveOnly) {
      if (-not $existing) {
        return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_NOT_FOUND';taskId=$TaskId;workspaceKey=$WorkspaceKey;guard='Automatic prompt observation requires an active task-scoped contract.'}
      }
      if (Test-SuperBrainRuntimeWakePendingInstructionPreserved $existing $UserInstruction) {
        $existing | Add-Member -NotePropertyName observationSkipped -NotePropertyValue $true -Force
        $existing | Add-Member -NotePropertyName observationCode -NotePropertyValue 'EXECUTION_CONTRACT_PENDING_INSTRUCTION_PRESERVED' -Force
        return $existing
      }
      $classification = Get-TopicClassification $UserInstruction ([string]$existing.focusId) $(if($existing.PSObject.Properties['focusLabel']){[string]$existing.focusLabel}else{''}) $(if($existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@()}) $(if($existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}) $(if($existing.PSObject.Properties['returnStack']){@($existing.returnStack)}else{@()}) $(if($existing.PSObject.Properties['unfinishedWorkPlans']){@($existing.unfinishedWorkPlans)}else{@()}) $(if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}else{''}) $(if($existing.PSObject.Properties['nextAction']){[string]$existing.nextAction}else{''}) $(if($existing.PSObject.Properties['assistantCommitment']){[string]$existing.assistantCommitment}else{''}) $(if($existing.PSObject.Properties['mergeIntents']){@($existing.mergeIntents)}else{@()})
      $observedAnchor = Invoke-SuperBrainRuntimeWakeInstructionAnchorObservation $memoryBase $WorkspaceKey $SessionKey $existing $UserInstruction $classification $(if([string]::IsNullOrWhiteSpace($Source)){'execution-contract.ps1:ObserveUser'}else{$Source}) -RequireCanonicalPlanSource:$RequireCanonicalPlanSource
      if (-not $observedAnchor.ok -or -not $observedAnchor.anchor) {
        return [pscustomobject]@{ok=$false;code=if($observedAnchor.code){[string]$observedAnchor.code}else{'EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_WRITE_FAILED'};taskId=$TaskId;workspaceKey=$WorkspaceKey;guard='Prompt observation did not durably record the latest instruction anchor; the contract was left unchanged.'}
      }
      $view = $existing | Select-Object *
      $view | Add-Member -NotePropertyName instructionAnchor -NotePropertyValue $observedAnchor.anchor -Force
      $view | Add-Member -NotePropertyName latestUserInstruction -NotePropertyValue ([string]$observedAnchor.anchor.instruction) -Force
      $view | Add-Member -NotePropertyName latestMessageClassification -NotePropertyValue $(if($observedAnchor.anchor.classification){$observedAnchor.anchor.classification}else{$classification}) -Force
      $view | Add-Member -NotePropertyName needsReconciliation -NotePropertyValue ([bool]$observedAnchor.pending) -Force
      $view | Add-Member -NotePropertyName observationSkipped -NotePropertyValue ([bool]$observedAnchor.preservedPending) -Force
      $view | Add-Member -NotePropertyName observationCode -NotePropertyValue $(if($observedAnchor.created){'EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_APPENDED'}else{'EXECUTION_CONTRACT_PENDING_INSTRUCTION_PRESERVED'}) -Force
      $view | Add-Member -NotePropertyName canonicalPlanSourceRequired -NotePropertyValue ([bool](($existing.PSObject.Properties['canonicalPlanSourceRequired'] -and $existing.canonicalPlanSourceRequired -eq $true) -or (Test-InstructionAnchorCanonicalPlanSourceRequirement $observedAnchor.anchor))) -Force
      $view | Add-Member -NotePropertyName rawPromptStored -NotePropertyValue $false -Force
      $view | Add-Member -NotePropertyName rawTranscriptStored -NotePropertyValue $false -Force
      $view | Add-Member -NotePropertyName rawSessionIdStored -NotePropertyValue $false -Force
      return $view
    }
    $canonicalMutationRecord = $null
    if ($script:CanonicalMutationPathWasBound) {
      if ($ObserveOnly) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_OBSERVE_FORBIDDEN'; taskId=$TaskId; workspaceKey=$WorkspaceKey } }
      $canonicalMutationRecord = Read-CanonicalMutationEnvelope $CanonicalMutationPath
      if (-not $canonicalMutationRecord.ok) { return $canonicalMutationRecord }
    }
    $canonicalSourceManifestRecord = $null
    if ($script:CanonicalSourceManifestPathWasBound) {
      if ($ObserveOnly) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_OBSERVE_FORBIDDEN'; taskId=$TaskId; workspaceKey=$WorkspaceKey } }
      $canonicalSourceManifestRecord = Read-CanonicalPlanSourceManifest $CanonicalSourceManifestPath
      if (-not $canonicalSourceManifestRecord.ok) { return $canonicalSourceManifestRecord }
    }
    if ($ObserveOnly -and $script:PhaseCloseoutPathWasBound) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PHASE_CLOSEOUT_OBSERVE_FORBIDDEN'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Prompt observation cannot attach execution evidence or advance a phase.' }
    }
    if ($ObserveOnly -and $script:PhaseEvidencePolicyWasBound) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PHASE_EVIDENCE_POLICY_OBSERVE_FORBIDDEN'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Prompt observation cannot weaken or replace the task-bound phase-evidence policy.' }
    }
    $phaseEvidencePolicyValue = Get-ContractPhaseEvidencePolicy $existing $PhaseEvidencePolicy $script:PhaseEvidencePolicyWasBound
    # A pre-H7 contract can still carry a retired P7 evidence policy.  It
    # must never continue to use that policy, but a current H7 checkpoint
    # needs one narrow migration route to bind fresh project proof and replace
    # it.  Require the exact H7 writer source plus both bounded transports;
    # ordinary Set calls and legacy receipts remain fail-closed below.
    $h7ProofPolicyMigration = (
      (Test-SuperBrainRetiredPhaseEvidencePolicy $phaseEvidencePolicyValue) -and
      -not $script:PhaseEvidencePolicyWasBound -and
      $script:ProgressCheckpointBase64WasBound -and
      $script:ProjectProgressProofBase64WasBound -and
      [string]$Source -eq 'turn-runtime:assistant-progress-checkpoint'
    )
    if ($h7ProofPolicyMigration) { $phaseEvidencePolicyValue = 'h7_current' }
    if (Test-SuperBrainRetiredPhaseEvidencePolicy $phaseEvidencePolicyValue) {
      return [pscustomobject]@{
        ok=$false; code='EXECUTION_CONTRACT_PHASE_EVIDENCE_POLICY_RETIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey
        guard='UserPromptSubmit, prompt-hook telemetry, P7, and synthetic Hook evidence are retired for formal phase transitions. Bind h7_current evidence instead.'
      }
    }
    if ($phaseEvidencePolicyValue -ne 'h7_current') {
      return [pscustomobject]@{
        ok=$false; code='EXECUTION_CONTRACT_PHASE_EVIDENCE_POLICY_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey
        guard='Formal phase transitions require the h7_current evidence policy.'
      }
    }
    $phaseCloseoutInputHash = if ($script:PhaseCloseoutPathWasBound) { Get-SuperBrainPhaseCloseoutHash $PhaseCloseoutPath } else { '' }
    $transitionIdValue = if ($ObserveOnly) { '' } else { Limit-ContractText $TransitionId 120 }
    $setPayloadHash = if ([string]::IsNullOrWhiteSpace($transitionIdValue)) { '' } else { Get-TransitionPayloadHash ([ordered]@{
      action=if($script:PackageVersionRebindActive){'RebindPackageVersion'}else{'Set'}; taskId=$TaskId; workspaceKey=$WorkspaceKey; rebindSession=[bool]$RebindSession
      focusId=Limit-ContractText $FocusId 120; focusLabel=Limit-ContractText $FocusLabel 120; instructionMode=$InstructionMode; checklistUpdateMode=$ChecklistUpdateMode
      latestUserInstruction=Protect-Instruction $LatestUserInstruction; assistantCommitment=Limit-ContractText $AssistantCommitment 480
      lastConfirmedSentence=Limit-ContractText $LastConfirmedSentence 320; lastConfirmedSource=$LastConfirmedSource; nextAction=Limit-ContractText $NextAction 480
      currentPhase=Limit-ContractText $CurrentPhase 120; currentStep=Limit-ContractText $CurrentStep 220
      completedSteps=@(Limit-ContractList $CompletedSteps $script:ActiveChecklistMaxItems 180); pendingSteps=@(Limit-ContractList $PendingSteps $script:ActiveChecklistMaxItems 180)
      blockers=@(Limit-ContractList $Blockers 6 180); evidence=@(Limit-ContractList $Evidence 8 180); verificationResults=@(Limit-ContractList $VerificationResults 6 180)
      constraints=@(Limit-ContractList $Constraints 12 220); invalidatedWorkItems=@(Limit-ContractList $InvalidatedWorkItems 20 120); acceptanceCriteria=@(Limit-ContractList $AcceptanceCriteria 12 220)
      retainForMerge=[bool]$RetainForMerge; mergeTargetFocusId=Limit-ContractText $MergeTargetFocusId 120; mergeTargetLabel=Limit-ContractText $MergeTargetLabel 120; mergeTargetScope=$MergeTargetScope
      artifactRefs=@(Limit-MergeEvidenceList $ArtifactRefs 6 160); interfaceContracts=@(Limit-MergeEvidenceList $InterfaceContracts 5 160); dependencies=@(Limit-MergeEvidenceList $Dependencies 5 140)
      verificationSteps=@(Limit-MergeEvidenceList $VerificationSteps 6 140); mergeConditions=@(Limit-MergeEvidenceList $MergeConditions 5 140)
      topicKeys=@(Limit-TopicKeys $TopicKeys); prioritySource=$PrioritySource; priorityReason=Limit-ContractText $PriorityReason 180
      enableCanonicalPlan=[bool]$EnableCanonicalPlan; canonicalMutationHash=if($canonicalMutationRecord){[string]$canonicalMutationRecord.contentHash}else{''}
      requireCanonicalPlanSource=[bool]$RequireCanonicalPlanSource; canonicalSourceManifestHash=if($canonicalSourceManifestRecord){[string]$canonicalSourceManifestRecord.manifestSha256}else{''}
      requiresReconciliation=[bool]$RequiresReconciliation
      requireIntentContract=[bool]$RequireIntentContract; intentContractFingerprint=if($intentContractInput){[string]$intentContractInput.contractFingerprint}else{''}
      projectProgressInputHash=if($script:ProjectProgressProofBase64WasBound){Get-SuperBrainStableHash $ProjectProgressProofBase64 64}else{''}; projectRootHash=if($script:ProjectRootWasBound){[string](Get-ProjectProgressRootBinding $ProjectRoot).rootHash}else{''}
      stageKind=$StageKind; decisionIntentFingerprint=Limit-ContractText $DecisionIntentFingerprint 128; phaseCloseoutHash=$phaseCloseoutInputHash; phaseEvidencePolicy=$phaseEvidencePolicyValue
    }) }
    $transitionReceipts = @(Limit-TransitionReceipts $(if($existing -and $existing.PSObject.Properties['transitionReceipts']){@($existing.transitionReceipts)}else{@()}))
    if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) {
      $receipt = Get-TransitionReceipt $existing $transitionIdValue
      if ($receipt) {
        if ([string]$receipt.action -ne 'Set' -or [string]$receipt.payloadHash -ne $setPayloadHash) {
          return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'; taskId=$TaskId; transitionId=$transitionIdValue; expectedAction=[string]$receipt.action; expectedPayloadHash=[string]$receipt.payloadHash; actualAction='Set'; actualPayloadHash=$setPayloadHash; guard='The transition id is already bound to a different operation or payload.' }
        }
        $replay = New-TransitionReplayResult $existing $receipt
        if ($ObserveOnly) { return $replay }
        return Complete-ContractContinuityMutation $replay 'SetReplay'
      }
    }
    if (-not $ObserveOnly -and $existing -and $ExpectedRevision -ge 0 -and [int]$existing.revision -ne $ExpectedRevision) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_REVISION_MISMATCH'; taskId=$TaskId; expectedRevision=$ExpectedRevision; actualRevision=[int]$existing.revision; guard='The execution contract changed after the caller observed it. Resolve the current contract before applying Set.' }
    }
    if (-not $ObserveOnly -and $existing -and -not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
      $actualPlanFingerprint = if ($existing.PSObject.Properties['planReceipt'] -and $existing.planReceipt) { [string]$existing.planReceipt.planFingerprint } else { '' }
      if ($actualPlanFingerprint -ne [string]$ExpectedPlanFingerprint) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH'; taskId=$TaskId; expectedPlanFingerprint=$ExpectedPlanFingerprint; actualPlanFingerprint=$actualPlanFingerprint; guard='The accepted plan changed after the caller observed it. Resolve the current contract before applying Set.' }
      }
    }
    $existingCanonicalPlan = $null
    if ($existing -and $existing.PSObject.Properties['canonicalPlan'] -and $existing.canonicalPlan) {
      $canonicalState = Test-CanonicalPlanState $existing.canonicalPlan
      if (-not $canonicalState.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$canonicalState.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The stored canonical plan is malformed or its fingerprint does not match. Reconcile it before any contract mutation.' }
      }
      $existingCanonicalPlan = $canonicalState.plan
    }
    if ($canonicalMutationRecord -and -not $existingCanonicalPlan) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A canonical mutation cannot run before an explicitly guarded canonical plan exists.' }
    }
    $ownerSessionKey = if ($RebindSession -and -not [string]::IsNullOrWhiteSpace($SessionKey)) { $SessionKey } elseif (-not [string]::IsNullOrWhiteSpace($existingSessionKey)) { $existingSessionKey } else { $SessionKey }
    $revision = if ($existing -and $existing.PSObject.Properties['revision']) { [int]$existing.revision + 1 } else { 1 }
    $taskInstanceIdValue = if($existing -and $existing.PSObject.Properties['taskInstanceId'] -and [string]$existing.taskInstanceId -match '^ti-[a-f0-9]{32}$'){[string]$existing.taskInstanceId}else{'ti-'+[guid]::NewGuid().ToString('n')}
    $intentContractRequiredValue = if ($ObserveOnly) { [bool]$existingIntentRequired } else { [bool]$intentContractRequiredRequested }
    $intentPreparedValue = $null
    $intentContractValue = if ($ObserveOnly) { $existingIntentContract } else { $null }
    $intentRevisionValue = if ($existing -and $existing.PSObject.Properties['intentRevision']) { [int]$existing.intentRevision } else { 0 }
    $intentAggregateIdValue = if ($existing -and $existing.PSObject.Properties['intentAggregateId']) { [string]$existing.intentAggregateId } else { '' }
    $intentSessionRebindReceiptValue = if ($existing -and $existing.PSObject.Properties['intentSessionRebindReceipt']) { $existing.intentSessionRebindReceipt } else { $null }
    $taskSessionRebindReceiptValue = if ($existing -and $existing.PSObject.Properties['taskSessionRebindReceipt']) { $existing.taskSessionRebindReceipt } else { $null }
    if ($RebindSession) {
      # A receipt authorizes exactly one prior-owner -> next-owner transition.
      # Do not carry an old receipt into a different explicit handoff.
      $intentSessionRebindReceiptValue = $null
      $taskSessionRebindReceiptValue = $null
    }
    if (-not $ObserveOnly -and $intentContractRequiredValue) {
      $intentCandidate = if ($intentContractInput) { $intentContractInput } else { $existingIntentContract }
      $requiresIntentSessionRebind = $RebindSession -and $existing -and -not [string]::IsNullOrWhiteSpace($existingSessionKey) -and -not [string]::Equals($existingSessionKey,$ownerSessionKey,[StringComparison]::OrdinalIgnoreCase)
      if ($requiresIntentSessionRebind) {
        $priorReceipt = if ($existing.PSObject.Properties['intentResolutionReceipt']) { $existing.intentResolutionReceipt } else { $null }
        $intentSessionRebind = Rebind-IntentResolution $TaskId $taskInstanceIdValue $WorkspaceKey $existingSessionKey $ownerSessionKey $intentRevisionValue $priorReceipt 'execution-contract.ps1:RebindSession'
        if (-not $intentSessionRebind.ok) {
          return [pscustomobject]@{ ok=$false; code=[string]$intentSessionRebind.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentSessionRebind.missing); guard='A cross-session continuation must rebind the immutable intent receipt before the original task can resume.' }
        }
        $intentSessionRebindReceiptValue = $intentSessionRebind.receipt
      }
      $intentPreparedValue = Prepare-IntentResolution $TaskId $taskInstanceIdValue $WorkspaceKey $ownerSessionKey $intentCandidate
      if (-not $intentPreparedValue.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$intentPreparedValue.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentPreparedValue.missing); guard='A required product intent must be normalized by the canonical local control plane before the plan can authorize work.' }
      }
      $intentContractValue = $intentPreparedValue.intentContract
      $intentRevisionValue = [int]$intentPreparedValue.intentRevision
      $intentAggregateIdValue = [string]$intentPreparedValue.aggregateId
    }
    $intentPlanBindingValue = if ($intentContractRequiredValue -and $intentRevisionValue -gt 0 -and $intentContractValue -and [string]$intentContractValue.contractFingerprint -match '^[a-f0-9]{64}$') {
      [pscustomobject]@{ intentRevision=$intentRevisionValue; intentContractFingerprint=[string]$intentContractValue.contractFingerprint }
    } else { $null }
    $oldFocus = if ($existing) { [string]$existing.focusId } else { '' }
    $newFocus = if ($ObserveOnly) { $oldFocus } elseif (-not [string]::IsNullOrWhiteSpace($FocusId)) { Limit-ContractText $FocusId 120 } else { $oldFocus }
    $focusChanged = (-not [string]::IsNullOrWhiteSpace($oldFocus) -and -not [string]::IsNullOrWhiteSpace($newFocus) -and $newFocus -ne $oldFocus)
    $mode = if ($ObserveOnly) { if ($existing -and $existing.PSObject.Properties['instructionMode']) { [string]$existing.instructionMode } else { 'continue' } } elseif ($InstructionMode -eq 'auto') { if ($focusChanged) { 'side_branch' } else { 'continue' } } else { $InstructionMode }
    $initialInstructionBinding = (-not $ObserveOnly -and -not $existing -and $script:LatestUserInstructionWasBound -and $script:FocusIdWasBound -and -not [string]::IsNullOrWhiteSpace($FocusId) -and $script:NextActionWasBound -and -not [string]::IsNullOrWhiteSpace($NextAction) -and -not [string]::IsNullOrWhiteSpace($newFocus))
    $explicitInstructionReconciliation = $initialInstructionBinding -or (-not $ObserveOnly -and ($script:InstructionModeWasBound -or $RebindSession) -and $script:FocusIdWasBound -and -not [string]::IsNullOrWhiteSpace($FocusId) -and $script:NextActionWasBound -and -not [string]::IsNullOrWhiteSpace($NextAction) -and -not [string]::IsNullOrWhiteSpace($newFocus))
    $reconciliationRequested = $script:RequiresReconciliationWasBound
    $instructionAnchorStatusBeforeSet = if (-not $ObserveOnly -and $existing) { Get-ContractInstructionAnchorStatus $existing $TaskId $WorkspaceKey $ownerSessionKey } else { $null }
    $instructionAnchorReconciliationPending = ($instructionAnchorStatusBeforeSet -and $instructionAnchorStatusBeforeSet.required -and -not $instructionAnchorStatusBeforeSet.current)
    $emptyExplicitReconciliationMapping = (-not $ObserveOnly -and $script:InstructionModeWasBound -and $script:FocusIdWasBound -and [string]::IsNullOrWhiteSpace($FocusId) -and $script:NextActionWasBound -and [string]::IsNullOrWhiteSpace($NextAction))
    if ($existing -and $instructionAnchorReconciliationPending -and $emptyExplicitReconciliationMapping) {
      # Empty mapping values are not authorization. Preserve the pending anchor
      # as a no-op projection so callers can safely learn that reconciliation
      # still remains required without mutating or clearing the task state.
      $view = $existing | Select-Object *
      $view | Add-Member -NotePropertyName ok -NotePropertyValue $true -Force
      $view | Add-Member -NotePropertyName needsReconciliation -NotePropertyValue $true -Force
      $view | Add-Member -NotePropertyName instructionAnchor -NotePropertyValue $instructionAnchorStatusBeforeSet.anchor -Force
      $view | Add-Member -NotePropertyName latestUserInstruction -NotePropertyValue $(if($instructionAnchorStatusBeforeSet.anchor){[string]$instructionAnchorStatusBeforeSet.anchor.instruction}else{[string]$existing.latestUserInstruction}) -Force
      $view | Add-Member -NotePropertyName latestMessageClassification -NotePropertyValue $(if($instructionAnchorStatusBeforeSet.anchor -and $instructionAnchorStatusBeforeSet.anchor.classification){$instructionAnchorStatusBeforeSet.anchor.classification}else{$existing.latestMessageClassification}) -Force
      $view | Add-Member -NotePropertyName mutationApplied -NotePropertyValue $false -Force
      $view | Add-Member -NotePropertyName guard -NotePropertyValue 'Empty focus/action values cannot reconcile a newer instruction anchor; no contract mutation was applied.' -Force
      return $view
    }
    # A controlled executor may consume a pending instruction only when the
    # caller supplies an explicit work-line mapping and that mapping either
    # matches the anchor's target, carries an explicit replacement, or has a
    # concrete action affinity. Everything else remains fail-closed.
    $anchorBackedReconciliation = $false
    if ($explicitInstructionReconciliation -and $instructionAnchorReconciliationPending -and $instructionAnchorStatusBeforeSet.anchor -and -not [string]::IsNullOrWhiteSpace([string]$instructionAnchorStatusBeforeSet.anchor.instruction)) {
      $anchorBackedReconciliation = Test-ContractInstructionAnchorMapping $instructionAnchorStatusBeforeSet.anchor $mode $newFocus $FocusLabel $NextAction $AssistantCommitment
    }
    $pendingInstructionObservation = ($script:LatestUserInstructionWasBound -and -not $explicitInstructionReconciliation -and -not $anchorBackedReconciliation)
    $reconciliationCleared = ($existing -and $existing.needsReconciliation -eq $true -and ($explicitInstructionReconciliation -or $anchorBackedReconciliation))
    if (-not $ObserveOnly -and $existingCanonicalPlan -and $mode -eq 'replace' -and $focusChanged -and (-not $canonicalMutationRecord -or [string]$canonicalMutationRecord.envelope.operation -ne 'replace_canonical')) {
      return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_REPLACEMENT_REQUIRED';taskId=$TaskId;workspaceKey=$WorkspaceKey;currentFocusId=$oldFocus;proposedFocusId=$newFocus;guard='Replacing the canonical root requires a replace_canonical mutation envelope bound to the current plan and instruction.'}
    }
    $structuralSet = (-not $ObserveOnly -and $existing -and ($focusChanged -or $mode -in @('side_branch','replace') -or $ChecklistUpdateMode -eq 'replace' -or $RebindSession -or $script:EnableCanonicalPlanWasBound -or $script:CanonicalMutationPathWasBound -or $script:CanonicalSourceManifestPathWasBound -or $script:RequireCanonicalPlanSourceWasBound -or $reconciliationRequested -or $reconciliationCleared -or $instructionAnchorReconciliationPending))
    if ($structuralSet) {
      # A session-only intent handoff must preserve the original immutable
      # task even when its plan-source binding is stale. The stale binding
      # remains visible and continues to withhold execution after the handoff;
      # it must not prevent ownership recovery itself.
      $structuralFailure = Get-StructuralGuardFailure $existing 'Set' -Force:$RequireStructuralGuards -AllowIntentReceiptRefresh:($script:IntentContractJsonWasBound -or $reconciliationCleared -or $RebindSession) -AllowCanonicalSourceRefresh:($script:CanonicalSourceManifestPathWasBound -or $RebindSession)
      if ($structuralFailure) { return $structuralFailure }
    }
    $invalidated = @($InvalidatedWorkItems)
    if ($existing) { $invalidated += @($existing.invalidatedWorkItems) }
    if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($newFocus)) {
      $invalidated = @($invalidated | Where-Object { [string]$_ -ne $newFocus })
    }
    # Keep single-item stacks as arrays; PowerShell's if-expression otherwise unwraps them.
    $stackIntegrity = Protect-ReturnStackIntegrity $(if($existing -and $existing.PSObject.Properties['returnStack']){@($existing.returnStack)}else{@()}) $TaskId $WorkspaceKey $oldFocus -UpgradeLegacy
    if (-not $stackIntegrity.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$stackIntegrity.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; currentFocusId=$oldFocus; reason=[string]$stackIntegrity.reason; guard='The stored parent path is malformed or its return-card fingerprint does not match. Reconcile or repair the task state before mutation.' }
    }
    $returnStack = @($stackIntegrity.cards)
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($existing -and $existing.PSObject.Properties['unfinishedWorkLines']) { @($existing.unfinishedWorkLines) } else { @() }) $(if ($existing -and $existing.PSObject.Properties['unfinishedWorkPlans']) { @($existing.unfinishedWorkPlans) } else { @() })
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $mergeIntents = @(Limit-MergeIntents $(if ($existing -and $existing.PSObject.Properties['mergeIntents']) { @($existing.mergeIntents) } else { @() }))
    $resumePlan = if ($focusChanged) { @($unfinishedWorkPlans | Where-Object { [string]$_.focusId -eq $newFocus } | Select-Object -First 1) } else { @() }
    $resumePlan = if (@($resumePlan).Count -gt 0) { @($resumePlan)[0] } else { $null }
    if ($focusChanged) {
      $mergeIntents = @(Limit-MergeIntents @($mergeIntents | Where-Object { [string]$_.sourceFocusId -ne $newFocus }))
    }
    if (-not $ObserveOnly -and $focusChanged -and $mode -eq 'continue') {
      return [pscustomobject]@{
        ok = $false
        code = 'EXECUTION_CONTRACT_CONTINUE_FOCUS_MISMATCH'
        taskId = $TaskId
        currentFocusId = $oldFocus
        proposedFocusId = $newFocus
        directParentFocusId = if ($returnStack.Count -gt 0) { [string]$returnStack[-1].focusId } else { '' }
        guard = 'Continue must retain the active focus. Use side_branch for a new child, ResumeParent for the direct parent, or replace to supersede the hierarchy.'
      }
    }
    if (-not $ObserveOnly -and $focusChanged -and $mode -eq 'side_branch') {
      $ancestorMatch = @($returnStack | Where-Object { [string]$_.focusId -eq $newFocus })
      if ($ancestorMatch.Count -gt 0) {
        return [pscustomobject]@{
          ok = $false
          code = 'EXECUTION_CONTRACT_ANCESTOR_REENTRY_REQUIRES_RESUME'
          taskId = $TaskId
          currentFocusId = $oldFocus
          proposedFocusId = $newFocus
          directParentFocusId = if ($returnStack.Count -gt 0) { [string]$returnStack[-1].focusId } else { '' }
          guard = 'An ancestor cannot be opened again as a child branch. Complete the current branch and resume one direct parent at a time.'
        }
      }
      if ($returnStack.Count -ge $script:ReturnStackMaxDepth) {
        return [pscustomobject]@{
          ok = $false
          code = 'EXECUTION_CONTRACT_RETURN_STACK_FULL'
          taskId = $TaskId
          currentFocusId = $oldFocus
          proposedFocusId = $newFocus
          maxReturnStackDepth = $script:ReturnStackMaxDepth
          returnStack = @($returnStack)
          returnTo = if ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
          guard = 'The bounded return stack is full. Resume or explicitly replace a parent before starting another side branch.'
        }
      }
      $returnStack = @($returnStack + @(ConvertTo-ReturnCard ([pscustomobject]@{
        focusId=$oldFocus
        focusLabel=if($existing.PSObject.Properties['focusLabel']){[string]$existing.focusLabel}else{''}
        nextAction=$existing.nextAction
        assistantCommitment=$existing.assistantCommitment
        constraints=$existing.constraints
        acceptanceCriteria=$existing.acceptanceCriteria
        currentPhase=if($existing.PSObject.Properties['currentPhase']){[string]$existing.currentPhase}elseif($existing.PSObject.Properties['continuityStateCard']){[string]$existing.continuityStateCard.phase}else{''}
        currentStep=if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}elseif($existing.PSObject.Properties['continuityStateCard']){[string]$existing.continuityStateCard.currentStep}else{''}
        completedSteps=if($existing.PSObject.Properties['completedSteps']){@($existing.completedSteps)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.completedSteps)}else{@()}
        pendingSteps=if($existing.PSObject.Properties['pendingSteps']){@($existing.pendingSteps)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.pendingSteps)}else{@()}
        blockers=if($existing.PSObject.Properties['blockers']){@($existing.blockers)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.blockers)}else{@()}
        evidence=if($existing.PSObject.Properties['evidence']){@($existing.evidence)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.evidence)}else{@()}
        verificationResults=if($existing.PSObject.Properties['verificationResults']){@($existing.verificationResults)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.verificationResults)}else{@()}
        projectProgressProof=if($existing.PSObject.Properties['projectProgressProof']){$existing.projectProgressProof}else{$null}
        topicKeys=if($existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@()}
        topicKeySource=if($existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}
        prioritySource=if($existing.PSObject.Properties['prioritySource']){[string]$existing.prioritySource}else{'current_contract'}
        priorityReason=if($existing.PSObject.Properties['priorityReason']){[string]$existing.priorityReason}else{''}
        checklistUpdateMode=if($existing.PSObject.Properties['checklistUpdateMode']){[string]$existing.checklistUpdateMode}else{'additive'}
        lastConfirmedSentence=if($existing.PSObject.Properties['lastConfirmedSentence']){[string]$existing.lastConfirmedSentence}else{''}
        lastConfirmedSource=if($existing.PSObject.Properties['lastConfirmedSource']){[string]$existing.lastConfirmedSource}else{''}
        visibleProgressReceipt=if($existing.PSObject.Properties['visibleProgressReceipt']){$existing.visibleProgressReceipt}else{$null}
        planFingerprint=if($existing.PSObject.Properties['planReceipt'] -and $existing.planReceipt.PSObject.Properties['planFingerprint']){[string]$existing.planReceipt.planFingerprint}else{''}
        mergeCaptureRequest=if($existing.PSObject.Properties['mergeCaptureRequest']){$existing.mergeCaptureRequest}else{$null}
      })))
    } elseif (-not $ObserveOnly -and $focusChanged) {
      $invalidated += $oldFocus
    }
    if (-not $ObserveOnly -and $mode -eq 'replace') {
      $invalidated += @($unfinishedWorkLines)
      $returnStack = @()
      $unfinishedWorkPlans = @()
      $unfinishedWorkLines = @()
    }
    $stackIntegrity = Protect-ReturnStackIntegrity $returnStack $TaskId $WorkspaceKey $newFocus -UpgradeLegacy
    if (-not $stackIntegrity.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$stackIntegrity.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; currentFocusId=$oldFocus; proposedFocusId=$newFocus; reason=[string]$stackIntegrity.reason; guard='The resulting parent path is invalid; no execution-contract mutation was written.' }
    }
    $returnStack = @($stackIntegrity.cards)
    if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($newFocus)) {
      $unfinishedState = Get-BoundedUnfinishedWorkState $unfinishedWorkLines $unfinishedWorkPlans @($newFocus)
      $unfinishedWorkLines = @($unfinishedState.lines)
      $unfinishedWorkPlans = @($unfinishedState.plans)
    }
    $completedWorkLines = @(
      if ($existing -and $existing.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($existing.completedWorkLines)) }
    )
    $latestInstruction = if ($ObserveOnly) { Protect-Instruction $UserInstruction } elseif (-not [string]::IsNullOrWhiteSpace($LatestUserInstruction)) { Protect-Instruction $LatestUserInstruction } elseif ($anchorBackedReconciliation) { [string]$instructionAnchorStatusBeforeSet.anchor.instruction } elseif ($existing) { [string]$existing.latestUserInstruction } else { '' }
    $instructionWasExplicitForBinding = (($script:LatestUserInstructionWasBound -and $explicitInstructionReconciliation) -or $anchorBackedReconciliation)
    if ($pendingInstructionObservation) {
      $pendingFocusLabel = if($existing -and $existing.PSObject.Properties['focusLabel']){[string]$existing.focusLabel}else{$newFocus}
      $pendingTopicKeys = if($existing -and $existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@(Get-DerivedTopicKeys $newFocus)}
      $pendingTopicSource = if($existing -and $existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}
      $pendingCurrentStep = if($existing -and $existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}else{''}
      $pendingNextAction = if($existing -and $existing.PSObject.Properties['nextAction']){[string]$existing.nextAction}else{''}
      $pendingCommitment = if($existing -and $existing.PSObject.Properties['assistantCommitment']){[string]$existing.assistantCommitment}else{''}
      $pendingMergeIntents = if($existing -and $existing.PSObject.Properties['mergeIntents']){@($existing.mergeIntents)}else{@()}
      $pendingClassification = Get-TopicClassification $latestInstruction $newFocus $pendingFocusLabel $pendingTopicKeys $pendingTopicSource $returnStack $unfinishedWorkPlans $pendingCurrentStep $pendingNextAction $pendingCommitment $pendingMergeIntents
      $anchorObservationContract = if($existing){$existing}else{[pscustomobject]@{taskId=$TaskId;instructionAnchor=$null}}
      $pendingObservation = Invoke-SuperBrainRuntimeWakeInstructionAnchorObservation $memoryBase $WorkspaceKey $ownerSessionKey $anchorObservationContract $latestInstruction $pendingClassification $(if([string]::IsNullOrWhiteSpace($Source)){'execution-contract.ps1:SetLatestInstruction'}else{$Source}) -RequireCanonicalPlanSource:$RequireCanonicalPlanSource
      if (-not $pendingObservation.ok -or -not $pendingObservation.anchor) {
        return [pscustomobject]@{ok=$false;code=if($pendingObservation.code){[string]$pendingObservation.code}else{'EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_WRITE_FAILED'};taskId=$TaskId;workspaceKey=$WorkspaceKey;guard='The latest instruction could not be recorded as a pending anchor, so no contract mutation was applied.'}
      }
      $instructionAnchorResolution = [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_INSTRUCTION_ANCHOR_PENDING';anchor=$pendingObservation.anchor;status=$pendingObservation}
    } else {
      $instructionAnchorResolution = Resolve-ContractInstructionAnchorBinding $existing $TaskId $WorkspaceKey $ownerSessionKey $latestInstruction $instructionWasExplicitForBinding $(if([string]::IsNullOrWhiteSpace($Source)){'execution-contract.ps1:Set'}else{$Source})
    }
    if (-not $instructionAnchorResolution.ok) {
      return [pscustomobject]@{ok=$false;code=[string]$instructionAnchorResolution.code;taskId=$TaskId;workspaceKey=$WorkspaceKey;instructionAnchorStatus=$instructionAnchorResolution.status;guard=[string]$instructionAnchorResolution.guard}
    }
    $instructionAnchorValue = $instructionAnchorResolution.anchor
    $instructionAnchorRequiresCanonicalSource = Test-InstructionAnchorCanonicalPlanSourceRequirement $instructionAnchorValue
    if ($instructionAnchorValue -and -not [string]::IsNullOrWhiteSpace([string]$instructionAnchorValue.instruction)) {
      $latestInstruction = [string]$instructionAnchorValue.instruction
    }
    $commitment = if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($AssistantCommitment)) { Limit-ContractText $AssistantCommitment 480 } elseif ($resumePlan) { [string]$resumePlan.assistantCommitment } elseif ($existing) { [string]$existing.assistantCommitment } else { '' }
    $actionValue = if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($NextAction)) { Limit-ContractText $NextAction 480 } elseif ($resumePlan) { [string]$resumePlan.nextAction } elseif ($existing) { [string]$existing.nextAction } else { '' }
    $stateProgressSentence = if (-not $ObserveOnly -and $script:CurrentStepWasBound -and -not [string]::IsNullOrWhiteSpace($CurrentStep)) { Limit-ContractText ('Progress checkpoint: ' + $CurrentStep) 320 } else { '' }
    $lastConfirmedSentenceValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['lastConfirmedSentence']) { [string]$existing.lastConfirmedSentence } elseif (-not $ObserveOnly -and $script:LastConfirmedSentenceWasBound -and -not [string]::IsNullOrWhiteSpace($LastConfirmedSentence)) { Limit-ContractText $LastConfirmedSentence 320 } elseif ($resumePlan -and $resumePlan.PSObject.Properties['lastConfirmedSentence']) { [string]$resumePlan.lastConfirmedSentence } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['lastConfirmedSentence']) { [string]$existing.lastConfirmedSentence } elseif (-not [string]::IsNullOrWhiteSpace($commitment)) { Limit-ContractText $commitment 320 } elseif (-not [string]::IsNullOrWhiteSpace($stateProgressSentence)) { $stateProgressSentence } elseif ($existing -and $existing.PSObject.Properties['lastConfirmedSentence']) { [string]$existing.lastConfirmedSentence } else { '' }
    $lastConfirmedSourceValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['lastConfirmedSource']) { [string]$existing.lastConfirmedSource } elseif (-not $ObserveOnly -and $script:LastConfirmedSourceWasBound) { $LastConfirmedSource } elseif ($resumePlan -and $resumePlan.PSObject.Properties['lastConfirmedSource']) { [string]$resumePlan.lastConfirmedSource } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['lastConfirmedSource']) { [string]$existing.lastConfirmedSource } elseif (-not [string]::IsNullOrWhiteSpace($commitment)) { 'assistant_commitment' } elseif (-not [string]::IsNullOrWhiteSpace($stateProgressSentence)) { 'execution_state_projection' } elseif ($existing -and $existing.PSObject.Properties['lastConfirmedSource']) { [string]$existing.lastConfirmedSource } else { '' }
    $constraintValue = @(
      if (($ObserveOnly -or -not $script:ConstraintsWereBound) -and $existing) { @($existing.constraints) }
      else { @(Limit-ContractList $Constraints) }
    )
    if (-not $ObserveOnly -and -not $script:ConstraintsWereBound -and $resumePlan) { $constraintValue = @($resumePlan.constraints) }
    $acceptanceValue = @(
      if (($ObserveOnly -or -not $script:AcceptanceCriteriaWereBound) -and $existing) { @($existing.acceptanceCriteria) }
      else { @(Limit-ContractList $AcceptanceCriteria) }
    )
    if (-not $ObserveOnly -and -not $script:AcceptanceCriteriaWereBound -and $resumePlan) { $acceptanceValue = @($resumePlan.acceptanceCriteria) }

    $focusLabelValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['focusLabel']) { [string]$existing.focusLabel } elseif ($script:FocusLabelWasBound -and -not [string]::IsNullOrWhiteSpace($FocusLabel)) { Limit-ContractText $FocusLabel 120 } elseif ($resumePlan) { [string]$resumePlan.focusLabel } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['focusLabel']) { [string]$existing.focusLabel } else { Get-DefaultFocusLabel $newFocus }
    $topicKeySourceValue = 'focus_id_derived'
    $topicKeyValue = @()
    if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['topicKeys']) {
      $topicKeyValue = @(Limit-TopicKeys @($existing.topicKeys))
      $topicKeySourceValue = if ($existing.PSObject.Properties['topicKeySource']) { [string]$existing.topicKeySource } else { 'focus_id_derived' }
    } elseif ($script:TopicKeysWereBound) {
      $topicKeyValue = @(Limit-TopicKeys $TopicKeys)
      $topicKeySourceValue = 'explicit'
    } elseif ($resumePlan) {
      $topicKeyValue = @($resumePlan.topicKeys)
      $topicKeySourceValue = [string]$resumePlan.topicKeySource
    } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['topicKeys']) {
      $topicKeyValue = @(Limit-TopicKeys @($existing.topicKeys))
      $topicKeySourceValue = if ($existing.PSObject.Properties['topicKeySource']) { [string]$existing.topicKeySource } else { 'focus_id_derived' }
    }
    if ($topicKeyValue.Count -eq 0) { $topicKeyValue = @(Get-DerivedTopicKeys $newFocus); $topicKeySourceValue = 'focus_id_derived' }

    $prioritySourceValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['prioritySource']) { [string]$existing.prioritySource } elseif ($script:PrioritySourceWasBound) { $PrioritySource } elseif ($resumePlan) { [string]$resumePlan.prioritySource } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['prioritySource']) { [string]$existing.prioritySource } elseif ($focusChanged) { 'latest_explicit_user_instruction' } else { 'current_contract' }
    $priorityReasonValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['priorityReason']) { [string]$existing.priorityReason } elseif ($script:PriorityReasonWasBound) { Limit-ContractText $PriorityReason 180 } elseif ($resumePlan) { [string]$resumePlan.priorityReason } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['priorityReason']) { [string]$existing.priorityReason } elseif ($focusChanged) { 'latest user instruction selected this active branch' } else { 'current execution contract remains active' }
    $existingStateCard = if ($existing -and $existing.PSObject.Properties['continuityStateCard']) { $existing.continuityStateCard } else { $null }
    $resumeStateCard = if ($resumePlan -and $resumePlan.PSObject.Properties['currentPhase']) { $resumePlan } elseif ($resumePlan -and $resumePlan.PSObject.Properties['phase']) { $resumePlan } else { $null }
    $resumePhaseRaw = if ($resumeStateCard -and $resumeStateCard.PSObject.Properties['currentPhase']) { [string]$resumeStateCard.currentPhase } elseif ($resumeStateCard -and $resumeStateCard.PSObject.Properties['phase']) { [string]$resumeStateCard.phase } else { '' }
    $statePhaseValue = if ($script:CurrentPhaseWasBound) { Limit-ContractText $CurrentPhase 120 } elseif ($resumeStateCard) { Limit-ContractText $resumePhaseRaw 120 } elseif ($existingStateCard -and -not $focusChanged) { Limit-ContractText ([string]$existingStateCard.phase) 120 } else { Limit-ContractText $mode 120 }
    $stateStepValue = if ($script:CurrentStepWasBound) { Limit-ContractText $CurrentStep 220 } elseif ($resumeStateCard) { Limit-ContractText ([string]$resumeStateCard.currentStep) 220 } elseif ($existingStateCard -and -not $focusChanged) { Limit-ContractText ([string]$existingStateCard.currentStep) 220 } else { Limit-ContractText $actionValue 220 }
    $phaseCloseoutResolution = if ($ObserveOnly) {
      [pscustomobject]@{ ok=$true; closeouts=@(Get-SuperBrainPhaseCloseoutEntries $existing); added=$false }
    } else {
      Resolve-SuperBrainPhaseCloseouts $existing $statePhaseValue $newFocus $mode $(if($script:PhaseCloseoutPathWasBound){$PhaseCloseoutPath}else{''}) $workspace ([string]$manifest.version) $Root $memoryBase $ProjectRoot
    }
    if (-not $phaseCloseoutResolution.ok) {
      return [pscustomobject]@{
        ok=$false; code=('EXECUTION_CONTRACT_' + [string]$phaseCloseoutResolution.code); taskId=$TaskId; workspaceKey=$WorkspaceKey
        phase=if($phaseCloseoutResolution.requirement){[string]$phaseCloseoutResolution.requirement.previousPhase}else{''}
        nextPhase=if($phaseCloseoutResolution.requirement){[string]$phaseCloseoutResolution.requirement.nextPhase}else{''}
        guard='A formal task phase cannot advance until current H7 entry, telemetry, and project-progress proof evidence are scope-bound and hash-verified. Retired P7/Hook evidence is never accepted.'
      }
    }
    $phaseCloseoutsValue = @($phaseCloseoutResolution.closeouts)
    $priorCompletedSteps = if ($resumeStateCard) { @($resumeStateCard.completedSteps) } elseif ($existingCanonicalPlan -and $existingStateCard -and -not $focusChanged -and $existingStateCard.PSObject.Properties['activeWorkPackageCompletedSteps']) { @($existingStateCard.activeWorkPackageCompletedSteps) } elseif ($existingStateCard -and -not $focusChanged) { @($existingStateCard.completedSteps) } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['completedSteps']) { @($existing.completedSteps) } else { @() }
    $priorPendingSteps = if ($resumeStateCard) { @($resumeStateCard.pendingSteps) } elseif ($existingCanonicalPlan -and $existingStateCard -and -not $focusChanged -and $existingStateCard.PSObject.Properties['activeWorkPackagePendingSteps']) { @($existingStateCard.activeWorkPackagePendingSteps) } elseif ($existingStateCard -and -not $focusChanged) { @($existingStateCard.pendingSteps) } elseif ($existing -and -not $focusChanged -and $existing.PSObject.Properties['pendingSteps']) { @($existing.pendingSteps) } else { @() }
    $incomingCompletedSteps = if ($script:CompletedStepsWereBound) { @($CompletedSteps) } else { @() }
    $explicitNoAutomaticActionInput = $script:NextActionWasBound -and -not [string]::IsNullOrWhiteSpace($NextAction) -and ([string]$NextAction).Trim().StartsWith('No automatic action:', [StringComparison]::OrdinalIgnoreCase)
    # A terminal/no-action marker is a pause boundary, not a checklist item.
    # This must be applied at the CLI boundary too; powershell.exe -File can
    # flatten an explicitly empty string[] and otherwise re-infer the marker
    # as a pending action.
    $incomingPendingSteps = if ($explicitNoAutomaticActionInput) { @() } elseif ($script:PendingStepsWereBound) { @($PendingSteps) } elseif (@($priorCompletedSteps).Count -eq 0 -and @($priorPendingSteps).Count -eq 0 -and $script:NextActionWasBound -and -not [string]::IsNullOrWhiteSpace($actionValue)) { @($actionValue) } else { @() }
    # A caller flag alone is not evidence that the user chose to discard work.
    # Keep ordinary progress updates additive, and require an explicit, bound
    # user instruction before a focus or checklist replacement can remove work.
    $explicitScopeReplacement = (Test-ExplicitChecklistScopeReplacement $latestInstruction)
    if (-not $ObserveOnly -and $mode -eq 'replace' -and -not $explicitScopeReplacement) {
      return [pscustomobject]@{
        ok=$false; code='EXECUTION_CONTRACT_SCOPE_REPLACEMENT_USER_AUTH_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey
        guard='Replacing an active work line requires explicit replacement or cancellation wording in the latest bound user instruction.'
      }
    }
    if (-not $ObserveOnly -and $ChecklistUpdateMode -eq 'replace' -and -not $explicitScopeReplacement) {
      $replacementCandidate = Merge-ActiveChecklist $priorCompletedSteps $priorPendingSteps $incomingCompletedSteps $incomingPendingSteps 'replace'
      if (-not $replacementCandidate.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$replacementCandidate.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; count=[int]$replacementCandidate.count; maxItems=[int]$replacementCandidate.maxItems; guard='The requested checklist replacement is malformed; no contract mutation was written.' }
      }
      $replacementKeys = @(@($replacementCandidate.completedSteps + $replacementCandidate.pendingSteps) | ForEach-Object { Get-ChecklistStepKey ([string]$_) })
      $discardedSteps = @(@($priorCompletedSteps + $priorPendingSteps) | Where-Object {
        $key = Get-ChecklistStepKey ([string]$_)
        -not [string]::IsNullOrWhiteSpace($key) -and $replacementKeys -notcontains $key
      } | Select-Object -Unique)
      if ($discardedSteps.Count -gt 0) {
        return [pscustomobject]@{
          ok=$false; code='EXECUTION_CONTRACT_CHECKLIST_REPLACEMENT_USER_AUTH_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; discardedSteps=@($discardedSteps)
          guard='A caller cannot discard accepted checklist items without explicit replacement or cancellation wording in the latest bound user instruction. Use additive progress updates for normal completion.'
        }
      }
    }
    $scopeReplacementRequested = (-not $ObserveOnly -and $explicitScopeReplacement)
    $checklistModeValue = if ($ObserveOnly -and $existing -and $existing.PSObject.Properties['checklistUpdateMode']) { [string]$existing.checklistUpdateMode } elseif ($scopeReplacementRequested) { 'replace' } else { 'additive' }
    $checklistState = Merge-ActiveChecklist $priorCompletedSteps $priorPendingSteps $incomingCompletedSteps $incomingPendingSteps $checklistModeValue
    if (-not $checklistState.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$checklistState.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; count=[int]$checklistState.count; maxItems=[int]$checklistState.maxItems; guard='The active checklist would exceed the bounded contract size. Split it explicitly instead of silently dropping plan items.' }
    }
    $canonicalMainActive = ($existingCanonicalPlan -and [string]$newFocus -eq [string]$existingCanonicalPlan.rootFocusId -and $returnStack.Count -eq 0)
    $canonicalChecklistChanged = $false
    if ($existingCanonicalPlan -and $canonicalMainActive -and ($script:CompletedStepsWereBound -or $script:PendingStepsWereBound)) {
      $existingCanonicalProjection = Get-CanonicalPlanProjection $existingCanonicalPlan
      $canonicalChecklistChanged = -not (Test-ChecklistStateEquivalent $existingCanonicalProjection.completedSteps $existingCanonicalProjection.pendingSteps $checklistState.completedSteps $checklistState.pendingSteps)
    }
    $unstructuredCanonicalMutation = (-not $ObserveOnly -and $existingCanonicalPlan -and -not $canonicalMutationRecord -and $canonicalMainActive -and ($scopeReplacementRequested -or $canonicalChecklistChanged))
    if ($unstructuredCanonicalMutation) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_MUTATION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; planId=[string]$existingCanonicalPlan.planId; guard='The approved canonical main plan can change only through CanonicalMutationPath with item identity, CAS fields, transition identity, and approval evidence.' }
    }
    $stateCompletedSteps = @($checklistState.completedSteps)
    $statePendingSteps = @($checklistState.pendingSteps)
    $canonicalPlanValue = $existingCanonicalPlan
    $canonicalPlanSourceValue = if ($existing -and $existing.PSObject.Properties['canonicalPlanSource']) { $existing.canonicalPlanSource } else { $null }
    $canonicalPlanSourceRequiredValue = [bool](
      $RequireCanonicalPlanSource -or
      $script:CanonicalSourceManifestPathWasBound -or
      $instructionAnchorRequiresCanonicalSource -or
      ($existing -and $existing.PSObject.Properties['canonicalPlanSourceRequired'] -and $existing.canonicalPlanSourceRequired -eq $true)
    )
    if ($canonicalMutationRecord) {
      $replacementRootFocusId = if($mode-eq'replace' -and $focusChanged){$newFocus}else{''}
      $mutationResult = Apply-CanonicalPlanMutation $existingCanonicalPlan $canonicalMutationRecord.envelope $latestInstruction ([int]$existing.revision) $replacementRootFocusId
      if (-not $mutationResult.ok) { return $mutationResult }
      $canonicalPlanValue = $mutationResult.plan
    } elseif ($script:EnableCanonicalPlanWasBound -and -not $existingCanonicalPlan) {
      $initialChecklist = @($checklistState.activeChecklist)
      if ($initialChecklist.Count -eq 0) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEMS_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='An explicit canonical plan cannot be enabled without at least one bounded checklist item.' }
      }
      $hasApprovalInstruction = -not [string]::IsNullOrWhiteSpace($latestInstruction)
      $orderConfidence = if ($existing -or -not $hasApprovalInstruction) { 'legacy_derived' } else { 'verified' }
      $approvalSource = if ($existing) { 'explicit_guarded_migration' } elseif($hasApprovalInstruction) { 'user_confirmation' } else { 'guarded_bootstrap_without_user_receipt' }
      $createdCanonical = New-CanonicalPlanFromChecklist $initialChecklist $newFocus $orderConfidence $approvalSource $latestInstruction
      if (-not $createdCanonical.ok) { return $createdCanonical }
      $canonicalPlanValue = $createdCanonical.plan
    }
    if ($canonicalPlanValue -and $intentPlanBindingValue) {
      $canonicalPlanValue = $canonicalPlanValue | ConvertTo-Json -Depth 14 | ConvertFrom-Json
      $canonicalPlanValue | Add-Member -NotePropertyName intentBinding -NotePropertyValue $intentPlanBindingValue -Force
      $canonicalPlanValue.currentFingerprint = ''
      $canonicalPlanValue = Complete-CanonicalPlanFingerprint $canonicalPlanValue
      $intentBoundCanonical = Test-CanonicalPlanState $canonicalPlanValue
      if (-not $intentBoundCanonical.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$intentBoundCanonical.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The canonical plan could not be bound to the current intent revision without changing its validated identity.' }
      }
      $canonicalPlanValue = $intentBoundCanonical.plan
    }
    if ($canonicalSourceManifestRecord) {
      if (-not $canonicalPlanValue) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A canonical plan source receipt can bind only to an existing canonical main plan.' }
      }
      $sourceBinding = New-CanonicalPlanSourceBinding $canonicalSourceManifestRecord $canonicalPlanValue
      if (-not $sourceBinding.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$sourceBinding.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The source receipt must bind exactly to the candidate canonical plan before it can authorize that plan.' }
      }
      $canonicalPlanSourceValue = $sourceBinding.binding
    }
    if (-not $ObserveOnly -and $canonicalPlanSourceRequiredValue -and $canonicalPlanValue -and -not $canonicalPlanSourceValue -and -not $reconciliationRequested) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A strict canonical plan requires a current source receipt; bind a manifest and its source document before this task can continue.' }
    }
    if ($canonicalPlanValue) {
      $canonicalProjection = Get-CanonicalPlanProjection $canonicalPlanValue
      $returnStack = @(Bind-ReturnStackCanonicalPlan $returnStack $canonicalPlanValue $TaskId $WorkspaceKey)
      if ([string]$newFocus -eq [string]$canonicalPlanValue.rootFocusId -and $returnStack.Count -eq 0) {
        $stateCompletedSteps = @($canonicalProjection.completedSteps)
        $statePendingSteps = @($canonicalProjection.pendingSteps)
      }
      if($returnStack.Count-eq0 -and [string]$newFocus-ne[string]$canonicalPlanValue.rootFocusId){
        return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_ROOT_FOCUS_MISMATCH';taskId=$TaskId;workspaceKey=$WorkspaceKey;focusId=$newFocus;canonicalRootFocusId=[string]$canonicalPlanValue.rootFocusId;guard='A root work line cannot detach from the canonical plan root without an explicit canonical replacement.'}
      }
    } else {
      $canonicalProjection = $null
    }
    $activeWorkPackageCompletedStepsValue = @($stateCompletedSteps)
    $activeWorkPackagePendingStepsValue = @($statePendingSteps)
    $stateBlockers = if ($script:BlockersWereBound) { @(Limit-ContractList $Blockers 6 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.blockers) 6 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.blockers) 6 180) } else { @() }
    $stateEvidence = if ($script:EvidenceWereBound) { @(Limit-ContractList $Evidence 8 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.evidence) 8 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.evidence) 8 180) } else { @() }
    $stateVerificationResults = if ($script:VerificationResultsWereBound) { @(Limit-ContractList $VerificationResults 6 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.verificationResults) 6 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.verificationResults) 6 180) } else { @() }
    if ($script:ProjectProgressProofBase64WasBound -and -not [string]::IsNullOrWhiteSpace($script:ProjectProgressProofDecodeError)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROJECT_PROGRESS_INPUT_DECODE_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The H7 project-progress proof transport is not valid UTF-8 Base64 JSON; the contract was left unchanged.' }
    }
    $existingProjectProgressProof = if($existing -and $existing.PSObject.Properties['projectProgressProof']){$existing.projectProgressProof}else{$null}
    # A checkpoint is an atomic public-progress transition.  It may reuse an
    # existing proof only when that proof is still current for the exact phase,
    # step, completed work, live file hashes, and next action being written.
    # Do not turn a missing fresh proof into a newly persisted ``withheld``
    # proof after already changing the contract: that creates a false-looking
    # checkpoint and breaks the visible-progress binding one write later.
    if ($script:ProgressCheckpointBase64WasBound -and -not $script:ProjectProgressProofBase64WasBound) {
      $checkpointProofStatus = Test-ProjectProgressProof $existingProjectProgressProof $statePhaseValue $stateStepValue $stateCompletedSteps $actionValue $ProjectRoot
      if (-not $checkpointProofStatus.current) {
        return [pscustomobject]@{
          ok=$false
          code='EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_PROJECT_PROOF_REQUIRED'
          taskId=$TaskId
          workspaceKey=$WorkspaceKey
          missing=@($checkpointProofStatus.missing)
          guard='A progress checkpoint that changes or outlives its project proof must carry one fresh H7 project-progress proof in the same CAS update; no withheld proof was written.'
        }
      }
    }
    $projectProgressResult = New-ProjectProgressProof $ProjectRoot $statePhaseValue $stateStepValue $stateCompletedSteps $stateEvidence $stateVerificationResults $actionValue $(if($script:ProjectProgressProofBase64WasBound){$script:ProjectProgressProofInput}else{$null}) $existingProjectProgressProof
    if (-not $projectProgressResult.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$projectProgressResult.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($projectProgressResult.missing); guard='A project-progress claim must bind the current phase, completed work, live project evidence, passed verification, and next action in one H7 proof.' }
    }
    $visibleProgressScopeBindingHash = Get-VisibleProgressScopeBindingHash $TaskId $taskInstanceIdValue $WorkspaceKey $ownerSessionKey ([string]$manifest.version)
    $visibleProgressReceiptValue = $null
    if ($script:ProgressCheckpointBase64WasBound) {
      $visibleProgressReceiptResult = New-VisibleProgressReceipt $lastConfirmedSentenceValue $lastConfirmedSourceValue $statePhaseValue $stateStepValue $actionValue $projectProgressResult.proof $visibleProgressScopeBindingHash $transitionIdValue
      if (-not $visibleProgressReceiptResult.ok) {
        return [pscustomobject]@{ ok=$false; code=[string]$visibleProgressReceiptResult.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='An H7 checkpoint must atomically bind the exact visible assistant progress sentence to the current task stage and project proof.' }
      }
      $visibleProgressReceiptValue = $visibleProgressReceiptResult.receipt
    } elseif ($existing -and $existing.PSObject.Properties['visibleProgressReceipt'] -and $existing.visibleProgressReceipt) {
      $visibleProgressReceiptStatus = Test-VisibleProgressReceipt $existing.visibleProgressReceipt $lastConfirmedSentenceValue $lastConfirmedSourceValue $statePhaseValue $stateStepValue $actionValue $projectProgressResult.proof $visibleProgressScopeBindingHash
      if ($visibleProgressReceiptStatus.ok) {
        $visibleProgressReceiptValue = $visibleProgressReceiptStatus.receipt
      }
    }
    $stateEvidence = @(Limit-ContractList (@($stateEvidence) + @($projectProgressResult.evidenceRefs)) 8 180)
    $stateVerificationResults = @(Limit-ContractList (@($stateVerificationResults) + @($projectProgressResult.verificationRefs)) 6 180)
    $stateSourceValue = if ($script:StateCardSourceWasBound) { Limit-ContractText $StateCardSource 120 } elseif ($resumeStateCard -and $resumeStateCard.PSObject.Properties['source']) { Limit-ContractText ([string]$resumeStateCard.source) 120 } elseif ($existingStateCard -and -not $focusChanged -and $existingStateCard.PSObject.Properties['source']) { Limit-ContractText ([string]$existingStateCard.source) 120 } else { 'execution-contract.ps1' }
    $existingMergeCaptureRequest = if (-not $focusChanged -and $existing -and $existing.PSObject.Properties['mergeCaptureRequest']) { $existing.mergeCaptureRequest } else { $null }
    $automaticMergeRetention = ($returnStack.Count -gt 0 -and (Test-DeferredMergeSignal $latestInstruction))
    $explicitMergeRetention = ($script:RetainForMergeWasBound -or $script:MergeTargetFocusIdWasBound -or $script:MergeTargetLabelWasBound -or $script:MergeTargetScopeWasBound -or $script:ArtifactRefsWereBound -or $script:InterfaceContractsWereBound -or $script:DependenciesWereBound -or $script:VerificationStepsWereBound -or $script:MergeConditionsWereBound)
    $mergeCaptureRequest = New-MergeCaptureRequest $existingMergeCaptureRequest $returnStack $newFocus $TaskId ($automaticMergeRetention -or $explicitMergeRetention) $MergeTargetFocusId $MergeTargetLabel $MergeTargetScope $ArtifactRefs $InterfaceContracts $Dependencies $VerificationSteps $MergeConditions $(if($automaticMergeRetention){'user_deferred_merge_signal'}elseif(-not [string]::IsNullOrWhiteSpace($Source)){[string]$Source}else{'assistant_execution_commitment'})
    $messageClassification = Get-TopicClassification $latestInstruction $newFocus $focusLabelValue $topicKeyValue $topicKeySourceValue $returnStack $unfinishedWorkPlans $stateStepValue $actionValue $commitment $mergeIntents
    if ($instructionAnchorValue -and $instructionAnchorValue.classification -and [string]$instructionAnchorValue.classification.topicAffinity -eq 'active' -and [string]$instructionAnchorValue.classification.confidence -eq 'high') {
      $messageClassification = [pscustomobject]@{
        mode=if([string]::IsNullOrWhiteSpace([string]$instructionAnchorValue.classification.mode)){$mode}else{[string]$instructionAnchorValue.classification.mode}; topicAffinity='active'; targetLineId=$newFocus; targetLineLabel=$focusLabelValue; confidence='high'; matchedKeys=if($instructionAnchorValue.classification.matchedKeys){@($instructionAnchorValue.classification.matchedKeys)}else{@('instruction_anchor')}; candidateLineIds=@($newFocus); needsClarification=[bool]$instructionAnchorValue.classification.needsClarification; recommendedInstructionMode=$mode; reason='the authoritative instruction anchor is bound to the active work line'; rawInstructionStored=$false
      }
    }
    if ($explicitInstructionReconciliation) {
      $messageClassification = [pscustomobject]@{
        mode=$mode; topicAffinity='active'; targetLineId=$newFocus; targetLineLabel=$focusLabelValue; confidence='high'; matchedKeys=@('explicit_instruction_mode'); candidateLineIds=@($newFocus); needsClarification=$false; recommendedInstructionMode=$mode; reason='an explicit instruction mode, focus, and concrete action reconciled the current work line'; rawInstructionStored=$false
      }
    }
    $classificationNeedsReconciliation = Test-ClassificationBlocksAuthorization $messageClassification $latestInstruction
    $workLineStatusValue = New-WorkLineStatus $newFocus $returnStack $completedWorkLines $unfinishedWorkLines $actionValue $commitment $constraintValue $acceptanceValue $focusLabelValue $topicKeyValue $topicKeySourceValue $prioritySourceValue $priorityReasonValue $unfinishedWorkPlans $messageClassification $mergeIntents $canonicalPlanValue $activeWorkPackageCompletedStepsValue $activeWorkPackagePendingStepsValue
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey $ownerSessionKey $revision $mode $newFocus $focusLabelValue $workLineStatusValue $returnStack $statePhaseValue $stateStepValue $stateCompletedSteps $statePendingSteps $stateBlockers $stateEvidence $stateVerificationResults $actionValue $commitment $constraintValue $acceptanceValue $stateSourceValue $checklistModeValue $lastConfirmedSentenceValue $lastConfirmedSourceValue $canonicalPlanValue $activeWorkPackageCompletedStepsValue $activeWorkPackagePendingStepsValue $projectProgressResult.proof
    $planReceiptRequiredValue = if ($ObserveOnly) { [bool]($existing -and $existing.PSObject.Properties['planReceiptRequired'] -and $existing.planReceiptRequired -eq $true) } else { $true }
    $planReceiptValue = if ($ObserveOnly) {
      if ($existing -and $existing.PSObject.Properties['planReceipt']) { $existing.planReceipt } else { $null }
    } else {
      New-PlanReceipt $TaskId $WorkspaceKey $ownerSessionKey $revision $newFocus $focusLabelValue $actionValue $statePhaseValue $stateStepValue $statePendingSteps $constraintValue $acceptanceValue $workLineStatusValue $latestInstruction $stateSourceValue $stateCompletedSteps $(if($canonicalPlanValue){'super-brain.plan-receipt.v3'}else{'super-brain.plan-receipt.v2'}) $intentPlanBindingValue
    }
    $intentResolutionReceiptValue = $null
    if ($ObserveOnly) {
      if ($existing -and $existing.PSObject.Properties['intentResolutionReceipt']) { $intentResolutionReceiptValue = $existing.intentResolutionReceipt }
    } elseif ($intentContractRequiredValue) {
      # Canonical state/source transitions change the contract revision and plan receipt.
      # They may reuse the same governed outcome, but must receive a fresh
      # task-scoped intent receipt instead of leaving the prior revision stale.
      $mayRefreshIntentReceipt = (
        $script:IntentContractJsonWasBound -or
        $script:CanonicalMutationPathWasBound -or
        $script:CanonicalSourceManifestPathWasBound -or
        $script:RequireCanonicalPlanSourceWasBound -or
        $reconciliationRequested -or
        $reconciliationCleared -or
        $instructionAnchorReconciliationPending -or
        (-not $script:LatestUserInstructionWasBound -and -not $focusChanged -and $mode -eq 'continue')
      )
      if ($mayRefreshIntentReceipt) {
        $intentResolution = Resolve-IntentResolution $intentPreparedValue $TaskId $taskInstanceIdValue $WorkspaceKey $ownerSessionKey ([string]$manifest.version) $revision $planReceiptValue $latestInstruction $stateSourceValue
        if (-not $intentResolution.ok) {
          return [pscustomobject]@{ ok=$false; code=[string]$intentResolution.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentResolution.missing); guard='The current plan could not receive an immutable intent resolution receipt from the canonical local control plane.' }
        }
        $intentContractValue = $intentResolution.intentContract
        $intentRevisionValue = [int]$intentResolution.intentRevision
        $intentAggregateIdValue = [string]$intentResolution.aggregateId
        $intentResolutionReceiptValue = $intentResolution.intentResolutionReceipt
      } elseif ($existing -and $existing.PSObject.Properties['intentResolutionReceipt']) {
        # A fresh user instruction must be deliberately re-resolved, not silently rebound to an older product decision.
        $intentResolutionReceiptValue = $existing.intentResolutionReceipt
      }
    }
    $stageKindValue = Get-ContractEffectiveDecisionStageKind $existing $StageKind $statePhaseValue
    if (-not $ObserveOnly -and $StageKind -eq 'none' -and $existing -and $existing.PSObject.Properties['decisionBinding'] -and $existing.decisionBinding -and [string]$existing.decisionBinding.status -eq 'bound') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DECISION_STAGE_CLEAR_REQUIRES_REPLACE'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A bound completion decision cannot be silently cleared from an active task. Replace or cancel the scoped task explicitly, then create a new contract.' }
    }
    $decisionIntentFingerprintValue = Get-ContractDecisionIntentFingerprint $existing $intentContractValue $latestInstruction $DecisionIntentFingerprint
    $decisionBindingValue = $null
    if ($ObserveOnly) {
      if ($existing -and $existing.PSObject.Properties['decisionBinding']) { $decisionBindingValue = $existing.decisionBinding }
    } elseif (-not [string]::IsNullOrWhiteSpace($stageKindValue)) {
      $decisionSeed = [pscustomobject]@{ taskInstanceId=$taskInstanceIdValue; focusId=$newFocus; ownerSessionKey=$ownerSessionKey }
      $decisionResolution = Invoke-ContractDecisionBinding 'Resolve' $decisionSeed $stageKindValue $decisionIntentFingerprintValue $revision $planReceiptValue
      if (-not $decisionResolution.ok) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DECISION_BINDING_WITHHELD'; taskId=$TaskId; workspaceKey=$WorkspaceKey; stageKind=$stageKindValue; decisionBindingStatus=$decisionResolution.status; decisionBindingCode=$decisionResolution.code; reasons=@($decisionResolution.reasons); guard='A current completion-decision receipt could not be resolved. Reconcile the exact task scope and decision state before mutation.' }
      }
      $decisionBindingValue = $decisionResolution.binding
    }
    $transitionReceiptsValue = @($transitionReceipts)
    $lastTransitionValue = if ($existing -and $existing.PSObject.Properties['lastTransition']) { $existing.lastTransition } else { $null }
    if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($transitionIdValue)) {
      $transitionReceiptsValue = @(Add-TransitionReceipt $transitionReceipts $transitionIdValue 'Set' $setPayloadHash $(if($existing){[int]$existing.revision}else{0}) $revision $oldFocus $newFocus)
      $lastTransitionValue = @($transitionReceiptsValue | Where-Object { [string]$_.transitionId -eq $transitionIdValue } | Select-Object -Last 1)[0]
    }
    $value = [pscustomobject]@{
      ok = $true
      schema = 'super-brain.execution-contract.v1'
      taskId = $TaskId
      taskInstanceId = $taskInstanceIdValue
      workspaceKey = $WorkspaceKey
      ownerSessionKey = $ownerSessionKey
      sessionBound = (-not [string]::IsNullOrWhiteSpace($ownerSessionKey))
      structuralGuardsRequired = [bool]($RequireStructuralGuards -or ($existing -and $existing.PSObject.Properties['structuralGuardsRequired'] -and $existing.structuralGuardsRequired -eq $true) -or ($existing -and $ExpectedRevision -ge 0 -and -not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not [string]::IsNullOrWhiteSpace($transitionIdValue)))
      packageVersion = [string]$manifest.version
      revision = $revision
      status = 'active'
      focusId = $newFocus
      focusLabel = $focusLabelValue
      instructionMode = $mode
      returnStack = @($returnStack)
      returnTo = if ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
      canResumeParent = ($returnStack.Count -gt 0)
      completedWorkLines = @($completedWorkLines)
      unfinishedWorkLines = @($unfinishedWorkLines)
      unfinishedWorkPlans = @($unfinishedWorkPlans)
      mergeCaptureRequest = $mergeCaptureRequest
      mergeIntents = @($mergeIntents)
      canonicalPlan = $canonicalPlanValue
      canonicalPlanSourceRequired = $canonicalPlanSourceRequiredValue
      canonicalPlanSource = $canonicalPlanSourceValue
      workLineStatus = $workLineStatusValue
      continuityStateCard = $stateCardValue
      phaseCloseouts = @($phaseCloseoutsValue)
      phaseEvidencePolicy = $phaseEvidencePolicyValue
      planReceiptRequired = $planReceiptRequiredValue
      planReceipt = $planReceiptValue
      intentContractRequired = $intentContractRequiredValue
      intentAggregateId = $intentAggregateIdValue
      intentRevision = $intentRevisionValue
       intentContract = $intentContractValue
       intentResolutionReceipt = $intentResolutionReceiptValue
       intentSessionRebindReceipt = $intentSessionRebindReceiptValue
       taskSessionRebindReceipt = $taskSessionRebindReceiptValue
       stageKind = $stageKindValue
      decisionIntentFingerprint = $decisionIntentFingerprintValue
      decisionBinding = $decisionBindingValue
      latestUserInstruction = $latestInstruction
      instructionAnchor = $instructionAnchorValue
      latestMessageClassification = $messageClassification
      assistantCommitment = $commitment
      lastConfirmedSentence = $lastConfirmedSentenceValue
      lastConfirmedSource = $lastConfirmedSourceValue
      nextAction = $actionValue
      currentPhase = $statePhaseValue
      currentStep = $stateStepValue
      completedSteps = @($stateCompletedSteps)
      pendingSteps = @($statePendingSteps)
      checklistUpdateMode = $checklistModeValue
      supersededChecklistSteps = @($checklistState.supersededSteps)
      blockers = @($stateBlockers)
      evidence = @($stateEvidence)
      verificationResults = @($stateVerificationResults)
      projectProgressProof = $projectProgressResult.proof
      visibleProgressReceipt = $visibleProgressReceiptValue
      constraints = @($constraintValue)
      topicKeys = @($topicKeyValue)
      topicKeySource = $topicKeySourceValue
      prioritySource = $prioritySourceValue
      priorityReason = $priorityReasonValue
      invalidatedWorkItems = @(Limit-ContractList $invalidated 20 120)
      acceptanceCriteria = @($acceptanceValue)
      needsReconciliation = if ($ObserveOnly) { ([bool]$RequiresReconciliation -or $classificationNeedsReconciliation) } elseif ($reconciliationRequested) { $true } elseif ($pendingInstructionObservation) { $true } elseif ($explicitInstructionReconciliation -or $anchorBackedReconciliation -or ($script:LatestUserInstructionWasBound -and $instructionAnchorValue)) { $false } elseif ($existing -and $existing.needsReconciliation -eq $true) { $true } else { $classificationNeedsReconciliation }
      transitionReceipts = @($transitionReceiptsValue)
      lastTransition = $lastTransitionValue
      updatedAt = (Get-SuperBrainUtcTimestamp)
      source = if ([string]::IsNullOrWhiteSpace($Source)) { if ($ObserveOnly) { 'user_prompt_hook' } else { 'assistant_execution_commitment' } } else { Limit-ContractText $Source 120 }
      rawPromptStored = $false
      rawTranscriptStored = $false
      rawSessionIdStored = $false
      retention = 'latest_task_contract_plus_bounded_return_stack_and_merge_dossiers'
      path = $contractPath
    }
    if ($ObserveOnly) {
      $publish = Publish-ExecutionContractDirect $value
      if ([string]$record.source -eq 'legacy_task_only') { Remove-MatchingLegacyContract $TaskId $WorkspaceKey }
      $value | Add-Member -NotePropertyName hotIndex -NotePropertyValue $publish.hotIndex -Force
      return $value
    }
    return Complete-ContractContinuityMutation $value $(if($script:PackageVersionRebindActive){'RebindPackageVersion'}else{'Set'})
  }
}

function New-PackageVersionRebindInputProof([object]$Contract,[string]$ProjectRootValue) {
  $rootBinding = Get-ProjectProgressRootBinding $ProjectRootValue
  if (-not $rootBinding.ok) {
    return [pscustomobject]@{ ok=$false; code=[string]$rootBinding.code; missing=@('project_root'); input=$null; changedEvidence=@() }
  }
  $proof = if ($Contract -and $Contract.PSObject.Properties['projectProgressProof']) { $Contract.projectProgressProof } else { $null }
  $structural = Test-ProjectProgressProof $proof ([string]$Contract.currentPhase) ([string]$Contract.currentStep) @($Contract.completedSteps) ([string]$Contract.nextAction) ''
  if (-not $structural.valid) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_PRIOR_PROOF_INVALID'; missing=@($structural.missing); input=$null; changedEvidence=@() }
  }

  # A release migration may alter the package manifest identity, but it must
  # not quietly bless unrelated source drift that happened after Stage proof.
  # Versioned docs/rules are deliberately outside the active proof; the only
  # current Stage 4 evidence allowed to change here is the CORE manifest.
  $allowedChangedEvidence = @('core/manifest.json')
  $evidenceByRelative = @{}
  $rebasedEvidence = @()
  $changedEvidence = @()
  foreach ($entry in @($proof.projectEvidence)) {
    $relative = ([string]$entry.relativePath).Replace('/','\\').Trim()
    $relativeKey = $relative.Replace('\\','/').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\\\)\.\.(\\\\|$)' -or $relative -match ':') {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_EVIDENCE_PATH_INVALID'; missing=@('project_evidence_path'); input=$null; changedEvidence=@() }
    }
    try {
      $candidate = [IO.Path]::GetFullPath((Join-Path $rootBinding.path $relative))
      $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
      $rootPrefix = $rootBinding.path + [IO.Path]::DirectorySeparatorChar
      if (-not $resolvedCandidate.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolvedCandidate -PathType Leaf)) { throw 'evidence path unavailable' }
      $actualHash = (Get-FileHash -LiteralPath $resolvedCandidate -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_EVIDENCE_MISSING'; missing=@('project_evidence_file'); input=$null; changedEvidence=@() }
    }
    if ($actualHash -ne [string]$entry.sha256) {
      if ($relativeKey -notin $allowedChangedEvidence) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_UNEXPECTED_EVIDENCE_DRIFT'; missing=@($relativeKey); input=$null; changedEvidence=@($changedEvidence + $relativeKey) }
      }
      $changedEvidence += $relativeKey
    }
    $newRef = Get-ProjectProgressEvidenceRef $relativeKey $actualHash
    if ($evidenceByRelative.ContainsKey($relativeKey)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_EVIDENCE_DUPLICATE'; missing=@('project_evidence_unique'); input=$null; changedEvidence=@($changedEvidence) }
    }
    $evidenceByRelative[$relativeKey] = $newRef
    $rebasedEvidence += [pscustomobject]@{ kind='project_file'; relativePath=$relativeKey; sha256=$actualHash }
  }

  $rebasedItems = @()
  foreach ($item in @($proof.completedItems)) {
    $rebasedRefs = @()
    foreach ($reference in @($item.evidenceRefs)) {
      $match = [regex]::Match([string]$reference,'^project:file:(.+)@sha256:[a-f0-9]{64}$')
      if (-not $match.Success) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_COMPLETED_ITEM_INVALID'; missing=@('completed_item_evidence'); input=$null; changedEvidence=@($changedEvidence) }
      }
      $referenceKey = $match.Groups[1].Value.Replace('\\','/').ToLowerInvariant()
      if (-not $evidenceByRelative.ContainsKey($referenceKey)) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_COMPLETED_ITEM_EVIDENCE_UNKNOWN'; missing=@($referenceKey); input=$null; changedEvidence=@($changedEvidence) }
      }
      $rebasedRefs += [string]$evidenceByRelative[$referenceKey]
    }
    $rebasedItems += [pscustomobject]@{
      itemKey=[string]$item.itemKey
      evidenceRefs=@($rebasedRefs | Sort-Object -Unique)
      verificationIds=@($item.verificationIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }
  }

  return [pscustomobject]@{
    ok=$true
    code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_PROOF_READY'
    changedEvidence=@($changedEvidence | Sort-Object -Unique)
    input=[pscustomobject]@{
      schema='super-brain.project-progress-input.v1'
      phase=[string]$Contract.currentPhase
      currentStep=[string]$Contract.currentStep
      completedItems=@($rebasedItems)
      projectEvidence=@($rebasedEvidence | Sort-Object relativePath)
      verificationResults=@($proof.verificationResults | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; status=[string]$_.status } } | Sort-Object id)
      nextAction=[string]$Contract.nextAction
    }
  }
}

function Rebind-PackageVersionContract {
  $allowedParameters = @(
    'Action','TaskId','WorkspaceKey','SessionKey','FromPackageVersion',
    'ExpectedRevision','ExpectedPlanFingerprint','ExpectedVisibleProgressReceiptHash',
    'TransitionId','ProjectRoot','StateRoot','NoExit','Json'
  )
  $unexpectedParameters = @($script:ExecutionContractBoundParameterNames | Where-Object { $_ -notin $allowedParameters })
  if ($unexpectedParameters.Count -gt 0) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_FIELDS_FORBIDDEN'; taskId=$TaskId; workspaceKey=$WorkspaceKey; forbidden=@($unexpectedParameters | Sort-Object); guard='A package-version rebind may only preserve one verified contract identity; it cannot change work, phase, proof input, authorization, or user instruction.' }
  }
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($WorkspaceKey) -or [string]::IsNullOrWhiteSpace($SessionKey)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_SCOPE_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A package-version rebind requires the exact task, workspace, and owning root session.' }
  }
  if ($FromPackageVersion -notmatch '^\d+\.\d+\.\d+$' -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+$' -or [string]$manifest.version -eq $FromPackageVersion) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_VERSION_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; fromVersion=$FromPackageVersion; toVersion=[string]$manifest.version; guard='The rebind must cross one explicit semantic-version boundary after the source manifest has changed.' }
  }
  if ($ExpectedRevision -lt 1 -or [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -or $ExpectedVisibleProgressReceiptHash -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($TransitionId) -or [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_EXPECTATIONS_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The rebind requires CAS revision, plan, visible-receipt, transition, and project-root bindings.' }
  }

  $record = Get-BoundContractRecord $TaskId $WorkspaceKey
  if ($record.identityConflict -or -not $record.contract) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_CONTRACT_MISSING'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Only one existing scoped execution contract may cross a package-version boundary.' }
  }
  $existing = $record.contract
  $sessionBlock = Get-ContractSessionMutationBlock $existing 'RebindPackageVersion'
  if ($sessionBlock) { return $sessionBlock }
  if ([string]$existing.status -ne 'active' -or [string]$existing.packageVersion -ne $FromPackageVersion -or [int]$existing.revision -ne $ExpectedRevision -or [string]$existing.planReceipt.planFingerprint -ne $ExpectedPlanFingerprint) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_CAS_MISMATCH'; taskId=$TaskId; workspaceKey=$WorkspaceKey; expectedRevision=$ExpectedRevision; actualRevision=[int]$existing.revision; expectedPlanFingerprint=$ExpectedPlanFingerprint; actualPlanFingerprint=[string]$existing.planReceipt.planFingerprint; fromVersion=$FromPackageVersion; actualVersion=[string]$existing.packageVersion; guard='The active contract changed after release preparation; reload current state and create a new explicit rebind request.' }
  }
  if ([string]$existing.lastConfirmedSource -ne 'assistant_visible_reply') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_VISIBLE_SOURCE_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A package-version rebind requires the current strict assistant-visible progress receipt, not a user attestation or an older summary.' }
  }
  $priorScope = Get-VisibleProgressScopeBindingHash $TaskId ([string]$existing.taskInstanceId) $WorkspaceKey ([string]$existing.ownerSessionKey) $FromPackageVersion
  $priorVisible = Test-VisibleProgressReceipt $existing.visibleProgressReceipt ([string]$existing.lastConfirmedSentence) ([string]$existing.lastConfirmedSource) ([string]$existing.currentPhase) ([string]$existing.currentStep) ([string]$existing.nextAction) $existing.projectProgressProof $priorScope
  if (-not $priorVisible.ok -or [string]$existing.visibleProgressReceipt.payloadHash -ne $ExpectedVisibleProgressReceiptHash) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_VISIBLE_RECEIPT_MISMATCH'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The package-version boundary must remain tied to the exact current H7 visible-progress receipt.' }
  }

  $rebasedProof = New-PackageVersionRebindInputProof $existing $ProjectRoot
  if (-not $rebasedProof.ok) {
    return [pscustomobject]@{ ok=$false; code=[string]$rebasedProof.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($rebasedProof.missing); guard='The release changed proof evidence beyond the allowed manifest identity boundary, so the prior stage must be revalidated before rebinding.' }
  }

  $saved = [ordered]@{
    packageVersionRebindActive=$script:PackageVersionRebindActive
    progressCheckpointWasBound=$script:ProgressCheckpointBase64WasBound
    projectProofWasBound=$script:ProjectProgressProofBase64WasBound
    lastConfirmedSentenceWasBound=$script:LastConfirmedSentenceWasBound
    lastConfirmedSourceWasBound=$script:LastConfirmedSourceWasBound
    currentPhaseWasBound=$script:CurrentPhaseWasBound
    currentStepWasBound=$script:CurrentStepWasBound
    nextActionWasBound=$script:NextActionWasBound
    projectRootWasBound=$script:ProjectRootWasBound
    projectProofInput=$script:ProjectProgressProofInput
    lastConfirmedSentence=$LastConfirmedSentence
    lastConfirmedSource=$LastConfirmedSource
    currentPhase=$CurrentPhase
    currentStep=$CurrentStep
    nextAction=$NextAction
    source=$Source
  }
  try {
    $rebindProofJson = $rebasedProof.input | ConvertTo-Json -Depth 16 -Compress
    $rebindProofBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rebindProofJson))
    $script:PackageVersionRebindActive = $true
    $script:ProgressCheckpointBase64WasBound = $true
    $script:ProjectProgressProofBase64WasBound = $true
    $script:LastConfirmedSentenceWasBound = $true
    $script:LastConfirmedSourceWasBound = $true
    $script:CurrentPhaseWasBound = $true
    $script:CurrentStepWasBound = $true
    $script:NextActionWasBound = $true
    $script:ProjectRootWasBound = $true
    $script:ProjectProgressProofInput = $rebasedProof.input
    $result = Set-Contract -PackageVersionRebindPayload ([pscustomobject]@{
      lastConfirmedSentence=[string]$existing.lastConfirmedSentence
      lastConfirmedSource='assistant_visible_reply'
      currentPhase=[string]$existing.currentPhase
      currentStep=[string]$existing.currentStep
      nextAction=[string]$existing.nextAction
      source='execution-contract.ps1:package-version-rebind'
      projectProgressProofBase64=$rebindProofBase64
    })
  } finally {
    $script:PackageVersionRebindActive = [bool]$saved.packageVersionRebindActive
    $script:ProgressCheckpointBase64WasBound = [bool]$saved.progressCheckpointWasBound
    $script:ProjectProgressProofBase64WasBound = [bool]$saved.projectProofWasBound
    $script:LastConfirmedSentenceWasBound = [bool]$saved.lastConfirmedSentenceWasBound
    $script:LastConfirmedSourceWasBound = [bool]$saved.lastConfirmedSourceWasBound
    $script:CurrentPhaseWasBound = [bool]$saved.currentPhaseWasBound
    $script:CurrentStepWasBound = [bool]$saved.currentStepWasBound
    $script:NextActionWasBound = [bool]$saved.nextActionWasBound
    $script:ProjectRootWasBound = [bool]$saved.projectRootWasBound
    $script:ProjectProgressProofInput = $saved.projectProofInput
  }
  if (-not $result -or $result.ok -ne $true) { return $result }
  if ([string]$result.packageVersion -ne [string]$manifest.version -or [string]$result.currentPhase -ne [string]$existing.currentPhase -or [string]$result.currentStep -ne [string]$existing.currentStep -or [string]$result.nextAction -ne [string]$existing.nextAction -or [string]$result.lastConfirmedSentence -ne [string]$existing.lastConfirmedSentence -or [string]$result.visibleProgressReceipt.source -ne 'assistant_visible_reply') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PACKAGE_VERSION_REBIND_PRESERVATION_FAILED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; contractCommitted=$true; contractRevision=[int]$result.revision; guard='The package-version rebind committed but did not preserve the exact task progress state; stop and repair from the current contract.' }
  }
  $result | Add-Member -NotePropertyName packageVersionRebind -NotePropertyValue ([pscustomobject]@{
    schema='super-brain.package-version-rebind.v1'
    fromVersion=$FromPackageVersion
    toVersion=[string]$manifest.version
    priorContractRevision=[int]$existing.revision
    priorVisibleProgressReceiptHash=$ExpectedVisibleProgressReceiptHash
    changedEvidence=@($rebasedProof.changedEvidence)
    source='h7_explicit_package_version_rebind'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }) -Force
  return $result
}

function Resume-ParentContract {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  $contractPath = Get-ContractPath $TaskId $WorkspaceKey
  return Invoke-SuperBrainFileLock $contractPath {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    if ($record.identityConflict) { throw 'EXECUTION_CONTRACT_IDENTITY_MISMATCH' }
    $existing = $record.contract
    $sessionBlock = Get-ContractSessionMutationBlock $existing 'ResumeParent'
    if ($sessionBlock) { return $sessionBlock }
    $resumeStackIntegrity = Protect-ReturnStackIntegrity $(if($existing -and $existing.PSObject.Properties['returnStack']){@($existing.returnStack)}else{@()}) $TaskId $WorkspaceKey $(if($existing){[string]$existing.focusId}else{''}) -UpgradeLegacy
    if (-not $resumeStackIntegrity.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$resumeStackIntegrity.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; currentFocusId=if($existing){[string]$existing.focusId}else{''}; reason=[string]$resumeStackIntegrity.reason; guard='The parent return path failed integrity validation. Do not restore or execute a modified parent plan.' }
    }
    $validity = Test-ContractCurrent $existing
    if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; reasons=@($validity.reasons); guard='Cannot resume a parent task without a current execution contract.' } }
    $instructionAnchorStatus = Get-ContractInstructionAnchorStatus $existing $TaskId $WorkspaceKey (Get-ContractSessionKey $existing)
    if (-not $instructionAnchorStatus.ok -or ($instructionAnchorStatus.required -and -not $instructionAnchorStatus.current)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; currentFocusId=if($existing){[string]$existing.focusId}else{''}; instructionAnchor=$instructionAnchorStatus; guard='The active branch has a newer unconsumed instruction anchor. Reconcile it before restoring a parent task.' }
    }
    $structuralFailure = Get-StructuralGuardFailure $existing 'ResumeParent'
    if ($structuralFailure) { return $structuralFailure }
    $transitionIdValue = Limit-ContractText $TransitionId 120
    $resumePayloadHash = if ([string]::IsNullOrWhiteSpace($transitionIdValue)) { '' } else { Get-TransitionPayloadHash ([ordered]@{
      action='ResumeParent'; taskId=$TaskId; workspaceKey=$WorkspaceKey; branchStatus=$BranchStatus; completionEvidence=Protect-Instruction $CompletionEvidence
      retainForMerge=[bool]$RetainForMerge; mergeTargetFocusId=Limit-ContractText $MergeTargetFocusId 120; mergeTargetLabel=Limit-ContractText $MergeTargetLabel 120; mergeTargetScope=$MergeTargetScope
      artifactRefs=@(Limit-MergeEvidenceList $ArtifactRefs 6 160); interfaceContracts=@(Limit-MergeEvidenceList $InterfaceContracts 5 160); dependencies=@(Limit-MergeEvidenceList $Dependencies 5 140)
      verificationSteps=@(Limit-MergeEvidenceList $VerificationSteps 6 140); mergeConditions=@(Limit-MergeEvidenceList $MergeConditions 5 140)
    }) }
    $transitionReceipts = @(Limit-TransitionReceipts $(if($existing -and $existing.PSObject.Properties['transitionReceipts']){@($existing.transitionReceipts)}else{@()}))
    if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) {
      $receipt = Get-TransitionReceipt $existing $transitionIdValue
      if ($receipt) {
        if ([string]$receipt.action -ne 'ResumeParent' -or [string]$receipt.payloadHash -ne $resumePayloadHash) {
          return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'; taskId=$TaskId; transitionId=$transitionIdValue; expectedAction=[string]$receipt.action; expectedPayloadHash=[string]$receipt.payloadHash; actualAction='ResumeParent'; actualPayloadHash=$resumePayloadHash; guard='The transition id is already bound to a different operation or payload.' }
        }
        return Complete-ContractContinuityMutation (New-TransitionReplayResult $existing $receipt) 'ResumeParentReplay'
      }
      if ($existing -and $existing.PSObject.Properties['lastTransition'] -and [string]$existing.lastTransition.transitionId -eq $transitionIdValue) {
        $legacyPayloadHash = if ($existing.lastTransition.PSObject.Properties['payloadHash']) { [string]$existing.lastTransition.payloadHash } else { '' }
        if ([string]$existing.lastTransition.action -ne 'ResumeParent' -or (-not [string]::IsNullOrWhiteSpace($legacyPayloadHash) -and $legacyPayloadHash -ne $resumePayloadHash)) {
          return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'; taskId=$TaskId; transitionId=$transitionIdValue; guard='The transition id is already bound to a different state transition.' }
        }
        $legacyReceipt = [pscustomobject]@{ transitionId=$transitionIdValue; resultRevision=if($existing.lastTransition.PSObject.Properties['toRevision']){[int]$existing.lastTransition.toRevision}else{[int]$existing.revision} }
        return Complete-ContractContinuityMutation (New-TransitionReplayResult $existing $legacyReceipt) 'ResumeParentReplay'
      }
    }
    if ($ExpectedRevision -ge 0 -and [int]$existing.revision -ne $ExpectedRevision) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_REVISION_MISMATCH'; taskId=$TaskId; expectedRevision=$ExpectedRevision; actualRevision=[int]$existing.revision; guard='The execution contract changed after the caller observed it. Resolve the current contract before resuming a parent.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and [string]$existing.planReceipt.planFingerprint -ne [string]$ExpectedPlanFingerprint) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH'; taskId=$TaskId; expectedPlanFingerprint=$ExpectedPlanFingerprint; actualPlanFingerprint=[string]$existing.planReceipt.planFingerprint; guard='The accepted plan changed after the caller observed it. Resolve the current contract before resuming a parent.' }
    }
    $existingClassification = if ($existing.PSObject.Properties['latestMessageClassification']) { $existing.latestMessageClassification } else { $null }
    if ($existing.needsReconciliation -eq $true -or -not (Test-ClassificationAuthorizesParentResume $existingClassification ([string]$existing.latestUserInstruction) ([string]$existing.focusId))) {
      return [pscustomobject]@{
        ok = $false
        code = 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
        taskId = $TaskId
        workspaceKey = $WorkspaceKey
        currentFocusId = [string]$existing.focusId
        latestMessageClassification = Remove-SuperBrainExecutableActions $existingClassification
        guard = 'The active branch has an unresolved user instruction. Reconcile it explicitly before restoring a parent task.'
      }
    }
    if (-not (Test-PlanReceiptCurrent $existing)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_STALE'; taskId=$TaskId; workspaceKey=$WorkspaceKey; currentFocusId=[string]$existing.focusId; guard='The active branch plan receipt is stale. Reconcile the latest visible plan before restoring its parent.' }
    }
    $stack = @($resumeStackIntegrity.cards)
    if ($stack.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_NO_PARENT'; taskId=$TaskId; currentFocusId=[string]$existing.focusId; guard='No suspended parent task is available.' } }
    $parent = $stack[-1]
    $canonicalPlanValue = if ($existing.PSObject.Properties['canonicalPlan']) { $existing.canonicalPlan } else { $null }
    if ($canonicalPlanValue -and ([string]$parent.canonicalPlanId -ne [string]$canonicalPlanValue.planId -or [int]$parent.canonicalGeneration -ne [int]$canonicalPlanValue.generation -or [string]$parent.canonicalFingerprint -ne [string]$canonicalPlanValue.currentFingerprint)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PARENT_STALE'; taskId=$TaskId; parentFocusId=[string]$parent.focusId; guard='The suspended parent card is not bound to the current canonical plan identity. Reconcile it before restoring the parent.' }
    }
    $parentActionStale = ($canonicalPlanValue -and ([string]$parent.actionBindingState -eq 'stale_canonical_change' -or [string]$parent.canonicalActionFingerprint -ne [string]$canonicalPlanValue.currentFingerprint))
    if($parentActionStale){
      if([string]$parent.focusId-ne[string]$canonicalPlanValue.rootFocusId){
        return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_PARENT_ACTION_RECONCILIATION_REQUIRED';taskId=$TaskId;parentFocusId=[string]$parent.focusId;guard='The suspended non-root parent action predates the current canonical plan and cannot be inferred safely.'}
      }
      $nextCanonicalItem=@($canonicalPlanValue.items|Where-Object{[string]$_.status-in@('pending','in_progress')}|Sort-Object {[int]$_.ordinal}|Select-Object -First 1)
      if($nextCanonicalItem.Count-eq0){
        return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_PARENT_ACTION_RECONCILIATION_REQUIRED';taskId=$TaskId;parentFocusId=[string]$parent.focusId;guard='The canonical parent changed and no remaining canonical action can be restored.'}
      }
      $parent.nextAction=Limit-ContractText ([string]$nextCanonicalItem[0].label) 220
      $parent.currentStep=[string]$parent.nextAction
      $parent.canonicalActionFingerprint=[string]$canonicalPlanValue.currentFingerprint
      $parent.actionBindingState='reconciled_from_canonical'
    }
    if ([string]::IsNullOrWhiteSpace([string]$parent.nextAction)) {
      return [pscustomobject]@{
        ok = $false
        code = 'EXECUTION_CONTRACT_PARENT_PLAN_MISSING'
        taskId = $TaskId
        currentFocusId = [string]$existing.focusId
        parentFocusId = [string]$parent.focusId
        guard = 'The suspended parent has no concrete next action. Recover a task-scoped plan or reconcile visible context before resuming.'
      }
    }
    $remaining = @(
      if ($stack.Count -gt 1) { @($stack[0..($stack.Count - 2)]) }
    )
    $sideBranchFocusId = [string]$existing.focusId
    $completionEvidence = Protect-Instruction $CompletionEvidence
    $branchCompleted = ($BranchStatus -eq 'completed' -and -not [string]::IsNullOrWhiteSpace($completionEvidence))
    $resolvedBranchStatus = if ($branchCompleted) { 'completed' } else { 'partial' }
    $completedWorkLines = @(Limit-WorkLineIds @($existing.completedWorkLines))
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($existing.PSObject.Properties['unfinishedWorkLines']) { @($existing.unfinishedWorkLines) } else { @() }) $(if ($existing.PSObject.Properties['unfinishedWorkPlans']) { @($existing.unfinishedWorkPlans) } else { @() })
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $mergeIntents = @(Limit-MergeIntents $(if ($existing.PSObject.Properties['mergeIntents']) { @($existing.mergeIntents) } else { @() }))
    $sideBranchPlan = ConvertTo-ReturnCard ([pscustomobject]@{
      focusId = $sideBranchFocusId
      focusLabel = if($existing.PSObject.Properties['focusLabel']){[string]$existing.focusLabel}else{''}
      nextAction = [string]$existing.nextAction
      assistantCommitment = [string]$existing.assistantCommitment
      constraints = @($existing.constraints)
      acceptanceCriteria = @($existing.acceptanceCriteria)
      currentPhase = if($existing.PSObject.Properties['currentPhase']){[string]$existing.currentPhase}elseif($existing.PSObject.Properties['continuityStateCard']){[string]$existing.continuityStateCard.phase}else{''}
      currentStep = if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}elseif($existing.PSObject.Properties['continuityStateCard']){[string]$existing.continuityStateCard.currentStep}else{''}
      completedSteps = if($existing.PSObject.Properties['completedSteps']){@($existing.completedSteps)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.completedSteps)}else{@()}
      pendingSteps = if($existing.PSObject.Properties['pendingSteps']){@($existing.pendingSteps)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.pendingSteps)}else{@()}
      blockers = if($existing.PSObject.Properties['blockers']){@($existing.blockers)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.blockers)}else{@()}
      evidence = if($existing.PSObject.Properties['evidence']){@($existing.evidence)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.evidence)}else{@()}
      verificationResults = if($existing.PSObject.Properties['verificationResults']){@($existing.verificationResults)}elseif($existing.PSObject.Properties['continuityStateCard']){@($existing.continuityStateCard.verificationResults)}else{@()}
      topicKeys = if($existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@()}
      topicKeySource = if($existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}
      prioritySource = if($existing.PSObject.Properties['prioritySource']){[string]$existing.prioritySource}else{'current_contract'}
      priorityReason = if($existing.PSObject.Properties['priorityReason']){[string]$existing.priorityReason}else{''}
      checklistUpdateMode = if($existing.PSObject.Properties['checklistUpdateMode']){[string]$existing.checklistUpdateMode}else{'additive'}
      lastConfirmedSentence = if($existing.PSObject.Properties['lastConfirmedSentence']){[string]$existing.lastConfirmedSentence}else{''}
      lastConfirmedSource = if($existing.PSObject.Properties['lastConfirmedSource']){[string]$existing.lastConfirmedSource}else{''}
      visibleProgressReceipt = if($existing.PSObject.Properties['visibleProgressReceipt']){$existing.visibleProgressReceipt}else{$null}
      planFingerprint = if($existing.PSObject.Properties['planReceipt'] -and $existing.planReceipt.PSObject.Properties['planFingerprint']){[string]$existing.planReceipt.planFingerprint}else{''}
      canonicalPlanId = if($canonicalPlanValue){[string]$canonicalPlanValue.planId}else{''}
      canonicalGeneration = if($canonicalPlanValue){[int]$canonicalPlanValue.generation}else{0}
      canonicalFingerprint = if($canonicalPlanValue){[string]$canonicalPlanValue.currentFingerprint}else{''}
      mergeCaptureRequest = if($existing.PSObject.Properties['mergeCaptureRequest']){$existing.mergeCaptureRequest}else{$null}
    })
    $existingMergeCaptureRequest = if ($existing.PSObject.Properties['mergeCaptureRequest']) { $existing.mergeCaptureRequest } else { $null }
    $explicitMergeRetention = ($script:RetainForMergeWasBound -or $script:MergeTargetFocusIdWasBound -or $script:MergeTargetLabelWasBound -or $script:MergeTargetScopeWasBound -or $script:ArtifactRefsWereBound -or $script:InterfaceContractsWereBound -or $script:DependenciesWereBound -or $script:VerificationStepsWereBound -or $script:MergeConditionsWereBound)
    $mergeCaptureRequest = New-MergeCaptureRequest $existingMergeCaptureRequest $stack $sideBranchFocusId $TaskId ($explicitMergeRetention -or $null -ne $existingMergeCaptureRequest) $MergeTargetFocusId $MergeTargetLabel $MergeTargetScope $ArtifactRefs $InterfaceContracts $Dependencies $VerificationSteps $MergeConditions $(if(-not [string]::IsNullOrWhiteSpace($Source)){[string]$Source}else{'execution-contract.ps1:ResumeParent'})
    $mergeIntent = if ($branchCompleted -and $mergeCaptureRequest) { New-MergeIntentFromBranch $TaskId $sideBranchPlan $parent $mergeCaptureRequest $completionEvidence ([int]$existing.revision) } else { $null }
    if ($mergeIntent) {
      $mergeIntents = @(Limit-MergeIntents (@($mergeIntents | Where-Object { [string]$_.sourceFocusId -ne $sideBranchFocusId }) + @($mergeIntent)))
    }
    if ($branchCompleted) {
      $completedWorkLines = @(Limit-WorkLineIds (@($completedWorkLines) + @($sideBranchFocusId)))
      $unfinishedState = Get-BoundedUnfinishedWorkState $unfinishedWorkLines $unfinishedWorkPlans @($sideBranchFocusId,[string]$parent.focusId)
    } else {
      $unfinishedState = Get-BoundedUnfinishedWorkState (@($unfinishedWorkLines) + @($sideBranchFocusId)) (@($unfinishedWorkPlans | Where-Object { [string]$_.focusId -ne $sideBranchFocusId }) + @($sideBranchPlan)) @([string]$parent.focusId)
    }
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $parentFocusLabel = if ($parent.PSObject.Properties['focusLabel']) { [string]$parent.focusLabel } else { Get-DefaultFocusLabel ([string]$parent.focusId) }
    $parentTopicKeys = if ($parent.PSObject.Properties['topicKeys']) { @($parent.topicKeys) } else { @(Get-DerivedTopicKeys ([string]$parent.focusId)) }
    $parentTopicKeySource = if ($parent.PSObject.Properties['topicKeySource']) { [string]$parent.topicKeySource } else { 'focus_id_derived' }
    $resumeClassification = [pscustomobject]@{
      mode='resume_parent'; topicAffinity='active'; targetLineId=[string]$parent.focusId; targetLineLabel=$parentFocusLabel; confidence='high'; matchedKeys=@('return_card'); candidateLineIds=@([string]$parent.focusId); needsClarification=$false; recommendedInstructionMode='continue'; reason='parent was restored from the bound return card'; rawInstructionStored=$false
    }
    $parentPhase = if ($parent.PSObject.Properties['currentPhase']) { [string]$parent.currentPhase } else { if($parent.PSObject.Properties['phase']){[string]$parent.phase}else{'resume_parent'} }
    $parentCurrentStep = if ($parent.PSObject.Properties['currentStep']) { [string]$parent.currentStep } else { [string]$parent.nextAction }
    $parentCompletedSteps = if ($parent.PSObject.Properties['completedSteps']) { @($parent.completedSteps) } else { @() }
    $parentPendingSteps = if ($parent.PSObject.Properties['pendingSteps']) { @($parent.pendingSteps) } else { if(-not [string]::IsNullOrWhiteSpace([string]$parentCurrentStep)){ @([string]$parentCurrentStep) }else{@()} }
    if ($canonicalPlanValue -and [string]$parent.focusId -eq [string]$canonicalPlanValue.rootFocusId) {
      $parentCanonicalProjection = Get-CanonicalPlanProjection $canonicalPlanValue
      $parentCompletedSteps = @($parentCanonicalProjection.completedSteps)
      $parentPendingSteps = @($parentCanonicalProjection.pendingSteps)
    }
    $parentChecklistUpdateMode = if ($parent.PSObject.Properties['checklistUpdateMode']) { [string]$parent.checklistUpdateMode } else { 'additive' }
    $parentLastConfirmedSentence = if ($parent.PSObject.Properties['lastConfirmedSentence']) { [string]$parent.lastConfirmedSentence } else { [string]$parent.assistantCommitment }
    $parentLastConfirmedSource = if ($parent.PSObject.Properties['lastConfirmedSource']) { [string]$parent.lastConfirmedSource } elseif (-not [string]::IsNullOrWhiteSpace($parentLastConfirmedSentence)) { 'assistant_commitment' } else { '' }
    $parentBlockers = if ($parent.PSObject.Properties['blockers']) { @($parent.blockers) } else { @() }
    $parentEvidence = if ($parent.PSObject.Properties['evidence']) { @($parent.evidence) } else { @() }
    $parentVerificationResults = if ($parent.PSObject.Properties['verificationResults']) { @($parent.verificationResults) } else { @() }
    $parentProjectProgressProof = if($parent.PSObject.Properties['projectProgressProof']){$parent.projectProgressProof}else{$null}
    $parentProjectProgress = New-ProjectProgressProof $ProjectRoot $parentPhase $parentCurrentStep $parentCompletedSteps $parentEvidence $parentVerificationResults ([string]$parent.nextAction) $null $parentProjectProgressProof
    if (-not $parentProjectProgress.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$parentProjectProgress.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($parentProjectProgress.missing); guard='The restored parent project-progress proof could not be validated without guessing its completed work.' }
    }
    $parentVisibleProgressReceipt = if($parent.PSObject.Properties['visibleProgressReceipt']){$parent.visibleProgressReceipt}else{$null}
    $parentVisibleProgressScopeBindingHash = Get-VisibleProgressScopeBindingHash $TaskId ([string]$existing.taskInstanceId) $WorkspaceKey (Get-ContractSessionKey $existing) ([string]$manifest.version)
    $parentVisibleProgressStatus = Test-VisibleProgressReceipt $parentVisibleProgressReceipt $parentLastConfirmedSentence $parentLastConfirmedSource $parentPhase $parentCurrentStep ([string]$parent.nextAction) $parentProjectProgress.proof $parentVisibleProgressScopeBindingHash
    if (-not $parentVisibleProgressStatus.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$parentVisibleProgressStatus.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; parentFocusId=[string]$parent.focusId; guard='A parent cannot resume from a stale or missing visible-progress recovery anchor. Reconcile its latest visible progress through H7 first.' }
    }
    $parentVisibleProgressReceipt = $parentVisibleProgressStatus.receipt
    $parentEvidence = @(Limit-ContractList (@($parentEvidence) + @($parentProjectProgress.evidenceRefs)) 8 180)
    $parentVerificationResults = @(Limit-ContractList (@($parentVerificationResults) + @($parentProjectProgress.verificationRefs)) 6 180)
    $revision = if ($existing.PSObject.Properties['revision']) { [int]$existing.revision + 1 } else { 1 }
    $taskInstanceIdValue=if($existing.PSObject.Properties['taskInstanceId']-and[string]$existing.taskInstanceId-match'^ti-[a-f0-9]{32}$'){[string]$existing.taskInstanceId}else{'ti-'+[guid]::NewGuid().ToString('n')}
    $intentContractRequiredValue = [bool]($existing.PSObject.Properties['intentContractRequired'] -and $existing.intentContractRequired -eq $true)
    $intentContractValue = if ($existing.PSObject.Properties['intentContract']) { $existing.intentContract } else { $null }
    $intentPreparedValue = $null
    $intentRevisionValue = if($existing.PSObject.Properties['intentRevision']){[int]$existing.intentRevision}else{0}
    $intentAggregateIdValue = if($existing.PSObject.Properties['intentAggregateId']){[string]$existing.intentAggregateId}else{''}
    if ($intentContractRequiredValue) {
      $intentPreparedValue = Prepare-IntentResolution $TaskId $taskInstanceIdValue $WorkspaceKey (Get-ContractSessionKey $existing) $intentContractValue
      if (-not $intentPreparedValue.ok) { return [pscustomobject]@{ ok=$false; code=[string]$intentPreparedValue.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentPreparedValue.missing); guard='A parent cannot resume until its retained intent is current in the canonical local control plane.' } }
      $intentContractValue = $intentPreparedValue.intentContract
      $intentRevisionValue = [int]$intentPreparedValue.intentRevision
      $intentAggregateIdValue = [string]$intentPreparedValue.aggregateId
    }
    $intentPlanBindingValue = if($intentContractRequiredValue){[pscustomobject]@{intentRevision=$intentRevisionValue;intentContractFingerprint=[string]$intentContractValue.contractFingerprint}}else{$null}
    if($canonicalPlanValue-and$intentPlanBindingValue-and(-not$canonicalPlanValue.PSObject.Properties['intentBinding']-or[int]$canonicalPlanValue.intentBinding.intentRevision-ne$intentRevisionValue-or[string]$canonicalPlanValue.intentBinding.intentContractFingerprint-ne[string]$intentContractValue.contractFingerprint)){
      return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_INTENT_BINDING_STALE';taskId=$TaskId;workspaceKey=$WorkspaceKey;guard='The suspended parent canonical plan is not bound to the current intent revision; reconcile it through Set before resuming.'}
    }
    $remaining = @(Bind-ReturnStackCanonicalPlan $remaining $canonicalPlanValue $TaskId $WorkspaceKey)
    $workLineStatusValue = New-WorkLineStatus ([string]$parent.focusId) $remaining $completedWorkLines $unfinishedWorkLines ([string]$parent.nextAction) ([string]$parent.assistantCommitment) @($parent.constraints) @($parent.acceptanceCriteria) $parentFocusLabel $parentTopicKeys $parentTopicKeySource 'restored_parent' 'nearest suspended parent resumed after side branch' $unfinishedWorkPlans $resumeClassification $mergeIntents $canonicalPlanValue $parentCompletedSteps $parentPendingSteps
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey (Get-ContractSessionKey $existing) $revision 'resume_parent' ([string]$parent.focusId) $parentFocusLabel $workLineStatusValue $remaining $parentPhase $parentCurrentStep $parentCompletedSteps $parentPendingSteps $parentBlockers $parentEvidence $parentVerificationResults ([string]$parent.nextAction) ([string]$parent.assistantCommitment) @($parent.constraints) @($parent.acceptanceCriteria) 'execution-contract.ps1:ResumeParent' $parentChecklistUpdateMode $parentLastConfirmedSentence $parentLastConfirmedSource $canonicalPlanValue $parentCompletedSteps $parentPendingSteps $parentProjectProgress.proof
    $resumedInstruction = Limit-ContractText ('Parent task resumed after side branch: ' + [string]$parent.focusId) 480
    $resumedLatestUserInstruction = if($existing.PSObject.Properties['instructionAnchor'] -and $existing.instructionAnchor -and -not [string]::IsNullOrWhiteSpace([string]$existing.instructionAnchor.instruction)){[string]$existing.instructionAnchor.instruction}elseif($existing.PSObject.Properties['latestUserInstruction'] -and -not [string]::IsNullOrWhiteSpace([string]$existing.latestUserInstruction)){[string]$existing.latestUserInstruction}else{$resumedInstruction}
    $resumedInstructionAnchor = if($existing.PSObject.Properties['instructionAnchor'] -and $existing.instructionAnchor){$existing.instructionAnchor}elseif($instructionAnchorStatus.anchor){$instructionAnchorStatus.anchor}else{$null}
    $planReceiptValue = New-PlanReceipt $TaskId $WorkspaceKey (Get-ContractSessionKey $existing) $revision ([string]$parent.focusId) $parentFocusLabel ([string]$parent.nextAction) $parentPhase $parentCurrentStep $parentPendingSteps @($parent.constraints) @($parent.acceptanceCriteria) $workLineStatusValue $resumedLatestUserInstruction 'execution-contract.ps1:ResumeParent' $parentCompletedSteps $(if($canonicalPlanValue){'super-brain.plan-receipt.v3'}else{'super-brain.plan-receipt.v2'}) $intentPlanBindingValue
    $newTransitionValue = if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) { [pscustomobject]@{ transitionId=$transitionIdValue; action='ResumeParent'; payloadHash=$resumePayloadHash; fromRevision=[int]$existing.revision; toRevision=$revision; fromFocusId=$sideBranchFocusId; toFocusId=[string]$parent.focusId; recordedAt=(Get-SuperBrainUtcTimestamp) } } elseif ($existing.PSObject.Properties['lastTransition']) { $existing.lastTransition } else { $null }
    $transitionReceiptsValue = if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) { @(Add-TransitionReceipt $transitionReceipts $transitionIdValue 'ResumeParent' $resumePayloadHash ([int]$existing.revision) $revision $sideBranchFocusId ([string]$parent.focusId)) } else { @($transitionReceipts) }
    $intentResolutionReceiptValue = $null
    if ($intentContractRequiredValue) {
      $intentResolution = Resolve-IntentResolution $intentPreparedValue $TaskId $taskInstanceIdValue $WorkspaceKey (Get-ContractSessionKey $existing) ([string]$manifest.version) $revision $planReceiptValue $resumedInstruction 'execution-contract.ps1:ResumeParent'
      if (-not $intentResolution.ok) { return [pscustomobject]@{ ok=$false; code=[string]$intentResolution.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentResolution.missing); guard='The resumed parent could not receive a current immutable intent receipt.' } }
      $intentContractValue = $intentResolution.intentContract
      $intentResolutionReceiptValue = $intentResolution.intentResolutionReceipt
    }
    $resumeStageKind = Get-ContractEffectiveDecisionStageKind $existing $StageKind $parentPhase
    $resumeDecisionIntent = Get-ContractDecisionIntentFingerprint $existing $intentContractValue $resumedInstruction $DecisionIntentFingerprint
    $resumeDecisionBinding = $null
    if (-not [string]::IsNullOrWhiteSpace($resumeStageKind)) {
      $resumeDecisionSeed = [pscustomobject]@{ taskInstanceId=$taskInstanceIdValue; focusId=[string]$parent.focusId; ownerSessionKey=(Get-ContractSessionKey $existing) }
      $resumeDecisionResolution = Invoke-ContractDecisionBinding 'Resolve' $resumeDecisionSeed $resumeStageKind $resumeDecisionIntent $revision $planReceiptValue
      if (-not $resumeDecisionResolution.ok) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DECISION_BINDING_WITHHELD'; taskId=$TaskId; workspaceKey=$WorkspaceKey; stageKind=$resumeStageKind; decisionBindingStatus=$resumeDecisionResolution.status; decisionBindingCode=$resumeDecisionResolution.code; reasons=@($resumeDecisionResolution.reasons); guard='The parent stage cannot resume until its current completion-decision receipt is reconciled.' }
      }
      $resumeDecisionBinding = $resumeDecisionResolution.binding
    }
    $value = [pscustomobject]@{
      ok = $true
      schema = 'super-brain.execution-contract.v1'
      taskId = $TaskId
      taskInstanceId = $taskInstanceIdValue
      workspaceKey = $WorkspaceKey
      ownerSessionKey = Get-ContractSessionKey $existing
      sessionBound = (-not [string]::IsNullOrWhiteSpace((Get-ContractSessionKey $existing)))
      structuralGuardsRequired = ($existing.PSObject.Properties['structuralGuardsRequired'] -and $existing.structuralGuardsRequired -eq $true)
      packageVersion = [string]$manifest.version
      revision = $revision
      status = 'active'
      focusId = [string]$parent.focusId
      focusLabel = $parentFocusLabel
      instructionMode = 'resume_parent'
      returnStack = @($remaining)
      returnTo = if ($remaining.Count -gt 0) { $remaining[-1] } else { $null }
      canResumeParent = ($remaining.Count -gt 0)
      completedWorkLines = @($completedWorkLines)
      unfinishedWorkLines = @($unfinishedWorkLines)
      unfinishedWorkPlans = @($unfinishedWorkPlans)
      mergeCaptureRequest = if($parent.PSObject.Properties['mergeCaptureRequest']){$parent.mergeCaptureRequest}else{$null}
      mergeIntents = @($mergeIntents)
      canonicalPlan = $canonicalPlanValue
      workLineStatus = $workLineStatusValue
      continuityStateCard = $stateCardValue
      phaseCloseouts = @(Get-SuperBrainPhaseCloseoutEntries $existing)
      phaseEvidencePolicy = Get-ContractPhaseEvidencePolicy $existing
      planReceiptRequired = $true
      planReceipt = $planReceiptValue
      intentContractRequired = $intentContractRequiredValue
      intentAggregateId = $intentAggregateIdValue
      intentRevision = $intentRevisionValue
      intentContract = $intentContractValue
      intentResolutionReceipt = $intentResolutionReceiptValue
      stageKind = $resumeStageKind
      decisionIntentFingerprint = $resumeDecisionIntent
      decisionBinding = $resumeDecisionBinding
      latestUserInstruction = $resumedLatestUserInstruction
      instructionAnchor = $resumedInstructionAnchor
      latestMessageClassification = $resumeClassification
      assistantCommitment = [string]$parent.assistantCommitment
      lastConfirmedSentence = $parentLastConfirmedSentence
      lastConfirmedSource = $parentLastConfirmedSource
      nextAction = [string]$parent.nextAction
      currentPhase = $parentPhase
      currentStep = $parentCurrentStep
      completedSteps = @($parentCompletedSteps)
      pendingSteps = @($parentPendingSteps)
      checklistUpdateMode = $parentChecklistUpdateMode
      supersededChecklistSteps = @()
      blockers = @($parentBlockers)
      evidence = @($parentEvidence)
      verificationResults = @($parentVerificationResults)
      projectProgressProof = $parentProjectProgress.proof
      visibleProgressReceipt = $parentVisibleProgressReceipt
      constraints = @($parent.constraints)
      topicKeys = @($parentTopicKeys)
      topicKeySource = $parentTopicKeySource
      prioritySource = 'restored_parent'
      priorityReason = 'nearest suspended parent resumed after side branch'
      invalidatedWorkItems = @($existing.invalidatedWorkItems)
      acceptanceCriteria = @($parent.acceptanceCriteria)
      needsReconciliation = $false
      updatedAt = (Get-SuperBrainUtcTimestamp)
      source = 'execution-contract.ps1:ResumeParent'
      completedSideBranchFocusId = if ($branchCompleted) { $sideBranchFocusId } else { '' }
      partialSideBranchFocusId = if ($branchCompleted) { '' } else { $sideBranchFocusId }
      resumedBranchStatus = $resolvedBranchStatus
      completionEvidence = if ($branchCompleted) { $completionEvidence } else { '' }
      transitionReceipts = @($transitionReceiptsValue)
      lastTransition = $newTransitionValue
      rawPromptStored = $false
      rawTranscriptStored = $false
      rawSessionIdStored = $false
      retention = 'latest_task_contract_plus_bounded_return_stack_and_merge_dossiers'
      path = $contractPath
    }
    return Complete-ContractContinuityMutation $value 'ResumeParent'
  }
}

function Get-ContractTurnClosePolicyResolution([object]$Resolution) {
  $blockers = if ($Resolution -and $Resolution.PSObject.Properties['blockers']) { @(Limit-ContractList @($Resolution.blockers) 12 220) } else { @() }
  return [ordered]@{
    ok = [bool]($Resolution -and $Resolution.ok -eq $true)
    actionAuthorization = if ($Resolution -and $Resolution.PSObject.Properties['actionAuthorization']) { [string]$Resolution.actionAuthorization } else { '' }
    claimAllowed = [bool]($Resolution -and $Resolution.PSObject.Properties['claimAllowed'] -and $Resolution.claimAllowed -eq $true)
    needsConfirmation = [bool]($Resolution -and $Resolution.PSObject.Properties['needsConfirmation'] -and $Resolution.needsConfirmation -eq $true)
    blockers = @($blockers)
    nextAction = if ($Resolution -and $Resolution.PSObject.Properties['nextAction']) { Limit-ContractText ([string]$Resolution.nextAction) 360 } else { '' }
    canResumeParent = [bool]($Resolution -and $Resolution.PSObject.Properties['canResumeParent'] -and $Resolution.canResumeParent -eq $true)
  }
}

function Invoke-ContractTurnClosePolicy([object]$Resolution,[string]$Outcome,[string]$Control,[bool]$CompletionEvidencePresent) {
  $policyPath = Join-Path $Root 'runtime\continuation_policy.py'
  if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_MISSING'; error='continuation_policy.py is unavailable' }
  }
  $pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pythonCommand) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_PYTHON_MISSING'; error='python is unavailable' }
  }
  $request = [ordered]@{
    resolution = Get-ContractTurnClosePolicyResolution $Resolution
    turnOutcome = [string]$Outcome
    userControl = [string]$Control
    completionEvidencePresent = [bool]$CompletionEvidencePresent
  }
  $payload = $request | ConvertTo-Json -Depth 6 -Compress
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = [string]$pythonCommand.Source
  $startInfo.Arguments = '-X utf8 "' + $policyPath.Replace('"','\"') + '" --stdin'
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_START_FAILED'; error='policy process did not start' }
    }
    $utf8Input = [IO.StreamWriter]::new($process.StandardInput.BaseStream,[Text.UTF8Encoding]::new($false))
    $utf8Input.Write($payload)
    $utf8Input.Close()
    if (-not $process.WaitForExit(5000)) {
      try { $process.Kill() } catch {}
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_TIMEOUT'; error='policy process exceeded its bounded timeout' }
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_FAILED'; error=(Limit-ContractText $stderr 180) }
    }
    try { $value = $stdout | ConvertFrom-Json } catch {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_PROTOCOL_INVALID'; error=(Limit-ContractText $_.Exception.Message 180) }
    }
    $validDecisions = @('continue_current_turn','resume_parent_required','pause_with_blocker','withhold_reconcile')
    if (-not $value -or $value.ok -ne $true -or [string]$value.schema -ne 'super-brain.continuation-policy.v1' -or $validDecisions -notcontains [string]$value.decision) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_PROTOCOL_INVALID'; error='policy returned an invalid decision packet' }
    }
    return [pscustomobject]@{ ok=$true; code=[string]$value.code; value=$value }
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_POLICY_FAILED'; error=(Limit-ContractText $_.Exception.Message 180) }
  } finally {
    $process.Dispose()
  }
}

function Invoke-ContractTurnCloseResume([string]$ResolvedBranchStatus) {
  $previousBranchStatus = $script:BranchStatus
  try {
    $script:BranchStatus = $ResolvedBranchStatus
    return Resume-ParentContract
  } finally {
    $script:BranchStatus = $previousBranchStatus
  }
}

function Complete-ContractTurnCloseResume([object]$Result,[string]$PolicyDecision,[string]$PolicyCode,[string]$Outcome) {
  if (-not $Result) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_RESUME_EMPTY'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The parent-resume transition returned no result.' }
  }
  if ($Result.ok -ne $true) { return $Result }
  $Result | Add-Member -NotePropertyName decision -NotePropertyValue 'auto_resumed' -Force
  $Result | Add-Member -NotePropertyName policyDecision -NotePropertyValue $PolicyDecision -Force
  $Result | Add-Member -NotePropertyName policyCode -NotePropertyValue $PolicyCode -Force
  $Result | Add-Member -NotePropertyName transitionAction -NotePropertyValue 'ResumeParent' -Force
  $Result | Add-Member -NotePropertyName turnOutcome -NotePropertyValue $Outcome -Force
  $Result | Add-Member -NotePropertyName source -NotePropertyValue 'execution-contract.ps1:CloseTurn' -Force
  $Result | Add-Member -NotePropertyName rawPromptStored -NotePropertyValue $false -Force
  $Result | Add-Member -NotePropertyName rawTranscriptStored -NotePropertyValue $false -Force
  return $Result
}

function Close-TurnContract {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }

  # A replay remains valid even after the first transition restored the parent.
  # Let ResumeParent verify the original transition payload rather than treating
  # the now-empty return stack as a new request.
  $transitionIdValue = Limit-ContractText $TransitionId 120
  if ($TurnOutcome -in @('side_branch_completed','side_branch_partial') -and -not [string]::IsNullOrWhiteSpace($transitionIdValue)) {
    $replayRecord = Get-BoundContractRecord $TaskId $WorkspaceKey
    if ($replayRecord -and -not $replayRecord.identityConflict -and $replayRecord.contract) {
      $priorReceipt = Get-TransitionReceipt $replayRecord.contract $transitionIdValue
      if ($priorReceipt) {
        $replayed = Invoke-ContractTurnCloseResume $(if($TurnOutcome -eq 'side_branch_completed'){'completed'}else{'partial'})
        return Complete-ContractTurnCloseResume $replayed 'resume_parent_required' 'CONTINUATION_POLICY_RESUME_PARENT_REQUIRED' $TurnOutcome
      }
    }
  }

  $resolution = Resolve-Contract
  if (-not $resolution -or $resolution.ok -ne $true) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_RESOLUTION_FAILED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='The current task must resolve before a turn-close continuation can be scheduled.' }
  }
  $policy = Invoke-ContractTurnClosePolicy $resolution $TurnOutcome $UserControl (-not [string]::IsNullOrWhiteSpace((Protect-Instruction $CompletionEvidence)))
  if (-not $policy.ok) {
    return [pscustomobject]@{ ok=$false; code=[string]$policy.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='Turn-close policy was unavailable, so no parent transition was attempted.' }
  }
  $decision = [string]$policy.value.decision
  if ($decision -eq 'resume_parent_required') {
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($transitionIdValue)) { $missing += 'TransitionId' }
    if ($ExpectedRevision -lt 0) { $missing += 'ExpectedRevision' }
    if ([string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) { $missing += 'ExpectedPlanFingerprint' }
    if ($missing.Count -gt 0) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUATION_CAS_REQUIRED'; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($missing); guard='Automatic parent restoration requires a caller-bound revision, plan fingerprint, and idempotent transition id.' }
    }
    $resumed = Invoke-ContractTurnCloseResume ([string]$policy.value.branchStatus)
    return Complete-ContractTurnCloseResume $resumed $decision ([string]$policy.value.code) $TurnOutcome
  }

  $authorized = ($decision -eq 'continue_current_turn')
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.turn-close-continuation.v1'
    taskId = $TaskId
    workspaceKey = $WorkspaceKey
    decision = $decision
    policyDecision = $decision
    policyCode = [string]$policy.value.code
    terminalReplyAllowed = [bool]$policy.value.terminalReplyAllowed
    transitionAction = ''
    turnOutcome = $TurnOutcome
    actionAuthorization = if($authorized){'allowed'}else{'withheld'}
    nextAction = if($authorized){[string]$resolution.nextAction}else{''}
    guard = if($authorized){'The handled insertion must return to the current authorized work line in this turn.'}elseif($decision -eq 'pause_with_blocker'){'A concrete blocker or explicit user terminal control permits a pause; no parent transition was attempted.'}else{'The current turn was not sufficiently attested for automatic continuation; reconcile before mutation.'}
    rawPromptStored = $false
    rawTranscriptStored = $false
    source = 'execution-contract.ps1:CloseTurn'
  }
}

function Prepare-MergeContract {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $sessionBlock = Get-ContractSessionMutationBlock $contract 'PrepareMerge'
  if ($sessionBlock) { return $sessionBlock }
  $validity = Test-ContractCurrent $contract
  if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; reasons=@($validity.reasons); guard='A current task contract is required before preparing a retained branch merge.' } }
  if ($contract.needsReconciliation -eq $true -or -not (Test-PlanReceiptCurrent $contract)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_RECONCILIATION_REQUIRED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; guard='Reconcile the current target work line and plan receipt before preparing a retained branch merge.' }
  }
  $intentId = Limit-ContractText $MergeIntentId 80
  if ([string]::IsNullOrWhiteSpace($intentId)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_INTENT_REQUIRED'; taskId=$TaskId; guard='A specific retained merge intent id is required; generic merge wording must not select a branch.' } }
  $intent = @(Limit-MergeIntents $(if($contract.PSObject.Properties['mergeIntents']){@($contract.mergeIntents)}else{@()}) | Where-Object { [string]$_.mergeIntentId -eq $intentId } | Select-Object -First 1)
  if ($intent.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_INTENT_NOT_FOUND'; taskId=$TaskId; mergeIntentId=$intentId; guard='The requested retained branch dossier is unavailable. Do not reconstruct or reimplement it from memory.' } }
  $intent = $intent[0]
  if ([string]$intent.status -eq 'integrated') { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_ALREADY_COMPLETED'; taskId=$TaskId; mergeIntentId=$intentId; integrationEvidence=[string]$intent.integrationEvidence; guard='This retained branch merge is already recorded as complete; do not repeat it.' } }
  if ([string]$intent.targetFocusId -ne [string]$contract.focusId) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_TARGET_NOT_ACTIVE'; taskId=$TaskId; mergeIntentId=$intentId; currentFocusId=[string]$contract.focusId; targetFocusId=[string]$intent.targetFocusId; targetFocusLabel=[string]$intent.targetFocusLabel; guard='Restore the intended target work line through its parent chain before preparing this merge.' }
  }
  $readiness = Get-MergeIntentReadiness $intent
  if (-not $readiness.ready) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_EVIDENCE_INCOMPLETE'; taskId=$TaskId; mergeIntentId=$intentId; sourceFocusId=[string]$intent.sourceFocusId; targetFocusId=[string]$intent.targetFocusId; missingEvidence=@($readiness.missing); mergeIntent=$intent; guard='The retained branch dossier lacks required evidence. Ask for the missing artifact or verification evidence; do not reimplement the branch.' }
  }
  return [pscustomobject]@{
    ok=$true
    action='PrepareMerge'
    taskId=$TaskId
    workspaceKey=$WorkspaceKey
    contractRevision=[int]$contract.revision
    planFingerprint=[string]$contract.planReceipt.planFingerprint
    mergeIntent=$intent
    requiredSteps=@('read_retained_branch_dossier','verify_target_interface_and_dependencies','perform_one_bounded_integration','record_integration_evidence')
    guard='The retained branch dossier is verified for review. Integrate its existing artifacts only; do not recreate the branch from memory.'
  }
}

function Complete-MergeContract {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  $contractPath = Get-ContractPath $TaskId $WorkspaceKey
  return Invoke-SuperBrainFileLock $contractPath {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    if ($record.identityConflict) { throw 'EXECUTION_CONTRACT_IDENTITY_MISMATCH' }
    $existing = $record.contract
    $sessionBlock = Get-ContractSessionMutationBlock $existing 'CompleteMerge'
    if ($sessionBlock) { return $sessionBlock }
    $structuralFailure = Get-StructuralGuardFailure $existing 'CompleteMerge'
    if ($structuralFailure) { return $structuralFailure }
    $transitionIdValue = Limit-ContractText $TransitionId 120
    $intentId = Limit-ContractText $MergeIntentId 80
    $integrationEvidence = Limit-ContractText (Protect-Instruction $MergeIntegrationEvidence) 240
    $mergePayloadHash = if ([string]::IsNullOrWhiteSpace($transitionIdValue)) { '' } else { Get-TransitionPayloadHash ([ordered]@{
      action='CompleteMerge'; taskId=$TaskId; workspaceKey=$WorkspaceKey; mergeIntentId=$intentId; integrationEvidence=$integrationEvidence
    }) }
    $transitionReceipts = @(Limit-TransitionReceipts $(if($existing -and $existing.PSObject.Properties['transitionReceipts']){@($existing.transitionReceipts)}else{@()}))
    if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) {
      $receipt = Get-TransitionReceipt $existing $transitionIdValue
      if ($receipt) {
        if ([string]$receipt.action -ne 'CompleteMerge' -or [string]$receipt.payloadHash -ne $mergePayloadHash) {
          return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'; taskId=$TaskId; transitionId=$transitionIdValue; expectedAction=[string]$receipt.action; expectedPayloadHash=[string]$receipt.payloadHash; actualAction='CompleteMerge'; actualPayloadHash=$mergePayloadHash; guard='The transition id is already bound to a different operation or payload.' }
        }
        return Complete-ContractContinuityMutation (New-TransitionReplayResult $existing $receipt) 'CompleteMergeReplay'
      }
    }
    $validity = Test-ContractCurrent $existing
    if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; reasons=@($validity.reasons); guard='A current task contract is required before recording merge completion.' } }
    if ($ExpectedRevision -ge 0 -and [int]$existing.revision -ne $ExpectedRevision) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_REVISION_MISMATCH'; taskId=$TaskId; expectedRevision=$ExpectedRevision; actualRevision=[int]$existing.revision; guard='The contract changed after the merge was prepared. Resolve and prepare again before completion.' } }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and [string]$existing.planReceipt.planFingerprint -ne [string]$ExpectedPlanFingerprint) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH'; taskId=$TaskId; guard='The accepted target plan changed after the merge was prepared. Resolve and prepare again before completion.' } }
    if ($existing.needsReconciliation -eq $true -or -not (Test-PlanReceiptCurrent $existing)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_RECONCILIATION_REQUIRED'; taskId=$TaskId; guard='Reconcile the current target work line and plan receipt before recording merge completion.' } }
    if ([string]::IsNullOrWhiteSpace($intentId) -or [string]::IsNullOrWhiteSpace($integrationEvidence)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_COMPLETION_EVIDENCE_REQUIRED'; taskId=$TaskId; guard='CompleteMerge requires one exact retained merge intent id and concise integration evidence.' } }
    $existingIntents = @(Limit-MergeIntents $(if($existing.PSObject.Properties['mergeIntents']){@($existing.mergeIntents)}else{@()}))
    $targetIntent = @($existingIntents | Where-Object { [string]$_.mergeIntentId -eq $intentId } | Select-Object -First 1)
    if ($targetIntent.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_INTENT_NOT_FOUND'; taskId=$TaskId; mergeIntentId=$intentId; guard='The requested retained branch dossier is unavailable. Do not mark an inferred merge as complete.' } }
    $targetIntent = $targetIntent[0]
    if ([string]$targetIntent.status -eq 'integrated') { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_ALREADY_COMPLETED'; taskId=$TaskId; mergeIntentId=$intentId; integrationEvidence=[string]$targetIntent.integrationEvidence; guard='This retained branch merge is already recorded as complete; do not duplicate it.' } }
    if ([string]$targetIntent.targetFocusId -ne [string]$existing.focusId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_TARGET_NOT_ACTIVE'; taskId=$TaskId; mergeIntentId=$intentId; currentFocusId=[string]$existing.focusId; targetFocusId=[string]$targetIntent.targetFocusId; guard='The merge target is not the active work line. Restore it through the parent chain before completion.' } }
    $readiness = Get-MergeIntentReadiness $targetIntent
    if (-not $readiness.ready) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MERGE_EVIDENCE_INCOMPLETE'; taskId=$TaskId; mergeIntentId=$intentId; missingEvidence=@($readiness.missing); guard='The retained branch dossier still lacks required evidence. Do not mark the merge complete.' } }
    $updatedIntents = @()
    foreach ($intent in $existingIntents) {
      if ([string]$intent.mergeIntentId -ne $intentId) { $updatedIntents += $intent; continue }
      $updated = ConvertTo-MergeIntent $intent
      $updated.status = 'integrated'
      $updated.integratedAt = (Get-SuperBrainUtcTimestamp)
      $updated.integrationEvidence = $integrationEvidence
      $updatedIntents += $updated
    }
    $updatedIntents = @(Limit-MergeIntents $updatedIntents)
    $canonicalPlanValue = if ($existing.PSObject.Properties['canonicalPlan']) { $existing.canonicalPlan } else { $null }
    $returnStack = @(Bind-ReturnStackCanonicalPlan @(Limit-ReturnStack @($existing.returnStack)) $canonicalPlanValue $TaskId $WorkspaceKey)
    $completedWorkLines = if ($existing.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($existing.completedWorkLines)) } else { @() }
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if($existing.PSObject.Properties['unfinishedWorkLines']){@($existing.unfinishedWorkLines)}else{@()}) $(if($existing.PSObject.Properties['unfinishedWorkPlans']){@($existing.unfinishedWorkPlans)}else{@()}) @([string]$existing.focusId)
    $revision = [int]$existing.revision + 1
    $taskInstanceIdValue = if($existing.PSObject.Properties['taskInstanceId'] -and [string]$existing.taskInstanceId -match '^ti-[a-f0-9]{32}$'){[string]$existing.taskInstanceId}else{'ti-'+[guid]::NewGuid().ToString('n')}
    $intentContractRequiredValue = [bool]($existing.PSObject.Properties['intentContractRequired'] -and $existing.intentContractRequired -eq $true)
    $intentContractValue = if ($existing.PSObject.Properties['intentContract']) { $existing.intentContract } else { $null }
    $intentPreparedValue = $null
    $intentRevisionValue = if($existing.PSObject.Properties['intentRevision']){[int]$existing.intentRevision}else{0}
    $intentAggregateIdValue = if($existing.PSObject.Properties['intentAggregateId']){[string]$existing.intentAggregateId}else{''}
    if ($intentContractRequiredValue) {
      $intentPreparedValue = Prepare-IntentResolution $TaskId $taskInstanceIdValue $WorkspaceKey (Get-ContractSessionKey $existing) $intentContractValue
      if (-not $intentPreparedValue.ok) { return [pscustomobject]@{ ok=$false; code=[string]$intentPreparedValue.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentPreparedValue.missing); guard='A retained merge cannot mutate the active plan until its task intent is current in the canonical control plane.' } }
      $intentContractValue = $intentPreparedValue.intentContract
      $intentRevisionValue = [int]$intentPreparedValue.intentRevision
      $intentAggregateIdValue = [string]$intentPreparedValue.aggregateId
    }
    $intentPlanBindingValue = if($intentContractRequiredValue){[pscustomobject]@{intentRevision=$intentRevisionValue;intentContractFingerprint=[string]$intentContractValue.contractFingerprint}}else{$null}
    if($canonicalPlanValue-and$intentPlanBindingValue-and(-not$canonicalPlanValue.PSObject.Properties['intentBinding']-or[int]$canonicalPlanValue.intentBinding.intentRevision-ne$intentRevisionValue-or[string]$canonicalPlanValue.intentBinding.intentContractFingerprint-ne[string]$intentContractValue.contractFingerprint)){
      return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_INTENT_BINDING_STALE';taskId=$TaskId;workspaceKey=$WorkspaceKey;guard='The active canonical plan is not bound to the current intent revision; reconcile it before completing the merge.'}
    }
    $focusLabelValue = if($existing.PSObject.Properties['focusLabel']){[string]$existing.focusLabel}else{Get-DefaultFocusLabel ([string]$existing.focusId)}
    $topicKeys = if($existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@(Get-DerivedTopicKeys ([string]$existing.focusId))}
    $topicKeySource = if($existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}
    $classification = [pscustomobject]@{ mode='continue'; topicAffinity='active'; targetLineId=[string]$existing.focusId; targetLineLabel=$focusLabelValue; confidence='high'; matchedKeys=@('merge_completion_receipt'); candidateLineIds=@([string]$existing.focusId); needsClarification=$false; recommendedInstructionMode='continue'; reason='retained branch integration completion was recorded against the active target'; rawInstructionStored=$false }
    $workPackageCompleted = if($existing.PSObject.Properties['completedSteps']){@($existing.completedSteps)}else{@()}
    $workPackagePending = if($existing.PSObject.Properties['pendingSteps']){@($existing.pendingSteps)}else{@()}
    $mergeEvidence = if($existing.PSObject.Properties['evidence']){@($existing.evidence)}else{@()}
    $mergeVerificationResults = if($existing.PSObject.Properties['verificationResults']){@($existing.verificationResults)}else{@()}
    $mergeProjectProgress = New-ProjectProgressProof $ProjectRoot $(if($existing.PSObject.Properties['currentPhase']){[string]$existing.currentPhase}else{[string]$existing.instructionMode}) $(if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}else{[string]$existing.nextAction}) $workPackageCompleted $mergeEvidence $mergeVerificationResults ([string]$existing.nextAction) $null $(if($existing.PSObject.Properties['projectProgressProof']){$existing.projectProgressProof}else{$null})
    if (-not $mergeProjectProgress.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$mergeProjectProgress.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($mergeProjectProgress.missing); guard='The merge transition cannot retain an unverified project-progress claim.' }
    }
    $mergeVisibleProgressReceipt = if($existing.PSObject.Properties['visibleProgressReceipt']){$existing.visibleProgressReceipt}else{$null}
    $mergeVisibleProgressScopeBindingHash = Get-VisibleProgressScopeBindingHash $TaskId $taskInstanceIdValue $WorkspaceKey (Get-ContractSessionKey $existing) ([string]$manifest.version)
    $mergeVisibleProgressStatus = Test-VisibleProgressReceipt $mergeVisibleProgressReceipt $(if($existing.PSObject.Properties['lastConfirmedSentence']){[string]$existing.lastConfirmedSentence}else{[string]$existing.assistantCommitment}) $(if($existing.PSObject.Properties['lastConfirmedSource']){[string]$existing.lastConfirmedSource}else{'assistant_commitment'}) $(if($existing.PSObject.Properties['currentPhase']){[string]$existing.currentPhase}else{[string]$existing.instructionMode}) $(if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}else{[string]$existing.nextAction}) ([string]$existing.nextAction) $mergeProjectProgress.proof $mergeVisibleProgressScopeBindingHash
    if (-not $mergeVisibleProgressStatus.ok) {
      return [pscustomobject]@{ ok=$false; code=[string]$mergeVisibleProgressStatus.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A merge cannot mutate an active task with a stale or missing visible-progress recovery anchor. Reconcile the latest H7 checkpoint first.' }
    }
    $mergeVisibleProgressReceipt = $mergeVisibleProgressStatus.receipt
    $mergeEvidence = @(Limit-ContractList (@($mergeEvidence) + @($mergeProjectProgress.evidenceRefs)) 8 180)
    $mergeVerificationResults = @(Limit-ContractList (@($mergeVerificationResults) + @($mergeProjectProgress.verificationRefs)) 6 180)
    $workLineStatus = New-WorkLineStatus ([string]$existing.focusId) $returnStack $completedWorkLines @($unfinishedState.lines) ([string]$existing.nextAction) ([string]$existing.assistantCommitment) @($existing.constraints) @($existing.acceptanceCriteria) $focusLabelValue $topicKeys $topicKeySource $(if($existing.PSObject.Properties['prioritySource']){[string]$existing.prioritySource}else{'current_contract'}) $(if($existing.PSObject.Properties['priorityReason']){[string]$existing.priorityReason}else{''}) @($unfinishedState.plans) $classification $updatedIntents $canonicalPlanValue $workPackageCompleted $workPackagePending
    $stateCard = New-ContinuityStateCard $TaskId $WorkspaceKey (Get-ContractSessionKey $existing) $revision ([string]$existing.instructionMode) ([string]$existing.focusId) $focusLabelValue $workLineStatus $returnStack $(if($existing.PSObject.Properties['currentPhase']){[string]$existing.currentPhase}else{[string]$existing.instructionMode}) $(if($existing.PSObject.Properties['currentStep']){[string]$existing.currentStep}else{[string]$existing.nextAction}) $workPackageCompleted $workPackagePending $(if($existing.PSObject.Properties['blockers']){@($existing.blockers)}else{@()}) $mergeEvidence $mergeVerificationResults ([string]$existing.nextAction) ([string]$existing.assistantCommitment) @($existing.constraints) @($existing.acceptanceCriteria) 'execution-contract.ps1:CompleteMerge' $(if($existing.PSObject.Properties['checklistUpdateMode']){[string]$existing.checklistUpdateMode}else{'additive'}) $(if($existing.PSObject.Properties['lastConfirmedSentence']){[string]$existing.lastConfirmedSentence}else{[string]$existing.assistantCommitment}) $(if($existing.PSObject.Properties['lastConfirmedSource']){[string]$existing.lastConfirmedSource}else{'assistant_commitment'}) $canonicalPlanValue $workPackageCompleted $workPackagePending $mergeProjectProgress.proof
    $receiptInstruction = Limit-ContractText ('Retained branch merge completed: ' + $intentId) 480
    $planReceipt = New-PlanReceipt $TaskId $WorkspaceKey (Get-ContractSessionKey $existing) $revision ([string]$existing.focusId) $focusLabelValue ([string]$existing.nextAction) ([string]$stateCard.phase) ([string]$stateCard.currentStep) $workPackagePending @($existing.constraints) @($existing.acceptanceCriteria) $workLineStatus $receiptInstruction 'execution-contract.ps1:CompleteMerge' $workPackageCompleted $(if($canonicalPlanValue){'super-brain.plan-receipt.v3'}else{'super-brain.plan-receipt.v2'}) $intentPlanBindingValue
    $intentResolutionReceiptValue = $null
    if ($intentContractRequiredValue) {
      $intentResolution = Resolve-IntentResolution $intentPreparedValue $TaskId $taskInstanceIdValue $WorkspaceKey (Get-ContractSessionKey $existing) ([string]$manifest.version) $revision $planReceipt $receiptInstruction 'execution-contract.ps1:CompleteMerge'
      if (-not $intentResolution.ok) { return [pscustomobject]@{ ok=$false; code=[string]$intentResolution.code; taskId=$TaskId; workspaceKey=$WorkspaceKey; missing=@($intentResolution.missing); guard='The retained merge could not receive a current immutable intent receipt.' } }
      $intentContractValue = $intentResolution.intentContract
      $intentResolutionReceiptValue = $intentResolution.intentResolutionReceipt
    }
    $mergeStageKind = Get-ContractEffectiveDecisionStageKind $existing $StageKind ([string]$stateCard.phase)
    $mergeDecisionIntent = Get-ContractDecisionIntentFingerprint $existing $intentContractValue $receiptInstruction $DecisionIntentFingerprint
    $mergeDecisionBinding = $null
    if (-not [string]::IsNullOrWhiteSpace($mergeStageKind)) {
      $mergeDecisionSeed = [pscustomobject]@{ taskInstanceId=$taskInstanceIdValue; focusId=[string]$existing.focusId; ownerSessionKey=(Get-ContractSessionKey $existing) }
      $mergeDecisionResolution = Invoke-ContractDecisionBinding 'Resolve' $mergeDecisionSeed $mergeStageKind $mergeDecisionIntent $revision $planReceipt
      if (-not $mergeDecisionResolution.ok) {
        return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DECISION_BINDING_WITHHELD'; taskId=$TaskId; workspaceKey=$WorkspaceKey; stageKind=$mergeStageKind; decisionBindingStatus=$mergeDecisionResolution.status; decisionBindingCode=$mergeDecisionResolution.code; reasons=@($mergeDecisionResolution.reasons); guard='The active stage must rebind current completion decisions before a merge state mutation can continue.' }
      }
      $mergeDecisionBinding = $mergeDecisionResolution.binding
    }
    $transitionReceiptsValue = if (-not [string]::IsNullOrWhiteSpace($transitionIdValue)) { @(Add-TransitionReceipt $transitionReceipts $transitionIdValue 'CompleteMerge' $mergePayloadHash ([int]$existing.revision) $revision ([string]$targetIntent.sourceFocusId) ([string]$existing.focusId)) } else { @($transitionReceipts) }
    $existing | Add-Member -NotePropertyName revision -NotePropertyValue $revision -Force
    $existing | Add-Member -NotePropertyName mergeIntents -NotePropertyValue @($updatedIntents) -Force
    $existing | Add-Member -NotePropertyName workLineStatus -NotePropertyValue $workLineStatus -Force
    $existing | Add-Member -NotePropertyName continuityStateCard -NotePropertyValue $stateCard -Force
    $existing | Add-Member -NotePropertyName evidence -NotePropertyValue @($mergeEvidence) -Force
    $existing | Add-Member -NotePropertyName verificationResults -NotePropertyValue @($mergeVerificationResults) -Force
    $existing | Add-Member -NotePropertyName projectProgressProof -NotePropertyValue $mergeProjectProgress.proof -Force
    $existing | Add-Member -NotePropertyName visibleProgressReceipt -NotePropertyValue $mergeVisibleProgressReceipt -Force
    $existing | Add-Member -NotePropertyName planReceipt -NotePropertyValue $planReceipt -Force
    $existing | Add-Member -NotePropertyName planReceiptRequired -NotePropertyValue $true -Force
    $existing | Add-Member -NotePropertyName taskInstanceId -NotePropertyValue $taskInstanceIdValue -Force
    $existing | Add-Member -NotePropertyName intentContractRequired -NotePropertyValue $intentContractRequiredValue -Force
    $existing | Add-Member -NotePropertyName intentAggregateId -NotePropertyValue $intentAggregateIdValue -Force
    $existing | Add-Member -NotePropertyName intentRevision -NotePropertyValue $intentRevisionValue -Force
    $existing | Add-Member -NotePropertyName intentContract -NotePropertyValue $intentContractValue -Force
    $existing | Add-Member -NotePropertyName intentResolutionReceipt -NotePropertyValue $intentResolutionReceiptValue -Force
    $existing | Add-Member -NotePropertyName stageKind -NotePropertyValue $mergeStageKind -Force
    $existing | Add-Member -NotePropertyName decisionIntentFingerprint -NotePropertyValue $mergeDecisionIntent -Force
    $existing | Add-Member -NotePropertyName decisionBinding -NotePropertyValue $mergeDecisionBinding -Force
    $existing | Add-Member -NotePropertyName latestUserInstruction -NotePropertyValue $receiptInstruction -Force
    $existing | Add-Member -NotePropertyName latestMessageClassification -NotePropertyValue $classification -Force
    $existing | Add-Member -NotePropertyName needsReconciliation -NotePropertyValue $false -Force
    $existing | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-SuperBrainUtcTimestamp) -Force
    $existing | Add-Member -NotePropertyName source -NotePropertyValue 'execution-contract.ps1:CompleteMerge' -Force
    $existing | Add-Member -NotePropertyName transitionReceipts -NotePropertyValue @($transitionReceiptsValue) -Force
    $existing | Add-Member -NotePropertyName lastTransition -NotePropertyValue ([pscustomobject]@{ transitionId=$transitionIdValue; action='CompleteMerge'; payloadHash=$mergePayloadHash; fromRevision=($revision-1); toRevision=$revision; fromFocusId=[string]$targetIntent.sourceFocusId; toFocusId=[string]$existing.focusId; recordedAt=(Get-SuperBrainUtcTimestamp) }) -Force
    $existing | Add-Member -NotePropertyName retention -NotePropertyValue 'latest_task_contract_plus_bounded_return_stack_and_merge_dossiers' -Force
    $existing | Add-Member -NotePropertyName path -NotePropertyValue $contractPath -Force
    return Complete-ContractContinuityMutation $existing 'CompleteMerge'
  }
}

function Resolve-Contract {
  $visibleUser = Protect-Instruction $VisibleUserInstruction
  $visibleCommitment = Limit-ContractText $VisibleAssistantCommitment 480
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $validity = Test-ContractCurrent $contract
  $sessionRead = Get-ContractSessionReadState $contract
  $contractReadable = ($validity.current -and $sessionRead.authorized -eq $true)
  $instructionAnchorStatus = if ($contractReadable) { Get-ContractInstructionAnchorStatus $contract $TaskId $WorkspaceKey (Get-ContractSessionKey $contract) } else { [pscustomobject]@{ok=$true;required=$false;current=$true;code='INSTRUCTION_ANCHOR_NOT_APPLICABLE';anchor=$null} }
  $instructionAnchorBlocked = ($contractReadable -and ((-not $instructionAnchorStatus.ok) -or ($instructionAnchorStatus.required -and -not $instructionAnchorStatus.current)))
  $instructionAnchorInstruction = if ($instructionAnchorBlocked -and $instructionAnchorStatus.anchor -and -not [string]::IsNullOrWhiteSpace([string]$instructionAnchorStatus.anchor.instruction)) { [string]$instructionAnchorStatus.anchor.instruction } elseif ($contract -and $contract.PSObject.Properties['latestUserInstruction']) { [string]$contract.latestUserInstruction } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($visibleCommitment) -or -not [string]::IsNullOrWhiteSpace($visibleUser)) {
    $visibleNoContract = (-not $contract)
    $visibleContractInvalid = ($contract -and -not $validity.current)
    $visibleSessionBlocked = ($validity.current -and $sessionRead.authorized -ne $true)
    $visibleContractPending = ($contractReadable -and ($contract.needsReconciliation -eq $true -or $instructionAnchorBlocked))
    $visiblePlanReceiptStale = ($contractReadable -and -not (Test-PlanReceiptCurrent $contract))
    $visibleIntentReceiptStatus = if ($contractReadable) { Get-IntentResolutionReceiptStatus $contract } else { [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'; missing=@() } }
    $visibleIntentReceiptStale = ($contractReadable -and $visibleIntentReceiptStatus.required -and -not $visibleIntentReceiptStatus.current)
    $visibleCanonicalSourceStatus = if ($contractReadable) { Get-CanonicalPlanSourceStatus $contract $instructionAnchorStatus.anchor } else { [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_CANONICAL_SOURCE_NOT_APPLICABLE' } }
    $visibleCanonicalSourceStale = ($contractReadable -and $visibleCanonicalSourceStatus.required -and -not $visibleCanonicalSourceStatus.current)
    $visibleContinuityStatus = if ($contractReadable) { Get-ContractContinuityAuthorityStatus $contract } else { [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_CONTINUITY_NOT_APPLICABLE' } }
    $visibleContinuityStale = ($contractReadable -and $visibleContinuityStatus.required -and -not $visibleContinuityStatus.current)
    $returnStack = @(if ($contractReadable) { @(Limit-ReturnStack @($contract.returnStack)) })
    $returnTo = if ($contractReadable -and $contract.PSObject.Properties['returnTo'] -and $contract.returnTo) { $contract.returnTo } elseif ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
    $completedWorkLines = if ($contractReadable -and $contract.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($contract.completedWorkLines)) } else { @() }
    $activeFocusId = if ($contractReadable) { [string]$contract.focusId } else { 'visible-conversation' }
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($contractReadable -and $contract.PSObject.Properties['unfinishedWorkLines']) { @($contract.unfinishedWorkLines) } else { @() }) $(if ($contractReadable -and $contract.PSObject.Properties['unfinishedWorkPlans']) { @($contract.unfinishedWorkPlans) } else { @() }) @($activeFocusId)
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $mergeIntents = @(Limit-MergeIntents $(if ($contractReadable -and $contract.PSObject.Properties['mergeIntents']) { @($contract.mergeIntents) } else { @() }))
    $activeFocusLabel = if ($contractReadable -and $contract.PSObject.Properties['focusLabel']) { [string]$contract.focusLabel } else { Get-DefaultFocusLabel $activeFocusId }
    $activeTopicKeys = if ($contractReadable -and $contract.PSObject.Properties['topicKeys']) { @($contract.topicKeys) } else { @(Get-DerivedTopicKeys $activeFocusId) }
    $activeTopicKeySource = if ($contractReadable -and $contract.PSObject.Properties['topicKeySource']) { [string]$contract.topicKeySource } else { 'focus_id_derived' }
    $visibleCanonicalPlan = if ($contractReadable -and $contract.PSObject.Properties['canonicalPlan']) { $contract.canonicalPlan } else { $null }
    $visibleAction = if (-not [string]::IsNullOrWhiteSpace($visibleCommitment)) { $visibleCommitment } elseif ($contractReadable) { [string]$contract.nextAction } else { $visibleUser }
    $visiblePlanCommitment = if (-not [string]::IsNullOrWhiteSpace($visibleCommitment)) { $visibleCommitment } elseif ($contractReadable) { [string]$contract.assistantCommitment } else { '' }
    $messageClassification = if ($visibleContractInvalid) { New-SessionIsolationClassification 'invalid' } elseif ($visibleSessionBlocked) { New-SessionIsolationClassification $sessionRead.state } elseif (-not [string]::IsNullOrWhiteSpace($visibleUser)) { Get-TopicClassification $visibleUser $activeFocusId $activeFocusLabel $activeTopicKeys $activeTopicKeySource $returnStack $unfinishedWorkPlans '' '' '' $mergeIntents } elseif ($contractReadable -and $contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { $null }
    $visibleWorkCompleted = if($contractReadable -and $contract.PSObject.Properties['completedSteps']){@($contract.completedSteps)}else{@()}
    $visibleWorkPending = if($contractReadable -and $contract.PSObject.Properties['pendingSteps']){@($contract.pendingSteps)}else{@()}
    $workLineStatus = New-WorkLineStatus $activeFocusId $returnStack $completedWorkLines $unfinishedWorkLines $visibleAction $visiblePlanCommitment $(if($contractReadable){@($contract.constraints)}else{@()}) $(if($contractReadable){@($contract.acceptanceCriteria)}else{@()}) $activeFocusLabel $activeTopicKeys $activeTopicKeySource $(if($contractReadable -and $contract.PSObject.Properties['prioritySource']){[string]$contract.prioritySource}else{'current_contract'}) $(if($contractReadable -and $contract.PSObject.Properties['priorityReason']){[string]$contract.priorityReason}else{'visible conversation preserves the active work-line identity'}) $unfinishedWorkPlans $messageClassification $mergeIntents $visibleCanonicalPlan $visibleWorkCompleted $visibleWorkPending
    $visibleStateCard = New-ContinuityStateCard $TaskId $WorkspaceKey $(if($contractReadable){Get-ContractSessionKey $contract}else{$SessionKey}) $(if($contractReadable -and $contract.PSObject.Properties['revision']){[int]$contract.revision}else{0}) $(if($contractReadable){'visible_conversation'}else{'none'}) $activeFocusId $activeFocusLabel $workLineStatus $returnStack $(if($contractReadable -and $contract.PSObject.Properties['currentPhase']){[string]$contract.currentPhase}else{'visible_conversation'}) $(if($contractReadable -and $contract.PSObject.Properties['currentStep']){[string]$contract.currentStep}else{$visibleAction}) $visibleWorkCompleted $visibleWorkPending $(if($contractReadable -and $contract.PSObject.Properties['blockers']){@($contract.blockers)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['evidence']){@($contract.evidence)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['verificationResults']){@($contract.verificationResults)}else{@()}) $visibleAction $visiblePlanCommitment $(if($contractReadable){@($contract.constraints)}else{@()}) $(if($contractReadable){@($contract.acceptanceCriteria)}else{@()}) 'execution-contract.ps1:visible-conversation' $(if($contractReadable -and $contract.PSObject.Properties['checklistUpdateMode']){[string]$contract.checklistUpdateMode}else{'additive'}) $(if($contractReadable -and $contract.PSObject.Properties['lastConfirmedSentence']){[string]$contract.lastConfirmedSentence}else{$visiblePlanCommitment}) $(if($contractReadable -and $contract.PSObject.Properties['lastConfirmedSource']){[string]$contract.lastConfirmedSource}else{'assistant_commitment'}) $visibleCanonicalPlan $visibleWorkCompleted $visibleWorkPending $(if($contractReadable -and $contract.PSObject.Properties['projectProgressProof']){$contract.projectProgressProof}else{$null})
    $visibleInstructionPending = (-not $visibleNoContract -and -not [string]::IsNullOrWhiteSpace($visibleUser) -and [string]::IsNullOrWhiteSpace($visibleCommitment))
    $visibleAuthorizationState = if($visibleNoContract){'not_applicable'}elseif($visibleContractInvalid -or $visibleSessionBlocked -or $visibleContractPending -or $visiblePlanReceiptStale -or $visibleIntentReceiptStale -or $visibleCanonicalSourceStale -or $visibleContinuityStale -or $visibleInstructionPending){'withheld'}else{'allowed'}
    $visibleAuthorizationWithheld = ($visibleAuthorizationState -eq 'withheld')
    if ($visibleAuthorizationState -ne 'allowed') {
      $workLineStatus = Remove-SuperBrainExecutableActions $workLineStatus
      if ($workLineStatus) { $workLineStatus | Add-Member -NotePropertyName actionAuthorization -NotePropertyValue $visibleAuthorizationState -Force }
      $returnStack = @($returnStack | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $returnTo = Remove-SuperBrainExecutableActions $returnTo
      $unfinishedWorkPlans = @($unfinishedWorkPlans | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $mergeIntents = @()
      $visibleStateCard = Remove-SuperBrainExecutableActions $visibleStateCard
    }
    if ($visibleSessionBlocked) {
      $activeFocusId = ''
      $activeFocusLabel = ''
      $returnStack = @()
      $returnTo = $null
      $completedWorkLines = @()
      $unfinishedWorkLines = @()
      $unfinishedWorkPlans = @()
      $mergeIntents = @()
      $workLineStatus = $null
      $visibleStateCard = $null
    }
    $resolvedVisibleAction = if($visibleNoContract){''}elseif($visibleContractInvalid){'The selected execution contract is stale or invalid. Reconcile a fresh contract before mutation.'}elseif($visibleSessionBlocked){'Session ownership is not verified for the selected execution contract. Explicitly recover or rebind it before mutation.'}elseif($visibleContractPending){'Reconcile the latest user instruction through the authoritative instruction anchor before mutation: ' + $instructionAnchorInstruction}elseif($visiblePlanReceiptStale){'The stored plan receipt is stale or invalid. Reconcile the visible plan through Set before mutation.'}elseif($visibleIntentReceiptStale){'Resolve and bind a current task-scoped intent receipt before structural mutation.'}elseif($visibleCanonicalSourceStale){'The canonical plan source receipt or its bound plan document changed. Reconcile the exact approved plan before mutation.'}elseif($visibleContinuityStale){'The current context is not synchronized with its checkpoint, task card, route, or task-state transaction. Reconcile the exact task before mutation.'}elseif($visibleInstructionPending){'Reconcile the latest visible user instruction before mutation: ' + $visibleUser}else{$visibleAction}
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom='visible_conversation'; resolutionSource=if($visibleNoContract){'none'}else{'visible_conversation'}; claimAllowed=($visibleAuthorizationState -ne 'withheld'); needsConfirmation=$visibleAuthorizationWithheld; actionAuthorization=$visibleAuthorizationState; sessionAccess=$sessionRead.state; foreignContextDetected=(-not [string]::IsNullOrWhiteSpace($script:ForeignContextTaskId)); foreignContextSessionAccess=$script:ForeignContextSessionState; taskId=$TaskId; taskInstanceId=if($contractReadable -and $contract.PSObject.Properties['taskInstanceId']){[string]$contract.taskInstanceId}else{''}; workspaceKey=$WorkspaceKey; packageVersion=if($contractReadable -and $contract.PSObject.Properties['packageVersion']){[string]$contract.packageVersion}else{''}; focusId=$activeFocusId; focusLabel=$activeFocusLabel; instructionMode=if($visibleNoContract){'none'}else{'visible_conversation'}; returnStack=@($returnStack); returnTo=$returnTo; canResumeParent=($visibleAuthorizationState -eq 'allowed' -and $returnStack.Count -gt 0); completedWorkLines=@($completedWorkLines); unfinishedWorkLines=@($unfinishedWorkLines); unfinishedWorkPlans=@($unfinishedWorkPlans); mergeIntents=@($mergeIntents); canonicalPlan=if($contractReadable){$visibleCanonicalPlan}else{$null}; canonicalPlanSource=$visibleCanonicalSourceStatus; continuity=$visibleContinuityStatus; instructionAnchor=$instructionAnchorStatus; workLineStatus=$workLineStatus; continuityStateCard=$visibleStateCard; latestUserInstruction=if($instructionAnchorBlocked){$instructionAnchorInstruction}else{$visibleUser}; latestMessageClassification=$messageClassification; assistantCommitment=if($visibleAuthorizationState -eq 'allowed'){$visibleCommitment}else{''}; nextAction=$resolvedVisibleAction; invalidatedWorkItems=if($contractReadable){@($contract.invalidatedWorkItems)}else{@()}; contractRevision=if($contractReadable){[int]$contract.revision}else{0}; planFingerprint=if($visibleAuthorizationState -eq 'allowed' -and $contract.planReceipt){[string]$contract.planReceipt.planFingerprint}else{''}; intentReceipt=[pscustomobject]@{required=$visibleIntentReceiptStatus.required;current=$visibleIntentReceiptStatus.current;code=$visibleIntentReceiptStatus.code;missing=@($visibleIntentReceiptStatus.missing)}; guard=if($visibleNoContract){'No execution contract exists; visible context is non-authorizing and ordinary work remains direct.'}elseif($visibleContractInvalid){'Visible context cannot authorize a stale or invalid execution contract.'}elseif($visibleSessionBlocked){'Visible context cannot authorize or project a current contract owned by another or unknown root session.'}elseif($visibleContractPending){'A visible assistant commitment cannot bypass a newer unreconciled authoritative instruction anchor.'}elseif($visiblePlanReceiptStale){'A visible assistant commitment cannot bypass a stale or invalid plan receipt.'}elseif($visibleIntentReceiptStale){'A stale task-scoped intent receipt cannot authorize a structural action.'}elseif($visibleCanonicalSourceStale){'A stale canonical plan source cannot authorize a visible action.'}elseif($visibleContinuityStale){'A stale continuity projection cannot authorize a visible action.'}elseif($visibleInstructionPending){'Visible user instruction is newer but has no matching assistant commitment; reconcile it before mutation.'}else{'Visible conversation is newest and supplies the current action.'} }
  }
  if ($validity.current) {
    $sessionBlocked = ($sessionRead.authorized -ne $true)
    $pending = ($contract.needsReconciliation -eq $true -or $instructionAnchorBlocked)
    $authoritativeInstruction = if ($instructionAnchorBlocked -and -not [string]::IsNullOrWhiteSpace($instructionAnchorInstruction)) { $instructionAnchorInstruction } else { [string]$contract.latestUserInstruction }
    $planReceiptStale = -not (Test-PlanReceiptCurrent $contract)
    $intentReceiptStatus = Get-IntentResolutionReceiptStatus $contract
    $intentReceiptStale = ($intentReceiptStatus.required -and -not $intentReceiptStatus.current)
    $canonicalSourceStatus = Get-CanonicalPlanSourceStatus $contract $instructionAnchorStatus.anchor
    $canonicalSourceStale = ($canonicalSourceStatus.required -and -not $canonicalSourceStatus.current)
    $continuityStatus = Get-ContractContinuityAuthorityStatus $contract
    $continuityStale = ($continuityStatus.required -and -not $continuityStatus.current)
    $returnStack = @(Limit-ReturnStack @($contract.returnStack))
    $returnTo = if ($contract.PSObject.Properties['returnTo'] -and $contract.returnTo) { $contract.returnTo } elseif ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
    $completedWorkLines = if ($contract.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($contract.completedWorkLines)) } else { @() }
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($contract.PSObject.Properties['unfinishedWorkLines']) { @($contract.unfinishedWorkLines) } else { @() }) $(if ($contract.PSObject.Properties['unfinishedWorkPlans']) { @($contract.unfinishedWorkPlans) } else { @() }) @([string]$contract.focusId)
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $mergeIntents = @(Limit-MergeIntents $(if ($contract.PSObject.Properties['mergeIntents']) { @($contract.mergeIntents) } else { @() }))
    $focusLabelValue = if ($contract.PSObject.Properties['focusLabel']) { [string]$contract.focusLabel } else { Get-DefaultFocusLabel ([string]$contract.focusId) }
    $topicKeyValue = if ($contract.PSObject.Properties['topicKeys']) { @($contract.topicKeys) } else { @(Get-DerivedTopicKeys ([string]$contract.focusId)) }
    $topicKeySourceValue = if ($contract.PSObject.Properties['topicKeySource']) { [string]$contract.topicKeySource } else { 'focus_id_derived' }
    $canonicalPlanValue = if ($contract.PSObject.Properties['canonicalPlan']) { $contract.canonicalPlan } else { $null }
    $messageClassification = if ($sessionBlocked) { New-SessionIsolationClassification $sessionRead.state } elseif ($instructionAnchorBlocked -and $instructionAnchorStatus.anchor -and $instructionAnchorStatus.anchor.classification) { $instructionAnchorStatus.anchor.classification } elseif ($contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { Get-TopicClassification $authoritativeInstruction ([string]$contract.focusId) $focusLabelValue $topicKeyValue $topicKeySourceValue $returnStack $unfinishedWorkPlans ([string]$contract.currentStep) ([string]$contract.nextAction) ([string]$contract.assistantCommitment) $mergeIntents }
    $classificationBlocked = (-not $sessionBlocked -and (Test-ClassificationBlocksAuthorization $messageClassification $authoritativeInstruction))
    $workPackageCompleted = if($contract.PSObject.Properties['completedSteps']){@($contract.completedSteps)}else{@()}
    $workPackagePending = if($contract.PSObject.Properties['pendingSteps']){@($contract.pendingSteps)}else{@()}
    $workLineStatus = New-WorkLineStatus ([string]$contract.focusId) $returnStack $completedWorkLines $unfinishedWorkLines ([string]$contract.nextAction) ([string]$contract.assistantCommitment) @($contract.constraints) @($contract.acceptanceCriteria) $focusLabelValue $topicKeyValue $topicKeySourceValue $(if($contract.PSObject.Properties['prioritySource']){[string]$contract.prioritySource}else{'current_contract'}) $(if($contract.PSObject.Properties['priorityReason']){[string]$contract.priorityReason}else{''}) $unfinishedWorkPlans $messageClassification $mergeIntents $canonicalPlanValue $workPackageCompleted $workPackagePending
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey (Get-ContractSessionKey $contract) ([int]$contract.revision) ([string]$contract.instructionMode) ([string]$contract.focusId) $focusLabelValue $workLineStatus $returnStack $(if($contract.PSObject.Properties['currentPhase']){[string]$contract.currentPhase}else{[string]$contract.instructionMode}) $(if($contract.PSObject.Properties['currentStep']){[string]$contract.currentStep}else{[string]$contract.nextAction}) $workPackageCompleted $workPackagePending $(if($contract.PSObject.Properties['blockers']){@($contract.blockers)}else{@()}) $(if($contract.PSObject.Properties['evidence']){@($contract.evidence)}else{@()}) $(if($contract.PSObject.Properties['verificationResults']){@($contract.verificationResults)}else{@()}) ([string]$contract.nextAction) ([string]$contract.assistantCommitment) @($contract.constraints) @($contract.acceptanceCriteria) 'execution-contract.ps1:resolve' $(if($contract.PSObject.Properties['checklistUpdateMode']){[string]$contract.checklistUpdateMode}else{'additive'}) $(if($contract.PSObject.Properties['lastConfirmedSentence']){[string]$contract.lastConfirmedSentence}else{[string]$contract.assistantCommitment}) $(if($contract.PSObject.Properties['lastConfirmedSource']){[string]$contract.lastConfirmedSource}else{'assistant_commitment'}) $canonicalPlanValue $workPackageCompleted $workPackagePending $(if($contract.PSObject.Properties['projectProgressProof']){$contract.projectProgressProof}else{$null})
    $resumedParentWithoutPlan = ($contract.PSObject.Properties['instructionMode'] -and $contract.instructionMode -eq 'resume_parent' -and -not [bool]$workLineStatus.activePlan.hasConcreteNextAction)
    $authorizationWithheld = ($sessionBlocked -or $pending -or $planReceiptStale -or $intentReceiptStale -or $canonicalSourceStale -or $continuityStale -or $classificationBlocked -or $resumedParentWithoutPlan)
    if ($authorizationWithheld) {
      $workLineStatus = Remove-SuperBrainExecutableActions $workLineStatus
      if ($workLineStatus) { $workLineStatus | Add-Member -NotePropertyName actionAuthorization -NotePropertyValue 'withheld' -Force }
      $returnStack = @($returnStack | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $returnTo = Remove-SuperBrainExecutableActions $returnTo
      $unfinishedWorkPlans = @($unfinishedWorkPlans | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $mergeIntents = @()
      $stateCardValue = Remove-SuperBrainExecutableActions $stateCardValue
    }
    if ($sessionBlocked) {
      $returnStack = @()
      $returnTo = $null
      $completedWorkLines = @()
      $unfinishedWorkLines = @()
      $unfinishedWorkPlans = @()
      $mergeIntents = @()
      $workLineStatus = $null
      $stateCardValue = $null
      $focusLabelValue = ''
      $topicKeyValue = @()
      $topicKeySourceValue = ''
    }
    $resolvedNextAction = if($sessionRead.state -eq 'foreign'){'Execution contract belongs to another root session. Explicitly recover it, then Set with RebindSession before mutation.'}elseif($sessionRead.state -in @('unbound','session_required')){'Execution contract session ownership is not established. Explicitly bind it before mutation.'}elseif($pending -or $classificationBlocked){'Reconcile the latest user instruction and its authoritative work-line affinity before mutation: '+$authoritativeInstruction}elseif($planReceiptStale){'The stored plan receipt is missing or older than the execution contract. Reconcile the latest visible plan before mutation.'}elseif($intentReceiptStale){'Resolve and bind the current task-level intent receipt before structural mutation.'}elseif($canonicalSourceStale){'The canonical plan source receipt or its bound plan document changed. Reconcile the exact approved plan before mutation.'}elseif($continuityStale){'The current context is not synchronized with its checkpoint, task card, route, or task-state transaction. Reconcile the exact task before mutation.'}elseif($resumedParentWithoutPlan){'Recovered parent plan is missing. Use task-scoped checkpoint or return-card evidence before mutation.'}else{[string]$contract.nextAction}
    $resolvedGuard = if($sessionBlocked){'Session ownership blocks this plan from authorizing work in the current root conversation.'}elseif($pending -or $classificationBlocked){'The latest authoritative instruction anchor has no bound, current execution contract; reconcile it before mutation.'}elseif($planReceiptStale){'A stale plan receipt cannot authorize an older next action after a newer state revision.'}elseif($intentReceiptStale){'A stale or unresolved task-level intent receipt cannot authorize structural work or a completion claim.'}elseif($canonicalSourceStale){'A canonical plan source receipt, its source document, or its plan fingerprint is stale; do not execute from a local contract alone.'}elseif($continuityStale){'A stale context, checkpoint, task card, route, or task-state transaction cannot authorize an action.'}elseif($resumedParentWithoutPlan){'A resumed parent has no concrete plan payload. Do not guess or continue generically.'}else{'Current task execution contract overrides phase-only checkpoint details.'}
    $resumeFrom = if($sessionRead.state -eq 'foreign'){'execution_contract_foreign_session'}elseif($sessionRead.state -in @('unbound','session_required')){'execution_contract_session_unbound'}elseif($instructionAnchorBlocked){'execution_contract_instruction_anchor_pending'}elseif($pending){'execution_contract_pending_reconciliation'}elseif($classificationBlocked){'execution_contract_topic_unresolved'}elseif($planReceiptStale){'execution_contract_plan_receipt_stale'}elseif($intentReceiptStale){'execution_contract_intent_receipt_stale'}elseif($canonicalSourceStale){'execution_contract_canonical_source_stale'}elseif($continuityStale){'execution_contract_continuity_stale'}elseif($contract.PSObject.Properties['instructionMode'] -and $contract.instructionMode -eq 'resume_parent'){'parent_return'}else{'execution_contract'}
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom=$resumeFrom; resolutionSource='execution_contract'; claimAllowed=(-not $authorizationWithheld); needsConfirmation=$authorizationWithheld; actionAuthorization=if($authorizationWithheld){'withheld'}else{'allowed'}; sessionAccess=$sessionRead.state; taskId=$TaskId; taskInstanceId=if($sessionBlocked){''}else{[string]$contract.taskInstanceId}; workspaceKey=$WorkspaceKey; packageVersion=if($sessionBlocked){''}else{[string]$contract.packageVersion}; focusId=if($sessionBlocked){''}else{[string]$contract.focusId}; focusLabel=$focusLabelValue; instructionMode=if($authorizationWithheld){'reconcile'}elseif($contract.PSObject.Properties['instructionMode']){[string]$contract.instructionMode}else{'continue'}; returnStack=@($returnStack); returnTo=$returnTo; canResumeParent=(-not $authorizationWithheld -and $returnStack.Count -gt 0); completedWorkLines=@($completedWorkLines); unfinishedWorkLines=@($unfinishedWorkLines); unfinishedWorkPlans=@($unfinishedWorkPlans); mergeIntents=@($mergeIntents); canonicalPlan=if($sessionBlocked){$null}else{$canonicalPlanValue}; canonicalPlanSource=$canonicalSourceStatus; continuity=$continuityStatus; instructionAnchor=$instructionAnchorStatus; workLineStatus=$workLineStatus; continuityStateCard=$stateCardValue; latestUserInstruction=if($sessionBlocked){''}else{$authoritativeInstruction}; latestMessageClassification=$messageClassification; assistantCommitment=if($authorizationWithheld){''}else{[string]$contract.assistantCommitment}; nextAction=$resolvedNextAction; currentPhase=if($authorizationWithheld){''}else{[string]$stateCardValue.phase}; currentStep=if($authorizationWithheld){''}else{[string]$stateCardValue.currentStep}; completedSteps=if($authorizationWithheld){@()}else{@($stateCardValue.completedSteps)}; pendingSteps=if($authorizationWithheld){@()}else{@($stateCardValue.pendingSteps)}; blockers=if($authorizationWithheld){@()}else{@($stateCardValue.blockers)}; evidence=if($authorizationWithheld){@()}else{@($stateCardValue.evidence)}; verificationResults=if($authorizationWithheld){@()}else{@($stateCardValue.verificationResults)}; constraints=if($sessionBlocked){@()}else{@($contract.constraints)}; topicKeys=@($topicKeyValue); topicKeySource=$topicKeySourceValue; invalidatedWorkItems=if($sessionBlocked){@()}else{@($contract.invalidatedWorkItems)}; acceptanceCriteria=if($sessionBlocked){@()}else{@($contract.acceptanceCriteria)}; contractRevision=[int]$contract.revision; planFingerprint=if($authorizationWithheld){''}else{[string]$contract.planReceipt.planFingerprint}; intentReceipt=[pscustomobject]@{required=$intentReceiptStatus.required;current=$intentReceiptStatus.current;code=$intentReceiptStatus.code;missing=@($intentReceiptStatus.missing)}; guard=$resolvedGuard }
  }
  $checkpoint = Read-ContractJson $CheckpointPath
  if (-not $contract -and -not $checkpoint) {
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom='none'; resolutionSource='none'; claimAllowed=$true; needsConfirmation=$false; actionAuthorization='not_applicable'; sessionAccess='missing'; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=''; instructionMode='none'; returnStack=@(); returnTo=$null; canResumeParent=$false; completedWorkLines=@(); unfinishedWorkLines=@(); workLineStatus=$null; continuityStateCard=$null; latestUserInstruction=''; assistantCommitment=''; nextAction=''; currentPhase=''; currentStep=''; checkpointCurrentStepAvailable=$false; invalidatedWorkItems=@(); contractRevision=0; contractInvalidReasons=@($validity.reasons); guard='No execution contract exists for this task/session scope; no stored action is authorized and independent work remains direct.' }
  }
  return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom=if($checkpoint){'checkpoint_state_only'}else{'unknown'}; resolutionSource=if($checkpoint){'checkpoint_state_only'}else{'none'}; claimAllowed=$false; needsConfirmation=$true; actionAuthorization='withheld'; sessionAccess=$sessionRead.state; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=''; instructionMode='unknown'; returnStack=@(); returnTo=$null; canResumeParent=$false; completedWorkLines=@(); unfinishedWorkLines=@(); workLineStatus=$null; continuityStateCard=$null; latestUserInstruction=''; assistantCommitment=''; nextAction=''; currentPhase=if($checkpoint){[string]$checkpoint.currentPhase}else{''}; currentStep=''; checkpointCurrentStepAvailable=($checkpoint -and -not [string]::IsNullOrWhiteSpace([string]$checkpoint.currentStep)); invalidatedWorkItems=@(); contractRevision=0; contractInvalidReasons=@($validity.reasons); guard='No current execution contract is available. A checkpoint may report phase/status, but must not expose or invent the latest promised action.' }
}

function Get-ContractContinuityWalStatus([string]$EventPath,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($EventPath) -or -not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_WAL_MISSING'; incompleteCount=0; parseErrorCount=0 }
  }
  $prepared = @{}
  $terminal = @{}
  $parseErrors = 0
  foreach ($line in @(Get-Content -LiteralPath $EventPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
    try { $event = $line | ConvertFrom-Json } catch { $parseErrors++; continue }
    if ($event.PSObject.Properties['taskId'] -and [string]$event.taskId -ne $Id) { $parseErrors++; continue }
    $transactionId = if ($event.PSObject.Properties['transactionId']) { [string]$event.transactionId } else { '' }
    if ([string]::IsNullOrWhiteSpace($transactionId)) { continue }
    $phase = if ($event.PSObject.Properties['phase']) { [string]$event.phase } else { '' }
    if ($phase -eq 'prepared') { $prepared[$transactionId] = $true }
    elseif ($phase -in @('committed','aborted')) { $terminal[$transactionId] = $true }
  }
  $incomplete = @($prepared.Keys | Where-Object { -not $terminal.ContainsKey([string]$_) })
  if ($parseErrors -gt 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_WAL_PARSE_FAILED'; incompleteCount=$incomplete.Count; parseErrorCount=$parseErrors } }
  if ($incomplete.Count -gt 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_TRANSACTION_PENDING'; incompleteCount=$incomplete.Count; parseErrorCount=0 } }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CONTINUITY_WAL_CURRENT'; incompleteCount=0; parseErrorCount=0 }
}

function Get-ContractContinuityChecklistSignature([object[]]$Values) {
  return (@($Values | ForEach-Object { Limit-ContractText ([string]$_) 180 }) -join [string][char]31)
}

function Test-ContractContinuityProjectionEntity(
  [object]$Projection,
  [string]$Kind,
  [object]$Contract,
  [int]$TaskStateRevision,
  [string]$ContractHash
) {
  $id = [string]$Contract.taskId
  $key = [string]$Contract.workspaceKey
  $entity = if ($Projection.entities -and $Projection.entities.PSObject.Properties[$Kind]) { $Projection.entities.$Kind } else { $null }
  if (-not $entity -or [string]$entity.status -ne 'active' -or [string]::IsNullOrWhiteSpace([string]$entity.path) -or [string]::IsNullOrWhiteSpace([string]$entity.hash)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_PROJECTION_MISSING'; reason='projection_missing'; path='' }
  }
  $path = [IO.Path]::GetFullPath([string]$entity.path)
  $expectedPath = if ($Kind -eq 'checkpoint') {
    Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $id '.json'
  } else {
    Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $memoryBase 'shared\tasks') 'active') $id '.task.json'
  }
  if (-not [string]::Equals($path,[IO.Path]::GetFullPath($expectedPath),[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_PATH_MISMATCH'; reason='path_mismatch'; path=$path }
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_FILE_MISSING'; reason='file_missing'; path=$path }
  }
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  if (-not [string]::Equals($hash,[string]$entity.hash,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_HASH_MISMATCH'; reason='hash_mismatch'; path=$path }
  }
  $value = Read-ContractJson $path
  if (-not $value -or [string]$value.taskId -ne $id -or -not (Test-SuperBrainWorkspaceKey ([string]$value.workspaceKey) $key) -or [string]$value.status -ne 'active') {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_IDENTITY_MISMATCH'; reason='identity_mismatch'; path=$path }
  }
  foreach ($check in @(
    [pscustomobject]@{ name='taskStateRevision'; expected=$TaskStateRevision; code='TASK_STATE_REVISION_MISMATCH' },
    [pscustomobject]@{ name='contractRevision'; expected=[int]$Contract.revision; code='CONTRACT_REVISION_MISMATCH' },
    [pscustomobject]@{ name='planFingerprint'; expected=[string]$Contract.planReceipt.planFingerprint; code='PLAN_FINGERPRINT_MISMATCH' },
    [pscustomobject]@{ name='continuityContractHash'; expected=$ContractHash; code='CONTRACT_HASH_MISMATCH' },
    [pscustomobject]@{ name='taskInstanceId'; expected=[string]$Contract.taskInstanceId; code='TASK_INSTANCE_MISMATCH' },
    [pscustomobject]@{ name='ownerSessionKey'; expected=[string]$Contract.ownerSessionKey; code='OWNER_SESSION_MISMATCH' },
    [pscustomobject]@{ name='currentPhase'; expected=[string]$Contract.currentPhase; code='CURRENT_PHASE_MISMATCH' },
    [pscustomobject]@{ name='currentStep'; expected=[string]$Contract.currentStep; code='CURRENT_STEP_MISMATCH' },
    [pscustomobject]@{ name='nextAction'; expected=[string]$Contract.nextAction; code='NEXT_ACTION_MISMATCH' }
  )) {
    if (-not $value.PSObject.Properties[$check.name] -or [string]$value.($check.name) -ne [string]$check.expected) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_' + $check.code; reason=$check.code.ToLowerInvariant(); path=$path }
    }
  }
  if ((Get-ContractContinuityChecklistSignature @($value.completedSteps)) -ne (Get-ContractContinuityChecklistSignature @($Contract.completedSteps))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_COMPLETED_CHECKLIST_MISMATCH'; reason='completed_checklist_mismatch'; path=$path }
  }
  if ((Get-ContractContinuityChecklistSignature @($value.pendingSteps)) -ne (Get-ContractContinuityChecklistSignature @($Contract.pendingSteps))) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_PENDING_CHECKLIST_MISMATCH'; reason='pending_checklist_mismatch'; path=$path }
  }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_CONTINUITY_' + $Kind.ToUpperInvariant() + '_CURRENT'; reason='current'; path=$path; hash=$hash }
}

function Get-ContractContinuityAuthorityStatus([object]$Contract) {
  $notApplicable = [pscustomobject]@{ required=$false; current=$true; code='EXECUTION_CONTRACT_CONTINUITY_NOT_APPLICABLE'; reason='bound_context_missing'; contextPath=''; routePath=''; projectionPath=''; eventPath=''; contractRevision=0; taskStateRevision=0; incompleteTransactionCount=0; parseErrorCount=0 }
  if (-not $Contract -or [string]::IsNullOrWhiteSpace([string]$Contract.taskId) -or [string]::IsNullOrWhiteSpace([string]$Contract.workspaceKey)) { return $notApplicable }
  $id = [string]$Contract.taskId
  $key = [string]$Contract.workspaceKey
  $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $id '.json'
  $notApplicable.contextPath = $contextPath
  if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { return $notApplicable }
  $context = Read-ContractJson $contextPath
  if (-not $context -or [string]$context.taskId -ne $id -or -not (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) $key)) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_IDENTITY_MISMATCH'; reason='context_identity_mismatch'; contextPath=$contextPath; routePath=''; projectionPath=''; eventPath=''; contractRevision=[int]$Contract.revision; taskStateRevision=0; incompleteTransactionCount=0; parseErrorCount=0 }
  }
  if ([string]$context.bindingState -ne 'bound' -or [string]$context.authorizationState -ne 'authorizing') {
    $notApplicable.reason = 'context_locator_only'
    return $notApplicable
  }
  $contractPath = [string]$Contract.path
  if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CONTINUITY_CONTRACT_FILE_MISSING'; reason='contract_file_missing'; contextPath=$contextPath; routePath=''; projectionPath=''; eventPath=''; contractRevision=[int]$Contract.revision; taskStateRevision=0; incompleteTransactionCount=0; parseErrorCount=0 }
  }
  $contractHash = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
  foreach ($check in @(
    [pscustomobject]@{ ok=([int]$context.contractRevision -eq [int]$Contract.revision); code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_CONTRACT_REVISION_MISMATCH'; reason='context_contract_revision_mismatch' },
    [pscustomobject]@{ ok=([string]$context.planFingerprint -eq [string]$Contract.planReceipt.planFingerprint); code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_PLAN_FINGERPRINT_MISMATCH'; reason='context_plan_fingerprint_mismatch' },
    [pscustomobject]@{ ok=([string]$context.ownerSessionKey -eq [string]$Contract.ownerSessionKey); code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_SESSION_MISMATCH'; reason='context_session_mismatch' },
    [pscustomobject]@{ ok=([string]$context.contractFileName -eq (Split-Path -Leaf $contractPath)); code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_CONTRACT_PATH_MISMATCH'; reason='context_contract_path_mismatch' },
    [pscustomobject]@{ ok=([string]::Equals([string]$context.targetHash,$contractHash,[StringComparison]::OrdinalIgnoreCase)); code='EXECUTION_CONTRACT_CONTINUITY_CONTEXT_TARGET_HASH_MISMATCH'; reason='context_contract_hash_mismatch' }
  )) {
    if (-not $check.ok) { return [pscustomobject]@{ required=$true; current=$false; code=$check.code; reason=$check.reason; contextPath=$contextPath; routePath=''; projectionPath=''; eventPath=''; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$context.taskStateRevision; incompleteTransactionCount=0; parseErrorCount=0 } }
  }
  $storeRoot = Join-Path $workspace 'task-state-store'
  $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $storeRoot 'projections') $id '.json'
  $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $storeRoot 'events') $id '.jsonl'
  $projection = Read-ContractJson $projectionPath
  if (-not $projection -or [string]$projection.taskId -ne $id -or [string]$projection.lifecycle.status -ne 'active') {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CONTINUITY_TASK_STATE_INVALID'; reason='task_state_projection_missing_or_nonactive'; contextPath=$contextPath; routePath=''; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$context.taskStateRevision; incompleteTransactionCount=0; parseErrorCount=0 }
  }
  $projectedContext = if ($projection.entities -and $projection.entities.PSObject.Properties['context']) { $projection.entities.context } else { $null }
  $contextHash = (Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash
  if (-not $projectedContext -or [int]$projection.revision -ne [int]$context.taskStateRevision -or [string]$projectedContext.path -ne $contextPath -or [string]$projectedContext.status -ne 'active' -or -not [string]::Equals([string]$projectedContext.hash,$contextHash,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CONTINUITY_TASK_STATE_BINDING_MISMATCH'; reason='context_projection_binding_mismatch'; contextPath=$contextPath; routePath=''; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$projection.revision; incompleteTransactionCount=0; parseErrorCount=0 }
  }
  $planCheckpointRequired = Test-ContractRequiresPlanCheckpoint $Contract
  $checkpointProjection = if($projection.entities -and $projection.entities.PSObject.Properties['checkpoint']){$projection.entities.checkpoint}else{$null}
  $checkpointActive = ($checkpointProjection -and [string]$checkpointProjection.status -in @('active','running','in_progress'))
  $checkpointRequired = ($planCheckpointRequired -or $checkpointActive)
  $requiredKinds = @('task_card')
  if ($checkpointRequired) { $requiredKinds = @('checkpoint','task_card') }
  foreach ($kind in $requiredKinds) {
    $entityStatus = Test-ContractContinuityProjectionEntity $projection $kind $Contract ([int]$projection.revision) $contractHash
    if (-not $entityStatus.ok) {
      return [pscustomobject]@{ required=$true; current=$false; code=[string]$entityStatus.code; reason=[string]$entityStatus.reason; contextPath=$contextPath; checkpointPath=if($kind -eq 'checkpoint'){$entityStatus.path}else{''}; taskCardPath=if($kind -eq 'task_card'){$entityStatus.path}else{''}; routePath=''; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$projection.revision; incompleteTransactionCount=0; parseErrorCount=0 }
    }
  }
  $wal = Get-ContractContinuityWalStatus $eventPath $id
  if (-not $wal.ok) {
    return [pscustomobject]@{ required=$true; current=$false; code=$wal.code; reason='task_state_wal_not_current'; contextPath=$contextPath; routePath=''; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$projection.revision; incompleteTransactionCount=$wal.incompleteCount; parseErrorCount=$wal.parseErrorCount }
  }
  $routePath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\route-checkpoints') $id '.json'
  if (Test-Path -LiteralPath $routePath -PathType Leaf) {
    $route = Read-ContractJson $routePath
    if (-not $route -or [string]$route.bindingState -ne 'bound' -or [string]$route.status -ne 'clean' -or [int]$route.taskStateRevision -ne [int]$projection.revision -or [int]$route.contractRevision -ne [int]$Contract.revision -or [string]$route.planFingerprint -ne [string]$Contract.planReceipt.planFingerprint -or -not [string]::Equals([string]$route.targetHash,$contractHash,[StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ required=$true; current=$false; code='EXECUTION_CONTRACT_CONTINUITY_ROUTE_BINDING_MISMATCH'; reason='route_binding_mismatch'; contextPath=$contextPath; routePath=$routePath; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$projection.revision; incompleteTransactionCount=0; parseErrorCount=0 }
    }
  }
  return [pscustomobject]@{ required=$true; current=$true; code='EXECUTION_CONTRACT_CONTINUITY_CURRENT'; reason=if($checkpointRequired){'bound_context_checkpoint_task_card_and_task_state_current'}else{'bound_context_task_card_and_task_state_current'}; planCheckpointRequired=[bool]$planCheckpointRequired; checkpointProjectionIncluded=[bool]$checkpointRequired; contextPath=$contextPath; checkpointPath=if($checkpointRequired){Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $id '.json'}else{''}; taskCardPath=(Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $memoryBase 'shared\tasks') 'active') $id '.task.json'); routePath=if(Test-Path -LiteralPath $routePath -PathType Leaf){$routePath}else{''}; projectionPath=$projectionPath; eventPath=$eventPath; contractRevision=[int]$Contract.revision; taskStateRevision=[int]$projection.revision; incompleteTransactionCount=0; parseErrorCount=0 }
}

function Guard-Work {
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $sessionBlock = Get-ContractSessionMutationBlock $contract 'Guard'
  if ($sessionBlock) { return $sessionBlock }
  $validity = Test-ContractCurrent $contract
  if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; currentFocusId=''; proposedWorkId=$ProposedWorkId; reasons=@($validity.reasons); guard='Refresh the execution contract from visible conversation before mutation.' } }
  $instructionAnchorStatus = Get-ContractInstructionAnchorStatus $contract $TaskId $WorkspaceKey (Get-ContractSessionKey $contract)
  if (-not $instructionAnchorStatus.ok -or ($instructionAnchorStatus.required -and -not $instructionAnchorStatus.current)) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'; reconciliationReason='instruction_anchor_pending'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; instructionAnchor=$instructionAnchorStatus; latestUserInstruction=if($instructionAnchorStatus.anchor){[string]$instructionAnchorStatus.anchor.instruction}else{[string]$contract.latestUserInstruction}; guard='A newer authoritative instruction anchor is not bound to this contract. Reconcile it before mutation.' }
  }
  if ($ExpectedRevision -ge 0 -and [int]$contract.revision -ne $ExpectedRevision) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_REVISION_MISMATCH'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; expectedRevision=$ExpectedRevision; actualRevision=[int]$contract.revision; guard='The execution contract changed after the caller observed it. Resolve again before mutation.' } }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and [string]$contract.planReceipt.planFingerprint -ne [string]$ExpectedPlanFingerprint) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; expectedPlanFingerprint=$ExpectedPlanFingerprint; actualPlanFingerprint=[string]$contract.planReceipt.planFingerprint; guard='The accepted plan changed after the caller observed it. Resolve again before mutation.' } }
  if ($contract.needsReconciliation -eq $true) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; latestUserInstruction=[string]$contract.latestUserInstruction; latestMessageClassification=if($contract.PSObject.Properties['latestMessageClassification']){$contract.latestMessageClassification}else{$null}; guard='A newer user instruction has not yet been reconciled. Use its task-scoped classification; ambiguous or unknown affinity must not authorize mutation.' } }
  $canonicalSourceStatus = Get-CanonicalPlanSourceStatus $contract $instructionAnchorStatus.anchor
  if ($canonicalSourceStatus.required -and -not $canonicalSourceStatus.current) {
    return [pscustomobject]@{ ok=$false; code=[string]$canonicalSourceStatus.code; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; canonicalPlanSource=$canonicalSourceStatus; guard='The canonical plan source receipt, source document, or plan fingerprint is stale. Reconcile the approved plan before any key action.' }
  }
  $guardClassification = if ($contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { $null }
  if (Test-ClassificationBlocksAuthorization $guardClassification ([string]$contract.latestUserInstruction)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TOPIC_RECONCILIATION_REQUIRED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; latestUserInstruction=[string]$contract.latestUserInstruction; latestMessageClassification=$guardClassification; guard='Unknown or ambiguous work-line affinity cannot authorize mutation. Reconcile the latest instruction explicitly.' } }
  if (-not (Test-PlanReceiptCurrent $contract)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_STALE'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; planReceipt=if($contract.PSObject.Properties['planReceipt']){$contract.planReceipt}else{$null}; guard='The accepted-plan receipt is missing or older than the execution contract. Reconcile the latest visible plan before mutation.' } }
  $intentReceiptStatus = Get-IntentResolutionReceiptStatus $contract -Force:$RequireIntentContract
  if ($intentReceiptStatus.required -and -not $intentReceiptStatus.current) {
    return [pscustomobject]@{ ok=$false; code=[string]$intentReceiptStatus.code; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint; missing=@($intentReceiptStatus.missing); intentReceipt=[pscustomobject]@{required=$intentReceiptStatus.required;current=$intentReceiptStatus.current;code=$intentReceiptStatus.code;missing=@($intentReceiptStatus.missing)}; guard='Structural product work and its completion claim require a current task-scoped intent receipt bound to this task, workspace, session, plan, instruction, and package version.' }
  }
  $decisionBindingStatus = Get-ContractDecisionBindingStatus $contract
  if ($decisionBindingStatus.required -and -not $decisionBindingStatus.current) {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_DECISION_BINDING_STALE'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint; decisionBinding=$decisionBindingStatus; guard='A structural stage has completion decisions, but their receipt is missing, stale, foreign, or withheld. Reconcile the current task decision binding before mutation.' }
  }
  $decisionGuidance = if ($decisionBindingStatus.required -and $decisionBindingStatus.current -and [string]$decisionBindingStatus.status -eq 'bound') {
    [pscustomobject]@{ required=$true; action='GetPrivateGuidance'; taskInstanceId=[string]$contract.taskInstanceId; stageKind=[string]$contract.stageKind; intentFingerprint=if($contract.PSObject.Properties['decisionIntentFingerprint']){[string]$contract.decisionIntentFingerprint}else{''}; ownerSessionKey=[string]$contract.ownerSessionKey; receiptPath=[string]$contract.decisionBinding.path; bindingDigest=[string]$contract.decisionBinding.bindingDigest; rawDecisionBodyStoredInContract=$false }
  } else {
    [pscustomobject]@{ required=$false; action=''; taskInstanceId=''; stageKind=''; intentFingerprint=''; ownerSessionKey=''; receiptPath=''; bindingDigest=''; rawDecisionBodyStoredInContract=$false }
  }
  $continuityStatus = Get-ContractContinuityAuthorityStatus $contract
  if ($continuityStatus.required -and -not $continuityStatus.current) {
    return [pscustomobject]@{ ok=$false; code=[string]$continuityStatus.code; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint; continuity=$continuityStatus; guard='The task-scoped contract no longer matches its current context, TaskStateStore projection, route, or WAL. Reconcile the exact task before mutation; do not execute from the contract file alone.' }
  }
  if ([string]::IsNullOrWhiteSpace([string]$contract.nextAction)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_ACTIVE_PLAN_MISSING'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; guard='The active work line has no concrete next action. Recover a task-scoped plan before mutation; generic memory cannot authorize work.' } }
  $returnStack = @(Limit-ReturnStack @($contract.returnStack))
  if ($returnStack.Count -gt 0 -and [string]$returnStack[-1].focusId -eq $ProposedWorkId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PARENT_SUSPENDED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; returnTo=$returnStack[-1]; guard='The parent task is suspended behind a side branch. Complete or explicitly close the branch, then run ResumeParent before mutating the parent.' } }
  if (@($contract.invalidatedWorkItems) -contains $ProposedWorkId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_WORK_INVALIDATED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; invalidatedWorkItems=@($contract.invalidatedWorkItems); guard='The proposed work was superseded by a newer execution contract.' } }
  if (-not [string]::IsNullOrWhiteSpace($ProposedWorkId) -and -not [string]::IsNullOrWhiteSpace([string]$contract.focusId) -and $ProposedWorkId -ne [string]$contract.focusId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_FOCUS_MISMATCH'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; guard='Do not mutate a different work item without updating the task execution contract.' } }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_GUARD_OK'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; planFingerprint=[string]$contract.planReceipt.planFingerprint; canonicalPlanSource=$canonicalSourceStatus; continuity=$continuityStatus; intentReceipt=[pscustomobject]@{required=$intentReceiptStatus.required;current=$intentReceiptStatus.current;code=$intentReceiptStatus.code;missing=@($intentReceiptStatus.missing)}; decisionBinding=$decisionBindingStatus; decisionGuidance=$decisionGuidance; guard='Proposed work matches the latest current task execution contract and its bound continuity authority.' }
}

function Clear-Contract {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  $contractPath = Get-ContractPath $TaskId $WorkspaceKey
  $legacyPath = Get-LegacyContractPath $TaskId
  return Invoke-SuperBrainFileLock $contractPath {
    return Invoke-SuperBrainFileLock $legacyPath {
      return Invoke-SuperBrainFileLock $pointerPath {
        $removedContract = $false
        $identityConflict = $false
        $scoped = Read-ContractJson $contractPath
        $legacy = Read-ContractJson $legacyPath
        $pointer = Read-ContractJson $pointerPath
        foreach ($candidate in @($scoped,$legacy,$pointer)) {
          if ($candidate -and (Test-ContractIdentity $candidate $TaskId $WorkspaceKey)) {
            $sessionBlock = Get-ContractSessionMutationBlock $candidate 'Clear'
            if ($sessionBlock) { return $sessionBlock }
          }
        }
        $guardContract = @(@($scoped,$legacy,$pointer) | Where-Object { $_ -and (Test-ContractIdentity $_ $TaskId $WorkspaceKey) } | Select-Object -First 1)
        $guardContract = if ($guardContract.Count -gt 0) { $guardContract[0] } else { $null }
        $structuralFailure = Get-StructuralGuardFailure $guardContract 'Clear'
        if ($structuralFailure) { return $structuralFailure }
        if ($guardContract -and $ExpectedRevision -ge 0 -and [int]$guardContract.revision -ne $ExpectedRevision) {
          return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_REVISION_MISMATCH';taskId=$TaskId;expectedRevision=$ExpectedRevision;actualRevision=[int]$guardContract.revision;guard='The execution contract changed after the caller observed it. Resolve before clearing.'}
        }
        if ($guardContract -and -not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and [string]$guardContract.planReceipt.planFingerprint -ne $ExpectedPlanFingerprint) {
          return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH';taskId=$TaskId;expectedPlanFingerprint=$ExpectedPlanFingerprint;actualPlanFingerprint=[string]$guardContract.planReceipt.planFingerprint;guard='The accepted plan changed after the caller observed it. Resolve before clearing.'}
        }
        if ($scoped) {
          if (Test-ContractIdentity $scoped $TaskId $WorkspaceKey) {
            Remove-Item -LiteralPath $contractPath -Force
            $removedContract = $true
          } else { $identityConflict = $true }
        }
        if ($legacy) {
          if (Test-ContractIdentity $legacy $TaskId $WorkspaceKey) {
            Remove-Item -LiteralPath $legacyPath -Force
            $removedContract = $true
          } elseif (-not $removedContract) { $identityConflict = $true }
        }
        if ($pointer -and (Test-ContractIdentity $pointer $TaskId $WorkspaceKey) -and (Test-Path -LiteralPath $pointerPath)) {
          Remove-Item -LiteralPath $pointerPath -Force
          $removedContract = $true
        }
        if ($identityConflict -and -not $removedContract) {
          return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_IDENTITY_MISMATCH';action='Clear';taskId=$TaskId;workspaceKey=$WorkspaceKey;path=$contractPath;guard='A task-only or scoped contract exists, but its task and workspace identity does not match this clear request.'}
        }
        if ($removedContract) {
          try { Remove-SuperBrainRuntimeWakeEntry $memoryBase $SessionKey $WorkspaceKey $TaskId | Out-Null } catch {}
        }
        return [pscustomobject]@{ok=$true;action='Clear';taskId=$TaskId;workspaceKey=$WorkspaceKey;path=$contractPath;removed=$removedContract}
      }
    }
  }
}

function Write-Result($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 12 }
  else { Write-Host "EXECUTION_CONTRACT action=$Action ok=$($Value.ok) taskId=$TaskId focus=$($Value.focusId)" }
  if ($NoExit) { $script:ExecutionContractExitCode = $ExitCode; return }
  exit $ExitCode
}

try {
  Resolve-Identity
  if ($script:ProgressCheckpointBase64WasBound -and $Action -ne 'Set') {
    $invalidCheckpointAction = [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_ACTION_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; guard='A H7 progress checkpoint is valid only for the CAS-protected Set action.' }
    Write-Result $invalidCheckpointAction 1
    if ($NoExit) { return }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$script:ProgressCheckpointDecodeError)) {
    $invalidCheckpoint = [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_INVALID'; taskId=$TaskId; workspaceKey=$WorkspaceKey; reason=(Limit-ContractText ([string]$script:ProgressCheckpointDecodeError) 160); guard='The H7 progress checkpoint must be UTF-8 Base64 JSON with exactly source, current phase, step, next action, and assistant progress sentence.' }
    Write-Result $invalidCheckpoint 1
    if ($NoExit) { return }
  }
  if (@($script:AmbiguousTaskIds).Count -gt 1) {
    $ambiguous = [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TASK_AMBIGUOUS'; taskId=''; workspaceKey=$WorkspaceKey; candidateTaskIds=@($script:AmbiguousTaskIds); guard='Multiple active task contracts exist in this workspace. Supply an explicit task id; choosing the most recent contract would risk cross-task continuation.' }
    Write-Result $ambiguous 1
    if ($NoExit) { return }
  }
  if ([string]::IsNullOrWhiteSpace($TaskId) -and $Action -eq 'ObserveUser') {
    $foreignContextDetected = -not [string]::IsNullOrWhiteSpace($script:ForeignContextTaskId)
    $missing = [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_NOT_FOUND'; taskId=''; workspaceKey=$WorkspaceKey; sessionBoundRequest=(-not [string]::IsNullOrWhiteSpace($SessionKey)); foreignContextDetected=$foreignContextDetected; foreignContextSessionAccess=if($foreignContextDetected){$script:ForeignContextSessionState}else{''}; guard=if($foreignContextDetected){'The workspace context belongs to another or unbound root session. Automatic observation ignored it and made no mutation.'}else{'No active execution contract is bound to this root Codex session and workspace; automatic prompt observation made no mutation.'} }
    Write-Result $missing 1
    if ($NoExit) { return }
  }
  $result = switch ($Action) {
    'Set' { Set-Contract }
    'ObserveUser' { Set-Contract -ObserveOnly }
    'Get' { Get-ContractForSession }
    'Resolve' { Resolve-Contract }
    'Guard' { Guard-Work }
    'ValidatePlanReceipt' { Validate-PlanReceipt }
    'ValidateIntentReceipt' { Validate-IntentReceipt }
    'ResumeParent' { Resume-ParentContract }
    'CloseTurn' { Close-TurnContract }
    'PrepareMerge' { Prepare-MergeContract }
    'CompleteMerge' { Complete-MergeContract }
    'BindContext' { Bind-ContractContext }
    'RebindPackageVersion' { Rebind-PackageVersionContract }
    'Clear' { Clear-Contract }
  }
  if ($null -eq $result) { $result = [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_NOT_FOUND';taskId=$TaskId} }
  $exitCode = if ($result.ok -eq $true) { 0 } else { 1 }
  Write-Result $result $exitCode
} catch {
  Write-Result ([pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_ERROR';taskId=$TaskId;error=$_.Exception.Message}) 1
}
