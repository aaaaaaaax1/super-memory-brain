param(
  [ValidateSet('Capture','Propose','Validate','List')]
  [string]$Mode = 'List',
  [string]$Title = '',
  [string]$Trigger = '',
  [string]$Expected = '',
  [string]$Actual = '',
  [string]$Evidence = '',
  [string]$Affected = '',
  [string]$Proposal = '',
  [string]$ProposalId = '',
  [string]$Source = '',
  [string]$EvidenceFingerprint = '',
  [string]$ValidationArtifactPath = '',
  [string]$WorkspaceRoot = '',
  [switch]$Pass,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$evolutionRoot = Join-Path $workspace 'skill-evolution'
$failureRoot = Join-Path $evolutionRoot 'failures'
$proposalRoot = Join-Path $evolutionRoot 'proposals'
$indexPath = Join-Path $evolutionRoot 'index.json'
if ($Mode -in @('Capture','Propose','Validate')) { New-Item -ItemType Directory -Force -Path $failureRoot,$proposalRoot | Out-Null }

function New-EvolutionId([string]$Prefix) {
  return ('{0}-{1}' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Get-CompactHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..11] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return '' }
}

function Assert-CompactId([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,119}$') { throw "${Name}_INVALID: use a compact non-secret identifier." }
  return $Value
}

function Read-JsonFile([string]$Path, [string]$ErrorCode) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "${ErrorCode}: file is missing." }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "${ErrorCode}: file is invalid." }
}

