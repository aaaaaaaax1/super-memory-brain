function Get-H7FixtureWorkspaceKey([string]$WorkspaceKey = '') {
  $value = [string]$WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($value)) { return '' }
  $value = $value.Trim()
  if ($value -match '^ws-[0-9a-f]{24}$') { return $value.ToLowerInvariant() }
  try { $value = [IO.Path]::GetFullPath($value).TrimEnd('\','/') } catch {}
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value.ToLowerInvariant()))
    return 'ws-' + (-join ($hash[0..11] | ForEach-Object { $_.ToString('x2') }))
  } finally { $sha.Dispose() }
}

function Get-H7FixtureContract([string]$StateRoot,[string]$TaskId = '',[string]$WorkspaceKey = '') {
  $normalizedWorkspaceKey = Get-H7FixtureWorkspaceKey $WorkspaceKey
  $pointer = Join-Path $StateRoot 'workspace\last-execution-contract.json'
  $matchesScope = {
    param($Contract)
    if (-not $Contract) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($TaskId) -and [string]$Contract.taskId -ne $TaskId) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($normalizedWorkspaceKey) -and [string]$Contract.workspaceKey -ne $normalizedWorkspaceKey) { return $false }
    return $true
  }
  if (Test-Path -LiteralPath $pointer -PathType Leaf) {
    try {
      $pointed = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointer | ConvertFrom-Json
      if (& $matchesScope $pointed) { return $pointed }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($WorkspaceKey)) { return $null }
  $contractsRoot = Join-Path $StateRoot 'workspace\runtime-state\execution-contracts'
  if (-not (Test-Path -LiteralPath $contractsRoot -PathType Container)) { return $null }
  $matches = @()
  foreach ($path in @(Get-ChildItem -LiteralPath $contractsRoot -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
    try {
      $candidate = Get-Content -Raw -Encoding UTF8 -LiteralPath $path.FullName | ConvertFrom-Json
      if (& $matchesScope $candidate) { $matches += $candidate }
    } catch {}
  }
  if ($matches.Count -eq 1) { return $matches[0] }
  return $null
}

function Get-H7FixtureHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
}

