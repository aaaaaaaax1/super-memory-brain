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
$handlerSource=Join-Path $PackageRoot 'runtime\codex_stop_hook.py'
$dispatcherSource=Join-Path $PackageRoot 'runtime\codex_stop_hook_dispatcher.py'
$stableRoot=Join-Path $CodexHome 'hooks\super-memory-brain'
$stableDispatcher=Join-Path $stableRoot 'codex_stop_hook_dispatcher.py'
$handlerConfigPath=Join-Path $stableRoot 'stop-handler.json'
$memoryBase=Get-SuperBrainMemoryBaseRoot $PackageRoot
$statusPath=Join-Path (Join-Path $memoryBase 'workspace') 'last-codex-stop-hook-install.json'
$timestamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backups=@();$created=@()

function Backup-ManagedFile([string]$Path){
  if($NoBackup-or-not(Test-Path -LiteralPath $Path)){return}
  $backup="$Path.bak-super-brain-stop-$timestamp"
  Copy-Item -LiteralPath $Path -Destination $backup -Force
  $script:backups += [pscustomobject]@{path=$Path;backup=$backup}
}

function Prepare-ManagedFile([string]$Path){
  if(@($script:backups|Where-Object{$_.path-eq$Path}).Count-gt0){return}
  if(Test-Path -LiteralPath $Path){Backup-ManagedFile $Path}else{$script:created += $Path}
}

function Restore-ManagedFiles {
  foreach($entry in @($backups)){if(Test-Path -LiteralPath $entry.backup){Copy-Item -LiteralPath $entry.backup -Destination $entry.path -Force}}
  foreach($path in @($created|Sort-Object Length -Descending)){if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
}

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
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

function Get-CodexExecutable {
  $candidates=@((Join-Path $CodexHome '.sandbox-bin\codex.exe'),(Join-Path $CodexHome 'plugins\.plugin-appserver\codex.exe'))
  $localBin=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if(Test-Path -LiteralPath $localBin){$candidates+=@(Get-ChildItem -LiteralPath $localBin -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|ForEach-Object{$_.FullName})}
  foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate){return $candidate}}
  throw 'CODEX_STOP_HOOK_INSTALLER_CODEX_EXE_NOT_FOUND'
}

