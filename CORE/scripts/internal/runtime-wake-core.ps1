function Limit-SuperBrainRuntimeWakeText([string]$Value,[int]$Max=1200) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Max -le 0) { return '' }
  $clean = ([string]$Value).Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant() -replace '\s+',' '
  if ($clean.Length -le $Max) { return $clean }
  $headLength = [Math]::Max(1,[int]($Max * 0.75))
  $tailLength = [Math]::Max(0,$Max - $headLength)
  return $clean.Substring(0,$headLength) + $(if($tailLength -gt 0){$clean.Substring($clean.Length-$tailLength)}else{''})
}

function Protect-SuperBrainRuntimeWakeInstruction([string]$Value,[int]$Max=480) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { $clean = $clean.Substring(0,$Max) }
  if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
  $clean = $clean -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*','Bearer [REDACTED]'
  $clean = $clean -replace '(?i)\bsk-[A-Za-z0-9_-]{8,}\b','[REDACTED_KEY]'
  $clean = $clean -replace '(?i)\b(api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+','$1=[REDACTED]'
  return $clean
}

function Test-SuperBrainRuntimeWakeSensitiveText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ([string]$Value) -match '(?i)(?:\[redacted(?:_key)?\]|\bbearer\s+[a-z0-9._~+/-]+=*|\bsk-[a-z0-9_-]{8,}\b|\b(?:api[_ -]?key|password|passwd|token|secret)\s*[:=])'
}

function Get-SuperBrainRuntimeWakeSafeHotValue([string]$Value,[int]$Max=1200) {
  $protected = Protect-SuperBrainRuntimeWakeInstruction $Value $Max
  if ([string]::IsNullOrWhiteSpace($protected) -or (Test-SuperBrainRuntimeWakeSensitiveText $protected)) { return '' }
  return Limit-SuperBrainRuntimeWakeText $protected $Max
}

if (-not $script:SuperBrainRuntimeWakeStopTerms) {
  $script:SuperBrainRuntimeWakeStopTerms = @{}
  $stopTerms = @(
    'a','an','and','are','as','at','be','been','but','by','can','could','do','does','for','from','had','has','have',
    'how','i','if','in','into','is','it','its','may','more','must','no','not','of','on','or','our','should','so',
    'that','the','their','then','there','these','they','this','to','use','used','using','we','what','when','where',
    'which','will','with','would','you','your','action','current','feature','plan','project','system','task','user','work'
  )
  foreach ($term in $stopTerms) { $script:SuperBrainRuntimeWakeStopTerms[[string]$term] = $true }
  $script:SuperBrainRuntimeWakeCjkStopPattern = '^(?:\u4e00\u4e2a|\u4e00\u4e9b|\u8fd9\u4e2a|\u90a3\u4e2a|\u8fd9\u4e9b|\u90a3\u4e9b|\u8fd9\u91cc|\u90a3\u91cc|\u8fd9\u6837|\u90a3\u6837|\u6211\u4eec|\u4f60\u4eec|\u4ed6\u4eec|\u7136\u540e|\u73b0\u5728|\u5f53\u524d|\u5df2\u7ecf|\u8fd8\u662f|\u5c31\u662f|\u4e0d\u662f|\u9700\u8981|\u5e94\u8be5|\u53ef\u4ee5|\u53ef\u80fd|\u8fdb\u884c|\u5b8c\u6210|\u7ee7\u7eed|\u5904\u7406|\u76f8\u5173|\u5de5\u4f5c|\u4efb\u52a1|\u7cfb\u7edf|\u7528\u6237|\u95ee\u9898|\u4fee\u6539|\u68c0\u67e5|\u4f7f\u7528|\u5b9e\u73b0|\u529f\u80fd|\u9879\u76ee|\u4e8b\u60c5|\u5730\u65b9|\u4ec0\u4e48|\u600e\u4e48|\u5982\u4f55|\u4ee5\u53ca|\u6216\u8005|\u6ca1\u6709)$'
}

function Test-SuperBrainRuntimeWakeStopTerm([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $term = $Value.ToLowerInvariant()
  if (Test-SuperBrainRuntimeWakeSensitiveText $term) { return $true }
  if ($script:SuperBrainRuntimeWakeStopTerms.ContainsKey($term)) { return $true }
  $first = [int]$term[0]
  if ($first -lt 0x3400 -or $first -gt 0x9fff) { return $false }
  return [regex]::IsMatch($term,$script:SuperBrainRuntimeWakeCjkStopPattern)
}

function Get-SuperBrainRuntimeWakeTerms([object[]]$Values,[int]$MaxTerms=48) {
  if ($MaxTerms -le 0) { return @() }
  $scores = @{}
  $sourceIndex = 0
  foreach ($raw in @($Values)) {
    $text = Get-SuperBrainRuntimeWakeSafeHotValue ([string]$raw) 1200
    if ([string]::IsNullOrWhiteSpace($text)) { $sourceIndex++; continue }
    $sourceWeight = [Math]::Max(1,8-$sourceIndex)
    foreach ($match in [regex]::Matches($text,'(?<![a-z0-9])[a-z][a-z0-9._-]{2,}(?![a-z0-9])')) {
      $term = [string]$match.Value
      if ($term.Length -gt 32 -or (Test-SuperBrainRuntimeWakeStopTerm $term)) { continue }
      if ($scores.ContainsKey($term)) { $scores[$term] += $sourceWeight + [Math]::Min(8,$term.Length) }
      else { $scores[$term] = $sourceWeight + [Math]::Min(8,$term.Length) }
    }
    foreach ($match in [regex]::Matches($text,'[\u3400-\u9fff]{2,}')) {
      $run = [string]$match.Value
      if ($run.Length -le 12 -and -not (Test-SuperBrainRuntimeWakeStopTerm $run)) {
        if ($scores.ContainsKey($run)) { $scores[$run] += $sourceWeight + [Math]::Min(8,$run.Length) }
        else { $scores[$run] = $sourceWeight + [Math]::Min(8,$run.Length) }
      }
      $maxN = [Math]::Min(4,$run.Length)
      for ($n=2; $n -le $maxN; $n++) {
        for ($offset=0; $offset -le ($run.Length-$n); $offset++) {
          $term = $run.Substring($offset,$n)
          if (Test-SuperBrainRuntimeWakeStopTerm $term) { continue }
          if ($scores.ContainsKey($term)) { $scores[$term] += $sourceWeight + $n }
          else { $scores[$term] = $sourceWeight + $n }
        }
      }
    }
    $sourceIndex++
  }
  return @($scores.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{term=[string]$_.Key;score=[int]$_.Value;length=([string]$_.Key).Length}
  } | Sort-Object score,length,term -Descending | Select-Object -First $MaxTerms -ExpandProperty term)
}

function Test-SuperBrainRuntimeWakePhraseMatch([string]$Prompt,[string]$Term) {
  $promptText = Limit-SuperBrainRuntimeWakeText $Prompt 1200
  return Test-SuperBrainRuntimeWakeNormalizedPhraseMatch $promptText $Term
}

function Test-SuperBrainRuntimeWakeNormalizedPhraseMatch([string]$PromptText,[string]$Term) {
  if ([string]::IsNullOrWhiteSpace($Term)) { return $false }
  $termText = ([string]$Term).Trim().ToLowerInvariant()
  if ($termText.Length -gt 96) { $termText = $termText.Substring(0,96) }
  if ([string]::IsNullOrWhiteSpace($promptText) -or [string]::IsNullOrWhiteSpace($termText)) { return $false }
  $offset = 0
  while ($offset -lt $promptText.Length) {
    $match = $promptText.IndexOf($termText,$offset,[StringComparison]::Ordinal)
    if ($match -lt 0) { return $false }
    $beforeOk = ($match -eq 0 -or -not [char]::IsLetterOrDigit($promptText[$match-1]))
    $afterIndex = $match + $termText.Length
    $afterOk = ($afterIndex -ge $promptText.Length -or -not [char]::IsLetterOrDigit($promptText[$afterIndex]))
    if ($beforeOk -and $afterOk) { return $true }
    $offset = $match + 1
  }
  return $false
}

