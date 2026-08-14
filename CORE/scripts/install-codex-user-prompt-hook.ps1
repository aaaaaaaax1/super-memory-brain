[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$PackageRoot = '',
  [switch]$ReportOnly,
  [switch]$NoBackup,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\codex-hook-host-state.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
if([string]::IsNullOrWhiteSpace($PackageRoot)){$PackageRoot=Split-Path -Parent $PSScriptRoot}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$CodexHome=[IO.Path]::GetFullPath($CodexHome)
$hooksPath=Join-Path $CodexHome 'hooks.json'
$configPath=Join-Path $CodexHome 'config.toml'
$hookScript=Join-Path $PackageRoot 'scripts\codex-user-prompt-hook.ps1'
$nativeHook=Join-Path $PackageRoot 'runtime\codex_prompt_hook.py'
$nativeHookLauncher=Join-Path $PackageRoot 'runtime\codex_prompt_hook_launcher.py'
$dispatcherSource=Join-Path $PackageRoot 'runtime\codex_prompt_hook_dispatcher.py'
$hookRuntimeCommon=Join-Path $PackageRoot 'scripts\internal\hook-runtime-common.ps1'
$stableRoot=Join-Path $CodexHome 'hooks\super-memory-brain'
$stableLauncher=Join-Path $stableRoot 'codex_prompt_hook_dispatcher.py'
$stableWindowsLauncher=Join-Path $stableRoot 'codex_prompt_hook_dispatcher.cmd'
$handlerConfigPath=Join-Path $stableRoot 'handler.json'
$installedMemoryMarker=Join-Path $CodexHome 'skills\super-memory-brain\memory-root.txt'
$memoryBase=Get-SuperBrainMemoryBaseRoot $PackageRoot
if(Test-Path -LiteralPath $installedMemoryMarker -PathType Leaf){
  try{
    $installedMemoryRoot=(Get-Content -LiteralPath $installedMemoryMarker -Raw -Encoding UTF8).Trim()
    if(-not[string]::IsNullOrWhiteSpace($installedMemoryRoot)){$memoryBase=Split-Path -Parent ([IO.Path]::GetFullPath($installedMemoryRoot))}
  }catch{}
}
$statusPath=Join-Path (Join-Path $memoryBase 'workspace') 'last-codex-hook-install.json'
$entryReceiptPath=Join-Path $memoryBase 'workspace\runtime-state\prompt-hook-diagnostics\handler-last-entry.json'
$timestamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backups=@()
$createdPaths=@()
$stableRootCreated=$false

function Backup-File([string]$Path){
  if($NoBackup-or-not(Test-Path -LiteralPath $Path)){return}
  $backup="$Path.bak-super-brain-hook-$timestamp"
  Copy-Item -LiteralPath $Path -Destination $backup -Force
  $script:backups += [pscustomobject]@{path=$Path;backup=$backup}
}

function Prepare-ManagedFile([string]$Path){
  if(@($script:backups|Where-Object{$_.path-eq$Path}).Count-gt0){return}
  if(Test-Path -LiteralPath $Path){Backup-File $Path}else{$script:createdPaths += $Path}
}

function Restore-Backups {
  foreach($item in @($script:backups)){
    if(Test-Path -LiteralPath $item.backup){Copy-Item -LiteralPath $item.backup -Destination $item.path -Force}
  }
  foreach($path in @($script:createdPaths|Sort-Object Length -Descending)){
    if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
  }
  if($script:stableRootCreated-and(Test-Path -LiteralPath $stableRoot -PathType Container)-and@(Get-ChildItem -LiteralPath $stableRoot -Force).Count-eq0){
    Remove-Item -LiteralPath $stableRoot -Force -ErrorAction SilentlyContinue
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

function Test-HooksFeatureEnabled([string]$Text){
  if($Text-notmatch'(?ms)^\[features\]\s*.*?(?=^\[|\z)'){return $false}
  return [regex]::IsMatch($Matches[0],'(?mi)^\s*hooks\s*=\s*true\s*(?:#.*)?$')
}

function Get-LocalHookTrustRecord([string]$Text,[string]$HookKey){
  if([string]::IsNullOrWhiteSpace($Text)-or[string]::IsNullOrWhiteSpace($HookKey)){return $null}
  foreach($header in @("[hooks.state.'$HookKey']",('[hooks.state."'+$HookKey+'"]'))){
    $start=$Text.IndexOf($header,[StringComparison]::Ordinal)
    if($start-lt0){continue}
    $section=$Text.Substring($start)
    $next=$section.IndexOf("`n[")
    if($next-ge0){$section=$section.Substring(0,$next)}
    $hashMatch=[regex]::Match($section,'(?mi)^\s*trusted_hash\s*=\s*"(sha256:[a-f0-9]{64})"\s*(?:#.*)?$')
    $enabled=[regex]::IsMatch($section,'(?mi)^\s*enabled\s*=\s*true\s*(?:#.*)?$')
    if($hashMatch.Success-and$enabled){return [pscustomobject]@{key=$HookKey;trustedHash=$hashMatch.Groups[1].Value}}
  }
  return $null
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
    try{if(-not$process.HasExited){$process.WaitForExit(1000)|Out-Null}}catch{}
    try{if(-not$process.HasExited){$process.Kill();$process.WaitForExit(1000)|Out-Null}}catch{}
    $process.Dispose()
  }
}

function Invoke-DispatcherDescription([string]$PythonPath,[string]$DispatcherPath){
  $raw=@(& $PythonPath -X utf8 -B $DispatcherPath --codex-home $CodexHome --package-root $PackageRoot --describe 2>&1)
  $code=$LASTEXITCODE
  $text=($raw|ForEach-Object{[string]$_})-join"`n"
  if($code-ne0){throw "CODEX_HOOK_DISPATCHER_DESCRIBE_FAILED exit=$code $text"}
  return ConvertFrom-SuperBrainJsonOutput $text 'Codex prompt-hook dispatcher description'
}

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}

function Get-ManagedFileState([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{exists=$false;sha256='';lastWriteTimeUtc=''}}
  $item=Get-Item -LiteralPath $Path
  return [pscustomobject]@{
    exists=$true
    sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    lastWriteTimeUtc=[DateTimeOffset]::new($item.LastWriteTimeUtc).ToString('o')
  }
}

function Get-StableWindowsLauncherContent([string]$PythonPath){
  return ((@(
    '@echo off',
    'setlocal DisableDelayedExpansion',
    ('"'+$PythonPath+'" -X utf8 "%~dp0codex_prompt_hook_dispatcher.py" --codex-home "%~dp0..\.." %*'),
    'set "rc=%ERRORLEVEL%"',
    'endlocal & exit /b %rc%'
  )-join"`r`n")+"`r`n")
}

function Test-PackageHookCommand([string]$Command){
  if([string]::IsNullOrWhiteSpace($Command)){return $false}
  foreach($marker in @('codex-user-prompt-hook.ps1','codex_prompt_hook.py','codex_prompt_hook_launcher.py','codex_prompt_hook_dispatcher.py','codex_prompt_hook_dispatcher.cmd')){
    if($Command.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase)-ge0){return $true}
  }
  return $false
}

