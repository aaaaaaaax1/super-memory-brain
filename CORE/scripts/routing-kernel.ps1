function ConvertTo-SuperBrainRouteText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return $Value.Normalize([System.Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
}

function ConvertTo-SuperBrainCompactRouteText([string]$Value) {
  $normalized = ConvertTo-SuperBrainRouteText $Value
  return [regex]::Replace($normalized, '[\s\p{P}\p{S}]+', '')
}

function ConvertFrom-SuperBrainCharCodes([int[]]$Codes) {
  if (-not $Codes -or $Codes.Count -eq 0) { return '' }
  return -join [char[]]$Codes
}

function Test-SuperBrainRouteContainsAny([string]$Value,[string[]]$Terms) {
  foreach ($term in @($Terms)) {
    if (-not [string]::IsNullOrWhiteSpace($term) -and $Value.Contains($term.ToLowerInvariant())) { return $true }
  }
  return $false
}

function Get-SuperBrainIssueAssessment([string]$Prompt) {
  # Pure, bounded classification only. It never stores the prompt or claims a
  # root cause before the active task has produced evidence.
  $text = ConvertTo-SuperBrainRouteText $Prompt
  $zhSuperBrain = ConvertFrom-SuperBrainCharCodes @(36229,32423,22823,33041)
  $zhIssue = ConvertFrom-SuperBrainCharCodes @(38382,39064)
  $zhWhy = ConvertFrom-SuperBrainCharCodes @(20026,20160,20040)
  $zhReason = ConvertFrom-SuperBrainCharCodes @(21407,22240)
  $zhNature = ConvertFrom-SuperBrainCharCodes @(26412,36136)
  $zhRootCause = ConvertFrom-SuperBrainCharCodes @(26681,22240)
  $zhFailure = ConvertFrom-SuperBrainCharCodes @(25925,38556)
  $zhInvalid = ConvertFrom-SuperBrainCharCodes @(22833,36133)
  $zhRepair = ConvertFrom-SuperBrainCharCodes @(20462,22797)
  $zhDiagnose = ConvertFrom-SuperBrainCharCodes @(35786,26029)
  $zhContinue = ConvertFrom-SuperBrainCharCodes @(32487,32493)
  $zhResume = ConvertFrom-SuperBrainCharCodes @(25509,30528)
  $zhMainLine = ConvertFrom-SuperBrainCharCodes @(20027,32447)
  $zhParentLine = ConvertFrom-SuperBrainCharCodes @(29238,32447)
  $zhReturn = ConvertFrom-SuperBrainCharCodes @(36820,22238)
  $zhNextAction = ConvertFrom-SuperBrainCharCodes @(19979,19968,27493)
  $zhRecall = ConvertFrom-SuperBrainCharCodes @(22238,24518)
  $zhMemory = ConvertFrom-SuperBrainCharCodes @(35760,24518)
  $zhInjection = ConvertFrom-SuperBrainCharCodes @(27880,20837)
  $zhStarmap = ConvertFrom-SuperBrainCharCodes @(26143,22270)
  $zhUi = ConvertFrom-SuperBrainCharCodes @(30028,38754)
  $zhHealth = ConvertFrom-SuperBrainCharCodes @(20581,24247)
  $zhStatus = ConvertFrom-SuperBrainCharCodes @(29366,24577)
  $zhTotalPlan = ConvertFrom-SuperBrainCharCodes @(24635,26041,26696)
  $zhDoNotExecute = ConvertFrom-SuperBrainCharCodes @(20808,19981,35201,25191)
  $zhWaitApproval = ConvertFrom-SuperBrainCharCodes @(31561,25105,30830,35748)

  $explicitSuperBrain = $text.Contains('super brain') -or $text.Contains('superbrain') -or $text.Contains($zhSuperBrain)
  $diagnosticIntent = (
    $text -match '(?i)(?<![a-z])(?:issue|problem|why|reason|root cause|nature|broken|failure|failing|bug|diagnos(?:e|is)|repair|fix|what happened)(?![a-z])'
  ) -or (Test-SuperBrainRouteContainsAny $text @($zhIssue,$zhWhy,$zhReason,$zhNature,$zhRootCause,$zhFailure,$zhInvalid,$zhRepair,$zhDiagnose))
  $detected = [bool]($explicitSuperBrain -and $diagnosticIntent)

  $continuity = $text -match '(?i)(?<![a-z])(?:continue|resume|workline|main line|parent|return|next action|stop hook)(?![a-z])'
  $hookTransport = $text -match '(?i)(?<![a-z])(?:hook|dispatcher|handler|receipt|telemetry|desktop host|prompt submit)(?![a-z])'
  $memoryEffect = $text -match '(?i)(?<![a-z])(?:memory|recall|injection|inject|card|retriev)(?![a-z])'
  $uiProjection = $text -match '(?i)(?<![a-z])(?:ui|star map|starmap|3d|graph|projection)(?![a-z])'
  $healthStatus = $text -match '(?i)(?<![a-z])(?:health|status|doctor|startup)(?![a-z])'
  if (-not $continuity) { $continuity = Test-SuperBrainRouteContainsAny $text @($zhContinue,$zhResume,$zhMainLine,$zhParentLine,$zhReturn,$zhNextAction) }
  if (-not $memoryEffect) { $memoryEffect = Test-SuperBrainRouteContainsAny $text @($zhRecall,$zhMemory,$zhInjection) }
  if (-not $uiProjection) { $uiProjection = Test-SuperBrainRouteContainsAny $text @($zhStarmap,$zhUi) }
  if (-not $healthStatus) { $healthStatus = Test-SuperBrainRouteContainsAny $text @($zhHealth,$zhStatus) }

  $problemNature = if ($continuity) { 'execution_continuity' }
    elseif ($hookTransport) { 'hook_transport' }
    elseif ($memoryEffect) { 'memory_recall_effect' }
    elseif ($uiProjection) { 'ui_projection' }
    elseif ($healthStatus) { 'health_status' }
    else { 'unknown' }
  $learningClass = switch ($problemNature) {
    'execution_continuity' { 'execution_rule' }
    'hook_transport' { 'system_rule' }
    'memory_recall_effect' { 'system_rule' }
    'ui_projection' { 'experience' }
    'health_status' { 'system_rule' }
    default { 'experience' }
  }
  $learningKey = switch ($problemNature) {
    'execution_continuity' { 'mainline_auto_resume' }
    'hook_transport' { 'prompt_hook_transport' }
    'memory_recall_effect' { 'memory_effect_scope' }
    'ui_projection' { 'memory_projection_usability' }
    'health_status' { 'runtime_health_separation' }
    default { 'super_brain_issue_triage' }
  }
  $planOnly = ($text -match '(?i)(?<![a-z])(?:plan only|do not (?:execute|implement|change)|wait for (?:my )?approval|before (?:you )?(?:execute|implement))(?![a-z])') -or (Test-SuperBrainRouteContainsAny $text @($zhTotalPlan,$zhDoNotExecute,$zhWaitApproval))
  $governedScope = $text -match '(?i)(?<![a-z])(?:global|hook|install|startup|publish|delete|migration)(?![a-z])'

  return [pscustomobject]@{
    detected = $detected
    problemNature = $problemNature
    rootCauseState = if ($detected) { 'evidence_required' } else { 'not_applicable' }
    responseOrder = 'essence>evidence>repair>next'
    repairMode = if (-not $detected) { 'not_applicable' } elseif ($planOnly) { 'plan_for_approval' } else { 'diagnose_and_repair' }
    repairScope = if ($governedScope) { 'governed_scope_check_required' } else { 'current_authorized_local_scope' }
    learningClass = $learningClass
    learningKey = $learningKey
    rawPromptStored = $false
  }
}

function Get-SuperBrainActionEntry([string]$Prompt) {
  # Only exact, compact action commands enter the dependency preflight path.
  # This deliberately excludes words such as "testing", "package.json", and prose.
  $compact = ConvertTo-SuperBrainCompactRouteText $Prompt
  if ([string]::IsNullOrWhiteSpace($compact)) {
    return [pscustomobject]@{ actionEntrySignal=$false; actionKind=''; continuation=$false }
  }
  $zhContinue = ConvertFrom-SuperBrainCharCodes @(32487,32493)
  $zhNext = ConvertFrom-SuperBrainCharCodes @(19979,19968,27493)
  $zhResume = ConvertFrom-SuperBrainCharCodes @(25509,30528)
  $zhCommit = ConvertFrom-SuperBrainCharCodes @(25552,20132)
  $zhPackage = ConvertFrom-SuperBrainCharCodes @(25171,21253)
  $zhTest = ConvertFrom-SuperBrainCharCodes @(27979,35797)
  $zhModify = ConvertFrom-SuperBrainCharCodes @(20462,25913)
  $zhSync = ConvertFrom-SuperBrainCharCodes @(21516,27493)
  $kind = switch ($compact) {
    'continue' { 'continue'; break }
    'resume' { 'continue'; break }
    'next' { 'next'; break }
    'nextstep' { 'next'; break }
    $zhContinue { 'continue'; break }
    $zhResume { 'continue'; break }
    $zhNext { 'next'; break }
    'commit' { 'commit'; break }
    $zhCommit { 'commit'; break }
    'package' { 'package'; break }
    $zhPackage { 'package'; break }
    'test' { 'test'; break }
    $zhTest { 'test'; break }
    'modify' { 'modify'; break }
    'edit' { 'modify'; break }
    $zhModify { 'modify'; break }
    'sync' { 'sync'; break }
    $zhSync { 'sync'; break }
    default { '' }
  }
  return [pscustomobject]@{
    actionEntrySignal = (-not [string]::IsNullOrWhiteSpace($kind))
    actionKind = $kind
    continuation = ($kind -in @('continue','next'))
  }
}

function Get-SuperBrainHotRouteSignals([string]$Prompt) {
  $text = ConvertTo-SuperBrainRouteText $Prompt
  $compact = ConvertTo-SuperBrainCompactRouteText $Prompt
  $actionEntry = Get-SuperBrainActionEntry $Prompt
  $contextReplySignal = $compact -match '^(?:ok|okay|yes|yep|sure|confirm|confirmed|[1-9]{1,3}|[1-9]?[a-c]{1,3}|\u53ef\u4ee5|\u5bf9|\u5bf9\u7684|\u662f\u7684|\u786e\u8ba4|\u6ca1\u95ee\u9898|\u6ca1\u9519|\u597d|\u597d\u7684|\u884c|\u5c31\u8fd9\u6837|\u6309\u8fd9\u4e2a)$'
  $trivial = (-not $actionEntry.actionEntrySignal) -and ([string]::IsNullOrWhiteSpace($text) -or $compact -match '^\d+$' -or $compact -match '^(?:hi|hello|hey|thanks|thankyou|test|ping|\u4f60\u597d|\u60a8\u597d|\u5728\u5417|\u53ef\u4ee5|\u8c22\u8c22|\u4f60\u597d\u554a|\u4f60\u597d\u5440|\u4f60\u597d\u4e86)$')

  $standaloneG1 = $false
  if ($compact.StartsWith('g1')) { $standaloneG1 = $compact.Substring(2) -in @('','status','health','start','wake','refresh','repair') }
  $explicitSuperBrain = $standaloneG1 -or $text.Contains('super brain') -or $text.Contains('superbrain') -or $text.Contains(([string][char]0x8d85+[char]0x7ea7+[char]0x5927+[char]0x8111))
  $superBrainIssue = Get-SuperBrainIssueAssessment $Prompt
  $continuitySignal = $actionEntry.continuation -or $text -match '(?i)(?<![a-z])(?:continue|resume|previous|last time|another session|remember|current\s+(?:plan|status|progress)|task\s+(?:status|progress)|next\s+step|where\s+are\s+we)(?![a-z])|\u7ee7\u7eed|\u4e0a\u6b21|\u4e4b\u524d|\u8bb0\u4f4f|\u56de\u5fc6|\u5f53\u524d\u8ba1\u5212|\u5f53\u524d\u4efb\u52a1|\u5f53\u524d\u72b6\u6001|\u4e0b\u4e00\u6b65|\u8fdb\u5ea6|\u603b\u7ed3\u9700\u6c42'
  $routeSensitive = $compact.Length -le 16 -or $text.Contains('skill') -or $text.Contains('smag') -or $text.Contains('samg') -or $text.Contains('browser') -or $text.Contains('playwright') -or $text.Contains('chrome') -or $text.Contains('git') -or $text.Contains('commit')
  $hookCandidate = -not $trivial -and ($explicitSuperBrain -or $continuitySignal -or $superBrainIssue.detected)

  return [pscustomobject]@{
    text=$text; compact=$compact; trivial=[bool]$trivial; explicitSuperBrain=[bool]$explicitSuperBrain; standaloneG1=[bool]$standaloneG1
    browserTaskSignal=$false; browserRoute=''; browserRouteReason=''
    continuitySignal=[bool]$continuitySignal; contextReplySignal=[bool]$contextReplySignal; actionEntrySignal=[bool]$actionEntry.actionEntrySignal; actionKind=[string]$actionEntry.actionKind; skillSignal=$false
    workflowPreferenceSignal=$false; hookCandidate=[bool]$hookCandidate; requiresFullRoute=[bool]$routeSensitive; hotRoute=$true; superBrainIssue=$superBrainIssue
  }
}

function Get-SuperBrainRouteSignals([string]$Prompt) {
  $text = ConvertTo-SuperBrainRouteText $Prompt
  $compact = ConvertTo-SuperBrainCompactRouteText $Prompt
  $actionEntry = Get-SuperBrainActionEntry $Prompt

  $zhHello = ConvertFrom-SuperBrainCharCodes @(20320,22909)
  $zhHelloFormal = ConvertFrom-SuperBrainCharCodes @(24744,22909)
  $zhAt = ConvertFrom-SuperBrainCharCodes @(22312,21527)
  $zhCan = ConvertFrom-SuperBrainCharCodes @(21487,20197)
  $zhThanks = ConvertFrom-SuperBrainCharCodes @(35874,35874)
  $zhParticleA = ConvertFrom-SuperBrainCharCodes @(21834)
  $zhParticleYa = ConvertFrom-SuperBrainCharCodes @(21568)
  $zhParticleLe = ConvertFrom-SuperBrainCharCodes @(20102)
  $trivialValues = @('hi','hello','hey','ok','okay','thanks','thankyou','test','ping',$zhHello,$zhHelloFormal,$zhAt,$zhCan,$zhThanks,$zhHello+$zhParticleA,$zhHello+$zhParticleYa,$zhHello+$zhParticleLe)
  $trivial = (-not $actionEntry.actionEntrySignal) -and ([string]::IsNullOrWhiteSpace($text) -or $compact -match '^\d+$' -or $trivialValues -contains $compact)
  $contextReplyValues = @(
    'ok','okay','yes','yep','sure','confirm','confirmed',
    (ConvertFrom-SuperBrainCharCodes @(21487,20197)),
    (ConvertFrom-SuperBrainCharCodes @(23545)),
    (ConvertFrom-SuperBrainCharCodes @(23545,30340)),
    (ConvertFrom-SuperBrainCharCodes @(26159,30340)),
    (ConvertFrom-SuperBrainCharCodes @(30830,35748)),
    (ConvertFrom-SuperBrainCharCodes @(27809,38382,39064)),
    (ConvertFrom-SuperBrainCharCodes @(27809,38169)),
    (ConvertFrom-SuperBrainCharCodes @(22909)),
    (ConvertFrom-SuperBrainCharCodes @(22909,30340)),
    (ConvertFrom-SuperBrainCharCodes @(34892)),
    (ConvertFrom-SuperBrainCharCodes @(23601,36825,26679)),
    (ConvertFrom-SuperBrainCharCodes @(25353,36825,20010))
  )
  $contextReplySignal = ($contextReplyValues -contains $compact) -or $compact -match '^(?:[1-9]{1,3}|[1-9]?[a-c]{1,3})$'

  $zhSuperBrain = ConvertFrom-SuperBrainCharCodes @(36229,32423,22823,33041)
  $zhStatus = ConvertFrom-SuperBrainCharCodes @(29366,24577)
  $zhHealth = ConvertFrom-SuperBrainCharCodes @(20581,24247)
  $zhStart = ConvertFrom-SuperBrainCharCodes @(21551,21160)
  $zhRefresh = ConvertFrom-SuperBrainCharCodes @(21047,26032)
  $zhRepair = ConvertFrom-SuperBrainCharCodes @(20462,22797)
  $g1Suffixes = @('','status','health','start','wake','refresh','repair',$zhStatus,$zhHealth,$zhStart,$zhRefresh,$zhRepair)
  $standaloneG1 = $false
  if ($compact.StartsWith('g1')) { $standaloneG1 = $g1Suffixes -contains $compact.Substring(2) }
  $explicitSuperBrain = $standaloneG1 -or $text.Contains('super brain') -or $text.Contains('superbrain') -or $text.Contains($zhSuperBrain)
  $superBrainIssue = Get-SuperBrainIssueAssessment $Prompt

  $agentMention = $text -match '(?<![a-z0-9_.-])(?:sub-?agent|agent)(?![a-z0-9_.-])'
  $zhChannel = ConvertFrom-SuperBrainCharCodes @(36890,36947)
  $zhOpen = ConvertFrom-SuperBrainCharCodes @(25171,24320)
  $zhStart2 = ConvertFrom-SuperBrainCharCodes @(24320,21551)
  $zhConnect = ConvertFrom-SuperBrainCharCodes @(36830,25509)
  $zhConnect2 = ConvertFrom-SuperBrainCharCodes @(25509,20837)
  $zhSend = ConvertFrom-SuperBrainCharCodes @(21457,36865)
  $zhSendMessage = ConvertFrom-SuperBrainCharCodes @(21457,28040,24687)
  $zhRead = ConvertFrom-SuperBrainCharCodes @(35835,21462)
  $zhClose = ConvertFrom-SuperBrainCharCodes @(20851,38381)
  $zhTo = ConvertFrom-SuperBrainCharCodes @(21521)
  $zhGive = ConvertFrom-SuperBrainCharCodes @(32473)
  $bridgeNoun = Test-SuperBrainRouteContainsAny $text @('agent channel','agent bridge','subagent channel','sub-agent channel',$zhChannel)
  $bridgeVerb = ($text -match '(?<![a-z])(?:open|connect|send|read|close)(?![a-z])') -or (Test-SuperBrainRouteContainsAny $text @($zhOpen,$zhStart2,$zhConnect,$zhConnect2,$zhSend,$zhSendMessage,$zhRead,$zhClose))
  $directAgentSend = ($text -match '(?<![a-z])send(?![a-z]).*(?<![a-z0-9_.-])(?:sub-?agent|agent)(?![a-z0-9_.-])') -or ((Test-SuperBrainRouteContainsAny $text @($zhTo,$zhGive)) -and (Test-SuperBrainRouteContainsAny $text @($zhSend,$zhSendMessage)) -and $agentMention)
  $agentBridgeIntent = $agentMention -and (($bridgeNoun -and $bridgeVerb) -or $directAgentSend)

  $integrationAction = $text -match '(?<![a-z])(?:connect|wire|integrate|integration|hook up|plug in|plug-in|embed|attach|bind|fold into|merge into|route into|thread into)(?![a-z])'
  if (-not $integrationAction) { $integrationAction = $text -match '(?<![a-z])(?:fold|merge|route|thread)(?:\s+\S+){0,8}\s+into(?![a-z])' }
  $optimizationAction = $text -match '(?<![a-z])(?:improve|enhance|speed up|faster|accelerate|performance|optimization|optimisation)(?![a-z])'
  $zhStrongActions = @(
    @(20462,22797),@(35843,35797),@(35786,26029),@(20248,21270),@(23454,29616),@(24320,21457),
    @(26500,24314),@(37325,26500),@(36801,31227),@(27979,35797),@(39564,35777),@(26816,26597),
    @(23457,35745),@(37096,32626),@(23433,35013),@(21024,38500),@(28155,21152),@(20462,25913),
    @(32487,32493),@(24674,22797),@(26032,22686),@(25913,36827),@(25552,21319),@(21152,36895),
    @(21152,24555),@(25509,20837),@(38598,25104),@(25972,21512),@(36830,25509),@(25913,24471),@(25913,25104),
    @(26356,24555),@(26032,22686),@(25913,36896),@(37325,20889),
    @(26367,25442),@(25913,29992),@(24341,20837),@(37325,26032,35774,35745)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $zhIntegrationActions = @(
    @(25509,20837),@(38598,25104),@(25972,21512),@(36830,25509),
    @(25509,36827),@(32465,36827),@(24182,20837),@(31359,20837),@(23884,36827),
    @(25509,21040),@(31359,36807),@(32435,20837),@(32465,23450)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $zhOptimizationActions = @(
    @(20248,21270),@(25913,36827),@(25552,21319),@(21152,36895),@(21152,24555),@(25913,24471),@(26356,24555)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $zhCoherenceActions = @(
    @(34917),@(20018,36215,26469),@(20018,36827),@(34701,20837),@(32452,36827),
    @(23884,20837),@(32465,36827),@(22686,21152),@(23884,20837,21040),@(32465,36827,21040),
    @(25509,21040),@(31359,36807),@(32435,20837),@(32465,23450)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $coherenceActionSignal = Test-SuperBrainRouteContainsAny $text $zhCoherenceActions
  $zhLet = ConvertFrom-SuperBrainCharCodes @(35753)
  $zhEnter = ConvertFrom-SuperBrainCharCodes @(36827,20837)
  $letIndex = $text.IndexOf($zhLet,[StringComparison]::Ordinal)
  $enterIndex = if ($letIndex -ge 0) { $text.IndexOf($zhEnter,$letIndex + $zhLet.Length,[StringComparison]::Ordinal) } else { -1 }
  if (-not $coherenceActionSignal -and $enterIndex -gt $letIndex -and ($enterIndex - $letIndex) -le 80) { $coherenceActionSignal = $true }
  if (-not $integrationAction) { $integrationAction = Test-SuperBrainRouteContainsAny $text $zhIntegrationActions }
  if (-not $optimizationAction) { $optimizationAction = Test-SuperBrainRouteContainsAny $text $zhOptimizationActions }
  $strongAction = $text -match '(?<![a-z])(?:fix|repair|debug|diagnose|diagnosis|optimize|optimise|implement|build|create|develop|refactor|rewrite|redesign|replace|migrate|test|verify|review|audit|deploy|install|remove|delete|add|change|continue|resume)(?![a-z])'
  if (-not $strongAction) { $strongAction = Test-SuperBrainRouteContainsAny $text $zhStrongActions }
  if (-not $strongAction) { $strongAction = $coherenceActionSignal }
  $changeActionSignal = $strongAction -or $integrationAction -or $optimizationAction
  $zhFeatureContext = @(
    (ConvertFrom-SuperBrainCharCodes @(21151,33021)),
    (ConvertFrom-SuperBrainCharCodes @(33021,21147)),
    (ConvertFrom-SuperBrainCharCodes @(27169,22359)),
    (ConvertFrom-SuperBrainCharCodes @(27969,31243)),
    (ConvertFrom-SuperBrainCharCodes @(39033,30446)),
    (ConvertFrom-SuperBrainCharCodes @(29616,26377)),
    (ConvertFrom-SuperBrainCharCodes @(23548,20986)),
    (ConvertFrom-SuperBrainCharCodes @(38142)),
    (ConvertFrom-SuperBrainCharCodes @(36807,31243))
  )
  $featureContextSignal = $text -match '(?i)(?<![a-z])(?:feature|capability|module|workflow|flow|journey|process|path|chain|booking|submission|closure|project|image generation|export|integration)(?![a-z])'
  if (-not $featureContextSignal) { $featureContextSignal = Test-SuperBrainRouteContainsAny $text $zhFeatureContext }
  $zhProductFlowContext = @(
    @(20837,21475),@(29366,24577),@(32467,26524),@(33853,28857),@(21518,32493),
    @(36820,22238),@(38142,36335),@(36335,24452),@(36827,20837),@(33853,21040),
    @(32467,26524,39029),@(21518,32493,21160,20316),@(38142),@(33410,28857),
    @(22238,21040),@(39539,22238),@(36807,31243),@(25764,38144),@(22238,28378)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $productFlowContextSignal = $text -match '(?i)(?<![a-z])(?:entry|states?|status|outcomes?|results?|destinations?|return(?: path)?|failure path|follow-up|rollback|recovery|context|process|path|chain|step|pages?|booking|submission|closure|sign-in|checkout|upload|approval|publishing path|release path)(?![a-z])'
  if (-not $productFlowContextSignal) { $productFlowContextSignal = Test-SuperBrainRouteContainsAny $text $zhProductFlowContext }
  $featureIntentSignal = ($featureContextSignal -and $changeActionSignal) -or ($productFlowContextSignal -and ($integrationAction -or $coherenceActionSignal))

  $zhStructuralTerms = @(
    @(26550,26500),@(25968,25454,27169,22411),@(25968,25454,24211),@(23548,33322),
    @(26435,38480),@(20381,36182),@(36328,27169,22359),@(26680,24515,27969,31243),
    @(25968,25454,36801,31227),@(37325,20889),@(20381,36182,20851,31995),@(38271,26399,32500,25252)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $structuralChangeSignal = $text -match '(?i)(?<![a-z])(?:architecture|data model|database|api contract|navigation|permission|dependency|cross-module|cross[- ]service|core workflow|migration|rewrite|long-term maintenance)(?![a-z])'
  if (-not $structuralChangeSignal) { $structuralChangeSignal = Test-SuperBrainRouteContainsAny $text $zhStructuralTerms }
  if ($structuralChangeSignal -and $changeActionSignal) { $featureIntentSignal = $true }

  $zhBrowserTerms = @(
    @(32593,39029),@(39029,38754),@(27983,35272,22120),@(32593,31449)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $browserTaskSignal = ($text -match '(?i)(?<![a-z0-9_-])(?:browser|browser-act|playwright|webpage|website|web page|chrome)(?![a-z0-9_-])') -or (Test-SuperBrainRouteContainsAny $text $zhBrowserTerms)
  $browserActRequested = $text.Contains('browser-act')
  $zhCannot = @(
    @(20570,19981,20102),@(19981,33021),@(26080,27861),@(19981,21487,38752),@(22833,36133)
  ) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  $playwrightUnreliable = $browserActRequested -and $text.Contains('playwright') -and (($text -match '(?i)(?:cannot|can''t|unable|unreliable|failed|fails|does not work|doesn''t work)') -or (Test-SuperBrainRouteContainsAny $text $zhCannot))
  $browserRoute = if ($playwrightUnreliable) { 'browser-act' } elseif ($browserActRequested) { 'browser-act' } elseif ($browserTaskSignal) { 'playwright' } else { '' }
  $browserRouteReason = if ($playwrightUnreliable) { 'playwright_unreliable' } elseif ($browserActRequested) { 'user_requested' } elseif ($browserTaskSignal) { 'default' } else { '' }

  $materialRisk = $text -match '(?<![a-z])(?:risk|failure|failed|broken|regression|bottleneck)(?![a-z])'
  $zhRiskTerms = @(@(39118,38505),@(25925,38556),@(22833,36133),@(22238,24402),@(24615,33021,22238,24402),@(29942,39048)) | ForEach-Object { ConvertFrom-SuperBrainCharCodes $_ }
  if (-not $materialRisk) { $materialRisk = Test-SuperBrainRouteContainsAny $text $zhRiskTerms }

  $zhContinue = ConvertFrom-SuperBrainCharCodes @(32487,32493)
  $zhPrevious = ConvertFrom-SuperBrainCharCodes @(19978,27425)
  $zhBefore = ConvertFrom-SuperBrainCharCodes @(20043,21069)
  $zhRemember = ConvertFrom-SuperBrainCharCodes @(35760,20303)
  $zhRecall = ConvertFrom-SuperBrainCharCodes @(22238,24518)
  $continuitySignal = $actionEntry.continuation -or ($text -match '(?<![a-z])(?:continue|resume|previous|last time|another session|remember|current\s+(?:plan|status|progress)|task\s+(?:status|progress)|next\s+step|where\s+are\s+we)(?![a-z])') -or (Test-SuperBrainRouteContainsAny $text @($zhContinue,$zhPrevious,$zhBefore,$zhRemember,$zhRecall,(ConvertFrom-SuperBrainCharCodes @(24403,21069,35745,21010)),(ConvertFrom-SuperBrainCharCodes @(24403,21069,20219,21153)),(ConvertFrom-SuperBrainCharCodes @(24403,21069,29366,24577)),(ConvertFrom-SuperBrainCharCodes @(19979,19968,27493)),(ConvertFrom-SuperBrainCharCodes @(36827,24230)),(ConvertFrom-SuperBrainCharCodes @(24635,32467,38656,27714))))

  $skillSignal = ($text -match '(?<![a-z0-9_.-])skills?(?![a-z0-9_.-])|(?<![a-z0-9_.-])s(?:ma|am)g(?![a-z0-9_.-])') -or $text.Contains((ConvertFrom-SuperBrainCharCodes @(25216,33021)))
  $workflowPreferenceSignal = (
    $compact.Contains('git' + (ConvertFrom-SuperBrainCharCodes @(24590,20040,20889))) -or
    $compact.Contains('git' + (ConvertFrom-SuperBrainCharCodes @(21602))) -or
    $compact.Contains((ConvertFrom-SuperBrainCharCodes @(24590,20040,25552,20132))) -or
    $compact.Contains((ConvertFrom-SuperBrainCharCodes @(25552,20132,24590,20040,20889))) -or
    $compact.Contains('git' + (ConvertFrom-SuperBrainCharCodes @(25552,20132,24590,20040,20889))) -or
    $compact.Contains('commit' + (ConvertFrom-SuperBrainCharCodes @(24590,20040,20889))) -or
    $compact.Contains((ConvertFrom-SuperBrainCharCodes @(25552,20132,20449,24687,24590,20040,20889))) -or
    $compact.Contains((ConvertFrom-SuperBrainCharCodes @(25552,20132,35828,26126,24590,20040,20889)))
  )
  $systemStatusIntent = $explicitSuperBrain -and (($text -match '(?<![a-z])(?:status|health|version|dashboard|ready)(?![a-z])') -or (Test-SuperBrainRouteContainsAny $text @($zhStatus,$zhHealth)))
  $hookCandidate = -not $trivial -and ($explicitSuperBrain -or $agentBridgeIntent -or $strongAction -or $integrationAction -or $optimizationAction -or $featureIntentSignal -or $browserTaskSignal -or $materialRisk -or $continuitySignal -or $skillSignal)

  return [pscustomobject]@{
    text = $text
    compact = $compact
    trivial = $trivial
    explicitSuperBrain = $explicitSuperBrain
    standaloneG1 = $standaloneG1
    agentMention = $agentMention
    agentBridgeIntent = $agentBridgeIntent
    genericAgent = ($agentMention -and -not $agentBridgeIntent)
    strongAction = [bool]$strongAction
    integrationAction = [bool]$integrationAction
    optimizationAction = [bool]$optimizationAction
    featureIntentSignal = [bool]$featureIntentSignal
    featureContextSignal = [bool]$featureContextSignal
    productFlowContextSignal = [bool]$productFlowContextSignal
    changeActionSignal = [bool]$changeActionSignal
    structuralChangeSignal = [bool]$structuralChangeSignal
    collaborationClass = if ($structuralChangeSignal) { 'structural' } elseif ($featureIntentSignal) { 'workflow' } else { 'local' }
    browserTaskSignal = [bool]$browserTaskSignal
    browserRoute = $browserRoute
    browserRouteReason = $browserRouteReason
    materialRisk = [bool]$materialRisk
    continuitySignal = [bool]$continuitySignal
    contextReplySignal = [bool]$contextReplySignal
    actionEntrySignal = [bool]$actionEntry.actionEntrySignal
    actionKind = [string]$actionEntry.actionKind
    skillSignal = [bool]$skillSignal
    workflowPreferenceSignal = [bool]$workflowPreferenceSignal
    systemStatusIntent = [bool]$systemStatusIntent
    superBrainIssue = $superBrainIssue
    hookCandidate = [bool]$hookCandidate
  }
}