function Get-SuperBrainRuntimeWakePromptTermSet([string]$Prompt) {
  $terms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  if ([string]::IsNullOrWhiteSpace($Prompt)) { return ,$terms }
  $text = ([string]$Prompt).Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
  if ($text.Length -gt 1200) { $text = $text.Substring(0,1200) }
  if ([string]::IsNullOrWhiteSpace($text)) { return $terms }
  $asciiStart = -1
  $cjkStart = -1
  for ($index=0; $index -le $text.Length; $index++) {
    $code = if($index -lt $text.Length){[int]$text[$index]}else{-1}
    $asciiToken = (($code -ge 0x61 -and $code -le 0x7a) -or ($code -ge 0x30 -and $code -le 0x39) -or $code -in @(0x2e,0x5f,0x2d))
    $cjkToken = ($code -ge 0x3400 -and $code -le 0x9fff)
    if ($asciiToken) {
      if ($asciiStart -lt 0) { $asciiStart = $index }
    } elseif ($asciiStart -ge 0) {
      $term = $text.Substring($asciiStart,$index-$asciiStart)
      if ($term.Length -ge 3 -and $term.Length -le 32 -and $term[0] -ge 'a' -and $term[0] -le 'z' -and -not (Test-SuperBrainRuntimeWakeStopTerm $term)) { [void]$terms.Add($term) }
      $asciiStart = -1
    }
    if ($cjkToken) {
      if ($cjkStart -lt 0) { $cjkStart = $index }
    } elseif ($cjkStart -ge 0) {
      $run = $text.Substring($cjkStart,$index-$cjkStart)
      if ($run.Length -le 12 -and -not (Test-SuperBrainRuntimeWakeStopTerm $run)) { [void]$terms.Add($run) }
      $maxN = [Math]::Min(4,$run.Length)
      for ($n=2; $n -le $maxN; $n++) {
        for ($offset=0; $offset -le ($run.Length-$n); $offset++) {
          $term = $run.Substring($offset,$n)
          if (-not (Test-SuperBrainRuntimeWakeStopTerm $term)) { [void]$terms.Add($term) }
        }
      }
      $cjkStart = -1
    }
  }
  return ,$terms
}

function New-SuperBrainRuntimeWakeLine(
  [string]$FocusId,
  [string]$FocusLabel,
  [string]$Role,
  [object[]]$TopicKeys,
  [string]$CurrentStep='',
  [string]$NextAction='',
  [string]$AssistantCommitment='',
  [string]$LatestInstruction='',
  [string]$MergeIntentId=''
) {
  $topics = @($TopicKeys | ForEach-Object { Get-SuperBrainRuntimeWakeSafeHotValue ([string]$_) 64 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique -First 8)
  $derived = @(Get-SuperBrainRuntimeWakeTerms @($FocusLabel,$CurrentStep,$NextAction,$AssistantCommitment,$LatestInstruction) 48)
  $terms = @($topics + $derived | Select-Object -Unique -First 56)
  return [pscustomobject]@{
    focusId = Limit-SuperBrainRuntimeWakeText $FocusId 120
    focusLabel = Limit-SuperBrainRuntimeWakeText $FocusLabel 120
    role = Limit-SuperBrainRuntimeWakeText $Role 24
    mergeIntentId = Limit-SuperBrainRuntimeWakeText $MergeIntentId 80
    topicKeys = @($topics)
    wakeTerms = @($terms)
  }
}

function New-SuperBrainRuntimeWakeEntry([object]$Contract) {
  if (-not $Contract) { return $null }
  $nextAction = if ($Contract.PSObject.Properties['nextAction']) { [string]$Contract.nextAction } else { '' }
  $explicitNoAction = -not [string]::IsNullOrWhiteSpace($nextAction) -and $nextAction.Trim().StartsWith('No automatic action:',[StringComparison]::OrdinalIgnoreCase)
  $wakeEligible = ([string]$Contract.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$Contract.focusId) -and -not [string]::IsNullOrWhiteSpace($nextAction) -and -not $explicitNoAction)
  $lines = @()
  foreach ($card in @($Contract.returnStack)) {
    $lines += New-SuperBrainRuntimeWakeLine ([string]$card.focusId) ([string]$card.focusLabel) 'suspended' @($card.topicKeys) ([string]$card.currentStep) ([string]$card.nextAction) ([string]$card.assistantCommitment)
  }
  $lines += New-SuperBrainRuntimeWakeLine ([string]$Contract.focusId) ([string]$Contract.focusLabel) 'active' @($Contract.topicKeys) ([string]$Contract.currentStep) ([string]$Contract.nextAction) ([string]$Contract.assistantCommitment) ([string]$Contract.latestUserInstruction)
  foreach ($card in @($Contract.unfinishedWorkPlans)) {
    if (@($lines | Where-Object { [string]$_.focusId -eq [string]$card.focusId }).Count -gt 0) { continue }
    $lines += New-SuperBrainRuntimeWakeLine ([string]$card.focusId) ([string]$card.focusLabel) 'unfinished' @($card.topicKeys) ([string]$card.currentStep) ([string]$card.nextAction) ([string]$card.assistantCommitment)
  }
  foreach ($intent in @($Contract.mergeIntents)) {
    if ([string]$intent.status -notin @('waiting_for_target','ready_for_review')) { continue }
    if (@($lines | Where-Object { [string]$_.focusId -eq [string]$intent.sourceFocusId }).Count -gt 0) { continue }
    $lines += New-SuperBrainRuntimeWakeLine ([string]$intent.sourceFocusId) ([string]$intent.sourceFocusLabel) 'merge_waiting' @($intent.topicKeys) 'read retained branch dossier before integration' 'prepare one bounded merge from existing artifacts' 'do not reimplement retained branch' ([string]$intent.sourceObjective) ([string]$intent.mergeIntentId)
  }
  return [pscustomobject]@{
    taskId = [string]$Contract.taskId
    workspaceKey = [string]$Contract.workspaceKey
    ownerSessionKey = [string]$Contract.ownerSessionKey
    packageVersion = [string]$Contract.packageVersion
    revision = [int]$Contract.revision
    status = [string]$Contract.status
    wakeEligible = $wakeEligible
    focusId = [string]$Contract.focusId
    focusLabel = [string]$Contract.focusLabel
    canonicalPlanId = if($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan){Limit-SuperBrainRuntimeWakeText ([string]$Contract.canonicalPlan.planId) 80}else{''}
    canonicalGeneration = if($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan){[int]$Contract.canonicalPlan.generation}else{0}
    canonicalFingerprint = if($Contract.PSObject.Properties['canonicalPlan'] -and $Contract.canonicalPlan){Limit-SuperBrainRuntimeWakeText ([string]$Contract.canonicalPlan.currentFingerprint) 32}else{''}
    contractFileName = if($Contract.PSObject.Properties['path']){Split-Path -Leaf ([string]$Contract.path)}else{''}
    lineCount = @($lines).Count
    lines = @($lines)
    updatedAt = [string]$Contract.updatedAt
    rawPromptStored = $false
    memoryBodyStored = $false
    executableActionStored = $false
  }
}

function Get-SuperBrainRuntimeWakeIndexPath([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($MemoryBase) -or [string]::IsNullOrWhiteSpace($SessionKey) -or [string]::IsNullOrWhiteSpace($WorkspaceKey)) { return '' }
  $session = Get-SuperBrainHostSessionKey $SessionKey
  $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($workspace)) { return '' }
  return Join-Path (Join-Path $MemoryBase 'workspace\runtime-state\execution-hot-index') ($session+'--'+$workspace+'.json')
}

