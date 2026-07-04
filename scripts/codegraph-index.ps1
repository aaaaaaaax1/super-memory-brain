param(
  [switch]$Json,
  [switch]$IncludeInternal,
  [switch]$NoWrite
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

$manifest = Get-SuperBrainManifest $Root
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$indexPath = Join-Path $workspace 'codegraph-index.json'
$statusPath = Join-Path $workspace 'last-codegraph-index.json'

$metadataByPath = @{}
foreach ($entry in @($manifest.scriptMetadata)) {
  if (-not [string]::IsNullOrWhiteSpace([string]$entry.path)) { $metadataByPath[[string]$entry.path] = $entry }
}

$internal = @($manifest.internalScripts | ForEach-Object { [string]$_ })
$scriptNames = @($manifest.scripts | Where-Object { [string]$_ -like '*.ps1' } | ForEach-Object { [string]$_ })
if ($IncludeInternal) { $scriptNames = @($scriptNames + $internal | Where-Object { [string]$_ -like '*.ps1' } | Select-Object -Unique) }
$scriptNames = @($scriptNames | Sort-Object -Unique)

$mutationMarkers = @('Remove-Item','Set-Content','Add-Content','Copy-Item','New-Item','Compress-Archive','Write-JsonUtf8NoBom','Add-Utf8LineLocked')
$readMarkers = @('Read-WorkspaceJson','Get-Content','ConvertFrom-Json','Read-JsonOrNull')
$writeMarkers = @('Write-JsonUtf8NoBom','Add-Utf8LineLocked','Set-Content','Write-Utf8NoBom')
$nodes = @(); $edges = @(); $scripts = @(); $parseErrors = @(); $missingMetadata = @(); $workspaceNodes = @{}

function Normalize-ScriptPath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = ($Value -replace '\\','/').Trim()
  $idx = $v.LastIndexOf('/scripts/')
  if ($idx -ge 0) { return $v.Substring($idx + 9) }
  if ($v.StartsWith('scripts/')) { return $v.Substring(8) }
  return (Split-Path -Leaf $v)
}
function Add-Node([string]$Id, [string]$Type, [string]$Path, [hashtable]$Extra = @{}) {
  $obj = [ordered]@{ id=$Id; type=$Type; path=$Path }
  foreach ($key in $Extra.Keys) { $obj[$key] = $Extra[$key] }
  [pscustomobject]$obj
}
function Add-Edge([string]$From, [string]$Relation, [string]$To, [string]$Evidence = '') {
  [pscustomobject]@{ from=$From; relation=$Relation; to=$To; evidence=$Evidence }
}
function Add-WorkspaceNode([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return }
  if (-not $script:workspaceNodes.ContainsKey($Name)) {
    $id = "workspace:$Name"
    $script:workspaceNodes[$Name] = $id
    $script:nodes += Add-Node $id 'workspace_file' "memory/workspace/$Name" @{ name=$Name }
  }
}
function Has-AnyMarker([string]$Text, [string[]]$Markers) {
  foreach ($m in @($Markers)) { if ($Text -like "*$m*") { return $true } }
  return $false
}