function Invoke-StopHookProtocol([string]$Exe,[bool]$Trust){
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$Exe;$start.Arguments='app-server --stdio';$start.UseShellExecute=$false
  $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
  $start.EnvironmentVariables['CODEX_HOME']=$CodexHome
  $process=New-Object Diagnostics.Process;$process.StartInfo=$start
  if(-not$process.Start()){throw 'CODEX_STOP_HOOK_APP_SERVER_START_FAILED'}
  function Send-Rpc([int]$Id,[string]$Method,[object]$Params){$line=([ordered]@{id=$Id;method=$Method;params=$Params}|ConvertTo-Json -Compress -Depth 12)+"`n";$bytes=[Text.Encoding]::UTF8.GetBytes($line);$process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.BaseStream.Flush()}
  function Read-Rpc([int]$Id,[int]$TimeoutMs=12000){$watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds-lt$TimeoutMs){$remaining=[Math]::Max(1,$TimeoutMs-[int]$watch.ElapsedMilliseconds);$task=$process.StandardOutput.ReadLineAsync();if(-not$task.Wait($remaining)){throw "CODEX_STOP_HOOK_RPC_TIMEOUT id=$Id"};$line=$task.Result;if($null-eq$line){$stderr=$process.StandardError.ReadToEnd();throw "CODEX_STOP_HOOK_RPC_CLOSED id=$Id stderr=$stderr"};try{$message=$line|ConvertFrom-Json}catch{continue};if([int]$message.id-eq$Id){if($message.error){throw "CODEX_STOP_HOOK_RPC_ERROR id=$Id $($message.error.message)"};return $message}};throw "CODEX_STOP_HOOK_RPC_TIMEOUT id=$Id"}
  if($PSVersionTable.PSEdition-eq'Desktop'){$prime=[Text.Encoding]::UTF8.GetBytes("{}`n");$process.StandardInput.BaseStream.Write($prime,0,$prime.Length);$process.StandardInput.BaseStream.Flush()}
  try{
    Send-Rpc 1 'initialize' ([ordered]@{clientInfo=[ordered]@{name='super-brain-stop-hook-installer';version='1.0'};capabilities=[ordered]@{experimentalApi=$true}});$null=Read-Rpc 1
    Send-Rpc 2 'hooks/list' ([ordered]@{cwds=@($PackageRoot)});$listed=Read-Rpc 2
    $group=@($listed.result.data)[0]
    $hook=@($group.hooks|Where-Object{[string]$_.sourcePath-eq$hooksPath-and[string]$_.eventName-match'(?i)^stop$'})|Select-Object -First 1
    if(-not$hook){throw "CODEX_STOP_HOOK_NOT_DISCOVERED: $hooksPath"}
    if($Trust-and[string]$hook.trustStatus-ne'trusted'){
      $value=[ordered]@{};$value[[string]$hook.key]=[ordered]@{trusted_hash=[string]$hook.currentHash}
      Send-Rpc 3 'config/batchWrite' ([ordered]@{edits=@([ordered]@{keyPath='hooks.state';value=$value;mergeStrategy='upsert'});filePath=$null;expectedVersion=$null;reloadUserConfig=$true});$null=Read-Rpc 3
      Send-Rpc 4 'hooks/list' ([ordered]@{cwds=@($PackageRoot)});$listed=Read-Rpc 4;$group=@($listed.result.data)[0]
      $hook=@($group.hooks|Where-Object{[string]$_.sourcePath-eq$hooksPath-and[string]$_.eventName-match'(?i)^stop$'})|Select-Object -First 1
    }
    return [pscustomobject]@{enabled=[bool]$hook.enabled;trustStatus=[string]$hook.trustStatus;eventName=[string]$hook.eventName;key=[string]$hook.key;currentHash=[string]$hook.currentHash;warnings=@($group.warnings);errors=@($group.errors)}
  }finally{
    try{$process.StandardInput.Close()}catch{};try{if(-not$process.HasExited){$process.WaitForExit(1000)|Out-Null}}catch{};try{if(-not$process.HasExited){$process.Kill();$process.WaitForExit(1000)|Out-Null}}catch{};$process.Dispose()
  }
}

function Test-PackageStopCommand([string]$Command){return(-not[string]::IsNullOrWhiteSpace($Command)-and$Command-match'(?i)codex_stop_hook(?:_dispatcher)?\.py')}

function Get-PackageStopRecords([string]$Path){
  $document=Read-Json $Path
  if(-not$document-or-not$document.PSObject.Properties['hooks']-or-not$document.hooks.PSObject.Properties['Stop']){return @()}
  $records=@();foreach($entry in @($document.hooks.Stop)){foreach($hook in @($entry.hooks)){if((Test-PackageStopCommand ([string]$hook.command)) -or (Test-PackageStopCommand $(if($hook.PSObject.Properties['commandWindows']){[string]$hook.commandWindows}else{''}))){$records+=$hook}}};return @($records)
}

function Test-DesiredStopDefinition([object]$Hook,[string]$Command){
  if(-not$Hook){return $false};$windows=if($Hook.PSObject.Properties['commandWindows']){[string]$Hook.commandWindows}else{''};$timeout=if($Hook.PSObject.Properties['timeout']){[int]$Hook.timeout}else{0};$status=if($Hook.PSObject.Properties['statusMessage']){[string]$Hook.statusMessage}else{''}
  return([string]$Hook.type-eq'command'-and[string]$Hook.command-eq$Command-and$windows-eq$Command-and$timeout-eq8-and$status-eq'Super Brain continuation gate')
}