function Get-SuperBrainPromptHookTelemetryPath([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($MemoryBase)) { return '' }
  $session = Get-SuperBrainHostSessionKey $SessionKey
  $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($workspace)) { return '' }
  return Join-Path (Join-Path $MemoryBase 'workspace\runtime-state\prompt-hook-telemetry') ($session+'--'+$workspace+'.json')
}

function Read-SuperBrainRuntimeWakeIndex([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey) {
  $path = Get-SuperBrainRuntimeWakeIndexPath $MemoryBase $SessionKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    $value = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    if ([string]$value.schema -ne 'super-brain.execution-hot-index.v1') { return $null }
    return $value
  } catch { return $null }
}

function Write-SuperBrainRuntimeWakeJsonUnlocked([string]$Path,[object]$Value) {
  Write-SuperBrainRuntimeWakeTextUnlocked $Path ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Write-SuperBrainRuntimeWakeTextUnlocked([string]$Path,[string]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $temporary = Join-Path $directory ('.execution-hot-index-'+[guid]::NewGuid().ToString('n')+'.tmp')
  $backup = Join-Path $directory ('.execution-hot-index-'+[guid]::NewGuid().ToString('n')+'.bak')
  try {
    [IO.File]::WriteAllText($temporary,$Value,[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,$backup) }
    else { [IO.File]::Move($temporary,$Path) }
  } finally {
    if ([IO.File]::Exists($temporary)) { try { [IO.File]::Delete($temporary) } catch {} }
    if ([IO.File]::Exists($backup)) { try { [IO.File]::Delete($backup) } catch {} }
  }
}

function Get-SuperBrainRuntimeWakeRecoveryPath([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey,[string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($MemoryBase) -or [string]::IsNullOrWhiteSpace($TaskId)) { return '' }
  $session = Get-SuperBrainHostSessionKey $SessionKey
  $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($workspace)) { return '' }
  $safeTask = (([string]$TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safeTask)) { $safeTask = 'task' }
  return Join-Path (Join-Path $MemoryBase 'workspace\runtime-state\hot-index-recovery') ($session+'--'+$workspace+'--'+$safeTask+'.json')
}

function Remove-SuperBrainRuntimeWakeRecoveryMarker([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey,[string]$TaskId) {
  $path = Get-SuperBrainRuntimeWakeRecoveryPath $MemoryBase $SessionKey $WorkspaceKey $TaskId
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  if (Test-Path -LiteralPath $path -PathType Leaf) { try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch {} }
}

function Write-SuperBrainRuntimeWakeRecoveryMarker([string]$MemoryBase,[object]$Contract,[string]$Code='RUNTIME_WAKE_HOT_INDEX_SYNC_FAILED') {
  $entry = New-SuperBrainRuntimeWakeEntry $Contract
  if (-not $entry) { return $false }
  $path = Get-SuperBrainRuntimeWakeRecoveryPath $MemoryBase ([string]$entry.ownerSessionKey) ([string]$entry.workspaceKey) ([string]$entry.taskId)
  if ([string]::IsNullOrWhiteSpace($path)) { return $false }
  try {
    $marker = [pscustomobject]@{
      schema = 'super-brain.execution-hot-index-recovery.v1'
      taskId = [string]$entry.taskId
      workspaceKey = [string]$entry.workspaceKey
      ownerSessionKey = [string]$entry.ownerSessionKey
      packageVersion = [string]$entry.packageVersion
      revision = [int]$entry.revision
      contractFileName = [string]$entry.contractFileName
      status = 'pending_rebuild'
      code = Limit-SuperBrainRuntimeWakeText $Code 80
      updatedAt = [string]$entry.updatedAt
      rawPromptStored = $false
      memoryBodyStored = $false
      executableActionStored = $false
    }
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    Invoke-SuperBrainFileLock $path { Write-SuperBrainRuntimeWakeJsonUnlocked $path $marker; return $true } 5000 120 | Out-Null
    return $true
  } catch { return $false }
}

function Restore-SuperBrainRuntimeWakeRecovery([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey) {
  $session = Get-SuperBrainHostSessionKey $SessionKey
  $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($workspace)) { return $null }
  $root = Join-Path $MemoryBase 'workspace\runtime-state\hot-index-recovery'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
  $pattern = $session+'--'+$workspace+'--*.json'
  $markers = @(Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8)
  if ($markers.Count -eq 0) { return $null }
  $contractRoot = Join-Path $MemoryBase 'workspace\runtime-state\execution-contracts'
  $restored = $false
  foreach ($markerFile in $markers) {
    try {
      $marker = Get-Content -Raw -Encoding UTF8 -LiteralPath $markerFile.FullName | ConvertFrom-Json
      if ([string]$marker.schema -ne 'super-brain.execution-hot-index-recovery.v1' -or [string]$marker.status -ne 'pending_rebuild' -or [string]$marker.ownerSessionKey -ne $session -or [string]$marker.workspaceKey -ne $workspace) { continue }
      $name = Split-Path -Leaf ([string]$marker.contractFileName)
      $contractPath = Join-Path $contractRoot $name
      if ([string]::IsNullOrWhiteSpace($name) -or -not (Test-SuperBrainChildPath $contractRoot $contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) { continue }
      $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $contractPath | ConvertFrom-Json
      if ([string]$contract.schema -ne 'super-brain.execution-contract.v1' -or [string]$contract.status -ne 'active' -or [string]$contract.taskId -ne [string]$marker.taskId -or [string]$contract.ownerSessionKey -ne $session -or [string]$contract.workspaceKey -ne $workspace) { continue }
      $index = Write-SuperBrainRuntimeWakeEntry $MemoryBase $contract
      if ($index) { Remove-Item -LiteralPath $markerFile.FullName -Force -ErrorAction SilentlyContinue; $restored = $true }
    } catch {}
  }
  if ($restored) { return Read-SuperBrainRuntimeWakeIndex $MemoryBase $session $workspace }
  return $null
}

function Sync-SuperBrainRuntimeWakeEntry([string]$MemoryBase,[object]$Contract,[string]$Code='RUNTIME_WAKE_HOT_INDEX_SYNC_FAILED') {
  $entry = New-SuperBrainRuntimeWakeEntry $Contract
  if (-not $entry) { return [pscustomobject]@{ok=$false;state='not_applicable';code='RUNTIME_WAKE_HOT_INDEX_NOT_APPLICABLE'} }
  foreach ($attempt in 1..2) {
    try {
      $index = Write-SuperBrainRuntimeWakeEntry $MemoryBase $Contract
      if ($index) {
        Remove-SuperBrainRuntimeWakeRecoveryMarker $MemoryBase ([string]$entry.ownerSessionKey) ([string]$entry.workspaceKey) ([string]$entry.taskId)
        return [pscustomobject]@{ok=$true;state=if($attempt -eq 1){'synced'}else{'recovered'};code=if($attempt -eq 1){'RUNTIME_WAKE_HOT_INDEX_SYNCED'}else{'RUNTIME_WAKE_HOT_INDEX_REBUILT'};attempt=$attempt}
      }
    } catch {}
    if ($attempt -eq 1) { Start-Sleep -Milliseconds 15 }
  }
  $marked = Write-SuperBrainRuntimeWakeRecoveryMarker $MemoryBase $Contract $Code
  return [pscustomobject]@{ok=$false;state='pending_rebuild';code='RUNTIME_WAKE_HOT_INDEX_RECOVERY_PENDING';recoveryMarkerWritten=$marked}
}

function Write-SuperBrainRuntimeWakeEntry([string]$MemoryBase,[object]$Contract,[int]$MaxEntries=8) {
  $entry = New-SuperBrainRuntimeWakeEntry $Contract
  if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.ownerSessionKey)) { return $null }
  $path = Get-SuperBrainRuntimeWakeIndexPath $MemoryBase ([string]$entry.ownerSessionKey) ([string]$entry.workspaceKey)
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  return Invoke-SuperBrainFileLock $path {
    $existing = Read-SuperBrainRuntimeWakeIndex $MemoryBase ([string]$entry.ownerSessionKey) ([string]$entry.workspaceKey)
    $entries = @()
    if ($existing) {
      $entries += @($existing.entries | Where-Object {
        [string]$_.taskId -ne [string]$entry.taskId -and [string]$_.status -eq 'active' -and [string]$_.packageVersion -eq [string]$entry.packageVersion
      })
    }
    $entries += $entry
    $entries = @($entries | Sort-Object @{Expression={try{[datetime]::Parse([string]$_.updatedAt)}catch{[datetime]::MinValue}};Descending=$true} | Select-Object -First $MaxEntries)
    $value = [pscustomobject]@{
      schema = 'super-brain.execution-hot-index.v1'
      packageVersion = [string]$entry.packageVersion
      workspaceKey = [string]$entry.workspaceKey
      ownerSessionKey = [string]$entry.ownerSessionKey
      entryCount = @($entries).Count
      entries = @($entries)
      updatedAt = (Get-SuperBrainUtcTimestamp)
      rawPromptStored = $false
      memoryBodyStored = $false
      executableActionStored = $false
    }
    Write-SuperBrainRuntimeWakeJsonUnlocked $path $value
    return $value
  } 5000 120
}

function Update-SuperBrainRuntimeWakeEntryRevision([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey,[string]$TaskId,[int]$ExpectedRevision,[int]$Revision,[string]$UpdatedAt) {
  $path = Get-SuperBrainRuntimeWakeIndexPath $MemoryBase $SessionKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  return Invoke-SuperBrainFileLock $path {
    $index = Read-SuperBrainRuntimeWakeIndex $MemoryBase $SessionKey $WorkspaceKey
    if (-not $index) { return $false }
    $matched = $null
    foreach ($entry in @($index.entries)) {
      if ([string]$entry.taskId -eq $TaskId) { $matched=$entry; break }
    }
    if (-not $matched -or [int]$matched.revision -ne $ExpectedRevision) { return $false }
    $matched.revision = $Revision
    $matched.updatedAt = $UpdatedAt
    $index.updatedAt = $UpdatedAt
    Write-SuperBrainRuntimeWakeJsonUnlocked $path $index
    return $true
  } 5000 120
}

function Remove-SuperBrainRuntimeWakeEntry([string]$MemoryBase,[string]$SessionKey,[string]$WorkspaceKey,[string]$TaskId) {
  $path = Get-SuperBrainRuntimeWakeIndexPath $MemoryBase $SessionKey $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $false }
  return Invoke-SuperBrainFileLock $path {
    $existing = Read-SuperBrainRuntimeWakeIndex $MemoryBase $SessionKey $WorkspaceKey
    if (-not $existing) { return $false }
    $entries = @($existing.entries | Where-Object { [string]$_.taskId -ne $TaskId })
    if ($entries.Count -eq 0) { Remove-Item -LiteralPath $path -Force; return $true }
    $existing.entries = @($entries)
    $existing.entryCount = $entries.Count
    $existing.updatedAt = (Get-SuperBrainUtcTimestamp)
    Write-SuperBrainRuntimeWakeJsonUnlocked $path $existing
    return $true
  } 5000 120
}

function Get-SuperBrainRuntimeWakeAffinity([string]$Prompt,[object[]]$Lines) {
  $lineValues = @($Lines)
  $unknown = [pscustomobject]@{topicAffinity='unknown';targetLineId='';targetLineLabel='';confidence='none';matchedTerms=@();candidateLineIds=@();reason='no bounded hot-state affinity matched'}
  if ([string]::IsNullOrWhiteSpace($Prompt) -or $lineValues.Count -eq 0) { return $unknown }
  $promptText = ([string]$Prompt).Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
  if ($promptText.Length -gt 1200) { $promptText = $promptText.Substring(0,1200) }
  $explicitWinners = @()
  $bestExplicitScore = -1
  foreach ($line in $lineValues) {
    $matched = @()
    $seen = @{}
    $maxLength = 0
    foreach ($topic in @($line.topicKeys)) {
      $term = [string]$topic
      if ($seen.ContainsKey($term)) { continue }
      $seen[$term] = $true
      if (-not (Test-SuperBrainRuntimeWakeNormalizedPhraseMatch $promptText $term)) { continue }
      $matched += $term
      $maxLength = [Math]::Max($maxLength,$term.Length)
    }
    if ($matched.Count -gt 0) {
      $candidate = [pscustomobject]@{line=$line;matched=@($matched);score=100+($matched.Count*10)+$maxLength}
      if ($candidate.score -gt $bestExplicitScore) { $explicitWinners=@($candidate); $bestExplicitScore=$candidate.score }
      elseif ($candidate.score -eq $bestExplicitScore) { $explicitWinners += $candidate }
    }
  }
  if ($explicitWinners.Count -gt 0) {
    if ($explicitWinners.Count -eq 1) {
      $winner = $explicitWinners[0]
      return [pscustomobject]@{topicAffinity=if([string]$winner.line.role -eq 'active'){'active'}else{[string]$winner.line.role+':'+[string]$winner.line.focusId};targetLineId=[string]$winner.line.focusId;targetLineLabel=[string]$winner.line.focusLabel;confidence='high';matchedTerms=@($winner.matched);candidateLineIds=@([string]$winner.line.focusId);reason='one explicit hot topic matched uniquely'}
    }
    $terms=@{}; $ids=@{}
    foreach ($winner in $explicitWinners) { foreach ($term in @($winner.matched)) { $terms[[string]$term]=$true }; $ids[[string]$winner.line.focusId]=$true }
    return [pscustomobject]@{topicAffinity='ambiguous';targetLineId='';targetLineLabel='';confidence='low';matchedTerms=@($terms.Keys);candidateLineIds=@($ids.Keys);reason='multiple lines share the strongest explicit hot topic'}
  }

  if ($lineValues.Count -eq 1) {
    $line=$lineValues[0]; $terms=@(); $seen=@{}; $score=0
    foreach ($rawTerm in @($line.wakeTerms)) {
      $term=[string]$rawTerm
      if ($seen.ContainsKey($term)) { continue }
      $seen[$term]=$true
      if (-not (Test-SuperBrainRuntimeWakeNormalizedPhraseMatch $promptText $term)) { continue }
      $terms += $term
      $length=$term.Length
      $score += $(if($length-ge4){6}elseif($length-eq3){3}else{1})
      if ($score -ge 6 -or $terms.Count -ge 2) {
        return [pscustomobject]@{topicAffinity=if([string]$line.role -eq 'active'){'active'}else{[string]$line.role+':'+[string]$line.focusId};targetLineId=[string]$line.focusId;targetLineLabel=[string]$line.focusLabel;confidence='high';matchedTerms=@($terms);candidateLineIds=@([string]$line.focusId);reason='bounded derived hot-state terms matched one line'}
      }
    }
    if ($terms.Count -eq 0) { return $unknown }
    return [pscustomobject]@{topicAffinity=if([string]$line.role -eq 'active'){'active'}else{[string]$line.role+':'+[string]$line.focusId};targetLineId=[string]$line.focusId;targetLineLabel=[string]$line.focusLabel;confidence='medium';matchedTerms=@($terms);candidateLineIds=@([string]$line.focusId);reason='bounded derived hot-state terms matched one line'}
  }

  $frequency = @{}
  if ($lineValues.Count -gt 1) {
    foreach ($line in $lineValues) {
      $seen = @{}
      foreach ($rawTerm in @($line.wakeTerms)) {
        $term = [string]$rawTerm
        if ($seen.ContainsKey($term)) { continue }
        $seen[$term] = $true
        if ($frequency.ContainsKey($term)) { $frequency[$term]++ } else { $frequency[$term]=1 }
      }
    }
  }
  $derivedWinners = @()
  $bestDerivedScore = -1
  foreach ($line in $lineValues) {
    $terms = @()
    $seen = @{}
    $score = 0
    foreach ($rawTerm in @($line.wakeTerms)) {
      $term = [string]$rawTerm
      if ($seen.ContainsKey($term)) { continue }
      $seen[$term] = $true
      if (($lineValues.Count -ne 1 -and [int]$frequency[$term] -ne 1) -or -not (Test-SuperBrainRuntimeWakeNormalizedPhraseMatch $promptText $term)) { continue }
      $terms += $term
      $length=$term.Length
      $score += $(if($length-ge4){6}elseif($length-eq3){3}else{1})
    }
    if ($terms.Count -eq 0) { continue }
    $candidate = [pscustomobject]@{line=$line;matched=@($terms);score=$score}
    if ($score -gt $bestDerivedScore) { $derivedWinners=@($candidate); $bestDerivedScore=$score }
    elseif ($score -eq $bestDerivedScore) { $derivedWinners += $candidate }
  }
  if ($derivedWinners.Count -eq 0) { return $unknown }
  if ($derivedWinners.Count -ne 1) {
    $terms=@{}; $ids=@{}
    foreach ($winner in $derivedWinners) { foreach ($term in @($winner.matched)) { $terms[[string]$term]=$true }; $ids[[string]$winner.line.focusId]=$true }
    return [pscustomobject]@{topicAffinity='ambiguous';targetLineId='';targetLineLabel='';confidence='low';matchedTerms=@($terms.Keys);candidateLineIds=@($ids.Keys);reason='multiple lines share the strongest derived hot-state affinity'}
  }
  $winner = $derivedWinners[0]
  $confidence = if ([int]$winner.score -ge 6 -or @($winner.matched).Count -ge 2) { 'high' } else { 'medium' }
  return [pscustomobject]@{topicAffinity=if([string]$winner.line.role -eq 'active'){'active'}else{[string]$winner.line.role+':'+[string]$winner.line.focusId};targetLineId=[string]$winner.line.focusId;targetLineLabel=[string]$winner.line.focusLabel;confidence=$confidence;matchedTerms=@($winner.matched);candidateLineIds=@([string]$winner.line.focusId);reason='bounded derived hot-state terms matched one line'}
}

function Test-SuperBrainRuntimeWakeContextReference([string]$Prompt) {
  $text = Limit-SuperBrainRuntimeWakeText $Prompt 1200
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  return $text -match '(?i)(?:\b(?:this|that|it|these|those|above|earlier|just now|same one|as discussed)\b|\u8fd9\u4e2a|\u8fd9\u91cc|\u8fd9\u8fb9|\u8fd9\u6837|\u8fd9\u4e9b|\u4e0a\u8ff0|\u4e0a\u9762|\u524d\u9762|\u521a\u624d|\u521a\u521a|\u4e4b\u524d\u8bf4\u7684|\u6309\u8fd9\u4e2a|\u7167\u8fd9\u4e2a|\u8fd8\u662f\u8fd9\u4e2a)'
}

function Test-SuperBrainRuntimeWakeContextReply([string]$Prompt) {
  $text = (Limit-SuperBrainRuntimeWakeText $Prompt 80) -replace '[\s\p{P}\p{S}]+',''
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  return $text -match '^(?i:ok|okay|yes|yep|sure|confirm|confirmed|[1-9]{1,3}|[1-9]?[a-c]{1,3}|\u53ef\u4ee5|\u5bf9|\u5bf9\u7684|\u662f\u7684|\u786e\u8ba4|\u6ca1\u95ee\u9898|\u6ca1\u9519|\u597d|\u597d\u7684|\u884c|\u5c31\u8fd9\u6837|\u6309\u8fd9\u4e2a)$'
}

function Test-SuperBrainRuntimeWakeBareContinuation([string]$Prompt) {
  $text = Limit-SuperBrainRuntimeWakeText $Prompt 80
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  return $text -match '^\s*(?i:continue|resume|\u7ee7\u7eed|\u63a5\u7740|\u4e0b\u4e00\u6b65|\u8fdb\u884c\u4e0b\u4e00\u6b65|\u7ee7\u7eed\u4e0b\u4e00\u6b65)[\s\p{P}\p{S}]*$'
}

function Test-SuperBrainRuntimeWakePendingInstructionPreserved([object]$Contract,[string]$Prompt) {
  if (-not $Contract -or $Contract.needsReconciliation -ne $true) { return $false }
  if (-not (Test-SuperBrainRuntimeWakeContextReply $Prompt) -and -not (Test-SuperBrainRuntimeWakeBareContinuation $Prompt)) { return $false }
  $pending = if ($Contract.PSObject.Properties['latestUserInstruction']) { [string]$Contract.latestUserInstruction } else { '' }
  if ([string]::IsNullOrWhiteSpace($pending)) { return $false }
  return (-not (Test-SuperBrainRuntimeWakeContextReply $pending) -and -not (Test-SuperBrainRuntimeWakeBareContinuation $pending))
}

function Test-SuperBrainRuntimeWakeDeferredMergeSignal([string]$Prompt) {
  $text = Limit-SuperBrainRuntimeWakeText $Prompt 480
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  $waitSignal = $text -match '(?i)(?:\b(?:wait|defer|hold|later)\b|\u7b49\u5f85|\u7a0d\u540e|\u540e\u7eed|\u6682\u7f13|\u5f85)'
  $mergeSignal = $text -match '(?i)(?:\b(?:merge|integrat|wire\s+in|join)\b|\u5408\u5e76|\u6574\u5408|\u63a5\u5165)'
  $mainSignal = $text -match '(?i)(?:\b(?:main|parent)\b|\u4e3b\u7ebf|\u7236\u7ebf)'
  return ($mergeSignal -and ($waitSignal -or $mainSignal))
}

function Get-SuperBrainRuntimeWakeContractLine([object]$Contract,[string]$FocusId) {
  if (-not $Contract -or [string]::IsNullOrWhiteSpace($FocusId)) { return $null }
  if ([string]$Contract.focusId -eq $FocusId) { return [pscustomobject]@{focusId=$FocusId;focusLabel=[string]$Contract.focusLabel;role='active'} }
  foreach ($line in @($Contract.returnStack)) {
    if ([string]$line.focusId -eq $FocusId) { return [pscustomobject]@{focusId=$FocusId;focusLabel=[string]$line.focusLabel;role='suspended'} }
  }
  foreach ($line in @($Contract.unfinishedWorkPlans)) {
    if ([string]$line.focusId -eq $FocusId) { return [pscustomobject]@{focusId=$FocusId;focusLabel=[string]$line.focusLabel;role='unfinished'} }
  }
  foreach ($intent in @($Contract.mergeIntents)) {
    if ([string]$intent.status -in @('waiting_for_target','ready_for_review') -and [string]$intent.sourceFocusId -eq $FocusId) { return [pscustomobject]@{focusId=$FocusId;focusLabel=[string]$intent.sourceFocusLabel;role='merge_waiting';mergeIntentId=[string]$intent.mergeIntentId} }
  }
  return $null
}

function New-SuperBrainRuntimeWakeObservationClassification([object]$Contract,[object]$Decision,[string]$Prompt) {
  $activeId = [string]$Contract.focusId
  $activeLabel = [string]$Contract.focusLabel
  $contextReply = if($Decision -and $Decision.PSObject.Properties['contextReply']){[bool]$Decision.contextReply}else{Test-SuperBrainRuntimeWakeContextReply $Prompt}
  if ($contextReply) {
    return [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId=$activeId;targetLineLabel=$activeLabel;confidence='high';matchedKeys=@('context_reply_signal');candidateLineIds=@($activeId);needsClarification=$false;recommendedInstructionMode='continue';reason='a bounded contextual reply binds to the active work line';rawInstructionStored=$false}
  }
  $bareContinuation = Test-SuperBrainRuntimeWakeBareContinuation $Prompt
  if ($bareContinuation) {
    return [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId=$activeId;targetLineLabel=$activeLabel;confidence='high';matchedKeys=@('continuation_signal');candidateLineIds=@($activeId);needsClarification=$false;recommendedInstructionMode='continue';reason='bare continuation signal binds to the active work line';rawInstructionStored=$false}
  }
  $actionEntry = ($Decision -and $Decision.PSObject.Properties['actionEntrySignal'] -and $Decision.actionEntrySignal -eq $true)
  $actionKind = if($Decision -and $Decision.PSObject.Properties['actionKind']){[string]$Decision.actionKind}else{''}
  if ($actionEntry -and $actionKind -notin @('continue','next')) {
    return [pscustomobject]@{mode='action_preflight';topicAffinity='active';targetLineId=$activeId;targetLineLabel=$activeLabel;confidence='high';matchedKeys=@('critical_action_entry');candidateLineIds=@($activeId);needsClarification=$true;recommendedInstructionMode='classify';reason=('short '+$actionKind+' action requires task-scoped dependency preflight before mutation');rawInstructionStored=$false}
  }
  if (Test-SuperBrainRuntimeWakeContextReference $Prompt) {
    return [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId=$activeId;targetLineLabel=$activeLabel;confidence='high';matchedKeys=@('context_reference_signal');candidateLineIds=@($activeId);needsClarification=$false;recommendedInstructionMode='continue';reason='a bounded anaphoric reference binds to the active work line';rawInstructionStored=$false}
  }
  $affinity = if($Decision -and $Decision.PSObject.Properties['affinity']){$Decision.affinity}else{$null}
  if ($affinity -and [string]$affinity.topicAffinity -eq 'ambiguous') {
    return [pscustomobject]@{mode='ambiguous';topicAffinity='ambiguous';targetLineId='';targetLineLabel='';confidence='low';matchedKeys=@('runtime_hot_affinity');candidateLineIds=@($affinity.candidateLineIds);needsClarification=$true;recommendedInstructionMode='classify';reason=[string]$affinity.reason;rawInstructionStored=$false}
  }
  if ($affinity -and [string]$affinity.topicAffinity -ne 'unknown' -and -not [string]::IsNullOrWhiteSpace([string]$affinity.targetLineId)) {
    if ([string]$affinity.topicAffinity -eq 'active') {
      return [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId=[string]$affinity.targetLineId;targetLineLabel=[string]$affinity.targetLineLabel;confidence=[string]$affinity.confidence;matchedKeys=@('runtime_hot_affinity');candidateLineIds=@([string]$affinity.targetLineId);needsClarification=([string]$affinity.confidence-ne'high');recommendedInstructionMode='continue';reason=[string]$affinity.reason;rawInstructionStored=$false}
    }
    $line = Get-SuperBrainRuntimeWakeContractLine $Contract ([string]$affinity.targetLineId)
    if ($line) {
      $role = [string]$line.role
      $high = ([string]$affinity.confidence -eq 'high')
      return [pscustomobject]@{mode=if($role-eq'active'){'continue'}else{'line_reference'};topicAffinity=if($role-eq'active'){'active'}else{$role+':'+[string]$line.focusId};targetLineId=[string]$line.focusId;targetLineLabel=[string]$line.focusLabel;mergeIntentId=if($line.PSObject.Properties['mergeIntentId']){[string]$line.mergeIntentId}else{''};confidence=[string]$affinity.confidence;matchedKeys=@('runtime_hot_affinity');candidateLineIds=@([string]$line.focusId);needsClarification=(-not $high);recommendedInstructionMode=if($role-eq'active'){'continue'}elseif($role-eq'unfinished'){'side_branch'}elseif($role-eq'merge_waiting'){'merge_review'}else{'resume_parent'};reason=[string]$affinity.reason;rawInstructionStored=$false}
    }
  }
  $continuation = $bareContinuation -or $(if($Decision -and $Decision.PSObject.Properties['continuitySignal']){[bool]$Decision.continuitySignal}else{$false})
  if ($continuation) {
    return [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId=$activeId;targetLineLabel=$activeLabel;confidence='high';matchedKeys=@('continuation_signal');candidateLineIds=@($activeId);needsClarification=$false;recommendedInstructionMode='continue';reason='bare continuation signal binds to the active work line';rawInstructionStored=$false}
  }
  $multiple = (@($Contract.returnStack).Count + @($Contract.unfinishedWorkPlans).Count + @($Contract.mergeIntents | Where-Object { [string]$_.status -in @('waiting_for_target','ready_for_review') }).Count -gt 0)
  return [pscustomobject]@{mode='unclassified';topicAffinity='unknown';targetLineId='';targetLineLabel='';confidence='none';matchedKeys=@();candidateLineIds=@();needsClarification=$multiple;recommendedInstructionMode='classify';reason='no unique bounded runtime affinity matched';rawInstructionStored=$false}
}

function Set-SuperBrainRuntimeWakeProperty([object]$Object,[string]$Name,[object]$Value) {
  if (-not $Object) { return }
  if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Invoke-SuperBrainRuntimeWakeAnchorControl(
  [ValidateSet('observe-instruction-anchor','get-instruction-anchor','check-instruction-anchor','record-continuation-receipt','get-continuation-receipt')][string]$Action,
  [string]$MemoryBase,
  [hashtable]$Request
) {
  $packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $runtime = Join-Path $packageRoot 'runtime\brain_control.py'
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_INSTRUCTION_ANCHOR_RUNTIME_MISSING';error='brain_control.py is unavailable'}
  }
  try {
    $payload = $Request | ConvertTo-Json -Depth 10 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $raw = @(& python -X utf8 $runtime --state-root $MemoryBase $Action --request-base64 $encoded 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
      return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_INSTRUCTION_ANCHOR_PROTOCOL_INVALID';error=(Limit-SuperBrainRuntimeWakeText $text 180)}
    }
    $value = $text.Substring($start,$end-$start+1) | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $value -or $value.ok -ne $true) {
      return [pscustomobject]@{ok=$false;code=if($value -and $value.code){[string]$value.code}else{'RUNTIME_WAKE_INSTRUCTION_ANCHOR_RUNTIME_FAILED'};error=if($value -and $value.error){[string]$value.error}else{(Limit-SuperBrainRuntimeWakeText $text 180)}}
    }
    return $value
  } catch {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_INSTRUCTION_ANCHOR_RUNTIME_FAILED';error=(Limit-SuperBrainRuntimeWakeText $_.Exception.Message 180)}
  }
}

