param(
  [ValidateSet('Status','Collect','Maintain','Resolve','RecordVerification','IssueAdoptionReceipt')]
  [string]$Action = 'Status',
  [switch]$Json,
  [string]$Summary = '',
  [string]$TaskId = '',
  [string[]]$Evidence = @(),
  [string]$WorkspaceRoot = '',
  [int]$MaxActive = 32,
  [int]$ArchiveAfterDays = 14,
  [string]$CandidateId = '',
  [ValidateSet('resolved','adopted','rejected','duplicate','superseded','blocked')]
  [string]$Resolution = 'resolved',
  [string[]]$ResolutionEvidence = @(),
  [string]$VerificationId = '',
  [ValidateSet('pass','fail')]
  [string]$VerificationOutcome = 'pass',
  [string]$VerificationEvidenceRef = '',
  [string]$VerificationTaskId = '',
  [string]$VerificationWorkspaceKey = '',
  [string]$VerificationReceiptPath = '',
  [string]$EffectArtifactPath = '',
  [string]$OwnerSessionKey = '',
  [string]$AdoptionReceiptPath = '',
  [string]$AdoptionReceiptSha256 = '',
  [string]$ApprovalInstructionHash = '',
  [switch]$ConfirmAdoption,
  [int]$ExpectedRevision = -1
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$queuePath = Join-Path $workspace 'self-improvement-queue.json'
$lastPath = Join-Path $workspace 'last-self-improvement-queue.json'
$archiveRoot = Join-Path $workspace 'archive\self-improvement'
$reflectionRoot = Join-Path $workspace 'reflection\candidates'
$skillEvolutionProposalRoot = Join-Path $workspace 'skill-evolution\proposals'
$adoptionReceiptRoot = Join-Path $workspace 'runtime-state\learning-adoption-receipts'
$promotionTransactionRoot = Join-Path $workspace 'runtime-state\learning-promotion-transactions'
if ($MaxActive -lt 8) { $MaxActive = 8 }
if ($ArchiveAfterDays -lt 1) { $ArchiveAfterDays = 1 }

function Limit-Text([string]$Value, [int]$Max = 420) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $normalized = $Value.Trim() -replace '\s+', ' '
  if ($normalized.Length -gt $Max) { return $normalized.Substring(0, $Max) + '...' }
  return $normalized
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function New-Queue {
  return [pscustomobject]@{
    ok = $true
    schema = 'super-brain.self-improvement-queue.v3'
    version = [string]$manifest.version
    revision = 0
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    updatedAt = ''
    items = @()
  }
}

function Read-Queue {
  $queue = Read-JsonFile $queuePath
  if (-not $queue) { return New-Queue }
  if (-not $queue.PSObject.Properties['revision']) { $queue | Add-Member -NotePropertyName revision -NotePropertyValue 0 -Force }
  if ([int]$queue.revision -lt 0) { $queue.revision = 0 }
  return $queue
}

function Get-CompactHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..11] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-FamilyKey([string]$Kind, [string]$Title, [string]$Source, [string]$Target = '', [string]$Scope = '') {
  return 'improvement-' + (Get-CompactHash (($Kind.Trim().ToLowerInvariant()) + '|' + ($Title.Trim().ToLowerInvariant()) + '|' + ($Source.Trim().ToLowerInvariant()) + '|' + ($Target.Trim().ToLowerInvariant()) + '|' + ($Scope.Trim().ToLowerInvariant())))
}

function Get-ItemFamilyKey($Item) {
  if ($Item.PSObject.Properties['familyKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.familyKey)) { return [string]$Item.familyKey }
  $target = if ($Item.PSObject.Properties['target']) { [string]$Item.target } else { '' }
  $scope = if ($Item.PSObject.Properties['scope']) { [string]$Item.scope } else { '' }
  return Get-FamilyKey ([string]$Item.kind) ([string]$Item.title) ([string]$Item.source) $target $scope
}

function Get-PriorityRank([string]$Priority) {
  switch ($Priority) { 'high' { return 0 }; 'medium' { return 1 }; default { return 2 } }
}

function Get-StatusRank([string]$Status) {
  switch ($Status) {
    'validated' { return 0 }
    'adopted' { return 1 }
    'staged' { return 2 }
    'candidate' { return 3 }
    'blocked' { return 4 }
    default { return 5 }
  }
}

function Test-PrivateText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -match '(?i)(api[_-]?key|password|passwd|token|cookie|secret|private[_-]?key|authorization:)')
}

function Test-CompactId([string]$Value, [int]$Max = 120) {
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match ('^[A-Za-z0-9][A-Za-z0-9_.:-]{0,' + ($Max - 1) + '}$'))
}

function Test-VerificationEvidenceRef([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 260 -or $Value -match '\s' -or (Test-PrivateText $Value)) { return $false }
  if ($Value -match '(?i)(prompt|transcript|payload|base64|credential)') { return $false }
  return $Value -match '^(artifact|hash|report|task|test|receipt|verification|phase6):[A-Za-z0-9._:/=-]{4,240}$'
}

function Test-ResolutionEvidenceRef([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 260 -or $Value -match '\s' -or (Test-PrivateText $Value)) { return $false }
  if ($Value -match '(?i)(prompt|transcript|payload|base64|credential)') { return $false }
  return $Value -match '^(artifact|hash|report|task|test|receipt|verification|phase6):[A-Za-z0-9._:/=-]{4,240}$'
}

function Get-ActiveLifecycleStatus([object[]]$Members) {
  $latestStatus = [string]$Members[0].status
  if ($latestStatus -in @('resolved','adopted','rejected','duplicate','superseded')) { return $latestStatus }
  $statuses = @($Members | ForEach-Object { [string]$_.status })
  foreach ($status in @('validated','staged','candidate','blocked')) {
    if ($statuses -contains $status) { return $status }
  }
  return [string]$Members[0].status
}

function Test-AutoResolutionEligible($Item) {
  if (-not $Item) { return $false }
  if (-not ($Item.PSObject.Properties['autoResolutionEligible'] -and $Item.autoResolutionEligible -eq $true)) { return $false }
  if ([string]$Item.riskLevel -ne 'low' -or [string]$Item.changeClass -ne 'evidence_only') { return $false }
  $protected = (([string]$Item.kind) + '|' + ([string]$Item.title) + '|' + ([string]$Item.source) + '|' + ([string]$Item.target) + '|' + ([string]$Item.scope))
  return $protected -notmatch '(?i)(skill|rule|global|mcp|hook|install|startup|hot[ _-]?path|deploy|publish|release|secret)'
}

function Get-VerificationReceipts($Item) {
  if (-not $Item -or -not $Item.PSObject.Properties['verificationReceipts'] -or $null -eq $Item.verificationReceipts) { return @() }
  return @($Item.verificationReceipts | Where-Object {
    $_ -and (Test-CompactId ([string]$_.verificationId)) -and [string]$_.outcome -in @('pass','fail') -and (Test-VerificationEvidenceRef ([string]$_.evidenceRef))
  })
}

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return '' }
}

function New-NotScoredLearningEffect([string]$ReasonCode = 'comparable_effect_artifact_missing') {
  return [pscustomobject]@{
    status = 'not_scored'
    reasonCode = $ReasonCode
    improvementClaimAllowed = $false
    rawPromptStored = $false
    rawTranscriptStored = $false
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
}

function Get-EffectMetric($Metric, [string]$Name) {
  if (-not $Metric -or -not (Test-CompactId ([string]$Metric.metricId))) { throw "LEARNING_EFFECT_METRIC_INVALID: $Name metricId is missing or invalid." }
  $scenarioHash = [string]$Metric.scenarioFamilyHash
  if ($scenarioHash -notmatch '^[a-f0-9]{32,64}$') { throw "LEARNING_EFFECT_METRIC_INVALID: $Name scenario family hash is invalid." }
  $sampleCount = 0
  $passCount = 0
  if (-not [int]::TryParse([string]$Metric.sampleCount,[ref]$sampleCount) -or $sampleCount -lt 1) { throw "LEARNING_EFFECT_METRIC_INVALID: $Name sample count is invalid." }
  if (-not [int]::TryParse([string]$Metric.passCount,[ref]$passCount) -or $passCount -lt 0 -or $passCount -gt $sampleCount) { throw "LEARNING_EFFECT_METRIC_INVALID: $Name pass count is invalid." }
  $rate = 0.0
  if (-not [double]::TryParse([string]$Metric.passRate,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$rate) -or $rate -lt 0 -or $rate -gt 1) { throw "LEARNING_EFFECT_METRIC_INVALID: $Name pass rate is invalid." }
  $expectedRate = [double]$passCount / [double]$sampleCount
  if ([Math]::Abs($rate - $expectedRate) -gt 0.000001) { throw "LEARNING_EFFECT_METRIC_INVALID: $Name pass rate does not match counts." }
  return [pscustomobject]@{ metricId=[string]$Metric.metricId; scenarioFamilyHash=$scenarioHash; sampleCount=$sampleCount; passCount=$passCount; passRate=[Math]::Round($rate,6) }
}

function Read-LearningEffectArtifact([string]$Path, [string]$ProposalId, [string]$EvidenceFingerprint, [string]$TaskIdValue, [string]$WorkspaceKeyValue, [string]$OwnerSessionKeyValue) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return New-NotScoredLearningEffect }
  $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { '' }
  $artifactRoot = Join-Path $workspace 'runtime-state\learning-effect-artifacts'
  if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-SuperBrainChildPath $artifactRoot $fullPath)) { throw 'LEARNING_EFFECT_ARTIFACT_PATH_OUTSIDE_ROOT: effect evidence must stay under the scoped runtime artifact root.' }
  $artifact = Read-JsonFile $fullPath
  if (-not $artifact) { throw 'LEARNING_EFFECT_ARTIFACT_INVALID: effect artifact is unreadable.' }
  if ([string]$artifact.schema -eq 'super-brain.learning-effect-artifact.v1') { throw 'LEARNING_EFFECT_ARTIFACT_HISTORICAL: v1 effect artifacts cannot authorize a new adoption.' }
  if ([string]$artifact.schema -ne 'super-brain.learning-effect-artifact.v2') { throw 'LEARNING_EFFECT_ARTIFACT_INVALID: effect artifact schema is invalid.' }
  if ([string]$artifact.proposalId -ne $ProposalId -or [string]$artifact.evidenceFingerprint -ne $EvidenceFingerprint -or [string]$artifact.packageVersion -ne [string]$manifest.version) { throw 'LEARNING_EFFECT_ARTIFACT_IDENTITY_MISMATCH: effect artifact does not match the current proposal or package.' }
  $scopeBinding = $artifact.scopeBinding
  $tree = Get-SuperBrainSourceTreeBinding $Root
  $scopeBindingOk = (
    $scopeBinding -and
    [string]$scopeBinding.schema -eq 'super-brain.learning-effect-scope-binding.v1' -and
    [string]$scopeBinding.packageVersion -eq [string]$manifest.version -and
    [string]$scopeBinding.taskId -eq $TaskIdValue -and
    (Test-SuperBrainWorkspaceKey ([string]$scopeBinding.workspaceKey) $WorkspaceKeyValue) -and
    [string]$scopeBinding.ownerSessionKey -eq $OwnerSessionKeyValue -and
    [string]$scopeBinding.gitTreeHash -eq [string]$tree.gitTreeHash -and
    [string]$scopeBinding.gitHeadTreeHash -eq [string]$tree.gitHeadTreeHash -and
    [string]$scopeBinding.treeAlgorithm -eq [string]$tree.treeAlgorithm
  )
  if (-not $scopeBindingOk) { throw 'LEARNING_EFFECT_ARTIFACT_SCOPE_BINDING_MISMATCH: effect evidence is not current task/workspace/session/source-tree evidence.' }
  $privacy = $artifact.privacy
  if (-not $privacy -or $privacy.rawPromptStored -ne $false -or $privacy.rawTranscriptStored -ne $false -or $privacy.rawCasePayloadStored -ne $false) { throw 'LEARNING_EFFECT_ARTIFACT_PRIVACY_REJECTED: effect artifact is not privacy-safe.' }
  $checks = $artifact.checks
  if (-not $checks -or $checks.comparableScenario -ne $true -or $checks.independentHoldout -ne $true -or $checks.regressionFree -ne $true -or $checks.overfitGuardPassed -ne $true) { throw 'LEARNING_EFFECT_ARTIFACT_GUARD_REJECTED: comparable, holdout, regression, and anti-overfit checks are required.' }
  $baseline = Get-EffectMetric $artifact.baseline 'baseline'
  $treatment = Get-EffectMetric $artifact.treatment 'treatment'
  if ($baseline.metricId -ne $treatment.metricId -or $baseline.scenarioFamilyHash -ne $treatment.scenarioFamilyHash -or $baseline.sampleCount -ne $treatment.sampleCount) { throw 'LEARNING_EFFECT_ARTIFACT_NOT_COMPARABLE: baseline and treatment must use the same metric, sealed scenario family, and sample count.' }
  $delta = [Math]::Round(([double]$treatment.passRate - [double]$baseline.passRate),6)
  if ($delta -le 0) { throw 'LEARNING_EFFECT_ARTIFACT_NO_IMPROVEMENT: treatment must show a strictly positive measured effect before adoption.' }
  $sha256 = Get-FileSha256 $fullPath
  if ([string]::IsNullOrWhiteSpace($sha256)) { throw 'LEARNING_EFFECT_ARTIFACT_HASH_MISSING: effect artifact cannot be hashed.' }
  return [pscustomobject]@{
    status = 'scored'
    metricId = [string]$baseline.metricId
    scenarioFamilyHash = [string]$baseline.scenarioFamilyHash
    baseline = $baseline
    treatment = $treatment
    delta = $delta
    artifactSha256 = $sha256
    path = $fullPath
    improvementClaimAllowed = $true
    rawPromptStored = $false
    rawTranscriptStored = $false
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
}