foreach ($script in $scriptNames) {
  if (-not $IncludeInternal -and ($internal -contains $script)) { continue }
  $full = Join-Path (Join-Path $Root 'scripts') $script
  $meta = if ($metadataByPath.ContainsKey($script)) { $metadataByPath[$script] } else { $null }
  if ($null -eq $meta) { $missingMetadata += $script }

  $exists = Test-Path -LiteralPath $full
  $raw = if ($exists) { Get-Content -LiteralPath $full -Raw -Encoding UTF8 } else { '' }
  $hasMutation = $false; $mutationHits = @()
  foreach ($marker in $mutationMarkers) { if ($raw -like "*$marker*") { $hasMutation = $true; $mutationHits += $marker } }

  $scriptId = "script:$script"
  $nodes += Add-Node $scriptId 'script' "scripts/$script" @{ tier=if($meta){[string]$meta.tier}else{''}; manualOnly=if($meta){[bool]$meta.manualOnly}else{$false}; dangerousSwitches=if($meta){@($meta.dangerousSwitches)}else{@()}; hasMutation=$hasMutation; exists=$exists }

  $tokens = $null; $errors = $null; $ast = $null; $functions = @(); $params = @()
  if ($exists) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    foreach ($err in @($errors)) { $parseErrors += [pscustomobject]@{ script=$script; message=$err.Message; line=$err.Extent.StartLineNumber; column=$err.Extent.StartColumnNumber } }
    if ($ast.ParamBlock) {
      foreach ($p in @($ast.ParamBlock.Parameters)) {
        $name = [string]$p.Name.VariablePath.UserPath; if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $params += $name; $paramId = "param:$script`:$name"
        $nodes += Add-Node $paramId 'param' "scripts/$script" @{ name=$name }
        $edges += Add-Edge $scriptId 'declares_param' $paramId 'top-level ParamBlock'
      }
    }
    foreach ($fn in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
      $name = [string]$fn.Name; if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $functions += $name; $fnId = "function:$script`:$name"
      $nodes += Add-Node $fnId 'function' "scripts/$script" @{ name=$name; line=$fn.Extent.StartLineNumber }
      $edges += Add-Edge $scriptId 'defines_function' $fnId "line:$($fn.Extent.StartLineNumber)"
    }
  }

  $callTargets = @(); $callDetails = @(); $unknownDynamic = @()
  foreach ($match in [regex]::Matches($raw, "(?i)(?:scripts[\\/])?([A-Za-z0-9_.-]+\.ps1)")) {
    $target = Normalize-ScriptPath $match.Groups[1].Value
    if ($target -and $target -ne $script -and $scriptNames -contains $target) { $callTargets += $target; $callDetails += [pscustomobject]@{ target=$target; kind='script_call_literal' } }
  }
  foreach ($match in [regex]::Matches($raw, '(?is)Join-Path\s+\$PSScriptRoot\s+[''\"]([^''\"]+\.ps1)[''\"]')) {
    $target = Normalize-ScriptPath $match.Groups[1].Value
    if ($target -and $target -ne $script -and $scriptNames -contains $target) { $callTargets += $target; $callDetails += [pscustomobject]@{ target=$target; kind='script_call_joinpath' } }
  }
  foreach ($match in [regex]::Matches($raw, '(?is)Run-Step\s+[''\"][^''\"]+[''\"]\s+\([^\)]*[''\"]([^''\"]+\.ps1)[''\"]')) {
    $target = Normalize-ScriptPath $match.Groups[1].Value
    if ($target -and $target -ne $script -and $scriptNames -contains $target) { $callTargets += $target; $callDetails += [pscustomobject]@{ target=$target; kind='script_call_runstep' } }
  }
  $varTargets = @{}
  foreach ($match in [regex]::Matches($raw, '(?im)^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:Join-Path\s+\$PSScriptRoot\s+)?[''\"]([^''\"]+\.ps1)[''\"]')) {
    $varTargets[$match.Groups[1].Value] = Normalize-ScriptPath $match.Groups[2].Value
  }
  foreach ($match in [regex]::Matches($raw, '(?im)&\s+\$([A-Za-z_][A-Za-z0-9_]*)')) {
    $var = $match.Groups[1].Value
    if ($varTargets.ContainsKey($var)) {
      $target = $varTargets[$var]
      if ($target -and $target -ne $script -and $scriptNames -contains $target) { $callTargets += $target; $callDetails += [pscustomobject]@{ target=$target; kind='script_call_variable'; variable=$var } }
    } else { $unknownDynamic += "& `$$var" }
  }
  if ($exists -and $ast) {
    foreach ($cmd in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
      $cmdName = $cmd.GetCommandName()
      if ($cmdName -in @('Invoke-Expression','iex')) { $unknownDynamic += $cmdName }
    }
  }

  foreach ($detail in @($callDetails | Sort-Object kind,target -Unique)) { $edges += Add-Edge $scriptId $detail.kind "script:$($detail.target)" 'PowerShell static call analysis' }
  foreach ($unk in @($unknownDynamic | Sort-Object -Unique)) { $edges += Add-Edge $scriptId 'script_call_dynamic_unknown' 'script:unknown' $unk }
  $callTargets = @($callTargets | Sort-Object -Unique)

  $workspaceRefs = @(); $workspaceReads = @(); $workspaceWrites = @()
  foreach ($match in [regex]::Matches($raw, '(?i)([A-Za-z0-9_.-]*(?:last-[A-Za-z0-9_.-]+|status-card|super-brain-state|session-binding|codegraph-index|project-graph|task-graph|structure-baseline|step-ledger)[A-Za-z0-9_.-]*\.json)')) {
    $name = $match.Groups[1].Value
    Add-WorkspaceNode $name
    $workspaceRefs += $name
    $start = [Math]::Max(0, $match.Index - 180); $len = [Math]::Min($raw.Length - $start, 420); $near = $raw.Substring($start, $len)
    $isWrite = Has-AnyMarker $near $writeMarkers
    $isRead = Has-AnyMarker $near $readMarkers
    if (-not $isWrite -and (Has-AnyMarker $raw $writeMarkers) -and $near -match '(?i)\$.*Path|Join-Path') { $isWrite = $true }
    if (-not $isRead -and (Has-AnyMarker $raw $readMarkers) -and $near -match '(?i)Read|Get|Convert|Json') { $isRead = $true }
    if ($isWrite) { $workspaceWrites += $name; $edges += Add-Edge $scriptId 'workspace_write' "workspace:$name" 'workspace JSON write/reference analysis' }
    if ($isRead) { $workspaceReads += $name; $edges += Add-Edge $scriptId 'workspace_read' "workspace:$name" 'workspace JSON read/reference analysis' }
    if (-not $isWrite -and -not $isRead) { $edges += Add-Edge $scriptId 'workspace_reference' "workspace:$name" 'workspace JSON reference' }
  }

  $scripts += [pscustomobject]@{ path=$script; exists=$exists; tier=if($meta){[string]$meta.tier}else{''}; manualOnly=if($meta){[bool]$meta.manualOnly}else{$false}; dangerousSwitches=if($meta){@($meta.dangerousSwitches)}else{@()}; hasMutation=$hasMutation; mutationHits=@($mutationHits|Sort-Object -Unique); params=@($params|Sort-Object -Unique); functions=@($functions|Sort-Object -Unique); calls=@($callTargets); callDetails=@($callDetails|Sort-Object kind,target -Unique); dynamicCallsUnknown=@($unknownDynamic|Sort-Object -Unique); workspaceReads=@($workspaceReads|Sort-Object -Unique); workspaceWrites=@($workspaceWrites|Sort-Object -Unique); workspaceReferences=@($workspaceRefs|Sort-Object -Unique); parseErrorCount=@($errors).Count }
}