function Invoke-SuperBrainRuntimeWakeInstructionAnchorObservation(
  [string]$MemoryBase,
  [string]$WorkspaceKey,
  [string]$SessionKey,
  [object]$Contract,
  [string]$Prompt,
  [object]$Classification,
  [string]$Source='codex-user-prompt-hook.ps1',
  [switch]$RequireCanonicalPlanSource
) {
  $instruction = Protect-SuperBrainRuntimeWakeInstruction $Prompt 480
  if ([string]::IsNullOrWhiteSpace($instruction)) {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_INSTRUCTION_ANCHOR_EMPTY';error='instruction is empty'}
  }
  $boundAnchor = if ($Contract -and $Contract.PSObject.Properties['instructionAnchor']) { $Contract.instructionAnchor } else { $null }
  $preservePending = (Test-SuperBrainRuntimeWakeContextReply $Prompt) -or (Test-SuperBrainRuntimeWakeBareContinuation $Prompt)
  $signals = @{
    deferredMergeRequested=(Test-SuperBrainRuntimeWakeDeferredMergeSignal $Prompt)
    canonicalPlanSourceRequired=[bool]$RequireCanonicalPlanSource
  }
  return Invoke-SuperBrainRuntimeWakeAnchorControl 'observe-instruction-anchor' $MemoryBase @{
    taskId=[string]$Contract.taskId
    workspaceKey=(Get-SuperBrainWorkspaceKey $WorkspaceKey)
    ownerSessionKey=(Get-SuperBrainHostSessionKey $SessionKey)
    instruction=$instruction
    classification=$Classification
    signals=$signals
    source=(Limit-SuperBrainRuntimeWakeText $Source 120)
    preserveIfPending=$preservePending
    boundAnchor=$boundAnchor
  }
}

