param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function U([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

$zhSuperBrain = U @(0x8D85,0x7EA7,0x5927,0x8111)
$zhBigBrain = U @(0x5927,0x8111)
$zhBrain = U @(0x8111,0x5B50)
$zhRefreshSuperBrain = (U @(0x5237,0x65B0)) + $zhSuperBrain
$zhStartSuperBrain = (U @(0x542F,0x52A8)) + $zhSuperBrain
$zhOptimizeQuestion = $zhSuperBrain + (U @(0x8FD8,0x6709,0x53EF,0x4EE5,0x4F18,0x5316,0x7684,0x5417))
$zhOptimize = U @(0x4F18,0x5316)
$zhPresent = U @(0x5728,0x5417)
$zhStatus = U @(0x72B6,0x6001)
$zhRefresh = U @(0x5237,0x65B0)
$zhHumanBrainSelfReport = (U @(0x6211)) + $zhBrain + (U @(0x6709,0x95EE,0x9898))
$zhOkNoProblem = (U @(0x597D,0x7684,0x6CA1,0x95EE,0x9898))
$zhHello = U @(0x4F60,0x597D)
$zhNevermind = U @(0x6CA1,0x4E8B)
$zhHumanBrainConfused = (U @(0x6211,0x7684)) + $zhBrain + (U @(0x6709,0x70B9,0x4E71))
$zhIncidentalG1Product = (U @(0x8FD9,0x4E2A)) + ' G1 ' + (U @(0x578B,0x53F7,0x600E,0x4E48,0x6837))
$zhSuperBrainFault = $zhSuperBrain + (U @(0x574F,0x4E86))
$zhBrainSystemFault = $zhBrain + (U @(0x4E0D,0x5BF9))
$zhBad = U @(0x574F,0x4E86)
$zhNotRight = U @(0x4E0D,0x5BF9)
$zhContinue = U @(0x7EE7,0x7EED)
$zhConnect = U @(0x63A5,0x4E0A)
$zhFastResume = (U @(0x5FEB,0x901F,0x7EED,0x63A5))

$scenarios = @(
  [pscustomobject]@{ name='bare_superbrain_zh'; prompt=$zhSuperBrain; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='bare_g1'; prompt='G1'; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='bare_superbrain_en'; prompt='Super Brain'; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='superbrain_optimize'; prompt=$zhOptimizeQuestion; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='ack_ok_zh'; prompt=(U @(0x597D,0x7684)); kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='ack_received_zh'; prompt=(U @(0x6536,0x5230)); kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='ack_no_problem_zh'; prompt=(U @(0x6CA1,0x95EE,0x9898)); kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='ack_ok_en'; prompt='ok'; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='ack_ok_no_problem_zh'; prompt=$zhOkNoProblem; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='greeting_hello_zh'; prompt=$zhHello; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='casual_nevermind_zh'; prompt=$zhNevermind; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='ordinary_coding_question'; prompt='帮我改这个 bug'; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='incidental_g1_mention'; prompt='这个 G1 规则可以写进文档'; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='incidental_g1_product'; prompt=$zhIncidentalG1Product; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='human_brain_self_report'; prompt=$zhHumanBrainSelfReport; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='human_brain_confused'; prompt=$zhHumanBrainConfused; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='superbrain_fault'; prompt=$zhSuperBrainFault; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='brain_system_fault'; prompt=$zhBrainSystemFault; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='fast_session_resume_zh'; prompt=($zhContinue + ' #sess_abc123'); kind='fast-session-resume'; expectedFastResume=$true },
  [pscustomobject]@{ name='fast_session_resume_connect_zh'; prompt=($zhConnect + ' #sess_abc123'); kind='fast-session-resume'; expectedFastResume=$true },
  [pscustomobject]@{ name='fast_session_resume_en'; prompt='continue #sess_abc123'; kind='fast-session-resume'; expectedFastResume=$true },
  [pscustomobject]@{ name='fast_session_resume_negative_no_id'; prompt=$zhContinue; kind='fast-session-resume-negative'; expectedFastResume=$false },
  [pscustomobject]@{ name='simple_continue'; prompt='continue'; kind='dispatch'; flags='SimpleDirect'; expectedLevel='direct'; expectedTemplate=$null },
  [pscustomobject]@{ name='single_file_fast_fix'; prompt='known single-file fast fix'; kind='dispatch'; flags='KnownSingleFile,FastRequested,VerificationRequired'; expectedLevel='direct'; expectedTemplate=$null },
  [pscustomobject]@{ name='broad_project_search'; prompt='broad project search and understand implementation'; kind='dispatch'; flags='BroadSearch,Parallelizable,VerificationRequired'; expectedLevel='team_parallel'; expectedTemplate='explore-team' },
  [pscustomobject]@{ name='release_share'; prompt='release share package and verify privacy'; kind='dispatch'; flags='VerificationRequired,Parallelizable'; extraReasons=@('release','share'); expectedLevel='single_delegate'; expectedTemplate='release-team' },
  [pscustomobject]@{ name='architecture_review'; prompt='architecture change needs logic safety review'; kind='dispatch'; flags='ArchitectureChange,LongTask,LogicSafetyRequired,VerificationRequired'; expectedLevel='review_board'; expectedTemplate='review-team' },
  [pscustomobject]@{ name='memory_sensitive_failure'; prompt='memory-sensitive repeated failure'; kind='dispatch'; flags='MemorySensitive,RepeatedFailure,LogicSafetyRequired,VerificationRequired'; expectedLevel='review_board'; expectedTemplate='review-team' }
)

function Test-BareSuperBrainTrigger([string]$Prompt) {
  $trimmed = ([string]$Prompt).Trim()
  $normalized = $trimmed.ToLowerInvariant()
  $bareWords = @($script:zhSuperBrain,'super brain','g1',$script:zhRefreshSuperBrain,$script:zhStartSuperBrain)

  $isBare = $false
  foreach ($word in $bareWords) {
    if ($normalized -eq $word.ToLowerInvariant()) { $isBare = $true; break }
  }

  $isSuperBrainMention = ($trimmed -like "*$script:zhSuperBrain*") -or ($normalized -like '*super brain*')
  $isHumanSelfReport = ($trimmed -like "我*$script:zhBrain*" -or $trimmed -like "我*$script:zhBigBrain*")
  $isBrainSystemFault = (-not $isHumanSelfReport) -and (($trimmed -like "*$script:zhSuperBrain*$script:zhBad*") -or ($trimmed -like "*$script:zhBrain*$script:zhNotRight*") -or ($trimmed -like "*$script:zhBigBrain*$script:zhNotRight*"))
  $isG1Question = (($normalized -match '(^|\s)g1(\s|$)') -and (($normalized -like '*status*') -or ($normalized -like '*working*') -or ($normalized -like '*optimiz*') -or ($trimmed -like "*$script:zhStatus*") -or ($trimmed -like "*$script:zhPresent*")))
  $isSuperBrainIntent = $isBare -or $isSuperBrainMention -or $isG1Question -or $isBrainSystemFault
  $isStatusOrOptimize = ($trimmed -like "*$script:zhOptimize*") -or ($normalized -like '*optimiz*') -or ($trimmed -like "*$script:zhPresent*") -or ($trimmed -like "*$script:zhStatus*") -or ($trimmed -like "*$script:zhRefresh*")
  $triggered = $isBare -or $isBrainSystemFault -or ($isSuperBrainIntent -and $isStatusOrOptimize)
  [pscustomobject]@{
    triggered = $triggered
    skill = if ($triggered) { 'super-memory-brain' } else { $null }
    requiresG1 = $triggered
    reason = if ($isBare) { 'bare_superbrain_wake_word' } elseif ($isBrainSystemFault) { 'superbrain_system_fault' } elseif ($triggered) { 'superbrain_status_or_optimize_intent' } else { 'no_superbrain_trigger' }
  }
}

function Test-FastSessionResumeTrigger([string]$Prompt) {
  $trimmed = ([string]$Prompt).Trim()
  $normalized = $trimmed.ToLowerInvariant()
  $hasSessionId = $normalized -match '#?sess[_-][a-z0-9._-]+'
  $hasResumeIntent = ($trimmed -like "*$script:zhContinue*") -or ($trimmed -like "*$script:zhConnect*") -or ($trimmed -like "*$script:zhFastResume*") -or ($normalized -match '(^|\s)(continue|resume)(\s|$)')
  $triggered = $hasSessionId -and $hasResumeIntent
  [pscustomobject]@{
    triggered = $triggered
    requiresSkill = $triggered
    skill = if ($triggered) { 'super-memory-brain' } else { $null }
    bindSession = $triggered
    deepRecall = $false
    reason = if ($triggered) { 'fast_session_resume_session_id' } elseif (-not $hasSessionId) { 'missing_session_id' } else { 'missing_resume_intent' }
  }
}

$results = @()
foreach ($scenario in $scenarios) {
  if ($scenario.kind -eq 'skill' -or $scenario.kind -eq 'skill-negative') {
    $trigger = Test-BareSuperBrainTrigger $scenario.prompt
    $skillOk = ([string]$trigger.skill -eq [string]$scenario.expectedSkill)
    $g1Ok = ([bool]$trigger.requiresG1 -eq [bool]$scenario.expectedG1)
    $positiveOk = if ($scenario.kind -eq 'skill') { $trigger.triggered } else { -not $trigger.triggered }
    $results += [pscustomobject]@{
      name = $scenario.name
      prompt = $scenario.prompt
      kind = $scenario.kind
      ok = ($positiveOk -and $skillOk -and $g1Ok)
      expectedSkill = $scenario.expectedSkill
      skill = $trigger.skill
      expectedG1 = $scenario.expectedG1
      requiresG1 = $trigger.requiresG1
      reason = $trigger.reason
    }
    continue
  }

  if ($scenario.kind -eq 'fast-session-resume' -or $scenario.kind -eq 'fast-session-resume-negative') {
    $trigger = Test-FastSessionResumeTrigger $scenario.prompt
    $positiveOk = if ($scenario.kind -eq 'fast-session-resume') { $trigger.triggered } else { -not $trigger.triggered }
    $results += [pscustomobject]@{
      name = $scenario.name
      prompt = $scenario.prompt
      kind = $scenario.kind
      ok = ($positiveOk -and ([bool]$trigger.triggered -eq [bool]$scenario.expectedFastResume))
      expectedFastResume = $scenario.expectedFastResume
      fastSessionResume = $trigger.triggered
      skill = $trigger.skill
      bindSession = $trigger.bindSession
      deepRecall = $trigger.deepRecall
      reason = $trigger.reason
    }
    continue
  }

  switch ($scenario.name) {
    'simple_continue' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -SimpleDirect -Json }
    'single_file_fast_fix' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -KnownSingleFile -FastRequested -VerificationRequired -Json }
    'broad_project_search' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -BroadSearch -Parallelizable -VerificationRequired -Json }
    'release_share' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -VerificationRequired -Parallelizable -Json }
    'architecture_review' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -ArchitectureChange -LongTask -LogicSafetyRequired -VerificationRequired -Json }
    'memory_sensitive_failure' { $dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -MemorySensitive -RepeatedFailure -LogicSafetyRequired -VerificationRequired -Json }
    default { throw "unknown trigger simulation scenario $($scenario.name)" }
  }
  if ($LASTEXITCODE -ne 0) { throw "dispatch failed for $($scenario.name)" }
  $dispatch = $dispatchJsonText | ConvertFrom-Json
  $reasons = @(@($dispatch.reasons) + @($scenario.extraReasons) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $templateJsonText = & (Join-Path $PSScriptRoot 'team-template-select.ps1') -DispatchLevel $dispatch.dispatchLevel -Reason $reasons -Json
  if ($LASTEXITCODE -ne 0) { throw "template select failed for $($scenario.name)" }
  $template = $templateJsonText | ConvertFrom-Json
  $actualTemplate = if ($template.selected) { [string]$template.selected.id } else { $null }
  $levelOk = ([string]$dispatch.dispatchLevel -eq [string]$scenario.expectedLevel)
  $templateOk = ([string]$actualTemplate -eq [string]$scenario.expectedTemplate)
  $results += [pscustomobject]@{
    name = $scenario.name
    prompt = $scenario.prompt
    kind = $scenario.kind
    ok = ($levelOk -and $templateOk)
    dispatchLevel = $dispatch.dispatchLevel
    expectedLevel = $scenario.expectedLevel
    templateId = $actualTemplate
    expectedTemplate = $scenario.expectedTemplate
    score = $dispatch.score
    reasons = @($reasons)
  }
}

$failed = @($results | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  total = $results.Count
  failed = $failed.Count
  results = @($results)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "TRIGGER_SIMULATION total=$($result.total) failed=$($result.failed)"
  foreach ($item in @($results)) {
    if ($item.kind -like 'skill*') {
      Write-Host "TRIGGER_CASE name=$($item.name) ok=$($item.ok) kind=$($item.kind) skill=$($item.skill) g1=$($item.requiresG1) reason=$($item.reason)"
    } elseif ($item.kind -like 'fast-session-resume*') {
      Write-Host "TRIGGER_CASE name=$($item.name) ok=$($item.ok) kind=$($item.kind) fastSessionResume=$($item.fastSessionResume) bindSession=$($item.bindSession) deepRecall=$($item.deepRecall) reason=$($item.reason)"
    } else {
      Write-Host "TRIGGER_CASE name=$($item.name) ok=$($item.ok) kind=dispatch level=$($item.dispatchLevel) template=$($item.templateId)"
    }
  }
}
if (-not $result.ok) { exit 1 }
exit 0