function Get-H7FixtureFileHash([string]$Path) {
  $stream = $null
  $sha = $null
  try {
    $stream = [IO.File]::Open(
      [IO.Path]::GetFullPath($Path),
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::ReadWrite
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    return -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
  } finally {
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Add-H7FixtureCheckpoint([hashtable]$Parameters,[string]$Root) {
  # Test-only fixture builder. It keeps Pester's direct contract tests inside
  # the same H7 invariant as production: each synthetic visible progress
  # update carries an assistant source, exact scope fields, and a live local
  # project proof. It never changes package or user state.
  if (-not $Parameters.ContainsKey('StateRoot')) { return }
  $stateRoot = [string]$Parameters.StateRoot
  if ([string]::IsNullOrWhiteSpace($stateRoot)) { return }
  $projectRoot = if ($Parameters.ContainsKey('ProjectRoot') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.ProjectRoot)) {
    [IO.Path]::GetFullPath([string]$Parameters.ProjectRoot)
  } else {
    Join-Path $stateRoot 'h7-fixture-project'
  }
  $Parameters.ProjectRoot = $projectRoot
  if ([string]$Parameters.Action -ne 'Set') { return }
  $hasCheckpoint = ($Parameters.ContainsKey('ProgressCheckpointBase64') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.ProgressCheckpointBase64))
  $hasProof = ($Parameters.ContainsKey('ProjectProgressProofBase64') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.ProjectProgressProofBase64))
  if ($hasCheckpoint -and $hasProof) { return }
  $taskId = if ($Parameters.ContainsKey('TaskId')) { [string]$Parameters.TaskId } else { 'fixture-task' }
  $workspaceKey = if ($Parameters.ContainsKey('WorkspaceKey')) { Get-H7FixtureWorkspaceKey ([string]$Parameters.WorkspaceKey) } else { '' }
  $existing = Get-H7FixtureContract $stateRoot $taskId $workspaceKey
  # The checkpoint is a continuation proof, not a request to repeat an old
  # phase label.  Preserve an existing phase unless the test explicitly asks
  # to transition it; this avoids making an unrelated next-action update look
  # like a formal stage transition.
  $phase = if ($Parameters.ContainsKey('CurrentPhase') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.CurrentPhase)) { [string]$Parameters.CurrentPhase } elseif ($existing -and $existing.PSObject.Properties['currentPhase']) { [string]$existing.currentPhase } elseif ($Parameters.ContainsKey('InstructionMode')) { [string]$Parameters.InstructionMode } else { 'fixture' }
  $nextAction = if ($Parameters.ContainsKey('NextAction') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.NextAction)) { [string]$Parameters.NextAction } elseif ($existing -and $existing.PSObject.Properties['nextAction']) { [string]$existing.nextAction } else { '' }
  $currentStep = if ($Parameters.ContainsKey('CurrentStep') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.CurrentStep)) { [string]$Parameters.CurrentStep } elseif ($existing -and $existing.PSObject.Properties['currentStep']) { [string]$existing.currentStep } else { $nextAction }
  if ([string]::IsNullOrWhiteSpace($phase) -or [string]::IsNullOrWhiteSpace($currentStep) -or [string]::IsNullOrWhiteSpace($nextAction)) { return }
  $completed = if ($Parameters.ContainsKey('CompletedSteps')) { @($Parameters.CompletedSteps) } elseif ($existing -and $existing.PSObject.Properties['completedSteps']) { @($existing.completedSteps) } else { @() }
  # Canonical mutation tests can change the completed checklist implicitly.
  # Mirror only the prospective item-status delta in the fixture proof so the
  # contract validates the same post-mutation state it is about to persist.
  if ($Parameters.ContainsKey('CanonicalMutationPath') -and $existing -and $existing.PSObject.Properties['canonicalPlan']) {
    try {
      $mutation = Get-Content -Raw -Encoding UTF8 -LiteralPath ([string]$Parameters.CanonicalMutationPath) | ConvertFrom-Json
      $targetIds = @($mutation.targetItemIds | ForEach-Object { [string]$_ })
      $targetLabels = @($existing.canonicalPlan.items | Where-Object { $targetIds -contains [string]$_.itemId } | ForEach-Object { [string]$_.label })
      $candidateFocus = if ($Parameters.ContainsKey('FocusId') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.FocusId)) { [string]$Parameters.FocusId } else { [string]$existing.focusId }
      $canonicalRootIsActive = ($candidateFocus -eq [string]$existing.canonicalPlan.rootFocusId)
      if ([string]$mutation.operation -eq 'set_status') {
        if ([string]$mutation.status -eq 'completed' -and $canonicalRootIsActive) {
          $completed = @($completed + $targetLabels | Select-Object -Unique)
        } elseif ($targetLabels.Count -gt 0 -and $canonicalRootIsActive) {
          $completed = @($completed | Where-Object { $targetLabels -notcontains [string]$_ })
        }
      } elseif ([string]$mutation.operation -eq 'replace_canonical') {
        $completed = @($mutation.items | Where-Object { [string]$_.status -eq 'completed' } | ForEach-Object { [string]$_.label })
      }
    } catch {
      # Let the production mutation validator report malformed input. The
      # fixture must not invent a completion mapping for an unreadable envelope.
    }
  }
  New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
  $evidenceText = 'phase=' + $phase + ';step=' + $currentStep + ';next=' + $nextAction
  # Never rewrite an evidence file already bound to a parent/side proof:
  # parent resumption revalidates its own historical live file hash.
  $evidenceName = 'h7-fixture-evidence-' + (Get-H7FixtureHash $evidenceText).Substring(0,16) + '.txt'
  $evidencePath = Join-Path $projectRoot $evidenceName
  [IO.File]::WriteAllText($evidencePath,$evidenceText,[Text.UTF8Encoding]::new($false))
  $hash = Get-H7FixtureFileHash $evidencePath
  $evidenceRef = 'project:file:' + $evidenceName + '@sha256:' + $hash
  $verificationId = 'h7_fixture_proof_passed'
  $completedItems = @($completed | ForEach-Object {
    [ordered]@{itemKey=[string]$_;evidenceRefs=@($evidenceRef);verificationIds=@($verificationId)}
  })
  [object[]]$verification = @()
  if ($completedItems.Count -gt 0) { $verification = @([pscustomobject]@{id=$verificationId;status='passed'}) }
  $proof = [ordered]@{
    schema='super-brain.project-progress-input.v1'
    phase=$phase
    currentStep=$currentStep
    completedItems=$completedItems
    projectEvidence=@([ordered]@{kind='project_file';relativePath=$evidenceName;sha256=$hash})
    verificationResults=@($verification)
    nextAction=$nextAction
  } | ConvertTo-Json -Depth 12 -Compress
  $sentence = if ($Parameters.ContainsKey('LastConfirmedSentence') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.LastConfirmedSentence)) {
    [string]$Parameters.LastConfirmedSentence
  } elseif ($existing -and $existing.PSObject.Properties['lastConfirmedSentence'] -and -not [string]::IsNullOrWhiteSpace([string]$existing.lastConfirmedSentence)) {
    [string]$existing.lastConfirmedSentence
  } else {
    'H7 fixture published progress for ' + $taskId + '.'
  }
  $checkpoint = [ordered]@{
    last_confirmed_sentence=$sentence
    source='assistant_visible_reply'
    current_phase=$phase
    current_step=$currentStep
    next_action=$nextAction
  } | ConvertTo-Json -Compress
  # A fixture may intentionally exercise an explicit proof input. Do not
  # overwrite it; synthesize only the missing H7 transport half.
  $Parameters.ProjectRoot = $projectRoot
  if (-not $hasProof) { $Parameters.ProjectProgressProofBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($proof)) }
  if (-not $hasCheckpoint) { $Parameters.ProgressCheckpointBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($checkpoint)) }
  if (-not $Parameters.ContainsKey('TransitionId') -or [string]::IsNullOrWhiteSpace([string]$Parameters.TransitionId)) {
    $transitionPayload = [ordered]@{
      taskId = $taskId
      workspaceKey = $workspaceKey
      priorRevision = if ($existing -and $existing.PSObject.Properties['revision']) { [int]$existing.revision } else { 0 }
      focusId = if ($Parameters.ContainsKey('FocusId')) { [string]$Parameters.FocusId } else { '' }
      instructionMode = if ($Parameters.ContainsKey('InstructionMode')) { [string]$Parameters.InstructionMode } else { '' }
      latestUserInstruction = if ($Parameters.ContainsKey('LatestUserInstruction')) { [string]$Parameters.LatestUserInstruction } else { '' }
      phase = $phase
      currentStep = $currentStep
      nextAction = $nextAction
      sentence = $sentence
      completedSteps = if ($Parameters.ContainsKey('CompletedSteps')) { @($Parameters.CompletedSteps) } else { @() }
      pendingSteps = if ($Parameters.ContainsKey('PendingSteps')) { @($Parameters.PendingSteps) } else { @() }
    }
    $Parameters.TransitionId = 'h7-fixture-' + (Get-H7FixtureHash ($transitionPayload | ConvertTo-Json -Depth 8 -Compress)).Substring(0,16)
  }
}

