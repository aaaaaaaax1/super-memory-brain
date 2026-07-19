[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$TestPrompt = '',
  [string]$TestWorkspace = '',
  [string]$TestSessionId = '',
  [string]$TestAgentId = '',
  [string]$TestAgentType = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'routing-kernel.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$skillCatalogScript = Join-Path $Root 'modules\skill-pool-router\scripts\skill-catalog.ps1'
if (Test-Path -LiteralPath $skillCatalogScript) { . $skillCatalogScript }
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-codex-user-prompt-hook.json'
$metricsPath = Join-Path $workspace 'last-codex-route-metrics.json'
$script:HookInputMaxChars = 4000
$script:HookAdditionalContextMaxChars = 1900
$script:HookSessionId = ''
$script:HookAgentId = ''
$script:HookAgentType = ''

function Get-InputPrompt {
  if (-not [string]::IsNullOrWhiteSpace($TestPrompt)) {
    $script:HookSessionId = $TestSessionId
    $script:HookAgentId = $TestAgentId
    $script:HookAgentType = $TestAgentType
    return $TestPrompt
  }
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
  try {
    $payload = $raw | ConvertFrom-Json
    foreach ($name in @('session_id','sessionId')) {
      $value = $payload.PSObject.Properties[$name]
      if ($value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) { $script:HookSessionId = [string]$value.Value; break }
    }
    foreach ($name in @('agent_id','agentId')) {
      $value = $payload.PSObject.Properties[$name]
      if ($value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) { $script:HookAgentId = [string]$value.Value; break }
    }
    foreach ($name in @('agent_type','agentType')) {
      $value = $payload.PSObject.Properties[$name]
      if ($value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) { $script:HookAgentType = [string]$value.Value; break }
    }
    foreach ($name in @('prompt','user_prompt','input')) {
      $value = $payload.PSObject.Properties[$name]
      if ($value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) { return [string]$value.Value }
    }
  } catch {}
  return ''
}

function Get-ShortHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..7] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Limit-ContinuationPacketText([string]$Value,[int]$Max=220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($Max -le 0) { return '' }
  if ($clean.Length -gt $Max) {
    if ($Max -le 3) { return $clean.Substring(0,$Max) }
    return $clean.Substring(0,$Max - 3).TrimEnd() + '...'
  }
  return $clean
}

function Limit-HookAdditionalContext([string]$Value) {
  return Limit-ContinuationPacketText $Value $script:HookAdditionalContextMaxChars
}

function Merge-HookAdditionalContext([string]$Critical,[string]$Optional) {
  $criticalText = Limit-ContinuationPacketText $Critical ([Math]::Min(1500,$script:HookAdditionalContextMaxChars))
  if ([string]::IsNullOrWhiteSpace($criticalText)) { return Limit-HookAdditionalContext $Optional }
  $remaining = $script:HookAdditionalContextMaxChars - $criticalText.Length - 1
  if ($remaining -le 0 -or [string]::IsNullOrWhiteSpace($Optional)) { return $criticalText }
  return $criticalText + ' ' + (Limit-ContinuationPacketText $Optional $remaining)
}

