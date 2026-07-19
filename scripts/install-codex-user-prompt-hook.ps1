[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$PackageRoot = '',
  [switch]$ReportOnly,
  [switch]$NoBackup,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
if([string]::IsNullOrWhiteSpace($PackageRoot)){$PackageRoot=Split-Path -Parent $PSScriptRoot}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$CodexHome=[IO.Path]::GetFullPath($CodexHome)
$hooksPath=Join-Path $CodexHome 'hooks.json'
$configPath=Join-Path $CodexHome 'config.toml'
$hookScript=Join-Path $PackageRoot 'scripts\codex-user-prompt-hook.ps1'
$statusPath=Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $PackageRoot) 'workspace') 'last-codex-hook-install.json'
$timestamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backups=@()

function Backup-File([string]$Path){
  if($NoBackup-or-not(Test-Path -LiteralPath $Path)){return}
  $backup="$Path.bak-super-brain-hook-$timestamp"
  Copy-Item -LiteralPath $Path -Destination $backup -Force
  $script:backups += [pscustomobject]@{path=$Path;backup=$backup}
}

function Restore-Backups {
  foreach($item in @($script:backups)){
    if(Test-Path -LiteralPath $item.backup){Copy-Item -LiteralPath $item.backup -Destination $item.path -Force}
  }
}

function Enable-HooksFeature([string]$Text){
  if($Text-match'(?ms)^\[features\]\s*.*?(?=^\[|\z)'){
    $section=$Matches[0]
    if($section-match'(?m)^\s*hooks\s*='){$updated=[regex]::Replace($section,'(?m)^\s*hooks\s*=.*$','hooks = true',1)}
    else{$updated=$section.TrimEnd()+"`r`nhooks = true`r`n"}
    return $Text.Replace($section,$updated)
  }
  return $Text.TrimEnd()+"`r`n`r`n[features]`r`nhooks = true`r`n"
}

function Get-CodexExecutable {
  $candidates=@(
    (Join-Path $CodexHome '.sandbox-bin\codex.exe'),
    (Join-Path $CodexHome 'plugins\.plugin-appserver\codex.exe')
  )
  $localBin=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if(Test-Path -LiteralPath $localBin){$candidates+=@(Get-ChildItem -LiteralPath $localBin -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|ForEach-Object{$_.FullName})}
  foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate){return $candidate}}
  throw 'CODEX_HOOK_INSTALLER_CODEX_EXE_NOT_FOUND'
}

function Invoke-HookProtocol([string]$Exe,[bool]$Trust,[string]$ProtocolCodexHome){
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$Exe;$start.Arguments='app-server --stdio';$start.UseShellExecute=$false
  $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
  $start.EnvironmentVariables['CODEX_HOME']=$ProtocolCodexHome
  $process=New-Object Diagnostics.Process;$process.StartInfo=$start
  if(-not$process.Start()){throw 'CODEX_HOOK_APP_SERVER_START_FAILED'}
  function Send-Rpc([int]$Id,[string]$Method,[object]$Params){$line=([ordered]@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Compress -Depth 12)+"`n";$bytes=[Text.Encoding]::UTF8.GetBytes($line);$process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.BaseStream.Flush()}
  function Read-Rpc([int]$Id,[int]$TimeoutMs=12000){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds-lt$TimeoutMs){
      $remaining=[Math]::Max(1,$TimeoutMs-[int]$watch.ElapsedMilliseconds)
      $task=$process.StandardOutput.ReadLineAsync()
      if(-not$task.Wait($remaining)){throw "CODEX_HOOK_RPC_TIMEOUT id=$Id"}
      $line=$task.Result
      if($null-eq$line){$stderr=$process.StandardError.ReadToEnd();throw "CODEX_HOOK_RPC_CLOSED id=$Id stderr=$stderr"}
      try{$message=$line|ConvertFrom-Json}catch{continue}
      if([int]$message.id-eq$Id){if($message.error){throw "CODEX_HOOK_RPC_ERROR id=$Id $($message.error.message)"};return $message}
    }
    throw "CODEX_HOOK_RPC_TIMEOUT id=$Id"
  }
  # CODEX_HOOK_WINDOWS_POWERSHELL_BOM_PRIME: consume the UTF-8 BOM emitted by Windows PowerShell 5.1.
  if($PSVersionTable.PSEdition-eq'Desktop'){
    $primeBytes=[Text.Encoding]::UTF8.GetBytes("{}`n")
    $process.StandardInput.BaseStream.Write($primeBytes,0,$primeBytes.Length)
    $process.StandardInput.BaseStream.Flush()
  }
  try{
    Send-Rpc 1 'initialize' ([ordered]@{clientInfo=[ordered]@{name='super-brain-hook-installer';version='1.0'};capabilities=[ordered]@{experimentalApi=$true}})
    $null=Read-Rpc 1
    Send-Rpc 2 'hooks/list' ([ordered]@{cwds=@($PackageRoot)})
    $listed=Read-Rpc 2
    $group=@($listed.result.data)[0]
    $hook=@($group.hooks|Where-Object{[string]$_.sourcePath-eq$hooksPath})|Select-Object -First 1
    if(-not$hook){throw "CODEX_HOOK_NOT_DISCOVERED: $hooksPath"}
    if($Trust-and[string]$hook.trustStatus-ne'trusted'){
      $value=[ordered]@{};$value[[string]$hook.key]=[ordered]@{trusted_hash=[string]$hook.currentHash}
      Send-Rpc 3 'config/batchWrite' ([ordered]@{edits=@([ordered]@{keyPath='hooks.state';value=$value;mergeStrategy='upsert'});filePath=$null;expectedVersion=$null;reloadUserConfig=$true})
      $null=Read-Rpc 3
      Send-Rpc 4 'hooks/list' ([ordered]@{cwds=@($PackageRoot)})
      $listed=Read-Rpc 4
      $group=@($listed.result.data)[0]
      $hook=@($group.hooks|Where-Object{[string]$_.sourcePath-eq$hooksPath})|Select-Object -First 1
    }
    return [pscustomobject]@{enabled=[bool]$hook.enabled;trustStatus=[string]$hook.trustStatus;eventName=[string]$hook.eventName;key=[string]$hook.key;currentHash=[string]$hook.currentHash;warnings=@($group.warnings);errors=@($group.errors)}
  }finally{
    try{$process.StandardInput.Close()}catch{}
    try{
      if(-not$process.HasExited){$process.WaitForExit(1000)|Out-Null}
    }catch{}
    try{
      if(-not$process.HasExited){$process.Kill();$process.WaitForExit(1000)|Out-Null}
    }catch{}
    $process.Dispose()
  }
}