function Get-QualifyingPassReceipts($Item) {
  $unique = @{}
  foreach ($receipt in @(Get-VerificationReceipts $Item | Where-Object {
    [string]$_.outcome -eq 'pass' -and
    (Test-CompactId ([string]$_.taskId)) -and
    ([string]$_.receiptHash -match '^[a-f0-9]{64}$') -and
    (Test-SuperBrainWorkspaceKey ([string]$_.workspaceKey) ([string]$_.workspaceKey))
  })) {
    $taskIdValue = [string]$receipt.taskId
    $receiptHash = [string]$receipt.receiptHash
    if ($unique.ContainsKey($taskIdValue) -or @($unique.Values | Where-Object { $_ -eq $receiptHash }).Count -gt 0) { continue }
    $unique[$taskIdValue] = $receiptHash
  }
  return @($unique.GetEnumerator() | ForEach-Object { [pscustomobject]@{ taskId=[string]$_.Key; receiptHash=[string]$_.Value } })
}

function Read-LearningVerificationReceipt([string]$Path, [string]$ExpectedId, [string]$ExpectedTaskId, [string]$ExpectedWorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'VERIFICATION_RECEIPT_PATH_REQUIRED: RecordVerification requires an immutable receipt path.' }
  $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { '' }
  $receiptRoot = Join-Path $workspace 'runtime-state\learning-verification-receipts'
  if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-SuperBrainChildPath $receiptRoot $fullPath)) { throw 'VERIFICATION_RECEIPT_PATH_OUTSIDE_ROOT: receipt must stay under the scoped runtime receipt root.' }
  $receipt = Read-JsonFile $fullPath
  if (-not $receipt -or [string]$receipt.schema -ne 'super-brain.learning-verification-receipt.v1') { throw 'VERIFICATION_RECEIPT_INVALID: receipt schema is invalid.' }
  if ([string]$receipt.receiptId -ne $ExpectedId -or [string]$receipt.taskId -ne $ExpectedTaskId -or -not (Test-SuperBrainWorkspaceKey ([string]$receipt.workspaceKey) $ExpectedWorkspaceKey)) { throw 'VERIFICATION_RECEIPT_IDENTITY_MISMATCH: receipt identity does not match the exact supplied task.' }
  if ([string]$receipt.packageVersion -ne [string]$manifest.version -or [string]$receipt.verificationArtifactHash -notmatch '^[a-f0-9]{64}$') { throw 'VERIFICATION_RECEIPT_STALE_OR_INVALID: receipt is not current or lacks a bound artifact hash.' }
  $privacyOk = ($receipt.privacy -and $receipt.privacy.rawPromptStored -eq $false -and $receipt.privacy.rawSummaryStored -eq $false -and $receipt.privacy.rawTranscriptStored -eq $false)
  $checks = $receipt.checks
  $checksOk = ($checks -and $checks.taskVerification -eq $true -and $checks.taskScopedGuard -eq $true -and $checks.completedCheckpoint -eq $true -and $checks.evidenceBindingCurrent -eq $true)
  $binding = $receipt.evidenceBinding
  $tree = Get-SuperBrainSourceTreeBinding $Root
  $bindingOk = ($binding -and [string]$binding.taskId -eq $ExpectedTaskId -and (Test-SuperBrainWorkspaceKey ([string]$binding.workspaceKey) $ExpectedWorkspaceKey) -and [string]$binding.packageVersion -eq [string]$manifest.version -and [string]$binding.gitTreeHash -eq [string]$tree.gitTreeHash -and [string]$binding.gitHeadTreeHash -eq [string]$tree.gitHeadTreeHash -and [string]$binding.treeAlgorithm -eq [string]$tree.treeAlgorithm)
  if (-not $privacyOk -or -not $checksOk -or -not $bindingOk) { throw 'VERIFICATION_RECEIPT_GUARD_REJECTED: receipt is not privacy-safe, fully verified, or current-bound.' }
  $sha256 = Get-FileSha256 $fullPath
  if ([string]::IsNullOrWhiteSpace($sha256)) { throw 'VERIFICATION_RECEIPT_HASH_MISSING: receipt cannot be hashed.' }
  return [pscustomobject]@{ receipt=$receipt; path=$fullPath; sha256=$sha256; ownerSessionKey=[string]$receipt.ownerSessionKey }
}

function Get-SkillEvolutionStatus([string]$Status) {
  switch ($Status) {
    'candidate' { return 'candidate' }
    'sealed-validated' { return 'staged' }
    'staged' { return 'staged' }
    'validated' { return 'staged' }
    'adopted' { return 'adopted' }
    'resolved' { return 'resolved' }
    'blocked' { return 'blocked' }
    'rejected' { return 'rejected' }
    'failed' { return 'rejected' }
    default { return '' }
  }
}

function Get-SkillEvolutionCanonicalStage($Proposal) {
  $allowed = @('candidate','sealed-validated','staged','adopted','resolved','blocked','rejected','historical')
  if ($Proposal -and $Proposal.PSObject.Properties['lifecycle'] -and $Proposal.lifecycle -and $Proposal.lifecycle.PSObject.Properties['canonicalStage']) {
    $declared = [string]$Proposal.lifecycle.canonicalStage
    if ($declared -in $allowed) { return $declared }
  }
  $validation = if ($Proposal -and $Proposal.PSObject.Properties['validation']) { $Proposal.validation } else { $null }
  if ($validation -and [string]$validation.contractVersion -eq 'legacy_v1') { return 'historical' }
  if ($validation -and [string]$validation.contractVersion -eq 'v2' -and [string]$validation.status -in @('validated','sealed-validated')) { return 'sealed-validated' }
  switch ([string]$Proposal.status) {
    'candidate' { return 'candidate' }
    'staged' { return 'candidate' }
    'validated' { return 'sealed-validated' }
    'adopted' { return 'adopted' }
    'resolved' { return 'resolved' }
    'blocked' { return 'blocked' }
    'rejected' { return 'rejected' }
    default { return '' }
  }
}

function Test-SkillEvolutionCandidate($Item) {
  if (-not $Item) { return $false }
  return ([string]$Item.kind -eq 'skill_evolution_proposal' -or [string]$Item.source -eq 'skill-evolution.ps1')
}

function Get-SkillEvolutionQueueStage($Item) {
  if ($Item -and $Item.PSObject.Properties['governanceLifecycleStage'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.governanceLifecycleStage)) {
    return [string]$Item.governanceLifecycleStage
  }
  if ([string]$Item.status -eq 'validated') { return 'staged' }
  return [string]$Item.status
}

function Test-SkillEvolutionResolutionEligible($Item) {
  return ((Test-SkillEvolutionCandidate $Item) -and [string]$Item.status -eq 'adopted' -and @(Get-QualifyingPassReceipts $Item).Count -ge 3)
}

function Test-SkillEvolutionAdoptionEligible($Item) {
  if (-not (Test-SkillEvolutionCandidate $Item) -or -not $Item.PSObject.Properties['validation'] -or -not $Item.validation) { return $false }
  return (
    (Get-SkillEvolutionQueueStage $Item) -eq 'staged' -and
    [string]$Item.validation.contractVersion -eq 'v2' -and
    [string]$Item.validation.status -eq 'sealed-validated' -and
    $Item.validation.sealedReplay -eq $true -and
    $Item.validation.sealedHoldout -eq $true -and
    $Item.validation.noConsumedHoldoutReuse -eq $true -and
    $Item.validation.overfitGuardPassed -eq $true -and
    [string]$Item.validation.artifactSha256 -match '^[a-f0-9]{64}$'
  )
}