function Get-ExecutionContractResumePacket($Contract,[bool]$ContinuitySignal) {
  if (-not $Contract -or $Contract.ok -ne $true) { return '' }
  $workLine = if ($Contract.PSObject.Properties['workLineStatus']) { $Contract.workLineStatus } else { $null }
  $focusId = Limit-ContinuationPacketText ([string]$Contract.focusId) 120
  $mainLine = if ($workLine -and $workLine.PSObject.Properties['mainLine']) { Limit-ContinuationPacketText ([string]$workLine.mainLine) 120 } else { $focusId }
  $activeLine = if ($workLine -and $workLine.PSObject.Properties['activeLine']) { Limit-ContinuationPacketText ([string]$workLine.activeLine) 120 } else { $focusId }
  $mainLabel = if ($workLine -and $workLine.userView -and $workLine.userView.main) { Limit-ContinuationPacketText ([string]$workLine.userView.main.label) 100 } else { $mainLine }
  $activeLabel = if ($workLine -and $workLine.userView -and $workLine.userView.current) { Limit-ContinuationPacketText ([string]$workLine.userView.current.label) 100 } else { $activeLine }
  $activePlan = if ($workLine -and $workLine.PSObject.Properties['activePlan']) { $workLine.activePlan } else { $null }
  $constraints = @($Contract.constraints | Select-Object -First 2 | ForEach-Object { Limit-ContinuationPacketText ([string]$_) 120 } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $classification = if ($Contract.PSObject.Properties['latestMessageClassification']) { $Contract.latestMessageClassification } elseif ($workLine -and $workLine.PSObject.Properties['latestMessageClassification']) { $workLine.latestMessageClassification } else { $null }
  $affinity = if ($classification) { Limit-ContinuationPacketText ([string]$classification.topicAffinity) 140 } else { 'unknown' }
  $confidence = if ($classification) { Limit-ContinuationPacketText ([string]$classification.confidence) 20 } else { 'none' }
  $needsClarification = if ($classification -and $classification.needsClarification -eq $true) { 'true' } else { 'false' }
  $targetLine = if ($classification) { Limit-ContinuationPacketText ([string]$classification.targetLineId) 120 } else { '' }
  $actionAuthorized = ($Contract.needsReconciliation -ne $true -and $needsClarification -ne 'true' -and $Contract.actionAuthorization -ne 'withheld')
  $nextAction = if (-not $actionAuthorized) { '' } elseif ($activePlan) { Limit-ContinuationPacketText ([string]$activePlan.nextAction) 260 } else { Limit-ContinuationPacketText ([string]$Contract.nextAction) 260 }
  $commitment = if ($actionAuthorized) { Limit-ContinuationPacketText ([string]$Contract.assistantCommitment) 220 } else { '' }
  $suspended = @()
  if ($workLine -and $workLine.PSObject.Properties['suspendedPlans']) {
    $suspended = @($workLine.suspendedPlans | Select-Object -First 3 | ForEach-Object {
      $label = if (-not [string]::IsNullOrWhiteSpace([string]$_.focusLabel)) { Limit-ContinuationPacketText ([string]$_.focusLabel) 80 } else { Limit-ContinuationPacketText ([string]$_.focusId) 80 }
      $action = if ($actionAuthorized) { Limit-ContinuationPacketText ([string]$_.nextAction) 90 } else { '' }
      if ([string]::IsNullOrWhiteSpace($action)) { $label } else { $label + '=>' + $action }
    })
  }
  $priority = @()
  if ($workLine -and $workLine.PSObject.Properties['priorityOrder']) {
    $priority = @($workLine.priorityOrder | Select-Object -First 4 | ForEach-Object { '#' + [string]$_.executionRank + ':' + (Limit-ContinuationPacketText ([string]$_.focusLabel) 70) + '(' + [string]$_.source + ')' })
  }
  $unfinished = @()
  if ($workLine -and $workLine.PSObject.Properties['unfinishedPlans']) {
    $nextUnfinishedRank = $priority.Count + 1
    $unfinished = @($workLine.unfinishedPlans | Select-Object -First 3 | ForEach-Object {
      $rank = if ($_.priority -and [int]$_.priority.executionRank -gt 0) { [int]$_.priority.executionRank } else { $nextUnfinishedRank }
      $nextUnfinishedRank = [Math]::Max($nextUnfinishedRank + 1,$rank + 1)
      $label = if (-not [string]::IsNullOrWhiteSpace([string]$_.focusLabel)) { Limit-ContinuationPacketText ([string]$_.focusLabel) 80 } else { Limit-ContinuationPacketText ([string]$_.focusId) 80 }
      $action = if ($actionAuthorized) { Limit-ContinuationPacketText ([string]$_.nextAction) 90 } else { '' }
      $entry = '#' + [string]$rank + ':' + $label
      if (-not [string]::IsNullOrWhiteSpace($action)) { $entry += '=>' + $action }
      if ($priority.Count -lt 4) { $priority += $entry + '(unfinished)' }
      $entry
    })
  }
  $hasMultipleLines = (@($suspended).Count -gt 0 -or ($workLine -and @($workLine.unfinishedPlans).Count -gt 0))
  if (-not $ContinuitySignal -and -not $hasMultipleLines -and $affinity -eq 'unknown') { return '' }
  if (-not $actionAuthorized) {
    return "EXECUTION_CONTRACT_RESUME_PACKET: actionAuthorization=withheld oldActionsOmitted=true mutationGuard=reconcile-before-mutation recoveryPoint=task:$($Contract.taskId) mainLine=$mainLabel[$mainLine] currentLine=$activeLabel[$activeLine] messageAffinity=$affinity targetLine=$targetLine confidence=$confidence needsClarification=$needsClarification suspended=$($suspended -join ' | ') unfinished=$($unfinished -join ' | ') priorityOrder=$($priority -join '>'). Do not execute, infer, or restore an older action from memory, checkpoint, commitment, suspended plans, or unfinished plans."
  }
  if ([string]::IsNullOrWhiteSpace($nextAction)) {
    return "EXECUTION_CONTRACT_RESUME_PACKET: actionAuthorization=withheld oldActionsOmitted=true mutationGuard=recover-plan-before-mutation recoveryPoint=task:$($Contract.taskId) mainLine=$mainLabel[$mainLine] currentLine=$activeLabel[$activeLine] messageAffinity=$affinity targetLine=$targetLine confidence=$confidence needsClarification=$needsClarification planStatus=missing. Do not guess or use generic memory; recover only task-scoped checkpoint/return-card evidence before mutation."
  }
  $constraintText = if ($constraints.Count -gt 0) { ' constraints=' + ($constraints -join ' | ') } else { '' }
  $commitmentText = if (-not [string]::IsNullOrWhiteSpace($commitment)) { ' commitment=' + $commitment } else { '' }
  $suspendedText = if ($suspended.Count -gt 0) { ' suspended=' + ($suspended -join ' | ') } else { ' suspended=none' }
  $unfinishedText = if ($unfinished.Count -gt 0) { ' unfinished=' + ($unfinished -join ' | ') } else { ' unfinished=none' }
  $priorityText = if ($priority.Count -gt 0) { ' priorityOrder=' + ($priority -join '>') } else { ' priorityOrder=#1:' + $activeLabel }
  $taskId = Limit-ContinuationPacketText ([string]$Contract.taskId) 120
  $actionText = ' actionAuthorization=allowed authorizedNextAction=' + $nextAction
  return "EXECUTION_CONTRACT_RESUME_PACKET: recoveryPoint=task:$taskId mainLine=$mainLabel[$mainLine] currentLine=$activeLabel[$activeLine]$suspendedText$unfinishedText$priorityText messageAffinity=$affinity targetLine=$targetLine confidence=$confidence needsClarification=$needsClarification$actionText$commitmentText$constraintText. When multiple lines exist, the first visible status update must name the current line, unfinished lines, effective rank, and message affinity. Unknown, pending, or ambiguous affinity must be reconciled before mutation; memory cannot replace this plan."
}

function Update-RouteMetrics([string]$Tier,[int]$DurationMs,[string]$ResolvedName) {
  $fallback=[pscustomobject]@{p95Ms=[Math]::Max(0,$DurationMs)}
  try {
    return Invoke-SuperBrainFileLock $metricsPath {
      $current=$null
      if(Test-Path -LiteralPath $metricsPath){try{$current=Get-Content -Raw -Encoding UTF8 -LiteralPath $metricsPath|ConvertFrom-Json}catch{}}
      $counts=[ordered]@{T0=0;T1=0;T2=0;GATE=0}
      if($current-and$current.counts){foreach($name in @($counts.Keys)){if($current.counts.PSObject.Properties[$name]){$counts[$name]=[int]$current.counts.$name}}}
      if($counts.Contains($Tier)){$counts[$Tier]++}
      $samples=@()
      if($current-and$current.samplesMs){$samples+=@($current.samplesMs)}
      $samples=@($samples+[Math]::Max(0,$DurationMs)|Select-Object -Last 64)
      $sorted=@($samples|Sort-Object)
      $p95=if($sorted.Count){[int]$sorted[[Math]::Max(0,[Math]::Ceiling($sorted.Count*0.95)-1)]}else{0}
      $resolved=@()
      if($current-and$current.resolved){$resolved+=@($current.resolved|Where-Object{[string]$_.name-ne$ResolvedName})}
      if(-not[string]::IsNullOrWhiteSpace($ResolvedName)){
        $previous=@($current.resolved|Where-Object{[string]$_.name-eq$ResolvedName}|Select-Object -First 1)
        $resolved+=[pscustomobject]@{name=$ResolvedName;count=if($previous){[int]$previous.count+1}else{1}}
      }
      $value=[pscustomobject]@{schema='super-brain.codex-route-metrics.v1';updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');total=([int]$counts.T0+[int]$counts.T1+[int]$counts.T2+[int]$counts.GATE);counts=[pscustomobject]$counts;samplesMs=@($samples);p95Ms=$p95;resolved=@($resolved|Sort-Object count -Descending|Select-Object -First 32);rawPromptStored=$false}
      [IO.File]::WriteAllText($metricsPath,($value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
      return $value
    } 250 120
  } catch {
    return $fallback
  }
}

function Read-SkillMetadata([string]$SkillFile,[string]$Folder,[string]$Source,[string]$ExpectedHash='') {
  if(-not(Test-Path -LiteralPath $SkillFile)){return $null}
  if(-not[string]::IsNullOrWhiteSpace($ExpectedHash)){
    $actualHash=(Get-FileHash -LiteralPath $SkillFile -Algorithm SHA256).Hash
    if($actualHash -ne $ExpectedHash){return $null}
  }
  $name=$Folder
  foreach($line in @(Get-Content -LiteralPath $SkillFile -Encoding UTF8 -TotalCount 20)){
    if($line -match '^name:\s*(.*)$'){$name=([string]$Matches[1]).Trim().Trim('"').Trim("'");break}
  }
  return [pscustomobject]@{name=$name;folder=$Folder;skillFile=$SkillFile;source=$Source;verified=$true}
}

function Get-Value([object]$Object,[string]$Name){
  if($Object -is [System.Collections.IDictionary]){return $Object[$Name]}
  $property=$Object.PSObject.Properties[$Name]
  if($property){return $property.Value}
  return $null
}

function Test-ChildPath([string]$RootPath,[string]$CandidatePath){
  try {
    $root=[IO.Path]::GetFullPath($RootPath).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $candidate=[IO.Path]::GetFullPath($CandidatePath)
    return $candidate.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Get-CjkFourgrams([string]$Value){
  $phrases=@{}
  foreach($match in [regex]::Matches([string]$Value,'[\u3400-\u9fff]{4,}')){
    $run=[string]$match.Value
    for($index=0;$index-le($run.Length-4);$index++){$phrases[$run.Substring($index,4)]=$true}
  }
  return @($phrases.Keys)
}

function Normalize-SkillPhrase([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return ''}
  return ((($Value.ToLowerInvariant()-replace '[^\p{L}\p{N}]+',' ').Trim())-replace '\s+',' ')
}

function Test-ColdSkillTaskIntent([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)-or$Value.Length-lt4){return $false}
  if($Value-match'(?i:\b(generate|create|build|design|edit|revise|rewrite|optimize|fix|upgrade|migrate|test|analyze|find|search|scrape|crawl|convert|summarize|write|develop|configure|install|debug|review|model|automate|refactor|research|plan)\b)'){return $true}
  return $Value-match'(?:\u751F\u6210|\u521B\u5EFA|\u5236\u4F5C|\u8BBE\u8BA1|\u7F16\u8F91|\u4FEE\u6539|\u4F18\u5316|\u4FEE\u590D|\u5347\u7EA7|\u8FC1\u79FB|\u6D4B\u8BD5|\u5206\u6790|\u67E5\u627E|\u68C0\u7D22|\u6293\u53D6|\u722C\u53D6|\u8F6C\u6362|\u603B\u7ED3|\u5199\u4F5C|\u5F00\u53D1|\u642D\u5EFA|\u914D\u7F6E|\u5B89\u88C5|\u8C03\u8BD5|\u6392\u67E5|\u5BA1\u67E5|\u5BA1\u6838|\u5EFA\u6A21|\u81EA\u52A8\u5316|\u6DA6\u8272|\u6539\u5199|\u91CD\u6784|\u89C4\u5212|\u7814\u7A76)'
}

function Get-UserCorrectionSignals([string]$Value){
  $signals=@()
  if([string]::IsNullOrWhiteSpace($Value)){return @()}
  if($Value-match'(?:^|[\s\p{P}])\u4E0D\u5BF9(?!\u79F0)(?:$|[\s\p{P}])'){$signals+='explicit_wrong'}
  if($Value-match'(?:\u7406\u89E3\u9519|\u641E\u9519|\u4E32\u53F0)'){$signals+='misunderstood'}
  if($Value-match'(?:\u4E0D\u662F\u8BA9\u4F60|\u6211\u8BF4\u7684\u4E0D\u662F|\u4E0D\u662F\u6211\u8981\u7684)'){$signals+='wrong_goal'}
  if($Value-match'(?i:\b(?:that is wrong|that''s wrong|you misunderstood|not what i asked|not what i meant)\b)'){$signals+='explicit_wrong'}
  return @($signals|Select-Object -Unique)
}

function Get-ExplicitPreferenceSignals([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return @()}
  $durable='(?i:\u4ee5\u540e|\u4eca\u540e|\u9ed8\u8ba4|\u8bb0\u4f4f|\u6211\u5e0c\u671b\u4f60|\u6211\u4e60\u60ef|\u6211\u504f\u597d|from now on|going forward|by default|remember that|i prefer|always)'
  if($Value-notmatch$durable){return @()}
  $rules=@(
    [pscustomobject]@{habitKey='response_detail';value='concise';pattern='(?i:\u7b80\u6d01|\u7cbe\u7b80|\u7b80\u77ed|\u522b\u5570\u55e6|\u4e0d\u8981\u5570\u55e6|concise|brief)'},
    [pscustomobject]@{habitKey='response_detail';value='detailed';pattern='(?i:\u8be6\u7ec6(?:\u89e3\u91ca|\u8bf4\u660e|\u5c55\u5f00)?|\u5c55\u5f00\u89e3\u91ca|detailed|explain in detail)'},
    [pscustomobject]@{habitKey='reasoning_style';value='evidence_first';pattern='(?i:\u5148\u7ed9\u4f9d\u636e|\u4e8b\u60c5\u8981\u6709\u4f9d\u636e|\u57fa\u4e8e\u8bc1\u636e|\u8bc1\u636e\u4f18\u5148|evidence first|facts first)'},
    [pscustomobject]@{habitKey='reasoning_style';value='solution_first';pattern='(?i:\u5148\u7ed9\u65b9\u6848|\u5148\u8bf4\u7ed3\u8bba|\u7ed3\u8bba\u5148\u884c|solution first|answer first|lead with the recommendation)'},
    [pscustomobject]@{habitKey='proactivity';value='material_only';pattern='(?i:(?:\u6536\u76ca|\u6548\u679c).{0,8}\u660e\u663e.{0,16}(?:\u98ce\u9669.{0,8}\u660e\u663e)?.{0,12}(?:\u4e3b\u52a8|\u4ecb\u5165|\u5e72\u9884)|material (?:benefit|risk).{0,20}(?:intervene|proactive))'},
    [pscustomobject]@{habitKey='proactivity';value='ask_first';pattern='(?i:\u53ef\u9009.{0,8}\u5148\u95ee\u6211|\u4e3b\u52a8.{0,8}\u5148\u786e\u8ba4|ask me before optional|ask first before optional)'},
    [pscustomobject]@{habitKey='proactivity';value='proactive';pattern='(?i:\u53ef\u9006.{0,8}\u4e3b\u52a8|\u5c0f\u6539.{0,8}\u4e3b\u52a8|proactively (?:handle|execute).{0,20}(?:small|reversible))'},
    [pscustomobject]@{habitKey='small_change_autonomy';value='auto';pattern='(?i:\u5c0f(?:\u6539\u52a8|\u4e8b).{0,10}(?:\u76f4\u63a5\u505a|\u81ea\u52a8\u5904\u7406|\u4e0d\u7528\u95ee)|small reversible changes?.{0,16}(?:directly|automatically|without asking))'},
    [pscustomobject]@{habitKey='small_change_autonomy';value='ask';pattern='(?i:\u5c0f(?:\u6539\u52a8|\u4e8b).{0,10}(?:\u4e5f\u8981|\u90fd\u8981)?\u5148\u95ee\u6211|ask before even small changes?)'},
    [pscustomobject]@{habitKey='structural_change_autonomy';value='discuss';pattern='(?i:\u7ed3\u6784(?:\u4e0a|\u6027|\u6539\u52a8)?.{0,10}(?:\u5148\u5546\u91cf|\u5148\u8ba8\u8bba|\u5148\u95ee\u6211)|discuss structural changes? first)'},
    [pscustomobject]@{habitKey='structural_change_autonomy';value='align';pattern='(?i:\u7ed3\u6784(?:\u4e0a|\u6027|\u6539\u52a8)?.{0,12}(?:\u5148\u8bf4\u660e\u5f71\u54cd|\u5148\u5bf9\u9f50)|align before structural changes?)'},
    [pscustomobject]@{habitKey='verification_depth';value='risk_based';pattern='(?i:(?:\u6309|\u6839\u636e)\u98ce\u9669.{0,10}(?:\u6d4b\u8bd5|\u9a8c\u8bc1)|risk.based verification|scale verification to risk)'},
    [pscustomobject]@{habitKey='verification_depth';value='thorough';pattern='(?i:(?:\u5b8c\u6574|\u5168\u91cf|\u5168\u9762).{0,8}(?:\u6d4b\u8bd5|\u9a8c\u8bc1)|thorough verification|full regression)'},
    [pscustomobject]@{habitKey='verification_depth';value='minimal';pattern='(?i:\u53ea\u505a.{0,8}(?:\u6700\u5c0f|\u5fc5\u8981).{0,8}(?:\u6d4b\u8bd5|\u9a8c\u8bc1)|minimal verification only)'},
    [pscustomobject]@{habitKey='feature_thinking';value='integrated';pattern='(?i:\u529f\u80fd.{0,16}(?:\u8fde\u8d2f|\u878d\u5165|\u4ea7\u54c1\u6d41\u7a0b|\u6574\u4f53\u903b\u8f91|\u4f5c\u7528\u548c\u5f71\u54cd)|features?.{0,20}(?:fit|integrate).{0,16}(?:product|flow))'},
    [pscustomobject]@{habitKey='clarification_style';value='infer_then_confirm';pattern='(?i:(?:\u5148\u68c0\u67e5|\u5148\u7406\u89e3|\u5148\u81ea\u5df1\u627e).{0,16}(?:\u518d\u95ee|\u53ea\u95ee\u5173\u952e)|inspect first.{0,20}ask only)'},
    [pscustomobject]@{habitKey='clarification_style';value='ask_first';pattern='(?i:(?:\u6709\u6b67\u4e49|\u4e0d\u786e\u5b9a|\u591a\u79cd\u65b9\u6848).{0,12}\u5148\u95ee|ask first when ambiguous)'}
  )
  $matches=@($rules|Where-Object{$Value-match$_.pattern})
  $signals=@()
  foreach($group in @($matches|Group-Object habitKey)){
    $values=@($group.Group.value|Select-Object -Unique)
    if($values.Count-eq1){$signals += [pscustomobject]@{habitKey=[string]$group.Name;value=[string]$values[0];scope='global';context='general'}}
  }
  return @($signals)
}

function Get-ScannedSkillEntries {
  $entries=@()
  $seen=@{}
  $activeRoot=Join-Path $env:USERPROFILE '.codex\skills'
  if((Test-Path -LiteralPath $activeRoot) -and (Get-Command Get-SkillCatalogFiles -ErrorAction SilentlyContinue)){
    foreach($file in @(Get-SkillCatalogFiles $activeRoot)){
      $folder=Split-Path -Leaf (Split-Path -Parent $file.FullName)
      $meta=Read-SkillMetadata $file.FullName $folder 'active'
      if($meta -and -not $seen.ContainsKey($file.FullName)){$entries+=$meta;$seen[$file.FullName]=$true}
    }
  }
  $coldRoot=Join-Path $env:USERPROFILE '.codex-cold-skills'
  if((Test-Path -LiteralPath $coldRoot) -and (Get-Command Get-SkillCatalogFiles -ErrorAction SilentlyContinue)){
    foreach($file in @(Get-SkillCatalogFiles $coldRoot)){
      $folder=Split-Path -Leaf (Split-Path -Parent $file.FullName)
      $meta=Read-SkillMetadata $file.FullName $folder 'cold'
      if($meta -and -not $seen.ContainsKey($file.FullName)){$entries+=$meta;$seen[$file.FullName]=$true}
    }
  }
  return @($entries)
}

function Select-NamedSkillEntries([object[]]$Entries,[string]$Needle) {
  $needleLower=$Needle.ToLowerInvariant()
  $needleNormalized=Normalize-SkillPhrase $Needle
  $ranked=@()
  foreach($entry in $Entries){
    $name=([string]$entry.name).ToLowerInvariant();$folder=([string]$entry.folder).ToLowerInvariant()
    $nameAlias=Normalize-SkillPhrase $name;$folderAlias=Normalize-SkillPhrase $folder
    $rawLength=0
    if($name.Length-ge3-and$needleLower.Contains($name)){$rawLength=[Math]::Max($rawLength,$name.Length)}
    if($folder.Length-ge3-and$needleLower.Contains($folder)){$rawLength=[Math]::Max($rawLength,$folder.Length)}
    $aliasLength=0
    if($nameAlias.Length-ge3-and$needleNormalized.Contains($nameAlias)){$aliasLength=[Math]::Max($aliasLength,$nameAlias.Length)}
    if($folderAlias.Length-ge3-and$needleNormalized.Contains($folderAlias)){$aliasLength=[Math]::Max($aliasLength,$folderAlias.Length)}
    $matchLength=[Math]::Max($rawLength,$aliasLength)
    $sourcePriority=if(([string]$entry.source)-eq'active'){2}else{0}
    $score=if($matchLength-gt0){($matchLength*10)+[int]($rawLength-ge$aliasLength-and$rawLength-gt0)+$sourcePriority}else{0}
    if($score-gt0){$ranked += [pscustomobject]@{score=$score;entry=$entry}}
  }
  $ranked=@($ranked|Sort-Object score -Descending)
  if($ranked.Count-gt1-and$ranked[0].score-eq$ranked[1].score){return @()}
  return @($ranked|ForEach-Object{$_.entry})
}

function Find-NamedSkill([string]$Prompt) {
  $needle=$Prompt.ToLowerInvariant()
  if($needle.Contains('samg')){$needle=$needle.Replace('samg','smag')}
  $entries=@()
  $usedCompactIndex=$false
  $lookupPath=Join-Path $env:USERPROFILE '.codex-cold-skills\skill-name-index.tsv'
  if(Test-Path -LiteralPath $lookupPath){
    foreach($line in @([IO.File]::ReadAllLines($lookupPath,[Text.Encoding]::UTF8)|Select-Object -Skip 1)){
      $parts=@($line -split "`t")
      if($parts.Count-ne5){continue}
      $entries += [pscustomobject]@{source=$parts[0];folder=$parts[1];name=$parts[2];skillFile=$parts[3];sha256=$parts[4]}
    }
    $usedCompactIndex=($entries.Count-gt0)
  }
  if($entries.Count-eq0){$entries=@(Get-ScannedSkillEntries)}
  $matches=@(Select-NamedSkillEntries $entries $needle)
  if($matches.Count-eq0-and$usedCompactIndex){
    $entries=@(Get-ScannedSkillEntries)
    $matches=@(Select-NamedSkillEntries $entries $needle)
  }
  foreach($selected in @($matches)){
    if(-not(Test-Path -LiteralPath $selected.skillFile)){continue}
    if($selected.PSObject.Properties['sha256']-and-not[string]::IsNullOrWhiteSpace([string]$selected.sha256)){
      if((Get-FileHash -LiteralPath $selected.skillFile -Algorithm SHA256).Hash-ne[string]$selected.sha256){continue}
    }
    return $selected
  }
  if($usedCompactIndex){
    $scanned=@(Get-ScannedSkillEntries)
    foreach($selected in @(Select-NamedSkillEntries $scanned $needle)){
      if(Test-Path -LiteralPath $selected.skillFile){return $selected}
    }
  }
  return $null
}

function Find-CapabilitySkill([string]$Prompt) {
  if([string]::IsNullOrWhiteSpace($Prompt)-or$Prompt.Length-lt4){return $null}
  $coldRoot=Join-Path $env:USERPROFILE '.codex-cold-skills'
  $indexPath=Join-Path $coldRoot 'skill-pool-index.json'
  if(-not(Test-Path -LiteralPath $indexPath)){return $null}
  try{$index=[IO.File]::ReadAllText($indexPath,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{return $null}
  $entries=@(Get-Value $index 'entries')
  if($entries.Count-eq0){return $null}

  $prepared=@()
  $phraseFrequency=@{}
  foreach($entry in $entries){
    $folder=[string](Get-Value $entry 'folder')
    $name=[string](Get-Value $entry 'name')
    $description=[string](Get-Value $entry 'description')
    $skillFile=[string](Get-Value $entry 'skillFile')
    $sha256=[string](Get-Value $entry 'sha256')
    if([string]::IsNullOrWhiteSpace($skillFile)-or[string]::IsNullOrWhiteSpace($sha256)){continue}
    $fourgrams=@{}
    foreach($phrase in @(Get-CjkFourgrams "$folder $name $description")){
      $fourgrams[$phrase]=$true
      if($phraseFrequency.ContainsKey($phrase)){$phraseFrequency[$phrase]++}else{$phraseFrequency[$phrase]=1}
    }
    $quoted=@([regex]::Matches($description,'"([^"\r\n]{4,48})"')|ForEach-Object{[string]$_.Groups[1].Value}|Select-Object -Unique)
    $prepared += [pscustomobject]@{entry=$entry;folder=$folder;name=$name;description=$description;skillFile=$skillFile;sha256=$sha256;fourgrams=$fourgrams;quoted=$quoted}
  }

  $promptLower=$Prompt.ToLowerInvariant()
  $promptFourgrams=@(Get-CjkFourgrams $Prompt)
  $ranked=@()
  foreach($item in $prepared){
    $score=0
    foreach($phrase in @($item.quoted)){
      if($promptLower.Contains(([string]$phrase).ToLowerInvariant())){$score+=100+([string]$phrase).Length}
    }
    foreach($phrase in $promptFourgrams){
      if($item.fourgrams.ContainsKey($phrase)-and$phraseFrequency[$phrase]-eq1){$score+=20}
    }
    if($score-gt0){$ranked += [pscustomobject]@{score=$score;item=$item}}
  }
  $ranked=@($ranked|Sort-Object score -Descending)
  if($ranked.Count-eq0){return $null}
  if($ranked.Count-gt1-and$ranked[0].score-eq$ranked[1].score){return $null}
  $selected=$ranked[0].item
  if(-not(Test-ChildPath $coldRoot $selected.skillFile)-or-not(Test-Path -LiteralPath $selected.skillFile)){return $null}
  if((Get-FileHash -LiteralPath $selected.skillFile -Algorithm SHA256).Hash-ne$selected.sha256){return $null}
  return [pscustomobject]@{source='cold';folder=$selected.folder;name=$selected.name;skillFile=$selected.skillFile;verified=$true;match='capability'}
}

$hookWatch=[Diagnostics.Stopwatch]::StartNew()
$rawPrompt = (Get-InputPrompt).Trim()
if (-not [string]::IsNullOrWhiteSpace($script:HookAgentId) -or -not [string]::IsNullOrWhiteSpace($script:HookAgentType)) { exit 0 }
$promptLength = $rawPrompt.Length
$prompt = Limit-ContinuationPacketText $rawPrompt $script:HookInputMaxChars
$hookSessionId = if (-not [string]::IsNullOrWhiteSpace($script:HookSessionId)) { $script:HookSessionId } else { [string]$env:CODEX_THREAD_ID }
$hookSessionKey = Get-SuperBrainHostSessionKey $hookSessionId
$routeSignals = Get-SuperBrainRouteSignals $prompt
$executionContractCapture = $null
$executionContractObservation = $null
$executionContractObservationFailed = $false
if ([string]::IsNullOrWhiteSpace($TestPrompt) -and -not $routeSignals.trivial) {
  try {
    $hookWorkspaceKey = Get-SuperBrainWorkspaceKey
    $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action ObserveUser -WorkspaceKey $hookWorkspaceKey -SessionKey $hookSessionKey -UserInstruction $prompt -RequiresReconciliation -Source 'codex-user-prompt-hook.ps1' -NoExit -Json 2>$null)
    if ($contractRaw) {
      $captured = (($contractRaw -join "`n") | ConvertFrom-Json)
      if ($captured.ok -eq $true) { $executionContractCapture = $captured }
      $executionContractObservation = [pscustomobject]@{
        ok=($captured.ok -eq $true); code=Limit-ContinuationPacketText ([string]$captured.code) 80; taskId=Limit-ContinuationPacketText ([string]$captured.taskId) 120; revision=if($captured.PSObject.Properties['revision']){[int]$captured.revision}else{0}; needsReconciliation=($captured.needsReconciliation -eq $true); actionAuthorization='withheld'; sessionAccess=Limit-ContinuationPacketText ([string]$captured.sessionAccess) 32; foreignContextDetected=($captured.foreignContextDetected -eq $true); foreignContextSessionAccess=Limit-ContinuationPacketText ([string]$captured.foreignContextSessionAccess) 32; oldActionsOmitted=$true; rawSessionIdStored=$false
      }
    } else {
      $executionContractObservationFailed = $true
    }
  } catch {
    $executionContractCapture = $null
    $executionContractObservationFailed = $true
  }
}
$executionObservationError = ($executionContractObservation -and $executionContractObservation.ok -ne $true -and [string]$executionContractObservation.code -ne 'EXECUTION_CONTRACT_NOT_FOUND')
$foreignContextContinuation = ($executionContractObservation -and $executionContractObservation.foreignContextDetected -eq $true -and $routeSignals.continuitySignal)
$executionObservationGuardRequired = ($executionContractObservationFailed -or $executionObservationError -or $foreignContextContinuation)
if ($executionContractObservationFailed) {
  $executionContractObservation = [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_OBSERVATION_FAILED';taskId='';revision=0;needsReconciliation=$true;actionAuthorization='withheld';sessionAccess='unknown';oldActionsOmitted=$true;rawSessionIdStored=$false}
}
$correctionSignals = @(Get-UserCorrectionSignals $prompt)
$userCorrection = ($correctionSignals.Count -gt 0)
$adaptationSignals = @(Get-ExplicitPreferenceSignals $prompt)
$explicitPreference = ($adaptationSignals.Count -gt 0)
$namedSkill = if($prompt.Length-ge3){Find-NamedSkill $prompt}else{$null}
$capabilitySkill = if(-not $routeSignals.trivial-and$null-eq$namedSkill){Find-CapabilitySkill $prompt}else{$null}
$resolvedSkill = if($namedSkill){$namedSkill}else{$capabilitySkill}
$resolutionKind = if($namedSkill){'exact'}elseif($capabilitySkill){'capability'}else{''}
$coldSkillFallback = (-not $routeSignals.trivial) -and ($null-eq$resolvedSkill) -and (Test-ColdSkillTaskIntent $prompt)
$candidate = ($executionContractCapture -and $executionContractCapture.ok -eq $true) -or $executionObservationGuardRequired -or $userCorrection -or $explicitPreference -or ((-not $routeSignals.trivial) -and ($routeSignals.hookCandidate -or $routeSignals.workflowPreferenceSignal -or $null-ne$resolvedSkill -or $coldSkillFallback))

if (-not $candidate) { exit 0 }

$routeTier=if($namedSkill){'T0'}elseif($capabilitySkill){'T1'}elseif($coldSkillFallback){'T2'}else{'GATE'}

$rulePreflight = $null
if ($routeSignals.hookCandidate -and -not $routeSignals.workflowPreferenceSignal) {
  $rulePreflight = [pscustomobject]@{
    ok = $false
    status = 'not_resolved'
    constraints = @()
    mustPreserve = @()
  }
  try {
    $ruleOutput = @(& (Join-Path $PSScriptRoot 'accepted-constraints-preflight.ps1') -Query $prompt -MaxConstraints 3 -Json 2>$null)
    $ruleText = ($ruleOutput -join [Environment]::NewLine)
    $ruleResult = if (-not [string]::IsNullOrWhiteSpace($ruleText)) { $ruleText | ConvertFrom-Json } else { $null }
    if ($ruleResult) {
      $rulePreflight = [pscustomobject]@{
        ok = ($ruleResult.ok -eq $true)
        status = if (@($ruleResult.constraints).Count -gt 0) { 'resolved' } else { 'no_current_match' }
        constraints = @($ruleResult.constraints | Select-Object -First 3 | ForEach-Object {
          [pscustomobject]@{
            claim = Limit-ContinuationPacketText ([string]$_.claim) 180
            source = Limit-ContinuationPacketText ([string]$_.source) 180
            confidence = [double]$_.confidence
          }
        })
        mustPreserve = @($ruleResult.mustPreserve | Select-Object -First 3 | ForEach-Object { Limit-ContinuationPacketText ([string]$_) 140 })
      }
    }
  } catch {
    $rulePreflight.status = 'preflight_failed'
  }
}

$workflowPreflight = $null
if ($routeSignals.workflowPreferenceSignal) {
  $workflowPreflight = [pscustomobject]@{
    ok = $false
    status = 'not_resolved'
    decisionKey = ''
    content = ''
    source = ''
  }
  try {
    $intentWorkspace = if ([string]::IsNullOrWhiteSpace($TestWorkspace)) { (Get-Location).Path } else { $TestWorkspace }
    $intentOutput = @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $prompt -Workspace $intentWorkspace -Json 2>$null)
    $intentText = ($intentOutput -join [Environment]::NewLine)
    $intentResult = if (-not [string]::IsNullOrWhiteSpace($intentText)) { $intentText | ConvertFrom-Json } else { $null }
    if ($intentResult -and $intentResult.intent -eq 'workflow_preference_recall') {
      $decisionKey = [string]$intentResult.workflowPreference.decisionKey
      $decisionOutput = @(& (Join-Path $PSScriptRoot 'decision-search.ps1') -Key $decisionKey -CurrentOnly -Relation 'decides' -TopK 1 -MaxTokens 400 -Json 2>$null)
      $decisionText = ($decisionOutput -join [Environment]::NewLine)
      $decisions = if (-not [string]::IsNullOrWhiteSpace($decisionText)) { @($decisionText | ConvertFrom-Json) } else { @() }
      $active = @($decisions | Where-Object {
        $tags = [string]$_.tags
        $_.relation -eq 'decides' -and
        $tags.Contains('[CURRENT]') -and
        $tags.Contains('[VERIFIED]') -and
        -not ($_.adr -and $_.adr.superseded -eq $true)
      })
      if ($active.Count -eq 1) {
        $workflowPreflight = [pscustomobject]@{
          ok = $true
          status = 'resolved'
          decisionKey = $decisionKey
          content = [string]$active[0].object
          source = [string]$active[0].evidence
        }
      } else {
        $workflowPreflight.status = if ($active.Count -eq 0) { 'canonical_missing' } else { 'canonical_conflict' }
        $workflowPreflight.decisionKey = $decisionKey
      }
    } else {
      $workflowPreflight.status = 'scope_or_route_mismatch'
    }
  } catch {
    $workflowPreflight.status = 'preflight_failed'
  }
}

$firstLoadBootstrap = $null
if ($routeSignals.explicitSuperBrain -and [string]::IsNullOrWhiteSpace($TestPrompt)) {
  try {
    $bootstrapPath = Join-Path $PSScriptRoot 'first-load-bootstrap.ps1'
    if (Test-Path -LiteralPath $bootstrapPath) {
      $bootstrapRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrapPath -RepairMcp -Json 2>&1)
      $bootstrapText = ($bootstrapRaw | ForEach-Object { [string]$_ }) -join "`n"
      $bootstrapStart = $bootstrapText.IndexOf('{')
      if ($bootstrapStart -ge 0) { $firstLoadBootstrap = $bootstrapText.Substring($bootstrapStart) | ConvertFrom-Json }
    }
  } catch {
    $firstLoadBootstrap = [pscustomobject]@{ ok=$false; action='first_load_check_failed'; error='FIRST_LOAD_BOOTSTRAP_FAILED' }
  }
}

$criticalContext = ''
$context = if ($workflowPreflight -and $workflowPreflight.status -eq 'resolved') {
  $canonicalRecord = Limit-ContinuationPacketText ([string]$workflowPreflight.content) 900
  $decisionKey = Limit-ContinuationPacketText ([string]$workflowPreflight.decisionKey) 120
  $workflowSource = Limit-ContinuationPacketText ([string]$workflowPreflight.source) 220
  "WORKFLOW_PREFERENCE_HARD_GATE: decisionKey=$decisionKey current verified record is loaded. Response contract is exactly Summary, Description, and Commit button text. Use the loaded canonical record and current verified facts; do not output git add/git commit commands, generic Git templates, apology text, or unverified staging/commit claims. CANONICAL_RECORD: $canonicalRecord EVIDENCE: $workflowSource."
} elseif ($routeSignals.workflowPreferenceSignal) {
  $workflowStatus = Limit-ContinuationPacketText ([string]$workflowPreflight.status) 80
  "WORKFLOW_PREFERENCE_HARD_GATE: exact workflow phrase detected but current verified record status=$workflowStatus. Do not substitute generic Git commands or apology text; report the missing/conflicting evidence instead."
} elseif($routeSignals.hookCandidate-or$resolvedSkill){
  "HOST_PRETURN_GATE: Use super-memory-brain only for material risk/benefit, continuity, or approved multi-step work. Before the first mutation of an approved 3+ step plan, run autonomous-executor.ps1 and require checkpoint.created=true. For a specialized capability not covered by active skills, run skill-pool-router Search once with concise terms, translating the query when needed; load at most one verified SKILL.md in place; no activation or restart. Live evidence wins."
}elseif($coldSkillFallback){
  "COLD_SKILL_FALLBACK: If no active skill clearly fits, run skill-pool-router Search once with concise capability terms; translate when needed. Load at most one verified SKILL.md in place; no activation or restart."
}else{''}
if ($routeSignals.browserTaskSignal) {
  $fallbackAllowed = if ($routeSignals.browserRoute -eq 'browser-act') { 'true' } else { 'false' }
  $context += " BROWSER_ROUTE selected=$($routeSignals.browserRoute) fallback=browser-act fallbackAllowed=$fallbackAllowed reason=$($routeSignals.browserRouteReason)."
}
if ($rulePreflight -and $rulePreflight.status -eq 'resolved' -and @($rulePreflight.mustPreserve).Count -gt 0) {
  $context += " RULE_PREFLIGHT: current query-matched constraints are loaded before action. Must preserve: $(@($rulePreflight.mustPreserve) -join ' | '). Do not replace them with remembered or guessed rules; live evidence and the newest user instruction win."
}
if ($executionContractCapture -and $executionContractCapture.ok -eq $true) {
  $resumePacket = Get-ExecutionContractResumePacket $executionContractCapture ([bool]$routeSignals.continuitySignal)
  $criticalContext = "EXECUTION_CONTRACT_PENDING: actionAuthorization=withheld oldActionsOmitted=true mutationGuard=classify-before-mutation task=$($executionContractCapture.taskId) revision=$($executionContractCapture.revision). This user instruction is newer than every stored action. Do not execute or infer an older next action from memory, checkpoint, commitment, suspended plans, or unfinished plans. Classify as continue, side_branch, or explicit replace; preserve the parent return card for side_branch."
  if (-not [string]::IsNullOrWhiteSpace($resumePacket)) { $criticalContext += " $resumePacket" }
} elseif ($executionObservationGuardRequired) {
  $observationCode = if($foreignContextContinuation){'EXECUTION_CONTRACT_FOREIGN_CONTEXT_IGNORED'}else{Limit-ContinuationPacketText ([string]$executionContractObservation.code) 80}
  $criticalContext = "EXECUTION_CONTRACT_OBSERVATION_GUARD: actionAuthorization=withheld oldActionsOmitted=true mutationGuard=recover-contract-before-mutation code=$observationCode. Contract observation or session ownership could not be verified. Do not execute, infer, or restore any stored action from memory, checkpoint, commitment, suspended plans, or unfinished plans."
}
if ($firstLoadBootstrap) {
  if ($firstLoadBootstrap.ok -eq $true) {
    $context += " SUPER_BRAIN_FIRST_LOAD: MCP and formal memory root verified; no full bootstrap needed."
  } elseif ($firstLoadBootstrap.needsNewTask -eq $true) {
    $context += " SUPER_BRAIN_FIRST_LOAD: MCP was repaired against the formal memory root; open a new Codex task before relying on MCP tools."
  } else {
    $context += " SUPER_BRAIN_FIRST_LOAD: installation/runtime binding is not ready; use the one-click bootstrap path before claiming MCP memory access."
  }
}
if($resolvedSkill){
  $marker=if($resolutionKind-eq'exact'){'EXACT_SKILL_RESOLUTION'}else{'CAPABILITY_SKILL_RESOLUTION'}
  $skillName = Limit-ContinuationPacketText ([string]$resolvedSkill.name) 100
  $skillSource = Limit-ContinuationPacketText ([string]$resolvedSkill.source) 40
  $skillFile = Limit-ContinuationPacketText ([string]$resolvedSkill.skillFile) 260
  $context += " ${marker}: requested skill is available now; name=$skillName; source=$skillSource; skillFile=$skillFile. Read that SKILL.md and use it in this task. Catalog/tool-button absence is not evidence of unavailability."
  if($resolutionKind-eq'exact'){
    $context += ' EXACT_SKILL_BINDING: The user-selected name wins over active/default alternatives. Do not substitute another overlapping skill unless the user explicitly asks.'
  }
}
if($userCorrection){
  $correctionId='correction-'+(Get-ShortHash $prompt)
  $context += " CORRECTION_FEEDBACK_GATE: This is a strong user correction. Stop the mismatched route, restate the corrected outcome, repair it, and only after evidence run reflection-promotion.ps1 -Mode Analyze -TriggerType user_correction -Evidence correctionCandidate=$correctionId with a compact verified summary. Stage a candidate only; do not store the raw prompt or mutate durable memory automatically."
  $correctionCandidate=[pscustomobject]@{schema='super-brain.correction-candidate.v1';candidateId=$correctionId;capturedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');promptHash=(Get-ShortHash $prompt);promptLength=$prompt.Length;signals=@($correctionSignals);workspaceKey=(Get-SuperBrainWorkspaceKey);status='pending_verification';rawPromptStored=$false;durablePromotionAllowed=$false}
  if([string]::IsNullOrWhiteSpace($TestPrompt)){
    $correctionRoot=Join-Path $workspace 'reflection\correction-candidates'
    if(-not(Test-Path -LiteralPath $correctionRoot)){New-Item -ItemType Directory -Force -Path $correctionRoot|Out-Null}
    Write-JsonUtf8NoBom (Join-Path $correctionRoot ($correctionId+'.json')) $correctionCandidate 8
  }
}else{$correctionCandidate=$null}
$adaptationCapture=$null
if($explicitPreference){
  $signalNames=@($adaptationSignals|ForEach-Object{"$($_.habitKey):$($_.value)"})
  $context += " USER_ADAPTATION_SIGNAL: Current explicit instruction wins; recognized collaboration defaults=$($signalNames -join ',')."
  if(-not[string]::IsNullOrWhiteSpace($TestPrompt)){
    $adaptationCapture=[pscustomobject]@{ok=$true;mode='test';mutated=$false;signals=@($adaptationSignals);rawPromptStored=$false}
  }else{
    try{
      . (Join-Path $PSScriptRoot 'internal\user-adaptation-core.ps1')
      $promptHash=Get-ShortHash $prompt
      $observations=@()
      foreach($signal in $adaptationSignals){
        $observations += Add-UserAdaptationObservation -Root $Root -HabitKey $signal.habitKey -Value $signal.value -Signal Support -Source explicit_user -Scope $signal.scope -Context $signal.context -TaskId ("hook-"+$promptHash) -EvidenceRef ("hook|$promptHash|$($signal.habitKey)|$($signal.value)")
      }
      $synthesis=Invoke-UserAdaptationSynthesis -Root $Root
      $adaptationCapture=[pscustomobject]@{ok=$true;mode='apply';mutated=$true;signals=@($adaptationSignals);observationIds=@($observations.observationId|Where-Object{$_});promotedPreferenceIds=@($synthesis.promotedPreferenceIds);rawPromptStored=$false}
    }catch{
      $adaptationCapture=[pscustomobject]@{ok=$false;mode='apply';mutated=$false;signals=@($adaptationSignals);errorCode='USER_ADAPTATION_CAPTURE_FAILED';rawPromptStored=$false}
    }
  }
}
$hookWatch.Stop()
$context = Merge-HookAdditionalContext $criticalContext $context
$routeMetrics=Update-RouteMetrics $routeTier ([int]$hookWatch.ElapsedMilliseconds) $(if($resolvedSkill){[string]$resolvedSkill.name}else{''})
$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.codex-user-prompt-hook.v1'
  promptHash = Get-ShortHash $prompt
  promptLength = $promptLength
  candidate = $candidate
  contextChars = $context.Length
  rawPromptStored = $false
  namedSkillResolved = ($null-ne$namedSkill)
  capabilitySkillResolved = ($null-ne$capabilitySkill)
  coldSkillFallback = $coldSkillFallback
  userCorrection = $userCorrection
  correctionCandidate = $correctionCandidate
  explicitPreference = $explicitPreference
  adaptationSignals = @($adaptationSignals)
  adaptationCapture = $adaptationCapture
  routeTier = $routeTier
  durationMs = [int]$hookWatch.ElapsedMilliseconds
  routeP95Ms = [int]$routeMetrics.p95Ms
  resolutionKind = $resolutionKind
  exactBinding = ($resolutionKind-eq'exact')
  resolvedSkill = if($resolvedSkill){[string]$resolvedSkill.name}else{''}
  firstLoadBootstrap = $firstLoadBootstrap
  executionContractCapture = $executionContractObservation
  sessionBound = (-not [string]::IsNullOrWhiteSpace($hookSessionKey))
  rawSessionIdStored = $false
  workflowPreferenceSignal = [bool]$routeSignals.workflowPreferenceSignal
  workflowPreflight = $workflowPreflight
  rulePreflight = $rulePreflight
  browserTaskSignal = [bool]$routeSignals.browserTaskSignal
  browserRoute = [string]$routeSignals.browserRoute
  browserRouteReason = [string]$routeSignals.browserRouteReason
  browserFallbackAllowed = ([string]$routeSignals.browserRoute -eq 'browser-act')
}
Write-JsonUtf8NoBom $outPath $result 8

[pscustomobject]@{
  hookSpecificOutput = [pscustomobject]@{
    hookEventName = 'UserPromptSubmit'
    additionalContext = $context
  }
} | ConvertTo-Json -Compress -Depth 5
