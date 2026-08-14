param(
  [ValidateSet('Create','Status','List')]
  [string]$Action = 'List',
  [string]$Module = '',
  [string]$VerifiedBehavior = '',
  [string]$Entrypoint = '',
  [string[]]$Inputs = @(),
  [string[]]$Outputs = @(),
  [string[]]$Dependencies = @(),
  [string[]]$StateAssumptions = @(),
  [string]$VerificationCommand = '',
  [string[]]$Evidence = @(),
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$moduleRoot = Join-Path $workspace 'verified-modules'
if (-not (Test-Path -LiteralPath $moduleRoot)) { New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null }
$outPath = Join-Path $workspace 'last-verified-module-snapshot.json'
function Limit-Text([string]$Value,[int]$Max=400){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Safe-Name([string]$Value){ $v=if([string]::IsNullOrWhiteSpace($Value)){'unnamed-module'}else{$Value}; return (($v -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant() }
function Get-Hash([string]$Raw){ $sha=[Security.Cryptography.SHA256]::Create(); -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Raw))[0..7] | ForEach-Object { $_.ToString('x2') }) }

if($Action -eq 'List'){
  $items=@()
  foreach($p in @(Get-ChildItem -LiteralPath $moduleRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)){
    try{ $o=Get-Content -LiteralPath $p.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $items += [pscustomobject]@{ module=$o.module; snapshotHash=$o.snapshotHash; verifiedBehavior=$o.verifiedBehavior; entrypoint=$o.entrypoint; checkedAt=$o.checkedAt; path=$p.FullName } }catch{}
  }
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.verified-module-snapshot.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; count=@($items).Count; items=@($items); guard='Module verification success is not integration success; snapshots preserve the original verification contract.'; path=$outPath }
  Write-JsonUtf8NoBom $outPath $result 10
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "VERIFIED_MODULE_SNAPSHOT count=$(@($items).Count) path=$outPath"}; exit 0
}

if($Action -eq 'Status'){
  $name=Safe-Name $Module
  $path=Join-Path $moduleRoot ($name+'.json')
  $exists=Test-Path -LiteralPath $path
  $obj=if($exists){try{Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{$null}}else{$null}
  $result=[pscustomobject]@{ ok=$exists; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.verified-module-snapshot.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; module=$Module; exists=$exists; snapshot=$obj; guard='If no snapshot exists, do not claim the module has a reusable verified contract.'; path=$path }
  Write-JsonUtf8NoBom $outPath $result 12
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "VERIFIED_MODULE_SNAPSHOT ok=$exists module=$Module path=$path"}; if(-not $exists){exit 1}; exit 0
}

if([string]::IsNullOrWhiteSpace($Module)){ throw 'Module is required for Create.' }
$envInfo=[pscustomobject]@{ platform=$PSVersionTable.Platform; os=$PSVersionTable.OS; psVersion=$PSVersionTable.PSVersion.ToString(); cwd=(Get-Location).Path; encoding='UTF-8'; shell='PowerShell'; packageRoot=$Root }
$raw=($Module,$VerifiedBehavior,$Entrypoint,($Inputs -join '|'),($Outputs -join '|'),($Dependencies -join '|'),($StateAssumptions -join '|'),$VerificationCommand,($Evidence -join '|'),($envInfo | ConvertTo-Json -Compress)) -join '||'
$hash=Get-Hash $raw
$fileName=(Safe-Name $Module)+'-'+$hash+'.json'
$path=Join-Path $moduleRoot $fileName
$result=[pscustomobject]@{
  ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.verified-module-snapshot.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action
  module=Limit-Text $Module 180; verifiedBehavior=Limit-Text $VerifiedBehavior 600; entrypoint=Limit-Text $Entrypoint 360; inputs=@($Inputs | ForEach-Object { Limit-Text $_ 260 }); outputs=@($Outputs | ForEach-Object { Limit-Text $_ 260 }); environment=$envInfo; dependencies=@($Dependencies | ForEach-Object { Limit-Text $_ 260 }); stateAssumptions=@($StateAssumptions | ForEach-Object { Limit-Text $_ 260 }); verificationCommand=Limit-Text $VerificationCommand 700; evidence=@($Evidence | ForEach-Object { Limit-Text $_ 300 }); snapshotHash=$hash
  guard='This snapshot is a verified module contract. If entrypoint/inputs/environment/dependencies/state/call path changes, prior verification becomes reference evidence and integration must be re-verified.'; nextAction='Run integration-parity-check.ps1 before claiming the module works inside the main system.'; path=$path
}
Write-JsonUtf8NoBom $path $result 12; Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "VERIFIED_MODULE_SNAPSHOT ok=True module=$Module snapshotHash=$hash path=$path"}; exit 0