try{
  if(-not(Test-Path -LiteralPath $hookScript)){throw "CODEX_HOOK_SCRIPT_MISSING: $hookScript"}
  $desiredCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookScript+'"'
  if(-not$ReportOnly){
    if(-not(Test-Path -LiteralPath $CodexHome)){New-Item -ItemType Directory -Force -Path $CodexHome|Out-Null}
    Backup-File $hooksPath;Backup-File $configPath
    $document=if(Test-Path -LiteralPath $hooksPath){Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{hooks=[pscustomobject]@{}}}
    if(-not$document.PSObject.Properties['hooks']){$document|Add-Member NoteProperty hooks ([pscustomobject]@{})}
    $existing=if($document.hooks.PSObject.Properties['UserPromptSubmit']){@($document.hooks.UserPromptSubmit)}else{@()}
    $kept=@($existing|Where-Object{-not(@($_.hooks|Where-Object{([string]$_.command).Contains('codex-user-prompt-hook.ps1')}).Count)})
    $entry=[pscustomobject]@{hooks=@([pscustomobject]@{type='command';command=$desiredCommand;commandWindows=$desiredCommand;timeoutSec=3;async=$false;statusMessage='Super Brain pre-turn gate'})}
    $value=@($kept+$entry)
    if($document.hooks.PSObject.Properties['UserPromptSubmit']){$document.hooks.UserPromptSubmit=$value}else{$document.hooks|Add-Member NoteProperty UserPromptSubmit $value}
    Write-JsonUtf8NoBom $hooksPath $document 12
    $config=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw -Encoding UTF8}else{''}
    Write-Utf8NoBom $configPath (Enable-HooksFeature $config)
  }
  $status=Invoke-HookProtocol (Get-CodexExecutable) (-not$ReportOnly) $CodexHome
  $ok=($status.enabled-and$status.trustStatus-eq'trusted'-and$status.eventName-eq'userPromptSubmit'-and@($status.warnings).Count-eq0-and@($status.errors).Count-eq0)
  $result=[pscustomobject]@{ok=$ok;mode=if($ReportOnly){'report'}else{'apply'};checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');hooksPath=$hooksPath;configPath=$configPath;hookScript=$hookScript;status=$status;backups=@($backups)}
  if(-not$ReportOnly){Write-JsonUtf8NoBom $statusPath $result 8}
  if($Json){$result|ConvertTo-Json -Depth 10}else{Write-Host "CODEX_USER_PROMPT_HOOK ok=$ok mode=$($result.mode) trust=$($status.trustStatus)"}
  if(-not$ok){exit 1}
  exit 0
}catch{
  if(-not$ReportOnly){Restore-Backups}
  if($Json){[pscustomobject]@{ok=$false;mode=if($ReportOnly){'report'}else{'apply'};error=$_.Exception.Message;hooksPath=$hooksPath;configPath=$configPath}|ConvertTo-Json -Depth 5}else{Write-Host "CODEX_USER_PROMPT_HOOK_FAILED $($_.Exception.Message)"}
  exit 1
}