function Get-PackageHookRecords([string]$Path){
  $document=Read-Json $Path
  if(-not$document-or-not$document.PSObject.Properties['hooks']-or-not$document.hooks.PSObject.Properties['UserPromptSubmit']){return @()}
  $records=@()
  foreach($entry in @($document.hooks.UserPromptSubmit)){
    foreach($hook in @($entry.hooks)){
      $command=[string]$hook.command
      $commandWindows=if($hook.PSObject.Properties['commandWindows']){[string]$hook.commandWindows}else{''}
      if((Test-PackageHookCommand $command)-or(Test-PackageHookCommand $commandWindows)){$records+=$hook}
    }
  }
  return @($records)
}

function Test-CanonicalDirectPythonHookCommand([string]$Actual,[string]$Expected){
  if([string]::IsNullOrWhiteSpace($Actual)-or$Actual-ne$Expected){return $false}
  if($Actual -match '(?i)(^|\s)(call|cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh(?:\.exe)?)(?=\s|$)'){return $false}
  if($Actual -match '(?i)\.(cmd|bat|ps1)(?=("|\s|$))'){return $false}
  return $true
}

function Test-DesiredHookDefinition([object]$Hook,[string]$Command,[string]$CommandWindows){
  if(-not$Hook){return $false}
  $actualWindows=if($Hook.PSObject.Properties['commandWindows']){[string]$Hook.commandWindows}else{''}
  $actualTimeout=if($Hook.PSObject.Properties['timeout']){[int]$Hook.timeout}else{0}
  $actualStatus=if($Hook.PSObject.Properties['statusMessage']){[string]$Hook.statusMessage}else{''}
  return (
    [string]$Hook.type-eq'command'-and
    (Test-CanonicalDirectPythonHookCommand ([string]$Hook.command) $Command)-and
    (Test-CanonicalDirectPythonHookCommand $actualWindows $CommandWindows)-and
    $actualTimeout-eq10-and
    $actualStatus-eq'Super Brain pre-turn gate'
  )
}