function Get-SuperBrainRuntimeWakeInstructionAnchorStatus(
  [string]$MemoryBase,
  [string]$WorkspaceKey,
  [string]$SessionKey,
  [object]$Contract,
  [string]$TaskId=''
) {
  $task = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId } elseif ($Contract) { [string]$Contract.taskId } else { '' }
  if ([string]::IsNullOrWhiteSpace($task)) { return [pscustomobject]@{ok=$true;required=$false;current=$true;code='INSTRUCTION_ANCHOR_NOT_APPLICABLE';anchor=$null} }
  $owner = if ($Contract -and $Contract.PSObject.Properties['ownerSessionKey']) { [string]$Contract.ownerSessionKey } else { Get-SuperBrainHostSessionKey $SessionKey }
  if ([string]::IsNullOrWhiteSpace($owner)) { return [pscustomobject]@{ok=$false;required=$true;current=$false;code='INSTRUCTION_ANCHOR_SESSION_REQUIRED';anchor=$null} }
  $boundAnchor = if ($Contract -and $Contract.PSObject.Properties['instructionAnchor']) { $Contract.instructionAnchor } else { $null }
  return Invoke-SuperBrainRuntimeWakeAnchorControl 'check-instruction-anchor' $MemoryBase @{
    taskId=$task
    workspaceKey=(Get-SuperBrainWorkspaceKey $WorkspaceKey)
    ownerSessionKey=$owner
    boundAnchor=$boundAnchor
  }
}