$result = [pscustomobject]@{
  schema='super-brain.codegraph-index.v2'; ok=(@($parseErrors).Count -eq 0 -and @($missingMetadata).Count -eq 0); checkedAt=$now; version=[string]$manifest.version; packageRoot=$Root; source='codegraph-index.ps1'; includeInternal=[bool]$IncludeInternal
  nodes=@($nodes); edges=@($edges); scripts=@($scripts); parseErrors=@($parseErrors); missingMetadata=@($missingMetadata)
  summary=[pscustomobject]@{ scriptCount=@($scripts).Count; functionCount=@($nodes|Where-Object{$_.type -eq 'function'}).Count; paramCount=@($nodes|Where-Object{$_.type -eq 'param'}).Count; callEdgeCount=@($edges|Where-Object{$_.relation -like 'script_call*' -and $_.relation -ne 'script_call_dynamic_unknown'}).Count; dynamicCallUnknownCount=@($edges|Where-Object{$_.relation -eq 'script_call_dynamic_unknown'}).Count; workspaceFileCount=@($workspaceNodes.Keys).Count; workspaceReadEdgeCount=@($edges|Where-Object{$_.relation -eq 'workspace_read'}).Count; workspaceWriteEdgeCount=@($edges|Where-Object{$_.relation -eq 'workspace_write'}).Count; workspaceReferenceEdgeCount=@($edges|Where-Object{$_.relation -eq 'workspace_reference'}).Count; parseErrorCount=@($parseErrors).Count; missingMetadataCount=@($missingMetadata).Count; mutationScriptCount=@($scripts|Where-Object{$_.hasMutation}).Count }
  guard='Use this codegraph before script edits to estimate impact, dynamic calls, workspace dataflow, function ownership, and mutation risk.'
}
if (-not $NoWrite) { Write-JsonUtf8NoBom $indexPath $result 14; Write-JsonUtf8NoBom $statusPath $result 14 }
if ($Json) { $result | ConvertTo-Json -Depth 14 } else { Write-Host "CODEGRAPH_INDEX_OK schema=v2 scripts=$(@($scripts).Count) calls=$($result.summary.callEdgeCount) workspace=$($result.summary.workspaceFileCount) dynamicUnknown=$($result.summary.dynamicCallUnknownCount) status=$statusPath" }
if (-not $result.ok) { exit 1 }
exit 0
