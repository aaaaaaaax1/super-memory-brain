param(
  [ValidateSet('Open','Connect','Send','Inbox','WaitInbox','Ack','WaitConnect','WaitReply','SendAndWait','Active','Close','Status')]
  [string]$Action = 'Status',
  [string]$ChannelId = '',
  [string]$BridgeId = '',
  [string]$TaskId = '',
  [string]$From = '',
  [string]$To = '',
  [string]$FromAgentId = '',
  [string]$ToAgentId = '',
  [string]$AgentId = '',
  [string]$OperatorAgentId = '',
  [string]$OperatorName = '',
  [string]$Alias = '',
  [string]$TargetSession = '',
  [string]$TargetSessionName = '',
  [string]$SessionId = '',
  [string]$SessionName = '',
  [string]$MessageId = '',
  [string]$SinceMessageId = '',
  [string]$Intent = 'message',
  [string]$Summary = '',
  [string[]]$Evidence = @(),
  [string[]]$Blockers = @(),
  [string]$NextAction = '',
  [string[]]$Participants = @(),
  [int]$MaxTurns = 20,
  [int]$TtlMinutes = 120,
  [int]$WaitSeconds = 60,
  [int]$PollIntervalSeconds = 2,
  [switch]$AutoAck,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$channelsRoot = Join-Path $bridgeRoot 'channels'
$statusPath = Join-Path $bridgeRoot 'last-agent-bridge-channel.json'
$activePath = Join-Path $bridgeRoot 'active-agent-bridge-channel.json'
$logPath = Join-Path $bridgeRoot 'channel-log.jsonl'
foreach ($dir in @($bridgeRoot,$channelsRoot)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Limit-Text([string]$Text, [int]$Max = 400) { if ([string]::IsNullOrWhiteSpace($Text)) { return '' }; $v=$Text.Trim(); if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Get-SafeName([string]$Value, [string]$Fallback) { $safe=([string]$Value -replace '[^A-Za-z0-9._-]','-').Trim('-'); if([string]::IsNullOrWhiteSpace($safe)){$safe=$Fallback}; return $safe.ToLowerInvariant() }
function New-ChannelId { return 'chan-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')) }
function New-MessageId { return 'msg-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')) }
function Get-ChannelPath([string]$Id) { return Join-Path $channelsRoot ((Get-SafeName $Id 'channel') + '.json') }
function Read-Json([string]$Path) { if(-not (Test-Path -LiteralPath $Path)){return $null}; try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null } }
function Read-Channel([string]$Id) { if([string]::IsNullOrWhiteSpace($Id)){return $null}; return Read-Json (Get-ChannelPath $Id) }
function Save-Channel([object]$Channel) { $Channel.updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); $path=Get-ChannelPath ([string]$Channel.channelId); Write-JsonUtf8NoBom $path $Channel 14; return $path }
function Write-ChannelLog([string]$Event,[object]$Payload){ $record=[pscustomobject]@{time=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');event=$Event;channelId=$script:ChannelId;payload=$Payload}; Add-Utf8LineLocked $logPath ($record|ConvertTo-Json -Depth 8 -Compress) }
function New-Participant([string]$Id,[string]$Name,[string]$SessId,[string]$SessName){ return [pscustomobject]@{agentId=$Id;agentName=$Name;sessionId=$SessId;sessionName=$SessName;alias='';joinedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')} }
function Add-ParticipantIfMissing([object]$Channel,[string]$Id,[string]$Name,[string]$SessId,[string]$SessName,[string]$AliasValue=''){ if([string]::IsNullOrWhiteSpace($Id)){return}; $existing=@($Channel.participants|Where-Object{$_.agentId -eq $Id}); if($existing.Count -eq 0){ $p=New-Participant $Id $Name $SessId $SessName; $p.alias=$AliasValue; $Channel.participants=@(@($Channel.participants)+@($p)) } }
function Get-TargetSessionValue([object]$Message){ $prop=$Message.PSObject.Properties['target-session']; if($prop){return [string]$prop.Value}; return '' }
function Is-Expired([object]$Channel){ if(-not $Channel -or -not $Channel.createdAt){return $false}; try { return ((Get-Date) - [DateTime]::Parse([string]$Channel.createdAt)).TotalMinutes -gt [int]$Channel.ttlMinutes } catch { return $false } }
function Read-Active { return Read-Json $activePath }
function Save-Active([object]$Active){ $Active.updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Write-JsonUtf8NoBom $activePath $Active 10 }
function Clear-Active { if(Test-Path -LiteralPath $activePath){ Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue } }
function Resolve-ActiveChannel {
  $active=Read-Active
  if(-not $active -or $active.status -ne 'active'){ return $null }
  $ch=Read-Channel ([string]$active.channelId)
  if(-not $ch -or $ch.status -eq 'closed' -or (Is-Expired $ch)){ return $null }
  return [pscustomobject]@{ active=$active; channel=$ch }
}
function Ensure-OpenChannel {
  if([string]::IsNullOrWhiteSpace($script:ChannelId)){ $script:ChannelId=New-ChannelId }
  $ch=Read-Channel $script:ChannelId
  if($ch){ return $ch }
  $plist=@()
  foreach($p in @($Participants)){ if($p){ $plist += New-Participant $p '' '' '' } }
  if($FromAgentId){ $plist += New-Participant $FromAgentId $From $SessionId $SessionName }
  if($ToAgentId){ $plist += New-Participant $ToAgentId $To $TargetSession $TargetSessionName }
  $plist=@($plist|Where-Object{$_.agentId}|Sort-Object agentId -Unique)
  return [pscustomobject]@{ ok=$true; schema='agent-bridge.channel.v2'; version=[string]$manifest.version; channelId=$script:ChannelId; bridgeId=$BridgeId; taskId=$TaskId; mode='target-session'; status='open'; createdAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); updatedAt=''; closedAt=''; openedByAgentId=$FromAgentId; targetSessionId=$TargetSession; targetSessionName=$TargetSessionName; maxTurns=$MaxTurns; ttlMinutes=$TtlMinutes; participants=@($plist); messages=@(); lastRead=[pscustomobject]@{} }
}
function Get-ChannelForAction([bool]$AllowCreate=$false){
  if(-not [string]::IsNullOrWhiteSpace($script:ChannelId)){ $ch=Read-Channel $script:ChannelId; if($ch){return $ch}; if($AllowCreate){ return Ensure-OpenChannel }; throw "Channel not found: $script:ChannelId" }
  $resolved=Resolve-ActiveChannel
  if($resolved){ $script:ChannelId=[string]$resolved.channel.channelId; return $resolved.channel }
  if($AllowCreate){ return Ensure-OpenChannel }
  throw 'No ChannelId and no active channel. Connect first.'
}
function New-Message([object]$Channel,[string]$FromId,[string]$ToId,[string]$TargetSess,[string]$Text){
  $id=if($MessageId){$MessageId}else{New-MessageId}
  $msg=[pscustomobject]@{ messageId=$id; channelId=$Channel.channelId; bridgeId=$BridgeId; taskId=$TaskId; fromAgentId=$FromId; toAgentId=$ToId; from=$From; to=$To; intent=$Intent; summary=Limit-Text $Text 1200; evidence=@($Evidence|Select-Object -First 8|ForEach-Object{Limit-Text ([string]$_) 240}); blockers=@($Blockers|Select-Object -First 8|ForEach-Object{Limit-Text ([string]$_) 240}); nextAction=Limit-Text $NextAction 400; status='pending'; createdAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); ackBy=@(); ackAt='' }
  $msg | Add-Member -NotePropertyName 'target-session' -NotePropertyValue $TargetSess
  return $msg
}
function Find-Replies([object]$Channel,[string]$ForAgentId,[string]$AfterMessageId=''){
  $msgs=@($Channel.messages)
  if($AfterMessageId){ $seen=$false; $msgs=@($msgs|Where-Object{ if($seen){$true}elseif($_.messageId -eq $AfterMessageId){$seen=$true;$false}else{$false} }) }
  return @($msgs|Where-Object{ $_.status -eq 'pending' -and $_.toAgentId -eq $ForAgentId })
}
function Get-InboxMessages([object]$Channel,[string]$ForAgentId,[string]$SessId=''){
  return @($Channel.messages|Where-Object{ $_.status -eq 'pending' -and $_.toAgentId -eq $ForAgentId -and ([string]::IsNullOrWhiteSpace($SessId) -or [string]::IsNullOrWhiteSpace((Get-TargetSessionValue $_)) -or (Get-TargetSessionValue $_) -eq $SessId) })
}
function Get-WaitConnectStatus([object]$Channel,[string]$TargetId){
  if(-not $Channel){ return [pscustomobject]@{done=$true;status='missing'} }
  if($Channel.status -eq 'closed'){ return [pscustomobject]@{done=$true;status='closed'} }
  if(Is-Expired $Channel){ return [pscustomobject]@{done=$true;status='expired'} }
  $active=Read-Active
  if($active -and $active.status -eq 'active' -and $active.channelId -eq $Channel.channelId -and ([string]::IsNullOrWhiteSpace($TargetId) -or $active.targetAgentId -eq $TargetId)){
    return [pscustomobject]@{done=$true;status='connected';active=$active}
  }
  return [pscustomobject]@{done=$false;status='waiting_connect'}
}

$result=$null

if($Action -eq 'Open'){
  # Open is a subordinate/target-session entry command. Without an explicit
  # ChannelId it must create a fresh channel for the current conversation,
  # not reuse the operator's active/last channel from another session.
  if([string]::IsNullOrWhiteSpace($script:ChannelId)){ $script:ChannelId=New-ChannelId }
  $channel=Get-ChannelForAction $true
  if($FromAgentId){ Add-ParticipantIfMissing $channel $FromAgentId $From $SessionId $SessionName $Alias }
  if($ToAgentId){ Add-ParticipantIfMissing $channel $ToAgentId $To $TargetSession $TargetSessionName $Alias }
  $path=Save-Channel $channel
  $result=[pscustomobject]@{ok=$true;action='Open';channelId=$channel.channelId;status='waiting_connect';channelStatus=$channel.status;targetState='waiting_connect';path=$path;participants=@($channel.participants);readyForConnect=$true;silentUntilConnected=$true;closeOnlyByUser=$true}
  Write-ChannelLog 'Open' $result
}
elseif($Action -eq 'Connect'){
  $channel=Get-ChannelForAction $false
  $opId=if($OperatorAgentId){$OperatorAgentId}elseif($FromAgentId){$FromAgentId}else{$AgentId}
  if([string]::IsNullOrWhiteSpace($opId)){ throw 'OperatorAgentId or FromAgentId is required for Connect.' }
  $targetId=if($ToAgentId){$ToAgentId}else{$AgentId}
  if([string]::IsNullOrWhiteSpace($targetId)){ throw 'ToAgentId is required for Connect.' }
  Add-ParticipantIfMissing $channel $opId $OperatorName $SessionId $SessionName ''
  Add-ParticipantIfMissing $channel $targetId $To $TargetSession $TargetSessionName $Alias
  $channel | Add-Member -NotePropertyName connectedAt -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force
  $channel | Add-Member -NotePropertyName operatorAgentId -NotePropertyValue $opId -Force
  $channel | Add-Member -NotePropertyName operatorName -NotePropertyValue $OperatorName -Force
  $channel | Add-Member -NotePropertyName targetAgentId -NotePropertyValue $targetId -Force
  $channel | Add-Member -NotePropertyName alias -NotePropertyValue $Alias -Force
  $path=Save-Channel $channel
  $expires=(Get-Date).AddMinutes($TtlMinutes).ToString('yyyy-MM-dd HH:mm:ss')
  $active=[pscustomobject]@{ ok=$true; schema='agent-bridge.channel.active.v1'; version=[string]$manifest.version; status='active'; channelId=$channel.channelId; alias=$Alias; operatorAgentId=$opId; operatorName=$OperatorName; targetAgentId=$targetId; targetName=$To; targetSessionId=$TargetSession; targetSessionName=$TargetSessionName; connectedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); updatedAt=''; expiresAt=$expires; lastSentMessageId=''; lastReceivedMessageId=''; guards=[pscustomobject]@{ workspaceOnly=$true; noSharedMemoryAdoption=$true; boundedWaitOnly=$true; userCloseClearsActive=$true } }
  Save-Active $active
  $result=[pscustomobject]@{ok=$true;action='Connect';channelId=$channel.channelId;active=$active;path=$path;activePath=$activePath}
  Write-ChannelLog 'Connect' $result
}
elseif($Action -eq 'Active'){
  $resolved=Resolve-ActiveChannel
  if($resolved){ $result=[pscustomobject]@{ok=$true;action='Active';active=$true;state=$resolved.active;channelStatus=$resolved.channel.status;activePath=$activePath} } else { $result=[pscustomobject]@{ok=$true;action='Active';active=$false;activePath=$activePath} }
}
elseif($Action -eq 'WaitConnect'){
  $channel=Get-ChannelForAction $false
  $targetId=if($AgentId){$AgentId}elseif($FromAgentId){$FromAgentId}else{$ToAgentId}
  if([string]::IsNullOrWhiteSpace($targetId)){ throw 'AgentId or FromAgentId is required for WaitConnect.' }
  $deadline=(Get-Date).AddSeconds([Math]::Max(0,$WaitSeconds))
  $state=$null
  do {
    $channel=Read-Channel $channel.channelId
    $state=Get-WaitConnectStatus $channel $targetId
    if(-not $state.done){ Start-Sleep -Seconds ([Math]::Max(1,$PollIntervalSeconds)) }
  } while(-not $state.done -and (Get-Date) -lt $deadline)
  if(-not $state.done){ $state=[pscustomobject]@{done=$true;status='idle_waiting_connect';idle=$true;notBlocked=$true} }
  $result=[pscustomobject]@{ok=$true;action='WaitConnect';channelId=$script:ChannelId;agentId=$targetId;status=$state.status;active=$state.active;waitSeconds=$WaitSeconds;boundedWait=$true;silentUntilConnected=$true;noRepeatedWaitingOutput=$true;idleWait=($state.status -eq 'idle_waiting_connect');notBlocked=($state.status -eq 'idle_waiting_connect');noProgressReportRequired=($state.status -eq 'idle_waiting_connect');path=(Get-ChannelPath $script:ChannelId)}
}
elseif($Action -eq 'Send' -or $Action -eq 'SendAndWait'){
  $resolved=Resolve-ActiveChannel
  $channel=Get-ChannelForAction $false
  if($resolved -and [string]::IsNullOrWhiteSpace($FromAgentId)){ $FromAgentId=[string]$resolved.active.operatorAgentId }
  if($resolved -and [string]::IsNullOrWhiteSpace($ToAgentId)){ $ToAgentId=[string]$resolved.active.targetAgentId }
  if($resolved -and [string]::IsNullOrWhiteSpace($TargetSession)){ $TargetSession=[string]$resolved.active.targetSessionId }
  if([string]::IsNullOrWhiteSpace($FromAgentId)){ throw 'FromAgentId is required for Send.' }
  if([string]::IsNullOrWhiteSpace($ToAgentId)){ throw 'ToAgentId is required for Send.' }
  if(Is-Expired $channel){ throw 'Channel expired.' }
  if(@($channel.messages).Count -ge [int]$channel.maxTurns){ throw 'Channel maxTurns reached.' }
  Add-ParticipantIfMissing $channel $FromAgentId $From $SessionId $SessionName ''
  Add-ParticipantIfMissing $channel $ToAgentId $To $TargetSession $TargetSessionName $Alias
  $msg=New-Message $channel $FromAgentId $ToAgentId $TargetSession $Summary
  $channel.messages=@(@($channel.messages)+@($msg))
  $path=Save-Channel $channel
  $active=Read-Active; if($active -and $active.channelId -eq $channel.channelId -and $FromAgentId -eq $active.operatorAgentId){ $active.lastSentMessageId=$msg.messageId; Save-Active $active }
  $sendResult=[pscustomobject]@{ok=$true;action='Send';channelId=$channel.channelId;message=$msg;path=$path}
  Write-ChannelLog 'Send' $sendResult
  if($Action -eq 'Send') { $result=$sendResult } else {
    $deadline=(Get-Date).AddSeconds([Math]::Max(0,$WaitSeconds)); $reply=@()
    do { Start-Sleep -Seconds ([Math]::Max(1,$PollIntervalSeconds)); $channel=Read-Channel $channel.channelId; $reply=Find-Replies $channel $FromAgentId $msg.messageId } while(@($reply).Count -eq 0 -and (Get-Date) -lt $deadline)
    if(@($reply).Count -gt 0 -and $AutoAck){ foreach($r in @($reply)){ foreach($m in @($channel.messages)){ if($m.messageId -eq $r.messageId){ $m.status='acked'; $m.ackBy=@(@($m.ackBy)+@($FromAgentId)|Select-Object -Unique); $m.ackAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } } }; Save-Channel $channel | Out-Null }
    $active=Read-Active; if($active -and @($reply).Count -gt 0){ $active.lastReceivedMessageId=$reply[0].messageId; Save-Active $active }
    $result=[pscustomobject]@{ok=$true;action='SendAndWait';channelId=$channel.channelId;sent=$msg;status=if(@($reply).Count -gt 0){'reply_received'}else{'timeout'};replyCount=@($reply).Count;replies=@($reply);waitSeconds=$WaitSeconds;activePath=$activePath}
  }
}
elseif($Action -eq 'Inbox' -or $Action -eq 'WaitInbox'){
  $channel=Get-ChannelForAction $false
  if([string]::IsNullOrWhiteSpace($AgentId)){ $active=Read-Active; if($active){$AgentId=[string]$active.operatorAgentId} }
  if([string]::IsNullOrWhiteSpace($AgentId)){ throw 'AgentId is required for Inbox.' }
  if($Action -eq 'Inbox'){
    $items=Get-InboxMessages $channel $AgentId $SessionId
    $result=[pscustomobject]@{ok=$true;action='Inbox';channelId=$channel.channelId;agentId=$AgentId;sessionId=$SessionId;count=$items.Count;messages=@($items);path=(Get-ChannelPath $channel.channelId)}
  } else {
    $deadline=(Get-Date).AddSeconds([Math]::Max(0,$WaitSeconds)); $items=@(); $state='idle_waiting_message'
    do {
      $channel=Read-Channel $channel.channelId
      if(-not $channel){ $state='missing'; break }
      if($channel.status -eq 'closed'){ $state='closed'; break }
      if(Is-Expired $channel){ $state='expired'; break }
      $items=Get-InboxMessages $channel $AgentId $SessionId
      if(@($items).Count -gt 0){ $state='message_received'; break }
      Start-Sleep -Seconds ([Math]::Max(1,$PollIntervalSeconds))
    } while((Get-Date) -lt $deadline)
    $idle=($state -eq 'idle_waiting_message')
    $result=[pscustomobject]@{ok=$true;action='WaitInbox';channelId=$script:ChannelId;agentId=$AgentId;sessionId=$SessionId;status=$state;count=@($items).Count;messages=@($items);waitSeconds=$WaitSeconds;boundedWait=$true;silentUntilMessage=$true;noRepeatedWaitingOutput=$true;idleWait=$idle;notBlocked=$idle;noProgressReportRequired=$idle;path=(Get-ChannelPath $script:ChannelId)}
  }
}
elseif($Action -eq 'WaitReply'){
  $resolved=Resolve-ActiveChannel; $channel=Get-ChannelForAction $false
  if([string]::IsNullOrWhiteSpace($AgentId)){ if($resolved){$AgentId=[string]$resolved.active.operatorAgentId}else{throw 'AgentId is required for WaitReply.'} }
  if([string]::IsNullOrWhiteSpace($SinceMessageId) -and $resolved){ $SinceMessageId=[string]$resolved.active.lastSentMessageId }
  $deadline=(Get-Date).AddSeconds([Math]::Max(0,$WaitSeconds)); $reply=@()
  do { $channel=Read-Channel $channel.channelId; $reply=Find-Replies $channel $AgentId $SinceMessageId; if(@($reply).Count -eq 0){ Start-Sleep -Seconds ([Math]::Max(1,$PollIntervalSeconds)) } } while(@($reply).Count -eq 0 -and (Get-Date) -lt $deadline)
  $result=[pscustomobject]@{ok=$true;action='WaitReply';channelId=$channel.channelId;agentId=$AgentId;status=if(@($reply).Count -gt 0){'reply_received'}else{'timeout'};replyCount=@($reply).Count;replies=@($reply);waitSeconds=$WaitSeconds}
}
elseif($Action -eq 'Ack'){
  $channel=Get-ChannelForAction $false
  if([string]::IsNullOrWhiteSpace($AgentId)){ throw 'AgentId is required for Ack.' }
  if([string]::IsNullOrWhiteSpace($MessageId)){ throw 'MessageId is required for Ack.' }
  foreach($m in @($channel.messages)){ if($m.messageId -eq $MessageId -and $m.toAgentId -eq $AgentId){ $acks=@($m.ackBy); if($acks -notcontains $AgentId){$acks+=$AgentId}; $m.ackBy=@($acks); $m.status='acked'; $m.ackAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
  $path=Save-Channel $channel
  $result=[pscustomobject]@{ok=$true;action='Ack';channelId=$channel.channelId;messageId=$MessageId;agentId=$AgentId;path=$path}
  Write-ChannelLog 'Ack' $result
}
elseif($Action -eq 'Close'){
  $channel=Get-ChannelForAction $false
  $channel.status='closed'; $channel.closedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $path=Save-Channel $channel
  $active=Read-Active; if($active -and $active.channelId -eq $channel.channelId){ Clear-Active }
  $result=[pscustomobject]@{ok=$true;action='Close';channelId=$channel.channelId;status=$channel.status;path=$path;activeCleared=$true}
  Write-ChannelLog 'Close' $result
}
else {
  if([string]::IsNullOrWhiteSpace($ChannelId)){ $resolved=Resolve-ActiveChannel; if($resolved){ $channel=$resolved.channel } else { $result=[pscustomobject]@{ok=$true;action='Status';active=$false;total=0;pending=0;activePath=$activePath}; $channel=$null } } else { $channel=Read-Channel $ChannelId }
  if($channel){ $pending=@($channel.messages|Where-Object{$_.status -eq 'pending'}); $result=[pscustomobject]@{ok=$true;action='Status';active=$true;channelId=$channel.channelId;status=$channel.status;participants=@($channel.participants);total=@($channel.messages).Count;pending=$pending.Count;path=(Get-ChannelPath $channel.channelId);updatedAt=$channel.updatedAt} }
}

Write-JsonUtf8NoBom $statusPath $result 14
if($Json){ $result | ConvertTo-Json -Depth 14 } else { Write-Host "AGENT_BRIDGE_CHANNEL action=$Action ok=$($result.ok) channelId=$($result.channelId) statusPath=$statusPath" }
exit 0