function New-NotScoredEffect([string]$ReasonCode = 'comparable_effect_artifact_missing') {
  return [pscustomobject]@{
    status = 'not_scored'
    reasonCode = $ReasonCode
    improvementClaimAllowed = $false
    rawPromptStored = $false
    rawTranscriptStored = $false
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
}

function Get-CanonicalSkillEvolutionStage($Item) {
  $allowed = @('candidate','sealed-validated','staged','adopted','resolved','blocked','rejected','historical')
  if ($Item -and $Item.PSObject.Properties['lifecycle'] -and $Item.lifecycle -and $Item.lifecycle.PSObject.Properties['canonicalStage']) {
    $declared = [string]$Item.lifecycle.canonicalStage
    if ($declared -in $allowed) { return $declared }
  }
  $validation = if ($Item -and $Item.PSObject.Properties['validation']) { $Item.validation } else { $null }
  if ($validation -and [string]$validation.contractVersion -eq 'legacy_v1') { return 'historical' }
  if ($validation -and [string]$validation.contractVersion -eq 'v2' -and [string]$validation.status -in @('validated','sealed-validated')) { return 'sealed-validated' }
  switch ([string]$Item.status) {
    'candidate' { return 'candidate' }
    'staged' { return 'candidate' }
    'validated' { return 'sealed-validated' }
    'adopted' { return 'adopted' }
    'resolved' { return 'resolved' }
    'blocked' { return 'blocked' }
    'rejected' { return 'rejected' }
    default { return 'candidate' }
  }
}

function Ensure-ProposalLifecycleMetadata($Item) {
  if (-not $Item.PSObject.Properties['lifecycle'] -or -not $Item.lifecycle) {
    $Item | Add-Member -NotePropertyName lifecycle -NotePropertyValue ([pscustomobject]@{
      authority = 'self-improvement-queue.ps1'
      status = [string]$Item.status
      queueCandidateId = ''
      updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      projected = $false
    }) -Force
  } else {
    $Item.lifecycle | Add-Member -NotePropertyName authority -NotePropertyValue 'self-improvement-queue.ps1' -Force
    $Item.lifecycle | Add-Member -NotePropertyName status -NotePropertyValue ([string]$Item.status) -Force
    $Item.lifecycle | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
    if (-not $Item.lifecycle.PSObject.Properties['queueCandidateId']) { $Item.lifecycle | Add-Member -NotePropertyName queueCandidateId -NotePropertyValue '' -Force }
    if (-not $Item.lifecycle.PSObject.Properties['projected']) { $Item.lifecycle | Add-Member -NotePropertyName projected -NotePropertyValue $false -Force }
  }
  $Item.lifecycle | Add-Member -NotePropertyName canonicalStage -NotePropertyValue (Get-CanonicalSkillEvolutionStage $Item) -Force
  if (-not $Item.PSObject.Properties['effect'] -or -not $Item.effect) {
    $Item | Add-Member -NotePropertyName effect -NotePropertyValue (New-NotScoredEffect) -Force
  }
  return $Item
}

function Read-Index {
  if (Test-Path $indexPath) {
    try { return Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ ok=$true; updatedAt=''; failures=@(); proposals=@() }
}

function Write-Index([object]$Index) {
  $Index.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-JsonUtf8NoBom $indexPath $Index 10
}

function Sanitize-Text([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $clean = [string]$Text
  $secretPattern = "(?i)(api[_-]?key|password|token|cookie|secret)\s*[:=]\s*\S+"
  $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, $secretPattern, '$1=<redacted>')
  if ($clean.Length -gt 1200) { $clean = $clean.Substring(0, 1200) + '...' }
  return $clean
}

function Get-FailureFingerprint(
  [string]$Title,
  [string]$Trigger,
  [string]$Expected,
  [string]$Actual,
  [string]$Evidence,
  [string]$Affected,
  [string]$Source,
  [string]$EvidenceFingerprint
) {
  return Get-CompactHash ((@($Title,$Trigger,$Expected,$Actual,$Evidence,$Affected,$Source,$EvidenceFingerprint) -join '|').ToLowerInvariant())
}

function Find-CapturedFailure([string]$Fingerprint) {
  foreach ($entry in @($index.failures)) {
    $path = if ($entry.PSObject.Properties['path']) { [string]$entry.path } else { '' }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
      $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      $existingFingerprint = if ($existing.PSObject.Properties['fingerprint']) {
        [string]$existing.fingerprint
      } else {
        Get-FailureFingerprint ([string]$existing.title) ([string]$existing.trigger) ([string]$existing.expected) ([string]$existing.actual) ([string]$existing.evidence) ([string]$existing.affected) ([string]$existing.source) ([string]$existing.evidenceFingerprint)
      }
      if ($existingFingerprint -eq $Fingerprint -and [string]$existing.status -eq 'captured') {
        return [pscustomobject]@{ id=[string]$existing.id; path=$path; status=[string]$existing.status; fingerprint=$Fingerprint }
      }
    } catch {}
  }
  return $null
}

$index = Read-Index

if ($Mode -eq 'Capture') {
  $cleanTitle = Sanitize-Text $Title
  $cleanTrigger = Sanitize-Text $Trigger
  $cleanExpected = Sanitize-Text $Expected
  $cleanActual = Sanitize-Text $Actual
  $cleanEvidence = Sanitize-Text $Evidence
  $cleanAffected = Sanitize-Text $Affected
  $cleanSource = Sanitize-Text $Source
  $cleanEvidenceFingerprint = Sanitize-Text $EvidenceFingerprint
  $fingerprint = Get-FailureFingerprint $cleanTitle $cleanTrigger $cleanExpected $cleanActual $cleanEvidence $cleanAffected $cleanSource $cleanEvidenceFingerprint
  $duplicate = Find-CapturedFailure $fingerprint
  if ($duplicate) {
    $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$duplicate.id; path=$duplicate.path; status=$duplicate.status; fingerprint=$fingerprint; reused=$true; next='A matching compact failure sample is already captured; stage or validate its existing proposal instead of duplicating it.' }
    if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "SKILL_EVOLUTION_CAPTURE ok=$($result.ok) status=$($result.status) id=$($result.id) reused=true" }
    exit 0
  }
  $id = New-EvolutionId 'FAIL'
  $item = [pscustomobject]@{
    id = $id
    status = 'captured'
    title = $cleanTitle
    trigger = $cleanTrigger
    expected = $cleanExpected
    actual = $cleanActual
    evidence = $cleanEvidence
    affected = $cleanAffected
    source = $cleanSource
    evidenceFingerprint = $cleanEvidenceFingerprint
    fingerprint = $fingerprint
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    privacy = 'redacted; compact evidence only; no raw transcript harvesting'
  }
  $path = Join-Path $failureRoot ($id + '.json')
  Write-JsonUtf8NoBom $path $item 8
  $index.failures = @($index.failures) + @([pscustomobject]@{ id=$id; title=$item.title; path=$path; status='captured'; fingerprint=$fingerprint })
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$id; path=$path; status='captured'; fingerprint=$fingerprint; reused=$false; next='Create a bounded proposal with -Mode Propose.' }
}
elseif ($Mode -eq 'Propose') {
  if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Proposal)) { throw 'PROPOSAL_CONTENT_REQUIRED: title and proposal are required.' }
  $id = if ([string]::IsNullOrWhiteSpace($ProposalId)) { New-EvolutionId 'PROP' } else { Assert-CompactId $ProposalId 'PROPOSAL_ID' }
  $path = Join-Path $proposalRoot ($id + '.json')
  $fingerprint = if ([string]::IsNullOrWhiteSpace($EvidenceFingerprint)) { Get-CompactHash ((Sanitize-Text $Title) + '|' + (Sanitize-Text $Proposal) + '|' + (Sanitize-Text $Evidence)) } else { Assert-CompactId $EvidenceFingerprint 'EVIDENCE_FINGERPRINT' }
  if (Test-Path -LiteralPath $path) {
    $existing = Read-JsonFile $path 'PROPOSAL_READ_FAILED'
    if ([string]$existing.status -eq 'staged' -and [string]$existing.evidenceFingerprint -eq $fingerprint) {
      $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$id; path=$path; status='staged'; reused=$true; next='A matching bounded proposal is already staged; provide a verified replay artifact before validation.' }
      if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "SKILL_EVOLUTION_PROPOSE ok=$($result.ok) status=$($result.status) id=$($result.id)"; Write-Host "PATH $($result.path)" }
      exit 0
    }
    throw 'PROPOSAL_ID_COLLISION: proposal id already belongs to different evidence.'
  }
  $item = [pscustomobject]@{
    id = $id
    status = 'staged'
    title = (Sanitize-Text $Title)
    affected = (Sanitize-Text $Affected)
    proposal = (Sanitize-Text $Proposal)
    evidence = (Sanitize-Text $Evidence)
    evidenceFingerprint = $fingerprint
    source = (Sanitize-Text $Source)
    validationGate = [pscustomobject]@{
      failureFixed = $false
      criticalBehaviorPreserved = $false
      noExtraVerbosity = $false
      noPrivacyRegression = $false
      noBroadAutoMutation = $false
    }
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    adoption = 'Requires user approval or an already-approved rule-edit task before mutating skill files.'
    lifecycle = [pscustomobject]@{
      authority = 'self-improvement-queue.ps1'
      status = 'staged'
      canonicalStage = 'candidate'
      queueCandidateId = ''
      updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      projected = $false
    }
    validation = [pscustomobject]@{
      contractVersion = 'pending'
      status = 'pending'
      sealedReplay = $false
      sealedHoldout = $false
      noConsumedHoldoutReuse = $false
      overfitGuardPassed = $false
      artifactSha256 = ''
      rawPromptStored = $false
      updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    effect = (New-NotScoredEffect)
  }
  Write-JsonUtf8NoBom $path $item 10
  $index.proposals = @($index.proposals) + @([pscustomobject]@{ id=$id; title=$item.title; path=$path; status='staged' })
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$id; path=$path; status='staged'; canonicalStage='candidate'; next='Run -Mode Validate after evidence exists; apply only after approval.' }
}
elseif ($Mode -eq 'Validate') {
  if ([string]::IsNullOrWhiteSpace($ProposalId)) { throw 'ProposalId is required for Validate.' }
  $ProposalId = Assert-CompactId $ProposalId 'PROPOSAL_ID'
  $path = Join-Path $proposalRoot ($ProposalId + '.json')
  if (-not (Test-Path $path)) { throw "Proposal not found: $ProposalId" }
  $item = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $item = Ensure-ProposalLifecycleMetadata $item
  if ($Pass) {
    if ([string]::IsNullOrWhiteSpace($ValidationArtifactPath)) { throw 'VALIDATION_ARTIFACT_REQUIRED: -Pass requires a verified replay artifact.' }
    $artifactPath = [IO.Path]::GetFullPath($ValidationArtifactPath)
    $artifact = Read-JsonFile $artifactPath 'VALIDATION_ARTIFACT_INVALID'
    $checks = $artifact.checks
    $checksOk = ($checks -and $checks.failureFixed -eq $true -and $checks.criticalBehaviorPreserved -eq $true -and $checks.noExtraVerbosity -eq $true -and $checks.noPrivacyRegression -eq $true -and $checks.noBroadAutoMutation -eq $true)
    $schema = [string]$artifact.schema
    if ($schema -notin @('super-brain.skill-evolution-validation.v1','super-brain.skill-evolution-validation.v2') -or [string]$artifact.proposalId -ne $ProposalId -or [string]$artifact.evidenceFingerprint -ne [string]$item.evidenceFingerprint -or $artifact.rawPromptStored -ne $false -or -not $checksOk) { throw 'VALIDATION_ARTIFACT_REJECTED: replay artifact does not satisfy the governed validation contract.' }
    $validation = [pscustomobject]@{
      contractVersion = if ($schema -eq 'super-brain.skill-evolution-validation.v2') { 'v2' } else { 'legacy_v1' }
      status = if ($schema -eq 'super-brain.skill-evolution-validation.v2') { 'sealed-validated' } else { 'historical' }
      sealedReplay = $false
      sealedHoldout = $false
      noConsumedHoldoutReuse = $false
      overfitGuardPassed = $false
      artifactSha256 = (Get-FileSha256 $artifactPath)
      rawPromptStored = $false
      updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    if ($schema -eq 'super-brain.skill-evolution-validation.v2') {
      $sealed = $artifact.sealedEvaluation
      $sealedChecksOk = ($sealed -and $sealed.replayArtifactSha256 -match '^[a-f0-9]{64}$' -and $sealed.holdoutSetHash -match '^[a-f0-9]{64}$' -and $sealed.holdoutUnused -eq $true -and $sealed.independentGeneration -eq $true -and $checks.sealedReplay -eq $true -and $checks.sealedHoldout -eq $true -and $checks.noConsumedHoldoutReuse -eq $true -and $checks.overfitGuardPassed -eq $true)
      if (-not $sealedChecksOk) { throw 'VALIDATION_ARTIFACT_SEALED_EVALUATION_REQUIRED: v2 validation requires replay, unused independent holdout, and anti-overfit evidence.' }
      $validation.sealedReplay = $true
      $validation.sealedHoldout = $true
      $validation.noConsumedHoldoutReuse = $true
      $validation.overfitGuardPassed = $true
    }
    $item | Add-Member -NotePropertyName validationEvidence -NotePropertyValue ('artifact:' + (Get-FileSha256 $artifactPath)) -Force
    $item | Add-Member -NotePropertyName validationArtifact -NotePropertyValue ([pscustomobject]@{ fileName=(Split-Path -Leaf $artifactPath); sha256=(Get-FileSha256 $artifactPath); rawPromptStored=$false }) -Force
    $item | Add-Member -NotePropertyName validation -NotePropertyValue $validation -Force
    if ($schema -eq 'super-brain.skill-evolution-validation.v2') {
      $item.status = 'validated'
      $item.validationGate.failureFixed = $true
      $item.validationGate.criticalBehaviorPreserved = $true
      $item.validationGate.noExtraVerbosity = $true
      $item.validationGate.noPrivacyRegression = $true
      $item.validationGate.noBroadAutoMutation = $true
      $item.lifecycle | Add-Member -NotePropertyName canonicalStage -NotePropertyValue 'sealed-validated' -Force
    } else {
      $item.status = 'blocked'
      $item | Add-Member -NotePropertyName blockReason -NotePropertyValue 'validation_v1_historical_only' -Force
      $item.lifecycle | Add-Member -NotePropertyName canonicalStage -NotePropertyValue 'historical' -Force
    }
  } else {
    $item.status = 'rejected'
    $item | Add-Member -NotePropertyName validationEvidence -NotePropertyValue (Sanitize-Text $Evidence) -Force
    $item | Add-Member -NotePropertyName validation -NotePropertyValue ([pscustomobject]@{ contractVersion='none'; status='rejected'; sealedReplay=$false; sealedHoldout=$false; noConsumedHoldoutReuse=$false; overfitGuardPassed=$false; artifactSha256=''; rawPromptStored=$false; updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) -Force
    $item.lifecycle | Add-Member -NotePropertyName canonicalStage -NotePropertyValue 'rejected' -Force
  }
  $item = Ensure-ProposalLifecycleMetadata $item
  $item | Add-Member -NotePropertyName validatedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
  Write-JsonUtf8NoBom $path $item 10
  foreach ($p in @($index.proposals)) { if ($p.id -eq $ProposalId) { $p.status = $item.status } }
  Write-Index $index
  $result = [pscustomobject]@{ ok=$true; mode=$Mode; id=$ProposalId; path=$path; status=$item.status; canonicalStage=[string]$item.lifecycle.canonicalStage }
}
else {
  $result = [pscustomobject]@{
    ok = $true
    mode = $Mode
    indexPath = $indexPath
    failureCount = @($index.failures).Count
    proposalCount = @($index.proposals).Count
    recentFailures = @($index.failures | Select-Object -Last 5)
    recentProposals = @($index.proposals | Select-Object -Last 5)
  }
}

if ($Json) { $result | ConvertTo-Json -Depth 10 } else {
  Write-Host "SKILL_EVOLUTION_$($Mode.ToUpperInvariant()) ok=$($result.ok) status=$($result.status) id=$($result.id)"
  if ($result.path) { Write-Host "PATH $($result.path)" }
}
exit 0
