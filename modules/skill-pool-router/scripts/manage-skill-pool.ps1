[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Report','Apply','Activate','Expose','Hide','Restore','Reindex','Resolve','Search')]
  [string]$Action = 'Report',
  [string]$ActiveRoot = (Join-Path $env:USERPROFILE '.codex\skills'),
  [string]$ColdRoot = (Join-Path $env:USERPROFILE '.codex-cold-skills'),
  [string]$SkillName = '',
  [string]$Query = '',
  [int]$Limit = 5,
  [string]$ManifestPath = '',
  [int]$MaxActiveSkillFiles = 30,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'skill-catalog.ps1')

$freeImageFolder = -join (@(20813,36153,29983,22270) | ForEach-Object { [char]$_ })
$hotFolders = @(
  '.system','skill-pool-router',
  'super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory','skill-evolution-loop',
  'keep-codex-fast','ponytail','diagnose','review','codebase-design','app-root-solution-advisor',
  'context7-mcp','last30days','playwright','browser-act',
  'frontend-app-builder','frontend-design','image-to-code-skill','vue-best-practices',
  'android-cli','account-key-registrar','share-mini-imagegen',$freeImageFolder
)
$protectedFolders = @('.system','skill-pool-router','super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory','skill-evolution-loop','share-mini-imagegen',$freeImageFolder)
$active = [System.IO.Path]::GetFullPath($ActiveRoot).TrimEnd('\','/')
$cold = [System.IO.Path]::GetFullPath($ColdRoot).TrimEnd('\','/')
$indexPath = Join-Path $cold 'skill-pool-index.json'
$lookupPath = Join-Path $cold 'skill-name-index.tsv'

function Write-JsonAtomic([string]$Path,[object]$Value,[int]$Depth=12) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
  $json = $Value | ConvertTo-Json -Depth $Depth
  [System.IO.File]::WriteAllText($temp,$json,(New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-TextAtomic([string]$Path,[string]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
  [System.IO.File]::WriteAllText($temp,$Value,(New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Assert-Child([string]$Parent,[string]$Child,[string]$Label) {
  $prefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
  $full = [System.IO.Path]::GetFullPath($Child)
  if (-not $full.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "SKILL_POOL_PATH_ESCAPE: $Label '$full'"
  }
}

function Assert-CodexSkillFrontmatter([string]$SkillFile) {
  if(-not(Test-Path -LiteralPath $SkillFile -PathType Leaf)){throw "SKILL_POOL_SKILL_FILE_MISSING: $SkillFile"}
  $bytes=[IO.File]::ReadAllBytes($SkillFile)
  $valid=($bytes.Length-ge3-and$bytes[0]-eq0x2D-and$bytes[1]-eq0x2D-and$bytes[2]-eq0x2D)
  if(-not$valid){throw "SKILL_POOL_CODEX_FRONTMATTER_INVALID: $SkillFile; UTF-8 without BOM must start with ---"}
}

$skillTextExtensions=@('.md','.ps1','.py','.json','.jsonl','.yaml','.yml','.txt','.js','.ts','.tsx','.jsx','.sh','.toml')
$mojibakeTokens=@(
  (-join(@(37711,23944,22402)|ForEach-Object{[char]$_})),
  (-join(@(37922,29111,27992)|ForEach-Object{[char]$_})),
  (-join(@(36423,21620,12303)|ForEach-Object{[char]$_})),
  (-join(@(37510)|ForEach-Object{[char]$_})),
  (-join(@(38171)|ForEach-Object{[char]$_})),
  (-join(@(37413)|ForEach-Object{[char]$_})),
  (-join(@(37419)|ForEach-Object{[char]$_})),
  (-join(@(28729,23678,22426)|ForEach-Object{[char]$_})),
  (-join(@(28003,36328,25956)|ForEach-Object{[char]$_})),
  (-join(@(37922,12582,22491)|ForEach-Object{[char]$_})),
  (-join(@(37826,22249,25939)|ForEach-Object{[char]$_})),
  (-join(@(37733,21095,22678)|ForEach-Object{[char]$_})),
  (-join(@(26440,25779,21446)|ForEach-Object{[char]$_})),
  (-join(@(29831,38155,30512)|ForEach-Object{[char]$_})),
  (-join(@(37721,20635,26271)|ForEach-Object{[char]$_}))
)
$mojibakePattern=($mojibakeTokens|ForEach-Object{[regex]::Escape($_)})-join'|'
$strictUtf8=New-Object System.Text.UTF8Encoding($false,$true)

function Get-SkillContentProblems([string]$Folder) {
  $problems=@()
  if(-not(Test-Path -LiteralPath $Folder -PathType Container)){
    return @([pscustomobject]@{folder=$Folder;file='';problem='folder_missing'})
  }
  foreach($file in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue)){
    if($skillTextExtensions -notcontains $file.Extension.ToLowerInvariant()){continue}
    try{$text=$strictUtf8.GetString([IO.File]::ReadAllBytes($file.FullName))}catch{
      $problems += [pscustomobject]@{folder=$Folder;file=$file.FullName;problem='invalid_utf8'}
      continue
    }
    if($text.Contains([char]0xFFFD)-or$text-match$mojibakePattern){
      $problems += [pscustomobject]@{folder=$Folder;file=$file.FullName;problem='mojibake_marker'}
    }
  }
  return @($problems)
}

function Get-CatalogContentProblems([string]$Root) {
  $problems=@()
  foreach($dir in @(Get-SkillCatalogDirectories $Root|Where-Object{-not$_.Name.StartsWith('.')-and$_.Name-ne'manifests'})){
    $problems += @(Get-SkillContentProblems $dir.FullName)
  }
  return @($problems|Sort-Object file -Unique)
}

function Assert-SkillContentHealthy([string]$Folder) {
  $problems=@(Get-SkillContentProblems $Folder)
  if($problems.Count-gt0){throw "SKILL_POOL_CONTENT_INVALID: $($problems[0].problem) $($problems[0].file)"}
}

function Assert-CatalogContentHealthy {
  $problems=@(Get-CatalogContentProblems $active)+@(Get-CatalogContentProblems $cold)
  if($problems.Count-gt0){throw "SKILL_POOL_CONTENT_INVALID: $($problems[0].problem) $($problems[0].file)"}
}

function Read-Metadata([string]$Folder) {
  $file = Get-ChildItem -LiteralPath $Folder -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $file) { return [pscustomobject]@{ name=(Split-Path -Leaf $Folder); description=''; skillFile=''; sha256='' } }
  $name = Split-Path -Leaf $Folder
  $description = ''
  $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 80)
  for($lineIndex=0;$lineIndex -lt $lines.Count;$lineIndex++) {
    $line = [string]$lines[$lineIndex]
    if ($line -match '^name:\s*(.*)$') { $name = ([string]$Matches[1]).Trim().Trim('"').Trim("'") }
    if ($line -match '^description:\s*(.*)$') {
      $description = ([string]$Matches[1]).Trim().Trim('"').Trim("'")
      if([string]::IsNullOrWhiteSpace($description) -or $description -in @('>','>-','|','|-')) {
        $parts=@()
        for($next=$lineIndex+1;$next -lt $lines.Count;$next++) {
          $candidate=[string]$lines[$next]
          if($candidate -eq '---' -or $candidate -match '^[A-Za-z0-9_.-]+:\s*'){break}
          if(-not[string]::IsNullOrWhiteSpace($candidate)){$parts += $candidate.Trim()}
        }
        $description=($parts -join ' ')
      }
    }
  }
  if([string]::IsNullOrWhiteSpace($description)) {
    $description = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^---$' -and $_ -notmatch '^#' -and $_ -notmatch '^[A-Za-z0-9_.-]+:\s*' } | Select-Object -First 2 | ForEach-Object { $_.Trim('`',' ') }) -join ' '
  }
  return [pscustomobject]@{ name=$name; description=$description; skillFile=$file.FullName; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
}

function Get-Stats([string]$Root) {
  $files = @(Get-SkillCatalogFiles $Root)
  $descriptionChars = 0
  foreach($file in $files){$meta=Read-Metadata (Split-Path -Parent $file.FullName);$descriptionChars += $meta.description.Length}
  return [pscustomobject]@{ skillFiles=$files.Count; descriptionChars=$descriptionChars; skillBytes=(@($files|Measure-Object Length -Sum).Sum) }
}

function Get-ColdEntries {
  if(-not(Test-Path -LiteralPath $cold)){return @()}
  $entries=@()
  foreach($dir in @(Get-SkillCatalogDirectories $cold | Where-Object{-not $_.Name.StartsWith('.') -and $_.Name -ne 'manifests'})){
    $meta=Read-Metadata $dir.FullName
    if([string]::IsNullOrWhiteSpace($meta.skillFile)){continue}
    $entries += [pscustomobject]@{folder=$dir.Name;name=$meta.name;description=$meta.description;coldPath=$dir.FullName;activePath=(Join-Path $active $dir.Name);skillFile=$meta.skillFile;sha256=$meta.sha256}
  }
  return @($entries|Sort-Object folder)
}

function Get-ActiveEntries {
  $entries=@()
  foreach($file in @(Get-SkillCatalogFiles $active)){
    $folderPath=Split-Path -Parent $file.FullName
    $folder=Split-Path -Leaf $folderPath
    $meta=Read-Metadata $folderPath
    if([string]::IsNullOrWhiteSpace($meta.skillFile)){continue}
    $entries += [pscustomobject]@{source='active';folder=$folder;name=$meta.name;description=$meta.description;activePath=$folderPath;coldPath='';skillFile=$meta.skillFile;sha256=$meta.sha256}
  }
  return @($entries|Sort-Object folder)
}

function Get-Value([object]$Object,[string]$Name) {
  if($Object -is [System.Collections.IDictionary]){return $Object[$Name]}
  $property=$Object.PSObject.Properties[$Name]
  if($property){return $property.Value}
  return $null
}

function Read-ColdIndex {
  if(-not(Test-Path -LiteralPath $indexPath)){throw "SKILL_POOL_INDEX_MISSING: $indexPath; run Reindex"}
  $raw=[System.IO.File]::ReadAllText($indexPath,[System.Text.Encoding]::UTF8)
  try{return ($raw|ConvertFrom-Json)}catch{
    try{
      Add-Type -AssemblyName System.Web.Extensions
      $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
      $serializer.MaxJsonLength=[int]::MaxValue
      return $serializer.DeserializeObject($raw)
    }catch{throw "SKILL_POOL_INDEX_INVALID: $indexPath; run Reindex"}
  }
}

function Get-IndexedEntries {
  $index=Read-ColdIndex
  return @((Get-Value $index 'entries'))
}

function Test-IndexedEntry([object]$Entry) {
  $skillFile=[string](Get-Value $Entry 'skillFile')
  $expectedHash=[string](Get-Value $Entry 'sha256')
  if([string]::IsNullOrWhiteSpace($skillFile)-or-not(Test-Path -LiteralPath $skillFile)){throw "SKILL_POOL_INDEXED_FILE_MISSING: $skillFile"}
  Assert-Child $cold $skillFile 'indexed skill file'
  Assert-SkillContentHealthy (Split-Path -Parent $skillFile)
  $actualHash=(Get-FileHash -LiteralPath $skillFile -Algorithm SHA256).Hash
  if($actualHash -ne $expectedHash){throw "SKILL_POOL_HASH_MISMATCH: $skillFile; run Reindex after reviewing the change"}
  return [pscustomobject]@{
    folder=[string](Get-Value $Entry 'folder');name=[string](Get-Value $Entry 'name');description=[string](Get-Value $Entry 'description')
    skillFile=$skillFile;sha256=$actualHash;verified=$true;loadInPlace=$true;requiresActivation=$false;requiresRestart=$false
  }
}

function Test-ActiveEntry([object]$Entry) {
  $skillFile=[string](Get-Value $Entry 'skillFile')
  if([string]::IsNullOrWhiteSpace($skillFile)-or-not(Test-Path -LiteralPath $skillFile)){throw "SKILL_POOL_ACTIVE_FILE_MISSING: $skillFile"}
  Assert-Child $active $skillFile 'active skill file'
  Assert-SkillContentHealthy (Split-Path -Parent $skillFile)
  $actualHash=(Get-FileHash -LiteralPath $skillFile -Algorithm SHA256).Hash
  return [pscustomobject]@{
    source='active';folder=[string](Get-Value $Entry 'folder');name=[string](Get-Value $Entry 'name');description=[string](Get-Value $Entry 'description')
    skillFile=$skillFile;sha256=$actualHash;verified=$true;loadInPlace=$true;requiresActivation=$false;requiresRestart=$false
  }
}

function Write-Index([string]$Reason) {
  Assert-CatalogContentHealthy
  $entries=@(Get-ColdEntries)
  $value=[pscustomobject]@{schema='codex.skill-pool-index.v1';updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');reason=$Reason;activeRoot=$active;coldRoot=$cold;count=$entries.Count;entries=$entries}
  Write-JsonAtomic $indexPath $value 10
  $lookup=@('codex.skill-name-index.v1')
  $activeSkillFiles=@(Get-SkillCatalogFiles $active)
  foreach($file in $activeSkillFiles){
    $folder=Split-Path -Leaf (Split-Path -Parent $file.FullName)
    $meta=Read-Metadata (Split-Path -Parent $file.FullName)
    if(@($folder,$meta.name,$file.FullName,$meta.sha256)|Where-Object{([string]$_).Contains("`t")-or([string]$_).Contains("`n")}){continue}
    $lookup += "active`t$folder`t$($meta.name)`t$($file.FullName)`t$($meta.sha256)"
  }
  foreach($entry in $entries){
    if(@($entry.folder,$entry.name,$entry.skillFile,$entry.sha256)|Where-Object{([string]$_).Contains("`t")-or([string]$_).Contains("`n")}){continue}
    $lookup += "cold`t$($entry.folder)`t$($entry.name)`t$($entry.skillFile)`t$($entry.sha256)"
  }
  Write-TextAtomic $lookupPath (($lookup -join "`n")+"`n")
  return $value
}

if(-not(Test-Path -LiteralPath $active)){throw "SKILL_POOL_ACTIVE_ROOT_MISSING: $active"}
if($active.Equals($cold,[System.StringComparison]::OrdinalIgnoreCase)){throw 'SKILL_POOL_ROOTS_MUST_DIFFER'}

if($Action -eq 'Reindex'){
  if(-not(Test-Path -LiteralPath $cold)){throw "SKILL_POOL_COLD_ROOT_MISSING: $cold"}
  $index=Write-Index 'reindex'
  $result=[pscustomobject]@{ok=$true;action=$Action;coldCount=$index.count;index=$indexPath;lookupIndex=$lookupPath}
  if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SKILL_POOL_REINDEXED count=$($index.count)"}
  exit 0
}

if($Action -eq 'Resolve'){
  if([string]::IsNullOrWhiteSpace($SkillName)){throw 'SKILL_POOL_RESOLVE_REQUIRES_NAME'}
  $activeMatches=@(Get-ActiveEntries|Where-Object{([string]$_.folder) -ieq $SkillName -or ([string]$_.name) -ieq $SkillName})
  if($activeMatches.Count -gt 1){throw "SKILL_POOL_AMBIGUOUS_ACTIVE_NAME: $SkillName"}
  if($activeMatches.Count -eq 1){
    $resolved=Test-ActiveEntry $activeMatches[0]
    $result=[pscustomobject]@{ok=$true;action=$Action;status='resolved_active_in_place';query=$SkillName;checkedActiveCatalog=$true;checkedColdIndex=$false;skill=$resolved;instruction='Read skillFile now and follow it in the current task. Do not activate or restart.'}
    if($Json){$result|ConvertTo-Json -Depth 6}else{Write-Host "SKILL_POOL_RESOLVED_ACTIVE skill=$($resolved.name) file=$($resolved.skillFile)"}
    exit 0
  }
  $matches=@(Get-IndexedEntries|Where-Object{([string](Get-Value $_ 'folder')) -ieq $SkillName -or ([string](Get-Value $_ 'name')) -ieq $SkillName})
  if($matches.Count -eq 0){
    $result=[pscustomobject]@{ok=$false;action=$Action;status='not_found_after_active_and_cold_check';query=$SkillName;index=$indexPath;checkedActiveCatalog=$true;checkedColdIndex=$true}
    if($Json){$result|ConvertTo-Json -Depth 6}else{Write-Host "SKILL_POOL_NOT_FOUND name=$SkillName"}
    exit 1
  }
  if($matches.Count -gt 1){throw "SKILL_POOL_AMBIGUOUS_NAME: $SkillName"}
  $resolved=Test-IndexedEntry $matches[0]
  $result=[pscustomobject]@{ok=$true;action=$Action;status='resolved_cold_in_place';query=$SkillName;checkedActiveCatalog=$true;checkedColdIndex=$true;skill=$resolved;instruction='Read skillFile now and follow it in the current task. Do not activate or restart.'}
  if($Json){$result|ConvertTo-Json -Depth 6}else{Write-Host "SKILL_POOL_RESOLVED skill=$($resolved.name) file=$($resolved.skillFile)"}
  exit 0
}

if($Action -eq 'Search'){
  if([string]::IsNullOrWhiteSpace($Query)){throw 'SKILL_POOL_SEARCH_REQUIRES_QUERY'}
  if($Limit -lt 1 -or $Limit -gt 20){throw 'SKILL_POOL_SEARCH_LIMIT_RANGE: 1..20'}
  $tokens=@($Query.ToLowerInvariant() -split '[^\p{L}\p{N}_.-]+'|Where-Object{$_.Length-ge2}|Select-Object -Unique)
  $rankedItems=@(foreach($entry in Get-IndexedEntries){
    $folder=[string](Get-Value $entry 'folder');$name=[string](Get-Value $entry 'name');$description=[string](Get-Value $entry 'description')
    $haystack=("$folder $name $description").ToLowerInvariant();$score=0
    if($folder -ieq $Query -or $name -ieq $Query){$score+=100}
    if($haystack.Contains($Query.ToLowerInvariant())){$score+=20}
    foreach($token in $tokens){if($haystack.Contains($token)){$score+=3}}
    if($score-gt0){[pscustomobject]@{score=$score;entry=$entry}}
  })
  $ranked=@($rankedItems|Sort-Object score -Descending)
  $matches=@($ranked|Select-Object -First $Limit|ForEach-Object{Test-IndexedEntry $_.entry})
  $result=[pscustomobject]@{ok=$true;action=$Action;query=$Query;checkedColdIndex=$true;count=$matches.Count;matches=$matches;instruction='Select at most one exact capability match, read its skillFile in place, and continue without activation or restart.'}
  if($Json){$result|ConvertTo-Json -Depth 7}else{Write-Host "SKILL_POOL_SEARCH matches=$($matches.Count)";$matches|Format-Table name,folder,skillFile}
  exit 0
}

if($Action -eq 'Activate'){
  if([string]::IsNullOrWhiteSpace($SkillName)){throw 'SKILL_POOL_ACTIVATE_REQUIRES_NAME'}
  $entry=@(Get-ColdEntries|Where-Object{$_.folder -ieq $SkillName -or $_.name -ieq $SkillName})|Select-Object -First 1
  if(-not $entry){throw "SKILL_POOL_SKILL_NOT_FOUND: $SkillName"}
  $destination=Join-Path $active $entry.folder
  Assert-CodexSkillFrontmatter $entry.skillFile
  Assert-SkillContentHealthy $entry.coldPath
  Assert-Child $cold $entry.coldPath 'activate source'
  Assert-Child $active $destination 'activate destination'
  if(Test-Path -LiteralPath $destination){throw "SKILL_POOL_DESTINATION_EXISTS: $destination"}
  Move-Item -LiteralPath $entry.coldPath -Destination $destination
  $index=Write-Index 'activate'
  $result=[pscustomobject]@{ok=$true;action=$Action;skill=$entry.folder;activePath=$destination;coldCount=$index.count;note='Open a new Codex session to refresh the catalog.'}
  if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SKILL_POOL_ACTIVATED skill=$($entry.folder)"}
  exit 0
}

if($Action -eq 'Expose'){
  if([string]::IsNullOrWhiteSpace($SkillName)){throw 'SKILL_POOL_EXPOSE_REQUIRES_NAME'}
  $entry=@(Get-ColdEntries|Where-Object{$_.folder -ieq $SkillName -or $_.name -ieq $SkillName})|Select-Object -First 1
  if(-not $entry){throw "SKILL_POOL_SKILL_NOT_FOUND: $SkillName"}
  $destination=Join-Path $active $entry.folder
  Assert-CodexSkillFrontmatter $entry.skillFile
  Assert-SkillContentHealthy $entry.coldPath
  Assert-Child $cold $entry.coldPath 'expose target'
  Assert-Child $active $destination 'expose destination'
  if(Test-Path -LiteralPath $destination){throw "SKILL_POOL_DESTINATION_EXISTS: $destination"}
  New-Item -ItemType Junction -Path $destination -Target $entry.coldPath | Out-Null
  $index=Write-Index 'expose'
  $result=[pscustomobject]@{ok=$true;action=$Action;skill=$entry.folder;activePath=$destination;coldPath=$entry.coldPath;coldPreserved=(Test-Path -LiteralPath $entry.coldPath);coldCount=$index.count;note='Cold source preserved. Open a new Codex task to refresh the catalog.'}
  if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SKILL_POOL_EXPOSED skill=$($entry.folder)"}
  exit 0
}

if($Action -eq 'Hide'){
  if([string]::IsNullOrWhiteSpace($SkillName)){throw 'SKILL_POOL_HIDE_REQUIRES_NAME'}
  $entry=@(Get-ActiveEntries|Where-Object{([string]$_.folder) -ieq $SkillName -or ([string]$_.name) -ieq $SkillName})|Select-Object -First 1
  if(-not $entry){throw "SKILL_POOL_ACTIVE_SKILL_NOT_FOUND: $SkillName"}
  $destination=[string]$entry.activePath
  Assert-Child $active $destination 'hide destination'
  $item=Get-Item -LiteralPath $destination -Force
  if(-not$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)-or$item.LinkType-ne'Junction'){throw "SKILL_POOL_HIDE_REQUIRES_JUNCTION: $destination"}
  $target=[string](@($item.Target)|Select-Object -First 1)
  Assert-Child $cold $target 'hide target'
  [IO.Directory]::Delete($destination)
  $index=Write-Index 'hide'
  $result=[pscustomobject]@{ok=$true;action=$Action;skill=$entry.folder;activePath=$destination;coldPath=$target;coldPreserved=(Test-Path -LiteralPath $target);coldCount=$index.count;note='Only the active junction was removed; the cold skill remains intact.'}
  if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SKILL_POOL_HIDDEN skill=$($entry.folder)"}
  exit 0
}

if($Action -eq 'Restore'){
  if([string]::IsNullOrWhiteSpace($ManifestPath)){throw 'SKILL_POOL_RESTORE_REQUIRES_MANIFEST'}
  $manifest=Get-Content -LiteralPath ([System.IO.Path]::GetFullPath($ManifestPath)) -Raw -Encoding UTF8|ConvertFrom-Json
  $restored=@()
  foreach($item in @($manifest.items)){
    Assert-Child $cold ([string]$item.coldPath) 'restore source'
    Assert-Child $active ([string]$item.activePath) 'restore destination'
    if(-not(Test-Path -LiteralPath $item.coldPath)){continue}
    if(Test-Path -LiteralPath $item.activePath){throw "SKILL_POOL_RESTORE_DESTINATION_EXISTS: $($item.activePath)"}
    Move-Item -LiteralPath $item.coldPath -Destination $item.activePath
    $restored += [string]$item.folder
  }
  $index=Write-Index 'restore'
  $result=[pscustomobject]@{ok=$true;action=$Action;restoredCount=$restored.Count;restored=$restored;coldCount=$index.count}
  if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SKILL_POOL_RESTORED count=$($restored.Count)"}
  exit 0
}

$hot=@{}
foreach($name in $hotFolders){$hot[$name.ToLowerInvariant()]=$true}
$dirs=@(Get-SkillCatalogDirectories $active)
$candidates=@($dirs|Where-Object{-not $hot.ContainsKey($_.Name.ToLowerInvariant())})
$conflicts=@($candidates|Where-Object{Test-Path -LiteralPath (Join-Path $cold $_.Name)}|ForEach-Object{$_.Name})
$before=Get-Stats $active
$candidateFiles=@($candidates|ForEach-Object{Get-SkillCatalogFiles $_.FullName}).Count
$projected=$before.skillFiles-$candidateFiles
$contentProblems=@(Get-CatalogContentProblems $active)+@(Get-CatalogContentProblems $cold)
$report=[pscustomobject]@{ok=($conflicts.Count-eq0-and $projected-le$MaxActiveSkillFiles-and$contentProblems.Count-eq0);action=$Action;activeRoot=$active;coldRoot=$cold;before=$before;projectedActiveSkillFiles=$projected;maxActiveSkillFiles=$MaxActiveSkillFiles;hotFolders=$hotFolders;candidateCount=$candidates.Count;candidates=@($candidates.Name|Sort-Object);conflicts=$conflicts;contentProblemCount=$contentProblems.Count;contentProblems=$contentProblems;noWrites=($Action-eq'Report')}

if($Action -eq 'Report'){
  if($Json){$report|ConvertTo-Json -Depth 10}else{Write-Host "SKILL_POOL_REPORT active=$($before.skillFiles) projected=$projected candidates=$($candidates.Count) conflicts=$($conflicts.Count)"}
  if(-not $report.ok){exit 1};exit 0
}
if(-not $report.ok){throw "SKILL_POOL_APPLY_BLOCKED: projected=$projected conflicts=$($conflicts -join ',')"}
foreach($name in $protectedFolders){if($candidates.Name -contains $name){throw "SKILL_POOL_PROTECTED_CANDIDATE: $name"}}

New-Item -ItemType Directory -Force -Path $cold|Out-Null
$manifestRoot=Join-Path $cold 'manifests'
New-Item -ItemType Directory -Force -Path $manifestRoot|Out-Null
$manifestFile=Join-Path $manifestRoot ("skill-pool-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$items=@($candidates|ForEach-Object{$meta=Read-Metadata $_.FullName;[pscustomobject]@{folder=$_.Name;name=$meta.name;description=$meta.description;reason='outside lightweight active profile; preserved in cold pool';activePath=$_.FullName;coldPath=(Join-Path $cold $_.Name);skillSha256=$meta.sha256}})
$manifest=[pscustomobject]@{schema='codex.skill-pool-move.v1';status='planned';createdAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');activeRoot=$active;coldRoot=$cold;before=$before;projectedActiveSkillFiles=$projected;items=$items}
Write-JsonAtomic $manifestFile $manifest 10
$moved=@()
try{
  foreach($item in $items){Assert-Child $active $item.activePath 'apply source';Assert-Child $cold $item.coldPath 'apply destination';Move-Item -LiteralPath $item.activePath -Destination $item.coldPath;$moved += $item}
}catch{
  for($i=$moved.Count-1;$i-ge0;$i--){$item=$moved[$i];if((Test-Path -LiteralPath $item.coldPath)-and-not(Test-Path -LiteralPath $item.activePath)){Move-Item -LiteralPath $item.coldPath -Destination $item.activePath}}
  $manifest.status='rolled_back';$manifest|Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force;Write-JsonAtomic $manifestFile $manifest 10;throw
}
$after=Get-Stats $active
$index=Write-Index 'apply'
$manifest.status='applied';$manifest|Add-Member -NotePropertyName appliedAt -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force;$manifest|Add-Member -NotePropertyName after -NotePropertyValue $after -Force;$manifest|Add-Member -NotePropertyName indexPath -NotePropertyValue $indexPath -Force
Write-JsonAtomic $manifestFile $manifest 10
$result=[pscustomobject]@{ok=$true;action=$Action;movedCount=$moved.Count;activeBefore=$before;activeAfter=$after;coldCount=$index.count;manifest=$manifestFile;index=$indexPath;note='No skills were deleted. Open a new Codex session to load the smaller catalog.'}
if($Json){$result|ConvertTo-Json -Depth 10}else{Write-Host "SKILL_POOL_APPLIED moved=$($moved.Count) active=$($after.skillFiles)"}