function Invoke-SuperBrainRuntimeWakeObservation(
  [string]$MemoryBase,
  [string]$WorkspaceKey,
  [string]$SessionKey,
  [string]$Prompt,
  [object]$Decision,
  [string]$Source='codex-user-prompt-hook.ps1'
) {
  if (-not $Decision -or $Decision.active -ne $true -or $Decision.ambiguous -eq $true -or [string]::IsNullOrWhiteSpace([string]$Decision.taskId)) {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_NOT_APPLICABLE';written=$false}
  }
  $entry = @()
  if ($Decision.PSObject.Properties['indexEntry'] -and [string]$Decision.indexEntry.taskId -eq [string]$Decision.taskId) { $entry = @($Decision.indexEntry) }
  if ($entry.Count -eq 0) {
    $index = Read-SuperBrainRuntimeWakeIndex $MemoryBase $SessionKey $WorkspaceKey
    $entry = @($index.entries | Where-Object { [string]$_.taskId -eq [string]$Decision.taskId } | Select-Object -First 1)
  }
  if ($entry.Count -eq 0 -and [string]$Decision.source -eq 'legacy_pointer_migration') {
    $pointerPath = Join-Path $MemoryBase 'workspace\last-execution-contract.json'
    try {
      $pointer = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerPath | ConvertFrom-Json
      $entry = @(New-SuperBrainRuntimeWakeEntry $pointer)
    } catch { $entry = @() }
  }
  if ($entry.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$entry[0].contractFileName)) {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_INDEX_MISSING';written=$false}
  }
  $contractRoot = Join-Path $MemoryBase 'workspace\runtime-state\execution-contracts'
  $contractPath = Join-Path $contractRoot ([string]$entry[0].contractFileName)
  if (-not (Test-SuperBrainChildPath $contractRoot $contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_PATH_INVALID';written=$false}
  }
  return Invoke-SuperBrainFileLock $contractPath {
    try { $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $contractPath | ConvertFrom-Json } catch { return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_CONTRACT_INVALID';written=$false} }
    $session = Get-SuperBrainHostSessionKey $SessionKey
    $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
    if ([string]$contract.schema -ne 'super-brain.execution-contract.v1' -or [string]$contract.status -ne 'active' -or [string]$contract.taskId -ne [string]$Decision.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $workspace) -or [string]$contract.ownerSessionKey -ne $session) {
      return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_IDENTITY_MISMATCH';written=$false}
    }
    try { $actualRevision = [int]$contract.revision } catch {
      return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_CONTRACT_INVALID';written=$false}
    }
    $expectedRevision = 0
    if ($Decision.PSObject.Properties['revision']) {
      try { $expectedRevision = [int]$Decision.revision } catch {
        return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_INDEX_INVALID';written=$false}
      }
    }
    if ($expectedRevision -gt 0 -and $actualRevision -ne $expectedRevision) {
      return [pscustomobject]@{ok=$false;code='RUNTIME_WAKE_FAST_OBSERVE_REVISION_MISMATCH';written=$false;expectedRevision=$expectedRevision;actualRevision=$actualRevision}
    }
    $classification = New-SuperBrainRuntimeWakeObservationClassification $contract $Decision $Prompt
    if (Test-SuperBrainRuntimeWakePendingInstructionPreserved $contract $Prompt) {
      Set-SuperBrainRuntimeWakeProperty $contract 'observationSkipped' $true
      Set-SuperBrainRuntimeWakeProperty $contract 'observationCode' 'RUNTIME_WAKE_PENDING_INSTRUCTION_PRESERVED'
      return $contract
    }
    $observation = Invoke-SuperBrainRuntimeWakeInstructionAnchorObservation $MemoryBase $WorkspaceKey $SessionKey $contract $Prompt $classification $Source
    if (-not $observation.ok -or -not $observation.anchor) {
      return [pscustomobject]@{ok=$false;code=if($observation.code){[string]$observation.code}else{'RUNTIME_WAKE_INSTRUCTION_ANCHOR_WRITE_FAILED'};written=$false}
    }
    $view = $contract | Select-Object *
    Set-SuperBrainRuntimeWakeProperty $view 'instructionAnchor' $observation.anchor
    Set-SuperBrainRuntimeWakeProperty $view 'latestUserInstruction' ([string]$observation.anchor.instruction)
    Set-SuperBrainRuntimeWakeProperty $view 'latestMessageClassification' $(if($observation.anchor.classification){$observation.anchor.classification}else{$classification})
    Set-SuperBrainRuntimeWakeProperty $view 'needsReconciliation' ([bool]$observation.pending)
    Set-SuperBrainRuntimeWakeProperty $view 'observationSkipped' ([bool]$observation.preservedPending)
    Set-SuperBrainRuntimeWakeProperty $view 'observationCode' $(if($observation.created){'RUNTIME_WAKE_INSTRUCTION_ANCHOR_APPENDED'}else{'RUNTIME_WAKE_PENDING_INSTRUCTION_PRESERVED'})
    Set-SuperBrainRuntimeWakeProperty $view 'rawPromptStored' $false
    Set-SuperBrainRuntimeWakeProperty $view 'rawTranscriptStored' $false
    Set-SuperBrainRuntimeWakeProperty $view 'rawSessionIdStored' $false
    return $view
  } 5000 120
}

