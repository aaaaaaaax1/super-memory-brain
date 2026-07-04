param(
  [string]$Query = '',
  [int]$TopK = 50,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$mapPath = Join-Path $workspace 'extension-capability-map.json'
$outPath = Join-Path $workspace 'last-extension-capability-map.json'

function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function To-Array($Value){ if($null -eq $Value){ return @() }; return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
function Infer-Category([string]$Name,[string[]]$Triggers,[string]$ExtensionId){
  $hay = (($Name,$ExtensionId,($Triggers -join ' ')) -join ' ').ToLowerInvariant()
  if($hay -match 'browser|网页|click|screenshot|cloudflare'){ return 'tool_execution' }
  if($hay -match 'test|tdd|vitest|verify'){ return 'verification' }
  if($hay -match 'react|typescript|vue|frontend|ui|design'){ return 'domain_execution' }
  if($hay -match 'karpathy|overengineering|minimal|ponytail|guideline'){ return 'rule' }
  if($hay -match 'prd|issue|triage|spec|product'){ return 'planning' }
  return 'extension'
}
function Infer-Role([string]$Category,[string]$Name,[string[]]$Triggers){
  $hay = (($Name,($Triggers -join ' ')) -join ' ').ToLowerInvariant()
  if($hay -match 'browser|click|screenshot|cloudflare'){ return 'browser_operator' }
  if($hay -match 'test|tdd|vitest'){ return 'test_strategy' }
  if($hay -match 'ponytail|minimal|overengineering|karpathy|guideline'){ return 'pre_action_constraint' }
  if($hay -match 'prd|spec|issue|triage'){ return 'structured_decision' }
  if($Category -eq 'domain_execution'){ return 'domain_executor' }
  return 'extension_capability'
}
function Get-Terms([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){ return @() }
  return @($Value.ToLowerInvariant() -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 })
}
function Test-PhraseContains([string]$Haystack,[string]$Needle){
  if([string]::IsNullOrWhiteSpace($Haystack) -or [string]::IsNullOrWhiteSpace($Needle)){ return $false }
  return $Haystack.ToLowerInvariant().Contains($Needle.ToLowerInvariant())
}
function Get-CapabilityMatch($Cap,[string]$Needle){
  $empty = [pscustomobject]@{ score=0; matchStrength='none'; matchReason='no_query_match'; matchedTriggers=@() }
  if([string]::IsNullOrWhiteSpace($Needle)){ return $empty }

  $query = $Needle.Trim().ToLowerInvariant()
  $reverseLabNegativePatterns = @('reverse a string','generic security talk','security awareness','user agent','逆向思维','反向排序')
  if(([string]$Cap.name -eq 'reverselab-unified' -or [string]$Cap.extensionId -eq 'reverselab-unified') -and @($reverseLabNegativePatterns | Where-Object { $query.Contains($_) }).Count -gt 0){
    return $empty
  }
  $queryTerms = @(Get-Terms $Needle)
  if(@($queryTerms).Count -eq 0){ return $empty }

  $genericTerms = @('reverse','reversing','security','talk','generic','awareness','string','agent','user','what','common','tips','sort')
  $positiveTriggers = @($Cap.triggers)
  $matchedTriggers = @()
  $bestScore = 0
  $bestReason = 'no_trigger_match'
  $strong = $false

  foreach($trigger in $positiveTriggers){
    $triggerText = ([string]$trigger).Trim()
    if([string]::IsNullOrWhiteSpace($triggerText)){ continue }
    $triggerLower = $triggerText.ToLowerInvariant()
    $triggerTerms = @(Get-Terms $triggerText)
    if(@($triggerTerms).Count -eq 0){ continue }

    if($query -eq $triggerLower -or (Test-PhraseContains $query $triggerLower) -or (Test-PhraseContains $triggerLower $query -and @($queryTerms).Count -gt 1)){
      $matchedTriggers += $triggerText
      $termScore = [Math]::Max(3, @($triggerTerms).Count)
      if($termScore -gt $bestScore){ $bestScore = $termScore; $bestReason = "phrase:$triggerText" }
      $strong = $true
      continue
    }

    $overlap = @($queryTerms | Where-Object { $triggerTerms -contains $_ })
    if(@($overlap).Count -eq 0){ continue }
    $matchedTriggers += $triggerText
    $required = if(@($triggerTerms).Count -le 1){ 1 } else { [Math]::Min(2, @($triggerTerms).Count) }
    $onlyGeneric = (@($queryTerms | Where-Object { $genericTerms -notcontains $_ }).Count -eq 0)
    if(@($overlap).Count -ge $required -and -not $onlyGeneric){
      $score = @($overlap).Count
      if($score -gt $bestScore){ $bestScore = $score; $bestReason = "token_overlap:$triggerText" }
      $strong = $true
    } elseif(-not $onlyGeneric) {
      if($bestScore -lt 1){ $bestScore = 1; $bestReason = "weak_token_overlap:$triggerText" }
    }
  }

  $nameOrId = (([string]$Cap.name),([string]$Cap.extensionId),([string]$Cap.extensionName) -join ' ').ToLowerInvariant()
  $nameTerms = @(Get-Terms $nameOrId)
  $nameOverlap = @($queryTerms | Where-Object { $nameTerms -contains $_ })
  if(@($nameOverlap).Count -gt 0 -and @($queryTerms | Where-Object { $genericTerms -notcontains $_ }).Count -gt 0){
    $bestScore = [Math]::Max($bestScore, @($nameOverlap).Count)
    $bestReason = 'name_or_extension_match'
    $strong = $true
  }

  if($bestScore -le 0){ return $empty }
  return [pscustomobject]@{
    score = $bestScore
    matchStrength = if($strong){'strong'}else{'weak'}
    matchReason = $bestReason
    matchedTriggers = @($matchedTriggers | Select-Object -Unique)
  }
}
function Score-Capability($Cap,[string]$Needle){
  return (Get-CapabilityMatch $Cap $Needle).score
}

$capabilities = New-Object System.Collections.ArrayList
foreach($extension in @(Get-SuperBrainExtensionManifests @() $Root)){
  foreach($skill in @($extension.skills)){
    $triggers = To-Array $skill.triggers
    $skillName = [string]$skill.name
    $category = if($skill.category){[string]$skill.category}else{Infer-Category $skillName $triggers ([string]$extension.id)}
    $role = if($skill.role){[string]$skill.role}else{Infer-Role $category $skillName $triggers}
    $skillPath = if($skill.path){ Join-Path ([string]$extension.extensionRoot) ([string]$skill.path) } else { [string]$extension.extensionRoot }
    $setupRequired = if($skill.setupRequired){ [string]$skill.setupRequired } elseif($extension.setupRequired){ [string]$extension.setupRequired } elseif($extension.installNote){ [string]$extension.installNote } else { '' }
    $canDo = To-Array $skill.canDo
    if(@($canDo).Count -eq 0){ $canDo = @("extension skill: $skillName", "auto-routable from triggers and extension metadata") }
    $cannotDo = To-Array $skill.cannotDo
    if(@($cannotDo).Count -eq 0){ $cannotDo = @('skip extension setup or safety notes', 'override current user instructions or live evidence') }
    $verification = To-Array $skill.verification
    if(@($verification).Count -eq 0){ $verification = @('extension manifest is valid', 'SKILL.md exists', 'route appears in skill-capability-map query when triggers match') }
    $cap = [pscustomobject]@{
      name = $skillName
      category = $category
      role = $role
      canDo = @($canDo)
      cannotDo = @($cannotDo)
      triggers = @($triggers)
      applyAt = if($skill.applyAt){@(To-Array $skill.applyAt)}else{@('planning','execution','verification')}
      verification = @($verification)
      stopCondition = if($skill.stopCondition){[string]$skill.stopCondition}else{'Do not use when trigger intent does not match, setup is missing, or the task is safer with core Super Brain behavior.'}
      extensionId = [string]$extension.id
      extensionName = [string]$extension.name
      manifestPath = [string]$extension.manifestPath
      skillPath = $skillPath
      defaultEnabled = [bool]$extension.defaultEnabled
      setupRequired = $setupRequired
      sourceRepo = [string]$extension.sourceRepo
      sourceCommit = [string]$extension.sourceCommit
      license = [string]$extension.license
      provenance = 'extension-capability-map.ps1'
    }
    [void]$capabilities.Add($cap)
  }
}

$items = @($capabilities)
if(-not [string]::IsNullOrWhiteSpace($Query)){ $items = @($items | ForEach-Object { $match = Get-CapabilityMatch $_ $Query; $_ | Add-Member -NotePropertyName score -NotePropertyValue $match.score -Force; $_ | Add-Member -NotePropertyName matchStrength -NotePropertyValue $match.matchStrength -Force; $_ | Add-Member -NotePropertyName matchReason -NotePropertyValue $match.matchReason -Force; $_ | Add-Member -NotePropertyName matchedTriggers -NotePropertyValue @($match.matchedTriggers) -Force; $_ } | Where-Object { $_.score -gt 0 -and $_.matchStrength -ne 'none' } | Sort-Object @{Expression={if($_.matchStrength -eq 'strong'){1}else{0}};Descending=$true},score,name -Descending | Select-Object -First $TopK) }
else { $items = @($items | Select-Object -First $TopK) }

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.extension-capability-map.v1'
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $Query 260
  count = @($items).Count
  total = @($capabilities).Count
  capabilities = @($items)
  guard = 'Extension skills become ORC-routable capabilities with provenance; list/detail is for visibility, not a manual-only skill menu.'
  path = $mapPath
}
Write-JsonUtf8NoBom $mapPath ([pscustomobject]@{ schema='super-brain.extension-capability-map.v1'; updatedAt=$result.checkedAt; capabilities=@($capabilities); guard=$result.guard }) 14
Write-JsonUtf8NoBom $outPath $result 14
if($Json){ Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "EXTENSION_CAPABILITY_MAP ok=True count=$($result.count) total=$($result.total) path=$mapPath" }
exit 0