try{
  foreach($path in @($handlerSource,$dispatcherSource)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "CODEX_STOP_HOOK_REQUIRED_FILE_MISSING: $path"}}
  $python=Get-Command python -ErrorAction SilentlyContinue;if(-not$python){throw 'CODEX_STOP_HOOK_PYTHON_NOT_FOUND'};$pythonPath=if($python.Source){[string]$python.Source}else{[string]$python.Name}
  $desiredCommand='"'+$pythonPath+'" -X utf8 "'+$stableDispatcher+'" --codex-home "'+$CodexHome+'"'
  $handlerHash=(Get-FileHash -LiteralPath $handlerSource -Algorithm SHA256).Hash.ToLowerInvariant();$dispatcherHash=(Get-FileHash -LiteralPath $dispatcherSource -Algorithm SHA256).Hash.ToLowerInvariant()
  $generation='sg-'+(Get-SuperBrainStableHash ($handlerHash+'|'+$PackageRoot+'|'+$memoryBase) 32)
  $preHooks=@(Get-PackageStopRecords $hooksPath);$preHook=if($preHooks.Count-eq1){$preHooks[0]}else{$null};$definitionChanged=(-not(Test-DesiredStopDefinition $preHook $desiredCommand))
  $preconfig=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw -Encoding UTF8}else{''};$featureChanged=(-not(Test-HooksFeatureEnabled $preconfig))
  $existingConfig=Read-Json $handlerConfigPath;$existingStableHash=if(Test-Path -LiteralPath $stableDispatcher){(Get-FileHash -LiteralPath $stableDispatcher -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
  $stableChanged=($existingStableHash-ne$dispatcherHash)
  $configChanged=(-not($existingConfig-and[string]$existingConfig.schema-eq'super-brain.stop-hook-handler-config.v1'-and[string]$existingConfig.generation-eq$generation-and[string]$existingConfig.handlerPath-eq$handlerSource-and[string]$existingConfig.handlerSha256-eq$handlerHash-and[string]$existingConfig.packageRoot-eq$PackageRoot-and[string]$existingConfig.stateRoot-eq$memoryBase-and[string]$existingConfig.stableDispatcherPath-eq$stableDispatcher))
  if(-not$ReportOnly){
    if(-not(Test-Path -LiteralPath $CodexHome)){New-Item -ItemType Directory -Force -Path $CodexHome|Out-Null};if(-not(Test-Path -LiteralPath $stableRoot)){New-Item -ItemType Directory -Force -Path $stableRoot|Out-Null}
    if($stableChanged){Prepare-ManagedFile $stableDispatcher;Copy-Item -LiteralPath $dispatcherSource -Destination $stableDispatcher -Force}
    if($configChanged){Prepare-ManagedFile $handlerConfigPath;Write-JsonUtf8NoBom $handlerConfigPath ([ordered]@{schema='super-brain.stop-hook-handler-config.v1';generation=$generation;handlerPath=$handlerSource;handlerSha256=$handlerHash;packageRoot=$PackageRoot;stateRoot=$memoryBase;stableDispatcherPath=$stableDispatcher;installedAt=[DateTimeOffset]::UtcNow.ToString('o');rawPromptStored=$false}) 8}
    if($definitionChanged){
      Prepare-ManagedFile $hooksPath;$document=if(Test-Path -LiteralPath $hooksPath){Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{hooks=[pscustomobject]@{}}};if(-not$document.PSObject.Properties['hooks']){$document|Add-Member NoteProperty hooks ([pscustomobject]@{})}
      $existing=if($document.hooks.PSObject.Properties['Stop']){@($document.hooks.Stop)}else{@()};$kept=@();foreach($entry in $existing){$retained=@(@($entry.hooks)|Where-Object{-not((Test-PackageStopCommand ([string]$_.command)) -or (Test-PackageStopCommand $(if($_.PSObject.Properties['commandWindows']){[string]$_.commandWindows}else{''})))});if($retained.Count-gt0){$copy=[pscustomobject]@{};foreach($property in $entry.PSObject.Properties){$copy|Add-Member NoteProperty $property.Name $property.Value};$copy.hooks=$retained;$kept+=$copy}}
      $entry=[pscustomobject]@{hooks=@([pscustomobject]@{type='command';command=$desiredCommand;commandWindows=$desiredCommand;timeout=8;statusMessage='Super Brain continuation gate'})};$value=@($kept+$entry);if($document.hooks.PSObject.Properties['Stop']){$document.hooks.Stop=$value}else{$document.hooks|Add-Member NoteProperty Stop $value};Write-JsonUtf8NoBom $hooksPath $document 12
    }
    if($featureChanged){Prepare-ManagedFile $configPath;Write-Utf8NoBom $configPath (Enable-HooksFeature $preconfig)}
  }
  $status=Invoke-StopHookProtocol (Get-CodexExecutable) $false;if([string]$status.trustStatus-ne'trusted'-and-not$ReportOnly){$status=Invoke-StopHookProtocol (Get-CodexExecutable) $true}
  $configured=@(Get-PackageStopRecords $hooksPath);$configuredHook=if($configured.Count-eq1){$configured[0]}else{$null};$stableFresh=(Test-Path -LiteralPath $stableDispatcher)-and((Get-FileHash -LiteralPath $stableDispatcher -Algorithm SHA256).Hash.ToLowerInvariant()-eq$dispatcherHash);$installedConfig=Read-Json $handlerConfigPath
  $configFresh=($installedConfig-and[string]$installedConfig.schema-eq'super-brain.stop-hook-handler-config.v1'-and[string]$installedConfig.generation-eq$generation-and[string]$installedConfig.handlerSha256-eq$handlerHash-and[string]$installedConfig.packageRoot-eq$PackageRoot-and[string]$installedConfig.stateRoot-eq$memoryBase)
  $ok=($status.enabled-and$status.trustStatus-eq'trusted'-and[string]$status.eventName-match'(?i)^stop$'-and@($status.warnings).Count-eq0-and@($status.errors).Count-eq0-and(Test-DesiredStopDefinition $configuredHook $desiredCommand)-and$stableFresh-and$configFresh)
  $result=[pscustomobject]@{ok=$ok;schema='super-brain.codex-stop-hook-install.v1';mode=if($ReportOnly){'report'}else{'apply'};hooksPath=$hooksPath;configPath=$configPath;handlerSource=$handlerSource;dispatcherSource=$dispatcherSource;stableDispatcher=$stableDispatcher;handlerConfigPath=$handlerConfigPath;generation=$generation;configuredCommand=if($configuredHook){[string]$configuredHook.command}else{''};desiredCommand=$desiredCommand;configuredCommandCount=$configured.Count;stableDispatcherFresh=$stableFresh;handlerConfigFresh=$configFresh;hookDefinitionChanged=$definitionChanged;hooksFeatureChanged=$featureChanged;status=$status;backups=@($backups);createdPaths=@($created);nextAction=if($ok){'Codex Stop hook is installed and trusted; run a synthetic Stop payload before relying on a real host event.'}else{'Repair the Codex Stop hook installation before relying on automatic continuation.'}}
  if(-not$ReportOnly){Write-JsonUtf8NoBom $statusPath $result 10};if($Json){$result|ConvertTo-Json -Depth 12}else{Write-Host "CODEX_STOP_HOOK ok=$ok trust=$($status.trustStatus)"};if(-not$ok){exit 1}
}catch{
  if(-not$ReportOnly){Restore-ManagedFiles};if($Json){[pscustomobject]@{ok=$false;schema='super-brain.codex-stop-hook-install.v1';mode=if($ReportOnly){'report'}else{'apply'};error=$_.Exception.Message;hooksPath=$hooksPath}|ConvertTo-Json -Depth 6}else{Write-Host "CODEX_STOP_HOOK_FAILED $($_.Exception.Message)"};exit 1
}