try{
  foreach($required in @($hookScript,$nativeHook,$nativeHookLauncher,$dispatcherSource,$hookRuntimeCommon)){
    if(-not(Test-Path -LiteralPath $required)){throw "CODEX_HOOK_REQUIRED_FILE_MISSING: $required"}
  }
  $pythonCommand=Get-Command python -ErrorAction SilentlyContinue
  if(-not$pythonCommand){throw 'CODEX_HOOK_PYTHON_NOT_FOUND'}
  $pythonPath=if(-not[string]::IsNullOrWhiteSpace([string]$pythonCommand.Source)){$pythonCommand.Source}else{[string]$pythonCommand.Name}
  $desiredCommand='"'+$pythonPath+'" -X utf8 "'+$stableLauncher+'" --codex-home "'+$CodexHome+'"'
  # New Desktop configurations execute the same direct Python command on every
  # platform.  The sibling .cmd remains only for already-cached legacy Hosts.
  $desiredCommandWindows=$desiredCommand
  $expectedWindowsLauncherHash=Get-SuperBrainStableHash (Get-StableWindowsLauncherContent $pythonPath) 64
  $sourceHash=(Get-FileHash -LiteralPath $dispatcherSource -Algorithm SHA256).Hash.ToLowerInvariant()
  $preconfiguredHooks=@(Get-PackageHookRecords $hooksPath)
  $preconfiguredHook=if($preconfiguredHooks.Count-eq1){$preconfiguredHooks[0]}else{$null}
  $preconfiguredHookDefinitionMatches=($preconfiguredHooks.Count-eq1-and(Test-DesiredHookDefinition $preconfiguredHook $desiredCommand $desiredCommandWindows))
  $preconfig=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw -Encoding UTF8}else{''}
  $preconfiguredHooksFeatureEnabled=(Test-HooksFeatureEnabled $preconfig)
  $hookDefinitionChanged=(-not$preconfiguredHookDefinitionMatches)
  $hookFeatureChanged=(-not$preconfiguredHooksFeatureEnabled)
  $hooksJsonWriteRequired=[bool]$hookDefinitionChanged
  $configTomlWriteRequired=[bool]$hookFeatureChanged
  $hooksJsonWritePerformed=$false
  $configTomlWritePerformed=$false
  $hooksJsonBefore=Get-ManagedFileState $hooksPath
  $configTomlBefore=Get-ManagedFileState $configPath
  $existingHandlerConfig=Read-Json $handlerConfigPath
  $existingStableHash=if(Test-Path -LiteralPath $stableLauncher){(Get-FileHash -LiteralPath $stableLauncher -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
  $existingStableWindowsHash=if(Test-Path -LiteralPath $stableWindowsLauncher){(Get-FileHash -LiteralPath $stableWindowsLauncher -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
  $stableLauncherNeedsWrite=($existingStableHash-ne$sourceHash)
  $stableWindowsLauncherNeedsWrite=($existingStableWindowsHash-ne$expectedWindowsLauncherHash)
  $runtimeOnlyCandidate=[bool](($stableLauncherNeedsWrite-or$stableWindowsLauncherNeedsWrite)-and-not$hookDefinitionChanged-and-not$hookFeatureChanged)
  $localHookKey=$hooksPath+':user_prompt_submit:0:0'
  $localHookTrust=Get-LocalHookTrustRecord $preconfig $localHookKey

  if(-not$ReportOnly){
    if(-not(Test-Path -LiteralPath $CodexHome)){New-Item -ItemType Directory -Force -Path $CodexHome|Out-Null}
    if(-not(Test-Path -LiteralPath $stableRoot)){$stableRootCreated=$true;New-Item -ItemType Directory -Force -Path $stableRoot|Out-Null}
    if($stableLauncherNeedsWrite){Prepare-ManagedFile $stableLauncher;Copy-Item -LiteralPath $dispatcherSource -Destination $stableLauncher -Force}
    if($stableWindowsLauncherNeedsWrite){Prepare-ManagedFile $stableWindowsLauncher;Write-Utf8NoBom $stableWindowsLauncher (Get-StableWindowsLauncherContent $pythonPath)}
  }

  $descriptionDispatcher=if($ReportOnly){$dispatcherSource}else{$stableLauncher}
  $description=Invoke-DispatcherDescription $pythonPath $descriptionDispatcher
  if(-not$description-or$description.ok-ne$true-or[string]$description.schema-ne'super-brain.prompt-hook-handler-config.v1'-or[string]$description.generation-notmatch'^hg-[a-f0-9]{64}$'){
    throw 'CODEX_HOOK_DISPATCHER_DESCRIPTION_INVALID'
  }
  $installedAt=[DateTimeOffset]::UtcNow
  $existingInstalledAt=if($existingHandlerConfig){ConvertTo-SuperBrainCodexHookTimestamp $existingHandlerConfig.installedAt}else{$null}
  if($existingHandlerConfig-and[string]$existingHandlerConfig.schema-eq'super-brain.prompt-hook-handler-config.v1'-and[string]$existingHandlerConfig.generation-eq[string]$description.generation-and$existingStableHash-eq$sourceHash-and$existingInstalledAt){
    $installedAt=$existingInstalledAt
  }
  if(-not$ReportOnly){
    if($hookDefinitionChanged){
      Prepare-ManagedFile $hooksPath
      $document=if(Test-Path -LiteralPath $hooksPath){Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{hooks=[pscustomobject]@{}}}
      if(-not$document.PSObject.Properties['hooks']){$document|Add-Member NoteProperty hooks ([pscustomobject]@{})}
      $existing=if($document.hooks.PSObject.Properties['UserPromptSubmit']){@($document.hooks.UserPromptSubmit)}else{@()}
      $kept=@(
        foreach($existingEntry in $existing){
          $retainedHooks=@(
            @($existingEntry.hooks)|Where-Object{
              -not((Test-PackageHookCommand ([string]$_.command))-or(Test-PackageHookCommand $(if($_.PSObject.Properties['commandWindows']){[string]$_.commandWindows}else{''})))
            }
          )
          if($retainedHooks.Count -gt 0){
            $retainedEntry=[pscustomobject]@{}
            foreach($property in $existingEntry.PSObject.Properties){$retainedEntry|Add-Member NoteProperty $property.Name $property.Value}
            $retainedEntry.hooks=$retainedHooks
            $retainedEntry
          }
        }
      )
      $entry=[pscustomobject]@{hooks=@([pscustomobject]@{type='command';command=$desiredCommand;commandWindows=$desiredCommandWindows;timeout=10;statusMessage='Super Brain pre-turn gate'})}
      $value=@($kept+$entry)
      if($document.hooks.PSObject.Properties['UserPromptSubmit']){$document.hooks.UserPromptSubmit=$value}else{$document.hooks|Add-Member NoteProperty UserPromptSubmit $value}
      Write-JsonUtf8NoBom $hooksPath $document 12
      $hooksJsonWritePerformed=$true
    }
    if($hookFeatureChanged){Prepare-ManagedFile $configPath;Write-Utf8NoBom $configPath (Enable-HooksFeature $preconfig);$configTomlWritePerformed=$true}
  }

  $hookConfigChangeRequired=($hookDefinitionChanged-or$hookFeatureChanged)
  $hookConfigChangePerformed=((-not$ReportOnly)-and$hookConfigChangeRequired)
  $hookConfigChangeReasonsThisRun=@()
  if($hookDefinitionChanged){$hookConfigChangeReasonsThisRun+='hook_definition'}
  if($hookFeatureChanged){$hookConfigChangeReasonsThisRun+='features.hooks'}
  $existingHookConfigChangeAt=if($existingHandlerConfig-and$existingHandlerConfig.PSObject.Properties['hookConfigChangeAt']){ConvertTo-SuperBrainCodexHookTimestamp $existingHandlerConfig.hookConfigChangeAt}else{$null}
  $existingHookConfigChangeReasons=if($existingHandlerConfig-and$existingHandlerConfig.PSObject.Properties['hookConfigChangeReasons']){@($existingHandlerConfig.hookConfigChangeReasons|ForEach-Object{[string]$_}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}else{@()}
  if($hookConfigChangePerformed){
    $hookConfigChangeAt=[DateTimeOffset]::UtcNow
    $hookConfigChangeReasons=@($hookConfigChangeReasonsThisRun)
  }elseif($existingHookConfigChangeAt){
    $hookConfigChangeAt=$existingHookConfigChangeAt
    $hookConfigChangeReasons=if($existingHookConfigChangeReasons.Count-gt0){@($existingHookConfigChangeReasons)}else{@('legacy_file_timestamp')}
  }else{
    $hookConfigTimes=@()
    foreach($path in @($hooksPath,$configPath)){if(Test-Path -LiteralPath $path){$hookConfigTimes += [DateTimeOffset]::new((Get-Item -LiteralPath $path).LastWriteTimeUtc)}}
    $hookConfigChangeAt=if($hookConfigTimes.Count-gt0){@($hookConfigTimes|Sort-Object)[-1]}else{$installedAt}
    $hookConfigChangeReasons=@('legacy_file_timestamp')
  }
  $protocolValidation='app_server'
  if($runtimeOnlyCandidate-and-not$ReportOnly-and$localHookTrust){
    # A dispatcher-only refresh does not alter hooks.json, config.toml, or the
    # already-recorded trust entry.  Avoid blocking a safe runtime update on a
    # transient Desktop app-server RPC timeout; the next real submit still
    # validates the live handler generation.
    $protocolValidation='cached_local_runtime_only'
    $status=[pscustomobject]@{
      enabled=$true;trustStatus='trusted';eventName='userPromptSubmit';key=[string]$localHookTrust.key;currentHash=[string]$localHookTrust.trustedHash
      warnings=@();errors=@();validation=$protocolValidation
    }
  }else{
    $status=Invoke-HookProtocol (Get-CodexExecutable) $false $CodexHome
  }
  $trustStateWriteRequired=([string]$status.trustStatus-ne'trusted')
  $trustStateWritePerformed=$false
  if($trustStateWriteRequired-and-not$ReportOnly){
    Prepare-ManagedFile $configPath
    $status=Invoke-HookProtocol (Get-CodexExecutable) $true $CodexHome
    $trustStateWritePerformed=$true
  }
  $runtimeOnlyUpdate=[bool]($runtimeOnlyCandidate-and-not$trustStateWriteRequired)
  $handlerConfigNeedsWrite=[bool](-not(
    $existingHandlerConfig-and
    [string]$existingHandlerConfig.schema-eq'super-brain.prompt-hook-handler-config.v1'-and
    [string]$existingHandlerConfig.generation-eq[string]$description.generation-and
    [string]$existingHandlerConfig.packageRoot-eq$PackageRoot-and
    [string]$existingHandlerConfig.dispatcherSha256-eq[string]$description.dispatcherSha256-and
    [string]$existingHandlerConfig.stableLauncherPath-eq$stableLauncher-and
    [string]$existingHandlerConfig.legacyWindowsLauncherPath-eq$stableWindowsLauncher-and
    [string]$existingHandlerConfig.legacyWindowsLauncherSha256-eq$expectedWindowsLauncherHash-and
    $existingHandlerConfig.cachedManagedCommandCompatibility-eq$true-and
    [string]$existingHandlerConfig.hookConfigChangeAt-eq$hookConfigChangeAt.ToUniversalTime().ToString('o')-and
    ((@($existingHookConfigChangeReasons)-join"`n")-eq(@($hookConfigChangeReasons)-join"`n"))-and
    $existingInstalledAt
  ))
  if(-not$ReportOnly-and$handlerConfigNeedsWrite){
    $description|Add-Member NoteProperty installedAt $installedAt.ToUniversalTime().ToString('o') -Force
    $description|Add-Member NoteProperty stableLauncherPath $stableLauncher -Force
    # A Host that cached the prior managed Windows .cmd still lands in this
    # stable dispatcher.  Keep the shim and record that it is safe to request
    # one real submit without forcing a disruptive Desktop restart.
    $description|Add-Member NoteProperty legacyWindowsLauncherPath $stableWindowsLauncher -Force
    $description|Add-Member NoteProperty legacyWindowsLauncherSha256 $expectedWindowsLauncherHash -Force
    $description|Add-Member NoteProperty cachedManagedCommandCompatibility $true -Force
    $description|Add-Member NoteProperty hookConfigChangeAt $hookConfigChangeAt.ToUniversalTime().ToString('o') -Force
    $description|Add-Member NoteProperty hookConfigChangeReasons @($hookConfigChangeReasons) -Force
    Prepare-ManagedFile $handlerConfigPath
    Write-JsonUtf8NoBom $handlerConfigPath $description 8
  }
  $configuredHooks=@(Get-PackageHookRecords $hooksPath)
  $configuredHook=if($configuredHooks.Count-eq1){$configuredHooks[0]}else{$null}
  $configuredCommand=if($configuredHook){[string]$configuredHook.command}else{''}
  $configuredCommandWindows=if($configuredHook-and$configuredHook.PSObject.Properties['commandWindows']){[string]$configuredHook.commandWindows}else{''}
  $configuredCommandMatches=($configuredHooks.Count-eq1-and$configuredCommand-eq$desiredCommand)
  $configuredCommandWindowsMatches=($configuredHooks.Count-eq1-and$configuredCommandWindows-eq$desiredCommandWindows)
  $configuredHookDefinitionMatches=($configuredHooks.Count-eq1-and(Test-DesiredHookDefinition $configuredHook $desiredCommand $desiredCommandWindows))
  $stableLauncherFresh=(Test-Path -LiteralPath $stableLauncher)-and((Get-FileHash -LiteralPath $stableLauncher -Algorithm SHA256).Hash.ToLowerInvariant()-eq$sourceHash)
  $stableWindowsLauncherFresh=(Test-Path -LiteralPath $stableWindowsLauncher)-and((Get-FileHash -LiteralPath $stableWindowsLauncher -Algorithm SHA256).Hash.ToLowerInvariant()-eq$expectedWindowsLauncherHash)
  $installedHandlerConfig=Read-Json $handlerConfigPath
  $installedTimestamp=if($installedHandlerConfig){ConvertTo-SuperBrainCodexHookTimestamp $installedHandlerConfig.installedAt}else{$null}
  $installedHookConfigChangeReasons=if($installedHandlerConfig-and$installedHandlerConfig.PSObject.Properties['hookConfigChangeReasons']){@($installedHandlerConfig.hookConfigChangeReasons|ForEach-Object{[string]$_}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}else{@()}
  $handlerConfigFresh=[bool](
    $installedHandlerConfig-and
    [string]$installedHandlerConfig.schema-eq'super-brain.prompt-hook-handler-config.v1'-and
    [string]$installedHandlerConfig.generation-eq[string]$description.generation-and
    [string]$installedHandlerConfig.packageRoot-eq$PackageRoot-and
    [string]$installedHandlerConfig.dispatcherSha256-eq[string]$description.dispatcherSha256-and
    [string]$installedHandlerConfig.stableLauncherPath-eq$stableLauncher-and
    [string]$installedHandlerConfig.legacyWindowsLauncherPath-eq$stableWindowsLauncher-and
    [string]$installedHandlerConfig.legacyWindowsLauncherSha256-eq$expectedWindowsLauncherHash-and
    $installedHandlerConfig.cachedManagedCommandCompatibility-eq$true-and
    [string]$installedHandlerConfig.hookConfigChangeAt-eq$hookConfigChangeAt.ToUniversalTime().ToString('o')-and
    ((@($installedHookConfigChangeReasons)-join"`n")-eq(@($hookConfigChangeReasons)-join"`n"))-and
    $installedTimestamp
  )
  if(-not$handlerConfigFresh){$installedTimestamp=$null}
  if(-not$installedTimestamp){$installedTimestamp=[DateTimeOffset]::UtcNow}
  $hooksJsonAfter=Get-ManagedFileState $hooksPath
  $configTomlAfter=Get-ManagedFileState $configPath
  $protocolOk=($status.enabled-and$status.trustStatus-eq'trusted'-and$status.eventName-eq'userPromptSubmit'-and@($status.warnings).Count-eq0-and@($status.errors).Count-eq0)
  $configurationOk=($protocolOk-and$configuredHookDefinitionMatches-and$stableLauncherFresh-and$stableWindowsLauncherFresh-and$handlerConfigFresh)
  $defaultCodexHome=[IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\','/')
  $isDefaultCodexHome=$CodexHome.TrimEnd('\','/').Equals($defaultCodexHome,[StringComparison]::OrdinalIgnoreCase)
  $liveHost=if($isDefaultCodexHome){
    Get-SuperBrainCodexHookHostState -InstalledAt $installedTimestamp -HandlerGeneration ([string]$description.generation) -EntryReceiptPath $entryReceiptPath -HookConfigChangeAt $hookConfigChangeAt
  }else{
    Get-SuperBrainCodexHookHostState -InstalledAt $installedTimestamp -HandlerGeneration ([string]$description.generation) -EntryReceiptPath $entryReceiptPath -HookConfigChangeAt $hookConfigChangeAt -ProcessSnapshot ([object[]]@())
  }
  $cachedManagedCommandCompatibility=[bool](
    $handlerConfigFresh-and
    $stableWindowsLauncherFresh-and
    $installedHandlerConfig-and
    [string]$installedHandlerConfig.legacyWindowsLauncherPath-eq$stableWindowsLauncher-and
    [string]$installedHandlerConfig.legacyWindowsLauncherSha256-eq$expectedWindowsLauncherHash-and
    $installedHandlerConfig.cachedManagedCommandCompatibility-eq$true
  )
  $hostConfigurationReloadRequired=[bool]($liveHost-and[bool]$liveHost.restartRequired)
  # Static shim compatibility is advisory only.  A current-generation live
  # entry is the sole proof that the active Host loaded this handler; do not
  # clear restartRequired merely because a legacy launcher file exists.
  $cacheCompatibilityApplied=$false
  $result=[pscustomobject]@{
    ok=$configurationOk
    schema='super-brain.codex-user-prompt-hook-install.v2'
    mode=if($ReportOnly){'report'}else{'apply'}
    checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    hooksPath=$hooksPath
    configPath=$configPath
    hookScript=$hookScript
    nativeHook=$nativeHook
    nativeHookLauncher=$nativeHookLauncher
    dispatcherSource=$dispatcherSource
    stableLauncher=$stableLauncher
    stableWindowsLauncher=$stableWindowsLauncher
    handlerConfigPath=$handlerConfigPath
    handlerGeneration=[string]$description.generation
    handlerInstalledAt=$installedTimestamp.ToUniversalTime().ToString('o')
    pythonPath=$pythonPath
    configuredCommand=$configuredCommand
    configuredCommandWindows=$configuredCommandWindows
    desiredCommand=$desiredCommand
    desiredCommandWindows=$desiredCommandWindows
    configuredCommandMatches=$configuredCommandMatches
    configuredCommandWindowsMatches=$configuredCommandWindowsMatches
    configuredHookDefinitionMatches=$configuredHookDefinitionMatches
    configuredCommandCount=$configuredHooks.Count
    hookDefinitionChangedThisRun=[bool]$hookDefinitionChanged
    hookFeatureChangedThisRun=[bool]$hookFeatureChanged
    hooksJsonWriteRequired=$hooksJsonWriteRequired
    hooksJsonWritePerformed=$hooksJsonWritePerformed
    configTomlWriteRequired=$configTomlWriteRequired
    configTomlWritePerformed=$configTomlWritePerformed
    trustStateWriteRequired=$trustStateWriteRequired
    trustStateWritePerformed=$trustStateWritePerformed
    protocolValidation=$protocolValidation
    localRuntimeOnlyTrustCached=[bool]$localHookTrust
    runtimeOnlyUpdate=$runtimeOnlyUpdate
    hookConfigChangeAt=$hookConfigChangeAt.ToUniversalTime().ToString('o')
    hookConfigChangeReasons=@($hookConfigChangeReasons)
    hooksJsonBefore=$hooksJsonBefore
    hooksJsonAfter=$hooksJsonAfter
    configTomlBefore=$configTomlBefore
    configTomlAfter=$configTomlAfter
    stableLauncherFresh=$stableLauncherFresh
    stableWindowsLauncherFresh=$stableWindowsLauncherFresh
    cachedManagedCommandCompatibility=$cachedManagedCommandCompatibility
    hostConfigurationReloadRequired=$hostConfigurationReloadRequired
    cacheCompatibilityApplied=$cacheCompatibilityApplied
    handlerConfigFresh=$handlerConfigFresh
    configurationOk=$configurationOk
    liveHostValidated=[bool]$liveHost.liveHostValidated
    restartRequired=[bool]$liveHost.restartRequired
    readyForRealSubmit=($configurationOk-and-not[bool]$liveHost.restartRequired)
    p7HostPathAccepted=($configurationOk-and[bool]$liveHost.liveHostValidated-and-not[bool]$liveHost.restartRequired)
    liveHost=$liveHost
    status=$status
    backups=@($backups)
    createdPaths=@($createdPaths)
    nextAction=if(-not$configurationOk){'Repair the stable hook installation before sending another prompt.'}elseif($liveHost.restartRequired){'Fully restart Codex Desktop, then send one real UserPromptSubmit event.'}elseif(-not$liveHost.liveHostValidated){'Send one real UserPromptSubmit event to validate this handler generation.'}else{'The active Desktop Host has executed the installed stable handler generation.'}
  }
  if(-not$ReportOnly){Write-JsonUtf8NoBom $statusPath $result 12}
  if($Json){$result|ConvertTo-Json -Depth 12}else{Write-Host "CODEX_USER_PROMPT_HOOK ok=$configurationOk mode=$($result.mode) trust=$($status.trustStatus) host=$($liveHost.state)"}
  if(-not$configurationOk){exit 1}
  exit 0
}catch{
  if(-not$ReportOnly){Restore-Backups}
  if($Json){[pscustomobject]@{ok=$false;schema='super-brain.codex-user-prompt-hook-install.v2';mode=if($ReportOnly){'report'}else{'apply'};error=$_.Exception.Message;hooksPath=$hooksPath;configPath=$configPath;stableLauncher=$stableLauncher;handlerConfigPath=$handlerConfigPath}|ConvertTo-Json -Depth 6}else{Write-Host "CODEX_USER_PROMPT_HOOK_FAILED $($_.Exception.Message)"}
  exit 1
}
