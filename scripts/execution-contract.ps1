[CmdletBinding(PositionalBinding=$false)]
param(
[ValidateSet('Set','ObserveUser','Get','Resolve','Guard','Clear','ResumeParent')]
  [string]$Action = 'Get',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [switch]$RebindSession,
  [string]$FocusId = '',
  [string]$LatestUserInstruction = '',
  [string]$AssistantCommitment = '',
  [string]$NextAction = '',
  [string]$CurrentPhase = '',
  [string]$CurrentStep = '',
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
  [string[]]$AcceptanceCriteria = @(),
  [ValidateSet('partial','completed')]
  [string]$BranchStatus = 'partial',
  [string]$CompletionEvidence = '',
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
  [int]$MaxAgeHours = 168,
  [string]$StateRoot = '',
  [string]$Source = '',
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
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
$script:NextActionWasBound = $PSBoundParameters.ContainsKey('NextAction')
$script:CurrentPhaseWasBound = $PSBoundParameters.ContainsKey('CurrentPhase')
$script:CurrentStepWasBound = $PSBoundParameters.ContainsKey('CurrentStep')
$script:CompletedStepsWereBound = $PSBoundParameters.ContainsKey('CompletedSteps')
$script:PendingStepsWereBound = $PSBoundParameters.ContainsKey('PendingSteps')
$script:BlockersWereBound = $PSBoundParameters.ContainsKey('Blockers')
$script:EvidenceWereBound = $PSBoundParameters.ContainsKey('Evidence')
$script:VerificationResultsWereBound = $PSBoundParameters.ContainsKey('VerificationResults')
$script:StateCardSourceWasBound = $PSBoundParameters.ContainsKey('StateCardSource')
$script:InstructionModeWasBound = $PSBoundParameters.ContainsKey('InstructionMode') -and $InstructionMode -ne 'auto'
$script:ForeignContextTaskId = ''
$script:ForeignContextSessionState = ''
$script:ReturnStackMaxDepth = 4
$script:UnfinishedWorkPlanMaxCount = 12

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
    completedSteps = if ($Card.PSObject.Properties['completedSteps']) { @(Limit-ContractList @($Card.completedSteps) 8 180) } else { @() }
    pendingSteps = if ($Card.PSObject.Properties['pendingSteps']) { @(Limit-ContractList @($Card.pendingSteps) 8 180) } else { @() }
    blockers = if ($Card.PSObject.Properties['blockers']) { @(Limit-ContractList @($Card.blockers) 6 180) } else { @() }
    evidence = if ($Card.PSObject.Properties['evidence']) { @(Limit-ContractList @($Card.evidence) 8 180) } else { @() }
    verificationResults = if ($Card.PSObject.Properties['verificationResults']) { @(Limit-ContractList @($Card.verificationResults) 6 180) } else { @() }
    topicKeys = @($topicKeys)
    topicKeySource = $topicKeySource
    prioritySource = $prioritySourceValue
    priorityReason = Limit-ContractText $priorityReasonValue 180
    capturedAt = if ($Card.PSObject.Properties['capturedAt']) { [string]$Card.capturedAt } else { (Get-Date).ToString('o') }
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
  [object[]]$UnfinishedWorkPlans
) {
  $empty = [pscustomobject]@{
    mode = 'unclassified'
    topicAffinity = 'unknown'
    targetLineId = ''
    targetLineLabel = ''
    confidence = 'none'
    matchedKeys = @()
    candidateLineIds = @()
    needsClarification = (@($ReturnStack).Count + @($UnfinishedWorkPlans).Count -gt 0)
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
    topicKeys = @(Limit-TopicKeys $ActiveTopicKeys)
    topicKeySource = $ActiveTopicKeySource
  }
  foreach ($item in @(Limit-ReturnStack $ReturnStack)) {
    $candidates += [pscustomobject]@{
      focusId = [string]$item.focusId
      focusLabel = [string]$item.focusLabel
      role = 'suspended'
      topicKeys = @($item.topicKeys)
      topicKeySource = [string]$item.topicKeySource
    }
  }
  foreach ($item in @(Limit-UnfinishedWorkPlans $UnfinishedWorkPlans @() $script:UnfinishedWorkPlanMaxCount)) {
    if (@($candidates | Where-Object { [string]$_.focusId -eq [string]$item.focusId }).Count -gt 0) { continue }
    $candidates += [pscustomobject]@{
      focusId = [string]$item.focusId
      focusLabel = [string]$item.focusLabel
      role = 'unfinished'
      topicKeys = @($item.topicKeys)
      topicKeySource = [string]$item.topicKeySource
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
    if (-not $isBareContinuation) {
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
    confidence = [string]$winner.confidence
    matchedKeys = @($winner.matchedKeys)
    candidateLineIds = @([string]$winner.candidate.focusId)
    needsClarification = -not $highConfidence
    recommendedInstructionMode = if ($role -eq 'active') { 'continue' } elseif ($role -eq 'unfinished') { 'side_branch' } else { 'resume_parent' }
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
  if ([string]$Classification.mode -notin @('continue','side_branch')) { return $false }
  $matchedKeys = @($Classification.matchedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($matchedKeys.Count -eq 0) { return $false }
  if (-not [string]::IsNullOrWhiteSpace($Instruction)) { return $true }
  return ($matchedKeys -contains 'explicit_instruction_mode')
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
  [object]$LatestMessageClassification = $null
) {
  $returnCards = @(Limit-ReturnStack @($ReturnStack))
  $suspended = @(Limit-WorkLineIds @($returnCards) 4)
  $completed = @(Limit-WorkLineIds @($CompletedWorkLines) 12)
  $excludedUnfinished = @($ActiveFocusId) + @($returnCards | ForEach-Object { [string]$_.focusId })
  $unfinishedState = Get-BoundedUnfinishedWorkState $UnfinishedWorkLines $UnfinishedWorkPlans $excludedUnfinished
  $unfinished = @($unfinishedState.lines)
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
    $LatestMessageClassification = Get-TopicClassification '' $ActiveFocusId $ActiveFocusLabel $ActiveTopicKeys $ActiveTopicKeySource $returnCards $unfinishedCards
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
    mainLine = if ($suspended.Count -gt 0) { [string]$suspended[0] } else { Limit-ContractText $ActiveFocusId 120 }
    activeLine = Limit-ContractText $ActiveFocusId 120
    completedRecent = @($completed)
    unfinishedLines = @($unfinished)
    suspendedLines = @($suspended)
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
      suspended = @($suspendedPlans | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; label=$_.focusLabel; nextAction=$_.nextAction } })
      unfinished = @($unfinishedPlans | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; label=$_.focusLabel; status='unfinished'; role='side_branch'; nextAction=$_.nextAction; executionRank=$_.priority.executionRank } })
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
  [string]$SourceValue = 'execution-contract.ps1'
) {
  $returnCards = @(Limit-ReturnStack @($ReturnStackValue) 4)
  $mainLineId = if ($WorkLineStatusValue) { [string]$WorkLineStatusValue.mainLine } else { '' }
  $activeLineId = if ($WorkLineStatusValue) { [string]$WorkLineStatusValue.activeLine } else { $ActiveFocusIdValue }
  if ([string]::IsNullOrWhiteSpace($activeLineId)) { $activeLineId = $ActiveFocusIdValue }
  $parentLineId = if ($returnCards.Count -gt 0) { [string]$returnCards[-1].focusId } else { '' }
  $lineRole = if ($returnCards.Count -gt 0) { 'side_branch' } else { 'main_line' }
  $phase = if (-not [string]::IsNullOrWhiteSpace($CurrentPhaseValue)) { Limit-ContractText $CurrentPhaseValue 120 } else { Limit-ContractText $InstructionModeValue 120 }
  $currentStep = if (-not [string]::IsNullOrWhiteSpace($CurrentStepValue)) { Limit-ContractText $CurrentStepValue 220 } else { Limit-ContractText $NextActionValue 220 }
  $completedSteps = @(Limit-ContractList @($CompletedStepsValue) 8 180)
  $pendingSteps = @(Limit-ContractList @($PendingStepsValue) 8 180)
  if ($pendingSteps.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentStep)) { $pendingSteps = @($currentStep) }
  $blockers = @(Limit-ContractList @($BlockersValue) 6 180)
  $evidence = @(Limit-ContractList @($EvidenceValue) 8 180)
  $verificationResults = @(Limit-ContractList @($VerificationResultsValue) 6 180)
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
    blockers = @($blockers)
    evidence = @($evidence)
    verificationResults = @($verificationResults)
    nextAction = Limit-ContractText $NextActionValue 220
    assistantCommitment = Limit-ContractText $AssistantCommitmentValue 260
    constraints = @(Limit-ContractList @($ConstraintsValue) 6 160)
    acceptanceCriteria = @(Limit-ContractList @($AcceptanceCriteriaValue) 6 160)
    priorityOrder = @($priorityOrder)
    suspendedLineIds = @($(if ($WorkLineStatusValue) { @(Limit-WorkLineIds @($WorkLineStatusValue.suspendedLines) 4) } else { @() }))
    unfinishedLineIds = @($(if ($WorkLineStatusValue) { @(Limit-WorkLineIds @($WorkLineStatusValue.unfinishedLines) 6) } else { @() }))
    returnStack = @($returnCardsForCard)
    latestMessageClassification = if ($WorkLineStatusValue -and $WorkLineStatusValue.PSObject.Properties['latestMessageClassification']) { $WorkLineStatusValue.latestMessageClassification } else { $null }
    source = Limit-ContractText $SourceValue 120
    capturedAt = (Get-Date).ToString('o')
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
  if ($readState.authorized -eq $true) { return $contract }
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
  return Read-ContractJson (Join-Path $workspace 'current-task-context.json')
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
  if ([string]::IsNullOrWhiteSpace($TaskId)) {
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

function Test-ContractCurrent($Contract) {
  $reasons = @()
  if (-not $Contract) { $reasons += 'missing' }
  else {
    if ([string]$Contract.schema -ne 'super-brain.execution-contract.v1') { $reasons += 'schema_mismatch' }
    if ([string]$Contract.taskId -ne $TaskId) { $reasons += 'task_mismatch' }
    if (-not (Test-SuperBrainWorkspaceKey ([string]$Contract.workspaceKey) $WorkspaceKey)) { $reasons += 'workspace_mismatch' }
    if ([string]$Contract.packageVersion -ne [string]$manifest.version) { $reasons += 'version_mismatch' }
    if ([string]$Contract.status -ne 'active') { $reasons += 'inactive' }
    try {
      $age = ((Get-Date) - [datetime]::Parse([string]$Contract.updatedAt)).TotalHours
      if ($age -gt $MaxAgeHours) { $reasons += 'stale' }
      if ($age -lt -0.25) { $reasons += 'future_timestamp' }
    } catch { $reasons += 'invalid_timestamp' }
  }
  return [pscustomobject]@{ current=($reasons.Count -eq 0); reasons=@($reasons) }
}

function Set-Contract([switch]$ObserveOnly) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'EXECUTION_CONTRACT_TASK_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'EXECUTION_CONTRACT_WORKSPACE_REQUIRED' }
  $contractPath = Get-ContractPath $TaskId $WorkspaceKey
  return Invoke-SuperBrainFileLock $contractPath {
    $record = Get-BoundContractRecord $TaskId $WorkspaceKey
    if ($record.identityConflict) { throw 'EXECUTION_CONTRACT_IDENTITY_MISMATCH' }
    $existing = $record.contract
    $existingSessionKey = Get-ContractSessionKey $existing
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
    $ownerSessionKey = if ($RebindSession -and -not [string]::IsNullOrWhiteSpace($SessionKey)) { $SessionKey } elseif (-not [string]::IsNullOrWhiteSpace($existingSessionKey)) { $existingSessionKey } else { $SessionKey }
    $revision = if ($existing -and $existing.PSObject.Properties['revision']) { [int]$existing.revision + 1 } else { 1 }
    $oldFocus = if ($existing) { [string]$existing.focusId } else { '' }
    $newFocus = if ($ObserveOnly) { $oldFocus } elseif (-not [string]::IsNullOrWhiteSpace($FocusId)) { Limit-ContractText $FocusId 120 } else { $oldFocus }
    $focusChanged = (-not [string]::IsNullOrWhiteSpace($oldFocus) -and -not [string]::IsNullOrWhiteSpace($newFocus) -and $newFocus -ne $oldFocus)
    $mode = if ($ObserveOnly) { if ($existing -and $existing.PSObject.Properties['instructionMode']) { [string]$existing.instructionMode } else { 'continue' } } elseif ($InstructionMode -eq 'auto') { if ($focusChanged) { 'side_branch' } else { 'continue' } } else { $InstructionMode }
    $invalidated = @($InvalidatedWorkItems)
    if ($existing) { $invalidated += @($existing.invalidatedWorkItems) }
    # Keep single-item stacks as arrays; PowerShell's if-expression otherwise unwraps them.
    $returnStack = @(
      if ($existing) { @(Limit-ReturnStack @($existing.returnStack)) }
    )
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($existing -and $existing.PSObject.Properties['unfinishedWorkLines']) { @($existing.unfinishedWorkLines) } else { @() }) $(if ($existing -and $existing.PSObject.Properties['unfinishedWorkPlans']) { @($existing.unfinishedWorkPlans) } else { @() })
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $resumePlan = if ($focusChanged) { @($unfinishedWorkPlans | Where-Object { [string]$_.focusId -eq $newFocus } | Select-Object -First 1) } else { @() }
    $resumePlan = if (@($resumePlan).Count -gt 0) { @($resumePlan)[0] } else { $null }
    if (-not $ObserveOnly -and $focusChanged -and $mode -eq 'side_branch') {
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
        topicKeys=if($existing.PSObject.Properties['topicKeys']){@($existing.topicKeys)}else{@()}
        topicKeySource=if($existing.PSObject.Properties['topicKeySource']){[string]$existing.topicKeySource}else{'focus_id_derived'}
        prioritySource=if($existing.PSObject.Properties['prioritySource']){[string]$existing.prioritySource}else{'current_contract'}
        priorityReason=if($existing.PSObject.Properties['priorityReason']){[string]$existing.priorityReason}else{''}
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
    if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($newFocus)) {
      $unfinishedState = Get-BoundedUnfinishedWorkState $unfinishedWorkLines $unfinishedWorkPlans @($newFocus)
      $unfinishedWorkLines = @($unfinishedState.lines)
      $unfinishedWorkPlans = @($unfinishedState.plans)
    }
    $completedWorkLines = @(
      if ($existing -and $existing.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($existing.completedWorkLines)) }
    )
    $latestInstruction = if ($ObserveOnly) { Protect-Instruction $UserInstruction } elseif (-not [string]::IsNullOrWhiteSpace($LatestUserInstruction)) { Protect-Instruction $LatestUserInstruction } elseif ($existing) { [string]$existing.latestUserInstruction } else { '' }
    $commitment = if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($AssistantCommitment)) { Limit-ContractText $AssistantCommitment 480 } elseif ($resumePlan) { [string]$resumePlan.assistantCommitment } elseif ($existing) { [string]$existing.assistantCommitment } else { '' }
    $actionValue = if (-not $ObserveOnly -and -not [string]::IsNullOrWhiteSpace($NextAction)) { Limit-ContractText $NextAction 480 } elseif ($resumePlan) { [string]$resumePlan.nextAction } elseif ($existing) { [string]$existing.nextAction } else { '' }
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
    $stateStepValue = if ($script:CurrentStepWasBound) { Limit-ContractText $CurrentStep 220 } elseif ($script:NextActionWasBound) { Limit-ContractText $actionValue 220 } elseif ($resumeStateCard) { Limit-ContractText ([string]$resumeStateCard.currentStep) 220 } elseif ($existingStateCard -and -not $focusChanged) { Limit-ContractText ([string]$existingStateCard.currentStep) 220 } else { Limit-ContractText $actionValue 220 }
    $stateCompletedSteps = if ($script:CompletedStepsWereBound) { @(Limit-ContractList $CompletedSteps 8 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.completedSteps) 8 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.completedSteps) 8 180) } else { @() }
    $statePendingSteps = if ($script:PendingStepsWereBound) { @(Limit-ContractList $PendingSteps 8 180) } elseif ($script:NextActionWasBound) { if(-not [string]::IsNullOrWhiteSpace($actionValue)){ @($actionValue) } else { @() } } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.pendingSteps) 8 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.pendingSteps) 8 180) } else { @() }
    $stateBlockers = if ($script:BlockersWereBound) { @(Limit-ContractList $Blockers 6 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.blockers) 6 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.blockers) 6 180) } else { @() }
    $stateEvidence = if ($script:EvidenceWereBound) { @(Limit-ContractList $Evidence 8 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.evidence) 8 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.evidence) 8 180) } else { @() }
    $stateVerificationResults = if ($script:VerificationResultsWereBound) { @(Limit-ContractList $VerificationResults 6 180) } elseif ($resumeStateCard) { @(Limit-ContractList @($resumeStateCard.verificationResults) 6 180) } elseif ($existingStateCard -and -not $focusChanged) { @(Limit-ContractList @($existingStateCard.verificationResults) 6 180) } else { @() }
    $stateSourceValue = if ($script:StateCardSourceWasBound) { Limit-ContractText $StateCardSource 120 } elseif ($resumeStateCard -and $resumeStateCard.PSObject.Properties['source']) { Limit-ContractText ([string]$resumeStateCard.source) 120 } elseif ($existingStateCard -and -not $focusChanged -and $existingStateCard.PSObject.Properties['source']) { Limit-ContractText ([string]$existingStateCard.source) 120 } else { 'execution-contract.ps1' }
    $messageClassification = Get-TopicClassification $latestInstruction $newFocus $focusLabelValue $topicKeyValue $topicKeySourceValue $returnStack $unfinishedWorkPlans
    $explicitInstructionReconciliation = (-not $ObserveOnly -and $script:InstructionModeWasBound -and $script:FocusIdWasBound -and -not [string]::IsNullOrWhiteSpace($FocusId) -and $script:NextActionWasBound -and -not [string]::IsNullOrWhiteSpace($NextAction) -and -not [string]::IsNullOrWhiteSpace($newFocus) -and -not [string]::IsNullOrWhiteSpace($actionValue))
    if ($explicitInstructionReconciliation) {
      $messageClassification = [pscustomobject]@{
        mode=$mode; topicAffinity='active'; targetLineId=$newFocus; targetLineLabel=$focusLabelValue; confidence='high'; matchedKeys=@('explicit_instruction_mode'); candidateLineIds=@($newFocus); needsClarification=$false; recommendedInstructionMode=$mode; reason='an explicit instruction mode, focus, and concrete action reconciled the current work line'; rawInstructionStored=$false
      }
    }
    $classificationNeedsReconciliation = Test-ClassificationBlocksAuthorization $messageClassification $latestInstruction
    $workLineStatusValue = New-WorkLineStatus $newFocus $returnStack $completedWorkLines $unfinishedWorkLines $actionValue $commitment $constraintValue $acceptanceValue $focusLabelValue $topicKeyValue $topicKeySourceValue $prioritySourceValue $priorityReasonValue $unfinishedWorkPlans $messageClassification
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey $ownerSessionKey $revision $mode $newFocus $focusLabelValue $workLineStatusValue $returnStack $statePhaseValue $stateStepValue $stateCompletedSteps $statePendingSteps $stateBlockers $stateEvidence $stateVerificationResults $actionValue $commitment $constraintValue $acceptanceValue $stateSourceValue
    $value = [pscustomobject]@{
      ok = $true
      schema = 'super-brain.execution-contract.v1'
      taskId = $TaskId
      workspaceKey = $WorkspaceKey
      ownerSessionKey = $ownerSessionKey
      sessionBound = (-not [string]::IsNullOrWhiteSpace($ownerSessionKey))
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
      workLineStatus = $workLineStatusValue
      continuityStateCard = $stateCardValue
      latestUserInstruction = $latestInstruction
      latestMessageClassification = $messageClassification
      assistantCommitment = $commitment
      nextAction = $actionValue
      currentPhase = $statePhaseValue
      currentStep = $stateStepValue
      completedSteps = @($stateCompletedSteps)
      pendingSteps = @($statePendingSteps)
      blockers = @($stateBlockers)
      evidence = @($stateEvidence)
      verificationResults = @($stateVerificationResults)
      constraints = @($constraintValue)
      topicKeys = @($topicKeyValue)
      topicKeySource = $topicKeySourceValue
      prioritySource = $prioritySourceValue
      priorityReason = $priorityReasonValue
      invalidatedWorkItems = @(Limit-ContractList $invalidated 20 120)
      acceptanceCriteria = @($acceptanceValue)
      needsReconciliation = if ($ObserveOnly) { ([bool]$RequiresReconciliation -or $classificationNeedsReconciliation) } elseif ($explicitInstructionReconciliation) { $false } elseif ($existing -and $existing.needsReconciliation -eq $true) { $true } else { $classificationNeedsReconciliation }
      updatedAt = (Get-Date).ToString('o')
      source = if ([string]::IsNullOrWhiteSpace($Source)) { if ($ObserveOnly) { 'user_prompt_hook' } else { 'assistant_execution_commitment' } } else { Limit-ContractText $Source 120 }
      rawPromptStored = $false
      rawTranscriptStored = $false
      rawSessionIdStored = $false
      retention = 'latest_task_contract_plus_bounded_return_stack'
      path = $contractPath
    }
    Write-AtomicJsonUnlocked $contractPath $value
    Invoke-SuperBrainFileLock $pointerPath { Write-AtomicJsonUnlocked $pointerPath $value } | Out-Null
    if ([string]$record.source -eq 'legacy_task_only') { Remove-MatchingLegacyContract $TaskId $WorkspaceKey }
    return $value
  }
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
    $validity = Test-ContractCurrent $existing
    if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; reasons=@($validity.reasons); guard='Cannot resume a parent task without a current execution contract.' } }
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
    $stack = @(Limit-ReturnStack @($existing.returnStack))
    if ($stack.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_NO_PARENT'; taskId=$TaskId; currentFocusId=[string]$existing.focusId; guard='No suspended parent task is available.' } }
    $parent = $stack[-1]
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
    $completionEvidence = Limit-ContractText $CompletionEvidence 480
    $branchCompleted = ($BranchStatus -eq 'completed' -and -not [string]::IsNullOrWhiteSpace($completionEvidence))
    $resolvedBranchStatus = if ($branchCompleted) { 'completed' } else { 'partial' }
    $completedWorkLines = @(Limit-WorkLineIds @($existing.completedWorkLines))
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($existing.PSObject.Properties['unfinishedWorkLines']) { @($existing.unfinishedWorkLines) } else { @() }) $(if ($existing.PSObject.Properties['unfinishedWorkPlans']) { @($existing.unfinishedWorkPlans) } else { @() })
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
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
    })
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
    $workLineStatusValue = New-WorkLineStatus ([string]$parent.focusId) $remaining $completedWorkLines $unfinishedWorkLines ([string]$parent.nextAction) ([string]$parent.assistantCommitment) @($parent.constraints) @($parent.acceptanceCriteria) $parentFocusLabel $parentTopicKeys $parentTopicKeySource 'restored_parent' 'nearest suspended parent resumed after side branch' $unfinishedWorkPlans $resumeClassification
    $parentPhase = if ($parent.PSObject.Properties['currentPhase']) { [string]$parent.currentPhase } else { if($parent.PSObject.Properties['phase']){[string]$parent.phase}else{'resume_parent'} }
    $parentCurrentStep = if ($parent.PSObject.Properties['currentStep']) { [string]$parent.currentStep } else { [string]$parent.nextAction }
    $parentCompletedSteps = if ($parent.PSObject.Properties['completedSteps']) { @($parent.completedSteps) } else { @() }
    $parentPendingSteps = if ($parent.PSObject.Properties['pendingSteps']) { @($parent.pendingSteps) } else { if(-not [string]::IsNullOrWhiteSpace([string]$parentCurrentStep)){ @([string]$parentCurrentStep) }else{@()} }
    $parentBlockers = if ($parent.PSObject.Properties['blockers']) { @($parent.blockers) } else { @() }
    $parentEvidence = if ($parent.PSObject.Properties['evidence']) { @($parent.evidence) } else { @() }
    $parentVerificationResults = if ($parent.PSObject.Properties['verificationResults']) { @($parent.verificationResults) } else { @() }
    $revision = if ($existing.PSObject.Properties['revision']) { [int]$existing.revision + 1 } else { 1 }
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey (Get-ContractSessionKey $existing) $revision 'resume_parent' ([string]$parent.focusId) $parentFocusLabel $workLineStatusValue $remaining $parentPhase $parentCurrentStep $parentCompletedSteps $parentPendingSteps $parentBlockers $parentEvidence $parentVerificationResults ([string]$parent.nextAction) ([string]$parent.assistantCommitment) @($parent.constraints) @($parent.acceptanceCriteria) 'execution-contract.ps1:ResumeParent'
    $value = [pscustomobject]@{
      ok = $true
      schema = 'super-brain.execution-contract.v1'
      taskId = $TaskId
      workspaceKey = $WorkspaceKey
      ownerSessionKey = Get-ContractSessionKey $existing
      sessionBound = (-not [string]::IsNullOrWhiteSpace((Get-ContractSessionKey $existing)))
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
      workLineStatus = $workLineStatusValue
      continuityStateCard = $stateCardValue
      latestUserInstruction = Limit-ContractText ('Parent task resumed after side branch: ' + [string]$parent.focusId) 480
      latestMessageClassification = $resumeClassification
      assistantCommitment = [string]$parent.assistantCommitment
      nextAction = [string]$parent.nextAction
      currentPhase = $parentPhase
      currentStep = $parentCurrentStep
      completedSteps = @($parentCompletedSteps)
      pendingSteps = @($parentPendingSteps)
      blockers = @($parentBlockers)
      evidence = @($parentEvidence)
      verificationResults = @($parentVerificationResults)
      constraints = @($parent.constraints)
      topicKeys = @($parentTopicKeys)
      topicKeySource = $parentTopicKeySource
      prioritySource = 'restored_parent'
      priorityReason = 'nearest suspended parent resumed after side branch'
      invalidatedWorkItems = @($existing.invalidatedWorkItems)
      acceptanceCriteria = @($parent.acceptanceCriteria)
      needsReconciliation = $false
      updatedAt = (Get-Date).ToString('o')
      source = 'execution-contract.ps1:ResumeParent'
      completedSideBranchFocusId = if ($branchCompleted) { $sideBranchFocusId } else { '' }
      partialSideBranchFocusId = if ($branchCompleted) { '' } else { $sideBranchFocusId }
      resumedBranchStatus = $resolvedBranchStatus
      completionEvidence = if ($branchCompleted) { $completionEvidence } else { '' }
      rawPromptStored = $false
      rawTranscriptStored = $false
      rawSessionIdStored = $false
      retention = 'latest_task_contract_plus_bounded_return_stack'
      path = $contractPath
    }
    Write-AtomicJsonUnlocked $contractPath $value
    Invoke-SuperBrainFileLock $pointerPath { Write-AtomicJsonUnlocked $pointerPath $value } | Out-Null
    if ([string]$record.source -eq 'legacy_task_only') { Remove-MatchingLegacyContract $TaskId $WorkspaceKey }
    return $value
  }
}

