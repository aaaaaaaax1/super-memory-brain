param(
  [string]$Query = '',
  [string]$Category = '',
  [string]$Role = '',
  [string]$Name = '',
  [int]$TopK = 8,
  [switch]$List,
  [switch]$Detail,
  [switch]$IncludeAuditHints,
  [switch]$NoExtensions,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$mapPath = Join-Path $workspace 'skill-capability-map.json'
$extensionMapPath = Join-Path $workspace 'extension-capability-map.json'
$outPath = Join-Path $workspace 'last-skill-capability-map.json'

function Limit-Text([string]$Value,[int]$Max=260){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Score-Capability($Cap,[string]$Needle){
  $score = 0
  $query = $Needle.ToLowerInvariant()
  $reverseLabNegativePatterns = @('reverse a string','generic security talk','security awareness','user agent','逆向思维','反向排序')
  if(([string]$Cap.name -eq 'reverselab-unified' -or [string]$Cap.extensionId -eq 'reverselab-unified') -and @($reverseLabNegativePatterns | Where-Object { $query.Contains($_) }).Count -gt 0){ return 0 }
  $terms = @($query -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 })
  $genericTerms = @('reverse','reversing','security','talk','generic','awareness','string','agent','user','what','common','tips','sort')
  if(([string]$Cap.name -eq 'reverselab-unified' -or [string]$Cap.extensionId -eq 'reverselab-unified') -and @($terms).Count -gt 0 -and @($terms | Where-Object { $genericTerms -notcontains $_ }).Count -eq 0){ return 0 }
  $haystack = (($Cap.name,$Cap.category,$Cap.role,(@($Cap.canDo)-join ' '),(@($Cap.triggers)-join ' '),(@($Cap.applyAt)-join ' '),(@($Cap.verification)-join ' '),$Cap.extensionId,$Cap.extensionName) -join ' ').ToLowerInvariant()
  foreach($term in $terms){ if($haystack.Contains($term)){ $score += 1 } }
  if(-not [string]::IsNullOrWhiteSpace($Category) -and [string]$Cap.category -eq $Category){ $score += 3 }
  if(-not [string]::IsNullOrWhiteSpace($Role) -and [string]$Cap.role -eq $Role){ $score += 3 }
  return $score
}
function Normalize-Capability($Cap,[int]$Score=0,[switch]$Full){
  $base = [ordered]@{ name=[string]$Cap.name; category=[string]$Cap.category; role=[string]$Cap.role; score=$Score; canDo=@($Cap.canDo); cannotDo=@($Cap.cannotDo); triggers=@($Cap.triggers); applyAt=@($Cap.applyAt); verification=@($Cap.verification); stopCondition=if($Cap.stopCondition){[string]$Cap.stopCondition}else{''} }
  foreach($field in @('extensionId','extensionName','setupRequired','defaultEnabled','manifestPath','skillPath','sourceRepo','sourceCommit','license','provenance')){ if($null -ne $Cap.$field -and -not [string]::IsNullOrWhiteSpace([string]$Cap.$field)){ $base[$field] = $Cap.$field } }
  if(-not $Full){ $base['canDo'] = @($base['canDo'] | Select-Object -First 3); $base['cannotDo'] = @($base['cannotDo'] | Select-Object -First 2); $base['triggers'] = @($base['triggers'] | Select-Object -First 6); $base['verification'] = @($base['verification'] | Select-Object -First 3) }
  return [pscustomobject]$base
}

if(-not (Test-Path -LiteralPath $mapPath)){ throw "skill capability map missing: $mapPath" }
if(-not $NoExtensions){ try { & (Join-Path $PSScriptRoot 'extension-capability-map.ps1') -Json | Out-Null } catch {} }
$map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($map.capabilities)
if((-not $NoExtensions) -and (Test-Path -LiteralPath $extensionMapPath)){ try { $extensionMap = Get-Content -LiteralPath $extensionMapPath -Raw -Encoding UTF8 | ConvertFrom-Json; $items += @($extensionMap.capabilities) } catch {} }
$view = if($List){'list'}elseif(-not [string]::IsNullOrWhiteSpace($Name) -or $Detail){'detail'}else{'search'}
if(-not [string]::IsNullOrWhiteSpace($Category)){ $items = @($items | Where-Object { [string]$_.category -eq $Category }) }
if(-not [string]::IsNullOrWhiteSpace($Role)){ $items = @($items | Where-Object { [string]$_.role -eq $Role }) }
if(-not [string]::IsNullOrWhiteSpace($Name)){
  $needle = $Name.ToLowerInvariant()
  $items = @($items | Where-Object { ([string]$_.name).ToLowerInvariant() -eq $needle -or ([string]$_.name).ToLowerInvariant().Contains($needle) -or ([string]$_.extensionId).ToLowerInvariant() -eq $needle })
  $Detail = $true
}
elseif(-not $List -and -not [string]::IsNullOrWhiteSpace($Query)){
  $items = @($items | ForEach-Object { $score = Score-Capability $_ $Query; Normalize-Capability $_ $score -Full:$Detail } | Sort-Object score,name -Descending | Select-Object -First $TopK)
}

if($List -or -not [string]::IsNullOrWhiteSpace($Name) -or $Detail -or [string]::IsNullOrWhiteSpace($Query)){
  $ranked = @($items | ForEach-Object { $score = if([string]::IsNullOrWhiteSpace($Query)){0}else{Score-Capability $_ $Query}; Normalize-Capability $_ $score -Full:$Detail } | Sort-Object category,role,name | Select-Object -First $TopK)
}else{
  $ranked = @($items)
}
$auditHints = @()
if($IncludeAuditHints){
  $auditHintRoles = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair','extension_capability')
  $auditHints = @($auditHintRoles | ForEach-Object { [pscustomobject]@{ role=$_; present=(@($ranked.role) -contains $_) } })
}
$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.skill-capability-map.result.v1'
  version = (Get-SuperBrainManifest $Root).version
  view = $view
  query = Limit-Text $Query 260
  name = Limit-Text $Name 160
  category = $Category
  role = $Role
  count = @($ranked).Count
  totalKnown = @($map.capabilities).Count + $(if(Test-Path -LiteralPath $extensionMapPath){try{@((Get-Content -LiteralPath $extensionMapPath -Raw -Encoding UTF8 | ConvertFrom-Json).capabilities).Count}catch{0}}else{0})
  capabilities = @($ranked)
  auditHints = @($auditHints)
  sources = @($mapPath,$extensionMapPath | Where-Object { Test-Path -LiteralPath $_ })
  guard = 'Use this map to combine skills as internal execution constraints, verifiers, executors, references, extension capabilities, or coordinators; do not force the user to remember skill names.'
  path = $mapPath
}
Write-JsonUtf8NoBom $outPath $result 14
if($Json){ Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  if($view -eq 'detail'){ foreach($cap in @($ranked)){ Write-Host "SKILL_DETAIL name=$($cap.name) role=$($cap.role) category=$($cap.category) triggers=$((@($cap.triggers)|Select-Object -First 4)-join ',')" } }
  else { Write-Host "SKILL_CAPABILITY_MAP ok=True view=$view count=$($result.count) path=$mapPath"; foreach($cap in @($ranked | Select-Object -First 20)){ Write-Host "SKILL name=$($cap.name) role=$($cap.role) category=$($cap.category)" } }
}
exit 0

