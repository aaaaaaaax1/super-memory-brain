param(
  [ValidateSet('List','Inspect','Adopt','RebuildMap')]
  [string]$Action = 'List',
  [string]$Path = '',
  [string]$ExtensionId = '',
  [string]$Name = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$extensionsRoot = Join-Path $Root 'extensions'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
if (-not (Test-Path -LiteralPath $extensionsRoot)) { New-Item -ItemType Directory -Force -Path $extensionsRoot | Out-Null }
$outPath = Join-Path $workspace 'last-extension-ingest.json'

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Safe-Id([string]$Value){ $v=if([string]::IsNullOrWhiteSpace($Value)){'extension'}else{$Value}; (($v -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant() }
function Read-FirstLines([string]$File,[int]$Max=40){ if(-not (Test-Path -LiteralPath $File)){ return @() }; return @(Get-Content -LiteralPath $File -Encoding UTF8 -TotalCount $Max) }
function Get-InstalledState([string]$SkillName){
  $userHome = [Environment]::GetFolderPath('UserProfile')
  $roots = @((Join-Path $userHome '.zcode\skills'),(Join-Path $userHome '.codex\skills'))
  $states = @()
  foreach($root in $roots){
    $dir = Join-Path $root $SkillName
    $pkg = Join-Path $dir 'package-root.txt'
    $exists = Test-Path -LiteralPath $dir
    $marker = if(Test-Path -LiteralPath $pkg){ try{ (Get-Content -LiteralPath $pkg -Raw -Encoding UTF8).Trim() }catch{''} } else { '' }
    $states += [pscustomobject]@{ root=$root; exists=$exists; packageRoot=$marker; belongsToThisPackage=($marker -eq (Get-NormalizedSuperBrainRoot $Root)) }
  }
  return @($states)
}
function Inspect-Path([string]$CandidatePath){
  if([string]::IsNullOrWhiteSpace($CandidatePath)){ throw 'Path is required for Inspect/Adopt.' }
  $full = [System.IO.Path]::GetFullPath($CandidatePath)
  if(-not (Test-Path -LiteralPath $full)){ throw "Path not found: $full" }
  $item = Get-Item -LiteralPath $full
  $dir = if($item.PSIsContainer){ $item.FullName } else { Split-Path -Parent $item.FullName }
  $manifestPath = Join-Path $dir 'extension.json'
  $skillPath = Join-Path $dir 'SKILL.md'
  $pluginPath = Join-Path $dir '.claude-plugin\plugin.json'
  $manifest = $null
  $sourceType = 'directory'
  if(Test-Path -LiteralPath $manifestPath){ try{ $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json; $sourceType='extension_manifest' }catch{} }
  elseif(Test-Path -LiteralPath $pluginPath){ try{ $manifest = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8 | ConvertFrom-Json; $sourceType='claude_plugin' }catch{} }
  $skillText = if(Test-Path -LiteralPath $skillPath){ (Read-FirstLines $skillPath 80) -join "`n" } else { '' }
  $detectedName = if($Name){$Name}elseif($manifest.name){[string]$manifest.name}elseif($manifest.id){[string]$manifest.id}elseif($skillText -match '(?m)^name:\s*(.+)$'){$Matches[1].Trim()}else{Split-Path -Leaf $dir}
  $detectedId = if($ExtensionId){$ExtensionId}elseif($manifest.id){[string]$manifest.id}else{Safe-Id $detectedName}
  $description = if($manifest.description){[string]$manifest.description}elseif($skillText -match '(?m)^description:\s*(.+)$'){$Matches[1].Trim()}else{'Imported skill/plugin candidate.'}
  $triggers = @()
  if($manifest.triggers){ $triggers += @($manifest.triggers | ForEach-Object {[string]$_}) }
  if($manifest.skills){ foreach($s in @($manifest.skills)){ if($s.triggers){ $triggers += @($s.triggers | ForEach-Object {[string]$_}) } } }
  if($triggers.Count -eq 0){ $triggers = @($detectedName, $description) }
  $skillName = Safe-Id $detectedName
  return [pscustomobject]@{
    ok=$true; sourceType=$sourceType; path=$full; root=$dir; extensionId=(Safe-Id $detectedId); name=Limit-Text $detectedName 160; description=Limit-Text $description 500
    skillName=$skillName; skillPath=$skillPath; hasSkillMd=(Test-Path -LiteralPath $skillPath); manifestPath=if(Test-Path -LiteralPath $manifestPath){$manifestPath}else{''}; pluginPath=if(Test-Path -LiteralPath $pluginPath){$pluginPath}else{''}
    triggers=@($triggers | Select-Object -Unique | Select-Object -First 12)
    canDo=@('candidate skill/plugin can be inspected, adopted, and converted into an ORC-routable extension capability')
    cannotDo=@('be trusted without manifest/SKILL.md verification','override current Super Brain guardrails')
    setupRequired=if($manifest.setupRequired){[string]$manifest.setupRequired}else{''}
    conflicts=@(Get-InstalledState $skillName | Where-Object { $_.exists -and $_.belongsToThisPackage -ne $true })
    suggestedAction='Use -Action Adopt only after inspection looks correct; then run RebuildMap and verify-package.'
  }
}

if($Action -eq 'List'){
  $extensions = @(Get-SuperBrainExtensionManifests @() $Root)
  $items = @()
  foreach($extension in $extensions){
    $skills = @()
    foreach($skill in @($extension.skills)){ $skills += [pscustomobject]@{ name=[string]$skill.name; path=[string]$skill.path; triggers=@($skill.triggers); installedState=@(Get-InstalledState ([string]$skill.name)) } }
    $items += [pscustomobject]@{ id=[string]$extension.id; name=[string]$extension.name; defaultEnabled=[bool]$extension.defaultEnabled; skillCount=@($extension.skills).Count; skills=@($skills); manifestPath=[string]$extension.manifestPath; setupRequired=if($extension.setupRequired){[string]$extension.setupRequired}else{''} }
  }
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.extension-ingest.v1'; action=$Action; version=(Get-SuperBrainManifest $Root).version; count=@($items).Count; extensions=@($items); guard='Extension list is visibility for ORC-routable capabilities, not a manual-only skill menu.'; path=$outPath }
}
elseif($Action -eq 'Inspect'){
  $inspection = Inspect-Path $Path
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.extension-ingest.v1'; action=$Action; version=(Get-SuperBrainManifest $Root).version; inspection=$inspection; path=$outPath }
}
elseif($Action -eq 'RebuildMap'){
  $mapRaw = @(& (Join-Path $PSScriptRoot 'extension-capability-map.ps1') -Json 2>$null)
  $map = (($mapRaw -join "`n") | ConvertFrom-Json)
  $result=[pscustomobject]@{ ok=($map.ok -eq $true); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.extension-ingest.v1'; action=$Action; version=(Get-SuperBrainManifest $Root).version; extensionCapabilityMap=$map; path=$outPath }
}
else {
  $inspection = Inspect-Path $Path
  $targetRoot = Join-Path $extensionsRoot $inspection.extensionId
  $targetSkillRoot = Join-Path $targetRoot 'skills'
  if(Test-Path -LiteralPath $targetRoot){ throw "Extension target already exists: $targetRoot" }
  New-Item -ItemType Directory -Force -Path $targetSkillRoot | Out-Null
  $sourceDir = [string]$inspection.root
  $skillTarget = Join-Path $targetSkillRoot $inspection.skillName
  Copy-Item -LiteralPath $sourceDir -Destination $skillTarget -Recurse -Force
  $manifest = [pscustomobject]@{
    id=$inspection.extensionId; name=$inspection.name; type='skill-extension'; defaultEnabled=$false; sourceRepo='local'; sourceCommit='local-adopted'; license='unknown'; installNote='Local adopted extension; review setup and privacy before sharing.'
    skills=@([pscustomobject]@{ name=$inspection.skillName; path=('skills/' + $inspection.skillName); triggers=@($inspection.triggers); canDo=@($inspection.canDo); cannotDo=@($inspection.cannotDo); setupRequired=$inspection.setupRequired })
  }
  Write-JsonUtf8NoBom (Join-Path $targetRoot 'extension.json') $manifest 10
  $mapRaw = @(& (Join-Path $PSScriptRoot 'extension-capability-map.ps1') -Json 2>$null)
  $map = (($mapRaw -join "`n") | ConvertFrom-Json)
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.extension-ingest.v1'; action=$Action; version=(Get-SuperBrainManifest $Root).version; adopted=[pscustomobject]@{ extensionId=$inspection.extensionId; targetRoot=$targetRoot; skillName=$inspection.skillName; skillTarget=$skillTarget }; extensionCapabilityMap=$map; nextAction='Run verify-extensions, skill-capability-map, verify-package, and hot-refresh before relying on this extension.'; path=$outPath }
}

Write-JsonUtf8NoBom $outPath $result 14
if($Json){ Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "EXTENSION_INGEST action=$Action ok=$($result.ok) path=$outPath" }
if($result.ok -eq $false){ exit 1 }
exit 0