function ConvertFrom-H7FixtureArgumentList([string[]]$Arguments) {
  $parameters = @{}
  $switchNames = @(
    'RebindSession','RetainForMerge','RequiresReconciliation','RequireStructuralGuards',
    'EnableCanonicalPlan','RequireCanonicalPlanSource','NoExit','Json'
  )
  $listNames = @(
    'CompletedSteps','PendingSteps','Blockers','Evidence','VerificationResults','Constraints',
    'InvalidatedWorkItems','AcceptanceCriteria','ArtifactRefs','InterfaceContracts','Dependencies',
    'VerificationSteps','MergeConditions','TopicKeys'
  )
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $token = [string]$Arguments[$index]
    if (-not $token.StartsWith('-')) { continue }
    $name = $token.TrimStart('-')
    if ($switchNames -contains $name) {
      $parameters[$name] = $true
      continue
    }
    if ($listNames -contains $name) {
      $values = @()
      while (($index + 1) -lt $Arguments.Count -and -not ([string]$Arguments[$index + 1]).StartsWith('-')) {
        $index++
        $values += [string]$Arguments[$index]
      }
      $parameters[$name] = @($values)
      continue
    }
    if (($index + 1) -lt $Arguments.Count -and -not ([string]$Arguments[$index + 1]).StartsWith('-')) {
      $index++
      $parameters[$name] = [string]$Arguments[$index]
    } else {
      $parameters[$name] = $true
    }
  }
  return $parameters
}

function Add-H7FixtureCheckpointArguments([string[]]$Arguments,[string]$Root) {
  $parameters = ConvertFrom-H7FixtureArgumentList $Arguments
  Add-H7FixtureCheckpoint -Parameters $parameters -Root $Root
  $result = @($Arguments)
  foreach ($name in @('ProjectRoot','ProjectProgressProofBase64','ProgressCheckpointBase64','TransitionId')) {
    $alreadyBound = @($Arguments | Where-Object { [string]$_ -ieq ('-' + $name) }).Count -gt 0
    if (-not $alreadyBound -and $parameters.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$parameters[$name])) {
      $result += '-' + $name
      $result += [string]$parameters[$name]
    }
  }
  return @($result)
}

function Invoke-H7FixtureContractScript([string]$ContractScript,[string]$Root,[string[]]$Arguments) {
  # Test-only escape hatch for a deliberate negative legacy/no-checkpoint
  # assertion.  Normal Set calls always use the exact same H7 checkpoint and
  # proof transport as production; this switch is never forwarded to the
  # contract script.
  $skipFixtureCheckpoint = $false
  $contractArguments = @()
  foreach ($argument in @($Arguments)) {
    if ([string]$argument -eq '-H7FixtureSkipCheckpoint') {
      $skipFixtureCheckpoint = $true
      continue
    }
    $contractArguments += [string]$argument
  }
  $parameters = ConvertFrom-H7FixtureArgumentList $contractArguments
  if (-not $skipFixtureCheckpoint) { Add-H7FixtureCheckpoint -Parameters $parameters -Root $Root }
  $parameters.NoExit = $true
  $parameters.Json = $true
  $raw = @(& $ContractScript @parameters 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{
    exitCode = if ($value -and $value.ok -eq $true) { 0 } else { 1 }
    value = $value
    text = $text
  }
}