function Read-SkillEvolutionProposals {
  $rows = New-Object System.Collections.ArrayList
  foreach ($file in @(Get-ChildItem -LiteralPath $skillEvolutionProposalRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $proposal = Read-JsonFile $file.FullName
    if (-not $proposal) { continue }
    $canonicalStage = Get-SkillEvolutionCanonicalStage $proposal
    $status = switch ($canonicalStage) {
      'candidate' { 'candidate' }
      'sealed-validated' { 'staged' }
      'staged' { 'staged' }
      'adopted' { 'adopted' }
      'resolved' { 'resolved' }
      'blocked' { 'blocked' }
      'rejected' { 'rejected' }
      'historical' { 'blocked' }
      default { Get-SkillEvolutionStatus ([string]$proposal.status) }
    }
    if (-not (Test-CompactId ([string]$proposal.id)) -or -not (Test-CompactId ([string]$proposal.evidenceFingerprint)) -or [string]::IsNullOrWhiteSpace($status)) { continue }
    [void]$rows.Add([pscustomobject]@{ value=$proposal; status=$status; canonicalStage=$canonicalStage; lastWriteTime=$file.LastWriteTime })
  }
  return @($rows)
}

function Sync-SkillEvolutionLifecycle([System.Collections.ArrayList]$Items, [object[]]$ProposalRows) {
  $added = 0
  $changed = 0
  foreach ($row in @($ProposalRows)) {
    $proposal = $row.value
    $queueStage = switch ([string]$row.canonicalStage) {
      'sealed-validated' { 'staged' }
      'candidate' { 'candidate' }
      'staged' { 'staged' }
      'adopted' { 'adopted' }
      'resolved' { 'resolved' }
      'blocked' { 'blocked' }
      'rejected' { 'rejected' }
      'historical' { 'blocked' }
      default { [string]$row.status }
    }
    $proposalId = [string]$proposal.id
    $fingerprint = [string]$proposal.evidenceFingerprint
    $familyKey = 'evolution-' + (Get-CompactHash ($proposalId + '|' + $fingerprint))
    $matches = @($Items | Where-Object {
      (Get-ItemFamilyKey $_) -eq $familyKey -or
      (@($_.proposalLinks) | Where-Object { [string]$_.proposalId -eq $proposalId -and [string]$_.evidenceFingerprint -eq $fingerprint }).Count -gt 0
    })
    if ($matches.Count -gt 1) { throw "SKILL_EVOLUTION_QUEUE_LINK_AMBIGUOUS proposalId=$proposalId" }
    if ($matches.Count -eq 0) {
      $item = [pscustomobject]@{
        id = 'improve-' + $familyKey.Substring($familyKey.Length - 12)
        familyKey = $familyKey
        kind = 'skill_evolution_proposal'
        title = Limit-Text ([string]$proposal.title) 140
        status = [string]$row.status
        governanceLifecycleStage = $queueStage
        priority = 'high'
        problem = Limit-Text ([string]$proposal.proposal) 520
        expected = 'Keep the proposal staged until an independent governed validation and explicit adoption decision exist.'
        evidence = @('proposal:' + $proposalId, 'fingerprint:' + $fingerprint)
        source = 'skill-evolution.ps1'
        target = Limit-Text ([string]$proposal.affected) 180
        scope = 'governed_change'
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        lastSeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        seenCount = 1
        mergedInstanceCount = 1
        proposalLinks = @([pscustomobject]@{ proposalId=$proposalId; evidenceFingerprint=$fingerprint; status=[string]$row.status; canonicalStage=[string]$row.canonicalStage; observedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
        verificationReceipts = @()
        effect = if ($proposal.PSObject.Properties['effect'] -and $proposal.effect) { $proposal.effect } else { New-NotScoredLearningEffect }
        validation = if ($proposal.PSObject.Properties['validation'] -and $proposal.validation) { $proposal.validation } else { [pscustomobject]@{ contractVersion='legacy_unknown'; status='unknown'; sealedReplay=$false; sealedHoldout=$false; noConsumedHoldoutReuse=$false; overfitGuardPassed=$false; artifactSha256=''; rawPromptStored=$false } }
        riskLevel = 'high'
        changeClass = 'governed_change'
        autoResolutionEligible = $false
        safety = [pscustomobject]@{ candidateOnly=$true; noAutomaticSkillMutation=$true; noExternalPublish=$true; requiresEvidenceBeforePromotion=$true; requiresConfirmationForRuleOrSkillChange=$true }
        nextAction = 'Keep the governed proposal separate from automatic adoption; require a matching validation artifact and explicit approval.'
      }
      [void]$Items.Add($item)
      $added++
      continue
    }
    $item = $matches[0]
    $item.lastSeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $item.evidence = @(@($item.evidence) + @('proposal:' + $proposalId, 'fingerprint:' + $fingerprint) | Select-Object -Unique | Select-Object -Last 16)
    $item | Add-Member -NotePropertyName proposalLinks -NotePropertyValue @([pscustomobject]@{ proposalId=$proposalId; evidenceFingerprint=$fingerprint; status=[string]$row.status; canonicalStage=[string]$row.canonicalStage; observedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    if (-not $item.PSObject.Properties['effect'] -or -not $item.effect) {
      $item | Add-Member -NotePropertyName effect -NotePropertyValue $(if ($proposal.PSObject.Properties['effect'] -and $proposal.effect) { $proposal.effect } else { New-NotScoredLearningEffect }) -Force
    }
    if ($proposal.PSObject.Properties['validation'] -and $proposal.validation) {
      $item | Add-Member -NotePropertyName validation -NotePropertyValue $proposal.validation -Force
    }
    if ([string]$item.status -notin @('adopted','rejected','resolved','duplicate','superseded')) {
      $item.status = [string]$row.status
      $item | Add-Member -NotePropertyName governanceLifecycleStage -NotePropertyValue $queueStage -Force
      if ([string]$row.status -eq 'rejected') {
        $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'skill-evolution.ps1:validation' -Force
        $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @('proposal:' + $proposalId, 'validation=rejected') -Force
      }
    }
    $changed++
  }
  return [pscustomobject]@{ added=$added; changed=$changed }
}

function Write-SkillEvolutionProposalProjection($Item) {
  if (-not (Test-SkillEvolutionCandidate $Item)) { return [pscustomobject]@{ attempted=0; projected=0; errors=@() } }
  $projected = 0
  $errors = New-Object System.Collections.ArrayList
  foreach ($link in @($Item.proposalLinks | Where-Object {
    $_ -and (Test-CompactId ([string]$_.proposalId)) -and (Test-CompactId ([string]$_.evidenceFingerprint))
  })) {
    $proposalId = [string]$link.proposalId
    $proposalPath = Join-Path $skillEvolutionProposalRoot ($proposalId + '.json')
    try {
      $proposal = Read-JsonFile $proposalPath
      if (-not $proposal -or [string]$proposal.id -ne $proposalId -or [string]$proposal.evidenceFingerprint -ne [string]$link.evidenceFingerprint) {
        throw "SKILL_EVOLUTION_PROJECTION_IDENTITY_MISMATCH proposalId=$proposalId"
      }
      $proposal | Add-Member -NotePropertyName status -NotePropertyValue ([string]$Item.status) -Force
      $proposal | Add-Member -NotePropertyName lifecycle -NotePropertyValue ([pscustomobject]@{
        authority = 'self-improvement-queue.ps1'
        status = [string]$Item.status
        canonicalStage = if ($Item.PSObject.Properties['governanceLifecycleStage']) { [string]$Item.governanceLifecycleStage } else { [string]$Item.status }
        queueCandidateId = [string]$Item.id
        updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        projected = $true
        approvalReceipt = if ($Item.PSObject.Properties['approvalReceipt']) { [string]$Item.approvalReceipt } else { '' }
        resolutionEvidence = if ($Item.PSObject.Properties['resolutionEvidence']) { @($Item.resolutionEvidence | Select-Object -First 8) } else { @() }
      }) -Force
      $proposal | Add-Member -NotePropertyName effect -NotePropertyValue $(if ($Item.PSObject.Properties['effect'] -and $Item.effect) { $Item.effect } else { New-NotScoredLearningEffect }) -Force
      if ([string]$Item.status -eq 'adopted') {
        $proposal | Add-Member -NotePropertyName adoptedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
      }
      if ([string]$Item.status -eq 'resolved') {
        $proposal | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
      }
      Write-JsonUtf8NoBom $proposalPath $proposal 14
      $indexPath = Join-Path (Join-Path $workspace 'skill-evolution') 'index.json'
      $index = Read-JsonFile $indexPath
      if ($index -and $index.proposals) {
        foreach ($indexProposal in @($index.proposals | Where-Object { [string]$_.id -eq $proposalId })) { $indexProposal.status = [string]$Item.status }
        $index.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Write-JsonUtf8NoBom $indexPath $index 10
      }
      $projected++
    } catch {
      [void]$errors.Add((Limit-Text ([string]$_.Exception.Message) 260))
    }
  }
  return [pscustomobject]@{ attempted=@($Item.proposalLinks).Count; projected=$projected; errors=@($errors) }
}

function Write-LearningAdoptionReceipt($Item, $VerificationResult, $Effect, [string]$TaskIdValue, [string]$WorkspaceKeyValue, [string]$OwnerSessionKeyValue, [string]$InstructionHash) {
  if (-not (Test-CompactId ([string]$Item.id)) -or -not (Test-CompactId $TaskIdValue) -or -not (Test-CompactId $WorkspaceKeyValue) -or $OwnerSessionKeyValue -notmatch '^sid-[A-Za-z0-9._:-]{8,120}$') {
    throw 'ADOPTION_RECEIPT_IDENTITY_INVALID: candidate, task, workspace, and owner session must be exact current identifiers.'
  }
  if ($InstructionHash -notmatch '^[a-f0-9]{64}$') { throw 'ADOPTION_RECEIPT_INSTRUCTION_HASH_REQUIRED: use the current user-confirmation instruction hash.' }
  $effectHash = if ($Effect -and $Effect.PSObject.Properties['artifactSha256']) { [string]$Effect.artifactSha256 } else { '' }
  $artifactPath = if (-not [string]::IsNullOrWhiteSpace($effectHash)) { [string]$Effect.path } else { [string]$VerificationResult.path }
  $artifactHash = if (-not [string]::IsNullOrWhiteSpace($effectHash)) { $effectHash } else { [string]$VerificationResult.sha256 }
  $artifactKind = if (-not [string]::IsNullOrWhiteSpace($effectHash)) { 'learning_effect_artifact' } else { 'learning_verification_receipt' }
  $binding = New-SuperBrainEvidenceBinding -TaskId $TaskIdValue -WorkspaceKey $WorkspaceKeyValue -OwnerSessionKey $OwnerSessionKeyValue -ArtifactHash $artifactHash -ArtifactKind $artifactKind -Root $Root
  $proposalLink = @($Item.proposalLinks | Select-Object -First 1)[0]
  $record = [pscustomobject]@{
    schema = 'super-brain.learning-adoption-receipt.v1'
    producer = 'self-improvement-queue.ps1'
    actor = 'real_user'
    authorityKind = 'local_explicit_adoption'
    decision = 'adopted'
    candidateId = [string]$Item.id
    proposalId = if ($proposalLink) { [string]$proposalLink.proposalId } else { '' }
    evidenceFingerprint = if ($proposalLink) { [string]$proposalLink.evidenceFingerprint } else { '' }
    taskId = $TaskIdValue
    workspaceKey = $WorkspaceKeyValue
    ownerSessionKey = $OwnerSessionKeyValue
    packageVersion = [string]$manifest.version
    approvalInstructionHash = $InstructionHash
    verificationReceipt = [pscustomobject]@{
      relativePath = ('runtime-state/learning-verification-receipts/' + [IO.Path]::GetFileName([string]$VerificationResult.path))
      sha256 = [string]$VerificationResult.sha256
      receiptId = [string]$VerificationResult.receipt.receiptId
    }
    validationArtifactHash = if ($Item.PSObject.Properties['validation'] -and $Item.validation) { [string]$Item.validation.artifactSha256 } else { [string]$VerificationResult.sha256 }
    effectArtifactHash = $effectHash
    effectArtifact = if (-not [string]::IsNullOrWhiteSpace($effectHash)) {
      [pscustomobject]@{
        relativePath = ('runtime-state/learning-effect-artifacts/' + [IO.Path]::GetFileName([string]$Effect.path))
        sha256 = $effectHash
      }
    } else {
      $null
    }
    evidenceBinding = $binding
    privacy = [pscustomobject]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
    issuedAt = (Get-Date).ToString('o')
  }
  New-Item -ItemType Directory -Force -Path $adoptionReceiptRoot | Out-Null
  $pending = Join-Path $adoptionReceiptRoot ('.pending-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    Write-JsonUtf8NoBom $pending $record 12
    $sha256 = Get-FileSha256 $pending
    if ($sha256 -notmatch '^[a-f0-9]{64}$') { throw 'ADOPTION_RECEIPT_HASH_MISSING: receipt cannot be hashed.' }
    $candidateToken = 'c-' + (Get-SuperBrainStableHash ([string]$Item.id) 16)
    $path = Join-Path $adoptionReceiptRoot ($candidateToken + '--' + $sha256 + '.json')
    Move-Item -LiteralPath $pending -Destination $path -Force
    return [pscustomobject]@{ path=$path; sha256=$sha256; record=$record }
  } finally {
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
  }
}

function Read-LearningAdoptionReceipt([string]$Path, [string]$ExpectedSha256, $Item, [string]$TaskIdValue, [string]$WorkspaceKeyValue, [string]$OwnerSessionKeyValue, [string]$EffectPath) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $ExpectedSha256 -notmatch '^[a-f0-9]{64}$') { throw 'ADOPTION_RECEIPT_REFERENCE_REQUIRED: adoption requires the exact immutable receipt path and sha256.' }
  $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { '' }
  if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-SuperBrainChildPath $adoptionReceiptRoot $fullPath) -or (Get-FileSha256 $fullPath) -ne $ExpectedSha256.ToLowerInvariant()) {
    throw 'ADOPTION_RECEIPT_MISMATCH: receipt must be current, content-addressed, and scoped under the adoption receipt root.'
  }
  $receipt = Read-JsonFile $fullPath
  if (-not $receipt -or [string]$receipt.schema -ne 'super-brain.learning-adoption-receipt.v1' -or [string]$receipt.producer -ne 'self-improvement-queue.ps1' -or [string]$receipt.actor -ne 'real_user' -or [string]$receipt.authorityKind -ne 'local_explicit_adoption' -or [string]$receipt.decision -ne 'adopted') {
    throw 'ADOPTION_RECEIPT_INVALID: receipt provenance or decision is invalid.'
  }
  if ([string]$receipt.candidateId -ne [string]$Item.id -or [string]$receipt.taskId -ne $TaskIdValue -or -not (Test-SuperBrainWorkspaceKey ([string]$receipt.workspaceKey) $WorkspaceKeyValue) -or [string]$receipt.ownerSessionKey -ne $OwnerSessionKeyValue -or [string]$receipt.packageVersion -ne [string]$manifest.version -or [string]$receipt.approvalInstructionHash -notmatch '^[a-f0-9]{64}$') {
    throw 'ADOPTION_RECEIPT_IDENTITY_MISMATCH: receipt is not bound to this candidate, task, workspace, session, or package.'
  }
  $verificationRelative = [string]$receipt.verificationReceipt.relativePath
  if ([string]::IsNullOrWhiteSpace($verificationRelative) -or [IO.Path]::IsPathRooted($verificationRelative) -or $verificationRelative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'ADOPTION_RECEIPT_VERIFICATION_PATH_INVALID: receipt verification reference is unsafe.' }
  $verificationPath = [IO.Path]::GetFullPath((Join-Path $workspace ($verificationRelative -replace '/','\')))
  $verification = Read-LearningVerificationReceipt $verificationPath ([string]$receipt.verificationReceipt.receiptId) $TaskIdValue $WorkspaceKeyValue
  if ([string]$verification.sha256 -ne [string]$receipt.verificationReceipt.sha256 -or [string]$verification.ownerSessionKey -ne $OwnerSessionKeyValue) { throw 'ADOPTION_RECEIPT_VERIFICATION_MISMATCH: receipt verification binding is not current.' }
  $effect = $null
  $artifactPath = [string]$verification.path
  if (Test-SkillEvolutionCandidate $Item) {
    $proposalLink = @($Item.proposalLinks | Select-Object -First 1)[0]
    $proposalId = if ($proposalLink) { [string]$proposalLink.proposalId } else { '' }
    $proposalFingerprint = if ($proposalLink) { [string]$proposalLink.evidenceFingerprint } else { '' }
    if ([string]$receipt.validationArtifactHash -ne [string]$Item.validation.artifactSha256) { throw 'ADOPTION_RECEIPT_VALIDATION_MISMATCH: receipt validation artifact does not match the sealed candidate validation.' }
    $effectRelative = [string]$receipt.effectArtifact.relativePath
    if ([string]::IsNullOrWhiteSpace($effectRelative) -or [IO.Path]::IsPathRooted($effectRelative) -or $effectRelative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'ADOPTION_RECEIPT_EFFECT_PATH_INVALID: receipt effect reference is unsafe.' }
    $receiptEffectPath = [IO.Path]::GetFullPath((Join-Path $workspace ($effectRelative -replace '/','\')))
    if ((Get-FileSha256 $receiptEffectPath) -ne [string]$receipt.effectArtifact.sha256 -or [string]$receipt.effectArtifact.sha256 -ne [string]$receipt.effectArtifactHash) { throw 'ADOPTION_RECEIPT_EFFECT_REFERENCE_MISMATCH: receipt effect reference is not immutable.' }
    $effect = Read-LearningEffectArtifact $EffectPath $proposalId $proposalFingerprint $TaskIdValue $WorkspaceKeyValue $OwnerSessionKeyValue
    if ([string]$receipt.effectArtifactHash -ne [string]$effect.artifactSha256 -or (Get-FileSha256 $receiptEffectPath) -ne (Get-FileSha256 $EffectPath)) { throw 'ADOPTION_RECEIPT_EFFECT_MISMATCH: receipt effect artifact does not match the supplied current artifact.' }
    $artifactPath = [string]$EffectPath
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$receipt.effectArtifactHash)) {
    throw 'ADOPTION_RECEIPT_EFFECT_UNEXPECTED: non-governed candidates cannot carry an unvalidated effect artifact.'
  }
  $bindingCheck = Test-SuperBrainEvidenceBinding -Binding $receipt.evidenceBinding -TaskId $TaskIdValue -WorkspaceKey $WorkspaceKeyValue -OwnerSessionKey $OwnerSessionKeyValue -ArtifactPath $artifactPath -RequireArtifactHash -Root $Root
  if (-not $bindingCheck.ok) { throw ('ADOPTION_RECEIPT_BINDING_' + [string]$bindingCheck.reason) }
  return [pscustomobject]@{ receipt=$receipt; path=$fullPath; sha256=$ExpectedSha256.ToLowerInvariant(); effect=$effect }
}

function Test-ControlledMemoryPromotionCandidate($Item) {
  if (-not $Item) { return $false }
  return ([string]$Item.source -eq 'reflection-promotion.ps1' -and [string]$Item.target -in @('experience','memory'))
}

function Invoke-QueueChildJson([string]$ScriptPath, [hashtable]$Parameters) {
  $raw = @(& $ScriptPath @Parameters 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  $value = $null
  if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
    try { $value = $text | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function Get-ControlledPromotionTransactionPath([string]$CandidateIdValue, [string]$ReceiptSha256) {
  $candidateToken = 'c-' + (Get-SuperBrainStableHash $CandidateIdValue 16)
  return Join-Path $promotionTransactionRoot ($candidateToken + '--' + $ReceiptSha256 + '.json')
}

function Invoke-ControlledMemoryPromotion($Item, $Adoption) {
  if (-not (Test-ControlledMemoryPromotionCandidate $Item)) { throw 'CONTROLLED_MEMORY_PROMOTION_TARGET_INVALID: only staged reflection experience or memory candidates may use the controlled writer.' }
  $summary = Limit-Text ([string]$Item.problem) 900
  $title = Limit-Text ([string]$Item.title) 180
  if ([string]::IsNullOrWhiteSpace($summary) -or [string]::IsNullOrWhiteSpace($title)) { throw 'CONTROLLED_MEMORY_PROMOTION_CONTENT_MISSING: candidate summary and title are required.' }
  $transactionPath = Get-ControlledPromotionTransactionPath ([string]$Item.id) ([string]$Adoption.sha256)
  $existing = Read-JsonFile $transactionPath
  if ($existing -and [string]$existing.schema -eq 'super-brain.controlled-memory-promotion-transaction.v1' -and [string]$existing.candidateId -eq [string]$Item.id -and [string]$existing.adoptionReceiptSha256 -eq [string]$Adoption.sha256 -and [string]$existing.state -in @('memory_written','deduplicated','committed')) {
    return [pscustomobject]@{ path=$transactionPath; state=[string]$existing.state; replayed=$true; memoryLayer=[string]$existing.memoryLayer; rawPromptStored=$false }
  }
  New-Item -ItemType Directory -Force -Path $promotionTransactionRoot | Out-Null
  $memoryLayer = if ([string]$Item.target -eq 'memory') { 'project' } else { 'experience' }
  $transaction = [pscustomobject]@{
    schema = 'super-brain.controlled-memory-promotion-transaction.v1'
    candidateId = [string]$Item.id
    target = [string]$Item.target
    memoryLayer = $memoryLayer
    titleHash = Get-SuperBrainStableHash $title 32
    summaryHash = Get-SuperBrainStableHash $summary 32
    adoptionReceiptSha256 = [string]$Adoption.sha256
    taskId = [string]$Adoption.receipt.taskId
    workspaceKey = [string]$Adoption.receipt.workspaceKey
    ownerSessionKey = [string]$Adoption.receipt.ownerSessionKey
    packageVersion = [string]$manifest.version
    state = 'prepared'
    preparedAt = (Get-Date).ToString('o')
    privacy = [pscustomobject]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  }
  Write-JsonUtf8NoBom $transactionPath $transaction 12
  $write = Invoke-QueueChildJson (Join-Path $PSScriptRoot 'learn-memory.ps1') @{
    Text = $summary
    Layer = $memoryLayer
    Title = $title
    Tags = @('[LEARNING]')
    Evidence = @('receipt:' + [string]$Adoption.sha256, 'candidate:' + [string]$Item.id)
    TaskId = [string]$Adoption.receipt.taskId
    WorkspaceKey = [string]$Adoption.receipt.workspaceKey
    SessionId = [string]$Adoption.receipt.ownerSessionKey
    WorkspaceRoot = $workspace
    MemoryMode = 'force'
    Json = $true
  }
  if ($write.exitCode -ne 0 -or -not $write.value -or $write.value.ok -ne $true) {
    $transaction.state = 'failed'
    $transaction | Add-Member -NotePropertyName failureCode -NotePropertyValue 'controlled_memory_writer_failed' -Force
    $transaction | Add-Member -NotePropertyName failedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    Write-JsonUtf8NoBom $transactionPath $transaction 12
    throw 'CONTROLLED_MEMORY_PROMOTION_WRITE_FAILED: governed memory writer did not return a successful compact result.'
  }
  $transaction.state = if ($write.value.preview -eq $true) { 'deduplicated' } else { 'memory_written' }
  $transaction | Add-Member -NotePropertyName wroteAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
  $transaction | Add-Member -NotePropertyName writerResult -NotePropertyValue ([pscustomobject]@{
    ok = $true
    preview = ($write.value.preview -eq $true)
    decision = Limit-Text ([string]$write.value.decision) 80
    rawPromptStored = $false
  }) -Force
  Write-JsonUtf8NoBom $transactionPath $transaction 12
  return [pscustomobject]@{ path=$transactionPath; state=[string]$transaction.state; replayed=$false; memoryLayer=$memoryLayer; rawPromptStored=$false }
}

function Complete-ControlledMemoryPromotion($Promotion) {
  if (-not $Promotion -or [string]::IsNullOrWhiteSpace([string]$Promotion.path)) { return $null }
  $transaction = Read-JsonFile ([string]$Promotion.path)
  if (-not $transaction -or [string]$transaction.schema -ne 'super-brain.controlled-memory-promotion-transaction.v1' -or [string]$transaction.state -notin @('memory_written','deduplicated','committed')) { throw 'CONTROLLED_MEMORY_PROMOTION_TRANSACTION_INVALID: transaction cannot be committed.' }
  if ([string]$transaction.state -ne 'committed') {
    $transaction.state = 'committed'
    $transaction | Add-Member -NotePropertyName committedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    Write-JsonUtf8NoBom ([string]$Promotion.path) $transaction 12
  }
  return $transaction
}

function Mark-ReflectionCandidatePromoted($Item, $Promotion) {
  if (-not $Promotion -or -not (Test-ControlledMemoryPromotionCandidate $Item)) { return }
  $ids = @($Item.reflectionCandidateIds | Where-Object { Test-CompactId ([string]$_) } | Select-Object -Unique)
  foreach ($file in @(Get-ChildItem -LiteralPath $reflectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $candidate = Read-JsonFile $file.FullName
    if (-not $candidate -or $ids -notcontains [string]$candidate.id) { continue }
    if (-not $candidate.lifecycle) { $candidate | Add-Member -NotePropertyName lifecycle -NotePropertyValue ([pscustomobject]@{}) -Force }
    $candidate.lifecycle | Add-Member -NotePropertyName status -NotePropertyValue 'adopted' -Force
    $candidate.lifecycle | Add-Member -NotePropertyName reason -NotePropertyValue 'controlled_memory_promotion_committed' -Force
    $candidate.lifecycle | Add-Member -NotePropertyName lastSeenAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    if (-not $candidate.promotion) { $candidate | Add-Member -NotePropertyName promotion -NotePropertyValue ([pscustomobject]@{}) -Force }
    $candidate.promotion | Add-Member -NotePropertyName applied -NotePropertyValue $true -Force
    $candidate.promotion | Add-Member -NotePropertyName transactionSha256 -NotePropertyValue (Get-FileSha256 ([string]$Promotion.path)) -Force
    $candidate.promotion | Add-Member -NotePropertyName rawPromptStored -NotePropertyValue $false -Force
    Write-JsonUtf8NoBom $file.FullName $candidate 12
  }
}

function Write-QueueWithRevision($Queue, [int]$ExpectedQueueRevision) {
  Invoke-SuperBrainFileLock $queuePath {
    $liveQueue = Read-JsonFile $queuePath
    $liveRevision = if ($liveQueue -and $liveQueue.PSObject.Properties['revision']) { [int]$liveQueue.revision } else { 0 }
    if ($liveRevision -ne $ExpectedQueueRevision) { throw "SELF_IMPROVEMENT_QUEUE_REVISION_CONFLICT expected=$ExpectedQueueRevision actual=$liveRevision" }
    $Queue | Add-Member -NotePropertyName revision -NotePropertyValue ($ExpectedQueueRevision + 1) -Force
    $content = $Queue | ConvertTo-Json -Depth 16
    $tmp = "$queuePath.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
      [IO.File]::WriteAllText($tmp, $content, [Text.UTF8Encoding]::new($false))
      Move-Item -LiteralPath $tmp -Destination $queuePath -Force
    } finally {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  } | Out-Null
}

function Get-DateValue([object]$Value, [datetime]$Fallback = [datetime]::MinValue) {
  $parsed = [datetime]::MinValue
  if ($null -ne $Value -and [datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
  return $Fallback
}

function Merge-FamilyItems([object[]]$Items) {
  $families = New-Object System.Collections.ArrayList
  foreach ($group in @($Items | Group-Object { Get-ItemFamilyKey $_ })) {
    $members = @($group.Group | Sort-Object @{Expression={ Get-DateValue $_.lastSeenAt (Get-DateValue $_.createdAt) };Descending=$true})
    $latest = $members[0]
    $createdValues = @($members | ForEach-Object { Get-DateValue $_.createdAt } | Where-Object { $_ -ne [datetime]::MinValue })
    $lastValues = @($members | ForEach-Object { Get-DateValue $_.lastSeenAt (Get-DateValue $_.createdAt) } | Where-Object { $_ -ne [datetime]::MinValue })
    $latest | Add-Member -NotePropertyName familyKey -NotePropertyValue ([string]$group.Name) -Force
    $latest | Add-Member -NotePropertyName status -NotePropertyValue (Get-ActiveLifecycleStatus $members) -Force
    $latest | Add-Member -NotePropertyName createdAt -NotePropertyValue $(if ($createdValues.Count -gt 0) { ($createdValues | Sort-Object | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    $latest | Add-Member -NotePropertyName lastSeenAt -NotePropertyValue $(if ($lastValues.Count -gt 0) { ($lastValues | Sort-Object -Descending | Select-Object -First 1).ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    $latest | Add-Member -NotePropertyName seenCount -NotePropertyValue ([int](@($members | ForEach-Object { if ($_.seenCount) { [int]$_.seenCount } else { 1 } } | Measure-Object -Sum).Sum)) -Force
    $latest | Add-Member -NotePropertyName evidence -NotePropertyValue @($members | ForEach-Object { @($_.evidence) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16) -Force
    $latest | Add-Member -NotePropertyName sampleIds -NotePropertyValue @($members | ForEach-Object { @($_.sampleIds) + @($_.sampleId) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16) -Force
    $latest | Add-Member -NotePropertyName proposalLinks -NotePropertyValue @($members | ForEach-Object { @($_.proposalLinks) } | Where-Object { $_ -and (Test-CompactId ([string]$_.proposalId)) } | Sort-Object proposalId -Unique | Select-Object -Last 8) -Force
    $latest | Add-Member -NotePropertyName verificationReceipts -NotePropertyValue @($members | ForEach-Object { Get-VerificationReceipts $_ } | Sort-Object recordedAt -Descending | Group-Object verificationId | ForEach-Object { $_.Group | Select-Object -First 1 } | Select-Object -First 8) -Force
    $latest | Add-Member -NotePropertyName mergedInstanceCount -NotePropertyValue $members.Count -Force
    [void]$families.Add($latest)
  }
  return @($families)
}

function Add-OrUpdateFamily([System.Collections.ArrayList]$Items, [string]$Kind, [string]$Title, [string]$Problem, [string]$Expected, [string[]]$EvidenceItems, [string]$Priority, [string]$Source, [string]$Target = '', [string]$Scope = '') {
  $familyKey = Get-FamilyKey $Kind $Title $Source $Target $Scope
  $existing = @($Items | Where-Object { (Get-ItemFamilyKey $_) -eq $familyKey } | Select-Object -First 1)
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if ($existing.Count -gt 0) {
    $item = $existing[0]
    $item.lastSeenAt = $now
    $item.seenCount = $(if ($item.seenCount) { [int]$item.seenCount + 1 } else { 2 })
    $item.problem = Limit-Text $Problem 520
    $item.expected = Limit-Text $Expected 520
    $item.evidence = @(@($item.evidence) + @($EvidenceItems) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16)
    return $false
  }
  $candidate = [pscustomobject]@{
    id = 'improve-' + $familyKey.Substring($familyKey.Length - 12)
    familyKey = $familyKey
    kind = $Kind
    title = Limit-Text $Title 140
    status = 'candidate'
    priority = $Priority
    problem = Limit-Text $Problem 520
    expected = Limit-Text $Expected 520
    evidence = @($EvidenceItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -Last 16)
    source = $Source
    target = $Target
    scope = $Scope
    createdAt = $now
    lastSeenAt = $now
    seenCount = 1
    mergedInstanceCount = 1
    proposalLinks = @()
    verificationReceipts = @()
    effect = (New-NotScoredLearningEffect)
    riskLevel = 'medium'
    changeClass = 'governed_change'
    autoResolutionEligible = $false
    safety = [pscustomobject]@{ candidateOnly=$true; noAutomaticSkillMutation=$true; noExternalPublish=$true; requiresEvidenceBeforePromotion=$true; requiresConfirmationForRuleOrSkillChange=$true }
    nextAction = 'Verify reuse and scope, then close as adopted, rejected, duplicate, superseded, or blocked through a governed learning action.'
  }
  [void]$Items.Add($candidate)
  return $true
}

function Link-ReflectionCandidate([System.Collections.ArrayList]$Items, [string]$Kind, [string]$Title, [string]$Target, [string]$Scope, [string]$CandidateId) {
  if (-not (Test-CompactId $CandidateId)) { throw 'REFLECTION_CANDIDATE_ID_INVALID: reflection candidate id must be a compact stable id.' }
  $familyKey = Get-FamilyKey $Kind $Title 'reflection-promotion.ps1' $Target $Scope
  $matches = @($Items | Where-Object { (Get-ItemFamilyKey $_) -eq $familyKey })
  if ($matches.Count -ne 1) { throw "REFLECTION_CANDIDATE_QUEUE_LINK_AMBIGUOUS candidateId=$CandidateId matches=$($matches.Count)" }
  $item = $matches[0]
  $ids = @(@($item.reflectionCandidateIds) + @($CandidateId) | Where-Object { Test-CompactId ([string]$_) } | Select-Object -Unique | Select-Object -Last 12)
  $item | Add-Member -NotePropertyName reflectionCandidateIds -NotePropertyValue $ids -Force
  return $item
}

function Get-QueueSummary([object[]]$Items, [int]$Added = 0, [int]$Archived = 0, [int]$Merged = 0) {
  $activeItems = @($Items | Where-Object {
    [string]$_.status -in @('candidate','staged','validated','blocked') -or ((Test-SkillEvolutionCandidate $_) -and [string]$_.status -eq 'adopted')
  })
  return [pscustomobject]@{
    total = @($Items).Count
    active = $activeItems.Count
    candidate = @($Items | Where-Object { [string]$_.status -eq 'candidate' }).Count
    staged = @($Items | Where-Object { [string]$_.status -eq 'staged' }).Count
    validated = @($Items | Where-Object { [string]$_.status -eq 'validated' }).Count
    blocked = @($Items | Where-Object { [string]$_.status -eq 'blocked' }).Count
    high = @($Items | Where-Object { $_.priority -eq 'high' }).Count
    medium = @($Items | Where-Object { $_.priority -eq 'medium' }).Count
    low = @($Items | Where-Object { $_.priority -eq 'low' }).Count
    effectScored = @($Items | Where-Object { $_.effect -and [string]$_.effect.status -eq 'scored' }).Count
    effectNotScored = @($Items | Where-Object { -not $_.effect -or [string]$_.effect.status -eq 'not_scored' }).Count
    added = $Added
    archived = $Archived
    merged = $Merged
    maxActive = $MaxActive
    overBudget = ($activeItems.Count -gt $MaxActive)
  }
}

function Write-Archive([object[]]$QueueItems, [object[]]$ReflectionItems, [string]$Reason) {
  if (@($QueueItems).Count -eq 0 -and @($ReflectionItems).Count -eq 0) { return $null }
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $path = Join-Path $archiveRoot ("candidates-$stamp.json")
  $archive = [pscustomobject]@{
    schema = 'super-brain.self-improvement-archive.v1'
    archivedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    reason = $Reason
    sourceQueue = $queuePath
    queueItems = @($QueueItems)
    reflectionItems = @($ReflectionItems)
    restore = 'Copy selected queueItems back into self-improvement-queue.json or reflectionItems back to reflection/candidates after review.'
  }
  Write-JsonUtf8NoBom $path $archive 16
  return $path
}

function Read-ReflectionCandidates {
  $rows = New-Object System.Collections.ArrayList
  foreach ($file in @(Get-ChildItem -LiteralPath $reflectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $candidate = Read-JsonFile $file.FullName
    if ($candidate) { [void]$rows.Add([pscustomobject]@{ path=$file.FullName; lastWriteTime=$file.LastWriteTime; value=$candidate }) }
  }
  return @($rows)
}

function Sync-ReflectionLifecycle([System.Collections.ArrayList]$Items, [object[]]$ReflectionRows) {
  $changed = 0
  $terminalStatuses = @('resolved','adopted','rejected','duplicate','superseded','blocked','closed')
  foreach ($item in @($Items | Where-Object { [string]$_.source -eq 'reflection-promotion.ps1' })) {
    $candidateIds = @($item.reflectionCandidateIds | Where-Object { Test-CompactId ([string]$_) } | Select-Object -Unique)
    if ($candidateIds.Count -eq 0) { continue }
    $matches = @($ReflectionRows | Where-Object {
      $candidateIds -contains [string]$_.value.id -and
      $_.value.lifecycle -and [string]$_.value.lifecycle.status -in $terminalStatuses
    } | Sort-Object { Get-DateValue $_.value.lifecycle.lastSeenAt $_.lastWriteTime } -Descending)
    if ($matches.Count -ne 1) { continue }
    $match = $matches[0]
    $item.status = if ([string]$match.value.lifecycle.status -eq 'closed') { 'resolved' } else { [string]$match.value.lifecycle.status }
    $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @('reflection-candidate:' + [string]$match.value.id, 'reflection-status:' + [string]$match.value.lifecycle.status) -Force
    $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'reflection-promotion.ps1' -Force
    $changed++
  }
  return $changed
}

$queue = Read-Queue
$initialQueueRevision = [int]$queue.revision
if ($ExpectedRevision -ge 0 -and $ExpectedRevision -ne $initialQueueRevision) { throw "SELF_IMPROVEMENT_QUEUE_REVISION_CONFLICT expected=$ExpectedRevision actual=$initialQueueRevision" }
$originalItems = @($queue.items)
$mergedItems = @(Merge-FamilyItems $originalItems)
$mergeCount = [Math]::Max(0, $originalItems.Count - $mergedItems.Count)
$mergedSourceItems = @($originalItems | Group-Object { Get-ItemFamilyKey $_ } | Where-Object { $_.Count -gt 1 } | ForEach-Object { @($_.Group) })
$items = New-Object System.Collections.ArrayList
foreach ($item in $mergedItems) { [void]$items.Add($item) }
$added = 0
$archived = 0
$archivePath = ''
$reflectionArchived = 0
$sideEffectFree = ($Action -eq 'Status')
$resolved = 0
$proposalSynced = 0
$verificationRecorded = 0
$autoResolved = 0
$proposalProjectionCount = 0
$proposalProjectionErrors = New-Object System.Collections.ArrayList
$issuedAdoptionReceipt = $null
$controlledMemoryPromotion = $null
$controlledMemoryPromotionCommitError = ''
$queueMutationRequired = ($Action -notin @('Status','IssueAdoptionReceipt'))

if ($Action -eq 'IssueAdoptionReceipt') {
  if (-not $ConfirmAdoption) { throw 'ADOPTION_CONFIRMATION_REQUIRED: issue a receipt only after an explicit current user adoption confirmation.' }
  if ([string]::IsNullOrWhiteSpace($CandidateId)) { throw 'CANDIDATE_ID_REQUIRED: IssueAdoptionReceipt requires -CandidateId.' }
  if (-not (Test-CompactId $TaskId) -or -not (Test-CompactId $VerificationId) -or -not (Test-CompactId $VerificationTaskId) -or -not (Test-CompactId $VerificationWorkspaceKey)) {
    throw 'ADOPTION_RECEIPT_IDENTITY_REQUIRED: candidate, task, verification, and workspace identifiers must be compact exact ids.'
  }
  $matches = @($items | Where-Object { [string]$_.id -eq $CandidateId -or [string](Get-ItemFamilyKey $_) -eq $CandidateId })
  if ($matches.Count -ne 1) { throw "CANDIDATE_NOT_FOUND_OR_AMBIGUOUS id=$CandidateId matches=$($matches.Count)" }
  $item = $matches[0]
  $isSkillEvolution = Test-SkillEvolutionCandidate $item
  $isControlledMemory = Test-ControlledMemoryPromotionCandidate $item
  if ($isSkillEvolution -and (Get-SkillEvolutionQueueStage $item) -ne 'staged') { throw 'ADOPTION_VALIDATION_REQUIRED: only a sealed-validated staged candidate can receive an adoption receipt.' }
  if ($isControlledMemory -and [string]$item.status -ne 'validated') { throw 'CONTROLLED_MEMORY_VALIDATION_REQUIRED: reflection memory promotion requires one current task-bound validation receipt first.' }
  if (-not $isSkillEvolution -and -not $isControlledMemory) { throw 'ADOPTION_TARGET_UNSUPPORTED: only governed skill proposals and controlled reflection memory candidates can receive an adoption receipt.' }
  if ($isSkillEvolution -and -not (Test-SkillEvolutionAdoptionEligible $item)) { throw 'SKILL_EVOLUTION_SEALED_VALIDATION_REQUIRED: governed proposal adoption requires a current v2 sealed replay and holdout validation artifact.' }
  if ($isSkillEvolution -and [string]::IsNullOrWhiteSpace($EffectArtifactPath)) { throw 'SKILL_EVOLUTION_EFFECT_REQUIRED: governed proposal adoption requires a comparable measured effect artifact.' }
  $verification = Read-LearningVerificationReceipt $VerificationReceiptPath $VerificationId $VerificationTaskId $VerificationWorkspaceKey
  if ([string]$VerificationTaskId -ne [string]$TaskId -or [string]$verification.ownerSessionKey -ne [string]$OwnerSessionKey) { throw 'ADOPTION_RECEIPT_SESSION_OR_TASK_MISMATCH: verification must bind the exact current task and owner session.' }
  $effect = $null
  if ($isSkillEvolution) {
    $proposalLink = @($item.proposalLinks | Select-Object -First 1)[0]
    $proposalId = if ($proposalLink) { [string]$proposalLink.proposalId } else { '' }
    $proposalFingerprint = if ($proposalLink) { [string]$proposalLink.evidenceFingerprint } else { '' }
    $effect = Read-LearningEffectArtifact $EffectArtifactPath $proposalId $proposalFingerprint $TaskId $VerificationWorkspaceKey $OwnerSessionKey
  }
  $issuedAdoptionReceipt = Write-LearningAdoptionReceipt $item $verification $effect $TaskId $VerificationWorkspaceKey $OwnerSessionKey $ApprovalInstructionHash
}

if ($Action -eq 'Resolve') {
  if ([string]::IsNullOrWhiteSpace($CandidateId)) { throw 'CANDIDATE_ID_REQUIRED: Resolve requires -CandidateId.' }
  if ($Resolution -eq 'resolved') { throw 'MANUAL_RESOLUTION_DISABLED: record three independent current task-bound verification receipts; resolution is evidence-only.' }
  $matches = @($items | Where-Object { [string]$_.id -eq $CandidateId -or [string](Get-ItemFamilyKey $_) -eq $CandidateId })
  if ($matches.Count -ne 1) { throw "CANDIDATE_NOT_FOUND_OR_AMBIGUOUS id=$CandidateId matches=$($matches.Count)" }
  $item = $matches[0]
  if ([string]$item.status -in @('resolved','rejected','duplicate','superseded')) { throw 'CANDIDATE_TERMINAL_TRANSITION_REJECTED: terminal candidates cannot be reopened or re-resolved.' }
  $adoption = $null
  if ($Resolution -eq 'adopted') {
    $isSkillEvolution = Test-SkillEvolutionCandidate $item
    $isControlledMemory = Test-ControlledMemoryPromotionCandidate $item
    if ($isSkillEvolution -and (Get-SkillEvolutionQueueStage $item) -ne 'staged') { throw 'ADOPTION_VALIDATION_REQUIRED: only a sealed-validated staged governed proposal can be adopted.' }
    if ($isControlledMemory -and [string]$item.status -ne 'validated') { throw 'CONTROLLED_MEMORY_VALIDATION_REQUIRED: reflection memory promotion requires one current task-bound validation receipt first.' }
    if (-not $isSkillEvolution -and -not $isControlledMemory) { throw 'ADOPTION_TARGET_UNSUPPORTED: only governed skill proposals and controlled reflection memory candidates can be adopted.' }
    if ($isSkillEvolution -and -not (Test-SkillEvolutionAdoptionEligible $item)) { throw 'SKILL_EVOLUTION_SEALED_VALIDATION_REQUIRED: governed proposal adoption requires a current v2 sealed replay and holdout validation artifact.' }
    if (-not (Test-CompactId $TaskId) -or $OwnerSessionKey -notmatch '^sid-[A-Za-z0-9._:-]{8,120}$') { throw 'ADOPTION_RECEIPT_IDENTITY_REQUIRED: adoption requires the exact current task and owner session.' }
    $adoption = Read-LearningAdoptionReceipt $AdoptionReceiptPath $AdoptionReceiptSha256 $item $TaskId $VerificationWorkspaceKey $OwnerSessionKey $EffectArtifactPath
    if ($isControlledMemory) { $controlledMemoryPromotion = Invoke-ControlledMemoryPromotion $item $adoption }
  } else {
    if (@($ResolutionEvidence | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw 'RESOLUTION_EVIDENCE_REQUIRED: Resolve requires compact verified evidence.' }
    if (Test-PrivateText (($ResolutionEvidence -join '; '))) { throw 'RESOLUTION_PRIVACY_GATE: evidence contains secret-like material.' }
    if (@($ResolutionEvidence | Where-Object { -not (Test-ResolutionEvidenceRef ([string]$_)) }).Count -gt 0) { throw 'RESOLUTION_EVIDENCE_REFERENCE_REQUIRED: resolution evidence must be an allowlisted immutable reference.' }
    if ($Resolution -eq 'rejected' -and -not (Test-SkillEvolutionCandidate $item) -and [string]$item.status -ne 'validated') { throw 'LIFECYCLE_VALIDATION_REQUIRED: rejection requires validated evidence.' }
  }
  $priorStatus = [string]$item.status
  $item.status = $Resolution
  if ($Resolution -eq 'blocked') {
    $item | Add-Member -NotePropertyName blockedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName blockedFromStatus -NotePropertyValue $priorStatus -Force
    $item | Add-Member -NotePropertyName blockReason -NotePropertyValue (Limit-Text ($ResolutionEvidence -join '; ') 360) -Force
  } else {
    $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue $(if ($Resolution -eq 'adopted') { @('receipt:' + [string]$adoption.sha256) } else { @($ResolutionEvidence | ForEach-Object { Limit-Text ([string]$_) 360 } | Select-Object -Unique | Select-Object -First 8) }) -Force
    $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'self-improvement-queue.ps1:Resolve' -Force
    if ($Resolution -eq 'adopted') {
      if (Test-SkillEvolutionCandidate $item) { $item | Add-Member -NotePropertyName governanceLifecycleStage -NotePropertyValue 'adopted' -Force }
      $item | Add-Member -NotePropertyName approvalReceipt -NotePropertyValue ('receipt:' + [string]$adoption.sha256) -Force
      $item | Add-Member -NotePropertyName adoptionReceipt -NotePropertyValue ([pscustomobject]@{
        relativePath = ('runtime-state/learning-adoption-receipts/' + [IO.Path]::GetFileName([string]$adoption.path))
        sha256 = [string]$adoption.sha256
        taskId = [string]$TaskId
        workspaceKey = [string]$VerificationWorkspaceKey
        ownerSessionKey = [string]$OwnerSessionKey
        rawPromptStored = $false
      }) -Force
      $item | Add-Member -NotePropertyName effect -NotePropertyValue $(if ($adoption.effect) { $adoption.effect } else { New-NotScoredLearningEffect 'controlled_memory_promotion_not_objectively_scored' }) -Force
      if ($controlledMemoryPromotion) {
        $item | Add-Member -NotePropertyName promotionTransaction -NotePropertyValue ([pscustomobject]@{
          relativePath = ('runtime-state/learning-promotion-transactions/' + [IO.Path]::GetFileName([string]$controlledMemoryPromotion.path))
          sha256 = Get-FileSha256 ([string]$controlledMemoryPromotion.path)
          state = [string]$controlledMemoryPromotion.state
          rawPromptStored = $false
        }) -Force
      }
    }
    $resolved = 1
  }
}

if ($Action -eq 'RecordVerification') {
  if (-not (Test-CompactId $CandidateId) -or -not (Test-CompactId $VerificationId) -or -not (Test-CompactId $VerificationTaskId) -or -not (Test-CompactId $VerificationWorkspaceKey)) { throw 'VERIFICATION_IDENTITY_REQUIRED: candidate, verification, task, and workspace identifiers must be compact exact ids.' }
  $matches = @($items | Where-Object { [string]$_.id -eq $CandidateId -or [string](Get-ItemFamilyKey $_) -eq $CandidateId })
  if ($matches.Count -ne 1) { throw "CANDIDATE_NOT_FOUND_OR_AMBIGUOUS id=$CandidateId matches=$($matches.Count)" }
  $item = $matches[0]
  if ([string]$item.status -in @('resolved','rejected','duplicate','superseded')) { throw 'CANDIDATE_TERMINAL_TRANSITION_REJECTED: terminal candidates cannot accept verification receipts.' }
  $receiptResult = Read-LearningVerificationReceipt $VerificationReceiptPath $VerificationId $VerificationTaskId $VerificationWorkspaceKey
  $expectedEvidenceRef = 'receipt:' + [string]$receiptResult.sha256
  if ($VerificationEvidenceRef -ne $expectedEvidenceRef -or -not (Test-VerificationEvidenceRef $VerificationEvidenceRef)) { throw 'VERIFICATION_EVIDENCE_REFERENCE_MISMATCH: use the exact immutable receipt hash reference.' }
  $existingReceipts = @(Get-VerificationReceipts $item)
  if (@($existingReceipts | Where-Object { [string]$_.verificationId -eq $VerificationId -or [string]$_.receiptHash -eq [string]$receiptResult.sha256 }).Count -gt 0) { throw 'VERIFICATION_RECEIPT_DUPLICATE: a verification id or receipt hash may be recorded once only.' }
  $receipt = [pscustomobject]@{
    verificationId = $VerificationId
    outcome = $VerificationOutcome
    evidenceRef = $VerificationEvidenceRef
    receiptHash = [string]$receiptResult.sha256
    taskId = $VerificationTaskId
    workspaceKey = $VerificationWorkspaceKey
    ownerSessionKey = [string]$receiptResult.ownerSessionKey
    recordedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    rawPromptStored = $false
    rawTranscriptStored = $false
  }
  $item | Add-Member -NotePropertyName verificationReceipts -NotePropertyValue @($existingReceipts + @($receipt) | Select-Object -Last 8) -Force
  $verificationRecorded = 1
  if ($VerificationOutcome -eq 'fail') {
    $priorStatus = [string]$item.status
    $item.status = 'blocked'
    $item | Add-Member -NotePropertyName blockedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName blockedFromStatus -NotePropertyValue $priorStatus -Force
    $item | Add-Member -NotePropertyName blockReason -NotePropertyValue 'verification_receipt_failed' -Force
  } elseif ((Test-ControlledMemoryPromotionCandidate $item) -and [string]$item.status -in @('candidate','staged')) {
    $item.status = 'validated'
    $item | Add-Member -NotePropertyName validation -NotePropertyValue ([pscustomobject]@{
      contractVersion = 'task_receipt_v1'
      status = 'validated'
      artifactSha256 = [string]$receiptResult.sha256
      taskId = $VerificationTaskId
      workspaceKey = $VerificationWorkspaceKey
      ownerSessionKey = [string]$receiptResult.ownerSessionKey
      rawPromptStored = $false
      updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }) -Force
    $item | Add-Member -NotePropertyName validationEvidence -NotePropertyValue ('receipt:' + [string]$receiptResult.sha256) -Force
  } elseif (Test-SkillEvolutionResolutionEligible $item) {
    $item.status = 'resolved'
    $item | Add-Member -NotePropertyName governanceLifecycleStage -NotePropertyValue 'resolved' -Force
    $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @((Get-QualifyingPassReceipts $item | ForEach-Object { 'receipt:' + [string]$_.receiptHash }) | Select-Object -First 3) -Force
    $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'self-improvement-queue.ps1:three-independent-learning-receipts' -Force
    $resolved = 1
    $autoResolved = 1
  } elseif ((Test-AutoResolutionEligible $item) -and [string]$item.status -eq 'validated' -and @(Get-QualifyingPassReceipts $item).Count -ge 3) {
    $item.status = 'resolved'
    $item | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    $item | Add-Member -NotePropertyName resolutionEvidence -NotePropertyValue @((Get-QualifyingPassReceipts $item | ForEach-Object { 'receipt:' + [string]$_.receiptHash }) | Select-Object -First 3) -Force
    $item | Add-Member -NotePropertyName resolutionSource -NotePropertyValue 'self-improvement-queue.ps1:auto-evidence-only' -Force
    $resolved = 1
    $autoResolved = 1
  }
}

if ($Action -eq 'Collect' -or ($Action -eq 'Maintain' -and [string]::IsNullOrWhiteSpace($TaskId))) {
  $hygiene = Read-JsonFile (Join-Path $workspace 'last-memory-hygiene.json')
  $lifecycle = Read-JsonFile (Join-Path $workspace 'last-workspace-lifecycle.json')
  $doctor = $null
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    try { $doctor = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json | ConvertFrom-Json } catch {}
  }
  $reflection = $null
  $reflectionSummary = if ([string]::IsNullOrWhiteSpace($Summary)) { 'post-task self-improvement queue scan' } else { $Summary }
  try { $reflection = & (Join-Path $PSScriptRoot 'reflection-promotion.ps1') -Mode Preview -TriggerType manual -Summary $reflectionSummary -Evidence (($Evidence + @('self-improvement-queue.ps1')) -join '; ') -Scope 'super-memory-brain' -WorkspaceRoot $workspace -Json | ConvertFrom-Json } catch {}

  if ($hygiene -and [int]$hygiene.requiresConfirmation -gt 0) {
    if (Add-OrUpdateFamily $items 'hygiene_confirmation' 'Memory hygiene found items requiring confirmation' 'Automatic memory hygiene found unsafe items that cannot be changed automatically.' 'Surface only current high-risk cleanup work for explicit confirmation.' @('last-memory-hygiene.json requiresConfirmation=' + [string]$hygiene.requiresConfirmation) 'high' 'auto-hygiene-runner.ps1') { $added++ }
  }
  if ($hygiene -and $hygiene.after -and [int]$hygiene.after.tooLongCount -gt 0) {
    if (Add-OrUpdateFamily $items 'hygiene_gap' 'Long memory entries remain after hygiene scan' 'Some memory entries remain above the compactness budget.' 'Compress low-risk long memories with archived evidence and leave risky entries for confirmation.' @('last-memory-hygiene.json tooLongAfter=' + [string]$hygiene.after.tooLongCount) 'medium' 'auto-hygiene-runner.ps1') { $added++ }
  }
  if ($lifecycle -and [int]$lifecycle.requiresConfirmation -gt 0) {
    if (Add-OrUpdateFamily $items 'lifecycle_confirmation' 'Workspace lifecycle found items requiring confirmation' 'Workspace cleanup found artifacts that must not be changed automatically.' 'Track one current family and require explicit confirmation before moving or deleting evidence.' @('last-workspace-lifecycle.json requiresConfirmation=' + [string]$lifecycle.requiresConfirmation) 'medium' 'workspace-lifecycle-manager.ps1') { $added++ }
  }
  if ($lifecycle -and [int]$lifecycle.errorCount -gt 0) {
    if (Add-OrUpdateFamily $items 'lifecycle_error' 'Workspace lifecycle maintenance had errors' 'Automatic lifecycle maintenance did not fully complete.' 'Fix the current lifecycle failure so safe maintenance remains automatic.' @('last-workspace-lifecycle.json errorCount=' + [string]$lifecycle.errorCount) 'high' 'workspace-lifecycle-manager.ps1') { $added++ }
  }
  if ($doctor -and $doctor.riskSummary -and [int]$doctor.riskSummary.total -gt 0) {
    $riskCodes = @($doctor.risks | ForEach-Object { [string]$_.code } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (Add-OrUpdateFamily $items 'doctor_risk' 'Doctor still reports risks after maintenance' 'Health risks remain after the maintenance loop.' 'Turn recurring current doctor risks into specific guarded fixes.' @('doctor risk codes=' + ($riskCodes -join ',')) 'high' 'doctor.ps1') { $added++ }
  }
  if ($reflection -and $reflection.candidates) {
    foreach ($candidate in @($reflection.candidates | Where-Object { $_.target -ne 'none' -and $_.lifecycle.status -eq 'candidate' } | Select-Object -First 6)) {
      $kind = if ($candidate.candidateType) { [string]$candidate.candidateType } else { 'reflection_candidate' }
      $priority = if ([double]$candidate.confidence -ge 0.82) { 'high' } elseif ([double]$candidate.confidence -ge 0.72) { 'medium' } else { 'low' }
      if (Add-OrUpdateFamily $items $kind ([string]$candidate.title) ([string]$candidate.summary) 'Promote only through governed learning gates after evidence and scope checks.' @([string]$candidate.sampleId) $priority 'reflection-promotion.ps1' ([string]$candidate.target) ([string]$candidate.scope)) { $added++ }
      $null = Link-ReflectionCandidate $items $kind ([string]$candidate.title) ([string]$candidate.target) ([string]$candidate.scope) ([string]$candidate.id)
    }
  }
  foreach ($row in @(Read-ReflectionCandidates | Where-Object {
    $_.value -and $_.value.lifecycle -and [string]$_.value.target -ne 'none' -and [string]$_.value.lifecycle.status -in @('candidate','staged')
  } | Sort-Object { Get-DateValue $_.value.lifecycle.lastSeenAt $_.lastWriteTime } -Descending | Select-Object -First 12)) {
    $candidate = $row.value
    $kind = if ($candidate.candidateType) { [string]$candidate.candidateType } else { 'reflection_candidate' }
    $priority = if ([double]$candidate.confidence -ge 0.82) { 'high' } elseif ([double]$candidate.confidence -ge 0.72) { 'medium' } else { 'low' }
    if (Add-OrUpdateFamily $items $kind ([string]$candidate.title) ([string]$candidate.summary) 'Keep the reflected candidate staged until task-bound validation and a controlled promotion transaction exist.' @([string]$candidate.sampleId) $priority 'reflection-promotion.ps1' ([string]$candidate.target) ([string]$candidate.scope)) { $added++ }
    $null = Link-ReflectionCandidate $items $kind ([string]$candidate.title) ([string]$candidate.target) ([string]$candidate.scope) ([string]$candidate.id)
  }
}

if ($Action -eq 'Maintain') {
  $now = Get-Date
  $reflectionRows = Read-ReflectionCandidates
  $resolved += Sync-ReflectionLifecycle $items $reflectionRows
  $proposalSync = Sync-SkillEvolutionLifecycle $items (Read-SkillEvolutionProposals)
  $added += [int]$proposalSync.added
  $proposalSynced = [int]$proposalSync.changed + [int]$proposalSync.added
  $sorted = @($items | Sort-Object @{Expression={Get-StatusRank ([string]$_.status)}}, @{Expression={Get-PriorityRank ([string]$_.priority)}}, @{Expression={[int]$_.seenCount};Descending=$true}, @{Expression={Get-DateValue $_.lastSeenAt};Descending=$true})
  $keep = New-Object System.Collections.ArrayList
  $archiveItems = New-Object System.Collections.ArrayList
  foreach ($item in $sorted) {
    $isClosed = ([string]$item.status -in @('resolved','rejected','duplicate','superseded','closed') -or ([string]$item.status -eq 'adopted' -and -not (Test-SkillEvolutionCandidate $item)))
    $ageDays = ($now - (Get-DateValue $item.lastSeenAt (Get-DateValue $item.createdAt $now))).TotalDays
    $staleSingle = ($ageDays -ge $ArchiveAfterDays -and [int]$item.seenCount -le 1 -and [string]$item.priority -ne 'high')
    $overBudget = (@($keep | Where-Object { [string]$_.status -in @('candidate','staged','validated','blocked') -or ((Test-SkillEvolutionCandidate $_) -and [string]$_.status -eq 'adopted') }).Count -ge $MaxActive -and ([string]$item.status -in @('candidate','staged','validated','blocked') -or ((Test-SkillEvolutionCandidate $item) -and [string]$item.status -eq 'adopted')))
    if ($isClosed -or $staleSingle -or $overBudget) { [void]$archiveItems.Add($item) } else { [void]$keep.Add($item) }
  }

  $reflectionKeepByFamily = @{}
  $reflectionArchive = New-Object System.Collections.ArrayList
  foreach ($row in @($reflectionRows | Sort-Object { Get-DateValue $_.value.lifecycle.lastSeenAt $_.lastWriteTime } -Descending)) {
    $family = if ($row.value.familyKey) { [string]$row.value.familyKey } else { ([string]$row.value.target + '|' + [string]$row.value.title + '|' + [string]$row.value.scope) }
    $closed = ($row.value.lifecycle -and [string]$row.value.lifecycle.status -in @('adopted','rejected','duplicate','superseded','closed'))
    if ($closed -or $reflectionKeepByFamily.ContainsKey($family)) {
      [void]$reflectionArchive.Add([pscustomobject]@{ path=$row.path; value=$row.value })
    } else {
      $reflectionKeepByFamily[$family] = $true
    }
  }
  $queueArchiveItems = @(@($mergedSourceItems) + @($archiveItems))
  $archivePath = Write-Archive $queueArchiveItems @($reflectionArchive) 'bounded lifecycle maintenance; merged source instances, duplicate, closed, stale singleton, or active-budget overflow'
  if ($archivePath) {
    foreach ($row in $reflectionArchive) { Remove-Item -LiteralPath $row.path -Force }
    $reflectionArchived = @($reflectionArchive).Count
  }
  $archived = @($queueArchiveItems).Count
  $items = $keep
}

$sortedItems = @($items | Sort-Object @{Expression={Get-StatusRank ([string]$_.status)}}, @{Expression={Get-PriorityRank ([string]$_.priority)}}, @{Expression={[int]$_.seenCount};Descending=$true}, @{Expression={Get-DateValue $_.lastSeenAt};Descending=$true})
$queueSummary = Get-QueueSummary $sortedItems $added $archived $mergeCount

if ($queueMutationRequired) {
  if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
  $queue | Add-Member -NotePropertyName ok -NotePropertyValue $true -Force
  $queue | Add-Member -NotePropertyName schema -NotePropertyValue 'super-brain.self-improvement-queue.v3' -Force
  $queue | Add-Member -NotePropertyName version -NotePropertyValue ([string]$manifest.version) -Force
  $queue | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
  $queue | Add-Member -NotePropertyName items -NotePropertyValue $sortedItems -Force
  $queue | Add-Member -NotePropertyName summary -NotePropertyValue $queueSummary -Force
  Write-QueueWithRevision $queue $initialQueueRevision
  if ($controlledMemoryPromotion) {
    try {
      [void](Complete-ControlledMemoryPromotion $controlledMemoryPromotion)
      $promotionItem = @($sortedItems | Where-Object { [string]$_.id -eq $CandidateId } | Select-Object -First 1)[0]
      if ($promotionItem) { Mark-ReflectionCandidatePromoted $promotionItem $controlledMemoryPromotion }
    } catch {
      $controlledMemoryPromotionCommitError = Limit-Text ([string]$_.Exception.Message) 180
    }
  }
  foreach ($projectionItem in @($sortedItems | Where-Object {
    (Test-SkillEvolutionCandidate $_) -and [string]$_.status -in @('adopted','resolved','rejected','blocked')
  })) {
    $projection = Write-SkillEvolutionProposalProjection $projectionItem
    $proposalProjectionCount += [int]$projection.projected
    foreach ($projectionError in @($projection.errors)) { [void]$proposalProjectionErrors.Add([string]$projectionError) }
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.self-improvement-queue-result.v3'
  version = [string]$manifest.version
  action = $Action
  sideEffectFree = $sideEffectFree
  queuePath = $queuePath
  total = $queueSummary.total
  active = $queueSummary.active
  candidate = $queueSummary.candidate
  staged = $queueSummary.staged
  validated = $queueSummary.validated
  blocked = $queueSummary.blocked
  added = $added
  merged = $mergeCount
  archived = $archived
  resolved = $resolved
  autoResolved = $autoResolved
  verificationRecorded = $verificationRecorded
  adoptionReceipt = if ($issuedAdoptionReceipt) { [pscustomobject]@{ path=[string]$issuedAdoptionReceipt.path; sha256=[string]$issuedAdoptionReceipt.sha256; rawPromptStored=$false } } else { $null }
  controlledMemoryPromotion = if ($controlledMemoryPromotion) { [pscustomobject]@{ path=[string]$controlledMemoryPromotion.path; state=[string]$controlledMemoryPromotion.state; commitPending=(-not [string]::IsNullOrWhiteSpace($controlledMemoryPromotionCommitError)); rawPromptStored=$false } } else { $null }
  proposalSynced = $proposalSynced
  proposalProjectionCount = $proposalProjectionCount
  proposalProjectionErrors = @($proposalProjectionErrors)
  reflectionArchived = $reflectionArchived
  high = $queueSummary.high
  medium = $queueSummary.medium
  low = $queueSummary.low
  effectScored = $queueSummary.effectScored
  effectNotScored = $queueSummary.effectNotScored
  maxActive = $MaxActive
  overBudget = $queueSummary.overBudget
  archivePath = $archivePath
  revision = if ($queueMutationRequired) { $initialQueueRevision + 1 } else { $initialQueueRevision }
  recent = @($sortedItems | Select-Object -First 8)
  guard = if ($Action -eq 'Status') { 'Status is read-only: no doctor, reflection generation, queue write, last-result write, or archive mutation.' } else { 'Candidates are family-deduplicated and bounded; maintenance archives instead of deleting evidence.' }
}

if ($Action -ne 'Status') { Write-JsonUtf8NoBom $lastPath $result 12 }
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SELF_IMPROVEMENT_QUEUE action=$Action ok=True total=$($result.total) active=$($result.active) added=$added merged=$mergeCount archived=$archived" }
exit 0
