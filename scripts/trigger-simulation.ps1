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
$zhBrainFault = $zhBrain + (U @(0x6709,0x95EE,0x9898))
$zhBigBrainFault = $zhBigBrain + (U @(0x6709,0x95EE,0x9898))
$zhThisBrainWrong = (U @(0x8FD9,0x4E2A)) + $zhBrain + (U @(0x4E0D,0x5BF9))
$zhBrainWrong = $zhBrain + (U @(0x4E0D,0x5BF9))
$zhBigBrainWrong = $zhBigBrain + (U @(0x4E0D,0x5BF9))
$zhSuperBrainBroken = $zhSuperBrain + (U @(0x574F,0x4E86))
$zhSuperBrainFault = $zhSuperBrain + (U @(0x6709,0x95EE,0x9898))
$zhIBrainFault = (U @(0x6211)) + $zhBrainFault
$zhMyBrain = (U @(0x6211,0x7684)) + $zhBrain
$zhIBigBrainWrongAsk = (U @(0x6211)) + $zhBigBrain + (U @(0x4E0D,0x5BF9,0x52B2,0x600E,0x4E48,0x529E))
$zhMyBigBrain = (U @(0x6211,0x7684)) + $zhBigBrain
$zhPersonBrain = (U @(0x4EBA)) + $zhBrain
$zhHumanBrain = (U @(0x4EBA,0x7C7B)) + $zhBrain
$zhMeBrain = (U @(0x672C,0x4EBA)) + $zhBrain
$zhBrainBroken = $zhBrain + (U @(0x574F,0x4E86))
$zhBigBrainBroken = $zhBigBrain + (U @(0x574F,0x4E86))
$zhThisBrain = (U @(0x8FD9,0x4E2A)) + $zhBrain
$zhThisBrainShort = (U @(0x8FD9)) + $zhBrain
$zhYouBrain = (U @(0x4F60)) + $zhBrain
$zhAssistantBrain = (U @(0x52A9,0x624B)) + $zhBrain
$zhBigBrainSystem = $zhBigBrain + (U @(0x7CFB,0x7EDF))
$zhOptimize = U @(0x4F18,0x5316)
$zhPresent = U @(0x5728,0x5417)
$zhStatus = U @(0x72B6,0x6001)
$zhRefresh = U @(0x5237,0x65B0)

$scenarios = @(
  [pscustomobject]@{ name='bare_superbrain_zh'; prompt=$zhSuperBrain; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='bare_g1'; prompt='G1'; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='bare_superbrain_en'; prompt='Super Brain'; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='superbrain_optimize'; prompt=$zhOptimizeQuestion; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='brain_fault_bare'; prompt=$zhBrainFault; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='brain_fault_system'; prompt=$zhThisBrainWrong; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='superbrain_fault'; prompt=$zhSuperBrainBroken; kind='skill'; expectedSkill='super-memory-brain'; expectedG1=$true },
  [pscustomobject]@{ name='human_brain_self_report'; prompt=$zhIBrainFault; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
  [pscustomobject]@{ name='human_brain_medical'; prompt=$zhIBigBrainWrongAsk; kind='skill-negative'; expectedSkill=$null; expectedG1=$false },
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
  $bareWords = @($script:zhSuperBrain,'super brain','g1',$script:zhBigBrain,$script:zhBrain,$script:zhRefreshSuperBrain,$script:zhStartSuperBrain)
  $humanSelfReportPatterns = @($script:zhIBrainFault.Substring(0, 3),$script:zhMyBrain,(U @(0x6211)) + $script:zhBigBrain,$script:zhMyBigBrain,$script:zhMeBrain,$script:zhPersonBrain,$script:zhHumanBrain)
  $faultPatterns = @($script:zhBrainFault,$script:zhBigBrainFault,$script:zhBrainWrong,$script:zhBigBrainWrong,$script:zhBrainBroken,$script:zhBigBrainBroken,$script:zhSuperBrainBroken,$script:zhSuperBrainFault,'g1' + (U @(0x574F,0x4E86)),'g1' + (U @(0x6709,0x95EE,0x9898)))
  $assistantContextPatterns = @($script:zhThisBrain,$script:zhThisBrainShort,$script:zhYouBrain,$script:zhAssistantBrain,$script:zhSuperBrain,$script:zhBigBrainSystem,'g1')

  $isHumanSelfReport = $false
  foreach ($pattern in $humanSelfReportPatterns) {
    if ($normalized.StartsWith($pattern.ToLowerInvariant())) { $isHumanSelfReport = $true; break }
  }

  $isBare = $false
  foreach ($word in $bareWords) {
    if ($normalized -eq $word.ToLowerInvariant()) { $isBare = $true; break }
  }

  $hasFaultLanguage = $false
  foreach ($pattern in $faultPatterns) {
    if ($normalized -like "*$($pattern.ToLowerInvariant())*") { $hasFaultLanguage = $true; break }
  }

  $hasAssistantContext = $false
  foreach ($pattern in $assistantContextPatterns) {
    if ($normalized -like "*$($pattern.ToLowerInvariant())*") { $hasAssistantContext = $true; break }
  }

  $isSuperBrainIntent = $isBare -or ($trimmed -like "*$script:zhSuperBrain*") -or ($normalized -like '*super brain*') -or ($trimmed -like '*G1*')
  $isStatusOrOptimize = ($trimmed -like "*$script:zhOptimize*") -or ($normalized -like '*optimiz*') -or ($trimmed -like "*$script:zhPresent*") -or ($trimmed -like "*$script:zhStatus*") -or ($trimmed -like "*$script:zhRefresh*")
  $isFaultTrigger = (-not $isHumanSelfReport) -and $hasFaultLanguage -and (($trimmed -eq $script:zhBrainFault) -or ($trimmed -eq $script:zhBigBrainFault) -or $hasAssistantContext)
  $triggered = $isBare -or ($isSuperBrainIntent -and $isStatusOrOptimize) -or $isFaultTrigger
  [pscustomobject]@{
    triggered = $triggered
    skill = if ($triggered) { 'super-memory-brain' } else { $null }
    requiresG1 = $triggered
    reason = if ($isBare) { 'bare_superbrain_wake_word' } elseif ($isFaultTrigger) { 'superbrain_fault_semantic_trigger' } elseif ($isHumanSelfReport) { 'human_self_report_excluded' } elseif ($triggered) { 'superbrain_status_or_optimize_intent' } else { 'no_superbrain_trigger' }
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
    } else {
      Write-Host "TRIGGER_CASE name=$($item.name) ok=$($item.ok) kind=dispatch level=$($item.dispatchLevel) template=$($item.templateId)"
    }
  }
}
if (-not $result.ok) { exit 1 }
exit 0
