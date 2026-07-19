param(
  [ValidateSet('Status','List','Observe','Set','Synthesize','Packet','Enable','Disable','Forget')]
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
  [string]$WorkspaceRoot = '',
  [switch]$ConfirmForget,
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
  $result = switch ($Action) {
    'Status' { Get-UserAdaptationStatus $Root $WorkspaceRoot }
    'List' {
      $paths=Get-UserAdaptationPaths $Root $WorkspaceRoot;$defaults=New-UserAdaptationStoreDefaults
      $status=Get-UserAdaptationStatus $Root $WorkspaceRoot
      $profile=Read-UserAdaptationJson $paths.profile $defaults.profile
      $candidates=Read-UserAdaptationJson $paths.candidates $defaults.candidates
      [pscustomobject]@{ok=$true;action='List';status=$status;preferences=@($profile.entries);candidates=@($candidates.items);rawPromptStored=$false}
    }
    'Observe' {
      Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -Signal $Signal -Source $Source -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot
    }
    'Set' {
      $observation=Add-UserAdaptationObservation -Root $Root -HabitKey $HabitKey -Value $Value -Signal Support -Source explicit_user -Scope $Scope -ScopeKey $ScopeKey -Context $Context -TaskId $TaskId -EvidenceRef $EvidenceRef -WorkspaceRoot $WorkspaceRoot
      $synthesis=Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot
      [pscustomobject]@{ok=($observation.ok-and$synthesis.ok);action='Set';observation=$observation;synthesis=$synthesis;rawPromptStored=$false}
    }
    'Synthesize' { Invoke-UserAdaptationSynthesis -Root $Root -WorkspaceRoot $WorkspaceRoot }
    'Packet' { Get-UserAdaptationPacket -Root $Root -Context $Context -WorkspaceKey $WorkspaceKey -WorkflowKey $WorkflowKey -WorkspaceRoot $WorkspaceRoot }
    'Enable' { Set-UserAdaptationEnabled -Root $Root -Enabled $true -WorkspaceRoot $WorkspaceRoot }
    'Disable' { Set-UserAdaptationEnabled -Root $Root -Enabled $false -WorkspaceRoot $WorkspaceRoot }
    'Forget' {
      if (-not $ConfirmForget) { throw 'USER_ADAPTATION_FORGET_REQUIRES_CONFIRMATION' }
      Remove-UserAdaptationPreference -Root $Root -PreferenceId $PreferenceId -WorkspaceRoot $WorkspaceRoot
    }
  }
  Write-UserAdaptationResult $result 0
} catch {
  $failure=[pscustomobject]@{ok=$false;action=$Action;schema='super-brain.user-adaptation-error.v1';error=$_.Exception.Message;rawPromptStored=$false}
  Write-UserAdaptationResult $failure 1
}
