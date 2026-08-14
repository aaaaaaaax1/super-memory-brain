param(
  [ValidateSet('Status','List','PolicyContract','MigratePreview','MigrateApply','Observe','Set','Synthesize','Packet','Explain','Evolution','Enable','Disable','Forget','Reinstate')]
  [string]$Action = 'Status',
  [string]$HabitKey = '',
  [string]$Value = '',
  [ValidateSet('Support','Contradict')]
  [string]$Signal = 'Support',
  [ValidateSet('explicit_user','repeated_behavior','accepted_outcome','user_correction')]
  [string]$Source = 'repeated_behavior',
  [ValidateSet('global','project','workflow')]
  [string]$Scope = 'global',
  [string]$ScopeKey = '',
  [ValidateSet('general','coding','debugging','planning','review','design','release')]
  [string]$Context = 'general',
  [string]$TaskId = '',
  [string]$EvidenceRef = '',
  [string]$WorkspaceKey = '',
  [string]$WorkflowKey = '',
  [string]$PreferenceId = '',
  [string]$CandidateId = '',
  [string]$ParametersJson = '',
  [string]$MigrationId = '',
  [int]$ExpectedRevision = -1,
  [string]$TransitionId = '',
  [string]$WorkspaceRoot = '',
  [switch]$ConfirmMigrate,
  [switch]$ConfirmForget,
  [switch]$ConfirmReinstate,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\user-adaptation-core.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot

function Write-UserAdaptationResult($Result,[int]$ExitCode=0) {
  if ($Json) { $Result | ConvertTo-Json -Depth 16 }
  else { Write-Host "USER_ADAPTATION action=$($Result.action) ok=$($Result.ok)" }
  exit $ExitCode
}

try {
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { $WorkspaceKey = Get-SuperBrainWorkspaceKey }
  if ($Scope -eq 'project' -and [string]::IsNullOrWhiteSpace($ScopeKey)) { $ScopeKey = $WorkspaceKey }
  $parameters = $null
  if (-not [string]::IsNullOrWhiteSpace($ParametersJson)) {
    try { $parameters = $ParametersJson | ConvertFrom-Json } catch { throw 'USER_ADAPTATION_PARAMETERS_JSON_INVALID' }
  }
  $result = switch ($Action) {
    'Status' { Get-UserAdaptationStatus $Root $WorkspaceRoot }
    'PolicyContract' { Assert-UserAdaptationPolicyV2 $Root }
    'MigratePreview' { Get-UserAdaptationMigrationPreview $Root $WorkspaceRoot }
    'MigrateApply' {
      if (-not $ConfirmMigrate) { throw 'USER_ADAPTATION_MIGRATION_REQUIRES_CONFIRMATION' }
      Invoke-UserAdaptationMigrationApply -Root $Root -ExpectedMigrationId $MigrationId -ExpectedRevision $ExpectedRevision -WorkspaceRoot $WorkspaceRoot -TransitionId $TransitionId
    }
    'List' {
      $status=Get-UserAdaptationStatus $Root $WorkspaceRoot
      if([string]$status.schema-eq'super-brain.user-adaptation-status.v2'){
        $store=Get-UserAdaptationV2Store $Root $WorkspaceRoot
        [pscustomobject]@{ok=$true;action='List';status=$status;preferences=@($store.profile);candidates=@($store.candidates);rawPromptStored=$false}
      }else{
        $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot;$defaults=New-UserAdaptationStoreDefaults
        $profile=Read-UserAdaptationJson $paths.profile $defaults.profile
        $candidates=Read-UserAdaptationJson $paths.candidates $defaults.candidates
        [pscustomobject]@{ok=$true;action='List';status=$status;preferences=@($profile.entries);candidates=@($candidates.items);rawPromptStored=$false}
      }
    }
    'Observe' {
      Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -Signal $Signal -Source $Source -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot -Parameters $parameters -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId
    }
    'Set' {
      $observation=Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -Signal Support -Source explicit_user -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot -Parameters $parameters -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId
      $synthesis=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $(if($observation.PSObject.Properties['revision']){[int]$observation.revision}else{-1})
      [pscustomobject]@{ok=($observation.ok-and$synthesis.ok);action='Set';observation=$observation;synthesis=$synthesis;rawPromptStored=$false}
    }
    'Synthesize' { Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId }
    'Packet' { Get-UserAdaptationPacket -Root $Root -Context $Context -WorkspaceKey $WorkspaceKey -WorkflowKey $WorkflowKey -WorkspaceRoot $WorkspaceRoot }
    'Explain' { Get-UserAdaptationExplainV2 -Root $Root -PreferenceId $PreferenceId -CandidateId $CandidateId -WorkspaceRoot $WorkspaceRoot }
    'Evolution' { Get-UserAdaptationEvolutionV2 -Root $Root -WorkspaceRoot $WorkspaceRoot }
    'Enable' { Set-UserAdaptationEnabled -Root $Root -Enabled $true -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId }
    'Disable' { Set-UserAdaptationEnabled -Root $Root -Enabled $false -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId }
    'Forget' {
      if (-not $ConfirmForget) { throw 'USER_ADAPTATION_FORGET_REQUIRES_CONFIRMATION' }
      Remove-UserAdaptationPreference -Root $Root -PreferenceId $PreferenceId -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -Confirmed
    }
    'Reinstate' {
      if (-not $ConfirmReinstate) { throw 'USER_ADAPTATION_REINSTATE_REQUIRES_CONFIRMATION' }
      Invoke-UserAdaptationReinstateV2 -Root $Root -Scope $Scope -ScopeKey $ScopeKey -HabitKey $HabitKey -WorkspaceRoot $WorkspaceRoot -ExpectedRevision $ExpectedRevision -TransitionId $TransitionId -Confirmed
    }
  }
  Write-UserAdaptationResult $result 0
} catch {
  $failure=[pscustomobject]@{ok=$false;action=$Action;schema='super-brain.user-adaptation-error.v1';error=$_.Exception.Message;rawPromptStored=$false}
  Write-UserAdaptationResult $failure 1
}