function Resolve-Contract {
  $visibleUser = Protect-Instruction $VisibleUserInstruction
  $visibleCommitment = Limit-ContractText $VisibleAssistantCommitment 480
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $validity = Test-ContractCurrent $contract
  $sessionRead = Get-ContractSessionReadState $contract
  $contractReadable = ($validity.current -and $sessionRead.authorized -eq $true)
  if (-not [string]::IsNullOrWhiteSpace($visibleCommitment) -or -not [string]::IsNullOrWhiteSpace($visibleUser)) {
    $visibleNoContract = (-not $contract)
    $visibleContractInvalid = ($contract -and -not $validity.current)
    $visibleSessionBlocked = ($validity.current -and $sessionRead.authorized -ne $true)
    $returnStack = @(if ($contractReadable) { @(Limit-ReturnStack @($contract.returnStack)) })
    $returnTo = if ($contractReadable -and $contract.PSObject.Properties['returnTo'] -and $contract.returnTo) { $contract.returnTo } elseif ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
    $completedWorkLines = if ($contractReadable -and $contract.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($contract.completedWorkLines)) } else { @() }
    $activeFocusId = if ($contractReadable) { [string]$contract.focusId } else { 'visible-conversation' }
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($contractReadable -and $contract.PSObject.Properties['unfinishedWorkLines']) { @($contract.unfinishedWorkLines) } else { @() }) $(if ($contractReadable -and $contract.PSObject.Properties['unfinishedWorkPlans']) { @($contract.unfinishedWorkPlans) } else { @() }) @($activeFocusId)
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $activeFocusLabel = if ($contractReadable -and $contract.PSObject.Properties['focusLabel']) { [string]$contract.focusLabel } else { Get-DefaultFocusLabel $activeFocusId }
    $activeTopicKeys = if ($contractReadable -and $contract.PSObject.Properties['topicKeys']) { @($contract.topicKeys) } else { @(Get-DerivedTopicKeys $activeFocusId) }
    $activeTopicKeySource = if ($contractReadable -and $contract.PSObject.Properties['topicKeySource']) { [string]$contract.topicKeySource } else { 'focus_id_derived' }
    $visibleAction = if (-not [string]::IsNullOrWhiteSpace($visibleCommitment)) { $visibleCommitment } elseif ($contractReadable) { [string]$contract.nextAction } else { $visibleUser }
    $visiblePlanCommitment = if (-not [string]::IsNullOrWhiteSpace($visibleCommitment)) { $visibleCommitment } elseif ($contractReadable) { [string]$contract.assistantCommitment } else { '' }
    $messageClassification = if ($visibleContractInvalid) { New-SessionIsolationClassification 'invalid' } elseif ($visibleSessionBlocked) { New-SessionIsolationClassification $sessionRead.state } elseif (-not [string]::IsNullOrWhiteSpace($visibleUser)) { Get-TopicClassification $visibleUser $activeFocusId $activeFocusLabel $activeTopicKeys $activeTopicKeySource $returnStack $unfinishedWorkPlans } elseif ($contractReadable -and $contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { $null }
    $workLineStatus = New-WorkLineStatus $activeFocusId $returnStack $completedWorkLines $unfinishedWorkLines $visibleAction $visiblePlanCommitment $(if($contractReadable){@($contract.constraints)}else{@()}) $(if($contractReadable){@($contract.acceptanceCriteria)}else{@()}) $activeFocusLabel $activeTopicKeys $activeTopicKeySource $(if($contractReadable -and $contract.PSObject.Properties['prioritySource']){[string]$contract.prioritySource}else{'current_contract'}) $(if($contractReadable -and $contract.PSObject.Properties['priorityReason']){[string]$contract.priorityReason}else{'visible conversation preserves the active work-line identity'}) $unfinishedWorkPlans $messageClassification
    $visibleStateCard = New-ContinuityStateCard $TaskId $WorkspaceKey $(if($contractReadable){Get-ContractSessionKey $contract}else{$SessionKey}) $(if($contractReadable -and $contract.PSObject.Properties['revision']){[int]$contract.revision}else{0}) $(if($contractReadable){'visible_conversation'}else{'none'}) $activeFocusId $activeFocusLabel $workLineStatus $returnStack $(if($contractReadable -and $contract.PSObject.Properties['currentPhase']){[string]$contract.currentPhase}else{'visible_conversation'}) $(if($contractReadable -and $contract.PSObject.Properties['currentStep']){[string]$contract.currentStep}else{$visibleAction}) $(if($contractReadable -and $contract.PSObject.Properties['completedSteps']){@($contract.completedSteps)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['pendingSteps']){@($contract.pendingSteps)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['blockers']){@($contract.blockers)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['evidence']){@($contract.evidence)}else{@()}) $(if($contractReadable -and $contract.PSObject.Properties['verificationResults']){@($contract.verificationResults)}else{@()}) $visibleAction $visiblePlanCommitment $(if($contractReadable){@($contract.constraints)}else{@()}) $(if($contractReadable){@($contract.acceptanceCriteria)}else{@()}) 'execution-contract.ps1:visible-conversation'
    $visibleInstructionPending = (-not $visibleNoContract -and -not [string]::IsNullOrWhiteSpace($visibleUser) -and [string]::IsNullOrWhiteSpace($visibleCommitment))
    $visibleAuthorizationState = if($visibleNoContract){'not_applicable'}elseif($visibleContractInvalid -or $visibleSessionBlocked -or $visibleInstructionPending){'withheld'}else{'allowed'}
    $visibleAuthorizationWithheld = ($visibleAuthorizationState -eq 'withheld')
    if ($visibleAuthorizationState -ne 'allowed') {
      $workLineStatus = Remove-SuperBrainExecutableActions $workLineStatus
      if ($workLineStatus) { $workLineStatus | Add-Member -NotePropertyName actionAuthorization -NotePropertyValue $visibleAuthorizationState -Force }
      $returnStack = @($returnStack | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $returnTo = Remove-SuperBrainExecutableActions $returnTo
      $unfinishedWorkPlans = @($unfinishedWorkPlans | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $visibleStateCard = Remove-SuperBrainExecutableActions $visibleStateCard
    }
    $resolvedVisibleAction = if($visibleNoContract){''}elseif($visibleContractInvalid){'The selected execution contract is stale or invalid. Reconcile a fresh contract before mutation.'}elseif($visibleSessionBlocked){'Session ownership is not verified for the selected execution contract. Explicitly recover or rebind it before mutation.'}elseif($visibleInstructionPending){'Reconcile the latest visible user instruction before mutation: ' + $visibleUser}else{$visibleAction}
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom='visible_conversation'; resolutionSource=if($visibleNoContract){'none'}else{'visible_conversation'}; claimAllowed=($visibleAuthorizationState -ne 'withheld'); needsConfirmation=$visibleAuthorizationWithheld; actionAuthorization=$visibleAuthorizationState; sessionAccess=$sessionRead.state; foreignContextDetected=(-not [string]::IsNullOrWhiteSpace($script:ForeignContextTaskId)); foreignContextSessionAccess=$script:ForeignContextSessionState; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=$activeFocusId; focusLabel=$activeFocusLabel; instructionMode=if($visibleNoContract){'none'}else{'visible_conversation'}; returnStack=@($returnStack); returnTo=$returnTo; canResumeParent=($visibleAuthorizationState -eq 'allowed' -and $returnStack.Count -gt 0); completedWorkLines=@($completedWorkLines); unfinishedWorkLines=@($unfinishedWorkLines); unfinishedWorkPlans=@($unfinishedWorkPlans); workLineStatus=$workLineStatus; continuityStateCard=$visibleStateCard; latestUserInstruction=$visibleUser; latestMessageClassification=$messageClassification; assistantCommitment=if($visibleAuthorizationState -eq 'allowed'){$visibleCommitment}else{''}; nextAction=$resolvedVisibleAction; invalidatedWorkItems=if($contractReadable){@($contract.invalidatedWorkItems)}else{@()}; contractRevision=if($contractReadable){[int]$contract.revision}else{0}; guard=if($visibleNoContract){'No execution contract exists; visible context is non-authorizing and ordinary work remains direct.'}elseif($visibleContractInvalid){'Visible context cannot authorize a stale or invalid execution contract.'}elseif($visibleSessionBlocked){'Visible context cannot authorize a current contract owned by another or unknown root session.'}elseif($visibleInstructionPending){'Visible user instruction is newer but has no matching assistant commitment; reconcile it before mutation.'}else{'Visible conversation is newest and supplies the current action.'} }
  }
  if ($validity.current) {
    $sessionBlocked = ($sessionRead.authorized -ne $true)
    $pending = ($contract.needsReconciliation -eq $true)
    $returnStack = @(Limit-ReturnStack @($contract.returnStack))
    $returnTo = if ($contract.PSObject.Properties['returnTo'] -and $contract.returnTo) { $contract.returnTo } elseif ($returnStack.Count -gt 0) { $returnStack[-1] } else { $null }
    $completedWorkLines = if ($contract.PSObject.Properties['completedWorkLines']) { @(Limit-WorkLineIds @($contract.completedWorkLines)) } else { @() }
    $unfinishedState = Get-BoundedUnfinishedWorkState $(if ($contract.PSObject.Properties['unfinishedWorkLines']) { @($contract.unfinishedWorkLines) } else { @() }) $(if ($contract.PSObject.Properties['unfinishedWorkPlans']) { @($contract.unfinishedWorkPlans) } else { @() }) @([string]$contract.focusId)
    $unfinishedWorkLines = @($unfinishedState.lines)
    $unfinishedWorkPlans = @($unfinishedState.plans)
    $focusLabelValue = if ($contract.PSObject.Properties['focusLabel']) { [string]$contract.focusLabel } else { Get-DefaultFocusLabel ([string]$contract.focusId) }
    $topicKeyValue = if ($contract.PSObject.Properties['topicKeys']) { @($contract.topicKeys) } else { @(Get-DerivedTopicKeys ([string]$contract.focusId)) }
    $topicKeySourceValue = if ($contract.PSObject.Properties['topicKeySource']) { [string]$contract.topicKeySource } else { 'focus_id_derived' }
    $messageClassification = if ($sessionBlocked) { New-SessionIsolationClassification $sessionRead.state } elseif ($contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { Get-TopicClassification ([string]$contract.latestUserInstruction) ([string]$contract.focusId) $focusLabelValue $topicKeyValue $topicKeySourceValue $returnStack $unfinishedWorkPlans }
    $classificationBlocked = (-not $sessionBlocked -and (Test-ClassificationBlocksAuthorization $messageClassification ([string]$contract.latestUserInstruction)))
    $workLineStatus = New-WorkLineStatus ([string]$contract.focusId) $returnStack $completedWorkLines $unfinishedWorkLines ([string]$contract.nextAction) ([string]$contract.assistantCommitment) @($contract.constraints) @($contract.acceptanceCriteria) $focusLabelValue $topicKeyValue $topicKeySourceValue $(if($contract.PSObject.Properties['prioritySource']){[string]$contract.prioritySource}else{'current_contract'}) $(if($contract.PSObject.Properties['priorityReason']){[string]$contract.priorityReason}else{''}) $unfinishedWorkPlans $messageClassification
    $stateCardValue = New-ContinuityStateCard $TaskId $WorkspaceKey (Get-ContractSessionKey $contract) ([int]$contract.revision) ([string]$contract.instructionMode) ([string]$contract.focusId) $focusLabelValue $workLineStatus $returnStack $(if($contract.PSObject.Properties['currentPhase']){[string]$contract.currentPhase}else{[string]$contract.instructionMode}) $(if($contract.PSObject.Properties['currentStep']){[string]$contract.currentStep}else{[string]$contract.nextAction}) $(if($contract.PSObject.Properties['completedSteps']){@($contract.completedSteps)}else{@()}) $(if($contract.PSObject.Properties['pendingSteps']){@($contract.pendingSteps)}else{@()}) $(if($contract.PSObject.Properties['blockers']){@($contract.blockers)}else{@()}) $(if($contract.PSObject.Properties['evidence']){@($contract.evidence)}else{@()}) $(if($contract.PSObject.Properties['verificationResults']){@($contract.verificationResults)}else{@()}) ([string]$contract.nextAction) ([string]$contract.assistantCommitment) @($contract.constraints) @($contract.acceptanceCriteria) 'execution-contract.ps1:resolve'
    $resumedParentWithoutPlan = ($contract.PSObject.Properties['instructionMode'] -and $contract.instructionMode -eq 'resume_parent' -and -not [bool]$workLineStatus.activePlan.hasConcreteNextAction)
    $authorizationWithheld = ($sessionBlocked -or $pending -or $classificationBlocked -or $resumedParentWithoutPlan)
    if ($authorizationWithheld) {
      $workLineStatus = Remove-SuperBrainExecutableActions $workLineStatus
      if ($workLineStatus) { $workLineStatus | Add-Member -NotePropertyName actionAuthorization -NotePropertyValue 'withheld' -Force }
      $returnStack = @($returnStack | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $returnTo = Remove-SuperBrainExecutableActions $returnTo
      $unfinishedWorkPlans = @($unfinishedWorkPlans | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
      $stateCardValue = Remove-SuperBrainExecutableActions $stateCardValue
    }
    $resolvedNextAction = if($sessionRead.state -eq 'foreign'){'Execution contract belongs to another root session. Explicitly recover it, then Set with RebindSession before mutation.'}elseif($sessionRead.state -in @('unbound','session_required')){'Execution contract session ownership is not established. Explicitly bind it before mutation.'}elseif($pending -or $classificationBlocked){'Reconcile the latest user instruction and its work-line affinity before mutation: '+[string]$contract.latestUserInstruction}elseif($resumedParentWithoutPlan){'Recovered parent plan is missing. Use task-scoped checkpoint or return-card evidence before mutation.'}else{[string]$contract.nextAction}
    $resolvedGuard = if($sessionBlocked){'Session ownership blocks this plan from authorizing work in the current root conversation.'}elseif($pending -or $classificationBlocked){'The latest user instruction has no unique authorized work-line classification; reconcile it before mutation.'}elseif($resumedParentWithoutPlan){'A resumed parent has no concrete plan payload. Do not guess or continue generically.'}else{'Current task execution contract overrides phase-only checkpoint details.'}
    $resumeFrom = if($sessionRead.state -eq 'foreign'){'execution_contract_foreign_session'}elseif($sessionRead.state -in @('unbound','session_required')){'execution_contract_session_unbound'}elseif($pending){'execution_contract_pending_reconciliation'}elseif($classificationBlocked){'execution_contract_topic_unresolved'}elseif($contract.PSObject.Properties['instructionMode'] -and $contract.instructionMode -eq 'resume_parent'){'parent_return'}else{'execution_contract'}
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom=$resumeFrom; resolutionSource='execution_contract'; claimAllowed=(-not $authorizationWithheld); needsConfirmation=$authorizationWithheld; actionAuthorization=if($authorizationWithheld){'withheld'}else{'allowed'}; sessionAccess=$sessionRead.state; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=[string]$contract.focusId; focusLabel=$focusLabelValue; instructionMode=if($authorizationWithheld){'reconcile'}elseif($contract.PSObject.Properties['instructionMode']){[string]$contract.instructionMode}else{'continue'}; returnStack=@($returnStack); returnTo=$returnTo; canResumeParent=(-not $authorizationWithheld -and $returnStack.Count -gt 0); completedWorkLines=@($completedWorkLines); unfinishedWorkLines=@($unfinishedWorkLines); unfinishedWorkPlans=@($unfinishedWorkPlans); workLineStatus=$workLineStatus; continuityStateCard=$stateCardValue; latestUserInstruction=[string]$contract.latestUserInstruction; latestMessageClassification=$messageClassification; assistantCommitment=if($authorizationWithheld){''}else{[string]$contract.assistantCommitment}; nextAction=$resolvedNextAction; currentPhase=if($authorizationWithheld){''}else{[string]$stateCardValue.phase}; currentStep=if($authorizationWithheld){''}else{[string]$stateCardValue.currentStep}; completedSteps=if($authorizationWithheld){@()}else{@($stateCardValue.completedSteps)}; pendingSteps=if($authorizationWithheld){@()}else{@($stateCardValue.pendingSteps)}; blockers=if($authorizationWithheld){@()}else{@($stateCardValue.blockers)}; evidence=if($authorizationWithheld){@()}else{@($stateCardValue.evidence)}; verificationResults=if($authorizationWithheld){@()}else{@($stateCardValue.verificationResults)}; constraints=@($contract.constraints); topicKeys=@($topicKeyValue); topicKeySource=$topicKeySourceValue; invalidatedWorkItems=@($contract.invalidatedWorkItems); acceptanceCriteria=@($contract.acceptanceCriteria); contractRevision=[int]$contract.revision; guard=$resolvedGuard }
  }
  $checkpoint = Read-ContractJson $CheckpointPath
  if (-not $contract -and -not $checkpoint) {
    return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom='none'; resolutionSource='none'; claimAllowed=$true; needsConfirmation=$false; actionAuthorization='not_applicable'; sessionAccess='missing'; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=''; instructionMode='none'; returnStack=@(); returnTo=$null; canResumeParent=$false; completedWorkLines=@(); unfinishedWorkLines=@(); workLineStatus=$null; continuityStateCard=$null; latestUserInstruction=''; assistantCommitment=''; nextAction=''; currentPhase=''; currentStep=''; checkpointCurrentStepAvailable=$false; invalidatedWorkItems=@(); contractRevision=0; contractInvalidReasons=@($validity.reasons); guard='No execution contract exists for this task/session scope; no stored action is authorized and independent work remains direct.' }
  }
  return [pscustomobject]@{ ok=$true; schema='super-brain.execution-resolution.v1'; resumeFrom=if($checkpoint){'checkpoint_state_only'}else{'unknown'}; resolutionSource=if($checkpoint){'checkpoint_state_only'}else{'none'}; claimAllowed=$false; needsConfirmation=$true; actionAuthorization='withheld'; sessionAccess=$sessionRead.state; taskId=$TaskId; workspaceKey=$WorkspaceKey; focusId=''; instructionMode='unknown'; returnStack=@(); returnTo=$null; canResumeParent=$false; completedWorkLines=@(); unfinishedWorkLines=@(); workLineStatus=$null; continuityStateCard=$null; latestUserInstruction=''; assistantCommitment=''; nextAction=''; currentPhase=if($checkpoint){[string]$checkpoint.currentPhase}else{''}; currentStep=''; checkpointCurrentStepAvailable=($checkpoint -and -not [string]::IsNullOrWhiteSpace([string]$checkpoint.currentStep)); invalidatedWorkItems=@(); contractRevision=0; contractInvalidReasons=@($validity.reasons); guard='No current execution contract is available. A checkpoint may report phase/status, but must not expose or invent the latest promised action.' }
}

function Guard-Work {
  $contract = Read-BoundContract $TaskId $WorkspaceKey
  $sessionBlock = Get-ContractSessionMutationBlock $contract 'Guard'
  if ($sessionBlock) { return $sessionBlock }
  $validity = Test-ContractCurrent $contract
  if (-not $validity.current) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_MISSING_OR_STALE'; taskId=$TaskId; currentFocusId=''; proposedWorkId=$ProposedWorkId; reasons=@($validity.reasons); guard='Refresh the execution contract from visible conversation before mutation.' } }
  if ($contract.needsReconciliation -eq $true) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; latestUserInstruction=[string]$contract.latestUserInstruction; latestMessageClassification=if($contract.PSObject.Properties['latestMessageClassification']){$contract.latestMessageClassification}else{$null}; guard='A newer user instruction has not yet been reconciled. Use its task-scoped classification; ambiguous or unknown affinity must not authorize mutation.' } }
  $guardClassification = if ($contract.PSObject.Properties['latestMessageClassification']) { $contract.latestMessageClassification } else { $null }
  if (Test-ClassificationBlocksAuthorization $guardClassification ([string]$contract.latestUserInstruction)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_TOPIC_RECONCILIATION_REQUIRED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; latestUserInstruction=[string]$contract.latestUserInstruction; latestMessageClassification=$guardClassification; guard='Unknown or ambiguous work-line affinity cannot authorize mutation. Reconcile the latest instruction explicitly.' } }
  if ([string]::IsNullOrWhiteSpace([string]$contract.nextAction)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_ACTIVE_PLAN_MISSING'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; guard='The active work line has no concrete next action. Recover a task-scoped plan before mutation; generic memory cannot authorize work.' } }
  $returnStack = @(Limit-ReturnStack @($contract.returnStack))
  if ($returnStack.Count -gt 0 -and [string]$returnStack[-1].focusId -eq $ProposedWorkId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PARENT_SUSPENDED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; returnTo=$returnStack[-1]; guard='The parent task is suspended behind a side branch. Complete or explicitly close the branch, then run ResumeParent before mutating the parent.' } }
  if (@($contract.invalidatedWorkItems) -contains $ProposedWorkId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_WORK_INVALIDATED'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; invalidatedWorkItems=@($contract.invalidatedWorkItems); guard='The proposed work was superseded by a newer execution contract.' } }
  if (-not [string]::IsNullOrWhiteSpace($ProposedWorkId) -and -not [string]::IsNullOrWhiteSpace([string]$contract.focusId) -and $ProposedWorkId -ne [string]$contract.focusId) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_FOCUS_MISMATCH'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; guard='Do not mutate a different work item without updating the task execution contract.' } }
  return [pscustomobject]@{ ok=$true; code='EXECUTION_CONTRACT_GUARD_OK'; taskId=$TaskId; currentFocusId=[string]$contract.focusId; proposedWorkId=$ProposedWorkId; contractRevision=[int]$contract.revision; guard='Proposed work matches the latest current task execution contract.' }
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
    'ResumeParent' { Resume-ParentContract }
    'Clear' { Clear-Contract }
  }
  if ($null -eq $result) { $result = [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_NOT_FOUND';taskId=$TaskId} }
  $exitCode = if ($result.ok -eq $true) { 0 } else { 1 }
  Write-Result $result $exitCode
} catch {
  Write-Result ([pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_ERROR';taskId=$TaskId;error=$_.Exception.Message}) 1
}
