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

function Get-CurrentSelfModelTreeBinding {
  $tree = Get-SuperBrainSourceTreeBinding $Root
  return [pscustomobject]@{
    schema = 'super-brain.self-model-tree-binding.v1'
    packageVersion = [string]$manifest.version
    gitTreeHash = [string]$tree.gitTreeHash
    gitHeadTreeHash = [string]$tree.gitHeadTreeHash
    treeAlgorithm = [string]$tree.treeAlgorithm
  }
}

function Test-CurrentSelfModelTreeBinding($Binding) {
  if (-not $Binding -or [string](Property $Binding 'schema' '') -ne 'super-brain.self-model-tree-binding.v1') { return $false }
  $current = Get-CurrentSelfModelTreeBinding
  foreach ($name in @('packageVersion','gitTreeHash','gitHeadTreeHash','treeAlgorithm')) {
    if ([string](Property $Binding $name '') -ne [string](Property $current $name '')) { return $false }
  }
  return $true
}

function Resolve-SelfModelWorkspacePath([string]$RelativePath, [string]$ExpectedRoot) {
  if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { return '' }
  try {
    $full = [IO.Path]::GetFullPath((Join-Path $workspace ($RelativePath -replace '/','\')))
    if (-not (Test-SuperBrainChildPath $ExpectedRoot $full)) { return '' }
    return $full
  } catch {
    return ''
  }
}

function Get-LearningQueueTrust($Queue) {
  if (-not $Queue) { return [pscustomobject]@{ status='not_present'; reasons=@(); verified=$true } }
  $reasons = New-Object Collections.ArrayList
  if ([string](Property $Queue 'schema' '') -ne 'super-brain.self-improvement-queue.v3') { [void]$reasons.Add('queue_schema_invalid') }
  if ([string](Property $Queue 'version' '') -ne [string]$manifest.version) { [void]$reasons.Add('queue_version_missing_or_stale') }
  if ((Property $Queue 'rawPromptStored' $false) -eq $true -or (Property $Queue 'rawTranscriptStored' $false) -eq $true) { [void]$reasons.Add('queue_privacy_invariant_failed') }
  $adoptionRoot = Join-Path $workspace 'runtime-state\learning-adoption-receipts'
  $effectRoot = Join-Path $workspace 'runtime-state\learning-effect-artifacts'
  $verificationRoot = Join-Path $workspace 'runtime-state\learning-verification-receipts'
  $promotionRoot = Join-Path $workspace 'runtime-state\learning-promotion-transactions'
  foreach ($item in @((Property $Queue 'items' @()))) {
    if (-not $item) { [void]$reasons.Add('queue_item_missing'); continue }
    if ((Property $item 'rawPromptStored' $false) -eq $true -or (Property $item 'rawTranscriptStored' $false) -eq $true) { [void]$reasons.Add('queue_item_privacy_invariant_failed'); continue }
    $status = [string](Property $item 'status' '')
    if ($status -notin @('adopted','resolved')) { continue }
    $isGoverned = ([string](Property $item 'kind' '') -eq 'skill_evolution_proposal' -or [string](Property $item 'source' '') -eq 'skill-evolution.ps1')
    $isControlledMemory = ([string](Property $item 'source' '') -eq 'reflection-promotion.ps1' -and [string](Property $item 'target' '') -in @('experience','memory'))
    if (-not $isGoverned -and -not $isControlledMemory) { [void]$reasons.Add('legacy_unbound_terminal_candidate'); continue }
    $adoption = Property $item 'adoptionReceipt' $null
    $adoptionPath = if ($adoption) { Resolve-SelfModelWorkspacePath ([string](Property $adoption 'relativePath' '')) $adoptionRoot } else { '' }
    $adoptionHash = if ($adoption) { [string](Property $adoption 'sha256' '') } else { '' }
    if ([string]::IsNullOrWhiteSpace($adoptionPath) -or $adoptionHash -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $adoptionPath) -or (Get-SuperBrainFileSha256 $adoptionPath) -ne $adoptionHash) { [void]$reasons.Add('adoption_receipt_missing_or_mismatched'); continue }
    $receipt = Read-Json $adoptionPath
    if (-not $receipt -or [string](Property $receipt 'schema' '') -ne 'super-brain.learning-adoption-receipt.v1' -or [string](Property $receipt 'candidateId' '') -ne [string](Property $item 'id' '') -or [string](Property $receipt 'packageVersion' '') -ne [string]$manifest.version -or (Property (Property $receipt 'privacy' $null) 'rawPromptStored' $true) -ne $false) { [void]$reasons.Add('adoption_receipt_invalid'); continue }
    if ($isControlledMemory) {
      $verificationReference = Property $receipt 'verificationReceipt' $null
      $verificationPath = if ($verificationReference) { Resolve-SelfModelWorkspacePath ([string](Property $verificationReference 'relativePath' '')) $verificationRoot } else { '' }
      $verificationHash = if ($verificationReference) { [string](Property $verificationReference 'sha256' '') } else { '' }
      $promotionReference = Property $item 'promotionTransaction' $null
      $promotionPath = if ($promotionReference) { Resolve-SelfModelWorkspacePath ([string](Property $promotionReference 'relativePath' '')) $promotionRoot } else { '' }
      $promotionHash = if ($promotionReference) { [string](Property $promotionReference 'sha256' '') } else { '' }
      if ([string]::IsNullOrWhiteSpace($verificationPath) -or $verificationHash -notmatch '^[a-f0-9]{64}$' -or (Get-SuperBrainFileSha256 $verificationPath) -ne $verificationHash -or [string](Property $receipt 'effectArtifactHash' '') -ne '') { [void]$reasons.Add('controlled_memory_verification_missing_or_mismatched'); continue }
      $bindingCheck = Test-SuperBrainEvidenceBinding -Binding (Property $receipt 'evidenceBinding' $null) -TaskId ([string](Property $receipt 'taskId' '')) -WorkspaceKey ([string](Property $receipt 'workspaceKey' '')) -OwnerSessionKey ([string](Property $receipt 'ownerSessionKey' '')) -ArtifactPath $verificationPath -RequireArtifactHash -Root $Root
      $transaction = if (-not [string]::IsNullOrWhiteSpace($promotionPath) -and $promotionHash -match '^[a-f0-9]{64}$' -and (Get-SuperBrainFileSha256 $promotionPath) -eq $promotionHash) { Read-Json $promotionPath } else { $null }
      $transactionOk = ($transaction -and [string](Property $transaction 'schema' '') -eq 'super-brain.controlled-memory-promotion-transaction.v1' -and [string](Property $transaction 'candidateId' '') -eq [string](Property $item 'id' '') -and [string](Property $transaction 'adoptionReceiptSha256' '') -eq $adoptionHash -and [string](Property $transaction 'state' '') -eq 'committed' -and (Property (Property $transaction 'privacy' $null) 'rawPromptStored' $true) -eq $false)
      if (-not $bindingCheck.ok -or -not $transactionOk) { [void]$reasons.Add('controlled_memory_transaction_invalid') }
      continue
    }
    $effectReference = Property $receipt 'effectArtifact' $null
    $effectPath = if ($effectReference) { Resolve-SelfModelWorkspacePath ([string](Property $effectReference 'relativePath' '')) $effectRoot } else { '' }
    $effectHash = if ($effectReference) { [string](Property $effectReference 'sha256' '') } else { '' }
    if ([string]::IsNullOrWhiteSpace($effectPath) -or $effectHash -notmatch '^[a-f0-9]{64}$' -or (Get-SuperBrainFileSha256 $effectPath) -ne $effectHash -or $effectHash -ne [string](Property $receipt 'effectArtifactHash' '')) { [void]$reasons.Add('effect_artifact_missing_or_mismatched'); continue }
    $effectArtifact = Read-Json $effectPath
    $scope = if ($effectArtifact) { Property $effectArtifact 'scopeBinding' $null } else { $null }
    $scopeOk = ($effectArtifact -and [string](Property $effectArtifact 'schema' '') -eq 'super-brain.learning-effect-artifact.v2' -and $scope -and [string](Property $scope 'schema' '') -eq 'super-brain.learning-effect-scope-binding.v1' -and [string](Property $scope 'taskId' '') -eq [string](Property $receipt 'taskId' '') -and (Test-SuperBrainWorkspaceKey ([string](Property $scope 'workspaceKey' '')) ([string](Property $receipt 'workspaceKey' ''))) -and [string](Property $scope 'ownerSessionKey' '') -eq [string](Property $receipt 'ownerSessionKey' ''))
    if (-not $scopeOk) { [void]$reasons.Add('effect_scope_binding_invalid'); continue }
    $bindingCheck = Test-SuperBrainEvidenceBinding -Binding (Property $receipt 'evidenceBinding' $null) -TaskId ([string](Property $receipt 'taskId' '')) -WorkspaceKey ([string](Property $receipt 'workspaceKey' '')) -OwnerSessionKey ([string](Property $receipt 'ownerSessionKey' '')) -ArtifactPath $effectPath -RequireArtifactHash -Root $Root
    $effect = Property $item 'effect' $null
    if (-not $bindingCheck.ok -or -not $effect -or [string](Property $effect 'status' '') -ne 'scored' -or (Property $effect 'improvementClaimAllowed' $false) -ne $true -or [double](Property $effect 'delta' 0) -le 0) { [void]$reasons.Add('adoption_evidence_chain_invalid') }
  }
  $unique = @($reasons | Select-Object -Unique)
  return [pscustomobject]@{ status=if($unique.Count -eq 0){'verified'}else{'unverified'}; reasons=$unique; verified=($unique.Count -eq 0) }
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
  $treeBindingValid = $snapshot -and (Test-CurrentSelfModelTreeBinding (Property $snapshot 'sourceTreeBinding' $null))
  $valid = (
    $schemaValid -and $versionValid -and $privacyValid -and $treeBindingValid -and
    $fresh.fresh
  )
  $snapshotStatus = if(-not $snapshot){'missing'}elseif(-not $fresh.fresh){'stale'}elseif(-not $schemaValid -or -not $versionValid -or -not $privacyValid -or -not $treeBindingValid){'invalid'}else{$declaredEvidenceStatus}
  $result = [pscustomobject]@{
    ok=$true; schema='super-brain.self-model-status.v1'; action='Status'
    snapshotExists=($null -ne $snapshot); fresh=$valid
    snapshotStatus=$snapshotStatus; evidenceStatus=if($valid){$declaredEvidenceStatus}elseif(-not $snapshot){'missing'}else{'unverified'}
    verificationStatus=if($valid){$declaredEvidenceStatus}elseif(-not $snapshot){'unknown'}else{'unverified'}
    checkedAt=(Get-Date).ToString('o'); ageHours=$fresh.ageHours
    evidenceCount=if($snapshot){@((Property $snapshot 'evidence' @())).Count}else{0}
    treeBindingCurrent=$treeBindingValid; rawPromptStored=$false; path=$path
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

$context = Get-SuperBrainCurrentTaskContext $workspace
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

$adaptationDirectory = if ($policy -and $policy.userAdaptation -and $policy.userAdaptation.storage -and -not [string]::IsNullOrWhiteSpace([string]$policy.userAdaptation.storage.directory)) { [string]$policy.userAdaptation.storage.directory } else { 'user-adaptation' }
$adaptationStore = Read-Json (Join-Path $workspace (Join-Path $adaptationDirectory 'store.v2.json'))
$adaptationV2 = ($adaptationStore -and [string](Property $adaptationStore 'schema' '') -eq 'super-brain.user-adaptation-store.v2' -and (Property $adaptationStore 'rawPromptStored' $false) -ne $true)
$profile = if ($adaptationV2) { [pscustomobject]@{ entries=@((Property $adaptationStore 'profile' @())); rawPromptStored=$false } } else { Read-Json (Join-Path $workspace (Join-Path $adaptationDirectory 'profile.json')) }
$adaptationValidatedCount = if ($adaptationV2) { @((Property $adaptationStore 'candidates' @()) | Where-Object { $_.validation -and [string](Property $_.validation 'status' '') -eq 'validated' }).Count } else { 0 }
$adaptationReceiptCount = if ($adaptationV2) { @((Property $adaptationStore 'receipts' @())).Count } else { 0 }
$learningQueue = Read-Json (Join-Path $workspace 'self-improvement-queue.json')
$learningQueueItems = if ($learningQueue -and (Property $learningQueue 'items' $null)) { @((Property $learningQueue 'items' @())) } else { @() }
$learningEffectScored = @($learningQueueItems | Where-Object { $_.effect -and [string](Property $_.effect 'status' '') -eq 'scored' }).Count
$learningEffectNotScored = @($learningQueueItems | Where-Object { -not $_.effect -or [string](Property $_.effect 'status' '') -eq 'not_scored' }).Count
$learningAdopted = @($learningQueueItems | Where-Object { [string](Property $_ 'status' '') -eq 'adopted' }).Count
$learningBlocked = @($learningQueueItems | Where-Object { [string](Property $_ 'status' '') -eq 'blocked' }).Count
$learningQueueTrust = Get-LearningQueueTrust $learningQueue
$learningQueueTrusted = ($learningQueueTrust.status -in @('verified','not_present'))
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
if ($adaptationV2) { [void]$evidenceList.Add("$adaptationDirectory/store.v2.json activePreferences=$($preferences.Count) validatedCandidates=$adaptationValidatedCount receipts=$adaptationReceiptCount") }
elseif ($preferences.Count -gt 0) { [void]$evidenceList.Add("$adaptationDirectory/profile.json activePreferences=$($preferences.Count)") }
if ($reflectionSafe) { [void]$evidenceList.Add("last-reflection-promotion.json candidates=$reflectionCount") }
if ($learningQueue) { [void]$evidenceList.Add("self-improvement-queue.json trust=$($learningQueueTrust.status) active=$(@($learningQueueItems | Where-Object { [string](Property $_ 'status' '') -in @('candidate','staged','validated','blocked','adopted') }).Count) effectScored=$learningEffectScored") }
$evidence = @($evidenceList | Select-Object -Unique -First $maxEvidence)

$capabilityList = New-Object Collections.ArrayList
if ($verifyOk) {
  [void]$capabilityList.Add('package and native runtime verification')
  if ($contextOk) { [void]$capabilityList.Add('governed task continuity state') }
  if ($taskOk) { [void]$capabilityList.Add('verified task outcome tracking') }
  if ($adaptationV2) { [void]$capabilityList.Add('governed user adaptation') }
  if ($reflectionSafe) { [void]$capabilityList.Add('evidence-gated reflection') }
  if ($learningQueue -and $learningQueueTrust.verified) { [void]$capabilityList.Add('evidence-gated learning lifecycle') }
}

$state = @($(if($verifyOk){'packageVerification=current'}else{'packageVerification=missing_or_stale'}))
if ($contextOk) { $state += "activeTask=$([string](Property $context 'taskId'))" }
if ($taskOk) { $state += "lastVerifiedTask=$([string](Property $taskVerification 'taskId'))" }
if ($reflectionSafe) { $state += "reflectionCandidates=$reflectionCount" }
if ($adaptationV2) { $state += "adaptationValidatedCandidates=$adaptationValidatedCount" }
if ($learningQueue) { $state += "learningTrust=$($learningQueueTrust.status);learningAdopted=$learningAdopted;learningBlocked=$learningBlocked" }
$nextAction = if (-not $verifyOk) {
  'Refresh package verification before relying on capability claims.'
} elseif ($contextOk -and [string](Property $context 'nextAction')) {
  Limit-Text ([string](Property $context 'nextAction')) 220
} else {
  'Refresh after the next verified task outcome or safe maintenance.'
}

$snapshot = [pscustomobject]@{
  schema='super-brain.self-model.v1'; packageVersion=[string]$manifest.version
  updatedAt=(Get-Date).ToString('o'); evidenceStatus=if($verifyOk -and $learningQueueTrusted){'verified'}else{'degraded'}
  sourceTreeBinding=Get-CurrentSelfModelTreeBinding
  identity='Super Memory Brain / G1 local control plane'
  role='Route, recall, verify, and learn from governed local evidence.'
  verifiedCapabilities=@($capabilityList | Select-Object -First 5)
  currentState=Limit-Text ($state -join '; ') 420
  userModel=if($preferences.Count -gt 0){Limit-Text ('Governed collaboration preferences: ' + ($preferences -join ', ') + '. Explicit current instructions always win.') 360}else{'No active governed preference snapshot is available.'}
  learning=[pscustomobject]@{
    queue=[pscustomobject]@{items=$learningQueueItems.Count;adopted=$learningAdopted;blocked=$learningBlocked;effectScored=$learningEffectScored;effectNotScored=$learningEffectNotScored;trustStatus=$learningQueueTrust.status;trustReasons=@($learningQueueTrust.reasons | Select-Object -First 4)}
    adaptation=[pscustomobject]@{v2Available=$adaptationV2;activePreferences=$preferences.Count;validatedCandidates=$adaptationValidatedCount;receiptCount=$adaptationReceiptCount;effectStatus='not_scored'}
    claimBoundary='Only comparable measured-effect artifacts may claim improvement; unpaired adaptation remains not_scored.'
  }
  knownLimits=@(
    'Self-model claims are limited to the listed local evidence.',
    'Missing or stale evidence makes current state unknown.',
    'Memory is evidence, not authority; unknown personal facts remain unknown.',
    'Adaptation never overrides explicit user instructions, safety, or permissions.'
    'Learning candidates remain evidence-gated; a local lifecycle event is not an objective improvement claim.'
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
  preferenceCount=$preferences.Count; learningTrustStatus=$learningQueueTrust.status; rawPromptStored=$false; path=$path
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "SELF_MODEL action=Refresh status=$($result.evidenceStatus) evidence=$($result.evidenceCount) path=$path" }
exit 0
