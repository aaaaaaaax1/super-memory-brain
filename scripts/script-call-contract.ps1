[CmdletBinding(PositionalBinding=$false)]
param([switch]$Json)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$violations=@()
$checkedCalls=0
$parseErrors=@()
$ignoreCommands=@('Get-Content','Read-Utf8','Join-Path','Test-Path','Resolve-Path','Select-String','rg')

foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  foreach($error in @($errors)){$parseErrors += [pscustomobject]@{file=$file.Name;line=$error.Extent.StartLineNumber;message=$error.Message}}
  foreach($command in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true))){
    $text=[string]$command.Extent.Text
    if($text-notmatch'(?i)intent-router\.ps1'){continue}
    $name=[string]$command.GetCommandName()
    if($ignoreCommands-contains$name){continue}
    $checkedCalls++
    $hasTextParameter=($text-match'(?i)-Text')
    $hasTextForwarding=@($command.FindAll({param($node)$node-is[Management.Automation.Language.StringConstantExpressionAst]-and[string]$node.Value-eq'-Text'},$true)).Count-gt0
    if(-not($hasTextParameter-or$hasTextForwarding)){
      $violations += [pscustomobject]@{code='intent_router_text_not_named';file=$file.Name;line=$command.Extent.StartLineNumber;command=$text;required='Pass task text with -Text; reserve -Workspace for an actual path.'}
    }
  }
}

$routerPath=Join-Path $PSScriptRoot 'intent-router.ps1'
$routerText=Get-Content -LiteralPath $routerPath -Raw -Encoding UTF8
if($routerText-notmatch'Parameter\(Position\s*=\s*0\s*,\s*ValueFromRemainingArguments\s*=\s*\$true\)'){
  $violations += [pscustomobject]@{code='intent_router_position_zero_missing';file='intent-router.ps1';line=1;command='parameter contract';required='Text must explicitly own Position=0 for external compatibility.'}
}

$ok=(@($violations).Count-eq0-and@($parseErrors).Count-eq0)
$result=[pscustomobject]@{ok=$ok;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');schema='super-brain.script-call-contract.v1';version=(Get-SuperBrainManifest $Root).version;checkedCalls=$checkedCalls;violationCount=@($violations).Count;parseErrorCount=@($parseErrors).Count;violations=$violations;parseErrors=$parseErrors}
if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "SCRIPT_CALL_CONTRACT ok=$ok calls=$checkedCalls violations=$(@($violations).Count) parseErrors=$(@($parseErrors).Count)"}
if(-not$ok){exit 1}