function Get-SuperBrainRuntimeWakeDecision(
  [string]$MemoryBase,
  [string]$Prompt,
  [string]$WorkspaceKey,
  [string]$SessionKey,
  [object]$RouteSignals,
  [string]$PackageVersion='',
  [int]$MaxAgeHours=168
) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $index = Read-SuperBrainRuntimeWakeIndex $MemoryBase $SessionKey $WorkspaceKey
  try {
    $recoveredIndex = Restore-SuperBrainRuntimeWakeRecovery $MemoryBase $SessionKey $WorkspaceKey
    if ($recoveredIndex) { $index = $recoveredIndex }
  } catch {}
  $source = if($index){'session_workspace_hot_index'}else{'none'}
  $entries = if($index){@($index.entries)}else{@()}
  $indexedEntryCount = @($entries).Count
  $legacySignal = [bool]($RouteSignals.continuitySignal -or $RouteSignals.contextReplySignal -or $RouteSignals.hookCandidate -or $RouteSignals.explicitSuperBrain)
  if ($entries.Count -eq 0 -and $legacySignal) {
    $pointerPath = Join-Path $MemoryBase 'workspace\last-execution-contract.json'
    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
      try {
        $pointer = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerPath | ConvertFrom-Json
        $session = Get-SuperBrainHostSessionKey $SessionKey
        $workspace = Get-SuperBrainWorkspaceKey $WorkspaceKey
        if ([string]$pointer.status -eq 'active' -and [string]$pointer.ownerSessionKey -eq $session -and (Test-SuperBrainWorkspaceKey ([string]$pointer.workspaceKey) $workspace)) {
          $entries = @(New-SuperBrainRuntimeWakeEntry $pointer)
          $source = 'legacy_pointer_migration'
        }
      } catch {}
    }
  }
  $currentEntries = [Collections.Generic.List[object]]::new()
  # Keep the hot wake path self-contained. The prompt hook intentionally does
  # not load common.ps1 on every user turn, so this cannot depend on its clock helper.
  $now = [DateTimeOffset]::UtcNow
  foreach ($candidate in @($entries)) {
    if ([string]$candidate.status -ne 'active' -or $candidate.wakeEligible -ne $true) { continue }
    if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and [string]$candidate.packageVersion -ne $PackageVersion) { continue }
    try { if (($now-[DateTimeOffset]::Parse([string]$candidate.updatedAt,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()).TotalHours -gt $MaxAgeHours) { continue } } catch { continue }
    $currentEntries.Add($candidate)
  }
  $entries = @($currentEntries.ToArray())
  if ($entries.Count -gt 1 -and (Get-Command Get-SuperBrainCurrentTaskContext -ErrorAction SilentlyContinue)) {
    $context = Get-SuperBrainCurrentTaskContext (Join-Path $MemoryBase 'workspace') $WorkspaceKey
    $session = Get-SuperBrainHostSessionKey $SessionKey
    $contextMatchesScope = ($context -and [string]$context.status -eq 'active' -and $context.stale -ne $true -and [string]$context.ownerSessionKey -eq $session)
    if ($contextMatchesScope) {
      $selected = @($entries | Where-Object { [string]$_.taskId -eq [string]$context.taskId })
      if ($selected.Count -eq 1) {
        $entries = $selected
        $source = 'current_task_context_pointer'
      }
    }
  }
  if ($entries.Count -eq 0) {
    $watch.Stop()
    return [pscustomobject]@{active=$false;ambiguous=$false;shouldObserve=$false;shouldWake=$false;source=$source;taskId='';revision=0;entryCount=0;ineligibleEntryCount=$indexedEntryCount;affinity=$null;actionEntrySignal=($RouteSignals.PSObject.Properties['actionEntrySignal'] -and $RouteSignals.actionEntrySignal -eq $true);actionKind=if($RouteSignals.PSObject.Properties['actionKind']){[string]$RouteSignals.actionKind}else{''};reason=if($indexedEntryCount-gt0){'session-scoped execution state exists but is not wake eligible'}else{'no current session-scoped execution state'};durationMs=[int]$watch.ElapsedMilliseconds;modelCalled=$false;networkCalled=$false;deepRecallCalled=$false;memoryBodyLoaded=$false}
  }
  if ($entries.Count -ne 1) {
    $signal = [bool]($RouteSignals.continuitySignal -or $RouteSignals.contextReplySignal -or $RouteSignals.hookCandidate -or $RouteSignals.explicitSuperBrain -or ($RouteSignals.PSObject.Properties['actionEntrySignal'] -and $RouteSignals.actionEntrySignal -eq $true))
    $watch.Stop()
    return [pscustomobject]@{active=$true;ambiguous=$true;shouldObserve=$signal;shouldWake=$signal;source=$source;taskId='';revision=0;entryCount=$entries.Count;affinity=[pscustomobject]@{topicAffinity='ambiguous';confidence='low';candidateLineIds=@($entries.taskId)};actionEntrySignal=($RouteSignals.PSObject.Properties['actionEntrySignal'] -and $RouteSignals.actionEntrySignal -eq $true);actionKind=if($RouteSignals.PSObject.Properties['actionKind']){[string]$RouteSignals.actionKind}else{''};reason='multiple current session-scoped tasks require contract disambiguation';durationMs=[int]$watch.ElapsedMilliseconds;modelCalled=$false;networkCalled=$false;deepRecallCalled=$false;memoryBodyLoaded=$false}
  }
  $entry = $entries[0]
  $affinity = Get-SuperBrainRuntimeWakeAffinity $Prompt @($entry.lines)
  $contextReference = Test-SuperBrainRuntimeWakeContextReference $Prompt
  $contextReply = [bool]($RouteSignals.contextReplySignal -or (Test-SuperBrainRuntimeWakeContextReply $Prompt))
  $continuity = [bool]$RouteSignals.continuitySignal
  $actionEntry = [bool]($RouteSignals.PSObject.Properties['actionEntrySignal'] -and $RouteSignals.actionEntrySignal -eq $true)
  $actionKind = if($RouteSignals.PSObject.Properties['actionKind']){[string]$RouteSignals.actionKind}else{''}
  $actionOrRisk = [bool]($RouteSignals.hookCandidate -or $RouteSignals.workflowPreferenceSignal -or $RouteSignals.explicitSuperBrain -or $actionEntry)
  $affinityMatched = ([string]$affinity.topicAffinity -ne 'unknown')
  $shouldWake = ($affinityMatched -or $contextReference -or $contextReply -or $continuity -or $actionOrRisk)
  $watch.Stop()
  return [pscustomobject]@{
    active=$true;ambiguous=$false;shouldObserve=$shouldWake;shouldWake=$shouldWake;source=$source;taskId=[string]$entry.taskId;revision=[int]$entry.revision;entryCount=1;affinity=$affinity;indexEntry=$entry;contextReply=$contextReply;continuitySignal=$continuity;actionEntrySignal=$actionEntry;actionKind=$actionKind
    reason=if($affinityMatched){[string]$affinity.reason}elseif($contextReply){'bounded contextual reply signal'}elseif($contextReference){'bounded anaphoric reference signal'}elseif($continuity){'explicit continuity signal'}elseif($actionEntry){'short critical action requires scoped dependency preflight'}elseif($actionOrRisk){'active task plus actionable or material-risk instruction'}else{'independent direct message'}
    durationMs=[int]$watch.ElapsedMilliseconds;modelCalled=$false;networkCalled=$false;deepRecallCalled=$false;memoryBodyLoaded=$false
  }
}
